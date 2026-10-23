classdef TestCheckpointedExperimentRunner < matlab.unittest.TestCase
    methods (Test)
        function freshRunStartsWithCheckpointAndCompletes(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@() removeFolder(folder)); %#ok<NASGU>
            options=struct('folder',folder,'identity',identity, ...
                'intervalSeconds',600,'resume',false,'progressFile',fullfile(folder,'progress.json'), ...
                'progressPhase','fixture-context');

            [result,info]=nbiot.experiments.runCheckpointedExperiment( ...
                cfg,scenario,execution,struct(),options);

            t.verifyEqual(result.status,'completed');
            t.verifyEqual(info.status,'completed');
            t.verifyEqual(info.checkpointCount,1);
            t.verifyEqual(numel(info.checkpointPaths),1);
            t.verifyTrue(isfile(fullfile(folder,'checkpoint-manifest.json')));
            t.verifyEqual(info.resumeInfo.checkpointTick,0);
            t.verifyTrue(isfield(info,'phaseElapsedSeconds'));
            t.verifyTrue(isfield(info,'checkpointTimings'));
            progress=jsondecode(fileread(options.progressFile));
            t.verifyEqual(progress.phase,'exporting');
            t.verifyEqual(progress.status,'running');
            t.verifyEqual(progress.phaseContext,'fixture-context');
            t.verifyTrue(isfield(progress.phaseElapsedSeconds,'result_finalizing'));
        end

        function pauseKeepsPausedProgressAfterPartialResult(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            pausePath=fullfile(folder,'pause.request'); fclose(fopen(pausePath,'w'));
            progressPath=fullfile(folder,'progress.json');
            options=struct('folder',fullfile(folder,'checkpoints'),'identity',identity, ...
                'pauseRequestFile',pausePath,'progressFile',progressPath);
            [result,info]=nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options);
            t.verifyEqual(result.status,'partial');
            t.verifyEqual(info.status,'paused');
            progress=jsondecode(fileread(progressPath));
            t.verifyEqual(progress.phase,'paused'); t.verifyEqual(progress.status,'paused');
            t.verifyEqual(progress.currentTick,result.actualTick);
            t.verifyTrue(isfile(progress.lastCheckpoint));
        end

        function resumePenultimateTickDoesNotExportTerminalState(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(1);
            checkpoint=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            options=struct('folder',folder,'identity',identity,'resume',true,'progressFile',fullfile(folder,'progress.json'));
            [result,info]=nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options);
            t.verifyEqual(result.status,'completed'); t.verifyEqual(result.actualTick,2);
            t.verifyEqual(info.resumeInfo.checkpointTick,1);
            progress=jsondecode(fileread(options.progressFile));
            t.verifyEqual(progress.lastCheckpoint,checkpoint);
            t.verifyEqual(progress.phase,'exporting');
        end

        function failedInitialCheckpointKeepsPhaseAndOriginalError(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            blocked=fullfile(folder,'blocked'); fclose(fopen(blocked,'w'));
            progressPath=fullfile(folder,'progress.json');
            options=struct('folder',blocked,'identity',identity,'progressFile',progressPath);
            t.verifyError(@()nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options), ...
                'nbiot:experiments:CheckpointWrite');
            progress=jsondecode(fileread(progressPath));
            t.verifyEqual(progress.phase,'failed'); t.verifyEqual(progress.failedPhase,'checkpointing');
            t.verifyEqual(progress.errorIdentifier,'nbiot:experiments:CheckpointWrite');
        end

        function failedResumeKeepsLoadingPhaseAndLastKnownCheckpoint(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(1);
            checkpoint=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            progressPath=fullfile(folder,'progress.json');
            changed=identity; changed.sourceSha256=repmat('f',1,64);
            nbiot.experiments.writeRuntimeProgress(progressPath,struct('caseKey',changed.caseKey, ...
                'phase','paused','status','paused','currentTick',1,'lastCheckpoint',checkpoint));
            options=struct('folder',folder,'identity',changed,'resume',true,'progressFile',progressPath);
            t.verifyError(@()nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options), ...
                'nbiot:experiments:CheckpointIdentity');
            progress=jsondecode(fileread(progressPath));
            t.verifyEqual(progress.failedPhase,'checkpoint-loading');
            t.verifyEqual(progress.errorIdentifier,'nbiot:experiments:CheckpointIdentity');
            t.verifyEqual(progress.lastCheckpoint,checkpoint);
        end

        function periodicCheckpointsReturnR2TimingAndPublishedPath(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            options=struct('folder',folder,'identity',identity,'intervalSeconds',eps, ...
                'progressFile',fullfile(folder,'progress.json'));
            [~,info]=nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options);
            t.verifyGreaterThan(numel(info.checkpointTimings),1);
            progress=jsondecode(fileread(options.progressFile));
            t.verifyEqual(progress.lastCheckpoint,info.checkpointTimings(end).path);
            t.verifyTrue(isfile(progress.lastCheckpoint));
            t.verifyGreaterThan(info.checkpointTimings(end).timing.bytes,0);
            fprintf('RUNTIME_CHECKPOINT_TIMINGS %s\n',jsonencode(info.checkpointTimings));
        end

        function progressWriteFailureDoesNotInterruptScientificRun(t)
            [cfg,scenario,identity,execution]=runnerFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            previous=warning('off','nbiot:experiments:ProgressWrite');
            t.addTeardown(@()warning(previous));
            options=struct('folder',fullfile(folder,'checkpoints'),'identity',identity,'progressFile',folder);
            [result,info]=nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options);
            t.verifyEqual(result.status,'completed'); t.verifyEqual(info.status,'completed');
        end

        function scientificResultMatchesOrdinaryRunner(t)
            [cfg,scenario,identity,execution]=runnerFixture(500);
            folder=tempname; mkdir(folder); t.addTeardown(@()removeFolder(folder));
            options=struct('folder',folder,'identity',identity,'progressFile',fullfile(folder,'progress.json'));
            ordinary=nbiot.runExperiment(cfg,scenario,execution);
            [checkpointed,info]=nbiot.experiments.runCheckpointedExperiment(cfg,scenario,execution,struct(),options);
            t.verifyEqual(TestSimulationCheckpoint.scientificResult(checkpointed), ...
                TestSimulationCheckpoint.scientificResult(ordinary));
            t.verifyNotEmpty(info.checkpointTimings);
            fprintf('RUNTIME_SCIENTIFIC_EQUIVALENCE %d\n',isequaln( ...
                TestSimulationCheckpoint.scientificResult(checkpointed), ...
                TestSimulationCheckpoint.scientificResult(ordinary)));
        end
    end
end

function [cfg,scenario,identity,execution]=runnerFixture(durationTicks)
if nargin<1, durationTicks=2; end
root=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=durationTicks;
cfg.cell.radiusM=20; cfg.cell.indoorFraction=0;
cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0;
cfg.channel.cfoSigmaHz=0; cfg.channel.syncLimitSeconds=0;
cfg.traffic.kind='burst'; cfg.traffic.packetBytes=200;
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
cfg.policy.name='Static'; cfg.policy.windowTicks=500; cfg.dataset.windowTicks=500;
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(root,'results','nprach-calibration.mat'));
scenario=nbiot.scenario.buildScenario(cfg);
identity=nbiot.experiments.runtimeManifest(cfg,struct('scenario',scenario));
execution=localDevelopment();
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
