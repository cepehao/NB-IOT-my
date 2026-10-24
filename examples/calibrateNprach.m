function report=calibrateNprach(cfg,outputFile,options)
%CALIBRATENPRACH Калибровка порога детектора NPRACH (долгий расчёт: 20 000 окон подбора + проверка).
%   Порог подбирается по целевой вероятности ложной тревоги 5e-4 на окнах только с шумом, затем
%   проверяется на новых реализациях (95 %-ная верхняя граница P_FA <= 1e-3).
%   Результат — results/nprach-calibration.mat (обязателен для запуска симулятора). Перекалибровка
%   нужна при смене конфигурации NPRACH или алгоритма детектора (nbiot.phy.nprach.receiverRevision).
%   OPTIONS: fitRealizationId (4000), validationRealizationIds (4005:4008), maxSeconds (Inf).
if nargin<1, cfg=nbiot.config.defaultConfig(); end
if nargin<2, outputFile=fullfile(cfg.logging.outputFolder,'nprach-calibration.mat'); end
if nargin<3, options=struct(); end
if ~isfield(options,'maxSeconds'), options.maxSeconds=Inf; end
if ~isfield(options,'fitRealizationId'), options.fitRealizationId=4000; end
if ~isfield(options,'validationRealizationIds'), options.validationRealizationIds=4005:4008; end
validateattributes(options.fitRealizationId,{'numeric'},{'scalar','integer','nonnegative'});
validateattributes(options.validationRealizationIds,{'numeric'},{'vector','integer','nonnegative','nonempty'});
assert(numel(unique([options.fitRealizationId options.validationRealizationIds]))==1+numel(options.validationRealizationIds),...
    'nbiot:phy:Calibration','Fit and validation realization IDs must be distinct.');
thresholdFloor=.005; cfg.phy.nprachThreshold=thresholdFloor;
n=20000; pfa=0.0005; clockStart=tic;
fit=measure(cfg,options.fitRealizationId,n,clockStart,options.maxSeconds); sorted=sort(fit);
% The measured maximum includes only candidates passing the calibrated
% full-sequence match, so false-alarm calibration covers the actual detector.
threshold=max(thresholdFloor,min(1,sorted(ceil((1-pfa)*n))+eps(sorted(ceil((1-pfa)*n)))));
history=struct('realizationId',{},'threshold',{},'falseAlarms',{},'interval95',{},'accepted',{});
for attempt=1:numel(options.validationRealizationIds)
    id=options.validationRealizationIds(attempt);
    maxima=measure(cfg,id,n,clockStart,options.maxSeconds); falseAlarms=sum(maxima>=threshold);
    if falseAlarms==0, lo=0; else, lo=betaincinv(.025,falseAlarms,n-falseAlarms+1); end
    if falseAlarms==n, hi=1; else, hi=betaincinv(.975,falseAlarms+1,n-falseAlarms); end
    accepted=hi<=.001;
    history(end+1)=struct('realizationId',id,'threshold',threshold,...
        'falseAlarms',falseAlarms,'interval95',[lo hi],'accepted',accepted); %#ok<AGROW>
    if accepted, break; end
    % A failed validation becomes development evidence; acceptance uses new data.
    a=sort(maxima); threshold=max(threshold,a(ceil((1-pfa/2^attempt)*n))+eps);
end
report=struct('profileVersion',cfg.profileVersion,'seed',cfg.simulation.seed,...
    'fitRealizationId',options.fitRealizationId,'numFitWindows',n,'numValidationWindows',n,...
    'targetPfa',pfa,'threshold',threshold,'thresholdFloor',thresholdFloor,'history',history,'accepted',accepted,...
    'cfoGridHz',cfg.phy.nprachCfoGridHz,'interferenceValidated',false,...
    'toolboxVersion',ver('lte'),'matlabRelease',version('-release'));
report.profile=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId,...
    'format',cfg.ra.format,'periodTicks',cfg.ra.periodTicks,...
    'numSubcarriers',cfg.ra.numSubcarriers,'repetitions',cfg.ra.repetitions,...
    'sampleRateHz',cfg.phy.sampleRateHz,'fractionalFilterLength',cfg.channel.fractionalFilterLength,...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(),'cfoLimitHz',cfg.channel.cfoLimitHz);
report.noiseFitMaxima=fit; report.noiseValidationMaxima=maxima;
report.elapsedSeconds=toc(clockStart);
folder=fileparts(outputFile); if ~isempty(folder) && ~exist(folder,'dir'), mkdir(folder); end
save(outputFile,'report');
assert(accepted,'nbiot:phy:Calibration','Noise validation failed; saved report is not a usable acceptance artifact.');
end
function maxima=measure(cfg,realizationId,n,clockStart,maxSeconds)
sources=nbiot.randomness.RandomSources(cfg.simulation.seed,realizationId);
occasion=struct('occasionId',1,'startTick',8); bank=nbiot.phy.nprach.templates(cfg);
first=8*1920-16; count=numel(bank{1}.waveform)+128;
maxima=zeros(n,1);
for k=1:n
    if toc(clockStart)>=maxSeconds
        error('nbiot:phy:CalibrationTimeout','Calibration time limit options.maxSeconds exhausted.');
    end
    stream=sources.stream('noise',0,0,k);
    w=complex(randn(stream,count,1),randn(stream,count,1))/sqrt(2);
    rx=struct('waveform',w,'sampleRateHz',1920000,'startSample',first);
    [detected,~]=nbiot.phy.nprach.detect(cfg,rx,occasion);
    if isempty(detected), maxima(k)=0; else, maxima(k)=max([detected.metric]); end
    if mod(k,1000)==0, fprintf('NPRACH realization %d: %d/%d windows\n',realizationId,k,n); end
end
end
