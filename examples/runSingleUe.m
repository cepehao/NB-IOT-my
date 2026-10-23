function result=runSingleUe(calibrationFile)
%RUNSINGLEUE Small, strong-link integration experiment before 1000 UE.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
cfg.cell.radiusM=20; cfg.cell.indoorFraction=0;
cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0;
cfg.channel.cfoSigmaHz=0; cfg.channel.syncLimitSeconds=0;
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
cfg.logging.outputFolder=fullfile(root,'results','single-ue');
if nargin<1, calibrationFile=fullfile(root,'results','nprach-calibration.mat'); end
checkEnvironment(false); cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
result=nbiot.runExperiment(cfg); nbiot.results.saveResult(result,cfg.logging.outputFolder);
disp(result.kpiSummary);
if strcmp(result.status,'failed'), error('nbiot:experiment:Failed','%s',result.error.message); end
end
