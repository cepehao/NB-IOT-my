function cfg = validateConfig(cfg)
%VALIDATECONFIG Validate configuration without opening MATLAB LTE functions.
base = nbiot.config.defaultConfig();
if isstruct(cfg)&&isscalar(cfg)&&isfield(cfg,'traffic')&&isstruct(cfg.traffic)&&isscalar(cfg.traffic)
    if ~isfield(cfg.traffic,'activityMode'), cfg.traffic.activityMode=base.traffic.activityMode; end
    if ~isfield(cfg.traffic,'activeUeIds'), cfg.traffic.activeUeIds=base.traffic.activeUeIds; end
end
checkFields(cfg,base,'cfg');
unsupported(strcmp(cfg.profileVersion,base.profileVersion),'profileVersion','only static-v1 supported');
s=cfg.simulation; c=cfg.cell; h=cfg.channel; t=cfg.traffic; r=cfg.ra;
integer(s.numUE,1,65535,'simulation.numUE'); integer(s.durationTicks,1,2^24-1,'simulation.durationTicks');
integer(s.seed,0,2^32-1,'simulation.seed'); integer(s.realizationId,0,4095,'simulation.realizationId');
must(s.tickSeconds==.001 && s.sampleRateHz==1920000,'simulation','requires 1 ms ticks and 1.92 MHz');
positive(c.radiusM,'cell.radiusM'); nonnegative(c.minDistanceM,'cell.minDistanceM'); must(c.radiusM>c.minDistanceM,'cell.radiusM','must exceed minimum radius');
nonnegative(c.bsHeightM,'cell.bsHeightM'); nonnegative(c.ueHeightM,'cell.ueHeightM'); unit(c.indoorFraction,'cell.indoorFraction'); integer(c.cellId,0,503,'cell.cellId');
for f={'carrierHz','referenceDistanceM','pathLossExponent','temperatureK'}, positive(h.(f{1}),['channel.' f{1}]); end
for f={'shadowOutdoorDb','shadowIndoorDb','penetrationIndoorDb','cfoSigmaHz','cfoLimitHz','syncLimitSeconds'}, nonnegative(h.(f{1}),['channel.' f{1}]); end
for f={'uePowerDbm','bsPowerDbm','bsNoiseFigureDb','ueNoiseFigureDb'}, finite(h.(f{1}),['channel.' f{1}]); end
must(isnumeric(h.tapDelaysSeconds)&&isvector(h.tapDelaysSeconds)&&all(isfinite(h.tapDelaysSeconds))&&all(h.tapDelaysSeconds>=0)&&all(diff(h.tapDelaysSeconds)>=0),'channel.tapDelaysSeconds','requires sorted nonnegative finite delays');
must(isnumeric(h.tapPowersDb)&&numel(h.tapPowersDb)==numel(h.tapDelaysSeconds)&&all(isfinite(h.tapPowersDb)),'channel.tapPowersDb','requires one finite power per tap');
integer(h.fractionalFilterLength,3,4095,'channel.fractionalFilterLength'); must(mod(h.fractionalFilterLength,2)==1,'channel.fractionalFilterLength','must be odd');
must(any(strcmp(t.kind,{'burst','periodic','poisson','none'})),'traffic.kind','unknown traffic');
must((ischar(t.activityMode)&&isrow(t.activityMode))|| ...
    (isstring(t.activityMode)&&isscalar(t.activityMode)), ...
    'traffic.activityMode','all or explicit required');
must(any(strcmp(char(t.activityMode),{'all','explicit'})), ...
    'traffic.activityMode','all or explicit required');
if strcmp(char(t.activityMode),'explicit')
    ids=t.activeUeIds;
    must(isnumeric(ids)&&isreal(ids)&&(isempty(ids)||isvector(ids))&& ...
        all(isfinite(ids(:)))&&all(ids(:)==fix(ids(:)))&& ...
        all(ids(:)>=1)&&all(ids(:)<=s.numUE)&&numel(unique(ids))==numel(ids), ...
        'traffic.activeUeIds','unique finite integer UE IDs in [1,numUE] required');
    cfg.traffic.activeUeIds=sort(double(ids(:).'));
end
integer(t.packetBytes,1,6630,'traffic.packetBytes'); integer(t.queueLimit,1,65535,'traffic.queueLimit');
for f={'periodTicks','burstDurationTicks','lifetimeTicks'}, integer(t.(f{1}),1,2^24-1,['traffic.' f{1}]); end
integer(t.burstStartTick,0,2^24-1,'traffic.burstStartTick'); nonnegative(t.poissonRatePerSecond,'traffic.poissonRatePerSecond');
for f={'maxAttempts','periodTicks','numSubcarriers','repetitions','rarPp','contentionPp'}, integer(r.(f{1}),1,65535,['ra.' f{1}]); end
integer(r.backoffTicks,0,2^24-1,'ra.backoffTicks'); integer(r.startOffsetTicks,0,r.periodTicks-1,'ra.startOffsetTicks');
unsupported(r.format==0&&r.repetitions==1&&r.numSubcarriers==12,'ra','only configured format 0, one repetition, 12 subcarriers');
if r.startOffsetTicks+6>r.periodTicks, error('nbiot:config:ResourceInfeasible','ra occasion exceeds its period'); end
unit(cfg.policy.accessProbability,'policy.accessProbability'); unit(cfg.policy.raShare,'policy.raShare');
integer(cfg.policy.windowTicks,1,2^24-1,'policy.windowTicks'); integer(cfg.dataset.windowTicks,1,2^24-1,'dataset.windowTicks');
method=cfg.policy.name;
must((ischar(method)||(isstring(method)&&isscalar(method)))&& ...
    any(strcmp(char(string(method)),{'Static','Adaptive-P','Adaptive-RA/DT'})), ...
    'policy.name','unknown control method');
if any(strcmp(char(string(method)),{'Adaptive-P','Adaptive-RA/DT'}))
    must(cfg.policy.windowTicks==500&&cfg.dataset.windowTicks==500, ...
        'policy.windowTicks','adaptive modes require matching 500 ms windows');
end
must(cfg.phy.sampleRateHz==s.sampleRateHz&&cfg.phy.cellId==c.cellId,'phy','sample rate and cell ID must agree');
for f={'processingTicks','maxHarqTransmissions','decoderIterations','progressTimeoutTicks','receiptTimeoutTicks','maxReceiptTransmissions'}, integer(cfg.phy.(f{1}),1,2^24-1,['phy.' f{1}]); end
for f={'msg3','data','ack','downlink','npdcch'}, unsupported(isequal(cfg.phy.(f{1}),base.phy.(f{1})),['phy.' f{1}],'static-v1 tables must match baseline'); end
unsupported(isequal(cfg.phy.rvSequence,[0 2 0 2])&&cfg.phy.maxHarqTransmissions==4,'phy.rvSequence','requires four bundles 0/2/0/2');
must(isscalar(cfg.phy.nprachThreshold)&&(isnan(cfg.phy.nprachThreshold)||(isfinite(cfg.phy.nprachThreshold)&&cfg.phy.nprachThreshold>0&&cfg.phy.nprachThreshold<=1)),'phy.nprachThreshold','NaN means calibration required; otherwise (0,1]');
must(isnumeric(cfg.phy.nprachCfoGridHz)&&isvector(cfg.phy.nprachCfoGridHz)&&all(isfinite(cfg.phy.nprachCfoGridHz))&&~isempty(cfg.phy.nprachCfoGridHz),'phy.nprachCfoGridHz','finite nonempty grid required');
must(islogical(cfg.logging.saveWaveforms)&&isscalar(cfg.logging.saveWaveforms),'logging.saveWaveforms','scalar logical required');
must((ischar(cfg.logging.outputFolder)||isstring(cfg.logging.outputFolder))&&strlength(string(cfg.logging.outputFolder))>0,'logging.outputFolder','nonempty folder required');
must(~isfile(cfg.logging.outputFolder),'logging.outputFolder','path names an existing file');
end
function checkFields(a,b,p)
must(isstruct(a)&&isscalar(a),p,'scalar struct required');
fs=fieldnames(b); for k=1:numel(fs), f=fs{k}; must(isfield(a,f),[p '.' f],'missing field'); if isstruct(b.(f)), checkFields(a.(f),b.(f),[p '.' f]); end, end
end
function finite(x,p), must(isnumeric(x)&&isreal(x)&&isscalar(x)&&isfinite(x),p,'finite real scalar required'); end
function integer(x,a,b,p), finite(x,p); must(x==fix(x)&&x>=a&&x<=b,p,sprintf('integer in [%g,%g] required',a,b)); end
function positive(x,p), finite(x,p); must(x>0,p,'must be positive'); end
function nonnegative(x,p), finite(x,p); must(x>=0,p,'must be nonnegative'); end
function unit(x,p), finite(x,p); must(x>=0&&x<=1,p,'must lie in [0,1]'); end
function must(ok,p,why), if ~ok, error('nbiot:config:InvalidValue','%s: %s',p,why); end, end
function unsupported(ok,p,why), if ~ok, error('nbiot:config:UnsupportedProfile','%s: %s',p,why); end, end
