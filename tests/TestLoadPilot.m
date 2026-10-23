classdef TestLoadPilot < matlab.unittest.TestCase
    methods (Test)
        function designUsesFiveLoadsAndFullPhysicalHorizon(t)
            plan=runLoadPilot(struct('designOnly',true));
            t.verifyEqual(plan.counts,[100 500 1000 2500 5000]);
            t.verifyEqual(plan.durationTicks,5000);
            t.verifyEqual(plan.burstDurationTicks,100);
            t.verifyEqual(plan.policy,'Static');
            t.verifyTrue(plan.requiresStage2Acceptance);
        end
        function physicalPilotRequiresStage2Acceptance(t)
            file=fullfile(tempdir,'missing-stage2-acceptance.json');
            execution=struct('profile','external-machine','role','stage-3-load-pilot', ...
                'maxUE',5000,'maxCaseSeconds',50000,'maxSuiteSeconds',250000);
            t.verifyError(@() runLoadPilot(struct('stage2AcceptanceFile',file,'execution',execution)),...
                'nbiot:experiments:PilotGate');
        end
        function rejectsUnsupportedLoadSize(t)
            t.verifyError(@() runLoadPilot(struct('designOnly',true,'counts',123)),...
                'nbiot:experiments:PilotOptions');
        end
        function rejectsBudgetIncompleteSubset(t)
            t.verifyError(@() runLoadPilot(struct('designOnly',true,'counts',[100 500])),...
                'nbiot:experiments:PilotOptions');
        end
        function artifactHashComparisonIgnoresJsonArrayOrientation(t)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'verification','completion','stage-2'));
            hashes=stage2ArtifactHashes(root);
            decoded=jsondecode(jsonencode(hashes));
            t.verifyTrue(stage2ArtifactHashesMatch(hashes,decoded));
            decoded(1).sha256=repmat('0',1,64);
            t.verifyFalse(stage2ArtifactHashesMatch(hashes,decoded));
        end
    end
end
