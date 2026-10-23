function report=checkModelAcceptanceEvidence(acceptance,rootFolder)
%CHECKMODELACCEPTANCEEVIDENCE Validate portable evidence; load only dataset.mat variable data.
%   Проверка комплекта доказательств допуска ML-модели. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
errors={}; evidenceDigest=''; evidenceFiles=struct('path',{},'sha256',{});
sourceSha256=''; calibrationSha256='';
try
    [acceptance,root]=normalizeInput(acceptance,rootFolder);
    required={'schemaVersion','status','evidenceKind','featureSchemaVersion', ...
        'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
        'trainingManifest','metrics','sourceManifest','calibration','registry', ...
        'policy','protocol','evaluation','policySha256','trainingIds', ...
        'validationIds','testIds','policyTuningIds','scope','review'};
    requireFields(acceptance,required,'Acceptance metadata is incomplete.');
    requireText(acceptance.schemaVersion,'model-acceptance-v1','schemaVersion');
    if ~ismember(textValue(acceptance.status,'status'),{'candidate','accepted','rejected'})
        fail('Acceptance status is unsupported.');
    end
    if ~strcmp(textValue(acceptance.featureSchemaVersion,'feature schema'), ...
            'bs-known-v2.0')
        fail('Feature schema does not match the supported model schema.');
    end
    refNames={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
        'trainingManifest','metrics','sourceManifest','calibration','registry', ...
        'policy','protocol','evaluation'};
    paths=struct();
    for k=1:numel(refNames)
        name=refNames{k}; paths.(name)=resolveAcceptanceRef(root,acceptance.(name),name);
        if ~isfile(paths.(name))
            fail('Required evidence file is missing: %s.',name);
        end
        if ~isSha256(acceptance.(name).sha256)|| ...
                ~strcmpi(nbiot.ml.fileSha256(paths.(name)),acceptance.(name).sha256)
            fail('Evidence checksum does not match: %s.',name);
        end
    end
    ids=validateSplitIds(acceptance);
    tuningIds=normalizeIds(acceptance.policyTuningIds,'policyTuningIds',true);
    if ~isempty(intersect(tuningIds,[ids.training ids.test]))
        fail('Policy-tuning IDs cannot overlap training or model-test IDs.');
    end
    evidenceDigest=computeEvidenceDigest(acceptance);

    modelSidecar=readJsonFile(paths.modelSidecar,'model sidecar');
    if ~isstruct(modelSidecar)||~isscalar(modelSidecar)|| ...
            ~all(isfield(modelSidecar,{'modelName','artifactFile','artifactSha256', ...
            'schemaVersion','targetName','trainingIds','validationIds','testIds','status','dataKind'}))
        fail('Model sidecar metadata is incomplete.');
    end
    [~,modelBase,modelExtension]=fileparts(paths.model);
    if ~strcmp(textValue(modelSidecar.artifactFile,'model sidecar artifactFile'), ...
            [modelBase modelExtension])|| ...
            ~strcmpi(textValue(modelSidecar.artifactSha256,'model sidecar artifactSha256'), ...
            acceptance.model.sha256)
        fail('Model sidecar does not bind the referenced model file.');
    end
    if ~strcmp(textValue(modelSidecar.schemaVersion,'model schema'), ...
            acceptance.featureSchemaVersion)||~strcmp(textValue(modelSidecar.targetName,'model target'),'meanRaUe')
        fail('Model sidecar schema or target is incompatible.');
    end
    validateSameIds(modelSidecar.trainingIds,ids.training,'model sidecar training IDs');
    validateSameIds(modelSidecar.validationIds,ids.validation,'model sidecar validation IDs');
    validateSameIds(modelSidecar.testIds,ids.test,'model sidecar test IDs');

    training=readJsonFile(paths.trainingManifest,'training manifest');
    freeze=validateTrainingManifest(training,acceptance,ids,paths,root,modelSidecar);
[metrics,metricPath]=validateMetrics(paths.metrics,training,modelSidecar.modelName,ids);

    datasetManifest=readJsonFile(paths.datasetManifest,'dataset manifest');
    datasetArtifacts=readJsonFile(paths.datasetArtifacts,'dataset artifacts');
    validateDatasetEvidence(datasetManifest,datasetArtifacts,acceptance,training,ids, ...
        paths,root,metricPath);

    sourceManifest=readJsonFile(paths.sourceManifest,'source manifest');
    validateSourceEvidence(sourceManifest,paths.sourceManifest,acceptance,training,root);
    sourceSha256=textValue(sourceManifest.sourceSha256,'source manifest source hash');
    calibrationSha256=textValue(sourceManifest.calibrationSha256,'source manifest calibration hash');
    registry=readJsonFile(paths.registry,'registry snapshot');
    validateRegistry(registry,ids,tuningIds);

    policy=readJsonFile(paths.policy,'adaptive policy');
    validatePolicy(policy,acceptance,training);
    protocol=readJsonFile(paths.protocol,'evaluation protocol');
    validateProtocol(protocol,acceptance,policy,paths.protocol);
    evaluation=readJsonFile(paths.evaluation,'evaluation report');
    validateEvaluation(evaluation,protocol,acceptance,training,modelSidecar,ids,metrics,freeze);

    validateReview(acceptance.review,acceptance.status,evidenceDigest, ...
        acceptance.protocol.sha256,evaluation.completedAtUtc);
    inferredKind=inferEvidenceKind(datasetManifest,training,modelSidecar,sourceManifest);
    if ~strcmp(textValue(acceptance.evidenceKind,'evidenceKind'),inferredKind)
        fail('Acceptance evidenceKind does not match dataset/model provenance.');
    end
    validateEvidenceKindLinks(inferredKind,datasetManifest,training,modelSidecar,freeze,evaluation);
    evidenceFiles=collectValidatedEvidenceFiles(root,paths);
catch exception
    errors={exception.message};
end
if ~isempty(errors), evidenceFiles=struct('path',{},'sha256',{}); end
report=struct();
report.passed=isempty(errors); report.errors=errors;
report.evidenceDigest=evidenceDigest; report.evidenceFiles=evidenceFiles;
report.sourceSha256=sourceSha256; report.calibrationSha256=calibrationSha256;
end

function files=collectValidatedEvidenceFiles(root,paths)
filePaths={};
refNames={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
    'trainingManifest','metrics','sourceManifest','calibration','registry', ...
    'policy','protocol','evaluation'};
for k=1:numel(refNames)
    filePaths{end+1}=paths.(refNames{k}); %#ok<AGROW>
end

training=readJsonFile(paths.trainingManifest,'training manifest');
trainingFolder=fileparts(paths.trainingManifest);
trainingArtifacts=normalizeTextList(training.artifactFiles,'artifactFiles');
for k=1:numel(trainingArtifacts)
    filePaths{end+1}=resolvePackageRelative(root,trainingFolder,trainingArtifacts{k}); %#ok<AGROW>
end
freezePath=resolvePackageRelative(root,trainingFolder, ...
    textValue(training.freezeFile,'freezeFile'));
filePaths{end+1}=freezePath;
if isfield(training,'testConsumptionFile')
    filePaths{end+1}=resolvePackageRelative(root,trainingFolder, ...
        textValue(training.testConsumptionFile,'testConsumptionFile')); %#ok<AGROW>
end
freeze=readJsonFile(freezePath,'model selection freeze');
for k=1:numel(freeze.models)
    filePaths{end+1}=resolvePackageRelative(root,fileparts(freezePath), ...
        textValue(freeze.models(k).file,'freeze model file')); %#ok<AGROW>
    filePaths{end+1}=resolvePackageRelative(root,fileparts(freezePath), ...
        textValue(freeze.models(k).sidecarFile,'freeze model sidecar file')); %#ok<AGROW>
end

artifacts=readJsonFile(paths.datasetArtifacts,'dataset artifacts');
artifactFolder=fileparts(paths.datasetArtifacts);
for k=1:numel(artifacts.files)
    filePaths{end+1}=resolvePackageRelative(root,artifactFolder, ...
        textValue(artifacts.files(k).name,'dataset artifact name')); %#ok<AGROW>
end
datasetManifest=readJsonFile(paths.datasetManifest,'dataset manifest');
for k=1:numel(datasetManifest.inputs)
    resultPath=resolvePackageRelative(root,root, ...
        textValue(datasetManifest.inputs(k).resultFile,'dataset input resultFile'));
    caseFolder=fileparts(resultPath);
    markerPath=resolvePackageRelative(root,caseFolder,'case-complete.json');
    marker=readJsonFile(markerPath,'dataset input completion marker');
    stem=textValue(marker.exportStem,'completion exportStem');
    filePaths=[filePaths,{resultPath,markerPath, ...
        resolvePackageRelative(root,caseFolder,[stem '_summary.csv']), ...
        resolvePackageRelative(root,caseFolder,[stem '_observations.csv']), ...
        resolvePackageRelative(root,caseFolder,[stem '_targets.csv'])}]; %#ok<AGROW>
end

sourceManifest=readJsonFile(paths.sourceManifest,'source manifest');
sourceFolder=fileparts(paths.sourceManifest);
for k=1:numel(sourceManifest.files)
    filePaths{end+1}=resolvePackageRelative(root,sourceFolder, ...
        textValue(sourceManifest.files(k).name,'source manifest file name')); %#ok<AGROW>
end

canonicalPaths=cellfun(@canonicalPath,filePaths,'UniformOutput',false);
uniquePaths=unique(canonicalPaths,'stable');
[~,order]=sort(lower(string(uniquePaths))); uniquePaths=uniquePaths(order);
files=repmat(struct('path','','sha256',''),numel(uniquePaths),1);
for k=1:numel(uniquePaths)
    files(k)=struct('path',uniquePaths{k}, ...
        'sha256',nbiot.ml.fileSha256(uniquePaths{k}));
end
end

function [acceptance,root]=normalizeInput(value,rootFolder)
if ischar(value)||(isstring(value)&&isscalar(value))
    file=char(value);
    if ~isfile(file), fail('Acceptance JSON file is missing.'); end
    acceptance=readJsonFile(file,'acceptance JSON');
elseif isstruct(value)&&isscalar(value)
    acceptance=value;
else
    fail('Acceptance must be a JSON path or scalar structure.');
end
if ~(ischar(rootFolder)||(isstring(rootFolder)&&isscalar(rootFolder)))||~isfolder(rootFolder)
    fail('Acceptance package root must be an existing folder.');
end
root=canonicalPath(char(rootFolder));
end

function ids=validateSplitIds(acceptance)
ids=struct('training',normalizeIds(acceptance.trainingIds,'trainingIds',false), ...
    'validation',normalizeIds(acceptance.validationIds,'validationIds',false), ...
    'test',normalizeIds(acceptance.testIds,'testIds',false));
if ~isempty(intersect(ids.training,ids.validation))|| ...
        ~isempty(intersect(ids.training,ids.test))||~isempty(intersect(ids.validation,ids.test))
    fail('Training, validation, and model-test IDs must be disjoint.');
end
end

function freeze=validateTrainingManifest(manifest,acceptance,ids,paths,root,sidecar)
required={'formatVersion','phase','dataKind','allocationsVerified','status', ...
    'targetName','schemaVersion','bestValidationModel','selectionRule','modelNames', ...
    'artifactFiles','artifactSha256','trainingIds','validationIds','testIds', ...
    'metricsFile','metricsSha256','metricsRowCount','splitEvidence','datasetFile', ...
    'datasetSha256','datasetManifestFile','datasetManifestSha256','sourceSha256', ...
    'calibrationSha256','freezeFile','freezeSha256','selectionManifestSha256', ...
    'datasetArtifactsFile','datasetArtifactsSha256','evaluationFile','evaluationSha256', ...
    'protocolFile','protocolSha256','policyFile','policySha256','policyFileSha256', ...
    'registryFile','registrySha256','evaluationPassed'};
    requireFields(manifest,required,'Evaluated training manifest is incomplete.');
    requireText(manifest.formatVersion,'load-training-report-v2','training manifest formatVersion');
    requireText(manifest.phase,'evaluated','training manifest phase');
    requireText(manifest.status,'development','training manifest status');
    dataKind=textValue(manifest.dataKind,'training dataKind');
    if ~ismember(dataKind,{'candidate-training','development-fixture'})|| ...
            ~strcmp(textValue(manifest.targetName,'training target'),'meanRaUe')|| ...
            ~strcmp(textValue(manifest.schemaVersion,'training schema'),acceptance.featureSchemaVersion)
        fail('Training manifest data kind, target, or schema is unsupported.');
    end
    if ~isLogicalScalar(manifest.allocationsVerified)|| ...
            (strcmp(dataKind,'candidate-training')&&~manifest.allocationsVerified)|| ...
            (strcmp(dataKind,'development-fixture')&&manifest.allocationsVerified)
        fail('Training allocation verification flag does not match data provenance.');
    end
    if ~strcmpi(textValue(manifest.datasetSha256,'training dataset hash'),acceptance.dataset.sha256)|| ...
            ~strcmpi(textValue(manifest.datasetManifestSha256,'training dataset-manifest hash'), ...
            acceptance.datasetManifest.sha256)|| ...
            ~strcmpi(textValue(manifest.datasetArtifactsSha256,'training dataset-artifacts hash'), ...
            acceptance.datasetArtifacts.sha256)|| ...
            ~strcmpi(textValue(manifest.metricsSha256,'training metrics hash'),acceptance.metrics.sha256)
        fail('Training manifest hashes do not match acceptance references.');
    end
    validateSameIds(manifest.trainingIds,ids.training,'training manifest training IDs');
    validateSameIds(manifest.validationIds,ids.validation,'training manifest validation IDs');
    validateSameIds(manifest.testIds,ids.test,'training manifest test IDs');
    splitEvidence=manifest.splitEvidence;
    if ~isstruct(splitEvidence)||numel(splitEvidence)~=3|| ...
            ~all(isfield(splitEvidence,{'split','ids','sampleCount','idCount'}))
        fail('Training splitEvidence must contain train, validation, and test.');
    end
    splitNames={'train','validation','test'}; splitIds={ids.training,ids.validation,ids.test};
    for k=1:3
        at=find(strcmp({splitEvidence.split},splitNames{k}));
        if numel(at)~=1||~isequal(normalizeIds(splitEvidence(at).ids,'splitEvidence IDs',false),splitIds{k})|| ...
                ~isPositiveInteger(splitEvidence(at).sampleCount)|| ...
                ~isPositiveInteger(splitEvidence(at).idCount)|| ...
                splitEvidence(at).sampleCount<splitEvidence(at).idCount|| ...
                double(splitEvidence(at).idCount)~=numel(splitIds{k})
            fail('Training splitEvidence is inconsistent for %s.',splitNames{k});
        end
    end
    modelNames=normalizeTextList(manifest.modelNames,'modelNames');
    expectedModels={'linearRegression','decisionTree','randomForest','gradientBoosting'};
    artifactFiles=normalizeTextList(manifest.artifactFiles,'artifactFiles');
    artifactHashes=normalizeTextList(manifest.artifactSha256,'artifact hashes');
    if numel(modelNames)~=4||~isequal(sort(modelNames),sort(expectedModels))|| ...
            numel(artifactFiles)~=4||numel(artifactHashes)~=4
        fail('Training manifest must bind the four supported model artifacts.');
    end
    for k=1:4
        if ~strcmp(artifactFiles{k},[modelNames{k} '.mat'])||~isSha256(artifactHashes{k})
            fail('Training model artifact names and hashes do not align.');
        end
        artifactPath=resolvePackageRelative(root,fileparts(paths.trainingManifest),artifactFiles{k});
        if ~isfile(artifactPath)||~strcmpi(nbiot.ml.fileSha256(artifactPath),artifactHashes{k})
            fail('A trained model artifact is missing or changed: %s.',artifactFiles{k});
        end
    end
    selectedName=textValue(sidecar.modelName,'selected model name');
    if ~strcmp(textValue(manifest.bestValidationModel,'bestValidationModel'),selectedName)
        fail('Best validation model differs from the selected model sidecar.');
    end
    if ~ischar(manifest.selectionRule)&&~(isstring(manifest.selectionRule)&&isscalar(manifest.selectionRule))
        fail('Training selection rule must be text.');
    end
    if ~isLogicalScalar(manifest.evaluationPassed)||~manifest.evaluationPassed
        fail('Training manifest does not record a completed passing evaluation.');
    end

    base=fileparts(paths.trainingManifest);
    checkManifestRef(root,base,manifest.metricsFile,acceptance.metrics,'metricsFile');
    checkManifestRef(root,base,manifest.datasetFile,acceptance.dataset,'datasetFile');
    checkManifestRef(root,base,manifest.datasetManifestFile,acceptance.datasetManifest,'datasetManifestFile');
    checkManifestRef(root,base,manifest.datasetArtifactsFile,acceptance.datasetArtifacts,'datasetArtifactsFile');
    checkManifestRef(root,base,manifest.evaluationFile,acceptance.evaluation,'evaluationFile');
    checkManifestRef(root,base,manifest.protocolFile,acceptance.protocol,'protocolFile');
    checkManifestRef(root,base,manifest.policyFile,acceptance.policy,'policyFile');
    checkManifestRef(root,base,manifest.registryFile,acceptance.registry,'registryFile');
    local=resolvePackageRelative(root,base,textValue(manifest.freezeFile,'freezeFile'));
    if ~isfile(local)||~isSha256(manifest.freezeSha256)|| ...
            ~strcmpi(nbiot.ml.fileSha256(local),manifest.freezeSha256)
        fail('Training manifest freeze reference is missing or changed.');
    end
    checkOptionalManifestDigest(manifest,'testConsumptionFile','testConsumptionSha256',root,base);
    freeze=readJsonFile(local,'model selection freeze');
    validateFreeze(freeze,manifest,acceptance,ids,sidecar,root,local);
    if ~isfile(paths.dataset)||~strcmpi(nbiot.ml.fileSha256(paths.dataset),acceptance.dataset.sha256) %#ok<*NASGU>
        fail('Dataset MAT bytes do not match the accepted reference.');
    end
end

function validateFreeze(freeze,manifest,acceptance,ids,sidecar,root,freezePath)
required={'schemaVersion','evidenceKind','createdAtUtc','approvedProtocolSha256', ...
    'modelSha256','modelSidecarSha256','policySha256','policyFileSha256','datasetSha256', ...
    'selectionManifestSha256','registrySha256','selectedModel','selectionRule', ...
    'trainingIds','validationIds','testIds','policyTuningIds','models'};
    requireFields(freeze,required,'Model selection freeze is incomplete.');
    requireText(freeze.schemaVersion,'load-model-freeze-v1','freeze schemaVersion');
    if ~strcmpi(textValue(freeze.modelSha256,'freeze model hash'),acceptance.model.sha256)|| ...
            ~strcmpi(textValue(freeze.modelSidecarSha256,'freeze model sidecar hash'),acceptance.modelSidecar.sha256)|| ...
            ~strcmpi(textValue(freeze.datasetSha256,'freeze dataset hash'),acceptance.dataset.sha256)|| ...
            ~strcmpi(textValue(freeze.approvedProtocolSha256,'approved protocol hash'),acceptance.protocol.sha256)|| ...
            ~strcmpi(textValue(freeze.policySha256,'freeze policy digest'),acceptance.policySha256)|| ...
            ~strcmpi(textValue(freeze.policyFileSha256,'freeze policy file hash'),acceptance.policy.sha256)|| ...
            ~strcmpi(textValue(freeze.registrySha256,'freeze registry hash'),acceptance.registry.sha256)|| ...
            ~strcmpi(textValue(freeze.selectionManifestSha256,'selection manifest hash'), ...
            manifest.selectionManifestSha256)
        fail('Freeze hashes do not match the evidence package.');
    end
    validateSameIds(freeze.trainingIds,ids.training,'freeze training IDs');
    validateSameIds(freeze.validationIds,ids.validation,'freeze validation IDs');
    validateSameIds(freeze.testIds,ids.test,'freeze test IDs');
    freezeTuning=normalizeIds(freeze.policyTuningIds,'freeze policy-tuning IDs',true);
    if ~isequal(freezeTuning,normalizeIds(acceptance.policyTuningIds,'policyTuningIds',true))
        fail('Freeze policy-tuning IDs differ from acceptance metadata.');
    end
    if ~strcmp(textValue(freeze.selectedModel,'freeze selected model'),sidecar.modelName)|| ...
            ~strcmp(textValue(manifest.bestValidationModel,'bestValidationModel'),sidecar.modelName)
        fail('Freeze selection differs from the evaluated model.');
    end
    expectedSelectionRule=['lowest-validation-mae;tieOrder=' ...
        'linearRegression,decisionTree,randomForest,gradientBoosting'];
    if ~strcmp(textValue(freeze.selectionRule,'freeze selectionRule'),expectedSelectionRule)
        fail('Freeze selection rule or deterministic tie order is unsupported.');
    end
    if ~isstruct(freeze.models)||numel(freeze.models)~=4|| ...
            ~all(isfield(freeze.models,{'modelName','file','sha256','sidecarFile','sidecarSha256'}))|| ...
            ~any(strcmp({freeze.models.modelName},sidecar.modelName))
        fail('Freeze does not bind the selected model artifact.');
    end
    expectedModels={'linearRegression','decisionTree','randomForest','gradientBoosting'};
    frozenNames=normalizeTextList({freeze.models.modelName},'freeze model names');
    trainingNames=normalizeTextList(manifest.modelNames,'training model names');
    trainingFiles=normalizeTextList(manifest.artifactFiles,'training artifact files');
    trainingHashes=normalizeTextList(manifest.artifactSha256,'training artifact hashes');
    if numel(frozenNames)~=4||~isequal(sort(frozenNames),sort(expectedModels))|| ...
            ~isequal(sort(trainingNames),sort(expectedModels))
        fail('Freeze must contain exactly one artifact for each supported model.');
    end
    for k=1:numel(freeze.models)
        frozen=freeze.models(k);
        frozenName=textValue(frozen.modelName,'freeze model name');
        trainingAt=find(strcmp(trainingNames,frozenName));
        if numel(trainingAt)~=1|| ...
                ~strcmp(textValue(frozen.file,'freeze model file'),trainingFiles{trainingAt})|| ...
                ~strcmpi(textValue(frozen.sha256,'freeze model hash'),trainingHashes{trainingAt})|| ...
                ~strcmp(textValue(frozen.sidecarFile,'freeze sidecar file'),[frozenName '.json'])
            fail('Frozen model artifacts do not match the training-manifest model set.');
        end
        modelPath=resolvePackageRelative(root,fileparts(freezePath),textValue(frozen.file,'freeze model file'));
        sidecarPath=resolvePackageRelative(root,fileparts(freezePath),textValue(frozen.sidecarFile,'freeze sidecar file'));
        if ~isfile(modelPath)||~isfile(sidecarPath)|| ...
                ~strcmpi(nbiot.ml.fileSha256(modelPath),textValue(frozen.sha256,'freeze model hash'))|| ...
                ~strcmpi(nbiot.ml.fileSha256(sidecarPath),textValue(frozen.sidecarSha256,'freeze sidecar hash'))
            fail('Frozen model evidence is missing or changed.');
        end
        frozenSidecar=readJsonFile(sidecarPath,'frozen model sidecar');
        sidecarFields={'modelName','artifactFile','artifactSha256','schemaVersion', ...
            'targetName','trainingIds','validationIds','testIds','status','dataKind'};
        if ~all(isfield(frozenSidecar,sidecarFields))|| ...
                ~strcmp(textValue(frozenSidecar.modelName,'frozen sidecar modelName'),frozenName)|| ...
                ~strcmp(textValue(frozenSidecar.artifactFile,'frozen sidecar artifactFile'),trainingFiles{trainingAt})|| ...
                ~strcmpi(textValue(frozenSidecar.artifactSha256,'frozen sidecar artifact hash'),trainingHashes{trainingAt})|| ...
                ~strcmp(textValue(frozenSidecar.schemaVersion,'frozen sidecar schema'),acceptance.featureSchemaVersion)|| ...
                ~strcmp(textValue(frozenSidecar.targetName,'frozen sidecar target'),'meanRaUe')|| ...
                ~strcmp(textValue(frozenSidecar.status,'frozen sidecar status'),textValue(manifest.status,'training status'))|| ...
                ~strcmp(textValue(frozenSidecar.dataKind,'frozen sidecar dataKind'),textValue(manifest.dataKind,'training dataKind'))
            fail('Frozen model sidecar does not bind its model or provenance.');
        end
        validateSameIds(frozenSidecar.trainingIds,ids.training,'frozen sidecar training IDs');
        validateSameIds(frozenSidecar.validationIds,ids.validation,'frozen sidecar validation IDs');
        validateSameIds(frozenSidecar.testIds,ids.test,'frozen sidecar test IDs');
    end
    at=find(strcmp({freeze.models.modelName},sidecar.modelName),1);
    if ~strcmpi(textValue(freeze.models(at).sha256,'frozen model hash'),acceptance.model.sha256)|| ...
            ~strcmpi(textValue(freeze.models(at).sidecarSha256,'frozen sidecar hash'),acceptance.modelSidecar.sha256)
        fail('Frozen model hashes differ from the acceptance references.');
    end
end

function [metrics,path]=validateMetrics(path,manifest,modelName,ids)
if ~isfile(path), fail('Evaluation metrics file is missing.'); end
try
    metrics=readtable(path,'TextType','string');
catch exception
    fail('Cannot read evaluation metrics: %s.',exception.message);
end
columns={'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
if ~isequal(metrics.Properties.VariableNames,columns)||height(metrics)~=15|| ...
        ~isPositiveInteger(manifest.metricsRowCount)||manifest.metricsRowCount~=height(metrics)
    fail('Evaluated metrics must contain exactly 15 rows and the supported columns.');
end
modelNames=string(metrics.model); splitNames=string(metrics.split);
allowedModels=["linearRegression","decisionTree","randomForest","gradientBoosting","trainMean"];
if any(~ismember(modelNames,allowedModels))||any(~ismember(splitNames,["train","validation","test"]))
    fail('Metrics contain an unsupported model or split name.');
end
if height(unique(table(modelNames,splitNames),'rows'))~=height(metrics)
    fail('Metrics contain duplicate model/split rows.');
end
numericNames={'sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
for k=1:numel(numericNames)
    value=metrics.(numericNames{k});
    if ~isnumeric(value)||~isreal(value)||any(~isfinite(value(:)))
        fail('Metrics contain non-finite numeric values.');
    end
end
if any(metrics.sampleCount<=0|metrics.sampleCount~=fix(metrics.sampleCount))|| ...
        any(metrics.idCount<=0|metrics.idCount~=fix(metrics.idCount))|| ...
        any(metrics.sampleCount<metrics.idCount)|| ...
        any(metrics.mae<0|metrics.rmse<0|metrics.predictionSeconds<0|metrics.trainingSeconds<0)
    fail('Metrics contain invalid counts or negative error/time values.');
end
rmseTolerance=1e-12.*max(1,metrics.rmse);
if any(metrics.rmse+rmseTolerance<metrics.mae)
    fail('Metric RMSE cannot be smaller than MAE beyond numerical tolerance.');
end
splitEvidence=manifest.splitEvidence;
for split={'train','validation','test'}
    at=find(strcmp({splitEvidence.split},split{1}),1); rows=splitNames==string(split{1});
    if isempty(at)||any(metrics.sampleCount(rows)~=splitEvidence(at).sampleCount)|| ...
            any(metrics.idCount(rows)~=splitEvidence(at).idCount)
        fail('Metric sample counts differ from splitEvidence for %s.',split{1});
    end
end
for name=cellstr(allowedModels)
    for split={'train','validation','test'}
        if nnz(modelNames==string(name{1})&splitNames==string(split{1}))~=1
            fail('Metrics must contain one %s/%s row.',name{1},split{1});
        end
    end
end
if ~ismember(modelName,cellstr(allowedModels))
    fail('Selected model is not represented in the metrics.');
end
selectionOrder=["linearRegression","decisionTree","randomForest","gradientBoosting"];
validationScores=zeros(1,numel(selectionOrder));
for k=1:numel(selectionOrder)
    at=modelNames==selectionOrder(k)&splitNames=="validation";
    if nnz(at)~=1, fail('Validation metrics must contain one row per selectable model.'); end
    validationScores(k)=metrics.mae(at);
end
[~,winnerAt]=min(validationScores);
winner=char(selectionOrder(winnerAt));
if ~strcmp(textValue(manifest.bestValidationModel,'bestValidationModel'),winner)|| ...
        ~strcmp(textValue(modelName,'selected model name'),winner)
    fail('Selected model is not the deterministic lowest-validation-MAE winner.');
end
end

function validateDatasetEvidence(manifest,artifacts,acceptance,training,ids,paths,root,metricsPath)
if ~isstruct(manifest)||~isscalar(manifest)|| ...
        ~all(isfield(manifest,{'kind','assignments','inputs','allocationsVerified', ...
        'experimentRolesExplicit','sourceSha256','calibrationSha256'}))
    fail('Dataset manifest is incomplete.');
end
kind=textValue(manifest.kind,'dataset kind');
if ~strcmp(kind,textValue(training.dataKind,'training data kind'))
    fail('Dataset manifest kind differs from the training manifest.');
end
if ~isstruct(manifest.inputs)||isempty(manifest.inputs)|| ...
        ~isstruct(manifest.assignments)||isempty(manifest.assignments)
    fail('Dataset manifest needs explicit inputs and split assignments.');
end
if ~isLogicalScalar(manifest.allocationsVerified)|| ...
        ~isLogicalScalar(manifest.experimentRolesExplicit)|| ...
        (strcmp(kind,'candidate-training')&& ...
            (~manifest.allocationsVerified||~manifest.experimentRolesExplicit|| ...
            ~isfield(manifest,'diagnosticsComplete')||~isLogicalScalar(manifest.diagnosticsComplete)|| ...
            ~manifest.diagnosticsComplete||~isfield(manifest,'diagnosticsSchemaVersion')|| ...
            ~strcmp(textValue(manifest.diagnosticsSchemaVersion,'diagnostics schema'), ...
                'window-diagnostics-v1')||~logical(training.allocationsVerified)))|| ...
        (strcmp(kind,'development-fixture')&& ...
            (manifest.allocationsVerified||manifest.experimentRolesExplicit||logical(training.allocationsVerified)))
    fail('Dataset allocation, role, or diagnostics flags do not match its provenance.');
end
if ~ismember(kind,{'candidate-training','development-fixture'})
    fail('Dataset kind is unsupported for model acceptance.');
end
requiredInput={'resultFile','caseKey','sourceSha256','calibrationSha256','markerSha256', ...
    'schemaVersion','numUE','realizationId','isFixture','trafficKind'};
if ~all(isfield(manifest.inputs,requiredInput))
    fail('Dataset input provenance is incomplete.');
end
inputIds=zeros(1,numel(manifest.inputs)); caseKeys=cell(1,numel(manifest.inputs));
caseEvidence=repmat(struct('caseKey','','realizationId',0, ...
    'observationsPath','','targetsPath',''),1,numel(manifest.inputs));
for k=1:numel(manifest.inputs)
    item=manifest.inputs(k); inputIds(k)=scalarId(item.realizationId,'dataset input realizationId');
    caseKeys{k}=textValue(item.caseKey,'dataset input caseKey');
    if isempty(caseKeys{k})||~isSha256(item.sourceSha256)||~isSha256(item.calibrationSha256)|| ...
            ~isSha256(item.markerSha256)||~isPositiveInteger(item.numUE)|| ...
            ~strcmp(textValue(item.schemaVersion,'dataset input schema'),acceptance.featureSchemaVersion)
        fail('Dataset input provenance is invalid.');
    end
    if ~strcmpi(item.sourceSha256,manifest.sourceSha256)|| ...
            ~strcmpi(item.calibrationSha256,manifest.calibrationSha256)
        fail('Dataset inputs mix computational-source or calibration versions.');
    end
    if ~isLogicalScalar(item.isFixture)|| ...
            (strcmp(kind,'candidate-training')&&item.isFixture)
        fail('Candidate-training inputs cannot be fixture-derived.');
    end
    caseEvidence(k)=validateCaseCompletionEvidence(item,root,manifest.sourceSha256, ...
        manifest.calibrationSha256);
end
if numel(unique(inputIds))~=numel(inputIds)||numel(unique(caseKeys))~=numel(caseKeys)
    fail('Dataset input IDs and case keys must be unique.');
end
assignments=manifest.assignments; requiredAssignment={'externalRealizationId','split','experimentRole'};
if ~all(isfield(assignments,requiredAssignment))
    fail('Dataset split assignments must include explicit roles.');
end
assignmentIds=zeros(1,numel(assignments)); assignmentRoles=cell(1,numel(assignments));
assignmentSplits=cell(1,numel(assignments));
for k=1:numel(assignments)
    assignmentIds(k)=scalarId(assignments(k).externalRealizationId,'dataset assignment ID');
    assignmentRoles{k}=textValue(assignments(k).experimentRole,'dataset experiment role');
    assignmentSplits{k}=textValue(assignments(k).split,'dataset split');
    if ~ismember(assignmentSplits{k},{'train','validation','test'})|| ...
            ~ismember(assignmentRoles{k},{'training','validation','model-test'})
        fail('Dataset assignment uses a disallowed split or experiment role.');
    end
end
if numel(unique(assignmentIds))~=numel(assignmentIds)|| ...
        ~isequal(sort(inputIds),sort(assignmentIds))|| ...
        ~isequal(sort(assignmentIds),sort([ids.training ids.validation ids.test]))
    fail('Dataset assignments contain missing or extra realization IDs.');
end
expectedRoles=cell(size(assignmentIds));
for k=1:numel(assignmentIds)
    if ismember(assignmentIds(k),ids.training), expectedRoles{k}='training'; expectedSplit='train';
    elseif ismember(assignmentIds(k),ids.validation), expectedRoles{k}='validation'; expectedSplit='validation';
    else, expectedRoles{k}='model-test'; expectedSplit='test'; end
    if ~strcmp(assignmentRoles{k},expectedRoles{k})||~strcmp(assignmentSplits{k},expectedSplit)
        fail('Dataset assignment role or split differs from the frozen IDs.');
    end
end

artifactFolder=fileparts(paths.datasetArtifacts);
if ~isstruct(artifacts)||~isscalar(artifacts)||~isfield(artifacts,'schemaVersion')|| ...
        artifacts.schemaVersion~=1||~isfield(artifacts,'files')||~isstruct(artifacts.files)||isempty(artifacts.files)
    fail('Dataset artifacts manifest is invalid.');
end
names={}; artifactPaths=struct();
for k=1:numel(artifacts.files)
    item=artifacts.files(k);
    if ~all(isfield(item,{'name','sha256','bytes'})), fail('Dataset artifact entry is incomplete.'); end
    name=textValue(item.name,'dataset artifact name');
    if ~isBasename(name)||~isSha256(item.sha256)||~isPositiveInteger(item.bytes)||ismember(name,names)
        fail('Dataset artifact name, size, or digest is invalid.');
    end
    artifactPath=resolvePackageRelative(root,artifactFolder,name); info=dir(artifactPath);
    if isempty(info)||info.isdir||info.bytes~=item.bytes|| ...
            ~strcmpi(nbiot.ml.fileSha256(artifactPath),item.sha256)
        fail('Dataset artifact is missing or changed: %s.',name);
    end
    names{end+1}=name; %#ok<AGROW>
    artifactPaths.(matlab.lang.makeValidName(name))=artifactPath;
end
requiredArtifacts={'dataset.mat','manifest.json','rows.csv','diagnostics.csv', ...
    'observations.csv','targets.csv'};
if ~all(ismember(requiredArtifacts,names))
    fail('Dataset artifact set must include dataset, manifest, rows, and diagnostics.');
end
if ~strcmpi(nbiot.ml.fileSha256(artifactPaths.dataset_mat),acceptance.dataset.sha256)|| ...
        ~strcmpi(nbiot.ml.fileSha256(artifactPaths.manifest_json),acceptance.datasetManifest.sha256)
    fail('Dataset artifacts differ from the referenced dataset or manifest.');
end
if ~strcmpi(textValue(manifest.sourceSha256,'dataset source hash'),training.sourceSha256)|| ...
        ~strcmpi(textValue(manifest.calibrationSha256,'dataset calibration hash'),training.calibrationSha256)
    fail('Dataset source/calibration hashes differ from the training manifest.');
end

try, rows=readtable(artifactPaths.rows_csv,'TextType','string');
catch exception, fail('Cannot read dataset row map: %s.',exception.message); end
rowFields={'caseKey','realizationId','windowId','startTick','endTick','split','experimentRole'};
if ~all(ismember(rowFields,rows.Properties.VariableNames))||height(rows)==0
    fail('Dataset row map is missing case, ID, split, or role columns.');
end
validateUniqueWindowKeys(rows,'dataset row map');
rowCase=string(rows.caseKey); rowIds=double(rows.realizationId);
rowSplit=string(rows.split); rowRole=string(rows.experimentRole);
if any(~isfinite(rowIds)|rowIds<0|rowIds>3999|rowIds~=fix(rowIds))
    fail('Dataset row map contains invalid realization IDs.');
end
for k=1:numel(manifest.inputs)
    item=manifest.inputs(k); mask=rowCase==string(item.caseKey);
    if ~any(mask)||any(rowIds(mask)~=double(item.realizationId))
        fail('Dataset row map does not match input case %s.',item.caseKey);
    end
    at=find(assignmentIds==double(item.realizationId),1);
    if isempty(at)||any(rowSplit(mask)~=string(assignmentSplits{at}))|| ...
            any(rowRole(mask)~=string(assignmentRoles{at}))
        fail('Dataset row map split/role differs from assignment for %s.',item.caseKey);
    end
end
if any(~ismember(rowCase,string(caseKeys)))||isempty(metricsPath)
    fail('Dataset row map contains an unassigned case or metrics evidence is unavailable.');
end
splitNames={'train','validation','test'};
for k=1:3
    rowMask=rowSplit==string(splitNames{k});
    splitAt=find(strcmp({training.splitEvidence.split},splitNames{k}),1);
    if isempty(splitAt)||nnz(rowMask)~=double(training.splitEvidence(splitAt).sampleCount)|| ...
            numel(unique(rowIds(rowMask)))~=double(training.splitEvidence(splitAt).idCount)
        fail('Dataset row counts differ from training splitEvidence for %s.', ...
            splitNames{k});
    end
end
try, diagnostics=readtable(artifactPaths.diagnostics_csv,'TextType','string');
catch exception, fail('Cannot read dataset diagnostics: %s.',exception.message); end
diagnosticKeys={'caseKey','realizationId','windowId','startTick','endTick'};
if ~all(ismember(diagnosticKeys,diagnostics.Properties.VariableNames))||height(diagnostics)~=height(rows)
    fail('Dataset diagnostics lack complete one-to-one window keys.');
end
validateTableColumnsEqual(diagnostics,rows,diagnosticKeys,'diagnostics CSV and row map');
try
    observations=readtable(artifactPaths.observations_csv,'TextType','string');
    targets=readtable(artifactPaths.targets_csv,'TextType','string');
catch exception
    fail('Cannot read dataset observations/targets exports: %s.',exception.message);
end
caseKeys={'caseKey','realizationId','windowId','startTick','endTick'};
validateTableColumnsEqual(observations,rows,caseKeys,'observations CSV and row map');
validateTableColumnsEqual(targets,rows,caseKeys,'targets CSV and row map');
persisted=loadPersistedDataset(artifactPaths.dataset_mat);
validatePersistedDataset(persisted,manifest,rows,diagnostics,observations,targets,kind);
validateCaseDatasetExports(persisted,caseEvidence);
end

function evidence=validateCaseCompletionEvidence(input,root,sourceSha,calibrationSha)
resultFile=textValue(input.resultFile,'dataset input resultFile');
validateSafePackageRelativePath(resultFile,'dataset input resultFile');
resultPath=resolvePackageRelative(root,root,resultFile);
if ~isfile(resultPath)
    fail('Dataset input result artifact is unavailable: %s.',resultFile);
end
caseFolder=fileparts(resultPath);
markerPath=resolvePackageRelative(root,caseFolder,'case-complete.json');
if ~isfile(markerPath)||~strcmpi(nbiot.ml.fileSha256(markerPath),input.markerSha256)
    fail('Dataset completion marker is missing or changed for case %s.',input.caseKey);
end
marker=readJsonFile(markerPath,'dataset input completion marker');
required={'manifestVersion','caseKey','status','sourceSha256','calibrationSha256', ...
    'resultFile','exportStem','files'};
if ~all(isfield(marker,required))||~isnumeric(marker.manifestVersion)|| ...
        ~isscalar(marker.manifestVersion)||~ismember(double(marker.manifestVersion),[1 2 3])|| ...
        ~strcmp(textValue(marker.status,'completion status'),'completed')|| ...
        ~strcmp(textValue(marker.caseKey,'completion caseKey'),textValue(input.caseKey,'dataset caseKey'))|| ...
        ~strcmpi(textValue(marker.sourceSha256,'completion source hash'),sourceSha)|| ...
        ~strcmpi(textValue(marker.calibrationSha256,'completion calibration hash'),calibrationSha)
    fail('Dataset input completion marker does not match its provenance.');
end
[~,resultName,resultExtension]=fileparts(resultPath);
if ~strcmp(textValue(marker.resultFile,'completion resultFile'),[resultName resultExtension])
    fail('Dataset input result path differs from its completion marker.');
end
stem=textValue(marker.exportStem,'completion exportStem');
if ~isSafeStem(stem)||~isstruct(marker.files)||isempty(marker.files)|| ...
        ~all(isfield(marker.files,{'name','bytes','sha256'}))
    fail('Dataset completion marker has invalid export file records.');
end
fileNames=cell(1,numel(marker.files));
for k=1:numel(marker.files)
    fileNames{k}=textValue(marker.files(k).name,'completion export name');
    if ~isBasename(fileNames{k})||~isPositiveInteger(marker.files(k).bytes)|| ...
            ~isSha256(marker.files(k).sha256)||any(strcmpi(fileNames{k},fileNames(1:k-1)))
        fail('Dataset completion marker contains an invalid or duplicate file record.');
    end
end
requiredFiles={[resultName resultExtension],[stem '_summary.csv'], ...
    [stem '_observations.csv'],[stem '_targets.csv']};
for k=1:numel(requiredFiles)
    at=find(strcmp(fileNames,requiredFiles{k}));
    if numel(at)~=1, fail('Completion marker is missing required file %s.',requiredFiles{k}); end
    path=resolvePackageRelative(root,caseFolder,requiredFiles{k}); info=dir(path);
    if isempty(info)||info.isdir||info.bytes~=marker.files(at).bytes|| ...
            ~strcmpi(nbiot.ml.fileSha256(path),marker.files(at).sha256)
        fail('A required completion export is unavailable or changed: %s.',requiredFiles{k});
    end
end
evidence=struct('caseKey',textValue(input.caseKey,'dataset caseKey'), ...
    'realizationId',scalarId(input.realizationId,'dataset input realizationId'), ...
    'observationsPath',resolvePackageRelative(root,caseFolder,[stem '_observations.csv']), ...
    'targetsPath',resolvePackageRelative(root,caseFolder,[stem '_targets.csv']));
end

function validateSafePackageRelativePath(value,label)
normalized=strrep(value,'\','/');
parts=split(string(normalized),'/');
if isempty(normalized)||startsWith(normalized,'/')||contains(normalized,':')|| ...
        contains(normalized,char(10))||contains(normalized,char(13))|| ...
        any(parts==""|parts=="."|parts=="..")
    fail('%s must be a safe package-relative path.',label);
end
end

function yes=isSafeStem(value)
[folder,name,extension]=fileparts(value);
yes=~isempty(value)&&isempty(folder)&&isempty(extension)&&~isempty(name)&& ...
    ~contains(value,'..')&&~contains(value,':')&&~contains(value,'\');
end

function data=loadPersistedDataset(datasetFile)
try
    saved=load(datasetFile,'data');
catch exception
    fail('Cannot load the persisted dataset structure: %s.',exception.message);
end
if ~isfield(saved,'data')||~isstruct(saved.data)||~isscalar(saved.data)
    fail('Persisted dataset MAT must contain one scalar data structure.');
end
data=saved.data;
end

function validatePersistedDataset(data,manifest,rows,diagnostics,observations,targets,kind)
required={'manifest','rowInfo','observations','targets','diagnostics'};
if ~all(isfield(data,required))||~isstruct(data.manifest)||~isscalar(data.manifest)|| ...
        ~istable(data.rowInfo)||~istable(data.observations)||~istable(data.targets)||~istable(data.diagnostics)
    fail('Persisted dataset MAT lacks its manifest, row map, observations, targets, or diagnostics.');
end
validateUniqueWindowKeys(data.rowInfo,'persisted row map');
validateUniqueWindowKeys(data.observations,'persisted observations');
validateUniqueWindowKeys(data.targets,'persisted targets');
validateUniqueWindowKeys(data.diagnostics,'persisted diagnostics');
embedded=data.manifest;
textFields={'kind','sourceSha256','calibrationSha256'};
for k=1:numel(textFields)
    name=textFields{k};
    if ~isfield(embedded,name)||~strcmp(textValue(embedded.(name),['persisted dataset ' name]), ...
            textValue(manifest.(name),['dataset manifest ' name]))
        fail('Persisted dataset MAT differs from manifest.json for %s.',name);
    end
end
flagFields={'allocationsVerified','experimentRolesExplicit'};
if isfield(manifest,'diagnosticsComplete'), flagFields{end+1}='diagnosticsComplete'; end
for k=1:numel(flagFields)
    name=flagFields{k};
    if ~isfield(embedded,name)||~isLogicalScalar(embedded.(name))|| ...
            ~isfield(manifest,name)||~isLogicalScalar(manifest.(name))|| ...
            embedded.(name)~=manifest.(name)
        fail('Persisted dataset MAT differs from manifest.json for %s.',name);
    end
end
validateEmbeddedAssignments(embedded,manifest);
validateEmbeddedInputs(embedded,manifest);
rowFields={'caseKey','realizationId','windowId','startTick','endTick','split','experimentRole'};
validateTableColumnsEqual(data.rowInfo,rows,rowFields,'persisted dataset and row map');
diagnosticKeys={'caseKey','realizationId','windowId','startTick','endTick'};
validateTableColumnsEqual(data.diagnostics,diagnostics,diagnosticKeys, ...
    'persisted diagnostics and diagnostics CSV');
datasetKeys={'realizationId','windowId','startTick','endTick'};
validateTableColumnsEqual(data.observations,rows,datasetKeys,'persisted observations and row map');
validateTableColumnsEqual(data.targets,rows,datasetKeys,'persisted targets and row map');
validateDatasetExportValues(observations,data.observations,data.rowInfo,'observations export');
validateDatasetExportValues(targets,data.targets,data.rowInfo,'targets export');
if strcmp(kind,'candidate-training')
    fullDiagnostics={'caseKey','realizationId','windowId','startTick','endTick', ...
        'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
        'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
        'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
        'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
        'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'};
    if ~all(ismember(fullDiagnostics,diagnostics.Properties.VariableNames))|| ...
            ~all(ismember(fullDiagnostics,data.diagnostics.Properties.VariableNames))
        fail('Scientific candidate diagnostics do not match the required window schema.');
    end
    if ~isfield(embedded,'diagnosticsSchemaVersion')|| ...
            ~strcmp(textValue(embedded.diagnosticsSchemaVersion,'persisted diagnostics schema'), ...
                'window-diagnostics-v1')
        fail('Persisted dataset diagnostics schema is missing or unsupported.');
    end
    validateTableColumnsEqual(data.diagnostics,diagnostics,fullDiagnostics, ...
        'persisted diagnostics and diagnostics CSV');
end
end

function validateDatasetExportValues(exported,persisted,rowInfo,label)
if ~istable(exported)||~istable(persisted)||~istable(rowInfo)|| ...
        height(persisted)~=height(rowInfo)||ismember('caseKey',persisted.Properties.VariableNames)
    fail('%s cannot be aligned with the persisted dataset.',label);
end
validateUniqueWindowKeys(persisted,label);
validateUniqueWindowKeys(exported,label);
fields=persisted.Properties.VariableNames;
expectedFields=[fields,{'caseKey'}];
if numel(exported.Properties.VariableNames)~=numel(expectedFields)|| ...
        ~isequal(sort(exported.Properties.VariableNames),sort(expectedFields))
    fail('%s columns differ from the persisted dataset.',label);
end
expected=persisted; expected.caseKey=rowInfo.caseKey;
validateTableColumnsEqual(expected,exported,expectedFields,[label ' and dataset MAT']);
end

function validateCaseDatasetExports(data,evidence)
keys={'realizationId','windowId','startTick','endTick'};
for k=1:numel(evidence)
    item=evidence(k); mask=string(data.rowInfo.caseKey)==string(item.caseKey);
    if ~any(mask)||any(double(data.rowInfo.realizationId(mask))~=item.realizationId)
        fail('Persisted dataset has no rows for input case %s.',item.caseKey);
    end
    try
        observations=readtable(item.observationsPath,'VariableNamingRule','preserve','TextType','string');
        targets=readtable(item.targetsPath,'VariableNamingRule','preserve','TextType','string');
    catch exception
        fail('Cannot read input observation/target exports for %s: %s.',item.caseKey,exception.message);
    end
    validateUniqueWindowKeys(observations,['case observations for ' item.caseKey]);
    validateUniqueWindowKeys(targets,['case targets for ' item.caseKey]);
    if ~isequal(sort(observations.Properties.VariableNames), ...
            sort(data.observations.Properties.VariableNames))|| ...
            ~isequal(sort(targets.Properties.VariableNames),sort(data.targets.Properties.VariableNames))
        fail('Input observation/target columns differ from the persisted dataset for %s.',item.caseKey);
    end
    expectedObservations=sortrows(data.observations(mask,:),keys);
    expectedTargets=sortrows(data.targets(mask,:),keys);
    observations=sortrows(observations,keys); targets=sortrows(targets,keys);
    validateTableColumnsEqual(expectedObservations,observations, ...
        data.observations.Properties.VariableNames, ...
        ['case observations and persisted dataset for ' item.caseKey]);
    validateTableColumnsEqual(expectedTargets,targets,data.targets.Properties.VariableNames, ...
        ['case targets and persisted dataset for ' item.caseKey]);
end
end

function validateUniqueWindowKeys(value,label)
fields={'realizationId','windowId','startTick','endTick'};
if ~istable(value)||~all(ismember(fields,value.Properties.VariableNames))
    fail('%s do not contain the supported window-key columns.',label);
end
for k=1:numel(fields)
    column=value.(fields{k});
    if ~isnumeric(column)||~isreal(column)||~isvector(column)|| ...
            numel(column)~=height(value)||any(~isfinite(column(:)))
        fail('%s contain invalid window keys.',label);
    end
end
if height(unique(value(:,fields),'rows'))~=height(value)
    fail('%s contain duplicate window keys.',label);
end
end

function validateEmbeddedAssignments(embedded,manifest)
if ~isfield(embedded,'assignments')||~isfield(manifest,'assignments')
    fail('Persisted dataset assignments are missing.');
end
left=embedded.assignments; right=manifest.assignments;
if istable(left), left=table2struct(left); end
required={'externalRealizationId','split','experimentRole'};
if ~isstruct(left)||~isstruct(right)||numel(left)~=numel(right)|| ...
        ~all(isfield(left,required))||~all(isfield(right,required))
    fail('Persisted dataset assignments do not match manifest.json.');
end
for k=1:numel(right)
    id=scalarId(right(k).externalRealizationId,'dataset assignment ID');
    at=find([left.externalRealizationId]==id);
    if numel(at)~=1||~strcmp(textValue(left(at).split,'persisted assignment split'), ...
            textValue(right(k).split,'dataset assignment split'))|| ...
            ~strcmp(textValue(left(at).experimentRole,'persisted assignment role'), ...
            textValue(right(k).experimentRole,'dataset assignment role'))
        fail('Persisted dataset assignments differ from manifest.json.');
    end
end
end

function validateEmbeddedInputs(embedded,manifest)
if ~isfield(embedded,'inputs')||~isstruct(embedded.inputs)|| ...
        numel(embedded.inputs)~=numel(manifest.inputs)
    fail('Persisted dataset inputs do not match manifest.json.');
end
fields={'resultFile','caseKey','sourceSha256','calibrationSha256','markerSha256', ...
    'schemaVersion','realizationId','isFixture','trafficKind'};
for k=1:numel(manifest.inputs)
    input=manifest.inputs(k); id=scalarId(input.realizationId,'dataset input ID');
    at=find([embedded.inputs.realizationId]==id);
    if numel(at)~=1, fail('Persisted dataset input ID is missing or duplicated.'); end
    for j=1:numel(fields)
        name=fields{j};
        if ~isfield(embedded.inputs(at),name)||~isfield(input,name)
            fail('Persisted dataset input is missing %s.',name);
        end
        left=embedded.inputs(at).(name); right=input.(name);
        if ischar(left)||isstring(left)||ischar(right)||isstring(right)
            same=strcmp(textValue(left,['persisted input ' name]), ...
                textValue(right,['dataset input ' name]));
        else
            same=isequaln(left,right);
        end
        if ~same, fail('Persisted dataset input differs from manifest.json for %s.',name); end
    end
end
end

function validateTableColumnsEqual(left,right,fields,label)
if ~istable(left)||~istable(right)||height(left)~=height(right)|| ...
        ~all(ismember(fields,left.Properties.VariableNames))|| ...
        ~all(ismember(fields,right.Properties.VariableNames))
    fail('%s do not have matching columns and rows.',label);
end
for k=1:numel(fields)
    a=left.(fields{k}); b=right.(fields{k});
    if isnumeric(a)||islogical(a), a=double(a(:)); else, a=string(a(:)); end
    if isnumeric(b)||islogical(b), b=double(b(:)); else, b=string(b(:)); end
    if ~isequaln(a,b), fail('%s differ in %s.',label,fields{k}); end
end
end

function validateSourceEvidence(manifest,manifestPath,acceptance,training,root)
if ~isstruct(manifest)||~isscalar(manifest)|| ...
        ~all(isfield(manifest,{'schemaVersion','sourceSha256','calibrationSha256','files'}))|| ...
        manifest.schemaVersion~=1||~isSha256(manifest.sourceSha256)||~isSha256(manifest.calibrationSha256)|| ...
        ~isstruct(manifest.files)||isempty(manifest.files)||~isSha256(acceptance.calibration.sha256)
    fail('Source manifest or calibration evidence is incomplete.');
end
if ~strcmpi(manifest.sourceSha256,training.sourceSha256)|| ...
        ~strcmpi(manifest.calibrationSha256,training.calibrationSha256)|| ...
        ~strcmpi(manifest.calibrationSha256,acceptance.calibration.sha256)
    fail('Source manifest, training data, and calibration evidence do not match.');
end
base=fileparts(manifestPath); names={};
for k=1:numel(manifest.files)
    item=manifest.files(k);
    if ~all(isfield(item,{'name','sha256'})), fail('Source manifest file entry is incomplete.'); end
    name=textValue(item.name,'source manifest file name');
    validateSafePackageRelativePath(name,'source manifest file name');
    if ~isSha256(item.sha256)||any(strcmpi(name,names))
        fail('Source manifest contains an invalid file record.');
    end
    path=resolvePackageRelative(root,base,name);
    if ~isfile(path)||~strcmpi(nbiot.ml.fileSha256(path),item.sha256)
        fail('Computational source file is missing or changed: %s.',name);
    end
    names{end+1}=name; %#ok<AGROW>
end
end

function validateRegistry(registry,ids,tuningIds)
required={'schemaVersion','validRange','roles','reservations','assignments'};
if ~isstruct(registry)||~isscalar(registry)||~all(isfield(registry,required))|| ...
        registry.schemaVersion~=1||~isnumeric(registry.validRange)||~isreal(registry.validRange)|| ...
        numel(registry.validRange)~=2|| ...
        any(~isfinite(registry.validRange))||registry.validRange(1)<0|| ...
        registry.validRange(2)>3999||registry.validRange(2)<registry.validRange(1)|| ...
        any(registry.validRange~=fix(registry.validRange))||~isstruct(registry.assignments)
    fail('Allocation registry snapshot is invalid.');
end
roles=normalizeTextList(registry.roles,'registry roles');
occupied=[]; allocatedRole=containers.Map('KeyType','char','ValueType','char');
allocatedStatus=containers.Map('KeyType','char','ValueType','char');
for k=1:numel(registry.assignments)
    item=registry.assignments(k);
    if ~all(isfield(item,{'role','ids','status'})), fail('Registry assignment is incomplete.'); end
    role=textValue(item.role,'registry role'); status=textValue(item.status,'registry status');
    itemIds=normalizeIds(item.ids,'registry assignment IDs',false);
    if ~ismember(role,roles)||~ismember(status,{'planned','completed','failed'})|| ...
            any(itemIds<registry.validRange(1)|itemIds>registry.validRange(2))|| ...
            ~isempty(intersect(occupied,itemIds))
        fail('Registry assignments have invalid role, status, range, or duplicate IDs.');
    end
    for id=itemIds
        key=sprintf('%.0f',id); allocatedRole(key)=role; allocatedStatus(key)=status;
    end
    occupied=[occupied itemIds]; %#ok<AGROW>
end
reserved=[]; reservations=registry.reservations;
if ~isstruct(reservations)&&~isempty(reservations), fail('Registry reservations are invalid.'); end
for k=1:numel(reservations)
    item=reservations(k);
    if isfield(item,'ids')&&~isempty(item.ids)
        reservationIds=normalizeIds(item.ids,'reserved IDs',false);
    elseif isfield(item,'range')&&isnumeric(item.range)&&isreal(item.range)&& ...
            numel(item.range)==2&&all(isfinite(item.range))&&all(item.range==fix(item.range))&& ...
            item.range(1)>=registry.validRange(1)&&item.range(2)<=registry.validRange(2)&&item.range(2)>=item.range(1)
        reservationIds=item.range(1):item.range(2);
    else
        fail('Registry reservation has no valid IDs or range.');
    end
    reserved=[reserved double(reservationIds(:).')]; %#ok<AGROW>
end
allIds=[ids.training ids.validation ids.test tuningIds];
if ~isempty(intersect(allIds,reserved)), fail('A model or policy-tuning ID is reserved.'); end
groups={ids.training,ids.validation,ids.test}; expectedRoles={'training','validation','model-test'};
for g=1:3
    for id=groups{g}
        key=sprintf('%.0f',id);
        if ~isKey(allocatedRole,key)||~strcmp(allocatedRole(key),expectedRoles{g})|| ...
                ~strcmp(allocatedStatus(key),'completed')
            fail('Every frozen split ID needs one completed matching registry allocation.');
        end
    end
end
for id=tuningIds
    key=sprintf('%.0f',id);
    if ~isKey(allocatedRole,key)||~strcmp(allocatedStatus(key),'completed')|| ...
            ~ismember(allocatedRole(key),{'development','validation'})
        fail('Policy-tuning IDs need completed development or validation allocations.');
    end
end
end

function validatePolicy(policy,acceptance,training)
defaults=adaptiveDefaults(); fields=fieldnames(defaults);
if ~isstruct(policy)||~isscalar(policy)||~isequal(sort(fieldnames(policy)),sort(fields))
    fail('Policy must contain exactly all adaptiveDefaults fields.');
end
try, digest=nbiot.controller.policySha256(policy);
catch exception, fail('Policy is invalid: %s.',exception.message); end
if ~strcmpi(digest,acceptance.policySha256)|| ...
        ~strcmpi(digest,textValue(training.policySha256,'training policy digest'))|| ...
        ~strcmp(textValue(policy.status,'policy status'),'frozen-validation')
    fail('Frozen policy digest or status differs from the evidence.');
end
if ~isPositiveInteger(policy.windowTicks)||~isPositiveInteger(policy.maximumLoad)|| ...
        ~isProbability(policy.staticAccessProbability)||~isProbability(policy.staticRaShare)|| ...
        ~validIncreasing(policy.accessLoadThresholds)|| ...
        ~validLevels(policy.accessProbabilityLevels,numel(policy.accessLoadThresholds)+1,'descending')|| ...
        ~validIncreasing(policy.raLoadThresholds)|| ...
        ~validLevels(policy.raShareLevels,numel(policy.raLoadThresholds)+1,'ascending')|| ...
        policy.maximumLoad<max([policy.accessLoadThresholds(:);policy.raLoadThresholds(:)])
    fail('Frozen adaptive policy thresholds or levels are invalid.');
end
end

function validateProtocol(protocol,acceptance,policy,protocolPath)
required={'schemaVersion','frozenAtUtc','approver','approvedAtUtc','baseline', ...
    'selectionRule','thresholds','requiredStrata','scope','policyTuningAllowedRoles','testConsumption'};
if ~isstruct(protocol)||~isscalar(protocol)||~all(isfield(protocol,required))|| ...
        protocol.schemaVersion~=1||isempty(textValue(protocol.approver,'protocol approver'))|| ...
        ~strcmp(textValue(protocol.baseline,'protocol baseline'),'trainMean')|| ...
        ~strcmp(textValue(protocol.selectionRule,'protocol selection rule'),'lowest-validation-mae')|| ...
        ~strcmp(textValue(protocol.testConsumption,'protocol test consumption'),'once-after-freeze')
    fail('Approved protocol is malformed or incomplete.');
end
frozenAt=parseUtc(protocol.frozenAtUtc,'protocol frozenAtUtc');
approvedAt=parseUtc(protocol.approvedAtUtc,'protocol approvedAtUtc');
if approvedAt<frozenAt, fail('Protocol approval must follow the frozen protocol.'); end
thresholdNames={'maxMae','maxRmse','maxMaeToBaselineRatio','maxRmseToBaselineRatio'};
if ~isstruct(protocol.thresholds)||~isscalar(protocol.thresholds)||~all(isfield(protocol.thresholds,thresholdNames))
    fail('Protocol must state all four numerical thresholds.');
end
for k=1:numel(thresholdNames)
    value=protocol.thresholds.(thresholdNames{k});
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)||value<0
        fail('Protocol thresholds must be finite nonnegative numbers.');
    end
end
if ~isstruct(protocol.requiredStrata)||isempty(protocol.requiredStrata)|| ...
        ~all(isfield(protocol.requiredStrata,{'numUE','trafficKind'}))
    fail('Protocol must list explicit required strata.');
end
for k=1:numel(protocol.requiredStrata)
    stratum=protocol.requiredStrata(k);
    if ~isPositiveInteger(stratum.numUE)|| ...
            ~ismember(textValue(stratum.trafficKind,'required traffic kind'),{'burst','periodic','poisson'})
        fail('Protocol contains an invalid required stratum.');
    end
    if ~ismember(double(stratum.numUE),double(protocol.scope.numUE(:)))|| ...
            ~ismember(textValue(stratum.trafficKind,'required traffic kind'), ...
            cellstr(string(protocol.scope.trafficKinds(:))))
        fail('Required strata must be included in the approved scope.');
    end
end
roles=normalizeTextList(protocol.policyTuningAllowedRoles,'policy tuning roles');
if ~isequal(sort(roles),sort({'development','validation'}))
    fail('Policy tuning must be limited to development and validation.');
end
validateScope(protocol.scope);
if ~strcmp(canonicalScopeJson(protocol.scope),canonicalScopeJson(acceptance.scope))
    fail('Acceptance scope differs from the approved protocol scope.');
end
if double(policy.windowTicks)~=double(protocol.scope.windowTicks)
    fail('Frozen policy window does not match the approved protocol scope.');
end
if ~strcmpi(nbiot.ml.fileSha256(protocolPath),acceptance.protocol.sha256)
    fail('Protocol bytes changed after reference validation.');
end
end

function validateEvaluation(evaluation,protocol,acceptance,training,sidecar,ids,metrics,freeze)
required={'schemaVersion','status','evidenceKind','datasetSha256','modelSha256', ...
    'protocolSha256','frozenModelSha256','selectedModel','evaluatedAtUtc', ...
    'selectionSplit','testOpenedAtUtc','completedAtUtc','strata','passed','unmetRequirements', ...
    'freezeSha256','selectionManifestSha256'};
requireFields(evaluation,required,'Model evaluation report is incomplete.');
requireText(evaluation.schemaVersion,'load-model-evaluation-v1','evaluation schemaVersion');
if ~strcmp(textValue(evaluation.status,'evaluation status'),'complete')|| ...
        ~strcmp(textValue(evaluation.selectionSplit,'selection split'),'validation')|| ...
        ~isLogicalScalar(evaluation.passed)||~evaluation.passed||~isempty(evaluation.unmetRequirements)
    fail('Evaluation is incomplete, failed, or has unmet requirements.');
end
if ~strcmpi(textValue(evaluation.datasetSha256,'evaluation dataset hash'),acceptance.dataset.sha256)|| ...
        ~strcmpi(textValue(evaluation.modelSha256,'evaluation model hash'),acceptance.model.sha256)|| ...
        ~strcmpi(textValue(evaluation.frozenModelSha256,'frozen evaluation model hash'),acceptance.model.sha256)|| ...
        ~strcmpi(textValue(evaluation.protocolSha256,'evaluation protocol hash'),acceptance.protocol.sha256)|| ...
        ~strcmp(textValue(evaluation.selectedModel,'evaluation selected model'),sidecar.modelName)|| ...
        ~strcmpi(textValue(evaluation.freezeSha256,'evaluation freeze hash'),training.freezeSha256)|| ...
        ~strcmpi(textValue(evaluation.selectionManifestSha256,'evaluation selection manifest hash'), ...
        training.selectionManifestSha256)
    fail('Evaluation hashes or selected model do not match the frozen evidence.');
end
approvedAt=parseUtc(protocol.approvedAtUtc,'protocol approvedAtUtc');
frozenAt=parseUtc(freeze.createdAtUtc,'freeze createdAtUtc');
openedAt=parseUtc(evaluation.testOpenedAtUtc,'evaluation testOpenedAtUtc');
evaluatedAt=parseUtc(evaluation.evaluatedAtUtc,'evaluation evaluatedAtUtc');
completedAt=parseUtc(evaluation.completedAtUtc,'evaluation completedAtUtc');
if approvedAt>frozenAt||openedAt<approvedAt||openedAt<frozenAt||completedAt<openedAt|| ...
        evaluatedAt<openedAt||completedAt<evaluatedAt
    fail('Protocol approval, freeze, and test evaluation timestamps are out of order.');
end
if ~isstruct(evaluation.strata)||isempty(evaluation.strata)|| ...
        ~all(isfield(evaluation.strata,{'split','numUE','trafficKind','sampleCount','idCount', ...
        'mae','rmse','baselineMae','baselineRmse'}))
    fail('Evaluation strata are incomplete.');
end
if numel(evaluation.strata)~=3*numel(protocol.requiredStrata)
    fail('Evaluation contains missing or unexpected strata.');
end
thresholds=protocol.thresholds; recalculatedPassed=true;
splitIds={ids.training,ids.validation,ids.test}; splitNames={'train','validation','test'};
for k=1:numel(protocol.requiredStrata)
    requiredStratum=protocol.requiredStrata(k);
    for s=1:3
        at=find(strcmp({evaluation.strata.split},splitNames{s})& ...
            [evaluation.strata.numUE]==double(requiredStratum.numUE)& ...
            strcmp({evaluation.strata.trafficKind},textValue(requiredStratum.trafficKind,'traffic kind')));
        if numel(at)~=1, fail('Evaluation is missing a required %s stratum.',splitNames{s}); end
        row=evaluation.strata(at);
        if ~isPositiveInteger(row.sampleCount)||~isPositiveInteger(row.idCount)|| ...
                row.sampleCount<row.idCount||row.idCount>numel(splitIds{s})|| ...
                ~isFiniteNonnegative(row.mae)|| ...
                ~isFiniteNonnegative(row.rmse)||~isFiniteNonnegative(row.baselineMae)|| ...
                ~isFiniteNonnegative(row.baselineRmse)
            fail('Evaluation stratum metrics/counts are invalid.');
        end
        if row.rmse+1e-12*max(1,row.rmse)<row.mae|| ...
                row.baselineRmse+1e-12*max(1,row.baselineRmse)<row.baselineMae
            fail('Evaluation RMSE cannot be smaller than MAE beyond numerical tolerance.');
        end
        if s==3
            checks=[row.mae<=thresholds.maxMae,row.rmse<=thresholds.maxRmse, ...
                row.mae<=thresholds.maxMaeToBaselineRatio*row.baselineMae, ...
                row.rmse<=thresholds.maxRmseToBaselineRatio*row.baselineRmse];
            if ~all(checks), recalculatedPassed=false; end
        end
    end
end
if ~recalculatedPassed, fail('Evaluation does not meet the approved numerical thresholds.'); end
for s=1:3
    strataMask=strcmp({evaluation.strata.split},splitNames{s});
    sampleCounts=double([evaluation.strata(strataMask).sampleCount]);
    totalSamples=sum(sampleCounts);
    totalIds=sum(double([evaluation.strata(strataMask).idCount]));
    overallMae=sum(sampleCounts.*double([evaluation.strata(strataMask).mae]))/totalSamples;
    overallRmse=sqrt(sum(sampleCounts.*double([evaluation.strata(strataMask).rmse]).^2)/totalSamples);
    baselineMae=sum(sampleCounts.*double([evaluation.strata(strataMask).baselineMae]))/totalSamples;
    baselineRmse=sqrt(sum(sampleCounts.*double([evaluation.strata(strataMask).baselineRmse]).^2)/totalSamples);
    metricSplit=string(metrics.split)==string(splitNames{s});
    selected=metricSplit&string(metrics.model)==string(sidecar.modelName);
    baseline=metricSplit&string(metrics.model)=="trainMean";
    if any(metrics.sampleCount(metricSplit)~=totalSamples)|| ...
            any(metrics.idCount(metricSplit)~=totalIds)||nnz(selected)~=1||nnz(baseline)~=1|| ...
            ~closeEnough(metrics.mae(selected),overallMae)|| ...
            ~closeEnough(metrics.rmse(selected),overallRmse)|| ...
            ~closeEnough(metrics.mae(baseline),baselineMae)|| ...
            ~closeEnough(metrics.rmse(baseline),baselineRmse)
        fail('Evaluation %s metrics differ from aggregated metrics CSV values.',splitNames{s});
    end
end
end

function validateReview(review,status,digest,protocolSha,evaluationCompletedAt)
required={'decision','reviewer','reviewedAtUtc','evidenceDigest','protocolSha256','limitations'};
if ~isstruct(review)||~isscalar(review)||~all(isfield(review,required))
    fail('Acceptance review metadata is incomplete.');
end
decision=textValue(review.decision,'review decision');
if strcmp(status,'candidate')
    if ~ismember(decision,{'pending',''})
        fail('Candidate acceptance cannot carry a final review decision.');
    end
    return
end
if ~ismember(decision,{'accepted','rejected'})|| ...
        isempty(strtrim(textValue(review.reviewer,'reviewer')))|| ...
        isempty(strtrim(textValue(review.limitations,'review limitations')))|| ...
        ~strcmpi(textValue(review.evidenceDigest,'review evidence digest'),digest)|| ...
        ~strcmpi(textValue(review.protocolSha256,'review protocol hash'),protocolSha)
    fail('Review is missing or is bound to different evidence/protocol bytes.');
end
reviewedAt=parseUtc(review.reviewedAtUtc,'reviewedAtUtc');
if reviewedAt<parseUtc(evaluationCompletedAt,'evaluation completedAtUtc')
    fail('Scientific review must follow completed evaluation.');
end
if ~strcmp(status,decision), fail('Acceptance status and scientific review decision differ.'); end
end

function kind=inferEvidenceKind(dataset,training,sidecar,source)
isFixture=strcmp(textValue(dataset.kind,'dataset kind'),'development-fixture')|| ...
    strcmp(textValue(training.dataKind,'training data kind'),'development-fixture')|| ...
    strcmp(textValue(sidecar.dataKind,'model dataKind'),'development-fixture');
if isfield(dataset,'inputs')&&isstruct(dataset.inputs)&&isfield(dataset.inputs,'isFixture')
    isFixture=isFixture||any([dataset.inputs.isFixture]);
end
if isfield(source,'evidenceKind')&&ismember(textValue(source.evidenceKind,'source evidenceKind'), ...
        {'test-fixture','development-fixture'})
    isFixture=true;
end
if isFixture, kind='test-fixture'; else, kind='scientific-candidate'; end
end

function validateEvidenceKindLinks(kind,dataset,training,sidecar,freeze,evaluation)
if strcmp(kind,'test-fixture')
    expectedDataKind='development-fixture';
elseif strcmp(kind,'scientific-candidate')
    expectedDataKind='candidate-training';
else
    fail('Inferred evidence kind is unsupported.');
end
if ~strcmp(textValue(dataset.kind,'dataset kind'),expectedDataKind)|| ...
        ~strcmp(textValue(training.dataKind,'training data kind'),expectedDataKind)|| ...
        ~strcmp(textValue(sidecar.dataKind,'model dataKind'),expectedDataKind)|| ...
        ~strcmp(textValue(freeze.evidenceKind,'freeze evidenceKind'),kind)|| ...
        ~strcmp(textValue(evaluation.evidenceKind,'evaluation evidenceKind'),kind)
    fail('Dataset, training, model, freeze, and evaluation provenance labels do not agree.');
end
end

function digest=computeEvidenceDigest(acceptance)
names={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
    'trainingManifest','metrics','sourceManifest','calibration','registry','policy','protocol','evaluation'};
refs=struct();
for k=1:numel(names)
    item=acceptance.(names{k});
    refs.(names{k})=struct('file',strrep(textValue(item.file,[names{k} ' reference']), '\','/'), ...
        'sha256',lower(textValue(item.sha256,[names{k} ' hash'])));
end
canonical=struct('schemaVersion',textValue(acceptance.schemaVersion,'schemaVersion'), ...
    'featureSchemaVersion',textValue(acceptance.featureSchemaVersion,'feature schema'), ...
    'refs',refs,'trainingIds',normalizeIds(acceptance.trainingIds,'trainingIds',false), ...
    'validationIds',normalizeIds(acceptance.validationIds,'validationIds',false), ...
    'testIds',normalizeIds(acceptance.testIds,'testIds',false), ...
    'policyTuningIds',normalizeIds(acceptance.policyTuningIds,'policyTuningIds',true), ...
    'scope',canonicalScope(acceptance.scope),'protocolSha256',lower(acceptance.protocol.sha256), ...
    'policySha256',lower(textValue(acceptance.policySha256,'policy digest')));
bytes=unicode2native(jsonencode(canonical),'UTF-8');
md=java.security.MessageDigest.getInstance('SHA-256'); md.update(typecast(uint8(bytes),'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function checkManifestRef(root,base,relative,topRef,label)
path=resolvePackageRelative(root,base,textValue(relative,[label ' manifest ref']));
topPath=resolveAcceptanceRef(root,topRef,label);
if ~strcmpi(canonicalPath(path),canonicalPath(topPath))||~isfile(path)|| ...
        ~strcmpi(nbiot.ml.fileSha256(path),topRef.sha256)
    fail('Training manifest %s does not match acceptance references.',label);
end
end

function checkOptionalManifestDigest(manifest,fileField,digestField,root,base)
if isfield(manifest,fileField)||isfield(manifest,digestField)
    if ~all(isfield(manifest,{fileField,digestField}))||~isSha256(manifest.(digestField))
        fail('Training manifest test-consumption reference is incomplete.');
    end
    path=resolvePackageRelative(root,base,textValue(manifest.(fileField),fileField));
    if ~isfile(path)||~strcmpi(nbiot.ml.fileSha256(path),manifest.(digestField))
        fail('Test-consumption evidence is missing or changed.');
    end
end
end

function path=resolveAcceptanceRef(root,ref,label)
if ~isstruct(ref)||~isscalar(ref)||~all(isfield(ref,{'file','sha256'}))
    fail('Acceptance %s reference is malformed.',label);
end
relative=textValue(ref.file,[label ' file']);
if isempty(relative)||startsWith(relative,{'/','\'})||contains(relative,':')
    fail('Acceptance %s path must be package-relative.',label);
end
parts=split(string(strrep(relative,'\','/')),'/');
if any(parts=="..")||any(parts=="")
    fail('Acceptance %s path escapes or is malformed.',label);
end
path=resolvePackageRelative(root,root,relative);
end

function path=resolvePackageRelative(root,base,relative)
if isempty(relative)||startsWith(relative,{'/','\'})||contains(relative,':')
    fail('Evidence path must be relative to the package.');
end
path=canonicalPath(fullfile(base,strrep(relative,'/',filesep)));
prefix=[canonicalPath(root) filesep];
if ~startsWith(path,prefix,'IgnoreCase',true)
    fail('Evidence path escapes the package root.');
end
end

function path=canonicalPath(value)
try, path=char(java.io.File(char(value)).getCanonicalPath());
catch, path=char(value); end
end

function value=readJsonFile(path,label)
try, value=jsondecode(fileread(path));
catch exception, fail('Cannot read %s: %s.',label,exception.message); end
if ~isstruct(value)||~isscalar(value), fail('%s must contain one JSON object.',label); end
end

function ids=normalizeIds(value,label,allowEmpty)
if isempty(value)&&allowEmpty, ids=[]; return; end
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:))|value(:)<0|value(:)>3999|value(:)~=fix(value(:)))
    fail('%s must contain integer IDs in 0:3999.',label);
end
ids=sort(double(value(:).'));
if numel(unique(ids))~=numel(ids), fail('%s contains duplicate IDs.',label); end
end

function validateSameIds(value,expected,label)
actual=normalizeIds(value,label,~isempty(expected));
if ~isequal(actual,sort(double(expected(:).'))), fail('%s do not match the frozen split.',label); end
end

function value=scalarId(value,label)
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)|| ...
        value<0||value>3999||value~=fix(value)
    fail('%s must be one integer in 0:3999.',label);
end
value=double(value);
end

function values=normalizeTextList(value,label)
try, values=cellstr(string(value(:))).';
catch, fail('%s must be a list of text values.',label); end
if isempty(values)||any(cellfun(@isempty,values))||numel(unique(values))~=numel(values)
    fail('%s must contain unique non-empty text values.',label);
end
end

function text=requireText(value,expected,label)
text=textValue(value,label);
if ~strcmp(text,expected), fail('%s is unsupported.',label); end
end

function value=textValue(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1, fail('%s must be scalar text.',label); end
value=strtrim(value);
end

function requireFields(value,fields,message)
if ~isstruct(value)||~isscalar(value)||~all(isfield(value,fields)), fail('%s',message); end
end

function validateScope(scope)
required={'methods','numUE','trafficKinds','windowTicks'};
allowed=[required,{'burstDurationTicks','periodTicks','poissonRatePerSecond'}];
if ~isstruct(scope)||~isscalar(scope)||~all(isfield(scope,required))|| ...
        ~all(ismember(fieldnames(scope),allowed))
    fail('Scope must explicitly declare methods, loads, traffic kinds, and windowTicks.');
end
methods=normalizeTextList(scope.methods,'scope methods');
if any(~ismember(methods,{'Adaptive-P','Adaptive-RA/DT'}))
    fail('Scope contains an unsupported Adaptive method.');
end
loads=scope.numUE;
if ~isnumeric(loads)||~isreal(loads)||~isvector(loads)||isempty(loads)|| ...
        any(~isfinite(loads(:))|loads(:)<1|loads(:)>65535|loads(:)~=fix(loads(:)))|| ...
        numel(unique(double(loads(:))))~=numel(loads)||~isPositiveInteger(scope.windowTicks)
    fail('Scope loads and windowTicks must be positive integers.');
end
traffic=normalizeTextList(scope.trafficKinds,'scope trafficKinds');
if any(~ismember(traffic,{'burst','periodic','poisson'}))
    fail('Scope contains an unsupported traffic kind.');
end
scopeTrafficField(scope,traffic,'burst','burstDurationTicks','positive');
scopeTrafficField(scope,traffic,'periodic','periodTicks','positive');
scopeTrafficField(scope,traffic,'poisson','poissonRatePerSecond','nonnegative');
end

function scopeTrafficField(scope,traffic,kind,field,rule)
present=isfield(scope,field);
if present~=any(strcmp(traffic,kind))
    fail('Scope field %s must appear exactly for %s traffic.',field,kind);
end
if ~present, return; end
values=scope.(field);
if ~isnumeric(values)||~isreal(values)||~isvector(values)||isempty(values)|| ...
        any(~isfinite(values(:)))||numel(unique(double(values(:))))~=numel(values)
    fail('Scope field %s must contain unique finite values.',field);
end
if strcmp(rule,'positive')
    if any(values(:)<1|values(:)~=fix(values(:)))
        fail('Scope field %s must contain positive integers.',field);
    end
elseif any(values(:)<0)
    fail('Scope field %s cannot contain negative values.',field);
end
end

function result=canonicalScopeJson(scope)
result=jsonencode(canonicalScope(scope));
end

function value=canonicalScope(scope)
validateScope(scope);
value=struct('methods',{sort(normalizeTextList(scope.methods,'scope methods'))}, ...
    'numUE',sort(double(scope.numUE(:).')),'trafficKinds',{sort(normalizeTextList(scope.trafficKinds,'scope trafficKinds'))}, ...
    'windowTicks',double(scope.windowTicks));
for field={'burstDurationTicks','periodTicks','poissonRatePerSecond'}
    name=field{1};
    if isfield(scope,name)
        values=scope.(name); value.(name)=sort(double(values(:).'));
    end
end
end

function time=parseUtc(value,label)
value=textValue(value,label);
try
    time=datetime(value,'InputFormat',"yyyy-MM-dd'T'HH:mm:ss'Z'",'TimeZone','UTC');
catch exception
    fail('%s is not a UTC timestamp: %s.',label,exception.message);
end
if isnat(time), fail('%s is not a UTC timestamp.',label); end
end

function yes=isSha256(value)
yes=(ischar(value)||(isstring(value)&&isscalar(value)))&& ...
    numel(char(value))==64&&all(ismember(lower(char(value)),'0123456789abcdef'));
end

function yes=isPositiveInteger(value)
yes=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>=1&&value==fix(value);
end

function yes=isLogicalScalar(value)
yes=islogical(value)&&isscalar(value);
end

function yes=isFiniteNonnegative(value)
yes=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>=0;
end

function yes=isProbability(value)
yes=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>=0&&value<=1;
end

function yes=validIncreasing(values)
yes=isnumeric(values)&&isreal(values)&&isvector(values)&&~isempty(values)&& ...
    all(isfinite(values(:)))&&all(values(:)>=0)&&all(diff(values(:))>0);
end

function yes=validLevels(values,count,direction)
yes=isnumeric(values)&&isreal(values)&&isvector(values)&&numel(values)==count&& ...
    all(isfinite(values(:)))&&all(values(:)>=0)&&all(values(:)<=1);
if ~yes, return; end
delta=diff(values(:));
if strcmp(direction,'ascending'), yes=all(delta>=0); else, yes=all(delta<=0); end
end

function yes=isBasename(value)
[folder,name,extension]=fileparts(value);
yes=isempty(folder)&&~isempty(name)&&~isempty(extension)&& ...
    ~contains(value,'..')&&~contains(value,':');
end

function yes=closeEnough(left,right)
yes=isnumeric(left)&&isnumeric(right)&&isscalar(left)&&isscalar(right)&& ...
    abs(double(left)-double(right))<=1e-10*max(1,abs(double(right)));
end

function fail(message,varargin)
error('nbiot:ml:AcceptanceEvidence',message,varargin{:});
end
