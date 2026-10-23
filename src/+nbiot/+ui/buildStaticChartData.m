function data=buildStaticChartData(result)
%BUILDSTATICCHARTDATA Derive explicit per-window diagnostics for completed UI results.
required={'config','kpiTimeSeries','dataset','raLog','packetLog','observedLog','truthLog'};
if ~isstruct(result)||~isscalar(result)||~all(isfield(result,required))|| ...
        ~isstruct(result.dataset)||~isfield(result.dataset,'targets')|| ...
        ~istable(result.kpiTimeSeries)||~istable(result.dataset.targets)
    error('nbiot:ui:ChartResult','A simulation result with window KPIs and targets is required.');
end
series=result.kpiTimeSeries; targets=result.dataset.targets;
seriesFields={'windowId','startTick','endTick','raSucceededInWindow','throughputBitsPerSecond'};
targetFields={'windowId','startTick','endTick','meanRaUe','meanActiveUe'};
if ~all(ismember(seriesFields,series.Properties.VariableNames))|| ...
        ~all(ismember(targetFields,targets.Properties.VariableNames))
    error('nbiot:ui:ChartResult','Result window tables do not match the supported schema.');
end
if numel(unique(series.windowId))~=height(series)||numel(unique(targets.windowId))~=height(targets)
    error('nbiot:ui:ChartResult','Window identifiers must be unique within a result.');
end
[matched,targetIndex]=ismember(series.windowId,targets.windowId);
seriesIndex=find(matched);
targetIndex=targetIndex(matched);
aligned=series.startTick(matched)==targets.startTick(targetIndex) & ...
    series.endTick(matched)==targets.endTick(targetIndex);
% A stopped run may have an unfinished trailing KPI window with no closed target row.
seriesIndex=seriesIndex(aligned); targetIndex=targetIndex(aligned);
series=series(seriesIndex,:); targets=targets(targetIndex,:);

data=table(double(series.windowId),double(series.startTick),double(series.endTick), ...
    double(series.endTick)*result.config.simulation.tickSeconds, ...
    double(targets.meanActiveUe),double(targets.meanRaUe), ...
    NaN(height(series),1),NaN(height(series),1), ...
    double(series.raSucceededInWindow), ...
    repmat(double(result.config.policy.accessProbability),height(series),1), ...
    NaN(height(series),1), ...
    repmat(double(result.config.policy.raShare),height(series),1), ...
    NaN(height(series),1),double(series.throughputBitsPerSecond), ...
    NaN(height(series),1),NaN(height(series),1), ...
    NaN(height(series),1),NaN(height(series),1), ...
    'VariableNames',{'windowId','startTick','endTick','endTimeSeconds', ...
    'meanActiveUe','actualLoadMeanRaUe','predictedLoadMeanRaUe', ...
    'collisionProbability','successfulRa','staticAccessProbability', ...
    'adaptiveAccessProbability','staticRaShare','adaptiveRaShare', ...
    'throughputBitsPerSecond','meanDeliveryDelaySeconds','dataBler', ...
    'ulOccupancy','dlOccupancy'});

for window=1:height(data)
    first=data.startTick(window); last=data.endTick(window);
    attempts=result.raLog;
    if ~isempty(attempts)
        requireFields(attempts,{'startTick','collision'},'random-access log');
        starts=double([attempts.startTick]);
        inWindow=starts>=first & starts<last;
        if any(inWindow), data.collisionProbability(window)=mean(double([attempts(inWindow).collision])); end
    end
    packets=result.packetLog;
    if ~isempty(packets)
        requireFields(packets,{'status','createdTick','deliveredTick'},'packet log');
        delivered=strcmp({packets.status},'delivered');
        deliveryTicks=double([packets.deliveredTick]);
        inWindow=delivered & deliveryTicks>first & deliveryTicks<=last;
        if any(inWindow)
            delayTicks=deliveryTicks(inWindow)-double([packets(inWindow).createdTick]);
            data.meanDeliveryDelaySeconds(window)=mean(delayTicks)*result.config.simulation.tickSeconds;
        end
    end
    data.dataBler(window)=windowDataBler(result.observedLog,first,last);
    [data.ulOccupancy(window),data.dlOccupancy(window)]= ...
        windowOccupancy(result.truthLog,result.config,first,last);
end
end

function rate=windowDataBler(events,first,last)
decoded=0; failed=0;
for k=1:numel(events)
    event=events(k);
    if event.tick<=first||event.tick>last||~strcmp(event.kind,'phy_decode'), continue; end
    fields=event.fields;
    if ~isfield(fields,'receiverId')||fields.receiverId~=0|| ...
            ~isfield(fields,'hasCrc')||~fields.hasCrc|| ...
            ~isfield(fields,'channel')||~strcmp(fields.channel,'Data')||~isfield(fields,'crcError')
        continue;
    end
    decoded=decoded+1; failed=failed+double(fields.crcError~=0);
end
if decoded==0, rate=NaN; else, rate=failed/decoded; end
end

function [ulRate,dlRate]=windowOccupancy(events,cfg,first,last)
width=last-first;
if width<=0, error('nbiot:ui:ChartResult','Chart windows must have positive duration.'); end
ulUsed=false(2*width,48); dlUsed=false(width,1);
for k=1:numel(events)
    event=events(k);
    if ~strcmp(event.kind,'transmission'), continue; end
    f=event.fields;
    if ~all(isfield(f,{'direction','ticks','frequencyStartHz','bandwidthHz'}))
        error('nbiot:ui:ChartResult','A transmission is missing resource coordinates.');
    end
    ticks=double(f.ticks(:)); inWindow=ticks>=first & ticks<last;
    if ~any(inWindow), continue; end
    localTicks=ticks(inWindow)-first;
    if strcmpi(f.direction,'UL')
        firstBin=double(f.frequencyStartHz)/3750;
        binCount=double(f.bandwidthHz)/3750;
        if firstBin~=fix(firstBin)||binCount<1||binCount~=fix(binCount)
            error('nbiot:ui:ChartResult','UL allocations must align to the supported 3.75 kHz grid.');
        end
        columns=firstBin+(1:binCount);
        if any(columns<1|columns>48)
            error('nbiot:ui:ChartResult','UL allocation is outside the supported resource grid.');
        end
        rows=reshape([2*localTicks+1 2*localTicks+2].',[],1);
        ulUsed(rows,columns)=true;
    elseif strcmpi(f.direction,'DL')
        dlUsed(localTicks+1)=true;
    end
end
ulRate=sum(ulUsed,'all')/numel(ulUsed);
mask=nbiot.scheduler.mandatoryDlMask(last,cfg.cell.cellId);
available=~mask(first+1:last);
if any(available)
    dlRate=sum(dlUsed&available)/sum(available);
else
    dlRate=NaN;
end
end

function requireFields(value,fields,label)
if ~isstruct(value)||~all(isfield(value,fields))
    error('nbiot:ui:ChartResult','The %s does not match the supported result schema.',label);
end
end
