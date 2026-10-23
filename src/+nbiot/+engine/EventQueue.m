classdef EventQueue < handle
    %EVENTQUEUE Очередь отложенных событий завершения приёма (модель времени симулятора).
    %   Каждое событие: тик готовности, порядковый номер, тип ('nprach','monitor','dl_payload',
    %   'bs_ul') и данные. popReady(now) выдаёт все события с tick <= now в стабильном порядке
    %   (тик, затем порядок постановки) — это делает прогон детерминированным.
    properties (Access=private)
        entries = struct('tick',{},'sequence',{},'kind',{},'payload',{})
        nextSequence = 1
    end
    methods
        %PUSH Добавляет событие KIND с данными PAYLOAD, готовое к тику TICK.
        function push(obj,tick,kind,payload)
            validateattributes(tick,{'numeric'},{'scalar','integer','nonnegative','finite'});
            e=struct('tick',double(tick),'sequence',obj.nextSequence,'kind',char(kind),'payload',payload);
            obj.nextSequence=obj.nextSequence+1; obj.entries(end+1)=e;
        end
        %POPREADY Извлекает готовые к тику NOW события, упорядоченные по (тик, номер).
        function ready=popReady(obj,now)
            selected=[obj.entries.tick]<=now; ready=obj.entries(selected); obj.entries(selected)=[];
            if ~isempty(ready)
                [~,order]=sortrows([[ready.tick].',[ready.sequence].'],[1 2]); ready=ready(order);
            end
        end
        %COUNT Число ожидающих событий; NEXTTICK — тик ближайшего события (Inf, если пусто).
        function value=count(obj), value=numel(obj.entries); end
        function value=nextTick(obj)
            if isempty(obj.entries), value=Inf; else, value=min([obj.entries.tick]); end
        end
    end
end
