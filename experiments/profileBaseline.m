function measurement=profileBaseline(numUE,calibrationFile)
%PROFILEBASELINE Measure on actual target hardware; no precomputed estimates.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
if nargin<1, numUE=100; end
if nargin<2, calibrationFile=fullfile(root,'results','nprach-calibration.mat'); end
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=numUE;
cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile); cfg.logging.outputFolder=fullfile(root,'results','profiling');
profile on; cleanup=onCleanup(@() profile('off')); %#ok<NASGU>
clockStart=tic; result=nbiot.runExperiment(cfg); elapsed=toc(clockStart); info=profile('info');
measurement=struct('numUE',numUE,'status',result.status,'elapsedSeconds',elapsed,'computer',computer,'profile',info);
if ispc, [user,system]=memory; measurement.memory=struct('user',user,'system',system); end
if ~isfolder(cfg.logging.outputFolder), mkdir(cfg.logging.outputFolder); end
% Keep the same measured run for resource, packet and payload verification.
save(fullfile(cfg.logging.outputFolder,sprintf('profile_n%d.mat',numUE)),'measurement','result','-v7.3');
end
