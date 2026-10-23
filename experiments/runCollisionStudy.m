function rows=runCollisionStudy(calibrationFile)
%RUNCOLLISIONSTUDY Equal/different indices and near-far, always real waveforms.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
if nargin<1, calibrationFile=fullfile(root,'results','nprach-calibration.mat'); end
rows={};
for same=[false true]
    for deltaDb=[0 6 12 20 30 40]
        cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=2; cfg.cell.indoorFraction=0;
        cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0; cfg.channel.cfoSigmaHz=0;
        cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
        cfg.simulation.realizationId=matchingRealization(cfg,same);
        cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
        sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
        scenario=nbiot.scenario.buildScenario(cfg,sources);
        firstDistance=sqrt(50^2+(cfg.cell.bsHeightM-cfg.cell.ueHeightM)^2);
        for u=1:2
            distance=firstDistance*10^((u-1)*deltaDb/(10*cfg.channel.pathLossExponent));
            radius=sqrt(distance^2-(cfg.cell.bsHeightM-cfg.cell.ueHeightM)^2);
            scenario.ue(u).xM=radius; scenario.ue(u).yM=0; scenario.ue(u).distanceM=distance;
            scenario.ue(u).horizontalDistanceM=radius;
            scenario.ue(u).pathLossDb=20*log10(4*pi*cfg.channel.carrierHz*10/299792458)+ ...
                10*cfg.channel.pathLossExponent*log10(distance/10);
            scenario.ue(u).medianPathLossDb=scenario.ue(u).pathLossDb;
            scenario.ue(u).shadowingDb=0; scenario.ue(u).penetrationDb=0;
            scenario.ue(u).tapsUl=[1;0;0]; scenario.ue(u).tapsDl=[1;0;0];
        end
        cfg.logging.outputFolder=fullfile(root,'results','collision',sprintf('same%d_delta%02d',same,deltaDb));
        result=nbiot.runExperiment(cfg,scenario); nbiot.results.saveResult(result,cfg.logging.outputFolder);
        rows(end+1,:)={same,deltaDb,result.status,result.kpiSummary.raSuccess,result.kpiSummary.delivered}; %#ok<AGROW>
        if strcmp(result.status,'failed'), error('nbiot:experiment:Failed','%s',result.error.message); end
    end
end
rows=cell2table(rows,'VariableNames',{'samePreamble','pathLossDifferenceDb','status','raSuccess','delivered'});
end
function id=matchingRealization(cfg,same)
for id=0:3999
    sources=nbiot.randomness.RandomSources(cfg.simulation.seed,id); indices=zeros(1,2);
    for u=1:2
        s=sources.stream('access',0,u,1); rand(s); indices(u)=floor(rand(s)*12);
    end
    if (indices(1)==indices(2))==same, return; end
end
error('nbiot:experiments:Scenario','No matching access realization found.');
end
