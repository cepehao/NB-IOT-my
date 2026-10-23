classdef EventQueue < handle
    %EVENTQUEUE Stable queue of deferred physical receiver completions.
    properties (Access=private)
        entries = struct('tick',{},'sequence',{},'kind',{},'payload',{})
        nextSequence = 1
    end
    methods
        function push(obj,tick,kind,payload)
            validateattributes(tick,{'numeric'},{'scalar','integer','nonnegative','finite'});
            e=struct('tick',double(tick),'sequence',obj.nextSequence,'kind',char(kind),'payload',payload);
            obj.nextSequence=obj.nextSequence+1; obj.entries(end+1)=e;
        end
        function ready=popReady(obj,now)
            selected=[obj.entries.tick]<=now; ready=obj.entries(selected); obj.entries(selected)=[];
            if ~isempty(ready)
                [~,order]=sortrows([[ready.tick].',[ready.sequence].'],[1 2]); ready=ready(order);
            end
        end
        function value=count(obj), value=numel(obj.entries); end
        function value=nextTick(obj)
            if isempty(obj.entries), value=Inf; else, value=min([obj.entries.tick]); end
        end
    end
end
