function meta=runStaticCase(cfg,caseFolder,provenance,runner,runtimeOptions)
%RUNSTATICCASE Execute and commit one independent case in its own folder.
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(root); addpath(fullfile(root,'src')); addpath(fullfile(root,'experiments')); setupProject();
if nargin<4, runner=[]; end
if nargin<5, runtimeOptions=struct(); end
if ~isfield(runtimeOptions,'execution'), runtimeOptions.execution=struct(); end
checkpointMode=isfield(runtimeOptions,'checkpoint')&&~isempty(runtimeOptions.checkpoint);
if checkpointMode
    checkpointOptions=checkpointSettings(runtimeOptions.checkpoint);
    if ~isempty(runner)
        error('nbiot:experiments:CheckpointRunner', ...
            'Checkpointed cases require the registered nbiot.runExperiment runner.');
    end
end
nbiot.experiments.validateExecutionBudget(cfg,runtimeOptions.execution);
runtimeOptions.projectRoot=root; runtimeOptions.runner=runner;
if nargin<3 || isempty(provenance)
    provenance=nbiot.experiments.runtimeManifest(cfg,runtimeOptions);
elseif isfield(provenance,'runtimeVersion')
    current=nbiot.experiments.runtimeManifest(cfg,runtimeOptions);
    names=fieldnames(current);
    for k=1:numel(names)
        if ~isfield(provenance,names{k}) || ~isequaln(provenance.(names{k}),current.(names{k}))
            error('nbiot:experiments:RuntimeIdentity','Supplied runtime identity differs in %s.',names{k});
        end
    end
end
cfg.logging.outputFolder=caseFolder;
if ~isfolder(caseFolder), mkdir(caseFolder); end
runtimePhase='initializing'; progressTick=0; lastCheckpoint='';
runnerOwnsFailure=false; progress=struct();
try
if checkpointMode
    publishPhase('verifying','running');
    [meta,alreadyComplete]=existingCheckpointResult(caseFolder,provenance);
    if alreadyComplete
        progressTick=cfg.simulation.durationTicks;
        publishPhase('completed','completed');
        return
    end
    publishPhase('initializing','running');
    [id,staging,checkpointFolder,resume]=checkpointAttempt(caseFolder);
    attempt=fullfile(caseFolder,['run-' id]);
    checkpointOptions=struct('folder',checkpointFolder,'identity',provenance, ...
        'intervalSeconds',checkpointOptions.intervalSeconds,'resume',resume, ...
        'pauseRequestFile',checkpointOptions.pauseRequestFile, ...
        'progressFile',checkpointOptions.progressFile, ...
        'budgetLedgerFile',checkpointOptions.budgetLedgerFile, ...
        'progressPhase',checkpointOptions.progressPhase);
    scenario=[];
    if isfield(runtimeOptions,'scenario'), scenario=runtimeOptions.scenario; end
    controllerOptions=struct();
    if isfield(runtimeOptions,'controllerOptions')
        controllerOptions=runtimeOptions.controllerOptions;
    end
    runnerOwnsFailure=true;
    [result,checkpointInfo]=nbiot.experiments.runCheckpointedExperiment( ...
        cfg,scenario,runtimeOptions.execution,controllerOptions,checkpointOptions);
    runnerOwnsFailure=false;
    progressTick=result.actualTick;
    if ~isempty(checkpointInfo.checkpointPaths)
        lastCheckpoint=checkpointInfo.checkpointPaths{end};
    elseif isfield(checkpointInfo.resumeInfo,'checkpointPath')
        lastCheckpoint=checkpointInfo.resumeInfo.checkpointPath;
    end
    if strcmp(checkpointInfo.status,'paused')
        meta=struct('caseKey',char(string(provenance.caseKey)), ...
            'status','paused','attemptId',id,'caseFolder',caseFolder, ...
            'stagingFolder',staging,'checkpointFolder',checkpointFolder, ...
            'checkpoint',checkpointInfo);
        return
    end
    if ~strcmp(result.status,'completed')
        runtimePhase='simulating';
        error('nbiot:experiments:CheckpointIncomplete', ...
            'Checkpointed case ended with status %s; its checkpoint and staging ID were preserved.', ...
            result.status);
    end
else
    id=char(java.util.UUID.randomUUID());
    staging=fullfile(caseFolder,['.staging-' id]);
    attempt=fullfile(caseFolder,['run-' id]);
    if isfolder(staging) || isfolder(attempt)
        error('nbiot:experiments:AttemptCollision','Generated case attempt already exists.');
    end
    [ok,message]=mkdir(staging);
    if ~ok, error('nbiot:experiments:Stage','Cannot create case staging directory: %s',message); end
    if isempty(runner)
        scenario=[];
        if isfield(runtimeOptions,'scenario'), scenario=runtimeOptions.scenario; end
        controllerOptions=struct();
        if isfield(runtimeOptions,'controllerOptions')
            controllerOptions=runtimeOptions.controllerOptions;
        end
        result=nbiot.runExperiment(cfg,scenario,runtimeOptions.execution,controllerOptions);
    else
        result=runner(cfg);
    end
end
publishPhase('exporting','running');
nbiot.results.saveResult(result,staging,provenance);
publishPhase('verifying','running');
if checkpointMode
    report=nbiot.results.verifyCase(staging,provenance);
    if ~report.passed
        error('nbiot:experiments:CheckpointCompletedCase', ...
            'Staged completion marker failed verification: %s',strjoin(report.errors,'; '));
    end
end
[ok,message]=movefile(staging,attempt);
if ~ok, error('nbiot:experiments:Commit','Cannot commit case folder: %s',message); end
marker=jsondecode(fileread(fullfile(attempt,'case-complete.json')));
meta=caseMeta(caseFolder,attempt,marker);
publishPhase('completed','completed');
if checkpointMode
    checkpointInfo.phaseElapsedSeconds=progress.phaseElapsedSeconds;
    meta.checkpoint=checkpointInfo;
end
catch exception
    if checkpointMode&&~runnerOwnsFailure
        update=struct('phase','failed','status','failed','caseKey',char(string(provenance.caseKey)), ...
            'currentTick',double(progressTick),'failedPhase',runtimePhase, ...
            'errorIdentifier',exception.identifier,'phaseContext',checkpointOptions.progressPhase);
        if ~isempty(lastCheckpoint), update.lastCheckpoint=lastCheckpoint; end
        nbiot.experiments.writeRuntimeProgress(checkpointOptions.progressFile,update);
    end
    rethrow(exception);
end

    function publishPhase(phase,status)
        if ~checkpointMode, return; end
        runtimePhase=phase;
        update=struct('phase',phase,'status',status,'caseKey',char(string(provenance.caseKey)), ...
            'currentTick',double(progressTick),'phaseContext',checkpointOptions.progressPhase, ...
            'errorIdentifier','','failedPhase','');
        if ~isempty(lastCheckpoint), update.lastCheckpoint=lastCheckpoint; end
        progress=nbiot.experiments.writeRuntimeProgress(checkpointOptions.progressFile,update);
    end
end

function settings=checkpointSettings(value)
if ~isstruct(value)||~isscalar(value)
    error('nbiot:experiments:CheckpointOptions', ...
        'runtimeOptions.checkpoint must be a scalar structure.');
end
defaults=struct('intervalSeconds',600,'pauseRequestFile','','progressFile','', ...
    'budgetLedgerFile','','progressPhase','');
names=fieldnames(value);
if ~all(ismember(names,fieldnames(defaults)))
    error('nbiot:experiments:CheckpointOptions', ...
        'runtimeOptions.checkpoint contains unsupported fields.');
end
for k=1:numel(names), defaults.(names{k})=value.(names{k}); end
if ~isnumeric(defaults.intervalSeconds)||~isscalar(defaults.intervalSeconds)|| ...
        ~isfinite(defaults.intervalSeconds)||defaults.intervalSeconds<=0
    error('nbiot:experiments:CheckpointOptions', ...
        'Checkpoint intervalSeconds must be a positive finite scalar.');
end
if ~(ischar(defaults.pauseRequestFile)|| ...
        (isstring(defaults.pauseRequestFile)&&isscalar(defaults.pauseRequestFile)))
    error('nbiot:experiments:CheckpointOptions', ...
        'Checkpoint pauseRequestFile must be a character vector or scalar string.');
end
if ~(ischar(defaults.progressFile)|| ...
        (isstring(defaults.progressFile)&&isscalar(defaults.progressFile)))
    error('nbiot:experiments:CheckpointOptions', ...
        'Checkpoint progressFile must be a character vector or scalar string.');
end
if ~(ischar(defaults.budgetLedgerFile)|| ...
        (isstring(defaults.budgetLedgerFile)&&isscalar(defaults.budgetLedgerFile)))
    error('nbiot:experiments:CheckpointOptions', ...
        'Checkpoint budgetLedgerFile must be a character vector or scalar string.');
end
if ~(ischar(defaults.progressPhase)|| ...
        (isstring(defaults.progressPhase)&&isscalar(defaults.progressPhase)))
    error('nbiot:experiments:CheckpointOptions', ...
        'Checkpoint progressPhase must be a character vector or scalar string.');
end
settings=defaults;
end

function [meta,found]=existingCheckpointResult(caseFolder,identity)
meta=struct(); found=false;
attempts=dir(fullfile(caseFolder,'run-*'));
for k=1:numel(attempts)
    if ~attempts(k).isdir, continue; end
    attempt=fullfile(attempts(k).folder,attempts(k).name);
    markerPath=fullfile(attempt,'case-complete.json');
    if ~isfile(markerPath)
        error('nbiot:experiments:CheckpointAttempt', ...
            'An unfinished committed attempt exists at %s; refusing to allocate a new ID.',attempt);
    end
    marker=jsondecode(fileread(markerPath));
    if ~isfield(marker,'caseKey')||~strcmp(char(string(marker.caseKey)),char(string(identity.caseKey)))
        continue
    end
    report=nbiot.results.verifyCase(attempt,identity);
    if ~report.passed
        error('nbiot:experiments:CheckpointCompletedCase', ...
            'Existing completion marker failed verification: %s',strjoin(report.errors,'; '));
    end
    meta=caseMeta(caseFolder,attempt,marker); found=true; return
end
end

function [id,staging,checkpointFolder,resume]=checkpointAttempt(caseFolder)
stages=dir(fullfile(caseFolder,'.staging-*'));
checkpoints=dir(fullfile(caseFolder,'.checkpoint-*'));
ids={};
for k=1:numel(stages)
    if stages(k).isdir
        ids{end+1}=stages(k).name(numel('.staging-')+1:end); %#ok<AGROW>
    end
end
for k=1:numel(checkpoints)
    if checkpoints(k).isdir
        ids{end+1}=checkpoints(k).name(numel('.checkpoint-')+1:end); %#ok<AGROW>
    end
end
ids=unique(ids);
if numel(ids)>1
    error('nbiot:experiments:CheckpointAttempt', ...
        'Multiple unfinished checkpoint attempts exist; refusing to choose or replace one.');
elseif isempty(ids)
    id=char(java.util.UUID.randomUUID());
else
    id=ids{1};
end
staging=fullfile(caseFolder,['.staging-' id]);
checkpointFolder=fullfile(caseFolder,['.checkpoint-' id]);
attempt=fullfile(caseFolder,['run-' id]);
if isfolder(attempt)
    error('nbiot:experiments:CheckpointAttempt', ...
        'Attempt ID %s already has a committed folder without a reusable completion marker.',id);
end
if ~isfolder(staging)
    [ok,message]=mkdir(staging);
    if ~ok, error('nbiot:experiments:Stage','Cannot create case staging directory: %s',message); end
else
    contents=dir(staging); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents)
        error('nbiot:experiments:CheckpointAttempt', ...
            'Unrecognized files exist in unfinished staging folder %s.',staging);
    end
end
resume=isfile(fullfile(checkpointFolder,'checkpoint-manifest.json'));
end

function meta=caseMeta(caseFolder,attempt,marker)
meta=struct('caseKey',char(string(marker.caseKey)), ...
    'status',char(string(marker.status)),'elapsedSeconds',double(marker.elapsedSeconds), ...
    'caseFolder',caseFolder,'attemptFolder',attempt, ...
    'resultFile',fullfile(attempt,char(string(marker.resultFile))), ...
    'configSha256',char(string(marker.configSha256)), ...
    'sourceSha256',char(string(marker.sourceSha256)), ...
    'calibrationSha256',char(string(marker.calibrationSha256)), ...
    'environment',marker.environment,'files',marker.files);
if isfield(marker,'runtimeVersion')
    names={'runtimeVersion','resultSchemaVersion','canonicalConfigSha256', ...
        'modelSha256','policySha256','inputSha256','runnerSha256'};
    for k=1:numel(names), meta.(names{k})=marker.(names{k}); end
end
end
