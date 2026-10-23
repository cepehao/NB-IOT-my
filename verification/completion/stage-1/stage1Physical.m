evidenceFolder=fileparts(mfilename('fullpath'));
sourceRoot=getenv('STAGE1_SOURCE_ROOT'); label=getenv('STAGE1_LABEL');
if isempty(sourceRoot), sourceRoot=fileparts(fileparts(fileparts(evidenceFolder))); end
if isempty(label), label='candidate'; end
cd(sourceRoot); addpath(sourceRoot); setupProject();
fprintf('MATLAB_VERSION=%s RELEASE=%s SOURCE_ROOT=%s LABEL=%s\n',version,version('-release'),sourceRoot,label);
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.simulation.durationTicks=1200;
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1; cfg.cell.indoorFraction=0;
cfg.phy.nprachThreshold=.005; cfg.logging.outputFolder='stage-1-diagnostic';
sources=nbiot.randomness.RandomSources(42,0); scenario=nbiot.scenario.buildScenario(cfg,sources);
u=scenario.ue(1); radius=50; distance=hypot(radius,cfg.cell.bsHeightM-cfg.cell.ueHeightM);
u.xM=radius; u.yM=0; u.horizontalDistanceM=radius; u.distanceM=distance;
u.pathLossDb=20*log10(4*pi*cfg.channel.carrierHz*10/299792458)+10*cfg.channel.pathLossExponent*log10(distance/10);
u.medianPathLossDb=u.pathLossDb; u.shadowingDb=0; u.penetrationDb=0;
u.cfoHz=0; u.syncOffsetSeconds=0; u.tapsUl=[1;0;0]; u.tapsDl=[1;0;0]; scenario.ue(1)=u;
rngBefore=rng; result=nbiot.runExperiment(cfg,scenario); rngAfter=rng;
assert(strcmp(result.status,'completed')); assert(result.kpiSummary.delivered==1);
save(fullfile(evidenceFolder,[label '-physical.mat']),'result','rngBefore','rngAfter','-v7.3');
nbiot.results.saveResult(result,fullfile(evidenceFolder,[label '-exports']));
fprintf('PHYSICAL_SINGLE_UE created=%d delivered=%d bits=%d dataDecoded=%d crcFailures=%d\n', ...
    result.kpiSummary.created,result.kpiSummary.delivered,result.kpiSummary.deliveredPayloadBits, ...
    result.kpiSummary.dataDecoded,result.kpiSummary.dataCrcFailures);
if isfield(result.kpiSummary,'harq')
    h=result.kpiSummary.harq;
    assert(h.blocksStarted==8 && h.blocksAccepted==8 && h.firstDecoded==8 && h.firstTransmissionBler==0);
    fprintf('PHYSICAL_HARQ blocks=%d accepted=%d firstDecoded=%d firstBler=%g retries=%d censored=%d\n', ...
        h.blocksStarted,h.blocksAccepted,h.firstDecoded,h.firstTransmissionBler,h.retryAttempts,h.blocksCensored);
end
