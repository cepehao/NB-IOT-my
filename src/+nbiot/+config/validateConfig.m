function cfg = validateConfig(cfg)
%VALIDATECONFIG Проверяет конфигурацию до запуска (ТЗ §46.2, §46.15) и возвращает нормализованную.
%   CFG = nbiot.config.validateConfig(CFG). Сверяет структуру с defaultConfig (все поля на месте),
%   диапазоны и типы. Ошибки:
%     nbiot:config:InvalidValue        — значение вне допустимого диапазона/типа (указано поле);
%     nbiot:config:UnsupportedProfile  — параметр, который текущая PHY-реализация не поддерживает
%                                        (таблицы NPUSCH/NPDSCH/NPDCCH, формат NPRACH, HARQ);
%     nbiot:config:ResourceInfeasible  — ресурсы NPRACH не помещаются в период.
%   LTE Toolbox не вызывается.
% Эталон структуры и значений по умолчанию.
base = nbiot.config.defaultConfig();
% Совместимость со старыми конфигурациями без полей активности трафика.
% Если поле traffic есть и это одна struct —
if isstruct(cfg)&&isscalar(cfg)&&isfield(cfg,'traffic')&&isstruct(cfg.traffic)&&isscalar(cfg.traffic)
    % добавляем режим активности 'all', если его нет (старые конфигурации),
    if ~isfield(cfg.traffic,'activityMode'), cfg.traffic.activityMode=base.traffic.activityMode; end
    % и пустой список активных UE.
    if ~isfield(cfg.traffic,'activeUeIds'), cfg.traffic.activeUeIds=base.traffic.activeUeIds; end
end
% Все поля эталона должны присутствовать (рекурсивно по вложенным struct).
checkFields(cfg,base,'cfg');
% Поддерживается только профиль static-v1.
unsupported(strcmp(cfg.profileVersion,base.profileVersion),'profileVersion','only static-v1 supported');
% Короткие имена разделов для проверок ниже.
s=cfg.simulation; c=cfg.cell; h=cfg.channel; t=cfg.traffic; r=cfg.ra;
% Число UE 1..65535 и длительность 1..2^24−1 тиков — целые.
integer(s.numUE,1,65535,'simulation.numUE'); integer(s.durationTicks,1,2^24-1,'simulation.durationTicks');
% seed 0..2^32−1 и номер реализации 0..4095 — целые.
integer(s.seed,0,2^32-1,'simulation.seed'); integer(s.realizationId,0,4095,'simulation.realizationId');
% Шаг модели 1 мс и частота отсчётов 1,92 МГц зашиты в PHY и канал (1 тик = 1920 отсчётов).
must(s.tickSeconds==.001 && s.sampleRateHz==1920000,'simulation','requires 1 ms ticks and 1.92 MHz');
% Радиус > 0, минимальное расстояние >= 0, радиус больше минимального расстояния.
positive(c.radiusM,'cell.radiusM'); nonnegative(c.minDistanceM,'cell.minDistanceM'); must(c.radiusM>c.minDistanceM,'cell.radiusM','must exceed minimum radius');
% Высоты BS и UE >= 0, доля indoor в [0,1], идентификатор соты 0..503 (диапазон NNCellID).
nonnegative(c.bsHeightM,'cell.bsHeightM'); nonnegative(c.ueHeightM,'cell.ueHeightM'); unit(c.indoorFraction,'cell.indoorFraction'); integer(c.cellId,0,503,'cell.cellId');
% Несущая, опорное расстояние, показатель потерь и температура — строго положительны.
for f={'carrierHz','referenceDistanceM','pathLossExponent','temperatureK'}, positive(h.(f{1}),['channel.' f{1}]); end
% Shadowing, проникновение, σ и предел CFO, рассинхрон — неотрицательны.
for f={'shadowOutdoorDb','shadowIndoorDb','penetrationIndoorDb','cfoSigmaHz','cfoLimitHz','syncLimitSeconds'}, nonnegative(h.(f{1}),['channel.' f{1}]); end
% Мощности и коэффициенты шума — конечные числа (могут быть любого знака).
for f={'uePowerDbm','bsPowerDbm','bsNoiseFigureDb','ueNoiseFigureDb'}, finite(h.(f{1}),['channel.' f{1}]); end
% Задержки отводов fading — конечные, неотрицательные, по возрастанию.
must(isnumeric(h.tapDelaysSeconds)&&isvector(h.tapDelaysSeconds)&&all(isfinite(h.tapDelaysSeconds))&&all(h.tapDelaysSeconds>=0)&&all(diff(h.tapDelaysSeconds)>=0),'channel.tapDelaysSeconds','requires sorted nonnegative finite delays');
% Мощностей отводов столько же, сколько задержек, все конечные.
must(isnumeric(h.tapPowersDb)&&numel(h.tapPowersDb)==numel(h.tapDelaysSeconds)&&all(isfinite(h.tapPowersDb)),'channel.tapPowersDb','requires one finite power per tap');
% Длина фильтра дробной задержки — нечётное целое 3..4095 (симметричное ядро).
integer(h.fractionalFilterLength,3,4095,'channel.fractionalFilterLength'); must(mod(h.fractionalFilterLength,2)==1,'channel.fractionalFilterLength','must be odd');
% Тип трафика — один из поддерживаемых.
must(any(strcmp(t.kind,{'burst','periodic','poisson','none'})),'traffic.kind','unknown traffic');
% Режим активности — строка ('all' или 'explicit').
must((ischar(t.activityMode)&&isrow(t.activityMode))|| ...
    (isstring(t.activityMode)&&isscalar(t.activityMode)), ...
    'traffic.activityMode','all or explicit required');
% Значение режима активности — 'all' или 'explicit'.
must(any(strcmp(char(t.activityMode),{'all','explicit'})), ...
    'traffic.activityMode','all or explicit required');
% Для явного списка активных UE —
if strcmp(char(t.activityMode),'explicit')
    % берём список,
    ids=t.activeUeIds;
    % проверяем: уникальные конечные целые номера UE в [1, numUE],
    must(isnumeric(ids)&&isreal(ids)&&(isempty(ids)||isvector(ids))&& ...
        all(isfinite(ids(:)))&&all(ids(:)==fix(ids(:)))&& ...
        all(ids(:)>=1)&&all(ids(:)<=s.numUE)&&numel(unique(ids))==numel(ids), ...
        'traffic.activeUeIds','unique finite integer UE IDs in [1,numUE] required');
    % и сохраняем отсортированной строкой double.
    cfg.traffic.activeUeIds=sort(double(ids(:).'));
end
% Размер пакета 1..6630 байт; лимит очереди 1..65535.
integer(t.packetBytes,1,6630,'traffic.packetBytes'); integer(t.queueLimit,1,65535,'traffic.queueLimit');
% Период, длительность всплеска и срок жизни пакета — целые тики >= 1.
for f={'periodTicks','burstDurationTicks','lifetimeTicks'}, integer(t.(f{1}),1,2^24-1,['traffic.' f{1}]); end
% Начало всплеска — целый тик >= 0; интенсивность Пуассона — неотрицательна.
integer(t.burstStartTick,0,2^24-1,'traffic.burstStartTick'); nonnegative(t.poissonRatePerSecond,'traffic.poissonRatePerSecond');
% NPRACH: реализован только формат 0, 1 повтор, 12 поднесущих (ADR-005).
% Параметры RA (попытки, период, поднесущие, повторы, окна RAR и contention) — целые >= 1.
for f={'maxAttempts','periodTicks','numSubcarriers','repetitions','rarPp','contentionPp'}, integer(r.(f{1}),1,65535,['ra.' f{1}]); end
% Окно BACKOFF — целое >= 0; сдвиг возможности NPRACH — внутри периода.
integer(r.backoffTicks,0,2^24-1,'ra.backoffTicks'); integer(r.startOffsetTicks,0,r.periodTicks-1,'ra.startOffsetTicks');
% Реализация PHY поддерживает только формат 0, 1 повтор, 12 поднесущих.
unsupported(r.format==0&&r.repetitions==1&&r.numSubcarriers==12,'ra','only configured format 0, one repetition, 12 subcarriers');
% Возможность NPRACH (6 тиков) должна помещаться в период.
if r.startOffsetTicks+6>r.periodTicks, error('nbiot:config:ResourceInfeasible','ra occasion exceeds its period'); end
% Вероятность доступа P и доля RA — в [0,1].
unit(cfg.policy.accessProbability,'policy.accessProbability'); unit(cfg.policy.raShare,'policy.raShare');
% Окна политики и датасета — целые тики >= 1.
integer(cfg.policy.windowTicks,1,2^24-1,'policy.windowTicks'); integer(cfg.dataset.windowTicks,1,2^24-1,'dataset.windowTicks');
% Имя метода управления.
method=cfg.policy.name;
% Метод — строка из списка: Static, Adaptive-P, Adaptive-RA/DT.
must((ischar(method)||(isstring(method)&&isscalar(method)))&& ...
    any(strcmp(char(string(method)),{'Static','Adaptive-P','Adaptive-RA/DT'})), ...
    'policy.name','unknown control method');
% Контроллер решает раз в 500 мс по окну датасета той же длины (ТЗ §23).
% Для адаптивных методов —
if any(strcmp(char(string(method)),{'Adaptive-P','Adaptive-RA/DT'}))
    % окна политики и датасета обязаны быть по 500 мс.
    must(cfg.policy.windowTicks==500&&cfg.dataset.windowTicks==500, ...
        'policy.windowTicks','adaptive modes require matching 500 ms windows');
end
% Частота отсчётов PHY и идентификатор соты в разделах phy и simulation/cell совпадают.
must(cfg.phy.sampleRateHz==s.sampleRateHz&&cfg.phy.cellId==c.cellId,'phy','sample rate and cell ID must agree');
% Параметры обработки, HARQ, декодера и тайм-аутов — целые >= 1.
for f={'processingTicks','maxHarqTransmissions','decoderIterations','progressTimeoutTicks','receiptTimeoutTicks','maxReceiptTransmissions'}, integer(cfg.phy.(f{1}),1,2^24-1,['phy.' f{1}]); end
% Таблицы PHY (TBS, повторы, слоты) согласованы между собой — менять их по отдельности нельзя.
% Таблицы профилей каналов должны совпадать с эталоном static-v1.
for f={'msg3','data','ack','downlink','npdcch'}, unsupported(isequal(cfg.phy.(f{1}),base.phy.(f{1})),['phy.' f{1}],'static-v1 tables must match baseline'); end
% HARQ: ровно 4 передачи с RV 0,2,0,2.
unsupported(isequal(cfg.phy.rvSequence,[0 2 0 2])&&cfg.phy.maxHarqTransmissions==4,'phy.rvSequence','requires four bundles 0/2/0/2');
% Порог NPRACH: NaN — калибровка не загружена (запуск KPI-эксперимента запрещён), иначе (0, 1].
% Порог детектора NPRACH: NaN (не загружен) или в (0,1].
must(isscalar(cfg.phy.nprachThreshold)&&(isnan(cfg.phy.nprachThreshold)||(isfinite(cfg.phy.nprachThreshold)&&cfg.phy.nprachThreshold>0&&cfg.phy.nprachThreshold<=1)),'phy.nprachThreshold','NaN means calibration required; otherwise (0,1]');
% Сетка поиска CFO — непустой вектор конечных значений.
must(isnumeric(cfg.phy.nprachCfoGridHz)&&isvector(cfg.phy.nprachCfoGridHz)&&all(isfinite(cfg.phy.nprachCfoGridHz))&&~isempty(cfg.phy.nprachCfoGridHz),'phy.nprachCfoGridHz','finite nonempty grid required');
% Флаг сохранения waveform — логический скаляр.
must(islogical(cfg.logging.saveWaveforms)&&isscalar(cfg.logging.saveWaveforms),'logging.saveWaveforms','scalar logical required');
% Папка результатов — непустая строка.
must((ischar(cfg.logging.outputFolder)||isstring(cfg.logging.outputFolder))&&strlength(string(cfg.logging.outputFolder))>0,'logging.outputFolder','nonempty folder required');
% Путь папки не должен указывать на существующий файл.
must(~isfile(cfg.logging.outputFolder),'logging.outputFolder','path names an existing file');
end
% Рекурсивно проверяет, что в A есть все поля эталона B.
function checkFields(a,b,p)
% Проверяемое значение — одна struct.
must(isstruct(a)&&isscalar(a),p,'scalar struct required');
% Для каждого поля эталона: оно есть в A; если это struct — проверяем рекурсивно.
fs=fieldnames(b); for k=1:numel(fs), f=fs{k}; must(isfield(a,f),[p '.' f],'missing field'); if isstruct(b.(f)), checkFields(a.(f),b.(f),[p '.' f]); end, end
end
% Проверки скаляров: конечное, целое в [a,b], положительное, неотрицательное, в [0,1].
% Конечное действительное число-скаляр.
function finite(x,p), must(isnumeric(x)&&isreal(x)&&isscalar(x)&&isfinite(x),p,'finite real scalar required'); end
% Целое в [a, b].
function integer(x,a,b,p), finite(x,p); must(x==fix(x)&&x>=a&&x<=b,p,sprintf('integer in [%g,%g] required',a,b)); end
% Строго положительное.
function positive(x,p), finite(x,p); must(x>0,p,'must be positive'); end
% Неотрицательное.
function nonnegative(x,p), finite(x,p); must(x>=0,p,'must be nonnegative'); end
% В отрезке [0, 1].
function unit(x,p), finite(x,p); must(x>=0&&x<=1,p,'must lie in [0,1]'); end
% Если условие не выполнено — ошибка nbiot:config:InvalidValue с именем поля и причиной.
function must(ok,p,why), if ~ok, error('nbiot:config:InvalidValue','%s: %s',p,why); end, end
% Если условие не выполнено — ошибка nbiot:config:UnsupportedProfile (не поддержано реализацией).
function unsupported(ok,p,why), if ~ok, error('nbiot:config:UnsupportedProfile','%s: %s',p,why); end, end
