function series=windowKpi(cfg,packets,attempts,observed,actualTick,queueSamples,controllerLog)
%WINDOWKPI Временные ряды KPI по окнам 500 мс (ТЗ §27, графики ТЗ §46.9).
%   Два вида знаменателей: события, произошедшие в окне (доставлено/отброшено/начато в окне), и
%   когорта пакетов, созданных в окне (их итоговая доля доставки) — их нельзя смешивать.
%   Также throughput окна, очереди и число решений/переключений контроллера.
names={'windowId','startTick','endTick','created','deliveredInWindow','droppedInWindow', ...
    'cohortDelivered','cohortDropped','cohortUnfinished','cohortDeliveryProbability', ...
    'raStarted','raSucceededInWindow','raFailedInWindow','ulTbDecoded','ulCrcFailures','throughputBitsPerSecond'};
names=[names,{'meanBsQueueLength','maxBsQueueLength','meanUeQueueLength', ...
    'maxUeQueueLength','controllerApplicable','controllerDecisions','configurationSwitches'}];
if nargin<6, queueSamples=zeros(0,3); end
if nargin<7, controllerLog=struct([]); end
rows={};
for first=0:cfg.dataset.windowTicks:actualTick-1
    last=min(first+cfg.dataset.windowTicks,actualTick);
    created=0; delivered=0; dropped=0; cohortDelivered=0; cohortDropped=0; cohortUnfinished=0;
    for p=reshape(packets,1,[])
        inCohort=double(p.createdTick)>=first && double(p.createdTick)<last;
        created=created+inCohort;
        delivered=delivered+(strcmp(p.status,'delivered') && p.deliveredTick>first && p.deliveredTick<=last);
        dropped=dropped+(strcmp(p.status,'dropped') && p.terminalTick>=first && p.terminalTick<last);
        if inCohort
            cohortDelivered=cohortDelivered+strcmp(p.status,'delivered');
            cohortDropped=cohortDropped+strcmp(p.status,'dropped');
            cohortUnfinished=cohortUnfinished+strcmp(p.status,'unfinished');
        end
    end
    started=0; succeeded=0; failed=0;
    for a=reshape(attempts,1,[])
        started=started+(a.startTick>=first && a.startTick<last);
        succeeded=succeeded+(strcmp(a.status,'success') && a.endTick>first && a.endTick<=last);
        failed=failed+(strcmp(a.status,'failure') && a.endTick>=first && a.endTick<last);
    end
    decoded=0; crcFailures=0;
    for e=reshape(observed,1,[])
        if e.tick>first && e.tick<=last && strcmp(e.kind,'phy_decode') && e.fields.hasCrc
            decoded=decoded+1; crcFailures=crcFailures+double(e.fields.crcError~=0);
        end
    end
    if created==0, probability=NaN; else, probability=cohortDelivered/created; end
    throughput=delivered*cfg.traffic.packetBytes*8/((last-first)*cfg.simulation.tickSeconds);
    queues=[];
    for e=reshape(observed,1,[])
        if e.tick>=first && e.tick<last && strcmp(e.kind,'bs_queue')
            queues(end+1)=e.fields.pendingRequests; %#ok<AGROW>
        end
    end
    q=queueSamples(queueSamples(:,1)>=first & queueSamples(:,1)<last,:);
    meanUe=NaN; maxUe=NaN;
    if ~isempty(q), meanUe=sum(q(:,2))/(size(q,1)*cfg.simulation.numUE); maxUe=max(q(:,3)); end
    maxBs=NaN; if ~isempty(queues), maxBs=max(queues); end
    controllerApplicable=~strcmp(char(string(cfg.policy.name)),'Static');
    controllerDecisions=NaN; configurationSwitches=NaN;
    if controllerApplicable
        controllerDecisions=0; configurationSwitches=0;
        if ~isempty(controllerLog)
            decisionTicks=[controllerLog.decisionTick];
            inWindow=decisionTicks>=first&decisionTicks<last;
            controllerDecisions=sum(inWindow);
            switchTicks=decisionTicks([controllerLog.switched]);
            configurationSwitches=sum(switchTicks>=first&switchTicks<last);
        end
    end
    rows(end+1,:)={floor(first/cfg.dataset.windowTicks)+1,first,last,created,delivered,dropped, ...
        cohortDelivered,cohortDropped,cohortUnfinished,probability,started,succeeded,failed,decoded,crcFailures,throughput, ...
        mean(queues),maxBs,meanUe,maxUe,controllerApplicable,controllerDecisions,configurationSwitches}; %#ok<AGROW>
end
if isempty(rows), series=array2table(zeros(0,numel(names)),'VariableNames',names);
else, series=cell2table(rows,'VariableNames',names); end
series.Properties.Description='Arrivals/drops/starts use [start,end); receiver completions use (start,end]. Cohorts classified at export horizon.';
end
