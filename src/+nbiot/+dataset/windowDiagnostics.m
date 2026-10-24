% Диагностика окон датасета по истине симулятора (только для анализа, не признаки — ТЗ §40).
function rows=windowDiagnostics(cfg,packets,attempts,truthEvents,observedEvents, ...
    receptionEvents,actualTick,windowKeys)
%WINDOWDIAGNOSTICS Derive outcome-only diagnostics for already closed windows.
%   Диагностика по окнам датасета из истины (обнаружения, коллизии, приём) — только для анализа,
%   в признаки не входит (ТЗ §40).
% This function consumes completed in-memory journals. It never calls a PHY,
% changes simulator state, or supplies any value to the controller.
% Проверка конфигурации, горизонта и таблицы ключей окон.
validateInputs(cfg,actualTick,windowKeys);
% Имена ключей окна.
keyNames={'realizationId','windowId','startTick','endTick'};
% Ключи всех закрытых окон.
keys=windowKeys(:,keyNames);
% Окон нет —
if isempty(keys)
    % пустая таблица диагностики с правильными столбцами.
    rows=emptyDiagnostics();
    return
end

% Доступен ли журнал попыток RA (нужные поля).
attemptAvailable=isstruct(attempts)&&all(isfield(attempts, ...
    {'attemptId','startTick','endTick','status'}));
% Доступен ли журнал пакетов.
packetAvailable=isstruct(packets)&&all(isfield(packets, ...
    {'packetId','createdTick','deliveredTick','status'}));
% Доступны ли журналы истины, наблюдений BS и диагностики приёма.
truthAvailable=isstruct(truthEvents)&&all(isfield(truthEvents,{'kind','fields','tick'}));
observationAvailable=isstruct(observedEvents)&&all(isfield(observedEvents,{'kind','fields','tick'}));
receptionAvailable=isstruct(receptionEvents)&&all(isfield(receptionEvents,{'kind','fields','tick'}));

% Если попытки доступны —
if attemptAvailable
    % проверяем их корректность (номера, интервалы, статусы).
    validateAttempts(attempts,actualTick);
end
% Если пакеты доступны —
if packetAvailable
    % проверяем их корректность.
    validatePackets(packets,actualTick);
end
% Тик готовности результата детектора по каждой возможности NPRACH и список обнаруженных возможностей.
[readyTick,detectedOccasions]=indexDetections(observedEvents,observationAvailable,actualTick);
% Группы попыток по (возможность, NInit) из истины Msg1 и номера всех попыток.
[groups,truthIds]=indexTruth(truthEvents,truthAvailable);
% Если есть попытки и истина —
if attemptAvailable&&truthAvailable
    % каждая попытка из истины Msg1 должна быть в журнале попыток.
    if any(~ismember(truthIds,[attempts.attemptId]))
        diagnosticsError('A Msg1 truth event references a missing attempt.');
    end
end
% Компоненты сигнала NPRACH по попыткам (из диагностики приёма).
components=indexComponents(receptionEvents,receptionAvailable,readyTick,detectedOccasions);
% Пары попыток с физическим перекрытием сигналов в приёмнике.
pairs=indexOverlaps(receptionEvents,receptionAvailable,components,readyTick,actualTick);

% Число окон.
n=height(keys);
% Заготовки (NaN — «нет данных»): логические коллизии — группы и попытки;
logicalGroups=nan(n,1); logicalAttempts=nan(n,1);
% физические перекрытия — пары и попытки;
physicalPairs=nan(n,1); physicalAttempts=nan(n,1);
% успешные доступы, повторные попытки, средняя задержка и число доставок;
successes=nan(n,1); retries=nan(n,1); meanDelay=nan(n,1); delayCount=nan(n,1);
% незавершённые попытки и пакеты;
unfinishedAccess=nan(n,1); unfinishedPackets=nan(n,1);
% признаки доступности каждой диагностики (если исходных журналов нет — значения недоступны).
logicalAvailable=repmat(attemptAvailable&&truthAvailable&&observationAvailable,n,1);
% Физические перекрытия требуют диагностики приёма и наблюдений.
physicalAvailable=repmat(receptionAvailable&&observationAvailable,n,1);
% Доступ — по журналу попыток.
accessAvailable=repmat(attemptAvailable,n,1);
% Повторы — если в попытках есть номер пакета.
retryAvailable=repmat(attemptAvailable&&isstruct(attempts)&&isfield(attempts,'packetId'),n,1);
% Задержка доступна только для окон с доставками (заполняется ниже).
delayAvailable=false(n,1);

% Диагностика доступа по окнам:
if attemptAvailable
    % для каждого окна:
    for row=1:n
        % границы окна;
        s=keys.startTick(row); e=keys.endTick(row);
        % попытки, начатые в окне;
        inInterval=[attempts.startTick]>=s & [attempts.startTick]<e;
        % попытки, завершённые к горизонту;
        finished=[attempts.endTick]<=actualTick & isfinite([attempts.endTick]);
        % начатые в окне, но не завершённые;
        unfinishedAccess(row)=sum(inInterval&~finished);
        % успешные попытки, завершившиеся в окне (s, e];
        successes(row)=sum(strcmp({attempts.status},'success') & ...
            isfinite([attempts.endTick]) & [attempts.endTick]>s & [attempts.endTick]<=e);
        % если повторы доступны —
        if retryAvailable(row)
            % число повторных Msg1 (вторых и далее попыток пакета), начатых в окне.
            retries(row)=retryCount(attempts,s,e);
        end
    end
end

% Логические коллизии по окнам (если доступны):
if logicalAvailable(1)
    % для каждого окна:
    for row=1:n
        % границы окна;
        s=keys.startTick(row); e=keys.endTick(row);
        % группы с >= 2 попытками, результат детектора которых готов в окне, и число попыток в них.
        [logicalGroups(row),logicalAttempts(row)]=countLogical(groups,readyTick,s,e);
    end
end
% Физические перекрытия по окнам:
if physicalAvailable(1)
    % для каждого окна:
    for row=1:n
        % тики готовности всех пар перекрытий;
        ready=[pairs.readyTick];
        % пары, результат которых готов в окне (s, e];
        selected=ready>keys.startTick(row)&ready<=keys.endTick(row);
        % число пар;
        physicalPairs(row)=sum(selected);
        % число разных попыток в этих парах.
        physicalAttempts(row)=numel(unique([pairs(selected).attemptIds]));
    end
end
% Диагностика пакетов по окнам:
if packetAvailable
    % число доставок по окнам (сначала нули);
    delayCount=zeros(n,1);
    % для каждого окна:
    for row=1:n
        % границы окна;
        s=keys.startTick(row); e=keys.endTick(row);
        % пакеты, созданные в окне и оставшиеся незавершёнными к горизонту;
        unfinishedPackets(row)=sum([packets.createdTick]>=s & [packets.createdTick]<e & ...
            strcmp({packets.status},'unfinished'));
        % пакеты, доставленные в окне (s, e];
        delivered=strcmp({packets.status},'delivered') & isfinite([packets.deliveredTick]) & ...
            [packets.deliveredTick]>s & [packets.deliveredTick]<=e;
        % число доставок;
        delayCount(row)=sum(delivered);
        % если доставки есть —
        if delayCount(row)>0
            % задержка каждой доставки (тик доставки − тик создания);
            delay=double([packets(delivered).deliveredTick])-double([packets(delivered).createdTick]);
            % средняя задержка;
            meanDelay(row)=mean(delay);
            % задержка доступна.
            delayAvailable(row)=true;
        end
    end
end

% Итоговая таблица диагностики: ключи окна, значения, признаки доступности, горизонт оценки исходов.
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

%VALIDATEINPUTS Проверка конфигурации, горизонта и ключей окон.
function validateInputs(cfg,actualTick,keys)
% cfg с номером реализации, горизонт — целый тик в пределах длительности, ключи — таблица с нужными столбцами.
if ~isstruct(cfg)||~isfield(cfg,'simulation')||~isfield(cfg.simulation,'realizationId')|| ...
        ~isscalar(actualTick)||~isnumeric(actualTick)||~isfinite(actualTick)|| ...
        actualTick<0||actualTick~=fix(actualTick)|| ...
        (isfield(cfg,'simulation')&&isfield(cfg.simulation,'durationTicks')&& ...
            actualTick>cfg.simulation.durationTicks)||~istable(keys)|| ...
        ~all(ismember({'realizationId','windowId','startTick','endTick'},keys.Properties.VariableNames))
    diagnosticsError('Configuration, horizon, or window-key table is malformed.');
end
% Обязательные столбцы ключей.
required={'realizationId','windowId','startTick','endTick'};
% Ключи конечные; реализация совпадает с cfg; номера окон >= 1; окна — целые интервалы в пределах горизонта; без повторов.
if ~isnumeric(keys{:,required})||any(~isfinite(keys{:,required}),'all')|| ...
        any(keys.realizationId~=cfg.simulation.realizationId)|| ...
        any(keys.windowId<1|keys.windowId~=fix(keys.windowId))|| ...
        any(keys.startTick<0|keys.startTick~=fix(keys.startTick))|| ...
        any(keys.endTick<=keys.startTick|keys.endTick>actualTick|keys.endTick~=fix(keys.endTick))|| ...
        height(unique(keys(:,required),'rows'))~=height(keys)
    diagnosticsError('Window keys must be unique valid closed intervals through actualTick.');
end
end

%VALIDATEATTEMPTS Проверка журнала попыток RA.
function validateAttempts(attempts,horizon)
% Номера, тики начала и окончания попыток.
ids=double([attempts.attemptId]); starts=double([attempts.startTick]); ends=double([attempts.endTick]);
% Номера уникальные целые >= 1; начало — целый тик до горизонта; конец не раньше начала; статус из списка.
if any(~isfinite(ids)|ids<1|ids~=fix(ids))||numel(unique(ids))~=numel(ids)|| ...
        any(~isfinite(starts)|starts<0|starts>=horizon|starts~=fix(starts))|| ...
        any(isfinite(ends)&(ends<starts|ends~=fix(ends)))|| ...
        any(~ismember(string({attempts.status}),["started","unfinished","success","failure"]))
    diagnosticsError('Attempt IDs, intervals, or status values are malformed.');
end
end

%VALIDATEPACKETS Проверка журнала пакетов.
function validatePackets(packets,horizon)
% Пакетов нет — проверять нечего.
if isempty(packets), return; end
% Номера, тики создания и доставки.
ids=double([packets.packetId]); created=double([packets.createdTick]); delivered=double([packets.deliveredTick]);
% Номера уникальные; создание — целый тик до горизонта; доставка не раньше создания; статус из списка.
if any(~isfinite(ids)|ids<1|ids~=fix(ids))||numel(unique(ids))~=numel(ids)|| ...
        any(~isfinite(created)|created<0|created>=horizon|created~=fix(created))|| ...
        any(isfinite(delivered)&(delivered<created|delivered~=fix(delivered)))|| ...
        any(~ismember(string({packets.status}),["pending","unfinished","delivered","dropped"]))
    diagnosticsError('Packet IDs, intervals, or status values are malformed.');
end
end

%INDEXDETECTIONS Тик готовности результата детектора по каждой возможности NPRACH.
function [ready,occasions]=indexDetections(events,available,~)
% Словарь возможность → тик готовности; список возможностей.
ready=containers.Map('KeyType','double','ValueType','double'); occasions=zeros(0,1);
% Журнала нет — пустые результаты.
if ~available, return; end
% Для каждого события журнала BS:
for k=1:numel(events)
    % интересуют только результаты детектора NPRACH;
    e=events(k); if ~strcmp(e.kind,'nprach_detection'), continue; end
    % в событии должны быть номер возможности и тик готовности;
    if ~isfield(e.fields,'occasionId')||~isfield(e.fields,'readyTick')
        diagnosticsError('NPRACH detection lacks occasionId or readyTick.');
    end
    % номер возможности — целое >= 0;
    occasion=integerValue(e.fields.occasionId,'occasionId',0);
    % тик готовности — целое >= 0;
    tick=integerValue(e.fields.readyTick,'readyTick',0);
    % тик готовности положительный и равен тику события;
    if tick==0||tick~=double(e.tick)
        diagnosticsError('Receiver readyTick must be positive and equal the event tick.');
    end
    % одна возможность — один результат детектора;
    if any(occasions==occasion)
        diagnosticsError('Duplicate NPRACH detection occasion.');
    end
    % запоминаем возможность
    occasions(end+1,1)=occasion; %#ok<AGROW>
    % и её тик готовности.
    ready(occasion)=tick;
end
end

%INDEXTRUTH Группы попыток Msg1 по (возможность, NInit) — основа логических коллизий.
function [groups,ids]=indexTruth(events,available)
% Пустые группы и список номеров попыток.
groups=struct('occasionId',{},'nInit',{},'attemptIds',{}); ids=zeros(0,1);
% Журнала истины нет — пустые результаты.
if ~available, return; end
% Для каждого события истины:
for k=1:numel(events)
    % только передачи Msg1;
    e=events(k); if ~strcmp(e.kind,'msg1'), continue; end
    % поля события;
    f=e.fields;
    % нужны номер попытки, возможность и NInit;
    if ~all(isfield(f,{'attemptId','occasionId','nInit'}))
        diagnosticsError('Msg1 truth event lacks collision-group keys.');
    end
    % номер попытки — целое >= 1;
    id=integerValue(f.attemptId,'attemptId',1);
    % номер возможности — целое >= 0;
    occasion=integerValue(f.occasionId,'occasionId',0);
    % NInit — целое >= 0;
    nInit=integerValue(f.nInit,'nInit',0);
    % номер попытки не повторяется;
    if any(ids==id), diagnosticsError('Duplicate Msg1 attempt ID.'); end
    % запоминаем номер;
    ids(end+1,1)=id; %#ok<AGROW>
    % ищем группу с той же (возможность, NInit);
    at=find([groups.occasionId]==occasion & [groups.nInit]==nInit,1);
    % нет — создаём новую группу;
    if isempty(at)
        groups(end+1)=struct('occasionId',occasion,'nInit',nInit,'attemptIds',id); %#ok<AGROW>
    % есть — добавляем попытку в группу.
    else
        groups(at).attemptIds(end+1)=id;
    end
end
end

%INDEXCOMPONENTS Компоненты сигнала NPRACH по попыткам из диагностики приёма.
function components=indexComponents(events,available,ready,detected)
% Пустой массив компонент.
components=struct('occasionId',{},'attemptId',{},'startSample',{}, ...
    'endSampleExclusive',{},'readyTick',{});
% Журнала нет — пустой результат.
if ~available, return; end
% Уже встреченные номера попыток.
seen=zeros(0,1);
% Для каждого события диагностики:
for k=1:numel(events)
    % только компоненты NPRACH;
    e=events(k); if ~strcmp(e.kind,'nprach_component'), continue; end
    % поля события;
    f=e.fields;
    % обязательные поля компоненты;
    needed={'occasionId','attemptId','startSample','endSampleExclusive'};
    % все поля на месте;
    if ~all(isfield(f,needed)), diagnosticsError('NPRACH component is incomplete.'); end
    % номер возможности;
    occasion=integerValue(f.occasionId,'occasionId',0);
    % номер попытки;
    id=integerValue(f.attemptId,'attemptId',1);
    % первый отсчёт компоненты;
    a=integerValue(f.startSample,'startSample',0);
    % отсчёт после последнего;
    b=integerValue(f.endSampleExclusive,'endSampleExclusive',1);
    % интервал непустой и попытка не повторяется;
    if b<=a||any(seen==id), diagnosticsError('Invalid or duplicate NPRACH receiver component.'); end
    % запоминаем попытку;
    seen(end+1,1)=id; %#ok<AGROW>
    % для возможности должен быть результат детектора;
    if ~any(detected==occasion)||~isKey(ready,occasion)
        diagnosticsError('NPRACH component has no matching detection.');
    end
    % тик готовности возможности;
    readyTick=ready(occasion);
    % событие компоненты записано в тот же тик;
    if e.tick~=readyTick, diagnosticsError('Component tick differs from detection readyTick.'); end
    % добавляем компоненту.
    components(end+1)=struct('occasionId',occasion,'attemptId',id, ...
        'startSample',a,'endSampleExclusive',b,'readyTick',readyTick); %#ok<AGROW>
end
end

%INDEXOVERLAPS Пары попыток, сигналы которых перекрылись в приёмнике (физические коллизии).
function pairs=indexOverlaps(events,available,components,ready,horizon)
% Пустой массив пар.
pairs=struct('readyTick',{},'attemptIds',{});
% Журнала нет — пустой результат.
if ~available, return; end
% Уже встреченные тройки (возможность, попытка A, попытка B).
seen=zeros(0,3);
% Для каждого события диагностики:
for k=1:numel(events)
    % только перекрытия NPRACH;
    e=events(k); if ~strcmp(e.kind,'nprach_overlap'), continue; end
    % поля события и обязательные поля;
    f=e.fields; needed={'occasionId','attemptIdA','attemptIdB','startSample', ...
        'endSampleExclusive','signalPowerAW','signalPowerBW'};
    % все поля на месте;
    if ~all(isfield(f,needed)), diagnosticsError('NPRACH overlap event is incomplete.'); end
    % номер возможности;
    occasion=integerValue(f.occasionId,'occasionId',0);
    % номера двух попыток;
    a=integerValue(f.attemptIdA,'attemptIdA',1); b=integerValue(f.attemptIdB,'attemptIdB',1);
    % попытки должны быть разными;
    if a==b, diagnosticsError('An overlap pair needs two distinct attempts.'); end
    % пара по возрастанию и тройка с возможностью;
    pair=sort([a b]); triple=[occasion pair];
    % пара не повторяется;
    if ismember(triple,seen,'rows'), diagnosticsError('Duplicate or reversed physical overlap pair.'); end
    % запоминаем;
    seen(end+1,:)=triple; %#ok<AGROW>
    % компонента попытки A;
    ia=find([components.attemptId]==a & [components.occasionId]==occasion,1);
    % компонента попытки B;
    ib=find([components.attemptId]==b & [components.occasionId]==occasion,1);
    % обе компоненты должны существовать;
    if isempty(ia)||isempty(ib)
        diagnosticsError('Overlap pair references a missing receiver component.');
    end
    % тик готовности результата;
    readyTick=components(ia).readyTick;
    % у обеих компонент и события он одинаков;
    if components(ib).readyTick~=readyTick||e.tick~=readyTick
        diagnosticsError('Overlap event tick differs from the shared receiver readyTick.');
    end
    % общее начало пересечения сигналов;
    start=max(components(ia).startSample,components(ib).startSample);
    % общий конец пересечения;
    finish=min(components(ia).endSampleExclusive,components(ib).endSampleExclusive);
    % пересечение непустое и совпадает с записанным в событии;
    if start>=finish||f.startSample~=start||f.endSampleExclusive~=finish
        diagnosticsError('Overlap event does not match the components’ shared support.');
    end
    % учитываем только пары, готовые к горизонту.
    if readyTick<=horizon
        pairs(end+1)=struct('readyTick',readyTick,'attemptIds',pair); %#ok<AGROW>
    end
end
end

%COUNTLOGICAL Логические коллизии окна: группы >= 2 попыток с результатом детектора в (s, e].
function [groupCount,attemptCount]=countLogical(groups,ready,s,e)
% Счётчик групп и номера попавших попыток.
groupCount=0; ids=zeros(0,1);
% Для каждой группы:
for k=1:numel(groups)
    % возможность группы;
    occasion=groups(k).occasionId;
    % одна попытка — не коллизия; без результата детектора — пропуск;
    if numel(groups(k).attemptIds)<2||~isKey(ready,occasion), continue; end
    % тик готовности результата;
    tick=ready(occasion);
    % если он в окне —
    if tick>s&&tick<=e
        % группа +1
        groupCount=groupCount+1;
        % и её попытки — в список.
        ids=[ids;groups(k).attemptIds(:)]; %#ok<AGROW>
    end
end
% Число разных попыток в коллизиях окна.
attemptCount=numel(unique(ids));
end

%RETRYCOUNT Число повторных Msg1 (вторая и следующие попытки пакета), начатых в [s, e).
function count=retryCount(attempts,s,e)
% Номера пакетов с попытками; счётчик.
ids=unique(double([attempts.packetId])); count=0;
% Для каждого пакета:
for k=1:numel(ids)
    % его попытки;
    at=find(double([attempts.packetId])==ids(k));
    % по порядку начала (и номера);
    ordered=sortrows([[attempts(at).startTick].',[attempts(at).attemptId].'],[1 2]);
    % если попыток больше одной —
    if size(ordered,1)>1
        % начала повторных попыток
        retryStarts=ordered(2:end,1);
        % и сколько из них попало в окно.
        count=count+sum(retryStarts>=s&retryStarts<e);
    end
end
end

%INTEGERVALUE Значение — конечное целое не меньше MINIMUM, иначе ошибка.
function value=integerValue(value,name,minimum)
% Проверка типа, конечности, минимума и целочисленности.
if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<minimum||value~=fix(value)
    diagnosticsError('%s must be a finite integer >= %d.',name,minimum);
end
% Результат — double.
value=double(value);
end

%EMPTYDIAGNOSTICS Пустая таблица диагностики со всеми столбцами и типами.
function rows=emptyDiagnostics()
% Нулевое число строк, те же имена столбцов, что у полной таблицы.
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

%DIAGNOSTICSERROR Ошибка nbiot:dataset:Diagnostics с форматированным сообщением.
function diagnosticsError(message,varargin)
% Выбрасываем ошибку.
error('nbiot:dataset:Diagnostics',message,varargin{:});
end
