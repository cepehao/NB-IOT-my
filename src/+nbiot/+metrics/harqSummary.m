function h=harqSummary(journal,actualTick)
%HARQSUMMARY Separate real first CRC outcomes, retries and censored blocks.
%   Сводка HARQ по журналу: исход первой передачи, повторы, итог блоков, BLER первой и всех передач.
h=struct('schemaVersion',1,'available',~isempty(journal),'blocksStarted',0, ...
    'blocksAccepted',0,'blocksFailed',0,'blocksCensored',0,'attemptsStarted',0, ...
    'decodedAttempts',0,'crcFailures',0,'retryAttempts',0,'pendingAttempts',0, ...
    'firstDecoded',0,'firstCrcFailures',0,'firstPending',0, ...
    'firstReceiverDecoded',0,'firstReceiverCrcFailures',0,'firstReceiverPending',0, ...
    'firstReceiverBler',NaN,'receiverRetryAttempts',0, ...
    'transmissionsStarted',0,'retryTransmissions',0,'blocksTransmitted',0,'unmatchedEmissions',0, ...
    'firstTransmissionBler',NaN,'allAttemptBler',NaN, ...
    'acceptedProbability',NaN,'failedProbability',NaN);
if isempty(journal), return; end
required={'contextId','packetSequence','blockIndex','attempt'};
keys=cell(numel(journal),1);
scheduled=false(1,numel(journal));
for k=1:numel(journal)
    f=journal(k).fields;
    if strcmp(journal(k).kind,'unmatchedEmission')
        h.unmatchedEmissions=h.unmatchedEmissions+double(journal(k).tick<actualTick);
        keys{k}='unmatched'; continue;
    end
    if ~all(isfield(f,required)) || ~ismember(journal(k).kind,{'scheduled','emitted','decoded','terminal'})
        error('nbiot:metrics:HarqJournal','Invalid HARQ record identity or kind.');
    end
    values=[f.contextId f.packetSequence f.blockIndex f.attempt];
    if any(~isfinite(values)) || any(values~=fix(values)) || ...
            f.contextId<1 || f.packetSequence<0 || f.blockIndex<0 || f.attempt<1
        error('nbiot:metrics:HarqJournal','HARQ identity must contain valid integer indices.');
    end
    keys{k}=sprintf('%d:%d:%d',f.contextId,f.packetSequence,f.blockIndex);
    if strcmp(journal(k).kind,'scheduled')
        if ~isfield(f,'startTick') || ~isnumeric(f.startTick) || ...
                ~isscalar(f.startTick) || ~isreal(f.startTick) || ...
                ~isfinite(f.startTick) || f.startTick<0 || f.startTick~=fix(f.startTick)
            error('nbiot:metrics:HarqJournal','Scheduled startTick must be a nonnegative integer scalar.');
        end
        % The journal tick is reservation time; the grant may start later.
        scheduled(k)=journal(k).tick<actualTick && f.startTick<actualTick;
    end
end
visible=[journal.tick]<=actualTick;
blockKeys=unique(keys(scheduled)); h.blocksStarted=numel(blockKeys);
for b=1:numel(blockKeys)
    group=find(strcmp(keys,blockKeys{b}) & visible(:));
    starts=group(scheduled(group));
    decodes=group(strcmp({journal(group).kind},'decoded'));
    emitted=group(strcmp({journal(group).kind},'emitted') & [journal(group).tick]<actualTick);
    terminals=group(strcmp({journal(group).kind},'terminal'));
    ordinals=arrayfun(@(i) journal(i).fields.attempt,starts);
    decodedOrdinals=arrayfun(@(i) journal(i).fields.attempt,decodes);
    emittedOrdinals=arrayfun(@(i) journal(i).fields.attempt,emitted);
    if numel(unique(ordinals))~=numel(ordinals) || ...
            numel(unique(decodedOrdinals))~=numel(decodedOrdinals) || ...
            ~all(ismember(decodedOrdinals,ordinals)) || ~ismember(1,ordinals) || ...
            ~all(ismember(emittedOrdinals,ordinals)) || numel(unique(emittedOrdinals))~=numel(emittedOrdinals)
        error('nbiot:metrics:HarqJournal','Duplicate, missing or unmatched HARQ attempt.');
    end
    h.attemptsStarted=h.attemptsStarted+numel(starts);
    h.retryAttempts=h.retryAttempts+sum(ordinals>1);
    h.receiverRetryAttempts=h.receiverRetryAttempts+sum(ordinals>1);
    h.transmissionsStarted=h.transmissionsStarted+numel(emitted);
    h.retryTransmissions=h.retryTransmissions+max(0,numel(emitted)-1);
    h.blocksTransmitted=h.blocksTransmitted+double(~isempty(emitted));
    h.decodedAttempts=h.decodedAttempts+numel(decodes);
    h.pendingAttempts=h.pendingAttempts+sum(~ismember(ordinals,decodedOrdinals));
    first=find(decodedOrdinals==1);
    if isempty(first), h.firstReceiverPending=h.firstReceiverPending+1;
    else
        h.firstReceiverDecoded=h.firstReceiverDecoded+1;
        h.firstReceiverCrcFailures=h.firstReceiverCrcFailures+double(journal(decodes(first)).fields.crcError~=0);
    end
    if ~isempty(emittedOrdinals)
        first=find(decodedOrdinals==min(emittedOrdinals));
        if isempty(first), h.firstPending=h.firstPending+1;
        else
            h.firstDecoded=h.firstDecoded+1;
            h.firstCrcFailures=h.firstCrcFailures+double(journal(decodes(first)).fields.crcError~=0);
        end
    end
    for i=reshape(decodes,1,[])
        h.crcFailures=h.crcFailures+double(journal(i).fields.crcError~=0);
    end
    if isempty(terminals), h.blocksCensored=h.blocksCensored+1;
    else
        outcome=journal(terminals(end)).fields.outcome;
        switch outcome
            case 'accepted', h.blocksAccepted=h.blocksAccepted+1;
            case 'failed', h.blocksFailed=h.blocksFailed+1;
            otherwise, error('nbiot:metrics:HarqJournal','Unknown terminal outcome.');
        end
    end
end
h.firstTransmissionBler=ratio(h.firstCrcFailures,h.firstDecoded);
h.firstReceiverBler=ratio(h.firstReceiverCrcFailures,h.firstReceiverDecoded);
h.allAttemptBler=ratio(h.crcFailures,h.decodedAttempts);
h.acceptedProbability=ratio(h.blocksAccepted,h.blocksStarted);
h.failedProbability=ratio(h.blocksFailed,h.blocksStarted);
end

function value=ratio(n,d)
if d==0, value=NaN; else, value=n/d; end
end
