classdef TestAcceptanceEvidenceSnapshotDataset < matlab.unittest.TestCase
    methods (Test)
        function snapshotIncludesDatasetArtifacts(t)
            f=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            t.assertTrue(report.passed,strjoin(report.errors,'; '));
            expected={f.paths.observations,f.paths.targets, ...
                fullfile(f.root,'evidence','rows.csv'), ...
                fullfile(f.root,'evidence','diagnostics.csv'), ...
                fullfile(f.root,'evidence','manifest.json'), ...
                fullfile(f.root,'evidence','dataset.mat')};
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
