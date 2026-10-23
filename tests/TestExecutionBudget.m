classdef TestExecutionBudget < matlab.unittest.TestCase
    methods (Test)
        function largeDirectLaunchIsRejected(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=5000;
            t.verifyError(@() nbiot.runExperiment(cfg), 'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.NBIoTSimulator(cfg), 'nbiot:experiments:ExecutionBudget');
        end
        function smallCaseIsAllowedAndUnknownProfileRejected(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=10;
            budget=nbiot.experiments.validateExecutionBudget(cfg);
            t.verifyEqual(budget.profile,'local-development');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('profile','unknown')), 'nbiot:experiments:ExecutionBudget');
        end
        function localLimitsCannotBeRaised(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('maxCaseSeconds',301)), 'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg,[],4), ...
                'nbiot:experiments:ExecutionBudget');
        end
        function enormousHorizonIsRejectedBeforeAllocation(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=2^24-1;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg), ...
                'nbiot:experiments:ExecutionBudget');
        end
        function externalBudgetMustBeDeclared(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=5000;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('profile','external-machine')), 'nbiot:experiments:ExecutionBudget');
            execution=struct('profile','external-machine','role','stage-3-load-pilot', ...
                'maxUE',5000,'maxCaseSeconds',50000,'maxSuiteSeconds',250000);
            budget=nbiot.experiments.validateExecutionBudget(cfg,execution,5);
            t.verifyEqual(budget.numCases,5);
        end
        function blockedRunnersHaveNoOutputSideEffects(t)
            folder=tempname; t.addTeardown(@() removeFolder(folder));
            opts=struct('outputFolder',folder,'calibrationFile','missing.mat');
            t.verifyError(@() runStaticSweep(opts),'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
            t.verifyError(@() runStaticSweepParallel(opts),'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
            t.verifyError(@() runLoadPilot(opts),'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
        end
        function directCaseRejectsBeforeCreatingStaging(t)
            cfg=nbiot.config.defaultConfig(); folder=tempname;
            t.addTeardown(@() removeFolder(folder));
            t.verifyError(@() nbiot.experiments.runStaticCase(cfg,folder), ...
                'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
        end
        function pendingParallelJobIsBlockedBeforePoolOrFolders(t)
            root=fileparts(fileparts(mfilename('fullpath'))); folder=tempname;
            t.addTeardown(@() removeFolder(folder));
            options=struct('counts',1,'burstDurations',100,'realizationIds',1065, ...
                'outputFolder',folder,'resume',false, ...
                'calibrationFile',fullfile(root,'results','nprach-calibration.mat'));
            t.verifyError(@() runStaticSweepParallel(options),'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
        end
        function expensiveOfflineDefaultsAreBlocked(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            folder=tempname; t.addTeardown(@() removeFolder(folder));
            % Invalid fit ID also makes the unguarded calibration fail immediately.
            t.verifyError(@() calibrateNprach(cfg,fullfile(folder,'cal.mat'), ...
                struct('fitRealizationId',-1)), 'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() validateCollisionCapture(struct('outputFolder',folder, ...
                'calibrationFile','missing.mat')), 'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(folder));
        end
        function directSteppingSharesCumulativeDeadline(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=2; cfg.traffic.kind='none';
            sim=nbiot.NBIoTSimulator(cfg,[],struct('maxCaseSeconds',1));
            sim.step(); pause(1.1);
            t.verifyError(@() sim.step(),'nbiot:experiments:ExecutionTimeout');
            r=sim.result(); t.verifyEqual(r.status,'stopped');
            t.verifyEqual(r.stopReason,'execution-budget');
        end
    end
end
function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
