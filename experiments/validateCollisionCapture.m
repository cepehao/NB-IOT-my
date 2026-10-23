function report=validateCollisionCapture(options)
%VALIDATECOLLISIONCAPTURE Small independent physical diagnostics, not acceptance statistics.
% DesignOnly lists the fixed diagnostic grid without running MATLAB PHY.
% Normal runs use the unchanged simulator/receivers and accepted calibration.
% Analyzer truth maps decoded tokens to UE only after reception; it never
% determines a decode or feeds the production receiver/controller.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
addpath(fullfile(root,'verification','completion','stage-2'));
if nargin<1, options=struct(); end
defaults=struct('designOnly',false,'repeats',10,'conditionIds',1:15,...
    'outputFolder',fullfile(root,'verification','completion','stage-2','physical'),...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'),...
    'durationTicks',1500,'realizationSeed',42,...
    'runReceiverChecks',true,'runInterferenceReplay',true,...
    'registryFile',fullfile(root,'experiments','realizationRegistry.json'),...
    'manageRegistry',true,'execution',struct(),'resume',false,'progressFile','',...
    'budgetLedgerFile','');
assert(isstruct(options)&&isscalar(options),'nbiot:collision:Options','Scalar options required.');
names=fieldnames(options);
assert(all(ismember(names,fieldnames(defaults))),'nbiot:collision:Options','Unknown option.');
for k=1:numel(names), defaults.(names{k})=options.(names{k}); end
options=defaults;
assert(isnumeric(options.realizationSeed)&&isreal(options.realizationSeed)&&...
    isscalar(options.realizationSeed)&&isfinite(options.realizationSeed)&&...
    options.realizationSeed==fix(options.realizationSeed)&&...
    options.realizationSeed>=0&&options.realizationSeed<=2^32-1,...
    'nbiot:collision:Seed','realizationSeed must be an integer from 0 through 2^32-1.');
options.realizationSeed=double(options.realizationSeed);
assert(isscalar(options.resume)&&(islogical(options.resume)||ismember(options.resume,[0 1])),...
    'nbiot:collision:Options','resume must be a scalar logical flag.');
options.resume=logical(options.resume);
assert(isscalar(options.repeats)&&isfinite(options.repeats)&&...
    options.repeats==fix(options.repeats)&&options.repeats>=1&&options.repeats<=10,...
    'nbiot:collision:Scope','Stage 2 permits only 1..10 independent IDs per condition.');
assert(isscalar(options.durationTicks)&&options.durationTicks==fix(options.durationTicks)&&...
    options.durationTicks>=1200&&options.durationTicks<=5000,...
    'nbiot:collision:Scope','Diagnostic horizon must be 1200..5000 ms.');
assert(isscalar(options.manageRegistry)&&(islogical(options.manageRegistry)||ismember(options.manageRegistry,[0 1])),...
    'nbiot:collision:Options','manageRegistry must be a scalar logical flag.');
options.manageRegistry=logical(options.manageRegistry);
conditions=conditionGrid(); ids=options.conditionIds;
assert(isnumeric(ids)&&isvector(ids)&&~isempty(ids)&&all(ismember(ids,[conditions.id]))&&...
    numel(unique(ids))==numel(ids),'nbiot:collision:Condition','Select unique existing condition IDs.');
conditions=conditions(ids);
report=struct('conditions',conditions,'options',options,...
    'successDefinition','Decoded RAR, accepted CRC/protocol Msg3, matching CRC/protocol Msg4',...
    'scope','10-ID diagnostics do not replace Stage 7 or 100-realization comparisons.', ...
    'status','design-only','pendingCases',{{}});
if options.designOnly, return; end
budgetCfg=nbiot.config.defaultConfig(); budgetCfg.simulation.numUE=max([conditions.numUE]);
numCases=options.repeats*numel(conditions)+8*options.repeats*logical(options.runReceiverChecks)+2*logical(options.runInterferenceReplay);
execution=nbiot.experiments.validateExecutionBudget(budgetCfg,options.execution,numCases);
options.execution=rmfield(execution,'numCases');
clockStart=tic;
report.status='running';
if options.resume
    assert(isfolder(options.outputFolder),'nbiot:collision:Output','Resume requires the original output folder.');
else
    assert(~isfolder(options.outputFolder),'nbiot:collision:Output','Use a fresh output folder.');
    mkdir(options.outputFolder);
end
if isempty(options.progressFile), options.progressFile=fullfile(options.outputFolder,'progress.json'); end
assert((ischar(options.progressFile)||(isstring(options.progressFile)&&isscalar(options.progressFile)))&&...
    ~isempty(char(options.progressFile)),'nbiot:collision:Progress','A progress file path is required.');
options.progressFile=char(options.progressFile);
report.options=options;
report.progressFile=options.progressFile;
report.budgetLedgerFile=options.budgetLedgerFile;
base=nbiot.experiments.loadCalibration(nbiot.config.defaultConfig(),options.calibrationFile);
base.simulation.seed=options.realizationSeed;
% The archived calibration and hash retain its full independent acceptance
% evidence. Repeating its fit-window arrays in every trial is unnecessary.
base=rmfield(base,'calibrationReport');
report.calibrationSha256=fileHash(options.calibrationFile);
report.threshold=base.phy.nprachThreshold; report.receiverRevision=nbiot.phy.nprach.receiverRevision();
report.sourceManifest=optimizationSourceManifest(root); report.matlabVersion=version;
report.matlabRelease=version('-release'); report.lteVersion=ver('lte');
report.artifactSourceHashes=stage2ArtifactHashes(root);
if options.resume
    savedProgress=stage2PhysicalProgress('read',options.progressFile);
    savedIdentity=savedProgress.identity;
    assert(isfield(savedIdentity,'collisionIdMatrix')&&isfield(savedIdentity,'receiverIds')&&...
        isequal(double(savedIdentity.conditionIds(:).'),double([conditions.id]))&&...
        double(savedIdentity.repeats)==options.repeats,'nbiot:stage2:ProgressIdentity',...
        'Saved Stage 2 matrix differs from requested conditions or repeats.');
    idMatrix=double(savedIdentity.collisionIdMatrix);
    receiverIds=double(savedIdentity.receiverIds(:).');
    assert(isequal(size(idMatrix),[numel(conditions) options.repeats]),...
        'nbiot:stage2:ProgressIdentity','Saved Stage 2 ID matrix has invalid dimensions.');
    idLists=arrayfun(@(k)idMatrix(k,:),1:size(idMatrix,1),'UniformOutput',false).';
else
    idLists=cell(numel(conditions),1);
    for ci=1:numel(conditions)
        condition=conditions(ci); idLists{ci}=matchingIds(base,condition,options.repeats,options.registryFile);
    end
    idMatrix=vertcat(idLists{:}); receiverIds=[];
    if options.runReceiverChecks
        receiverIds=nbiot.experiments.availableRealizationIds(options.registryFile,...
            'stage-2-receiver-diagnostics',1000:3999);
        receiverIds=setdiff(receiverIds,unique(idMatrix(:).'),'stable');
        if numel(receiverIds)<10
            error('nbiot:collision:IDs','Insufficient disjoint IDs for receiver diagnostics.');
        end
        receiverIds=receiverIds(1:10);
    end
end
collisionIds=unique(idMatrix(:).','stable');
identity=physicalIdentity(root,conditions,options,base,report,idMatrix,receiverIds,collisionIds);
caseSpecs=physicalCaseSpecs(conditions,idMatrix,options,receiverIds);
try
    if options.resume
        if ~isempty(options.budgetLedgerFile)
            settleInterruptedPhysicalBudget(options.budgetLedgerFile,savedProgress);
        end
        stage2PhysicalProgress('resume',options.progressFile,identity,caseSpecs);
        if options.manageRegistry
            verifyStage2Registry(options.registryFile,'stage-2-collision-diagnostics',collisionIds,...
                identity.assignmentSource,savedProgress.status);
            if ~isempty(receiverIds)
                verifyStage2Registry(options.registryFile,'stage-2-receiver-diagnostics',receiverIds,...
                    identity.assignmentSource,savedProgress.status);
            end
        end
    else
      if options.manageRegistry
        nbiot.experiments.registerRealizationUse(options.registryFile,'stage-2-collision-diagnostics',...
            collisionIds,identity.assignmentSource,'planned');
        if ~isempty(receiverIds)
            nbiot.experiments.registerRealizationUse(options.registryFile,'stage-2-receiver-diagnostics',...
                receiverIds,identity.assignmentSource,'planned');
        end
      end
      stage2PhysicalProgress('initialize',options.progressFile,identity,caseSpecs);
    end
rows=cell(0,21); summaries=cell(0,8); budgetPaused=false; pendingCases={};
for ci=1:numel(conditions)
    condition=conditions(ci);
    for trial=1:options.repeats
        realizationId=idLists{ci}(trial);
        caseKey=sprintf('collision-condition-%02d-repeat-%02d-id-%04d',condition.id,trial,realizationId);
        if progressCaseCompleted(options.progressFile,caseKey)
            payload=stage2PhysicalProgress('loadCase',options.progressFile,caseKey);
            rows(end+1,:)=payload.row; %#ok<AGROW>
            continue
        end
        if sharedBudgetExpired(options.budgetLedgerFile)
            budgetPaused=true;
            pendingCases=[pendingCases pendingCollisionCases( ...
                conditions,ci,trial,options.repeats)]; %#ok<AGROW>
            break
        end
        if suiteBudgetExpired(options.execution,clockStart)
            budgetPaused=true;
            pendingCases=[pendingCases pendingCollisionCases( ...
                conditions,ci,trial,options.repeats)]; %#ok<AGROW>
            break
        end
        stage2PhysicalProgress('start',options.progressFile,caseKey);
        budgetStart=beginPhysicalBudget(options.budgetLedgerFile,caseKey,condition.numUE,options.outputFolder);
        caseClock=tic;
        cfg=base; cfg.simulation.numUE=condition.numUE;
        cfg.simulation.realizationId=realizationId; cfg.simulation.durationTicks=options.durationTicks;
        cfg.cell.indoorFraction=0; cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0;
        cfg.channel.cfoSigmaHz=0; cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
        sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
        scenario=diagnosticScenario(cfg,sources,condition,false);
        [r,trace]=runObserved(cfg,scenario,false,options.execution);
        row=nbiot.experiments.analyzeCollisionTrial(condition,cfg,r,trace);
        rows(end+1,:)=row; %#ok<AGROW>
        % Retain scientific evidence; repetitive bs_queue snapshots add no decode evidence.
        r.observedLog=r.observedLog(~strcmp({r.observedLog.kind},'bs_queue'));
        evidence=struct('condition',condition,'cfg',cfg,'scenario',scenario,'result',r,'trace',trace);
        evidenceFile=physicalEvidenceFile(caseSpecs,caseKey);
        stage2PhysicalProgress('complete',options.progressFile,caseKey,struct('evidence',evidence,'row',{row}));
        finishPhysicalBudget(options.budgetLedgerFile,budgetStart,toc(caseClock),'completed');
        assert(isfile(fullfile(options.outputFolder,evidenceFile)),'nbiot:stage2:ProgressEvidence',...
            'Stage 2 collision evidence was not written.');
        fprintf('COLLISION condition=%02d repeat=%d/%d id=%d first=%d final=%d delivered=%d seconds=%.1f\n',...
            condition.id,trial,options.repeats,cfg.simulation.realizationId,row{8},row{9},row{10},toc(clockStart));
    end
    if budgetPaused, break; end
end
report.trials=cell2table(rows,'VariableNames',{'conditionId','group','realizationId','numUE',...
    'deltaDb','firstCandidates','logicalColliders','firstSuccess','raSuccess','delivered',...
    'firstStrongSuccess','firstWeakSuccess','firstAllSuccess','firstAnySuccess',...
    'firstMiss','firstFalseDetection','firstUnresolvedCollision','chainValidated','chainCount',...
    'dataCrcFailures','harqRetries'});
for ci=1:numel(conditions)
    tr=report.trials(report.trials.conditionId==conditions(ci).id,:);
    if isempty(tr), continue; end
    metrics={'firstStrongSuccess','firstWeakSuccess','firstAllSuccess','firstAnySuccess',...
        'firstMiss','firstFalseDetection','firstUnresolvedCollision'};
    if conditions(ci).deltaDb==0
        metrics=metrics(~ismember(metrics,{'firstStrongSuccess','firstWeakSuccess'}));
    end
    for mi=1:numel(metrics)
        count=sum(tr.(metrics{mi})); interval=binomialInterval(count,height(tr));
        summaries(end+1,:)={conditions(ci).id,conditions(ci).name,metrics{mi},height(tr),count,...
            count/height(tr),interval(1),interval(2)}; %#ok<AGROW>
    end
end
report.summary=cell2table(summaries,'VariableNames',{'conditionId','condition','event',...
    'independentIds','eventCount','probability','lo95','hi95'});
report.independentIds=idLists;
report.realizationAssignments=struct('collisionDiagnostics',collisionIds,...
    'receiverDiagnostics',receiverIds,'interferenceReplay',3300);
if budgetPaused
    if options.runReceiverChecks, pendingCases{end+1}='receiver-checks'; end
    if options.runInterferenceReplay
        pendingCases=[pendingCases {'interference-replay-delta-00','interference-replay-delta-40'}]; %#ok<AGROW>
    end
end
report.receiverChecks=cell2table(cell(0,11),'VariableNames', ...
    {'condition','id','index','present','ownDetected','miss','falseAlarm', ...
    'estimatedDelaySamples','estimatedCfoHz','actualDelaySamples','actualCfoHz'});
if options.runReceiverChecks && ~budgetPaused
    [report.receiverChecks,receiverPaused,receiverPending]=receiverChecks( ...
        base,options.outputFolder,receiverIds,options.execution,clockStart,options.progressFile,...
        options.budgetLedgerFile);
    if receiverPaused
        budgetPaused=true;
        pendingCases=[pendingCases receiverPending]; %#ok<AGROW>
        if options.runInterferenceReplay
            pendingCases=[pendingCases {'interference-replay-delta-00', ...
                'interference-replay-delta-40'}]; %#ok<AGROW>
        end
    end
end
if options.runInterferenceReplay && ~budgetPaused
    [report.interferenceReplay,replayPaused,replayPending]=interferenceReplay( ...
        base,options.outputFolder,options.execution,clockStart,options.progressFile,...
        options.budgetLedgerFile);
    if replayPaused
        budgetPaused=true;
        pendingCases=[pendingCases replayPending]; %#ok<AGROW>
    end
end
report.status='completed';
if budgetPaused
    report.status='budget-paused';
end
report.pendingCases=pendingCases;
report.elapsedSeconds=toc(clockStart);
if budgetPaused
    progress=stage2PhysicalProgress('pause',options.progressFile);
    report.pendingCases=cellstr(string(progress.pendingCaseKeys));
    updatePhysicalBudgetPending(options.budgetLedgerFile,report.pendingCases);
else
    stage2PhysicalProgress('finish',options.progressFile);
    updatePhysicalBudgetPending(options.budgetLedgerFile,{});
end
if options.manageRegistry && ~budgetPaused
    completeStage2Registry(options.registryFile,'stage-2-collision-diagnostics',collisionIds,identity.assignmentSource);
    if ~isempty(receiverIds)
        completeStage2Registry(options.registryFile,'stage-2-receiver-diagnostics',receiverIds,identity.assignmentSource);
    end
end
report.registrySha256=fileHash(options.registryFile);
save(fullfile(options.outputFolder,'report.mat'),'report','-v7');
writetable(report.trials,fullfile(options.outputFolder,'trials.csv'));
writetable(report.summary,fullfile(options.outputFolder,'summary.csv'));
if budgetPaused
    fprintf('COLLISION_BUDGET_PAUSED completedTrials=%d pendingCases=%d elapsedSeconds=%.3f\n', ...
        height(report.trials),numel(report.pendingCases),report.elapsedSeconds);
else
    fprintf('COLLISION_DONE conditions=%d independentTrials=%d seconds=%.3f\n',...
        numel(conditions),height(report.trials),report.elapsedSeconds);
end
catch exception
    rethrow(exception);
end
end

function identity=physicalIdentity(root,conditions,options,base,report,idMatrix,receiverIds,collisionIds)
assignmentSource=strrep(options.outputFolder,[root filesep],'');
identity=struct('scope','stage-2-physical-matrix-v1', ...
    'conditionIds',double([conditions.id]),'conditions',conditions, ...
    'repeats',double(options.repeats),'durationTicks',double(options.durationTicks), ...
    'runReceiverChecks',logical(options.runReceiverChecks), ...
    'runInterferenceReplay',logical(options.runInterferenceReplay), ...
    'baseConfig',base,'calibrationSha256',report.calibrationSha256, ...
    'receiverRevision',report.receiverRevision,'sourceManifest',report.sourceManifest, ...
    'artifactSourceHashes',report.artifactSourceHashes,'matlabRelease',report.matlabRelease, ...
    'lteVersion',report.lteVersion,'collisionIdMatrix',double(idMatrix), ...
    'collisionIds',double(collisionIds(:).'),'receiverIds',double(receiverIds(:).'), ...
    'assignedIds',double([collisionIds(:).' receiverIds(:).']), ...
    'assignmentSource',assignmentSource,'outputFolder',options.outputFolder, ...
    'registryFile',options.registryFile,'budgetLedgerFile',options.budgetLedgerFile);
end

function cases=physicalCaseSpecs(conditions,idMatrix,options,receiverIds)
cases=struct('caseKey',{},'kind',{},'realizationId',{},'evidenceFile',{});
for ci=1:numel(conditions)
    for trial=1:options.repeats
        id=idMatrix(ci,trial); condition=conditions(ci);
        cases(end+1)=struct('caseKey',sprintf('collision-condition-%02d-repeat-%02d-id-%04d', ...
            condition.id,trial,id),'kind','collision','realizationId',id, ...
            'evidenceFile',sprintf('condition-%02d-id-%04d.mat',condition.id,id)); %#ok<AGROW>
    end
end
if options.runReceiverChecks
    kinds={'clean','noise20','noiseMinus20','cfoMinus200','cfoPlus200', ...
        'delayMinus2us','delayPlus2us','noiseOnly'};
    for ci=1:numel(kinds)
        for ii=1:numel(receiverIds)
            id=receiverIds(ii); kind=kinds{ci};
            cases(end+1)=struct('caseKey',sprintf('receiver-%s-id-%04d',kind,id), ...
                'kind','receiver','realizationId',id, ...
                'evidenceFile',sprintf('receiver-%s-id-%04d.mat',kind,id)); %#ok<AGROW>
        end
    end
end
if options.runInterferenceReplay
    for delta=[0 40]
        cases(end+1)=struct('caseKey',sprintf('interference-replay-delta-%02d-id-3300',delta), ...
            'kind','interference-replay','realizationId',3300, ...
            'evidenceFile',sprintf('interference-replay-%02d.mat',delta)); %#ok<AGROW>
    end
end
end

function path=physicalEvidenceFile(cases,key)
index=find(strcmp({cases.caseKey},key),1);
assert(~isempty(index),'nbiot:stage2:ProgressCase','Unknown Stage 2 case %s.',key);
path=cases(index).evidenceFile;
end

function completed=progressCaseCompleted(progressFile,key)
progress=stage2PhysicalProgress('read',progressFile);
index=find(strcmp({progress.caseRecords.caseKey},key),1);
assert(~isempty(index),'nbiot:stage2:ProgressCase','Unknown Stage 2 case %s.',key);
completed=strcmp(progress.caseRecords(index).status,'completed');
end

function verifyStage2Registry(registryFile,role,ids,source,progressStatus)
if ~isfile(registryFile)
    error('nbiot:stage2:Registry','Stage 2 realization registry is missing.');
end
try, registry=jsondecode(fileread(registryFile));
catch exception
    error('nbiot:stage2:Registry','Cannot decode Stage 2 registry: %s.',exception.message);
end
if ~isfield(registry,'assignments')||isempty(registry.assignments)
    error('nbiot:stage2:Registry','Stage 2 registry has no saved assignment for %s.',role);
end
expectedStatus='planned';
found=false;
for k=1:numel(registry.assignments)
    entry=registry.assignments(k);
    if strcmp(entry.role,role)&&strcmp(entry.source,source)&& ...
            isequal(double(entry.ids(:).'),double(ids(:).'))&& ...
            (strcmp(entry.status,expectedStatus)|| ...
            (strcmp(progressStatus,'completed')&&strcmp(entry.status,'completed')))
        found=true; break
    end
end

if ~found
    error('nbiot:stage2:Registry', ...
        'Stage 2 registry assignment for %s does not match the saved IDs, source, or status.',role);
end
end

function completeStage2Registry(registryFile,role,ids,source)
registry=jsondecode(fileread(registryFile));
for k=1:numel(registry.assignments)
    entry=registry.assignments(k);
    if strcmp(entry.role,role)&&strcmp(entry.source,source)&&...
            isequal(double(entry.ids(:).'),double(ids(:).'))
        if strcmp(entry.status,'completed'), return; end
        if strcmp(entry.status,'planned')
            nbiot.experiments.updateRealizationUseStatus(registryFile,role,ids,'completed');
            return
        end
    end
end
error('nbiot:stage2:Registry','Cannot complete a mismatched Stage 2 assignment for %s.',role);
end

function expired=sharedBudgetExpired(path)
expired=false;
if isempty(path), return; end
ledger=nbiot.experiments.loadVariant2BudgetLedger(path,false);
if activeBudgetCase(ledger.activeCase)
    error('nbiot:stage2:BudgetLedger','A shared-budget case is already active; inspect its process before starting another.');
end
expired=ledger.elapsedSeconds>=ledger.budgetSeconds;
end

function active=beginPhysicalBudget(path,caseKey,numUE,runFolder)
active=struct('caseKey','','startedAtUtc','');
if isempty(path), return; end
ledger=nbiot.experiments.loadVariant2BudgetLedger(path,false);
if activeBudgetCase(ledger.activeCase)
    error('nbiot:stage2:BudgetLedger','Another shared-budget case is active.');
end
started=utcNow(); key=['stage-2-physical:' caseKey];
active=struct('caseKey',key,'startedAtUtc',started);
ledger.activeCase=struct('caseKey',key,'numUE',double(numUE), ...
    'startedAtUtc',started,'lastProgressAtUtc',started,'runFolder',runFolder);
ledger.pendingCases={caseKey};
ledger.phaseTimes(end+1)=struct('phase','stage-2-physical', ...
    'startedAtUtc',started,'finishedAtUtc','','elapsedSeconds',0,'caseKey',key);
nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
end

function finishPhysicalBudget(path,active,seconds,status)
if isempty(path)||isempty(active.caseKey), return; end
if ~isfinite(seconds)||seconds<0
    error('nbiot:stage2:BudgetLedger','Invalid Stage 2 case elapsed time.');
end
ledger=nbiot.experiments.loadVariant2BudgetLedger(path,false);
if ~activeBudgetCase(ledger.activeCase)||~strcmp(ledger.activeCase.caseKey,active.caseKey)
    error('nbiot:stage2:BudgetLedger','The active Stage 2 budget case changed before it was settled.');
end
ledger=closePhysicalBudgetCase(ledger,active.caseKey,seconds,status);
nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
end

function settleInterruptedPhysicalBudget(path,progress)
ledger=nbiot.experiments.loadVariant2BudgetLedger(path,false);
if ~activeBudgetCase(ledger.activeCase), return; end
prefix='stage-2-physical:';
if ~startsWith(ledger.activeCase.caseKey,prefix)
    error('nbiot:stage2:BudgetLedger','An unrelated shared-budget case remains active.');
end
caseKey=extractAfter(string(ledger.activeCase.caseKey),strlength(prefix));
index=find(strcmp({progress.caseRecords.caseKey},char(caseKey)),1);
if isempty(index), error('nbiot:stage2:BudgetLedger','Active Stage 2 budget case is absent from its progress manifest.'); end
record=progress.caseRecords(index);
if strcmp(record.status,'completed')&&~isempty(record.finishedAtUtc)
    seconds=max(0,secondsBetween(record.startedAtUtc,record.finishedAtUtc));
else
    % After a checked-dead worker, charge elapsed wall time conservatively.
    seconds=max(0,secondsBetween(ledger.activeCase.startedAtUtc,utcNow()));
end
ledger=closePhysicalBudgetCase(ledger,ledger.activeCase.caseKey,seconds,'recovered-after-worker-exit');
nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
end

function ledger=closePhysicalBudgetCase(ledger,key,seconds,status)
ledger.elapsedSeconds=double(ledger.elapsedSeconds)+double(seconds);
matches=find(strcmp({ledger.phaseTimes.caseKey},key)&cellfun(@isempty,{ledger.phaseTimes.finishedAtUtc}),1,'last');
if isempty(matches)
    ledger.phaseTimes(end+1)=struct('phase','stage-2-physical', ...
        'startedAtUtc',ledger.activeCase.startedAtUtc,'finishedAtUtc',utcNow(), ...
        'elapsedSeconds',double(seconds),'caseKey',key);
else
    ledger.phaseTimes(matches).finishedAtUtc=utcNow();
    ledger.phaseTimes(matches).elapsedSeconds=double(seconds);
end
ledger.activeCase=struct('caseKey','','numUE',0,'startedAtUtc','', ...
    'lastProgressAtUtc','','runFolder','');
ledger.pendingCases={};
ledger.lastCaseStatus=status;
if ledger.elapsedSeconds>=ledger.budgetSeconds
    ledger.warnings(end+1)=struct('timestampUtc',utcNow(),'phase','stage-2-physical', ...
        'elapsedSeconds',double(ledger.elapsedSeconds), ...
        'message',sprintf('Shared 57600-second budget was reached during %s; no next case was admitted.',key));
end
end

function active=activeBudgetCase(value)
active=isstruct(value)&&isscalar(value)&&isfield(value,'caseKey')&& ...
    ~isempty(char(string(value.caseKey)));
end

function seconds=secondsBetween(first,second)
try
    a=datetime(first,'InputFormat','yyyy-MM-dd HH:mm:ss.SSS','TimeZone','UTC');
    b=datetime(second,'InputFormat','yyyy-MM-dd HH:mm:ss.SSS','TimeZone','UTC');
    elapsed=seconds(b-a); seconds=elapsed;
catch exception
    error('nbiot:stage2:BudgetLedger','Cannot settle active Stage 2 case timestamps: %s.',exception.message);
end
end

function value=utcNow()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS'));
end

function updatePhysicalBudgetPending(path,pending)
if isempty(path), return; end
ledger=nbiot.experiments.loadVariant2BudgetLedger(path,false);
if activeBudgetCase(ledger.activeCase)
    error('nbiot:stage2:BudgetLedger','Cannot finalize a Stage 2 suite while a budget case remains active.');
end
ledger.pendingCases=pending;
nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
end

function expired=suiteBudgetExpired(execution,clockStart)
expired=false;
if toc(clockStart)<execution.maxSuiteSeconds, return; end
if strcmp(execution.timePolicy,'finish-current')
    expired=true;
else
    error('nbiot:experiments:ExecutionTimeout', ...
        'Collision diagnostics suite time budget exhausted.');
end
end

function pending=pendingCollisionCases(conditions,firstCondition,firstTrial,repeats)
pending={};
for ci=firstCondition:numel(conditions)
    trialStart=1;
    if ci==firstCondition, trialStart=firstTrial; end
    for trial=trialStart:repeats
        pending{end+1}=sprintf('collision-condition-%02d-repeat-%02d', ...
            conditions(ci).id,trial); %#ok<AGROW>
    end
end
end

function c=conditionGrid()
c=struct('id',{},'group',{},'name',{},'numUE',{},'samePreamble',{},'deltaDb',{},'delaySeconds',{},'cfoHz',{});
for same=[true false]
    for delta=[0 6 12 20 30 40]
        group=4; if delta==0, if same, group=1; else, group=3; end, end
        c(end+1)=struct('id',numel(c)+1,'group',group,...
            'name',sprintf('same%d-nearfar%02d',same,delta),'numUE',2,...
            'samePreamble',same,'deltaDb',delta,'delaySeconds',[0 0],'cfoHz',[0 0]); %#ok<AGROW>
    end
end
c(end+1)=struct('id',13,'group',2,'name','three-same','numUE',3,...
    'samePreamble',true,'deltaDb',0,'delaySeconds',[0 0 0],'cfoHz',[0 0 0]);
c(end+1)=struct('id',14,'group',5,'name','same-delay-edges','numUE',2,...
    'samePreamble',true,'deltaDb',0,'delaySeconds',[-2 2]*1e-6,'cfoHz',[0 0]);
c(end+1)=struct('id',15,'group',6,'name','same-cfo-edges','numUE',2,...
    'samePreamble',true,'deltaDb',0,'delaySeconds',[0 0],'cfoHz',[-200 200]);
end

function ids=matchingIds(cfg,c,n,registryFile)
ids=[];
% Condition only the initial NPRACH choices; independent noise/payload/token
% substreams remain unselected. The same ID list across near-far is paired.
candidateIds=nbiot.experiments.availableRealizationIds(registryFile,...
    'stage-2-collision-diagnostics',1000:3999);
for id=candidateIds
    sources=nbiot.randomness.RandomSources(cfg.simulation.seed,id); indices=zeros(1,c.numUE);
    for u=1:c.numUE
        s=sources.stream('access',0,u,1); rand(s); indices(u)=floor(rand(s)*12);
    end
    if (c.samePreamble&&numel(unique(indices))==1)||(~c.samePreamble&&numel(unique(indices))==c.numUE)
        ids(end+1)=id; %#ok<AGROW>
        if numel(ids)==n, return; end
    end
end
error('nbiot:collision:IDs','Insufficient distinct external IDs for selected initial preambles.');
end

function scenario=diagnosticScenario(cfg,sources,c,keepFading)
scenario=nbiot.scenario.buildScenario(cfg,sources);
distance0=hypot(50,cfg.cell.bsHeightM-cfg.cell.ueHeightM);
for u=1:c.numUE
    distance=distance0*10^((u>1)*c.deltaDb/(10*cfg.channel.pathLossExponent));
    radius=sqrt(distance^2-(cfg.cell.bsHeightM-cfg.cell.ueHeightM)^2);
    assert(radius<=cfg.cell.radiusM,'nbiot:collision:Geometry','Diagnostic UE outside cell.');
    ue=scenario.ue(u); ue.xM=radius; ue.yM=0; ue.horizontalDistanceM=radius; ue.distanceM=distance;
    ue.medianPathLossDb=20*log10(4*pi*cfg.channel.carrierHz*cfg.channel.referenceDistanceM/299792458)+...
        10*cfg.channel.pathLossExponent*log10(distance/cfg.channel.referenceDistanceM);
    ue.pathLossDb=ue.medianPathLossDb; ue.shadowingDb=0; ue.penetrationDb=0;
    if ~keepFading
        ue.tapsUl=[1;0;0]; ue.tapsDl=[1;0;0]; ue.cfoHz=c.cfoHz(u);
        ue.syncOffsetSeconds=c.delaySeconds(u);
    end
    scenario.ue(u)=ue;
end
end

function [r,trace]=runObserved(cfg,scenario,collectFailures,execution)
if nargin<4, execution=struct(); end
sim=nbiot.NBIoTSimulator(cfg,scenario,execution);
trace=struct('attemptTokens',struct('attemptId',{},'ueId',{},'token',{},'raRnti',{},'rnti',{},'rarTick',{}),...
    'acceptedMsg3',struct('contextId',{},'rnti',{},'token',{},'sequence',{},'tick',{}),...
    'firstDetected',[],'firstMetrics',[],'stateTransitions',{{}},'dataGrants',{{}},'failure',[],...
    'replayCandidate',[],...
    'failureScan',struct('dataRxSchedules',0,'decodeTickMatches',0,'rntiMatches',0,...
        'packetMatches',0,'ndiMatches',0,'busyWindowMatches',0,'decodeAttempts',0,...
        'decodePasses',0,'decodeFailures',0));
seenTokens=[]; seenMsg3=[]; seenGrants=[];
while ~strcmp(sim.status,'completed')
    before=sim.devices.entries;
    % Offline counterfactual input is captured before the actual receive event.
    if collectFailures&&isempty(trace.failure)
        [trace.failure,trace.failureScan,trace.replayCandidate]=...
            inspectFailure(sim,cfg,scenario,trace.failureScan,trace.replayCandidate);
    end
    sim.step(); after=sim.devices.entries;
    for u=1:numel(after)
        d=after(u); old=before(u);
        if ~strcmp(old.state,d.state)
            trace.stateTransitions{end+1}=struct('tick',sim.currentTick,'ueId',u,'from',old.state,'to',d.state);
        end
        if d.attemptId>0&&~ismember(d.attemptId,seenTokens)
            trace.attemptTokens(end+1)=struct('attemptId',d.attemptId,'ueId',u,...
                'token',d.token,'raRnti',d.raRnti,'rnti',0,'rarTick',NaN); seenTokens(end+1)=d.attemptId;
        end
        if strcmp(old.state,'WAIT_RAR')&&strcmp(d.state,'WAIT_MSG4')
            at=find([trace.attemptTokens.attemptId]==d.attemptId,1);
            trace.attemptTokens(at).rnti=d.rnti; trace.attemptTokens(at).rarTick=sim.currentTick;
        end
    end
    for id=1:numel(sim.contexts.entries)
        ctx=sim.contexts.get(id);
        if ctx.token>0&&~ismember(id,seenMsg3)
            trace.acceptedMsg3(end+1)=struct('contextId',id,'rnti',ctx.rnti,...
                'token',ctx.token,'sequence',ctx.sequence,'tick',sim.currentTick); seenMsg3(end+1)=id;
        end
        if strcmp(ctx.state,'DATA_RX')&&~isempty(ctx.schedule)
            g=ctx.schedule.payloadGrant;
            if ~ismember(g.grantId,seenGrants)
                trace.dataGrants{end+1}=struct('contextId',id,'sequence',ctx.sequence,...
                    'blockIndex',ctx.nextFragment-1,'harqTry',ctx.harqTry,'grant',g);
                seenGrants(end+1)=g.grantId;
            end
        end
    end
    if sim.currentTick==16
        occasion=struct('occasionId',1,'startTick',8);
        rx=sim.channel.receive('UL',0,8*1920-128,14*1920+128);
        [trace.firstDetected,trace.firstMetrics]=nbiot.phy.nprach.detect(cfg,rx,occasion);
    end
end
r=sim.result(); assert(strcmp(r.status,'completed'),'nbiot:collision:Failed','Physical run failed.');
end

function interval=binomialInterval(k,n)
if k==0, lo=0; else, lo=betaincinv(.025,k,n-k+1); end
if k==n, hi=1; else, hi=betaincinv(.975,k+1,n-k); end
interval=[lo hi];
end

function [checks,paused,pending]=receiverChecks(cfg,folder,ids,execution,clockStart,progressFile,budgetLedgerFile)
% Ten independent IDs per input condition; these are diagnostics, not calibration.
kinds={'clean','noise20','noiseMinus20','cfoMinus200','cfoPlus200','delayMinus2us','delayPlus2us','noiseOnly'};
rows=cell(0,11); saved={}; paused=false; pending={};
occasion=struct('occasionId',1,'startTick',8);
for ci=1:numel(kinds)
    for ii=1:numel(ids)
        id=ids(ii);
        kind=kinds{ci}; caseKey=sprintf('receiver-%s-id-%04d',kind,id);
        if progressCaseCompleted(progressFile,caseKey)
            payload=stage2PhysicalProgress('loadCase',progressFile,caseKey);
            rows(end+1,:)=payload.row; saved{end+1}=payload.saved; %#ok<AGROW>
            continue
        end
        if sharedBudgetExpired(budgetLedgerFile)||suiteBudgetExpired(execution,clockStart)
            paused=true;
            break
        end
        stage2PhysicalProgress('start',progressFile,caseKey);
        budgetStart=beginPhysicalBudget(budgetLedgerFile,caseKey,1,folder);
        caseClock=tic;
        sources=nbiot.randomness.RandomSources(42,id); index=mod(id,12);
        tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,index); tx.ueId=1;
        c=cfg; c.simulation.numUE=1; c.simulation.realizationId=id; c.cell.indoorFraction=0;
        condition=struct('numUE',1,'deltaDb',0,'cfoHz',0,'delaySeconds',0);
        s=diagnosticScenario(c,sources,condition,false);
        if strcmp(kind,'cfoMinus200'), s.ue.cfoHz=-200; end
        if strcmp(kind,'cfoPlus200'), s.ue.cfoHz=200; end
        if strcmp(kind,'delayMinus2us'), s.ue.syncOffsetSeconds=-2e-6; end
        if strcmp(kind,'delayPlus2us'), s.ue.syncOffsetSeconds=2e-6; end
        c.channel.bsNoiseFigureDb=-Inf; ch=nbiot.channel.RadioChannel(c,s,sources);
        if ~strcmp(kind,'noiseOnly'), ch.add(tx); end
        rx=ch.receive('UL',0,8*1920-128,14*1920+128);
        if startsWith(kind,'noise')
            noise=sources.stream('noise',0,0,8000000+ci);
            if strcmp(kind,'noiseOnly'), variance=1.380649e-23*290*10^(5/10)*1920000;
            else
                snr=20; if strcmp(kind,'noiseMinus20'), snr=-20; end
                variance=mean(abs(rx.waveform(129:end-128)).^2)/10^(snr/10);
            end
            rx.waveform=rx.waveform+sqrt(variance/2)*(randn(noise,size(rx.waveform))+1i*randn(noise,size(rx.waveform)));
        end
        [d,m]=nbiot.phy.nprach.detect(cfg,rx,occasion);
        present=~strcmp(kind,'noiseOnly'); found=ismember(index,[d.nInit]);
        falseAlarm=any(~ismember([d.nInit],index)); if ~present, falseAlarm=~isempty(d); end
        own=d([d.nInit]==index); delay=NaN; cfo=NaN;
        if ~isempty(own), delay=own.delaySeconds*1920000; cfo=own.cfoHz; end
        row={kind,id,index,present,found,present&&~found,falseAlarm,delay,cfo,...
            (2*s.ue.distanceM/299792458+s.ue.syncOffsetSeconds)*1920000,s.ue.cfoHz};
        savedItem=struct('kind',kind,'id',id,'detected',d,'metrics',m);
        stage2PhysicalProgress('complete',progressFile,caseKey,struct('row',{row},'saved',savedItem));
        finishPhysicalBudget(budgetLedgerFile,budgetStart,toc(caseClock),'completed');
        rows(end+1,:)=row; saved{end+1}=savedItem; %#ok<AGROW>
    end
    if paused, break; end
end
if paused
    progress=stage2PhysicalProgress('read',progressFile);
    pending=cellstr(string(progress.pendingCaseKeys));
end
checks=cell2table(rows,'VariableNames',{'condition','id','index','present','ownDetected','miss','falseAlarm',...
    'estimatedDelaySamples','estimatedCfoHz','actualDelaySamples','actualCfoHz'});
save(fullfile(folder,'receiver-checks.mat'),'checks','saved','pending','-v7');
writetable(checks,fullfile(folder,'receiver-checks.csv'));
end

function [failure,scan,candidate]=inspectFailure(sim,cfg,scenario,scan,candidate)
failure=[];
for id=1:numel(sim.contexts.entries)
    c=sim.contexts.get(id);
    if ~strcmp(c.state,'DATA_RX')||isempty(c.schedule), continue; end
    scan.dataRxSchedules=scan.dataRxSchedules+1;
    g=c.schedule.payloadGrant;
    % inspectFailure runs before step; decode is queued at end+processing+1.
    if sim.currentTick~=g.endTick+cfg.phy.processingTicks, continue; end
    scan.decodeTickMatches=scan.decodeTickMatches+1;
    % Only a genuine transmitted weak-UE block is a valid isolation input.
    device=sim.devices.get(2);
    if device.rnti~=g.rnti, continue; end
    scan.rntiMatches=scan.rntiMatches+1;
    if device.packetId<=0, continue; end
    scan.packetMatches=scan.packetMatches+1;
    if device.ndi~=g.ndi, continue; end
    scan.ndiMatches=scan.ndiMatches+1;
    if device.ulBusyStartTick~=g.startTick||device.ulBusyUntilTick~=g.endTick, continue; end
    scan.busyWindowMatches=scan.busyWindowMatches+1;
    first=max(0,g.startTick*1920-128); last=g.endTick*1920+128;
    fullRx=sim.channel.receive('UL',0,first,last);
    [decoded,~]=nbiot.phy.npusch.receive(cfg,fullRx,g,c.softBuffer);
    scan.decodeAttempts=scan.decodeAttempts+1;
    if isempty(candidate)
        packet=sim.packets.get(device.packetId); actualBits=packet.blocks{device.fragmentIndex+1};
        candidate=buildInterferenceDiagnosis(cfg,scenario,g,c,device,fullRx,decoded,actualBits);
    end
    if decoded.crcError==0, scan.decodePasses=scan.decodePasses+1; continue; end
    scan.decodeFailures=scan.decodeFailures+1;
    packet=sim.packets.get(device.packetId); actualBits=packet.blocks{device.fragmentIndex+1};
    if ~isempty(candidate)&&candidate.grant.grantId==g.grantId
        failure=candidate;
    else
        failure=buildInterferenceDiagnosis(cfg,scenario,g,c,device,fullRx,decoded,actualBits);
    end
    return;
end
end

function diagnosis=buildInterferenceDiagnosis(cfg,scenario,g,c,device,fullRx,fullDecode,actualBits)
first=max(0,g.startTick*1920-128); last=g.endTick*1920+128;
[tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,actualBits,device.encoderState);
tx.ueId=2; tx.timingAdvanceSeconds=device.timingAdvanceSeconds;
desired=nbiot.channel.RadioChannel(cfg,scenario,nbiot.randomness.RandomSources(42,cfg.simulation.realizationId));
noise=nbiot.channel.RadioChannel(cfg,scenario,nbiot.randomness.RandomSources(42,cfg.simulation.realizationId));
desired.add(tx); desiredRx=desired.receive('UL',0,first,last); noiseRx=noise.receive('UL',0,first,last);
variants={fullRx,fullRx,desiredRx,desiredRx};
variants{2}.waveform=fullRx.waveform-noiseRx.waveform;
variants{4}.waveform=desiredRx.waveform-noiseRx.waveform;
labels={'full-noisy','full-clean','desired-noisy','desired-clean'}; answers=cell(1,4); rows={};
answers{1}=fullDecode;
for vi=2:4
    [answers{vi},~]=nbiot.phy.npusch.receive(cfg,variants{vi},g,c.softBuffer);
    a=answers{vi}; rows(end+1,:)={labels{vi},a.crcError,isequal(a.decodedBits,actualBits),...
        a.measurements.timing.delaySamples,a.measurements.cfoHz}; %#ok<AGROW>
end
a=answers{1}; rows=[{labels{1},a.crcError,isequal(a.decodedBits,actualBits),...
    a.measurements.timing.delaySamples,a.measurements.cfoHz}; rows];
diagnosis=struct('cfg',cfg,'scenario',scenario,'grant',g,'contextBeforeDecode',c,...
    'deviceBeforeDecode',device,'actualBits',actualBits,'variants',{variants},'decodes',{answers},...
    'table',cell2table(rows,'VariableNames',{'variant','crcError','payloadMatchesActualTx','timingSamples','estimatedCfoHz'}),...
    'scope','Offline desired-only diagnostic uses truth only to reconstruct emitted TX, never as production decoder input.');
end

function [summary,paused,pending]=interferenceReplay(base,folder,execution,clockStart,progressFile,budgetLedgerFile)
rows=cell(0,6); paused=false; pending={}; deltas=[0 40];
for di=1:numel(deltas)
    delta=deltas(di);
    caseKey=sprintf('interference-replay-delta-%02d-id-3300',delta);
    if progressCaseCompleted(progressFile,caseKey)
        payload=stage2PhysicalProgress('loadCase',progressFile,caseKey);
        diagnosis=payload.diagnosis; result=payload.result;
        replayVerified=payload.replayVerified;
        assert(replayVerified,'nbiot:collision:Replay','Saved replay case was not verified.');
        appendReplayRows();
        continue
    end
    if sharedBudgetExpired(budgetLedgerFile)||suiteBudgetExpired(execution,clockStart)
        paused=true;
        break
    end
    stage2PhysicalProgress('start',progressFile,caseKey);
    budgetStart=beginPhysicalBudget(budgetLedgerFile,caseKey,2,folder);
    caseClock=tic;
    cfg=base; cfg.simulation.numUE=2; cfg.simulation.realizationId=3300;
    cfg.simulation.durationTicks=5000; cfg.cell.indoorFraction=0;
    cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0;
    cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
    c=struct('numUE',2,'deltaDb',delta); sources=nbiot.randomness.RandomSources(42,3300);
    scenario=diagnosticScenario(cfg,sources,c,true);
    [result,trace]=runObserved(cfg,scenario,true,execution);
    if isempty(trace.failure)&&isempty(trace.replayCandidate)
        result.observedLog=result.observedLog(~strcmp({result.observedLog.kind},'bs_queue'));
        save(fullfile(folder,sprintf('interference-replay-missing-%02d.mat',delta)),...
            'result','trace','cfg','scenario','-v7');
        error('nbiot:collision:Replay',...
            'No valid UE2 payload block was available for replay at %d dB; scan=%s.',...
            delta,jsonencode(trace.failureScan));
    end
    if isempty(trace.failure)
        if delta~=0
            result.observedLog=result.observedLog(~strcmp({result.observedLog.kind},'bs_queue'));
            save(fullfile(folder,sprintf('interference-replay-missing-%02d.mat',delta)),...
                'result','trace','cfg','scenario','-v7');
            error('nbiot:collision:Replay',...
                'Expected near-far CRC failure was not reproduced at %d dB; scan=%s.',...
                delta,jsonencode(trace.failureScan));
        end
        diagnosis=trace.replayCandidate;
    else
        diagnosis=trace.failure;
    end
    result.observedLog=result.observedLog(~strcmp({result.observedLog.kind},'bs_queue'));
    replayVerified=false;
    replayFile=fullfile(folder,sprintf('interference-replay-%02d.mat',delta));
    if delta==0
        verified=diagnosis.decodes{1}.crcError==0&&diagnosis.decodes{3}.crcError==0&&...
            isequal(diagnosis.decodes{1}.decodedBits,diagnosis.actualBits)&&...
            isequal(diagnosis.decodes{3}.decodedBits,diagnosis.actualBits);
    else
        verified=diagnosis.decodes{1}.crcError~=0&&diagnosis.decodes{3}.crcError==0&&...
            isequal(diagnosis.decodes{3}.decodedBits,diagnosis.actualBits);
    end
    if ~verified
        save(strrep(replayFile,'.mat','-unverified.mat'), ...
            'diagnosis','result','trace','replayVerified','-v7');
        if delta==0
            error('nbiot:collision:Replay',...
                'Equal-power control no longer decodes the actual UE2 payload.');
        else
            error('nbiot:collision:Replay',...
                'Near-far full-mixture fail / desired-only pass diagnosis changed.');
        end
    end
    replayVerified=true;
    stage2PhysicalProgress('complete',progressFile,caseKey, ...
        struct('diagnosis',diagnosis,'result',result,'trace',trace, ...
        'replayVerified',replayVerified,'cfg',cfg,'scenario',scenario));
    finishPhysicalBudget(budgetLedgerFile,budgetStart,toc(caseClock),'completed');
    assert(isfile(replayFile),'nbiot:stage2:ProgressEvidence','Stage 2 replay evidence was not written.');
    appendReplayRows();
    fprintf('INTERFERENCE_REPLAY delta=%d fullCRC=%d desiredCRC=%d retries=%d delivered=%d\n',...
        delta,diagnosis.decodes{1}.crcError,diagnosis.decodes{3}.crcError,...
        result.kpiSummary.harq.retryAttempts,result.kpiSummary.delivered);
end
if paused
    progress=stage2PhysicalProgress('read',progressFile);
    pending=cellstr(string(progress.pendingCaseKeys));
end
summary=cell2table(rows,'VariableNames', ...
    {'deltaDb','variant','crcError','payloadMatchesActualTx','timingSamples','estimatedCfoHz'});
writetable(summary,fullfile(folder,'interference-replay.csv'));

    function appendReplayRows()
        for rowIndex=1:height(diagnosis.table)
            trialRow=table2cell(diagnosis.table(rowIndex,:));
            rows(end+1,:)=[{delta} trialRow]; %#ok<AGROW>
        end
    end
end

function hash=fileHash(path)
fid=fopen(path,'rb'); assert(fid>=0); close=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=fread(fid,Inf,'*uint8'); digest=java.security.MessageDigest.getInstance('SHA-256'); digest.update(bytes);
hash=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
