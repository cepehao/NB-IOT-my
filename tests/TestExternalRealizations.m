classdef TestExternalRealizations < matlab.unittest.TestCase
    methods (Test)
        function scenarioIsIdenticalAcrossControlMethods(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=2;
            cfg.simulation.durationTicks=1000;
            cfg.simulation.seed=91;
            cfg.simulation.realizationId=17;
            cfg.traffic.burstStartTick=0;
            cfg.traffic.burstDurationTicks=100;
            methods={"Static","Adaptive-P","Adaptive-RA/DT"};
            scenarios=cell(size(methods));

            for k=1:numel(methods)
                methodConfig=cfg;
                methodConfig.policy.name=char(methods{k});
                if methods{k}~="Static"
                    methodConfig.policy.windowTicks=500;
                    methodConfig.dataset.windowTicks=500;
                end
                scenarios{k}=nbiot.scenario.buildScenario(methodConfig);
            end

            test.verifyEqual(scenarios{2},scenarios{1});
            test.verifyEqual(scenarios{3},scenarios{1});
        end

        function namedExternalStreamIsStableAcrossInstancesAndRequestOrder(test)
            referenceSources=nbiot.randomness.RandomSources(91,17);
            expected=randn(referenceSources.stream('access',0,1,7),8,1);

            sources=nbiot.randomness.RandomSources(91,17);
            randn(sources.stream('noise',0,0,2),31,1);
            randn(sources.stream('backoff',0,1,3),5,1);
            actual=randn(sources.stream('access',0,1,7),8,1);

            test.verifyEqual(actual,expected);
        end
    end
end
