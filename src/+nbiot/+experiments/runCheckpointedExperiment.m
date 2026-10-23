function [result,info]=runCheckpointedExperiment(cfg,scenario,execution,controllerOptions,checkpointOptions)
%RUNCHECKPOINTEDEXPERIMENT Run in step-sized portions and save recoverable state.
%   Прогон частями с сохранением чекпоинтов (возобновление после прерывания).
if nargin<2, scenario=[]; end
if nargin<3||isempty(execution), execution=struct(); end
if nargin<4||isempty(controllerOptions), controllerOptions=struct(); end
if nargin<5||isempty(checkpointOptions), checkpointOptions=struct(); end
if ~isstruct(checkpointOptions)||~isscalar(checkpointOptions)
    error('nbiot:experiments:CheckpointOptions','Checkpoint options must be a scalar structure.');
end
defaults=struct('folder','','identity',[],'intervalSeconds',600,'resume',false, ...
    'pauseRequestFile','','progressFile','','budgetLedgerFile','', ...
    'progressPhase','');
names=fieldnames(checkpointOptions);
if ~all(ismember(names,fieldnames(defaults)))
    error('nbiot:experiments:CheckpointOptions','Checkpoint options contain unsupported fields.');
end
for k=1:numel(names), defaults.(names{k})=checkpointOptions.(names{k}); end
checkpointOptions=defaults;
if ~(ischar(checkpointOptions.folder)||(isstring(checkpointOptions.folder)&&isscalar(checkpointOptions.folder)))|| ...
        isempty(char(checkpointOptions.folder))|| ...
        ~(ischar(checkpointOptions.pauseRequestFile)|| ...
        (isstring(checkpointOptions.pauseRequestFile)&&isscalar(checkpointOptions.pauseRequestFile)))|| ...
        ~(ischar(checkpointOptions.progressFile)|| ...
        (isstring(checkpointOptions.progressFile)&&isscalar(checkpointOptions.progressFile)))|| ...
        ~(ischar(checkpointOptions.budgetLedgerFile)|| ...
        (isstring(checkpointOptions.budgetLedgerFile)&&isscalar(checkpointOptions.budgetLedgerFile)))|| ...
        ~(ischar(checkpointOptions.progressPhase)|| ...
        (isstring(checkpointOptions.progressPhase)&&isscalar(checkpointOptions.progressPhase)))|| ...
        ~isnumeric(checkpointOptions.intervalSeconds)|| ...
        ~isscalar(checkpointOptions.intervalSeconds)|| ...
        ~isfinite(checkpointOptions.intervalSeconds)||checkpointOptions.intervalSeconds<=0|| ...
        ~(islogical(checkpointOptions.resume)&&isscalar(checkpointOptions.resume))
    error('nbiot:experiments:CheckpointOptions', ...
        'A checkpoint folder, positive interval and scalar logical resume flag are required.');
end
if isempty(scenario)
    sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
    scenario=nbiot.scenario.buildScenario(cfg,sources);
end
identity=checkpointOptions.identity;
if isempty(identity)
    if ~strcmp(char(string(cfg.policy.name)),'Static')||~isempty(fieldnames(controllerOptions))
        error('nbiot:experiments:CheckpointIdentity', ...
            'Adaptive or model-backed checkpoints require an explicit runtime identity.');
    end
    identity=nbiot.experiments.runtimeManifest(cfg,struct('scenario',scenario));
end
runClock=tic;
progressPhase=char(string(checkpointOptions.progressPhase));
sim=[]; progressTick=0; lastCheckpointPath=''; activePhase='initializing';
checkpointPaths={}; checkpointOverheadSeconds=0;
checkpointTimings=struct('operation',{},'path',{},'timing',{});
pauseRequested=false;
try
    progress=publishPhase('initializing','running');
    if checkpointOptions.resume
        publishPhase('checkpoint-loading','running');
        checkpointClock=tic;
        [sim,resumeInfo]=nbiot.experiments.loadCheckpoint(checkpointOptions.folder,identity,execution);
        checkpointOverheadSeconds=checkpointOverheadSeconds+toc(checkpointClock);
        lastCheckpointPath=char(string(resumeInfo.checkpointPath));
        checkpointTimings(end+1)=struct('operation','load','path',lastCheckpointPath,'timing',resumeInfo.timing);
        progressTick=sim.currentTick;
    else
        sim=nbiot.NBIoTSimulator(cfg,scenario,execution,controllerOptions);
        resumeInfo=struct('fallbackUsed',false,'lostTicks',0,'checkpointTick',0,'graphLinksValidated',true);
        saveCurrentCheckpoint();
    end
    lastCheckpointElapsed=0; lastProgressElapsed=-Inf;
    budgetLedgerPath=char(string(checkpointOptions.budgetLedgerFile));
    budgetBaseElapsed=0; budgetSeconds=Inf; budgetWarningWritten=false;
    if ~isempty(budgetLedgerPath)
        budgetLedger=nbiot.experiments.loadVariant2BudgetLedger(budgetLedgerPath,false);
        budgetBaseElapsed=double(budgetLedger.elapsedSeconds);
        budgetSeconds=double(budgetLedger.budgetSeconds);
    end
    publishPhase('simulating','running');
    while ~any(strcmp(sim.status,{'completed','stopped','failed'}))
        % Keep the established nextTick stepping protocol, without exporting
        % an additional whole state merely to report the public currentTick.
        state=sim.exportCheckpointState();
        sim.run(state.nextTick);
        progressTick=sim.currentTick;
        elapsed=toc(runClock);
        if ~budgetWarningWritten&&budgetBaseElapsed+elapsed>=budgetSeconds&&~isempty(budgetLedgerPath)
            budgetLedger=nbiot.experiments.loadVariant2BudgetLedger(budgetLedgerPath,false);
            message=sprintf(['Shared 57600-second budget threshold crossed during active case %s; ' ...
                'the current case continues and no later case will be admitted.'],identity.caseKey);
            exists=~isempty(budgetLedger.warnings)&&any(contains(string({budgetLedger.warnings.message}),identity.caseKey));
            if ~exists
                budgetLedger.warnings(end+1)=struct( ...
                    'timestampUtc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS')), ...
                    'phase','stage-3-load-probe','elapsedSeconds',budgetBaseElapsed+elapsed,'message',message);
                nbiot.experiments.saveVariant2BudgetLedger(budgetLedgerPath,budgetLedger);
            end
            budgetWarningWritten=true;
        end
        terminal=any(strcmp(sim.status,{'completed','stopped','failed'}));
        pausePath=char(checkpointOptions.pauseRequestFile);
        if ~terminal&&~isempty(pausePath)&&isfile(pausePath)
            saveCurrentCheckpoint();
            lastCheckpointElapsed=elapsed;
            pauseRequested=true;
            break
        end
        if ~terminal&&elapsed-lastCheckpointElapsed>=checkpointOptions.intervalSeconds
            saveCurrentCheckpoint();
            lastCheckpointElapsed=elapsed;
            publishPhase('simulating','running');
        elseif ~terminal&&elapsed-lastProgressElapsed>=10
            publishPhase('simulating','running');
            lastProgressElapsed=elapsed;
        end
    end
    activePhase='result-finalizing';
    update=progressUpdate();
    result=nbiot.experiments.finalizeCheckpointResult(@()sim.result(),checkpointOptions.progressFile,update);
    status=result.status;
    if pauseRequested
        status='paused';
        progress=publishPhase('paused','paused');
    elseif strcmp(status,'completed')
        % The scientific simulator is done; the outer case still must export,
        % verify and commit before progress may announce completed.
        progress=publishPhase('exporting','running');
    else
        activePhase='simulating';
        update=progressUpdate(); update.phase='failed'; update.status='failed';
        update.failedPhase='simulating'; update.errorIdentifier='';
        if isfield(result,'errorInfo')&&isfield(result.errorInfo,'identifier')
            update.errorIdentifier=result.errorInfo.identifier;
        end
        progress=nbiot.experiments.writeRuntimeProgress(checkpointOptions.progressFile,update);
    end
    checkpointFiles=dir(fullfile(char(checkpointOptions.folder),'checkpoint-tick-*.mat'));
    info=struct('status',status,'pauseRequested',pauseRequested, ...
        'checkpointFolder',char(checkpointOptions.folder),'checkpointPaths',{checkpointPaths}, ...
        'checkpointCount',numel(checkpointFiles),'checkpointBytes',sum([checkpointFiles.bytes]), ...
        'checkpointOverheadSeconds',checkpointOverheadSeconds,'elapsedSeconds',toc(runClock),'resumeInfo',resumeInfo);
    info.phaseElapsedSeconds=progress.phaseElapsedSeconds;
    info.checkpointTimings=checkpointTimings;
catch exception
    update=progressUpdate(); update.phase='failed'; update.status='failed';
    update.failedPhase=activePhase; update.errorIdentifier=exception.identifier;
    nbiot.experiments.writeRuntimeProgress(checkpointOptions.progressFile,update);
    rethrow(exception);
end

    function update=progressUpdate()
        update=struct('caseKey',char(string(identity.caseKey)),'currentTick',double(progressTick), ...
            'phaseContext',progressPhase,'workUnitsDone',0,'workUnitsTotal',[]);
        if ~isempty(lastCheckpointPath), update.lastCheckpoint=lastCheckpointPath; end
    end

    function value=publishPhase(phase,status)
        activePhase=phase;
        update=progressUpdate(); update.phase=phase; update.status=status;
        update.errorIdentifier=''; update.failedPhase='';
        value=nbiot.experiments.writeRuntimeProgress(checkpointOptions.progressFile,update);
    end

    function saveCurrentCheckpoint()
        publishPhase('checkpointing','running');
        checkpointClock=tic;
        [savedPath,timing]=nbiot.experiments.saveCheckpoint(sim,checkpointOptions.folder,identity);
        checkpointOverheadSeconds=checkpointOverheadSeconds+toc(checkpointClock);
        % A failed save must not replace the last successfully published path.
        lastCheckpointPath=savedPath;
        checkpointPaths{end+1}=savedPath;
        checkpointTimings(end+1)=struct('operation','save','path',savedPath,'timing',timing);
    end
end
