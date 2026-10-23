classdef TestAcceptanceEvidenceSnapshotHashes < matlab.unittest.TestCase
    methods (Test)
        function everySnapshotDigestMatchesItsValidatedFile(t)
            f=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            t.assertTrue(report.passed,strjoin(report.errors,'; '));
            t.assertNotEmpty(report.evidenceFiles);
            for k=1:numel(report.evidenceFiles)
                t.verifyEqual(nbiot.ml.fileSha256(report.evidenceFiles(k).path), ...
                    report.evidenceFiles(k).sha256);
            end
        end
    end
end
