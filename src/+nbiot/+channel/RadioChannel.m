classdef RadioChannel < handle
    %RADIOCHANNEL Радиоканал на уровне отсчётов (ТЗ §13, §14 п.4–9, §17), FDD: UL и DL раздельно.
    %   Хранит все переданные waveform (add) и по запросу формирует принятый сигнал в окне
    %   отсчётов (receive): для каждой передачи — потери (path loss + shadowing + penetration),
    %   многолучевой fading (отводы Rayleigh UE), задержка распространения и рассинхронизация
    %   (дробная задержка FIR), CFO; затем сумма всех одновременных сигналов + тепловой шум.
    %   Окно приёма не содержит сведений о передатчиках — только сигнал (приёмник «слепой»).
    %
    %   UL: приёмник BS (receiverId = 0), задержка туда-обратно 2d/c + рассинхрон − TA, CFO = +cfo UE.
    %   DL: приёмник — UE receiverId, задержка d/c, CFO = −cfo UE. Шум: k·T·F·fs, независимые
    %   блоки по 1 мс из потока 'noise' (ключ: направление, приёмник, блок).
    properties (Access=private)
        % cfg — конфигурация; ue — параметры UE из сценария; sources — потоки случайности.
        cfg
        % Параметры UE из сценария: расстояния, потери, CFO, рассинхрон, отводы fading.
        ue
        % Потоки случайности (для шума приёмника).
        sources
        % Все переданные сигналы (struct: waveform, startSample, direction, ueId, ...).
        transmissions = {}
        % LRU-кэш уже распространённых DL-сигналов на приёмник (до 128 МБ).
        cache
        % Порядок использования ключей кэша (для вытеснения самых старых).
        cacheOrder = {}
        % Текущий объём кэша в байтах.
        cacheBytes = 0
        % Предел кэша — 128 МБ.
        cacheLimitBytes = 128*1024*1024
    end
    methods
        %RADIOCHANNEL Создаёт канал для сценария SCENARIO.
        function obj=RadioChannel(cfg,scenario,sources)
            % Сохраняем конфигурацию, UE сценария и потоки случайности.
            obj.cfg=cfg; obj.ue=scenario.ue; obj.sources=sources;
            % Пустой кэш DL-сигналов: ключ «передача/приёмник» → распространённый сигнал.
            obj.cache=containers.Map('KeyType','char','ValueType','any');
            % Канал рассчитан на частоту отсчётов 1,92 МГц.
            assert(cfg.simulation.sampleRateHz==1920000,'nbiot:ChannelRate','Expected 1.92 MHz.');
        end
        %REFERENCESSOURCES Использует ли канал те же потоки случайности (проверка целостности).
        function matches=referencesSources(obj,sources)
            % Сравнение с переданными потоками.
            matches=isequal(obj.sources,sources);
        end
        %ADD Регистрирует передачу TX. Мощность нормируется на активную часть сигнала до txPowerDbm.
        function add(obj,tx)
            % Частота отсчётов передачи совпадает с частотой канала.
            assert(tx.sampleRateHz==obj.cfg.simulation.sampleRateHz);
            % Начальный отсчёт — целое число.
            assert(tx.startSample==fix(tx.startSample));
            % Если мощность ещё не приведена к физической —
            if ~isfield(tx,'powerNormalized') || ~tx.powerNormalized
                % масштабируем сигнал до мощности передачи (по активной части);
                tx.waveform=nbiot.channel.normalizePower(tx.waveform,tx.activeRanges,tx.txPowerDbm);
                % отмечаем, что мощность нормирована.
                tx.powerNormalized=true;
            else
                % The flag promises a physical-W column waveform already scaled
                % to txPowerDbm. MATLAB copy-on-write preserves shared templates.
                assert(isa(tx.waveform,'double') && iscolumn(tx.waveform));
            end
            % Сохраняем передачу в списке канала.
            obj.transmissions{end+1}=tx;
        end
        %RECEIVE Принятый сигнал в окне отсчётов [STARTSAMPLE, ENDSAMPLE) направления DIRECTION.
        %   RX.waveform — комплексный столбец (В, мощность в Вт). DIAGNOSTICS (только UL) — мощности
        %   компонент NPRACH, помехи и перекрытия попыток: для анализа коллизий/capture (ТЗ §15–16),
        %   на решение приёмника не влияют.
        function [rx,diagnostics]=receive(obj,direction,receiverId,startSample,endSample)
            % Код направления (0 — UL, 1 — DL) и частота отсчётов.
            d=obj.directionCode(direction); fs=obj.cfg.simulation.sampleRateHz;
            % Окно приёма — целые отсчёты, конец не раньше начала.
            assert(startSample>=0 && endSample>=startSample && all([startSample endSample]==fix([startSample endSample])));
            % UL принимает BS (приёмник 0); DL — конкретный UE из сценария.
            assert((d==0 && receiverId==0) || (d==1 && any([obj.ue.ueId]==receiverId)));
            % Принятый сигнал окна, сначала нули.
            y=complex(zeros(endSample-startSample,1));
            % Диагностику компонент собираем только для UL и только если её запросили.
            collectDiagnostics=nargout>1 && d==0;
            % Пустой список компонент NPRACH для диагностики.
            componentSignals=struct('occasionId',{},'attemptId',{},'ueId',{}, ...
                'nInit',{},'startSample',{},'endSampleExclusive',{}, ...
                'configuredDelaySeconds',{},'configuredCfoHz',{},'waveform',{});
            % Перебор всех хранимых передач того же направления, попадающих в окно.
            % Замечание о скорости: UL-сигналы не кэшируются и пересчитываются (свёртка) при каждом приёме.
            for i=1:numel(obj.transmissions)
                % Передача; передачи другого направления пропускаем.
                tx=obj.transmissions{i}; if obj.directionCode(tx.direction)~=d, continue; end
                % Задержка распространения и CFO для пути этой передачи к приёмнику.
                [delay,~,cfo,~]=obj.pathParameters(tx,d,receiverId);
                % Задержки отводов fading в отсчётах (задержка пути + задержка отвода).
                pathSamples=(delay+obj.cfg.channel.tapDelaysSeconds(:))*fs;
                % Половина длины фильтра дробной задержки.
                half=(obj.cfg.channel.fractionalFilterLength-1)/2;
                % Первый отсчёт, который может затронуть передача с учётом задержек и фильтра.
                first=tx.startSample+min(floor(pathSamples))-half;
                % Последний такой отсчёт.
                last=tx.startSample+numel(tx.waveform)+max(floor(pathSamples))+half;
                % Передача не пересекается с окном приёма — пропуск.
                if first>=endSample || last<=startSample, continue; end
                % Ключ кэша: номер передачи и приёмник.
                key=sprintf('%d/%d',i,receiverId);
                % Для DL сигнал этого приёмника уже распространён —
                if d==1 && isKey(obj.cache,key)
                    % берём из кэша и переносим ключ в конец очереди (недавно использован);
                    signal=obj.cache(key); obj.cacheOrder(strcmp(obj.cacheOrder,key))=[]; obj.cacheOrder{end+1}=key;
                else
                    % иначе применяем канал к передаче (потери, fading, задержка, CFO);
                    signal=obj.propagate(tx,d,receiverId);
                    % DL-результат кладём в кэш (UL не кэшируется).
                    if d==1, obj.cacheSignal(key,signal); end
                end
                % Сложение сигнала в пересечение окна приёма и окна сигнала (ТЗ §14 п.8).
                a=max(startSample,signal.startSample); b=min(endSample,signal.startSample+numel(signal.waveform));
                % Если пересечение с окном есть —
                if b>a
                    % часть распространённого сигнала, попадающая в окно;
                    waveform=signal.waveform(a-signal.startSample+1:b-signal.startSample);
                    % добавляем её к сумме принятого сигнала (суперпозиция всех UE, ТЗ §14 п.8);
                    y(a-startSample+1:b-startSample)=y(a-startSample+1:b-startSample)+waveform;
                    % для диагностики запоминаем компоненту каждой попытки NPRACH
                    if collectDiagnostics && isfield(tx,'kind') && strcmpi(tx.kind,'nprach') && ...
                            all(isfield(tx,{'attemptId','occasionId','nInit'}))
                        % (возможность, попытка, UE, NInit, интервал отсчётов, истинные задержка и CFO, сам сигнал).
                        componentSignals(end+1)=struct('occasionId',double(tx.occasionId), ...
                            'attemptId',double(tx.attemptId),'ueId',double(tx.ueId), ...
                            'nInit',double(tx.nInit),'startSample',double(a), ...
                            'endSampleExclusive',double(b), ...
                            'configuredDelaySeconds',double(delay), ...
                            'configuredCfoHz',double(cfo),'waveform',waveform); %#ok<AGROW>
                    end
                end
            end
            % Если запрошена диагностика —
            if nargout>1
                % пустая диагностика по умолчанию;
                diagnostics=struct('components',struct([]),'overlaps',struct([]));
                % для UL:
                if collectDiagnostics
                    % коэффициент шума BS;
                    nf=obj.cfg.channel.bsNoiseFigureDb;
                    % Шум в полосе NPRACH 45 кГц — только для диагностического SINR.
                    noisePowerW=1.380649e-23*obj.cfg.channel.temperatureK* ...
                        10^(nf/10)*45000;
                    % шаблон записи о компоненте (мощности сигнала, помехи, шума; истинные задержка и CFO);
                    diagnosticComponents=repmat(struct('occasionId',0,'attemptId',0, ...
                        'ueId',0,'nInit',0,'startSample',0,'endSampleExclusive',0, ...
                        'signalPowerW',0,'interferencePowerW',0,'noisePowerW',0, ...
                        'configuredDelaySeconds',0,'configuredCfoHz',0),0,1);
                    % шаблон записи о перекрытии двух попыток;
                    diagnosticOverlaps=repmat(struct('occasionId',0,'attemptIdA',0, ...
                        'attemptIdB',0,'startSample',0,'endSampleExclusive',0, ...
                        'signalPowerAW',0,'signalPowerBW',0),0,1);
                    % для каждой компоненты NPRACH:
                    for k=1:numel(componentSignals)
                        % компонента;
                        c=componentSignals(k);
                        % её первый отсчёт в окне приёма;
                        first=c.startSample-startSample+1;
                        % последний отсчёт;
                        last=c.endSampleExclusive-startSample;
                        % помеха = суммарный сигнал − сама компонента (без шума — он добавляется позже);
                        interference=y(first:last)-c.waveform;
                        % мощности сигнала и помехи, шум в полосе 45 кГц, истинные задержка и CFO.
                        diagnosticComponents(end+1)=struct( ...
                            'occasionId',c.occasionId,'attemptId',c.attemptId, ...
                            'ueId',c.ueId,'nInit',c.nInit, ...
                            'startSample',c.startSample, ...
                            'endSampleExclusive',c.endSampleExclusive, ...
                            'signalPowerW',mean(abs(c.waveform).^2), ...
                            'interferencePowerW',mean(abs(interference).^2), ...
                            'noisePowerW',noisePowerW, ...
                            'configuredDelaySeconds',c.configuredDelaySeconds, ...
                            'configuredCfoHz',c.configuredCfoHz); %#ok<AGROW>
                    end
                    % Для каждой пары компонент:
                    for i=1:numel(componentSignals)-1
                        % первая компонента;
                        firstComponent=componentSignals(i);
                        % перебор вторых;
                        for j=i+1:numel(componentSignals)
                            % вторая компонента;
                            secondComponent=componentSignals(j);
                            % разные возможности NPRACH не перекрываются по смыслу — пропуск;
                            if firstComponent.occasionId~=secondComponent.occasionId, continue; end
                            % начало общего интервала;
                            overlapStart=max(firstComponent.startSample,secondComponent.startSample);
                            % конец общего интервала;
                            overlapEnd=min(firstComponent.endSampleExclusive, ...
                                secondComponent.endSampleExclusive);
                            % интервал пустой — нет перекрытия;
                            if overlapEnd<=overlapStart, continue; end
                            % индексы общего интервала в первой компоненте;
                            firstSamples=overlapStart-firstComponent.startSample+1: ...
                                overlapEnd-firstComponent.startSample;
                            % и во второй;
                            secondSamples=overlapStart-secondComponent.startSample+1: ...
                                overlapEnd-secondComponent.startSample;
                            % запись о перекрытии: попытки и мощности обоих сигналов на общем интервале.
                            diagnosticOverlaps(end+1)=struct( ...
                                'occasionId',firstComponent.occasionId, ...
                                'attemptIdA',firstComponent.attemptId, ...
                                'attemptIdB',secondComponent.attemptId, ...
                                'startSample',double(overlapStart), ...
                                'endSampleExclusive',double(overlapEnd), ...
                                'signalPowerAW',mean(abs(firstComponent.waveform(firstSamples)).^2), ...
                                'signalPowerBW',mean(abs(secondComponent.waveform(secondSamples)).^2)); %#ok<AGROW>
                        end
                    end
                    % Итоговая диагностика.
                    diagnostics=struct('components',diagnosticComponents, ...
                        'overlaps',diagnosticOverlaps);
                end
            end
            % Тепловой шум приёмника: σ² = k·T·10^(NF/10)·fs (на комплексную компоненту — половина).
            if d==0, nf=obj.cfg.channel.bsNoiseFigureDb; else, nf=obj.cfg.channel.ueNoiseFigureDb; end
            % СКО шума на действительную/мнимую часть: σ² = k·T·10^(NF/10)·fs / 2 (Вт на отсчёт).
            sigma=sqrt(1.380649e-23*obj.cfg.channel.temperatureK*10^(nf/10)*fs/2);
            % Шум генерируется блоками по 1 мс с адресацией по номеру блока: одинаковый отсчёт шума
            % при любом окне запроса, независимо от порядка вызовов.
            blockLength=round(fs/1000);
            % Если окно непустое —
            if endSample>startSample
                % для каждого блока по 1 мс, задевающего окно:
                for block=floor(startSample/blockLength):floor((endSample-1)/blockLength)
                    % поток шума, адресованный (направление, приёмник, номер блока);
                    stream=obj.sources.stream('noise',d,receiverId,block);
                    % комплексный гауссов шум на весь блок;
                    noise=sigma*(randn(stream,blockLength,1)+1i*randn(stream,blockLength,1));
                    % пересечение блока с окном;
                    a=max(startSample,block*blockLength); b=min(endSample,(block+1)*blockLength);
                    % добавляем шум к соответствующей части принятого сигнала.
                    y(a-startSample+1:b-startSample)=y(a-startSample+1:b-startSample)+noise(a-block*blockLength+1:b-block*blockLength);
                end
            end
            % Принятый сигнал: отсчёты, частота, номер первого отсчёта.
            rx=struct('waveform',y,'sampleRateHz',fs,'startSample',startSample);
        end
        %DISCARDBEFORE Удаляет передачи, которые не могут попасть в окна после отсчёта SAMPLE.
        function discardBefore(obj,sample)
            % Retain the complete FIR tail, including all possible UE delays.
            fs=obj.cfg.simulation.sampleRateHz;
            % Максимальная задержка: туда-обратно до самого дальнего UE + рассинхрон + отвод + длина фильтра (в отсчётах).
            maximum=ceil((2*max([obj.ue.distanceM])/299792458+obj.cfg.channel.syncLimitSeconds+max(obj.cfg.channel.tapDelaysSeconds))*fs)+obj.cfg.channel.fractionalFilterLength;
            % Оставляем передачи, хвост которых ещё может попасть в окна после отсчёта SAMPLE.
            keep=cellfun(@(t)t.startSample+numel(t.waveform)+maximum>=sample,obj.transmissions);
            % Если что-то удаляется —
            if any(~keep)
                % сокращаем список и сбрасываем кэш (номера передач в ключах изменились).
                obj.transmissions=obj.transmissions(keep); obj.cache=containers.Map('KeyType','char','ValueType','any'); obj.cacheOrder={}; obj.cacheBytes=0;
            end
        end
    end
    methods (Access=private)
        %PROPAGATE Применяет канал к передаче: импульсная характеристика из отводов с дробными
        %   задержками (windowed sinc), потери в дБ, затем поворот фазы на CFO по абсолютному времени.
        function signal=propagate(obj,tx,d,receiverId)
            % Задержка, отводы, CFO и запись UE для пути; частота отсчётов.
            [delay,taps,cfo,u]=obj.pathParameters(tx,d,receiverId); fs=obj.cfg.simulation.sampleRateHz;
            % Длина фильтра дробной задержки и её половина.
            L=obj.cfg.channel.fractionalFilterLength; half=(L-1)/2;
            % Задержки отводов в отсчётах, их целые части и смещение начала итоговой импульсной характеристики.
            delays=(delay+obj.cfg.channel.tapDelaysSeconds(:))*fs; integers=floor(delays); base=min(integers)-half;
            % Импульсная характеристика канала (все отводы с дробными задержками).
            h=complex(zeros(max(integers)-min(integers)+L,1));
            % Для каждого отвода:
            for k=1:numel(taps)
                % ядро дробной задержки (windowed sinc);
                [~,~,kernel]=nbiot.channel.fractionalDelay([],delays(k),L);
                % добавляем ядро, умноженное на комплексный коэффициент отвода, в нужное место характеристики.
                idx=integers(k)-min(integers)+(1:L); h(idx)=h(idx)+taps(k)*kernel;
            end
            % Свёртка сигнала с характеристикой и ослабление на потери (дБ → амплитуда); новый первый отсчёт.
            y=conv(tx.waveform,h)*10^(-u.pathLossDb/20); first=tx.startSample+base;
            % Поворот фазы на CFO по абсолютному времени отсчёта.
            y=y.*exp(1i*2*pi*cfo*((first+(0:numel(y)-1)')/fs));
            % Распространённый сигнал и его начальный отсчёт.
            signal=struct('waveform',y,'startSample',first);
        end
        %PATHPARAMETERS Задержка (с), отводы fading, CFO (Гц) и параметры UE для пути передачи.
        function [delay,taps,cfo,u]=pathParameters(obj,tx,d,receiverId)
            % UE пути: для UL — передатчик, для DL — приёмник.
            if d==0, id=tx.ueId; else, id=receiverId; end
            % Запись этого UE в сценарии.
            u=obj.ue(find([obj.ue.ueId]==id,1));
            % UL:
            if d==0
                % задержка туда-обратно 2d/c (часы UE привязаны к принятому DL) + рассинхрон;
                delay=2*u.distanceM/299792458+u.syncOffsetSeconds;
                % минус timing advance, если UE его применил;
                if isfield(tx,'timingAdvanceSeconds'), delay=delay-tx.timingAdvanceSeconds; end
                % отводы UL и CFO UE.
                taps=u.tapsUl; cfo=u.cfoHz;
            else
                % DL: задержка d/c, отводы DL, CFO с обратным знаком (сдвиг относительно частоты UE).
                delay=u.distanceM/299792458; taps=u.tapsDl; cfo=-u.cfoHz;
            end
        end
        %CACHESIGNAL Добавляет DL-сигнал в LRU-кэш с вытеснением старых при превышении лимита.
        function cacheSignal(obj,key,signal)
            % Размер сигнала в байтах (complex double — 16 байт на отсчёт).
            bytes=16*numel(signal.waveform);
            % Сигнал больше всего кэша — не кэшируем.
            if bytes>obj.cacheLimitBytes, return; end
            % Пока не хватает места —
            while obj.cacheBytes+bytes>obj.cacheLimitBytes && ~isempty(obj.cacheOrder)
                % самый старый ключ и его сигнал;
                oldest=obj.cacheOrder{1}; old=obj.cache(oldest);
                % освобождаем место и удаляем из кэша и очереди.
                obj.cacheBytes=obj.cacheBytes-16*numel(old.waveform); remove(obj.cache,oldest); obj.cacheOrder(1)=[];
            end
            % Кладём сигнал в кэш, ключ — в конец очереди, учитываем объём.
            obj.cache(key)=signal; obj.cacheOrder{end+1}=key; obj.cacheBytes=obj.cacheBytes+bytes;
        end
    end
    methods (Static,Access=private)
        %DIRECTIONCODE 'UL' → 0, 'DL' → 1.
        function d=directionCode(direction)
            % Число как есть; строку 'UL'/'DL' переводим в 0/1.
            if isnumeric(direction), d=double(direction); else, d=find(strcmpi(char(direction),{'UL','DL'}),1)-1; end
            % Допустимы только 0 и 1.
            assert(isscalar(d) && any(d==[0 1]),'nbiot:Direction','Expected UL or DL.');
        end
    end
end
