function rows=windowDiagnostics(cfg,packets,attempts,truthEvents,observedEvents, ...
    receptionEvents,actualTick,windowKeys)
%WINDOWDIAGNOSTICS Derive outcome-only diagnostics for already closed windows.
% This function consumes completed in-memory journals. It never calls a PHY,
% changes simulator state, or supplies any value to the controller.
validateInputs(cfg,actualTick,windowKeys);
keyNames={'realizationId','windowId','startTick','endTick'};
keys=windowKeys(:,keyNames);
if isempty(keys)
    rows=emptyDiagnostics();
    return
end

attemptAvailable=isstruct(attempts)&&all(isfield(attempts, ...
    {'attemptId','startTick','endTick','status'}));
packetAvailable=isstruct(packets)&&all(isfield(packets, ...
    {'packetId','createdTick','deliveredTick','status'}));
truthAvailable=isstruct(truthEvents)&&all(isfield(truthEvents,{'kind','fields','tick'}));
observationAvailable=isstruct(observedEvents)&&all(isfield(observedEvents,{'kind','fields','tick'}));
receptionAvailable=isstruct(receptionEvents)&&all(isfield(receptionEvents,{'kind','fields','tick'}));

if attemptAvailable
    validateAttempts(attempts,actualTick);
end
if packetAvailable
    validatePackets(packets,actualTick);
end
[readyTick,detectedOccasions]=indexDetections(observedEvents,observationAvailable,actualTick);
[groups,truthIds]=indexTruth(truthEvents,truthAvailable);
if attemptAvailable&&truthAvailable
    if any(~ismember(truthIds,[attempts.attemptId]))
        diagnosticsError('A Msg1 truth event references a missing attempt.');
    end
end
components=indexComponents(receptionEvents,receptionAvailable,readyTick,detectedOccasions);
pairs=indexOverlaps(receptionEvents,receptionAvailable,components,readyTick,actualTick);

n=height(keys);
logicalGroups=nan(n,1); logicalAttempts=nan(n,1);
physicalPairs=nan(n,1); physicalAttempts=nan(n,1);
successes=nan(n,1); retries=nan(n,1); meanDelay=nan(n,1); delayCount=nan(n,1);
unfinishedAccess=nan(n,1); unfinishedPackets=nan(n,1);
logicalAvailable=repmat(attemptAvailable&&truthAvailable&&observationAvailable,n,1);
physicalAvailable=repmat(receptionAvailable&&observationAvailable,n,1);
accessAvailable=repmat(attemptAvailable,n,1);
retryAvailable=repmat(attemptAvailable&&isstruct(attempts)&&isfield(attempts,'packetId'),n,1);
delayAvailable=false(n,1);

if attemptAvailable
    for row=1:n
        s=keys.startTick(row); e=keys.endTick(row);
        inInterval=[attempts.startTick]>=s & [attempts.startTick]<e;
        finished=[attempts.endTick]<=actualTick & isfinite([attempts.endTick]);
        unfinishedAccess(row)=sum(inInterval&~finished);
        successes(row)=sum(strcmp({attempts.status},'success') & ...
            isfinite([attempts.endTick]) & [attempts.endTick]>s & [attempts.endTick]<=e);
        if retryAvailable(row)
            retries(row)=retryCount(attempts,s,e);
        end
    end
end

if logicalAvailable(1)
    for row=1:n
        s=keys.startTick(row); e=keys.endTick(row);
        [logicalGroups(row),logicalAttempts(row)]=countLogical(groups,readyTick,s,e);
    end
end
if physicalAvailable(1)
    for row=1:n
        ready=[pairs.readyTick];
        selected=ready>keys.startTick(row)&ready<=keys.endTick(row);
        physicalPairs(row)=sum(selected);
        physicalAttempts(row)=numel(unique([pairs(selected).attemptIds]));
    end
end
if packetAvailable
    delayCount=zeros(n,1);
    for row=1:n
        s=keys.startTick(row); e=keys.endTick(row);
        unfinishedPackets(row)=sum([packets.createdTick]>=s & [packets.createdTick]<e & ...
            strcmp({packets.status},'unfinished'));
        delivered=strcmp({packets.status},'delivered') & isfinite([packets.deliveredTick]) & ...
            [packets.deliveredTick]>s & [packets.deliveredTick]<=e;
        delayCount(row)=sum(delivered);
        if delayCount(row)>0
            delay=double([packets(delivered).deliveredTick])-double([packets(delivered).createdTick]);
            meanDelay(row)=mean(delay);
            delayAvailable(row)=true;
        end
    end
end

rows=table(keys.realizationId,keys.windowId,keys.startTick,keys.endTick, ...
    logicalGroups,logicalAttempts,physicalPairs,physicalAttempts,successes,retries, ...
    meanDelay,delayCount,unfinishedAccess,unfinishedPackets,logicalAvailable, ...
    physicalAvailable,accessAvailable,retryAvailable,delayAvailable, ...
    repmat(double(actualTick),n,1), ...
    'VariableNames',{'realizationId','windowId','startTick','endTick', ...
    'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
    'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
    'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
    'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
    'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'});
end

function validateInputs(cfg,actualTick,keys)
if ~isstruct(cfg)||~isfield(cfg,'simulation')||~isfield(cfg.simulation,'realizationId')|| ...
        ~isscalar(actualTick)||~isnumeric(actualTick)||~isfinite(actualTick)|| ...
        actualTick<0||actualTick~=fix(actualTick)|| ...
        (isfield(cfg,'simulation')&&isfield(cfg.simulation,'durationTicks')&& ...
            actualTick>cfg.simulation.durationTicks)||~istable(keys)|| ...
        ~all(ismember({'realizationId','windowId','startTick','endTick'},keys.Properties.VariableNames))
    diagnosticsError('Configuration, horizon, or window-key table is malformed.');
end
required={'realizationId','windowId','startTick','endTick'};
if ~isnumeric(keys{:,required})||any(~isfinite(keys{:,required}),'all')|| ...
        any(keys.realizationId~=cfg.simulation.realizationId)|| ...
        any(keys.windowId<1|keys.windowId~=fix(keys.windowId))|| ...
        any(keys.startTick<0|keys.startTick~=fix(keys.startTick))|| ...
        any(keys.endTick<=keys.startTick|keys.endTick>actualTick|keys.endTick~=fix(keys.endTick))|| ...
        height(unique(keys(:,required),'rows'))~=height(keys)
    diagnosticsError('Window keys must be unique valid closed intervals through actualTick.');
end
end

function validateAttempts(attempts,horizon)
ids=double([attempts.attemptId]); starts=double([attempts.startTick]); ends=double([attempts.endTick]);
if any(~isfinite(ids)|ids<1|ids~=fix(ids))||numel(unique(ids))~=numel(ids)|| ...
        any(~isfinite(starts)|starts<0|starts>=horizon|starts~=fix(starts))|| ...
        any(isfinite(ends)&(ends<starts|ends~=fix(ends)))|| ...
        any(~ismember(string({attempts.status}),["started","unfinished","success","failure"]))
    diagnosticsError('Attempt IDs, intervals, or status values are malformed.');
end
end

function validatePackets(packets,horizon)
if isempty(packets), return; end
ids=double([packets.packetId]); created=double([packets.createdTick]); delivered=double([packets.deliveredTick]);
if any(~isfinite(ids)|ids<1|ids~=fix(ids))||numel(unique(ids))~=numel(ids)|| ...
        any(~isfinite(created)|created<0|created>=horizon|created~=fix(created))|| ...
        any(isfinite(delivered)&(delivered<created|delivered~=fix(delivered)))|| ...
        any(~ismember(string({packets.status}),["pending","unfinished","delivered","dropped"]))
    diagnosticsError('Packet IDs, intervals, or status values are malformed.');
end
end

function [ready,occasions]=indexDetections(events,available,~)
ready=containers.Map('KeyType','double','ValueType','double'); occasions=zeros(0,1);
if ~available, return; end
for k=1:numel(events)
    e=events(k); if ~strcmp(e.kind,'nprach_detection'), continue; end
    if ~isfield(e.fields,'occasionId')||~isfield(e.fields,'readyTick')
        diagnosticsError('NPRACH detection lacks occasionId or readyTick.');
    end
    occasion=integerValue(e.fields.occasionId,'occasionId',0);
    tick=integerValue(e.fields.readyTick,'readyTick',0);
    if tick==0||tick~=double(e.tick)
        diagnosticsError('Receiver readyTick must be positive and equal the event tick.');
    end
    if any(occasions==occasion)
        diagnosticsError('Duplicate NPRACH detection occasion.');
    end
    occasions(end+1,1)=occasion; %#ok<AGROW>
    ready(occasion)=tick;
end
end

function [groups,ids]=indexTruth(events,available)
groups=struct('occasionId',{},'nInit',{},'attemptIds',{}); ids=zeros(0,1);
if ~available, return; end
for k=1:numel(events)
    e=events(k); if ~strcmp(e.kind,'msg1'), continue; end
    f=e.fields;
    if ~all(isfield(f,{'attemptId','occasionId','nInit'}))
        diagnosticsError('Msg1 truth event lacks collision-group keys.');
    end
    id=integerValue(f.attemptId,'attemptId',1);
    occasion=integerValue(f.occasionId,'occasionId',0);
    nInit=integerValue(f.nInit,'nInit',0);
    if any(ids==id), diagnosticsError('Duplicate Msg1 attempt ID.'); end
    ids(end+1,1)=id; %#ok<AGROW>
    at=find([groups.occasionId]==occasion & [groups.nInit]==nInit,1);
    if isempty(at)
        groups(end+1)=struct('occasionId',occasion,'nInit',nInit,'attemptIds',id); %#ok<AGROW>
    else
        groups(at).attemptIds(end+1)=id;
    end
end
end

function components=indexComponents(events,available,ready,detected)
components=struct('occasionId',{},'attemptId',{},'startSample',{}, ...
    'endSampleExclusive',{},'readyTick',{});
if ~available, return; end
seen=zeros(0,1);
for k=1:numel(events)
    e=events(k); if ~strcmp(e.kind,'nprach_component'), continue; end
    f=e.fields;
    needed={'occasionId','attemptId','startSample','endSampleExclusive'};
    if ~all(isfield(f,needed)), diagnosticsError('NPRACH component is incomplete.'); end
    occasion=integerValue(f.occasionId,'occasionId',0);
    id=integerValue(f.attemptId,'attemptId',1);
    a=integerValue(f.startSample,'startSample',0);
    b=integerValue(f.endSampleExclusive,'endSampleExclusive',1);
    if b<=a||any(seen==id), diagnosticsError('Invalid or duplicate NPRACH receiver component.'); end
    seen(end+1,1)=id; %#ok<AGROW>
    if ~any(detected==occasion)||~isKey(ready,occasion)
        diagnosticsError('NPRACH component has no matching detection.');
    end
    readyTick=ready(occasion);
    if e.tick~=readyTick, diagnosticsError('Component tick differs from detection readyTick.'); end
    components(end+1)=struct('occasionId',occasion,'attemptId',id, ...
        'startSample',a,'endSampleExclusive',b,'readyTick',readyTick); %#ok<AGROW>
end
end

function pairs=indexOverlaps(events,available,components,ready,horizon)
pairs=struct('readyTick',{},'attemptIds',{});
if ~available, return; end
seen=zeros(0,3);
for k=1:numel(events)
    e=events(k); if ~strcmp(e.kind,'nprach_overlap'), continue; end
    f=e.fields; needed={'occasionId','attemptIdA','attemptIdB','startSample', ...
        'endSampleExclusive','signalPowerAW','signalPowerBW'};
    if ~all(isfield(f,needed)), diagnosticsError('NPRACH overlap event is incomplete.'); end
    occasion=integerValue(f.occasionId,'occasionId',0);
    a=integerValue(f.attemptIdA,'attemptIdA',1); b=integerValue(f.attemptIdB,'attemptIdB',1);
    if a==b, diagnosticsError('An overlap pair needs two distinct attempts.'); end
    pair=sort([a b]); triple=[occasion pair];
    if ismember(triple,seen,'rows'), diagnosticsError('Duplicate or reversed physical overlap pair.'); end
    seen(end+1,:)=triple; %#ok<AGROW>
    ia=find([components.attemptId]==a & [components.occasionId]==occasion,1);
    ib=find([components.attemptId]==b & [components.occasionId]==occasion,1);
    if isempty(ia)||isempty(ib)
        diagnosticsError('Overlap pair references a missing receiver component.');
    end
    readyTick=components(ia).readyTick;
    if components(ib).readyTick~=readyTick||e.tick~=readyTick
        diagnosticsError('Overlap event tick differs from the shared receiver readyTick.');
    end
    start=max(components(ia).startSample,components(ib).startSample);
    finish=min(components(ia).endSampleExclusive,components(ib).endSampleExclusive);
    if start>=finish||f.startSample~=start||f.endSampleExclusive~=finish
        diagnosticsError('Overlap event does not match the components’ shared support.');
    end
    if readyTick<=horizon
        pairs(end+1)=struct('readyTick',readyTick,'attemptIds',pair); %#ok<AGROW>
    end
end
end

function [groupCount,attemptCount]=countLogical(groups,ready,s,e)
groupCount=0; ids=zeros(0,1);
for k=1:numel(groups)
    occasion=groups(k).occasionId;
    if numel(groups(k).attemptIds)<2||~isKey(ready,occasion), continue; end
    tick=ready(occasion);
    if tick>s&&tick<=e
        groupCount=groupCount+1;
        ids=[ids;groups(k).attemptIds(:)]; %#ok<AGROW>
    end
end
attemptCount=numel(unique(ids));
end

function count=retryCount(attempts,s,e)
ids=unique(double([attempts.packetId])); count=0;
for k=1:numel(ids)
    at=find(double([attempts.packetId])==ids(k));
    ordered=sortrows([[attempts(at).startTick].',[attempts(at).attemptId].'],[1 2]);
    if size(ordered,1)>1
        retryStarts=ordered(2:end,1);
        count=count+sum(retryStarts>=s&retryStarts<e);
    end
end
end

function value=integerValue(value,name,minimum)
if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<minimum||value~=fix(value)
    diagnosticsError('%s must be a finite integer >= %d.',name,minimum);
end
value=double(value);
end

function rows=emptyDiagnostics()
rows=table(zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    nan(0,1),zeros(0,1),nan(0,1),nan(0,1),false(0,1),false(0,1), ...
    false(0,1),false(0,1),false(0,1),zeros(0,1), ...
    'VariableNames',{'realizationId','windowId','startTick','endTick', ...
    'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
    'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
    'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
    'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
    'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'});
end

function diagnosticsError(message,varargin)
error('nbiot:dataset:Diagnostics',message,varargin{:});
end
