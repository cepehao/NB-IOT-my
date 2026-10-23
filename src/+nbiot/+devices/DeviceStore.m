classdef DeviceStore < handle
    %DEVICESTORE Plain records; no object per UE and no BS CRC field.
    properties (SetAccess=private)
        entries
    end
    methods
        function obj=DeviceStore(count)
            entry=struct('state','IDLE','packetId',0,'attemptId',0,'attemptNumber',0, ...
                'lifetimeAttempt',0,'occasionId',0,'nInit',-1,'token',uint64(0), ...
                'rnti',0,'raRnti',0,'timingAdvanceSeconds',0,'deadlineTick',Inf, ...
                'monitorStartTick',Inf,'nextAllowedTick',0,'progressDeadlineTick',Inf, ...
                'fragmentIndex',0,'ndi',-1,'encoderState',[],'raSucceeded',false, ...
                'ulBusyStartTick',-Inf,'ulBusyUntilTick',-Inf);
            obj.entries=repmat(entry,count,1);
        end
        function entry=get(obj,ueId), entry=obj.entries(ueId); end
        function set(obj,ueId,entry), obj.entries(ueId)=entry; end
        function reset(obj,ueId)
            lifetime=obj.entries(ueId).lifetimeAttempt;
            busyStart=obj.entries(ueId).ulBusyStartTick; busyEnd=obj.entries(ueId).ulBusyUntilTick;
            fresh=nbiot.devices.DeviceStore(1); obj.entries(ueId)=fresh.entries;
            obj.entries(ueId).lifetimeAttempt=lifetime;
            obj.entries(ueId).ulBusyStartTick=busyStart; obj.entries(ueId).ulBusyUntilTick=busyEnd;
        end
        function [ra,active]=counts(obj)
            state=string({obj.entries.state});
            ra=sum(ismember(state,["WAIT_RA","WAIT_RAR","WAIT_MSG4","BACKOFF"]));
            active=sum(state~="IDLE");
        end
    end
end
