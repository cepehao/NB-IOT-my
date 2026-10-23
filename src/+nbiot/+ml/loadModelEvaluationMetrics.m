function metrics=loadModelEvaluationMetrics(modelFile,bundle)
%LOADMODELEVALUATIONMETRICS Read only complete, hash-bound evaluation evidence.
metrics=emptyMetrics();
if ~(ischar(modelFile)||(isstring(modelFile)&&isscalar(modelFile)))|| ...
        ~isstruct(bundle)||~isscalar(bundle)|| ...
        ~all(isfield(bundle,{'modelName','trainingIds','validationIds','testIds'}))
    return;
end
modelFile=char(string(modelFile));
[folder,base,extension]=fileparts(modelFile);
manifestFile=fullfile(folder,'training-manifest.json');
if ~isfile(modelFile)||~strcmpi(extension,'.mat')||~isfile(manifestFile), return; end
try
    manifest=jsondecode(fileread(manifestFile));
    if ~isstruct(manifest)||~isscalar(manifest)|| ...
            ~all(isfield(manifest,{'formatVersion','phase','dataKind','allocationsVerified', ...
            'modelNames','artifactFiles','artifactSha256','trainingIds','validationIds', ...
            'testIds','splitEvidence','metricsFile','metricsSha256','metricsRowCount', ...
            'datasetFile','datasetSha256','datasetManifestFile','datasetManifestSha256', ...
            'sourceSha256','calibrationSha256'}))|| ...
            ~strcmp(char(string(manifest.formatVersion)),'load-training-report-v2')
        return;
    end
    phaseValue=manifest.phase;
    if (isstring(phaseValue)&&isscalar(phaseValue))|| ...
            (ischar(phaseValue)&&size(phaseValue,1)==1)
        phase=char(string(phaseValue));
    else
        return;
    end
    if ~any(strcmp(phase,{'selection','evaluated'})), return; end
    if ~ismember(char(string(manifest.dataKind)),{'development-fixture','candidate-training'})|| ...
            ~islogical(manifest.allocationsVerified)||~isscalar(manifest.allocationsVerified)
        return;
    end
    if (isfield(bundle,'dataKind')&& ...
            ~strcmp(char(string(bundle.dataKind)),char(string(manifest.dataKind))))|| ...
            (isfield(bundle,'allocationsVerified')&& ...
            ~isequal(bundle.allocationsVerified,manifest.allocationsVerified))
        return;
    end

    modelNames=normalizeTextList(manifest.modelNames);
    artifactFiles=normalizeTextList(manifest.artifactFiles);
    artifactHashes=normalizeTextList(manifest.artifactSha256);
    expectedModelNames=["linearRegression";"decisionTree"; ...
        "randomForest";"gradientBoosting"];
    if ~isequal(modelNames,expectedModelNames)|| ...
            numel(unique(modelNames))~=numel(modelNames)|| ...
            any(modelNames=="trainMean")||numel(artifactFiles)~=numel(modelNames)|| ...
            numel(artifactHashes)~=numel(modelNames)|| ...
            numel(unique(artifactFiles))~=numel(artifactFiles)|| ...
            any(~cellfun(@isBasename,cellstr(artifactFiles)))|| ...
            any(~cellfun(@isSha256,cellstr(artifactHashes)))
        return;
    end
    artifact=[base extension];
    selected=find(modelNames==string(bundle.modelName)&artifactFiles==string(artifact));
    if numel(selected)~=1||~strcmpi(artifactHashes(selected), ...
            string(nbiot.ml.fileSha256(modelFile)))
        return;
    end

    if ~validateIdSet(manifest.trainingIds)||~validateIdSet(manifest.validationIds)|| ...
            ~validateIdSet(manifest.testIds)|| ...
            ~sameIds(manifest.trainingIds,bundle.trainingIds)|| ...
            ~sameIds(manifest.validationIds,bundle.validationIds)|| ...
            ~sameIds(manifest.testIds,bundle.testIds)
        return;
    end
    evidence=normalizeSplitEvidence(manifest.splitEvidence);
    if ~validSplitEvidence(evidence,manifest)|| ...
            ~validateDataManifest(folder,manifest,evidence)
        return;
    end

    metricsPath=fullfile(folder,char(string(manifest.metricsFile)));
    if ~isBasename(string(manifest.metricsFile))|| ...
            ~strcmp(char(string(manifest.metricsFile)),'metrics.csv')||~isfile(metricsPath)|| ...
            ~isSha256(char(string(manifest.metricsSha256)))|| ...
            ~strcmpi(char(string(manifest.metricsSha256)),nbiot.ml.fileSha256(metricsPath))
        return;
    end
    source=readtable(metricsPath,'TextType','string');
    required={'model','split','sampleCount','idCount','mae','rmse'};
    if ~all(ismember(required,source.Properties.VariableNames))|| ...
            ~isscalar(manifest.metricsRowCount)||~isnumeric(manifest.metricsRowCount)|| ...
            ~isfinite(manifest.metricsRowCount)||manifest.metricsRowCount<1|| ...
            manifest.metricsRowCount~=fix(manifest.metricsRowCount)|| ...
            height(source)~=manifest.metricsRowCount|| ...
            ~validateAllScoreRows(source,modelNames,evidence,phase)
        return;
    end
    if strcmp(phase,'selection'), return; end
    selectedRows=string(source.model)==string(bundle.modelName);
    modelMetrics=source(selectedRows,required(2:end));
    splitValues=string(modelMetrics.split);
    if height(modelMetrics)~=3|| ...
            ~isequal(sort(splitValues),sort(["train";"validation";"test"]))
        return;
    end
    order=[find(splitValues=="train",1);find(splitValues=="validation",1); ...
        find(splitValues=="test",1)];
    if any(order==0), return; end
    metrics=modelMetrics(order,:);
catch
    metrics=emptyMetrics();
end
end

function valid=validateAllScoreRows(source,modelNames,evidence,phase)
valid=false;
expectedModels=[modelNames;"trainMean"];
models=string(source.model); splits=string(source.split);
if strcmp(phase,'selection')
    expectedSplits=["train";"validation"];
else
    expectedSplits=["train";"validation";"test"];
end
if numel(models)~=numel(expectedModels)*numel(expectedSplits)|| ...
        any(ismissing(models))||any(ismissing(splits))|| ...
        any(~ismember(models,expectedModels))|| ...
        any(~ismember(splits,expectedSplits))
    return;
end
keys=models+"/"+splits;
if numel(unique(keys))~=numel(keys), return; end
if ~isnumeric(source.sampleCount)||~isnumeric(source.idCount)|| ...
        ~isnumeric(source.mae)||~isnumeric(source.rmse)|| ...
        any(~isfinite(source.sampleCount))||any(~isfinite(source.idCount))|| ...
        any(~isfinite(source.mae))||any(~isfinite(source.rmse))|| ...
        any(source.sampleCount<1)||any(source.sampleCount~=fix(source.sampleCount))|| ...
        any(source.idCount<1)||any(source.idCount~=fix(source.idCount))|| ...
        any(source.sampleCount<source.idCount)||any(source.mae<0)||any(source.rmse<0)
    return;
end
tolerance=1e-12.*max(1,source.rmse);
if any(source.rmse+tolerance<source.mae), return; end
for k=1:numel(expectedModels)
    for split=reshape(expectedSplits,1,[])
        at=models==expectedModels(k)&splits==split;
        if sum(at)~=1, return; end
        evidenceAt=find(string({evidence.split})==split,1);
        if isempty(evidenceAt)||source.sampleCount(at)~=evidence(evidenceAt).sampleCount|| ...
                source.idCount(at)~=evidence(evidenceAt).idCount
            return;
        end
    end
end
valid=true;
end

function evidence=normalizeSplitEvidence(value)
evidence=struct('split',{},'ids',{},'sampleCount',{},'idCount',{});
required={'split','ids','sampleCount','idCount'};
if ~isstruct(value)||~all(isfield(value,required)), return; end
for k=1:numel(value)
    evidence(k).split=char(string(value(k).split));
    evidence(k).ids=double(value(k).ids(:).');
    evidence(k).sampleCount=double(value(k).sampleCount);
    evidence(k).idCount=double(value(k).idCount);
end
end

function valid=validSplitEvidence(evidence,manifest)
valid=false;
if numel(evidence)~=3||~isequal(string({evidence.split}),["train","validation","test"]), return; end
expected={manifest.trainingIds,manifest.validationIds,manifest.testIds};
validated=cell(1,3);
for k=1:3
    ids=double(expected{k}(:).');
    if ~validateIdSet(ids)||~isequal(evidence(k).ids,ids)|| ...
            evidence(k).idCount~=numel(ids)||~isscalar(evidence(k).sampleCount)|| ...
            ~isfinite(evidence(k).sampleCount)||evidence(k).sampleCount<evidence(k).idCount|| ...
            evidence(k).sampleCount~=fix(evidence(k).sampleCount)
        return;
    end
    validated{k}=ids;
end
if ~isempty(intersect(validated{1},validated{2}))|| ...
        ~isempty(intersect(validated{1},validated{3}))|| ...
        ~isempty(intersect(validated{2},validated{3}))
    return;
end
valid=true;
end

function valid=validateDataManifest(folder,manifest,evidence)
valid=false;
kind=char(string(manifest.dataKind));
hasDataset=~isempty(char(string(manifest.datasetFile)))|| ...
    ~isempty(char(string(manifest.datasetSha256)))|| ...
    ~isempty(char(string(manifest.datasetManifestSha256)));
if strcmp(kind,'development-fixture')&&~hasDataset
    valid=~manifest.allocationsVerified&&isempty(char(string(manifest.sourceSha256)))&& ...
        isempty(char(string(manifest.calibrationSha256)));
    return;
end
if ~isBasename(string(manifest.datasetFile))|| ...
        ~isSha256(char(string(manifest.datasetSha256)))|| ...
        ~strcmp(char(string(manifest.datasetManifestFile)),'dataset-manifest.json')|| ...
        ~isSha256(char(string(manifest.datasetManifestSha256)))|| ...
        ~strcmpi(char(string(manifest.datasetManifestSha256)), ...
            nbiot.ml.fileSha256(fullfile(folder,'dataset-manifest.json')))
    return;
end
datasetManifest=jsondecode(fileread(fullfile(folder,'dataset-manifest.json')));
if ~isstruct(datasetManifest)||~isscalar(datasetManifest)|| ...
        ~all(isfield(datasetManifest,{'kind','assignments','inputs','allocationsVerified', ...
        'experimentRolesExplicit'}))|| ...
        ~strcmp(char(string(datasetManifest.kind)),kind)
    return;
end
assignments=normalizeAssignments(datasetManifest.assignments);
expectedAssignments=splitEvidenceAssignments(evidence);
if isempty(assignments)||~isequal(assignments,expectedAssignments), return; end
if strcmp(kind,'candidate-training')
    if ~manifest.allocationsVerified||~isequal(datasetManifest.allocationsVerified,true)|| ...
            ~isequal(datasetManifest.experimentRolesExplicit,true)|| ...
            isempty(char(string(manifest.sourceSha256)))|| ...
            isempty(char(string(manifest.calibrationSha256)))|| ...
            ~validateManifestInputs(datasetManifest.inputs,manifest,evidence,true)
        return;
    end
elseif manifest.allocationsVerified
    return;
elseif isempty(datasetManifest.inputs)
    if ~isempty(char(string(manifest.sourceSha256)))|| ...
            ~isempty(char(string(manifest.calibrationSha256)))
        return;
    end
elseif ~validateManifestInputs(datasetManifest.inputs,manifest,evidence,false)
    return;
end
valid=true;
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
    required={'externalRealizationId','split','experimentRole'};
    if ~all(ismember(required,source.Properties.VariableNames)), return; end
    assignments=table(double(source.externalRealizationId(:)), ...
        string(source.split(:)),string(source.experimentRole(:)), ...
        'VariableNames',required);
    assignments=sortrows(assignments,'externalRealizationId');
catch
    assignments=table();
end
end

function expected=splitEvidenceAssignments(evidence)
ids=[evidence(1).ids(:);evidence(2).ids(:);evidence(3).ids(:)];
splits=[repmat("train",numel(evidence(1).ids),1); ...
    repmat("validation",numel(evidence(2).ids),1); ...
    repmat("test",numel(evidence(3).ids),1)];
roles=splits; roles(splits=="train")="training"; roles(splits=="test")="model-test";
expected=table(ids,splits,roles,'VariableNames', ...
    {'externalRealizationId','split','experimentRole'});
expected=sortrows(expected,'externalRealizationId');
end

function valid=validateManifestInputs(inputs,manifest,evidence,requireReal)
valid=false;
required={'sourceSha256','calibrationSha256','isFixture','realizationId'};
if ~isstruct(inputs)||isempty(inputs)|| ...
        ~all(isfield(inputs,[required,{'caseKey'}])), return; end
source=string({inputs.sourceSha256}); calibration=string({inputs.calibrationSha256});
fixtures=[inputs.isFixture];
inputIds=double([inputs.realizationId]);
caseKeys=string({inputs.caseKey});
expectedIds=sort([evidence(1).ids,evidence(2).ids,evidence(3).ids]);
if (requireReal&&any(fixtures))||any(~cellfun(@isSha256,cellstr(source)))|| ...
        any(~cellfun(@isSha256,cellstr(calibration)))|| ...
        numel(unique(source))~=1||numel(unique(calibration))~=1|| ...
        numel(unique(caseKeys))~=numel(caseKeys)|| ...
        any(ismissing(caseKeys)|caseKeys=="")|| ...
        any(~isfinite(inputIds)|inputIds<0|inputIds>=4000|inputIds~=fix(inputIds))|| ...
        ~isequal(sort(unique(inputIds(:))),expectedIds(:))
    return;
end
valid=strcmpi(char(source(1)),char(string(manifest.sourceSha256)))&& ...
    strcmpi(char(calibration(1)),char(string(manifest.calibrationSha256)));
end

function valid=validateIdSet(value)
valid=isnumeric(value)&&isvector(value)&&~isempty(value)&& ...
    all(isfinite(value(:)))&&all(value(:)>=0&value(:)<4000&value(:)==fix(value(:)))&& ...
    numel(unique(value(:)))==numel(value)&&isequal(double(value(:).'),sort(double(value(:).')));
end

function same=sameIds(a,b)
same=validateIdSet(a)&&validateIdSet(b)&&isequal(double(a(:).'),double(b(:).'));
end

function names=normalizeTextList(value)
names=string(value(:));
names=names(:);
end

function valid=isBasename(value)
value=char(string(value));
[folder,~,~]=fileparts(value);
valid=~isempty(value)&&isempty(folder)&&~contains(value,'..')&& ...
    ~contains(value,'/')&&~contains(value,'\')&&~contains(value,':');
end

function valid=isSha256(value)
valid=ischar(value)&&numel(value)==64&&all(ismember(lower(value),'0123456789abcdef'));
end

function value=emptyMetrics()
value=table(strings(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'split','sampleCount','idCount','mae','rmse'});
end
