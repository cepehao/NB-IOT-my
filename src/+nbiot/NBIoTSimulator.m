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
        % Причина остановки ('horizon', 'exception', 'requested' ...).
        stopReason = ''
        % Сведения об ошибке, если прогон упал.
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
        % Журнал решений контроллера (по окнам 500 мс).
        controllerLog = struct([])
        % Последняя оценка нагрузки контроллера (по умолчанию нет).
        controllerLatestEstimate = struct('valid',false,'value',NaN, ...
            'featureWindowEndTick',NaN,'reason','not-started')
        % Возможности NPRACH (occasions), заранее зарезервированные планировщиком.
        occasions
        % Следующий тик для step(); курсор по расписанию поступлений scenario.arrivals.
        nextTick = 0
        % Индекс следующего поступления пакета в сценарии.
        arrivalCursor = 1
        % Флаг: кандидаты мониторинга NPDCCH уже поставлены в очередь на этом тике.
        monitorQueued = false
        % Уникальные 48-битные идентификаторы конкуренции (contention resolution, Msg3/Msg4).
        tokens
        % Строки датасета по закрытым окнам: признаки BS (observation) и истина (target).
        observationRows = {}
        % Строки целей (target) датасета по окнам.
        targetRows = {}
        % Интегралы по тикам текущего окна датасета (для средних значений target).
        raIntegral = 0
        % Интеграл числа UE с работой (для средней нагрузки окна).
        activeIntegral = 0
        % Интеграл длины очередей на UE.
        queueIntegral = 0
        % Счётчики ошибок CRC, видимые BS (для живого отображения).
        observedCrcCounters = struct('msg3Errors',0,'dataErrors',0)
        % Время расчёта (с) по всем вызовам run.
        elapsedSeconds = 0
        % Запрошена ли остановка.
        stopRequested = false
        % Кэш собранного результата (сбрасывается при любом изменении).
        resultCache = []
    end
    methods
        %NBIOTSIMULATOR Создаёт симулятор: проверяет cfg, строит сценарий и все модули.
        %   CFG — конфигурация; SCENARIO — готовая внешняя реализация (пусто → строится по seed);
        %   CONTROLLEROPTIONS — для Adaptive-*: оценщик нагрузки и политика
        %   (см. nbiot.controller.prepareRuntime). Для Static не задаётся.
        function obj=NBIoTSimulator(cfg,scenario,controllerOptions)
            % Без конфигурации — значения по умолчанию.
            if nargin<1, cfg=nbiot.config.defaultConfig(); end
            % Без опций контроллера — пустые.
            if nargin<3, controllerOptions=struct(); end
            % Проверенная конфигурация.
            obj.cfg=nbiot.config.validateConfig(cfg);
            % Журнал жизненного цикла прогона.
            obj.lifecycleLog=nbiot.results.EventLog();
            % Событие «модель инициализирована».
            obj.lifecycleLog.append(0,'simulation_initialized', ...
                struct('profileVersion',obj.cfg.profileVersion));
            % Контроллер: политика и оценщик нагрузки.
            obj.controllerRuntime=nbiot.controller.prepareRuntime(obj.cfg,controllerOptions);
            % Если контроллер включён —
            if obj.controllerRuntime.enabled
                % событие «модель (оценщик) загружена».
                obj.lifecycleLog.append(0,'model_loaded',struct( ...
                    'method',obj.controllerRuntime.method, ...
                    'modelMetadata',obj.controllerRuntime.modelMetadata));
            end
            % Пустой журнал контроллера с нужными полями.
            obj.controllerLog=struct('decisionTick',{},'effectiveTick',{}, ...
                'featureWindowEndTick',{},'method',{},'estimateValue',{}, ...
                'estimateValid',{},'proposedAccessProbability',{},'proposedRaShare',{}, ...
                'appliedAccessProbability',{},'appliedRaShare',{},'applied',{}, ...
                'switched',{},'reason',{},'estimateReason',{}, ...
                'errorIdentifier',{},'errorMessage',{},'featureValuesJson',{});
            % Текущее действие: P, доля RA, тик вступления в силу — из конфигурации.
            obj.runtimeAction=struct('accessProbability',obj.cfg.policy.accessProbability, ...
                'raShare',obj.cfg.policy.raShare,'effectiveTick',0);
            % Все потоки случайности одной внешней реализации: (seed, realizationId), ТЗ §42–43.
            obj.sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
            % Сценарий строится один раз и одинаков для Static/Adaptive при равных seed и realizationId (ТЗ §63).
            if nargin<2 || isempty(scenario), scenario=nbiot.scenario.buildScenario(cfg,obj.sources); end
            % Проверяем сценарий и сохраняем его.
            obj.validateScenario(scenario); obj.scenario=scenario;
            % Состояния UE.
            obj.devices=nbiot.devices.DeviceStore(cfg.simulation.numUE);
            % Пакеты и контексты RA на BS.
            obj.packets=nbiot.traffic.PacketStore(cfg); obj.contexts=nbiot.ra.RaContextStore();
            % Календарь ресурсов UL/DL с квотами RA/DT.
            obj.calendar=nbiot.scheduler.ResourceCalendar(cfg);
            % Планировщик над календарём.
            obj.scheduler=nbiot.scheduler.Scheduler(cfg,obj.calendar);
            % Радиоканал (сложение сигналов, шум).
            obj.channel=nbiot.channel.RadioChannel(cfg,scenario,obj.sources);
            % Очередь завершения приёмов.
            obj.receiveQueue=nbiot.engine.EventQueue();
            % Журналы наблюдений BS и истины.
            obj.observed=nbiot.results.EventLog(); obj.truth=nbiot.results.EventLog();
            % Журнал диагностики приёма.
            obj.radioReceptionDiagnostics=nbiot.results.EventLog();
            % Журнал HARQ.
            obj.harqJournal=nbiot.results.EventLog();
            % NPRACH резервируется заранее на весь горизонт: период 80 мс, старт 8 мс (ADR-005).
            obj.occasions=obj.scheduler.reserveNprach();
            % Токены попыток RA (для проверки Msg4).
            obj.tokens=containers.Map('KeyType','char','ValueType','logical');
        end
        %RUN Выполняет шаги до тика UNTILTICK включительно (по умолчанию — до горизонта).
        %   Повторный вызов продолжает с места остановки; результат идентичен непрерывному прогону.
        function run(obj,untilTick)
            % По умолчанию — до конца горизонта.
            if nargin<2, untilTick=obj.cfg.simulation.durationTicks; end
            % Тик-цель — целый, не раньше текущего и не дальше горизонта.
            validateattributes(untilTick,{'numeric'},{'scalar','integer','>=',obj.currentTick,'<=',obj.cfg.simulation.durationTicks});
            % Прогон уже завершён — ничего не делаем.
            if any(strcmp(obj.status,{'completed','stopped','failed'})), return; end
            % Первый ли это запуск.
            firstRun=strcmp(obj.status,'ready');
            % Статус «идёт»; засекаем время.
            obj.status='running'; clockStart=tic;
            % При первом запуске —
            if firstRun
                % событие «прогон начат».
                obj.lifecycleLog.append(obj.currentTick,'simulation_started', ...
                    struct('untilTick',double(untilTick)));
            end
            try
                % Без LTE Toolbox и без калибровки порога NPRACH расчёт не имеет смысла — сразу ошибка.
                nbiot.phy.requireToolbox();
                % Порог детектора должен быть откалиброван —
                if ~isfinite(obj.cfg.phy.nprachThreshold)
                    error('nbiot:phy:Calibration','Run examples/calibrateNprach.m and load its threshold before a KPI experiment.');
                end
                % Основной цикл модели: один шаг = 1 мс.
                while obj.nextTick<=untilTick && ~obj.stopRequested, obj.step(); end
                % Остановлен по запросу;
                if obj.stopRequested, obj.status='stopped';
                % дошли до горизонта — завершён;
                elseif obj.nextTick>obj.cfg.simulation.durationTicks, obj.status='completed'; obj.stopReason='horizon';
                % иначе — частичный (остановились на untilTick).
                else, obj.status='partial'; end
            catch exception
                % Исключение — прогон неудачен;
                obj.status='failed'; obj.stopReason='exception';
                % сохраняем сведения об ошибке.
                obj.errorInfo=struct('identifier',exception.identifier,'message',exception.message,'stack',exception.stack);
            end
            % Прогон закончен (любым образом) —
            if any(strcmp(obj.status,{'completed','stopped','failed'}))
                % вид события по умолчанию — завершение;
                lifecycleKind='simulation_completed';
                % по статусу:
                switch obj.status
                    % остановлен;
                    case 'stopped', lifecycleKind='simulation_stopped';
                    % упал;
                    case 'failed', lifecycleKind='simulation_failed';
                end
                % поля события: горизонт и причина;
                lifecycleFields=struct('actualTick',obj.currentTick,'reason',obj.stopReason);
                % для упавшего —
                if strcmp(obj.status,'failed')
                    % идентификатор ошибки;
                    lifecycleFields.errorIdentifier=obj.errorInfo.identifier;
                    % сообщение ошибки;
                    lifecycleFields.errorMessage=obj.errorInfo.message;
                end
                % запись события.
                obj.lifecycleLog.append(obj.currentTick,lifecycleKind,lifecycleFields);
            end
            % Накопленное время расчёта.
            obj.elapsedSeconds=obj.elapsedSeconds+toc(clockStart);
            % Результат устарел.
            obj.resultCache=[];
        end
        %APPLYRUNTIMEACTION Применяет решение контроллера (P и доля RA) с текущего тика.
        %   Допустимы только значения из заранее заданного множества (ТЗ §23) и только на границе
        %   окна 500 мс. Если новые квоты RA/DT не вмещают уже выданные назначения — отказ целиком.
        %   Возвращает APPLIED (true/false) и REASON (причину отказа или 'applied').
        function [applied,reason]=applyRuntimeAction(obj,action)
            % По умолчанию не применено.
            applied=false; reason='unsupported-action';
            % Действие — скалярный struct с полями P, доля RA, тик;
            if ~isstruct(action)||~isscalar(action)|| ...
                    ~all(isfield(action,{'accessProbability','raShare','effectiveTick'}))
                % иначе не применяем.
                return;
            end
            % Поля действия.
            p=action.accessProbability; share=action.raShare; tick=action.effectiveTick;
            % Допустимые действия: P для Adaptive-P (ТЗ §24) и доли RA 10/20/30 % для Adaptive-RA/DT (ТЗ §25).
            supportedP=[0.1 0.25 0.5 0.75 1]; supportedShares=[0.1 0.2 0.3];
            % P и доля RA должны быть из допустимых наборов;
            if ~isnumeric(p)||~isscalar(p)||~isfinite(p)||~any(p==supportedP)|| ...
                    ~isnumeric(share)||~isscalar(share)||~isfinite(share)||~any(share==supportedShares)
                % иначе не применяем.
                return;
            end
            % Длина окна контроллера.
            windowTicks=obj.cfg.policy.windowTicks;
            % Тик — целый, на границе окна, в будущем и внутри горизонта;
            if ~isnumeric(tick)||~isscalar(tick)||~isfinite(tick)||tick~=fix(tick)|| ...
                    tick<=0||tick>=obj.cfg.simulation.durationTicks||tick~=obj.currentTick|| ...
                    mod(tick,windowTicks)~=0
                % иначе отказ.
                reason='wrong-effective-tick'; return;
            end
            % Прогон уже закончен —
            if any(strcmp(obj.status,{'completed','stopped','failed'}))
                % отказ.
                reason='session-not-active'; return;
            end
            % Смена доли RA перестраивает квоты календаря с этого тика; при конфликте — отказ.
            if share~=obj.runtimeAction.raShare
                % Не удалось перестроить квоты —
                if ~obj.scheduler.applyShareFrom(tick,share)
                    % отказ.
                    reason='resource-budget-conflict'; return;
                end
            end
            % Запоминаем новое действие.
            obj.runtimeAction=struct('accessProbability',double(p), ...
                'raShare',double(share),'effectiveTick',double(tick));
            % Результат устарел; применено.
            obj.resultCache=[]; applied=true; reason='applied';
        end
        %STEP Один шаг модели (1 мс). Порядок внутри тика зафиксирован (docs/architecture.md):
        %   1) завершить приёмы, готовые к этому тику; 2) истечение срока жизни пакетов; 3) таймеры UE/BS;
        %   4) новые пакеты; 5) закрыть окно датасета и, если нужно, решение контроллера;
        %   6) новые передачи: служебный DL, NPRACH, назначения, мониторинг NPDCCH; 7) статистика очередей.
        function step(obj)
            % Прогон закончен или запрошена остановка — шаг не делаем.
            if any(strcmp(obj.status,{'completed','stopped','failed'})) || obj.stopRequested, return; end
            % Результат устарел.
            obj.resultCache=[];
            % Текущий тик; признак «мониторинг уже поставлен» сбрасываем.
            now=obj.nextTick; obj.currentTick=now; obj.monitorQueued=false;
            % На тике 0 у контроллера ещё нет закрытого окна: фиксируем «решения нет».
            if now==0&&obj.controllerRuntime.enabled&&isempty(obj.controllerLog)
                % запись пустого решения.
                obj.processControllerWindow([],0);
            end
            % Complete physical receptions first, including the horizon boundary.
            ready=obj.receiveQueue.popReady(now);
            % Обрабатываем все готовые приёмы.
            for k=1:numel(ready), obj.handleReceive(ready(k)); end
            % До горизонта:
            if now<obj.cfg.simulation.durationTicks
                % Пакеты, у которых истёк срок жизни (cfg.traffic lifetime): попытка RA считается неуспешной.
                expired=obj.packets.expireLifetime(now);
                % Для каждого UE:
                for u=1:obj.cfg.simulation.numUE
                    % состояние UE;
                    d=obj.devices.get(u);
                    % его текущий пакет истёк —
                    if ismember(d.packetId,double(expired))
                        % незавершённая попытка RA —
                        if d.attemptId>0 && strcmp(obj.attempts(d.attemptId).status,'started')
                            % становится неуспешной;
                            obj.attempts(d.attemptId).status='failure';
                            % тик завершения;
                            obj.attempts(d.attemptId).endTick=now;
                            % событие истины «неуспех RA».
                            obj.truth.append(now,'ra_failure',struct( ...
                                'attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                                'reason','packet_lifetime'));
                        end
                        % UE возвращается в IDLE.
                        obj.devices.reset(u);
                    end
                end
                % Таймеры (окно RAR, contention timer, BACKOFF), поступления пакетов, переход IDLE→WAIT_RA.
                obj.advanceTimers(); obj.addArrivals(); obj.activateHeads();
            end
            % Граница окна датасета (500 мс) или горизонт: закрыть окно и запустить контроллер (ТЗ §22–23).
            if now>0 && (mod(now,obj.cfg.dataset.windowTicks)==0 || now==obj.cfg.simulation.durationTicks)
                % Начало закрываемого окна.
                first=floor((now-1)/obj.cfg.dataset.windowTicks)*obj.cfg.dataset.windowTicks;
                % Закрываем окно: признаки и цели.
                observation=obj.closeWindow(first,now);
                % Контроллер включён и горизонт не достигнут —
                if obj.controllerRuntime.enabled&&now<obj.cfg.simulation.durationTicks
                    % решение по признакам окна.
                    obj.processControllerWindow(observation,now);
                end
            end
            % До горизонта:
            if now<obj.cfg.simulation.durationTicks
                % Обязательные DL-сигналы соты (NPSS/NSSS/NRS и т.п.) — занимают ресурсы и создают помехи.
                mandatory=nbiot.phy.buildMandatoryTransmission(obj.cfg,now);
                % добавляем их в канал;
                if ~isempty(mandatory), obj.channel.add(mandatory); end
                % Новые передачи этого тика: Msg1 на возможности NPRACH, назначения BS, кандидаты NPDCCH.
                obj.emitNprach(); obj.schedulePending(); obj.queueMonitoring();
                % Статистика для target и KPI: число UE в RA, число UE с работой, длины очередей.
                [ra,~]=obj.devices.counts();
                % счётчики: UE с работой, ожидающие пакеты, всего в очередях, максимум;
                work=0; waiting=0; totalQueued=0; maxQueued=0;
                % для каждого UE:
                for u=1:obj.cfg.simulation.numUE
                    % длина очереди;
                    queueLength=obj.packets.queueLength(u);
                    % ждущие пакеты (кроме текущего);
                    waiting=waiting+max(0,queueLength-1);
                    % суммарная и максимальная очередь;
                    totalQueued=totalQueued+queueLength; maxQueued=max(maxQueued,queueLength);
                end
                % сэмпл очередей;
                obj.queueSamples(end+1,:)=[now,totalQueued,maxQueued];
                % если пакеты есть —
                if ~isempty(obj.packets.packets)
                    % ожидающие пакеты;
                    pending=obj.packets.packets(strcmp({obj.packets.packets.status},'pending'));
                    % число UE с ожидающими пакетами;
                    work=numel(unique([pending.ueId]));
                end
                % интегралы: UE в RA и UE с работой;
                obj.raIntegral=obj.raIntegral+ra; obj.activeIntegral=obj.activeIntegral+work;
                % средняя очередь ожидания на UE;
                obj.queueIntegral=obj.queueIntegral+waiting/obj.cfg.simulation.numUE;
                % наблюдение BS: число ожидающих запросов.
                obj.observed.append(now,'bs_queue',struct('pendingRequests',sum([obj.contexts.entries.pending])));
                % Освободить память канала: отсчёты старше 128 мс уже не попадут ни в одно окно приёма.
                obj.channel.discardBefore(max(0,(now-128)*1920));
            end
            % Следующий тик.
            obj.nextTick=now+1;
            % Дошли до горизонта — прогон завершён.
            if now==obj.cfg.simulation.durationTicks, obj.status='completed'; obj.stopReason='horizon'; end
        end
        %STOP Запрашивает остановку; текущий тик завершается, состояние можно сохранить.
        function stop(obj,reason)
            % По умолчанию причина — «запрошено».
            if nargin<2, reason='requested'; end
            % Результат устарел.
            obj.resultCache=[];
            % Флаг остановки и причина.
            obj.stopRequested=true; obj.stopReason=char(reason);
            % Событие «запрошена остановка».
            obj.lifecycleLog.append(obj.currentTick,'stop_requested', ...
                struct('reason',obj.stopReason));
            % Статус «остановлен» (если не упал).
            if ~strcmp(obj.status,'failed'), obj.status='stopped'; end
        end
        %SNAPSHOT Лёгкое состояние для GUI (ТЗ §46.6): тик, статус, UE, счётчики. Не меняет модель.
        function s=snapshot(obj)
            % Схема признаков и целей.
            schema=nbiot.dataset.featureSchema();
            % Таблица целей.
            targets=obj.rowsTable(obj.targetRows,schema.targetNames);
            % Цели для диагностики: конец окна и средняя нагрузка RA.
            diagnosticTargets=targets(:,{'endTick','meanRaUe'});
            % Число пакетов с начатой передачей.
            transmittedPacketCount=nbiot.metrics.countTransmittedPackets( ...
                obj.harqJournal.all(),obj.currentTick);
            % Снимок состояния: тик, статус, UE, пакеты, попытки, журналы, цели.
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
            % По умолчанию — с начала журнала.
            if nargin<2, afterIndex=0; end
            % Новые наблюдения BS и курсор.
            [events,nextIndex]=obj.observed.since(afterIndex);
        end
        %RESULT Собирает struct результата (ТЗ §47): журналы, KPI (ТЗ §27), датасет (ТЗ §22).
        %   Можно вызывать на паузе: незавершённые пакеты/попытки помечаются 'unfinished' в копии,
        %   состояние симулятора не меняется. Результат кэшируется до следующего шага.
        function result=result(obj)
            % Есть кэш — возвращаем его.
            if ~isempty(obj.resultCache), result=obj.resultCache; return; end
            % Копия пакетов.
            packets=obj.packets.packets;
            % Do not mutate resumable state when exporting a partial result.
            for k=1:numel(packets)
                % Ожидающий пакет — незавершён, причина — причина остановки.
                if strcmp(packets(k).status,'pending'), packets(k).status='unfinished'; packets(k).reason=obj.stopReason; end
            end
            % Копия попыток.
            attempts=obj.attempts;
            % Для каждой попытки:
            for k=1:numel(attempts)
                % начатая — незавершена.
                if strcmp(attempts(k).status,'started'), attempts(k).status='unfinished'; end
            end
            % Все наблюдения и истина.
            obs=obj.observed.all(); truth=obj.truth.all();
            % Состояния UE.
            deviceStates=cell(obj.cfg.simulation.numUE,1);
            % Для каждого UE:
            for u=1:obj.cfg.simulation.numUE
                % его состояние.
                device=obj.devices.get(u); deviceStates{u}=device.state;
            end
            % Link budget пересчитывается для экспорта per-UE таблицы (ТЗ §47, Per-UE).
            finalScenario=obj.scenario;
            % Бюджеты линий UE в итоговом сценарии.
            finalScenario.linkBudget=nbiot.channel.evaluateLinks(obj.cfg,finalScenario.ue);
            % Базовый результат: журналы, KPI, сводка UE.
            result=nbiot.results.finalizeResult(obj.cfg,finalScenario,packets,attempts,obs,truth, ...
                obj.calendar.usage(),obj.currentTick,obj.status,obj.stopReason,obj.errorInfo,deviceStates);
            % Журнал контроллера.
            result.controllerLog=obj.controllerLog;
            % Версия его схемы.
            result.controllerLogSchemaVersion=1;
            % Метаданные оценщика.
            result.controllerModel=obj.controllerRuntime.modelMetadata;
            % Если контроллер включён —
            if obj.controllerRuntime.enabled
                % версия схемы результата 3;
                result.resultSchemaVersion=3;
                % политика контроллера.
                result.controllerPolicy=obj.controllerRuntime.policy;
            end
            % Последнее действие.
            result.runtimeAction=obj.runtimeAction;
            % Журнал жизненного цикла.
            result.lifecycleLog=obj.lifecycleLog.all();
            % Версия его схемы.
            result.lifecycleLogSchemaVersion=1;
            % Журнал диагностики приёма.
            result.radioReceptionLog=obj.radioReceptionDiagnostics.all();
            % Версия его схемы.
            result.radioReceptionSchemaVersion=1;
            % Радиодиагностика (ТЗ §15–17).
            result.radioDiagnostics=nbiot.metrics.radioDiagnostics(truth,obs, ...
                result.radioReceptionLog,struct('actualTick',obj.currentTick, ...
                'nInitValues',0:obj.cfg.ra.numSubcarriers-1));
            % Журнал HARQ и версия схемы.
            result.harqLog=obj.harqJournal.all(); result.harqLogSchemaVersion=2;
            % Сэмплы очередей.
            result.queueSamples=obj.queueSamples;
            % Основные KPI (ТЗ §27): успех RA, доставка, throughput, коллизии, задержки, BLER, occupancy.
            result.kpiSummary=nbiot.metrics.summarizeKpi(obj.cfg,packets,attempts,obs,truth, ...
                result.resourceUsage,obj.currentTick,result.harqLog,obj.queueSamples);
            % KPI обслуживания и по группам UE.
            [serviceKpi,groupKpi]=nbiot.metrics.serviceKpi( ...
                result.ueSummary,obj.currentTick,strcmp(obj.status,'completed'));
            % Сохраняем KPI обслуживания.
            result.kpiSummary.service=serviceKpi;
            % KPI групп.
            result.groupKpi=groupKpi;
            % An initialized but empty journal is known empty, not legacy data.
            result.kpiSummary.harq.available=true;
            % Временные ряды KPI по окнам (для графиков ТЗ §46.9).
            result.kpiTimeSeries=nbiot.metrics.windowKpi(obj.cfg,packets,attempts,obs, ...
                obj.currentTick,obj.queueSamples,obj.controllerLog);
            % Число переключений контроллера.
            controllerSwitchCount=0;
            % Если решения были —
            if ~isempty(obj.controllerLog)
                % сумма переключений.
                controllerSwitchCount=sum([obj.controllerLog.switched]);
            end
            % KPI контроллера.
            result.kpiSummary.controller=struct( ...
                'applicable',obj.controllerRuntime.enabled, ...
                'decisionCount',numel(obj.controllerLog), ...
                'configurationSwitches',controllerSwitchCount);
            % Датасет: признаки BS и target по одним и тем же окнам; ключи окон обязаны совпадать.
            schema=nbiot.dataset.featureSchema();
            % Таблица признаков датасета.
            observations=obj.rowsTable(obj.observationRows,schema.observationNames);
            % Таблица целей.
            targets=obj.rowsTable(obj.targetRows,schema.targetNames);
            % Ключи окон признаков.
            windowKeys=observations(:,schema.keyNames);
            % Ключи признаков и целей должны совпадать;
            if ~isequaln(windowKeys,targets(:,schema.keyNames))
                error('nbiot:dataset:Diagnostics', ...
                    'Observation and target window keys do not align.');
            end
            % диагностика окон датасета.
            diagnostics=nbiot.dataset.windowDiagnostics(obj.cfg,packets,attempts,truth,obs, ...
                result.radioReceptionLog,obj.currentTick,windowKeys);
            % Датасет результата: признаки, цели, диагностика.
            result.dataset=struct('observations',observations,'targets',targets, ...
                'diagnostics',diagnostics,'schema',schema, ...
                'manifest',nbiot.dataset.buildManifest(obj.scenario.externalRealizationId));
            % Профилирование: время расчёта.
            result.profiling=struct('elapsedSeconds',obj.elapsedSeconds,'matlabValidation','pending');
            % Кэшируем результат.
            obj.resultCache=result;
        end
    end
    methods (Access=private)
        %ADDARRIVALS Ставит в очереди UE пакеты, созданные к текущему тику (ТЗ §11).
        %   При переполнении очереди пакет отбрасывается (drop-tail), это фиксируется в truth.
        function addArrivals(obj)
            % Поступления сценария.
            a=obj.scenario.arrivals;
            % Пока есть поступления с тиком создания не позже текущего:
            while obj.arrivalCursor<=numel(a) && double(a(obj.arrivalCursor).createdTick)<=obj.currentTick
                % поступление; ставим пакет в очередь UE;
                arrival=a(obj.arrivalCursor); accepted=obj.packets.enqueue(arrival);
                % событие истины «пакет создан»;
                obj.truth.append(obj.currentTick,'packet_created',struct('packetId',double(arrival.packetId),'ueId',double(arrival.ueId),'accepted',accepted));
                % следующее поступление.
                obj.arrivalCursor=obj.arrivalCursor+1;
            end
        end
        %ACTIVATEHEADS UE в IDLE с непустой очередью переходит в WAIT_RA (ТЗ §12).
        function activateHeads(obj)
            % Для каждого UE:
            for u=1:obj.cfg.simulation.numUE
                % состояние;
                d=obj.devices.get(u);
                % UE свободен —
                if strcmp(d.state,'IDLE')
                    % первый пакет очереди;
                    id=obj.packets.head(u);
                    % есть — переходим в WAIT_RA с этим пакетом, не раньше освобождения UL.
                    if id>0, d.state='WAIT_RA'; d.packetId=double(id); d.nextAllowedTick=max(obj.currentTick,d.ulBusyUntilTick); obj.devices.set(u,d); end
                end
            end
        end
        %EMITNPRACH Msg1: на возможности NPRACH каждое готовое UE передаёт преамбулу (ТЗ §14, §18).
        %   UE в WAIT_RA/BACKOFF с истёкшим ожиданием участвует с вероятностью P (Adaptive-P, ТЗ §24),
        %   выбирает NInit (номер начальной поднесущей = «преамбула») равномерно из 0..numSubcarriers-1
        %   и формирует waveform через LTE Toolbox. Сигналы всех UE складываются в канале.
        function emitNprach(obj)
            % Возможность NPRACH на этом тике; нет — выходим.
            at=find([obj.occasions.startTick]==obj.currentTick,1); if isempty(at), return; end
            % Возможность; номера попыток и NInit этой возможности.
            occasion=obj.occasions(at); ids=[]; indices=[];
            % Для каждого UE:
            for u=1:obj.cfg.simulation.numUE
                % состояние;
                d=obj.devices.get(u);
                % UE не ждёт RA или ещё рано — пропуск;
                if ~any(strcmp(d.state,{'WAIT_RA','BACKOFF'})) || d.nextAllowedTick>obj.currentTick, continue; end
                % Решения UE берутся из потока 'access', адресованного (UE, возможность), — не зависят
                % от числа других вызовов, поэтому внешняя реализация одинакова для всех политик (ТЗ §63).
                stream=obj.sources.stream('access',0,u,occasion.occasionId);
                % с вероятностью 1 − P UE пропускает возможность (Adaptive-P);
                if rand(stream)>obj.runtimeAction.accessProbability, continue; end
                % NInit равномерно из 0..numSubcarriers−1;
                d.nInit=floor(rand(stream)*obj.cfg.ra.numSubcarriers);
                % номер попытки для пакета и за всё время;
                d.attemptNumber=d.attemptNumber+1; d.lifetimeAttempt=d.lifetimeAttempt+1;
                % номер попытки в журнале и возможность;
                d.attemptId=numel(obj.attempts)+1; d.occasionId=occasion.occasionId;
                % новый токен попытки; RA ещё не успешен;
                d.token=obj.newToken(u,d.lifetimeAttempt); d.raSucceeded=false;
                % RA-RNTI по 3GPP TS 36.321 для NB-IoT: 1 + floor(SFN/4), SFN = номер кадра 10 мс.
                d.raRnti=1+floor(mod(floor(occasion.startTick/10),1024)/4);
                % Ожидание RAR начинается через 3 подкадра после конца преамбулы (TS 36.321, NRep=1).
                d.state='WAIT_RAR'; d.monitorStartTick=occasion.endTick+3;
                % дедлайн окна RAR;
                d.deadlineTick=obj.monitoringDeadline(d.monitorStartTick,obj.cfg.ra.rarPp);
                % счётчик попыток пакета; сохраняем UE;
                obj.packets.incrementAttempt(d.packetId); obj.devices.set(u,d);
                % waveform NPRACH (LTE Toolbox);
                tx=nbiot.phy.nprach.buildTransmission(obj.cfg,occasion,d.nInit);
                % метки передачи;
                tx.ueId=u; tx.attemptId=d.attemptId; tx.occasionId=occasion.occasionId;
                % NInit и добавление в канал;
                tx.nInit=d.nInit; obj.channel.add(tx);
                % учёт ресурсов передачи;
                obj.logTx(struct('startTick',occasion.startTick,'ticks',occasion.startTick:occasion.endTick-1, ...
                    'frequencyStartHz',0,'bandwidthHz',45000,'direction','UL','phase','RA','kind','NPRACH'),u);
                % запись попытки;
                a=struct('attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                    'occasionId',occasion.occasionId,'nInit',d.nInit,'startTick',obj.currentTick, ...
                    'endTick',NaN,'status','started','collision',false,'capture',false);
                % добавляем попытку и запоминаем её NInit;
                obj.attempts(end+1)=a; ids(end+1)=d.attemptId; indices(end+1)=d.nInit; %#ok<AGROW>
                % событие истины Msg1.
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
            % По виду приёма:
            switch event.kind
                % NPRACH:
                case 'nprach'
                    % Окно приёма NPRACH: [начало−128; конец+128] отсчётов (запас на задержку распространения).
                    occasion=event.payload; a=max(0,occasion.startTick*1920-128); z=occasion.endTick*1920+128;
                    % принятый сигнал и радиодиагностика;
                    [rx,radio]=obj.channel.receive('UL',0,a,z);
                    % Детектор видит только принятый суммарный сигнал и конфигурацию — не список передатчиков.
                    [detected,metrics]=nbiot.phy.nprach.detect(obj.cfg,rx,occasion);
                    % наблюдение BS: результат детектора;
                    obj.observed.append(obj.currentTick,'nprach_detection',struct( ...
                        'occasionId',occasion.occasionId,'readyTick',obj.currentTick, ...
                        'candidates',detected,'count',numel(detected), ...
                        'maxMetric',max(metrics),'meanMetric',mean(metrics), ...
                        'energyW',mean(abs(rx.waveform).^2)));
                    % для каждой компоненты сигнала —
                    for k=1:numel(radio.components)
                        % запись диагностики компоненты;
                        obj.radioReceptionDiagnostics.append(obj.currentTick, ...
                            'nprach_component',radio.components(k));
                    end
                    % для каждого перекрытия —
                    for k=1:numel(radio.overlaps)
                        % запись диагностики перекрытия;
                        obj.radioReceptionDiagnostics.append(obj.currentTick, ...
                            'nprach_overlap',radio.overlaps(k));
                    end
                    % На каждую обнаруженную преамбулу BS создаёт контекст RA и готовит RAR (Msg2).
                    deadline=obj.monitoringDeadline(occasion.endTick+3,obj.cfg.ra.rarPp);
                    % для каждой обнаруженной преамбулы —
                    for k=1:numel(detected)
                        % контекст RA на BS (NInit, возможность, дедлайн, оценка задержки);
                        obj.contexts.create(detected(k).nInit,occasion.occasionId,deadline,detected(k).delaySeconds);
                    end
                % мониторинг NPDCCH:
                case 'monitor'
                    obj.receiveControl(event.payload);
                % данные NPDSCH у UE:
                case 'dl_payload'
                    obj.receiveDlPayload(event.payload);
                % приём на BS (Msg3, данные, ACK):
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
            % Контексты RA на BS; нет — выходим.
            entries=obj.contexts.entries; if isempty(entries), return; end
            % Контексты, ждущие планирования.
            pending=find([entries.pending]);
            % Нет — выходим.
            if isempty(pending), return; end
            % Порядок: ближайший дедлайн, затем давнее продвижение, затем номер.
            [~,order]=sortrows([[entries(pending).deadlineTick].',[entries(pending).lastProgressTick].',pending.'],[1 2 3]);
            % Для каждого контекста по порядку:
            for id=pending(order)
                % контекст; назначения пока нет;
                c=obj.contexts.get(id); s=[];
                % дедлайн прошёл —
                if obj.currentTick>c.deadlineTick
                    % незавершённый блок данных — итог HARQ «не принят»;
                    if strcmp(c.state,'DATA_PENDING'), obj.harqTerminal(c,'failed'); end
                    % контекст истёк; дальше.
                    c.pending=false; c.state='EXPIRED'; obj.contexts.set(id,c); continue;
                end
                % по состоянию контекста:
                switch c.state
                    % Msg2 (RAR): NPDCCH (DCI N1 по RA-RNTI) + NPDSCH с RAPID=NInit, UL grant Msg3, TA, Temp C-RNTI.
                    case 'RAR_PENDING'
                        % возможность NPRACH контекста;
                        occasion=obj.occasions(c.occasionId);
                        % RA-RNTI этой возможности;
                        raRnti=1+floor(mod(floor(occasion.startTick/10),1024)/4);
                        % назначение RAR (NPDCCH + NPDSCH + Msg3) в окне RAR;
                        s=obj.scheduler.downlink('RAR','RA',max(obj.currentTick,occasion.endTick+3),c.deadlineTick,raRnti);
                        % не нашлось — попробуем на следующем тике;
                        if isempty(s), continue; end
                        % Msg3 адресован временному C-RNTI;
                        s.msg3Grant.rnti=c.rnti;
                        % поля RAR: UL grant, RAPID (= NInit), TC-RNTI;
                        f=s.rarGrant; f.rapid=c.nInit; f.rnti=c.rnti;
                        % Timing advance в шагах 16·Ts, Ts = 1/(15000·2048) с; диапазон 0..1282 (TS 36.213).
                        f.timingAdvance=max(0,min(1282,round(c.delaySeconds/(16/(15000*2048)))));
                        % кодируем RAR и передаём в DL;
                        bits=nbiot.ra.encodeMessage('RAR',f); obj.emitDownlink(s,bits);
                        % Одновременно резервируется ресурс Msg3: выдача RAR без возможности Msg3 запрещена.
                        obj.queueBsUl(id,s.msg3Grant,'Msg3'); c.state='MSG3_RX';
                        % новый дедлайн — contention timer после Msg3;
                        c.deadlineTick=obj.monitoringDeadline(s.msg3Grant.endTick,obj.cfg.ra.contentionPp);
                    % Msg4 (contention resolution): идентификатор конкуренции из принятого Msg3 + ожидание ACK.
                    case 'MSG4_PENDING'
                        % назначение Msg4 (NPDCCH + NPDSCH + ACK);
                        s=obj.scheduler.downlink('Msg4','RA',obj.currentTick,c.deadlineTick,c.rnti);
                        % не нашлось — позже;
                        if isempty(s), continue; end
                        % передаём Msg4 с токеном UE (разрешение конфликта);
                        obj.emitDownlink(s,nbiot.ra.encodeMessage('Msg4',struct('token',c.token)));
                        % ждём ACK от UE; счётчик попыток;
                        obj.queueBsUl(id,s.ackGrant,'Msg4Ack'); c.state='MSG4_ACK'; c.receiptAttempts=c.receiptAttempts+1;
                    % Данные: DCI N0 + NPUSCH, версия избыточности RV по номеру передачи HARQ (cfg.phy.rvSequence).
                    case 'DATA_PENDING'
                        % RV для текущей передачи HARQ;
                        rv=obj.cfg.phy.rvSequence(c.harqTry);
                        % назначение UL-данных (DCI N0 + NPUSCH) в доле DT;
                        s=obj.scheduler.uplink('Data','DT',obj.currentTick,c.deadlineTick,c.rnti,c.ndi,rv);
                        % не нашлось — позже;
                        if isempty(s), continue; end
                        % передаём DCI и ждём NPUSCH;
                        obj.emitControl(s.controlGrant,s.dci); obj.queueBsUl(id,s.payloadGrant,'Data'); c.state='DATA_RX';
                    % Квитанция о доставке пакета (receipt) по NPDSCH + ожидание ACK от UE.
                    case 'RECEIPT_PENDING'
                        % назначение квитанции (NPDCCH + NPDSCH + ACK);
                        s=obj.scheduler.downlink('receipt','DT',obj.currentTick,c.deadlineTick,c.rnti);
                        % не нашлось — позже;
                        if isempty(s), continue; end
                        % поля квитанции: номер пакета, последний фрагмент, статус OK;
                        f=struct('sequence',c.sequence,'fragmentIndex',c.nextFragment-1,'status',1);
                        % передаём квитанцию;
                        obj.emitDownlink(s,nbiot.ra.encodeMessage('receipt',f));
                        % ждём ACK; счётчик попыток;
                        obj.queueBsUl(id,s.ackGrant,'ReceiptAck'); c.state='RECEIPT_ACK'; c.receiptAttempts=c.receiptAttempts+1;
                end
                % назначение выдано —
                if ~isempty(s)
                    % сохраняем его; контекст больше не ждёт; отметка продвижения.
                    c.schedule=s; c.pending=false; c.lastProgressTick=obj.currentTick; obj.contexts.set(id,c);
                end
            end
        end
        %EMITCONTROL Передаёт DCI по NPDCCH и пишет факт выдачи grant в журнал BS.
        function emitControl(obj,g,dci)
            % Waveform NPDCCH с DCI; добавляем в канал.
            tx=nbiot.phy.npdcch.buildTransmission(obj.cfg,g,dci); obj.channel.add(tx);
            % Учёт ресурсов.
            obj.logTx(g,0);
            % Наблюдение BS: выдано назначение.
            obj.observed.append(obj.currentTick,'grant',struct('phase',g.phase,'rnti',g.rnti,'format',dci.format,'startTick',g.startTick,'endTick',g.endTick));
        end
        %EMITDOWNLINK Передаёт DCI (NPDCCH) и полезную нагрузку (NPDSCH): RAR, Msg4, receipt.
        function emitDownlink(obj,s,bits)
            % Сначала DCI на NPDCCH.
            obj.emitControl(s.controlGrant,s.dci);
            % Waveform NPDSCH с битами сообщения; в канал.
            [tx,~]=nbiot.phy.npdsch.buildTransmission(obj.cfg,s.payloadGrant,bits,[]); obj.channel.add(tx);
            % Учёт ресурсов.
            obj.logTx(s.payloadGrant,0);
            % Для RAR — наблюдение «RAR отправлен».
            if strcmpi(s.payloadGrant.kind,'RAR'), obj.observed.append(obj.currentTick,'rar_sent',struct('rnti',s.controlGrant.rnti)); end
        end
        %QUEUEBSUL Ставит в очередь приём UL-передачи на BS после окончания её назначения.
        function queueBsUl(obj,id,g,kind)
            % Приём на BS завершится после конца передачи + обработка.
            obj.receiveQueue.push(g.endTick+obj.cfg.phy.processingTicks+1,'bs_ul',struct('contextId',id,'grant',g,'kind',kind));
            % Для данных —
            if strcmp(kind,'Data')
                % идентификатор блока HARQ;
                c=obj.contexts.get(id); f=obj.harqIdentity(c);
                % интервал передачи;
                f.startTick=g.startTick; f.endTick=g.endTick;
                % тик готовности результата;
                f.readyTick=g.endTick+obj.cfg.phy.processingTicks+1;
                % журнал HARQ: «назначено».
                obj.harqJournal.append(obj.currentTick,'scheduled',f);
            end
        end
        %QUEUEMONITORING Кандидаты поиска NPDCCH для UE, ожидающих DL (ТЗ §19).
        %   Search space: период 32 мс (Rmax·G), берутся два подкадра кандидата (повторы NPDCCH = 2).
        function queueMonitoring(obj)
            % Поиск NPDCCH — раз в 32 мс.
            if mod(obj.currentTick,32)~=0, return; end
            % Кандидатные подкадры; нужно минимум 2.
            ticks=obj.calendar.monitoringTicks(obj.currentTick); if numel(ticks)<2, return; end
            % Два подкадра (2 повтора DCI); тик готовности декодирования.
            ticks=ticks(1:2); ready=max(ticks)+1+obj.cfg.phy.processingTicks+1;
            % Для каждого UE:
            for u=1:obj.cfg.simulation.numUE
                % состояние;
                d=obj.devices.get(u);
                % UE не ждёт DCI или ещё рано — пропуск;
                if ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})) || ticks(1)<d.monitorStartTick, continue; end
                % Полудуплекс FDD: UE не принимает DL, пока передаёт в UL.
                if ticks(1)<d.ulBusyUntilTick && max(ticks)+1>d.ulBusyStartTick, continue; end
                % При ожидании RAR UE ищет DCI N1 по RA-RNTI, далее — N0/N1 по своему C-RNTI.
                if strcmp(d.state,'WAIT_RAR'), rnti=d.raRnti; formats={'N1'}; else, rnti=d.rnti; formats={'N0','N1'}; end
                % Candidate is derived solely from the public monitoring calendar.
                g=struct('ticks',ticks,'startTick',ticks(1),'endTick',max(ticks)+1,'rnti',rnti, ...
                    'profile',struct('repetitions',2,'aggregationLevel',2));
                % декодирование кандидата завершится к тику готовности.
                obj.receiveQueue.push(ready,'monitor',struct('ueId',u,'attemptId',d.attemptId,'grant',g,'formats',{formats}));
            end
        end
        %RECEIVECONTROL UE декодирует NPDCCH-кандидат; по DCI N0 передаёт данные, по N1 ждёт NPDSCH.
        function receiveControl(obj,p)
            % Состояние UE.
            d=obj.devices.get(p.ueId);
            % Попытка сменилась или UE не ждёт DCI — выходим.
            if d.attemptId~=p.attemptId || ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})), return; end
            % Принятый сигнал DL у этого UE.
            rx=obj.receiverWindow('DL',p.ueId,p.grant);
            % Для каждого ожидаемого формата DCI:
            for f=1:numel(p.formats)
                % кандидат с этим форматом;
                g=p.grant; g.format=p.formats{f}; g.profile.format=g.format;
                % слепое декодирование NPDCCH;
                decoded=nbiot.phy.npdcch.receive(obj.cfg,rx,g);
                % CRC не сошёлся — следующий формат;
                if decoded.crcError~=0, continue; end
                try
                    % DCI N0 (UL grant) —
                    if strcmp(decoded.dci.format,'N0')
                        % UE не передаёт данные — пропуск;
                        if ~any(strcmp(d.state,{'DATA','WAIT_RECEIPT'})), continue; end
                        % восстанавливаем назначение NPUSCH;
                        ul=obj.scheduler.reconstructUplink(decoded.dci,g.ticks,d.rnti);
                        % передаём данные; выходим;
                        obj.ueTransmitData(p.ueId,ul); return;
                    else
                        % DCI N1 (DL) — восстанавливаем назначение NPDSCH;
                        dl=obj.scheduler.reconstructDownlink(decoded.dci,g.ticks,g.rnti);
                        % не удалось — пропуск;
                        if isempty(dl), continue; end
                        % приём NPDSCH завершится после конца + обработка;
                        obj.receiveQueue.push(dl.endTick+obj.cfg.phy.processingTicks+1,'dl_payload', ...
                            struct('ueId',p.ueId,'attemptId',d.attemptId,'grant',dl,'dci',decoded.dci)); return;
                    end
                catch exception
                    % неподдерживаемое назначение или ошибка протокола — пропуск.
                    if startsWith(exception.identifier,'nbiot:UnsupportedGrant') || startsWith(exception.identifier,'nbiot:protocol:'), continue; end
                    rethrow(exception);
                end
            end
        end
        %RECEIVEDLPAYLOAD UE декодирует NPDSCH: RAR, Msg4 или квитанцию, и реагирует по протоколу.
        function receiveDlPayload(obj,p)
            % Состояние UE.
            d=obj.devices.get(p.ueId);
            % Попытка сменилась или UE не ждёт DL — выходим.
            if d.attemptId~=p.attemptId || ~any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4','DATA','WAIT_RECEIPT'})), return; end
            % Принятый сигнал DL.
            rx=obj.receiverWindow('DL',p.ueId,p.grant);
            % Декодирование NPDSCH.
            [decoded,~]=nbiot.phy.npdsch.receive(obj.cfg,rx,p.grant,[]);
            % Учёт декодирования.
            obj.recordDecode('NPDSCH',decoded,p.grant,p.ueId);
            % CRC не сошёлся — выходим.
            if decoded.crcError~=0, return; end
            try
                % RAR: принимается, только если RAPID совпадает с выбранным NInit и окно RAR не истекло.
                % При логической коллизии RAR примут все UE с этим NInit — и все передадут Msg3 (ТЗ §15).
                if strcmp(d.state,'WAIT_RAR')
                    % разбор RAR;
                    rar=nbiot.ra.decodeMessage('RAR',decoded.decodedBits);
                    % RAPID не наш или окно RAR истекло — выходим;
                    if rar.rapid~=d.nInit || obj.currentTick>d.deadlineTick, return; end
                    % назначение Msg3 из UL grant; адрес — TC-RNTI;
                    ul=obj.scheduler.reconstructMsg3(rar,p.grant.ticks); ul.rnti=rar.rnti;
                    % Msg3 не успеваем — выходим;
                    if ul.startTick<obj.currentTick, return; end
                    % запоминаем RNTI и timing advance (в секундах);
                    d.rnti=rar.rnti; d.timingAdvanceSeconds=rar.timingAdvance*16/(15000*2048);
                    % ждём Msg4 до конца contention timer;
                    d.state='WAIT_MSG4'; d.deadlineTick=obj.monitoringDeadline(ul.endTick,obj.cfg.ra.contentionPp);
                    % мониторинг после Msg3; UL занят на время Msg3;
                    d.monitorStartTick=ul.endTick; d.ulBusyStartTick=ul.startTick; d.ulBusyUntilTick=ul.endTick;
                    % пакет; кодируем Msg3 с токеном и номером пакета;
                    packet=obj.packets.get(d.packetId); bits=nbiot.ra.encodeMessage('Msg3',struct('token',d.token,'sequence',double(packet.sequence)));
                    % Msg3 по NPUSCH: идентификатор конкуренции (token) и номер пакета; TA применяется в канале.
                    [tx,d.encoderState]=nbiot.phy.npusch.buildTransmission(obj.cfg,ul,bits,[]);
                    % TA и добавление в канал; сохраняем UE;
                    tx.ueId=p.ueId; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx); obj.devices.set(p.ueId,d);
                    % учёт ресурсов;
                    obj.logTx(ul,p.ueId);
                % Msg4 распознаётся по заголовку 60 (тип CE «contention resolution identity»).
                elseif numel(decoded.decodedBits)>=16 && nbiot.util.fromBits(decoded.decodedBits(1:8))==60
                    % разбор Msg4;
                    msg=nbiot.ra.decodeMessage('Msg4',decoded.decodedBits);
                    % Чужой идентификатор конкуренции — это UE проиграл конкуренцию; ждёт таймаут и BACKOFF.
                    if msg.token~=d.token, return; end
                    % contention timer истёк — выходим;
                    if strcmp(d.state,'WAIT_MSG4') && obj.currentTick>d.deadlineTick, return; end
                    % первый ли успех этой попытки;
                    firstSuccess=~d.raSucceeded;
                    % если первый —
                    if firstSuccess
                        % попытка успешна; тик завершения;
                        d.raSucceeded=true; obj.attempts(d.attemptId).status='success'; obj.attempts(d.attemptId).endTick=obj.currentTick;
                        % Capture (ТЗ §16): попытка успешна, хотя на её NInit была логическая коллизия.
                        obj.attempts(d.attemptId).capture=obj.attempts(d.attemptId).collision;
                        % событие истины «успех RA»;
                        obj.truth.append(obj.currentTick,'ra_success',struct('attemptId',d.attemptId,'ueId',p.ueId,'packetId',d.packetId));
                    end
                    % после первого успеха —
                    if firstSuccess
                        % передача данных: первый фрагмент, NDI сброшен, мониторинг с текущего тика;
                        d.state='DATA'; d.fragmentIndex=0; d.ndi=-1; d.monitorStartTick=obj.currentTick;
                        % таймаут продвижения;
                        d.progressDeadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                    end
                    % сохраняем UE и шлём ACK на Msg4;
                    obj.devices.set(p.ueId,d); obj.ueAck(p.ueId,p.dci,p.grant,'RA');
                else
                    % Квитанция о доставке последнего фрагмента: пакет завершён на стороне UE.
                    receipt=nbiot.ra.decodeMessage('receipt',decoded.decodedBits); packet=obj.packets.get(d.packetId);
                    % квитанция не на наш пакет или не на последний фрагмент — выходим;
                    if receipt.sequence~=double(packet.sequence) || receipt.status~=1 || receipt.fragmentIndex~=numel(packet.blocks)-1, return; end
                    % ACK на квитанцию;
                    obj.ueAck(p.ueId,p.dci,p.grant,'DT');
                    % пакет доставлен; UE в IDLE;
                    obj.packets.localFinish(d.packetId,obj.currentTick,true); obj.devices.reset(p.ueId);
                end
            catch exception
                % ошибка протокола или назначения — тихо выходим.
                if startsWith(exception.identifier,'nbiot:protocol:') || startsWith(exception.identifier,'nbiot:UnsupportedGrant'), return; end
                rethrow(exception);
            end
        end
        %UETRANSMITDATA UE передаёт фрагмент пакета по NPUSCH по полученному DCI N0 (ТЗ §20).
        %   Новый NDI — следующий фрагмент; тот же NDI — повтор HARQ (RV меняется в DCI).
        function ueTransmitData(obj,u,g)
            % Состояние UE и его пакет.
            d=obj.devices.get(u); packet=obj.packets.get(d.packetId);
            % Первая передача — фрагмент 0;
            if d.ndi<0, d.fragmentIndex=0;
            % NDI сменился — следующий фрагмент, новый кодер.
            elseif g.ndi~=d.ndi, d.fragmentIndex=d.fragmentIndex+1; d.encoderState=[]; end
            % Фрагменты кончились или опоздали — выходим.
            if d.fragmentIndex>=numel(packet.blocks) || g.startTick<obj.currentTick, return; end
            % Запоминаем NDI.
            d.ndi=g.ndi; d.state='DATA';
            % Таймаут продвижения.
            d.progressDeadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
            % UL занят на время передачи.
            d.ulBusyStartTick=g.startTick; d.ulBusyUntilTick=g.endTick;
            % Waveform NPUSCH текущего фрагмента.
            [tx,d.encoderState]=nbiot.phy.npusch.buildTransmission(obj.cfg,g,packet.blocks{d.fragmentIndex+1},d.encoderState);
            % TA и добавление в канал; сохраняем UE.
            tx.ueId=u; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx); obj.devices.set(u,d);
            % Учёт ресурсов.
            obj.logTx(g,u);
            % Ниже — только журнал HARQ для анализа; на сигнал и состояние UE не влияет.
            % Analyzer provenance only; never influences the waveform or state.
            id=obj.contexts.findRnti(g.rnti);
            % Контекст найден —
            if id>0
                % контекст;
                c=obj.contexts.get(id);
                % ждёт именно эту передачу —
                if strcmp(c.state,'DATA_RX') && isfield(c.schedule,'payloadGrant') && ...
                        c.schedule.payloadGrant.startTick==g.startTick && c.schedule.payloadGrant.endTick==g.endTick
                    % идентификатор HARQ и интервал;
                    f=obj.harqIdentity(c); f.startTick=g.startTick; f.endTick=g.endTick;
                    % что передаёт UE: номер пакета и фрагмента;
                    f.transmitterSequence=double(packet.sequence); f.transmitterBlockIndex=d.fragmentIndex;
                    % номер пакета;
                    f.packetId=double(packet.packetId);
                    % журнал HARQ: «излучено»;
                    obj.harqJournal.append(g.startTick,'emitted',f);
                    % выходим.
                    return;
                end
            end
            % Передача без ожидающего контекста — журнал HARQ: «излучено без назначения».
            obj.harqJournal.append(g.startTick,'unmatchedEmission', ...
                struct('rnti',g.rnti,'startTick',g.startTick,'endTick',g.endTick, ...
                'packetId',double(packet.packetId)));
        end
        %UEACK UE передаёт ACK (NPUSCH формат 2, 1 бит) на принятые Msg4/квитанцию.
        function ueAck(obj,u,dci,payload,phase)
            % Состояние UE; назначение ACK по DCI.
            d=obj.devices.get(u); g=obj.scheduler.reconstructAck(dci,payload,d.rnti);
            % Фаза (RA или DT).
            g.phase=phase;
            % ACK не успевает — ошибка модели.
            if g.startTick<obj.currentTick, error('nbiot:engine:Timing','Decoded DL cannot meet its ACK start.'); end
            % Waveform ACK (1 бит, NPUSCH формат 2).
            [tx,~]=nbiot.phy.npusch.buildTransmission(obj.cfg,g,int8(1),[]);
            % TA и добавление в канал.
            tx.ueId=u; tx.timingAdvanceSeconds=d.timingAdvanceSeconds; obj.channel.add(tx);
            % UL занят на время ACK; сохраняем UE.
            d.ulBusyStartTick=g.startTick; d.ulBusyUntilTick=g.endTick; obj.devices.set(u,d);
            % Учёт ресурсов.
            obj.logTx(g,u);
        end
        %RECEIVEATBS BS принимает UL-передачу (Msg3, данные, ACK) по суммарному сигналу и декодирует.
        %   Результат принимается, только если состояние контекста и назначение совпадают с ожидаемыми.
        function receiveAtBs(obj,p)
            % Контекст и назначение.
            c=obj.contexts.get(p.contextId); g=p.grant;
            % Контекст уже закрыт — выходим.
            if any(strcmp(c.state,{'FAILED','EXPIRED','DONE'})), return; end
            % Receive events belong to one public BS state and grant. A queued
            % event from an earlier schedule must not advance a newer context.
            switch p.kind
                % Msg3;
                case 'Msg3', expectedState='MSG3_RX'; grantField='msg3Grant';
                % данные;
                case 'Data', expectedState='DATA_RX'; grantField='payloadGrant';
                % ACK на Msg4;
                case 'Msg4Ack', expectedState='MSG4_ACK'; grantField='ackGrant';
                % ACK на квитанцию;
                case 'ReceiptAck', expectedState='RECEIPT_ACK'; grantField='ackGrant';
                % иное — выходим.
                otherwise, return;
            end
            % Контекст не ждёт этот приём —
            if ~strcmp(c.state,expectedState) || ~isstruct(c.schedule) || ...
                    ~isfield(c.schedule,grantField) || ...
                    ~isequaln(c.schedule.(grantField),g)
                % выходим.
                return;
            end
            % Принятый сигнал UL на BS.
            rx=obj.receiverWindow('UL',0,g);
            % Декодирование NPUSCH (с мягким буфером HARQ).
            [decoded,soft]=nbiot.phy.npusch.receive(obj.cfg,rx,g,c.softBuffer);
            % Диагностика оценок приёмника.
            obj.appendNpuschReceptionDiagnostic(p.kind,decoded,g,c);
            % Учёт декодирования.
            obj.recordDecode(p.kind,decoded,g,0);
            % По виду приёма:
            switch p.kind
                % Msg3: CRC не прошёл → контекст FAILED (UE уйдёт в BACKOFF по таймауту contention timer).
                case 'Msg3'
                    % CRC не сошёлся — контекст неуспешен;
                    if decoded.crcError~=0, c.state='FAILED';
                    else
                        % иначе разбор Msg3;
                        try, msg=nbiot.ra.decodeMessage('Msg3',decoded.decodedBits);
                        catch exception
                            % ошибка протокола — контекст неуспешен;
                            if startsWith(exception.identifier,'nbiot:protocol:'), c.state='FAILED'; obj.contexts.set(p.contextId,c); return; end
                            rethrow(exception);
                        end
                        % токен и номер пакета; ждём Msg4;
                        c.token=msg.token; c.sequence=msg.sequence; c.state='MSG4_PENDING'; c.pending=true;
                        % очищаем мягкий буфер и счётчик.
                        c.softBuffer=[]; c.receiptAttempts=0;
                    end
                % Данные: CRC + проверка заголовка фрагмента; мягкие биты сохраняются для HARQ-объединения.
                case 'Data'
                    % Идентификатор HARQ; блок пока не принят.
                    harqFields=obj.harqIdentity(c); accepted=false;
                    % Мягкий буфер для комбинирования.
                    c.softBuffer=soft;
                    % CRC сошёлся —
                    if decoded.crcError==0
                        % биты;
                        b=decoded.decodedBits;
                        try
                            % заголовок фрагмента;
                            f=obj.fragmentHeader(b);
                            % Пакет 200 байт = 1600 бит режется на фрагменты по 208 бит полезных данных (TB 256 бит с заголовком).
                            valid=f.sequence==c.sequence && f.index==c.nextFragment-1 && f.count==ceil(obj.cfg.traffic.packetBytes*8/208);
                        % битый заголовок — блок не годится;
                        catch, valid=false; end
                        % заголовок корректен —
                        if valid
                            % блок принят;
                            accepted=true;
                            % Ground-truth mapping below is an analyzer side effect only;
                            % BS scheduling uses the decoded header/token, not PacketStore.
                            obj.analyzeDelivery(c,b,f.index);
                            % последний фрагмент —
                            if c.nextFragment==f.count
                                % данные собраны; готовим квитанцию;
                                c.dataComplete=true; c.state='RECEIPT_PENDING'; c.receiptAttempts=0;
                            else
                                % иначе — следующий фрагмент, NDI меняется;
                                c.nextFragment=c.nextFragment+1; c.ndi=1-c.ndi; c.state='DATA_PENDING';
                            end
                            % первая передача нового блока; буфер очищен; контекст ждёт планирования;
                            c.harqTry=1; c.softBuffer=[]; c.pending=true;
                            % новый дедлайн продвижения;
                            c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                        % заголовок битый — неудачная передача HARQ;
                        else, c=obj.failedTb(c); end
                    % CRC не сошёлся — неудачная передача HARQ.
                    else, c=obj.failedTb(c); end
                    % Результат для журнала HARQ.
                    harqFields.crcError=decoded.crcError; harqFields.accepted=accepted;
                    % Журнал HARQ: «декодировано».
                    obj.harqJournal.append(obj.currentTick,'decoded',harqFields);
                    % Принят —
                    if accepted
                        % итог «принят»;
                        harqFields.outcome='accepted'; obj.harqJournal.append(obj.currentTick,'terminal',harqFields);
                    % контекст неуспешен (исчерпаны передачи) —
                    elseif strcmp(c.state,'FAILED')
                        % итог HARQ «не принят».
                        harqFields.outcome='failed'; obj.harqJournal.append(obj.currentTick,'terminal',harqFields);
                    end
                % ACK без CRC: решение по детектору UCI (uciDetected) и значению бита.
                case {'Msg4Ack','ReceiptAck'}
                    % ACK: 1 бит без CRC, равный 1;
                    ack=~decoded.hasCrc && ~isempty(decoded.decodedBits) && decoded.decodedBits(1)==1 && ...
                        isfield(decoded.measurements,'uciDetected') && decoded.measurements.uciDetected;
                    % ACK получен —
                    if ack
                        % на Msg4 —
                        if strcmp(p.kind,'Msg4Ack')
                            % переходим к данным: первая передача, пустой буфер;
                            c.state='DATA_PENDING'; c.pending=true; c.softBuffer=[]; c.harqTry=1;
                            % дедлайн продвижения;
                            c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks;
                        % на квитанцию — пакет закрыт на BS.
                        else, c.state='DONE'; c.pending=false; end
                    % Нет ACK и исчерпаны повторы — контекст неуспешен;
                    elseif c.receiptAttempts>=obj.cfg.phy.maxReceiptTransmissions, c.state='FAILED'; c.pending=false;
                    % нет ACK на Msg4 —
                    elseif strcmp(p.kind,'Msg4Ack')
                        % Retry contention resolution within its existing window.
                        % The 512 ms receipt interval applies to data receipts.
                        c.state='MSG4_PENDING'; c.pending=true;
                    else
                        % нет ACK на квитанцию — повтор после паузы;
                        c.state=strrep(c.state,'_ACK','_RETRY'); c.pending=false;
                        % тик повтора.
                        c.lastProgressTick=obj.currentTick+obj.cfg.phy.receiptTimeoutTicks;
                    end
            end
            % Сохраняем контекст.
            obj.contexts.set(p.contextId,c);
        end
        %FAILEDTB Ошибка CRC блока: повтор HARQ или FAILED после cfg.phy.maxHarqTransmissions.
        function c=failedTb(obj,c)
            % Исчерпаны передачи HARQ (4) — контекст неуспешен;
            if c.harqTry>=obj.cfg.phy.maxHarqTransmissions, c.state='FAILED'; c.pending=false;
            % иначе следующая передача того же блока.
            else, c.harqTry=c.harqTry+1; c.state='DATA_PENDING'; c.pending=true; end
        end
        %HARQIDENTITY Идентификатор блока HARQ контекста C (для журнала).
        function f=harqIdentity(~,c)
            % Контекст, пакет, блок, номер передачи.
            f=struct('contextId',c.id,'packetSequence',c.sequence, ...
                'blockIndex',c.nextFragment-1,'attempt',c.harqTry);
        end
        %HARQTERMINAL Итоговое событие HARQ с исходом OUTCOME.
        function harqTerminal(obj,c,outcome)
            % Идентификатор и исход.
            f=obj.harqIdentity(c); f.outcome=outcome;
            % Запись в журнал.
            obj.harqJournal.append(obj.currentTick,'terminal',f);
        end
        %ANALYZEDELIVERY Только для KPI: сопоставить принятый блок с истинным пакетом UE.
        function analyzeDelivery(obj,c,b,index)
            % Ищем UE этого контекста:
            for u=1:obj.cfg.simulation.numUE
                % состояние;
                d=obj.devices.get(u);
                % токен, RNTI совпадают и пакет есть —
                if d.token==c.token && d.rnti==c.rnti && d.packetId>0
                    % отмечаем принятый фрагмент; пакет собран целиком —
                    if obj.packets.markReceived(d.packetId,index,b,obj.currentTick)
                        % событие истины «пакет доставлен»;
                        obj.truth.append(obj.currentTick,'packet_delivered',struct('packetId',d.packetId,'ueId',u));
                    end
                    % выходим.
                    return;
                end
            end
        end
        %ADVANCETIMERS Таймеры: окно RAR и contention timer у UE (→ BACKOFF или DROPPED, ТЗ §38),
        %   тайм-аут прогресса передачи данных, повторы Msg4/квитанции у BS.
        function advanceTimers(obj)
            % Для каждого UE:
            for u=1:obj.cfg.simulation.numUE
                % состояние;
                d=obj.devices.get(u);
                % ждёт RAR или Msg4 и дедлайн прошёл —
                if any(strcmp(d.state,{'WAIT_RAR','WAIT_MSG4'})) && obj.currentTick>=d.deadlineTick
                    % попытка неуспешна; тик завершения;
                    obj.attempts(d.attemptId).status='failure'; obj.attempts(d.attemptId).endTick=obj.currentTick;
                    % причина — таймаут RAR;
                    reason='rar_timeout';
                    % или таймаут Msg4 (contention timer);
                    if strcmp(d.state,'WAIT_MSG4'), reason='msg4_timeout'; end
                    % событие истины «неуспех RA»;
                    obj.truth.append(obj.currentTick,'ra_failure',struct( ...
                        'attemptId',d.attemptId,'ueId',u,'packetId',d.packetId, ...
                        'reason',reason));
                    % Лимит попыток RA (база 8, ТЗ §30) исчерпан → пакет отбрасывается (DROPPED, ТЗ §12).
                    if d.attemptNumber>=obj.cfg.ra.maxAttempts
                        % пакет отброшен; UE в IDLE;
                        obj.packets.markTerminal(d.packetId,'dropped','ra_limit',obj.currentTick); obj.devices.reset(u);
                    else
                        % BACKOFF: равномерно 0..backoffTicks мс (база 256 мс, ADR-005), поток 'backoff' по (UE, попытка).
                        s=obj.sources.stream('backoff',0,u,d.lifetimeAttempt);
                        % ожидание BACKOFF; состояние BACKOFF;
                        d.nextAllowedTick=obj.currentTick+ceil(rand(s)*obj.cfg.ra.backoffTicks); d.state='BACKOFF'; obj.devices.set(u,d);
                    end
                % передача данных без продвижения слишком долго —
                elseif any(strcmp(d.state,{'DATA','WAIT_RECEIPT'})) && obj.currentTick>=d.progressDeadlineTick
                    % пакет отброшен; UE в IDLE.
                    obj.packets.markTerminal(d.packetId,'dropped','progress_timeout',obj.currentTick); obj.devices.reset(u);
                end
            end
            % Для каждого контекста на BS:
            for id=1:numel(obj.contexts.entries)
                % контекст;
                c=obj.contexts.get(id);
                % пауза перед повтором Msg4/квитанции истекла —
                if any(strcmp(c.state,{'MSG4_RETRY','RECEIPT_RETRY'})) && obj.currentTick>=c.lastProgressTick
                    % снова ждёт планирования;
                    c.state=strrep(c.state,'_RETRY','_PENDING'); c.pending=true;
                    % для квитанции — новый дедлайн;
                    if c.dataComplete, c.deadlineTick=obj.currentTick+obj.cfg.phy.progressTimeoutTicks; end
                    % сохраняем.
                    obj.contexts.set(id,c);
                end
            end
        end
        %RECEIVERWINDOW Суммарный принятый сигнал для назначения G (±128 отсчётов запаса).
        function rx=receiverWindow(obj,direction,u,g)
            % Принятый сигнал в окне назначения с запасом ±128 отсчётов.
            rx=obj.channel.receive(direction,u,max(0,g.startTick*1920-128),g.endTick*1920+128);
        end
        %RECORDDECODE Журналирует результат декодирования: на BS — в наблюдения, у UE — в истину.
        function recordDecode(obj,kind,decoded,g,receiverId)
            % Поля события декодирования.
            fields=struct('channel',kind,'phase',g.phase, ...
                'rnti',g.rnti,'hasCrc',decoded.hasCrc,'crcError',decoded.crcError, ...
                'receiverId',receiverId,'startTick',g.startTick,'endTick',g.endTick);
            % Приёмник — BS —
            if receiverId==0
                % наблюдение BS;
                obj.observed.append(obj.currentTick,'phy_decode',fields);
                % ошибка CRC —
                if decoded.hasCrc && decoded.crcError~=0
                    % в Msg3 —
                    if strcmp(kind,'Msg3')
                        % счётчик ошибок Msg3;
                        obj.observedCrcCounters.msg3Errors=obj.observedCrcCounters.msg3Errors+1;
                    % в данных —
                    elseif strcmp(kind,'Data')
                        % счётчик ошибок данных;
                        obj.observedCrcCounters.dataErrors=obj.observedCrcCounters.dataErrors+1;
                    end
                end
            else
                % приёмник — UE: только в истину.
                obj.truth.append(obj.currentTick,'phy_decode',fields);
            end
        end
        %APPENDNPUSCHRECEPTIONDIAGNOSTIC Сравнение оценок задержки/CFO приёмника с истиной (диагностика ТЗ §36).
        function appendNpuschReceptionDiagnostic(obj,kind,decoded,g,c)
            % Истинные задержка и CFO по умолчанию неизвестны.
            configuredDelay=NaN; configuredCfo=NaN;
            % Попытка и UE по умолчанию неизвестны.
            attemptId=NaN; ueId=NaN;
            % Попытки той же возможности и NInit.
            matching=find([obj.attempts.occasionId]==c.occasionId & ...
                [obj.attempts.nInit]==c.nInit);
            % Истина однозначна, только если такая попытка одна —
            if numel(matching)==1
                % попытка;
                attempt=obj.attempts(matching);
                % её номер и UE;
                attemptId=attempt.attemptId; ueId=attempt.ueId;
                % UE сценария;
                ue=obj.scenario.ue(find([obj.scenario.ue.ueId]==attempt.ueId,1));
                % TA по умолчанию 0;
                timingAdvance=0;
                % состояние UE;
                device=obj.devices.get(attempt.ueId);
                % если TA известен —
                if isfield(device,'timingAdvanceSeconds') && ...
                        isfinite(device.timingAdvanceSeconds)
                    % берём его;
                    timingAdvance=device.timingAdvanceSeconds;
                end
                % Истинная остаточная задержка UL: путь туда-обратно + рассинхрон UE − применённый TA.
                configuredDelay=2*ue.distanceM/299792458+ ...
                    ue.syncOffsetSeconds-timingAdvance;
                % истинный CFO UE.
                configuredCfo=ue.cfoHz;
            end
            % Запись диагностики приёмника NPUSCH.
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
            % Событие истины «передача» (для учёта ресурсов).
            obj.truth.append(g.startTick,'transmission',struct('direction',g.direction,'phase',g.phase, ...
                'channel',g.kind,'ueId',u,'ticks',g.ticks,'frequencyStartHz',g.frequencyStartHz,'bandwidthHz',g.bandwidthHz));
        end
        %MONITORINGDEADLINE Тик окончания окна ожидания длиной PP·Rmax подкадров поиска NPDCCH
        %   (окно RAR = pp10, contention timer = pp16; TS 36.321), начиная со START.
        function deadline=monitoringDeadline(obj,start,pp)
            % Сколько подкадров NPDCCH осталось (PP × Rmax); дедлайн по умолчанию — бесконечность.
            remaining=pp*obj.cfg.phy.npdcch.rmax; deadline=Inf;
            % Перебор периодов поиска (32 мс) начиная с периода START:
            for base=floor(start/32)*32:32:obj.cfg.simulation.durationTicks-1
                % кандидатные подкадры не раньше START;
                ticks=obj.calendar.monitoringTicks(base); ticks=ticks(ticks>=start);
                % их хватает —
                if numel(ticks)>=remaining
                    % дедлайн: после нужного подкадра + декодирование; выходим.
                    deadline=ticks(remaining)+1+obj.cfg.phy.processingTicks+1; return;
                end
                % иначе вычитаем и идём дальше.
                remaining=remaining-numel(ticks);
            end
        end
        %NEWTOKEN Уникальный 48-битный идентификатор конкуренции UE для попытки (Msg3/Msg4).
        function token=newToken(obj,u,attempt)
            % Поток 'token' по (UE, попытка).
            s=obj.sources.stream('token',0,u,attempt);
            % Пока не найден уникальный токен:
            while true
                % 48-битный токен и ключ;
                token=uint64(floor(rand(s)*2^48)); key=sprintf('%u',token);
                % ненулевой и новый — запоминаем и выходим.
                if token>0 && ~isKey(obj.tokens,key), obj.tokens(key)=true; return; end
            end
        end
        %CLOSEWINDOW Закрывает окно датасета [FIRST, LAST): признаки BS и target (ТЗ §22).
        function obs=closeWindow(obj,first,last)
            % Занятость ресурсов RA/DT в окне.
            occupancy=obj.calendar.windowOccupancy(first,last);
            % Признаки и цели окна по журналам.
            [obs,target]=nbiot.dataset.closeWindow(obj.observed.all(),obj.truth.all(),first,last, ...
                obj.raIntegral,obj.activeIntegral,obj.queueIntegral, ...
                obj.scenario.externalRealizationId,obj.cfg.dataset.windowTicks, ...
                occupancy,obj.runtimeAction);
            % Добавляем строки признаков и целей.
            obj.observationRows{end+1}=obs; obj.targetRows{end+1}=target;
            % Сбрасываем интегралы окна.
            obj.raIntegral=0; obj.activeIntegral=0; obj.queueIntegral=0;
            % Признаки окна таблицей (для контроллера).
            obs=nbiot.NBIoTSimulator.rowsTable({obs},nbiot.dataset.featureSchema().observationNames);
        end
        %PROCESSCONTROLLERWINDOW Решение контроллера на границе окна (ТЗ §23, период 500 мс):
        %   признаки закрытого окна → оценка нагрузки (оценщик, напр. ML-модель) → выбор действия
        %   из допустимого множества
        %   → применение → запись в журнал решений (время, оценка, конфигурация, переключение).
        function processControllerWindow(obj,observation,decisionTick)
            % Состояние решения: тик и горизонт.
            state=struct('tick',double(decisionTick), ...
                'durationTicks',double(obj.cfg.simulation.durationTicks));
            % Признаки для журнала — по умолчанию пусто.
            featureValuesJson='{}';
            % Если есть закрытое окно —
            if istable(observation)&&height(observation)==1
                % схема;
                schema=nbiot.dataset.featureSchema();
                % Признаки — только наблюдения BS (без ключей окна); истинная нагрузка сюда не попадает (ТЗ §40).
                featureTable=observation(:,schema.observationNames(5:end));
                % признаки в JSON.
                featureValuesJson=jsonencode(table2struct(featureTable));
            end
            % Оценка по умолчанию — нет.
            estimate=struct('valid',false,'value',NaN, ...
                'featureWindowEndTick',NaN,'reason','no-prior-window');
            % Ошибки оценщика пока нет.
            estimateError=[];
            % Решения только внутри горизонта (не на тике 0) —
            if decisionTick>0&&decisionTick<state.durationTicks
                try
                    % оценка нагрузки оценщиком;
                    estimate=nbiot.controller.estimateLoad(obj.controllerRuntime.estimator, ...
                        observation,obj.controllerRuntime.policy.maximumLoad);
                catch exception
                    % ошибка оценщика — оценки нет;
                    estimate=struct('valid',false,'value',NaN, ...
                        'featureWindowEndTick',double(decisionTick),'reason','prediction-error');
                    % запоминаем ошибку.
                    estimateError=exception;
                end
            end
            % Последняя оценка.
            obj.controllerLatestEstimate=estimate;
            % Выбор действия по методу, оценке и порогам.
            action=nbiot.controller.chooseAction(obj.controllerRuntime.method,estimate, ...
                state,obj.runtimeAction,obj.controllerRuntime.policy);
            % Действие до решения.
            before=obj.runtimeAction;
            % По умолчанию не применено; причина — от политики.
            applied=false; reason=action.reason;
            % Порог сработал —
            if strcmp(action.reason,'load-threshold')
                % применяем действие;
                [applied,reason]=obj.applyRuntimeAction(action);
            % иначе, если оценщик упал —
            elseif ~isempty(estimateError)
                % причина «ошибка прогноза».
                reason='prediction-error';
            end
            % Запись решения: тики, оценка, действие до/после, переключение, признаки.
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
            % Если оценщик упал —
            if ~isempty(estimateError)
                % идентификатор ошибки;
                record.errorIdentifier=estimateError.identifier;
                % сообщение.
                record.errorMessage=estimateError.message;
            end
            % Добавляем запись в журнал контроллера.
            obj.controllerLog(end+1)=record;
        end
        %VALIDATESCENARIO Сценарий согласован с cfg: UE 1..N, тот же realizationId, поступления в горизонте.
        function validateScenario(obj,s)
            % В сценарии не ровно N UE с номерами 1..N —
            if ~isfield(s,'ue') || numel(s.ue)~=obj.cfg.simulation.numUE || ...
                    ~isequal(double([s.ue.ueId]),1:obj.cfg.simulation.numUE)
                % иначе ошибка.
                error('nbiot:scenario:Incompatible','Scenario UE IDs must be 1:numUE.');
            end
            % Номер реализации сценария не совпадает с конфигурацией —
            if ~isfield(s,'externalRealizationId') || s.externalRealizationId~=obj.cfg.simulation.realizationId
                error('nbiot:scenario:Randomness','Scenario/config realization IDs disagree.');
            end
            % Если поступления есть —
            if ~isempty(s.arrivals)
                % их тики;
                ticks=double([s.arrivals.createdTick]);
                % не по возрастанию или вне горизонта —
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
            % TB — 256 бит из 0/1; иначе ошибка протокола.
            if numel(b)~=256 || any(b~=0 & b~=1), error('nbiot:protocol:Fragment','Invalid TB.'); end
            % Заголовок: номер пакета (16 бит), индекс, число фрагментов, число полезных бит.
            f=struct('sequence',double(nbiot.util.fromBits(b(1:16))), ...
                'index',double(nbiot.util.fromBits(b(17:24))), ...
                'count',double(nbiot.util.fromBits(b(25:32))), ...
                'validBits',double(nbiot.util.fromBits(b(33:40))));
            % Резервные биты, индексы или хвост после полезных бит некорректны —
            if any(b(41:48)) || f.count<1 || f.index>=f.count || f.validBits<1 || f.validBits>208 || any(b(49+f.validBits:end))
                error('nbiot:protocol:Fragment','Invalid fragment header/padding.');
            end
        end
        %ROWSTABLE Склеивает строки датасета (cell) в table с заданными именами столбцов.
        function tableValue=rowsTable(rows,names)
            % Нет строк — пустая таблица с нужными столбцами;
            if isempty(rows), tableValue=array2table(zeros(0,numel(names)),'VariableNames',names);
            % иначе таблица из строк.
            else, tableValue=cell2table(vertcat(rows{:}),'VariableNames',names); end
        end
    end
end
