classdef RaContextStore < handle
    %RACONTEXTSTORE BS observations only: no true UE identity or contenders.
    properties (SetAccess=private)
        entries = struct('id',{},'rnti',{},'nInit',{},'occasionId',{},'state',{}, ...
            'deadlineTick',{},'token',{},'sequence',{},'nextFragment',{},'ndi',{}, ...
            'harqTry',{},'softBuffer',{},'pending',{},'schedule',{}, ...
            'receiptAttempts',{},'lastProgressTick',{},'dataComplete',{},'delaySeconds',{})
    end
    methods
        function id=create(obj,nInit,occasionId,deadlineTick,delaySeconds)
            id=numel(obj.entries)+1;
            if id>65000, error('nbiot:ra:RntiExhausted','Temporary RNTI pool exhausted.'); end
            e=struct('id',id,'rnti',255+id,'nInit',nInit,'occasionId',occasionId, ...
                'state','RAR_PENDING','deadlineTick',deadlineTick,'token',uint64(0), ...
                'sequence',0,'nextFragment',1,'ndi',0,'harqTry',1,'softBuffer',[], ...
                'pending',true,'schedule',[],'receiptAttempts',0,'lastProgressTick',0, ...
                'dataComplete',false,'delaySeconds',delaySeconds);
            obj.entries(end+1)=e;
        end
        function e=get(obj,id), e=obj.entries(id); end
        function set(obj,id,e), obj.entries(id)=e; end
        function id=findRnti(obj,rnti)
            id=find([obj.entries.rnti]==rnti,1); if isempty(id), id=0; end
        end
    end
end
