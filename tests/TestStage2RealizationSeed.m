classdef TestStage2RealizationSeed < matlab.unittest.TestCase
    methods (TestClassSetup)
        function addProjectPaths(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(root); setupProject();
            addpath(fullfile(root,'verification','completion','stage-2'));
        end
    end
    methods (Test)
        function designReportsDefaultSeed(t)
            report=validateCollisionCapture(struct('designOnly',true));
            t.verifyTrue(isfield(report.options,'realizationSeed'), ...
                'Stage 2 design output must identify its random seed.');
            if isfield(report.options,'realizationSeed')
                t.verifyEqual(report.options.realizationSeed,42);
            end
        end

        function designAcceptsFreshSeed(t)
            try
                report=validateCollisionCapture(struct('designOnly',true,'realizationSeed',43));
            catch exception
                if strcmp(exception.identifier,'nbiot:collision:Options')
                    t.verifyFail('Stage 2 must accept and report an explicit realization seed.');
                    return
                end
                rethrow(exception)
            end
            t.verifyEqual(report.options.realizationSeed,43);
        end

        function physicalDryRunReportsSeed(t)
            execution=struct('profile','scheduled-local', ...
                'role','stage-2-collision-diagnostics','maxUE',10, ...
                'maxCaseSeconds',57600,'maxSuiteSeconds',57600, ...
                'timePolicy','finish-current');
            try
                report=stage2Physical(execution,true,struct('realizationSeed',43));
            catch exception
                if strcmp(exception.identifier,'nbiot:stage2:RunOptions')
                    t.verifyFail('Stage 2 physical runner must expose its realization seed.');
                    return
                end
                rethrow(exception)
            end
            t.verifyEqual(report.realizationSeed,43);
        end
    end
end
