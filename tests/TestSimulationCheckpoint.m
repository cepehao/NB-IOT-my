classdef TestSimulationCheckpoint < matlab.unittest.TestCase
    methods (Static)
        function [cfg,scenario,identity,execution]=fixture()
            [cfg,scenario,identity,execution]=checkpointFixture();
        end

        function value=scientificResult(value)
            value=scientificProjection(value);
        end

        function folder=processFolder()
            value=getenv('NB_IOT_CHECKPOINT_TEST_FOLDER');
            if isempty(value)||~java.io.File(value).isAbsolute()
                error('nbiot:test:CheckpointFolder','An absolute tempdir path is required.');
            end
            folder=char(java.io.File(value).getCanonicalPath());
            temporaryRoot=char(java.io.File(tempdir).getCanonicalPath());
            if ~startsWith(lower(folder),lower([temporaryRoot filesep]))
                error('nbiot:test:CheckpointFolder','Checkpoint process folder must be inside tempdir.');
            end
        end
    end
    methods (Test)
        function processFolderRejectsRelativeAndOutsideTempPaths(t)
            previous=getenv('NB_IOT_CHECKPOINT_TEST_FOLDER');
            t.addTeardown(@()setenv('NB_IOT_CHECKPOINT_TEST_FOLDER',previous));
            setenv('NB_IOT_CHECKPOINT_TEST_FOLDER','relative-checkpoint-folder');
            t.verifyError(@()TestSimulationCheckpoint.processFolder(),'nbiot:test:CheckpointFolder');
            root=fileparts(fileparts(mfilename('fullpath')));
            setenv('NB_IOT_CHECKPOINT_TEST_FOLDER',root);
            t.verifyError(@()TestSimulationCheckpoint.processFolder(),'nbiot:test:CheckpointFolder');
        end
        function checkpointRestoresAtWindowBoundaryWithoutNestedProcess(t)
            [cfg,scenario,identity,execution]=checkpointFixture();
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            direct=nbiot.NBIoTSimulator(cfg,scenario,execution);
            direct.run(); directResult=direct.result();
            t.verifyTrue(any([directResult.truthLog.tick]<500));
            t.verifyTrue(any([directResult.truthLog.tick]>500));
            t.verifyEqual(sum(directResult.dataset.observations.endTick==500),1);
            t.verifyGreaterThan(directResult.kpiSummary.delivered,0);
            split=nbiot.NBIoTSimulator(cfg,scenario,execution);
            split.run(499); state=split.exportCheckpointState(); partial=split.result();
            t.verifyEqual(state.currentTick,499);
            t.verifyEqual(state.nextTick,500);
            t.verifyGreaterThan(state.receiveQueue.count(),0);
            t.verifyGreaterThanOrEqual(state.receiveQueue.nextTick(),state.nextTick);
            t.verifyLessThanOrEqual(state.receiveQueue.nextTick()-state.nextTick,25);
            t.verifyTrue(any(strcmp({partial.observedLog.kind},'phy_decode')));
            checkpointPath=nbiot.experiments.saveCheckpoint(split,checkpointFolder,identity);
            [resumed,info]=nbiot.experiments.loadCheckpoint(checkpointFolder,identity,execution);
            resumed.run();
            t.verifyEqual(info.checkpointTick,499);
            t.verifyFalse(info.fallbackUsed);
            t.verifyTrue(info.graphLinksValidated);
            t.verifyEqual(scientificProjection(resumed.result()),scientificProjection(directResult));
            t.verifyTrue(isfile(checkpointPath));
        end
        function corruptNewestCheckpointFallsBackAndRecordsLostTicks(t)
            [cfg,scenario,identity,execution]=checkpointFixture(); %#ok<ASGLU>
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution);
            sim.run(99); first=nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            sim.run(199); nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            sim.run(299); nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            manifest=jsondecode(fileread(fullfile(checkpointFolder,'checkpoint-manifest.json')));
            t.verifyEqual(numel(manifest.checkpoints),2);
            t.verifyFalse(isfile(first));
            newest=manifest.checkpoints(end);
            newestPath=fullfile(checkpointFolder,newest.file);
            fid=fopen(newestPath,'w'); fwrite(fid,uint8('corrupt-checkpoint'),'uint8'); fclose(fid);

            [restored,info]=nbiot.experiments.loadCheckpoint( ...
                checkpointFolder,identity,execution);

            t.verifyEqual(restored.currentTick,199);
            t.verifyTrue(info.fallbackUsed);
            t.verifyEqual(info.newestCheckpointTick,299);
            t.verifyEqual(info.lostTicks,100);
            t.verifyTrue(isfile(fullfile(checkpointFolder,'checkpoint-recovery.json')));
            recovery=jsondecode(fileread(fullfile(checkpointFolder,'checkpoint-recovery.json')));
            t.verifyEqual(recovery.lostTicks,100);
            t.verifyEqual(recovery.usedTick,199);
        end

        function changedCalibrationIdentityIsRejected(t)
            [cfg,scenario,identity,execution]=checkpointFixture(); %#ok<ASGLU>
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            changed=identity; changed.calibrationSha256=repmat('0',1,64);

            t.verifyError(@() nbiot.experiments.loadCheckpoint( ...
                checkpointFolder,changed,execution), ...
                'nbiot:experiments:CheckpointIdentity');
        end

        function changedSourceIdentityIsRejected(t)
            [cfg,scenario,identity,execution]=checkpointFixture(); %#ok<ASGLU>
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            changed=identity; changed.sourceSha256=repmat('f',1,64);

            t.verifyError(@() nbiot.experiments.loadCheckpoint( ...
                checkpointFolder,changed,execution), ...
                'nbiot:experiments:CheckpointIdentity');
        end

        function changedConfigIdentityIsRejected(t)
            [cfg,scenario,identity,execution]=checkpointFixture();
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            changed=identity; changed.configSha256=repmat('0',1,64);
            t.verifyError(@()nbiot.experiments.loadCheckpoint(checkpointFolder,changed,execution), ...
                'nbiot:experiments:CheckpointIdentity');
        end

        function bothCorruptCheckpointsAreRejected(t)
            [cfg,scenario,identity,execution]=checkpointFixture();
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution);
            sim.run(99); first=nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            sim.run(199); second=nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            for path={first,second}
                fid=fopen(path{1},'wb'); fwrite(fid,uint8('corrupt'),'uint8'); fclose(fid);
            end
            t.verifyError(@()nbiot.experiments.loadCheckpoint(checkpointFolder,identity,execution), ...
                'nbiot:experiments:CheckpointCorrupt');
        end

        function failedManifestReplacementKeepsPreviousCheckpoint(t)
            [cfg,scenario,identity,execution]=checkpointFixture(); %#ok<ASGLU>
            checkpointFolder=tempname; mkdir(checkpointFolder);
            cleanup=onCleanup(@() removeFolder(checkpointFolder)); %#ok<NASGU>
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            nbiot.experiments.saveCheckpoint(sim,checkpointFolder,identity);
            manifestPath=fullfile(checkpointFolder,'checkpoint-manifest.json');
            previousManifest=fileread(manifestPath);
            previousSha=nbiot.ml.fileSha256(manifestPath);
            sim.run(199);
            lock=System.IO.FileStream(manifestPath,System.IO.FileMode.Open, ...
                System.IO.FileAccess.Read,System.IO.FileShare.Read);
            releaseLock=onCleanup(@() lock.Dispose()); %#ok<NASGU>

            t.verifyError(@() nbiot.experiments.saveCheckpoint( ...
                sim,checkpointFolder,identity), ...
                'nbiot:experiments:CheckpointWrite');
            clear releaseLock
            t.verifyEqual(fileread(manifestPath),previousManifest);
            t.verifyEqual(nbiot.ml.fileSha256(manifestPath),previousSha);
            files=dir(fullfile(checkpointFolder,'checkpoint-tick-*.mat'));
            t.verifyEqual(numel(files),1);
            [restored,info]=nbiot.experiments.loadCheckpoint( ...
                checkpointFolder,identity,execution);
            t.verifyEqual(restored.currentTick,99);
            t.verifyFalse(info.fallbackUsed);
        end
    end
end

function [cfg,scenario,identity,execution]=checkpointFixture()
root=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=1500;
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

function value=scientificProjection(value)
value.profiling.elapsedSeconds=0;
runtimeOnly={'simulation_started','simulation_resumed', ...
    'checkpoint_saved','checkpoint_restored'};
value.lifecycleLog=value.lifecycleLog( ...
    ~ismember({value.lifecycleLog.kind},runtimeOnly));
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
