classdef NBIoTSimulator < handle
    %NBIOTSIMULATOR Главный объект: пошаговая WAVEFORM-симуляция соты NB-IoT (ТЗ §9, §45).
    %   Оркеструет все модули: трафик, состояния UE (ТЗ §12), процедуру RA (Msg1–Msg4, ТЗ §18–19),
    %   передачу данных по NPUSCH с CRC и HARQ (ТЗ §20), контроллер (ТЗ §23–25) и сбор KPI/датасета.
    %
    %   Модель времени: целые тики по 1 мс (cfg.simulation.tickSeconds), горизонт
    %   cfg.simulation.durationTicks (база 5000). Сигналы PHY живут на частоте 1,92 МГц:
    %   1 тик = 1920 отсчётов. Приём сигнала завершается событием в очереди receiveQueue
    %   на первом тике после окончания передачи и обработки (cfg.phy.processingTicks).
    %
    %   Ключевой принцип: ни один исход приёма не решается по «истинному» знанию симулятора
    %   (SNR, факт коллизии). Решают только приёмники PHY по суммарному waveform.
    %   Истина пишется отдельно (truth) и используется лишь для KPI и target датасета (ТЗ §40).
    %
    %   Использование:
    %     sim = nbiot.NBIoTSimulator(cfg);   % cfg с калибровкой NPRACH (loadCalibration)
    %     sim.run();                         % до горизонта; sim.run(N) — до тика N; sim.step() — 1 тик
    %     result = sim.result();             % struct результата (ТЗ §47)
    %
    %   Состояния объекта (status): ready → running → partial (остановлен на тике < горизонта)
    %   → completed | stopped | failed.
    properties (SetAccess=private)
        % Проверенная конфигурация (nbiot.config.validateConfig).
        cfg
        % Внешняя реализация: геометрия, link budget, расписание пакетов (nbiot.scenario.buildScenario).
        scenario
        % Текущий тик модели (мс).
        currentTick = 0
        % ready | running | partial | completed | stopped | failed.
        status = 'ready'
        stopReason = ''
        errorInfo = struct()
        % Действующие параметры управления: вероятность доступа P (Adaptive-P) и доля RA в
        % ресурсах (Adaptive-RA/DT), а также тик, с которого они действуют. Static: P=1, RA=0.1.
        runtimeAction = struct('accessProbability',1,'raShare',0.1,'effectiveTick',0)
        % Протокольные состояния UE (nbiot.devices.DeviceStore, типизированные массивы).
        devices
        % Очереди пакетов UE (nbiot.traffic.PacketStore), лимит очереди — cfg.traffic.
        packets
        % Контексты RA на стороне BS — по одному на обнаруженную преамбулу (nbiot.ra.RaContextStore).
        contexts
        % Календари ресурсов UL/DL и квоты RA/DT по окнам 500 мс (nbiot.scheduler.ResourceCalendar).
        calendar
        % Планировщик назначений: RAR, Msg3, Msg4, N0/N1 grants, ACK (nbiot.scheduler.Scheduler).
        scheduler
        % Радиоканал: хранит переданные waveform и выдаёт суммарный принятый сигнал (nbiot.channel.RadioChannel).
        channel
        % Журнал попыток RA (Msg1) — истина для KPI: collision/capture считаются по совпадению NInit.
        attempts = struct('attemptId',{},'ueId',{},'packetId',{},'occasionId',{}, ...
            'nInit',{},'startTick',{},'endTick',{},'status',{},'collision',{},'capture',{})
    end
    properties (Access=private)
        % Именованные потоки случайности (nbiot.randomness.RandomSources), ТЗ §42–43.
        sources
        % Очередь событий завершения приёма (nbiot.engine.EventQueue): тик готовности → обработчик.
        receiveQueue
        % Журнал наблюдений BS (только то, что BS реально знает) — источник признаков ML/контроллера.
        observed
        % Журнал истины (реальные передачи, коллизии, доставки) — только KPI и target, ТЗ §40.
        truth
        % Диагностика приёма для анализа PHY (компоненты сигнала, перекрытия, оценки задержки/CFO).
        radioReceptionDiagnostics
        % Журнал жизненного цикла: вызовы run/step, остановки, загрузка модели (не физика).
        lifecycleLog
        % Журнал HARQ по транспортным блокам данных: scheduled / emitted / decoded / terminal.
        harqJournal
        % Сэмплы очередей по тикам: [тик, сумма длин очередей UE, максимум].
        queueSamples = zeros(0,3)
        % Контроллер (ТЗ §23): метод, политика, модель ML; журнал решений и последняя оценка нагрузки.
        controllerRuntime = struct()
        controllerLog = struct([])
        controllerLatestEstimate = struct('valid',false,'value',NaN, ...
            'featureWindowEndTick',NaN,'reason','not-started')
        % Возможности NPRACH (occasions), заранее зарезервированные планировщиком.
        occasions
        % Следующий тик для step(); курсор по расписанию поступлений scenario.arrivals.
        nextTick = 0
        arrivalCursor = 1
        % Флаг: кандидаты мониторинга NPDCCH уже поставлены в очередь на этом тике.
        monitorQueued = false
        % Уникальные 48-битные идентификаторы конкуренции (contention resolution, Msg3/Msg4).
        tokens
        % Строки датасета по закрытым окнам: признаки BS (observation) и истина (target).
        observationRows = {}
        targetRows = {}
        % Интегралы по тикам текущего окна датасета (для средних значений target).
        raIntegral = 0
        activeIntegral = 0
        queueIntegral = 0
        % Счётчики ошибок CRC, видимые BS (для живого отображения).
        observedCrcCounters = struct('msg3Errors',0,'dataErrors',0)
        elapsedSeconds = 0
        stopRequested = false
        resultCache = []
    end
    methods
        %NBIOTSIMULATOR Создаёт симулятор: проверяет cfg, строит сценарий и все модули.
        %   CFG — конфигурация; SCENARIO — готовая внешняя реализация (пусто → строится по seed);
        %   CONTROLLEROPTIONS — для Adaptive-*: оценщик нагрузки и политика
        %   (см. nbiot.controller.prepareRuntime). Для Static не задаётся.
        function obj=NBIoTSimulator(cfg,scenario,controllerOptions)
            if nargin<1, cfg=nbiot.config.defaultConfig(); end
            if nargin<3, controllerOptions=struct(); end
            obj.cfg=nbiot.config.validateConfig(cfg);
            obj.lifecycleLog=nbiot.results.EventLog();
            obj.lifecycleLog.append(0,'simulation_initialized', ...
                struct('profileVersion',obj.cfg.profileVersion));
            obj.controllerRuntime=nbiot.controller.prepareRuntime(obj.cfg,controllerOptions);
            if obj.controllerRuntime.enabled
                obj.lifecycleLog.append(0,'model_loaded',struct( ...
                    'method',obj.controllerRuntime.method, ...
                    'modelMetadata',obj.controllerRuntime.modelMetadata));
            end
            obj.controllerLog=struct('decisionTick',{},'effectiveTick',{}, ...
                'featureWindowEndTick',{},'method',{},'estimateValue',{}, ...
                'estimateValid',{},'proposedAccessProbability',{},'proposedRaShare',{}, ...
                'appliedAccessProbability',{},'appliedRaShare',{},'applied',{}, ...
                'switched',{},'reason',{},'estimateReason',{}, ...
                'errorIdentifier',{},'errorMessage',{},'featureValuesJson',{});
            obj.runtimeAction=struct('accessProbability',obj.cfg.policy.accessProbability, ...
                'raShare',obj.cfg.policy.raShare,'effectiveTick',0);
            % Все потоки случайности одной внешней реализации: (seed, realizationId), ТЗ §42–43.
            obj.sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
            % Сценарий строится один раз и одинаков для Static/Adaptive при равных seed и realizationId (ТЗ §63).
            if nargin<2 || isempty(scenario), scenario=nbiot.scenario.buildScenario(cfg,obj.sources); end
            obj.validateScenario(scenario); obj.scenario=scenario;
            obj.devices=nbiot.devices.DeviceStore(cfg.simulation.numUE);
            obj.packets=nbiot.traffic.PacketStore(cfg); obj.contexts=nbiot.ra.RaContextStore();
            obj.calendar=nbiot.scheduler.ResourceCalendar(cfg);
            obj.scheduler=nbiot.scheduler.Scheduler(cfg,obj.calendar);
            obj.channel=nbiot.channel.RadioChannel(cfg,scenario,obj.sources);
            obj.receiveQueue=nbiot.engine.EventQueue();
            obj.observed=nbiot.results.EventLog(); obj.truth=nbiot.results.EventLog();
            obj.radioReceptionDiagnostics=nbiot.results.EventLog();
            obj.harqJournal=nbiot.results.EventLog();
            % NPRACH резервируется заранее на весь горизонт: период 80 мс, старт 8 мс (ADR-005).
            obj.occasions=obj.scheduler.reserveNprach();
            obj.tokens=containers.Map('KeyType','char','ValueType','logical');
        end
        %RUN Выполняет шаги до тика UNTILTICK включительно (по умолчанию — до горизонта).
        %   Повторный вызов продолжает с места остановки; результат идентичен непрерывному прогону.
        function run(obj,untilTick)
            if nargin<2, untilTick=obj.cfg.simulation.durationTicks; end
            validateattributes(untilTick,{'numeric'},{'scalar','integer','>=',obj.currentTick,'<=',obj.cfg.simulation.durationTicks});
            if any(strcmp(obj.status,{'completed','stopped','failed'})), return; end
            firstRun=strcmp(obj.status,'ready');
            obj.status='running'; clockStart=tic;
            if firstRun
                obj.lifecycleLog.append(obj.currentTick,'simulation_started', ...
                    struct('untilTick',double(untilTick)));
            end
            try
                % Без LTE Toolbox и без калибровки порога NPRACH расчёт не имеет смысла — сразу ошибка.
                nbiot.phy.requireToolbox();
                if ~isfinite(obj.cfg.phy.nprachThreshold)
                    error('nbiot:phy:Calibration','Run examples/calibrateNprach.m and load its threshold before a KPI experiment.');
                end
                % Основной цикл модели: один шаг = 1 мс.
                while obj.nextTick<=untilTick && ~obj.stopRequested, obj.step(); end
                if obj.stopRequested, obj.status='stopped';
                elseif obj.nextTick>obj.cfg.simulation.durationTicks, obj.status='completed'; obj.stopReason='horizon';
                else, obj.status='partial'; end
            catch exception
                obj.status='failed'; obj.stopReason='exception';
                obj.errorInfo=struct('identifier',exception.identifier,'message',exception.message,'stack',exception.stack);
            end
            if any(strcmp(obj.status,{'completed','stopped','failed'}))
                lifecycleKind='simulation_completed';
                switch obj.status
                    case 'stopped', lifecycleKind='simulation_stopped';
                    case 'failed', lifecycleKind='simulation_failed';
                end
                lifecycleFields=struct('actualTick',obj.currentTick,'reason',obj.stopReason);
                if strcmp(obj.status,'failed')
                    lifecycleFields.errorIdentifier=obj.errorInfo.identifier;
                    lifecycleFields.errorMessage=obj.errorInfo.message;
                end
                obj.lifecycleLog.append(obj.currentTick,lifecycleKind,lifecycleFields);
            end
            obj.elapsedSeconds=obj.elapsedSeconds+toc(clockStart);
            obj.resultCache=[];
        end
        %APPLYRUNTIMEACTION Применяет решение контроллера (P и доля RA) с текущего тика.
        %   Допустимы только значения из заранее заданного множества (ТЗ §23) и только на границе
        %   окна 500 мс. Если новые квоты RA/DT не вмещают уже выданные назначения — отказ целиком.
        %   Возвращает APPLIED (true/false) и REASON (причину отказа или 'applied').
        function [applied,reason]=applyRuntimeAction(obj,action)
            applied=false; reason='unsupported-action';
            if ~isstruct(action)||~isscalar(action)|| ...
                    ~all(isfield(action,{'accessProbability','raShare','effectiveTick'}))
                return;
            end
            p=action.accessProbability; share=action.raShare; tick=action.effectiveTick;
            % Допустимые действия: P для Adaptive-P (ТЗ §24) и доли RA 10/20/30 % для Adaptive-RA/DT (ТЗ §25).
            supportedP=[0.1 0.25 0.5 0.75 1]; supportedShares=[0.1 0.2 0.3];
            if ~isnumeric(p)||~isscalar(p)||~isfinite(p)||~any(p==supportedP)|| ...
                    ~isnumeric(share)||~isscalar(share)||~isfinite(share)||~any(share==supportedShares)
                return;
            end
            windowTicks=obj.cfg.policy.windowTicks;
            if ~isnumeric(tick)||~isscalar(tick)||~isfinite(tick)||tick~=fix(tick)|| ...
                    tick<=0||tick>=obj.cfg.simulation.durationTicks||tick~=obj.currentTick|| ...
                    mod(tick,windowTicks)~=0
                reason='wrong-effective-tick'; return;
            end
            if any(strcmp(obj.status,{'completed','stopped','failed'}))
                reason='session-not-active'; return;
            end
            % Смена доли RA перестраивает квоты календаря с этого тика; при конфликте — отказ.
            if share~=obj.runtimeAction.raShare
                if ~obj.scheduler.applyShareFrom(tick,share)
                    reason='resource-budget-conflict'; return;
                end
            end
            obj.runtimeAction=struct('accessProbability',double(p), ...
                'raShare',double(share),'effectiveTick',double(tick));
            obj.resultCache=[]; applied=true; reason='applied';
        end
        %STEP Один шаг модели (1 мс). Порядок внутри тика зафиксирован (docs/architecture.md):
        %   1) завершить приёмы, готовые к этому тику; 2) истечение срока жизни пакетов; 3) таймеры UE/BS;
        %   4) новые пакеты; 5) закрыть окно датасета и, если нужно, решение контроллера;
        %   6) новые передачи: служебный DL, NPRACH, назначения, мониторинг NPDCCH; 7) статистика очередей.
        function step(obj)
            if any(strcmp(obj.status,{'completed','stopped','failed'})) || obj.stopRequested, return; end
            obj.resultCache=[];
            now=obj.nextTick; obj.currentTick=now; obj.monitorQueued=false;
            % На тике 0 у контроллера ещё нет закрытого окна: фиксируем «решения нет».
            if now==0&&obj.controllerRuntime.enabled&&isempty(obj.controllerLog)
                obj.processControllerWindow([],0);
            end
            % Complete physical receptions first, including the horizon boundary.
            ready=obj.receiveQueue.popReady(now);
            for k=1:numel(ready), obj.handleReceive(ready(k)); end
            if now<obj.cfg.simulation.durationTicks
                % Пакеты, у которых истёк срок жизни (cfg.traffic lifetime): попытка RA считается неуспешной.
                expired=obj.packets.expireLifetime(now);
                for u=1:obj.cfg.simulation.numUE
                    d=obj.devices.get(u);
                    if ismember(d.packetId,double(expired))
                        if d.attemptId>0 && strcmp(obj.attempts(d.attemptId).status,'started')
                            obj.attempts(d.attemptId).status='failure';
                            obj.attempts(d.attemptId).endTick=now;
                            obj.truth.append(now,'ra_failure',struct( ...
                                'attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                                'reason','packet_lifetime'));
                        end
                        obj.devices.reset(u);
                    end
                end
                % Таймеры (окно RAR, contention timer, BACKOFF), поступления пакетов, переход IDLE→WAIT_RA.
                obj.advanceTimers(); obj.addArrivals(); obj.activateHeads();
            end
            % Граница окна датасета (500 мс) или горизонт: закрыть окно и запустить контроллер (ТЗ §22–23).
            if now>0 && (mod(now,obj.cfg.dataset.windowTicks)==0 || now==obj.cfg.simulation.durationTicks)
                first=floor((now-1)/obj.cfg.dataset.windowTicks)*obj.cfg.dataset.windowTicks;
                observation=obj.closeWindow(first,now);
                if obj.controllerRuntime.enabled&&now<obj.cfg.simulation.durationTicks
                    obj.processControllerWindow(observation,now);
                end
            end
            if now<obj.cfg.simulation.durationTicks
                % Обязательные DL-сигналы соты (NPSS/NSSS/NRS и т.п.) — занимают ресурсы и создают помехи.
                mandatory=nbiot.phy.buildMandatoryTransmission(obj.cfg,now);
                if ~isempty(mandatory), obj.channel.add(mandatory); end
                % Новые передачи этого тика: Msg1 на возможности NPRACH, назначения BS, кандидаты NPDCCH.
                obj.emitNprach(); obj.schedulePending(); obj.queueMonitoring();
                % Статистика для target и KPI: число UE в RA, число UE с работой, длины очередей.
                [ra,~]=obj.devices.counts();
                work=0; waiting=0; totalQueued=0; maxQueued=0;
                for u=1:obj.cfg.simulation.numUE
                    queueLength=obj.packets.queueLength(u);
                    waiting=waiting+max(0,queueLength-1);
                    totalQueued=totalQueued+queueLength; maxQueued=max(maxQueued,queueLength);
                end
                obj.queueSamples(end+1,:)=[now,totalQueued,maxQueued];
                if ~isempty(obj.packets.packets)
                    pending=obj.packets.packets(strcmp({obj.packets.packets.status},'pending'));
                    work=numel(unique([pending.ueId]));
                end
                obj.raIntegral=obj.raIntegral+ra; obj.activeIntegral=obj.activeIntegral+work;
                obj.queueIntegral=obj.queueIntegral+waiting/obj.cfg.simulation.numUE;
                obj.observed.append(now,'bs_queue',struct('pendingRequests',sum([obj.contexts.entries.pending])));
                % Освободить память канала: отсчёты старше 128 мс уже не попадут ни в одно окно приёма.
                obj.channel.discardBefore(max(0,(now-128)*1920));
            end
            obj.nextTick=now+1;
            if now==obj.cfg.simulation.durationTicks, obj.status='completed'; obj.stopReason='horizon'; end
        end
        %STOP Запрашивает остановку; текущий тик завершается, состояние можно сохранить.
        function stop(obj,reason)
            if nargin<2, reason='requested'; end
            obj.resultCache=[];
            obj.stopRequested=true; obj.stopReason=char(reason);
            obj.lifecycleLog.append(obj.currentTick,'stop_requested', ...
                struct('reason',obj.stopReason));
            if ~strcmp(obj.status,'failed'), obj.status='stopped'; end
        end
        %SNAPSHOT Лёгкое состояние для GUI (ТЗ §46.6): тик, статус, UE, счётчики. Не меняет модель.
        function s=snapshot(obj)
            schema=nbiot.dataset.featureSchema();
            targets=obj.rowsTable(obj.targetRows,schema.targetNames);
            diagnosticTargets=targets(:,{'endTick','meanRaUe'});
            transmittedPacketCount=nbiot.metrics.countTransmittedPackets( ...
                obj.harqJournal.all(),obj.currentTick);
            s=struct('tick',obj.currentTick,'status',obj.status,'devices',obj.devices.entries, ...
                'pendingEvents',obj.receiveQueue.count(),'packetCounters',obj.packets.counters, ...
                'transmittedPacketCount',transmittedPacketCount, ...
                'crcCounters',obj.observedCrcCounters,'runtimeAction',obj.runtimeAction, ...
                'controllerLatestEstimate',obj.controllerLatestEstimate, ...
                'controllerLog',obj.controllerLog,'controllerMethod',obj.controllerRuntime.method, ...
                'controllerDiagnosticTargets',diagnosticTargets, ...
                'tickSeconds',obj.cfg.simulation.tickSeconds);
        end
        %OBSERVEDEVENTSSINCE События журнала BS после индекса AFTERINDEX (для журнала GUI).
        function [events,nextIndex]=observedEventsSince(obj,afterIndex)
            if nargin<2, afterIndex=0; end
            [events,nextIndex]=obj.observed.since(afterIndex);
        end
        %RESULT Собирает struct результата (ТЗ §47): журналы, KPI (ТЗ §27), датасет (ТЗ §22).
        %   Можно вызывать на паузе: незавершённые пакеты/попытки помечаются 'unfinished' в копии,
        %   состояние симулятора не меняется. Результат кэшируется до следующего шага.
        function result=result(obj)
            if ~isempty(obj.resultCache), result=obj.resultCache; return; end
            packets=obj.packets.packets;
            % Do not mutate resumable state when exporting a partial result.
            for k=1:numel(packets)
                if strcmp(packets(k).status,'pending'), packets(k).status='unfinished'; packets(k).reason=obj.stopReason; end
            end
            attempts=obj.attempts;
            for k=1:numel(attempts)
                if strcmp(attempts(k).status,'started'), attempts(k).status='unfinished'; end
            end
            obs=obj.observed.all(); truth=obj.truth.all();
            deviceStates=cell(obj.cfg.simulation.numUE,1);
            for u=1:obj.cfg.simulation.numUE
                device=obj.devices.get(u); deviceStates{u}=device.state;
            end
            % Link budget пересчитывается для экспорта per-UE таблицы (ТЗ §47, Per-UE).
            finalScenario=obj.scenario;
            finalScenario.linkBudget=nbiot.channel.evaluateLinks(obj.cfg,finalScenario.ue);
            result=nbiot.results.finalizeResult(obj.cfg,finalScenario,packets,attempts,obs,truth, ...
                obj.calendar.usage(),obj.currentTick,obj.status,obj.stopReason,obj.errorInfo,deviceStates);
            result.controllerLog=obj.controllerLog;
            result.controllerLogSchemaVersion=1;
            result.controllerModel=obj.controllerRuntime.modelMetadata;
            if obj.controllerRuntime.enabled
                result.resultSchemaVersion=3;
                result.controllerPolicy=obj.controllerRuntime.policy;
            end
            result.runtimeAction=obj.runtimeAction;
            result.lifecycleLog=obj.lifecycleLog.all();
            result.lifecycleLogSchemaVersion=1;
            result.radioReceptionLog=obj.radioReceptionDiagnostics.all();
            result.radioReceptionSchemaVersion=1;
            result.radioDiagnostics=nbiot.metrics.radioDiagnostics(truth,obs, ...
                result.radioReceptionLog,struct('actualTick',obj.currentTick, ...
                'nInitValues',0:obj.cfg.ra.numSubcarriers-1));
            result.harqLog=obj.harqJournal.all(); result.harqLogSchemaVersion=2;
            result.queueSamples=obj.queueSamples;
            % Основные KPI (ТЗ §27): успех RA, доставка, throughput, коллизии, задержки, BLER, occupancy.
            result.kpiSummary=nbiot.metrics.summarizeKpi(obj.cfg,packets,attempts,obs,truth, ...
                result.resourceUsage,obj.currentTick,result.harqLog,obj.queueSamples);
            [serviceKpi,groupKpi]=nbiot.metrics.serviceKpi( ...
                result.ueSummary,obj.currentTick,strcmp(obj.status,'completed'));
            result.kpiSummary.service=serviceKpi;
            result.groupKpi=groupKpi;
            % An initialized but empty journal is known empty, not legacy data.
            result.kpiSummary.harq.available=true;
            % Временные ряды KPI по окнам (для графиков ТЗ §46.9).
            result.kpiTimeSeries=nbiot.metrics.windowKpi(obj.cfg,packets,attempts,obs, ...
                obj.currentTick,obj.queueSamples,obj.controllerLog);
            controllerSwitchCount=0;
            if ~isempty(obj.controllerLog)
                controllerSwitchCount=sum([obj.controllerLog.switched]);
            end
            result.kpiSummary.controller=struct( ...
                'applicable',obj.controllerRuntime.enabled, ...
                'decisionCount',numel(obj.controllerLog), ...
                'configurationSwitches',controllerSwitchCount);
            % Датасет: признаки BS и target по одним и тем же окнам; ключи окон обязаны совпадать.
            schema=nbiot.dataset.featureSchema();
            observations=obj.rowsTable(obj.observationRows,schema.observationNames);
            targets=obj.rowsTable(obj.targetRows,schema.targetNames);
            windowKeys=observations(:,schema.keyNames);
            if ~isequaln(windowKeys,targets(:,schema.keyNames))
                error('nbiot:dataset:Diagnostics', ...
                    'Observation and target window keys do not align.');
            end
            diagnostics=nbiot.dataset.windowDiagnostics(obj.cfg,packets,attempts,truth,obs, ...
                result.radioReceptionLog,obj.currentTick,windowKeys);
            result.dataset=struct('observations',observations,'targets',targets, ...
                'diagnostics',diagnostics,'schema',schema, ...
                'manifest',nbiot.dataset.buildManifest(obj.scenario.externalRealizationId));
            result.profiling=struct('elapsedSeconds',obj.elapsedSeconds,'matlabValidation','pending');
            obj.resultCache=result;
        end
    end
    methods (Access=private)
        %ADDARRIVALS Ставит в очереди UE пакеты, созданные к текущему тику (ТЗ §11).
        %   При переполнении очереди пакет отбрасывается (drop-tail), это фиксируется в truth.
        function addArrivals(obj)
            a=obj.scenario.arrivals;
            while obj.arrivalCursor<=numel(a) && double(a(obj.arrivalCursor).createdTick)<=obj.currentTick
                arrival=a(obj.arrivalCursor); accepted=obj.packets.enqueue(arrival);
                obj.truth.append(obj.currentTick,'packet_created',struct('packetId',double(arrival.packetId),'ueId',double(arrival.ueId),'accepted',accepted));
                obj.arrivalCursor=obj.arrivalCursor+1;
            end
        end
        %ACTIVATEHEADS UE в IDLE с непустой очередью переходит в WAIT_RA (ТЗ §12).
        function activateHeads(obj)
            for u=1:obj.cfg.simulation.numUE
                d=obj.devices.get(u);
                if strcmp(d.state,'IDLE')
                    id=obj.packets.head(u);
                    if id>0, d.state='WAIT_RA'; d.packetId=double(id); d.nextAllowedTick=max(obj.currentTick,d.ulBusyUntilTick); obj.devices.set(u,d); end
                end
            end
        end
        %EMITNPRACH Msg1: на возможности NPRACH каждое готовое UE передаёт преамбулу (ТЗ §14, §18).
        %   UE в WAIT_RA/BACKOFF с истёкшим ожиданием участвует с вероятностью P (Adaptive-P, ТЗ §24),
        %   выбирает NInit (номер начальной поднесущей = «преамбула») равномерно из 0..numSubcarriers-1
        %   и формирует waveform через LTE Toolbox. Сигналы всех UE складываются в канале.
        function emitNprach(obj)
            at=find([obj.occasions.startTick]==obj.currentTick,1); if isempty(at), return; end
            occasion=obj.occasions(at); ids=[]; indices=[];
            for u=1:obj.cfg.simulation.numUE
                d=obj.devices.get(u);
                if ~any(strcmp(d.state,{'WAIT_RA','BACKOFF'})) || d.nextAllowedTick>obj.currentTick, continue; end
                % Решения UE берутся из потока 'access', адресованного (UE, возможность), — не зависят
                % от числа других вызовов, поэтому внешняя реализация одинакова для всех политик (ТЗ §63).
                stream=obj.sources.stream('access',0,u,occasion.occasionId);
                if rand(stream)>obj.runtimeAction.accessProbability, continue; end
                d.nInit=floor(rand(stream)*obj.cfg.ra.numSubcarriers);
                d.attemptNumber=d.attemptNumber+1; d.lifetimeAttempt=d.lifetimeAttempt+1;
                d.attemptId=numel(obj.attempts)+1; d.occasionId=occasion.occasionId;
                d.token=obj.newToken(u,d.lifetimeAttempt); d.raSucceeded=false;
                % RA-RNTI по 3GPP TS 36.321 для NB-IoT: 1 + floor(SFN/4), SFN = номер кадра 10 мс.
                d.raRnti=1+floor(mod(floor(occasion.startTick/10),1024)/4);
                % Ожидание RAR начинается через 3 подкадра после конца преамбулы (TS 36.321, NRep=1).
                d.state='WAIT_RAR'; d.monitorStartTick=occasion.endTick+3;
                d.deadlineTick=obj.monitoringDeadline(d.monitorStartTick,obj.cfg.ra.rarPp);
                obj.packets.incrementAttempt(d.packetId); obj.devices.set(u,d);
                tx=nbiot.phy.nprach.buildTransmission(obj.cfg,occasion,d.nInit);
                tx.ueId=u; tx.attemptId=d.attemptId; tx.occasionId=occasion.occasionId;
                tx.nInit=d.nInit; obj.channel.add(tx);
                obj.logTx(struct('startTick',occasion.startTick,'ticks',occasion.startTick:occasion.endTick-1, ...
                    'frequencyStartHz',0,'bandwidthHz',45000,'direction','UL','phase','RA','kind','NPRACH'),u);
                a=struct('attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                    'occasionId',occasion.occasionId,'nInit',d.nInit,'startTick',obj.currentTick, ...
                    'endTick',NaN,'status','started','collision',false,'capture',false);
                obj.attempts(end+1)=a; ids(end+1)=d.attemptId; indices(end+1)=d.nInit; %#ok<AGROW>
                obj.truth.append(obj.currentTick,'msg1',struct('attemptId',d.attemptId,'ueId',u,'packetId',d.packetId,'nInit',d.nInit,'occasionId',occasion.occasionId));
            end
            % Истина для KPI: логическая коллизия = несколько UE выбрали один NInit на одной возможности.
            for k=1:numel(ids), obj.attempts(ids(k)).collision=sum(indices==indices(k))>1; end
            % Детектор запускается на каждой возможности, даже без передач, — так считается false alarm.
            % Every configured occasion is detected, including pure noise.
            obj.receiveQueue.push(occasion.endTick+obj.cfg.phy.processingTicks+1,'nprach',occasion);
        end
        %HANDLERECEIVE Обрабатывает завершённый приём (событие из receiveQueue).
        function handleReceive(obj,event)
            switch event.kind
                case 'nprach'
                    % Окно приёма NPRACH: [начало−128; конец+128] отсчётов (запас на задержку распространения).
                    occasion=event.payload; a=max(0,occasion.startTick*1920-128); z=occasion.endTick*1920+128;
                    [rx,radio]=obj.channel.receive('UL',0,a,z);
                    % Детектор видит только принятый суммарный сигнал и конфигурацию — не список передатчиков.
                    [detected,metrics]=nbiot.phy.nprach.detect(obj.cfg,rx,occasion);
                    obj.observed.append(obj.currentTick,'nprach_detection',struct( ...
                        'occasionId',occasion.occasionId,'readyTick',obj.currentTick, ...
                        'candidates',detected,'count',numel(detected), ...
                        'maxMetric',max(metrics),'meanMetric',mean(metrics), ...
                        'energyW',mean(abs(rx.waveform).^2)));
                    for k=1:numel(radio.components)
                        obj.radioReceptionDiagnostics.append(obj.currentTick, ...
                            'nprach_component',radio.components(k));
                    end
                    for k=1:numel(radio.overlaps)
                        obj.radioReceptionDiagnostics.append(obj.currentTick, ...
                            'nprach_overlap',radio.overlaps(k));
                    end
                    % На каждую обнаруженную преамбулу BS создаёт контекст RA и готовит RAR (Msg2).
                    deadline=obj.monitoringDeadline(occasion.endTick+3,obj.cfg.ra.rarPp);
                    for k=1:numel(detected)
                        obj.contexts.create(detected(k).nInit,occasion.occasionId,deadline,detected(k).delaySeconds);
                    end
                case 'monitor'
                    obj.receiveControl(event.payload);
                case 'dl_payload'
                    obj.receiveDlPayload(event.payload);
                case 'bs_ul'
                    obj.receiveAtBs(event.payload);
                otherwise
                    error('nbiot:engine:Event','Unknown completion %s.',event.kind);
            end
        end
        %SCHEDULEPENDING BS выдаёт назначения по ожидающим контекстам RA (ТЗ §19).
        %   Порядок: ближайший дедлайн, затем давность прогресса, затем номер контекста.
        %   Состояния контекста: RAR_PENDING → MSG3_RX → MSG4_PENDING → MSG4_ACK → DATA_PENDING →
        %   DATA_RX → … → RECEIPT_PENDING → RECEIPT_ACK → DONE; при сбоях — FAILED/EXPIRED.
        %   Если ресурса нет (квота RA/DT исчерпана), контекст ждёт следующего тика.
        function schedulePending(obj)
            entries=obj.contexts.entries; if isempty(entries), return; end
            pending=find([entries.pending]);
            if isempty(pending), return; end
            [~,order]=sortrows([[entries(pending).deadlineTick].',[entries(pending).lastProgressTick].',pending.'],[1 2 3]);
            for id=pending(order)
                c=obj.contexts.get(id); s=[];
                if obj.currentTick>c.deadlineTick
                    if strcmp(c.state,'DATA_PENDING'), obj.harqTerminal(c,'failed'); end
                    c.pending=false; c.state='EXPIRED'; obj.contexts.set(id,c); continue;
                end
                switch c.state
                    % Msg2 (RAR): NPDCCH (DCI N1 по RA-RNTI) + NPDSCH с RAPID=NInit, UL grant Msg3, TA, Temp C-RNTI.
                    case 'RAR_PENDING'
                        occasion=obj.occasions(c.occasionId);
                        raRnti=1+floor(mod(floor(occasion.startTick/10),1024)/4);
                        s=obj.scheduler.downlink('RAR','RA',max(obj.currentTick,occasion.endTick+3),c.deadlineTick,raRnti);
                        if isempty(s), continue; end
                        s.msg3Grant.rnti=c.rnti;
                        f=s.rarGrant; f.rapid=c.nInit; f.rnti=c.rnti;
                        % Timing advance в шагах 16·Ts, Ts = 1/(15000·2048) с; диапазон 0..1282 (TS 36.213).
                        f.timingAdvance=max(0,min(1282,round(c.delaySeconds/(16/(15000*2048)))));
                        bits=nbiot.ra.encodeMessage('RAR',f); obj.emitDownlink(s,bits);
                        % Одновременно резервируется ресурс Msg3: выдача RAR без возможности Msg3 запрещена.
                        obj.queueBsUl(id,s.msg3Grant,'Msg3'); c.state='MSG3_RX';
                        c.deadlineTick=obj.monitoringDeadline(s.msg3Grant.endTick,obj.cfg.ra.contentionPp);
                    % Msg4 (contention resolution): идентификатор конкуренции из принятого Msg3 + ожидание ACK.
                    case 'MSG4_PENDING'
                        s=obj.scheduler.downlink('Msg4','RA',obj.currentTick,c.deadlineTick,c.rnti);
                        if isempty(s), continue; end
                        obj.emitDownlink(s,nbiot.ra.encodeMessage('Msg4',struct('token',c.token)));
                        obj.queueBsUl(id,s.ackGrant,'Msg4Ack'); c.state='MSG4_ACK'; c.receiptAttempts=c.receiptAttempts+1;
                    % Данные: DCI N0 + NPUSCH, версия избыточности RV по номеру передачи HARQ (cfg.phy.rvSequence).
                    case 'DATA_PENDING'
                        rv=obj.cfg.phy.rvSequence(c.harqTry);
                        s=obj.scheduler.uplink('Data','DT',obj.currentTick,c.deadlineTick,c.rnti,c.ndi,rv);
                        if isempty(s), continue; end
                        obj.emitControl(s.controlGrant,s.dci); obj.queueBsUl(id,s.payloadGrant,'Data'); c.state='DATA_RX';
                    % Квитанция о доставке пакета (receipt) по NPDSCH + ожидание ACK от UE.
                    case 'RECEIPT_PENDING'
                        s=obj.scheduler.downlink('receipt','DT',obj.currentTick,c.deadlineTick,c.rnti);
                        if isempty(s), continue; end
                        f=struct('sequence',c.sequence,'fragmentIndex',c.nextFragment-1,'status',1);
                        obj.emitDownlink(s,nbiot.ra.encodeMessage('receipt',f));
                        obj.queueBsUl(id,s.ackGrant,'ReceiptAck'); c.state='RECEIPT_ACK'; c.receiptAttempts=c.receiptAttempts+1;
                end
                if ~isempty(s)
                    c.schedule=s; c.pending=false; c.lastProgressTick=obj.currentTick; obj.contexts.set(id,c);
                end
            end
        end
        %EMITCONTROL Передаёт DCI по NPDCCH и пишет факт выдачи grant в журнал BS.
        function emitControl(obj,g,dci)
            tx=nbiot.phy.npdcch.buildTransmission(obj.cfg,g,dci); obj.channel.add(tx);
            obj.logTx(g,0);
            obj.observed.append(obj.currentTick,'grant',struct('phase',g.phase,'rnti',g.rnti,'format',dci.format,'startTick',g.startTick,'endTick',g.endTick));
        end
        %EMITDOWNLINK Передаёт DCI (NPDCCH) и полезную нагрузку (NPDSCH): RAR, Msg4, receipt.
        function emitDownlink(obj,s,bits)
            obj.emitControl(s.controlGrant,s.dci);
            [tx,~]=nbiot.phy.npdsch.buildTransmission(obj.cfg,s.payloadGrant,bits,[]); obj.channel.add(tx);
            obj.logTx(s.payloadGrant,0);
            if strcmpi(s.payloadGrant.kind,'RAR'), obj.observed.append(obj.currentTick,'rar_sent',struct('rnti',s.controlGrant.rnti)); end
        end
        %QUEUEBSUL Ставит в очередь приём UL-передачи на BS после окончания её назначения.
        function queueBsUl(obj,id,g,kind)
            obj.receiveQueue.push(g.endTick+obj.cfg.phy.processingTicks+1,'bs_ul',struct('contextId',id,'grant',g,'kind',kind));
            if strcmp(kind,'Data')
                c=obj.contexts.get(id); f=obj.harqIdentity(c);
                f.startTick=g.startTick; f.endTick=g.endTick;
                f.readyTick=g.endTick+obj.cfg.phy.processingTicks+1;
                obj.harqJournal.append(obj.currentTick,'scheduled',f);
            end
        end
        %QUEUEMONITORING Кандидаты поиска NPDCCH для UE, ожидающих DL (ТЗ §19).
        %   Search space: период 32 мс (Rmax·G), берутся два подкадра кандидата (повторы NPDCCH = 2).
        function queueMonitoring(obj)
            if mod(obj.currentTick,32)~=0, return; end
            ticks=obj.calendar.monitoringTicks(obj.currentTick); if numel(ticks)<2, return; end
            ticks=ticks(1:2); ready=max(ticks)+1+obj.cfg.phy.processingTicks+1;
            for u=1:obj.cfg.simulation.numUE
                d=obj.devices.get(u);
                if ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})) || ticks(1)<d.monitorStartTick, continue; end
                % Полудуплекс FDD: UE не принимает DL, пока передаёт в UL.
                if ticks(1)<d.ulBusyUntilTick && max(ticks)+1>d.ulBusyStartTick, continue; end
                % При ожидании RAR UE ищет DCI N1 по RA-RNTI, далее — N0/N1 по своему C-RNTI.
                if strcmp(d.state,'WAIT_RAR'), rnti=d.raRnti; formats={'N1'}; else, rnti=d.rnti; formats={'N0','N1'}; end
                % Candidate is derived solely from the public monitoring calendar.
                g=struct('ticks',ticks,'startTick',ticks(1),'endTick',max(ticks)+1,'rnti',rnti, ...
                    'profile',struct('repetitions',2,'aggregationLevel',2));
                obj.receiveQueue.push(ready,'monitor',struct('ueId',u,'attemptId',d.attemptId,'grant',g,'formats',{formats}));
            end
        end
        %RECEIVECONTROL UE декодирует NPDCCH-кандидат; по DCI N0 передаёт данные, по N1 ждёт NPDSCH.
        function receiveControl(obj,p)
            d=obj.devices.get(p.ueId);
            if d.attemptId~=p.attemptId || ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})), return; end
            rx=obj.receiverWindow('DL',p.ueId,p.grant);
            for f=1:numel(p.formats)
                g=p.grant; g.format=p.formats{f}; g.profile.format=g.format;
                decoded=nbiot.phy.npdcch.receive(obj.cfg,rx,g);
                if decoded.crcError~=0, continue; end
                try
                    if strcmp(decoded.dci.format,'N0')
                        if ~any(strcmp(d.state,{'DATA','WAIT_RECEIPT'})), continue; end
                        ul=obj.scheduler.reconstructUplink(decoded.dci,g.ticks,d.rnti);
                        obj.ueTransmitData(p.ueId,ul); return;
                    else
                        dl=obj.scheduler.reconstructDownlink(decoded.dci,g.ticks,g.rnti);
                        if isempty(dl), continue; end
                        obj.receiveQueue.push(dl.endTick+obj.cfg.phy.processingTicks+1,'dl_payload', ...
                            struct('ueId',p.ueId,'attemptId',d.attemptId,'grant',dl,'dci',decoded.dci)); return;
                    end
                catch exception
                    if startsWith(exception.identifier,'nbiot:UnsupportedGrant') || startsWith(exception.identifier,'nbiot:protocol:'), continue; end
                    rethrow(exception);
                end
            end
        end
        %RECEIVEDLPAYLOAD UE декодирует NPDSCH: RAR, Msg4 или квитанцию, и реагирует по протоколу.
        function receiveDlPayload(obj,p)
            d=obj.devices.get(p.ueId);
            if d.attemptId~=p.attemptId || ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})), return; end
            rx=obj.receiverWindow('DL',p.ueId,p.grant);
            [decoded,~]=nbiot.phy.npdsch.receive(obj.cfg,rx,p.grant,[]);
            obj.recordDecode('NPDSCH',decoded,p.grant,p.ueId);
            if decoded.crcError~=0, return; end
            try
                % RAR: принимается, только если RAPID совпадает с выбранным NInit и окно RAR не истекло.
                % При логической коллизии RAR примут все UE с этим NInit — и все передадут Msg3 (ТЗ §15).
                if strcmp(d.state,'WAIT_RAR')
                    rar=nbiot.ra.decodeMessage('RAR',decoded.decodedBits);
                    if rar.rapid~=d.nInit || obj.currentTick>d.deadlineTick, return; end
                    ul=obj.scheduler.reconstructMsg3(rar,p.grant.ticks); ul.rnti=rar.rnti;
                    if ul.startTick<obj.currentTick, return; end
                    d.rnti=rar.rnti; d.timingAdvanceSeconds=rar.timingAdvance*16/(15000*2048);
                    d.state='WAIT_MSG4'; d.deadlineTick=obj.monitoringDeadline(ul.endTick,obj.cfg.ra.contentionPp);
                    d.monitorStartTick=ul.endTick; d.ulBusyStartTick=ul.startTick; d.ulBusyUntilTick=ul.endTick;
                    packet=obj.packets.get(d.packetId); bits=nbiot.ra.encodeMessage('Msg3',struct('token',d.token,'sequence',double(packet.sequence)));
                    % Msg3 по NPUSCH: идентификатор конкуренции (token) и номер пакета; TA применяется в канале.
                    [tx,d.encoderState]=nbiot.phy.npusch.buildTransmission(obj.cfg,ul,bits,[]);
                    tx.ueId=p.ueId; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx); obj.devices.set(p.ueId,d);
                    obj.logTx(ul,p.ueId);
                % Msg4 распознаётся по заголовку 60 (тип CE «contention resolution identity»).
                elseif numel(decoded.decodedBits)>=16 && nbiot.util.fromBits(decoded.decodedBits(1:8))==60
                    msg=nbiot.ra.decodeMessage('Msg4',decoded.decodedBits);
                    % Чужой идентификатор конкуренции — это UE проиграл конкуренцию; ждёт таймаут и BACKOFF.
                    if msg.token~=d.token, return; end
                    if strcmp(d.state,'WAIT_MSG4') && obj.currentTick>d.deadlineTick, return; end
                    firstSuccess=~d.raSucceeded;
                    if firstSuccess
                        d.raSucceeded=true; obj.attempts(d.attemptId).status='success'; obj.attempts(d.attemptId).endTick=obj.currentTick;
                        % Capture (ТЗ §16): попытка успешна, хотя на её NInit была логическая коллизия.
                        obj.attempts(d.attemptId).capture=obj.attempts(d.attemptId).collision;
                        obj.truth.append(obj.currentTick,'ra_success',struct('attemptId',d.attemptId,'ueId',p.ueId,'packetId',d.packetId));
                    end
                    if firstSuccess
                        d.state='DATA'; d.fragmentIndex=0; d.ndi=-1; d.monitorStartTick=obj.currentTick;
                        d.progressDeadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                    end
                    obj.devices.set(p.ueId,d); obj.ueAck(p.ueId,p.dci,p.grant,'RA');
                else
                    % Квитанция о доставке последнего фрагмента: пакет завершён на стороне UE.
                    receipt=nbiot.ra.decodeMessage('receipt',decoded.decodedBits); packet=obj.packets.get(d.packetId);
                    if receipt.sequence~=double(packet.sequence) || receipt.status~=1 || receipt.fragmentIndex~=numel(packet.blocks)-1, return; end
                    obj.ueAck(p.ueId,p.dci,p.grant,'DT');
                    obj.packets.localFinish(d.packetId,obj.currentTick,true); obj.devices.reset(p.ueId);
                end
            catch exception
                if startsWith(exception.identifier,'nbiot:protocol:') || startsWith(exception.identifier,'nbiot:UnsupportedGrant'), return; end
                rethrow(exception);
            end
        end
        %UETRANSMITDATA UE передаёт фрагмент пакета по NPUSCH по полученному DCI N0 (ТЗ §20).
        %   Новый NDI — следующий фрагмент; тот же NDI — повтор HARQ (RV меняется в DCI).
        function ueTransmitData(obj,u,g)
            d=obj.devices.get(u); packet=obj.packets.get(d.packetId);
            if d.ndi<0, d.fragmentIndex=0;
            elseif g.ndi~=d.ndi, d.fragmentIndex=d.fragmentIndex+1; d.encoderState=[]; end
            if d.fragmentIndex>=numel(packet.blocks) || g.startTick<obj.currentTick, return; end
            d.ndi=g.ndi; d.state='DATA';
            d.progressDeadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
            d.ulBusyStartTick=g.startTick; d.ulBusyUntilTick=g.endTick;
            [tx,d.encoderState]=nbiot.phy.npusch.buildTransmission(obj.cfg,g,packet.blocks{d.fragmentIndex+1},d.encoderState);
            tx.ueId=u; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx); obj.devices.set(u,d);
            obj.logTx(g,u);
            % Ниже — только журнал HARQ для анализа; на сигнал и состояние UE не влияет.
            % Analyzer provenance only; never influences the waveform or state.
            id=obj.contexts.findRnti(g.rnti);
            if id>0
                c=obj.contexts.get(id);
                if strcmp(c.state,'DATA_RX') && isfield(c.schedule,'payloadGrant') && ...
                        c.schedule.payloadGrant.startTick==g.startTick && c.schedule.payloadGrant.endTick==g.endTick
                    f=obj.harqIdentity(c); f.startTick=g.startTick; f.endTick=g.endTick;
                    f.transmitterSequence=double(packet.sequence); f.transmitterBlockIndex=d.fragmentIndex;
                    f.packetId=double(packet.packetId);
                    obj.harqJournal.append(g.startTick,'emitted',f);
                    return;
                end
            end
            obj.harqJournal.append(g.startTick,'unmatchedEmission', ...
                struct('rnti',g.rnti,'startTick',g.startTick,'endTick',g.endTick, ...
                'packetId',double(packet.packetId)));
        end
        %UEACK UE передаёт ACK (NPUSCH формат 2, 1 бит) на принятые Msg4/квитанцию.
        function ueAck(obj,u,dci,payload,phase)
            d=obj.devices.get(u); g=obj.scheduler.reconstructAck(dci,payload,d.rnti);
            g.phase=phase;
            if g.startTick<obj.currentTick, error('nbiot:engine:Timing','Decoded DL cannot meet its ACK start.'); end
            [tx,~]=nbiot.phy.npusch.buildTransmission(obj.cfg,g,int8(1),[]);
            tx.ueId=u; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx);
            d.ulBusyStartTick=g.startTick; d.ulBusyUntilTick=g.endTick; obj.devices.set(u,d);
            obj.logTx(g,u);
        end
        %RECEIVEATBS BS принимает UL-передачу (Msg3, данные, ACK) по суммарному сигналу и декодирует.
        %   Результат принимается, только если состояние контекста и назначение совпадают с ожидаемыми.
        function receiveAtBs(obj,p)
            c=obj.contexts.get(p.contextId); g=p.grant;
            if any(strcmp(c.state,{'FAILED','EXPIRED','DONE'})), return; end
            % Receive events belong to one public BS state and grant. A queued
            % event from an earlier schedule must not advance a newer context.
            switch p.kind
                case 'Msg3', expectedState='MSG3_RX'; grantField='msg3Grant';
                case 'Data', expectedState='DATA_RX'; grantField='payloadGrant';
                case 'Msg4Ack', expectedState='MSG4_ACK'; grantField='ackGrant';
                case 'ReceiptAck', expectedState='RECEIPT_ACK'; grantField='ackGrant';
                otherwise, return;
            end
            if ~strcmp(c.state,expectedState) || ~isstruct(c.schedule) || ...
                    ~isfield(c.schedule,grantField) || ...
                    ~isequaln(c.schedule.(grantField),g)
                return;
            end
            rx=obj.receiverWindow('UL',0,g);
            [decoded,soft]=nbiot.phy.npusch.receive(obj.cfg,rx,g,c.softBuffer);
            obj.appendNpuschReceptionDiagnostic(p.kind,decoded,g,c);
            obj.recordDecode(p.kind,decoded,g,0);
            switch p.kind
                % Msg3: CRC не прошёл → контекст FAILED (UE уйдёт в BACKOFF по таймауту contention timer).
                case 'Msg3'
                    if decoded.crcError~=0, c.state='FAILED';
                    else
                        try, msg=nbiot.ra.decodeMessage('Msg3',decoded.decodedBits);
                        catch exception
                            if startsWith(exception.identifier,'nbiot:protocol:'), c.state='FAILED'; obj.contexts.set(p.contextId,c); return; end
                            rethrow(exception);
                        end
                        c.token=msg.token; c.sequence=msg.sequence; c.state='MSG4_PENDING'; c.pending=true;
                        c.softBuffer=[]; c.receiptAttempts=0;
                    end
                % Данные: CRC + проверка заголовка фрагмента; мягкие биты сохраняются для HARQ-объединения.
                case 'Data'
                    harqFields=obj.harqIdentity(c); accepted=false;
                    c.softBuffer=soft;
                    if decoded.crcError==0
                        b=decoded.decodedBits;
                        try
                            f=obj.fragmentHeader(b);
                            % Пакет 200 байт = 1600 бит режется на фрагменты по 208 бит полезных данных (TB 256 бит с заголовком).
                            valid=f.sequence==c.sequence && f.index==c.nextFragment-1 && f.count==ceil(obj.cfg.traffic.packetBytes*8/208);
                        catch, valid=false; end
                        if valid
                            accepted=true;
                            % Ground-truth mapping below is an analyzer side effect only;
                            % BS scheduling uses the decoded header/token, not PacketStore.
                            obj.analyzeDelivery(c,b,f.index);
                            if c.nextFragment==f.count
                                c.dataComplete=true; c.state='RECEIPT_PENDING'; c.receiptAttempts=0;
                            else
                                c.nextFragment=c.nextFragment+1; c.ndi=1-c.ndi; c.state='DATA_PENDING';
                            end
                            c.harqTry=1; c.softBuffer=[]; c.pending=true;
                            c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                        else, c=obj.failedTb(c); end
                    else, c=obj.failedTb(c); end
                    harqFields.crcError=decoded.crcError; harqFields.accepted=accepted;
                    obj.harqJournal.append(obj.currentTick,'decoded',harqFields);
                    if accepted
                        harqFields.outcome='accepted'; obj.harqJournal.append(obj.currentTick,'terminal',harqFields);
                    elseif strcmp(c.state,'FAILED')
                        harqFields.outcome='failed'; obj.harqJournal.append(obj.currentTick,'terminal',harqFields);
                    end
                % ACK без CRC: решение по детектору UCI (uciDetected) и значению бита.
                case {'Msg4Ack','ReceiptAck'}
                    ack=~decoded.hasCrc && ~isempty(decoded.decodedBits) && decoded.decodedBits(1)==1 && ...
                        isfield(decoded.measurements,'uciDetected') && decoded.measurements.uciDetected;
                    if ack
                        if strcmp(p.kind,'Msg4Ack')
                            c.state='DATA_PENDING'; c.pending=true; c.softBuffer=[]; c.harqTry=1;
                            c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                        else, c.state='DONE'; c.pending=false; end
                    elseif c.receiptAttempts>=obj.cfg.phy.maxReceiptTransmissions, c.state='FAILED'; c.pending=false;
                    elseif strcmp(p.kind,'Msg4Ack')
                        % Retry contention resolution within its existing window.
                        % The 512 ms receipt interval applies to data receipts.
                        c.state='MSG4_PENDING'; c.pending=true;
                    else
                        c.state=strrep(c.state,'_ACK','_RETRY'); c.pending=false;
                        c.lastProgressTick=obj.currentTick+obj.cfg.phy.receiptTimeoutTicks;
                    end
            end
            obj.contexts.set(p.contextId,c);
        end
        %FAILEDTB Ошибка CRC блока: повтор HARQ или FAILED после cfg.phy.maxHarqTransmissions.
        function c=failedTb(obj,c)
            if c.harqTry>=obj.cfg.phy.maxHarqTransmissions, c.state='FAILED'; c.pending=false;
            else, c.harqTry=c.harqTry+1; c.state='DATA_PENDING'; c.pending=true; end
        end
        function f=harqIdentity(~,c)
            f=struct('contextId',c.id,'packetSequence',c.sequence, ...
                'blockIndex',c.nextFragment-1,'attempt',c.harqTry);
        end
        function harqTerminal(obj,c,outcome)
            f=obj.harqIdentity(c); f.outcome=outcome;
            obj.harqJournal.append(obj.currentTick,'terminal',f);
        end
        %ANALYZEDELIVERY Только для KPI: сопоставить принятый блок с истинным пакетом UE.
        function analyzeDelivery(obj,c,b,index)
            for u=1:obj.cfg.simulation.numUE
                d=obj.devices.get(u);
                if d.token==c.token && d.rnti==c.rnti && d.packetId>0
                    if obj.packets.markReceived(d.packetId,index,b,obj.currentTick)
                        obj.truth.append(obj.currentTick,'packet_delivered',struct('packetId',d.packetId,'ueId',u));
                    end
                    return;
                end
            end
        end
        %ADVANCETIMERS Таймеры: окно RAR и contention timer у UE (→ BACKOFF или DROPPED, ТЗ §38),
        %   тайм-аут прогресса передачи данных, повторы Msg4/квитанции у BS.
        function advanceTimers(obj)
            for u=1:obj.cfg.simulation.numUE
                d=obj.devices.get(u);
                if any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4'})) && obj.currentTick>=d.deadlineTick
                    obj.attempts(d.attemptId).status='failure'; obj.attempts(d.attemptId).endTick=obj.currentTick;
                    reason='rar_timeout';
                    if strcmp(d.state,'WAIT_MSG4'), reason='msg4_timeout'; end
                    obj.truth.append(obj.currentTick,'ra_failure',struct( ...
                        'attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                        'reason',reason));
                    % Лимит попыток RA (база 8, ТЗ §30) исчерпан → пакет отбрасывается (DROPPED, ТЗ §12).
                    if d.attemptNumber>=obj.cfg.ra.maxAttempts
                        obj.packets.markTerminal(d.packetId,'dropped','ra_limit',obj.currentTick); obj.devices.reset(u);
                    else
                        % BACKOFF: равномерно 0..backoffTicks мс (база 256 мс, ADR-005), поток 'backoff' по (UE, попытка).
                        s=obj.sources.stream('backoff',0,u,d.lifetimeAttempt);
                        d.nextAllowedTick=obj.currentTick+ceil(rand(s)*obj.cfg.ra.backoffTicks); d.state='BACKOFF'; obj.devices.set(u,d);
                    end
                elseif any(strcmp(d.state,{'DATA','WAIT_RECEIPT'})) && obj.currentTick>=d.progressDeadlineTick
                    obj.packets.markTerminal(d.packetId,'dropped','progress_timeout',obj.currentTick); obj.devices.reset(u);
                end
            end
            for id=1:numel(obj.contexts.entries)
                c=obj.contexts.get(id);
                if any(strcmp(c.state,{'MSG4_RETRY','RECEIPT_RETRY'})) && obj.currentTick>=c.lastProgressTick
                    c.state=strrep(c.state,'_RETRY','_PENDING'); c.pending=true;
                    if c.dataComplete, c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks; end
                    obj.contexts.set(id,c);
                end
            end
        end
        %RECEIVERWINDOW Суммарный принятый сигнал для назначения G (±128 отсчётов запаса).
        function rx=receiverWindow(obj,direction,u,g)
            rx=obj.channel.receive(direction,u,max(0,g.startTick*1920-128),g.endTick*1920+128);
        end
        %RECORDDECODE Журналирует результат декодирования: на BS — в наблюдения, у UE — в истину.
        function recordDecode(obj,kind,decoded,g,receiverId)
            fields=struct('channel',kind,'phase',g.phase, ...
                'rnti',g.rnti,'hasCrc',decoded.hasCrc,'crcError',decoded.crcError, ...
                'receiverId',receiverId,'startTick',g.startTick,'endTick',g.endTick);
            if receiverId==0
                obj.observed.append(obj.currentTick,'phy_decode',fields);
                if decoded.hasCrc && decoded.crcError~=0
                    if strcmp(kind,'Msg3')
                        obj.observedCrcCounters.msg3Errors=obj.observedCrcCounters.msg3Errors+1;
                    elseif strcmp(kind,'Data')
                        obj.observedCrcCounters.dataErrors=obj.observedCrcCounters.dataErrors+1;
                    end
                end
            else
                obj.truth.append(obj.currentTick,'phy_decode',fields);
            end
        end
        %APPENDNPUSCHRECEPTIONDIAGNOSTIC Сравнение оценок задержки/CFO приёмника с истиной (диагностика ТЗ §36).
        function appendNpuschReceptionDiagnostic(obj,kind,decoded,g,c)
            configuredDelay=NaN; configuredCfo=NaN;
            attemptId=NaN; ueId=NaN;
            matching=find([obj.attempts.occasionId]==c.occasionId & ...
                [obj.attempts.nInit]==c.nInit);
            if numel(matching)==1
                attempt=obj.attempts(matching);
                attemptId=attempt.attemptId; ueId=attempt.ueId;
                ue=obj.scenario.ue(find([obj.scenario.ue.ueId]==attempt.ueId,1));
                timingAdvance=0;
                device=obj.devices.get(attempt.ueId);
                if isfield(device,'timingAdvanceSeconds') && ...
                        isfinite(device.timingAdvanceSeconds)
                    timingAdvance=device.timingAdvanceSeconds;
                end
                % Истинная остаточная задержка UL: путь туда-обратно + рассинхрон UE − применённый TA.
                configuredDelay=2*ue.distanceM/299792458+ ...
                    ue.syncOffsetSeconds-timingAdvance;
                configuredCfo=ue.cfoHz;
            end
            obj.radioReceptionDiagnostics.append(obj.currentTick,'npusch_receiver',struct( ...
                'contextId',c.id,'occasionId',c.occasionId,'nInit',c.nInit, ...
                'attemptId',attemptId,'ueId',ueId,'channel',char(kind), ...
                'estimatedDelaySeconds',decoded.measurements.timing.delaySeconds, ...
                'estimatedCfoHz',decoded.measurements.cfoHz, ...
                'configuredDelaySeconds',configuredDelay, ...
                'configuredCfoHz',configuredCfo, ...
                'noiseEstimate',decoded.measurements.noiseEstimate));
        end
        %LOGTX Пишет факт передачи в истину (для occupancy и анализа коллизий).
        function logTx(obj,g,u)
            obj.truth.append(g.startTick,'transmission',struct('direction',g.direction,'phase',g.phase, ...
                'channel',g.kind,'ueId',u,'ticks',g.ticks,'frequencyStartHz',g.frequencyStartHz,'bandwidthHz',g.bandwidthHz));
        end
        %MONITORINGDEADLINE Тик окончания окна ожидания длиной PP·Rmax подкадров поиска NPDCCH
        %   (окно RAR = pp10, contention timer = pp16; TS 36.321), начиная со START.
        function deadline=monitoringDeadline(obj,start,pp)
            remaining=pp*obj.cfg.phy.npdcch.rmax; deadline=Inf;
            for base=floor(start/32)*32:32:obj.cfg.simulation.durationTicks-1
                ticks=obj.calendar.monitoringTicks(base); ticks=ticks(ticks>=start);
                if numel(ticks)>=remaining
                    deadline=ticks(remaining)+1+obj.cfg.phy.processingTicks+1; return;
                end
                remaining=remaining-numel(ticks);
            end
        end
        %NEWTOKEN Уникальный 48-битный идентификатор конкуренции UE для попытки (Msg3/Msg4).
        function token=newToken(obj,u,attempt)
            s=obj.sources.stream('token',0,u,attempt);
            while true
                token=uint64(floor(rand(s)*2^48)); key=sprintf('%u',token);
                if token>0 && ~isKey(obj.tokens,key), obj.tokens(key)=true; return; end
            end
        end
        %CLOSEWINDOW Закрывает окно датасета [FIRST, LAST): признаки BS и target (ТЗ §22).
        function obs=closeWindow(obj,first,last)
            occupancy=obj.calendar.windowOccupancy(first,last);
            [obs,target]=nbiot.dataset.closeWindow(obj.observed.all(),obj.truth.all(),first,last, ...
                obj.raIntegral,obj.activeIntegral,obj.queueIntegral, ...
                obj.scenario.externalRealizationId,obj.cfg.dataset.windowTicks, ...
                occupancy,obj.runtimeAction);
            obj.observationRows{end+1}=obs; obj.targetRows{end+1}=target;
            obj.raIntegral=0; obj.activeIntegral=0; obj.queueIntegral=0;
            obs=nbiot.NBIoTSimulator.rowsTable({obs},nbiot.dataset.featureSchema().observationNames);
        end
        %PROCESSCONTROLLERWINDOW Решение контроллера на границе окна (ТЗ §23, период 500 мс):
        %   признаки закрытого окна → оценка нагрузки (оценщик, напр. ML-модель) → выбор действия
        %   из допустимого множества
        %   → применение → запись в журнал решений (время, оценка, конфигурация, переключение).
        function processControllerWindow(obj,observation,decisionTick)
            state=struct('tick',double(decisionTick), ...
                'durationTicks',double(obj.cfg.simulation.durationTicks));
            featureValuesJson='{}';
            if istable(observation)&&height(observation)==1
                schema=nbiot.dataset.featureSchema();
                % Признаки — только наблюдения BS (без ключей окна); истинная нагрузка сюда не попадает (ТЗ §40).
                featureTable=observation(:,schema.observationNames(5:end));
                featureValuesJson=jsonencode(table2struct(featureTable));
            end
            estimate=struct('valid',false,'value',NaN, ...
                'featureWindowEndTick',NaN,'reason','no-prior-window');
            estimateError=[];
            if decisionTick>0&&decisionTick<state.durationTicks
                try
                    estimate=nbiot.controller.estimateLoad(obj.controllerRuntime.estimator, ...
                        observation,obj.controllerRuntime.policy.maximumLoad);
                catch exception
                    estimate=struct('valid',false,'value',NaN, ...
                        'featureWindowEndTick',double(decisionTick),'reason','prediction-error');
                    estimateError=exception;
                end
            end
            obj.controllerLatestEstimate=estimate;
            action=nbiot.controller.chooseAction(obj.controllerRuntime.method,estimate, ...
                state,obj.runtimeAction,obj.controllerRuntime.policy);
            before=obj.runtimeAction;
            applied=false; reason=action.reason;
            if strcmp(action.reason,'load-threshold')
                [applied,reason]=obj.applyRuntimeAction(action);
            elseif ~isempty(estimateError)
                reason='prediction-error';
            end
            record=struct('decisionTick',double(decisionTick), ...
                'effectiveTick',double(action.effectiveTick), ...
                'featureWindowEndTick',double(estimate.featureWindowEndTick), ...
                'method',obj.controllerRuntime.method, ...
                'estimateValue',double(estimate.value), ...
                'estimateValid',logical(estimate.valid), ...
                'proposedAccessProbability',double(action.accessProbability), ...
                'proposedRaShare',double(action.raShare), ...
                'appliedAccessProbability',double(obj.runtimeAction.accessProbability), ...
                'appliedRaShare',double(obj.runtimeAction.raShare), ...
                'applied',logical(applied), ...
                'switched',logical(applied&& ...
                    (before.accessProbability~=obj.runtimeAction.accessProbability|| ...
                    before.raShare~=obj.runtimeAction.raShare)), ...
                'reason',char(string(reason)), ...
                'estimateReason',char(string(estimate.reason)), ...
                'errorIdentifier','','errorMessage','', ...
                'featureValuesJson',featureValuesJson);
            if ~isempty(estimateError)
                record.errorIdentifier=estimateError.identifier;
                record.errorMessage=estimateError.message;
            end
            obj.controllerLog(end+1)=record;
        end
        %VALIDATESCENARIO Сценарий согласован с cfg: UE 1..N, тот же realizationId, поступления в горизонте.
        function validateScenario(obj,s)
            if ~isfield(s,'ue') || numel(s.ue)~=obj.cfg.simulation.numUE || ...
                    ~isequal(double([s.ue.ueId]),1:obj.cfg.simulation.numUE)
                error('nbiot:scenario:Incompatible','Scenario UE IDs must be 1:numUE.');
            end
            if ~isfield(s,'externalRealizationId') || s.externalRealizationId~=obj.cfg.simulation.realizationId
                error('nbiot:scenario:Randomness','Scenario/config realization IDs disagree.');
            end
            if ~isempty(s.arrivals)
                ticks=double([s.arrivals.createdTick]);
                if any(diff(ticks)<0) || any(ticks<0 | ticks>=obj.cfg.simulation.durationTicks)
                    error('nbiot:scenario:Arrivals','Arrivals must be ordered within the half-open horizon.');
                end
            end
        end
    end
    methods (Static,Access=private)
        %FRAGMENTHEADER Разбор заголовка фрагмента в TB 256 бит:
        %   [1:16] номер пакета, [17:24] индекс фрагмента, [25:32] число фрагментов,
        %   [33:40] число полезных бит (1..208), [41:48] нули, далее данные и нулевой padding.
        function f=fragmentHeader(b)
            if numel(b)~=256 || any(b~=0 & b~=1), error('nbiot:protocol:Fragment','Invalid TB.'); end
            f=struct('sequence',double(nbiot.util.fromBits(b(1:16))), ...
                'index',double(nbiot.util.fromBits(b(17:24))), ...
                'count',double(nbiot.util.fromBits(b(25:32))), ...
                'validBits',double(nbiot.util.fromBits(b(33:40))));
            if any(b(41:48)) || f.count<1 || f.index>=f.count || f.validBits<1 || f.validBits>208 || any(b(49+f.validBits:end))
                error('nbiot:protocol:Fragment','Invalid fragment header/padding.');
            end
        end
        %ROWSTABLE Склеивает строки датасета (cell) в table с заданными именами столбцов.
        function tableValue=rowsTable(rows,names)
            if isempty(rows), tableValue=array2table(zeros(0,numel(names)),'VariableNames',names);
            else, tableValue=cell2table(vertcat(rows{:}),'VariableNames',names); end
        end
    end
end
