classdef TestAcceptanceEvidenceSnapshotCaseInputs < matlab.unittest.TestCase
    methods (Test)
        function snapshotIncludesCompletionInputs(t)
            f=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            t.assertTrue(report.passed,strjoin(report.errors,'; '));
            expected={f.caseMarkerFiles{1},f.caseObservationFiles{1}, ...
                f.caseTargetFiles{1}, ...
                fullfile(f.root,'evidence','cases','case-11','result-11.mat'), ...
                fullfile(f.root,'evidence','cases','case-11','case-11_summary.csv')};
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
