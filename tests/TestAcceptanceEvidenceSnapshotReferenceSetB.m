classdef TestAcceptanceEvidenceSnapshotReferenceSetB < matlab.unittest.TestCase
    methods (Test)
        function snapshotIncludesRemainingAcceptanceReferences(t)
            f=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            t.assertTrue(report.passed,strjoin(report.errors,'; '));
            expected={f.paths.registry,f.paths.artifacts, ...
                f.paths.trainingManifest,f.paths.evaluation};
            paths=string({report.evidenceFiles.path});
            for k=1:numel(expected)
                t.verifyTrue(any(strcmpi(paths,string(expected{k}))));
            end
        end
    end
end
