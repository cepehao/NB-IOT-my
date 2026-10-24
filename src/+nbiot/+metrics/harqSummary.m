function h=harqSummary(journal,actualTick)
%HARQSUMMARY Separate real first CRC outcomes, retries and censored blocks.
%   Сводка HARQ по журналу: исход первой передачи, повторы, итог блоков, BLER первой и всех передач.
% Заготовка сводки: все счётчики нулевые, BLER и вероятности — NaN; available — есть ли журнал.
h=struct('schemaVersion',1,'available',~isempty(journal),'blocksStarted',0, ...
    'blocksAccepted',0,'blocksFailed',0,'blocksCensored',0,'attemptsStarted',0, ...
    'decodedAttempts',0,'crcFailures',0,'retryAttempts',0,'pendingAttempts',0, ...
    'firstDecoded',0,'firstCrcFailures',0,'firstPending',0, ...
    'firstReceiverDecoded',0,'firstReceiverCrcFailures',0,'firstReceiverPending',0, ...
    'firstReceiverBler',NaN,'receiverRetryAttempts',0, ...
    'transmissionsStarted',0,'retryTransmissions',0,'blocksTransmitted',0,'unmatchedEmissions',0, ...
    'firstTransmissionBler',NaN,'allAttemptBler',NaN, ...
    'acceptedProbability',NaN,'failedProbability',NaN);
% Журнала нет — сводка пустая.
if isempty(journal), return; end
% Обязательные поля идентификатора блока: контекст, номер пакета, индекс блока, номер передачи.
required={'contextId','packetSequence','blockIndex','attempt'};
% Ключ блока для каждого события.
keys=cell(numel(journal),1);
% Какие события — «назначено» (начало передачи HARQ).
scheduled=false(1,numel(journal));
% Для каждого события журнала:
for k=1:numel(journal)
    % поля;
    f=journal(k).fields;
    % передача без совпадения с назначением BS —
    if strcmp(journal(k).kind,'unmatchedEmission')
        % считаем (до горизонта);
        h.unmatchedEmissions=h.unmatchedEmissions+double(journal(k).tick<actualTick);
        % особый ключ; дальше.
        keys{k}='unmatched'; continue;
    end
    % Поля и вид события должны быть корректными.
    if ~all(isfield(f,required)) || ~ismember(journal(k).kind,{'scheduled','emitted','decoded','terminal'})
        error('nbiot:metrics:HarqJournal','Invalid HARQ record identity or kind.');
    end
    % Числовые компоненты идентификатора;
    values=[f.contextId f.packetSequence f.blockIndex f.attempt];
    % конечные неотрицательные целые (номер передачи >= 1).
    if any(~isfinite(values)) || any(values~=fix(values)) || ...
            f.contextId<1 || f.packetSequence<0 || f.blockIndex<0 || f.attempt<1
        error('nbiot:metrics:HarqJournal','HARQ identity must contain valid integer indices.');
    end
    % Ключ блока «контекст:пакет:блок».
    keys{k}=sprintf('%d:%d:%d',f.contextId,f.packetSequence,f.blockIndex);
    % Для события «назначено» —
    if strcmp(journal(k).kind,'scheduled')
        % тик начала передачи должен быть неотрицательным целым.
        if ~isfield(f,'startTick') || ~isnumeric(f.startTick) || ...
                ~isscalar(f.startTick) || ~isreal(f.startTick) || ...
                ~isfinite(f.startTick) || f.startTick<0 || f.startTick~=fix(f.startTick)
            error('nbiot:metrics:HarqJournal','Scheduled startTick must be a nonnegative integer scalar.');
        end
        % The journal tick is reservation time; the grant may start later.
        scheduled(k)=journal(k).tick<actualTick && f.startTick<actualTick;
    end
end
% События, видимые к горизонту.
visible=[journal.tick]<=actualTick;
% Блоки, для которых была хотя бы одна передача; их число.
blockKeys=unique(keys(scheduled)); h.blocksStarted=numel(blockKeys);
% Для каждого блока:
for b=1:numel(blockKeys)
    % его видимые события;
    group=find(strcmp(keys,blockKeys{b}) & visible(:));
    % назначения передач;
    starts=group(scheduled(group));
    % результаты декодирования;
    decodes=group(strcmp({journal(group).kind},'decoded'));
    % фактические излучения до горизонта;
    emitted=group(strcmp({journal(group).kind},'emitted') & [journal(group).tick]<actualTick);
    % итоговые события (accepted / failed);
    terminals=group(strcmp({journal(group).kind},'terminal'));
    % номера передач назначений;
    ordinals=arrayfun(@(i) journal(i).fields.attempt,starts);
    % номера передач декодирований;
    decodedOrdinals=arrayfun(@(i) journal(i).fields.attempt,decodes);
    % номера передач излучений;
    emittedOrdinals=arrayfun(@(i) journal(i).fields.attempt,emitted);
    % номера не повторяются, у каждого декодирования есть назначение —
    if numel(unique(ordinals))~=numel(ordinals) || ...
            numel(unique(decodedOrdinals))~=numel(decodedOrdinals) || ...
            ~all(ismember(decodedOrdinals,ordinals)) || ~ismember(1,ordinals) || ...
            ~all(ismember(emittedOrdinals,ordinals)) || numel(unique(emittedOrdinals))~=numel(emittedOrdinals)
        error('nbiot:metrics:HarqJournal','Duplicate, missing or unmatched HARQ attempt.');
    end
    % передач начато;
    h.attemptsStarted=h.attemptsStarted+numel(starts);
    % из них повторных (номер > 1);
    h.retryAttempts=h.retryAttempts+sum(ordinals>1);
    % повторы с точки зрения приёмника;
    h.receiverRetryAttempts=h.receiverRetryAttempts+sum(ordinals>1);
    % излучений;
    h.transmissionsStarted=h.transmissionsStarted+numel(emitted);
    % повторных излучений;
    h.retryTransmissions=h.retryTransmissions+max(0,numel(emitted)-1);
    % блок излучался хотя бы раз;
    h.blocksTransmitted=h.blocksTransmitted+double(~isempty(emitted));
    % декодирований;
    h.decodedAttempts=h.decodedAttempts+numel(decodes);
    % назначенных, но ещё не декодированных передач;
    h.pendingAttempts=h.pendingAttempts+sum(~ismember(ordinals,decodedOrdinals));
    % первая передача приёмника (номер 1):
    first=find(decodedOrdinals==1);
    % не декодирована — ожидает;
    if isempty(first), h.firstReceiverPending=h.firstReceiverPending+1;
    else
        % декодирована —
        h.firstReceiverDecoded=h.firstReceiverDecoded+1;
        % и её ошибка CRC.
        h.firstReceiverCrcFailures=h.firstReceiverCrcFailures+double(journal(decodes(first)).fields.crcError~=0);
    end
    % Если были излучения —
    if ~isempty(emittedOrdinals)
        % декодирование первого фактического излучения:
        first=find(decodedOrdinals==min(emittedOrdinals));
        % нет — ожидает;
        if isempty(first), h.firstPending=h.firstPending+1;
        else
            % есть —
            h.firstDecoded=h.firstDecoded+1;
            % и его ошибка CRC.
            h.firstCrcFailures=h.firstCrcFailures+double(journal(decodes(first)).fields.crcError~=0);
        end
    end
    % Для каждого декодирования:
    for i=reshape(decodes,1,[])
        % ошибки CRC всех передач.
        h.crcFailures=h.crcFailures+double(journal(i).fields.crcError~=0);
    end
    % Итога нет — блок не завершён к горизонту (цензурирован);
    if isempty(terminals), h.blocksCensored=h.blocksCensored+1;
    else
        % иначе последний итог:
        outcome=journal(terminals(end)).fields.outcome;
        % по исходу:
        switch outcome
            % принят;
            case 'accepted', h.blocksAccepted=h.blocksAccepted+1;
            % окончательно не принят (исчерпаны 4 передачи);
            case 'failed', h.blocksFailed=h.blocksFailed+1;
            % иной исход — ошибка.
            otherwise, error('nbiot:metrics:HarqJournal','Unknown terminal outcome.');
        end
    end
end
% BLER первой фактической передачи.
h.firstTransmissionBler=ratio(h.firstCrcFailures,h.firstDecoded);
% BLER первой передачи с точки зрения приёмника.
h.firstReceiverBler=ratio(h.firstReceiverCrcFailures,h.firstReceiverDecoded);
% BLER по всем передачам.
h.allAttemptBler=ratio(h.crcFailures,h.decodedAttempts);
% Доля принятых блоков.
h.acceptedProbability=ratio(h.blocksAccepted,h.blocksStarted);
% Доля окончательно не принятых.
h.failedProbability=ratio(h.blocksFailed,h.blocksStarted);
end

%RATIO Отношение; при нулевом знаменателе — NaN.
function value=ratio(n,d)
% Деление с защитой.
if d==0, value=NaN; else, value=n/d; end
end
