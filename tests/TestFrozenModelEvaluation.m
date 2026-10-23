classdef TestFrozenModelEvaluation < matlab.unittest.TestCase
    methods (Test)
        function evaluatesFrozenSelectionAndPreservesSourceArtifacts(t)
            fixture=makeFixture(t);
            sourceBefore=artifactHashes(fixture.selection);

            report=evaluateFrozenLoadModels(fixture.options);
            evaluation=readJson(fullfile(fixture.output,'evaluation.json'));
            manifest=readJson(fullfile(fixture.output,'training-manifest.json'));
            metrics=readtable(fullfile(fixture.output,'metrics.csv'),'TextType','string');

            t.verifyEqual(report.status,'complete');
            t.verifyEqual(report.selectedModel,fixture.freeze.selectedModel);
            t.verifyEqual(evaluation.status,'complete');
            t.verifyEqual(evaluation.evidenceKind,'test-fixture');
            t.verifyEqual(evaluation.selectionSplit,'validation');
            t.verifyEqual(evaluation.selectedModel,fixture.freeze.selectedModel);
            t.verifyNotEmpty(evaluation.testOpenedAtUtc);
            t.verifyNotEmpty(evaluation.completedAtUtc);
            t.verifyEqual(manifest.phase,'evaluated');
            t.verifyEqual(manifest.freezeFile,'freeze.json');
            t.verifyEqual(manifest.freezeSha256,nbiot.ml.fileSha256(fixture.freezeFile));
            t.verifyEqual(manifest.selectionManifestSha256,fixture.freeze.selectionManifestSha256);
            t.verifyEqual(height(metrics),15);
            t.verifyEqual(sum(metrics.split=="test"),5);
            t.verifyEqual(sort(unique(metrics.model)),sort(["linearRegression"; ...
                "decisionTree";"randomForest";"gradientBoosting";"trainMean"]));
            t.verifyEqual(artifactHashes(fixture.selection),sourceBefore);
            modelMetrics=nbiot.ml.loadModelEvaluationMetrics( ...
                fullfile(fixture.output,[fixture.freeze.selectedModel '.mat']), ...
                nbiot.ml.validateModelBundle(fullfile(fixture.output, ...
                [fixture.freeze.selectedModel '.mat'])));
            t.verifyEqual(modelMetrics.split,["train";"validation";"test"]);

            modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
            for k=1:numel(modelNames)
                for extension={'.mat','.json'}
                    name=[modelNames{k} extension{1}];
                    t.verifyEqual(nbiot.ml.fileSha256(fullfile(fixture.selection,name)), ...
                        nbiot.ml.fileSha256(fullfile(fixture.output,name)));
                end
            end
            t.verifyEqual(nbiot.ml.fileSha256(fullfile(fixture.root,'diagnostics.csv')), ...
                nbiot.ml.fileSha256(fullfile(fixture.output,'diagnostics.csv')));
        end

        function completedRerunIsVerifiedAndDoesNotChangeTestTimestamp(t)
            fixture=makeFixture(t);
            first=evaluateFrozenLoadModels(fixture.options);
            second=evaluateFrozenLoadModels(fixture.options);
            t.verifyEqual(second.status,'already-evaluated');
            t.verifyEqual(second.selectedModel,first.selectedModel);
            t.verifyEqual(second.testOpenedAtUtc,first.testOpenedAtUtc);

            delete(fullfile(fixture.output,'diagnostics.csv'));
            t.verifyError(@() evaluateFrozenLoadModels(fixture.options), ...
                'nbiot:ml:FrozenEvaluation');

            changed=fixture.freeze; changed.selectedModel='decisionTree';
            changedFreeze=fullfile(fixture.root,'changed-freeze.json');
            writeJson(changedFreeze,changed);
            options=fixture.options; options.freezeFile=changedFreeze;
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            saved=readJson(fullfile(fixture.output,'evaluation.json'));
            t.verifyEqual(saved.testOpenedAtUtc,first.testOpenedAtUtc);
        end

        function completedTestIdsCannotBeOpenedThroughAnotherOutputFolder(t)
            fixture=makeFixture(t);
            first=evaluateFrozenLoadModels(fixture.options);
            options=fixture.options;
            options.outputFolder=fullfile(fixture.root,'evaluated-again');

            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(options.outputFolder,'evaluation-progress.json')));
            saved=readJson(fullfile(fixture.output,'evaluation.json'));
            t.verifyEqual(saved.testOpenedAtUtc,first.testOpenedAtUtc);
        end

        function copiedRegistryCannotReopenConsumedTestIds(t)
            fixture=makeFixture(t);
            evaluateFrozenLoadModels(fixture.options);
            copiedRegistryFolder=fullfile(fixture.root,'registry-copy');
            mkdir(copiedRegistryFolder);
            copiedRegistry=fullfile(copiedRegistryFolder,'registry.json');
            copyfile(fixture.options.registryFile,copiedRegistry);
            options=fixture.options;
            options.registryFile=copiedRegistry;
            options.outputFolder=fullfile(fixture.root,'evaluated-from-copied-registry');

            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(options.outputFolder,'evaluation-progress.json')));
        end

        function copiedDatasetCannotReopenConsumedTestIds(t)
            fixture=makeFixture(t);
            evaluateFrozenLoadModels(fixture.options);
            options=fixture.options;
            options.datasetFile=fullfile(fixture.output,'dataset.mat');
            options.outputFolder=fullfile(fixture.root,'evaluated-from-copied-dataset');

            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(options.outputFolder,'evaluation-progress.json')));
        end

        function protocolWindowScopeIsCheckedBeforeTestOpen(t)
            fixture=makeFixture(t);
            protocol=fixture.protocol;
            protocol.scope.windowTicks=501;
            writeJson(fixture.options.protocolFile,protocol);
            freeze=fixture.freeze;
            freeze.approvedProtocolSha256=nbiot.ml.fileSha256(fixture.options.protocolFile);
            writeJson(fixture.freezeFile,freeze);

            t.verifyError(@() evaluateFrozenLoadModels(fixture.options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
        end

        function datasetRowsOutsideProtocolWindowAreRejectedBeforeTestOpen(t)
            fixture=makeFixture(t);
            policy=fixture.policy; policy.windowTicks=250;
            writeJson(fixture.options.policyFile,policy);
            protocol=fixture.protocol; protocol.scope.windowTicks=250;
            writeJson(fixture.options.protocolFile,protocol);
            freeze=fixture.freeze;
            freeze.policyFileSha256=nbiot.ml.fileSha256(fixture.options.policyFile);
            freeze.policySha256=nbiot.controller.policySha256(policy);
            freeze.approvedProtocolSha256=nbiot.ml.fileSha256(fixture.options.protocolFile);
            writeJson(fixture.freezeFile,freeze);

            t.verifyError(@() evaluateFrozenLoadModels(fixture.options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
        end

        function outOfScopeBurstDurationIsCheckedBeforeTestOpen(t)
            fixture=makeFixture(t);
            rewriteFixtureManifestWithOutOfScopeBurst(fixture);
            protocol=fixture.protocol;
            protocol.scope.trafficKinds={'burst'};
            protocol.scope.burstDurationTicks=100;
            writeJson(fixture.options.protocolFile,protocol);
            freeze=readJson(fixture.freezeFile);
            freeze.approvedProtocolSha256=nbiot.ml.fileSha256(fixture.options.protocolFile);
            writeJson(fixture.freezeFile,freeze);

            t.verifyError(@() evaluateFrozenLoadModels(fixture.options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
        end

        function inputCaseKeyMustMatchPreTestRows(t)
            fixture=makeFixture(t);
            rewriteFixtureManifestWithOutOfScopeBurst(fixture,'unmatched-case-31');
            protocol=fixture.protocol;
            protocol.scope.trafficKinds={'burst'};
            protocol.scope.burstDurationTicks=200;
            writeJson(fixture.options.protocolFile,protocol);
            freeze=readJson(fixture.freezeFile);
            freeze.approvedProtocolSha256=nbiot.ml.fileSha256(fixture.options.protocolFile);
            writeJson(fixture.freezeFile,freeze);

            t.verifyError(@() evaluateFrozenLoadModels(fixture.options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
        end

        function protocolPolicyRegistryAndModelHashesAreCheckedBeforeTestOpen(t)
            fixture=makeFixture(t);
            options=fixture.options;

            changed=fixture.protocol; changed.thresholds.maxMae=changed.thresholds.maxMae+0.1;
            writeJson(options.protocolFile,changed);
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            writeJson(options.protocolFile,fixture.protocol);

            changed=fixture.policy; changed.staticAccessProbability=0.35;
            writeJson(options.policyFile,changed);
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            writeJson(options.policyFile,fixture.policy);

            changed=fixture.registry; changed.assignments(1).ids=[11 12];
            writeJson(options.registryFile,changed);
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            writeJson(options.registryFile,fixture.registry);

            modelFile=fullfile(fixture.selection,'gradientBoosting.mat');
            bytes=readBytes(modelFile); writeBytes(modelFile,[bytes;uint8('x')]);
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            writeBytes(modelFile,bytes);

            sidecarFile=fullfile(fixture.selection,'gradientBoosting.json');
            originalText=fileread(sidecarFile); sidecar=readJson(sidecarFile);
            sidecar.modelName='linearRegression'; writeJson(sidecarFile,sidecar);
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            writeText(sidecarFile,originalText);
        end

        function testFixtureTargetMutationCannotChangeFrozenValidationChoice(t)
            fixture=makeFixture(t);
            chosen=fixture.freeze.selectedModel;
            sourceMetrics=readtable(fullfile(fixture.selection,'metrics.csv'), ...
                'TextType','string');
            changedData=fixture.data;
            testRows=string(changedData.rowInfo.split)=="test";
            names={'linearRegression','decisionTree','randomForest','gradientBoosting'};
            predictions=zeros(nnz(testRows),numel(names));
            for k=1:numel(names)
                bundle=nbiot.ml.validateModelBundle( ...
                    fullfile(fixture.selection,[names{k} '.mat']));
                x=double(changedData.observations{testRows,bundle.featureNames});
                x=imputeAndNormalize(x,bundle.transform);
                predictions(:,k)=double(predict(bundle.model,x));
            end
            selectedIndex=find(strcmp(names,chosen),1);
            alternatives=setdiff(1:numel(names),selectedIndex,'stable');
            separation=zeros(size(alternatives));
            for k=1:numel(alternatives)
                separation(k)=mean(abs(predictions(:,selectedIndex)- ...
                    predictions(:,alternatives(k))));
            end
            [largest,at]=max(separation);
            t.assertGreaterThan(largest,1e-10, ...
                'Fixture models must differ to test the validation-only freeze.');
            changedData.targets.meanRaUe(testRows)=predictions(:,alternatives(at));
            changedDataset=fullfile(fixture.root,'dataset-test-target-changed.mat');
            data=changedData; %#ok<NASGU>
            save(changedDataset,'data','-v7.3');
            t.verifyNotEqual(nbiot.ml.fileSha256(changedDataset),fixture.freeze.datasetSha256);

            validationRows=string(sourceMetrics.split)=="validation";
            [~,validationBest]=min(sourceMetrics.mae(validationRows & ...
                sourceMetrics.model~="trainMean"));
            modelRows=sourceMetrics(validationRows & sourceMetrics.model~="trainMean",:);
            [~,bestRow]=min(modelRows.mae);
            t.verifyEqual(char(modelRows.model(bestRow)),chosen);
            t.verifyGreaterThan(mean(abs(predictions(:,selectedIndex)- ...
                changedData.targets.meanRaUe(testRows))),0);

            options=fixture.options; options.datasetFile=changedDataset;
            t.verifyError(@() evaluateFrozenLoadModels(options), ...
                'nbiot:ml:FrozenEvaluation');
            t.verifyFalse(isfile(fullfile(fixture.output,'evaluation-progress.json')));
            t.verifyEqual(fixture.freeze.selectedModel,chosen);
            t.verifyEqual(validationBest,find(strcmp(names,chosen),1));
            t.verifyEqual(readtable(fullfile(fixture.selection,'metrics.csv'), ...
                'TextType','string'),sourceMetrics);
        end

        function candidateTrainingDefaultAllSplitsFailsBeforeTraining(t)
            data=smallLoadTrainingFixture();
            data.manifest.kind='candidate-training';
            data.manifest.allocationsVerified=true;
            data.manifest.experimentRolesExplicit=true;
            roles=string(data.rowInfo.split);
            roles(roles=="train")="training"; roles(roles=="test")="model-test";
            data.rowInfo.experimentRole=roles;
            outputFolder=tempname;
            options=mlTrainingDefaults(); options.outputFolder=outputFolder;
            t.verifyError(@() nbiot.ml.trainLoadModels(data,options), ...
                'nbiot:ml:EvaluationMode');
            t.verifyFalse(isfolder(outputFolder));
        end

        function entrypointDoesNotFitOrTrain(t)
            path=which('evaluateFrozenLoadModels');
            t.assertNotEmpty(path);
            source=lower(fileread(path));
            t.verifyFalse(contains(source,'trainloadmodels('));
            t.verifyFalse(contains(source,'fitlm('));
            t.verifyFalse(contains(source,'fitrtree('));
            t.verifyFalse(contains(source,'fitrensemble('));
            t.verifyFalse(contains(source,'treebagger('));
        end
    end
end

function fixture=makeFixture(testCase)
root=tempname; mkdir(root); testCase.addTeardown(@() removeFolder(root));
data=smallLoadTrainingFixture();
datasetFile=fullfile(root,'dataset.mat'); save(datasetFile,'data','-v7.3');
datasetManifest=data.manifest;
datasetManifest.assignments=table2struct(datasetManifest.assignments);
datasetManifest.diagnosticsComplete=false;
writeJson(fullfile(root,'manifest.json'),datasetManifest);
writetable(data.rowInfo,fullfile(root,'rows.csv'));
artifactNames={'dataset.mat','manifest.json','diagnostics.csv','rows.csv'};
writeText(fullfile(root,'diagnostics.csv'), ...
    sprintf('caseKey,realizationId,windowId,startTick,endTick\nfixture-31,31,1,0,500\n'));
artifactsList=repmat(struct('name','','sha256','','bytes',0),1,numel(artifactNames));
for k=1:numel(artifactNames)
    path=fullfile(root,artifactNames{k});
    artifactsList(k)=struct('name',artifactNames{k}, ...
        'sha256',nbiot.ml.fileSha256(path),'bytes',fileBytes(path));
end
writeJson(fullfile(root,'artifacts.json'),struct('schemaVersion',1,'files',artifactsList));

registry=struct(); registry.schemaVersion=1; registry.validRange=[0 4095];
registry.roles={'development','training','validation','model-test','final-comparison'};
registry.reservations=struct('role',{},'range',{},'source',{},'note',{});
template=struct('role','','ids',[],'source','','status','','recovery',[]);
registry.assignments=repmat(template,1,3);
registry.assignments(1)=struct('role','training','ids',[11 12 13], ...
    'source','test-fixture','status','completed','recovery',[]);
registry.assignments(2)=struct('role','validation','ids',21, ...
    'source','test-fixture','status','completed','recovery',[]);
registry.assignments(3)=struct('role','model-test','ids',31, ...
    'source','test-fixture','status','completed','recovery',[]);
registryFile=fullfile(root,'registry.json'); writeJson(registryFile,registry);

policy=adaptiveDefaults(); policy.status='frozen-validation';
policyFile=fullfile(root,'policy.json'); writeJson(policyFile,policy);
protocol=struct('schemaVersion',1,'frozenAtUtc','2026-10-18T15:00:00Z', ...
    'approver','TEST_FIXTURE_ONLY_NOT_SCIENTIFIC_APPROVAL', ...
    'approvedAtUtc','2026-10-18T15:01:00Z','baseline','trainMean', ...
    'selectionRule','lowest-validation-mae', ...
    'thresholds',struct('maxMae',1,'maxRmse',1, ...
        'maxMaeToBaselineRatio',1,'maxRmseToBaselineRatio',1), ...
    'requiredStrata',struct('numUE',1,'trafficKind','test-fixture'), ...
    'scope',struct('methods',{{'fixture'}},'numUE',1, ...
        'trafficKinds',{{'test-fixture'}},'windowTicks',500), ...
    'policyTuningAllowedRoles',{{'development','validation'}}, ...
    'testConsumption','once-after-freeze');
protocolFile=fullfile(root,'protocol.json'); writeJson(protocolFile,protocol);

selection=fullfile(root,'selection'); training=mlTrainingDefaults();
training.seed=17; training.evaluationMode='selection-only'; training.outputFolder=selection;
training.datasetFile=datasetFile; training.forestNumTrees=8; training.boostNumLearningCycles=8;
nbiot.ml.trainLoadModels(data,training);
freezeFile=fullfile(root,'freeze.json');
freezeOptions=struct('selectionFolder',selection,'datasetFile',datasetFile, ...
    'policyFile',policyFile,'protocolFile',protocolFile,'registryFile',registryFile, ...
    'policyTuningIds',21,'outputFile',freezeFile);
freeze=freezeLoadModelSelection(freezeOptions);
output=fullfile(root,'evaluated');
options=struct('freezeFile',freezeFile,'datasetFile',datasetFile, ...
    'modelFolder',selection,'protocolFile',protocolFile,'policyFile',policyFile, ...
    'registryFile',registryFile,'outputFolder',output);
fixture=struct('root',root,'data',data,'selection',selection,'freeze',freeze, ...
    'freezeFile',freezeFile,'output',output,'options',options,'protocol',protocol, ...
    'policy',policy,'registry',registry);
end

function rewriteFixtureManifestWithOutOfScopeBurst(fixture,lastCaseKey)
manifest=readJson(fullfile(fixture.root,'manifest.json'));
template=struct('caseKey','','realizationId',0,'numUE',1,'trafficKind','burst', ...
    'burstDurationTicks',200,'periodTicks',NaN,'poissonRatePerSecond',NaN);
ids=[11 12 13 21 31]; inputs=repmat(template,1,numel(ids));
for k=1:numel(ids)
    inputs(k).caseKey=sprintf('fixture-%d',ids(k));
    inputs(k).realizationId=ids(k);
end
if nargin>1&&~isempty(lastCaseKey), inputs(end).caseKey=lastCaseKey; end
manifest.inputs=inputs;
manifestFile=fullfile(fixture.root,'manifest.json'); writeJson(manifestFile,manifest);
manifestHash=nbiot.ml.fileSha256(manifestFile);
writeJson(fullfile(fixture.selection,'dataset-manifest.json'),manifest);
trainingManifestFile=fullfile(fixture.selection,'training-manifest.json');
trainingManifest=readJson(trainingManifestFile);
trainingManifest.datasetManifestSha256=manifestHash;
writeJson(trainingManifestFile,trainingManifest);
artifacts=readJson(fullfile(fixture.root,'artifacts.json'));
at=find(strcmp({artifacts.files.name},'manifest.json'),1);
artifacts.files(at).sha256=manifestHash;
artifacts.files(at).bytes=fileBytes(manifestFile);
writeJson(fullfile(fixture.root,'artifacts.json'),artifacts);
freeze=readJson(fixture.freezeFile);
freeze.selectionManifestSha256=nbiot.ml.fileSha256(trainingManifestFile);
writeJson(fixture.freezeFile,freeze);
end

function hashes=artifactHashes(folder)
names={'linearRegression.mat','linearRegression.json','decisionTree.mat','decisionTree.json', ...
    'randomForest.mat','randomForest.json','gradientBoosting.mat','gradientBoosting.json', ...
    'metrics.csv','training-manifest.json'};
hashes=cell(size(names));
for k=1:numel(names), hashes{k}=nbiot.ml.fileSha256(fullfile(folder,names{k})); end
end

function x=imputeAndNormalize(x,transform)
for column=1:size(x,2)
    x(isnan(x(:,column)),column)=transform.median(column);
end
x=(x-transform.mean)./transform.scale;
end

function value=readJson(path), value=jsondecode(fileread(path)); end
function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end
function writeText(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end
function writeBytes(path,value)
fid=fopen(path,'wb'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,value,'uint8');
end
function bytes=readBytes(path)
fid=fopen(path,'rb'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=fread(fid,inf,'*uint8');
end
function count=fileBytes(path), info=dir(path); count=info.bytes; end
function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
