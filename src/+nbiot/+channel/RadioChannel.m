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
        ue
        sources
        % Все переданные сигналы (struct: waveform, startSample, direction, ueId, ...).
        transmissions = {}
        % LRU-кэш уже распространённых DL-сигналов на приёмник (до 128 МБ).
        cache
        cacheOrder = {}
        cacheBytes = 0
        cacheLimitBytes = 128*1024*1024
    end
    methods
        %RADIOCHANNEL Создаёт канал для сценария SCENARIO.
        function obj=RadioChannel(cfg,scenario,sources)
            obj.cfg=cfg; obj.ue=scenario.ue; obj.sources=sources;
            obj.cache=containers.Map('KeyType','char','ValueType','any');
            assert(cfg.simulation.sampleRateHz==1920000,'nbiot:ChannelRate','Expected 1.92 MHz.');
        end
        function matches=referencesSources(obj,sources)
            matches=isequal(obj.sources,sources);
        end
        %ADD Регистрирует передачу TX. Мощность нормируется на активную часть сигнала до txPowerDbm.
        function add(obj,tx)
            assert(tx.sampleRateHz==obj.cfg.simulation.sampleRateHz);
            assert(tx.startSample==fix(tx.startSample));
            if ~isfield(tx,'powerNormalized') || ~tx.powerNormalized
                tx.waveform=nbiot.channel.normalizePower(tx.waveform,tx.activeRanges,tx.txPowerDbm);
                tx.powerNormalized=true;
            else
                % The flag promises a physical-W column waveform already scaled
                % to txPowerDbm. MATLAB copy-on-write preserves shared templates.
                assert(isa(tx.waveform,'double') && iscolumn(tx.waveform));
            end
            obj.transmissions{end+1}=tx;
        end
        %RECEIVE Принятый сигнал в окне отсчётов [STARTSAMPLE, ENDSAMPLE) направления DIRECTION.
        %   RX.waveform — комплексный столбец (В, мощность в Вт). DIAGNOSTICS (только UL) — мощности
        %   компонент NPRACH, помехи и перекрытия попыток: для анализа коллизий/capture (ТЗ §15–16),
        %   на решение приёмника не влияют.
        function [rx,diagnostics]=receive(obj,direction,receiverId,startSample,endSample)
            d=obj.directionCode(direction); fs=obj.cfg.simulation.sampleRateHz;
            assert(startSample>=0 && endSample>=startSample && all([startSample endSample]==fix([startSample endSample])));
            assert((d==0 && receiverId==0) || (d==1 && any([obj.ue.ueId]==receiverId)));
            y=complex(zeros(endSample-startSample,1));
            collectDiagnostics=nargout>1 && d==0;
            componentSignals=struct('occasionId',{},'attemptId',{},'ueId',{}, ...
                'nInit',{},'startSample',{},'endSampleExclusive',{}, ...
                'configuredDelaySeconds',{},'configuredCfoHz',{},'waveform',{});
            % Перебор всех хранимых передач того же направления, попадающих в окно.
            % Замечание о скорости: UL-сигналы не кэшируются и пересчитываются (свёртка) при каждом приёме.
            for i=1:numel(obj.transmissions)
                tx=obj.transmissions{i}; if obj.directionCode(tx.direction)~=d, continue; end
                [delay,~,cfo,~]=obj.pathParameters(tx,d,receiverId);
                pathSamples=(delay+obj.cfg.channel.tapDelaysSeconds(:))*fs;
                half=(obj.cfg.channel.fractionalFilterLength-1)/2;
                first=tx.startSample+min(floor(pathSamples))-half;
                last=tx.startSample+numel(tx.waveform)+max(floor(pathSamples))+half;
                if first>=endSample || last<=startSample, continue; end
                key=sprintf('%d/%d',i,receiverId);
                if d==1 && isKey(obj.cache,key)
                    signal=obj.cache(key); obj.cacheOrder(strcmp(obj.cacheOrder,key))=[]; obj.cacheOrder{end+1}=key;
                else
                    signal=obj.propagate(tx,d,receiverId);
                    if d==1, obj.cacheSignal(key,signal); end
                end
                % Сложение сигнала в пересечение окна приёма и окна сигнала (ТЗ §14 п.8).
                a=max(startSample,signal.startSample); b=min(endSample,signal.startSample+numel(signal.waveform));
                if b>a
                    waveform=signal.waveform(a-signal.startSample+1:b-signal.startSample);
                    y(a-startSample+1:b-startSample)=y(a-startSample+1:b-startSample)+waveform;
                    if collectDiagnostics && isfield(tx,'kind') && strcmpi(tx.kind,'nprach') && ...
                            all(isfield(tx,{'attemptId','occasionId','nInit'}))
                        componentSignals(end+1)=struct('occasionId',double(tx.occasionId), ...
                            'attemptId',double(tx.attemptId),'ueId',double(tx.ueId), ...
                            'nInit',double(tx.nInit),'startSample',double(a), ...
                            'endSampleExclusive',double(b), ...
                            'configuredDelaySeconds',double(delay), ...
                            'configuredCfoHz',double(cfo),'waveform',waveform); %#ok<AGROW>
                    end
                end
            end
            if nargout>1
                diagnostics=struct('components',struct([]),'overlaps',struct([]));
                if collectDiagnostics
                    nf=obj.cfg.channel.bsNoiseFigureDb;
                    % Шум в полосе NPRACH 45 кГц — только для диагностического SINR.
                    noisePowerW=1.380649e-23*obj.cfg.channel.temperatureK* ...
                        10^(nf/10)*45000;
                    diagnosticComponents=repmat(struct('occasionId',0,'attemptId',0, ...
                        'ueId',0,'nInit',0,'startSample',0,'endSampleExclusive',0, ...
                        'signalPowerW',0,'interferencePowerW',0,'noisePowerW',0, ...
                        'configuredDelaySeconds',0,'configuredCfoHz',0),0,1);
                    diagnosticOverlaps=repmat(struct('occasionId',0,'attemptIdA',0, ...
                        'attemptIdB',0,'startSample',0,'endSampleExclusive',0, ...
                        'signalPowerAW',0,'signalPowerBW',0),0,1);
                    for k=1:numel(componentSignals)
                        c=componentSignals(k);
                        first=c.startSample-startSample+1;
                        last=c.endSampleExclusive-startSample;
                        interference=y(first:last)-c.waveform;
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
                    for i=1:numel(componentSignals)-1
                        firstComponent=componentSignals(i);
                        for j=i+1:numel(componentSignals)
                            secondComponent=componentSignals(j);
                            if firstComponent.occasionId~=secondComponent.occasionId, continue; end
                            overlapStart=max(firstComponent.startSample,secondComponent.startSample);
                            overlapEnd=min(firstComponent.endSampleExclusive, ...
                                secondComponent.endSampleExclusive);
                            if overlapEnd<=overlapStart, continue; end
                            firstSamples=overlapStart-firstComponent.startSample+1: ...
                                overlapEnd-firstComponent.startSample;
                            secondSamples=overlapStart-secondComponent.startSample+1: ...
                                overlapEnd-secondComponent.startSample;
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
                    diagnostics=struct('components',diagnosticComponents, ...
                        'overlaps',diagnosticOverlaps);
                end
            end
            % Тепловой шум приёмника: σ² = k·T·10^(NF/10)·fs (на комплексную компоненту — половина).
            if d==0, nf=obj.cfg.channel.bsNoiseFigureDb; else, nf=obj.cfg.channel.ueNoiseFigureDb; end
            sigma=sqrt(1.380649e-23*obj.cfg.channel.temperatureK*10^(nf/10)*fs/2);
            % Шум генерируется блоками по 1 мс с адресацией по номеру блока: одинаковый отсчёт шума
            % при любом окне запроса, независимо от порядка вызовов.
            blockLength=round(fs/1000);
            if endSample>startSample
                for block=floor(startSample/blockLength):floor((endSample-1)/blockLength)
                    stream=obj.sources.stream('noise',d,receiverId,block);
                    noise=sigma*(randn(stream,blockLength,1)+1i*randn(stream,blockLength,1));
                    a=max(startSample,block*blockLength); b=min(endSample,(block+1)*blockLength);
                    y(a-startSample+1:b-startSample)=y(a-startSample+1:b-startSample)+noise(a-block*blockLength+1:b-block*blockLength);
                end
            end
            rx=struct('waveform',y,'sampleRateHz',fs,'startSample',startSample);
        end
        %DISCARDBEFORE Удаляет передачи, которые не могут попасть в окна после отсчёта SAMPLE.
        function discardBefore(obj,sample)
            % Retain the complete FIR tail, including all possible UE delays.
            fs=obj.cfg.simulation.sampleRateHz;
            maximum=ceil((2*max([obj.ue.distanceM])/299792458+obj.cfg.channel.syncLimitSeconds+max(obj.cfg.channel.tapDelaysSeconds))*fs)+obj.cfg.channel.fractionalFilterLength;
            keep=cellfun(@(t)t.startSample+numel(t.waveform)+maximum>=sample,obj.transmissions);
            if any(~keep)
                obj.transmissions=obj.transmissions(keep); obj.cache=containers.Map('KeyType','char','ValueType','any'); obj.cacheOrder={}; obj.cacheBytes=0;
            end
        end
    end
    methods (Access=private)
        %PROPAGATE Применяет канал к передаче: импульсная характеристика из отводов с дробными
        %   задержками (windowed sinc), потери в дБ, затем поворот фазы на CFO по абсолютному времени.
        function signal=propagate(obj,tx,d,receiverId)
            [delay,taps,cfo,u]=obj.pathParameters(tx,d,receiverId); fs=obj.cfg.simulation.sampleRateHz;
            L=obj.cfg.channel.fractionalFilterLength; half=(L-1)/2;
            delays=(delay+obj.cfg.channel.tapDelaysSeconds(:))*fs; integers=floor(delays); base=min(integers)-half;
            h=complex(zeros(max(integers)-min(integers)+L,1));
            for k=1:numel(taps)
                [~,~,kernel]=nbiot.channel.fractionalDelay([],delays(k),L);
                idx=integers(k)-min(integers)+(1:L); h(idx)=h(idx)+taps(k)*kernel;
            end
            y=conv(tx.waveform,h)*10^(-u.pathLossDb/20); first=tx.startSample+base;
            y=y.*exp(1i*2*pi*cfo*((first+(0:numel(y)-1)')/fs));
            signal=struct('waveform',y,'startSample',first);
        end
        %PATHPARAMETERS Задержка (с), отводы fading, CFO (Гц) и параметры UE для пути передачи.
        function [delay,taps,cfo,u]=pathParameters(obj,tx,d,receiverId)
            if d==0, id=tx.ueId; else, id=receiverId; end
            u=obj.ue(find([obj.ue.ueId]==id,1));
            if d==0
                delay=2*u.distanceM/299792458+u.syncOffsetSeconds;
                if isfield(tx,'timingAdvanceSeconds'), delay=delay-tx.timingAdvanceSeconds; end
                taps=u.tapsUl; cfo=u.cfoHz;
            else
                delay=u.distanceM/299792458; taps=u.tapsDl; cfo=-u.cfoHz;
            end
        end
        %CACHESIGNAL Добавляет DL-сигнал в LRU-кэш с вытеснением старых при превышении лимита.
        function cacheSignal(obj,key,signal)
            bytes=16*numel(signal.waveform);
            if bytes>obj.cacheLimitBytes, return; end
            while obj.cacheBytes+bytes>obj.cacheLimitBytes && ~isempty(obj.cacheOrder)
                oldest=obj.cacheOrder{1}; old=obj.cache(oldest);
                obj.cacheBytes=obj.cacheBytes-16*numel(old.waveform); remove(obj.cache,oldest); obj.cacheOrder(1)=[];
            end
            obj.cache(key)=signal; obj.cacheOrder{end+1}=key; obj.cacheBytes=obj.cacheBytes+bytes;
        end
    end
    methods (Static,Access=private)
        %DIRECTIONCODE 'UL' → 0, 'DL' → 1.
        function d=directionCode(direction)
            if isnumeric(direction), d=double(direction); else, d=find(strcmpi(char(direction),{'UL','DL'}),1)-1; end
            assert(isscalar(d) && any(d==[0 1]),'nbiot:Direction','Expected UL or DL.');
        end
    end
end
