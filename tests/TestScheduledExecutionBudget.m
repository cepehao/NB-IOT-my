classdef TestScheduledExecutionBudget < matlab.unittest.TestCase
    methods (Test)
        function explicitLoadProbeBudgetAllowsFinishCurrent(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=2500;

            budget=nbiot.experiments.validateExecutionBudget( ...
                cfg,probeExecution(),4);

            t.verifyEqual(budget.profile,'scheduled-local');
            t.verifyEqual(budget.role,'stage-3-load-pilot');
            t.verifyEqual(budget.timePolicy,'finish-current');
            t.verifyEqual(budget.numCases,4);
        end

        function explicitStageTwoBudgetIsAccepted(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=10;

            budget=nbiot.experiments.validateExecutionBudget( ...
                cfg,stageTwoExecution(),232);

            t.verifyEqual(budget.role,'stage-2-collision-diagnostics');
            t.verifyEqual(budget.maxCaseSeconds,120);
            t.verifyEqual(budget.maxSuiteSeconds,57600);
        end

        function stageTwoRoleCannotBorrowLoadProbeDeviceLimit(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=11;
            execution=stageTwoExecution(); execution.maxUE=2500;

            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,execution,1),'nbiot:experiments:ExecutionBudget');
        end

        function scheduledScopeRejectsLargeDefaultAndParallelCalls(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=5000;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,probeExecution(),4),'nbiot:experiments:ExecutionBudget');

            cfg.simulation.numUE=2500;
            parallel=probeExecution(); parallel.parallel=true;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,parallel,4),'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,struct(),4),'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.NBIoTSimulator(cfg), ...
                'nbiot:experiments:ExecutionBudget');

            cfg.simulation.durationTicks=5001;
            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,probeExecution(),4),'nbiot:experiments:ExecutionBudget');
        end

        function ordinaryDevelopmentLimitsRemainHardStop(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=10;
            local=nbiot.experiments.validateExecutionBudget(cfg);
            t.verifyEqual(local.profile,'local-development');
            t.verifyEqual(local.timePolicy,'hard-stop');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('maxCaseSeconds',301)), ...
                'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('maxSuiteSeconds',901)), ...
                'nbiot:experiments:ExecutionBudget');
            t.verifyError(@() nbiot.experiments.validateExecutionBudget(cfg, ...
                struct('timePolicy','finish-current')), ...
                'nbiot:experiments:ExecutionBudget');
        end

        function hardStopStillRequiresWholeSuiteAllowance(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            execution=probeExecution(); execution.timePolicy='hard-stop';
            t.verifyError(@() nbiot.experiments.validateExecutionBudget( ...
                cfg,execution,4),'nbiot:experiments:ExecutionBudget');
        end

        function finishCurrentWarnsOnceAndAllowsCurrentCaseToFinish(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=1; cfg.traffic.kind='none';
            execution=probeExecution(); execution.maxCaseSeconds=0.001;
            execution.maxSuiteSeconds=60;
            sim=nbiot.NBIoTSimulator(cfg,[],execution);
            sim.step(); sim.step();
            result=sim.result();

            t.verifyEqual(result.status,'completed');
            t.verifyEqual(result.stopReason,'horizon');
            warningCount=sum(strcmp({result.lifecycleLog.kind}, ...
                'execution_budget_warning'));
            t.verifyEqual(warningCount,1);
        end
    end
end

function execution=probeExecution()
execution=struct('profile','scheduled-local','role','stage-3-load-pilot', ...
    'maxUE',2500,'maxCaseSeconds',36000,'maxSuiteSeconds',57600, ...
    'timePolicy','finish-current');
end

function execution=stageTwoExecution()
execution=struct('profile','scheduled-local', ...
    'role','stage-2-collision-diagnostics','maxUE',10, ...
    'maxCaseSeconds',120,'maxSuiteSeconds',57600, ...
    'timePolicy','finish-current');
end
