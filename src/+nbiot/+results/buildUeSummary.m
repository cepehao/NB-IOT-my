function summary=buildUeSummary(cfg,scenario,packets,attempts,deviceStates)
%BUILDUESUMMARY Combine per-UE scenario, radio-access and service outcomes.
%   Таблица по UE (ТЗ §47 Per-UE): геометрия, потери, мощности, SNR, CFO, попытки, итог обслуживания.
cfg=nbiot.config.validateConfig(cfg);
n=cfg.simulation.numUE;
if ~isstruct(scenario)||~isfield(scenario,'ue')||numel(scenario.ue)~=n|| ...
        ~isequal(double([scenario.ue.ueId]),1:n)
    error('nbiot:results:UeSummaryScenario', ...
        'Scenario must contain one ordered UE record per configured device.');
end
if nargin<5||isempty(deviceStates)
    deviceStates=repmat({''},n,1);
end
deviceStates=string(deviceStates(:));
if numel(deviceStates)~=n||any(ismissing(deviceStates))
    error('nbiot:results:UeSummaryStates', ...
        'One nonmissing final device state is required per UE.');
end

ue=scenario.ue(:);
links=nbiot.channel.evaluateLinks(cfg,ue);
created=zeros(n,1); delivered=created; dropped=created; unfinished=created;
for k=1:numel(packets)
    id=checkedUeId(packets(k).ueId,n);
    created(id)=created(id)+1;
    switch char(string(packets(k).status))
        case 'delivered', delivered(id)=delivered(id)+1;
        case 'dropped', dropped(id)=dropped(id)+1;
        case 'unfinished', unfinished(id)=unfinished(id)+1;
        otherwise
            error('nbiot:results:UeSummaryPacketStatus', ...
                'Unexpected terminal packet status for UE summary.');
    end
end
raAttempts=zeros(n,1); raSuccesses=raAttempts; raFailures=raAttempts; raUnfinished=raAttempts;
for k=1:numel(attempts)
    id=checkedUeId(attempts(k).ueId,n);
    raAttempts(id)=raAttempts(id)+1;
    switch char(string(attempts(k).status))
        case 'success', raSuccesses(id)=raSuccesses(id)+1;
        case 'failure', raFailures(id)=raFailures(id)+1;
        case {'unfinished','started'}, raUnfinished(id)=raUnfinished(id)+1;
        otherwise
            error('nbiot:results:UeSummaryAttemptStatus', ...
                'Unexpected random-access status for UE summary.');
    end
end

outcome=strings(n,1);
for id=1:n
    if created(id)==0
        outcome(id)="no-packets";
    elseif created(id)~=delivered(id)+dropped(id)+unfinished(id)
        outcome(id)="inconsistent";
    else
        counts=[delivered(id),dropped(id),unfinished(id)];
        if nnz(counts)>1
            outcome(id)="mixed";
        elseif delivered(id)>0
            outcome(id)="delivered";
        elseif dropped(id)>0
            outcome(id)="dropped";
        else
            outcome(id)="unfinished";
        end
    end
end

ids=(1:n).';
summary=table(ids,[ue.xM].',[ue.yM].',logical([ue.indoor].'), ...
    [ue.horizontalDistanceM].',[ue.distanceM].',[ue.medianPathLossDb].', ...
    [ue.shadowingDb].',[ue.penetrationDb].',[ue.pathLossDb].', ...
    [ue.cfoHz].',[ue.syncOffsetSeconds].',string({ue.coverageClass}.'), ...
    [links.receivedPowerUlDbm].',[links.receivedPowerDlDbm].', ...
    [links.noisePsdBsWPerHz].',[links.noisePsdUeWPerHz].', ...
    [links.referenceBandwidthHz].',[links.referenceSnrUlDb].', ...
    [links.referenceSnrDlDb].',created,delivered,dropped,unfinished, ...
    raAttempts,raSuccesses,raFailures,raUnfinished,deviceStates,outcome, ...
    'VariableNames',{'ueId','xM','yM','indoor','horizontalDistanceM', ...
    'distanceM','medianPathLossDb','shadowingDb','penetrationDb','pathLossDb', ...
    'cfoHz','syncOffsetSeconds','coverageClass','receivedPowerUlDbm', ...
    'receivedPowerDlDbm','noisePsdBsWPerHz','noisePsdUeWPerHz', ...
    'referenceBandwidthHz','referenceSnrUlDb','referenceSnrDlDb', ...
    'created','delivered','dropped','unfinished','raAttempts','raSuccesses', ...
    'raFailures','raUnfinished','deviceStateAtEnd','serviceOutcome'});
end

function id=checkedUeId(value,n)
if ~(isnumeric(value)&&isscalar(value)&&isfinite(double(value))&& ...
        double(value)==fix(double(value))&&double(value)>=1&&double(value)<=n)
    error('nbiot:results:UeSummaryId','A result log has an invalid UE identifier.');
end
id=double(value);
end
