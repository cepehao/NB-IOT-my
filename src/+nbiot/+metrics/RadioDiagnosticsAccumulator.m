classdef RadioDiagnosticsAccumulator < handle
    %RADIODIAGNOSTICSACCUMULATOR Incremental, presentation-only radio summary.
    % The journal owner supplies append-only deltas. This object keeps the
    % accumulated event history by occasion and refreshes only changed ones.
    properties (Access=private)
        NInitValues
        DiagnosticFcn
        TruthEvents
        ObservedEvents
        ReceptionEvents
        AttemptIds
        AttemptOccasionIds
        AttemptUeIds
        CompleteOccasionIds
        TruthActiveMask
        ObservedActiveMask
        ReceptionActiveMask
        ContributionOccasionIds
        Contributions
        ContributionMetadata
        LastAsOfTick
    end

    methods
        function obj=RadioDiagnosticsAccumulator(nInitValues,diagnosticFcn)
            if nargin<1||~isnumeric(nInitValues)||~isreal(nInitValues)|| ...
                    ~isvector(nInitValues)||isempty(nInitValues)|| ...
                    any(~isfinite(nInitValues(:)))||any(nInitValues(:)<0)|| ...
                    any(nInitValues(:)~=fix(nInitValues(:)))
                error('nbiot:metrics:RadioDiagnosticsOptions', ...
                    'nInitValues must be a nonempty vector of unique nonnegative integers.');
            end
            nInitValues=double(nInitValues(:));
            if numel(unique(nInitValues))~=numel(nInitValues)
                error('nbiot:metrics:RadioDiagnosticsOptions', ...
                    'nInitValues must contain unique preamble indices.');
            end
            if nargin<2||isempty(diagnosticFcn)
                diagnosticFcn=str2func('nbiot.metrics.radioDiagnostics');
            elseif ~isa(diagnosticFcn,'function_handle')||~isscalar(diagnosticFcn)
                error('nbiot:metrics:RadioDiagnosticsOptions', ...
                    'The diagnostic callback must be a scalar function handle.');
            end

            obj.NInitValues=nInitValues;
            obj.DiagnosticFcn=diagnosticFcn;
            obj.TruthEvents=emptyEvents();
            obj.ObservedEvents=emptyEvents();
            obj.ReceptionEvents=emptyEvents();
            obj.AttemptIds=zeros(0,1);
            obj.AttemptOccasionIds=zeros(0,1);
            obj.AttemptUeIds=zeros(0,1);
            obj.CompleteOccasionIds=zeros(0,1);
            obj.TruthActiveMask=false(0,1);
            obj.ObservedActiveMask=false(0,1);
            obj.ReceptionActiveMask=false(0,1);
            obj.ContributionOccasionIds=zeros(0,1);
            obj.Contributions=cell(0,1);
            obj.ContributionMetadata=cell(0,1);
            obj.LastAsOfTick=NaN;
        end

        function live=update(obj,truthDelta,observedDelta,receptionDelta,asOfTick)
            validateEvents(truthDelta,'truthDelta');
            validateEvents(observedDelta,'observedDelta');
            validateEvents(receptionDelta,'receptionDelta');
            if ~isnumeric(asOfTick)||~isreal(asOfTick)||~isscalar(asOfTick)|| ...
                    ~isfinite(asOfTick)||asOfTick<0||asOfTick~=fix(asOfTick)
                error('nbiot:metrics:RadioDiagnosticsOptions', ...
                    'asOfTick must be a nonnegative integer.');
            end
            asOfTick=double(asOfTick);
            if isfinite(obj.LastAsOfTick)&&asOfTick<obj.LastAsOfTick
                error('nbiot:metrics:RadioDiagnosticsOptions', ...
                    'asOfTick cannot move backwards for an accumulator.');
            end

            obj.TruthEvents=appendEvents(obj.TruthEvents,truthDelta);
            obj.ObservedEvents=appendEvents(obj.ObservedEvents,observedDelta);
            obj.ReceptionEvents=appendEvents(obj.ReceptionEvents,receptionDelta);

            [truthActive,truthOccasions,truthAttemptIds,truthUeIds]= ...
                activeTruth(obj.TruthEvents,asOfTick);
            [observedActive,observedOccasions]= ...
                activeDetections(obj.ObservedEvents,asOfTick);
            [receptionActive,receptionOccasions,receptionKinds]= ...
                activeReception(obj.ReceptionEvents,asOfTick);

            activeMsg1=truthActive&strcmpKinds(obj.TruthEvents,'msg1');
            obj.AttemptIds=truthAttemptIds(activeMsg1);
            obj.AttemptOccasionIds=truthOccasions(activeMsg1);
            obj.AttemptUeIds=truthUeIds(activeMsg1);
            completeOccasions=unique(observedOccasions(observedActive));
            completeOccasions=completeOccasions(:);

            % radioDiagnostics rejects attempt IDs reused by two complete
            % occasions. Per-occasion calls would otherwise hide that error.
            completeAttemptMask=truthActive&strcmpKinds(obj.TruthEvents,'msg1')& ...
                ismember(truthOccasions,completeOccasions);
            completeAttemptIds=truthAttemptIds(completeAttemptMask);
            if numel(unique(completeAttemptIds))~=numel(completeAttemptIds)
                error('nbiot:metrics:RadioDiagnosticsEvent', ...
                    'A truth attempt ID must be unique.');
            end

            oldComplete=obj.CompleteOccasionIds;
            changed=zeros(0,1);
            changed=[changed;setdiff(completeOccasions,oldComplete)]; %#ok<AGROW>

            newTruth=truthActive&~padMask(obj.TruthActiveMask,numel(truthActive));
            for k=find(newTruth(:)).'
                if strcmp(obj.TruthEvents(k).kind,'msg1')
                    occasionId=truthOccasions(k);
                    if ismember(occasionId,completeOccasions)
                        changed(end+1,1)=occasionId; %#ok<AGROW>
                    end
                else
                    attemptId=truthAttemptIds(k);
                    if isfinite(attemptId)
                        [occasionId,found]=lookupAttempt(obj.AttemptIds, ...
                            obj.AttemptOccasionIds,attemptId);
                        if found&&ismember(occasionId,completeOccasions)
                            changed(end+1,1)=occasionId; %#ok<AGROW>
                        end
                    end
                end
            end

            newObserved=observedActive&~padMask(obj.ObservedActiveMask,numel(observedActive));
            for k=find(newObserved(:)).'
                occasionId=observedOccasions(k);
                if ismember(occasionId,completeOccasions)
                    changed(end+1,1)=occasionId; %#ok<AGROW>
                end
            end

            newReception=receptionActive&~padMask(obj.ReceptionActiveMask,numel(receptionActive));
            for k=find(newReception(:)).'
                occasionId=receptionOccasions(k);
                if strcmp(receptionKinds{k},'npusch_receiver')|| ...
                        ismember(occasionId,completeOccasions)
                    changed(end+1,1)=occasionId; %#ok<AGROW>
                end
            end

            % An active overlap outside a complete occasion cannot be
            % reconciled with the batch contract, which has no components for
            % that occasion yet. Fail closed instead of silently omitting it.
            activeOverlap=find(receptionActive&strcmpKinds(obj.ReceptionEvents,'nprach_overlap'));
            for k=activeOverlap(:).'
                occasionId=receptionOccasions(k);
                if ~ismember(occasionId,completeOccasions)
                    error('nbiot:metrics:RadioDiagnosticsEvent', ...
                        'An overlap event must refer to two logged components in its occasion.');
                end
            end

            changed=unique(changed);
            changed=changed(:);
            for occasionId=changed(:).'
                [truth,observed,reception]=obj.eventsForOccasion(occasionId, ...
                    asOfTick,completeOccasions,truthActive,truthOccasions, ...
                    truthAttemptIds,observedActive,observedOccasions, ...
                    receptionActive,receptionOccasions);
                contribution=obj.DiagnosticFcn(truth,observed,reception, ...
                    struct('actualTick',asOfTick,'nInitValues',obj.NInitValues));
                validateContribution(contribution);
                metadata=obj.metadataForOccasion(occasionId,contribution, ...
                    asOfTick,observedActive,observedOccasions,receptionActive, ...
                    receptionOccasions);
                obj.storeContribution(occasionId,contribution,metadata);
            end

            obj.CompleteOccasionIds=completeOccasions;
            obj.TruthActiveMask=truthActive;
            obj.ObservedActiveMask=observedActive;
            obj.ReceptionActiveMask=receptionActive;
            obj.LastAsOfTick=asOfTick;

            [summary,mergedMetadata]=obj.aggregate(asOfTick,completeOccasions);
            summary.lastEventTick=obj.latestEventTick(asOfTick,completeOccasions, ...
                truthActive,truthOccasions,observedActive,observedOccasions, ...
                receptionActive,receptionOccasions,receptionKinds,truthAttemptIds);
            perUe=obj.perUe(summary,mergedMetadata,completeOccasions, ...
                truthActive,truthOccasions,truthAttemptIds,truthUeIds, ...
                observedActive,observedOccasions,receptionActive, ...
                receptionOccasions,receptionKinds);

            status='pending';
            if summary.available, status='available'; end
            live=struct('asOfTick',asOfTick,'status',status, ...
                'summary',summary,'perUe',perUe);
        end
    end

    methods (Access=private)
        function [truth,observed,reception]=eventsForOccasion(obj,occasionId, ...
                horizon,completeOccasions,truthActive,truthOccasions, ...
                truthAttemptIds,observedActive,observedOccasions, ...
                receptionActive,receptionOccasions)
            truthMask=false(numel(obj.TruthEvents),1);
            for k=find(truthActive(:)).'
                e=obj.TruthEvents(k);
                if strcmp(e.kind,'msg1')
                    truthMask(k)=truthOccasions(k)==occasionId;
                else
                    [mappedOccasion,found]=lookupAttempt(obj.AttemptIds, ...
                        obj.AttemptOccasionIds,truthAttemptIds(k));
                    truthMask(k)=found&&mappedOccasion==occasionId;
                end
            end
            observedMask=observedActive(:)&observedOccasions(:)==occasionId;
            receptionMask=receptionActive(:)&receptionOccasions(:)==occasionId;
            truth=obj.TruthEvents(truthMask);
            observed=obj.ObservedEvents(observedMask);
            reception=obj.ReceptionEvents(receptionMask);

            % Keep each callback's inputs shaped like EventLog.all(), even
            % when the occasion currently has no events in one journal.
            truth=columnEvents(truth);
            observed=columnEvents(observed);
            reception=columnEvents(reception);
            %#ok<INUSD> horizon completeOccasions are explicit API context.
        end

        function metadata=metadataForOccasion(obj,occasionId,contribution, ...
                horizon,observedActive,observedOccasions,receptionActive, ...
                receptionOccasions)
            source=struct();
            source.perAttempt=zeros(numel(contribution.perAttempt),1);
            for j=1:numel(contribution.perAttempt)
                id=contribution.perAttempt(j).attemptId;
                matches=find(receptionActive(:)&strcmpKinds(obj.ReceptionEvents, ...
                    'nprach_component')&receptionOccasions(:)==occasionId& ...
                    eventFieldEquals(obj.ReceptionEvents,'attemptId',id));
                if numel(matches)~=1
                    aggregateError('A per-attempt row must map to one component event.');
                end
                source.perAttempt(j)=matches(1);
            end

            candidateOrder=zeros(0,2);
            detections=find(observedActive(:)&observedOccasions(:)==occasionId);
            for k=detections(:).'
                candidates=obj.ObservedEvents(k).fields.candidates;
                for j=1:numel(candidates)
                    candidateOrder(end+1,:)=[k j]; %#ok<AGROW>
                end
            end
            if size(candidateOrder,1)~=numel(contribution.receiverEstimates)
                aggregateError('Receiver estimate rows do not map to detection candidates.');
            end
            source.receiverEstimates=candidateOrder;

            source.npuschReceiverEstimates=find(receptionActive(:)& ...
                strcmpKinds(obj.ReceptionEvents,'npusch_receiver')& ...
                receptionOccasions(:)==occasionId);
            source.npuschReceiverEstimates=source.npuschReceiverEstimates(:);
            if numel(source.npuschReceiverEstimates)~= ...
                    numel(contribution.npuschReceiverEstimates)
                aggregateError('NPUSCH receiver rows do not map to source events.');
            end
            %#ok<INUSD> horizon is the current contribution horizon.
            metadata=source;
        end

        function storeContribution(obj,occasionId,contribution,metadata)
            index=find(obj.ContributionOccasionIds==occasionId,1);
            if isempty(index)
                obj.ContributionOccasionIds(end+1,1)=occasionId;
                obj.Contributions{end+1,1}=contribution;
                obj.ContributionMetadata{end+1,1}=metadata;
            else
                obj.Contributions{index}=contribution;
                obj.ContributionMetadata{index}=metadata;
            end
        end

        function [summary,metadata]=aggregate(obj,horizon,completeOccasions)
            summary=emptyDiagnostic(horizon);
            summary.available=~isempty(completeOccasions);
            summary.actualTick=horizon;
            preambleCountNames={'transmittedAttempts','transmittedKeys', ...
                'detectedCandidates','detectedKeys','misses','falseAlarms', ...
                'falseAlarmOpportunities'};
            collisionCountNames={'attempts','logicalGroups','logicalAttempts', ...
                'physicalOverlapPairs','physicalAttempts'};
            captureCountNames={'eligiblePairs','censoredPairs','equalPowerPairs', ...
                'capturedPairs'};
            preambleCounts=zeros(1,numel(preambleCountNames));
            collisionCounts=zeros(1,numel(collisionCountNames));
            captureCounts=zeros(1,numel(captureCountNames));
            strongSuccesses=0;
            weakSuccesses=0;

            for k=1:numel(obj.Contributions)
                value=obj.Contributions{k};
                for j=1:numel(preambleCountNames)
                    preambleCounts(j)=preambleCounts(j)+value.preamble.(preambleCountNames{j});
                end
                for j=1:numel(collisionCountNames)
                    collisionCounts(j)=collisionCounts(j)+value.collision.(collisionCountNames{j});
                end
                for j=1:numel(captureCountNames)
                    captureCounts(j)=captureCounts(j)+value.capture.(captureCountNames{j});
                end
                eligible=value.capture.eligiblePairs;
                if value.capture.capturedPairs>eligible
                    aggregateError('Captured pairs cannot exceed eligible pairs.');
                end
                validateRatio(value.capture.probability, ...
                    value.capture.capturedPairs,eligible,'capture probability');
                strongSuccesses=strongSuccesses+recoverNumerator( ...
                    value.capture.strongSuccessProbability,eligible, ...
                    'strongSuccessProbability');
                weakSuccesses=weakSuccesses+recoverNumerator( ...
                    value.capture.weakSuccessProbability,eligible, ...
                    'weakSuccessProbability');
            end

            summary.preamble=struct( ...
                'transmittedAttempts',preambleCounts(1), ...
                'transmittedKeys',preambleCounts(2), ...
                'detectedCandidates',preambleCounts(3), ...
                'detectedKeys',preambleCounts(4), ...
                'misses',preambleCounts(5), ...
                'falseAlarms',preambleCounts(6), ...
                'falseAlarmOpportunities',preambleCounts(7), ...
                'detectionProbability',ratio(preambleCounts(4),preambleCounts(2)), ...
                'missProbability',ratio(preambleCounts(5),preambleCounts(2)), ...
                'falseAlarmProbability',ratio(preambleCounts(6),preambleCounts(7)));
            summary.collision=struct( ...
                'attempts',collisionCounts(1), ...
                'logicalGroups',collisionCounts(2), ...
                'logicalAttempts',collisionCounts(3), ...
                'logicalAttemptProbability',ratio(collisionCounts(3),collisionCounts(1)), ...
                'physicalOverlapPairs',collisionCounts(4), ...
                'physicalAttempts',collisionCounts(5), ...
                'physicalAttemptProbability',ratio(collisionCounts(5),collisionCounts(1)));
            summary.capture=struct( ...
                'eligiblePairs',captureCounts(1), ...
                'censoredPairs',captureCounts(2), ...
                'equalPowerPairs',captureCounts(3), ...
                'capturedPairs',captureCounts(4), ...
                'probability',ratio(captureCounts(4),captureCounts(1)), ...
                'strongSuccessProbability',ratio(strongSuccesses,captureCounts(1)), ...
                'weakSuccessProbability',ratio(weakSuccesses,captureCounts(1)));

            [summary.perAttempt,metadata.perAttempt]=obj.collectRows('perAttempt', ...
                perAttemptTemplate(),false);
            [summary.receiverEstimates,metadata.receiverEstimates]= ...
                obj.collectRows('receiverEstimates',receiverEstimateTemplate(),true);
            [summary.npuschReceiverEstimates,metadata.npuschReceiverEstimates]= ...
                obj.collectRows('npuschReceiverEstimates',npuschEstimateTemplate(),false);
        end

        function [rows,order]=collectRows(obj,fieldName,rowTemplate,isPairOrder)
            rows=repmat(rowTemplate,0,1);
            if isPairOrder, order=zeros(0,2); else, order=zeros(0,1); end
            for k=1:numel(obj.Contributions)
                contribution=obj.Contributions{k};
                part=contribution.(fieldName);
                meta=obj.ContributionMetadata{k}.(fieldName);
                rows=[rows;part(:)]; %#ok<AGROW>
                order=[order;meta]; %#ok<AGROW>
            end
            if isempty(rows), return; end
            if isPairOrder
                [~,sortIndex]=sortrows(order,[1 2]);
            else
                [~,sortIndex]=sort(order,'ascend');
            end
            rows=rows(sortIndex);
            order=order(sortIndex,:);
            rows=rows(:).';
        end

        function lastTick=latestEventTick(obj,~,completeOccasions,truthActive, ...
                truthOccasions,observedActive,observedOccasions,receptionActive, ...
                receptionOccasions,receptionKinds,truthAttemptIds)
            ticks=zeros(0,1);
            for k=find(truthActive(:)).'
                e=obj.TruthEvents(k);
                if strcmp(e.kind,'msg1')
                    relevant=ismember(truthOccasions(k),completeOccasions);
                else
                    [occasionId,found]=lookupAttempt(obj.AttemptIds, ...
                        obj.AttemptOccasionIds,truthAttemptIds(k));
                    relevant=found&&ismember(occasionId,completeOccasions);
                end
                if relevant, ticks(end+1,1)=e.tick; end %#ok<AGROW>
            end
            for k=find(observedActive(:)).'
                if ismember(observedOccasions(k),completeOccasions)
                    ticks(end+1,1)=obj.ObservedEvents(k).tick; %#ok<AGROW>
                end
            end
            for k=find(receptionActive(:)).'
                if strcmp(receptionKinds{k},'npusch_receiver')|| ...
                        ismember(receptionOccasions(k),completeOccasions)
                    ticks(end+1,1)=obj.ReceptionEvents(k).tick; %#ok<AGROW>
                end
            end
            if isempty(ticks), lastTick=NaN; else, lastTick=max(ticks); end
        end

        function perUe=perUe(obj,summary,metadata,completeOccasions, ...
                truthActive,truthOccasions,truthAttemptIds,truthUeIds, ...
                observedActive,observedOccasions,receptionActive, ...
                receptionOccasions,receptionKinds)
            ueIds=zeros(0,1);
            for k=find(truthActive(:)&strcmpKinds(obj.TruthEvents,'msg1')).'
                if ismember(truthOccasions(k),completeOccasions)
                    ueIds(end+1,1)=truthUeIds(k); %#ok<AGROW>
                end
            end
            for k=1:numel(summary.perAttempt)
                ueIds(end+1,1)=summary.perAttempt(k).ueId; %#ok<AGROW>
            end
            for k=1:numel(summary.receiverEstimates)
                value=summary.receiverEstimates(k).ueId;
                if isfinite(value), ueIds(end+1,1)=value; end %#ok<AGROW>
            end
            for k=1:numel(summary.npuschReceiverEstimates)
                value=summary.npuschReceiverEstimates(k).ueId;
                if isfinite(value), ueIds(end+1,1)=value; end %#ok<AGROW>
            end
            for k=find(receptionActive(:)&strcmpKinds(obj.ReceptionEvents,'npusch_receiver')).'
                if ismember(receptionOccasions(k),completeOccasions)|| ...
                        ~isempty(find(metadata.npuschReceiverEstimates==k,1))
                    f=obj.ReceptionEvents(k).fields;
                    if isfield(f,'ueId')&&isnumeric(f.ueId)&&isscalar(f.ueId)&&isfinite(f.ueId)
                        ueIds(end+1,1)=double(f.ueId); %#ok<AGROW>
                    end
                end
            end
            ueIds=unique(ueIds);
            perUe=repmat(perUeTemplate(),numel(ueIds),1);
            for row=1:numel(ueIds)
                ueId=ueIds(row);
                attemptMask=[summary.perAttempt.ueId]==ueId;
                estimateMask=isfinite([summary.receiverEstimates.ueId])& ...
                    [summary.receiverEstimates.ueId]==ueId;
                npuschMask=isfinite([summary.npuschReceiverEstimates.ueId])& ...
                    [summary.npuschReceiverEstimates.ueId]==ueId;
                perUe(row).ueId=ueId;
                perUe(row).perAttempt=summary.perAttempt(attemptMask);
                perUe(row).receiverEstimates=summary.receiverEstimates(estimateMask);
                perUe(row).npuschReceiverEstimates= ...
                    summary.npuschReceiverEstimates(npuschMask);

                bestTick=-Inf;
                bestSource=0;
                for j=find(attemptMask)
                    source=metadata.perAttempt(j);
                    tick=obj.ReceptionEvents(source).tick;
                    if tick>bestTick||(tick==bestTick&&source>bestSource)
                        bestTick=tick;
                        bestSource=source;
                        perUe(row).sinrDb=summary.perAttempt(j).sinrDb;
                        perUe(row).sinrTick=tick;
                        perUe(row).sinrAvailable=isfinite(summary.perAttempt(j).sinrDb);
                    end
                end

                lastTick=NaN;
                for k=find(truthActive(:)&strcmpKinds(obj.TruthEvents,'msg1')).'
                    if ~ismember(truthOccasions(k),completeOccasions), continue; end
                    if truthUeIds(k)==ueId
                        lastTick=maxFinite(lastTick,obj.TruthEvents(k).tick);
                    end
                end
                for k=find(truthActive(:)&~strcmpKinds(obj.TruthEvents,'msg1')).'
                    [occasionId,found]=lookupAttempt(obj.AttemptIds, ...
                        obj.AttemptOccasionIds,truthAttemptIds(k));
                    if found&&ismember(occasionId,completeOccasions)
                        [~,ue,foundUe]=lookupAttemptUe(obj.AttemptIds, ...
                            obj.AttemptOccasionIds,obj.AttemptUeIds,truthAttemptIds(k));
                        if foundUe&&ue==ueId
                            lastTick=maxFinite(lastTick,obj.TruthEvents(k).tick);
                        end
                    end
                end
                for j=find(attemptMask)
                    lastTick=maxFinite(lastTick,obj.ReceptionEvents(metadata.perAttempt(j)).tick);
                end
                for j=find(estimateMask)
                    source=metadata.receiverEstimates(j,1);
                    lastTick=maxFinite(lastTick,obj.ObservedEvents(source).tick);
                end
                for j=find(npuschMask)
                    source=metadata.npuschReceiverEstimates(j);
                    lastTick=maxFinite(lastTick,obj.ReceptionEvents(source).tick);
                end
                for k=find(receptionActive(:)&strcmpKinds(obj.ReceptionEvents,'nprach_overlap')).'
                    if ~ismember(receptionOccasions(k),completeOccasions), continue; end
                    f=obj.ReceptionEvents(k).fields;
                    ids=[f.attemptIdA f.attemptIdB];
                    for id=ids
                        [~,ue,foundUe]=lookupAttemptUe(obj.AttemptIds, ...
                            obj.AttemptOccasionIds,obj.AttemptUeIds,id);
                        if foundUe&&ue==ueId
                            lastTick=maxFinite(lastTick,obj.ReceptionEvents(k).tick);
                        end
                    end
                end
                perUe(row).lastEventTick=lastTick;
            end
            %#ok<INUSD> observedActive and observedOccasions support future per-UE labels.
        end
    end
end

function validateEvents(events,name)
if ~isstruct(events)||~all(isfield(events,{'tick','kind','fields'}))
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        '%s must be an EventLog struct array.',name);
end
for k=1:numel(events)
    if ~isnumeric(events(k).tick)||~isreal(events(k).tick)|| ...
            ~isscalar(events(k).tick)||~isfinite(events(k).tick)|| ...
            events(k).tick<0||~ischar(events(k).kind)|| ...
            ~isscalar(events(k).fields)||~isstruct(events(k).fields)
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            '%s contains a malformed event.',name);
    end
end
end

function events=emptyEvents()
events=struct('tick',{},'kind',{},'fields',{});
end

function result=appendEvents(first,second)
if isempty(second), result=first; return; end
second=columnEvents(second);
if isempty(first), result=second; else, result=[first(:);second]; end
end

function events=columnEvents(events)
events=events(:);
end

function mask=padMask(oldMask,newLength)
mask=false(newLength,1);
count=min(numel(oldMask),newLength);
if count>0, mask(1:count)=oldMask(1:count); end
end

function [mask,occasionIds,attemptIds,ueIds]=activeTruth(events,horizon)
mask=false(numel(events),1);
occasionIds=NaN(numel(events),1);
attemptIds=NaN(numel(events),1);
ueIds=NaN(numel(events),1);
for k=1:numel(events)
    e=events(k);
    if strcmp(e.kind,'msg1')&&e.tick<horizon
        requireFields(e.fields,{'attemptId','ueId','occasionId','nInit'},'msg1');
        mask(k)=true;
        attemptIds(k)=validInteger(e.fields.attemptId,'attemptId',1);
        ueIds(k)=validInteger(e.fields.ueId,'ueId',1);
        occasionIds(k)=validInteger(e.fields.occasionId,'occasionId',0);
        validInteger(e.fields.nInit,'nInit',0);
    elseif any(strcmp(e.kind,{'ra_success','ra_failure'}))&&e.tick<=horizon
        requireFields(e.fields,{'attemptId'},e.kind);
        mask(k)=true;
        attemptIds(k)=validInteger(e.fields.attemptId,'attemptId',1);
    end
end
end

function [mask,occasionIds]=activeDetections(events,horizon)
mask=false(numel(events),1);
occasionIds=NaN(numel(events),1);
for k=1:numel(events)
    e=events(k);
    if ~strcmp(e.kind,'nprach_detection')||e.tick>horizon, continue; end
    requireFields(e.fields,{'occasionId','candidates'},'nprach_detection');
    readyTick=double(e.tick);
    if isfield(e.fields,'readyTick'), readyTick=double(e.fields.readyTick); end
    if ~isscalar(readyTick)||~isfinite(readyTick)||readyTick>horizon, continue; end
    occasionIds(k)=validInteger(e.fields.occasionId,'occasionId',0);
    mask(k)=true;
end
end

function [mask,occasionIds,kinds]=activeReception(events,horizon)
mask=false(numel(events),1);
occasionIds=NaN(numel(events),1);
kinds=cell(numel(events),1);
componentFields={'occasionId','attemptId','ueId','nInit','startSample', ...
    'endSampleExclusive','signalPowerW','interferencePowerW','noisePowerW', ...
    'configuredDelaySeconds','configuredCfoHz'};
overlapFields={'occasionId','attemptIdA','attemptIdB','startSample', ...
    'endSampleExclusive','signalPowerAW','signalPowerBW'};
npuschFields={'contextId','occasionId','nInit','channel', ...
    'estimatedDelaySeconds','estimatedCfoHz','configuredDelaySeconds', ...
    'configuredCfoHz','noiseEstimate'};
for k=1:numel(events)
    e=events(k);
    if e.tick>horizon, continue; end
    if strcmp(e.kind,'nprach_component')
        requireFields(e.fields,componentFields,'nprach_component');
        validInteger(e.fields.attemptId,'attemptId',1);
    elseif strcmp(e.kind,'nprach_overlap')
        requireFields(e.fields,overlapFields,'nprach_overlap');
    elseif strcmp(e.kind,'npusch_receiver')
        requireFields(e.fields,npuschFields,'npusch_receiver');
    else
        continue;
    end
    occasionIds(k)=validInteger(e.fields.occasionId,'occasionId',0);
    mask(k)=true;
    kinds{k}=e.kind;
end
end

function validateContribution(value)
if ~isstruct(value)||~isscalar(value)|| ...
        ~all(isfield(value,{'available','actualTick','preamble','collision', ...
        'capture','perAttempt','receiverEstimates','npuschReceiverEstimates'}))|| ...
        ~all(isfield(value.preamble,{'transmittedAttempts','transmittedKeys', ...
        'detectedCandidates','detectedKeys','misses','falseAlarms', ...
        'falseAlarmOpportunities','detectionProbability','missProbability', ...
        'falseAlarmProbability'}))|| ...
        ~all(isfield(value.collision,{'attempts','logicalGroups','logicalAttempts', ...
        'logicalAttemptProbability','physicalOverlapPairs','physicalAttempts', ...
        'physicalAttemptProbability'}))|| ...
        ~all(isfield(value.capture,{'eligiblePairs','censoredPairs', ...
        'equalPowerPairs','capturedPairs','probability', ...
        'strongSuccessProbability','weakSuccessProbability'}))|| ...
        ~isstruct(value.perAttempt)||~isstruct(value.receiverEstimates)|| ...
        ~isstruct(value.npuschReceiverEstimates)
    aggregateError('The diagnostic callback returned an incompatible structure.');
end
countPaths={ ...
    'preamble.transmittedAttempts','preamble.transmittedKeys', ...
    'preamble.detectedCandidates','preamble.detectedKeys','preamble.misses', ...
    'preamble.falseAlarms','preamble.falseAlarmOpportunities', ...
    'collision.attempts','collision.logicalGroups','collision.logicalAttempts', ...
    'collision.physicalOverlapPairs','collision.physicalAttempts', ...
    'capture.eligiblePairs','capture.censoredPairs','capture.equalPowerPairs', ...
    'capture.capturedPairs'};
for k=1:numel(countPaths)
    parts=strsplit(countPaths{k},'.');
    number=value.(parts{1}).(parts{2});
    if ~isnumeric(number)||~isreal(number)||~isscalar(number)|| ...
            ~isfinite(number)||number<0||number~=fix(number)
        aggregateError('Diagnostic counts must be finite nonnegative integers.');
    end
end
end

function diagnostics=emptyDiagnostic(actualTick)
diagnostics=struct();
diagnostics.available=false;
diagnostics.actualTick=actualTick;
diagnostics.preamble=struct( ...
    'transmittedAttempts',0,'transmittedKeys',0,'detectedCandidates',0, ...
    'detectedKeys',0,'misses',0,'falseAlarms',0,'falseAlarmOpportunities',0, ...
    'detectionProbability',NaN,'missProbability',NaN,'falseAlarmProbability',NaN);
diagnostics.collision=struct( ...
    'attempts',0,'logicalGroups',0,'logicalAttempts',0, ...
    'logicalAttemptProbability',NaN,'physicalOverlapPairs',0, ...
    'physicalAttempts',0,'physicalAttemptProbability',NaN);
diagnostics.capture=struct( ...
    'eligiblePairs',0,'censoredPairs',0,'equalPowerPairs',0,'capturedPairs',0, ...
    'probability',NaN,'strongSuccessProbability',NaN,'weakSuccessProbability',NaN);
diagnostics.perAttempt=repmat(perAttemptTemplate(),0,1);
diagnostics.receiverEstimates=repmat(receiverEstimateTemplate(),0,1);
diagnostics.npuschReceiverEstimates=repmat(npuschEstimateTemplate(),0,1);
end

function c=perAttemptTemplate()
c=struct('occasionId',0,'attemptId',0,'ueId',0,'nInit',0, ...
    'receivedPowerW',NaN,'interferencePowerW',NaN,'noisePowerW',NaN, ...
    'sinrDb',NaN,'provenance','diagnosticTruth');
end

function c=receiverEstimateTemplate()
c=struct('occasionId',0,'nInit',0,'attemptId',NaN,'ueId',NaN, ...
    'estimatedDelaySeconds',NaN,'configuredDelaySeconds',NaN, ...
    'delayErrorSeconds',NaN,'estimatedCfoHz',NaN,'configuredCfoHz',NaN, ...
    'cfoErrorHz',NaN,'truthAvailable',false);
end

function c=npuschEstimateTemplate()
c=struct('contextId',0,'occasionId',0,'nInit',0,'attemptId',NaN,'ueId',NaN, ...
    'channel','','estimatedDelaySeconds',NaN,'configuredDelaySeconds',NaN, ...
    'delayErrorSeconds',NaN,'estimatedCfoHz',NaN,'configuredCfoHz',NaN, ...
    'cfoErrorHz',NaN,'noiseEstimate',NaN,'truthAvailable',false);
end

function c=perUeTemplate()
c=struct('ueId',0,'sinrAvailable',false,'sinrDb',NaN,'sinrTick',NaN, ...
    'lastEventTick',NaN,'perAttempt',repmat(perAttemptTemplate(),0,1), ...
    'receiverEstimates',repmat(receiverEstimateTemplate(),0,1), ...
    'npuschReceiverEstimates',repmat(npuschEstimateTemplate(),0,1));
end

function requireFields(value,names,label)
if ~isstruct(value)||~isscalar(value)||~all(isfield(value,names))
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        '%s is missing required fields.',label);
end
end

function value=validInteger(value,name,minimum)
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)|| ...
        value~=fix(value)||value<minimum
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        '%s must be a valid integer.',name);
end
value=double(value);
end

function value=ratio(numerator,denominator)
if denominator==0, value=NaN; else, value=numerator/denominator; end
end

function numerator=recoverNumerator(probability,denominator,label)
if denominator==0
    if ~isnumeric(probability)||~isscalar(probability)||~isnan(probability)
        aggregateError('Capture probability must be NaN when there are no eligible pairs.');
    end
    numerator=0;
    return;
end
if ~isnumeric(probability)||~isreal(probability)||~isscalar(probability)|| ...
        ~isfinite(probability)
    aggregateError(['Capture ',label,' must be finite for eligible pairs.']);
end
raw=double(probability)*double(denominator);
nearest=round(raw);
tolerance=1e-9*max(1,abs(raw));
if abs(raw-nearest)>tolerance||nearest<0||nearest>denominator
    aggregateError(['Capture ',label,' does not recover an integer numerator.']);
end
numerator=nearest;
end

function validateRatio(probability,numerator,denominator,label)
if denominator==0
    if ~isnumeric(probability)||~isscalar(probability)||~isnan(probability)
        aggregateError([label,' must be NaN when its denominator is zero.']);
    end
    return;
end
if ~isnumeric(probability)||~isreal(probability)||~isscalar(probability)|| ...
        ~isfinite(probability)||abs(double(probability)-double(numerator)/double(denominator))>1e-12
    aggregateError([label,' must equal its integer numerator divided by denominator.']);
end
end

function [occasionId,found]=lookupAttempt(attemptIds,occasionIds,attemptId)
matches=find(attemptIds==attemptId);
found=~isempty(matches);
if ~found, occasionId=NaN; return; end
if numel(matches)>1&&numel(unique(occasionIds(matches)))>1
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'A truth attempt ID must be unique.');
end
occasionId=occasionIds(matches(1));
end

function [occasionId,ueId,found]=lookupAttemptUe(attemptIds,occasionIds,ueIds,attemptId)
[occasionId,found]=lookupAttempt(attemptIds,occasionIds,attemptId);
if ~found, ueId=NaN; return; end
matches=find(attemptIds==attemptId);
if numel(matches)>1&&numel(unique(ueIds(matches)))>1
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'A truth attempt ID must be unique.');
end
ueId=ueIds(matches(1));
end

function mask=strcmpKinds(events,kind)
if isempty(events), mask=false(0,1); else, mask=strcmp({events.kind}.',kind); end
end

function mask=eventFieldEquals(events,name,value)
mask=false(numel(events),1);
for k=1:numel(events)
    f=events(k).fields;
    if isfield(f,name)&&isnumeric(f.(name))&&isscalar(f.(name))&& ...
            isfinite(f.(name))&&f.(name)==value
        mask(k)=true;
    end
end
end

function value=maxFinite(current,candidate)
if isnan(current)||candidate>current, value=candidate; else, value=current; end
end

function aggregateError(message)
error('nbiot:metrics:RadioDiagnosticsAggregate','%s',message);
end
