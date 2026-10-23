classdef TestCheckpointedStaticCase < matlab.unittest.TestCase
    methods (Test)
        function resumesSameAttemptAndReturnsExistingCompletedMarker(t)
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@() removeFolder(folder)); %#ok<NASGU>
            [cfg,scenario,metadata,options]=staticCaseFixture(folder);
            caseFolder=fullfile(folder,'case');
            pauseFile=fullfile(folder,'pause.request');
            progressFile=fullfile(folder,'worker-progress.json');
            ledgerPath=fullfile(folder,'budget-ledger.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,true);
            ledger.elapsedSeconds=ledger.budgetSeconds-0.001;
            nbiot.experiments.saveVariant2BudgetLedger(ledgerPath,ledger);
            fclose(fopen(pauseFile,'w'));
            options.checkpoint.pauseRequestFile=pauseFile;
            options.checkpoint.progressFile=progressFile;
            options.checkpoint.budgetLedgerFile=ledgerPath;
            options.checkpoint.progressPhase='static-fixture';

            paused=nbiot.experiments.runStaticCase( ...
                cfg,caseFolder,metadata,[],options);
            t.verifyEqual(paused.status,'paused');
            pauseProgress=jsondecode(fileread(progressFile));
            t.verifyEqual(pauseProgress.phase,'paused');
            t.verifyEqual(pauseProgress.status,'paused');
            t.verifyTrue(isfile(fullfile(paused.checkpointFolder,'checkpoint-manifest.json')));
            t.verifyFalse(isfile(fullfile(paused.stagingFolder,'case-complete.json')));
            ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,false);
            t.verifyEqual(numel(ledger.warnings),1);
            [pauseState,checkpointInfo]=nbiot.experiments.loadCheckpoint( ...
                paused.checkpointFolder,metadata,options.execution);
            t.verifyEqual(pauseState.status,'partial');
            t.verifyTrue(isfield(checkpointInfo,'timing'));
            t.verifyEqual(checkpointInfo.timing.bytes,double(dir(checkpointInfo.checkpointPath).bytes));
            attemptId=paused.attemptId;
            delete(pauseFile);

            first=nbiot.experiments.runStaticCase( ...
                cfg,caseFolder,metadata,[],options);
            second=nbiot.experiments.runStaticCase( ...
                cfg,caseFolder,metadata,[],options);
            attempts=dir(fullfile(caseFolder,'run-*'));

            t.verifyEqual(first.status,'completed');
            t.verifyEqual(second.attemptFolder,first.attemptFolder);
            t.verifyEqual(first.attemptFolder,fullfile(caseFolder,['run-' attemptId]));
            t.verifyFalse(isfolder(fullfile(caseFolder,['.staging-' attemptId])));
            t.verifyEqual(numel(attempts),1);
            t.verifyTrue(nbiot.results.verifyCase(first.attemptFolder,metadata).passed);
            progress=jsondecode(fileread(progressFile));
            t.verifyEqual(progress.phase,'completed');
            t.verifyEqual(progress.currentTick,2);
            t.verifyNotEmpty(progress.lastCheckpoint);
            t.verifyEqual(progress.status,'completed');
            t.verifyEqual(progress.phaseContext,'static-fixture');
            t.verifyTrue(isfield(progress.phaseElapsedSeconds,'exporting'));
            t.verifyTrue(isfield(progress.phaseElapsedSeconds,'verifying'));
            t.verifyTrue(isfield(first.checkpoint,'checkpointTimings'));
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(pauseProgress));
            fprintf('RUNTIME_PROGRESS_SNAPSHOT %s\n',jsonencode(progress));
            ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,false);
            t.verifyEqual(numel(ledger.warnings),1);
        end

        function changedCheckpointIdentityIsRejectedWithoutNewAttempt(t)
            folder=tempname; mkdir(folder);
            cleanup=onCleanup(@() removeFolder(folder)); %#ok<NASGU>
            [cfg,scenario,metadata,options]=staticCaseFixture(folder);
            caseFolder=fullfile(folder,'case');
            attemptId='fedcba98-7654-3210-fedc-ba9876543210';
            mkdir(fullfile(caseFolder,['.staging-' attemptId]));
            checkpointFolder=fullfile(caseFolder,['.checkpoint-' attemptId]);
            changed=metadata; changed.calibrationSha256=repmat('0',1,64);
            sim=nbiot.NBIoTSimulator(cfg,scenario,options.execution);
            sim.run(0);
            nbiot.experiments.saveCheckpoint(sim,checkpointFolder,changed);

            t.verifyError(@() nbiot.experiments.runStaticCase( ...
                cfg,caseFolder,metadata,[],options), ...
                'nbiot:experiments:CheckpointIdentity');
            attempts=dir(fullfile(caseFolder,'run-*'));
            staging=dir(fullfile(caseFolder,'.staging-*'));
            t.verifyEmpty(attempts);
            t.verifyEqual(numel(staging),1);
            t.verifyEqual(staging(1).name,['.staging-' attemptId]);
        end
    end
end

function [cfg,scenario,metadata,options]=staticCaseFixture(folder)
root=fileparts(fileparts(mfilename('fullpath')));
calibrationFile=fullfile(folder,'calibration.mat'); writeCalibration(calibrationFile);
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=2;
cfg.cell.radiusM=20; cfg.cell.indoorFraction=0;
cfg.channel.shadowOutdoorDb=0; cfg.channel.shadowIndoorDb=0;
cfg.channel.cfoSigmaHz=0; cfg.channel.syncLimitSeconds=0;
cfg.traffic.kind='burst'; cfg.traffic.packetBytes=200;
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
cfg.policy.name='Static'; cfg.policy.windowTicks=500; cfg.dataset.windowTicks=500;
cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
scenario=nbiot.scenario.buildScenario(cfg);
options=struct('projectRoot',root,'calibrationFile',calibrationFile, ...
    'scenario',scenario,'execution',localDevelopment(), ...
    'checkpoint',struct('intervalSeconds',600));
metadata=nbiot.experiments.runtimeManifest(cfg,options);
end

function writeCalibration(path)
cfg=nbiot.config.defaultConfig();
profile=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId, ...
    'format',cfg.ra.format,'periodTicks',cfg.ra.periodTicks, ...
    'numSubcarriers',cfg.ra.numSubcarriers,'repetitions',cfg.ra.repetitions, ...
    'sampleRateHz',cfg.simulation.sampleRateHz, ...
    'fractionalFilterLength',cfg.channel.fractionalFilterLength, ...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(), ...
    'cfoLimitHz',cfg.channel.cfoLimitHz);
report=struct('accepted',true,'threshold',1,'profile',profile, ...
    'cfoGridHz',cfg.phy.nprachCfoGridHz);
save(path,'report');
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
