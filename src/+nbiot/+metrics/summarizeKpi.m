function k=summarizeKpi(cfg,packets,attempts,observed,truth,usage,actualTick,harqJournal,queueSamples)
%SUMMARIZEKPI Итоговые KPI прогона (ТЗ §27) с явными числителями и знаменателями.
%   Основные: raSuccessProbability = успешные RA / начатые попытки Msg1 (§27.1);
%   deliveryProbability = доставленные (CRC OK) / созданные пакеты (§27.2);
%   throughputBitsPerSecond = полезные биты доставленных пакетов / длительность (§27.3).
%   Дополнительные: collisionAttemptProbability (доля попыток с совпавшим NInit), логические группы
%   коллизий, capture, обнаруженные преамбулы, среднее/макс. число попыток, задержка (средняя и p95,
%   только доставленные), BLER Msg3 и данных, занятость UL/DL/NPRACH, очереди BS и UE, HARQ.
%   Вероятности с нулевым знаменателем — NaN. Баланс created = delivered + dropped + unfinished проверяется.
%   «…Completed…»-варианты считают только завершённые объекты (без незавершённых к горизонту).
% Создано пакетов; доставлено, отброшено, не завершено — сначала нули.
k=struct('created',numel(packets),'delivered',0,'dropped',0,'unfinished',0);
% Если пакеты есть —
if ~isempty(packets)
    % считаем доставленные и отброшенные;
    k.delivered=sum(strcmp({packets.status},'delivered')); k.dropped=sum(strcmp({packets.status},'dropped'));
    % и незавершённые к горизонту.
    k.unfinished=sum(strcmp({packets.status},'unfinished'));
end
% Баланс: каждый пакет ровно в одном итоговом статусе.
assert(k.created==k.delivered+k.dropped+k.unfinished,'nbiot:metrics:Balance','Packet balance broken.');
% Попытки RA (Msg1): успех — получен Msg4 со своим идентификатором конкуренции.
k.raStarted=numel(attempts); k.raSuccess=0; k.raFailed=0; k.raUnfinished=0; k.collidingAttempts=0;
% Если попытки есть —
if ~isempty(attempts)
    % успешные и неуспешные попытки;
    k.raSuccess=sum(strcmp({attempts.status},'success')); k.raFailed=sum(strcmp({attempts.status},'failure'));
    % незавершённые = начатые − успешные − неуспешные; попытки с совпавшим NInit (коллизии).
    k.raUnfinished=k.raStarted-k.raSuccess-k.raFailed; k.collidingAttempts=sum([attempts.collision]);
end
% Вероятность успешного доступа (ТЗ §27.1) = успешные / начатые попытки.
k.raSuccessProbability=ratio(k.raSuccess,k.raStarted);
% То же только по завершённым попыткам.
k.raSuccessCompletedProbability=ratio(k.raSuccess,k.raSuccess+k.raFailed);
% Вероятность доставки (ТЗ §27.2) = доставленные / созданные; вероятность потери = отброшенные / созданные.
k.deliveryProbability=ratio(k.delivered,k.created); k.dropProbability=ratio(k.dropped,k.created);
% Доставка среди завершённых пакетов (без незавершённых к горизонту).
k.deliveryCompletedProbability=ratio(k.delivered,k.delivered+k.dropped);
% Вероятность коллизии = попытки с логической коллизией / все попытки.
k.collisionAttemptProbability=ratio(k.collidingAttempts,k.raStarted);
% Число логических групп коллизий.
k.logicalCollisionGroups=countLogicalCollisionGroups(attempts);
% Число событий capture (успех при коллизии).
k.captureEvents=0;
% Если попытки есть —
if ~isempty(attempts)
    % и есть поле capture —
    if isfield(attempts,'capture')
        % считаем попытки с capture;
        k.captureEvents=sum(logical([attempts.capture]));
    else
        % иначе — нет данных.
        k.captureEvents=NaN;
    end
end
% Счётчик обнаруженных преамбул.
k.detectedCandidates=0;
% По всем результатам детектора NPRACH:
for event=reshape(observed(strcmp({observed.kind},'nprach_detection')),1,[])
    % если число обнаружений корректное —
    if isstruct(event.fields)&&isfield(event.fields,'count')&& ...
            isnumeric(event.fields.count)&&isscalar(event.fields.count)&& ...
            isfinite(event.fields.count)&&event.fields.count>=0
        % добавляем его.
        k.detectedCandidates=k.detectedCandidates+double(event.fields.count);
    end
end
% Максимум попыток RA на пакет (по умолчанию — нет данных).
k.maxRaAttemptsPerPacket=NaN;
% Если у пакетов есть счётчик попыток —
if ~isempty(packets)&&isfield(packets,'attemptCount')
    % счётчики;
    attemptCounts=double([packets.attemptCount]);
    % если все корректные —
    if all(isfinite(attemptCounts))&&all(attemptCounts>=0)&& ...
            all(attemptCounts==fix(attemptCounts))
        % максимум.
        k.maxRaAttemptsPerPacket=max(attemptCounts);
    end
end
% Throughput по уникальным доставленным пакетам; повторы HARQ не увеличивают его повторно.
k.deliveredPayloadBits=k.delivered*cfg.traffic.packetBytes*8;
% Длительность расчёта в секундах.
k.durationSeconds=actualTick*cfg.simulation.tickSeconds;
% Пропускная способность (ТЗ §27.3) = полезные биты / длительность (бит/с).
k.throughputBitsPerSecond=ratio(k.deliveredPayloadBits,k.durationSeconds);
% Задержка доставки = тик доставки на BS − тик создания пакета (мс).
delays=[];
% Для каждого пакета:
for p=packets
    % доставленный — задержка = тик доставки − тик создания.
    if strcmp(p.status,'delivered'), delays(end+1)=double(p.deliveredTick)-double(p.createdTick); end %#ok<AGROW>
end
% Число доставок, средняя задержка и 95-й перцентиль (тики).
k.delayCount=numel(delays); k.meanDelayTicks=mean(delays); k.p95DelayTicks=percentile(delays,.95);
% BLER по журналу BS: доля ошибок CRC среди завершённых декодирований (повторы HARQ — отдельные).
k.msg3Decoded=0; k.msg3CrcFailures=0; k.dataDecoded=0; k.dataCrcFailures=0;
% Результаты декодирования на BS.
decodes=observed(strcmp({observed.kind},'phy_decode'));
% Для каждого:
for e=reshape(decodes,1,[])
    % поля события;
    f=e.fields;
    % Msg3 с CRC —
    if f.hasCrc && strcmp(f.channel,'Msg3')
        % декодирование +1, ошибка CRC — если crcError ≠ 0;
        k.msg3Decoded=k.msg3Decoded+1; k.msg3CrcFailures=k.msg3CrcFailures+double(f.crcError~=0);
    % данные с CRC —
    elseif f.hasCrc && strcmp(f.channel,'Data')
        % аналогично.
        k.dataDecoded=k.dataDecoded+1; k.dataCrcFailures=k.dataCrcFailures+double(f.crcError~=0);
    end
end
% BLER Msg3 и данных = ошибки CRC / декодирования.
k.msg3Bler=ratio(k.msg3CrcFailures,k.msg3Decoded); k.dataBler=ratio(k.dataCrcFailures,k.dataDecoded);
% Occupancy is the union of actually used allocation envelopes, not bookings.
n=max(0,min(actualTick,cfg.simulation.durationTicks)); ul=false(2*n,48); dl=false(n,1);
% Для каждой фактической передачи (из истины):
for e=reshape(truth(strcmp({truth.kind},'transmission')),1,[])
    % поля и тики внутри горизонта; пусто — пропуск;
    f=e.fields; ticks=f.ticks(f.ticks<n & f.ticks>=0); if isempty(ticks), continue; end
    % UL:
    if strcmpi(f.direction,'UL')
        % строки календаря — два полуподкадра на тик;
        rows=reshape([2*ticks(:)+1 2*ticks(:)+2].',[],1);
        % столбцы — тоны 3,75 кГц полосы передачи; отмечаем занятыми;
        bins=f.frequencyStartHz/3750+(1:f.bandwidthHz/3750); ul(rows,bins)=true;
    % DL: отмечаем подкадры.
    else, dl(ticks+1)=true; end
end
% Маска обязательных DL-подкадров.
mask=nbiot.scheduler.mandatoryDlMask(n,cfg.cell.cellId);
% Занятость UL: занятые ячейки / все ячейки.
k.ulOccupiedUnits=sum(ul,'all'); k.ulAvailableUnits=numel(ul); k.ulOccupancy=ratio(k.ulOccupiedUnits,k.ulAvailableUnits);
% Занятость DL: занятые доступные подкадры / доступные подкадры.
k.dlOccupiedUnits=sum(dl & ~mask(:)); k.dlAvailableUnits=sum(~mask); k.dlOccupancy=ratio(k.dlOccupiedUnits,k.dlAvailableUnits);
% Определение занятости (для отчёта).
k.occupancyDefinition='Union of transmitted resource allocation envelopes; mandatory DL excluded; NPRACH reserved band is 45 kHz.';
% Квоты и резервирования RA/DT по окнам (из календаря).
k.resourceBudgets=usage;
% Среднее число попыток RA на пакет.
k.meanRaAttempts=ratio(k.raStarted,k.created);
% Доля доставленных (= вероятность доставки).
k.deliveredFraction=k.deliveryProbability;
% Средняя задержка в секундах.
k.meanDelaySeconds=k.meanDelayTicks*cfg.simulation.tickSeconds;
% 95-й перцентиль задержки в секундах.
k.p95DelaySeconds=k.p95DelayTicks*cfg.simulation.tickSeconds;
% Занятость NPRACH: полоса 45 кГц (12 тонов × 3,75 кГц) в тиках фактических передач Msg1.
nprach=false(2*n,12);
% Для каждой фактической передачи:
for e=reshape(truth(strcmp({truth.kind},'transmission')),1,[])
    % поля;
    f=e.fields;
    % интересуют только NPRACH;
    if ~isfield(f,'channel') || ~strcmp(f.channel,'NPRACH'), continue; end
    % тики внутри горизонта;
    ticks=f.ticks(f.ticks<n & f.ticks>=0);
    % строки — полуподкадры;
    rows=reshape([2*ticks(:)+1 2*ticks(:)+2].',[],1);
    % отмечаем всю полосу NPRACH (12 тонов = 45 кГц).
    nprach(rows,:)=true;
end
% Занятые и все ячейки полосы NPRACH.
k.nprachOccupiedUnits=sum(nprach,'all'); k.nprachAvailableUnits=numel(nprach);
% Занятость NPRACH.
k.nprachOccupancy=ratio(k.nprachOccupiedUnits,k.nprachAvailableUnits);
% Тот же показатель (для совместимости).
k.nprachEnvelopeOccupancy=k.nprachOccupancy;
% Определение занятости NPRACH.
k.nprachOccupancyDefinition='Union of transmitted 45 kHz NPRACH allocation envelopes, divided by 45 kHz horizon; not instantaneous hopping-tone occupancy.';
% Сэмплы очереди запросов BS.
queues=[];
% Для каждого сэмпла очереди BS:
for e=reshape(observed(strcmp({observed.kind},'bs_queue')),1,[])
    % внутри горизонта — в список.
    if e.tick>=0 && e.tick<actualTick, queues(end+1)=e.fields.pendingRequests; end %#ok<AGROW>
end
% Средняя и максимальная очередь BS.
k.meanBsQueueLength=mean(queues); k.maxBsQueueLength=maximum(queues);
% Очереди UE — по умолчанию нет данных.
k.meanUeQueueLength=NaN; k.maxUeQueueLength=NaN; k.ueQueueSamples=0;
% Если есть сэмплы очередей UE —
if nargin>=9 && ~isempty(queueSamples)
    % сэмплы до горизонта;
    q=queueSamples(queueSamples(:,1)<actualTick,:);
    % их число;
    k.ueQueueSamples=size(q,1);
    % средняя очередь на UE = сумма длин / (число UE × число сэмплов);
    k.meanUeQueueLength=ratio(sum(q(:,2)),cfg.simulation.numUE*size(q,1));
    % максимальная очередь одного UE.
    k.maxUeQueueLength=maximum(q(:,3));
end
% Без журнала HARQ — пустой.
if nargin<8, harqJournal=[]; end
% Сводка HARQ.
k.harq=nbiot.metrics.harqSummary(harqJournal,actualTick);
% Заготовка KPI контроллера (заполняется в NBIoTSimulator.result).
k.controller=struct('applicable',false,'decisions',NaN,'configurationSwitches',NaN, ...
    'reason','controller-not-implemented');
end

%MAXIMUM Максимум; для пустого — NaN.
function v=maximum(x)
% Пустой список — NaN, иначе max.
if isempty(x), v=NaN; else, v=max(x); end
end
% Логическая группа коллизии — пара (возможность, NInit), выбранная двумя и более UE.
function count=countLogicalCollisionGroups(attempts)
% По умолчанию — нет данных.
count=NaN;
% Если попыток нет —
if isempty(attempts)
    % и поля на месте — групп 0.
    if all(isfield(attempts,{'collision','occasionId','nInit'})), count=0; end
    return;
end
% Нужные поля отсутствуют — нет данных.
if ~all(isfield(attempts,{'collision','occasionId','nInit'})), return; end
% Попытки с коллизией.
mask=logical([attempts.collision]);
% Коллизий нет — 0 групп.
if ~any(mask), count=0; return; end
% Пары (возможность, NInit) попыток с коллизией.
pairs=[double([attempts(mask).occasionId].'),double([attempts(mask).nInit].')];
% Номер группы для каждой пары.
[~,~,groups]=unique(pairs,'rows');
% Размеры групп.
groupSizes=accumarray(groups,1);
% Группы из 2 и более попыток.
count=sum(groupSizes>1);
end
function value=ratio(a,b), if b==0, value=NaN; else, value=a/b; end, end
% Перцентиль с линейной интерполяцией между порядковыми статистиками.
%PERCENTILE Перцентиль P (0..1) с линейной интерполяцией.
function value=percentile(x,p)
% Пустой — NaN.
if isempty(x), value=NaN; return; end
% Сортировка, дробная позиция, соседние порядковые статистики и интерполяция.
x=sort(x); r=1+(numel(x)-1)*p; a=floor(r); b=ceil(r); value=x(a)+(r-a)*(x(b)-x(a));
end
