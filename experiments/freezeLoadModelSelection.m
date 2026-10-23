function freeze=freezeLoadModelSelection(options)
%FREEZELOADMODELSELECTION Freeze the validation winner without opening test labels.
try
    freeze=buildFreeze(options);
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelFreeze')
        rethrow(exception);
    end
    wrapped=MException('nbiot:ml:ModelFreeze', ...
        'The selection could not be frozen: %s',exception.message);
    wrapped=addCause(wrapped,exception);
    throwAsCaller(wrapped);
end
end

function freeze=buildFreeze(options)
required={'selectionFolder','datasetFile','policyFile','protocolFile', ...
    'registryFile','policyTuningIds','outputFile'};
if ~isstruct(options)||~isscalar(options)
    fail('Options must be a scalar structure.');
end
names=fieldnames(options);
unknown=setdiff(names,required);
missing=setdiff(required,names);
if ~isempty(unknown), fail('Unknown option: %s.',unknown{1}); end
if ~isempty(missing), fail('Missing required option: %s.',missing{1}); end

selectionFolder=canonicalPath(options.selectionFolder,'selectionFolder',true);
datasetFile=canonicalPath(options.datasetFile,'datasetFile',true);
policyFile=canonicalPath(options.policyFile,'policyFile',true);
protocolFile=canonicalPath(options.protocolFile,'protocolFile',true);
registryFile=canonicalPath(options.registryFile,'registryFile',true);
outputFile=canonicalPath(options.outputFile,'outputFile',false);
if isfile(outputFile), fail('outputFile already exists; freeze never overwrites it.'); end
[~,~,outputExtension]=fileparts(outputFile);
if ~strcmpi(outputExtension,'.json'), fail('outputFile must have a .json extension.'); end
outputFolder=fileparts(outputFile);
if isempty(outputFolder), outputFolder=pwd; end
if ~isfolder(outputFolder), fail('The outputFile parent folder must already exist.'); end
if isWithin(outputFile,selectionFolder)
    fail('outputFile must be outside the immutable selection folder.');
end
inputPaths={selectionFolder,datasetFile,policyFile,protocolFile,registryFile};
if any(cellfun(@(path) samePath(path,outputFile),inputPaths))
    fail('outputFile cannot replace an input.');
end

% Approval and the immutable policy are checked before reading selection metadata.
protocol=readJson(protocolFile,'approved protocol');
protocol=validateProtocol(protocol);
policy=readJson(policyFile,'adaptive policy');
validateFrozenPolicy(policy);

trainingManifestFile=fullfile(selectionFolder,'training-manifest.json');
if ~isfile(trainingManifestFile), fail('Selection training-manifest.json is missing.'); end
trainingManifest=readJson(trainingManifestFile,'selection training manifest');
[trainingManifest,metrics,splitIds]=validateSelection(trainingManifest,selectionFolder,datasetFile);

datasetManifestFile=fullfile(selectionFolder,'dataset-manifest.json');
sourceManifestFile=fullfile(fileparts(datasetFile),'manifest.json');
if ~isfile(datasetManifestFile)||~isfile(sourceManifestFile)
    fail('Both the original and copied dataset manifests are required.');
end
datasetManifest=readJson(sourceManifestFile,'dataset manifest');
copiedManifest=readJson(datasetManifestFile,'copied dataset manifest');
if ~isequaln(datasetManifest,copiedManifest)
    fail('The copied dataset manifest differs from the original.');
end
if ~isfield(trainingManifest,'datasetManifestSha256')|| ...
        ~isSha256(trainingManifest.datasetManifestSha256)|| ...
        ~strcmpi(nbiot.ml.fileSha256(sourceManifestFile),trainingManifest.datasetManifestSha256)|| ...
        ~strcmpi(nbiot.ml.fileSha256(datasetManifestFile),trainingManifest.datasetManifestSha256)
    fail('The dataset manifest hash does not match the selection manifest.');
end
[datasetManifest,evidenceKind]=validateDatasetManifest( ...
    datasetManifest,trainingManifest,splitIds,protocol);
validateDatasetArtifacts(fileparts(datasetFile),datasetManifest.kind);

registry=readJson(registryFile,'allocation registry');
registry=validateRegistry(registry);
policyTuningIds=normalizeIds(options.policyTuningIds,'policyTuningIds',true);
validatePolicyTuningIds(policyTuningIds,splitIds,registry,protocol);

modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
modelTemplate=struct('modelName','','file','','sha256','', ...
    'sidecarFile','','sidecarSha256','');
models=repmat(modelTemplate,1,numel(modelNames));
bundles=cell(1,numel(modelNames));
for k=1:numel(modelNames)
    modelName=modelNames{k};
    manifestAt=find(strcmp(trainingManifest.modelNames,modelName),1);
    modelFile=fullfile(selectionFolder,[modelName '.mat']);
    sidecarFile=fullfile(selectionFolder,[modelName '.json']);
    if isempty(manifestAt)||~isfile(modelFile)||~isfile(sidecarFile)
        fail('A required model artifact or sidecar is missing: %s.',modelName);
    end
    actualModelHash=nbiot.ml.fileSha256(modelFile);
    if ~strcmpi(actualModelHash,trainingManifest.artifactSha256{manifestAt})
        fail('Model artifact hash mismatch: %s.',modelName);
    end
    bundle=nbiot.ml.validateModelBundle(modelFile);
    if ~strcmp(bundle.modelName,modelName)||~strcmp(bundle.dataKind,trainingManifest.dataKind)|| ...
            ~strcmp(bundle.status,'development')|| ...
            ~isequal(normalizeIds(bundle.trainingIds,'bundle training IDs',false),splitIds.training)|| ...
            ~isequal(normalizeIds(bundle.validationIds,'bundle validation IDs',false),splitIds.validation)|| ...
            ~isequal(normalizeIds(bundle.testIds,'bundle test IDs',false),splitIds.test)
        fail('Model bundle metadata differs from the selection manifest: %s.',modelName);
    end
    bundles{k}=bundle;
    models(k)=struct('modelName',modelName,'file',[modelName '.mat'], ...
        'sha256',actualModelHash,'sidecarFile',[modelName '.json'], ...
        'sidecarSha256',nbiot.ml.fileSha256(sidecarFile));
end

validationMae=zeros(1,numel(modelNames));
for k=1:numel(modelNames)
    at=string(metrics.model)==modelNames{k}&string(metrics.split)=="validation";
    if nnz(at)~=1, fail('Each model must have exactly one validation score.'); end
    validationMae(k)=metrics.mae(at);
end
[~,selectedIndex]=min(validationMae);
selectedModel=modelNames{selectedIndex};
if ~strcmp(trainingManifest.bestValidationModel,selectedModel)
    fail('bestValidationModel does not match the fixed validation-MAE rule.');
end
chosen=models(selectedIndex);
freeze=struct( ...
    'schemaVersion','load-model-freeze-v1', ...
    'evidenceKind',evidenceKind, ...
    'createdAtUtc',utcNow(), ...
    'approvedProtocolSha256',nbiot.ml.fileSha256(protocolFile), ...
    'modelSha256',chosen.sha256, ...
    'modelSidecarSha256',chosen.sidecarSha256, ...
    'policySha256',nbiot.controller.policySha256(policy), ...
    'policyFileSha256',nbiot.ml.fileSha256(policyFile), ...
    'datasetSha256',nbiot.ml.fileSha256(datasetFile), ...
    'selectionManifestSha256',nbiot.ml.fileSha256(trainingManifestFile), ...
    'registrySha256',nbiot.ml.fileSha256(registryFile), ...
    'selectedModel',selectedModel, ...
    'selectionRule','lowest-validation-mae;tieOrder=linearRegression,decisionTree,randomForest,gradientBoosting', ...
    'trainingIds',splitIds.training, ...
    'validationIds',splitIds.validation, ...
    'testIds',splitIds.test, ...
    'policyTuningIds',policyTuningIds, ...
    'models',models);
writeAtomicJson(outputFile,freeze);
freeze=readJson(outputFile,'saved freeze');
end

function [manifest,metrics,ids]=validateSelection(manifest,folder,datasetFile)
required={'formatVersion','phase','dataKind','allocationsVerified','status', ...
    'bestValidationModel','selectionRule','modelNames','artifactFiles','artifactSha256', ...
    'trainingIds','validationIds','testIds','metricsFile','metricsSha256', ...
    'metricsRowCount','datasetFile','datasetSha256','datasetManifestFile', ...
    'datasetManifestSha256','splitEvidence'};
if ~isstruct(manifest)||~isscalar(manifest)||~all(isfield(manifest,required))
    fail('Selection training manifest is incomplete.');
end
if ~strcmp(char(string(manifest.formatVersion)),'load-training-report-v2')|| ...
        ~strcmp(char(string(manifest.phase)),'selection')
    fail('The training manifest must describe phase=selection.');
end
if ~strcmp(char(string(manifest.status)),'development')|| ...
        ~ismember(char(string(manifest.dataKind)),{'development-fixture','candidate-training'})
    fail('Unsupported selection data kind or status.');
end
ids=struct('training',normalizeIds(manifest.trainingIds,'trainingIds',false), ...
    'validation',normalizeIds(manifest.validationIds,'validationIds',false), ...
    'test',normalizeIds(manifest.testIds,'testIds',false));
if ~isempty(intersect(ids.training,ids.validation))|| ...
        ~isempty(intersect(ids.training,ids.test))||~isempty(intersect(ids.validation,ids.test))
    fail('Training, validation, and test IDs must be disjoint.');
end
if ~isequal(sort([ids.training ids.validation ids.test]), ...
        unique([ids.training ids.validation ids.test]))
    fail('Model split IDs must be unique.');
end
evidence=manifest.splitEvidence;
if ~isstruct(evidence)||numel(evidence)~=3|| ...
        ~all(isfield(evidence,{'split','ids','sampleCount','idCount'}))
    fail('splitEvidence must contain exactly train, validation, and test.');
end
splitNames={'train','validation','test'};
idGroups={ids.training,ids.validation,ids.test};
for k=1:3
    at=find(strcmp({evidence.split},splitNames{k}));
    if numel(at)~=1, fail('splitEvidence must contain one %s group.',splitNames{k}); end
    evidenceIds=normalizeIds(evidence(at).ids,[splitNames{k} ' split IDs'],false);
    if ~isequal(evidenceIds,idGroups{k})|| ...
            ~isPositiveInteger(evidence(at).sampleCount)|| ...
            ~isPositiveInteger(evidence(at).idCount)||evidence(at).idCount~=numel(idGroups{k})
        fail('splitEvidence counts or IDs do not match %s.',splitNames{k});
    end
end

names=normalizeTextList(manifest.modelNames,'modelNames');
expected={'linearRegression','decisionTree','randomForest','gradientBoosting'};
if numel(names)~=4||numel(unique(names))~=4||~isequal(sort(names),sort(expected))
    fail('Exactly the four supported model names are required.');
end
files=normalizeTextList(manifest.artifactFiles,'artifactFiles');
hashes=normalizeTextList(manifest.artifactSha256,'artifactSha256');
if numel(files)~=4||numel(hashes)~=4
    fail('The selection manifest must bind four model artifacts.');
end
for k=1:4
    if ~strcmp(files{k},[names{k} '.mat'])||~isBasename(files{k})||~isSha256(hashes{k})
        fail('Model artifact names or hashes are invalid.');
    end
end
if ~strcmp(char(string(manifest.metricsFile)),'metrics.csv')|| ...
        ~isSha256(manifest.metricsSha256)||~isPositiveInteger(manifest.metricsRowCount)|| ...
        manifest.metricsRowCount~=10
    fail('Selection metrics metadata is invalid.');
end
if ~strcmp(char(string(manifest.datasetFile)),fileName(datasetFile))|| ...
        ~isSha256(manifest.datasetSha256)|| ...
        ~strcmpi(nbiot.ml.fileSha256(datasetFile),manifest.datasetSha256)|| ...
        ~strcmp(char(string(manifest.datasetManifestFile)),'dataset-manifest.json')
    fail('Selection dataset references are invalid.');
end
if ~isSha256(manifest.datasetManifestSha256)|| ...
        ~strcmp(char(string(manifest.selectionRule)), ...
        'lowest validation MAE; test results are not used for selection')
    fail('Dataset hash or selection rule is invalid.');
end
if ~isequal(logical(manifest.allocationsVerified), ...
        strcmp(char(string(manifest.dataKind)),'candidate-training'))
    fail('Allocation verification does not match the training data kind.');
end

metricsFile=fullfile(folder,'metrics.csv');
if ~isfile(metricsFile)||~strcmpi(nbiot.ml.fileSha256(metricsFile),manifest.metricsSha256)
    fail('Selection metrics file is missing or its hash is incorrect.');
end
metrics=readtable(metricsFile);
expectedColumns={'model','split','sampleCount','idCount','mae','rmse', ...
    'bias','predictionSeconds','trainingSeconds'};
if height(metrics)~=10||~isequal(metrics.Properties.VariableNames,expectedColumns)
    fail('Selection metrics must contain exactly the ten train/validation rows.');
end
modelColumn=string(metrics.model); splitColumn=string(metrics.split);
allowedModels=[string(expected) "trainMean"];
if any(~ismember(modelColumn,allowedModels))||any(~ismember(splitColumn,["train" "validation"]))
    fail('Selection metrics contain an unsupported model or split.');
end
numericColumns={'sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'};
for k=1:numel(numericColumns)
    values=metrics.(numericColumns{k});
    if ~isnumeric(values)||any(~isfinite(values))
        fail('Selection metrics contain non-finite numeric values.');
    end
end
if any(metrics.sampleCount<=0|metrics.sampleCount~=fix(metrics.sampleCount))|| ...
        any(metrics.idCount<=0|metrics.idCount~=fix(metrics.idCount))|| ...
        any(metrics.mae<0|metrics.rmse<0|metrics.predictionSeconds<0|metrics.trainingSeconds<0)
    fail('Selection metrics contain invalid counts or values.');
end
allModels=[expected {'trainMean'}];
for modelIndex=1:numel(allModels)
    for splitIndex=1:2
        splitName=splitNames{splitIndex}; modelName=allModels{modelIndex};
        at=modelColumn==modelName&splitColumn==splitName;
        if nnz(at)~=1, fail('Metrics must contain one %s/%s row.',modelName,splitName); end
        evidenceAt=find(strcmp({evidence.split},splitName),1);
        if metrics.sampleCount(at)~=evidence(evidenceAt).sampleCount|| ...
                metrics.idCount(at)~=evidence(evidenceAt).idCount
            fail('Metric counts do not match splitEvidence for %s.',splitName);
        end
    end
end
if ~ismember(char(string(manifest.bestValidationModel)),expected)
    fail('bestValidationModel is not one of the four supported models.');
end
end

function [manifest,evidenceKind]=validateDatasetManifest(manifest,trainingManifest,ids,protocol)
required={'kind','assignments','inputs','allocationsVerified','experimentRolesExplicit'};
if ~isstruct(manifest)||~isscalar(manifest)||~all(isfield(manifest,required))|| ...
        ~strcmp(char(string(manifest.kind)),char(string(trainingManifest.dataKind)))
    fail('Dataset manifest kind or structure does not match training evidence.');
end
assignments=normalizeDatasetAssignments(manifest.assignments);
expectedSplits={'train','validation','test'};
expectedRoles={'training','validation','model-test'};
idGroups={ids.training,ids.validation,ids.test};
allIds=[];
for k=1:3
    at=string({assignments.split})==expectedSplits{k};
    groupIds=sort([assignments(at).id]);
    if ~isequal(groupIds,idGroups{k})|| ...
            any(string({assignments(at).role})~=expectedRoles{k})
        fail('Dataset manifest assignments do not match the %s split.',expectedSplits{k});
    end
    allIds=[allIds groupIds]; %#ok<AGROW>
end
if numel(assignments)~=numel(allIds)||numel(unique(allIds))~=numel(allIds)
    fail('Dataset manifest has missing, duplicate, or extra realization assignments.');
end
kind=char(string(manifest.kind));
if strcmp(kind,'development-fixture')
    if logical(manifest.allocationsVerified)||logical(manifest.experimentRolesExplicit)|| ...
            logical(trainingManifest.allocationsVerified)
        fail('Development fixture evidence cannot claim verified scientific allocations.');
    end
    evidenceKind='test-fixture';
elseif strcmp(kind,'candidate-training')
    if ~logical(manifest.allocationsVerified)||~logical(manifest.experimentRolesExplicit)|| ...
            ~logical(trainingManifest.allocationsVerified)|| ...
            ~isfield(manifest,'diagnosticsComplete')||~logical(manifest.diagnosticsComplete)
        fail('Candidate evidence requires verified roles, allocations, and diagnostics.');
    end
    if ~isfield(manifest,'diagnosticsSchemaVersion')|| ...
            isempty(char(string(manifest.diagnosticsSchemaVersion)))|| ...
            isempty(manifest.inputs)||~isstruct(manifest.inputs)
        fail('Candidate evidence is missing diagnostics or source inputs.');
    end
    for k=1:numel(manifest.inputs)
        input=manifest.inputs(k);
        if ~all(isfield(input,{'realizationId','sourceSha256','calibrationSha256','isFixture'}))|| ...
                ~isSha256(input.sourceSha256)||~isSha256(input.calibrationSha256)|| ...
                ~isequal(input.isFixture,false)|| ...
                ~ismember(double(input.realizationId),allIds)
            fail('Candidate dataset input provenance is incomplete or fixture-derived.');
        end
    end
    if ~isSha256(trainingManifest.sourceSha256)||~isSha256(trainingManifest.calibrationSha256)|| ...
            contains(lower(char(string(protocol.approver))),'fixture')
        fail('Candidate evidence needs non-fixture source, calibration, and protocol approval.');
    end
    evidenceKind='scientific-candidate';
else
    fail('Unsupported dataset kind.');
end
end

function validateDatasetArtifacts(folder,kind)
artifactFile=fullfile(folder,'artifacts.json');
if ~isfile(artifactFile), fail('Dataset artifacts.json is missing.'); end
artifacts=readJson(artifactFile,'dataset artifacts');
if ~isstruct(artifacts)||~isscalar(artifacts)||~isfield(artifacts,'schemaVersion')|| ...
        artifacts.schemaVersion~=1||~isfield(artifacts,'files')||~isstruct(artifacts.files)
    fail('Dataset artifacts.json has an unsupported schema.');
end
files=artifacts.files;
if isempty(files)||~all(isfield(files,{'name','bytes','sha256'}))
    fail('Dataset artifact entries are incomplete.');
end
names=cell(1,numel(files));
for k=1:numel(files)
    names{k}=char(string(files(k).name));
    if ~isBasename(names{k})||~isPositiveInteger(files(k).bytes)||~isSha256(files(k).sha256)
        fail('A dataset artifact reference is invalid.');
    end
    path=fullfile(folder,names{k});
    info=dir(path);
    if isempty(info)||info.isdir||info.bytes~=files(k).bytes|| ...
            ~strcmpi(nbiot.ml.fileSha256(path),files(k).sha256)
        fail('A dataset artifact is missing or changed: %s.',names{k});
    end
end
required={'dataset.mat','manifest.json'};
if strcmp(char(string(kind)),'candidate-training'), required{end+1}='diagnostics.csv'; end
if ~all(ismember(required,names))||numel(unique(names))~=numel(names)
    fail('Dataset artifacts must include unique dataset, manifest, and required diagnostic files.');
end
end

function registry=validateRegistry(registry)
required={'schemaVersion','validRange','roles','reservations','assignments'};
if ~isstruct(registry)||~isscalar(registry)||~all(isfield(registry,required))|| ...
        registry.schemaVersion~=1||~isnumeric(registry.validRange)|| ...
        numel(registry.validRange)~=2||any(~isfinite(registry.validRange))|| ...
        registry.validRange(1)<0||registry.validRange(2)<registry.validRange(1)
    fail('Allocation registry schema is invalid.');
end
roles=normalizeTextList(registry.roles,'registry roles');
if isempty(roles)||numel(unique(roles))~=numel(roles)
    fail('Allocation registry roles are invalid.');
end
if ~isstruct(registry.assignments),
    if isempty(registry.assignments), registry.assignments=struct('role',{},'ids',{},'status',{});
    else, fail('Registry assignments are invalid.'); end
end
occupied=[];
for k=1:numel(registry.assignments)
    item=registry.assignments(k);
    if ~all(isfield(item,{'role','ids','status'}))
        fail('A registry assignment is incomplete.');
    end
    role=char(string(item.role)); status=char(string(item.status));
    assignmentIds=normalizeIds(item.ids,'registry assignment IDs',false);
    if ~ismember(role,roles)||~ismember(status,{'planned','completed','failed'})|| ...
            any(assignmentIds<registry.validRange(1)|assignmentIds>registry.validRange(2))|| ...
            ~isempty(intersect(occupied,assignmentIds))
        fail('Registry assignments contain invalid roles, status, range, or duplicate IDs.');
    end
    occupied=[occupied assignmentIds]; %#ok<AGROW>
end
reservations=registry.reservations;
if ~isstruct(reservations)
    if isempty(reservations), reservations=struct([]); else, fail('Registry reservations are invalid.'); end
end
for k=1:numel(reservations)
    item=reservations(k);
    if isfield(item,'range')&&~isempty(item.range)
        range=double(item.range(:).');
        if numel(range)~=2||any(~isfinite(range))||range(1)<registry.validRange(1)|| ...
                range(2)>registry.validRange(2)||range(2)<range(1)
            fail('Registry reservation range is invalid.');
        end
    elseif isfield(item,'ids')&&~isempty(item.ids)
        reservationIds=normalizeIds(item.ids,'registry reservation IDs',false);
        if any(reservationIds<registry.validRange(1)|reservationIds>registry.validRange(2))
            fail('Registry reservation IDs are outside validRange.');
        end
    else
        fail('Registry reservations need IDs or a range.');
    end
end
registry.roles=roles;
end

function validatePolicyTuningIds(tuningIds,splitIds,registry,protocol)
if ~isempty(intersect(tuningIds,splitIds.test))
    fail('policyTuningIds cannot overlap model-test IDs.');
end
allowed=normalizeTextList(protocol.policyTuningAllowedRoles,'policyTuningAllowedRoles');
if ~isequal(sort(allowed),sort({'development','validation'}))
    fail('Policy tuning is allowed only for development and validation roles.');
end
for id=tuningIds
    [role,status]=registryRoleForId(registry,id);
    if ~strcmp(status,'completed')||~ismember(role,allowed)
        fail('policyTuningIds must come from completed development or validation allocations.');
    end
end
for id=[splitIds.training splitIds.validation splitIds.test]
    [role,status]=registryRoleForId(registry,id);
    if ~strcmp(status,'completed')
        fail('Every training, validation, and test ID needs a completed registry allocation.');
    end
    if ismember(id,splitIds.training)&&~strcmp(role,'training')
        fail('Training IDs must match training allocations.');
    elseif ismember(id,splitIds.validation)&&~strcmp(role,'validation')
        fail('Validation IDs must match validation allocations.');
    elseif ismember(id,splitIds.test)&&~strcmp(role,'model-test')
        fail('Test IDs must match model-test allocations.');
    end
end
end

function [role,status]=registryRoleForId(registry,id)
role=''; status=''; matches=0;
for k=1:numel(registry.assignments)
    ids=double(registry.assignments(k).ids(:));
    if any(ids==id)
        matches=matches+1;
        role=char(string(registry.assignments(k).role));
        status=char(string(registry.assignments(k).status));
    end
end
if matches~=1, fail('Every referenced ID must have exactly one registry allocation.'); end
for k=1:numel(registry.reservations)
    reservation=registry.reservations(k);
    if isfield(reservation,'range')&&numel(reservation.range)==2&& ...
            id>=min(reservation.range)&&id<=max(reservation.range)
        fail('A referenced ID is reserved in the allocation registry.');
    elseif isfield(reservation,'ids')&&any(double(reservation.ids(:))==id)
        fail('A referenced ID is reserved in the allocation registry.');
    end
end
end

function protocol=validateProtocol(protocol)
required={'schemaVersion','frozenAtUtc','approver','approvedAtUtc','baseline', ...
    'selectionRule','thresholds','requiredStrata','scope', ...
    'policyTuningAllowedRoles','testConsumption'};
if ~isstruct(protocol)||~isscalar(protocol)||~all(isfield(protocol,required))|| ...
        protocol.schemaVersion~=1
    fail('Protocol schema is incomplete or unsupported.');
end
if isempty(textValue(protocol.approver,'protocol approver'))|| ...
        ~strcmp(char(string(protocol.baseline)),'trainMean')|| ...
        ~strcmp(char(string(protocol.selectionRule)),'lowest-validation-mae')|| ...
        ~strcmp(char(string(protocol.testConsumption)),'once-after-freeze')
    fail('Protocol approval or fixed selection contract is invalid.');
end
thresholdNames={'maxMae','maxRmse','maxMaeToBaselineRatio','maxRmseToBaselineRatio'};
if ~isstruct(protocol.thresholds)||~isscalar(protocol.thresholds)|| ...
        ~all(isfield(protocol.thresholds,thresholdNames))
    fail('Protocol must provide all four numeric thresholds.');
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
strata=protocol.requiredStrata;
for k=1:numel(strata)
    if ~isPositiveInteger(strata(k).numUE)||isempty(textValue(strata(k).trafficKind,'trafficKind'))
        fail('Protocol required strata are invalid.');
    end
end
allowed=normalizeTextList(protocol.policyTuningAllowedRoles,'policyTuningAllowedRoles');
if ~isequal(sort(allowed),sort({'development','validation'}))
    fail('Protocol policyTuningAllowedRoles must be development and validation.');
end
frozen=parseUtc(protocol.frozenAtUtc,'protocol frozenAtUtc');
approved=parseUtc(protocol.approvedAtUtc,'protocol approvedAtUtc');
if approved<frozen||approved>datetime('now','TimeZone','UTC')
    fail('Protocol approval must be recorded before selection freeze.');
end
end

function validateFrozenPolicy(policy)
defaults=adaptiveDefaults();
fields=fieldnames(defaults);
if ~isstruct(policy)||~isscalar(policy)|| ...
        numel(fieldnames(policy))~=numel(fields)||~isequal(sort(fieldnames(policy)),sort(fields))|| ...
        ~strcmp(textValue(policy.status,'policy status'),'frozen-validation')
    fail('Policy must contain every adaptiveDefaults field and status=frozen-validation.');
end
if ~isPositiveInteger(policy.windowTicks)||~isPositiveInteger(policy.maximumLoad)|| ...
        ~isProbability(policy.staticAccessProbability)||~isProbability(policy.staticRaShare)
    fail('Policy scalar bounds are invalid.');
end
accessThresholds=policy.accessLoadThresholds; accessLevels=policy.accessProbabilityLevels;
raThresholds=policy.raLoadThresholds; raLevels=policy.raShareLevels;
if ~validIncreasing(accessThresholds)|| ...
        ~validLevels(accessLevels,numel(accessThresholds)+1,'descending')|| ...
        ~validIncreasing(raThresholds)|| ...
        ~validLevels(raLevels,numel(raThresholds)+1,'ascending')|| ...
        policy.maximumLoad<max([accessThresholds(:);raThresholds(:)])
    fail('Policy threshold and level sequences are invalid.');
end
nbiot.controller.policySha256(policy);
end

function assignments=normalizeDatasetAssignments(value)
if istable(value)
    source=value;
elseif isstruct(value)
    source=struct2table(value);
else
    fail('Dataset assignments must be a table or structure array.');
end
required={'externalRealizationId','split','experimentRole'};
if ~all(ismember(required,source.Properties.VariableNames))||isempty(source)
    fail('Dataset assignments need explicit ID, split, and experiment role.');
end
ids=double(source.externalRealizationId(:)); splits=string(source.split(:)); roles=string(source.experimentRole(:));
if numel(ids)~=height(source)||any(~isfinite(ids)|ids<0|ids>=4000|ids~=fix(ids))|| ...
        numel(unique(ids))~=numel(ids)||any(strlength(splits)==0)||any(strlength(roles)==0)
    fail('Dataset assignments contain invalid or duplicate IDs.');
end
assignments=struct('id',num2cell(ids),'split',cellstr(splits),'role',cellstr(roles));
assignments=reshape(assignments,1,[]);
end

function ids=normalizeIds(value,label,allowEmpty)
if ~isnumeric(value)||~isreal(value)||(~isvector(value)&&~isempty(value))
    fail('%s must be a numeric vector.',label);
end
if isempty(value)
    if allowEmpty, ids=[]; return; end
    fail('%s cannot be empty.',label);
end
ids=double(value(:).');
if any(~isfinite(ids)|ids<0|ids>=4000|ids~=fix(ids))||numel(unique(ids))~=numel(ids)
    fail('%s must contain unique integer IDs in 0:3999.',label);
end
ids=sort(ids);
end

function values=normalizeTextList(value,label)
try
    if ischar(value)&&size(value,1)==1
        values={value};
    elseif isstring(value)
        values=cellstr(value(:));
    elseif iscell(value)
        values=cellstr(string(value(:)));
    else
        fail('%s must be a text list.',label);
    end
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelFreeze'), rethrow(exception); end
    fail('%s must be a text list.',label);
end
values=reshape(values,1,[]);
if isempty(values)||any(cellfun(@(item) isempty(strtrim(item)),values))
    fail('%s cannot be empty.',label);
end
end

function path=canonicalPath(value,label,mustExist)
value=textValue(value,label);
try
    path=char(java.io.File(value).getCanonicalPath());
catch
    fail('%s is not a valid path.',label);
end
if mustExist
    if strcmp(label,'selectionFolder')
        if ~isfolder(path), fail('%s does not exist.',label); end
    elseif ~isfile(path)
        fail('%s does not exist.',label);
    end
end
end

function value=textValue(input,label)
if isstring(input)&&isscalar(input), input=char(input); end
if ~ischar(input)||size(input,1)~=1||isempty(strtrim(input))
    fail('%s must be nonempty scalar text.',label);
end
value=strtrim(input);
end

function path=fileName(value)
[~,name,extension]=fileparts(value); path=[name extension];
end

function tf=isBasename(value)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||isempty(value), tf=false; return; end
[folder,name,extension]=fileparts(value);
tf=isempty(folder)&&~isempty(name)&&strcmp([name extension],value)&& ...
    ~contains(value,'/')&&~contains(value,'\')&&~strcmp(value,'.')&&~strcmp(value,'..');
end

function tf=isSha256(value)
try, value=char(string(value)); catch, tf=false; return; end
tf=~isempty(regexp(value,'^[0-9a-fA-F]{64}$','once'));
end

function tf=isPositiveInteger(value)
tf=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>0&&value==fix(value);
end

function tf=isProbability(value)
tf=isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>=0&&value<=1;
end

function tf=validIncreasing(values)
tf=isnumeric(values)&&isreal(values)&&isvector(values)&&~isempty(values)&& ...
    all(isfinite(values(:)))&&all(values(:)>0)&&all(diff(double(values(:)))>0);
end

function tf=validLevels(values,expectedCount,direction)
tf=isnumeric(values)&&isreal(values)&&isvector(values)&&numel(values)==expectedCount&& ...
    all(isfinite(values(:)))&&all(values(:)>=0&values(:)<=1);
if tf
    differences=diff(double(values(:)));
    if strcmp(direction,'descending'), tf=all(differences<=0); else, tf=all(differences>=0); end
end
end

function timestamp=parseUtc(value,label)
value=textValue(value,label);
formats={"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'","yyyy-MM-dd'T'HH:mm:ss'Z'"};
timestamp=NaT('TimeZone','UTC');
for k=1:numel(formats)
    try
        timestamp=datetime(value,'InputFormat',formats{k},'TimeZone','UTC');
        if ~isnat(timestamp), return; end
    catch
    end
end
fail('%s must be an ISO-8601 UTC timestamp.',label);
end

function text=utcNow()
text=char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"));
end

function writeAtomicJson(path,value)
folder=fileparts(path);
temporary=fullfile(folder,['.freeze-' char(java.util.UUID.randomUUID()) '.tmp']);
try
    fid=fopen(temporary,'w','n','UTF-8');
    if fid<0, fail('Cannot create temporary freeze file.'); end
    closeFile=onCleanup(@() fclose(fid));
    bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
    if fwrite(fid,bytes,'uint8')~=numel(bytes), fail('Cannot write complete freeze JSON.'); end
    clear closeFile
    saved=jsondecode(fileread(temporary));
    if ~isstruct(saved)||~isfield(saved,'schemaVersion')|| ...
            ~strcmp(saved.schemaVersion,'load-model-freeze-v1')
        fail('Temporary freeze JSON did not pass readback.');
    end
    if isfile(path), fail('outputFile appeared during freeze; it was not overwritten.'); end
    [ok,message]=movefile(temporary,path);
    if ~ok, fail('Cannot atomically publish freeze JSON: %s.',message); end
catch exception
    if isfile(temporary), delete(temporary); end
    rethrow(exception);
end
if isfile(temporary), delete(temporary); end
end

function value=readJson(path,label)
try
    value=jsondecode(fileread(path));
catch exception
    error('nbiot:ml:ModelFreeze','Cannot read %s: %s',label,exception.message);
end
end

function tf=samePath(first,second)
tf=strcmpi(char(java.io.File(first).getCanonicalPath()), ...
    char(java.io.File(second).getCanonicalPath()));
end

function tf=isWithin(path,parent)
path=char(java.io.File(path).getCanonicalPath());
parent=char(java.io.File(parent).getCanonicalPath());
prefix=[parent filesep];
tf=strcmpi(path,parent)||startsWith(path,prefix,'IgnoreCase',true);
end

function fail(message,varargin)
error('nbiot:ml:ModelFreeze',message,varargin{:});
end
