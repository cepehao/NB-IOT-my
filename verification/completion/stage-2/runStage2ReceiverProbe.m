%RUNSTAGE2RECEIVERPROBE Validate the revised receiver before the full paired rerun.
projectRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(projectRoot); setupProject();
addpath(fullfile(projectRoot,'experiments'));
addpath(fullfile(projectRoot,'verification','completion','stage-2'));
stageFolder=fullfile(projectRoot,'verification','completion','stage-2');
stamp=char(datetime('now','TimeZone','UTC','Format','yyyyMMdd-HHmmss-SSS'));
outputFolder=fullfile(stageFolder,['receiver-probe-' stamp]);
registryPath=fullfile(projectRoot,'experiments','realizationRegistry.json');
options=struct('repeats',1,'conditionIds',7,'durationTicks',1500,...
    'outputFolder',outputFolder,'runReceiverChecks',true,...
    'runInterferenceReplay',false,'registryFile',registryPath,...
    'manageRegistry',true,'calibrationFile',fullfile(projectRoot,'results',...
    'nprach-calibration.mat'));
report=validateCollisionCapture(options);
passed=true; failure='';
try
    nbiot.experiments.validateStage2ReceiverChecks(report.receiverChecks);
catch exception
    passed=false; failure=exception.message;
end
report.receiverProbe=struct('passed',passed,'failure',failure,...
    'purpose','development preflight; excluded from Stage 2 acceptance receiver IDs');
save(fullfile(outputFolder,'report.mat'),'report','-v7');
fprintf('STAGE2_RECEIVER_PROBE passed=%d trialIds=%s receiverIds=%s output=%s\n',...
    passed,mat2str(report.trials.realizationId),...
    mat2str(sort(unique(double(report.receiverChecks.id(:).')))),outputFolder);
if ~passed
    error('nbiot:stage2:ReceiverProbe','Receiver preflight failed: %s.',failure);
end
