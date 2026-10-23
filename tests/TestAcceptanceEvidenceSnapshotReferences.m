classdef TestAcceptanceEvidenceSnapshotReferences < matlab.unittest.TestCase
    methods (Test)
        function snapshotIncludesAcceptanceReferences(t)
            f=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            t.assertTrue(report.passed,strjoin(report.errors,'; '));
            expected={f.prepareOptions.calibrationFile,f.paths.metrics, ...
                f.paths.policy,f.paths.protocol};
            verifyPaths(t,report,expected);
        end
    end
end

function verifyPaths(testCase,report,expected)
paths=string({report.evidenceFiles.path});
for k=1:numel(expected)
    testCase.verifyTrue(any(strcmpi(paths,string(expected{k}))));
end
end
