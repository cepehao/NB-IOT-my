classdef TestAdaptivePolicySelection < matlab.unittest.TestCase
    methods (Test)
        function accessProbabilityRangeSelectsMatchingLevelsAndThresholds(t)
            policy=nbiot.controller.buildAdaptivePolicy('Adaptive-P',[0.25 0.75],[]);

            t.verifyEqual(policy.accessProbabilityLevels,[0.75 0.5 0.25]);
            t.verifyEqual(policy.accessLoadThresholds,[3 6]);
            t.verifyEqual(policy.raShareLevels,[0.1 0.2 0.3]);
        end

        function resourceSelectionKeepsOrderAndUsesSelectedBoundaries(t)
            policy=nbiot.controller.buildAdaptivePolicy('Adaptive-RA/DT',[],[0.3 0.1]);

            t.verifyEqual(policy.raShareLevels,[0.1 0.3]);
            t.verifyEqual(policy.raLoadThresholds,5);
            t.verifyEqual(policy.accessProbabilityLevels,[1 0.75 0.5 0.25 0.1]);
        end

        function oneAllowedLevelHasNoThreshold(t)
            policy=nbiot.controller.buildAdaptivePolicy('Adaptive-P',[0.5 0.5],[]);

            t.verifyEqual(policy.accessProbabilityLevels,0.5);
            t.verifyEmpty(policy.accessLoadThresholds);
        end

        function invalidOrEmptySelectionsAreRejected(t)
            t.verifyError(@() nbiot.controller.buildAdaptivePolicy( ...
                'Adaptive-P',[0.75 0.25],[]),'nbiot:controller:PolicySelection');
            t.verifyError(@() nbiot.controller.buildAdaptivePolicy( ...
                'Adaptive-RA/DT',[],[]),'nbiot:controller:PolicySelection');
            t.verifyError(@() nbiot.controller.buildAdaptivePolicy( ...
                'Adaptive-RA/DT',[],[0.1 0.4]),'nbiot:controller:PolicySelection');
        end
    end
end
