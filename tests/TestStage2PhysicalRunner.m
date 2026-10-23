classdef TestStage2PhysicalRunner < matlab.unittest.TestCase
    methods (Test)
        function dryRunReportsScheduledLocalScopeWithoutTouchingRegistry(t)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'verification','completion','stage-2'));
            registryPath=fullfile(root,'experiments','realizationRegistry.json');
            registryBefore=fileread(registryPath);
            execution=struct('profile','scheduled-local', ...
                'role','stage-2-collision-diagnostics','maxUE',10, ...
                'maxCaseSeconds',120,'maxSuiteSeconds',57600, ...
                'timePolicy','finish-current');
            try
                plan=stage2Physical(execution,true);
            catch exception
                t.verifyTrue(false,['Expected a side-effect-free Stage 2 plan; got ' ...
                    exception.identifier ': ' exception.message]);
                return
            end

            t.verifyTrue(plan.dryRun);
            t.verifyEqual(plan.numCases,232);
            t.verifyEqual(plan.maxUE,10);
            t.verifyEqual(plan.execution.profile,'scheduled-local');
            t.verifyEqual(plan.execution.timePolicy,'finish-current');
            t.verifyEqual(fileread(registryPath),registryBefore);
            t.verifyFalse(isfolder(plan.outputFolder));
        end

        function aPhysicalPlanRequiresExplicitExternalBudget(t)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'verification','completion','stage-2'));
            actualIdentifier='';
            try
                stage2Physical(struct(),true);
            catch exception
                actualIdentifier=exception.identifier;
            end

            t.verifyEqual(actualIdentifier,'nbiot:experiments:ExecutionBudget');
        end
    end
end
