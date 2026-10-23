classdef ResourceCalendar < handle
    properties (SetAccess=private)
        mandatoryMask
        durationTicks
    end
    properties (Access=private)
        cfg
        ul
        dl
        monitoringDlTicks
        monitoringDlPrefix
        windowShares
        records = struct('direction',{},'phase',{},'ticks',{},'frequencyStartHz',{},'bandwidthHz',{},'grantId',{})
    end
    methods
        function obj=ResourceCalendar(cfg)
            obj.cfg=cfg; obj.durationTicks=cfg.simulation.durationTicks;
            obj.mandatoryMask=nbiot.scheduler.mandatoryDlMask(obj.durationTicks,cfg.cell.cellId);
            mask=obj.mandatoryMask(:).';
            obj.monitoringDlTicks=reshape(find(~mask)-1,1,[]);
            obj.monitoringDlPrefix=[0 cumsum(~mask)];
            windowCount=ceil(obj.durationTicks/cfg.policy.windowTicks);
            obj.windowShares=repmat(cfg.policy.raShare,1,windowCount);
            obj.ul=zeros(2*obj.durationTicks,48,'uint8'); obj.dl=zeros(obj.durationTicks,1,'uint8');
        end
        function ok=canReserve(obj,plans)
            [ok,~,~]=obj.check(plans);
        end
        function ticks=monitoringTicks(obj,baseTick)
            assert(isscalar(baseTick) && baseTick>=0 && baseTick==fix(baseTick));
            if baseTick>=obj.durationTicks, ticks=zeros(1,0); return; end
            first=obj.monitoringDlPrefix(baseTick+1)+1;
            last=min(first+3,numel(obj.monitoringDlTicks));
            if first>last, ticks=zeros(1,0); return; end
            ticks=obj.monitoringDlTicks(first:last);
        end
        function ok=reserveTransaction(obj,plans)
            [ok,u,d]=obj.check(plans);
            if ok
                obj.ul=u; obj.dl=d;
                for k=1:numel(plans), obj.records(end+1)=obj.canonical(plans(k)); end
            end
        end
        function applied=applyShareFrom(obj,effectiveTick,raShare)
            applied=false; windowTicks=obj.cfg.policy.windowTicks;
            if ~isnumeric(effectiveTick)||~isscalar(effectiveTick)||~isfinite(effectiveTick)|| ...
                    effectiveTick<0||effectiveTick>=obj.durationTicks||effectiveTick~=fix(effectiveTick)|| ...
                    mod(effectiveTick,windowTicks)~=0||~isnumeric(raShare)||~isscalar(raShare)|| ...
                    ~isfinite(raShare)||raShare<=0||raShare>=1
                return;
            end
            firstWindow=effectiveTick/windowTicks+1;
            proposed=obj.windowShares; proposed(firstWindow:end)=raShare;
            if ~obj.reservationsFit(proposed), return; end
            obj.windowShares=proposed; applied=true;
        end
        function ok=isFree(obj,plan)
            [rows,cols,direction]=obj.indices(plan);
            if direction==0, ok=~any(obj.ul(rows,cols)~=0,'all'); else, ok=~any(obj.dl(rows)~=0|obj.mandatoryMask(rows)); end
        end
        function releaseUnstarted(obj,grantIds,now)
            keep=true(1,numel(obj.records));
            for i=1:numel(obj.records)
                p=obj.records(i);
                if ismember(p.grantId,grantIds) && min(p.ticks)>=now, keep(i)=false; end
            end
            obj.records=obj.records(keep); obj.ul(:)=0; obj.dl(:)=0;
            for i=1:numel(obj.records)
                p=obj.records(i); [r,c,d]=obj.indices(p); phase=1+strcmpi(p.phase,'DT');
                if d==0, obj.ul(r,c)=phase; else, obj.dl(r)=phase; end
            end
        end
        function occupancy=windowOccupancy(obj,first,last)
            windowTicks=obj.cfg.dataset.windowTicks;
            validFirst=isnumeric(first)&&isreal(first)&&isscalar(first)&&isfinite(first)&& ...
                first>=0&&first<obj.durationTicks&&first==fix(first)&&mod(first,windowTicks)==0;
            if validFirst
                expectedLast=min(first+windowTicks,obj.durationTicks);
            else
                expectedLast=NaN;
            end
            validLast=isnumeric(last)&&isreal(last)&&isscalar(last)&&isfinite(last)&& ...
                last==expectedLast;
            if ~validFirst||~validLast
                error('nbiot:scheduler:WindowOccupancy', ...
                    'Occupancy can be read only for one aligned, completed dataset window.');
            end
            first=double(first); last=double(last);
            ulWindow=obj.ul(2*first+1:2*last,:);
            dlWindow=obj.dl(first+1:last);
            dlAvailable=~obj.mandatoryMask(first+1:last);
            ulAvailable=numel(ulWindow); dlAvailableUnits=sum(dlAvailable);
            ulRa=NaN; ulDt=NaN; dlRa=NaN; dlDt=NaN;
            if ulAvailable>0
                ulRa=double(sum(ulWindow==1,'all'))/ulAvailable;
                ulDt=double(sum(ulWindow==2,'all'))/ulAvailable;
            end
            if dlAvailableUnits>0
                dlRa=double(sum(dlWindow==1))/dlAvailableUnits;
                dlDt=double(sum(dlWindow==2))/dlAvailableUnits;
            end
            occupancy=struct( ...
                'ulRaOccupancy',ulRa,'ulDtOccupancy',ulDt, ...
                'dlRaOccupancy',dlRa,'dlDtOccupancy',dlDt);
        end
        function result=usage(obj)
            rows={}; w=obj.cfg.policy.windowTicks;
            for first=0:w:obj.durationTicks-1
                last=min(first+w,obj.durationTicks); u=obj.ul(2*first+1:2*last,:); d=obj.dl(first+1:last);
                for direction=0:1
                    if direction==0, available=numel(u); ra=sum(u==1,'all'); dt=sum(u==2,'all'); unit=3750*0.0005;
                    else, available=sum(~obj.mandatoryMask(first+1:last)); ra=sum(d==1); dt=sum(d==2); unit=180000*0.001; end
                    share=obj.windowShares(floor(first/w)+1);
                    quota=floor(share*available);
                    rows(end+1,:)={first,last,direction,available,quota,available-quota,ra,dt,unit,ra*unit,dt*unit}; %#ok<AGROW>
                end
            end
            result=cell2table(rows,'VariableNames',{'startTick','endTick','direction','availableUnits','raQuotaUnits','dtQuotaUnits','raReservedUnits','dtReservedUnits','unitHzSeconds','raReservedHzSeconds','dtReservedHzSeconds'});
        end
    end
    methods (Access=private)
        function fits=reservationsFit(obj,shares)
            fits=false; w=obj.cfg.policy.windowTicks;
            for first=0:w:obj.durationTicks-1
                last=min(first+w,obj.durationTicks);
                us=obj.ul(2*first+1:2*last,:); ds=obj.dl(first+1:last);
                share=shares(floor(first/w)+1);
                availableUl=numel(us); availableDl=sum(~obj.mandatoryMask(first+1:last));
                quotaUl=floor(share*availableUl); quotaDl=floor(share*availableDl);
                if sum(us==1,'all')>quotaUl||sum(us==2,'all')>availableUl-quotaUl|| ...
                        sum(ds==1)>quotaDl||sum(ds==2)>availableDl-quotaDl
                    return;
                end
            end
            fits=true;
        end
        function [ok,u,d]=check(obj,plans)
            u=obj.ul; d=obj.dl; ok=false;
            if isempty(plans), ok=true; return; end
            ids=[obj.records.grantId];
            for i=1:numel(plans)
                p=plans(i); if ismember(p.grantId,ids), return; end; ids(end+1)=p.grantId;
                [r,c,dir]=obj.indices(p); phase=1+strcmpi(p.phase,'DT');
                assert(any(strcmpi(p.phase,{'RA','DT'})));
                if dir==0
                    if any(u(r,c)~=0,'all'), return; end; u(r,c)=phase;
                else
                    if any(d(r)~=0|obj.mandatoryMask(r)), return; end; d(r)=phase;
                end
            end
            w=obj.cfg.policy.windowTicks;
            for first=0:w:obj.durationTicks-1
                last=min(first+w,obj.durationTicks); us=u(2*first+1:2*last,:); ds=d(first+1:last);
                share=obj.windowShares(floor(first/w)+1);
                au=numel(us); ad=sum(~obj.mandatoryMask(first+1:last)); qu=floor(share*au); qd=floor(share*ad);
                if sum(us==1,'all')>qu || sum(us==2,'all')>au-qu || sum(ds==1)>qd || sum(ds==2)>ad-qd, return; end
            end
            ok=true;
        end
        function [rows,cols,d]=indices(obj,p)
            if isnumeric(p.direction), d=double(p.direction); else, d=find(strcmpi(p.direction,{'UL','DL'}),1)-1; end
            assert(isscalar(d) && any(d==[0 1]));
            ticks=p.ticks(:); assert(~isempty(ticks) && numel(unique(ticks))==numel(ticks));
            assert(all(ticks>=0 & ticks<obj.durationTicks & ticks==fix(ticks)));
            if d==0
                rows=reshape([2*ticks+1,2*ticks+2].',[],1);
                a=p.frequencyStartHz/3750; b=p.bandwidthHz/3750;
                assert(a==fix(a) && b==fix(b) && a>=0 && b>0 && a+b<=48); cols=a+(1:b);
            else
                assert(p.frequencyStartHz==0 && p.bandwidthHz==180000); rows=ticks+1; cols=1;
            end
        end
        function p=canonical(~,x)
            p=struct('direction',x.direction,'phase',x.phase,'ticks',x.ticks,'frequencyStartHz',x.frequencyStartHz,'bandwidthHz',x.bandwidthHz,'grantId',x.grantId);
        end
    end
end
