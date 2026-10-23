classdef RandomSources
    properties (SetAccess=private)
        masterSeed
        realizationId
    end
    methods
        function obj=RandomSources(masterSeed,realizationId)
            validateattributes(masterSeed,{'numeric'},{'scalar','integer','>=',0,'<=',2^32-1});
            validateattributes(realizationId,{'numeric'},{'scalar','integer','>=',0,'<=',4095});
            obj.masterSeed=double(masterSeed); obj.realizationId=double(realizationId);
        end
        function s=stream(obj,name,direction,receiverId,blockId)
            key=nbiot.randomness.substreamKey(name,direction,receiverId,blockId);
            s=RandStream.create('mrg32k3a','NumStreams',4096,'StreamIndices',obj.realizationId+1,'Seed',obj.masterSeed);
            s.Substream=key;
        end
        function m=manifest(obj)
            m=struct('algorithm','mrg32k3a','masterSeed',obj.masterSeed,'externalRealizationId',obj.realizationId,'numStreams',4096,'streamIndex',obj.realizationId+1,'sourceNames',{{'layout','traffic','shadowing','channel','CFO','timing','noise','payload','access','backoff','token'}},'sourceCodes',1:11,'keyFormula','1+blockId+2^24*(receiverId+2^16*(direction+2*sourceCode))','directionCodes',[0 1],'staticBlockId',0);
        end
    end
end
