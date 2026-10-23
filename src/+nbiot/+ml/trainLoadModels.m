function [bundles,report]=trainLoadModels(data,options)
%TRAINLOADMODELS Fit four fixed load regressors using ID-separated groups.
if nargin<2||isempty(options), options=mlTrainingDefaults(); end
options=validatedOptions(options);
[x,y,ids,groups,schema,kind,allocationsVerified]=validateTrainingData(data);
selectionOnly=strcmp(options.evaluationMode,'selection-only');
if selectionOnly, phase='selection'; else, phase='evaluated'; end
if strcmp(kind,'candidate-training')&&~selectionOnly
    error('nbiot:ml:EvaluationMode', ...
        'Candidate training requires the explicit selection-only evaluation mode.');
end
provenance=validateDatasetProvenance(data,options.datasetFile,kind,groups,ids,allocationsVerified);
allocationsVerified=provenance.allocationsVerified;
requireStatisticsToolbox();
outputFolder=prepareOutputFolder(options.outputFolder);

trainMask=groups=="train";
validationMask=groups=="validation";
testMask=groups=="test";
trainX=x(trainMask,:); trainY=y(trainMask);
medians=median(trainX,1,'omitnan');
if any(~isfinite(medians))
    error('nbiot:ml:TrainingFeatureMissing', ...
        'A feature is missing in every training row; it cannot be imputed safely.');
end
trainImputed=imputeFeatures(trainX,medians);
featureMean=mean(trainImputed,1);
featureScale=std(trainImputed,0,1);
featureScale(~isfinite(featureScale)|featureScale<=eps)=1;
transform=struct('median',medians,'mean',featureMean,'scale',featureScale, ...
    'method','training-median imputation then training-only z-score');
scoreMask=true(size(groups));
if selectionOnly, scoreMask=groups~="test"; end
scoreFeatures=normalizeFeatures(x(scoreMask,:),transform);
scoreTargets=y(scoreMask); scoreIds=ids(scoreMask); scoreGroups=groups(scoreMask);
trainScoreMask=scoreGroups=="train";

modelNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
bundleTemplate=struct('name','','bundle',struct(),'file','','sha256','','manifestFile','');
bundles=repmat(bundleTemplate,1,numel(modelNames));
metricRows=cell(0,9); validationMae=nan(1,numel(modelNames)); trainingSeconds=zeros(1,numel(modelNames));
oldRng=rng; restoreRng=onCleanup(@() rng(oldRng));
rng(options.seed,'twister');

for modelIndex=1:numel(modelNames)
    modelName=modelNames{modelIndex}; started=tic;
    model=fitOne(modelName,scoreFeatures(trainScoreMask,:), ...
        scoreTargets(trainScoreMask),options);
    trainingSeconds(modelIndex)=toc(started);
    package=struct();
    package.formatVersion='load-model-bundle-v1';
    package.modelName=modelName; package.model=model;
    package.schemaVersion=schema.version;
    package.featureNames=schema.inputNames;
    package.keyNames=schema.keyNames;
    package.targetName='meanRaUe';
    package.transform=transform;
    package.trainingIds=unique(ids(trainMask)).';
    package.validationIds=unique(ids(validationMask)).';
    package.testIds=unique(ids(testMask)).';
    package.seed=options.seed;
    package.status='development';
    package.dataKind=kind;
    package.allocationsVerified=allocationsVerified;
    package.modelClass=class(model);
    package.modelOptions=modelOptions(modelName,options);
    package.matlabRelease=version('-release');
    package.toolboxVersion=toolboxVersion();

    bundles(modelIndex).name=modelName;
    bundles(modelIndex).bundle=package;
    if ~isempty(outputFolder)
        [artifact,sidecar,digest]=writePackage(package,outputFolder);
        bundles(modelIndex).file=artifact;
        bundles(modelIndex).manifestFile=sidecar;
        bundles(modelIndex).sha256=digest;
    end

    scoreSplits={'train','validation'};
    if ~selectionOnly, scoreSplits{end+1}='test'; end
    for splitIndex=1:numel(scoreSplits)
        splitName=scoreSplits{splitIndex}; mask=scoreGroups==splitName;
        [row,mae]=score(modelName,splitName,model,scoreFeatures(mask,:), ...
            scoreTargets(mask),scoreIds(mask),trainingSeconds(modelIndex));
        metricRows(end+1,:)=row; %#ok<AGROW>
        if splitIndex==2, validationMae(modelIndex)=mae; end
    end
end

baseline=mean(trainY);
scoreSplits={'train','validation'};
if ~selectionOnly, scoreSplits{end+1}='test'; end
for splitIndex=1:numel(scoreSplits)
    splitName=scoreSplits{splitIndex}; mask=scoreGroups==splitName;
    [row,~]=score('trainMean',splitName,[],scoreFeatures(mask,:), ...
        scoreTargets(mask),scoreIds(mask),0,baseline);
    metricRows(end+1,:)=row; %#ok<AGROW>
end
metrics=cell2table(metricRows,'VariableNames', ...
    {'model','split','sampleCount','idCount','mae','rmse','bias','predictionSeconds','trainingSeconds'});
[~,bestIndex]=min(validationMae);
report=struct('metrics',metrics,'bestValidationModel',modelNames{bestIndex}, ...
    'baselineValue',baseline,'seed',options.seed, ...
    'evaluationMode',options.evaluationMode, ...
    'phase',phase, ...
    'dataKind',kind, ...
    'allocationsVerified',allocationsVerified,'schemaVersion',schema.version, ...
    'targetName','meanRaUe','trainingIds',unique(ids(trainMask)).', ...
    'validationIds',unique(ids(validationMask)).','testIds',unique(ids(testMask)).', ...
    'selectionRule','lowest validation MAE; test results are not used for selection', ...
    'status','development','datasetFile',provenance.datasetFile, ...
    'datasetSha256',provenance.datasetSha256, ...
    'datasetManifestFile','dataset-manifest.json', ...
    'datasetManifestSha256',provenance.datasetManifestSha256, ...
    'sourceSha256',provenance.sourceSha256, ...
    'calibrationSha256',provenance.calibrationSha256, ...
    'splitEvidence',provenance.splitEvidence);
if ~isempty(outputFolder), writeTrainingReport(report,bundles,outputFolder,provenance); end
end

function options=validatedOptions(value)
defaults=mlTrainingDefaults();
if ~isstruct(value)||~isscalar(value), error('nbiot:ml:Options','Training options must be a scalar structure.'); end
unknown=setdiff(fieldnames(value),fieldnames(defaults));
if ~isempty(unknown), error('nbiot:ml:Options','Unsupported option: %s',unknown{1}); end
options=defaults;
names=fieldnames(value);
for k=1:numel(names), options.(names{k})=value.(names{k}); end
mode=options.evaluationMode;
if isstring(mode)&&isscalar(mode)
    mode=char(mode);
elseif ~(ischar(mode)&&size(mode,1)==1)
    error('nbiot:ml:Options', ...
        'evaluationMode must be development-all-splits or selection-only.');
end
if ~any(strcmp(mode,{'development-all-splits','selection-only'}))
    error('nbiot:ml:Options', ...
        'evaluationMode must be development-all-splits or selection-only.');
end
options.evaluationMode=mode;
integerFields={'seed','treeMaxNumSplits','treeMinLeafSize','forestNumTrees', ...
    'forestMinLeafSize','boostNumLearningCycles','boostMaxNumSplits'};
for k=1:numel(integerFields)
    field=integerFields{k}; number=options.(field);
    if ~isnumeric(number)||~isscalar(number)||~isreal(number)||~isfinite(number)|| ...
            number<1||number~=fix(number)
        error('nbiot:ml:Options','%s must be a positive integer.',field);
    end
end
if options.seed>4294967295
    error('nbiot:ml:Options','Seed must be in 0:4294967295.');
end
rate=options.boostLearnRate;
if ~isnumeric(rate)||~isscalar(rate)||~isreal(rate)||~isfinite(rate)||rate<=0||rate>1
    error('nbiot:ml:Options','boostLearnRate must be greater than zero and no greater than one.');
end
folder=options.outputFolder;
if isstring(folder)&&isscalar(folder), folder=char(folder); end
if ~ischar(folder)||(~isempty(folder)&&isempty(strtrim(folder)))
    error('nbiot:ml:Options','outputFolder must be empty or a non-empty path.');
end
options.outputFolder=folder;
datasetFile=options.datasetFile;
if isstring(datasetFile)&&isscalar(datasetFile), datasetFile=char(datasetFile); end
if ~ischar(datasetFile)||(~isempty(datasetFile)&&size(datasetFile,1)~=1)|| ...
        (~isempty(datasetFile)&&isempty(strtrim(datasetFile)))
    error('nbiot:ml:Options','datasetFile must be empty or one explicit path.');
end
options.datasetFile=datasetFile;
end

function requireStatisticsToolbox()
if isempty(ver('stats'))||~license('test','Statistics_Toolbox')
    error('nbiot:ml:ToolboxUnavailable', ...
        'Statistics and Machine Learning Toolbox and its license are required for training.');
end
required={'fitlm','fitrtree','TreeBagger','fitrensemble'};
for k=1:numel(required)
    if isempty(which(required{k}))
        error('nbiot:ml:ToolboxUnavailable','Required training function %s is unavailable.',required{k});
    end
end
end

function [x,y,ids,groups,schema,kind,allocationsVerified]=validateTrainingData(data)
required={'features','targets','rowInfo','schema','manifest'};
if ~isstruct(data)||~isscalar(data)||~all(isfield(data,required))
    error('nbiot:ml:Data','Training data is missing required tables or metadata.');
end
schema=canonicalTrainingSchema(data.schema);
if ~istable(data.features)|| ...
        ~isequal(normalizeNames(data.features.Properties.VariableNames),schema.inputNames)
    error('nbiot:ml:FeatureSchema','Feature columns must exactly match the ordered schema whitelist.');
end
if ~istable(data.targets)||~ismember('meanRaUe',data.targets.Properties.VariableNames)|| ...
        ~istable(data.rowInfo)||~all(ismember({'realizationId','split'},data.rowInfo.Properties.VariableNames))
    error('nbiot:ml:Data','Targets and rowInfo need meanRaUe, realizationId and split columns.');
end
rowCount=height(data.features);
if rowCount<3||height(data.targets)~=rowCount||height(data.rowInfo)~=rowCount
    error('nbiot:ml:Data','Features, targets and rowInfo must have the same nontrivial row count.');
end
x=data.features{:,:}; y=data.targets.meanRaUe;
ids=data.rowInfo.realizationId; groups=string(data.rowInfo.split);
if ~isnumeric(x)||~isnumeric(y)||~isnumeric(ids)||~iscolumn(y)||~iscolumn(ids)|| ...
        any(isinf(x),'all')||any(~isfinite(y))||any(~isfinite(ids))
    error('nbiot:ml:Data','Features may contain NaN, but targets and realization IDs must be finite numeric values.');
end
if any(y<0)||any(ids<0|ids>=4000)||any(ids~=fix(ids))||numel(groups)~=rowCount
    error('nbiot:ml:Data','Targets must be nonnegative and realization IDs must be integers in 0:3999.');
end
if any(~ismember(groups,["train","validation","test"]))
    error('nbiot:ml:Split','Use only train, validation and test groups for model training.');
end
uniqueIds=unique(ids);
for k=1:numel(uniqueIds)
    if numel(unique(groups(ids==uniqueIds(k))))~=1
        error('nbiot:ml:GroupLeakage','Each realization ID must belong to only one split.');
    end
end
for group=["train","validation","test"]
    if ~any(groups==group), error('nbiot:ml:Split','The %s group must contain at least one row.',group); end
end
if ~isstruct(data.manifest)||~isfield(data.manifest,'kind')
    error('nbiot:ml:DataPurpose','Dataset purpose is required.');
end
kind=char(string(data.manifest.kind));
allocationsVerified=isfield(data.manifest,'allocationsVerified')&& ...
    isequal(data.manifest.allocationsVerified,true);
if ismember('experimentRole',data.rowInfo.Properties.VariableNames) && ...
        any(string(data.rowInfo.experimentRole)=="final-comparison")
    error('nbiot:ml:FinalComparison', ...
        'Final comparison realizations must never enter model training or model evaluation.');
end
if strcmp(kind,'candidate-training')
    if ~allocationsVerified
        error('nbiot:ml:DataPurpose','Candidate training data must have verified allocation roles.');
    end
    validateCandidateRoles(data,groups,ids);
elseif ~strcmp(kind,'development-fixture')
    error('nbiot:ml:DataPurpose', ...
        'Only verified candidate data or explicitly marked development fixtures can train models.');
end
end

function schema=canonicalTrainingSchema(asserted)
if ~isstruct(asserted)||~isscalar(asserted)|| ...
        ~all(isfield(asserted,{'version','keyNames','inputNames','targetName'}))
    error('nbiot:ml:FeatureSchema','Training schema must declare version, keys, inputs and target.');
end
try
    version=char(string(asserted.version));
    canonical=nbiot.dataset.featureSchema(version);
catch
    error('nbiot:ml:FeatureSchema','Training requires a supported canonical feature schema.');
end
if ~strcmp(version,'bs-known-v2.0')|| ...
        ~isequal(normalizeNames(asserted.keyNames),canonical.keyNames)|| ...
        ~isequal(normalizeNames(asserted.inputNames),canonical.inputNames)|| ...
        ~strcmp(char(string(asserted.targetName)),'meanRaUe')
    error('nbiot:ml:FeatureSchema','Training metadata does not match the canonical feature whitelist.');
end
schema=canonical;
end

function names=normalizeNames(value)
try
    names=cellstr(string(value));
    names=reshape(names,1,[]);
catch
    error('nbiot:ml:FeatureSchema','Feature names must be a sequence of scalar text values.');
end
if any(cellfun(@(name) isempty(name)||size(name,1)~=1,names))
    error('nbiot:ml:FeatureSchema','Feature names must be non-empty scalar text values.');
end
end

function provenance=validateDatasetProvenance(data,datasetFile,kind,groups,ids,flag)
provenance=struct('datasetFile','','datasetSha256','', ...
    'datasetManifestSourcePath','','datasetManifestSha256','', ...
    'sourceSha256','','calibrationSha256','', ...
    'allocationsVerified',false,'splitEvidence',makeSplitEvidence(data.rowInfo));
validateAssignmentsAgainstRows(data,groups,ids,kind);
inputs=[];
if isfield(data.manifest,'inputs'), inputs=data.manifest.inputs; end
[sourceHash,calibrationHash,allReal]=summarizeInputs(inputs);
inputsMatchRows=validateInputsMatchRows(inputs,data.rowInfo);

if ~isempty(datasetFile)
    if ~isfile(datasetFile)
        error('nbiot:ml:DataProvenance','The selected datasetFile does not exist.');
    end
    datasetFile=char(java.io.File(datasetFile).getCanonicalPath());
    variables=whos('-file',datasetFile);
    if ~any(strcmp({variables.name},'data'))
        error('nbiot:ml:DataProvenance','datasetFile must contain the exact data variable.');
    end
    loaded=load(datasetFile,'data');
    if ~isequaln(loaded.data,data)
        error('nbiot:ml:DataProvenance','In-memory training data differs from the selected dataset bytes.');
    end
    [~,base,extension]=fileparts(datasetFile);
    provenance.datasetFile=[base extension];
    provenance.datasetSha256=nbiot.ml.fileSha256(datasetFile);
    sourceManifest=fullfile(fileparts(datasetFile),'manifest.json');
    if isfile(sourceManifest)
        source=jsondecode(fileread(sourceManifest));
        validateDatasetManifestMatches(source,data,kind);
        provenance.datasetManifestSourcePath=sourceManifest;
        provenance.datasetManifestSha256=nbiot.ml.fileSha256(sourceManifest);
        provenance.sourceSha256=sourceHash;
        provenance.calibrationSha256=calibrationHash;
    elseif strcmp(kind,'candidate-training')
        error('nbiot:ml:DataProvenance', ...
            'Candidate training requires the original dataset manifest beside datasetFile.');
    end
end

if strcmp(kind,'candidate-training')
    if isempty(datasetFile)||isempty(provenance.datasetManifestSourcePath)|| ...
            ~isequal(flag,true)||~isfield(data.manifest,'allocationsVerified')|| ...
            ~isequal(data.manifest.allocationsVerified,true)|| ...
            ~isfield(data.manifest,'experimentRolesExplicit')|| ...
            ~isequal(data.manifest.experimentRolesExplicit,true)||~allReal|| ...
            isempty(sourceHash)||isempty(calibrationHash)||~inputsMatchRows
        error('nbiot:ml:DataProvenance', ...
            'Candidate training requires persisted, role-verified non-fixture data and its original manifest.');
    end
    provenance.allocationsVerified=true;
end
end

function validateAssignmentsAgainstRows(data,groups,ids,kind)
if ~isfield(data.manifest,'assignments')
    if strcmp(kind,'candidate-training')
        error('nbiot:ml:DataProvenance','Candidate data requires explicit assignments.');
    end
    return;
end
assignments=data.manifest.assignments;
required={'externalRealizationId','split'};
if ~istable(assignments)||~all(ismember(required,assignments.Properties.VariableNames))
    error('nbiot:ml:DataProvenance','Dataset assignments are malformed.');
end
assignmentIds=double(assignments.externalRealizationId(:));
assignmentSplits=string(assignments.split(:));
usedIds=unique(double(ids(:)));
if numel(unique(assignmentIds))~=numel(assignmentIds)|| ...
        any(~isfinite(assignmentIds)|assignmentIds<0|assignmentIds>=4000|assignmentIds~=fix(assignmentIds))|| ...
        ~isequal(sort(assignmentIds),sort(usedIds))||numel(assignmentSplits)~=numel(assignmentIds)
    error('nbiot:ml:DataProvenance', ...
        'Dataset assignment IDs must equal the IDs represented in training rows exactly.');
end
for k=1:numel(assignmentIds)
    at=ids==assignmentIds(k);
    if numel(unique(groups(at)))~=1||assignmentSplits(k)~=unique(groups(at))
        error('nbiot:ml:DataProvenance','Dataset assignment split does not match the training rows.');
    end
end
if ismember('experimentRole',assignments.Properties.VariableNames)&& ...
        ismember('experimentRole',data.rowInfo.Properties.VariableNames)
    roles=string(assignments.experimentRole);
    rowRoles=string(data.rowInfo.experimentRole);
    for k=1:numel(assignmentIds)
        at=ids==assignmentIds(k);
        if numel(unique(rowRoles(at)))~=1||roles(k)~=unique(rowRoles(at))
            error('nbiot:ml:DataProvenance','Dataset assignment role does not match the training rows.');
        end
    end
elseif strcmp(kind,'candidate-training')
    error('nbiot:ml:DataProvenance','Candidate assignments must preserve experiment roles.');
end
end

function validateDatasetManifestMatches(source,data,kind)
if ~isstruct(source)||~isscalar(source)|| ...
        ~all(isfield(source,{'kind','assignments','inputs','allocationsVerified', ...
            'experimentRolesExplicit'}))|| ...
        ~strcmp(char(string(source.kind)),kind)
    error('nbiot:ml:DataProvenance','Original dataset manifest does not match dataset purpose.');
end
sourceAssignments=normalizeAssignments(source.assignments);
dataAssignments=normalizeAssignments(data.manifest.assignments);
if isempty(sourceAssignments)||~isequal(sourceAssignments,dataAssignments)
    error('nbiot:ml:DataProvenance','Original dataset assignments differ from the loaded data.');
end
if ~isfield(data.manifest,'inputs')|| ...
        ~isequaln(jsondecode(jsonencode(source.inputs)), ...
        jsondecode(jsonencode(data.manifest.inputs)))
    error('nbiot:ml:DataProvenance','Original dataset inputs differ from the loaded data.');
end
expectedAllocations=isfield(data.manifest,'allocationsVerified')&& ...
    isequal(data.manifest.allocationsVerified,true);
expectedRoles=isfield(data.manifest,'experimentRolesExplicit')&& ...
    isequal(data.manifest.experimentRolesExplicit,true);
if ~isequal(source.allocationsVerified,expectedAllocations)|| ...
        ~isequal(source.experimentRolesExplicit,expectedRoles)
    error('nbiot:ml:DataProvenance','Original allocation evidence differs from the loaded data.');
end
end

function assignments=normalizeAssignments(value)
assignments=table();
try
    if istable(value)
        source=value;
    elseif isstruct(value)&&all(isfield(value,{'externalRealizationId','split','experimentRole'}))
        source=struct2table(value);
    else
        return;
    end
    if ismember('experimentRole',source.Properties.VariableNames)
        roles=string(source.experimentRole(:));
    else
        roles=repmat("",height(source),1);
    end
    assignments=table(double(source.externalRealizationId(:)),string(source.split(:)), ...
        roles,'VariableNames',{'externalRealizationId','split','experimentRole'});
    assignments=sortrows(assignments,'externalRealizationId');
catch
    assignments=table();
end
end

function [sourceHash,calibrationHash,allReal]=summarizeInputs(inputs)
sourceHash=''; calibrationHash=''; allReal=false;
if isempty(inputs), return; end
required={'sourceSha256','calibrationSha256','isFixture'};
if ~isstruct(inputs)||~all(isfield(inputs,required)), return; end
source=string({inputs.sourceSha256}); calibration=string({inputs.calibrationSha256});
fixtures=[inputs.isFixture];
if any(~cellfun(@isSha256,cellstr(source)))|| ...
        any(~cellfun(@isSha256,cellstr(calibration)))|| ...
        numel(unique(source))~=1||numel(unique(calibration))~=1
    return;
end
sourceHash=char(source(1)); calibrationHash=char(calibration(1)); allReal=~any(fixtures);
end

function valid=isSha256(value)
valid=ischar(value)&&numel(value)==64&&all(ismember(lower(value),'0123456789abcdef'));
end

function valid=validateInputsMatchRows(inputs,rowInfo)
valid=false;
if ~isstruct(inputs)||isempty(inputs)|| ...
        ~all(isfield(inputs,{'caseKey','realizationId'}))|| ...
        ~istable(rowInfo)||~all(ismember({'caseKey','realizationId'}, ...
            rowInfo.Properties.VariableNames))
    return;
end
inputIds=double([inputs.realizationId]);
inputKeys=string({inputs.caseKey});
rowKeys=string(rowInfo.caseKey);
expectedKeys=unique(rowKeys);
if numel(unique(inputKeys))~=numel(inputKeys)|| ...
        ~isequal(sort(inputKeys(:).'),sort(expectedKeys(:).'))|| ...
        any(~isfinite(inputIds)|inputIds<0|inputIds>=4000|inputIds~=fix(inputIds))
    return;
end
expectedIds=zeros(size(expectedKeys));
for k=1:numel(expectedKeys)
    at=rowKeys==expectedKeys(k);
    ids=unique(double(rowInfo.realizationId(at)));
    inputAt=find(inputKeys==expectedKeys(k),1);
    if numel(ids)~=1||inputIds(inputAt)~=ids
        return;
    end
    expectedIds(k)=ids;
end
valid=isequal(sort(unique(inputIds(:))),sort(unique(expectedIds(:))));
end

function evidence=makeSplitEvidence(rowInfo)
splits={'train','validation','test'};
evidence=repmat(struct('split','','ids',[],'sampleCount',0,'idCount',0),1,3);
for k=1:3
    mask=string(rowInfo.split)==splits{k};
    values=sort(unique(double(rowInfo.realizationId(mask))));
    evidence(k)=struct('split',splits{k},'ids',values(:).', ...
        'sampleCount',sum(mask),'idCount',numel(values));
end
end

function validateCandidateRoles(data,groups,ids)
if ~isfield(data.manifest,'experimentRolesExplicit')|| ...
        ~isequal(data.manifest.experimentRolesExplicit,true)|| ...
        ~ismember('experimentRole',data.rowInfo.Properties.VariableNames)
    error('nbiot:ml:RoleManifest', ...
        'Candidate training data requires explicit experiment roles for every row.');
end
roles=string(data.rowInfo.experimentRole);
if ~iscolumn(roles)||numel(roles)~=numel(groups)|| ...
        any(~ismember(roles,["training","validation","model-test"]))
    error('nbiot:ml:RoleManifest','Candidate training data contains an unsupported experiment role.');
end
expected=groups;
expected(groups=="train")="training";
expected(groups=="test")="model-test";
if any(roles~=expected)
    error('nbiot:ml:RoleManifest','Experiment roles do not match the train/validation/test groups.');
end

if ~isfield(data.manifest,'assignments')||~istable(data.manifest.assignments)|| ...
        ~all(ismember({'externalRealizationId','split','experimentRole'}, ...
            data.manifest.assignments.Properties.VariableNames))
    error('nbiot:ml:RoleManifest','Candidate dataset manifest must preserve explicit ID roles.');
end
assignments=data.manifest.assignments;
assignmentIds=assignments.externalRealizationId;
assignmentSplits=string(assignments.split);
assignmentRoles=string(assignments.experimentRole);
if ~isnumeric(assignmentIds)||~iscolumn(assignmentIds)|| ...
        numel(unique(assignmentIds))~=numel(assignmentIds)|| ...
        numel(assignmentSplits)~=numel(assignmentIds)|| ...
        numel(assignmentRoles)~=numel(assignmentIds)
    error('nbiot:ml:RoleManifest','Candidate dataset ID assignments are malformed.');
end
uniqueIds=unique(ids);
for idIndex=1:numel(uniqueIds)
    at=find(assignmentIds==uniqueIds(idIndex));
    rowAt=ids==uniqueIds(idIndex);
    if numel(at)~=1||numel(unique(groups(rowAt)))~=1|| ...
            assignmentSplits(at)~=unique(groups(rowAt))|| ...
            assignmentRoles(at)~=unique(roles(rowAt))
        error('nbiot:ml:RoleManifest','A row role does not match the declared ID assignment.');
    end
end
end

function folder=prepareOutputFolder(folder)
if isempty(folder), return; end
if isfile(folder), error('nbiot:ml:OutputFolder','Output path is already a file.'); end
if isfolder(folder)
    contents=dir(folder); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents)
        error('nbiot:ml:OutputFolder','Refusing to overwrite a non-empty model folder.');
    end
else
    [ok,message]=mkdir(folder);
    if ~ok, error('nbiot:ml:OutputFolder','Cannot create model folder: %s',message); end
end
end

function x=imputeFeatures(x,medians)
for column=1:size(x,2)
    missing=isnan(x(:,column));
    x(missing,column)=medians(column);
end
end

function normalized=normalizeFeatures(x,transform)
x=imputeFeatures(double(x),transform.median);
normalized=(x-transform.mean)./transform.scale;
end

function model=fitOne(name,x,y,options)
switch name
    case 'linearRegression'
        model=fitlm(x,y);
    case 'decisionTree'
        model=fitrtree(x,y,'MaxNumSplits',options.treeMaxNumSplits, ...
            'MinLeafSize',options.treeMinLeafSize);
    case 'randomForest'
        model=TreeBagger(options.forestNumTrees,x,y,'Method','regression', ...
            'MinLeafSize',options.forestMinLeafSize);
    case 'gradientBoosting'
        learner=templateTree('MaxNumSplits',options.boostMaxNumSplits, ...
            'MinLeafSize',options.treeMinLeafSize,'Reproducible',true);
        model=fitrensemble(x,y,'Method','LSBoost', ...
            'NumLearningCycles',options.boostNumLearningCycles, ...
            'LearnRate',options.boostLearnRate,'Learners',learner);
    otherwise
        error('nbiot:ml:ModelType','Unsupported load model: %s',name);
end
end

function parameters=modelOptions(name,options)
switch name
    case 'linearRegression'
        parameters=struct('fit','least-squares linear model');
    case 'decisionTree'
        parameters=struct('maxNumSplits',options.treeMaxNumSplits, ...
            'minLeafSize',options.treeMinLeafSize);
    case 'randomForest'
        parameters=struct('numTrees',options.forestNumTrees, ...
            'minLeafSize',options.forestMinLeafSize,'method','regression');
    otherwise
        parameters=struct('method','LSBoost', ...
            'numLearningCycles',options.boostNumLearningCycles, ...
            'learnRate',options.boostLearnRate,'maxNumSplits',options.boostMaxNumSplits, ...
            'minLeafSize',options.treeMinLeafSize);
end
end

function [row,mae]=score(modelName,splitName,model,x,y,ids,trainingSeconds,baseline)
if nargin<8
    started=tic; prediction=predict(model,x); predictionSeconds=toc(started);
else
    started=tic; prediction=repmat(baseline,numel(y),1); predictionSeconds=toc(started);
end
prediction=double(prediction(:)); errorValues=prediction-double(y(:));
mae=mean(abs(errorValues)); rmse=sqrt(mean(errorValues.^2)); bias=mean(errorValues);
row={string(modelName),string(splitName),double(numel(y)),double(numel(unique(ids))), ...
    mae,rmse,bias,predictionSeconds,trainingSeconds};
end

function [artifact,sidecar,digest]=writePackage(bundle,folder)
artifact=fullfile(folder,[bundle.modelName '.mat']);
sidecar=fullfile(folder,[bundle.modelName '.json']);
save(artifact,'bundle','-v7.3');
digest=nbiot.ml.fileSha256(artifact);
manifest=struct('formatVersion',bundle.formatVersion, ...
    'artifactFile',[bundle.modelName '.mat'],'artifactSha256',digest, ...
    'modelName',bundle.modelName,'schemaVersion',bundle.schemaVersion, ...
    'targetName',bundle.targetName,'featureNames',{bundle.featureNames}, ...
    'keyNames',{bundle.keyNames},'seed',bundle.seed,'status',bundle.status, ...
    'trainingIds',bundle.trainingIds,'validationIds',bundle.validationIds,'testIds',bundle.testIds, ...
    'dataKind',bundle.dataKind,'allocationsVerified',bundle.allocationsVerified);
writeJson(sidecar,manifest);
end

function writeTrainingReport(report,bundles,folder,provenance)
metricsPath=fullfile(folder,'metrics.csv');
writetable(report.metrics,metricsPath);
metricsHash=nbiot.ml.fileSha256(metricsPath);
if ~isempty(provenance.datasetManifestSourcePath)
    [copied,message]=copyfile(provenance.datasetManifestSourcePath, ...
        fullfile(folder,'dataset-manifest.json'));
    if ~copied
        error('nbiot:ml:OutputFolder','Cannot preserve dataset manifest: %s',message);
    end
end
names={bundles.name}; files={bundles.file}; hashes={bundles.sha256};
manifest=struct('formatVersion','load-training-report-v2','phase',report.phase, ...
    'dataKind',report.dataKind,'allocationsVerified',report.allocationsVerified, ...
    'status',report.status,'targetName',report.targetName,'schemaVersion',report.schemaVersion, ...
    'seed',report.seed,'bestValidationModel',report.bestValidationModel, ...
    'selectionRule',report.selectionRule,'modelNames',{names}, ...
    'artifactFiles',{cellfun(@localName,files,'UniformOutput',false)}, ...
    'artifactSha256',{hashes},'trainingIds',report.trainingIds, ...
    'validationIds',report.validationIds,'testIds',report.testIds, ...
    'metricsFile','metrics.csv','metricsSha256',metricsHash, ...
    'metricsRowCount',height(report.metrics),'splitEvidence',report.splitEvidence, ...
    'datasetFile',report.datasetFile,'datasetSha256',report.datasetSha256, ...
    'datasetManifestFile',report.datasetManifestFile, ...
    'datasetManifestSha256',report.datasetManifestSha256, ...
    'sourceSha256',report.sourceSha256,'calibrationSha256',report.calibrationSha256);
writeJson(fullfile(folder,'training-manifest.json'),manifest);
save(fullfile(folder,'training-report.mat'),'report','-v7.3');
end

function name=localName(path)
if isempty(path), name=''; else, [~,base,extension]=fileparts(path); name=[base extension]; end
end

function writeJson(file,value)
fid=fopen(file,'w','n','UTF-8');
if fid<0, error('nbiot:ml:OutputFolder','Cannot write model metadata.'); end
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end

function value=toolboxVersion()
products=ver('stats');
if isempty(products), value='unavailable'; else, value=products(1).Version; end
end
