classdef PacketStore < handle
    %PACKETSTORE BS delivery and UE queue completion are independent facts.
    properties (SetAccess=private)
        packets
        counters=struct('created',0,'delivered',0,'dropped',0,'unfinished',0,'deliveredPayloadBits',0)
    end
    properties (Access=private)
        cfg
        queues
        index
        sequences
    end
    methods
        function obj=PacketStore(cfg)
            obj.cfg=nbiot.config.validateConfig(cfg); obj.queues=cell(cfg.simulation.numUE,1);
            obj.sequences=cell(cfg.simulation.numUE,1); obj.index=containers.Map('KeyType','uint32','ValueType','double');
            obj.packets=struct('packetId',{},'ueId',{},'sequence',{},'payloadBits',{},'blocks',{},'map',{},'received',{},'status',{},'reason',{},'createdTick',{},'deliveredTick',{},'terminalTick',{},'attemptCount',{},'ueConfirmed',{},'localFinished',{},'localFinishedTick',{});
        end
        function accepted=enqueue(obj,a)
            id=uint32(a.packetId); ue=double(a.ueId); obj.validateUE(ue);
            validateattributes(a.packetId,{'numeric'},{'scalar','integer','positive','<=',2^32-1});
            validateattributes(a.sequence,{'numeric'},{'scalar','integer','>=',0,'<=',65535}); obj.tick(a.createdTick);
            if isKey(obj.index,id), error('nbiot:traffic:DuplicatePacket','Packet ID already exists'); end
            if any(obj.sequences{ue}==double(a.sequence)), error('nbiot:traffic:SequenceOverflow','Sequence reuse is ambiguous in static-v1'); end
            [blocks,map]=nbiot.traffic.segmentPacket(a.payloadBits,a.sequence);
            if numel(a.payloadBits)~=obj.cfg.traffic.packetBytes*8, error('nbiot:traffic:MalformedPacket','Payload length disagrees with config'); end
            p=struct('packetId',id,'ueId',uint32(ue),'sequence',uint16(a.sequence),'payloadBits',int8(a.payloadBits(:)),'blocks',{blocks},'map',map,'received',{cell(numel(blocks),1)},'status','pending','reason','','createdTick',uint64(a.createdTick),'deliveredTick',NaN,'terminalTick',NaN,'attemptCount',0,'ueConfirmed',false,'localFinished',false,'localFinishedTick',NaN);
            accepted=numel(obj.queues{ue})<obj.cfg.traffic.queueLimit;
            if accepted, obj.queues{ue}(end+1)=id; else, p.status='dropped'; p.reason='overflow'; p.terminalTick=double(a.createdTick); p.localFinished=true; p.localFinishedTick=double(a.createdTick); obj.counters.dropped=obj.counters.dropped+1; end
            obj.sequences{ue}(end+1)=double(a.sequence); obj.packets(end+1)=p; obj.index(id)=numel(obj.packets); obj.counters.created=obj.counters.created+1;
        end
        function id=head(obj,ue)
            obj.validateUE(ue); q=obj.queues{double(ue)}; id=uint32(0); if ~isempty(q), id=q(1); end
        end
        function n=queueLength(obj,ue), obj.validateUE(ue); n=numel(obj.queues{double(ue)}); end
        function p=get(obj,id), p=obj.packets(obj.lookup(id)); end
        function incrementAttempt(obj,id)
            i=obj.lookup(id); if ~strcmp(obj.packets(i).status,'pending'), error('nbiot:traffic:TerminalPacket','Cannot attempt terminal packet'); end
            obj.packets(i).attemptCount=obj.packets(i).attemptCount+1;
        end
        function expired=expireLifetime(obj,tick)
            % Called after all receive events at the same tick are processed.
            obj.tick(tick); expired=uint32([]);
            for i=1:numel(obj.packets)
                p=obj.packets(i);
                if ~p.localFinished && double(tick)-double(p.createdTick)>=obj.cfg.traffic.lifetimeTicks
                    expired(end+1)=p.packetId; %#ok<AGROW>
                    obj.markTerminal(p.packetId,'dropped','lifetime',tick);
                end
            end
        end
        function localFinish(obj,id,tick,confirmed)
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i);
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Completion precedes arrival'); end
            validateattributes(confirmed,{'logical'},{'scalar'});
            if confirmed&&~strcmp(p.status,'delivered'), error('nbiot:traffic:InvalidConfirmation','Cannot confirm undelivered packet'); end
            if p.localFinished, return; end
            p.localFinished=true; p.localFinishedTick=double(tick); p.ueConfirmed=confirmed; obj.packets(i)=p;
            ue=double(p.ueId); obj.queues{ue}(obj.queues{ue}==p.packetId)=[];
        end
        function markTerminal(obj,id,status,reason,tick)
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i);
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Terminal tick precedes arrival'); end
            if ~any(strcmp(status,{'dropped','unfinished'})), error('nbiot:traffic:InvalidStatus','Only dropped or unfinished terminal status allowed'); end
            if strcmp(p.status,'delivered'), obj.localFinish(id,tick,false); return; end
            if ~strcmp(p.status,'pending'), return; end
            p.status=char(status); p.reason=char(reason); p.terminalTick=double(tick); obj.packets(i)=p;
            obj.counters.(status)=obj.counters.(status)+1; obj.localFinish(id,tick,false);
        end
        function newlyDelivered=markReceived(obj,id,fragmentIndex,bits,tick)
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i); newlyDelivered=false;
            validateattributes(fragmentIndex,{'numeric'},{'scalar','integer','>=',0,'<',numel(p.blocks)});
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Receive precedes arrival'); end
            b=int8(bits(:)); expected=p.blocks{double(fragmentIndex)+1};
            if numel(bits)~=256||any(bits(:)~=0&bits(:)~=1)||~isequal(b(1:48),expected(1:48))||any(b(49+p.map.validPayloadBits(double(fragmentIndex)+1):end))
                error('nbiot:traffic:MalformedPacket','Invalid TB header or padding');
            end
            if any(strcmp(p.status,{'dropped','unfinished'})), return; end
            k=double(fragmentIndex)+1;
            if ~isempty(p.received{k})
                if ~isequal(p.received{k},b), error('nbiot:traffic:ConflictingFragment','Duplicate fragment differs'); end
                return;
            end
            p.received{k}=b;
            if all(~cellfun(@isempty,p.received))
                % Reassembly relies on decoded contents, never true payload comparison.
                nbiot.traffic.reassemblePacket(p.received);
                p.status='delivered'; p.deliveredTick=double(tick); p.terminalTick=double(tick); newlyDelivered=true;
                obj.counters.delivered=obj.counters.delivered+1; obj.counters.deliveredPayloadBits=obj.counters.deliveredPayloadBits+p.map.totalPayloadBits;
            end
            obj.packets(i)=p;
        end
        function packets=finalize(obj,tick)
            obj.tick(tick);
            for i=1:numel(obj.packets)
                if strcmp(obj.packets(i).status,'pending'), obj.markTerminal(obj.packets(i).packetId,'unfinished','horizon',tick); end
            end
            packets=obj.packets;
        end
    end
    methods (Access=private)
        function i=lookup(obj,id)
            validateattributes(id,{'numeric'},{'scalar','integer','positive','<=',2^32-1});
            if ~isKey(obj.index,uint32(id)), error('nbiot:traffic:UnknownPacket','Unknown packet ID'); end
            i=obj.index(uint32(id));
        end
        function validateUE(obj,ue), validateattributes(ue,{'numeric'},{'scalar','integer','>=',1,'<=',obj.cfg.simulation.numUE}); end
        function tick(~,t), validateattributes(t,{'numeric'},{'scalar','real','finite','integer','nonnegative'}); end
    end
end
