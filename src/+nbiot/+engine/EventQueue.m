classdef EventQueue < handle
    %EVENTQUEUE Очередь отложенных событий завершения приёма (модель времени симулятора).
    %   Каждое событие: тик готовности, порядковый номер, тип ('nprach','monitor','dl_payload',
    %   'bs_ul') и данные. popReady(now) выдаёт все события с tick <= now в стабильном порядке
    %   (тик, затем порядок постановки) — это делает прогон детерминированным.
    properties (Access=private)
        % Массив событий: тик готовности, порядковый номер постановки, тип и данные.
        entries = struct('tick',{},'sequence',{},'kind',{},'payload',{})
        % Следующий порядковый номер (возрастает при каждой постановке).
        nextSequence = 1
    end
    methods
        %PUSH Добавляет событие KIND с данными PAYLOAD, готовое к тику TICK.
        function push(obj,tick,kind,payload)
            % Тик — неотрицательное конечное целое.
            validateattributes(tick,{'numeric'},{'scalar','integer','nonnegative','finite'});
            % Новое событие с текущим порядковым номером.
            e=struct('tick',double(tick),'sequence',obj.nextSequence,'kind',char(kind),'payload',payload);
            % Увеличиваем счётчик номеров и добавляем событие в конец массива.
            obj.nextSequence=obj.nextSequence+1; obj.entries(end+1)=e;
        end
        %POPREADY Извлекает готовые к тику NOW события, упорядоченные по (тик, номер).
        function ready=popReady(obj,now)
            % Выбираем события с тиком <= now, забираем их и удаляем из очереди.
            selected=[obj.entries.tick]<=now; ready=obj.entries(selected); obj.entries(selected)=[];
            % Если готовые события есть —
            if ~isempty(ready)
                % сортируем их по тику, затем по порядку постановки (стабильный детерминированный порядок).
                [~,order]=sortrows([[ready.tick].',[ready.sequence].'],[1 2]); ready=ready(order);
            end
        end
        %COUNT Число ожидающих событий; NEXTTICK — тик ближайшего события (Inf, если пусто).
        % Число событий, ожидающих в очереди.
        function value=count(obj), value=numel(obj.entries); end
        % Тик ближайшего события в очереди.
        function value=nextTick(obj)
            % Пустая очередь — Inf, иначе минимальный тик среди событий.
            if isempty(obj.entries), value=Inf; else, value=min([obj.entries.tick]); end
        end
    end
end
