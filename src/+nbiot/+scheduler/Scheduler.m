classdef Scheduler < handle
    % Fixed quota allocator; all dependent grants commit atomically.
    properties (Access=private)
        cfg
        calendar
        nextId=1
        busyUntil
        occasions=[]
        availableDlTicks
        availableDlPrefix
    end
    methods
        function obj=Scheduler(cfg,calendar)
            obj.cfg=cfg; obj.calendar=calendar;
            obj.busyUntil=containers.Map('KeyType','double','ValueType','double');
            mask=calendar.mandatoryMask(:).';
            obj.availableDlTicks=reshape(find(~mask)-1,1,[]);
            obj.availableDlPrefix=[0 cumsum(~mask)];
        end
        function occasions=reserveNprach(obj)
            if ~isempty(obj.occasions), occasions=obj.occasions; return; end
            occasions=struct('occasionId',{},'startTick',{},'endTick',{},'grantId',{}); plans=[];
            for t=obj.cfg.ra.startOffsetTicks:obj.cfg.ra.periodTicks:obj.cfg.simulation.durationTicks-6
                g=obj.grant('NPRACH','RA','UL',t:t+5,0,45000,0,0,0,struct());
                p=obj.plan(g); if isempty(plans), plans=p; else, plans(end+1)=p; end
                occasions(end+1)=struct('occasionId',numel(occasions)+1,'startTick',t,'endTick',t+6,'grantId',g.grantId);
            end
            assert(obj.calendar.reserveTransaction(plans),'nbiot:NprachQuota','NPRACH exceeds the fixed RA budget.');
            obj.occasions=occasions;
        end
        function applied=applyShareFrom(obj,effectiveTick,raShare)
            applied=obj.calendar.applyShareFrom(effectiveTick,raShare);
        end
        function matches=referencesCalendar(obj,calendar)
            matches=(obj.calendar==calendar);
        end
        function schedule=uplink(obj,kind,phase,earliestTick,deadlineTick,rnti,ndi,rv)
            schedule=[]; earliestTick=max(earliestTick,obj.contextAvailable(rnti));
            for base=ceil(earliestTick/32)*32:32:min(deadlineTick,obj.cfg.simulation.durationTicks)-1
                mt=obj.calendar.monitoringTicks(base); if numel(mt)<2, continue; end
                control=obj.grant('NPDCCH',phase,'DL',mt(1:2),0,180000,rnti,ndi,rv,struct('format','N0','repetitions',2));
                for delay=0:3
                    for group=0:3
                        dci=struct('format','N0','subcarrierIndication',12+group,'resourceAssignment',3,'schedulingDelay',delay,'mcs',4,'rv',double(rv==2),'repetitionNumber',1,'ndi',ndi,'dciRepetitions',1);
                        payload=obj.reconstructUplink(dci,control.ticks,rnti); payload.kind=char(kind); payload.phase=char(phase); payload.grantId=obj.allocateId();
                        if payload.endTick>deadlineTick || payload.endTick>obj.cfg.simulation.durationTicks, continue; end
                        plans=[obj.plan(control) obj.plan(payload)];
                        if obj.calendar.reserveTransaction(plans)
                            schedule=struct('controlGrant',control,'payloadGrant',payload,'ackGrant',[],'msg3Grant',[],'dci',dci);
                            obj.busyUntil(double(rnti))=payload.endTick+3; return;
                        end
                    end
                end
            end
        end
        function schedule=downlink(obj,kind,phase,earliestTick,deadlineTick,rnti)
            schedule=[]; earliestTick=max(earliestTick,obj.contextAvailable(rnti)); rar=strcmpi(kind,'RAR');
            for base=ceil(earliestTick/32)*32:32:min(deadlineTick,obj.cfg.simulation.durationTicks)-1
                mt=obj.calendar.monitoringTicks(base); if numel(mt)<2, continue; end
                control=obj.grant('NPDCCH',phase,'DL',mt(1:2),0,180000,rnti,0,0,struct('format','N1','repetitions',2));
                for delay=0:7
                    for ackIndex=0:15
                        dci=struct('format','N1','order',0,'schedulingDelay',delay,'resourceAssignment',0,'mcs',6,'repetitionNumber',1,'ndi',0,'ackResource',ackIndex,'dciRepetitions',1);
                        payload=obj.reconstructDownlink(dci,control.ticks,rnti); if isempty(payload), continue; end
                        payload.kind=char(kind); payload.phase=char(phase); payload.grantId=obj.allocateId();
                        if payload.endTick+obj.cfg.phy.processingTicks+1>deadlineTick, continue; end
                        ack=[]; msg3=[]; plans=[obj.plan(control) obj.plan(payload)];
                        if rar
                            fields=struct('subcarrierSpacing',1,'subcarrierIndication',12,'schedulingDelay',0,'repetitionNumber',1,'mcs',2);
                            msg3=obj.reconstructMsg3(fields,payload.ticks); msg3.phase=char(phase); msg3.rnti=rnti; msg3.grantId=obj.allocateId();
                            plans(end+1)=obj.plan(msg3); finish=msg3.endTick;
                        else
                            ack=obj.reconstructAck(dci,payload,rnti); ack.phase=char(phase); ack.grantId=obj.allocateId();
                            plans(end+1)=obj.plan(ack); finish=ack.endTick;
                        end
                        if finish>obj.cfg.simulation.durationTicks, continue; end
                        if obj.calendar.reserveTransaction(plans)
                            schedule=struct('controlGrant',control,'payloadGrant',payload,'ackGrant',ack,'msg3Grant',msg3,'dci',dci);
                            if rar, schedule.rarGrant=fields; end
                            obj.busyUntil(double(rnti))=finish+3; return;
                        end
                        if rar, break; end
                    end
                end
            end
        end
        function g=reconstructUplink(obj,dci,controlTicks,rnti)
            assert(strcmpi(dci.format,'N0') && dci.mcs==4 && dci.resourceAssignment==3 && dci.repetitionNumber==1 && ismember(dci.subcarrierIndication,12:15),'nbiot:UnsupportedGrant','N0 is outside static-v1.');
            p=nbiot.phy.ProfileTables.profile('data');
            p.nru=nbiot.phy.ProfileTables.resourceUnits(dci.resourceAssignment);
            p.repetitions=nbiot.phy.ProfileTables.ulRepetitions(dci.repetitionNumber); p.mcs=dci.mcs; p.iru=dci.resourceAssignment;
            tones=nbiot.phy.ProfileTables.decodeUlAssignment(dci.subcarrierIndication); p.numSubcarriers=numel(tones);
            p.tbs=nbiot.phy.ProfileTables.ulTbs(p.mcs,p.iru,p.numSubcarriers);
            duration=p.nru*p.nulSlots*0.5*p.repetitions; p.durationTicks=duration;
            start=max(controlTicks)+1+nbiot.phy.ProfileTables.n0Delay(dci.schedulingDelay);
            g=obj.publicGrant('Data','DT','UL',start:start+duration-1,min(tones)*15000,numel(tones)*15000,rnti,dci.ndi,2*dci.rv,p);
        end
        function g=reconstructDownlink(obj,dci,controlTicks,rnti)
            assert(strcmpi(dci.format,'N1') && dci.order==0 && dci.mcs==6 && dci.resourceAssignment==0 && dci.repetitionNumber==1,'nbiot:UnsupportedGrant','N1 is outside static-v1.');
            p=nbiot.phy.ProfileTables.profile('downlink');
            p.mcs=dci.mcs; p.nsf=nbiot.phy.ProfileTables.dlSubframes(dci.resourceAssignment);
            p.repetitions=nbiot.phy.ProfileTables.dlRepetitions(dci.repetitionNumber); p.tbs=nbiot.phy.ProfileTables.dlTbs(p.mcs,dci.resourceAssignment);
            offset=nbiot.phy.ProfileTables.n1Delay(dci.schedulingDelay,4); count=p.nsf*p.repetitions;
            first=max(controlTicks)+5;
            if first>=obj.cfg.simulation.durationTicks, g=[]; return; end
            at=obj.availableDlPrefix(first+1)+1;
            if at+offset+count-1>numel(obj.availableDlTicks), g=[]; return; end
            ticks=obj.availableDlTicks(at+offset+(0:count-1)); p.durationTicks=ticks(end)+1-ticks(1);
            g=obj.publicGrant('NPDSCH','DT','DL',ticks,0,180000,rnti,dci.ndi,0,p);
        end
        function g=reconstructMsg3(obj,rar,payloadTicks)
            if isfield(rar,'ulGrant'), rar=rar.ulGrant; end
            assert(rar.subcarrierSpacing==1 && rar.mcs==2 && rar.repetitionNumber==1 && ismember(rar.subcarrierIndication,12:15),'nbiot:UnsupportedGrant','RAR is outside static-v1.');
            p=nbiot.phy.ProfileTables.msg3Profile(rar.mcs); tones=nbiot.phy.ProfileTables.decodeUlAssignment(rar.subcarrierIndication);
            p.numSubcarriers=numel(tones);
            p.repetitions=nbiot.phy.ProfileTables.ulRepetitions(rar.repetitionNumber); p.durationTicks=p.nru*p.nulSlots*0.5*p.repetitions;
            start=max(payloadTicks)+1+nbiot.phy.ProfileTables.rarDelay(rar.schedulingDelay);
            g=obj.publicGrant('Msg3','RA','UL',start:start+p.durationTicks-1,min(tones)*15000,numel(tones)*15000,0,0,0,p);
        end
        function g=reconstructAck(obj,dci,payload,rnti)
            [tone,k0]=nbiot.phy.ProfileTables.ackResource(dci.ackResource); p=nbiot.phy.ProfileTables.profile('ack');
            % TS 36.213 section 16.4.2: end of subframe n+k0-1.
            % payload.endTick is the end of final subframe n (n+1).
            start=payload.endTick+k0-1;
            g=obj.publicGrant('ACK','DT','UL',start:start+p.durationTicks-1,tone*15000,15000,rnti,0,0,p);
        end
    end
    methods (Access=private)
        function tick=contextAvailable(obj,rnti)
            if isKey(obj.busyUntil,double(rnti)), tick=obj.busyUntil(double(rnti)); else, tick=0; end
        end
        function g=grant(obj,varargin)
            g=obj.publicGrant(varargin{:}); g.grantId=obj.allocateId();
        end
        function id=allocateId(obj)
            id=obj.nextId; obj.nextId=obj.nextId+1;
        end
    end
    methods (Static,Access=private)
        function g=publicGrant(kind,phase,direction,ticks,frequency,bandwidth,rnti,ndi,rv,profile)
            g=struct('grantId',0,'kind',char(kind),'phase',char(phase),'direction',char(direction),'startTick',min(ticks),'endTick',max(ticks)+1,'ticks',ticks,'frequencyStartHz',frequency,'bandwidthHz',bandwidth,'rnti',rnti,'ndi',ndi,'rv',rv,'profile',profile);
        end
        function p=plan(g)
            p=struct('direction',g.direction,'phase',g.phase,'ticks',g.ticks,'frequencyStartHz',g.frequencyStartHz,'bandwidthHz',g.bandwidthHz,'grantId',g.grantId);
        end
    end
end
