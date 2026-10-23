classdef TestModelEvaluationMetrics < matlab.unittest.TestCase
    methods (Test)
        function loadsTrainValidationAndTestScoresForMatchingModel(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder);
            writeMetrics(folder);

            metrics=nbiot.ui.loadModelEvaluationMetrics(modelFile, ...
                struct('modelName','linearRegression','trainingIds',[11 12], ...
                'validationIds',21,'testIds',31));

            t.verifyEqual(string(metrics.split),["train";"validation";"test"]);
            t.verifyEqual(metrics.mae,[.2;.3;.4]);
            t.verifyEqual(metrics.rmse,[.3;.4;.5]);
        end

        function shuffledMetricsRowsStillReturnCanonicalSplitOrder(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            metricsFile=fullfile(folder,'metrics.csv');
            scores=readtable(metricsFile);
            scores=flipud(scores);
            writetable(scores,metricsFile);
            updateMetricsHash(folder);

            metrics=nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle());

            t.verifyEqual(string(metrics.split),["train";"validation";"test"]);
            t.verifyEqual(metrics.mae,[.2;.3;.4]);
        end

        function selectionPhaseReturnsUnavailableForTenRows(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            writeSelectionMetrics(folder);
            scores=readtable(fullfile(folder,'metrics.csv'),'TextType','string');
            manifest=readTrainingManifest(folder);

            t.verifyEqual(height(scores),10);
            t.verifyEqual(manifest.metricsRowCount,10);
            t.verifyEqual(manifest.phase,'selection');
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()));
        end

        function selectionPhaseRejectsAnyTestScoreRow(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            writeSelectionMetrics(folder);
            metricsFile=fullfile(folder,'metrics.csv');
            scores=readtable(metricsFile,'TextType','string');
            testRow=scores(1,:);
            testRow.split="test";
            testRow.model="linearRegression";
            testRow.sampleCount=1; testRow.idCount=1;
            scores(end+1,:)=testRow;
            writetable(scores,metricsFile);
            manifest=readTrainingManifest(folder);
            manifest.metricsRowCount=height(scores);
            manifest.metricsSha256=nbiot.ml.fileSha256(metricsFile);
            writeJson(fullfile(folder,'training-manifest.json'),manifest);

            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()));
        end

        function missingOrUnknownPhaseReturnsUnavailable(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);

            manifest=readTrainingManifest(folder);
            manifest.phase='unknown';
            writeJson(fullfile(folder,'training-manifest.json'),manifest);
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()), ...
                'Unknown phase');

            manifest=rmfield(manifest,'phase');
            writeJson(fullfile(folder,'training-manifest.json'),manifest);
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()), ...
                'Missing phase');
        end

        function acceptsDevelopmentManifestWithMultipleCasesPerRealization(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            writeDevelopmentProvenance(folder,true);

            metrics=nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle());

            t.verifyEqual(string(metrics.split),["train";"validation";"test"]);
            t.verifyEqual(metrics.mae,[.2;.3;.4]);
        end

        function acceptsDevelopmentFixtureWithNonemptyHashes(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            writeDevelopmentProvenance(folder,false);

            metrics=nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle());

            t.verifyEqual(string(metrics.split),["train";"validation";"test"]);
            t.verifyEqual(metrics.mae,[.2;.3;.4]);
        end

        function acceptsPersistedCandidateStructuralManifest(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            % Structural test fixture only; this is not admission evidence.
            writeCandidateStructuralProvenance(folder);

            metrics=nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle());

            t.verifyEqual(string(metrics.split),["train";"validation";"test"]);
            t.verifyEqual(metrics.mae,[.2;.3;.4]);
        end

        function rejectsMalformedInputHashWithUpdatedDatasetManifestHash(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            writeDevelopmentProvenance(folder,false);
            datasetManifestFile=fullfile(folder,'dataset-manifest.json');
            datasetManifest=jsondecode(fileread(datasetManifestFile));
            datasetManifest.inputs(1).sourceSha256='bad-digest';
            writeJson(datasetManifestFile,datasetManifest);
            manifest=readTrainingManifest(folder);
            manifest.datasetManifestSha256=nbiot.ml.fileSha256(datasetManifestFile);
            writeJson(fullfile(folder,'training-manifest.json'),manifest);

            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()));
        end

        function ignoresMetricsWhenTheModelFileHashChanged(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder);
            writeMetrics(folder);
            fid=fopen(modelFile,'a');
            cleanup=onCleanup(@() fclose(fid));
            fwrite(fid,'changed','char');

            metrics=nbiot.ui.loadModelEvaluationMetrics(modelFile, ...
                struct('modelName','linearRegression','trainingIds',[11 12], ...
                'validationIds',21,'testIds',31));

            t.verifyEmpty(metrics);
        end

        function ignoresMetricsWhenTheCsvHashChanged(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            scores=readtable(fullfile(folder,'metrics.csv'));
            scores.mae(1)=scores.mae(1)+.01;
            writetable(scores,fullfile(folder,'metrics.csv'));
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()));
        end

        function changedScoreIsNotVerified(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            scores=readtable(fullfile(folder,'metrics.csv'));
            scores.mae(1)=scores.mae(1)+1;
            writetable(scores,fullfile(folder,'metrics.csv'));
            updateMetricsHash(folder);
            bundle=struct('modelName','linearRegression', ...
                'trainingIds',[11 12],'validationIds',21,'testIds',31);
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,bundle));
        end

        function rejectsMalformedMetricsAndProvenanceAsAWhole(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder);
            cases={'wrongModel','duplicateTrain','negativeMae','negativeRmse', ...
                'nanMae','infiniteRmse','fractionalCount','zeroCount', ...
                'countBelowIdCount','idCountMismatch','idsDiffer','overlappingIds', ...
                'missingTest','unknownSplit','rowCountMismatch', ...
                'duplicateModelAndArtifact'};
            for k=1:numel(cases)
                writeMetrics(folder);
                manifest=readTrainingManifest(folder);
                scores=readtable(fullfile(folder,'metrics.csv'),'TextType','string');
                bundle=metricBundle();
                switch cases{k}
                    case 'wrongModel'
                        scores.model(1)="decisionTree";
                    case 'duplicateTrain'
                        scores(end+1,:)=scores(1,:);
                    case 'negativeMae'
                        scores.mae(1)=-.1;
                    case 'negativeRmse'
                        scores.rmse(1)=-.1;
                    case 'nanMae'
                        scores.mae(1)=NaN;
                    case 'infiniteRmse'
                        scores.rmse(1)=Inf;
                    case 'fractionalCount'
                        scores.sampleCount(1)=2.5;
                    case 'zeroCount'
                        scores.sampleCount(1)=0;
                    case 'countBelowIdCount'
                        scores.sampleCount(1)=1;
                    case 'idCountMismatch'
                        scores.idCount(1)=1;
                    case 'idsDiffer'
                        bundle.trainingIds=11;
                    case 'overlappingIds'
                        manifest.validationIds=12;
                        manifest.splitEvidence(2).ids=12;
                        bundle.validationIds=12;
                    case 'missingTest'
                        scores(scores.split=="test",:)=[];
                    case 'unknownSplit'
                        scores.split(1)="development";
                    case 'rowCountMismatch'
                        manifest.metricsRowCount=5;
                    case 'duplicateModelAndArtifact'
                        manifest.modelNames=["linearRegression";"linearRegression"];
                        manifest.artifactFiles=["linearRegression.mat";"linearRegression.mat"];
                        oneHash=string(manifest.artifactSha256);
                        oneHash=oneHash(1);
                        manifest.artifactSha256=[oneHash;oneHash];
                end
                writetable(scores,fullfile(folder,'metrics.csv'));
                if ~strcmp(cases{k},'rowCountMismatch')
                    manifest.metricsRowCount=height(scores);
                end
                manifest.metricsSha256=nbiot.ml.fileSha256(fullfile(folder,'metrics.csv'));
                writeJson(fullfile(folder,'training-manifest.json'),manifest);
                t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,bundle),cases{k});
            end
        end

        function oldTrainingManifestWithoutCsvHashIsUnavailable(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            modelFile=writeModelFixture(folder); writeMetrics(folder);
            oldManifest=struct('formatVersion','load-training-report-v1', ...
                'modelNames',{{'linearRegression'}}, ...
                'artifactFiles',{{'linearRegression.mat'}}, ...
                'artifactSha256',{{nbiot.ml.fileSha256(modelFile)}});
            writeJson(fullfile(folder,'training-manifest.json'),oldManifest);
            t.verifyEmpty(nbiot.ml.loadModelEvaluationMetrics(modelFile,metricBundle()));
        end
    end
end

function modelFile=writeModelFixture(folder)
modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
for k=1:numel(modelNames)
    bundle=struct('modelName',modelNames{k},'trainingIds',[11 12], ...
        'validationIds',21,'testIds',31);
    save(fullfile(folder,[modelNames{k} '.mat']),'bundle');
end
modelFile=fullfile(folder,'linearRegression.mat');
end

function writeMetrics(folder)
modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
splitNames={'train','validation','test'};
sampleCounts=[2 1 1]; idCounts=[2 1 1];
modelMae=[.2 .3 .4; .22 .32 .42; .24 .34 .44; .26 .36 .46; .25 .35 .45];
metricRows=cell(0,6);
for modelIndex=1:numel(modelNames)+1
    if modelIndex<=numel(modelNames)
        modelName=modelNames{modelIndex};
        maeValues=modelMae(modelIndex,:);
    else
        modelName='trainMean';
        maeValues=modelMae(end,:);
    end
    for splitIndex=1:numel(splitNames)
        mae=maeValues(splitIndex);
        metricRows(end+1,:)={string(modelName),string(splitNames{splitIndex}), ...
            sampleCounts(splitIndex),idCounts(splitIndex),mae,mae+.1}; %#ok<AGROW>
    end
end
metrics=cell2table(metricRows,'VariableNames', ...
    {'model','split','sampleCount','idCount','mae','rmse'});
writetable(metrics,fullfile(folder,'metrics.csv'));
artifactFiles=cellfun(@(name)[name '.mat'],modelNames,'UniformOutput',false);
artifactSha256=cellfun(@(file)nbiot.ml.fileSha256(fullfile(folder,file)), ...
    artifactFiles,'UniformOutput',false);
manifest=struct('formatVersion','load-training-report-v2','phase','evaluated', ...
    'modelNames',{modelNames},'artifactFiles',{artifactFiles}, ...
    'artifactSha256',{artifactSha256}, ...
    'trainingIds',[11 12],'validationIds',21,'testIds',31, ...
    'splitEvidence',struct( ...
        'split',{'train','validation','test'}, ...
        'ids',{[11 12],21,31},'sampleCount',{2,1,1},'idCount',{2,1,1}), ...
    'metricsFile','metrics.csv','metricsSha256', ...
        nbiot.ml.fileSha256(fullfile(folder,'metrics.csv')), ...
    'metricsRowCount',height(metrics),'dataKind','development-fixture');
manifest.allocationsVerified=false;
manifest.datasetFile=''; manifest.datasetSha256='';
manifest.datasetManifestFile='dataset-manifest.json'; manifest.datasetManifestSha256='';
manifest.sourceSha256=''; manifest.calibrationSha256='';
writeJson(fullfile(folder,'training-manifest.json'),manifest);
end

function writeSelectionMetrics(folder)
metricsFile=fullfile(folder,'metrics.csv');
scores=readtable(metricsFile,'TextType','string');
scores(scores.split=="test",:)=[];
writetable(scores,metricsFile);
manifest=readTrainingManifest(folder);
manifest.phase='selection';
manifest.metricsRowCount=height(scores);
manifest.metricsSha256=nbiot.ml.fileSha256(metricsFile);
writeJson(fullfile(folder,'training-manifest.json'),manifest);
end

function bundle=metricBundle()
bundle=struct('modelName','linearRegression','trainingIds',[11 12], ...
    'validationIds',21,'testIds',31);
end

function manifest=readTrainingManifest(folder)
manifest=jsondecode(fileread(fullfile(folder,'training-manifest.json')));
end

function updateMetricsHash(folder)
manifestFile=fullfile(folder,'training-manifest.json');
manifest=jsondecode(fileread(manifestFile));
manifest.metricsSha256=nbiot.ml.fileSha256(fullfile(folder,'metrics.csv'));
writeJson(manifestFile,manifest);
end

function writeDevelopmentProvenance(folder,repeatCases)
manifestFile=fullfile(folder,'training-manifest.json');
manifest=jsondecode(fileread(manifestFile));
sourceFile=fullfile(folder,'fixture-source.bin');
calibrationFile=fullfile(folder,'fixture-calibration.bin');
writeBytes(sourceFile,uint8('fixture source bytes'));
writeBytes(calibrationFile,uint8('fixture calibration bytes'));
sourceHash=nbiot.ml.fileSha256(sourceFile);
calibrationHash=nbiot.ml.fileSha256(calibrationFile);
inputTemplate=struct('caseKey','','realizationId',0,'sourceSha256',sourceHash, ...
    'calibrationSha256',calibrationHash,'isFixture',true);
if repeatCases
    inputs=repmat(inputTemplate,1,6);
    caseKeys={'case-11-a','case-11-b','case-12-a','case-12-b','case-21','case-31'};
    inputIds=[11 11 12 12 21 31];
else
    inputs=repmat(inputTemplate,1,4);
    caseKeys={'case-11','case-12','case-21','case-31'};
    inputIds=[11 12 21 31];
end
for k=1:numel(inputs)
    inputs(k).caseKey=caseKeys{k};
    inputs(k).realizationId=inputIds(k);
end
assignments=struct('externalRealizationId',{11,12,21,31}, ...
    'split',{'train','train','validation','test'}, ...
    'experimentRole',{'training','training','validation','model-test'});
datasetManifest=struct('kind','development-fixture','assignments',assignments, ...
    'inputs',inputs,'allocationsVerified',false,'experimentRolesExplicit',false);
datasetManifestFile=fullfile(folder,'dataset-manifest.json');
writeJson(datasetManifestFile,datasetManifest);
datasetFile=fullfile(folder,'dataset.mat');
fid=fopen(datasetFile,'wb'); fwrite(fid,uint8('dataset bytes')); fclose(fid);
manifest.dataKind='development-fixture'; manifest.allocationsVerified=false;
manifest.datasetFile='dataset.mat'; manifest.datasetSha256=nbiot.ml.fileSha256(datasetFile);
manifest.datasetManifestFile='dataset-manifest.json';
manifest.datasetManifestSha256=nbiot.ml.fileSha256(datasetManifestFile);
manifest.sourceSha256=sourceHash; manifest.calibrationSha256=calibrationHash;
writeJson(manifestFile,manifest);
end

function writeCandidateStructuralProvenance(folder)
manifestFile=fullfile(folder,'training-manifest.json');
manifest=jsondecode(fileread(manifestFile));
sourceFile=fullfile(folder,'structural-source.bin');
calibrationFile=fullfile(folder,'structural-calibration.bin');
writeBytes(sourceFile,uint8('structural source fixture'));
writeBytes(calibrationFile,uint8('structural calibration fixture'));
sourceHash=nbiot.ml.fileSha256(sourceFile);
calibrationHash=nbiot.ml.fileSha256(calibrationFile);
inputIds=[11 12 21 31];
caseKeys={'structural-11','structural-12','structural-21','structural-31'};
inputs=repmat(struct('caseKey','','realizationId',0,'sourceSha256',sourceHash, ...
    'calibrationSha256',calibrationHash,'isFixture',false),1,numel(inputIds));
for k=1:numel(inputs)
    inputs(k).caseKey=caseKeys{k};
    inputs(k).realizationId=inputIds(k);
end
assignments=struct('externalRealizationId',{11,12,21,31}, ...
    'split',{'train','train','validation','test'}, ...
    'experimentRole',{'training','training','validation','model-test'});
datasetManifest=struct('kind','candidate-training','assignments',assignments, ...
    'inputs',inputs,'allocationsVerified',true,'experimentRolesExplicit',true);
datasetManifestFile=fullfile(folder,'dataset-manifest.json');
writeJson(datasetManifestFile,datasetManifest);
datasetFile=fullfile(folder,'structural-dataset.mat');
writeBytes(datasetFile,uint8('structural candidate dataset fixture'));
manifest.dataKind='candidate-training'; manifest.allocationsVerified=true;
manifest.datasetFile='structural-dataset.mat';
manifest.datasetSha256=nbiot.ml.fileSha256(datasetFile);
manifest.datasetManifestFile='dataset-manifest.json';
manifest.datasetManifestSha256=nbiot.ml.fileSha256(datasetManifestFile);
manifest.sourceSha256=sourceHash; manifest.calibrationSha256=calibrationHash;
writeJson(manifestFile,manifest);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value),'UTF-8'),'uint8');
end

function writeBytes(path,bytes)
fid=fopen(path,'wb');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,bytes,'uint8');
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
