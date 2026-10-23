classdef TestRuntimeProgress < matlab.unittest.TestCase
    methods (Test)
        function finalizationFailureRemainsVisible(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            u=struct('caseKey','fixture','currentTick',2,'lastCheckpoint','saved.mat');
            f=@()error('fixture:ResultFailure','controlled');
            t.verifyError(@()nbiot.experiments.finalizeCheckpointResult(f,p,u), ...
                'fixture:ResultFailure');
            v=jsondecode(fileread(p));
            t.verifyEqual(v.phase,'failed');
            t.verifyEqual(v.failedPhase,'result-finalizing');
            t.verifyEqual(v.errorIdentifier,'fixture:ResultFailure');
            t.verifyEqual(v.currentTick,2);
            t.verifyEqual(v.lastCheckpoint,'saved.mat');
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(v));
        end

        function callbackSeesFinalizingBeforeExecution(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            actual=nbiot.experiments.finalizeCheckpointResult(@observesProgress,p, ...
                struct('caseKey','ordered','currentTick',2));
            t.verifyEqual(actual,'observed');
            function value=observesProgress()
                progress=jsondecode(fileread(p));
                t.verifyEqual(progress.phase,'result-finalizing');
                t.verifyEqual(progress.status,'running');
                fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(progress));
                value='observed';
            end
        end

        function outputlessCallbackIsExecutedExactlyOnce(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            count=0;
            nbiot.experiments.finalizeCheckpointResult(@withoutOutput,p,struct('caseKey','no-output'));
            t.verifyEqual(count,1);
            function withoutOutput()
                count=count+1;
                progress=jsondecode(fileread(p));
                t.verifyEqual(progress.phase,'result-finalizing');
            end
        end

        function outputRequestPreservesOriginalCallbackException(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            count=0;
            t.verifyError(@requestResult,'fixture:OutputFailure');
            t.verifyEqual(count,1);
            progress=jsondecode(fileread(p));
            t.verifyEqual(progress.errorIdentifier,'fixture:OutputFailure');
            t.verifyEqual(progress.failedPhase,'result-finalizing');
            function requestResult()
                actual=nbiot.experiments.finalizeCheckpointResult(@withOutput,p,struct('caseKey','output-failure')); %#ok<NASGU>
            end
            function value=withOutput() %#ok<STOUT>
                count=count+1;
                progress=jsondecode(fileread(p));
                t.verifyEqual(progress.phase,'result-finalizing');
                error('fixture:OutputFailure','controlled output callback');
            end
        end

        function repeatedPublicationKeepsProgressAndPhaseClocks(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            u=struct('caseKey','clocks','phase','simulating','status','running', ...
                'currentTick',1,'lastCheckpoint','saved.mat','workUnitsDone',0,'workUnitsTotal',[]);
            wall=tic;
            first=nbiot.experiments.writeRuntimeProgress(p,u);
            pause(.02);
            repeated=nbiot.experiments.writeRuntimeProgress(p,u);
            t.verifyEqual(repeated.phaseStartedAtUtc,first.phaseStartedAtUtc);
            t.verifyEqual(repeated.lastProgressAtUtc,first.lastProgressAtUtc);
            t.verifyNotEqual(repeated.updatedAtUtc,first.updatedAtUtc);
            t.verifyGreaterThan(repeated.phaseElapsedSeconds.simulating,first.phaseElapsedSeconds.simulating);
            t.verifyEmpty(repeated.workUnitsTotal);
            pause(.02); u.currentTick=2;
            moved=nbiot.experiments.writeRuntimeProgress(p,u);
            t.verifyNotEqual(moved.lastProgressAtUtc,repeated.lastProgressAtUtc);
            t.verifyEqual(moved.phaseStartedAtUtc,repeated.phaseStartedAtUtc);
            pause(.02);
            changed=nbiot.experiments.writeRuntimeProgress(p,struct('phase','checkpointing'));
            t.verifyEqual(changed.currentTick,2);
            t.verifyNotEqual(changed.phaseStartedAtUtc,moved.phaseStartedAtUtc);
            pause(.02);
            same=nbiot.experiments.writeRuntimeProgress(p,struct('phase','checkpointing'));
            t.verifyEqual(same.phaseStartedAtUtc,changed.phaseStartedAtUtc);
            t.verifyEqual(same.lastProgressAtUtc,changed.lastProgressAtUtc);
            t.verifyEqual(same.schemaVersion,2);
            t.verifyLessThanOrEqual(sum(cell2mat(struct2cell(same.phaseElapsedSeconds))),toc(wall));
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(first));
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(repeated));
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(changed));
        end

        function onlyRealProgressChangesLastProgressClock(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            first=nbiot.experiments.writeRuntimeProgress(p,struct('caseKey','units','phase','simulating'));
            pause(.02);
            total=nbiot.experiments.writeRuntimeProgress(p,struct('workUnitsTotal',10));
            t.verifyEqual(total.lastProgressAtUtc,first.lastProgressAtUtc);
            pause(.02);
            done=nbiot.experiments.writeRuntimeProgress(p,struct('workUnitsDone',1));
            t.verifyNotEqual(done.lastProgressAtUtc,total.lastProgressAtUtc);
            pause(.02);
            checkpoint=nbiot.experiments.writeRuntimeProgress(p,struct('lastCheckpoint','new.mat'));
            t.verifyNotEqual(checkpoint.lastProgressAtUtc,done.lastProgressAtUtc);
            t.verifyEqual(checkpoint.phaseStartedAtUtc,first.phaseStartedAtUtc);
        end

        function newProcessSegmentDoesNotReuseOldElapsedTimes(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            % This isolated path has never been in the persistent map. Seed
            % a prior-process JSON directly; no dependency on clear/cache.
            old=struct('schemaVersion',2,'caseKey','segments','phase','simulating', ...
                'status','running','processSegmentId','prior-process-fixture', ...
                'phaseElapsedSeconds',struct('simulating',1234));
            fid=fopen(p,'w'); fprintf(fid,'%s',jsonencode(old)); fclose(fid);
            fresh=nbiot.experiments.writeRuntimeProgress(p,struct('caseKey','segments','phase','simulating'));
            t.verifyNotEqual(fresh.processSegmentId,old.processSegmentId);
            t.verifyEqual(fresh.previousProcessSegmentId,old.processSegmentId);
            t.verifyEqual(fresh.phaseElapsedSeconds.simulating,0);
        end

        function invalidPreviousJsonIsExplicitlyReplaced(t)
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            fid=fopen(p,'w'); fprintf(fid,'broken-json'); fclose(fid);
            actual=nbiot.experiments.writeRuntimeProgress(p,struct('caseKey','repair','phase','initializing'));
            t.verifyTrue(actual.previousProgressUnreadable);
            t.verifyTrue(actual.writeSucceeded);
            t.verifyEqual(jsondecode(fileread(p)).schemaVersion,2);
        end

        function writeFailureWarnsAndReturnsWithoutThrowing(t)
            p=tempname; mkdir(p); t.addTeardown(@()rmdir(p,'s'));
            actual=[];
            t.verifyWarning(@writeBlocked,'nbiot:experiments:ProgressWrite');
            t.verifyFalse(actual.writeSucceeded);
            function writeBlocked()
                actual=nbiot.experiments.writeRuntimeProgress(p,struct('caseKey','blocked','phase','simulating'));
            end
        end

        function noOpAndInstrumentationDoNotConsumeMatlabRng(t)
            original=rng;
            actual=nbiot.experiments.writeRuntimeProgress('', ...
                struct('caseKey','none','phase','initializing','phaseContext','load-500'));
            t.verifyEqual(rng,original);
            t.verifyEqual(actual.phase,'initializing');
            t.verifyEqual(actual.phaseContext,'load-500');
            t.verifyEmpty(actual.workUnitsTotal);
        end

        function canonicalPhasesHaveUniqueValidElapsedKeys(t)
            phases={'initializing','checkpoint-loading','checkpointing','simulating', ...
                'result-finalizing','exporting','verifying','paused','completed','failed'};
            p=[tempname '.json']; t.addTeardown(@()delete(p));
            keys=cellfun(@matlab.lang.makeValidName,phases,'UniformOutput',false);
            t.verifyEqual(numel(unique(keys)),numel(phases));
            for k=1:numel(phases)
                actual=nbiot.experiments.writeRuntimeProgress(p, ...
                    struct('caseKey','keys','phase',phases{k}));
                t.verifyEqual(actual.phase,phases{k});
                t.verifyTrue(isfield(actual.phaseElapsedSeconds,keys{k}));
            end
        end
    end
end
