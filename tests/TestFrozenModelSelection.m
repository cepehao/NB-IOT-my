classdef TestFrozenModelSelection < matlab.unittest.TestCase
    methods (Test)
        function policyDigestIsCanonical(t)
            policy=adaptiveDefaults();
            digest=nbiot.controller.policySha256(policy);
            reordered=orderfields(policy,fliplr(fieldnames(policy)));
            fields={'accessLoadThresholds','accessProbabilityLevels','raLoadThresholds','raShareLevels'};
            for k=1:numel(fields)
                value=reordered.(fields{k});
                reordered.(fields{k})=value(:);
            end
            t.verifyEqual(nbiot.controller.policySha256(reordered),digest);
            changed=policy; changed.accessLoadThresholds(2)=changed.accessLoadThresholds(2)+0.25;
            t.verifyNotEqual(nbiot.controller.policySha256(changed),digest);
        end

        function selectionFreezeBindsValidationChoiceAndHashes(t)
            fixture=makeFixture(t);
            manifest=readJson(fullfile(fixture.selection,'training-manifest.json'));
            metrics=readtable(fullfile(fixture.selection,'metrics.csv'));
            t.verifyEqual(manifest.phase,'selection');
            t.verifyEqual(height(metrics),10);
            t.verifyFalse(any(string(metrics.split)=="test"));
            before=selectionHashes(fixture.selection);

            freeze=freezeLoadModelSelection(fixture.options);
            names={'linearRegression','decisionTree','randomForest','gradientBoosting'};
            validationMae=zeros(1,4);
            for k=1:4
                row=string(metrics.model)==names{k}&string(metrics.split)=="validation";
                t.verifyEqual(nnz(row),1);
                validationMae(k)=metrics.mae(row);
            end
            [~,best]=min(validationMae);
            t.verifyEqual(freeze.schemaVersion,'load-model-freeze-v1');
            t.verifyEqual(freeze.evidenceKind,'test-fixture');
            t.verifyEqual(freeze.selectedModel,names{best});
            t.verifyEqual(freeze.selectedModel,manifest.bestValidationModel);
            t.verifyEqual(freeze.selectionRule, ...
                'lowest-validation-mae;tieOrder=linearRegression,decisionTree,randomForest,gradientBoosting');
            t.verifyEqual(freeze.trainingIds(:).',double(manifest.trainingIds(:).'));
            t.verifyEqual(freeze.validationIds(:).',double(manifest.validationIds(:).'));
            t.verifyEqual(freeze.testIds(:).',double(manifest.testIds(:).'));
            t.verifyEqual(freeze.policyTuningIds(:).',21);
            t.verifyEqual(freeze.datasetSha256,nbiot.ml.fileSha256(fixture.options.datasetFile));
            t.verifyEqual(freeze.selectionManifestSha256, ...
                nbiot.ml.fileSha256(fullfile(fixture.selection,'training-manifest.json')));
            t.verifyEqual(freeze.registrySha256,nbiot.ml.fileSha256(fixture.options.registryFile));
            t.verifyEqual(freeze.approvedProtocolSha256, ...
                nbiot.ml.fileSha256(fixture.options.protocolFile));
            t.verifyEqual(freeze.policySha256, ...
                nbiot.controller.policySha256(jsondecode(fileread(fixture.options.policyFile))));
            t.verifyEqual(freeze.policyFileSha256,nbiot.ml.fileSha256(fixture.options.policyFile));
            t.verifyEqual(numel(freeze.models),4);
            for k=1:4
                modelFile=fullfile(fixture.selection,[names{k} '.mat']);
                sidecarFile=fullfile(fixture.selection,[names{k} '.json']);
                t.verifyEqual(freeze.models(k).modelName,names{k});
                t.verifyEqual(freeze.models(k).file,[names{k} '.mat']);
                t.verifyEqual(freeze.models(k).sha256,nbiot.ml.fileSha256(modelFile));
                t.verifyEqual(freeze.models(k).sidecarFile,[names{k} '.json']);
                t.verifyEqual(freeze.models(k).sidecarSha256,nbiot.ml.fileSha256(sidecarFile));
            end
            chosen=find(strcmp(names,freeze.selectedModel),1);
            t.verifyEqual(freeze.modelSha256,freeze.models(chosen).sha256);
            t.verifyEqual(freeze.modelSidecarSha256,freeze.models(chosen).sidecarSha256);
            t.verifyEqual(selectionHashes(fixture.selection),before);
            t.verifyEqual(freeze,readJson(fixture.options.outputFile));
            if isfield(freeze,'status'), t.verifyNotEqual(freeze.status,'accepted'); end
            source=lower(fileread(which('freezeLoadModelSelection')));
            t.verifyFalse(contains(source,'predict('));
            t.verifyFalse(contains(source,'fitlm('));
            t.verifyFalse(contains(source,'trainloadmodels('));
        end

        function invalidPhaseProtocolIdsAndOverwriteAreRejected(t)
            fixture=makeFixture(t);
            manifestFile=fullfile(fixture.selection,'training-manifest.json');
            manifest=readJson(manifestFile); manifest.phase='evaluated';
            writeJson(manifestFile,manifest);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            manifest.phase='selection'; writeJson(manifestFile,manifest);

            protocol=fixture.protocol;
            protocol.thresholds=rmfield(protocol.thresholds,'maxRmse');
            writeJson(fixture.options.protocolFile,protocol);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            protocol=fixture.protocol; protocol.approvedAtUtc='';
            writeJson(fixture.options.protocolFile,protocol);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            writeJson(fixture.options.protocolFile,fixture.protocol);

            overlapping=fixture.options; overlapping.policyTuningIds=31;
            t.verifyError(@() freezeLoadModelSelection(overlapping),'nbiot:ml:ModelFreeze');
            t.verifyFalse(isfile(fixture.options.outputFile));

            freezeLoadModelSelection(fixture.options);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
        end

        function alteredManifestModelMetricsAndPolicyAreRejected(t)
            fixture=makeFixture(t);
            manifestFile=fullfile(fixture.selection,'training-manifest.json');
            manifest=readJson(manifestFile); manifest.datasetSha256=repmat('0',1,64);
            writeJson(manifestFile,manifest);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            writeJson(manifestFile,fixture.trainingManifest);

            modelFile=fullfile(fixture.selection,'randomForest.mat');
            original=readBytes(modelFile); writeBytes(modelFile,[original;uint8('x')]);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            writeBytes(modelFile,original);

            sidecarFile=fullfile(fixture.selection,'randomForest.json');
            originalText=fileread(sidecarFile); sidecar=jsondecode(originalText);
            sidecar.modelName='linearRegression'; writeJson(sidecarFile,sidecar);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            writeText(sidecarFile,originalText);

            metricsFile=fullfile(fixture.selection,'metrics.csv');
            originalText=fileread(metricsFile); writeText(metricsFile,[originalText newline]);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            writeText(metricsFile,originalText);

            policy=fixture.policy; policy.status='development-provisional';
            writeJson(fixture.options.policyFile,policy);
            t.verifyError(@() freezeLoadModelSelection(fixture.options),'nbiot:ml:ModelFreeze');
            t.verifyFalse(isfile(fixture.options.outputFile));
        end

        function unknownAndMissingOptionsAreRejected(t)
            fixture=makeFixture(t);
            unknown=fixture.options; unknown.extra=true;
            t.verifyError(@() freezeLoadModelSelection(unknown),'nbiot:ml:ModelFreeze');
            missing=rmfield(fixture.options,'registryFile');
            t.verifyError(@() freezeLoadModelSelection(missing),'nbiot:ml:ModelFreeze');
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
artifactNames={'dataset.mat','manifest.json'};
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
    'thresholds',struct('maxMae',1,'maxRmse',1,'maxMaeToBaselineRatio',1,'maxRmseToBaselineRatio',1), ...
    'requiredStrata',struct('numUE',1,'trafficKind','test-fixture'), ...
    'scope',struct('methods',{{'fixture'}},'numUE',1,'trafficKinds',{{'test-fixture'}},'windowTicks',500), ...
    'policyTuningAllowedRoles',{{'development','validation'}}, ...
    'testConsumption','once-after-freeze');
protocolFile=fullfile(root,'protocol.json'); writeJson(protocolFile,protocol);

selection=fullfile(root,'selection'); training=mlTrainingDefaults();
training.seed=17; training.evaluationMode='selection-only'; training.outputFolder=selection;
training.datasetFile=datasetFile; training.forestNumTrees=8; training.boostNumLearningCycles=8;
nbiot.ml.trainLoadModels(data,training);
fixture=struct('data',data,'selection',selection,'policy',policy,'protocol',protocol, ...
    'trainingManifest',readJson(fullfile(selection,'training-manifest.json')));
fixture.options=struct('selectionFolder',selection,'datasetFile',datasetFile, ...
    'policyFile',policyFile,'protocolFile',protocolFile,'registryFile',registryFile, ...
    'policyTuningIds',21,'outputFile',fullfile(root,'freeze.json'));
end

function hashes=selectionHashes(folder)
names={'linearRegression.mat','linearRegression.json','decisionTree.mat','decisionTree.json', ...
    'randomForest.mat','randomForest.json','gradientBoosting.mat','gradientBoosting.json', ...
    'metrics.csv','training-manifest.json'};
hashes=cell(size(names));
for k=1:numel(names), hashes{k}=nbiot.ml.fileSha256(fullfile(folder,names{k})); end
end

function value=readJson(path), value=jsondecode(fileread(path)); end
function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end
function writeBytes(path,value)
fid=fopen(path,'wb'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,value,'uint8');
end
function writeText(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end
function bytes=readBytes(path)
fid=fopen(path,'rb'); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=fread(fid,inf,'*uint8');
end
function count=fileBytes(path), info=dir(path); count=info.bytes; end
function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
