classdef EventLog < handle
    %EVENTLOG Append-only semantic events; receiver features have a whitelist.
    %   Журнал событий (тик, вид, поля) только на дозапись; основа журналов наблюдений и истины.
    properties (Access=private)
        buffer = cell(256,1)
        used = 0
    end
    methods
        function append(obj,tick,kind,fields)
            obj.used=obj.used+1;
            if obj.used>numel(obj.buffer), obj.buffer=[obj.buffer;cell(numel(obj.buffer),1)]; end
            obj.buffer{obj.used}=struct('tick',double(tick),'kind',char(kind),'fields',fields);
        end
        function events=all(obj)
            if obj.used==0, events=struct('tick',{},'kind',{},'fields',{});
            else, events=vertcat(obj.buffer{1:obj.used}); end
        end
        function [events,nextIndex]=since(obj,afterIndex)
            if nargin<2, afterIndex=0; end
            if ~isnumeric(afterIndex)||~isreal(afterIndex)||~isscalar(afterIndex)|| ...
                    ~isfinite(afterIndex)||afterIndex~=fix(afterIndex)|| ...
                    afterIndex<0||afterIndex>obj.used
                error('nbiot:results:EventLogCursor', ...
                    'Event cursor must be an integer between 0 and the current event count.');
            end
            nextIndex=obj.used;
            if afterIndex==obj.used
                events=struct('tick',{},'kind',{},'fields',{});
            else
                events=vertcat(obj.buffer{afterIndex+1:obj.used});
            end
        end
    end
end
