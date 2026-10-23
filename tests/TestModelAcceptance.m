classdef TestModelAcceptance < matlab.unittest.TestCase
    methods (Test)
        function checkerAcceptsConsistentFixtureEvidence(t)
            f=acceptanceFixture(t);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyTrue(report.passed,strjoin(report.errors,'; '));
            t.verifySize(report.evidenceDigest,[1 64]);
            t.verifyTrue(all(ismember(report.evidenceDigest,'0123456789abcdef')));
            t.verifyEqual(report.sourceSha256,f.sourceSha256);
            t.verifyEqual(report.calibrationSha256,f.calibrationSha256);
        end

        function runtimeIdentityRejectsSourceAndCalibrationMismatch(t)
            accepted=struct('sourceSha256',repmat('a',1,64), ...
                'calibrationSha256',repmat('b',1,64));

            sourceError=[];
            try
                nbiot.ml.verifyModelAcceptanceRuntimeIdentity(accepted, ...
                    repmat('c',1,64),repmat('b',1,64));
            catch caught
                sourceError=caught;
            end
            t.verifyNotEmpty(sourceError);
            if ~isempty(sourceError)
                t.verifyEqual(sourceError.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(sourceError.message, ...
                    'Current computational source manifest differs from accepted evidence.'));
            end

            calibrationError=[];
            try
                nbiot.ml.verifyModelAcceptanceRuntimeIdentity(accepted, ...
                    repmat('a',1,64),repmat('d',1,64));
            catch caught
                calibrationError=caught;
            end
            t.verifyNotEmpty(calibrationError);
            if ~isempty(calibrationError)
                t.verifyEqual(calibrationError.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(calibrationError.message, ...
                    'Current calibration file differs from accepted evidence.'));
            end
        end

        function checkerRejectsReferenceEscapingPackageRoot(t)
            f=acceptanceFixture(t);
            outside=fullfile(fileparts(f.root),'outside-model.mat');
            writeText(outside,'outside fixture bytes');
            f.acceptance.model.file='../outside-model.mat';
            f.acceptance.model.sha256=nbiot.ml.fileSha256(outside);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsAlteredMetricBytes(t)
            f=acceptanceFixture(t);
            writeText(f.paths.metrics,'altered metrics');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsMissingEvidenceFile(t)
            f=acceptanceFixture(t);
            delete(f.paths.metrics);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsNegativeMetricWithUpdatedHashes(t)
            f=acceptanceFixture(t);
            metrics=readtable(f.paths.metrics,'TextType','string');
            metrics.mae(1)=-0.01;
            writetable(metrics,f.paths.metrics);
            training=readJson(f.paths.trainingManifest);
            training.metricsSha256=nbiot.ml.fileSha256(f.paths.metrics);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.metrics.sha256=nbiot.ml.fileSha256(f.paths.metrics);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsEvaluationThatFailsApprovedThresholds(t)
            f=acceptanceFixture(t);
            metrics=readtable(f.paths.metrics,'TextType','string');
            selected=string(metrics.model)=="linearRegression"&string(metrics.split)=="test";
            metrics.mae(selected)=2; metrics.rmse(selected)=2;
            writetable(metrics,f.paths.metrics);
            evaluation=readJson(f.paths.evaluation);
            at=find(strcmp({evaluation.strata.split},'test'),1);
            evaluation.strata(at).mae=2; evaluation.strata(at).rmse=2;
            writeJson(f.paths.evaluation,evaluation);
            training=readJson(f.paths.trainingManifest);
            training.metricsSha256=nbiot.ml.fileSha256(f.paths.metrics);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.metrics.sha256=nbiot.ml.fileSha256(f.paths.metrics);
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsPolicyByteChange(t)
            f=acceptanceFixture(t);
            writeText(f.paths.policy,'altered policy bytes');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerAcceptsNestedSourceEvidencePath(t)
            f=acceptanceFixture(t);
            sourceManifestFile=fullfile(f.root,'evidence','source-manifest.json');
            nestedFolder=fullfile(f.root,'evidence','source'); mkdir(nestedFolder);
            nestedFile=fullfile(nestedFolder,'computation.m');
            writeText(nestedFile,'nested computational source bytes');
            sourceManifest=readJson(sourceManifestFile);
            sourceManifest.files=struct('name','source/computation.m', ...
                'sha256',nbiot.ml.fileSha256(nestedFile));
            writeJson(sourceManifestFile,sourceManifest);
            training=readJson(f.paths.trainingManifest);
            training.sourceManifestSha256=nbiot.ml.fileSha256(sourceManifestFile);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.sourceManifest.sha256=nbiot.ml.fileSha256(sourceManifestFile);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyTrue(report.passed,strjoin(report.errors,'; '));
        end

        function checkerRejectsFractionalRegistryRangeEndpoints(t)
            f=acceptanceFixture(t);
            registry=readJson(f.paths.registry);
            registry.reservations=struct('role','legacy','range',[9.5 9.5]);
            writeJson(f.paths.registry,registry);
            registrySha=nbiot.ml.fileSha256(f.paths.registry);
            training=readJson(f.paths.trainingManifest);
            freeze=readJson(f.paths.freeze);
            evaluation=readJson(f.paths.evaluation);
            training.registrySha256=registrySha;
            freeze.registrySha256=registrySha;
            writeJson(f.paths.freeze,freeze);
            training.freezeSha256=nbiot.ml.fileSha256(f.paths.freeze);
            evaluation.freezeSha256=training.freezeSha256;
            writeJson(f.paths.evaluation,evaluation);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.registry.sha256=registrySha;
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsSelectionThatIsNotTheValidationWinner(t)
            f=acceptanceFixture(t);
            metrics=readtable(f.paths.metrics,'TextType','string');
            selected=string(metrics.model)=="decisionTree"&string(metrics.split)=="validation";
            metrics.mae(selected)=0.05; metrics.rmse(selected)=0.05;
            writetable(metrics,f.paths.metrics);
            f=refreshMetricsEvidence(f);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsMetricSampleCountBelowIdCount(t)
            f=acceptanceFixture(t);
            metrics=readtable(f.paths.metrics,'TextType','string');
            training=readJson(f.paths.trainingManifest);
            trainRows=string(metrics.split)=="train";
            metrics.sampleCount(trainRows)=1;
            training.splitEvidence(1).sampleCount=1;
            evaluation=readJson(f.paths.evaluation);
            trainStratum=find(strcmp({evaluation.strata.split},'train'),1);
            evaluation.strata(trainStratum).sampleCount=1;
            writetable(metrics,f.paths.metrics);
            writeJson(f.paths.trainingManifest,training);
            writeJson(f.paths.evaluation,evaluation);
            f=refreshMetricsEvidence(f);
            f=refreshEvaluationEvidence(f);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsMetricRmseBelowMae(t)
            f=acceptanceFixture(t);
            metrics=readtable(f.paths.metrics,'TextType','string');
            row=string(metrics.model)=="decisionTree"&string(metrics.split)=="train";
            metrics.mae(row)=0.2; metrics.rmse(row)=0.1;
            writetable(metrics,f.paths.metrics);
            f=refreshMetricsEvidence(f);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsEvaluationTrainMetricsThatDifferFromCsv(t)
            f=acceptanceFixture(t);
            evaluation=readJson(f.paths.evaluation);
            at=find(strcmp({evaluation.strata.split},'train'),1);
            evaluation.strata(at).mae=0.25; evaluation.strata(at).rmse=0.25;
            writeJson(f.paths.evaluation,evaluation);
            f=refreshEvaluationEvidence(f);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsFixtureClaimingVerifiedAllocations(t)
            f=acceptanceFixture(t);
            training=readJson(f.paths.trainingManifest);
            training.allocationsVerified=true;
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsFreezeEvidenceKindMismatch(t)
            f=acceptanceFixture(t);
            freeze=readJson(f.paths.freeze);
            freeze.evidenceKind='scientific-candidate';
            writeJson(f.paths.freeze,freeze);
            training=readJson(f.paths.trainingManifest);
            evaluation=readJson(f.paths.evaluation);
            training.freezeSha256=nbiot.ml.fileSha256(f.paths.freeze);
            evaluation.freezeSha256=training.freezeSha256;
            writeJson(f.paths.evaluation,evaluation);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerCanonicalizesEquivalentScopeOrdering(t)
            f=acceptanceFixture(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            f.acceptance.scope.methods=fliplr(f.acceptance.scope.methods);
            f.acceptance.scope.trafficKinds=fliplr(f.acceptance.scope.trafficKinds);

            reordered=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyTrue(reordered.passed,strjoin(reordered.errors,'; '));
            t.verifyEqual(reordered.evidenceDigest,report.evidenceDigest);
        end

        function checkerRequiresInputCompletionEvidence(t)
            f=acceptanceFixture(t);
            delete(f.caseMarkerFiles{1});

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsChangedInputObservationExport(t)
            f=acceptanceFixture(t);
            writeText(f.caseObservationFiles{1},'tampered case observations');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsObservationValueMismatchWithUpdatedHashes(t)
            f=acceptanceFixture(t);
            observations=readtable(f.paths.observations,'TextType','string');
            observations.feature(1)=observations.feature(1)+1;
            writetable(observations,f.paths.observations);
            f=refreshDatasetArtifactEvidence(f,'observations.csv');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsTargetValueMismatchWithUpdatedHashes(t)
            f=acceptanceFixture(t);
            targets=readtable(f.paths.targets,'TextType','string');
            targets.meanRaUe(1)=targets.meanRaUe(1)+1;
            writetable(targets,f.paths.targets);
            f=refreshDatasetArtifactEvidence(f,'targets.csv');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsDuplicateFreezeModelSetWithUpdatedHashes(t)
            f=acceptanceFixture(t);
            freeze=readJson(f.paths.freeze);
            freeze.models(4)=freeze.models(1);
            writeJson(f.paths.freeze,freeze);
            training=readJson(f.paths.trainingManifest);
            evaluation=readJson(f.paths.evaluation);
            training.freezeSha256=nbiot.ml.fileSha256(f.paths.freeze);
            evaluation.freezeSha256=training.freezeSha256;
            writeJson(f.paths.evaluation,evaluation);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsFreezeArtifactDetachedFromTrainingManifest(t)
            f=acceptanceFixture(t);
            freeze=readJson(f.paths.freeze);
            at=find(strcmp({freeze.models.modelName},'decisionTree'));
            freeze.models(at).file='linearRegression.mat';
            freeze.models(at).sha256=freeze.models(1).sha256;
            freeze.models(at).sidecarFile='linearRegression.json';
            freeze.models(at).sidecarSha256=freeze.models(1).sidecarSha256;
            writeJson(f.paths.freeze,freeze);
            training=readJson(f.paths.trainingManifest);
            evaluation=readJson(f.paths.evaluation);
            training.freezeSha256=nbiot.ml.fileSha256(f.paths.freeze);
            evaluation.freezeSha256=training.freezeSha256;
            writeJson(f.paths.evaluation,evaluation);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsDuplicateWindowKeysWithConsistentExports(t)
            f=acceptanceFixture(t,true);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyTrue(contains(strjoin(report.errors,'; '),'duplicate window keys'));
        end

        function checkerRejectsSourceBytesThatNoLongerMatchManifest(t)
            f=acceptanceFixture(t);
            writeText(f.paths.sourceCode,'changed source bytes');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsIncompleteRegistryAllocation(t)
            f=acceptanceFixture(t);
            registry=readJson(f.paths.registry);
            registry.assignments(3).status='planned';
            writeJson(f.paths.registry,registry);
            registrySha=nbiot.ml.fileSha256(f.paths.registry);
            training=readJson(f.paths.trainingManifest);
            freeze=readJson(f.paths.freeze);
            evaluation=readJson(f.paths.evaluation);
            training.registrySha256=registrySha;
            freeze.registrySha256=registrySha;
            writeJson(f.paths.freeze,freeze);
            training.freezeSha256=nbiot.ml.fileSha256(f.paths.freeze);
            evaluation.freezeSha256=training.freezeSha256;
            writeJson(f.paths.evaluation,evaluation);
            training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
            writeJson(f.paths.trainingManifest,training);
            f.acceptance.registry.sha256=registrySha;
            f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
            f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsScientificLabelOnFixture(t)
            f=acceptanceFixture(t);
            f.acceptance.evidenceKind='scientific-candidate';

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsAcceptanceFeatureSchemaSpoof(t)
            f=acceptanceFixture(t);
            f.acceptance.featureSchemaVersion='bs-known-v99.0';

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsOverlappingSplitIds(t)
            f=acceptanceFixture(t);
            f.acceptance.trainingIds=[11 21];

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsInvalidThresholdsAndMissingStrata(t)
            f=acceptanceFixture(t);
            protocol=f.protocol;
            protocol.thresholds.maxMae=-1;
            protocol.requiredStrata(end+1)=struct('numUE',2,'trafficKind','burst');
            writeJson(f.paths.protocol,protocol);
            f.acceptance.protocol.sha256=nbiot.ml.fileSha256(f.paths.protocol);

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function checkerRejectsAcceptedEvidenceWithStaleReviewDigest(t)
            f=acceptanceFixture(t);
            f.acceptance.status='accepted';
            f.acceptance.review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',repmat('0',1,64), ...
                'protocolSha256',f.acceptance.protocol.sha256,'limitations','fixture only');

            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function prepareCreatesPortableCandidateWithoutAcceptance(t)
            f=acceptanceFixture(t);
            options=f.prepareOptions;

            candidate=prepareModelAcceptance(options);

            t.verifyEqual(candidate.schemaVersion,'model-acceptance-v1');
            t.verifyEqual(candidate.status,'candidate');
            t.verifyEqual(candidate.evidenceKind,'test-fixture');
            t.verifyFalse(isfile(fullfile(f.root,'accepted.json')));
            t.verifyFalse(contains(candidate.model.file,f.root));
            checked=nbiot.ml.checkModelAcceptanceEvidence( ...
                fullfile(f.root,'candidate.json'),f.root);
            t.verifyTrue(checked.passed,strjoin(checked.errors,'; '));
        end

        function prepareRejectsOutputOverwrite(t)
            f=acceptanceFixture(t);
            options=f.prepareOptions;
            writeText(options.outputFile,'keep existing bytes');

            t.verifyError(@() prepareModelAcceptance(options), ...
                'nbiot:ml:ModelAcceptance');
            t.verifyEqual(fileread(options.outputFile),'keep existing bytes');
        end

        function prepareRejectsEvidenceOutsidePackage(t)
            f=acceptanceFixture(t);
            outside=fullfile(fileparts(f.root),'outside-evidence.csv');
            writeText(outside,'outside');
            options=f.prepareOptions;
            options.metricsFile=outside;

            t.verifyError(@() prepareModelAcceptance(options), ...
                'nbiot:ml:ModelAcceptance');
            t.verifyFalse(isfile(options.outputFile));
        end

        function publicAdmissionRejectsFixtureSpoofedAsAccepted(t)
            f=acceptanceFixture(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            forged=f.acceptance;
            forged.status='accepted';
            forged.evidenceKind='scientific-candidate';
            forged.review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',report.evidenceDigest, ...
                'protocolSha256',f.acceptance.protocol.sha256,'limitations','fixture only');
            forgedFile=fullfile(f.root,'forged-accepted.json');
            writeJson(forgedFile,forged);
            before=nbiot.ml.fileSha256(fullfile(f.root,f.acceptance.model.file));

            t.verifyError(@() nbiot.ml.validateModelAcceptance( ...
                forgedFile,fullfile(f.root,f.acceptance.model.file),f.policy, ...
                f.execution,41,f.cfg),'nbiot:ml:ModelAcceptance');
            t.verifyEqual(nbiot.ml.fileSha256(fullfile(f.root,f.acceptance.model.file)),before);
        end

        function publishCannotPromoteFixtureEvenWithMatchingReview(t)
            f=acceptanceFixture(t);
            candidate=prepareModelAcceptance(f.prepareOptions);
            report=nbiot.ml.checkModelAcceptanceEvidence(candidate, f.root);
            review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',report.evidenceDigest, ...
                'protocolSha256',candidate.protocol.sha256,'limitations','fixture only');
            reviewFile=fullfile(f.root,'review.json'); writeJson(reviewFile,review);
            outputFile=fullfile(f.root,'accepted.json');
            options=struct('candidateFile',fullfile(f.root,'candidate.json'), ...
                'reviewFile',reviewFile,'outputFile',outputFile);
            before=nbiot.ml.fileSha256(fullfile(f.root,candidate.model.file));

            t.verifyError(@() publishModelAcceptance(options), ...
                'nbiot:ml:ModelAcceptance');
            t.verifyFalse(isfile(outputFile));
            t.verifyEqual(nbiot.ml.fileSha256(fullfile(f.root,candidate.model.file)),before);
        end

        function publishRejectsReviewBoundToDifferentEvidence(t)
            f=acceptanceFixture(t);
            candidate=prepareModelAcceptance(f.prepareOptions);
            review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',repmat('0',1,64), ...
                'protocolSha256',candidate.protocol.sha256,'limitations','fixture only');
            reviewFile=fullfile(f.root,'wrong-review.json'); writeJson(reviewFile,review);
            outputFile=fullfile(f.root,'wrong-accepted.json');

            t.verifyError(@() publishModelAcceptance(struct('candidateFile', ...
                fullfile(f.root,'candidate.json'),'reviewFile',reviewFile,'outputFile',outputFile)), ...
                'nbiot:ml:ModelAcceptance');
            t.verifyFalse(isfile(outputFile));
        end

        function publishRejectsReviewBeforeEvaluationCompletion(t)
            f=acceptanceFixture(t);
            candidate=prepareModelAcceptance(f.prepareOptions);
            report=nbiot.ml.checkModelAcceptanceEvidence(candidate,f.root);
            review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:02:00Z','evidenceDigest',report.evidenceDigest, ...
                'protocolSha256',candidate.protocol.sha256,'limitations','fixture only');
            reviewFile=fullfile(f.root,'early-review.json'); writeJson(reviewFile,review);
            outputFile=fullfile(f.root,'early-accepted.json');

            t.verifyError(@() publishModelAcceptance(struct('candidateFile', ...
                fullfile(f.root,'candidate.json'),'reviewFile',reviewFile,'outputFile',outputFile)), ...
                'nbiot:ml:ModelAcceptance');
            t.verifyFalse(isfile(outputFile));
        end

        function publicAdmissionRequiresCfgAsSixthArgument(t)
            f=acceptanceFixture(t);

            t.verifyError(@() nbiot.ml.validateModelAcceptance( ...
                fullfile(f.root,'missing.json'),fullfile(f.root,'models/linearRegression.mat'), ...
                f.policy,f.execution,41),'nbiot:ml:ModelAcceptance');
        end

        function publicAdmissionRejectsComparisonIdOverlap(t)
            f=acceptanceFixture(t);
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            forged=f.acceptance;
            forged.status='accepted';
            forged.review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',report.evidenceDigest, ...
                'protocolSha256',f.acceptance.protocol.sha256,'limitations','fixture only');
            forgedFile=fullfile(f.root,'accepted-fixture.json'); writeJson(forgedFile,forged);

            t.verifyError(@() nbiot.ml.validateModelAcceptance( ...
                forgedFile,fullfile(f.root,'models/linearRegression.mat'), ...
                f.policy,f.execution,31,f.cfg),'nbiot:ml:ModelAcceptance');
        end

        function publicAdmissionRejectsOutOfScopeConfig(t)
            f=acceptanceFixture(t);
            f.cfg.simulation.numUE=2;
            forged=f.acceptance; forged.status='accepted';
            report=nbiot.ml.checkModelAcceptanceEvidence(f.acceptance,f.root);
            forged.review=struct('decision','accepted','reviewer','reviewer-fixture', ...
                'reviewedAtUtc','2026-10-18T15:04:00Z','evidenceDigest',report.evidenceDigest, ...
                'protocolSha256',f.acceptance.protocol.sha256,'limitations','fixture only');
            forgedFile=fullfile(f.root,'accepted-fixture.json'); writeJson(forgedFile,forged);

            t.verifyError(@() nbiot.ml.validateModelAcceptance( ...
                forgedFile,fullfile(f.root,'models/linearRegression.mat'), ...
                f.policy,f.execution,41,f.cfg),'nbiot:ml:ModelAcceptance');
        end
    end
    methods (Static)
        function f=fixtureForEvidenceSnapshotTest(testCase)
            f=acceptanceFixture(testCase);
        end
    end
end

function f=acceptanceFixture(testCase,duplicateWindowKey)
if nargin<2, duplicateWindowKey=false; end
root=tempname; mkdir(root); testCase.addTeardown(@() removeFolder(root));
evidence=fullfile(root,'evidence'); modelsFolder=fullfile(root,'models');
mkdir(evidence); mkdir(modelsFolder);
ids=[11 12 21 31]; splits=["train";"train";"validation";"test"];
roles=["training";"training";"validation";"model-test"];
caseKeys="case-"+string(ids);
rowCaseKeys=[caseKeys(1);caseKeys(1);caseKeys(2);caseKeys(3);caseKeys(4)];
rowIds=[ids(1);ids(1);ids(2);ids(3);ids(4)];
windowIds=[1;2;1;1;1]; startTicks=[0;500;0;0;0]; endTicks=startTicks+500;
if duplicateWindowKey
    windowIds(2)=windowIds(1); startTicks(2)=startTicks(1); endTicks(2)=endTicks(1);
end
rowSplits=["train";"train";"train";"validation";"test"];
rowRoles=["training";"training";"training";"validation";"model-test"];
rowInfo=table(rowCaseKeys,rowIds,windowIds,startTicks,endTicks,rowSplits,rowRoles, ...
    'VariableNames',{'caseKey','realizationId','windowId','startTick','endTick','split','experimentRole'});
sourceFile=fullfile(evidence,'computational-source.m');
writeText(sourceFile,'fixture source snapshot');
sourceFileSha=nbiot.ml.fileSha256(sourceFile);
sourceManifestNow=optimizationSourceManifest(fileparts(which('setupProject')));
sourceSha=sourceManifestNow.sha256;
calibrationFile=fullfile(evidence,'calibration.mat');
writeText(calibrationFile,'fixture calibration bytes');
calibrationSha=nbiot.ml.fileSha256(calibrationFile);
inputTemplate=struct('resultFile','','caseKey','','sourceSha256','','calibrationSha256','', ...
    'markerSha256','','schemaVersion','bs-known-v2.0','numUE',1,'realizationId',0, ...
    'isFixture',true,'trafficKind','burst','burstDurationTicks',100, ...
    'periodTicks',NaN,'poissonRatePerSecond',NaN);
inputs=repmat(inputTemplate,1,numel(ids));
caseMarkerFiles=cell(1,numel(ids)); caseObservationFiles=cell(1,numel(ids));
caseTargetFiles=cell(1,numel(ids));
featureValues=[0.11;0.12;0.21;0.31;0.41]; raTargetValues=[0.11;0.12;0.21;0.31;0.41];
activeTargetValues=[0.10;0.10;0.20;0.30;0.40];
caseRoot=fullfile(evidence,'cases'); mkdir(caseRoot);
for k=1:numel(ids)
    caseFolder=fullfile(caseRoot,char(caseKeys(k))); mkdir(caseFolder);
    resultName=sprintf('result-%d.mat',ids(k)); exportStem=sprintf('case-%d',ids(k));
    resultPath=fullfile(caseFolder,resultName);
    summaryPath=fullfile(caseFolder,[exportStem '_summary.csv']);
    observationsPath=fullfile(caseFolder,[exportStem '_observations.csv']);
    targetsPath=fullfile(caseFolder,[exportStem '_targets.csv']);
    writeText(resultPath,'opaque completed case fixture bytes');
    writeText(summaryPath,'fixture-summary\n');
    caseMask=rowInfo.realizationId==ids(k);
    caseKeysTable=table(rowInfo.realizationId(caseMask),rowInfo.windowId(caseMask), ...
        rowInfo.startTick(caseMask),rowInfo.endTick(caseMask),featureValues(caseMask), ...
        'VariableNames',{'realizationId','windowId','startTick','endTick','feature'});
    caseTargetsTable=table(rowInfo.realizationId(caseMask),rowInfo.windowId(caseMask), ...
        rowInfo.startTick(caseMask),rowInfo.endTick(caseMask),raTargetValues(caseMask),activeTargetValues(caseMask), ...
        'VariableNames',{'realizationId','windowId','startTick','endTick','meanRaUe','meanActiveUe'});
    writetable(caseKeysTable,observationsPath);
    writetable(caseTargetsTable,targetsPath);
    names={resultName,[exportStem '_summary.csv'], ...
        [exportStem '_observations.csv'],[exportStem '_targets.csv']};
    markerFiles=repmat(struct('name','','bytes',0,'sha256',''),1,numel(names));
    casePaths={resultPath,summaryPath,observationsPath,targetsPath};
    for j=1:numel(names)
        info=dir(casePaths{j});
        markerFiles(j)=struct('name',names{j},'bytes',info.bytes, ...
            'sha256',nbiot.ml.fileSha256(casePaths{j}));
    end
    marker=struct('manifestVersion',1,'caseKey',char(caseKeys(k)),'status','completed', ...
        'sourceSha256',sourceSha,'calibrationSha256',calibrationSha, ...
        'resultFile',resultName,'exportStem',exportStem,'files',markerFiles);
    markerPath=fullfile(caseFolder,'case-complete.json'); writeJson(markerPath,marker);
    inputs(k).resultFile=strrep(strrep(resultPath,[root filesep],''),'\','/');
    inputs(k).caseKey=char(caseKeys(k)); inputs(k).sourceSha256=sourceSha;
    inputs(k).calibrationSha256=calibrationSha; inputs(k).markerSha256=nbiot.ml.fileSha256(markerPath);
    inputs(k).realizationId=ids(k);
    caseMarkerFiles{k}=markerPath; caseObservationFiles{k}=observationsPath;
    caseTargetFiles{k}=targetsPath;
end
assignmentTemplate=struct('externalRealizationId',0,'split','','experimentRole','');
assignments=repmat(assignmentTemplate,1,numel(ids));
for k=1:numel(ids)
    assignments(k)=struct('externalRealizationId',ids(k),'split',char(splits(k)), ...
        'experimentRole',char(roles(k)));
end
datasetManifest=struct('kind','development-fixture','assignments',assignments, ...
    'inputs',inputs,'allocationsVerified',false,'experimentRolesExplicit',false, ...
    'diagnosticsComplete',false,'diagnosticsSchemaVersion','window-diagnostics-v1', ...
    'sourceSha256',sourceSha,'calibrationSha256',calibrationSha);
manifestFile=fullfile(evidence,'manifest.json'); writeJson(manifestFile,datasetManifest);
rowsFile=fullfile(evidence,'rows.csv'); writetable(rowInfo,rowsFile);
diagnostics=table(rowInfo.caseKey,rowInfo.realizationId,rowInfo.windowId, ...
    rowInfo.startTick,rowInfo.endTick, ...
    'VariableNames',{'caseKey','realizationId','windowId','startTick','endTick'});
diagnosticsFile=fullfile(evidence,'diagnostics.csv');
datasetKeys=rowInfo(:,{'realizationId','windowId','startTick','endTick'});
observations=datasetKeys; observations.feature=featureValues;
targets=datasetKeys; targets.meanRaUe=raTargetValues; targets.meanActiveUe=activeTargetValues;
observationsExport=observations; observationsExport.caseKey=rowInfo.caseKey;
targetsExport=targets; targetsExport.caseKey=rowInfo.caseKey;
observationsFile=fullfile(evidence,'observations.csv'); writetable(observationsExport,observationsFile);
targetsFile=fullfile(evidence,'targets.csv'); writetable(targetsExport,targetsFile);
writetable(diagnostics,diagnosticsFile);
datasetFile=fullfile(evidence,'dataset.mat');
data=struct('rowInfo',rowInfo,'manifest',datasetManifest, ...
    'observations',observations,'targets',targets,'diagnostics',diagnostics); %#ok<NASGU>
save(datasetFile,'data','-v7.3');
artifactNames={'dataset.mat','manifest.json','diagnostics.csv','rows.csv','observations.csv','targets.csv'};
artifactTemplate=struct('name','','sha256','','bytes',0);
artifactFiles=repmat(artifactTemplate,1,numel(artifactNames));
for k=1:numel(artifactNames)
    path=fullfile(evidence,artifactNames{k}); info=dir(path);
    artifactFiles(k)=struct('name',artifactNames{k}, ...
        'sha256',nbiot.ml.fileSha256(path),'bytes',info.bytes);
end
artifactsFile=fullfile(evidence,'artifacts.json');
writeJson(artifactsFile,struct('schemaVersion',1,'files',artifactFiles));
registry=struct('schemaVersion',1,'validRange',[0 3999], ...
    'roles',{{'development','training','validation','model-test','final-comparison'}}, ...
    'reservations',struct('role',{},'range',{}));
assignmentTemplate=struct('role','','ids',[],'source','','status','');
registry.assignments=repmat(assignmentTemplate,1,4);
registry.assignments(1)=struct('role','development','ids',10, ...
    'source','fixture','status','completed');
registry.assignments(2)=struct('role','training','ids',[11 12], ...
    'source','fixture','status','completed');
registry.assignments(3)=struct('role','validation','ids',21, ...
    'source','fixture','status','completed');
registry.assignments(4)=struct('role','model-test','ids',31, ...
    'source','fixture','status','completed');
registryFile=fullfile(evidence,'registry-snapshot.json'); writeJson(registryFile,registry);
policy=adaptiveDefaults(); policy.status='frozen-validation';
policyFile=fullfile(root,'policy.json'); writeJson(policyFile,policy);
protocol=struct('schemaVersion',1,'frozenAtUtc','2026-10-18T14:59:00Z', ...
    'approver','fixture-approval','approvedAtUtc','2026-10-18T15:00:00Z', ...
    'baseline','trainMean','selectionRule','lowest-validation-mae', ...
    'thresholds',struct('maxMae',1,'maxRmse',1,'maxMaeToBaselineRatio',1, ...
        'maxRmseToBaselineRatio',1), ...
    'requiredStrata',struct('numUE',1,'trafficKind','burst'), ...
    'scope',struct('methods',{{'Adaptive-P','Adaptive-RA/DT'}},'numUE',1, ...
        'trafficKinds',{{'burst'}},'burstDurationTicks',100,'windowTicks',500), ...
    'policyTuningAllowedRoles',{{'development','validation'}}, ...
    'testConsumption','once-after-freeze');
protocolFile=fullfile(root,'protocol.json'); writeJson(protocolFile,protocol);
modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
modelTemplate=struct('modelName','','file','','sha256','','sidecarFile','','sidecarSha256','');
modelRecords=repmat(modelTemplate,1,numel(modelNames));
% Keep the fixture model artifacts intentionally opaque; only the public validator may load models.
for k=1:numel(modelNames)
    name=modelNames{k}; modelFile=fullfile(modelsFolder,[name '.mat']);
    writeText(modelFile,['opaque test fixture ' name]);
    modelHash=nbiot.ml.fileSha256(modelFile);
    sidecar=struct('formatVersion','load-model-bundle-v1','modelName',name, ...
        'artifactFile',[name '.mat'],'artifactSha256',modelHash, ...
        'schemaVersion','bs-known-v2.0','targetName','meanRaUe', ...
        'featureNames',{{'feature'}},'keyNames',{{'realizationId','windowId','startTick','endTick'}}, ...
        'trainingIds',[11 12],'validationIds',21,'testIds',31,'seed',17, ...
        'status','development','dataKind','development-fixture');
    sidecarFile=fullfile(modelsFolder,[name '.json']); writeJson(sidecarFile,sidecar);
    modelRecords(k)=struct('modelName',name,'file',[name '.mat'],'sha256',modelHash, ...
        'sidecarFile',[name '.json'],'sidecarSha256',nbiot.ml.fileSha256(sidecarFile));
end
metricsFile=fullfile(modelsFolder,'metrics.csv');
modelRows={}; validationMae=[0.1 0.2 0.3 0.4 0.8];
metricNames=[modelNames {'trainMean'}];
sampleCounts=[3 1 1]; idCounts=[2 1 1]; splitNames={'train','validation','test'};
for m=1:numel(metricNames)
    for s=1:numel(splitNames)
        value=validationMae(m);
        if strcmp(splitNames{s},'test')
            if strcmp(metricNames{m},'trainMean'), value=1; else, value=0.1; end
        end
        modelRows(end+1,:)={metricNames{m},splitNames{s},sampleCounts(s), ...
            idCounts(s),value,value,0,0.01,0.01}; %#ok<AGROW>
    end
end
metrics=cell2table(modelRows,'VariableNames', ...
    {'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'});
writetable(metrics,metricsFile);
policySha=nbiot.controller.policySha256(policy);
policyFileSha=nbiot.ml.fileSha256(policyFile); protocolSha=nbiot.ml.fileSha256(protocolFile);
datasetSha=nbiot.ml.fileSha256(datasetFile); registrySha=nbiot.ml.fileSha256(registryFile);
freeze=struct('schemaVersion','load-model-freeze-v1','evidenceKind','test-fixture', ...
    'createdAtUtc','2026-10-18T15:01:00Z','approvedProtocolSha256',protocolSha, ...
    'modelSha256',modelRecords(1).sha256,'modelSidecarSha256',modelRecords(1).sidecarSha256, ...
    'policySha256',policySha,'policyFileSha256',policyFileSha, ...
    'datasetSha256',datasetSha,'selectionManifestSha256',repmat('b',1,64), ...
    'registrySha256',registrySha,'selectedModel','linearRegression', ...
    'selectionRule','lowest-validation-mae;tieOrder=linearRegression,decisionTree,randomForest,gradientBoosting', ...
    'trainingIds',[11 12],'validationIds',21,'testIds',31,'policyTuningIds',10, ...
    'models',modelRecords);
freezeFile=fullfile(modelsFolder,'freeze.json'); writeJson(freezeFile,freeze);
freezeSha=nbiot.ml.fileSha256(freezeFile);
strataTemplate=struct('split','','numUE',1,'trafficKind','burst','sampleCount',1, ...
    'idCount',1,'mae',0.1,'rmse',0.1,'baselineMae',0.8,'baselineRmse',0.8);
strata=repmat(strataTemplate,1,3);
for k=1:3
    strata(k).split=splitNames{k}; strata(k).sampleCount=sampleCounts(k); strata(k).idCount=idCounts(k);
    if strcmp(splitNames{k},'test'), strata(k).baselineMae=1; strata(k).baselineRmse=1; end
end
evaluation=struct('schemaVersion','load-model-evaluation-v1','status','complete', ...
    'evidenceKind','test-fixture','datasetSha256',datasetSha,'modelSha256',modelRecords(1).sha256, ...
    'protocolSha256',protocolSha,'frozenModelSha256',modelRecords(1).sha256, ...
    'selectedModel','linearRegression','evaluatedAtUtc','2026-10-18T15:03:00Z', ...
    'selectionSplit','validation','testOpenedAtUtc','2026-10-18T15:02:00Z', ...
    'completedAtUtc','2026-10-18T15:03:00Z','strata',strata,'passed',true, ...
    'unmetRequirements',{{}},'freezeSha256',freezeSha, ...
    'selectionManifestSha256',freeze.selectionManifestSha256);
evaluationFile=fullfile(root,'evaluation.json'); writeJson(evaluationFile,evaluation);
trainingManifest=struct('formatVersion','load-training-report-v2','phase','evaluated', ...
    'dataKind','development-fixture','allocationsVerified',false,'status','development', ...
    'targetName','meanRaUe','schemaVersion','bs-known-v2.0','seed',17, ...
    'bestValidationModel','linearRegression', ...
    'selectionRule','lowest validation MAE; test results are not used for selection', ...
    'modelNames',{modelNames},'artifactFiles',{{modelRecords.file}},'artifactSha256',{{modelRecords.sha256}}, ...
    'trainingIds',[11 12],'validationIds',21,'testIds',31, ...
    'metricsFile','metrics.csv','metricsSha256',nbiot.ml.fileSha256(metricsFile), ...
    'metricsRowCount',height(metrics),'splitEvidence', ...
        struct('split',{'train','validation','test'},'ids',{[11 12],21,31}, ...
            'sampleCount',{3,1,1},'idCount',{2,1,1}), ...
    'datasetFile','../evidence/dataset.mat','datasetSha256',datasetSha, ...
    'datasetManifestFile','../evidence/manifest.json', ...
    'datasetManifestSha256',nbiot.ml.fileSha256(manifestFile), ...
    'sourceSha256',sourceSha,'calibrationSha256',calibrationSha, ...
    'freezeFile','freeze.json','freezeSha256',freezeSha, ...
    'selectionManifestSha256',freeze.selectionManifestSha256, ...
    'datasetArtifactsFile','../evidence/artifacts.json', ...
    'datasetArtifactsSha256',nbiot.ml.fileSha256(artifactsFile), ...
    'evaluationFile','../evaluation.json','evaluationSha256',nbiot.ml.fileSha256(evaluationFile), ...
    'protocolFile','../protocol.json','protocolSha256',protocolSha, ...
    'policyFile','../policy.json','policySha256',policySha,'policyFileSha256',policyFileSha, ...
    'registryFile','../evidence/registry-snapshot.json','registrySha256',registrySha, ...
    'sourceManifestFile','../evidence/source-manifest.json','sourceManifestSha256','', ...
    'evaluationPassed',true);
trainingManifestFile=fullfile(modelsFolder,'training-manifest.json');
writeJson(trainingManifestFile,trainingManifest);
sourceManifest=struct('schemaVersion',1,'sourceSha256',sourceSha, ...
    'calibrationSha256',calibrationSha,'files',struct('name','computational-source.m', ...
        'sha256',sourceFileSha));
sourceManifestFile=fullfile(evidence,'source-manifest.json'); writeJson(sourceManifestFile,sourceManifest);
trainingManifest.sourceManifestSha256=nbiot.ml.fileSha256(sourceManifestFile);
writeJson(trainingManifestFile,trainingManifest);

refs=struct(); refs.model=makeRef(root,fullfile(modelsFolder,'linearRegression.mat'));
refs.modelSidecar=makeRef(root,fullfile(modelsFolder,'linearRegression.json'));
refs.dataset=makeRef(root,datasetFile); refs.datasetManifest=makeRef(root,manifestFile);
refs.datasetArtifacts=makeRef(root,artifactsFile);
refs.trainingManifest=makeRef(root,trainingManifestFile); refs.metrics=makeRef(root,metricsFile);
refs.sourceManifest=makeRef(root,sourceManifestFile); refs.calibration=makeRef(root,calibrationFile);
refs.registry=makeRef(root,registryFile); refs.policy=makeRef(root,policyFile);
refs.protocol=makeRef(root,protocolFile); refs.evaluation=makeRef(root,evaluationFile);
acceptance=struct('schemaVersion','model-acceptance-v1','status','candidate', ...
    'evidenceKind','test-fixture','featureSchemaVersion','bs-known-v2.0', ...
    'model',refs.model,'modelSidecar',refs.modelSidecar,'dataset',refs.dataset, ...
    'datasetManifest',refs.datasetManifest,'datasetArtifacts',refs.datasetArtifacts, ...
    'trainingManifest',refs.trainingManifest,'metrics',refs.metrics, ...
    'sourceManifest',refs.sourceManifest,'calibration',refs.calibration, ...
    'registry',refs.registry,'policy',refs.policy,'protocol',refs.protocol, ...
    'evaluation',refs.evaluation,'policySha256',policySha, ...
    'trainingIds',[11 12],'validationIds',21,'testIds',31,'policyTuningIds',10, ...
    'scope',protocol.scope,'review',struct('decision','pending','reviewer','', ...
        'reviewedAtUtc','','evidenceDigest','','protocolSha256','','limitations',''));
prepareOptions=struct('modelFile',fullfile(modelsFolder,'linearRegression.mat'), ...
    'datasetFile',datasetFile,'datasetManifestFile',manifestFile, ...
    'datasetArtifactsFile',artifactsFile,'trainingManifestFile',trainingManifestFile, ...
    'metricsFile',metricsFile,'sourceManifestFile',sourceManifestFile, ...
    'calibrationFile',calibrationFile,'registryFile',registryFile, ...
    'policyFile',policyFile,'protocolFile',protocolFile,'evaluationFile',evaluationFile, ...
    'outputFile',fullfile(root,'candidate.json'));
cfg=struct('simulation',struct('numUE',1),'traffic',struct('kind','burst', ...
    'burstDurationTicks',100,'periodTicks',1000,'poissonRatePerSecond',0.2), ...
    'dataset',struct('windowTicks',500),'policy',struct('name','Adaptive-P', ...
        'windowTicks',500,'raShare',0.1,'accessProbability',1));
cfg.calibrationFileSha256=calibrationSha;
execution=struct('profile','external-machine','role','final-comparison', ...
    'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',300,'timePolicy','hard-stop');
f=struct('root',root,'acceptance',acceptance,'protocol',protocol,'policy',policy, ...
    'sourceSha256',sourceSha,'calibrationSha256',calibrationSha, ...
    'paths',struct('metrics',metricsFile,'protocol',protocolFile,'policy',policyFile, ...
        'trainingManifest',trainingManifestFile,'registry',registryFile, ...
        'freeze',freezeFile,'evaluation',evaluationFile,'sourceCode',sourceFile, ...
        'artifacts',artifactsFile,'observations',observationsFile,'targets',targetsFile), ...
    'prepareOptions',prepareOptions,'execution',execution,'cfg',cfg, ...
    'caseMarkerFiles',{caseMarkerFiles},'caseObservationFiles',{caseObservationFiles}, ...
    'caseTargetFiles',{caseTargetFiles});
end

function ref=makeRef(root,path)
relative=strrep(path,[root filesep],'');
ref=struct('file',strrep(relative,'\','/'),'sha256',nbiot.ml.fileSha256(path));
end

function f=refreshMetricsEvidence(f)
training=readJson(f.paths.trainingManifest);
training.metricsSha256=nbiot.ml.fileSha256(f.paths.metrics);
writeJson(f.paths.trainingManifest,training);
f.acceptance.metrics.sha256=nbiot.ml.fileSha256(f.paths.metrics);
f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);
end

function f=refreshEvaluationEvidence(f)
training=readJson(f.paths.trainingManifest);
training.evaluationSha256=nbiot.ml.fileSha256(f.paths.evaluation);
writeJson(f.paths.trainingManifest,training);
f.acceptance.evaluation.sha256=nbiot.ml.fileSha256(f.paths.evaluation);
f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);
end

function f=refreshDatasetArtifactEvidence(f,name)
artifacts=readJson(f.paths.artifacts);
at=find(strcmp({artifacts.files.name},name));
if numel(at)~=1, error('TestModelAcceptance:Artifact','Expected exactly one dataset artifact row.'); end
path=fullfile(fileparts(f.paths.artifacts),name); info=dir(path);
artifacts.files(at).bytes=info.bytes;
artifacts.files(at).sha256=nbiot.ml.fileSha256(path);
writeJson(f.paths.artifacts,artifacts);
training=readJson(f.paths.trainingManifest);
training.datasetArtifactsSha256=nbiot.ml.fileSha256(f.paths.artifacts);
writeJson(f.paths.trainingManifest,training);
f.acceptance.datasetArtifacts.sha256=nbiot.ml.fileSha256(f.paths.artifacts);
f.acceptance.trainingManifest.sha256=nbiot.ml.fileSha256(f.paths.trainingManifest);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end
function value=readJson(path)
value=jsondecode(fileread(path));
end
function writeText(path,value)
fid=fopen(path,'w'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,value,'char');
end
function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
