classdef RadioEventSimulatorStub < handle
    properties
        eventRows
        status = 'ready'
        errorInfo = struct()
    end
    methods
        function obj=RadioEventSimulatorStub(events)
            obj.eventRows=events;
        end
        function [newEvents,nextIndex]=observedEventsSince(obj,afterIndex)
            nextIndex=numel(obj.eventRows);
            if afterIndex>=nextIndex
                newEvents=struct('tick',{},'kind',{},'fields',{});
            else
                newEvents=obj.eventRows(afterIndex+1:nextIndex);
            end
        end
        function stop(obj,~)
            obj.status='stopped';
        end
    end
end
