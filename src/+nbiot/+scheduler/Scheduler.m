classdef Scheduler < handle
    %SCHEDULER Планировщик BS (ТЗ §19–20, §25): выдаёт назначения с учётом календаря и квот RA/DT.
    %   Все зависимые ресурсы резервируются одной транзакцией: DCI на NPDCCH + передача + (Msg3 или ACK).
    %   Поиск: кандидаты NPDCCH раз в 32 мс (Rmax 4 × G 8), перебор допустимых задержек DCI.
    %   Публичные reconstruct* восстанавливают назначение из принятого DCI/RAR — их использует UE,
    %   чтобы знать, когда и где передавать (UE не видит внутренние структуры BS).
    properties (Access=private)
        % Конфигурация.
        cfg
        % Календарь ресурсов (общий с симулятором).
        calendar
        % Следующий номер назначения (grantId).
        nextId=1
        % busyUntil(RNTI) — тик, до которого у этого UE уже есть назначения (не планировать внахлёст).
        busyUntil
        % Зарезервированные возможности NPRACH.
        occasions=[]
        % Тики DL, свободные от обязательных сигналов (с нуля).
        availableDlTicks
        % Префиксные суммы свободных DL-тиков (номер свободного тика по абсолютному тику).
        availableDlPrefix
    end
    methods
        %SCHEDULER Планировщик над календарём CALENDAR.
        function obj=Scheduler(cfg,calendar)
            % Конфигурация и календарь.
            obj.cfg=cfg; obj.calendar=calendar;
            % Пустая таблица занятости RNTI.
            obj.busyUntil=containers.Map('KeyType','double','ValueType','double');
            % Маска обязательных DL-подкадров строкой.
            mask=calendar.mandatoryMask(:).';
            % Номера свободных DL-тиков (с нуля).
            obj.availableDlTicks=reshape(find(~mask)-1,1,[]);
            % Префиксные суммы свободных тиков.
            obj.availableDlPrefix=[0 cumsum(~mask)];
        end
        %RESERVENPRACH Резервирует все возможности NPRACH на горизонт (период 80 мс, 6 тиков, 45 кГц UL).
        %   NPRACH входит в квоту RA; если не помещается — ошибка конфигурации.
        function occasions=reserveNprach(obj)
            % Уже зарезервированы — возвращаем их.
            if ~isempty(obj.occasions), occasions=obj.occasions; return; end
            % Пустой список возможностей и планов.
            occasions=struct('occasionId',{},'startTick',{},'endTick',{},'grantId',{}); plans=[];
            % Для каждого периода: начало возможности = сдвиг + k·период (до горизонта − 6):
            for t=obj.cfg.ra.startOffsetTicks:obj.cfg.ra.periodTicks:obj.cfg.simulation.durationTicks-6
                % назначение NPRACH: фаза RA, UL, 6 тиков, первые 45 кГц;
                g=obj.grant('NPRACH','RA','UL',t:t+5,0,45000,0,0,0,struct());
                % план для календаря добавляется в список;
                p=obj.plan(g); if isempty(plans), plans=p; else, plans(end+1)=p; end
                % возможность: номер, начало, конец (начало + 6), номер назначения.
                occasions(end+1)=struct('occasionId',numel(occasions)+1,'startTick',t,'endTick',t+6,'grantId',g.grantId);
            end
            % Резервируем все возможности одной транзакцией; если не помещаются в квоту RA — ошибка.
            assert(obj.calendar.reserveTransaction(plans),'nbiot:NprachQuota','NPRACH exceeds the fixed RA budget.');
            % Запоминаем возможности.
            obj.occasions=occasions;
        end
        %APPLYSHAREFROM Передаёт смену доли RA календарю (Adaptive-RA/DT).
        function applied=applyShareFrom(obj,effectiveTick,raShare)
            % Новая доля RA применяется календарём (с проверкой уже выданных назначений).
            applied=obj.calendar.applyShareFrom(effectiveTick,raShare);
        end
        %REFERENCESCALENDAR Использует ли планировщик этот календарь (проверка целостности).
        function matches=referencesCalendar(obj,calendar)
            % Сравнение ссылок на объект.
            matches=(obj.calendar==calendar);
        end
        %UPLINK Назначение UL-данных: DCI N0 на NPDCCH + NPUSCH (KIND 'Data', фаза PHASE) в окне
        %   [EARLIESTTICK, DEADLINETICK]. Перебор: кандидаты NPDCCH, задержка k0 (0..3), группа 3 тонов.
        %   Возвращает struct с controlGrant, payloadGrant и DCI или [] — ресурса нет.
        function schedule=uplink(obj,kind,phase,earliestTick,deadlineTick,rnti,ndi,rv)
            % Пока не найдено; начинать не раньше, чем UE освободится от прошлых назначений.
            schedule=[]; earliestTick=max(earliestTick,obj.contextAvailable(rnti));
            % Перебор периодов поиска NPDCCH (каждые 32 мс) до дедлайна и горизонта:
            for base=ceil(earliestTick/32)*32:32:min(deadlineTick,obj.cfg.simulation.durationTicks)-1
                % кандидатные DL-подкадры периода; нужно минимум 2 (2 повтора NPDCCH);
                mt=obj.calendar.monitoringTicks(base); if numel(mt)<2, continue; end
                % назначение NPDCCH: 2 подкадра, весь DL, DCI N0 с NDI и RV;
                control=obj.grant('NPDCCH',phase,'DL',mt(1:2),0,180000,rnti,ndi,rv,struct('format','N0','repetitions',2));
                % перебор задержки k0 (индекс 0..3):
                for delay=0:3
                    % перебор группы из 3 поднесущих (I_sc 12..15):
                    for group=0:3
                        % поля DCI N0: 3 поднесущие группы, I_RU 3 (4 RU), задержка, MCS 4, RV, 1 повтор DCI, NDI;
                        dci=struct('format','N0','subcarrierIndication',12+group,'resourceAssignment',3,'schedulingDelay',delay,'mcs',4,'rv',double(rv==2),'repetitionNumber',1,'ndi',ndi,'dciRepetitions',1);
                        % назначение NPUSCH по этим полям (как его восстановит UE); тип, фаза, номер назначения;
                        payload=obj.reconstructUplink(dci,control.ticks,rnti); payload.kind=char(kind); payload.phase=char(phase); payload.grantId=obj.allocateId();
                        % не успевает до дедлайна или горизонта — следующий вариант;
                        if payload.endTick>deadlineTick || payload.endTick>obj.cfg.simulation.durationTicks, continue; end
                        % планы: NPDCCH + NPUSCH;
                        plans=[obj.plan(control) obj.plan(payload)];
                        % если оба помещаются (ячейки свободны и квоты соблюдены) —
                        if obj.calendar.reserveTransaction(plans)
                            % назначение готово;
                            schedule=struct('controlGrant',control,'payloadGrant',payload,'ackGrant',[],'msg3Grant',[],'dci',dci);
                            % UE занят до конца передачи + 3 тика; выходим.
                            obj.busyUntil(double(rnti))=payload.endTick+3; return;
                        end
                    end
                end
            end
        end
        %DOWNLINK Назначение DL: DCI N1 + NPDSCH (RAR, Msg4, receipt) + зависимый UL-ресурс:
        %   для RAR — Msg3 (выдача RAR без ресурса Msg3 запрещена), иначе — ACK от UE.
        %   Возвращает schedule или [] — ресурса в квоте нет.
        function schedule=downlink(obj,kind,phase,earliestTick,deadlineTick,rnti)
            % Пока не найдено; учитываем занятость UE; это RAR?
            schedule=[]; earliestTick=max(earliestTick,obj.contextAvailable(rnti)); rar=strcmpi(kind,'RAR');
            % Перебор периодов поиска NPDCCH:
            for base=ceil(earliestTick/32)*32:32:min(deadlineTick,obj.cfg.simulation.durationTicks)-1
                % кандидатные подкадры; нужно минимум 2;
                mt=obj.calendar.monitoringTicks(base); if numel(mt)<2, continue; end
                % назначение NPDCCH с DCI N1;
                control=obj.grant('NPDCCH',phase,'DL',mt(1:2),0,180000,rnti,0,0,struct('format','N1','repetitions',2));
                % перебор задержки NPDSCH (индекс 0..7):
                for delay=0:7
                    % перебор ресурса ACK (индекс 0..15):
                    for ackIndex=0:15
                        % поля DCI N1: задержка, 1 подкадр, MCS 6, 1 повтор, NDI 0, ресурс ACK;
                        dci=struct('format','N1','order',0,'schedulingDelay',delay,'resourceAssignment',0,'mcs',6,'repetitionNumber',1,'ndi',0,'ackResource',ackIndex,'dciRepetitions',1);
                        % назначение NPDSCH по этим полям (только свободные DL-подкадры); нет — дальше;
                        payload=obj.reconstructDownlink(dci,control.ticks,rnti); if isempty(payload), continue; end
                        % тип, фаза, номер назначения;
                        payload.kind=char(kind); payload.phase=char(phase); payload.grantId=obj.allocateId();
                        % результат должен быть готов до дедлайна;
                        if payload.endTick+obj.cfg.phy.processingTicks+1>deadlineTick, continue; end
                        % планы: NPDCCH + NPDSCH;
                        ack=[]; msg3=[]; plans=[obj.plan(control) obj.plan(payload)];
                        % Msg3: 3 тона 15 кГц (I_sc 12), индекс MCS 2 → NRU 1, задержка k0 = 12 подкадров.
                        if rar
                            % UL grant Msg3 в RAR: 15 кГц, I_sc 12, задержка 0, 1 повтор, индекс 2;
                            fields=struct('subcarrierSpacing',1,'subcarrierIndication',12,'schedulingDelay',0,'repetitionNumber',1,'mcs',2);
                            % назначение Msg3 по UL grant (как восстановит UE); фаза, RNTI, номер;
                            msg3=obj.reconstructMsg3(fields,payload.ticks); msg3.phase=char(phase); msg3.rnti=rnti; msg3.grantId=obj.allocateId();
                            % план Msg3; конец всей транзакции — конец Msg3;
                            plans(end+1)=obj.plan(msg3); finish=msg3.endTick;
                        else
                            % иначе — ресурс ACK от UE по полю DCI N1;
                            ack=obj.reconstructAck(dci,payload,rnti); ack.phase=char(phase); ack.grantId=obj.allocateId();
                            % план ACK; конец транзакции — конец ACK;
                            plans(end+1)=obj.plan(ack); finish=ack.endTick;
                        end
                        % транзакция должна закончиться до горизонта;
                        if finish>obj.cfg.simulation.durationTicks, continue; end
                        % если все планы помещаются —
                        if obj.calendar.reserveTransaction(plans)
                            % назначение готово;
                            schedule=struct('controlGrant',control,'payloadGrant',payload,'ackGrant',ack,'msg3Grant',msg3,'dci',dci);
                            % для RAR сохраняем поля UL grant (их запишут в сообщение RAR);
                            if rar, schedule.rarGrant=fields; end
                            % UE занят до конца транзакции + 3 тика; выходим.
                            obj.busyUntil(double(rnti))=finish+3; return;
                        end
                        % для RAR ресурс ACK не перебирается (его нет) — следующая задержка.
                        if rar, break; end
                    end
                end
            end
        end
        %RECONSTRUCTUPLINK Назначение NPUSCH из DCI N0 (TS 36.213 §16.5.1): тоны, NRU, повторы, TBS, начало
        %   = конец NPDCCH + k0. Вне профиля static-v1 — ошибка nbiot:UnsupportedGrant.
        function g=reconstructUplink(obj,dci,controlTicks,rnti)
            % Поддерживается только набор полей профиля static-v1, иначе nbiot:UnsupportedGrant.
            assert(strcmpi(dci.format,'N0') && dci.mcs==4 && dci.resourceAssignment==3 && dci.repetitionNumber==1 && ismember(dci.subcarrierIndication,12:15),'nbiot:UnsupportedGrant','N0 is outside static-v1.');
            % Профиль данных.
            p=nbiot.phy.ProfileTables.profile('data');
            % Число RU по полю DCI.
            p.nru=nbiot.phy.ProfileTables.resourceUnits(dci.resourceAssignment);
            % Число повторов, MCS, I_RU.
            p.repetitions=nbiot.phy.ProfileTables.ulRepetitions(dci.repetitionNumber); p.mcs=dci.mcs; p.iru=dci.resourceAssignment;
            % Поднесущие по полю I_sc и их число.
            tones=nbiot.phy.ProfileTables.decodeUlAssignment(dci.subcarrierIndication); p.numSubcarriers=numel(tones);
            % TBS по таблице 3GPP.
            p.tbs=nbiot.phy.ProfileTables.ulTbs(p.mcs,p.iru,p.numSubcarriers);
            % Длительность в тиках: RU × слотов × 0,5 мс × повторы.
            duration=p.nru*p.nulSlots*0.5*p.repetitions; p.durationTicks=duration;
            % Начало: тик после конца NPDCCH + задержка k0 (TS 36.213 §16.5.1).
            start=max(controlTicks)+1+nbiot.phy.ProfileTables.n0Delay(dci.schedulingDelay);
            % Назначение UL-данных: тики, частота и полоса (Гц), RNTI, NDI, RV (0 или 2).
            g=obj.publicGrant('Data','DT','UL',start:start+duration-1,min(tones)*15000,numel(tones)*15000,rnti,dci.ndi,2*dci.rv,p);
        end
        %RECONSTRUCTDOWNLINK Назначение NPDSCH из DCI N1 (TS 36.213 §16.4.1): начало через 5 подкадров после
        %   NPDCCH + задержка, только по доступным (не обязательным) DL-подкадрам.
        function g=reconstructDownlink(obj,dci,controlTicks,rnti)
            % Поддерживается только набор полей профиля static-v1.
            assert(strcmpi(dci.format,'N1') && dci.order==0 && dci.mcs==6 && dci.resourceAssignment==0 && dci.repetitionNumber==1,'nbiot:UnsupportedGrant','N1 is outside static-v1.');
            % Профиль NPDSCH.
            p=nbiot.phy.ProfileTables.profile('downlink');
            % MCS и число подкадров.
            p.mcs=dci.mcs; p.nsf=nbiot.phy.ProfileTables.dlSubframes(dci.resourceAssignment);
            % Повторы и TBS.
            p.repetitions=nbiot.phy.ProfileTables.dlRepetitions(dci.repetitionNumber); p.tbs=nbiot.phy.ProfileTables.dlTbs(p.mcs,dci.resourceAssignment);
            % Задержка после NPDCCH и число подкадров с повторами.
            offset=nbiot.phy.ProfileTables.n1Delay(dci.schedulingDelay,4); count=p.nsf*p.repetitions;
            % Первый возможный подкадр: через 5 подкадров после конца NPDCCH.
            first=max(controlTicks)+5;
            % За горизонтом — назначения нет.
            if first>=obj.cfg.simulation.durationTicks, g=[]; return; end
            % Номер первого свободного DL-подкадра начиная с этого тика.
            at=obj.availableDlPrefix(first+1)+1;
            % Не хватает свободных подкадров до горизонта — назначения нет.
            if at+offset+count-1>numel(obj.availableDlTicks), g=[]; return; end
            % Тики NPDSCH: свободные подкадры после задержки; длительность от первого до последнего.
            ticks=obj.availableDlTicks(at+offset+(0:count-1)); p.durationTicks=ticks(end)+1-ticks(1);
            % Назначение NPDSCH: весь DL, RNTI, NDI.
            g=obj.publicGrant('NPDSCH','DT','DL',ticks,0,180000,rnti,dci.ndi,0,p);
        end
        %RECONSTRUCTMSG3 Назначение Msg3 из UL grant в RAR (TS 36.213 §16.3.3).
        function g=reconstructMsg3(obj,rar,payloadTicks)
            % UL grant мог прийти внутри struct RAR.
            if isfield(rar,'ulGrant'), rar=rar.ulGrant; end
            % Поддерживается только набор полей профиля static-v1.
            assert(rar.subcarrierSpacing==1 && rar.mcs==2 && rar.repetitionNumber==1 && ismember(rar.subcarrierIndication,12:15),'nbiot:UnsupportedGrant','RAR is outside static-v1.');
            % Профиль Msg3 по индексу из RAR; поднесущие по I_sc.
            p=nbiot.phy.ProfileTables.msg3Profile(rar.mcs); tones=nbiot.phy.ProfileTables.decodeUlAssignment(rar.subcarrierIndication);
            % Число поднесущих.
            p.numSubcarriers=numel(tones);
            % Повторы и длительность в тиках.
            p.repetitions=nbiot.phy.ProfileTables.ulRepetitions(rar.repetitionNumber); p.durationTicks=p.nru*p.nulSlots*0.5*p.repetitions;
            % Начало: тик после конца RAR + задержка (TS 36.213 §16.3.3).
            start=max(payloadTicks)+1+nbiot.phy.ProfileTables.rarDelay(rar.schedulingDelay);
            % Назначение Msg3 (фаза RA).
            g=obj.publicGrant('Msg3','RA','UL',start:start+p.durationTicks-1,min(tones)*15000,numel(tones)*15000,0,0,0,p);
        end
        %RECONSTRUCTACK Ресурс ACK/NACK (NPUSCH формат 2) по полю ACK-ресурса DCI N1.
        function g=reconstructAck(obj,dci,payload,rnti)
            % Поднесущая и задержка k0 ACK по полю DCI; профиль ACK.
            [tone,k0]=nbiot.phy.ProfileTables.ackResource(dci.ackResource); p=nbiot.phy.ProfileTables.profile('ack');
            % TS 36.213 section 16.4.2: end of subframe n+k0-1.
            % payload.endTick is the end of final subframe n (n+1).
            start=payload.endTick+k0-1;
            % Назначение ACK: 1 поднесущая 15 кГц.
            g=obj.publicGrant('ACK','DT','UL',start:start+p.durationTicks-1,tone*15000,15000,rnti,0,0,p);
        end
    end
    methods (Access=private)
        %CONTEXTAVAILABLE Первый тик, когда UE с RNTI свободен от ранее выданных назначений.
        function tick=contextAvailable(obj,rnti)
            % Тик, до которого UE занят (0, если не занят).
            if isKey(obj.busyUntil,double(rnti)), tick=obj.busyUntil(double(rnti)); else, tick=0; end
        end
        %GRANT Назначение с новым номером.
        function g=grant(obj,varargin)
            % Struct назначения и следующий номер.
            g=obj.publicGrant(varargin{:}); g.grantId=obj.allocateId();
        end
        %ALLOCATEID Следующий уникальный номер назначения.
        function id=allocateId(obj)
            % Текущий номер и увеличение счётчика.
            id=obj.nextId; obj.nextId=obj.nextId+1;
        end
    end
    methods (Static,Access=private)
        %PUBLICGRANT Struct назначения: тип, фаза RA/DT, направление, тики, частота и полоса (Гц), RNTI, NDI, RV, профиль.
        function g=publicGrant(kind,phase,direction,ticks,frequency,bandwidth,rnti,ndi,rv,profile)
            % Struct назначения: номер, тип, фаза, направление, начало/конец (конец не включён), тики, частота, полоса, RNTI, NDI, RV, профиль.
            g=struct('grantId',0,'kind',char(kind),'phase',char(phase),'direction',char(direction),'startTick',min(ticks),'endTick',max(ticks)+1,'ticks',ticks,'frequencyStartHz',frequency,'bandwidthHz',bandwidth,'rnti',rnti,'ndi',ndi,'rv',rv,'profile',profile);
        end
        %PLAN Проекция назначения на календарь (направление, фаза, тики, частоты).
        function p=plan(g)
            % Проекция назначения для календаря.
            p=struct('direction',g.direction,'phase',g.phase,'ticks',g.ticks,'frequencyStartHz',g.frequencyStartHz,'bandwidthHz',g.bandwidthHz,'grantId',g.grantId);
        end
    end
end
