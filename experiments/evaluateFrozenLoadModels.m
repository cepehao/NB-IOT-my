function report=evaluateFrozenLoadModels(options)
%EVALUATEFROZENLOADMODELS Evaluate frozen artifacts without fitting or reselection.
try
    report=runEvaluation(options);
catch exception
    if strcmp(exception.identifier,'nbiot:ml:FrozenEvaluation'), rethrow(exception); end
    wrapped=MException('nbiot:ml:FrozenEvaluation', ...
        'Frozen model evaluation failed: %s',exception.message);
    wrapped=addCause(wrapped,exception);
    throwAsCaller(wrapped);
end
end

function report=runEvaluation(options)
required={'freezeFile','datasetFile','modelFolder','protocolFile', ...
    'policyFile','registryFile','outputFolder'};
if ~isstruct(options)||~isscalar(options), fail('Options must be a scalar structure.'); end
unknown=setdiff(fieldnames(options),required); missing=setdiff(required,fieldnames(options));
if ~isempty(unknown), fail('Unknown option: %s.',unknown{1}); end
if ~isempty(missing), fail('Missing required option: %s.',missing{1}); end
ctx=preflight(options);
ctx.outputFolder=canonicalPath(options.outputFolder,'outputFolder',false);
if isWithin(ctx.outputFolder,ctx.modelFolder), fail('outputFolder must be outside selection.'); end
for k=1:numel(ctx.inputFiles)
    if samePath(ctx.outputFolder,ctx.inputFiles{k}), fail('outputFolder cannot replace an input.'); end
end
if isfolder(ctx.outputFolder)
    contents=dir(ctx.outputFolder); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents), report=readExistingEvaluation(ctx); return; end
else
    parent=fileparts(ctx.outputFolder); if isempty(parent), parent=pwd; end
    if ~isfolder(parent), fail('outputFolder parent must already exist.'); end
end
if isfile(ctx.testConsumptionFile)|| ...
        isfile(fullfile(ctx.datasetFolder,'test-consumption.json'))
    fail(['Model-test IDs were already consumed; only their verified completed ' ...
        'output may be reused.']);
end
if ~isfolder(ctx.outputFolder)
    [ok,message]=mkdir(ctx.outputFolder);
    if ~ok, fail('Cannot create outputFolder: %s',message); end
end

createTestConsumptionMarker(ctx);
testOpenedAtUtc=utcNow();
progress=struct('schemaVersion','frozen-model-evaluation-progress-v1', ...
    'status','incomplete','evidenceKind',ctx.freeze.evidenceKind, ...
    'freezeSha256',ctx.freezeSha256,'datasetSha256',ctx.freeze.datasetSha256, ...
    'protocolSha256',ctx.freeze.approvedProtocolSha256, ...
    'selectedModel',ctx.freeze.selectedModel,'testOpenedAtUtc',testOpenedAtUtc, ...
    'testConsumptionSha256',nbiot.ml.fileSha256(ctx.testConsumptionFile));
writeJsonAtomic(fullfile(ctx.outputFolder,'evaluation-progress.json'),progress);

% Loading the MAT file opens test labels; every frozen-source check is complete,
% and the durable test-open timestamp is already written.
loaded=load(ctx.datasetFile,'data');
data=validateDataset(loaded,ctx);
[metrics,evaluation]=scoreFrozenBundles(data,ctx,testOpenedAtUtc);
copyEvaluationInputs(ctx);
evaluation.testConsumptionFile='test-consumption.json';
evaluation.testConsumptionSha256=nbiot.ml.fileSha256( ...
    fullfile(ctx.outputFolder,'test-consumption.json'));
writeEvaluationMetrics(ctx.outputFolder,metrics);
evaluation.completedAtUtc=utcNow(); evaluation.status='complete';
writeJsonAtomic(fullfile(ctx.outputFolder,'evaluation.json'),evaluation);
manifest=makeEvaluatedManifest(ctx,metrics,evaluation);
writeJsonAtomic(fullfile(ctx.outputFolder,'training-manifest.json'),manifest);
if isfile(fullfile(ctx.outputFolder,'evaluation-progress.json'))
    try, delete(fullfile(ctx.outputFolder,'evaluation-progress.json')); catch, end
end
report=struct('status','complete','selectedModel',ctx.freeze.selectedModel, ...
    'testOpenedAtUtc',testOpenedAtUtc,'completedAtUtc',evaluation.completedAtUtc, ...
    'evaluation',evaluation,'metrics',metrics,'outputFolder',ctx.outputFolder);
end

function ctx=preflight(options)
ctx=struct();
ctx.freezeFile=canonicalPath(options.freezeFile,'freezeFile',true);
ctx.datasetFile=canonicalPath(options.datasetFile,'datasetFile',true);
ctx.modelFolder=canonicalPath(options.modelFolder,'modelFolder',true);
ctx.protocolFile=canonicalPath(options.protocolFile,'protocolFile',true);
ctx.policyFile=canonicalPath(options.policyFile,'policyFile',true);
ctx.registryFile=canonicalPath(options.registryFile,'registryFile',true);
ctx.inputFiles={ctx.freezeFile,ctx.datasetFile,ctx.protocolFile,ctx.policyFile,ctx.registryFile};
for k=1:numel(ctx.inputFiles)
    for j=k+1:numel(ctx.inputFiles)
        if samePath(ctx.inputFiles{k},ctx.inputFiles{j}), fail('Input files must be distinct.'); end
    end
end
freeze=readJson(ctx.freezeFile,'freeze JSON');
freezeFields={'schemaVersion','evidenceKind','createdAtUtc','approvedProtocolSha256', ...
    'modelSha256','modelSidecarSha256','policySha256','policyFileSha256', ...
    'datasetSha256','selectionManifestSha256','registrySha256','selectedModel', ...
    'selectionRule','trainingIds','validationIds','testIds','policyTuningIds','models'};
if ~isstruct(freeze)||~isscalar(freeze)||~all(isfield(freeze,freezeFields))|| ...
        ~strcmp(text(freeze.schemaVersion,'freeze schema'),'load-model-freeze-v1')
    fail('Freeze schema is incomplete or unsupported.');
end
if ~ismember(text(freeze.evidenceKind,'freeze evidenceKind'), ...
        {'test-fixture','scientific-candidate'})|| ...
        ~strcmp(text(freeze.selectionRule,'selection rule'), ...
        'lowest-validation-mae;tieOrder=linearRegression,decisionTree,randomForest,gradientBoosting')
    fail('Freeze evidenceKind or selection rule is unsupported.');
end
hashFields={'approvedProtocolSha256','modelSha256','modelSidecarSha256', ...
    'policySha256','policyFileSha256','datasetSha256','selectionManifestSha256','registrySha256'};
for k=1:numel(hashFields)
    if ~isSha256(freeze.(hashFields{k})), fail('Freeze has an invalid %s.',hashFields{k}); end
end
freeze.createdAtUtc=parseUtc(freeze.createdAtUtc,'freeze createdAtUtc');
ctx.freeze=freeze; ctx.freezeSha256=nbiot.ml.fileSha256(ctx.freezeFile);

protocol=readJson(ctx.protocolFile,'approved protocol');
validateProtocol(protocol,freeze.createdAtUtc);
if ~strcmpi(nbiot.ml.fileSha256(ctx.protocolFile),freeze.approvedProtocolSha256)
    fail('Approved protocol hash differs from the freeze.');
end
ctx.protocol=protocol;
policy=readJson(ctx.policyFile,'frozen policy'); validateFrozenPolicy(policy);
if ~strcmpi(nbiot.ml.fileSha256(ctx.policyFile),freeze.policyFileSha256)|| ...
        ~strcmpi(nbiot.controller.policySha256(policy),freeze.policySha256)
    fail('Policy hash differs from the freeze.');
end
ctx.policy=policy;
registry=readJson(ctx.registryFile,'allocation registry');
if ~strcmpi(nbiot.ml.fileSha256(ctx.registryFile),freeze.registrySha256)
    fail('Allocation registry hash differs from the freeze.');
end
validateRegistryIds(registry,freeze); ctx.registry=registry;
if ~strcmpi(nbiot.ml.fileSha256(ctx.datasetFile),freeze.datasetSha256)
    fail('Dataset hash differs from the freeze.');
end
[~,base,extension]=fileparts(ctx.datasetFile);
if ~strcmpi(extension,'.mat'), fail('datasetFile must be a MAT file.'); end
ctx.datasetName=[base extension];
ctx.datasetFolder=fileparts(ctx.datasetFile);
testIdKey=sha256Text(sprintf('%.0f,',double(freeze.testIds(:).')));
ctx.testConsumptionFile=fullfile(ctx.datasetFolder, ...
    ['model-test-consumption-' testIdKey(1:24) '.json']);

ctx.selectionManifestFile=fullfile(ctx.modelFolder,'training-manifest.json');
if ~isfile(ctx.selectionManifestFile)|| ...
        ~strcmpi(nbiot.ml.fileSha256(ctx.selectionManifestFile),freeze.selectionManifestSha256)
    fail('Selection training-manifest hash differs from the freeze.');
end
manifest=readJson(ctx.selectionManifestFile,'selection training manifest');
validateSelectionManifest(manifest,freeze,ctx.datasetName,ctx.datasetFile);
ctx.selectionManifest=manifest;
ctx.metricsFile=fullfile(ctx.modelFolder,'metrics.csv');
if ~isfile(ctx.metricsFile)||~strcmp(text(manifest.metricsFile,'metrics file'),'metrics.csv')|| ...
        ~strcmpi(nbiot.ml.fileSha256(ctx.metricsFile),manifest.metricsSha256)
    fail('Selection metrics hash differs from the manifest.');
end
metrics=readtable(ctx.metricsFile,'TextType','string');
validateSelectionMetrics(metrics,manifest); ctx.selectionMetrics=metrics;

ctx.sourceManifestFile=fullfile(fileparts(ctx.datasetFile),'manifest.json');
ctx.datasetManifestFile=fullfile(ctx.modelFolder,'dataset-manifest.json');
if ~isfile(ctx.sourceManifestFile)||~isfile(ctx.datasetManifestFile)|| ...
        ~strcmpi(nbiot.ml.fileSha256(ctx.sourceManifestFile),manifest.datasetManifestSha256)|| ...
        ~strcmpi(nbiot.ml.fileSha256(ctx.datasetManifestFile),manifest.datasetManifestSha256)
    fail('Original or copied dataset manifest hash is invalid.');
end
ctx.datasetManifest=readJson(ctx.sourceManifestFile,'original dataset manifest');
if ~isequaln(ctx.datasetManifest,readJson(ctx.datasetManifestFile,'copied dataset manifest'))
    fail('Original and copied dataset manifests differ.');
end
ctx.artifactsFile=fullfile(ctx.datasetFolder,'artifacts.json');
ctx.datasetArtifacts=validateArtifacts(ctx.artifactsFile,ctx.datasetFolder);
artifactNames=string({ctx.datasetArtifacts.files.name});
if ~any(artifactNames==string(ctx.datasetName))
    fail('Dataset artifact manifest does not bind the selected dataset file.');
end
ctx.preflightRows=validatePreTestScope(ctx.datasetManifest, ...
    ctx.selectionManifest.dataKind,freeze,protocol,policy,ctx.datasetFolder);

ctx.modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
if ~isstruct(freeze.models)||numel(freeze.models)~=4|| ...
        ~isequal(cellstr(string(manifest.modelNames(:))).',ctx.modelNames)
    fail('Freeze and selection must bind the four supported models.');
end
ctx.bundles=cell(1,4); ctx.modelFiles=cell(1,4); ctx.sidecarFiles=cell(1,4);
for k=1:4
    item=freeze.models(k); name=ctx.modelNames{k};
    modelFile=fullfile(ctx.modelFolder,[name '.mat']); sidecarFile=fullfile(ctx.modelFolder,[name '.json']);
    if ~all(isfield(item,{'modelName','file','sha256','sidecarFile','sidecarSha256'}))|| ...
            ~strcmp(text(item.modelName,'model name'),name)|| ...
            ~strcmp(text(item.file,'model file'),[name '.mat'])|| ...
            ~strcmp(text(item.sidecarFile,'sidecar file'),[name '.json'])|| ...
            ~isSha256(item.sha256)||~isSha256(item.sidecarSha256)|| ...
            ~isfile(modelFile)||~isfile(sidecarFile)|| ...
            ~strcmpi(nbiot.ml.fileSha256(modelFile),item.sha256)|| ...
            ~strcmpi(nbiot.ml.fileSha256(sidecarFile),item.sidecarSha256)
        fail('A model or sidecar differs from the freeze: %s.',name);
    end
    manifestAt=find(strcmp(cellstr(string(manifest.modelNames(:))),name),1);
    if isempty(manifestAt)||~strcmpi(manifest.artifactSha256{manifestAt},item.sha256)
        fail('Model hash differs from the selection manifest: %s.',name);
    end
    try, bundle=nbiot.ml.validateModelBundle(modelFile);
    catch exception, fail('Model package %s is invalid: %s.',name,exception.message); end
    if ~strcmp(bundle.modelName,name)||~strcmp(bundle.dataKind,manifest.dataKind)|| ...
            ~isequal(sort(double(bundle.trainingIds(:))),double(freeze.trainingIds(:)))|| ...
            ~isequal(sort(double(bundle.validationIds(:))),double(freeze.validationIds(:)))|| ...
            ~isequal(sort(double(bundle.testIds(:))),double(freeze.testIds(:)))
        fail('Model metadata differs from the frozen split: %s.',name);
    end
    ctx.bundles{k}=bundle; ctx.modelFiles{k}=modelFile; ctx.sidecarFiles{k}=sidecarFile;
end
chosen=find(strcmp(ctx.modelNames,text(freeze.selectedModel,'selected model')),1);
if isempty(chosen)||~strcmpi(freeze.models(chosen).sha256,freeze.modelSha256)|| ...
        ~strcmpi(freeze.models(chosen).sidecarSha256,freeze.modelSidecarSha256)|| ...
        ~strcmp(text(manifest.bestValidationModel,'validation winner'),ctx.modelNames{chosen})
    fail('Frozen winner does not match the validation manifest and artifact hashes.');
end
ctx.selectedIndex=chosen; ctx.selectedBundle=ctx.bundles{chosen};
end

function validateSelectionManifest(manifest,freeze,datasetName,datasetFile)
required={'formatVersion','phase','dataKind','allocationsVerified','status', ...
    'bestValidationModel','modelNames','artifactFiles','artifactSha256','trainingIds', ...
    'validationIds','testIds','metricsFile','metricsSha256','metricsRowCount', ...
    'datasetFile','datasetSha256','datasetManifestFile','datasetManifestSha256', ...
    'sourceSha256','calibrationSha256','splitEvidence'};
if ~isstruct(manifest)||~isscalar(manifest)||~all(isfield(manifest,required))|| ...
        ~strcmp(text(manifest.formatVersion,'training manifest format'),'load-training-report-v2')|| ...
        ~strcmp(text(manifest.phase,'training phase'),'selection')|| ...
        ~strcmp(text(manifest.status,'training status'),'development')|| ...
        ~ismember(text(manifest.dataKind,'data kind'),{'development-fixture','candidate-training'})|| ...
        ~strcmp(text(manifest.datasetFile,'dataset file'),datasetName)|| ...
        ~strcmpi(text(manifest.datasetSha256,'dataset hash'),nbiot.ml.fileSha256(datasetFile))|| ...
        ~strcmp(text(manifest.datasetManifestFile,'dataset manifest file'),'dataset-manifest.json')|| ...
        ~isSha256(manifest.datasetManifestSha256)||~isSha256(manifest.metricsSha256)|| ...
        ~strcmp(text(manifest.metricsFile,'metrics file'),'metrics.csv')|| ...
        ~strcmp(text(manifest.bestValidationModel,'validation winner'),text(freeze.selectedModel,'selected model'))|| ...
        ~strcmp(manifest.dataKind,kindForEvidence(freeze.evidenceKind))
    fail('Selection training manifest is incomplete or inconsistent with its freeze.');
end
idFields={'trainingIds','validationIds','testIds'};
for k=1:3
    if ~isequal(validIds(manifest.(idFields{k}),idFields{k}), ...
            validIds(freeze.(idFields{k}),idFields{k}))
        fail('Selection split IDs differ from the freeze.');
    end
end
if numel(manifest.splitEvidence)~=3||manifest.metricsRowCount~=10|| ...
        ~isequal(cellstr(string(manifest.modelNames(:))).', ...
        {'linearRegression','decisionTree','randomForest','gradientBoosting'})
    fail('Selection manifest must describe the complete ten-row selection phase.');
end
end

function validateSelectionMetrics(metrics,manifest)
required={'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
if ~istable(metrics)||height(metrics)~=10||~all(ismember(required,metrics.Properties.VariableNames))
    fail('Selection metrics must contain exactly ten complete rows.');
end
models=string(metrics.model); splits=string(metrics.split);
expected=["linearRegression";"decisionTree";"randomForest";"gradientBoosting";"trainMean"];
if any(splits=="test")||any(~ismember(models,expected))|| ...
        any(~ismember(splits,["train";"validation"]))||numel(unique(models+"/"+splits))~=10
    fail('Selection metrics must not contain test scores or duplicate rows.');
end
evidence=manifest.splitEvidence;
for k=1:3
    rows=splits==string(evidence(k).split);
    if any(metrics.sampleCount(rows)~=evidence(k).sampleCount)|| ...
            any(metrics.idCount(rows)~=evidence(k).idCount)
        fail('Selection score counts differ from splitEvidence.');
    end
end
order={'linearRegression','decisionTree','randomForest','gradientBoosting'}; values=zeros(1,4);
for k=1:4
    at=models==order{k}&splits=="validation";
    if nnz(at)~=1||~isfinite(metrics.mae(at)), fail('Validation score rows are incomplete.'); end
    values(k)=metrics.mae(at);
end
[~,best]=min(values);
if ~strcmp(order{best},char(string(manifest.bestValidationModel)))
    fail('Selection winner is not the validation-MAE minimum.');
end
end

function data=validateDataset(loaded,ctx)
if ~isstruct(loaded)||~isfield(loaded,'data'), fail('datasetFile must contain the data variable.'); end
data=loaded.data;
required={'observations','targets','features','rowInfo','schema','manifest'};
if ~isstruct(data)||~isscalar(data)||~all(isfield(data,required))|| ...
        ~istable(data.observations)||~istable(data.targets)||~istable(data.features)|| ...
        ~istable(data.rowInfo)||~isstruct(data.manifest)
    fail('The saved dataset structure is incomplete.');
end
bundle=ctx.selectedBundle; rows=height(data.rowInfo); keys=bundle.keyNames;
if rows<1||height(data.observations)~=rows||height(data.targets)~=rows||height(data.features)~=rows|| ...
        ~isequal(data.observations.Properties.VariableNames,[keys,bundle.featureNames])|| ...
        ~isfield(data.schema,'version')||~isfield(data.schema,'keyNames')|| ...
        ~isfield(data.schema,'inputNames')||~isfield(data.schema,'targetName')|| ...
        ~strcmp(char(string(data.schema.version)),bundle.schemaVersion)|| ...
        ~isequal(cellstr(string(data.schema.keyNames)),keys)|| ...
        ~isequal(cellstr(string(data.schema.inputNames)),bundle.featureNames)|| ...
        ~strcmp(char(string(data.schema.targetName)),bundle.targetName)|| ...
        ~isfield(data.schema,'targetNames')|| ...
        ~isequal(data.targets.Properties.VariableNames,cellstr(string(data.schema.targetNames)))|| ...
        ~isequal(data.features.Properties.VariableNames,bundle.featureNames)|| ...
        ~all(ismember([keys,{'split','realizationId','caseKey'}],data.rowInfo.Properties.VariableNames))
    fail('Dataset rows, keys, features, or targets do not match the frozen model schema.');
end
preflightRowNames=ctx.preflightRows.Properties.VariableNames;
if ~all(ismember(preflightRowNames,data.rowInfo.Properties.VariableNames))|| ...
        ~isequaln(data.rowInfo(:,preflightRowNames),ctx.preflightRows)
    fail('Loaded dataset row metadata differs from the pre-test row-key artifact.');
end
rowKeys=data.rowInfo(:,keys);
if ~isequal(data.observations(:,keys),data.targets(:,keys))|| ...
        ~isequaln(data.observations(:,keys),rowKeys)|| ...
        ~isequaln(data.features,data.observations(:,bundle.featureNames))
    fail('Dataset observations, targets, features and rowInfo are not aligned.');
end
groups=string(data.rowInfo.split); ids=double(data.rowInfo.realizationId);
rowIds=double(data.rowInfo.(keys{1}));
if any(~ismember(groups,["train";"validation";"test"]))|| ...
        ~isequal(rowIds(:),ids(:))
    fail('Dataset split or realization keys are invalid.');
end
splitNames={'train','validation','test'}; idFields={'trainingIds','validationIds','testIds'};
for k=1:3
    groupIds=sort(unique(ids(groups==splitNames{k}))).';
    if ~isequal(groupIds,double(ctx.freeze.(idFields{k})(:).'))
        fail('Dataset %s rows do not match the frozen split IDs.',splitNames{k});
    end
end
if ~isfield(data.manifest,'kind')|| ...
        ~strcmp(text(data.manifest.kind,'dataset kind'),ctx.selectionManifest.dataKind)
    fail('Dataset kind differs from the selection manifest.');
end
validateLoadedManifest(data.manifest,ctx.datasetManifest,ctx.selectionManifest.dataKind);
validateDatasetAssignments(data.manifest,ctx.freeze);
if strcmp(ctx.freeze.evidenceKind,'scientific-candidate')
    [data.numUE,data.trafficKind]=candidateStrata(data);
elseif strcmp(ctx.selectionManifest.dataKind,'development-fixture')
    data.numUE=ones(rows,1); data.trafficKind=repmat("test-fixture",rows,1);
else
    fail('Fixture strata cannot be inferred for a scientific candidate.');
end
end

function validateLoadedManifest(actual,source,kind)
required={'kind','assignments','inputs','allocationsVerified','experimentRolesExplicit'};
if ~isstruct(source)||~isscalar(source)||~all(isfield(actual,required))|| ...
        ~all(isfield(source,required))||~strcmp(text(actual.kind,'loaded manifest kind'), ...
        text(source.kind,'source manifest kind'))|| ...
        ~isequal(actual.allocationsVerified,source.allocationsVerified)|| ...
        ~isequal(actual.experimentRolesExplicit,source.experimentRolesExplicit)
    fail('Loaded dataset metadata differs from its source manifest.');
end
actualAssignments=normalizeAssignments(actual.assignments,kind);
sourceAssignments=normalizeAssignments(source.assignments,kind);
if ~isequal(actualAssignments,sourceAssignments)|| ...
        ~isequaln(jsondecode(jsonencode(actual.inputs)),jsondecode(jsonencode(source.inputs)))
    fail('Loaded dataset assignments or inputs differ from the source manifest.');
end
end

function value=normalizeAssignments(input,kind)
if istable(input), tableValue=input;
elseif isstruct(input)
    try, tableValue=struct2table(input);
    catch, fail('Dataset assignments cannot be normalized.'); end
else
    fail('Dataset assignments cannot be normalized.');
end
required={'externalRealizationId','split'};
if strcmp(kind,'candidate-training'), required{end+1}='experimentRole'; end
if ~all(ismember(required,tableValue.Properties.VariableNames))
    fail('Dataset assignments omit required fields.');
end
if ismember('experimentRole',tableValue.Properties.VariableNames)
    roles=string(tableValue.experimentRole(:));
else
    roles=repmat("",height(tableValue),1);
end
value=table(double(tableValue.externalRealizationId(:)), ...
    string(tableValue.split(:)),roles,'VariableNames',{'id','split','role'});
value=sortrows(value,{'id','split','role'});
end

function [metrics,evaluation]=scoreFrozenBundles(data,ctx,testOpenedAtUtc)
y=double(data.targets.(ctx.selectedBundle.targetName));
groups=string(data.rowInfo.split); ids=double(data.rowInfo.realizationId);
baseline=mean(y(groups=="train")); splitNames=["train","validation","test"];
predictions=cell(1,4); predictionSeconds=zeros(4,3); modelRows=cell(1,4);
for modelIndex=1:4
    bundle=ctx.bundles{modelIndex}; predictions{modelIndex}=nan(numel(y),1);
    for splitIndex=1:3
        mask=groups==splitNames(splitIndex);
        x=double(data.observations{mask,bundle.featureNames});
        x=imputeAndNormalize(x,bundle.transform); started=tic;
        values=double(predict(bundle.model,x)); predictionSeconds(modelIndex,splitIndex)=toc(started);
        values=values(:);
        if numel(values)~=nnz(mask)||~isreal(values)||any(~isfinite(values))
            fail('Frozen model prediction is invalid: %s.',bundle.modelName);
        end
        predictions{modelIndex}(mask)=values;
    end
    modelRows{modelIndex}=cell(3,9);
    for splitIndex=1:3
        mask=groups==splitNames(splitIndex);
        modelRows{modelIndex}(splitIndex,:)=scoreRow(ctx.modelNames{modelIndex}, ...
            splitNames(splitIndex),predictions{modelIndex}(mask),y(mask),ids(mask), ...
            predictionSeconds(modelIndex,splitIndex),0);
    end
end
baselineRows=cell(3,1);
for splitIndex=1:3
    mask=groups==splitNames(splitIndex);
    baselineRows{splitIndex}=scoreRow('trainMean',splitNames(splitIndex), ...
        repmat(baseline,nnz(mask),1),y(mask),ids(mask),0,0);
end

% Preserve train/validation selection scores exactly. Recomputed validation is
% only a consistency check and cannot replace the previously frozen winner.
selectedMetrics=ctx.selectionMetrics;
for k=1:4
    for splitIndex=1:2
        mask=string(selectedMetrics.model)==ctx.modelNames{k}& ...
            string(selectedMetrics.split)==splitNames(splitIndex);
        value=modelRows{k}{splitIndex,5};
        if nnz(mask)~=1||abs(selectedMetrics.mae(mask)-value)>1e-10*max(1,value)
            fail('Frozen %s score changed for %s after selection.',ctx.modelNames{k},splitNames(splitIndex));
        end
    end
end
for splitIndex=1:2
    mask=string(selectedMetrics.model)=="trainMean"& ...
        string(selectedMetrics.split)==splitNames(splitIndex);
    value=baselineRows{splitIndex}{5};
    if nnz(mask)~=1||abs(selectedMetrics.mae(mask)-value)>1e-10*max(1,value)
        fail('Frozen trainMean score changed for %s after selection.',splitNames(splitIndex));
    end
end
testRows=cell(5,1);
for k=1:4, testRows{k}=modelRows{k}(3,:); end
testRows{5}=baselineRows{3};
testMetrics=cell2table(vertcat(testRows{:}),'VariableNames', ...
    {'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'});
metrics=[selectedMetrics;testMetrics];
[strata,passed,unmet]=makeStrata(data,ctx,predictions,baseline,y,ids,groups);
evaluation=struct('schemaVersion','load-model-evaluation-v1','status','incomplete', ...
    'evidenceKind',ctx.freeze.evidenceKind,'datasetSha256',ctx.freeze.datasetSha256, ...
    'modelSha256',ctx.freeze.modelSha256,'protocolSha256',ctx.freeze.approvedProtocolSha256, ...
    'frozenModelSha256',ctx.freeze.modelSha256,'selectedModel',ctx.freeze.selectedModel, ...
    'evaluatedAtUtc',utcNow(),'selectionSplit','validation', ...
    'testOpenedAtUtc',testOpenedAtUtc,'completedAtUtc','', ...
    'strata',strata,'passed',passed,'unmetRequirements',{unmet}, ...
    'freezeSha256',ctx.freezeSha256, ...
    'selectionManifestSha256',ctx.freeze.selectionManifestSha256);
end

function [rows,passed,unmet]=makeStrata(data,ctx,predictions,baseline,y,ids,groups)
template=struct('split','','numUE',0,'trafficKind','','sampleCount',0, ...
    'idCount',0,'mae',[],'rmse',[],'baselineMae',[],'baselineRmse',[]);
rows=repmat(template,0,1); unmet={}; passed=true;
required=ctx.protocol.requiredStrata;
for k=1:numel(required)
    numUE=double(required(k).numUE); traffic=text(required(k).trafficKind,'required trafficKind');
    for split=["train";"validation";"test"].'
        mask=groups==split&data.numUE==numUE&data.trafficKind==traffic;
        row=template; row.split=char(split); row.numUE=numUE; row.trafficKind=traffic;
        row.sampleCount=nnz(mask); row.idCount=numel(unique(ids(mask)));
        if any(mask)
            actual=y(mask); predicted=predictions{ctx.selectedIndex}(mask);
            baselineValues=repmat(baseline,numel(actual),1);
            row.mae=mean(abs(predicted-actual)); row.rmse=sqrt(mean((predicted-actual).^2));
            row.baselineMae=mean(abs(baselineValues-actual));
            row.baselineRmse=sqrt(mean((baselineValues-actual).^2));
        else
            passed=false;
            unmet{end+1}=sprintf('missing-required-stratum:%s:%g:%s',split,numUE,traffic); %#ok<AGROW>
        end
        rows(end+1,1)=row; %#ok<AGROW>
        if split=="test"&&any(mask)
            limits=ctx.protocol.thresholds;
            checks=[row.mae<=limits.maxMae,row.rmse<=limits.maxRmse, ...
                row.mae<=limits.maxMaeToBaselineRatio*row.baselineMae, ...
                row.rmse<=limits.maxRmseToBaselineRatio*row.baselineRmse];
            if ~all(checks)
                passed=false;
                unmet{end+1}=sprintf('test-threshold-failed:%g:%s',numUE,traffic); %#ok<AGROW>
            end
        end
    end
end
end

function manifest=makeEvaluatedManifest(ctx,metrics,evaluation)
names=ctx.modelNames; files=cellfun(@(name)[name '.mat'],names,'UniformOutput',false);
hashes=cellfun(@(file)nbiot.ml.fileSha256(fullfile(ctx.outputFolder,file)), ...
    files,'UniformOutput',false);
manifest=struct('formatVersion','load-training-report-v2','phase','evaluated', ...
    'dataKind',ctx.selectionManifest.dataKind, ...
    'allocationsVerified',ctx.selectionManifest.allocationsVerified, ...
    'status','development','targetName',ctx.selectedBundle.targetName, ...
    'schemaVersion',ctx.selectedBundle.schemaVersion,'seed',ctx.selectedBundle.seed, ...
    'bestValidationModel',ctx.freeze.selectedModel, ...
    'selectionRule',ctx.selectionManifest.selectionRule,'modelNames',{names}, ...
    'artifactFiles',{files},'artifactSha256',{hashes}, ...
    'trainingIds',ctx.freeze.trainingIds,'validationIds',ctx.freeze.validationIds, ...
    'testIds',ctx.freeze.testIds,'metricsFile','metrics.csv', ...
    'metricsSha256',nbiot.ml.fileSha256(fullfile(ctx.outputFolder,'metrics.csv')), ...
    'metricsRowCount',height(metrics),'splitEvidence',ctx.selectionManifest.splitEvidence, ...
    'datasetFile',ctx.datasetName,'datasetSha256',ctx.freeze.datasetSha256, ...
    'datasetManifestFile','dataset-manifest.json', ...
    'datasetManifestSha256',ctx.selectionManifest.datasetManifestSha256, ...
    'sourceSha256',ctx.selectionManifest.sourceSha256, ...
    'calibrationSha256',ctx.selectionManifest.calibrationSha256, ...
    'freezeFile','freeze.json','freezeSha256',ctx.freezeSha256, ...
    'selectionManifestSha256',ctx.freeze.selectionManifestSha256, ...
    'datasetArtifactsFile','artifacts.json', ...
    'datasetArtifactsSha256',nbiot.ml.fileSha256(fullfile(ctx.outputFolder,'artifacts.json')), ...
    'evaluationFile','evaluation.json', ...
    'evaluationSha256',nbiot.ml.fileSha256(fullfile(ctx.outputFolder,'evaluation.json')), ...
    'testConsumptionFile','test-consumption.json', ...
    'testConsumptionSha256',nbiot.ml.fileSha256( ...
        fullfile(ctx.outputFolder,'test-consumption.json')), ...
    'protocolFile','protocol.json','protocolSha256',ctx.freeze.approvedProtocolSha256, ...
    'policyFile','policy.json','policySha256',ctx.freeze.policySha256, ...
    'policyFileSha256',ctx.freeze.policyFileSha256, ...
    'registryFile','registry.json','registrySha256',ctx.freeze.registrySha256, ...
    'evaluationPassed',logical(evaluation.passed));
end

function report=readExistingEvaluation(ctx)
folder=ctx.outputFolder;
manifestFile=fullfile(folder,'training-manifest.json');
evaluationFile=fullfile(folder,'evaluation.json'); metricsFile=fullfile(folder,'metrics.csv');
freezeCopy=fullfile(folder,'freeze.json');
if ~all(cellfun(@isfile,{manifestFile,evaluationFile,metricsFile,freezeCopy}))
    fail('outputFolder contains an incomplete prior evaluation; it cannot be resumed.');
end
manifest=readJson(manifestFile,'existing evaluation manifest');
evaluation=readJson(evaluationFile,'existing evaluation');
required={'phase','freezeFile','freezeSha256','selectionManifestSha256', ...
    'evaluationSha256','metricsSha256','artifactFiles','artifactSha256', ...
    'datasetArtifactsFile','datasetArtifactsSha256', ...
    'testConsumptionFile','testConsumptionSha256'};
if ~isstruct(manifest)||~all(isfield(manifest,required))|| ...
        ~strcmp(text(manifest.phase,'existing phase'),'evaluated')|| ...
        ~strcmpi(manifest.freezeSha256,ctx.freezeSha256)|| ...
        ~strcmpi(manifest.selectionManifestSha256,ctx.freeze.selectionManifestSha256)|| ...
        ~strcmpi(manifest.evaluationSha256,nbiot.ml.fileSha256(evaluationFile))|| ...
        ~strcmpi(manifest.metricsSha256,nbiot.ml.fileSha256(metricsFile))|| ...
        ~strcmp(text(manifest.datasetArtifactsFile,'dataset artifacts file'),'artifacts.json')|| ...
        ~strcmpi(manifest.datasetArtifactsSha256,nbiot.ml.fileSha256( ...
            fullfile(folder,'artifacts.json')))|| ...
        ~strcmp(text(manifest.testConsumptionFile,'test consumption file'),'test-consumption.json')|| ...
        ~strcmpi(manifest.testConsumptionSha256,nbiot.ml.fileSha256( ...
            fullfile(folder,'test-consumption.json')))|| ...
        ~strcmpi(evaluation.testConsumptionSha256,manifest.testConsumptionSha256)|| ...
        ~strcmp(text(evaluation.status,'evaluation status'),'complete')|| ...
        ~strcmpi(evaluation.freezeSha256,ctx.freezeSha256)|| ...
        ~strcmp(text(evaluation.selectedModel,'existing selected model'),ctx.freeze.selectedModel)|| ...
        ~strcmp(text(manifest.freezeFile,'freeze file'),'freeze.json')|| ...
        ~strcmpi(nbiot.ml.fileSha256(freezeCopy),ctx.freezeSha256)
    fail('Existing evaluated output does not match the frozen inputs.');
end
for k=1:numel(manifest.artifactFiles)
    name=char(string(manifest.artifactFiles{k})); path=fullfile(folder,name);
    if ~isfile(path)||~strcmpi(nbiot.ml.fileSha256(path),manifest.artifactSha256{k})
        fail('Existing evaluated model artifact is altered or missing.');
    end
end
for k=1:4
    for extension={'.mat','.json'}
        name=[ctx.modelNames{k} extension{1}];
        if ~isfile(fullfile(folder,name))|| ...
                ~strcmpi(nbiot.ml.fileSha256(fullfile(folder,name)), ...
                nbiot.ml.fileSha256(fullfile(ctx.modelFolder,name)))
            fail('Existing model copy differs from the frozen source.');
        end
    end
end
validateTestConsumptionMarker(ctx.testConsumptionFile,ctx);
validateTestConsumptionMarker(fullfile(folder,'test-consumption.json'),ctx);
copyNames={'dataset-manifest.json','protocol.json','policy.json','registry.json', ...
    'freeze.json','test-consumption.json','artifacts.json'};
for k=1:numel(copyNames)
    name=copyNames{k}; source=copySource(ctx,name); target=fullfile(folder,name);
    if isempty(source)||~isfile(source)||~isfile(target)|| ...
            ~strcmpi(nbiot.ml.fileSha256(source),nbiot.ml.fileSha256(target))
        fail('Existing evidence copy differs from source: %s.',name);
    end
end
validateCopiedDatasetArtifacts(ctx,folder);
metrics=readtable(metricsFile,'TextType','string');
validateEvaluatedMetrics(metrics,ctx.selectionManifest.splitEvidence);
report=struct('status','already-evaluated','selectedModel',ctx.freeze.selectedModel, ...
    'testOpenedAtUtc',text(evaluation.testOpenedAtUtc,'testOpenedAtUtc'), ...
    'completedAtUtc',text(evaluation.completedAtUtc,'completedAtUtc'), ...
    'evaluation',evaluation,'metrics',metrics,'outputFolder',folder);
end

function validateEvaluatedMetrics(metrics,evidence)
required={'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
expected=["linearRegression";"decisionTree";"randomForest";"gradientBoosting";"trainMean"];
if ~istable(metrics)||height(metrics)~=15||~all(ismember(required,metrics.Properties.VariableNames))|| ...
        any(~ismember(string(metrics.model),expected))|| ...
        any(~ismember(string(metrics.split),["train";"validation";"test"]))|| ...
        numel(unique(string(metrics.model)+"/"+string(metrics.split)))~=15
    fail('Evaluated metrics must contain exactly fifteen distinct model/split rows.');
end
for k=1:3
    rows=string(metrics.split)==string(evidence(k).split);
    if sum(rows)~=5||any(metrics.sampleCount(rows)~=evidence(k).sampleCount)|| ...
            any(metrics.idCount(rows)~=evidence(k).idCount)
        fail('Evaluated metric counts differ from splitEvidence.');
    end
end
numeric={'sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
for k=1:numel(numeric)
    values=metrics.(numeric{k});
    if ~isnumeric(values)||any(~isfinite(values)), fail('Metric column %s is not finite.',numeric{k}); end
end
end

function source=copySource(ctx,name)
switch name
    case 'dataset-manifest.json', source=ctx.datasetManifestFile;
    case 'artifacts.json', source=ctx.artifactsFile;
    case 'protocol.json', source=ctx.protocolFile;
    case 'policy.json', source=ctx.policyFile;
    case 'registry.json', source=ctx.registryFile;
    case 'freeze.json', source=ctx.freezeFile;
    case 'test-consumption.json', source=ctx.testConsumptionFile;
    otherwise, source='';
end
end

function copyEvaluationInputs(ctx)
for k=1:4
    copyExact(ctx.modelFiles{k},fullfile(ctx.outputFolder,[ctx.modelNames{k} '.mat']));
    copyExact(ctx.sidecarFiles{k},fullfile(ctx.outputFolder,[ctx.modelNames{k} '.json']));
end
for k=1:numel(ctx.datasetArtifacts.files)
    name=text(ctx.datasetArtifacts.files(k).name,'dataset artifact name');
    copyExact(fullfile(ctx.datasetFolder,name),fullfile(ctx.outputFolder,name));
end
names={'dataset-manifest.json','artifacts.json','protocol.json','policy.json', ...
    'registry.json','freeze.json','test-consumption.json'};
for k=1:numel(names)
    source=copySource(ctx,names{k});
    if isempty(source), fail('Evaluation evidence source is missing: %s.',names{k}); end
    copyExact(source,fullfile(ctx.outputFolder,names{k}));
end
end

function copyExact(source,target)
[ok,message]=copyfile(source,target);
if ~ok, fail('Cannot copy evaluation evidence: %s',message); end
if ~strcmpi(nbiot.ml.fileSha256(source),nbiot.ml.fileSha256(target))
    fail('Copied evaluation evidence bytes differ from source.');
end
end

function createTestConsumptionMarker(ctx)
reservation=java.io.File(ctx.testConsumptionFile);
if ~reservation.createNewFile()
    fail('Model-test IDs were already consumed or claimed by another evaluation.');
end
marker=struct('schemaVersion','load-model-test-consumption-v1', ...
    'status','claimed-before-open','testIds',double(ctx.freeze.testIds(:).'), ...
    'freezeSha256',ctx.freezeSha256,'datasetSha256',ctx.freeze.datasetSha256, ...
    'protocolSha256',ctx.freeze.approvedProtocolSha256, ...
    'registrySha256',ctx.freeze.registrySha256,'claimedAtUtc',utcNow());
fid=fopen(ctx.testConsumptionFile,'w','n','UTF-8');
if fid<0, fail('Cannot write the durable model-test consumption marker.'); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(marker,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    fail('Cannot write the complete model-test consumption marker.');
end
clear cleanup
validateTestConsumptionMarker(ctx.testConsumptionFile,ctx);
end

function validateTestConsumptionMarker(path,ctx)
if ~isfile(path), fail('The durable model-test consumption marker is missing.'); end
marker=readJson(path,'model-test consumption marker');
required={'schemaVersion','status','testIds','freezeSha256','datasetSha256', ...
    'protocolSha256','registrySha256','claimedAtUtc'};
if ~isstruct(marker)||~isscalar(marker)||~all(isfield(marker,required))|| ...
        ~strcmp(text(marker.schemaVersion,'test consumption schema'), ...
            'load-model-test-consumption-v1')|| ...
        ~strcmp(text(marker.status,'test consumption status'),'claimed-before-open')|| ...
        ~isequal(double(marker.testIds(:).'),double(ctx.freeze.testIds(:).'))|| ...
        ~strcmpi(text(marker.freezeSha256,'consumed freeze hash'),ctx.freezeSha256)|| ...
        ~strcmpi(text(marker.datasetSha256,'consumed dataset hash'),ctx.freeze.datasetSha256)|| ...
        ~strcmpi(text(marker.protocolSha256,'consumed protocol hash'), ...
            ctx.freeze.approvedProtocolSha256)|| ...
        ~strcmpi(text(marker.registrySha256,'consumed registry hash'),ctx.freeze.registrySha256)
    fail('The durable test-consumption marker does not match the frozen test IDs and inputs.');
end
parseUtc(marker.claimedAtUtc,'test consumption claimedAtUtc');
end

function writeEvaluationMetrics(folder,metrics)
file=fullfile(folder,'metrics.csv'); writetable(metrics,file);
if ~isfile(file), fail('Evaluation metrics were not saved.'); end
end

function row=scoreRow(model,split,prediction,target,ids,predictionSeconds,trainingSeconds)
prediction=double(prediction(:)); target=double(target(:));
if numel(prediction)~=numel(target)||isempty(target)|| ...
        any(~isfinite(prediction))||any(~isfinite(target))
    fail('A score row contains missing or non-finite values.');
end
errors=prediction-target;
row={string(model),string(split),double(numel(target)),double(numel(unique(ids))), ...
    mean(abs(errors)),sqrt(mean(errors.^2)),mean(errors),predictionSeconds,trainingSeconds};
end

function x=imputeAndNormalize(x,transform)
for column=1:size(x,2)
    missing=isnan(x(:,column)); x(missing,column)=transform.median(column);
end
x=(x-transform.mean)./transform.scale;
end

function [numUE,traffic]=candidateStrata(data)
inputs=data.manifest.inputs; required={'caseKey','realizationId','numUE','trafficKind'};
if ~isstruct(inputs)||isempty(inputs)||~all(isfield(inputs,required))
    fail('Candidate inputs must preserve caseKey, realizationId and traffic stratum.');
end
caseKeys=string({inputs.caseKey}); inputIds=double([inputs.realizationId]);
inputUE=double([inputs.numUE]); inputTraffic=string({inputs.trafficKind});
if any(ismissing(caseKeys)|caseKeys=="")||numel(unique(caseKeys))~=numel(caseKeys)|| ...
        numel(unique(inputIds))~=numel(inputIds)|| ...
        any(~isfinite(inputUE)|inputUE<1|inputUE~=fix(inputUE))|| ...
        any(~ismember(inputTraffic,["burst";"periodic";"poisson"]))
    fail('Candidate input stratum metadata is invalid.');
end
rowCases=string(data.rowInfo.caseKey); rowIds=double(data.rowInfo.realizationId);
numUE=zeros(numel(rowCases),1); traffic=strings(numel(rowCases),1);
for k=1:numel(rowCases)
    at=find(caseKeys==rowCases(k));
    if numel(at)~=1||inputIds(at)~=rowIds(k)
        fail('Candidate rowInfo does not match its input stratum metadata.');
    end
    numUE(k)=inputUE(at); traffic(k)=inputTraffic(at);
end
end

function validateDatasetAssignments(manifest,freeze)
if ~isfield(manifest,'assignments'), fail('Dataset split assignments are required.'); end
value=manifest.assignments;
if istable(value), actual=value;
elseif isstruct(value), actual=struct2table(value);
else, fail('Dataset assignments are malformed.'); end
required={'externalRealizationId','split'};
if ~all(ismember(required,actual.Properties.VariableNames)), fail('Dataset assignments are incomplete.'); end
actual=table(double(actual.externalRealizationId(:)),string(actual.split(:)), ...
    'VariableNames',{'id','split'});
expectedIds=[double(freeze.trainingIds(:));double(freeze.validationIds(:));double(freeze.testIds(:))];
expectedSplits=[repmat("train",numel(freeze.trainingIds),1); ...
    repmat("validation",numel(freeze.validationIds),1);repmat("test",numel(freeze.testIds),1)];
expected=table(expectedIds,expectedSplits,'VariableNames',{'id','split'});
if ~isequal(sortrows(actual,{'id','split'}),sortrows(expected,{'id','split'}))
    fail('Dataset assignment IDs differ from the frozen split.');
end
if ismember('experimentRole',actual.Properties.VariableNames)
    actualRoles=table(double(actual.externalRealizationId(:)),string(actual.experimentRole(:)), ...
        'VariableNames',{'id','role'});
    expectedRoles=expectedSplits; expectedRoles(expectedRoles=="train")="training";
    expectedRoles(expectedRoles=="test")="model-test";
    expectedRoleTable=table(expectedIds,expectedRoles,'VariableNames',{'id','role'});
    if ~isequal(sortrows(actualRoles,{'id','role'}),sortrows(expectedRoleTable,{'id','role'}))
        fail('Dataset assignment roles differ from frozen split roles.');
    end
end
end

function validateRegistryIds(registry,freeze)
if ~isstruct(registry)||~isscalar(registry)|| ...
        ~all(isfield(registry,{'schemaVersion','assignments','reservations'}))|| ...
        registry.schemaVersion~=1||~isstruct(registry.assignments)
    fail('Allocation registry is malformed.');
end
groups={freeze.trainingIds,freeze.validationIds,freeze.testIds};
roles={'training','validation','model-test'};
for groupIndex=1:3
    for id=double(groups{groupIndex}(:).')
        [role,status,count]=registryForId(registry,id);
        if count~=1||~strcmp(role,roles{groupIndex})||~strcmp(status,'completed')||isReserved(registry,id)
            fail('Frozen %s ID %d lacks one completed non-reserved allocation.',roles{groupIndex},id);
        end
    end
end
if isempty(freeze.policyTuningIds), policyIds=[];
else, policyIds=validIds(freeze.policyTuningIds,'policyTuningIds'); end
for id=policyIds
    [role,status,count]=registryForId(registry,id);
    if count~=1||~ismember(role,{'development','validation'})|| ...
            ~strcmp(status,'completed')||isReserved(registry,id)
        fail('Policy tuning IDs must be completed development or validation allocations.');
    end
end
end

function [role,status,count]=registryForId(registry,id)
role=''; status=''; count=0;
for k=1:numel(registry.assignments)
    item=registry.assignments(k);
    if isfield(item,'ids')&&any(double(item.ids(:))==id)
        count=count+1; role=text(item.role,'allocation role'); status=text(item.status,'allocation status');
    end
end
end

function yes=isReserved(registry,id)
yes=false;
for k=1:numel(registry.reservations)
    item=registry.reservations(k);
    if isfield(item,'ids')&&any(double(item.ids(:))==id), yes=true; return; end
    if isfield(item,'range')&&numel(item.range)==2&& ...
            id>=min(double(item.range))&&id<=max(double(item.range)), yes=true; return; end
end
end

function artifacts=validateArtifacts(path,folder)
if ~isfile(path), fail('Dataset artifacts manifest is missing.'); end
artifacts=readJson(path,'dataset artifacts');
if ~isstruct(artifacts)||~isscalar(artifacts)||~isfield(artifacts,'files')|| ...
        ~isstruct(artifacts.files)||isempty(artifacts.files)
    fail('Dataset artifacts manifest is malformed.');
end
names=strings(1,numel(artifacts.files));
reserved=["artifacts.json";"dataset-manifest.json";"protocol.json";"policy.json"; ...
    "registry.json";"freeze.json";"test-consumption.json";"metrics.csv"; ...
    "evaluation.json";"evaluation-progress.json";"training-manifest.json"; ...
    "linearRegression.mat";"linearRegression.json";"decisionTree.mat"; ...
    "decisionTree.json";"randomForest.mat";"randomForest.json"; ...
    "gradientBoosting.mat";"gradientBoosting.json"];
for k=1:numel(artifacts.files)
    item=artifacts.files(k);
    if ~all(isfield(item,{'name','sha256','bytes'})), fail('Dataset artifact entry is incomplete.'); end
    name=text(item.name,'dataset artifact name'); artifactPath=fullfile(folder,name);
    if ~isBasename(name)||ismember(string(name),reserved)|| ...
            ~isSha256(item.sha256)||~isPositiveInteger(item.bytes)|| ...
            ~isfile(artifactPath)||~strcmpi(nbiot.ml.fileSha256(artifactPath),item.sha256)|| ...
            fileBytes(artifactPath)~=item.bytes
        fail('Dataset artifact hash or size differs: %s.',name);
    end
    names(k)=string(name);
end
if numel(unique(names))~=numel(names)
    fail('Dataset artifacts manifest must contain unique file names.');
end
if ~all(ismember(["dataset.mat","manifest.json","rows.csv"],names))
    fail('Dataset artifact manifest must include the dataset, source manifest, and row keys.');
end
end

function validateCopiedDatasetArtifacts(ctx,folder)
for k=1:numel(ctx.datasetArtifacts.files)
    item=ctx.datasetArtifacts.files(k);
    name=text(item.name,'dataset artifact name'); path=fullfile(folder,name);
    if ~isfile(path)||fileBytes(path)~=double(item.bytes)|| ...
            ~strcmpi(nbiot.ml.fileSha256(path),text(item.sha256,'dataset artifact hash'))
        fail('Evaluated output is missing or alters dataset artifact: %s.',name);
    end
end
end

function validateProtocol(protocol,freezeAt)
required={'schemaVersion','frozenAtUtc','approver','approvedAtUtc','baseline', ...
    'selectionRule','thresholds','requiredStrata','scope','policyTuningAllowedRoles','testConsumption'};
if ~isstruct(protocol)||~isscalar(protocol)||~all(isfield(protocol,required))|| ...
        protocol.schemaVersion~=1||isempty(text(protocol.approver,'protocol approver'))|| ...
        ~strcmp(text(protocol.baseline,'protocol baseline'),'trainMean')|| ...
        ~strcmp(text(protocol.selectionRule,'protocol selection rule'),'lowest-validation-mae')|| ...
        ~strcmp(text(protocol.testConsumption,'protocol test consumption'),'once-after-freeze')
    fail('Approved protocol is malformed or violates the frozen evaluation contract.');
end
frozenAt=parseUtc(protocol.frozenAtUtc,'protocol frozenAtUtc');
approvedAt=parseUtc(protocol.approvedAtUtc,'protocol approvedAtUtc');
if approvedAt<frozenAt||approvedAt>freezeAt, fail('Protocol approval must precede selection freeze.'); end
thresholdNames={'maxMae','maxRmse','maxMaeToBaselineRatio','maxRmseToBaselineRatio'};
if ~isstruct(protocol.thresholds)||~isscalar(protocol.thresholds)|| ...
        ~all(isfield(protocol.thresholds,thresholdNames))
    fail('All four numeric protocol thresholds are required.');
end
for k=1:numel(thresholdNames)
    value=protocol.thresholds.(thresholdNames{k});
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)||value<0
        fail('Protocol thresholds must be finite nonnegative numbers.');
    end
end
if ~isstruct(protocol.requiredStrata)||isempty(protocol.requiredStrata)|| ...
        ~all(isfield(protocol.requiredStrata,{'numUE','trafficKind'}))|| ...
        ~isstruct(protocol.scope)||~isscalar(protocol.scope)
    fail('Protocol scope and required strata must be explicit.');
end
for k=1:numel(protocol.requiredStrata)
    if ~isPositiveInteger(protocol.requiredStrata(k).numUE)|| ...
            isempty(text(protocol.requiredStrata(k).trafficKind,'required trafficKind'))
        fail('Protocol required stratum is invalid.');
    end
end
roles=cellstr(string(protocol.policyTuningAllowedRoles(:))).';
if ~isequal(sort(roles),sort({'development','validation'}))
    fail('Protocol policy tuning roles are invalid.');
end
validateProtocolScope(protocol.scope);
end

function validateFrozenPolicy(policy)
defaults=adaptiveDefaults(); fields=fieldnames(defaults);
if ~isstruct(policy)||~isscalar(policy)||~isequal(sort(fieldnames(policy)),sort(fields))|| ...
        ~strcmp(text(policy.status,'policy status'),'frozen-validation')|| ...
        ~isPositiveInteger(policy.windowTicks)||~isPositiveInteger(policy.maximumLoad)|| ...
        ~isProbability(policy.staticAccessProbability)||~isProbability(policy.staticRaShare)
    fail('Policy must contain every adaptiveDefaults field and be frozen-validation.');
end
if ~validIncreasing(policy.accessLoadThresholds)|| ...
        ~validLevels(policy.accessProbabilityLevels,numel(policy.accessLoadThresholds)+1,'descending')|| ...
        ~validIncreasing(policy.raLoadThresholds)|| ...
        ~validLevels(policy.raShareLevels,numel(policy.raLoadThresholds)+1,'ascending')|| ...
        policy.maximumLoad<max([policy.accessLoadThresholds(:);policy.raLoadThresholds(:)])
    fail('Frozen policy thresholds and levels are invalid.');
end
nbiot.controller.policySha256(policy);
end

function validateProtocolScope(scope)
required={'methods','numUE','trafficKinds','windowTicks'};
allowed={'methods','numUE','trafficKinds','windowTicks','burstDurationTicks', ...
    'periodTicks','poissonRatePerSecond'};
if ~all(isfield(scope,required))||~all(ismember(fieldnames(scope),allowed))
    fail('Protocol scope must name methods, loads, traffic kinds, and windowTicks only.');
end
methods=cellstr(string(scope.methods(:)));
if isempty(methods)||any(cellfun(@isempty,methods))||numel(unique(methods))~=numel(methods)
    fail('Protocol scope methods must be non-empty and unique.');
end
if ~isnumeric(scope.numUE)||~isreal(scope.numUE)||~isvector(scope.numUE)||isempty(scope.numUE)|| ...
        any(~isfinite(scope.numUE(:))|scope.numUE(:)<1|scope.numUE(:)~=fix(scope.numUE(:)))|| ...
        numel(unique(double(scope.numUE(:))))~=numel(scope.numUE)
    fail('Protocol scope numUE values must be positive unique integers.');
end
traffic=string(scope.trafficKinds(:));
allowedTraffic=["burst";"periodic";"poisson";"test-fixture"];
if isempty(traffic)||any(ismissing(traffic)|traffic=="")|| ...
        any(~ismember(traffic,allowedTraffic))||numel(unique(traffic))~=numel(traffic)
    fail('Protocol scope contains an unsupported or duplicate traffic kind.');
end
if ~isPositiveInteger(scope.windowTicks)
    fail('Protocol scope windowTicks must be a positive integer.');
end
validateTrafficScopeField(scope,traffic,"burst",'burstDurationTicks','positive-integer');
validateTrafficScopeField(scope,traffic,"periodic",'periodTicks','positive-integer');
validateTrafficScopeField(scope,traffic,"poisson",'poissonRatePerSecond','nonnegative');
end

function validateTrafficScopeField(scope,traffic,kind,field,validation)
isApplicable=any(traffic==kind); hasField=isfield(scope,field);
if isApplicable~=hasField
    fail('Protocol scope must include %s exactly when %s traffic is scoped.',field,kind);
end
if ~hasField, return; end
values=scope.(field);
if ~isnumeric(values)||~isreal(values)||~isvector(values)||isempty(values)|| ...
        any(~isfinite(values(:)))||numel(unique(double(values(:))))~=numel(values)
    fail('Protocol scope %s values must be finite, non-empty, and unique.',field);
end
if strcmp(validation,'positive-integer')
    if any(values(:)<1|values(:)~=fix(values(:)))
        fail('Protocol scope %s values must be positive integers.',field);
    end
elseif any(values(:)<0)
    fail('Protocol scope %s values must be nonnegative.',field);
end
end

function rows=validatePreTestScope(datasetManifest,dataKind,freeze,protocol,policy,datasetFolder)
scope=protocol.scope;
if double(scope.windowTicks)~=double(policy.windowTicks)
    fail('Protocol windowTicks differs from the frozen policy window.');
end
rows=validateDatasetWindowRows(fullfile(datasetFolder,'rows.csv'),scope.windowTicks,freeze);
inputs=datasetManifest.inputs;
if strcmp(char(string(dataKind)),'development-fixture')&&isempty(inputs)
    validateScopeValues(1,"test-fixture",NaN,NaN,NaN,scope);
    return;
end
required={'caseKey','realizationId','numUE','trafficKind', ...
    'burstDurationTicks','periodTicks','poissonRatePerSecond'};
if ~isstruct(inputs)||isempty(inputs)||~all(isfield(inputs,required))
    fail('Candidate dataset manifest lacks complete pre-test scope metadata.');
end
caseKeys=string({inputs.caseKey}); ids=double([inputs.realizationId]);
numUE=double([inputs.numUE]); traffic=string({inputs.trafficKind});
burst=nan(1,numel(inputs)); periods=nan(1,numel(inputs)); rates=nan(1,numel(inputs));
for k=1:numel(inputs)
    burst(k)=optionalInputNumber(inputs(k).burstDurationTicks,'burstDurationTicks');
    periods(k)=optionalInputNumber(inputs(k).periodTicks,'periodTicks');
    rates(k)=optionalInputNumber(inputs(k).poissonRatePerSecond,'poissonRatePerSecond');
end
allIds=sort([double(freeze.trainingIds(:).'),double(freeze.validationIds(:).'), ...
    double(freeze.testIds(:).')]);
if any(ismissing(caseKeys)|caseKeys=="")||numel(unique(caseKeys))~=numel(caseKeys)|| ...
        numel(unique(ids))~=numel(ids)||~isequal(sort(ids),allIds)|| ...
        any(~isfinite(numUE)|numUE<1|numUE~=fix(numUE))|| ...
        any(~ismember(traffic,string(scope.trafficKinds(:))))
    fail('Candidate input IDs, load, or traffic kinds are outside the frozen protocol scope.');
end
for k=1:numel(inputs)
    validateScopeValues(numUE(k),traffic(k),burst(k),periods(k),rates(k),scope);
end
rowCaseKeys=string(rows.caseKey);
rowIds=double(rows.realizationId);
rowSplits=string(rows.split);
uniqueRowCases=unique(rowCaseKeys,'stable');
if numel(uniqueRowCases)~=numel(caseKeys)||any(~ismember(uniqueRowCases,caseKeys))
    fail('Pre-test row cases do not match the candidate input cases.');
end
for k=1:numel(inputs)
    at=rowCaseKeys==caseKeys(k);
    expectedSplit="";
    if ismember(ids(k),double(freeze.trainingIds(:))), expectedSplit="train"; end
    if ismember(ids(k),double(freeze.validationIds(:))), expectedSplit="validation"; end
    if ismember(ids(k),double(freeze.testIds(:))), expectedSplit="test"; end
    if ~any(at)||~isequal(unique(rowIds(at)),ids(k))|| ...
            ~isequal(unique(rowSplits(at)),expectedSplit)
        fail('Pre-test rows do not map to the candidate case keys, realization IDs, and frozen splits.');
    end
end
end

function rows=validateDatasetWindowRows(path,windowTicks,freeze)
if ~isfile(path), fail('Pre-test row-key artifact is missing.'); end
try, rows=readtable(path,'TextType','string');
catch exception, fail('Cannot read pre-test row-key artifact: %s.',exception.message); end
required={'caseKey','realizationId','windowId','startTick','endTick','split'};
if ~istable(rows)||isempty(rows)||~all(ismember(required,rows.Properties.VariableNames))
    fail('Pre-test row-key artifact is malformed or incomplete.');
end
caseKeys=string(rows.caseKey); ids=double(rows.realizationId);
windows=double(rows.windowId); starts=double(rows.startTick); ends=double(rows.endTick);
splits=string(rows.split);
if any(ismissing(caseKeys)|caseKeys=="")||any(~isfinite(ids)|ids<0|ids~=fix(ids))|| ...
        any(~isfinite(windows)|windows<1|windows~=fix(windows))|| ...
        any(~isfinite(starts)|starts<0|starts~=fix(starts))|| ...
        any(~isfinite(ends)|ends<=starts|ends~=fix(ends))|| ...
        any(~ismember(splits,["train";"validation";"test"]))
    fail('Pre-test row-key artifact has invalid IDs, windows, ticks, or splits.');
end
for k=1:3
    splitName=["train";"validation";"test"];
    idField={'trainingIds','validationIds','testIds'};
    actual=sort(unique(ids(splits==splitName(k)))).';
    if ~isequal(actual,double(freeze.(idField{k})(:).'))
        fail('Pre-test row keys do not match the frozen %s IDs.',splitName(k));
    end
end
uniqueCases=unique(caseKeys,'stable');
for k=1:numel(uniqueCases)
    at=caseKeys==uniqueCases(k); caseIds=unique(ids(at)); caseSplits=unique(splits(at));
    caseRows=sortrows(rows(at,:),'windowId');
    caseWindows=double(caseRows.windowId); caseStarts=double(caseRows.startTick);
    caseEnds=double(caseRows.endTick);
    if numel(caseIds)~=1||numel(caseSplits)~=1|| ...
            ~isequal(caseWindows(:),(1:numel(caseWindows)).')|| ...
            any(caseStarts(:)~=(caseWindows(:)-1)*double(windowTicks))|| ...
            any(caseEnds(:)>caseWindows(:)*double(windowTicks))|| ...
            (numel(caseWindows)>1&&any(caseEnds(1:end-1)~=caseStarts(2:end)))|| ...
            (numel(caseWindows)>1&&any(caseEnds(1:end-1)~=caseWindows(1:end-1)*double(windowTicks)))
        fail('Pre-test row windows exceed or differ from the protocol window scope.');
    end
    if ismember('experimentRole',rows.Properties.VariableNames)
        roles=string(caseRows.experimentRole);
        expected=caseSplits;
        if expected=="train", expected="training";
        elseif expected=="test", expected="model-test"; end
        if any(roles~=expected), fail('Pre-test row roles do not match their split.'); end
    end
end
end

function validateScopeValues(numUE,traffic,burst,periods,rates,scope)
if ~ismember(double(numUE),double(scope.numUE(:)))|| ...
        ~ismember(string(traffic),string(scope.trafficKinds(:)))
    fail('Dataset contains load or traffic strata outside the approved protocol scope.');
end
switch string(traffic)
    case "burst"
        if ~isfinite(burst)||~ismember(double(burst),double(scope.burstDurationTicks(:)))
            fail('Dataset burstDurationTicks is outside the approved protocol scope.');
        end
    case "periodic"
        if ~isfinite(periods)||~ismember(double(periods),double(scope.periodTicks(:)))
            fail('Dataset periodTicks is outside the approved protocol scope.');
        end
    case "poisson"
        if ~isfinite(rates)||~ismember(double(rates),double(scope.poissonRatePerSecond(:)))
            fail('Dataset poissonRatePerSecond is outside the approved protocol scope.');
        end
    case "test-fixture"
        if double(numUE)~=1
            fail('Development fixture strata must use the fixture load.');
        end
    otherwise
        fail('Dataset traffic kind is unsupported by the approved protocol scope.');
end
end

function value=optionalInputNumber(input,label)
if isempty(input)
    value=NaN;
elseif isnumeric(input)&&isreal(input)&&isscalar(input)
    value=double(input);
else
    fail('Dataset input %s metadata must be a scalar number or null.',label);
end
end

function yes=validIncreasing(values)
yes=isnumeric(values)&&isvector(values)&&~isempty(values)&&all(isfinite(values(:)))&& ...
    all(values(:)>=0)&&all(diff(double(values(:)))>0);
end
function yes=validLevels(values,count,direction)
yes=isnumeric(values)&&isvector(values)&&numel(values)==count&& ...
    all(isfinite(values(:)))&&all(values(:)>=0&values(:)<=1);
if yes&&strcmp(direction,'descending'), yes=all(diff(double(values(:)))<0); end
if yes&&strcmp(direction,'ascending'), yes=all(diff(double(values(:)))>0); end
end
function yes=isProbability(value)
yes=isnumeric(value)&&isscalar(value)&&isfinite(value)&&value>=0&&value<=1;
end

function ids=validIds(value,label)
if ~isnumeric(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:))|value(:)<0|value(:)>=4000|value(:)~=fix(value(:)))
    fail('%s must be non-empty integer IDs in 0:3999.',label);
end
ids=double(value(:).');
if numel(unique(ids))~=numel(ids)||~isequal(ids,sort(ids))
    fail('%s must be sorted and unique.',label);
end
end

function kind=kindForEvidence(evidence)
if strcmp(char(string(evidence)),'test-fixture'), kind='development-fixture';
else, kind='candidate-training'; end
end

function path=canonicalPath(value,label,mustExist)
if ~(ischar(value)||(isstring(value)&&isscalar(value)))
    fail('%s must be a scalar path.',label);
end
path=char(string(value));
if isempty(path), fail('%s must not be empty.',label); end
try, path=char(java.io.File(path).getCanonicalPath());
catch exception, fail('%s cannot be resolved: %s',label,exception.message); end
if mustExist&&~(isfile(path)||isfolder(path)), fail('%s does not exist.',label); end
if ~mustExist&&isfile(path), fail('%s cannot be an existing file.',label); end
end

function yes=isWithin(path,folder)
path=char(java.io.File(path).getCanonicalPath());
folder=char(java.io.File(folder).getCanonicalPath());
if ~endsWith(folder,filesep), folder=[folder filesep]; end
yes=strcmpi(path,folder(1:end-1))||strncmpi(path,folder,numel(folder));
end
function yes=samePath(a,b)
yes=strcmpi(char(java.io.File(a).getCanonicalPath()),char(java.io.File(b).getCanonicalPath()));
end

function digest=sha256Text(value)
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(unicode2native(char(value),'UTF-8'),'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function value=readJson(path,label)
try, value=jsondecode(fileread(path));
catch exception, fail('Cannot read %s: %s',label,exception.message); end
end

function writeJsonAtomic(path,value)
temporary=[path '.tmp-' char(java.util.UUID.randomUUID())];
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, fail('Cannot create temporary evaluation JSON.'); end
cleanup=onCleanup(@() closeAndDelete(fid,temporary)); %#ok<NASGU>
bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes), fail('Cannot write complete evaluation JSON.'); end
fclose(fid); fid=-1;
saved=readJson(temporary,'temporary evaluation JSON');
if ~isequaln(saved,jsondecode(jsonencode(value)))
    fail('Temporary evaluation JSON readback differs from its source.');
end
[ok,message]=movefile(temporary,path);
if ~ok, fail('Cannot finalize evaluation JSON: %s',message); end
end

function closeAndDelete(fid,path)
if fid>=0, try, fclose(fid); catch, end, end
if isfile(path), try, delete(path); catch, end, end
end

function value=text(input,label)
if (ischar(input)&&size(input,1)==1)||(isstring(input)&&isscalar(input))
    value=char(string(input));
else
    fail('%s must be scalar text.',label);
end
end
function yes=isSha256(value)
yes=(ischar(value)||(isstring(value)&&isscalar(value)))&& ...
    numel(char(string(value)))==64&& ...
    all(ismember(lower(char(string(value))),'0123456789abcdef'));
end
function yes=isBasename(value)
value=char(string(value)); [folder,~,~]=fileparts(value);
yes=~isempty(value)&&isempty(folder)&&~contains(value,'..')&& ...
    ~contains(value,'/')&&~contains(value,'\')&&~contains(value,':');
end
function yes=isPositiveInteger(value)
yes=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&& ...
    value>0&&value==fix(value);
end
function count=fileBytes(path), info=dir(path); count=info.bytes; end

function value=parseUtc(input,label)
timestamp=text(input,label);
formats={"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'","yyyy-MM-dd'T'HH:mm:ss'Z'"};
value=NaT('TimeZone','UTC');
for k=1:numel(formats)
    try
        value=datetime(timestamp,'InputFormat',formats{k},'TimeZone','UTC');
        if ~isnat(value), return; end
    catch
    end
end
fail('%s must be an ISO-8601 UTC timestamp.',label);
end
function value=utcNow()
stamp=datetime('now','TimeZone','UTC'); stamp.Format="yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
value=char(stamp);
end
function fail(message,varargin)
error('nbiot:ml:FrozenEvaluation',message,varargin{:});
end

