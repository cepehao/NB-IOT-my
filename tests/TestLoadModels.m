classdef TestLoadModels < matlab.unittest.TestCase
    methods (Test)
        function trainingRejectsHistoricalFeatureSchema(t)
            data=smallTrainingFixture();
            data.schema.version='static-v1.0';
            options=mlTrainingDefaults();
            options.forestNumTrees=2;
            options.boostNumLearningCycles=2;

            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:FeatureSchema');
        end

        function emptyDefaultDatasetPathAllowsDevelopmentValidation(t)
            data=smallTrainingFixture();
            data.schema.version='unsupported-fixture-schema';
            options=mlTrainingDefaults();
            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:FeatureSchema');
        end

        function cannotAuthorizeTruthByRewritingSchema(t)
            data=smallTrainingFixture();
            data.features.trueCollision=zeros(height(data.features),1);
            data.schema.inputNames=[data.schema.inputNames,{'trueCollision'}];
            t.verifyError(@() nbiot.ml.trainLoadModels(data,mlTrainingDefaults()), ...
                'nbiot:ml:FeatureSchema');
        end

        function trainingRequiresExactCanonicalFeatureAndKeySchema(t)
            options=mlTrainingDefaults();

            reordered=smallTrainingFixture();
            canonicalNames=reordered.schema.inputNames;
            reordered.schema.inputNames([1 2])=canonicalNames([2 1]);
            reordered.features=reordered.features(:,reordered.schema.inputNames);
            t.verifyError(@() nbiot.ml.trainLoadModels(reordered,options), ...
                'nbiot:ml:FeatureSchema');

            extraKey=smallTrainingFixture();
            extraKey.features.realizationId=zeros(height(extraKey.features),1);
            extraKey.schema.inputNames=[extraKey.schema.inputNames,{'realizationId'}];
            t.verifyError(@() nbiot.ml.trainLoadModels(extraKey,options), ...
                'nbiot:ml:FeatureSchema');

            missing=smallTrainingFixture();
            missing.features(:,end)=[];
            missing.schema.inputNames(end)=[];
            t.verifyError(@() nbiot.ml.trainLoadModels(missing,options), ...
                'nbiot:ml:FeatureSchema');

            wrongKeys=smallTrainingFixture();
            wrongKeys.schema.keyNames={'windowId'};
            t.verifyError(@() nbiot.ml.trainLoadModels(wrongKeys,options), ...
                'nbiot:ml:FeatureSchema');
        end

        function candidateTrainingRequiresExplicitExperimentRoles(t)
            data=smallTrainingFixture();
            data.manifest.kind='candidate-training';
            data.manifest.allocationsVerified=true;
            options=mlTrainingDefaults();

            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:RoleManifest');
        end

        function candidateTrainingRejectsDefaultAllSplitsBeforeFit(t)
            data=verifiedCandidateFixture();
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            [datasetFile,~,~,data]=writeCandidateDataset(root,data);

            defaultOptions=mlTrainingDefaults();
            if isfield(defaultOptions,'evaluationMode')
                missingOptions=rmfield(defaultOptions,'evaluationMode');
            else
                missingOptions=defaultOptions;
            end
            explicitAllSplits=defaultOptions;
            explicitAllSplits.evaluationMode='development-all-splits';
            variants={defaultOptions,missingOptions,explicitAllSplits};
            for k=1:numel(variants)
                options=variants{k};
                options.datasetFile=datasetFile;
                options.outputFolder=fullfile(root,sprintf('rejected-models-%d',k));
                t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                    'nbiot:ml:EvaluationMode');
                t.verifyFalse(isfolder(options.outputFolder));
            end
        end

        function selectionOnlyWritesTenRowsAndPreservesTestReservation(t)
            data=smallTrainingFixture();
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            options=mlTrainingDefaults();
            options.evaluationMode='selection-only';
            options.outputFolder=fullfile(root,'selection');
            options.forestNumTrees=2; options.boostNumLearningCycles=2;

            [bundles,report]=nbiot.ml.trainLoadModels(data,options);

            manifest=jsondecode(fileread(fullfile(options.outputFolder, ...
                'training-manifest.json')));
            reservedTestIds=unique(data.rowInfo.realizationId( ...
                data.rowInfo.split=="test")).';
            t.verifyEqual(height(report.metrics),10);
            t.verifyFalse(any(report.metrics.split=="test"));
            t.verifyEqual(numel(unique(report.metrics.model)),5);
            t.verifyEqual(sum(report.metrics.model=="trainMean"),2);
            t.verifyEqual(manifest.phase,'selection');
            t.verifyEqual(manifest.metricsRowCount,10);
            t.verifyEqual(manifest.testIds,reservedTestIds);
            t.verifyEqual(manifest.splitEvidence(3).sampleCount,6);
            t.verifyEqual(bundles(1).bundle.testIds,reservedTestIds);
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics( ...
                bundles(1).file,bundles(1).bundle));
        end

        function selectionOnlyTestTargetsDoNotAffectChosenModels(t)
            original=smallTrainingFixture();
            changed=original;
            testRows=changed.rowInfo.split=="test";
            changed.targets.meanRaUe(testRows)=changed.targets.meanRaUe(testRows)+1e6;
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            options=mlTrainingDefaults();
            options.evaluationMode='selection-only';
            options.forestNumTrees=2; options.boostNumLearningCycles=2;
            firstOptions=options; firstOptions.outputFolder=fullfile(root,'first');
            secondOptions=options; secondOptions.outputFolder=fullfile(root,'second');

            [firstBundles,firstReport]=nbiot.ml.trainLoadModels(original,firstOptions);
            [secondBundles,secondReport]=nbiot.ml.trainLoadModels(changed,secondOptions);

            t.verifyEqual(firstReport.bestValidationModel,secondReport.bestValidationModel);
            scoreColumns={'model','split','sampleCount','idCount','mae','rmse','bias'};
            t.verifyEqual(firstReport.metrics(:,scoreColumns), ...
                secondReport.metrics(:,scoreColumns));
            validationRow=original.observations( ...
                find(original.rowInfo.split=="validation",1),:);
            limits=struct('minimum',0,'maximum',1e9);
            for k=1:numel(firstBundles)
                firstPrediction=nbiot.ml.predictLoad( ...
                    firstBundles(k).bundle,validationRow,limits);
                secondPrediction=nbiot.ml.predictLoad( ...
                    secondBundles(k).bundle,validationRow,limits);
                t.verifyTrue(firstPrediction.valid,firstPrediction.reason);
                t.verifyTrue(secondPrediction.valid,secondPrediction.reason);
                t.verifyEqual(firstPrediction.value,secondPrediction.value,'AbsTol',1e-12);
            end
        end

        function candidateTrainingRequiresPersistedSourceManifest(t)
            data=verifiedCandidateFixture();
            options=mlTrainingDefaults(); options.evaluationMode='selection-only';
            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:DataProvenance');

            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            datasetFile=fullfile(root,'dataset.mat'); save(datasetFile,'data');
            options=mlTrainingDefaults(); options.datasetFile=datasetFile;
            options.evaluationMode='selection-only';
            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:DataProvenance');
        end

        function candidateTrainingAcceptsPersistedCasesSharingAnId(t)
            data=verifiedCandidateFixture();
            sharedId=data.rowInfo.realizationId==11 & data.rowInfo.windowId>3;
            data.rowInfo.caseKey(sharedId)="fixture-11-second-case";
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            [datasetFile,sourceHash,calibrationHash,data]=writeCandidateDataset(root,data);
            outputFolder=fullfile(root,'models');
            options=mlTrainingDefaults(); options.datasetFile=datasetFile;
            options.evaluationMode='selection-only';
            options.outputFolder=outputFolder;
            options.forestNumTrees=2; options.boostNumLearningCycles=2;

            runnerOptions=struct('datasetFile',datasetFile, ...
                'outputFolder',outputFolder,'trainingOptions',options);
            [bundles,report]=trainLoadModels(runnerOptions);

            manifest=jsondecode(fileread(fullfile(outputFolder,'training-manifest.json')));
            t.verifyEqual(manifest.dataKind,'candidate-training');
            t.verifyTrue(manifest.allocationsVerified);
            t.verifyEqual(manifest.sourceSha256,sourceHash);
            t.verifyEqual(manifest.calibrationSha256,calibrationHash);
            t.verifyEqual(report.dataKind,'candidate-training');
            t.verifyTrue(report.allocationsVerified);
            t.verifyEqual(report.datasetFile,'dataset.mat');
            t.verifyEqual(report.datasetSha256,nbiot.ml.fileSha256(datasetFile));
            t.verifyEqual(report.datasetManifestSha256, ...
                nbiot.ml.fileSha256(fullfile(outputFolder,'dataset-manifest.json')));
            t.verifyEqual(report.sourceSha256,sourceHash);
            t.verifyEqual(report.calibrationSha256,calibrationHash);
            t.verifyEqual([report.splitEvidence.sampleCount],[18 6 6]);
            t.verifyEqual([report.splitEvidence.idCount],[3 1 1]);
            t.verifyEqual(report.splitEvidence(1).ids,[11 12 13]);
            datasetManifest=jsondecode(fileread( ...
                fullfile(outputFolder,'dataset-manifest.json')));
            t.verifyEqual(numel(datasetManifest.inputs),6);
            sidecar=jsondecode(fileread(fullfile(outputFolder,'linearRegression.json')));
            t.verifyEqual(sidecar.dataKind,'candidate-training');
            t.verifyTrue(sidecar.allocationsVerified);
            t.verifyEqual(manifest.phase,'selection');
            t.verifyEqual(manifest.metricsRowCount,10);
            t.verifyFalse(any(report.metrics.split=="test"));
            metrics=nbiot.ml.loadModelEvaluationMetrics(bundles(1).file,bundles(1).bundle);
            t.verifyEmpty(metrics);
        end

        function candidateTrainingRejectsInputForUnknownCase(t)
            data=verifiedCandidateFixture();
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            [datasetFile,~,~,data]=writeCandidateDataset(root,data);
            data.manifest.inputs(end+1)=data.manifest.inputs(1);
            data.manifest.inputs(end).caseKey='not-present-in-rowInfo';
            save(datasetFile,'data');
            datasetManifest=data.manifest;
            datasetManifest.assignments=table2struct(datasetManifest.assignments);
            writeJson(fullfile(root,'manifest.json'),datasetManifest);
            options=mlTrainingDefaults(); options.datasetFile=datasetFile;
            options.evaluationMode='selection-only';

            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:DataProvenance');
        end

        function assignmentsMustMatchExactlyTheUsedRows(t)
            data=smallTrainingFixture();
            data.manifest.assignments(end+1,:)=table(99,"train","training", ...
                'VariableNames',data.manifest.assignments.Properties.VariableNames);
            t.verifyError(@() nbiot.ml.trainLoadModels(data,mlTrainingDefaults()), ...
                'nbiot:ml:DataProvenance');
        end

        function selectedDatasetBytesMustMatchInMemoryData(t)
            data=smallTrainingFixture();
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            datasetFile=fullfile(root,'dataset.mat'); save(datasetFile,'data');
            changed=data; changed.features{1,1}=changed.features{1,1}+1;
            options=mlTrainingDefaults(); options.datasetFile=datasetFile;
            t.verifyError(@() nbiot.ml.trainLoadModels(changed,options), ...
                'nbiot:ml:DataProvenance');
        end

        function candidateTrainingRejectsFinalComparisonRole(t)
            data=verifiedCandidateFixture();
            data.rowInfo.experimentRole(data.rowInfo.realizationId==31)="final-comparison";
            data.manifest.assignments.experimentRole( ...
                data.manifest.assignments.externalRealizationId==31)="final-comparison";
            options=mlTrainingDefaults();

            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:FinalComparison');
        end

        function candidateTrainingRejectsRoleSplitMismatch(t)
            data=verifiedCandidateFixture();
            data.rowInfo.experimentRole(data.rowInfo.realizationId==31)="training";
            data.manifest.assignments.experimentRole( ...
                data.manifest.assignments.externalRealizationId==31)="training";
            options=mlTrainingDefaults();

            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:RoleManifest');
        end

        function fourModelsTrainUseTrainOnlyTransformsAndReload(t)
            data=smallTrainingFixture();
            functionPath=which('nbiot.ml.trainLoadModels');
            t.assertTrue(~isempty(functionPath), ...
                'Load forecasting trainer is not implemented yet.');

            outputFolder=tempname;
            t.addTeardown(@() removeFolder(outputFolder));
            options=mlTrainingDefaults();
            options.outputFolder=outputFolder;
            options.forestNumTrees=8;
            options.boostNumLearningCycles=8;
            [bundles,report]=nbiot.ml.trainLoadModels(data,options);

            expectedNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
            t.verifyEqual({bundles.name},expectedNames);
            t.verifyEqual(numel(bundles),4);
            t.verifyTrue(all(ismember({'model','split','sampleCount','idCount', ...
                'mae','rmse','bias','predictionSeconds'},report.metrics.Properties.VariableNames)));
            t.verifyEqual(sum(report.metrics.model=="trainMean"),3);
            t.verifyTrue(any(report.metrics.model==report.bestValidationModel & ...
                report.metrics.split=="validation"));

            trainRows=data.rowInfo.split=="train";
            trainFeatures=data.features{trainRows,:};
            medians=median(trainFeatures,1,'omitnan');
            imputed=trainFeatures;
            for column=1:size(imputed,2)
                missing=isnan(imputed(:,column));
                imputed(missing,column)=medians(column);
            end
            expectedMean=mean(imputed,1);
            expectedScale=std(imputed,0,1);
            expectedScale(expectedScale<=eps)=1;
            for modelIndex=1:numel(bundles)
                bundle=bundles(modelIndex).bundle;
                t.verifyEqual(bundle.status,'development');
                t.verifyEqual(bundle.dataKind,'development-fixture');
                t.verifyEqual(bundle.targetName,'meanRaUe');
                t.verifyEqual(bundle.featureNames,data.schema.inputNames);
                t.verifyEqual(bundle.trainingIds,unique(data.rowInfo.realizationId(trainRows)).');
                t.verifyEqual(bundle.transform.median,medians,'AbsTol',1e-12);
                t.verifyEqual(bundle.transform.mean,expectedMean,'AbsTol',1e-12);
                t.verifyEqual(bundle.transform.scale,expectedScale,'AbsTol',1e-12);
                t.verifyTrue(isfile(bundles(modelIndex).file));
                t.verifyEqual(numel(bundles(modelIndex).sha256),64);
            end

            spoofedBundle=bundles(1).bundle;
            spoofedSchema=data.schema;
            spoofedBundle.featureNames{1}='trueCollision';
            spoofedBundle.schemaVersion=spoofedSchema.version;
            spoofedSchema.inputNames{1}='trueCollision';
            t.verifyError(@() nbiot.ml.validateModelBundle(spoofedBundle,spoofedSchema), ...
                'nbiot:ml:FeatureSchema');

            validationRow=data.observations(find(data.rowInfo.split=="validation",1),:);
            limits=struct('minimum',0,'maximum',10);
            for modelIndex=1:numel(bundles)
                estimate=nbiot.ml.predictLoad(bundles(modelIndex).bundle,validationRow,limits);
                t.verifyTrue(estimate.valid,estimate.reason);
                t.verifyEqual(estimate.featureWindowEndTick,validationRow.endTick);
                loaded=nbiot.ml.validateModelBundle(bundles(modelIndex).file,data.schema);
                reloaded=nbiot.ml.predictLoad(loaded,validationRow,limits);
                t.verifyEqual(reloaded.value,estimate.value,'AbsTol',1e-12);
            end

            wrongOrder=validationRow(:,end:-1:1);
            t.verifyError(@() nbiot.ml.predictLoad(bundles(1).bundle,wrongOrder,limits), ...
                'nbiot:ml:FeatureOrder');
            invalidSchema=bundles(1).bundle;
            invalidSchema.schemaVersion='unsupported-version';
            t.verifyError(@() nbiot.ml.validateModelBundle(invalidSchema,data.schema), ...
                'nbiot:ml:SchemaMismatch');
            t.verifyError(@() nbiot.ml.validateModelBundle( ...
                fullfile(outputFolder,'missing-model.mat'),data.schema), ...
                'nbiot:ml:MissingModel');
            nanBundle=bundles(1).bundle;
            nanBundle.model=NaNRegressionPredictor();
            nonfinite=nbiot.ml.predictLoad(nanBundle,validationRow,limits);
            t.verifyFalse(nonfinite.valid);
            t.verifyEqual(nonfinite.reason,'nonfinite-prediction');
            outside=nbiot.ml.predictLoad(bundles(1).bundle,validationRow, ...
                struct('minimum',1000,'maximum',1001));
            t.verifyFalse(outside.valid);
            t.verifyEqual(outside.reason,'prediction-outside-public-limits');

            fid=fopen(bundles(1).file,'a');
            fwrite(fid,uint8(0)); fclose(fid);
            t.verifyError(@() nbiot.ml.validateModelBundle(bundles(1).file,data.schema), ...
                'nbiot:ml:PackageHash');
        end

        function mixedIdsLeakingTargetsAndUnverifiedRealDataAreRejected(t)
            data=smallTrainingFixture();
            options=mlTrainingDefaults();

            mixed=data;
            mixed.rowInfo.split(2)="validation";
            t.verifyError(@() nbiot.ml.trainLoadModels(mixed,options), ...
                'nbiot:ml:GroupLeakage');

            leaked=data;
            leaked.features.meanRaUe=leaked.targets.meanRaUe;
            t.verifyError(@() nbiot.ml.trainLoadModels(leaked,options), ...
                'nbiot:ml:FeatureSchema');

            unverified=data;
            unverified.manifest.kind='candidate-training';
            unverified.manifest.allocationsVerified=false;
            t.verifyError(@() nbiot.ml.trainLoadModels(unverified,options), ...
                'nbiot:ml:DataPurpose');

            missing=data;
            trainRows=missing.rowInfo.split=="train";
            missing.features{trainRows,1}=NaN;
            t.verifyError(@() nbiot.ml.trainLoadModels(missing,options), ...
                'nbiot:ml:TrainingFeatureMissing');
        end

        function runnerLoadsAnExplicitDatasetAndWritesModelFiles(t)
            data=smallTrainingFixture();
            functionPath=which('trainLoadModels');
            t.assertTrue(~isempty(functionPath),'Training runner is not implemented yet.');
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            datasetFile=fullfile(root,'dataset.mat'); save(datasetFile,'data');
            datasetManifest=data.manifest;
            datasetManifest.assignments=table2struct(datasetManifest.assignments);
            writeJson(fullfile(root,'manifest.json'),datasetManifest);
            outputFolder=fullfile(root,'models');
            trainingOptions=mlTrainingDefaults();
            trainingOptions.forestNumTrees=8;
            trainingOptions.boostNumLearningCycles=8;
            options=struct('datasetFile',datasetFile,'outputFolder',outputFolder, ...
                'trainingOptions',trainingOptions);
            [bundles,report]=trainLoadModels(options);
            t.verifyEqual(numel(bundles),4);
            t.verifyEqual(report.status,'development');
            t.verifyTrue(isfile(fullfile(outputFolder,'metrics.csv')));
            t.verifyTrue(isfile(fullfile(outputFolder,'training-manifest.json')));
            t.verifyTrue(isfile(fullfile(outputFolder,'dataset-manifest.json')));
            trainingManifest=jsondecode(fileread(fullfile(outputFolder,'training-manifest.json')));
            t.verifyEqual(trainingManifest.formatVersion,'load-training-report-v2');
            t.verifyEqual(trainingManifest.phase,'evaluated');
            t.verifyEqual(height(report.metrics),15);
            t.verifyTrue(any(report.metrics.split=="test"));
            t.verifyEqual(trainingManifest.datasetFile,'dataset.mat');
            t.verifyEqual(trainingManifest.datasetSha256,nbiot.ml.fileSha256(datasetFile));
            t.verifyEqual(trainingManifest.datasetManifestFile,'dataset-manifest.json');
            t.verifyEqual(trainingManifest.datasetManifestSha256, ...
                nbiot.ml.fileSha256(fullfile(outputFolder,'dataset-manifest.json')));
            t.verifyEqual(trainingManifest.metricsRowCount,15);
            t.verifyEqual(trainingManifest.metricsSha256, ...
                nbiot.ml.fileSha256(fullfile(outputFolder,'metrics.csv')));
            t.verifyEqual(numel(trainingManifest.splitEvidence),3);
            t.verifyEqual(trainingManifest.splitEvidence(1).ids(:).',[11 12 13]);
            t.verifyEqual([trainingManifest.splitEvidence.sampleCount],[18 6 6]);
            t.verifyEqual([trainingManifest.splitEvidence.idCount],[3 1 1]);
            t.verifyFalse(trainingManifest.allocationsVerified);
            sidecar=jsondecode(fileread(fullfile(outputFolder,'linearRegression.json')));
            t.verifyEqual(sidecar.dataKind,'development-fixture');
            t.verifyFalse(sidecar.allocationsVerified);
        end

        function runnerRequiresAnExplicitDatasetWithDataVariable(t)
            root=tempname; mkdir(root);
            t.addTeardown(@() removeFolder(root));
            outputFolder=fullfile(root,'models');
            missingOptions=struct('datasetFile',fullfile(root,'missing.mat'), ...
                'outputFolder',outputFolder);
            t.verifyError(@() trainLoadModels(missingOptions),'nbiot:ml:DatasetFile');

            unrelated=1;
            datasetFile=fullfile(root,'unrelated.mat'); save(datasetFile,'unrelated');
            options=struct('datasetFile',datasetFile,'outputFolder',outputFolder);
            t.verifyError(@() trainLoadModels(options),'nbiot:ml:DatasetFile');

            options.datasetFile=fullfile(root,'another.mat');
            save(options.datasetFile,'unrelated');
            options.unexpectedPath='auto-search';
            t.verifyError(@() trainLoadModels(options),'nbiot:ml:RunnerOptions');
        end

        function sameSeedReproducesAllFourPredictions(t)
            data=smallTrainingFixture();
            options=mlTrainingDefaults();
            options.seed=17;
            options.forestNumTrees=8;
            options.boostNumLearningCycles=8;
            first=nbiot.ml.trainLoadModels(data,options);
            second=nbiot.ml.trainLoadModels(data,options);
            row=data.observations(find(data.rowInfo.split=="validation",1),:);
            limits=struct('minimum',0,'maximum',10);
            for k=1:numel(first)
                a=nbiot.ml.predictLoad(first(k).bundle,row,limits);
                b=nbiot.ml.predictLoad(second(k).bundle,row,limits);
                t.verifyEqual(b.value,a.value,'AbsTol',1e-12);
            end
        end
    end
end

function data=smallTrainingFixture()
data=smallLoadTrainingFixture();
end

function data=verifiedCandidateFixture()
data=smallTrainingFixture();
data.manifest.kind='candidate-training';
data.manifest.allocationsVerified=true;
data.manifest.experimentRolesExplicit=true;
roles=data.rowInfo.split;
roles(roles=="train")="training";
roles(roles=="test")="model-test";
data.rowInfo.experimentRole=roles;
data.manifest.assignments.experimentRole=data.manifest.assignments.split;
data.manifest.assignments.experimentRole( ...
    data.manifest.assignments.experimentRole=="train")="training";
data.manifest.assignments.experimentRole( ...
    data.manifest.assignments.experimentRole=="test")="model-test";
end

function [datasetFile,sourceHash,calibrationHash,data]=writeCandidateDataset(root,data)
sourceFile=fullfile(root,'source.bin'); calibrationFile=fullfile(root,'calibration.bin');
writeBytes(sourceFile,uint8('candidate fixture source bytes'));
writeBytes(calibrationFile,uint8('candidate fixture calibration bytes'));
sourceHash=nbiot.ml.fileSha256(sourceFile);
calibrationHash=nbiot.ml.fileSha256(calibrationFile);
caseKeys=unique(string(data.rowInfo.caseKey),'stable');
template=struct('caseKey','','realizationId',0,'sourceSha256',sourceHash, ...
    'calibrationSha256',calibrationHash,'isFixture',false);
inputs=repmat(template,1,numel(caseKeys));
for k=1:numel(caseKeys)
    at=string(data.rowInfo.caseKey)==caseKeys(k);
    ids=unique(data.rowInfo.realizationId(at));
    inputs(k).caseKey=char(caseKeys(k));
    inputs(k).realizationId=ids(1);
end
data.manifest.inputs=inputs;
datasetFile=fullfile(root,'dataset.mat');
save(datasetFile,'data');
datasetManifest=data.manifest;
datasetManifest.assignments=table2struct(datasetManifest.assignments);
writeJson(fullfile(root,'manifest.json'),datasetManifest);
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end

function writeBytes(path,bytes)
fid=fopen(path,'wb');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,bytes,'uint8');
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end
