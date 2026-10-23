function report=runLoadProbe(options)
%RUNLOADPROBE Run the four-load preliminary Static probe with safe resume.
%   Предварительный нагрузочный прогон Static на 4 уровнях с возобновлением. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
% The five-load budget pilot remains a separate interface in runLoadPilot.
if nargin<1, options=struct(); end
root=fileparts(fileparts(mfilename('fullpath')));
options=loadProbeOptions(options,root);
plan=struct('scope','variant2-preliminary-load-probe', ...
    'requestedCounts',[100 500 1000 2500],'completedCounts',[], ...
    'missingFullPilotCounts',5000,'fullPilotCompleted',false, ...
    'status','design-only','realizationId',[],'perCaseMeasurements',struct([]), ...
    'runtimeHashes',struct());
if options.designOnly, report=plan; return; end

validateProbeMode(options);
if isempty(options.runId), options.runId=char(java.util.UUID.randomUUID()); end
ledgerWriterLease=acquireBudgetLedgerWriterLease(options.budgetLedgerFile); %#ok<NASGU>
newRun=~options.resume;
if newRun
    options.outputFolder=prepareOutputFolder(options.outputFolder,root);
    if isempty(options.memoryRootFolder), options.memoryRootFolder=options.outputFolder; end
    snapshotPath=fullfile(options.outputFolder,'registry-snapshot.json');
    if ~isfile(options.registryFile)
        error('nbiot:experiments:LoadProbeRegistry','Realization registry is missing.');
    end
    [ok,message]=copyfile(options.registryFile,snapshotPath);
    if ~ok, error('nbiot:experiments:LoadProbeRegistry','Cannot preserve registry snapshot: %s',message); end
    progressPath=fullfile(options.outputFolder,'progress.json');
    writeJsonAtomic(fullfile(options.outputFolder,'preflight.json'), ...
        struct('status','checking','startedAtUtc',utcNow(),'runFolder',options.outputFolder));
else
    progressPath=fullfile(options.outputFolder,'progress.json');
    snapshotPath=fullfile(options.outputFolder,'registry-snapshot.json');
    if ~isfolder(options.outputFolder)||~isfile(progressPath)||~isfile(snapshotPath)
        error('nbiot:experiments:LoadProbeResume','Resume requires the original run folder, progress and registry snapshot.');
    end
end

if isempty(options.runControlFolder)
    options.runControlFolder=fileparts(canonicalPath(options.outputFolder));
else
    options.runControlFolder=canonicalPath(options.runControlFolder);
end
if ~isfolder(options.runControlFolder)
    error('nbiot:experiments:LoadProbeControl','The scheduler run folder is missing.');
end

try
    [execution,acceptance,preflight]=validatePreflight(options,root,snapshotPath);
    writeJsonAtomic(fullfile(options.outputFolder,'preflight.json'),preflight);
    syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
catch exception
    writeJsonAtomic(fullfile(options.outputFolder,'preflight.json'), ...
        struct('status','failed','failedAtUtc',utcNow(),'identifier',exception.identifier, ...
        'message',exception.message,'runFolder',options.outputFolder));
    if strcmp(exception.identifier,'nbiot:experiments:PilotGate')
        error('nbiot:experiments:LoadProbeStage2Gate','%s',exception.message);
    end
    rethrow(exception);
end

if newRun
    ledger=nbiot.experiments.loadVariant2BudgetLedger(options.budgetLedgerFile,false);
    syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
    [realizationId,source]=allocateRealization(options);
    progress=initialProgress(options,preflight,realizationId,source);
    progress.runId=options.runId;
    progress.status='allocation-pending'; progress.phase='allocation-pending';
    writeProgress(progressPath,progress);
    nbiot.experiments.registerRealizationUse(options.registryFile, ...
        'stage-3-load-pilot',realizationId,source,'planned');
    progress.status='running'; progress.phase='allocated';
    writeProgress(progressPath,progress);
else
    progress=readJson(progressPath,'nbiot:experiments:LoadProbeResume');
    if isempty(progress.caseRecords)
        progress.caseRecords=emptyCaseRecord(); progress.caseRecords=progress.caseRecords([]);
    end
    if ~isfield(progress,'activeCase')||isempty(progress.activeCase)
        progress.activeCase=emptyActiveCase();
    end
    validateResumeState(progress,options,preflight,snapshotPath);
    progress.runId=options.runId;
    realizationId=double(progress.realizationId);
    ledger=nbiot.experiments.loadVariant2BudgetLedger(options.budgetLedgerFile,false);
    [progress,ledger]=settleInterruptedCase(progress,ledger,options,progressPath);
    syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
    progress.budgetElapsedSeconds=ledger.elapsedSeconds;
    progress.owner=ownerIdentity();
    writeProgress(progressPath,progress);
end

if ismember(progress.status,{'preliminary-completed','test-only-completed'})
    verifyCompletedRecords(progress,options,root,realizationId);
    ensureCompletedAssignment(options.registryFile,realizationId, ...
        char(string(progress.assignment.source)));
    report=makeReport(progress,plan);
    writeSummary(options.outputFolder,report);
    return
end

runId=options.runId;
clockRun=tic;
while ~isempty(progress.pendingCounts)
    count=progress.pendingCounts(1);
    ledger=nbiot.experiments.loadVariant2BudgetLedger(options.budgetLedgerFile,false);
    if ledger.elapsedSeconds>=ledger.budgetSeconds
        progress.status='budget-paused'; progress.phase='budget-paused';
        progress.budgetElapsedSeconds=ledger.elapsedSeconds;
        progress.updatedAtUtc=utcNow();
        writeProgress(progressPath,progress);
        break
    end
    if stopAfterCaseRequested(options,runId)
        progress.status='paused'; progress.phase='paused';
        progress.budgetElapsedSeconds=ledger.elapsedSeconds;
        progress.updatedAtUtc=utcNow();
        writeProgress(progressPath,progress);
        break
    end

    cfg=loadCaseConfig(count,realizationId,options);
    runtimeOptions=runtimeManifestOptions(options,root);
    identity=nbiot.experiments.runtimeManifest(cfg,runtimeOptions);
    if stopAfterCaseRequested(options,runId)
        progress.status='paused'; progress.phase='paused';
        progress.budgetElapsedSeconds=ledger.elapsedSeconds;
        progress.updatedAtUtc=utcNow();
        writeProgress(progressPath,progress);
        break
    end
    caseFolder=fullfile(options.outputFolder,sprintf('n%05d-id%04d',count,realizationId));
    startedAt=utcNow(); wallClock=tic;
    attemptId=char(java.util.UUID.randomUUID());
    active=struct('runId',runId,'attemptId',attemptId, ...
        'caseKey',identity.caseKey,'numUE',count, ...
        'startedAtUtc',startedAt,'lastProgressAtUtc',startedAt, ...
        'runFolder',options.runControlFolder);
    ledger=beginBudgetAttempt(ledger,active);
    ledger.activeCase=active;
    ledger.pendingCases=progress.pendingCounts;
    ledger.phaseTimes(end+1)=phaseRecord('stage-3-load-probe',startedAt,'',0,identity.caseKey);
    nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
    syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
    progress.status='running'; progress.phase=sprintf('load-%d-running',count);
    progress.activeCase=active; progress.owner=ownerIdentity();
    progress.updatedAtUtc=utcNow(); progress.currentTick=0;
    writeProgress(progressPath,progress);
    writeWorkerProgress(options.outputFolder,'case-start',0,'');

    try
        runner=[];
        if options.testMode, runner=options.runner; end
        runtime=struct('projectRoot',root,'execution',execution, ...
            'calibrationFile',options.calibrationFile);
        if options.testMode
            runtime.runnerFiles=options.runnerFiles;
            runtime.runnerInputs=options.runnerInputs;
            runtime.runnerDependenciesDeclared=options.runnerDependenciesDeclared;
            meta=nbiot.experiments.runStaticCase(cfg,caseFolder,identity,runner,runtime);
        else
            checkpoint=struct('intervalSeconds',600, ...
                'pauseRequestFile',fullfile(options.outputFolder,'pause.request'), ...
                'progressFile',fullfile(options.outputFolder,'worker-progress.json'), ...
                'budgetLedgerFile',options.budgetLedgerFile, ...
                'progressPhase',sprintf('load-%d',count));
            runtime.checkpoint=checkpoint;
            meta=nbiot.experiments.runStaticCase(cfg,caseFolder,identity,[],runtime);
        end
        wallSeconds=toc(wallClock);
        if strcmp(meta.status,'paused')
            progress.status='paused'; progress.phase='paused';
            progress.activeCase=active; progress.updatedAtUtc=utcNow();
            writeProgress(progressPath,progress);
            writeWorkerProgress(options.outputFolder,'paused',progress.currentTick,'');
            ledger=finishBudgetCase(ledger,active,wallSeconds,'paused');
            ledger.pendingCases=progress.pendingCounts;
            nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
            syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
            progress.budgetElapsedSeconds=ledger.elapsedSeconds;
            break
        end
        caseRecord=verifyAndMeasure(meta,identity,cfg,count,realizationId, ...
            wallSeconds,options,caseFolder);
        progress.caseRecords(end+1)=caseRecord;
        progress.completedCounts(end+1)=count;
        progress.pendingCounts=progress.pendingCounts(2:end);
        progress.activeCase=struct(); progress.updatedAtUtc=utcNow();
        progress.currentTick=5000; progress.phase=sprintf('load-%d-completed',count);
        writeCaseEvidence(options.outputFolder,caseRecord,meta,identity);
        ledger=finishBudgetCase(ledger,active,wallSeconds,'completed');
        ledger.pendingCases=progress.pendingCounts;
        nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
        syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
        progress.budgetElapsedSeconds=ledger.elapsedSeconds;
        saveProgressAndSummary(progressPath,options.outputFolder,progress,plan);
        writeWorkerProgress(options.outputFolder,progress.phase,5000,caseRecord.caseKey);
        if ledger.elapsedSeconds>=ledger.budgetSeconds
            alreadyRecorded=~isempty(ledger.warnings)&& ...
                any(contains(string({ledger.warnings.message}),identity.caseKey));
            if ~alreadyRecorded
                warningRecord=struct('timestampUtc',utcNow(),'phase','stage-3-load-probe', ...
                    'elapsedSeconds',ledger.elapsedSeconds, ...
                    'message',sprintf(['Budget threshold crossed during case %s; ' ...
                    'the completed case was retained and the next case was not started.'],identity.caseKey));
                ledger.warnings(end+1)=warningRecord;
                nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
                syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
            end
        end
        if ~isempty(progress.pendingCounts)&&stopAfterCaseRequested(options,runId)
            progress.status='paused'; progress.phase='paused';
            progress.updatedAtUtc=utcNow();
            writeWorkerProgress(options.outputFolder,'paused',5000,caseRecord.caseKey);
            saveProgressAndSummary(progressPath,options.outputFolder,progress,plan);
            break;
        end
    catch exception
        wallSeconds=toc(wallClock);
        ledger=finishBudgetCase(ledger,active,wallSeconds,'needs-attention');
        ledger.pendingCases=progress.pendingCounts;
        nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
        syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);
        progress.budgetElapsedSeconds=ledger.elapsedSeconds;
        failedRecord=emptyCaseRecord();
        failedRecord.numUE=count; failedRecord.realizationId=realizationId;
        failedRecord.status='failed'; failedRecord.wallSeconds=wallSeconds;
        failedRecord.caseFolder=caseFolder; failedRecord.caseKey=identity.caseKey;
        failedRecord.errorIdentifier=exception.identifier; failedRecord.error=exception.message;
        progress.caseRecords(end+1)=failedRecord;
        progress.status='needs-attention'; progress.phase='needs-attention';
        progress.activeCase=emptyActiveCase();
        progress.lastError=struct('identifier',exception.identifier,'message',exception.message, ...
            'caseKey',identity.caseKey,'stack',{exceptionStack(exception)}, ...
            'recordedAtUtc',utcNow());
        progress.updatedAtUtc=utcNow();
        saveProgressAndSummary(progressPath,options.outputFolder,progress,plan);
        break
    end
end

if isempty(progress.pendingCounts)&&numel(progress.completedCounts)==numel(plan.requestedCounts)
    progress.status=ternary(options.testMode,'test-only-completed','preliminary-completed');
    progress.phase=progress.status; progress.updatedAtUtc=utcNow();
    try
        ensureCompletedAssignment(options.registryFile,realizationId, ...
            char(string(progress.assignment.source)));
        progress.assignment.status='completed';
    catch exception
        progress.status='needs-attention'; progress.phase='needs-attention';
        progress.lastError=struct('identifier',exception.identifier,'message',exception.message, ...
            'recordedAtUtc',utcNow());
    end
elseif ~ismember(progress.status,{'budget-paused','paused','needs-attention'})
    progress.status='running'; progress.phase='awaiting-resume';
end
progress.owner=ownerIdentity(); progress.updatedAtUtc=utcNow();
progress.elapsedThisProcessSeconds=toc(clockRun);
writeProgress(progressPath,progress);
report=makeReport(progress,plan);
writeSummary(options.outputFolder,report);
end

function ledgerWriterLease=acquireBudgetLedgerWriterLease(ledgerPath)
lockPath=[char(ledgerPath) '.writer.lock'];
leaseFile=[]; channel=[];
try
    leaseFile=java.io.RandomAccessFile(lockPath,'rw');
    channel=leaseFile.getChannel();
    fileLock=channel.tryLock();
catch exception
    closeBudgetLedgerLeaseHandles(channel,leaseFile);
    leaseError=MException('nbiot:experiments:LoadProbeLedgerLease', ...
        'Could not acquire budget-ledger writer lease %s: %s',lockPath,exception.message);
    leaseError=addCause(leaseError,exception);
    throw(leaseError);
end
if isempty(fileLock)
    closeBudgetLedgerLeaseHandles(channel,leaseFile);
    error('nbiot:experiments:LoadProbeLedgerLease', ...
        'Budget-ledger writer lease is held by another process: %s',lockPath);
end
ledgerWriterLease=onCleanup(@() releaseBudgetLedgerWriterLease(fileLock,channel,leaseFile));
end

function releaseBudgetLedgerWriterLease(fileLock,channel,leaseFile)
cleanupMessage='';
try
    if fileLock.isValid(), fileLock.release(); end
catch exception
    cleanupMessage=exception.message;
end
try
    channel.close();
catch exception
    if isempty(cleanupMessage), cleanupMessage=exception.message; end
end
try
    leaseFile.close();
catch exception
    if isempty(cleanupMessage), cleanupMessage=exception.message; end
end
if ~isempty(cleanupMessage)
    warning('nbiot:experiments:LoadProbeLeaseCleanup', ...
        'Could not cleanly release the budget-ledger writer lease: %s',cleanupMessage);
end
end

function closeBudgetLedgerLeaseHandles(channel,leaseFile)
if ~isempty(channel)
    try, channel.close(); catch, end
end
if ~isempty(leaseFile)
    try, leaseFile.close(); catch, end
end
end

function options=loadProbeOptions(value,root)
defaults=struct('designOnly',false,'counts',[100 500 1000 2500], ...
    'outputFolder','','stage2AcceptanceFile',fullfile(root,'verification', ...
    'completion','stage-2','acceptance.json'),'calibrationFile', ...
    fullfile(root,'results','nprach-calibration.mat'),'registryFile', ...
    fullfile(root,'experiments','realizationRegistry.json'),'realizationId',[], ...
    'execution',struct('profile','scheduled-local','role','stage-3-load-pilot', ...
    'maxUE',2500,'maxCaseSeconds',57600,'maxSuiteSeconds',57600, ...
    'timePolicy','finish-current'),'resume',false,'budgetLedgerFile','', ...
    'testMode',false,'runner',[],'runnerFiles',{{}},'runnerInputs',struct(), ...
    'runnerDependenciesDeclared',false,'memoryRootFolder','', ...
    'runId','','runControlFolder','');
if ~isstruct(value)||~isscalar(value)
    error('nbiot:experiments:LoadProbeOptions','Options must be a scalar structure.');
end
names=fieldnames(value);
if ~all(ismember(names,fieldnames(defaults)))
    error('nbiot:experiments:LoadProbeOptions','Unknown load-probe option.');
end
for k=1:numel(names), defaults.(names{k})=value.(names{k}); end
options=defaults;
if ~isnumeric(options.counts)||~isreal(options.counts)|| ...
        ~isequal(double(options.counts(:).'),[100 500 1000 2500])
    error('nbiot:experiments:LoadProbeOptions', ...
        'Variant 2 accepts exactly the ordered counts [100 500 1000 2500].');
end
flags={'designOnly','resume','testMode','runnerDependenciesDeclared'};
for k=1:numel(flags)
    if ~islogical(options.(flags{k}))||~isscalar(options.(flags{k}))
        error('nbiot:experiments:LoadProbeOptions','%s must be a scalar logical.',flags{k});
    end
end
paths={'outputFolder','stage2AcceptanceFile','calibrationFile','registryFile', ...
    'budgetLedgerFile','runControlFolder'};
for k=1:numel(paths)
    if ~(ischar(options.(paths{k}))||(isstring(options.(paths{k}))&&isscalar(options.(paths{k}))))
        error('nbiot:experiments:LoadProbeOptions','%s must be a character vector or scalar string.',paths{k});
    end
    options.(paths{k})=char(options.(paths{k}));
end
if ~(ischar(options.memoryRootFolder)||(isstring(options.memoryRootFolder)&&isscalar(options.memoryRootFolder)))
    error('nbiot:experiments:LoadProbeOptions', ...
        'memoryRootFolder must be a character vector or scalar string.');
end
options.memoryRootFolder=char(options.memoryRootFolder);
if ~(ischar(options.runId)||(isstring(options.runId)&&isscalar(options.runId)))
    error('nbiot:experiments:LoadProbeOptions','runId must be a character vector or scalar string.');
end
options.runId=char(options.runId);
if isempty(options.memoryRootFolder), options.memoryRootFolder=options.outputFolder; end
if isempty(options.budgetLedgerFile)
    options.budgetLedgerFile=fullfile(root,'verification','completion', ...
        'stage-2','budget-ledger.json');
end
if ~isempty(options.realizationId)&&(~isnumeric(options.realizationId)|| ...
        ~isscalar(options.realizationId)||~isfinite(options.realizationId)|| ...
        options.realizationId~=fix(options.realizationId))
    error('nbiot:experiments:LoadProbeOptions','realizationId must be empty or one integer.');
end
end

function validateProbeMode(options)
if options.testMode
    if isempty(options.runner)||~options.runnerDependenciesDeclared||isempty(options.runnerFiles)
        error('nbiot:experiments:LoadProbeTestRunner', ...
            'Test mode requires a registered runner and its defining file.');
    end
        if isempty(options.outputFolder)||~insideTemp(options.outputFolder)|| ...
            ~insideTemp(options.registryFile)||isempty(options.budgetLedgerFile)|| ...
            ~insideTemp(options.budgetLedgerFile)||~insideTemp(options.memoryRootFolder)|| ...
            (~isempty(options.runControlFolder)&&~insideTemp(options.runControlFolder))
        error('nbiot:experiments:LoadProbeTestRunner', ...
            'Test mode output, registry and budget ledger must be isolated under tempdir.');
    end
elseif ~isempty(options.runner)||~isempty(options.runnerFiles)|| ...
        ~isempty(fieldnames(options.runnerInputs))||options.runnerDependenciesDeclared
    error('nbiot:experiments:LoadProbeTestRunner', ...
        'A custom runner is only accepted in isolated test mode.');
end
end

function [execution,acceptance,preflight]=validatePreflight(options,root,snapshotPath)
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=2500; cfg.simulation.durationTicks=5000;
execution=nbiot.experiments.validateExecutionBudget(cfg,options.execution,4);
execution=rmfield(execution,'numCases');
try
    nbiot.experiments.validateLoadProbeRuntime(version('-release'),ver('lte'), ...
        logical(license('test','LTE_Toolbox')));
catch exception
    rethrow(exception);
end
acceptance=verifyStage2AcceptanceForLoadProbe(options.stage2AcceptanceFile,root, ...
    options.calibrationFile,snapshotPath);
ledger=nbiot.experiments.loadVariant2BudgetLedger(options.budgetLedgerFile,false);
source=optimizationSourceManifest(root);
preflight=struct('status','passed','checkedAtUtc',utcNow(), ...
    'matlabVersion',version,'matlabRelease',version('-release'), ...
    'lteVersion',ver('lte'),'lteLicenseAvailable',true, ...
    'counts',[100 500 1000 2500],'durationTicks',5000,'burstDurationTicks',100, ...
    'policy','Static','execution',execution, ...
    'stage2AcceptanceFile',canonicalPath(options.stage2AcceptanceFile), ...
    'stage2AcceptanceSha256',fileHash(options.stage2AcceptanceFile), ...
    'calibrationFile',canonicalPath(options.calibrationFile), ...
    'calibrationSha256',fileHash(options.calibrationFile), ...
    'registrySnapshotFile',snapshotPath,'registrySnapshotSha256',fileHash(snapshotPath), ...
    'budgetLedgerFile',canonicalPath(options.budgetLedgerFile), ...
    'budgetElapsedSeconds',ledger.elapsedSeconds,'budgetSeconds',ledger.budgetSeconds, ...
    'sourceManifestSha256',source.sha256,'runnerSha256',fileHash(which('runLoadProbe')), ...
    'testMode',options.testMode,'acceptanceStatus',acceptance.status);
end

function [id,source]=allocateRealization(options)
available=nbiot.experiments.availableRealizationIds(options.registryFile, ...
    'stage-3-load-pilot',1000:3999);
available=available(available~=1064 & available>=1000);
if isempty(options.realizationId)
    if isempty(available), error('nbiot:experiments:LoadProbeIds','No fresh stage-3 ID is available.'); end
    id=available(1);
else
    id=double(options.realizationId);
    if id==1064||id<1000||id>3999||~ismember(id,available)
        error('nbiot:experiments:LoadProbeIds','Requested ID is reserved, forbidden or outside 1000:3999.');
    end
end
source=relativeToRoot(options.outputFolder,fileparts(fileparts(mfilename('fullpath'))));
end

function progress=initialProgress(options,preflight,id,source)
progress=struct('schemaVersion',1,'scope','variant2-preliminary-load-probe', ...
    'status','running','phase','allocated','startedAtUtc',utcNow(), ...
    'updatedAtUtc',utcNow(),'owner',ownerIdentity(),'runFolder',options.outputFolder, ...
    'requestedCounts',[100 500 1000 2500],'completedCounts',[], ...
    'pendingCounts',[100 500 1000 2500],'realizationId',id, ...
    'assignment',struct('role','stage-3-load-pilot','source',source,'status','planned'), ...
    'registrySnapshotSha256',preflight.registrySnapshotSha256, ...
    'stage2AcceptanceSha256',preflight.stage2AcceptanceSha256, ...
    'calibrationSha256',preflight.calibrationSha256, ...
    'sourceManifestSha256',preflight.sourceManifestSha256, ...
    'runnerSha256',preflight.runnerSha256,'testMode',options.testMode, ...
    'budgetElapsedSeconds',preflight.budgetElapsedSeconds, ...
    'caseRecords',emptyCaseRecord(),'activeCase',emptyActiveCase(), ...
    'currentTick',0,'lastCheckpoint','','lastError',struct());
progress.caseRecords=progress.caseRecords([]);
end

function validateResumeState(progress,options,preflight,snapshotPath)
required={'schemaVersion','scope','status','runFolder','requestedCounts','owner', ...
    'completedCounts','pendingCounts','realizationId','assignment', ...
    'registrySnapshotSha256','stage2AcceptanceSha256','calibrationSha256', ...
    'sourceManifestSha256','runnerSha256','testMode','caseRecords','activeCase'};
if ~isstruct(progress)||~isscalar(progress)||~all(isfield(progress,required))|| ...
        progress.schemaVersion~=1||~strcmp(progress.scope,'variant2-preliminary-load-probe')
    error('nbiot:experiments:LoadProbeResume','Progress manifest is malformed or unsupported.');
end
samePath=strcmpi(canonicalPath(progress.runFolder),canonicalPath(options.outputFolder));
same= samePath&&isequal(double(progress.requestedCounts(:).'),[100 500 1000 2500])&& ...
    strcmp(progress.registrySnapshotSha256,fileHash(snapshotPath))&& ...
    strcmp(progress.registrySnapshotSha256,preflight.registrySnapshotSha256)&& ...
    strcmp(progress.stage2AcceptanceSha256,preflight.stage2AcceptanceSha256)&& ...
    strcmp(progress.calibrationSha256,preflight.calibrationSha256)&& ...
    strcmp(progress.sourceManifestSha256,preflight.sourceManifestSha256)&& ...
    strcmp(progress.runnerSha256,preflight.runnerSha256)&&progress.testMode==options.testMode;
if ~same, error('nbiot:experiments:LoadProbeResume','Run inputs or project identity changed since the original launch.'); end
owner=progress.owner;
if isfield(owner,'processId')&&double(owner.processId)~=double(feature('getpid'))&& ...
        processIdentityAlive(owner)
    error('nbiot:experiments:LoadProbeOwner','The original worker is still alive; resume would duplicate the computation.');
end
if ~strcmp(char(string(progress.assignment.role)),'stage-3-load-pilot')|| ...
        ~strcmp(char(string(progress.assignment.source)),registryOwnSource( ...
        options.registryFile,double(progress.realizationId)))
    error('nbiot:experiments:LoadProbeResume','Registry assignment role/source differs from this run.');
end
validateRegistrySnapshotAndAssignment(snapshotPath,options.registryFile, ...
    double(progress.realizationId),char(string(progress.assignment.source)));
validCounts=[progress.completedCounts(:).' progress.pendingCounts(:).'];
if ~isequal(validCounts,[100 500 1000 2500])
    error('nbiot:experiments:LoadProbeResume','Completed/pending load list is inconsistent.');
end
end

function validateRegistrySnapshotAndAssignment(snapshotPath,registryPath,id,source)
snapshot=jsondecode(fileread(snapshotPath)); current=jsondecode(fileread(registryPath));
if ~all(isfield(current,{'validRange','roles','reservations','assignments'}))|| ...
        ~all(isfield(snapshot,{'validRange','roles','reservations','assignments'}))
    error('nbiot:experiments:LoadProbeResume','Registry schema is invalid.');
end
if ~isequaln(snapshot.validRange,current.validRange)||~isequaln(snapshot.roles,current.roles)|| ...
        ~isequaln(snapshot.reservations,current.reservations)
    error('nbiot:experiments:LoadProbeResume','Registry reservations changed after the run snapshot.');
end
assignments=current.assignments; own=[];
if ~isempty(assignments)
    for k=1:numel(assignments)
        if strcmp(char(string(assignments(k).role)),'stage-3-load-pilot')&& ...
                isequal(double(assignments(k).ids(:).'),id)&& ...
                strcmp(char(string(assignments(k).source)),source)
            own(end+1)=k; %#ok<AGROW>
        end
    end
end
if numel(own)~=1
    error('nbiot:experiments:LoadProbeResume','The assigned stage-3 ID is missing or duplicated.');
end
assignment=assignments(own);
if ~ismember(char(string(assignment.status)),{'planned','completed'})
    error('nbiot:experiments:LoadProbeResume','The stage-3 assignment has an incompatible status.');
end
assignments(own)=[];
if ~isequaln(normalizeAssignments(snapshot.assignments),normalizeAssignments(assignments))
    error('nbiot:experiments:LoadProbeResume','Unrelated registry assignments changed after the run snapshot.');
end
end

function value=normalizeAssignments(value)
if isempty(value), value=struct('role',{},'ids',{},'source',{},'status',{},'recovery',{}); return; end
for k=1:numel(value)
    if ~isfield(value,'recovery'), [value.recovery]=deal([]); end
    value(k).ids=double(value(k).ids(:).');
end
end

function source=registryOwnSource(path,id)
registry=jsondecode(fileread(path)); source='';
for k=1:numel(registry.assignments)
    a=registry.assignments(k);
    if strcmp(char(string(a.role)),'stage-3-load-pilot')&& ...
            isequal(double(a.ids(:).'),id)
        source=char(string(a.source)); return
    end
end
end

function ensureCompletedAssignment(path,id,source)
registry=jsondecode(fileread(path)); match=[];
for k=1:numel(registry.assignments)
    item=registry.assignments(k);
    if strcmp(char(string(item.role)),'stage-3-load-pilot')&& ...
            isequal(double(item.ids(:).'),double(id))&& ...
            strcmp(char(string(item.source)),source)
        match=k; break
    end
end
if isempty(match)
    error('nbiot:experiments:LoadProbeRegistry', ...
        'The reserved Stage 3 assignment disappeared before completion.');
end
status=char(string(registry.assignments(match).status));
if strcmp(status,'completed'), return; end
if ~strcmp(status,'planned')
    error('nbiot:experiments:LoadProbeRegistry', ...
        'The reserved Stage 3 assignment cannot be marked completed from status %s.',status);
end
nbiot.experiments.updateRealizationUseStatus(path,'stage-3-load-pilot',id,'completed');
end

function [progress,ledger]=settleInterruptedCase(progress,ledger,options,progressPath)
if ~isActiveCase(progress.activeCase)||~isfield(ledger,'activeCase')|| ...
        ~isActiveCase(ledger.activeCase)
    return
end
active=ledger.activeCase;
completed=[];
if ~isempty(progress.caseRecords)
    completed=find(strcmp({progress.caseRecords.caseKey},char(string(active.caseKey)))& ...
        strcmp({progress.caseRecords.status},'completed'),1,'last');
end
if ~isempty(completed)
    seconds=double(progress.caseRecords(completed).wallSeconds);
    attemptStatus='completed';
else
    seconds=0;
    attemptStatus='interrupted';
    workerProgress=fullfile(options.outputFolder,'worker-progress.json');
    if isfile(workerProgress)
        worker=readJson(workerProgress,'nbiot:experiments:LoadProbeResume');
        if isfield(worker,'updatedAtUtc')
            seconds=max(0,secondsBetween(char(string(active.startedAtUtc)), ...
                char(string(worker.updatedAtUtc))));
        end
    end
end
ledger=finishBudgetCase(ledger,active,seconds,attemptStatus);
ledger.pendingCases=progress.pendingCounts;
nbiot.experiments.saveVariant2BudgetLedger(options.budgetLedgerFile,ledger);
progress.activeCase=emptyActiveCase(); progress.updatedAtUtc=utcNow();
progress.recoveredElapsedSeconds=seconds;
writeProgress(progressPath,progress);
end

function record=verifyAndMeasure(meta,identity,cfg,count,id,wallSeconds,options,caseFolder)
if ~strcmp(meta.status,'completed')||~isfield(meta,'attemptFolder')
    error('nbiot:experiments:LoadProbeCase','The static case did not produce a completed attempt.');
end
verification=nbiot.results.verifyCase(meta.attemptFolder,identity);
if ~verification.passed
    error('nbiot:experiments:LoadProbeVerify','Case verification failed: %s',strjoin(verification.errors,'; '));
end
loaded=load(meta.resultFile,'result','kpiSummary');
if ~isfield(loaded,'result')||~isfield(loaded.result,'kpiSummary')
    error('nbiot:experiments:LoadProbeVerify','Saved case has no complete result/KPI summary.');
end
result=loaded.result; k=result.kpiSummary;
actualTicks=actualHorizon(result,cfg);
if actualTicks~=5000||~strcmp(result.status,'completed')
    error('nbiot:experiments:LoadProbeHorizon', ...
        'Load case must complete exactly 5000 ticks; observed %d.',actualTicks);
end
requireBalances(result,k);
if ~isfield(result,'radioDiagnostics')||~isstruct(result.radioDiagnostics)|| ...
        ~isfield(result,'groupKpi')||~istable(result.groupKpi)|| ...
        ~isfield(k,'service')||~isstruct(k.service)||~isfield(k.service,'available')|| ...
        ~isfield(k.service,'actualTick')||~isfield(k.service,'demandUeCount')|| ...
        ~isfield(k.service,'outageUeCount')||~isfield(k.service,'unfinishedUeCount')|| ...
        ~isfield(k.service,'probability')
    error('nbiot:experiments:LoadProbeExports', ...
        'Radio, service and group diagnostics are required for the load result.');
end
service=k.service; ue=result.ueSummary;
demand=ue.created>0; outage=demand&ue.delivered==0;
expectedProbability=NaN;
if sum(demand)>0, expectedProbability=sum(outage)/sum(demand); end
groupFields={'groupDimension','groupValue','ueCount','demandUeCount','outageUeCount', ...
    'created','delivered','dropped','unfinished','packetDeliveryProbability', ...
    'serviceOutageProbability','raStarted','raSuccess','raFailure','raUnfinished'};
if ~islogical(service.available)||~isscalar(service.available)||~service.available|| ...
        double(service.actualTick)~=5000||double(service.demandUeCount)~=sum(demand)|| ...
        double(service.outageUeCount)~=sum(outage)|| ...
        double(service.unfinishedUeCount)~=sum(ue.unfinished>0)|| ...
        ~isequaln(double(service.probability),expectedProbability)|| ...
        ~all(ismember(groupFields,result.groupKpi.Properties.VariableNames))
    error('nbiot:experiments:LoadProbeExports', ...
        'Service KPI horizon/counts or group table schema do not match the completed UE result.');
end
names=string({meta.files.name});
radio=names(endsWith(names,'_radio.csv'));
groups=names(endsWith(names,'_groups.csv'));
summary=names(endsWith(names,'_summary.csv'));
if numel(radio)~=1||numel(groups)~=1||numel(summary)~=1
    error('nbiot:experiments:LoadProbeExports','Radio, service-summary and group CSV exports are incomplete.');
end
summaryTable=readtable(fullfile(meta.attemptFolder,char(summary)));
if ~ismember('kpi_service_probability',summaryTable.Properties.VariableNames)|| ...
        ~ismember('kpi_service_available',summaryTable.Properties.VariableNames)
    error('nbiot:experiments:LoadProbeExports','Service KPI fields are missing from the summary export.');
end
record=emptyCaseRecord();
record.numUE=count; record.realizationId=id; record.status='completed';
record.caseKey=identity.caseKey; record.caseFolder=caseFolder;
record.attemptFolder=meta.attemptFolder; record.resultFile=meta.resultFile;
record.wallSeconds=wallSeconds; record.engineSeconds=engineSeconds(result,meta);
record.checkpointOverheadSeconds=checkpointMetric(meta,'checkpointOverheadSeconds',caseFolder);
record.checkpointBytes=checkpointMetric(meta,'checkpointBytes',caseFolder);
record.sampledMemoryPeakBytes=sampledMemoryPeak(options.memoryRootFolder,count);
record.outputBytes=sum([meta.files.bytes]); record.actualTicks=actualTicks;
record.created=k.created; record.delivered=k.delivered; record.dropped=k.dropped;
record.unfinished=k.unfinished; record.raStarted=k.raStarted;
record.raSuccess=k.raSuccess; record.raFailed=k.raFailed;
record.raUnfinished=k.raUnfinished; record.serviceOutageProbability=k.service.probability;
record.caseSha256=hashJson(meta.files); record.configSha256=meta.configSha256;
record.sourceSha256=meta.sourceSha256; record.calibrationSha256=meta.calibrationSha256;
record.radioExport=char(radio); record.serviceExport=char(summary); record.groupExport=char(groups);
record.error=''; record.errorIdentifier='';
end

function requireBalances(result,k)
required={'created','delivered','dropped','unfinished','raStarted','raSuccess','raFailed','raUnfinished'};
if ~all(isfield(k,required))||k.created~=k.delivered+k.dropped+k.unfinished|| ...
        k.raStarted~=k.raSuccess+k.raFailed+k.raUnfinished
    error('nbiot:experiments:LoadProbeBalance','Saved packet or random-access counts do not balance.');
end
ue=result.ueSummary;
if sum(ue.created)~=k.created||sum(ue.delivered)~=k.delivered|| ...
        sum(ue.dropped)~=k.dropped||sum(ue.unfinished)~=k.unfinished|| ...
        sum(ue.raAttempts)~=k.raStarted||sum(ue.raSuccesses)~=k.raSuccess|| ...
        sum(ue.raFailures)~=k.raFailed||sum(ue.raUnfinished)~=k.raUnfinished
    error('nbiot:experiments:LoadProbeBalance','Per-UE packet or access totals disagree with the case summary.');
end
end

function cfg=loadCaseConfig(count,id,options)
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=count; cfg.simulation.durationTicks=5000;
cfg.simulation.realizationId=id; cfg.policy.name='Static';
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=100;
cfg=nbiot.experiments.loadCalibration(cfg,options.calibrationFile);
end

function runtime=runtimeManifestOptions(options,root)
runtime=struct('projectRoot',root,'calibrationFile',options.calibrationFile, ...
    'runner',[],'runnerFiles',{{}},'runnerInputs',struct(), ...
    'runnerDependenciesDeclared',false);
if options.testMode
    runtime.runner=options.runner; runtime.runnerFiles=options.runnerFiles;
    runtime.runnerInputs=options.runnerInputs;
    runtime.runnerDependenciesDeclared=options.runnerDependenciesDeclared;
end
end

function record=emptyCaseRecord()
record=struct('numUE',0,'realizationId',0,'status','','caseKey','','caseFolder','', ...
    'attemptFolder','','resultFile','','wallSeconds',0,'engineSeconds',NaN, ...
    'checkpointOverheadSeconds',NaN,'checkpointBytes',0,'sampledMemoryPeakBytes',NaN, ...
    'outputBytes',0,'actualTicks',0,'created',0,'delivered',0,'dropped',0, ...
    'unfinished',0,'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0, ...
    'serviceOutageProbability',NaN,'caseSha256','','configSha256','', ...
    'sourceSha256','','calibrationSha256','','radioExport','','serviceExport','', ...
    'groupExport','','errorIdentifier','','error','');
end

function active=emptyActiveCase()
active=struct('runId','','attemptId','','caseKey','','numUE',0, ...
    'startedAtUtc','','lastProgressAtUtc','','runFolder','');
end

function yes=isActiveCase(value)
yes=isstruct(value)&&isscalar(value)&&isfield(value,'caseKey')&& ...
    ~isempty(char(string(value.caseKey)));
end

function report=makeReport(progress,plan)
report=plan; report.status=progress.status; report.realizationId=progress.realizationId;
report.completedCounts=double(progress.completedCounts(:).');
report.perCaseMeasurements=progress.caseRecords;
report.runtimeHashes=struct('stage2AcceptanceSha256',progress.stage2AcceptanceSha256, ...
    'calibrationSha256',progress.calibrationSha256, ...
    'registrySnapshotSha256',progress.registrySnapshotSha256, ...
    'sourceManifestSha256',progress.sourceManifestSha256, ...
    'runnerSha256',progress.runnerSha256);
report.runFolder=progress.runFolder; report.testMode=progress.testMode;
report.pendingCounts=double(progress.pendingCounts(:).');
report.nextCount=[];
if ~isempty(report.pendingCounts), report.nextCount=report.pendingCounts(1); end
report.budgetElapsedSeconds=progress.budgetElapsedSeconds;
report.budgetSeconds=57600; report.owner=progress.owner;
report.fullPilotCompleted=false; report.missingFullPilotCounts=5000;
end

function saveProgressAndSummary(progressPath,folder,progress,plan)
writeProgress(progressPath,progress);
writeSummary(folder,makeReport(progress,plan));
end

function writeSummary(folder,report)
cases=report.perCaseMeasurements;
if isempty(cases), cases=emptyCaseRecord(); cases=cases([]); end
if isscalar(cases), caseTable=struct2table(cases,'AsArray',true);
else, caseTable=struct2table(cases); end
summary=report; summary.perCaseMeasurements=cases;
writeJsonAtomic(fullfile(folder,'load-probe.json'),summary);
temporary=fullfile(folder,['.load-probe-' char(java.util.UUID.randomUUID()) '.mat']);
cleanup=onCleanup(@() deleteIfPresent(temporary)); %#ok<NASGU>
save(temporary,'report','caseTable','-v7');
[ok,message]=movefile(temporary,fullfile(folder,'load-probe.mat'),'f');
if ~ok, error('nbiot:experiments:LoadProbeWrite','Cannot publish MAT summary: %s',message); end
temporaryCsv=fullfile(folder,['.load-probe-' char(java.util.UUID.randomUUID()) '.csv']);
cleanupCsv=onCleanup(@() deleteIfPresent(temporaryCsv)); %#ok<NASGU>
writetable(caseTable,temporaryCsv);
[ok,message]=movefile(temporaryCsv,fullfile(folder,'load-probe.csv'),'f');
if ~ok, error('nbiot:experiments:LoadProbeWrite','Cannot publish CSV summary: %s',message); end
end

function writeProgress(path,progress)
progress.updatedAtUtc=utcNow();
writeJsonAtomic(path,progress);
end

function writeJsonAtomic(path,value)
folder=fileparts(path);
if ~isfolder(folder), [ok,message]=mkdir(folder); if ~ok, error('nbiot:experiments:LoadProbeWrite','%s',message); end, end
temporary=[path '.' char(java.util.UUID.randomUUID()) '.tmp'];
cleanup=onCleanup(@() deleteIfPresent(temporary)); %#ok<NASGU>
bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:LoadProbeWrite','Cannot create temporary JSON.'); end
closeFile=onCleanup(@() fclose(fid)); %#ok<NASGU>
if fwrite(fid,bytes,'uint8')~=numel(bytes), error('nbiot:experiments:LoadProbeWrite','Could not write complete JSON.'); end
clear closeFile
[ok,message]=movefile(temporary,path,'f');
if ~ok, error('nbiot:experiments:LoadProbeWrite','Cannot publish JSON: %s',message); end
end

function value=readJson(path,id)
try, value=jsondecode(fileread(path));
catch exception, error(id,'Cannot read JSON %s: %s',path,exception.message); end
end

function record=phaseRecord(phase,started,finished,seconds,key)
record=struct('phase',phase,'startedAtUtc',started,'finishedAtUtc',finished, ...
    'elapsedSeconds',seconds,'caseKey',key);
end

function ledger=beginBudgetAttempt(ledger,active)
ledger.accountingVersion=2;
if ~isfield(ledger,'attempts')||isempty(ledger.attempts)
    ledger.attempts=emptyBudgetAttempts();
end
if any(strcmp({ledger.attempts.attemptId},char(string(active.attemptId))))
    error('nbiot:experiments:LoadProbeAttempt','Attempt UUID already exists in the budget ledger.');
end
attempt=struct('attemptId',char(string(active.attemptId)), ...
    'runId',char(string(active.runId)),'caseKey',char(string(active.caseKey)), ...
    'startedAtUtc',char(string(active.startedAtUtc)),'finishedAtUtc','', ...
    'status','active','observedSeconds',0,'chargedSeconds',0, ...
    'processReportSha256','');
ledger.attempts(end+1)=attempt;
end

function attempts=emptyBudgetAttempts()
attempts=struct('attemptId',{},'runId',{},'caseKey',{},'startedAtUtc',{}, ...
    'finishedAtUtc',{},'status',{},'observedSeconds',{},'chargedSeconds',{}, ...
    'processReportSha256',{});
end

function ledger=finishBudgetCase(ledger,active,seconds,status)
seconds=double(seconds);
delta=seconds;
hasAttempt=isfield(active,'attemptId')&&~isempty(char(string(active.attemptId)));
if hasAttempt
    if ~isfield(ledger,'attempts')||isempty(ledger.attempts)
        error('nbiot:experiments:LoadProbeAttempt', ...
            'The budget ledger has no row for the active case attempt.');
    end
    matches=find(strcmp({ledger.attempts.attemptId},char(string(active.attemptId))));
    if numel(matches)~=1
        error('nbiot:experiments:LoadProbeAttempt', ...
            'The active case attempt is missing or duplicated in the budget ledger.');
    end
    index=matches(1); attempt=ledger.attempts(index);
    chargedSeconds=double(attempt.chargedSeconds);
    delta=max(0,seconds-chargedSeconds);
    attempt.observedSeconds=max(double(attempt.observedSeconds),seconds);
    attempt.chargedSeconds=max(chargedSeconds,seconds);
    attempt.finishedAtUtc=utcNow(); attempt.status=status;
    ledger.attempts(index)=attempt;
end
ledger.elapsedSeconds=ledger.elapsedSeconds+delta;
ledger=closeBudgetPhase(ledger,char(string(active.caseKey)),utcNow(),seconds);
ledger.activeCase=emptyActiveCase();
ledger.pendingCases=[]; ledger.lastCaseStatus=status;
end

function ledger=closeBudgetPhase(ledger,key,finished,seconds)
index=[];
if ~isempty(ledger.phaseTimes)
    keys={ledger.phaseTimes.caseKey};
    open=cellfun(@isempty,{ledger.phaseTimes.finishedAtUtc});
    index=find(open&strcmp(keys,key),1,'last');
end
if isempty(index)
    ledger.phaseTimes(end+1)=phaseRecord('stage-3-load-probe',utcNow(), ...
        finished,seconds,key);
else
    ledger.phaseTimes(index).finishedAtUtc=finished;
    ledger.phaseTimes(index).elapsedSeconds=seconds;
end
end

function writeCaseEvidence(folder,record,meta,identity)
evidence=struct('record',record,'caseKey',identity.caseKey,'runtimeIdentity',identity, ...
    'completionMarker',jsondecode(fileread(fullfile(meta.attemptFolder,'case-complete.json'))), ...
    'verification','passed','recordedAtUtc',utcNow());
writeJsonAtomic(fullfile(folder,sprintf('case-n%05d-evidence.json',record.numUE)),evidence);
end

function actual=actualHorizon(result,cfg)
actual=NaN;
if isfield(result,'actualTick')&&isnumeric(result.actualTick)&&isscalar(result.actualTick)
    actual=double(result.actualTick);
elseif isfield(result,'kpiSummary')&&isfield(result.kpiSummary,'durationSeconds')
    actual=round(double(result.kpiSummary.durationSeconds)/cfg.simulation.tickSeconds);
end
end

function seconds=engineSeconds(result,meta)
seconds=NaN;
if isfield(result,'profiling')&&isfield(result.profiling,'elapsedSeconds')
    seconds=double(result.profiling.elapsedSeconds);
elseif isfield(meta,'elapsedSeconds'), seconds=double(meta.elapsedSeconds); end
end

function value=checkpointMetric(meta,name,caseFolder)
value=NaN;
if isfield(meta,'checkpoint')&&isfield(meta.checkpoint,name)
    value=double(meta.checkpoint.(name)); return
end
if strcmp(name,'checkpointBytes')
    checkpointFolders=dir(fullfile(caseFolder,'.checkpoint-*'));
    bytes=0;
    for k=1:numel(checkpointFolders)
        if checkpointFolders(k).isdir
            checkpoints=dir(fullfile(caseFolder,checkpointFolders(k).name, ...
                'checkpoint-tick-*.mat'));
            bytes=bytes+sum([checkpoints.bytes]);
        end
    end
    value=bytes;
end
end

function value=sampledMemoryPeak(folder,count)
value=NaN;
paths={fullfile(folder,'memory.csv'),fullfile(folder,'memory-samples.csv')};
workerFolders=dir(fullfile(folder,'workers','*'));
for k=1:numel(workerFolders)
    if workerFolders(k).isdir
        paths{end+1}=fullfile(folder,'workers',workerFolders(k).name,'memory.csv'); %#ok<AGROW>
    end
end
best=NaN;
for k=1:numel(paths)
    if ~isfile(paths{k}), continue; end
    try
        samples=readtable(paths{k});
        names=samples.Properties.VariableNames;
        column=find(strcmpi(names,'treeWorkingSetBytes'),1);
        if isempty(column), column=find(strcmpi(names,'workingSetBytes'),1); end
        if isempty(column)||height(samples)==0, continue; end
        phaseColumn=find(strcmpi(names,'phase'),1);
        if ~isempty(phaseColumn)
            phases=string(samples{:,phaseColumn});
            samples=samples(contains(phases,sprintf('load-%d-',count)),:);
        end
        if height(samples)>0
            sampled=max(double(samples{:,column}),[],'omitnan');
            if isnan(best)||sampled>best, best=sampled; end
        end
    catch
    end
end
value=best;
end

function writeWorkerProgress(folder,phase,tick,lastCheckpoint)
path=fullfile(folder,'worker-progress.json');
writeJsonAtomic(path,struct('phase',phase,'currentTick',tick, ...
    'lastCheckpoint',lastCheckpoint,'updatedAtUtc',utcNow()));
end

function requested=stopAfterCaseRequested(options,runId)
requested=false;
markerPath=fullfile(options.runControlFolder,'stop-after-case.request.json');
if ~isfile(markerPath), return; end
marker=readJson(markerPath,'nbiot:experiments:LoadProbeControl');
required={'schemaVersion','requestId','runId','action'};
if ~isstruct(marker)||~isscalar(marker)||~all(isfield(marker,required))|| ...
        double(marker.schemaVersion)~=1||isempty(char(string(marker.requestId)))|| ...
        ~strcmp(char(string(marker.action)),'stop-after-case')|| ...
        isempty(char(string(marker.runId)))
    error('nbiot:experiments:LoadProbeControl', ...
        'The stop-after-case marker is malformed or unsupported.');
end
requested=strcmp(char(string(marker.runId)),runId);
end

function syncBudgetLedgerSnapshot(outputFolder,sharedLedger)
if ~isfile(sharedLedger), return; end
destination=fullfile(fileparts(outputFolder),'budget-ledger.json');
temporary=[destination '.' char(java.util.UUID.randomUUID()) '.tmp'];
cleanup=onCleanup(@() deleteIfPresent(temporary)); %#ok<NASGU>
[ok,message]=copyfile(sharedLedger,temporary,'f');
if ~ok, error('nbiot:experiments:LoadProbeWrite','Cannot snapshot shared budget ledger: %s',message); end
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:experiments:LoadProbeWrite','Cannot publish budget ledger snapshot: %s',message); end
end

function owner=ownerIdentity()
owner=struct('processId',double(feature('getpid')),'matlabRelease',version('-release'), ...
    'startedAtUtc',utcNow(),'processStartTimeUtc','','commandLine','');
try
    handle=java.lang.ProcessHandle.of(int64(owner.processId));
    if handle.isPresent()
        info=handle.get().info();
        start=info.startInstant();
        if start.isPresent(), owner.processStartTimeUtc=char(string(start.get().toString())); end
        command=info.commandLine();
        if command.isPresent(), owner.commandLine=char(string(command.get())); end
    end
catch
end
end

function alive=processIdentityAlive(owner)
alive=false;
if ~isfield(owner,'processId'), return; end
try
    handle=java.lang.ProcessHandle.of(int64(owner.processId));
    if ~handle.isPresent(), return; end
    process=handle.get(); alive=process.isAlive();
    if alive&&isfield(owner,'processStartTimeUtc')&&~isempty(owner.processStartTimeUtc)
        current=char(string(process.info().startInstant().get().toString()));
        if ~strcmp(current,char(string(owner.processStartTimeUtc))), alive=false; end
    end
catch
    alive=double(owner.processId)~=double(feature('getpid'));
end
end

function verifyCompletedRecords(progress,options,root,id)
completed=progress.caseRecords(strcmp({progress.caseRecords.status},'completed'));
if numel(progress.completedCounts)~=numel(completed)|| ...
        ~isequal(double(progress.completedCounts(:).'),[100 500 1000 2500])
    error('nbiot:experiments:LoadProbeResume','Completed report does not contain all four ordered loads.');
end
for k=1:numel(completed)
    record=completed(k);
    if ~strcmp(record.status,'completed')||record.realizationId~=id
        error('nbiot:experiments:LoadProbeResume','A completed case record is inconsistent.');
    end
    cfg=loadCaseConfig(record.numUE,id,options);
    identity=nbiot.experiments.runtimeManifest(cfg,runtimeManifestOptions(options,root));
    verification=nbiot.results.verifyCase(record.attemptFolder,identity);
    marker=jsondecode(fileread(fullfile(record.attemptFolder,'case-complete.json')));
    if ~verification.passed||~strcmp(identity.caseKey,record.caseKey)|| ...
            ~strcmp(hashJson(marker.files),record.caseSha256)|| ...
            ~strcmp(record.configSha256,identity.configSha256)|| ...
            ~strcmp(record.sourceSha256,identity.sourceSha256)|| ...
            ~strcmp(record.calibrationSha256,identity.calibrationSha256)||record.actualTicks~=5000
        error('nbiot:experiments:LoadProbeResume','Completed case marker no longer verifies.');
    end
end
end

function output=prepareOutputFolder(path,root)
if isempty(path)
    path=fullfile(root,'verification','completion','stage-3', ...
        ['variant2-' char(datetime('now','Format','yyyyMMdd-HHmmss-SSS'))]);
end
output=char(java.io.File(path).getCanonicalPath());
if isfolder(output)
    content=dir(output); content=content(~ismember({content.name},{'.','..'}));
    if ~isempty(content), error('nbiot:experiments:LoadProbeOutput','A new run requires a new empty output folder.'); end
else
    [ok,message]=mkdir(output); if ~ok, error('nbiot:experiments:LoadProbeOutput','%s',message); end
end
end

function valid=insideTemp(path)
if isempty(path), valid=false; return; end
try
    root=char(java.io.File(tempdir).getCanonicalPath());
    value=char(java.io.File(path).getCanonicalPath());
    valid=startsWith(lower(value),lower([root filesep]));
catch
    valid=false;
end
end

function path=canonicalPath(path)
path=char(java.io.File(char(path)).getCanonicalPath());
end

function path=relativeToRoot(path,root)
path=canonicalPath(path); root=canonicalPath(root);
prefix=[root filesep];
if startsWith(lower(path),lower(prefix)), path=path(numel(prefix)+1:end); end
path=strrep(path,filesep,'/');
end

function seconds=secondsBetween(started,finished)
try
    a=datetime(started,'InputFormat','yyyy-MM-dd HH:mm:ss.SSS','TimeZone','UTC');
    b=datetime(finished,'InputFormat','yyyy-MM-dd HH:mm:ss.SSS','TimeZone','UTC');
    seconds=max(0,seconds(b-a));
catch
    seconds=0;
end
end

function value=hashJson(input)
bytes=unicode2native(jsonencode(input),'UTF-8');
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(bytes(:),'int8'));
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function value=fileHash(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:experiments:LoadProbeHash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8'); if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function value=utcNow()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS'));
end

function lines=exceptionStack(exception)
lines=cell(1,numel(exception.stack));
for k=1:numel(exception.stack)
    lines{k}=sprintf('%s:%d (%s)',exception.stack(k).file, ...
        exception.stack(k).line,exception.stack(k).name);
end
end

function deleteIfPresent(path)
if isfile(path), delete(path); end
end

function value=ternary(condition,a,b)
if condition, value=a; else, value=b; end
end
