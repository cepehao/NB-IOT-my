function cfg = defaultConfig()
%DEFAULTCONFIG Базовая конфигурация модели (профиль static-v1, ТЗ §10, §13, §30; ADR-005).
%   CFG = nbiot.config.defaultConfig() возвращает struct со всеми параметрами. Значения из ТЗ
%   помечены [ТЗ], проектные решения — [решение] (обоснование — docs/model-profile.md).
%   Перед запуском cfg проверяется nbiot.config.validateConfig.
%
%   simulation  — время и масштаб:
%     durationTicks 5000 тиков [ТЗ §30], tickSeconds 1e-3 с (шаг 1 мс) [ТЗ], sampleRateHz 1,92 МГц
%     (частота отсчётов NB-IoT UL/DL), numUE 1000 [ТЗ], seed 42 [ТЗ], realizationId — номер внешней
%     реализации 0..4095 (одинаков для Static и Adaptive при сравнении, ТЗ §63).
%   cell        — геометрия [ТЗ §10]: радиус 1000 м, мин. расстояние 10 м, высоты BS 30 м и UE 1,5 м,
%     доля indoor 0,30; cellId — NNCellID.
%   channel     — радиоканал [ТЗ §13]: несущая 900 МГц; path loss log-distance с d0 = 10 м и
%     показателем 3,5 [решение]; shadowing σ 8/10 дБ, penetration indoor 20 дБ, мощность UE 23 дБм,
%     NF BS 5 дБ, 290 K [ТЗ]; мощность BS 23 дБм, NF UE 7 дБ [решение]; CFO σ 50 Гц, предел ±200 Гц
%     [ТЗ]; рассинхронизация UE ±2 мкс; fading — 3 отвода Rayleigh с задержками 0/0,3/0,9 мкс и
%     мощностями 0/−3/−6 дБ [решение]; длина фильтра дробной задержки 65 отсчётов.
%   traffic     — нагрузка [ТЗ §11, §30]: kind 'burst' | 'periodic' | 'poisson' | 'none'; пакет 200 байт,
%     очередь 10 [ТЗ]; период 1000 мс, интенсивность Пуассона 0,2 пак/с; всплеск с 1000 мс длиной
%     100 мс; срок жизни пакета 10 000 мс; activityMode 'all' | 'explicit' (activeUeIds).
%   ra          — случайный доступ: maxAttempts 8 [ТЗ §30]; BACKOFF 0..256 мс; NPRACH формат 0,
%     период 80 мс, старт 8 мс, 12 поднесущих (NInit 0..11), 1 повтор; окно RAR pp10 и
%     contention timer pp16 в периодах поиска NPDCCH [решение, TS 36.321].
%   phy         — PHY: обработка 1 тик; HARQ до 4 передач с RV 0,2,0,2; 5 итераций турбо-декодера;
%     тайм-ауты прогресса 1024 мс и квитанции 512 мс; nprachThreshold — порог детектора из
%     калибровки (NaN = не загружен); сетка поиска CFO NPRACH −200..200 Гц шаг 25 Гц.
%     msg3/data/ack — профили NPUSCH: формат, разнос 15 кГц, поднесущие, NRU, слоты, повторы,
%     TBS (Msg3 88 бит, данные 256 бит, ACK 1 бит), длительность в тиках.
%     downlink — NPDSCH: QPSK, MCS 6, TBS 88, 2 повтора; npdcch — Rmax 4, G 8, повторы 2, AL 2.
%   policy      — управление [ТЗ §23–26]: 'Static' | 'Adaptive-P' | 'Adaptive-RA/DT'; вероятность
%     доступа P = 1 и доля RA 0,1 (Static RA/DT = 10/90); окно решений 500 мс.
%   dataset     — окно записи датасета 500 мс [решение, = период контроллера].
%   logging     — сохранять ли waveform; папка результатов (results/, не в git).
cfg.profileVersion = 'static-v1';
cfg.simulation = struct('durationTicks',5000,'tickSeconds',1e-3,'sampleRateHz',1920000,'numUE',1000,'seed',42,'realizationId',0);
cfg.cell = struct('radiusM',1000,'minDistanceM',10,'bsHeightM',30,'ueHeightM',1.5,'indoorFraction',.30,'cellId',1);
cfg.channel = struct('carrierHz',900e6,'referenceDistanceM',10,'pathLossExponent',3.5,'shadowOutdoorDb',8,'shadowIndoorDb',10,'penetrationIndoorDb',20,'uePowerDbm',23,'bsPowerDbm',23,'bsNoiseFigureDb',5,'ueNoiseFigureDb',7,'temperatureK',290,'cfoSigmaHz',50,'cfoLimitHz',200,'syncLimitSeconds',2e-6,'tapDelaysSeconds',[0 .3 .9]*1e-6,'tapPowersDb',[0 -3 -6],'fractionalFilterLength',65);
cfg.traffic = struct('kind','burst','packetBytes',200,'queueLimit',10,'periodTicks',1000,'poissonRatePerSecond',.2,'burstStartTick',1000,'burstDurationTicks',100,'lifetimeTicks',10000,'activityMode','all','activeUeIds',[]);
cfg.ra = struct('maxAttempts',8,'backoffTicks',256,'periodTicks',80,'startOffsetTicks',8,'numSubcarriers',12,'format',0,'repetitions',1,'rarPp',10,'contentionPp',16);
cfg.phy = struct('processingTicks',1,'cellId',1,'sampleRateHz',1920000,'maxHarqTransmissions',4,'rvSequence',[0 2 0 2],'decoderIterations',5,'progressTimeoutTicks',1024,'receiptTimeoutTicks',512,'maxReceiptTransmissions',4,'nprachThreshold',NaN,'nprachCfoGridHz',-200:25:200);
cfg.phy.msg3 = struct('format','Data','spacingHz',15000,'numSubcarriers',3,'nru',1,'nulSlots',8,'repetitions',2,'tbs',88,'rarIndex',2,'durationTicks',8);
cfg.phy.data = struct('format','Data','spacingHz',15000,'numSubcarriers',3,'nru',4,'nulSlots',8,'repetitions',2,'tbs',256,'mcs',4,'iru',3,'durationTicks',32);
cfg.phy.ack = struct('format','Control','spacingHz',15000,'numSubcarriers',1,'nru',1,'nulSlots',4,'repetitions',2,'tbs',1,'durationTicks',4);
cfg.phy.downlink = struct('modulation','QPSK','mcs',6,'isf',0,'nsf',1,'tbs',88,'repetitions',2,'nbRefP',1);
cfg.phy.npdcch = struct('rmax',4,'g',8,'offset',0,'repetitions',2,'aggregationLevel',2);
cfg.policy = struct('name','Static','accessProbability',1,'raShare',.1,'windowTicks',500);
cfg.dataset = struct('windowTicks',500);
cfg.logging = struct('saveWaveforms',false,'outputFolder','results');
cfg.parameterSources = struct('simulation','requirement','geometry','requirement','channel','static-v1 research decision','phy','Release 13 and static-v1 research decision','traffic','static-v1 research decision');
end
