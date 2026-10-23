classdef DialogSpy < handle
    properties
        LastTitle = ''
        LastMessage = ''
    end
    methods
        function capture(obj,message,title)
            obj.LastMessage=char(message);
            obj.LastTitle=char(title);
        end
    end
end
