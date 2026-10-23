classdef TestFinalAcceptance < matlab.unittest.TestCase
    methods (Test)
        function missingEvidenceProducesIncompleteReview(t)
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',struct([])));

            report=runFinalAcceptance(options);

            t.verifyEqual(report.status,'incomplete');
            t.verifyFalse(report.accepted);
            t.verifyEqual(numel(report.evidence),8);
            t.verifyEqual(sum(strcmp({report.evidence.status},'missing')),8);
            t.verifyTrue(isfile(fullfile(options.outputFolder,'acceptance-review.json')));
            t.verifyTrue(isfile(fullfile(options.outputFolder,'acceptance-review.md')));
        end

        function matchingEvidenceIsOnlyMarkedReadyForHumanReview(t)
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            evidence=completeEvidence(root);
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',evidence));

            report=runFinalAcceptance(options);

            t.verifyEqual(report.status,'ready-for-human-review');
            t.verifyFalse(report.accepted);
            t.verifyTrue(all(strcmp({report.evidence.status},'verified')));
            markdown=fileread(fullfile(options.outputFolder,'acceptance-review.md'));
            t.verifyTrue(contains(markdown,'не означает, что итоговая приёмка завершена'));
        end

        function changedEvidenceFileFailsIntegrityCheck(t)
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            evidence=completeEvidence(root);
            writeText(fullfile(root,evidence(1).path),'changed after manifest creation');
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',evidence));

            report=runFinalAcceptance(options);

            t.verifyEqual(report.status,'integrity-error');
            t.verifyEqual(report.evidence(1).status,'hash-mismatch');
            t.verifyFalse(report.accepted);
        end

        function rejectsDuplicateEvidenceKeys(t)
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            evidence=completeEvidence(root);
            evidence(2).key=evidence(1).key;
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',evidence));

            t.verifyError(@() runFinalAcceptance(options), ...
                'nbiot:finalAcceptance:DuplicateEvidence');
        end

        function rejectsEvidenceOutsideProject(t)
            % Путь с обратной косой чертой — выход за проект только в Windows; на других ОС '\' — символ имени.
            t.assumeTrue(ispc,'Backslash path semantics are Windows-only.');
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            evidence=completeEvidence(root);
            evidence(1).path='..\outside.txt';
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',evidence));

            t.verifyError(@() runFinalAcceptance(options), ...
                'nbiot:finalAcceptance:EvidencePath');
        end

        function existingReviewIsNotOverwritten(t)
            root=fixtureRoot(); t.addTeardown(@() removeFolder(root));
            options=baseOptions(root);
            evidence=completeEvidence(root);
            writeManifest(options.evidenceManifest,struct('schemaVersion',1,'evidence',evidence));
            mkdir(options.outputFolder);
            reviewFile=fullfile(options.outputFolder,'acceptance-review.md');
            writeText(reviewFile,'keep this existing review');

            t.verifyError(@() runFinalAcceptance(options), ...
                'nbiot:finalAcceptance:OutputExists');
            t.verifyEqual(fileread(reviewFile),'keep this existing review');
        end
    end
end

function options=baseOptions(root)
options=struct('projectRoot',root, ...
    'evidenceManifest',fullfile(root,'verification','completion','evidence.json'), ...
    'outputFolder',fullfile(root,'verification','completion','review'));
end

function evidence=completeEvidence(root)
keys={'stage2Revalidation','independentModelEvaluation','comparisonSweep', ...
    'fullRegression','section47Audit','section50Audit', ...
    'colleagueReproduction','releasePackage'};
evidence=repmat(struct('key','','path','','sha256',''),1,numel(keys));
for k=1:numel(keys)
    relativePath=['evidence/' keys{k} '.txt'];
    absolutePath=fullfile(root,relativePath);
    parent=fileparts(absolutePath);
    if ~isfolder(parent), mkdir(parent); end
    writeText(absolutePath,['fixture evidence: ' keys{k}]);
    evidence(k)=struct('key',keys{k},'path',relativePath, ...
        'sha256',nbiot.ml.fileSha256(absolutePath));
end
end

function root=fixtureRoot()
root=tempname; mkdir(root);
end

function writeManifest(path,value)
parent=fileparts(path);
if ~isfolder(parent), mkdir(parent); end
writeText(path,jsonencode(value));
end

function writeText(path,value)
fid=fopen(path,'w');
if fid<0, error('TestFinalAcceptance:Write','Could not create fixture file.'); end
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,value,'char');
end

function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
