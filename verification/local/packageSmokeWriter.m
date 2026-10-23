projectRoot=fileparts(fileparts(fileparts(mfilename('fullpath'))));
projectRoot=char(java.io.File(projectRoot).getCanonicalPath());
packageRoot=fullfile(projectRoot,'verification','external','variant2-local-snapshot-20261014','project');
smokeRoot=fullfile(projectRoot,'verification','local','package-smoke-variant2-20261014');
assert(isfolder(packageRoot),'nbiot:task6:Smoke','Packaged project folder is missing.');
if ~isfolder(smokeRoot), mkdir(smokeRoot); end
cd(packageRoot); addpath(packageRoot); setupProject();
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=1500; cfg.simulation.realizationId=0;
cfg.traffic.kind='burst'; cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=100;
cfg.policy.name='Static';
calibrationFile=fullfile(packageRoot,'results','nprach-calibration.mat');
cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
scenario=nbiot.scenario.buildScenario(cfg);
caseFolder=fullfile(smokeRoot,'case');
pauseFile=fullfile(smokeRoot,'pause.request');
progressFile=fullfile(smokeRoot,'worker-progress.json');
runtimeOptions=struct('projectRoot',packageRoot,'calibrationFile',calibrationFile, ...
    'scenario',scenario,'execution',localDevelopment(), ...
    'checkpoint',struct('intervalSeconds',600,'pauseRequestFile',pauseFile, ...
    'progressFile',progressFile,'budgetLedgerFile','','progressPhase','package-smoke'));
metadata=nbiot.experiments.runtimeManifest(cfg,runtimeOptions);
fid=fopen(pauseFile,'w'); assert(fid>=0,'nbiot:task6:Smoke','Cannot create pause request.'); fclose(fid);
meta=nbiot.experiments.runStaticCase(cfg,caseFolder,metadata,[],runtimeOptions);
assert(strcmp(meta.status,'paused'),'nbiot:task6:Smoke', ...
    'Packaged run did not pause at its first checkpoint boundary.');
checkpointFolder=meta.checkpointFolder;
manifestPath=fullfile(checkpointFolder,'checkpoint-manifest.json');
assert(isfile(manifestPath),'nbiot:task6:Smoke','Checkpoint manifest was not written.');
progress=jsondecode(fileread(progressFile));
assert(~isempty(progress.lastCheckpoint)&&isfile(progress.lastCheckpoint), ...
    'nbiot:task6:Smoke','Worker progress did not identify the saved checkpoint.');
writerProcessId=feature('getpid');
inputPath=fullfile(smokeRoot,'resume-input.mat');
save(inputPath,'cfg','scenario','metadata','runtimeOptions','caseFolder', ...
    'checkpointFolder','pauseFile','progressFile','writerProcessId','-v7.3');
fprintf('PACKAGE_SMOKE_PAUSED caseKey=%s tick=%d checkpoint=%s bytes=%d\n', ...
    metadata.caseKey,progress.currentTick,progress.lastCheckpoint, ...
    sum([dir(fullfile(checkpointFolder,'checkpoint-tick-*.mat')).bytes]));
