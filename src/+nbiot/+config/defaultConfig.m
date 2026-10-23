function cfg = defaultConfig()
%DEFAULTCONFIG Research profile static-v1, with no toolbox execution.
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
