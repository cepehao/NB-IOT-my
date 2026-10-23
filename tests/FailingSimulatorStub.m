classdef FailingSimulatorStub < handle
    properties
        status = 'ready'
        errorInfo = struct()
        currentTick = 0
        scenario = struct('ue',struct('xM',{},'yM',{},'indoor',{}))
        packets = struct('queueLength',zeros(0,1))
    end
    methods
        function run(obj,~)
            obj.status='failed';
            obj.errorInfo=struct('message','fixture simulation failure');
        end
        function state=snapshot(~)
            state=struct('tick',0,'packetCounters',struct(),'devices',struct([]), ...
                'crcCounters',struct('msg3Errors',0,'dataErrors',0));
        end
    end
end
