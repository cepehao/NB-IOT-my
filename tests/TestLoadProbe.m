classdef TestLoadProbe < matlab.unittest.TestCase
    methods (Test)
        function designOnlyExposesFourLoadsWithoutSideEffects(t)
            root=fileparts(fileparts(mfilename('fullpath')));
            registry=fullfile(root,'experiments','realizationRegistry.json');
            output=fullfile(tempdir,['load-probe-design-' char(java.util.UUID.randomUUID())]);
            before=fileHash(registry);

            plan=runLoadProbe(struct('designOnly',true,'outputFolder',output));

            t.verifyEqual(plan.scope,'variant2-preliminary-load-probe');
            t.verifyEqual(plan.requestedCounts,[100 500 1000 2500]);
            t.verifyFalse(plan.fullPilotCompleted);
            t.verifyEqual(plan.missingFullPilotCounts,5000);
            t.verifyEmpty(plan.realizationId);
            t.verifyFalse(isfolder(output));
            t.verifyEqual(fileHash(registry),before);
            t.verifyError(@() runLoadPilot(struct('designOnly',true, ...
                'counts',[100 500 1000 2500])), ...
                'nbiot:experiments:PilotOptions');
        end

        function rejectsAnyCountSetExceptVariantTwo(t)
            t.verifyError(@() runLoadProbe(struct('designOnly',true, ...
                'counts',[100 500 1000 2500 5000])), ...
                'nbiot:experiments:LoadProbeOptions');
            t.verifyError(@() runLoadProbe(struct('designOnly',true, ...
                'counts',[100 500])), ...
                'nbiot:experiments:LoadProbeOptions');
        end

        function missingStage2AcceptanceDoesNotReserveAnId(t)
            root=fileparts(fileparts(mfilename('fullpath')));
            fixture=makeFixture(t);
            output=fullfile(fixture.tempRoot,'missing-gate-run');
            options=fixture.options;
            options.outputFolder=output;
            options.stage2AcceptanceFile=fullfile(fixture.tempRoot,'missing-acceptance.json');
            options.realizationId=1200;
            before=fileHash(options.registryFile);

            t.verifyError(@() runLoadProbe(options), ...
                'nbiot:experiments:LoadProbeStage2Gate');

            t.verifyEqual(fileHash(options.registryFile),before);
            t.verifyTrue(isfile(fullfile(output,'preflight.json')));
            t.verifyFalse(isfile(fullfile(output,'progress.json')));
            lockPath=[options.budgetLedgerFile '.writer.lock'];
            t.verifyTrue(isfile(lockPath),'The run must create its shared-ledger lease before preflight.');
            t.verifyEqual(tryJavaFileChannelLock(lockPath),'acquired', ...
                'A preflight error must release the Java ledger lease.');
        end

        function absentLteLicenseIsRejectedBeforeExecution(t)
            t.verifyError(@() nbiot.experiments.validateLoadProbeRuntime( ...
                '2025b',struct('Name','LTE Toolbox'),false), ...
                'nbiot:experiments:LoadProbeLicense');
            t.verifyError(@() nbiot.experiments.validateLoadProbeRuntime( ...
                '2025a',struct('Name','LTE Toolbox'),true), ...
                'nbiot:experiments:LoadProbeRelease');
        end

        function forbiddenOrConflictingIdDoesNotChangeRegistry(t)
            fixture=makeFixture(t);
            options=fixture.options;
            options.realizationId=1064;
            before=fileHash(options.registryFile);

            t.verifyError(@() runLoadProbe(options), ...
                'nbiot:experiments:LoadProbeIds');

            t.verifyEqual(fileHash(options.registryFile),before);
            t.verifyFalse(isfile(fullfile(options.outputFolder,'progress.json')));
        end

        function exhaustedBudgetBeforeNextCaseLeavesItPending(t)
            fixture=makeFixture(t);
            ledger=nbiot.experiments.loadVariant2BudgetLedger(fixture.options.budgetLedgerFile,true);
            ledger.elapsedSeconds=ledger.budgetSeconds;
            nbiot.experiments.saveVariant2BudgetLedger(fixture.options.budgetLedgerFile,ledger);

            report=runLoadProbe(fixture.options);

            t.verifyEqual(report.status,'budget-paused');
            t.verifyEmpty(report.completedCounts);
            t.verifyFalse(report.fullPilotCompleted);
            t.verifyTrue(isfile(fullfile(fixture.tempRoot,'budget-ledger.json')));
            progress=jsondecode(fileread(fullfile(fixture.options.outputFolder,'progress.json')));
            t.verifyEqual(progress.pendingCounts(:).',[100 500 1000 2500]);
            t.verifyEqual(progress.assignment.status,'planned');
        end

        function writerLeaseCoversRunnerAndReleasesAfterReturn(t)
            fixture=makeFixture(t);
            lockPath=[fixture.options.budgetLedgerFile '.writer.lock'];
            outcomePath=fullfile(fixture.tempRoot,'runner-lease-outcome.txt');
            fixture.options.runner=leaseCheckingSyntheticRunner(lockPath,outcomePath);
            fixture.options.runnerInputs=struct('lockPath',lockPath, ...
                'outcomePath',outcomePath);

            report=runLoadProbe(fixture.options);

            t.verifyEqual(report.status,'test-only-completed',report.perCaseMeasurements(end).error);
            t.verifyTrue(isfile(lockPath),'The Java lease file must remain as the shared lock path.');
            outcome=fileread(outcomePath);
            t.verifyTrue(ismember(outcome,{'contended','overlapping'}), ...
                'runLoadProbe must hold its Java ledger lease while a case runner is active.');
            t.verifyEqual(tryJavaFileChannelLock(lockPath),'acquired', ...
                'The Java ledger lease must be released when runLoadProbe returns.');
        end

        function stopAfterCaseMarkerPausesBeforeNextAdmission(t)
            fixture=makeFixture(t);
            marker=fullfile(fixture.options.runControlFolder,'stop-after-case.request.json');
            [runner,counterPath]=stopAfterFirstSyntheticRunner( ...
                fixture.options.runControlFolder,fixture.options.runId);
            fixture.options.runner=runner;
            fixture.options.runnerInputs=struct('counterPath',counterPath, ...
                'folder',fixture.options.runControlFolder,'runId',fixture.options.runId);

            report=runLoadProbe(fixture.options);

            t.verifyEqual(report.status,'paused');
            t.verifyEqual(report.completedCounts,100);
            t.verifyEqual(report.pendingCounts,[500 1000 2500]);
            t.verifyEqual(str2double(strtrim(fileread(counterPath))),1, ...
                'No next case may be admitted after the marker is observed.');
            t.verifyEqual(caseFolderCount(fixture.options.outputFolder),1);
            t.verifyTrue(isfile(marker),'The stop-after-case marker remains until explicit resume.');
        end

        function stopAfterCaseMarkerBeforeFirstAdmissionPreservesAllCounts(t)
            fixture=makeFixture(t);
            marker=fullfile(fixture.options.runControlFolder,'stop-after-case.request.json');
            writeJson(marker,struct('schemaVersion',1,'requestId','fixture-stop-before-first', ...
                'runId',fixture.options.runId,'action','stop-after-case'));

            report=runLoadProbe(fixture.options);

            t.verifyEqual(report.status,'paused');
            t.verifyEmpty(report.completedCounts);
            t.verifyEqual(report.pendingCounts,[100 500 1000 2500]);
            t.verifyEqual(caseFolderCount(fixture.options.outputFolder),0, ...
                'A matching stop marker must be checked before the first case is created.');
            t.verifyTrue(isfile(marker));
        end

        function activeAttemptIsPublishedBeforeRunnerAndChargedOnce(t)
            fixture=makeFixture(t);
            progressPath=fullfile(fixture.options.outputFolder,'progress.json');
            ledgerPath=fixture.options.budgetLedgerFile;
            observationPath=fullfile(fixture.tempRoot,'active-attempt-observation.json');
            fixture.options.runner=attemptCheckingSyntheticRunner( ...
                progressPath,ledgerPath,observationPath);
            fixture.options.runnerInputs=struct('progressPath',progressPath, ...
                'ledgerPath',ledgerPath,'observationPath',observationPath);

            report=runLoadProbe(fixture.options);
            observation=jsondecode(fileread(observationPath));
            ledger=nbiot.experiments.loadVariant2BudgetLedger( ...
                fixture.options.budgetLedgerFile,false);

            t.verifyEqual(report.status,'test-only-completed');
            t.verifyEqual(observation.progressRunId,fixture.options.runId);
            t.verifyNotEmpty(observation.progressAttemptId);
            t.verifyEqual(observation.ledgerRunId,fixture.options.runId);
            t.verifyEqual(observation.ledgerAttemptId,observation.progressAttemptId);
            t.verifyTrue(observation.attemptRowPresent, ...
                'The active attempt row must be saved before runner dispatch.');
            t.verifyEqual(observation.attemptStatus,'active');
            t.verifyEqual(observation.chargedSeconds,0);
            t.verifyEqual(observation.attemptCaseKey,observation.progressCaseKey);
            t.verifyEqual(ledger.accountingVersion,2);
            t.verifyEqual(numel(ledger.attempts),4);
            attemptIds=string({ledger.attempts.attemptId});
            t.verifyEqual(numel(unique(attemptIds)),4);
            t.verifyEqual(string({ledger.attempts.runId}), ...
                repmat(string(fixture.options.runId),1,4));
            t.verifyEqual(string({ledger.attempts.status}),repmat("completed",1,4));
            for k=1:4
                t.verifyEqual(ledger.attempts(k).caseKey,report.perCaseMeasurements(k).caseKey);
                t.verifyEqual(ledger.attempts(k).observedSeconds, ...
                    report.perCaseMeasurements(k).wallSeconds);
                t.verifyEqual(ledger.attempts(k).chargedSeconds, ...
                    report.perCaseMeasurements(k).wallSeconds);
                t.verifyEmpty(ledger.attempts(k).processReportSha256);
            end
        end

        function legacyBudgetLedgerLoadsWithEmptyAttemptHistory(t)
            fixture=makeFixture(t);
            original=nbiot.experiments.loadVariant2BudgetLedger( ...
                fixture.options.budgetLedgerFile,false);
            legacy=rmfield(original,{'accountingVersion','attempts'});
            writeJson(fixture.options.budgetLedgerFile,legacy);

            loaded=nbiot.experiments.loadVariant2BudgetLedger( ...
                fixture.options.budgetLedgerFile,false);

            t.verifyEqual(loaded.schemaVersion,1);
            t.verifyEqual(loaded.budgetSeconds,57600);
            t.verifyEqual(loaded.accountingVersion,2);
            t.verifyEmpty(loaded.attempts);
            t.verifyEqual(loaded.elapsedSeconds,original.elapsedSeconds);
        end

        function refusesRunWhenAnotherWriterHoldsLedgerLease(t)
            % Тест использует .NET (System.IO) и семантику Windows — на других ОС пропускается.
            t.assumeTrue(ispc,'Requires Windows (.NET System.IO).');
            fixture=makeFixture(t);
            lockPath=[fixture.options.budgetLedgerFile '.writer.lock'];
            registryBefore=fileHash(fixture.options.registryFile);
            ledgerBefore=fileHash(fixture.options.budgetLedgerFile);
            holder=System.IO.FileStream(lockPath,System.IO.FileMode.OpenOrCreate, ...
                System.IO.FileAccess.ReadWrite,System.IO.FileShare.None);
            releaseHolder=onCleanup(@() holder.Dispose()); %#ok<NASGU>

            t.verifyError(@() runLoadProbe(fixture.options), ...
                'nbiot:experiments:LoadProbeLedgerLease');

            t.verifyFalse(isfolder(fixture.options.outputFolder), ...
                'Lease contention must fail before creating the run output folder.');
            t.verifyEqual(fileHash(fixture.options.registryFile),registryBefore);
            t.verifyEqual(fileHash(fixture.options.budgetLedgerFile),ledgerBefore);
        end

        function activeCaseCrossingBudgetFinishesAndDoesNotStartNext(t)
            fixture=makeFixture(t);
            fixture.options.runner=delayedSyntheticRunner(0.25);
            fixture.options.runnerInputs=struct('delaySeconds',0.25);
            ledger=nbiot.experiments.loadVariant2BudgetLedger(fixture.options.budgetLedgerFile,true);
            ledger.elapsedSeconds=ledger.budgetSeconds-0.01;
            nbiot.experiments.saveVariant2BudgetLedger(fixture.options.budgetLedgerFile,ledger);

            report=runLoadProbe(fixture.options);

            t.verifyEqual(report.status,'budget-paused',report.perCaseMeasurements(end).error);
            t.verifyEqual(report.completedCounts,100);
            t.verifyEqual(report.perCaseMeasurements(1).status,'completed');
            t.verifyGreaterThanOrEqual(report.perCaseMeasurements(1).wallSeconds,0.25);
            t.verifyFalse(report.fullPilotCompleted);
            ledger=nbiot.experiments.loadVariant2BudgetLedger(fixture.options.budgetLedgerFile,false);
            t.verifyGreaterThanOrEqual(ledger.elapsedSeconds,ledger.budgetSeconds);
            t.verifyEqual(numel(ledger.warnings),1);
            progress=jsondecode(fileread(fullfile(fixture.options.outputFolder,'progress.json')));
            t.verifyEqual(progress.pendingCounts(:).',[500 1000 2500]);
            t.verifyEqual(progress.assignment.status,'planned');
            existingCases=caseFolderCount(fixture.options.outputFolder);
            fixture.options.resume=true;
            resumed=runLoadProbe(fixture.options);
            t.verifyEqual(resumed.status,'budget-paused');
            t.verifyEqual(resumed.completedCounts,100);
            t.verifyEqual(caseFolderCount(fixture.options.outputFolder),existingCases);
        end

        function completedTestSeriesCanBeResumedWithoutDuplicateCases(t)
            fixture=makeFixture(t);
            report=runLoadProbe(fixture.options);
            t.verifyEqual(report.status,'test-only-completed',report.perCaseMeasurements(end).error);
            t.verifyEqual(report.completedCounts,[100 500 1000 2500]);
            t.verifyFalse(report.fullPilotCompleted);
            before=caseFolderCount(fixture.options.outputFolder);

            fixture.options.resume=true;
            resumed=runLoadProbe(fixture.options);

            t.verifyEqual(resumed.status,'test-only-completed');
            t.verifyEqual(resumed.completedCounts,[100 500 1000 2500]);
            t.verifyEqual(caseFolderCount(fixture.options.outputFolder),before);
            registry=jsondecode(fileread(fixture.options.registryFile));
            assignment=find(arrayfun(@(item) strcmp(item.role,'stage-3-load-pilot')&& ...
                isequal(double(item.ids(:).'),resumed.realizationId),registry.assignments),1);
            t.verifyNotEmpty(assignment);
            t.verifyEqual(registry.assignments(assignment).status,'completed');
        end

        function corruptedCheckpointOnResumeIsPreservedAsNeedsAttention(t)
            fixture=makeFixture(t);
            ledger=nbiot.experiments.loadVariant2BudgetLedger(fixture.options.budgetLedgerFile,true);
            ledger.elapsedSeconds=ledger.budgetSeconds;
            nbiot.experiments.saveVariant2BudgetLedger(fixture.options.budgetLedgerFile,ledger);
            report=runLoadProbe(fixture.options);
            t.verifyEqual(report.status,'budget-paused');

            % Switch this fixture to the native checkpoint path; the deliberately
            % malformed manifest must fail before any simulator step is run.
            progressPath=fullfile(fixture.options.outputFolder,'progress.json');
            progress=jsondecode(fileread(progressPath)); progress.testMode=false;
            writeJson(progressPath,progress);
            ledger=nbiot.experiments.loadVariant2BudgetLedger(fixture.options.budgetLedgerFile,false);
            ledger.elapsedSeconds=ledger.budgetSeconds-1;
            nbiot.experiments.saveVariant2BudgetLedger(fixture.options.budgetLedgerFile,ledger);
            caseFolder=fullfile(fixture.options.outputFolder,sprintf( ...
                'n%05d-id%04d',100,progress.realizationId));
            mkdir(caseFolder);
            mkdir(fullfile(caseFolder,'.staging-test-corrupt'));
            checkpointFolder=fullfile(caseFolder,'.checkpoint-test-corrupt');
            mkdir(checkpointFolder);
            writeJson(fullfile(checkpointFolder,'checkpoint-manifest.json'),struct('broken',true));
            fixture.options.testMode=false; fixture.options.runner=[];
            fixture.options.runnerFiles={}; fixture.options.runnerInputs=struct();
            fixture.options.runnerDependenciesDeclared=false; fixture.options.resume=true;

            resumed=runLoadProbe(fixture.options);

            t.verifyEqual(resumed.status,'needs-attention');
            t.verifyEmpty(resumed.completedCounts);
            t.verifyFalse(resumed.fullPilotCompleted);
            updated=jsondecode(fileread(progressPath));
            t.verifyEqual(updated.pendingCounts(:).',[100 500 1000 2500]);
            t.verifyEqual(updated.lastError.identifier,'nbiot:experiments:CheckpointFormat', ...
                updated.lastError.message);
            t.verifyTrue(isfile(fullfile(checkpointFolder,'checkpoint-manifest.json')));
        end
    end
end

function fixture=makeFixture(t)
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root); setupProject();
addpath(fullfile(root,'verification','completion','stage-2'));
token=char(java.util.UUID.randomUUID());
tempRoot=fullfile(tempdir,['load-probe-test-' token]); mkdir(tempRoot);
acceptanceFolder=fullfile(root,'verification','local',['load-probe-fixture-' token]);
mkdir(acceptanceFolder);
t.addTeardown(@() removeFolder(tempRoot));
t.addTeardown(@() removeFolder(acceptanceFolder));
registry=fullfile(tempRoot,'registry.json');
copyfile(fullfile(root,'experiments','realizationRegistry.json'),registry);
physical=fullfile(acceptanceFolder,'physical.mat');
targeted=fullfile(acceptanceFolder,'targeted.log');
fid=fopen(targeted,'w'); fwrite(fid,'fixture Stage 2 evidence','char'); fclose(fid);
source=optimizationSourceManifest(root);
report=struct('artifactSourceHashes',stage2ArtifactHashes(root), ...
    'registrySha256',fileHash(registry),'sourceManifest',struct('sha256',source.sha256), ...
    'calibrationSha256',fileHash(fullfile(root,'results','nprach-calibration.mat')));
report.receiverRevision=nbiot.phy.nprach.receiverRevision();
save(physical,'report');
acceptance=struct('schemaVersion',2,'status','accepted-for-stage-3', ...
    'humanReviewed',false,'technicalReview',struct('reviewer','fixture','notes','synthetic gate fixture'), ...
    'physicalReport',strrep(relativeToRoot(physical,root),filesep,'/'), ...
    'physicalReportSha256',fileHash(physical), ...
    'targetedLog',strrep(relativeToRoot(targeted,root),filesep,'/'), ...
    'targetedLogSha256',fileHash(targeted),'artifactSourceHashes',report.artifactSourceHashes, ...
    'registrySha256',report.registrySha256,'sourceManifestSha256',source.sha256, ...
    'calibrationSha256',report.calibrationSha256,'receiverRevision',report.receiverRevision, ...
    'acceptanceLogicSha256',fileHash(which('acceptStage2Evidence')), ...
    'artifactComparatorSha256',fileHash(which('stage2PhysicalArtifactsMatch')));
acceptancePath=fullfile(acceptanceFolder,'acceptance.json');
writeJson(acceptancePath,acceptance);
output=fullfile(tempRoot,'run');
budgetLedger=fullfile(tempRoot,'budget-ledger.json');
nbiot.experiments.loadVariant2BudgetLedger(budgetLedger,true);
runId=char(java.util.UUID.randomUUID());
options=struct('outputFolder',output,'stage2AcceptanceFile',acceptancePath, ...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'registryFile',registry,'budgetLedgerFile',budgetLedger, ...
    'runId',runId,'runControlFolder',tempRoot, ...
    'execution',struct('profile','scheduled-local','role','stage-3-load-pilot', ...
    'maxUE',2500,'maxCaseSeconds',57600,'maxSuiteSeconds',57600, ...
    'timePolicy','finish-current'),'testMode',true,'runner',@syntheticRunner, ...
    'runnerFiles',{{fullfile(root,'tests','TestLoadProbe.m')}}, ...
    'runnerInputs',struct(),'runnerDependenciesDeclared',true);
fixture=struct('root',root,'tempRoot',tempRoot,'acceptanceFolder',acceptanceFolder, ...
    'options',options);
end

function runner=delayedSyntheticRunner(delaySeconds)
runner=@run;
    function result=run(cfg)
        pause(delaySeconds);
        result=syntheticResult(cfg);
    end
end

function result=syntheticRunner(cfg)
result=syntheticResult(cfg);
end

function runner=leaseCheckingSyntheticRunner(lockPath,outcomePath)
runner=@run;
    function result=run(cfg)
        outcome=tryJavaFileChannelLock(lockPath);
        writeText(outcomePath,outcome);
        result=syntheticResult(cfg);
    end
end

function outcome=tryJavaFileChannelLock(lockPath)
file=java.io.RandomAccessFile(lockPath,'rw');
channel=file.getChannel();
cleanup=onCleanup(@() closeJavaLeaseProbe(channel,file)); %#ok<NASGU>
try
    lock=channel.tryLock();
catch exception
    details=[exception.identifier ' ' exception.message];
    if contains(details,'OverlappingFileLockException')
        outcome='overlapping';
        return
    end
    rethrow(exception);
end
if isempty(lock)
    outcome='contended';
else
    lock.release();
    outcome='acquired';
end
end

function closeJavaLeaseProbe(channel,file)
try, channel.close(); catch, end
try, file.close(); catch, end
end

function [runner,counterPath]=stopAfterFirstSyntheticRunner(folder,runId)
counterPath=fullfile(folder,'synthetic-runner-call-count.txt');
runner=@run;
    function result=run(cfg)
        calls=0;
        if isfile(counterPath)
            calls=str2double(strtrim(fileread(counterPath)));
        end
        calls=calls+1;
        writeText(counterPath,num2str(calls));
        result=syntheticResult(cfg);
        if calls==1
            writeJson(fullfile(folder,'stop-after-case.request.json'), ...
                struct('schemaVersion',1,'requestId',char(java.util.UUID.randomUUID()), ...
                'runId',runId,'action','stop-after-case'));
        end
    end
end

function runner=attemptCheckingSyntheticRunner(progressPath,ledgerPath,observationPath)
runner=@run;
    function result=run(cfg)
        progress=jsondecode(fileread(progressPath));
        ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,false);
        match=find(strcmp({ledger.attempts.attemptId},progress.activeCase.attemptId),1);
        observation=struct('progressRunId',progress.activeCase.runId, ...
            'progressAttemptId',progress.activeCase.attemptId, ...
            'progressCaseKey',progress.activeCase.caseKey, ...
            'ledgerRunId',ledger.activeCase.runId, ...
            'ledgerAttemptId',ledger.activeCase.attemptId, ...
            'attemptRowPresent',~isempty(match),'attemptStatus','', ...
            'chargedSeconds',0,'attemptCaseKey','');
        if ~isempty(match)
            observation.attemptStatus=ledger.attempts(match).status;
            observation.chargedSeconds=ledger.attempts(match).chargedSeconds;
            observation.attemptCaseKey=ledger.attempts(match).caseKey;
        end
        writeJson(observationPath,observation);
        result=syntheticResult(cfg);
    end
end

function result=syntheticResult(cfg)
n=cfg.simulation.numUE; zerosByUe=zeros(n,1); ids=(1:n).';
ue=table(ids,false(n,1),repmat("CE0",n,1),zerosByUe,zerosByUe, ...
    zerosByUe,zerosByUe,zerosByUe,zerosByUe,zerosByUe,zerosByUe, ...
    'VariableNames',{'ueId','indoor','coverageClass','created','delivered', ...
    'dropped','unfinished','raAttempts','raSuccesses','raFailures','raUnfinished'});
kpi=struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
    'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0, ...
    'durationSeconds',cfg.simulation.durationTicks*cfg.simulation.tickSeconds, ...
    'service',struct('available',true,'actualTick',5000, ...
    'demandUeCount',0,'outageUeCount',0,'unfinishedUeCount',0,'probability',NaN));
environment=struct('matlabVersion',version,'release',version('-release'), ...
    'lteVersion',ver('lte'),'computer',computer,'validatedInMatlab',false, ...
    'sourceProfile','static-v1');
emptyWindow=table(zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'windowId','startTick','endTick'});
emptyRows=table(zeros(0,1),zeros(0,1),'VariableNames',{'realizationId','windowId'});
group=table(strings(0,1),strings(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'groupDimension','groupValue','ueCount','demandUeCount', ...
    'outageUeCount','created','delivered','dropped','unfinished', ...
    'packetDeliveryProbability','serviceOutageProbability','raStarted', ...
    'raSuccess','raFailure','raUnfinished'});
result=struct('config',cfg,'status','completed','environment',environment, ...
    'actualTick',5000,'kpiSummary',kpi,'ueSummary',ue,'kpiTimeSeries',emptyWindow, ...
    'resourceUsage',table("cpu",0,'VariableNames',{'resource','units'}), ...
    'dataset',struct('observations',emptyRows,'targets',emptyRows, ...
    'manifest',table("test",1,'VariableNames',{'split','rows'})), ...
    'radioDiagnostics',struct(),'groupKpi',group, ...
    'profiling',struct('elapsedSeconds',0.001));
end

function count=caseFolderCount(folder)
listing=dir(fullfile(folder,'n*-id*'));
count=sum([listing.isdir]);
end

function path=relativeToRoot(path,root)
path=char(java.io.File(path).getCanonicalPath());
root=char(java.io.File(root).getCanonicalPath());
prefix=[root filesep];
if startsWith(lower(path),lower(prefix)), path=path(numel(prefix)+1:end); end
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end

function writeText(path,value)
fid=fopen(path,'w');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,value,'char');
end

function hex=fileHash(path)
fid=fopen(path,'rb'); bytes=fread(fid,Inf,'*uint8'); fclose(fid);
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(bytes(:),'int8'));
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
