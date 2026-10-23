% ТЗ §42–43, §63: воспроизводимость и идентичность внешних реализаций.
classdef RandomSources
    %RANDOMSOURCES Именованные независимые потоки случайности одной внешней реализации.
    %   Генератор mrg32k3a: поток = номер реализации (realizationId+1 из 4096), подпоток = ключ
    %   (источник, направление, получатель, блок времени) — см. nbiot.randomness.substreamKey.
    %   Поэтому значение для конкретного UE/события не зависит от того, сколько чисел взяли другие
    %   модули, и смена политики управления не сдвигает внешние воздействия.
    %
    %   Источники: layout, traffic, shadowing, channel, CFO, timing, noise, payload — внешние
    %   (одинаковы для всех политик); access, backoff, token — решения UE (зависят от политики).
    %
    %   Пример: s = sources.stream('CFO', 0, ueId, 0); cfo = randn(s);
    properties (SetAccess=private)
        % Главный seed (ТЗ §30: 42) и номер внешней реализации.
        masterSeed
        realizationId
    end
    methods
        %RANDOMSOURCES Создаёт набор потоков для (MASTERSEED, REALIZATIONID).
        function obj=RandomSources(masterSeed,realizationId)
            validateattributes(masterSeed,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
            validateattributes(realizationId,{'numeric'},{'scalar','integer','>=',0,'<=',4095});
            obj.masterSeed=double(masterSeed); obj.realizationId=double(realizationId);
        end
        %STREAM Новый RandStream для источника NAME и ключа (DIRECTION 0=UL/1=DL, RECEIVERID, BLOCKID).
        %   Каждый вызов создаёт поток заново и устанавливает подпоток — повторный вызов с тем же ключом
        %   возвращает ту же последовательность.
        function s=stream(obj,name,direction,receiverId,blockId)
            key=nbiot.randomness.substreamKey(name,direction,receiverId,blockId);
            s=RandStream.create('mrg32k3a','NumStreams',4096,'StreamIndices',obj.realizationId+1,'Seed',obj.masterSeed);
            s.Substream=key;
        end
        %MANIFEST Описание схемы генерации для сохранения в результате (ТЗ §47).
        function m=manifest(obj)
            m=struct('algorithm','mrg32k3a','masterSeed',obj.masterSeed,'externalRealizationId',obj.realizationId,'numStreams',4096,'streamIndex',obj.realizationId+1,'sourceNames',{{'layout','traffic','shadowing','channel','CFO','timing','noise','payload','access','backoff','token'}},'sourceCodes',1:11,'keyFormula','1+blockId+2^24*(receiverId+2^16*(direction+2*sourceCode))','directionCodes',[0 1],'staticBlockId',0);
        end
    end
end
