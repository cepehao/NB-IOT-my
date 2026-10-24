function diagnostics=radioDiagnostics(truthEvents,observedEvents,receptionEvents,options)
%RADIODIAGNOSTICS Compare post-reception observations with simulation truth.
%   Радиодиагностика прогона (ТЗ §15–17, §35–36): сопоставление наблюдений приёмника с истиной —
%   detection/miss/false alarm, коллизии, capture, ошибки оценок задержки и CFO, SINR компонент.
% Truth is joined only after the detector/receiver has produced its result.
% Журнал истины должен быть корректным массивом событий.
validateEvents(truthEvents,'truthEvents');
% Журнал наблюдений BS — тоже.
validateEvents(observedEvents,'observedEvents');
% Журнал диагностики приёма — тоже.
validateEvents(receptionEvents,'receptionEvents');
% Опции: горизонт и список допустимых NInit.
if ~isstruct(options)||~isscalar(options)|| ...
        ~all(isfield(options,{'actualTick','nInitValues'}))
    error('nbiot:metrics:RadioDiagnosticsOptions', ...
        'Options require actualTick and nInitValues.');
end
% Горизонт — неотрицательный целый тик.
validateattributes(options.actualTick,{'numeric'}, ...
    {'scalar','real','finite','integer','nonnegative'});
% Допустимые NInit — целые неотрицательные.
validateattributes(options.nInitValues,{'numeric'}, ...
    {'vector','real','finite','integer','nonnegative','nonempty'});
% NInit столбцом.
nInitValues=double(options.nInitValues(:));
% Без повторов.
if numel(unique(nInitValues))~=numel(nInitValues)
    error('nbiot:metrics:RadioDiagnosticsOptions', ...
        'nInitValues must contain unique preamble indices.');
end
% Горизонт как double.
horizon=double(options.actualTick);

% A detection event also records empty decisions, so it defines one complete
% occasion. The decision at H is complete; decisions after H are censored.
completeOccasions=zeros(0,1);
% Обнаруженные кандидаты: строки (возможность, NInit).
candidateRows=zeros(0,2);
% Оценки задержки и CFO по кандидатам.
candidateEstimates=repmat(candidateTemplate(),0,1);
% Для каждого события BS:
for k=1:numel(observedEvents)
    % событие;
    e=observedEvents(k);
    % только результаты детектора NPRACH в пределах горизонта;
    if ~strcmp(e.kind,'nprach_detection')||e.tick<0||e.tick>horizon, continue; end
    % поля;
    f=e.fields;
    % нужны номер возможности и список кандидатов;
    requireFields(f,{'occasionId','candidates'},'nprach_detection');
    % тик готовности по умолчанию — тик события;
    readyTick=double(e.tick);
    % если записан явно — берём его;
    if isfield(f,'readyTick'), readyTick=double(f.readyTick); end
    % результат не готов к горизонту — пропуск;
    if ~isscalar(readyTick)||~isfinite(readyTick)||readyTick>horizon, continue; end
    % номер возможности;
    occasionId=validInteger(f.occasionId,'occasionId',0);
    % возможность считается проанализированной детектором;
    completeOccasions(end+1,1)=occasionId; %#ok<AGROW>
    % кандидаты;
    candidates=f.candidates;
    % должны быть struct;
    if ~isstruct(candidates)
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'NPRACH candidates must be a struct array.');
    end
    % для каждого кандидата:
    for j=1:numel(candidates)
        % нужны NInit и оценки задержки и CFO;
        requireFields(candidates(j),{'nInit','delaySeconds','cfoHz'},'NPRACH candidate');
        % NInit;
        nInit=validInteger(candidates(j).nInit,'nInit',0);
        % должен быть допустимым;
        if ~ismember(nInit,nInitValues)
            error('nbiot:metrics:RadioDiagnosticsEvent', ...
                'An NPRACH candidate has an unconfigured preamble index.');
        end
        % запоминаем (возможность, NInit);
        candidateRows(end+1,:)=[occasionId nInit]; %#ok<AGROW>
        % и оценки детектора.
        candidateEstimates(end+1)=struct('occasionId',occasionId,'nInit',nInit, ...
            'estimatedDelaySeconds',finiteOrNaN(candidates(j).delaySeconds), ...
            'estimatedCfoHz',finiteOrNaN(candidates(j).cfoHz)); %#ok<AGROW>
    end
end
% Проанализированные возможности без повторов.
completeOccasions=unique(completeOccasions);
% Один NInit в одной возможности обнаруживается не больше одного раза.
if size(unique(candidateRows,'rows'),1)~=size(candidateRows,1)
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'The receiver logged a duplicate candidate for one occasion and preamble.');
end

% Truth attempts are included only when their NPRACH occasion was fully
% observed. One truth key is one transmitted preamble index, not one UE.
attempts=repmat(attemptTemplate(),0,1);
% Индексы событий Msg1 в истине до горизонта.
truthIndices=eventIndices(truthEvents,'msg1',horizon,false);
% Возможности этих Msg1.
truthOccasions=eventIntegers(truthEvents,truthIndices,'occasionId',0, ...
    {'attemptId','ueId','occasionId','nInit'},'msg1');
% Учитываем только Msg1 на проанализированных детектором возможностях.
truthIndices=truthIndices(ismember(truthOccasions,completeOccasions));
% Для каждого такого Msg1:
for k=truthIndices
    % событие;
    e=truthEvents(k);
    % проверка вида и тика;
    if ~strcmp(e.kind,'msg1')||e.tick<0||e.tick>=horizon, continue; end
    % поля и обязательные ключи;
    f=e.fields; requireFields(f,{'attemptId','ueId','occasionId','nInit'},'msg1');
    % возможность;
    occasionId=validInteger(f.occasionId,'occasionId',0);
    % номер попытки;
    attemptId=validInteger(f.attemptId,'attemptId',1);
    % номер UE;
    ueId=validInteger(f.ueId,'ueId',1);
    % NInit;
    nInit=validInteger(f.nInit,'nInit',0);
    % NInit должен быть допустимым;
    if ~ismember(nInit,nInitValues)
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'A transmitted preamble index is outside nInitValues.');
    end
    % запись истинной попытки.
    attempts(end+1)=struct('attemptId',attemptId,'ueId',ueId, ...
        'occasionId',occasionId,'nInit',nInit); %#ok<AGROW>
end
% Номера попыток уникальны.
if numel(unique([attempts.attemptId]))~=numel(attempts)
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'A truth attempt ID must be unique.');
end
% Истинные пары (возможность, NInit), где кто-то передавал.
trueKeys=zeros(0,2);
% Если попытки есть — уникальные пары.
if ~isempty(attempts), trueKeys=unique([[attempts.occasionId].',[attempts.nInit].'],'rows'); end
% Обнаруженные пары.
detectedKeys=unique(candidateRows,'rows');
% Истинные пары, которые детектор нашёл.
detectedTrueMask=ismember(trueKeys,detectedKeys,'rows');
% Обнаруженные пары без передачи — ложные тревоги.
falseAlarmMask=~ismember(detectedKeys,trueKeys,'rows');
% Пропуски — истинные пары, не найденные детектором.
misses=sum(~detectedTrueMask);
% Число ложных тревог.
falseAlarms=sum(falseAlarmMask);
% Возможности для ложной тревоги: все (возможность × NInit) минус истинные пары.
falseAlarmOpportunities=numel(completeOccasions)*numel(nInitValues)-size(trueKeys,1);
% Struct диагностики.
diagnostics=struct();
% Диагностика есть, если детектор что-то анализировал.
diagnostics.available=~isempty(completeOccasions);
% Горизонт.
diagnostics.actualTick=horizon;
% Обнаружение преамбул: передано, найдено, пропуски, ложные тревоги, вероятности.
diagnostics.preamble=struct( ...
    'transmittedAttempts',numel(attempts), ...
    'transmittedKeys',size(trueKeys,1), ...
    'detectedCandidates',size(candidateRows,1), ...
    'detectedKeys',sum(detectedTrueMask), ...
    'misses',misses, ...
    'falseAlarms',falseAlarms, ...
    'falseAlarmOpportunities',falseAlarmOpportunities, ...
    'detectionProbability',ratio(sum(detectedTrueMask),size(trueKeys,1)), ...
    'missProbability',ratio(misses,size(trueKeys,1)), ...
    'falseAlarmProbability',ratio(falseAlarms,falseAlarmOpportunities));

% Logical collision is a shared preamble choice. It does not imply that the
% received signal intervals actually overlap.
logicalCounts=zeros(0,1);
% Если попытки есть —
if ~isempty(attempts)
    % пары (возможность, NInit) попыток;
    attemptKeys=[[attempts.occasionId].',[attempts.nInit].'];
    % номер группы каждой попытки;
    [~,~,keyGroup]=unique(attemptKeys,'rows');
    % размеры групп.
    logicalCounts=accumarray(keyGroup,1);
end
% Логические коллизии: группы из >= 2 попыток.
logicalGroups=sum(logicalCounts>1);
% Число попыток в этих группах.
logicalAttempts=sum(logicalCounts(logicalCounts>1));

% Компоненты сигнала NPRACH (из диагностики приёма).
components=repmat(componentTemplate(),0,1);
% Обязательные поля компоненты.
componentFields={'occasionId','attemptId','ueId','nInit','startSample', ...
    'endSampleExclusive','signalPowerW','interferencePowerW','noisePowerW', ...
    'configuredDelaySeconds','configuredCfoHz'};
% Индексы событий компонент до горизонта.
componentIndices=eventIndices(receptionEvents,'nprach_component',horizon,true);
% Их возможности.
componentOccasions=eventIntegers(receptionEvents,componentIndices,'occasionId',0,componentFields,'nprach_component');
% Только на проанализированных возможностях.
componentIndices=componentIndices(ismember(componentOccasions,completeOccasions));
% Номера попыток компонент.
componentIds=eventIntegers(receptionEvents,componentIndices,'attemptId',1,componentFields,'nprach_component');
% Только для учтённых попыток.
componentIndices=componentIndices(ismember(componentIds,[attempts.attemptId]));
% Для каждой компоненты:
for k=componentIndices
    % событие;
    e=receptionEvents(k);
    % проверка вида и тика;
    if ~strcmp(e.kind,'nprach_component')||e.tick<0||e.tick>horizon, continue; end
    % поля;
    f=e.fields;
    % обязательные поля;
    componentFields={'occasionId','attemptId','ueId','nInit','startSample', ...
        'endSampleExclusive','signalPowerW','interferencePowerW','noisePowerW', ...
        'configuredDelaySeconds','configuredCfoHz'};
    % проверка их наличия;
    requireFields(f,componentFields,'nprach_component');
    % возможность;
    occasionId=validInteger(f.occasionId,'occasionId',0);
    % попытка;
    attemptId=validInteger(f.attemptId,'attemptId',1);
    % первый отсчёт;
    startSample=validInteger(f.startSample,'startSample',0);
    % отсчёт после последнего;
    endSample=validInteger(f.endSampleExclusive,'endSampleExclusive',1);
    % интервал непустой;
    if endSample<=startSample
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'Received signal support must be a nonempty half-open interval.');
    end
    % запись компоненты (мощности сигнала, помехи, шума; истинные задержка и CFO).
    components(end+1)=struct('occasionId',occasionId,'attemptId',attemptId, ...
        'ueId',validInteger(f.ueId,'ueId',1), ...
        'nInit',validInteger(f.nInit,'nInit',0), ...
        'startSample',startSample,'endSampleExclusive',endSample, ...
        'signalPowerW',nonnegativeFinite(f.signalPowerW,'signalPowerW'), ...
        'interferencePowerW',nonnegativeFinite(f.interferencePowerW,'interferencePowerW'), ...
        'noisePowerW',nonnegativeFinite(f.noisePowerW,'noisePowerW'), ...
        'configuredDelaySeconds',finiteOrNaN(f.configuredDelaySeconds), ...
        'configuredCfoHz',finiteOrNaN(f.configuredCfoHz)); %#ok<AGROW>
end
% Одна компонента на попытку.
if numel(unique([components.attemptId]))~=numel(components)
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'One NPRACH attempt must have one receiver-component summary.');
end
% Номера попыток компонент по возрастанию и порядок.
[sortedIds,componentOrder]=sort([components.attemptId]);

% Индексы событий перекрытий до горизонта.
overlapIndices=eventIndices(receptionEvents,'nprach_overlap',horizon,true);
% Заготовка перекрытий.
overlaps=repmat(overlapTemplate(),1,numel(overlapIndices));
% Для каждого перекрытия:
for k=1:numel(overlapIndices)
    % событие;
    e=receptionEvents(overlapIndices(k));
    % поля;
    f=e.fields;
    % обязательные поля;
    overlapFields={'occasionId','attemptIdA','attemptIdB','startSample', ...
        'endSampleExclusive','signalPowerAW','signalPowerBW'};
    % проверка;
    requireFields(f,overlapFields,'nprach_overlap');
    % возможность;
    occasionId=validInteger(f.occasionId,'occasionId',0);
    % попытка A;
    attemptIdA=validInteger(f.attemptIdA,'attemptIdA',1);
    % попытка B;
    attemptIdB=validInteger(f.attemptIdB,'attemptIdB',1);
    % попытки разные;
    if attemptIdA==attemptIdB
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'A physical overlap requires two distinct NPRACH attempts.');
    end
    % начало общего интервала;
    startSample=validInteger(f.startSample,'startSample',0);
    % конец;
    endSample=validInteger(f.endSampleExclusive,'endSampleExclusive',1);
    % интервал непустой;
    if endSample<=startSample
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'An overlap event must describe the exact shared half-open interval.');
    end
    % запись перекрытия с мощностями обоих сигналов.
    overlaps(k)=struct('occasionId',occasionId,'attemptIdA',attemptIdA, ...
        'attemptIdB',attemptIdB,'startSample',startSample, ...
        'endSampleExclusive',endSample, ...
        'signalPowerAW',nonnegativeFinite(f.signalPowerAW,'signalPowerAW'), ...
        'signalPowerBW',nonnegativeFinite(f.signalPowerBW,'signalPowerBW')); %#ok<AGROW>
end
% Empty public arrays retain the original 0-by-1 shape.
if isempty(overlaps), overlaps=repmat(overlapTemplate(),0,1); end
% Номера попыток пар.
idsA=[overlaps.attemptIdA]; idsB=[overlaps.attemptIdB];
% Позиции попыток A среди компонент.
[foundA,locationA]=ismember(idsA,sortedIds);
% Позиции попыток B.
[foundB,locationB]=ismember(idsB,sortedIds);
% У обеих попыток должны быть компоненты.
if ~all(foundA & foundB)
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'An overlap event must refer to two logged components in its occasion.');
end
% Индексы компонент A и B.
indicesA=componentOrder(locationA); indicesB=componentOrder(locationB);
% Возможности пары и компонент совпадают.
if any([components(indicesA).occasionId]~=[overlaps.occasionId])|| ...
        any([components(indicesB).occasionId]~=[overlaps.occasionId])
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'An overlap event must refer to two logged components in its occasion.');
end
% Интервал перекрытия совпадает с пересечением интервалов компонент.
if any([overlaps.startSample]~=max([components(indicesA).startSample],[components(indicesB).startSample]))|| ...
        any([overlaps.endSampleExclusive]~=min([components(indicesA).endSampleExclusive],[components(indicesB).endSampleExclusive]))
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'An overlap event must describe the exact shared half-open interval.');
end
% Пары по возрастанию номеров.
loggedPairs=[min(idsA,idsB).' max(idsA,idsB).'];
% Нет перекрытий — пустой список пар.
if isempty(overlaps), loggedPairs=zeros(0,2); end
% Пары не повторяются.
if size(unique(loggedPairs,'rows'),1)~=size(loggedPairs,1)
    error('nbiot:metrics:RadioDiagnosticsEvent','A physical overlap pair was logged twice.');
end
% Ожидаемые пары: все пары компонент одной возможности с пересечением.
expectedPairs=enumeratePairs(components);
% Записанные и ожидаемые пары должны совпадать.
if ~isempty(setxor(expectedPairs,loggedPairs,'rows'))
    error('nbiot:metrics:RadioDiagnosticsEvent', ...
        'Physical overlap events must cover every and only overlapping component pair.');
end

% Физические коллизии — перекрывшиеся пары.
physicalPairs=loggedPairs;
% Попытки, участвовавшие в перекрытиях.
physicalAttemptIds=zeros(0,1);
% Если перекрытия есть —
if ~isempty(overlaps)
    % номера всех попыток пар.
    physicalAttemptIds=[ [overlaps.attemptIdA].' ; [overlaps.attemptIdB].' ];
end
% Счётчики capture: пригодные пары, без исхода, с равной мощностью;
eligiblePairs=0; censoredPairs=0; equalPowerPairs=0;
% захваты, успехи сильной и слабой попытки.
capturedPairs=0; strongSuccesses=0; weakSuccesses=0;
% Индексы исходов попыток (успех / неуспех) до горизонта.
outcomeIndices=[eventIndices(truthEvents,'ra_success',horizon,true), ...
    eventIndices(truthEvents,'ra_failure',horizon,true)];
% Номера попыток и признак успеха по исходам.
outcomeIds=zeros(numel(outcomeIndices),1); outcomeSuccess=false(numel(outcomeIndices),1);
% Для каждого исхода:
for j=1:numel(outcomeIndices)
    % индекс события;
    k=outcomeIndices(j);
    % событие;
    e=truthEvents(k);
    % проверка вида и тика;
    if e.tick<0||e.tick>horizon||~any(strcmp(e.kind,{'ra_success','ra_failure'})), continue; end
    % нужен номер попытки;
    requireFields(e.fields,{'attemptId'},e.kind);
    % номер попытки;
    id=validInteger(e.fields.attemptId,'attemptId',1);
    % запоминаем;
    outcomeIds(j)=id;
    % успех или нет.
    outcomeSuccess(j)=strcmp(e.kind,'ra_success');
end
% Уникальные попытки с исходом.
[outcomeIds,~,outcomeGroup]=unique(outcomeIds);
% Исход каждой попытки.
outcomes=strings(numel(outcomeIds),1);
% Если исходы есть —
if ~isempty(outcomeGroup)
    % число успехов по попытке;
    successes=accumarray(outcomeGroup,double(outcomeSuccess));
    % число исходов по попытке;
    counts=accumarray(outcomeGroup,1);
    % попытка не может быть одновременно успешной и неуспешной;
    if any(successes>0 & successes<counts)
        error('nbiot:metrics:RadioDiagnosticsEvent', ...
            'An NPRACH attempt cannot both succeed and fail.');
    end
    % итог попытки: success, если был успех, иначе failure.
    outcomes(:)="failure"; outcomes(successes>0)="success";
end
% Исходы попыток A пар.
[knownA,outcomeIndexA]=ismember(idsA,outcomeIds);
% Исходы попыток B пар.
[knownB,outcomeIndexB]=ismember(idsB,outcomeIds);
% По умолчанию исход неизвестен.
pairOutcomesA=repmat("unknown",1,numel(overlaps));
% Для B — тоже.
pairOutcomesB=pairOutcomesA;
% Известные исходы A.
pairOutcomesA(knownA)=outcomes(outcomeIndexA(knownA));
% Известные исходы B.
pairOutcomesB(knownB)=outcomes(outcomeIndexB(knownB));
% Для каждой пары перекрытия:
for k=1:numel(overlaps)
    % пара;
    pair=overlaps(k);
    % разность мощностей A − B (дБ);
    deltaDb=powerDifferenceDb(pair.signalPowerAW,pair.signalPowerBW);
    % равные мощности — capture не определяется;
    if isnan(deltaDb)||abs(deltaDb)<=1e-9
        % счётчик равных;
        equalPowerPairs=equalPowerPairs+1;
        % дальше;
        continue;
    end
    % исход A;
    outcomeA=pairOutcomesA(k);
    % исход B;
    outcomeB=pairOutcomesB(k);
    % исход неизвестен (не завершён к горизонту) —
    if outcomeA=="unknown"||outcomeB=="unknown"
        % пара цензурирована;
        censoredPairs=censoredPairs+1;
        % дальше;
        continue;
    end
    % пригодная пара;
    eligiblePairs=eligiblePairs+1;
    % успех сильной и слабой попыток;
    strongerSuccess=false; weakerSuccess=false;
    % A сильнее —
    if deltaDb>0
        % сильная — A, слабая — B;
        strongerSuccess=outcomeA=="success"; weakerSuccess=outcomeB=="success";
    else
        % иначе сильная — B, слабая — A;
        strongerSuccess=outcomeB=="success"; weakerSuccess=outcomeA=="success";
    end
    % успехи сильной;
    strongSuccesses=strongSuccesses+double(strongerSuccess);
    % успехи слабой;
    weakSuccesses=weakSuccesses+double(weakerSuccess);
    % capture: сильная прошла, слабая — нет.
    capturedPairs=capturedPairs+double(strongerSuccess&&~weakerSuccess);
end
% Уникальные попытки в физических коллизиях.
physicalAttemptIds=unique(physicalAttemptIds);
% Диагностика коллизий: логические и физические.
diagnostics.collision=struct( ...
    'attempts',numel(attempts), ...
    'logicalGroups',logicalGroups, ...
    'logicalAttempts',logicalAttempts, ...
    'logicalAttemptProbability',ratio(logicalAttempts,numel(attempts)), ...
    'physicalOverlapPairs',size(physicalPairs,1), ...
    'physicalAttempts',numel(physicalAttemptIds), ...
    'physicalAttemptProbability',ratio(numel(physicalAttemptIds),numel(attempts)));
% Диагностика capture (ТЗ §16): пригодные пары, захваты, успехи сильной/слабой.
diagnostics.capture=struct( ...
    'eligiblePairs',eligiblePairs, ...
    'censoredPairs',censoredPairs, ...
    'equalPowerPairs',equalPowerPairs, ...
    'capturedPairs',capturedPairs, ...
    'probability',ratio(capturedPairs,eligiblePairs), ...
    'strongSuccessProbability',ratio(strongSuccesses,eligiblePairs), ...
    'weakSuccessProbability',ratio(weakSuccesses,eligiblePairs));

% Диагностика по попыткам.
perAttempt=repmat(perAttemptTemplate(),0,1);
% Для каждой компоненты:
for k=1:numel(components)
    % компонента;
    c=components(k);
    % помеха + шум (знаменатель SINR);
    denominator=c.interferencePowerW+c.noisePowerW;
    % SINR по умолчанию не определён;
    sinrDb=NaN;
    % если сигнал и знаменатель положительны —
    if c.signalPowerW>0&&denominator>0
        % SINR в дБ;
        sinrDb=10*log10(c.signalPowerW/denominator);
    end
    % запись попытки: мощности, SINR; источник — диагностическая истина.
    perAttempt(end+1)=struct('occasionId',c.occasionId,'attemptId',c.attemptId, ...
        'ueId',c.ueId,'nInit',c.nInit,'receivedPowerW',c.signalPowerW, ...
        'interferencePowerW',c.interferencePowerW,'noisePowerW',c.noisePowerW, ...
        'sinrDb',sinrDb,'provenance','diagnosticTruth'); %#ok<AGROW>
end
% Сохраняем диагностику по попыткам.
diagnostics.perAttempt=perAttempt;

% Ошибки оценок детектора NPRACH (задержка, CFO) относительно истины.
estimates=repmat(receiverEstimateTemplate(),0,1);
% Group once; only a key with one truth attempt can supply receiver truth.
attemptKeys=[[attempts.occasionId].' [attempts.nInit].'];
% Ключи (возможность, NInit) попыток; пустые — матрица 0×2.
if isempty(attempts), attemptKeys=zeros(0,2); end
% Уникальные ключи и группа каждой попытки.
[estimateKeys,~,estimateGroup]=unique(attemptKeys,'rows');
% Число попыток на ключ и индекс единственной попытки.
estimateCounts=zeros(0,1); singleAttempt=zeros(0,1);
% Если попытки есть —
if ~isempty(estimateGroup)
    % сколько попыток с каждым ключом;
    estimateCounts=accumarray(estimateGroup,1);
    % первая (единственная) попытка ключа.
    singleAttempt=accumarray(estimateGroup,(1:numel(attempts)).',[],@min);
end
% Есть ли у кандидата истинная попытка и её группа.
[candidateHasTruth,candidateGroup]=ismember(candidateRows,estimateKeys,'rows');
% Есть ли у попытки компонента сигнала и где она.
[attemptHasComponent,attemptComponentLocation]=ismember([attempts.attemptId],sortedIds);
% Для каждого кандидата детектора:
for k=1:numel(candidateEstimates)
    % кандидат;
    c=candidateEstimates(k);
    % по умолчанию истина неизвестна;
    configuredDelay=NaN; configuredCfo=NaN; attemptId=NaN; ueId=NaN; truthAvailable=false;
    % истина однозначна, только если ровно одна попытка с этим ключом (без коллизии):
    if candidateHasTruth(k)&&estimateCounts(candidateGroup(k))==1
        % индекс попытки;
        matchingIndex=singleAttempt(candidateGroup(k));
        % попытка;
        matching=attempts(matchingIndex);
        % номер попытки и UE;
        attemptId=matching.attemptId; ueId=matching.ueId;
        % если есть компонента сигнала —
        if attemptHasComponent(matchingIndex)
            % её индекс;
            componentIndex=componentOrder(attemptComponentLocation(matchingIndex));
            % истинная задержка;
            configuredDelay=components(componentIndex).configuredDelaySeconds;
            % истинный CFO;
            configuredCfo=components(componentIndex).configuredCfoHz;
            % истина доступна, если обе величины конечны.
            truthAvailable=isfinite(configuredDelay)&&isfinite(configuredCfo);
        end
    end
    % Ошибки по умолчанию не определены.
    delayError=NaN; cfoError=NaN;
    % Есть истина и оценка задержки —
    if truthAvailable&&isfinite(c.estimatedDelaySeconds)
        % ошибка задержки = оценка − истина (с);
        delayError=c.estimatedDelaySeconds-configuredDelay;
    end
    % есть истина и оценка CFO —
    if truthAvailable&&isfinite(c.estimatedCfoHz)
        % ошибка CFO = оценка − истина (Гц);
        cfoError=c.estimatedCfoHz-configuredCfo;
    end
    % запись оценки детектора.
    estimates(end+1)=struct('occasionId',c.occasionId,'nInit',c.nInit, ...
        'attemptId',attemptId,'ueId',ueId, ...
        'estimatedDelaySeconds',c.estimatedDelaySeconds, ...
        'configuredDelaySeconds',configuredDelay,'delayErrorSeconds',delayError, ...
        'estimatedCfoHz',c.estimatedCfoHz,'configuredCfoHz',configuredCfo, ...
        'cfoErrorHz',cfoError,'truthAvailable',truthAvailable); %#ok<AGROW>
end
% Сохраняем оценки детектора.
diagnostics.receiverEstimates=estimates;

% Оценки приёмника NPUSCH (задержка, CFO) по событиям диагностики приёма.
npuschEstimates=repmat(npuschEstimateTemplate(),0,1);
% Для каждого события диагностики:
for k=1:numel(receptionEvents)
    % событие;
    e=receptionEvents(k);
    % только приёмник NPUSCH в пределах горизонта;
    if ~strcmp(e.kind,'npusch_receiver')||e.tick<0||e.tick>horizon, continue; end
    % поля;
    f=e.fields;
    % обязательные поля;
    requireFields(f,{'contextId','occasionId','nInit','channel', ...
        'estimatedDelaySeconds','estimatedCfoHz','configuredDelaySeconds', ...
        'configuredCfoHz','noiseEstimate'},'npusch_receiver');
    % попытка и UE по умолчанию неизвестны;
    attemptId=NaN; ueId=NaN;
    % номер попытки, если записан;
    if isfield(f,'attemptId'), attemptId=finiteOrNaN(f.attemptId); end
    % номер UE, если записан;
    if isfield(f,'ueId'), ueId=finiteOrNaN(f.ueId); end
    % оценённая задержка;
    estimatedDelay=finiteOrNaN(f.estimatedDelaySeconds);
    % оценённый CFO;
    estimatedCfo=finiteOrNaN(f.estimatedCfoHz);
    % истинная задержка;
    truthDelay=finiteOrNaN(f.configuredDelaySeconds);
    % истинный CFO;
    truthCfo=finiteOrNaN(f.configuredCfoHz);
    % ошибки по умолчанию не определены;
    delayError=NaN; cfoError=NaN;
    % ошибка задержки, если обе величины конечны;
    if isfinite(estimatedDelay)&&isfinite(truthDelay), delayError=estimatedDelay-truthDelay; end
    % ошибка CFO, если обе величины конечны;
    if isfinite(estimatedCfo)&&isfinite(truthCfo), cfoError=estimatedCfo-truthCfo; end
    % запись оценки NPUSCH.
    npuschEstimates(end+1)=struct( ...
        'contextId',validInteger(f.contextId,'contextId',1), ...
        'occasionId',validInteger(f.occasionId,'occasionId',0), ...
        'nInit',validInteger(f.nInit,'nInit',0), ...
        'attemptId',attemptId,'ueId',ueId, ...
        'channel',char(string(f.channel)), ...
        'estimatedDelaySeconds',estimatedDelay, ...
        'configuredDelaySeconds',truthDelay, ...
        'delayErrorSeconds',delayError, ...
        'estimatedCfoHz',estimatedCfo, ...
        'configuredCfoHz',truthCfo, ...
        'cfoErrorHz',cfoError, ...
        'noiseEstimate',nonnegativeFinite(f.noiseEstimate,'noiseEstimate'), ...
        'truthAvailable',isfinite(truthDelay)&&isfinite(truthCfo)); %#ok<AGROW>
end
% Сохраняем оценки NPUSCH.
diagnostics.npuschReceiverEstimates=npuschEstimates;
end

%VALIDATEEVENTS Проверка журнала: struct с полями tick, kind, fields.
function validateEvents(events,name)
% Нужен struct с полями тик, вид, поля.
if ~isstruct(events)||~all(isfield(events,{'tick','kind','fields'}))
    error('nbiot:metrics:RadioDiagnosticsEvent','%s must be an EventLog struct array.',name);
end
% Для каждого события:
for k=1:numel(events)
    % тик — неотрицательное целое, вид — текст, поля — скалярный struct;
    if ~isnumeric(events(k).tick)||~isreal(events(k).tick)|| ...
            ~isscalar(events(k).tick)||~isfinite(events(k).tick)|| ...
            events(k).tick<0||~ischar(events(k).kind)||~isscalar(events(k).fields)|| ...
            ~isstruct(events(k).fields)
        % иначе ошибка.
        error('nbiot:metrics:RadioDiagnosticsEvent','%s contains a malformed event.',name);
    end
end
end

%REQUIREFIELDS Проверка, что S — скалярный struct со всеми полями NAMES.
function requireFields(s,names,label)
% Не struct, не скаляр или нет полей —
if ~isstruct(s)||~isscalar(s)||~all(isfield(s,names))
    error('nbiot:metrics:RadioDiagnosticsEvent','%s is missing required fields.',label);
end
end

%VALIDINTEGER Проверка целого не меньше MINIMUM; возвращает double.
function value=validInteger(value,name,minimum)
% Числовой вещественный конечный целый скаляр не меньше минимума;
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)|| ...
        value~=fix(value)||value<minimum
    % иначе ошибка.
    error('nbiot:metrics:RadioDiagnosticsEvent','%s must be a valid integer.',name);
end
% Как double.
value=double(value);
end

%NONNEGATIVEFINITE Проверка неотрицательного конечного числа; возвращает double.
function value=nonnegativeFinite(value,name)
% Числовой вещественный конечный неотрицательный скаляр;
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)||value<0
    error('nbiot:metrics:RadioDiagnosticsEvent','%s must be finite and nonnegative.',name);
end
% как double.
value=double(value);
end

%FINITEORNAN Число как double; бесконечность и нечисло — NaN.
function value=finiteOrNaN(value)
% Некорректное или бесконечное — NaN;
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||isinf(value), value=NaN;
% иначе double.
else, value=double(value); end
end

%RATIO Отношение; при нулевом знаменателе — NaN.
function value=ratio(numerator,denominator)
% Деление с защитой.
if denominator==0, value=NaN; else, value=numerator/denominator; end
end

%POWERDIFFERENCEDB Разность мощностей в дБ (±Inf, если одна из них нулевая).
function delta=powerDifferenceDb(first,second)
% По умолчанию не определена (обе нулевые).
delta=NaN;
% Обе положительны — 10·log10 отношения;
if first>0&&second>0, delta=10*log10(first/second);
% только первая — +Inf;
elseif first>0, delta=Inf;
% только вторая — −Inf.
elseif second>0, delta=-Inf;
end
end

%EVENTINDICES Индексы событий вида KIND до горизонта (включая или нет сам горизонт).
function indices=eventIndices(events,kind,horizon,includeHorizon)
% Тики событий.
ticks=[events.tick];
% Нужный вид и неотрицательный тик.
mask=strcmp({events.kind},kind) & ticks>=0;
% С горизонтом включительно;
if includeHorizon, mask=mask & ticks<=horizon;
% или строго до горизонта.
else, mask=mask & ticks<horizon; end
% Индексы.
indices=find(mask);
end

%EVENTINTEGERS Целое поле NAME у событий INDICES (с проверкой обязательных полей).
function values=eventIntegers(events,indices,name,minimum,required,label)
% Заготовка.
values=zeros(size(indices));
% Для каждого события:
for j=1:numel(indices)
    % поля;
    fields=events(indices(j)).fields;
    % обязательные поля;
    requireFields(fields,required,label);
    % целое значение.
    values(j)=validInteger(fields.(name),name,minimum);
end
end

function pairs=enumeratePairs(components)
% This order is internal only; public diagnostics retain event order.
% Нет компонент — нет пар.
if isempty(components), pairs=zeros(0,2); return; end
% Ключи сортировки: возможность, первый отсчёт, попытка.
keys=[[components.occasionId].' [components.startSample].' [components.attemptId].'];
% Порядок компонент.
[~,order]=sortrows(keys,[1 2 3]);
% Растущий буфер пар.
capacity=256; pairs=zeros(capacity,2); count=0;
% Для каждой компоненты по порядку:
for i=1:numel(order)-1
    % компонента A;
    a=components(order(i));
    % следующие за ней:
    for j=i+1:numel(order)
        % компонента B;
        b=components(order(j));
        % другая возможность или B начинается после конца A — дальше пересечений нет;
        if b.occasionId~=a.occasionId||b.startSample>=a.endSampleExclusive, break; end
        % интервалы пересекаются —
        if max(a.startSample,b.startSample)<min(a.endSampleExclusive,b.endSampleExclusive)
            % новая пара;
            count=count+1;
            % буфер полон —
            if count>capacity
                % удваиваем ёмкость;
                capacity=2*capacity;
                % расширяем матрицу;
                pairs(capacity,2)=0;
            end
            % пара (меньший номер, больший номер).
            pairs(count,:)=[min(a.attemptId,b.attemptId),max(a.attemptId,b.attemptId)];
        end
    end
end
% Обрезаем буфер.
pairs=pairs(1:count,:);
end

%ATTEMPTTEMPLATE Шаблон истинной попытки.
function c=attemptTemplate()
% Попытка, UE, возможность, NInit.
c=struct('attemptId',0,'ueId',0,'occasionId',0,'nInit',0);
end

%CANDIDATETEMPLATE Шаблон кандидата детектора.
function c=candidateTemplate()
% Возможность, NInit, оценки задержки и CFO.
c=struct('occasionId',0,'nInit',0,'estimatedDelaySeconds',NaN,'estimatedCfoHz',NaN);
end

%COMPONENTTEMPLATE Шаблон компоненты сигнала NPRACH.
function c=componentTemplate()
% Поля компоненты: идентификаторы, интервал отсчётов, мощности, истинные задержка и CFO.
c=struct('occasionId',0,'attemptId',0,'ueId',0,'nInit',0, ...
    'startSample',0,'endSampleExclusive',0,'signalPowerW',0, ...
    'interferencePowerW',0,'noisePowerW',0, ...
    'configuredDelaySeconds',NaN,'configuredCfoHz',NaN);
end

%PERATTEMPTTEMPLATE Шаблон диагностики попытки.
function c=perAttemptTemplate()
% Идентификаторы, мощности, SINR, источник.
c=struct('occasionId',0,'attemptId',0,'ueId',0,'nInit',0, ...
    'receivedPowerW',NaN,'interferencePowerW',NaN,'noisePowerW',NaN, ...
    'sinrDb',NaN,'provenance','diagnosticTruth');
end

%RECEIVERESTIMATETEMPLATE Шаблон оценки детектора NPRACH.
function c=receiverEstimateTemplate()
% Идентификаторы, оценки, истина и ошибки.
c=struct('occasionId',0,'nInit',0,'attemptId',NaN,'ueId',NaN, ...
    'estimatedDelaySeconds',NaN, ...
    'configuredDelaySeconds',NaN,'delayErrorSeconds',NaN, ...
    'estimatedCfoHz',NaN,'configuredCfoHz',NaN,'cfoErrorHz',NaN, ...
    'truthAvailable',false);
end

%OVERLAPTEMPLATE Шаблон перекрытия двух сигналов.
function c=overlapTemplate()
% Возможность, пара попыток, интервал, мощности.
c=struct('occasionId',0,'attemptIdA',0,'attemptIdB',0, ...
    'startSample',0,'endSampleExclusive',0,'signalPowerAW',0,'signalPowerBW',0);
end

%NPUSCHESTIMATETEMPLATE Шаблон оценки приёмника NPUSCH.
function c=npuschEstimateTemplate()
% Идентификаторы, канал, оценки, истина и ошибки.
c=struct('contextId',0,'occasionId',0,'nInit',0,'attemptId',NaN,'ueId',NaN,'channel','', ...
    'estimatedDelaySeconds',NaN,'configuredDelaySeconds',NaN, ...
    'delayErrorSeconds',NaN,'estimatedCfoHz',NaN,'configuredCfoHz',NaN, ...
    'cfoErrorHz',NaN,'noiseEstimate',NaN,'truthAvailable',false);
end
