function result=runBaseline(calibrationFile)
%RUNBASELINE Baseline source; first execution requires a calibrated detector.
%   Базовый прогон по defaultConfig (1000 UE, массовый доступ) с калибровкой NPRACH.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
cfg=nbiot.config.defaultConfig(); cfg.logging.outputFolder=fullfile(root,'results');
if nargin<1, calibrationFile=fullfile(cfg.logging.outputFolder,'nprach-calibration.mat'); end
checkEnvironment(false); cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
result=nbiot.runExperiment(cfg); path=nbiot.results.saveResult(result,cfg.logging.outputFolder);
fprintf('Run status: %s; saved: %s\n',result.status,path);
if strcmp(result.status,'failed')
    error('nbiot:experiment:Failed','%s: %s',result.error.identifier,result.error.message);
end
disp(result.kpiSummary); nbiot.results.plotSummary(result);
end
