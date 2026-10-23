function metadata=validateModelAcceptance(path,modelFile,policy,execution,comparisonIds,cfg)
%VALIDATEMODELACCEPTANCE Enforce scientific model admission without running an experiment.
try
    if nargin<6, reject('The six-argument admission interface requires cfg.'); end
    if ~(ischar(path)||(isstring(path)&&isscalar(path)))||~isfile(path)
        reject('Acceptance JSON file is missing.');
    end
    if ~(ischar(modelFile)||(isstring(modelFile)&&isscalar(modelFile))||isstruct(modelFile))
        reject('A model package file is required.');
    end
    if isstruct(modelFile)
        reject('External admission accepts a saved model file, not an in-memory bundle.');
    end
    acceptancePath=canonicalPath(char(path)); root=fileparts(acceptancePath);
    acceptance=readJson(acceptancePath);
    ids=normalizeComparisonIds(comparisonIds);
    trainingIds=normalizeIds(acceptance.trainingIds,'training IDs');
    validationIds=normalizeIds(acceptance.validationIds,'validation IDs');
    testIds=normalizeIds(acceptance.testIds,'model-test IDs');
    tuningIds=normalizeIds(acceptance.policyTuningIds,'policy-tuning IDs',true);
    if ~isempty(intersect(ids,[trainingIds validationIds testIds tuningIds]))
        reject('Comparison IDs overlap training, validation, model-test, or policy-tuning IDs.');
    end
    budget=nbiot.experiments.validateExecutionBudget(cfg,execution,numel(ids)); %#ok<NASGU>
    if ~strcmp(text(execution.profile,'execution profile'),'external-machine')|| ...
            ~strcmp(text(execution.role,'execution role'),'final-comparison')
        reject('Scientific admission is restricted to external final-comparison runs.');
    end
    validateConfigScope(cfg,acceptance.scope);
    expectedRuntimeIdentity=acceptedRuntimeIdentity(acceptance,root);
    projectRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
    currentSource=optimizationSourceManifest(projectRoot);
    currentCalibration='';
    if isfield(cfg,'calibrationFileSha256'), currentCalibration=text(cfg.calibrationFileSha256, ...
            'current calibration file hash'); end
    nbiot.ml.verifyModelAcceptanceRuntimeIdentity(expectedRuntimeIdentity, ...
        currentSource.sha256,currentCalibration);
    report=nbiot.ml.checkModelAcceptanceEvidence(acceptance,root);
    if ~report.passed
        reject('Acceptance evidence failed validation: %s',strjoin(report.errors,'; '));
    end
    nbiot.ml.verifyModelAcceptanceRuntimeIdentity(expectedRuntimeIdentity, ...
        report.sourceSha256,report.calibrationSha256);
    if ~strcmp(text(acceptance.status,'acceptance status'),'accepted')|| ...
            ~strcmp(text(acceptance.evidenceKind,'evidence kind'),'scientific-candidate')|| ...
            ~strcmp(text(acceptance.review.decision,'review decision'),'accepted')
        reject('Only reviewed scientific-candidate evidence can be admitted.');
    end
    if isfield(acceptance,'unmetRequirements')&&~isempty(acceptance.unmetRequirements)
        reject('Acceptance still lists unmet requirements.');
    end

    expectedModel=resolveRef(root,acceptance.model);
    requestedModel=canonicalPath(char(modelFile));
    if ~strcmpi(requestedModel,expectedModel)|| ...
            ~strcmpi(nbiot.ml.fileSha256(requestedModel),acceptance.model.sha256)
        reject('Requested model file differs from the reviewed acceptance evidence.');
    end
    if ~isstruct(policy)||~isscalar(policy)
        reject('A complete scalar controller policy is required.');
    end
    policyDigest=nbiot.controller.policySha256(policy);
    if ~strcmpi(policyDigest,acceptance.policySha256)
        reject('Runtime policy differs from the reviewed frozen policy.');
    end
    policyFile=readJson(resolveRef(root,acceptance.policy));
    if ~strcmpi(nbiot.controller.policySha256(policyFile),policyDigest)
        reject('Runtime policy does not match the packaged policy file.');
    end

    training=readJson(resolveRef(root,acceptance.trainingManifest));
    datasetManifest=readJson(resolveRef(root,acceptance.datasetManifest));
    modelSidecar=readJson(resolveRef(root,acceptance.modelSidecar));
    if ~strcmp(text(training.dataKind,'training data kind'),'candidate-training')|| ...
            ~logical(training.allocationsVerified)|| ...
            ~strcmp(text(datasetManifest.kind,'dataset kind'),'candidate-training')|| ...
            ~logical(datasetManifest.allocationsVerified)|| ...
            ~logical(datasetManifest.experimentRolesExplicit)|| ...
            ~isfield(datasetManifest,'diagnosticsComplete')||~logical(datasetManifest.diagnosticsComplete)|| ...
            ~strcmp(text(modelSidecar.dataKind,'model dataKind'),'candidate-training')|| ...
            ~strcmp(text(modelSidecar.status,'model status'),'development')
        reject('Development fixtures or unverified allocations cannot be scientifically admitted.');
    end
    if ~isstruct(datasetManifest.inputs)||isempty(datasetManifest.inputs)|| ...
            any([datasetManifest.inputs.isFixture])|| ...
            any(strcmp({datasetManifest.assignments.experimentRole},'final-comparison'))
        reject('Dataset inputs include fixture or comparison data.');
    end
    if isfield(training,'testConsumptionSha256')&&~isSha256(training.testConsumptionSha256)
        reject('Test-consumption evidence digest is invalid.');
    end

    bundle=nbiot.ml.validateModelBundle(requestedModel);
    if ~strcmp(text(bundle.dataKind,'model dataKind'),'candidate-training')|| ...
            ~strcmp(text(bundle.status,'model status'),'development')|| ...
            ~strcmpi(nbiot.ml.fileSha256(requestedModel),acceptance.model.sha256)
        reject('Saved model bundle does not match scientific candidate evidence.');
    end
    if ~isequal(normalizeIds(bundle.trainingIds,'bundle training IDs'),trainingIds)|| ...
            ~isequal(normalizeIds(bundle.validationIds,'bundle validation IDs'),validationIds)|| ...
            ~isequal(normalizeIds(bundle.testIds,'bundle test IDs'),testIds)
        reject('Saved model split IDs differ from acceptance metadata.');
    end
    validateConfigScope(cfg,acceptance.scope);
    metadata=struct('admissionStatus','accepted','acceptanceSha256', ...
        nbiot.ml.fileSha256(acceptancePath),'policySha256',policyDigest, ...
        'evidenceDigest',report.evidenceDigest,'review',acceptance.review, ...
        'scope',acceptance.scope,'evidenceFiles',report.evidenceFiles, ...
        'sourceSha256',report.sourceSha256, ...
        'calibrationSha256',report.calibrationSha256);
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Model acceptance rejected: %s',exception.message);
end
end

function identity=acceptedRuntimeIdentity(acceptance,root)
if ~isfield(acceptance,'sourceManifest')||~isfield(acceptance,'calibration')|| ...
        ~isstruct(acceptance.sourceManifest)||~isscalar(acceptance.sourceManifest)|| ...
        ~isstruct(acceptance.calibration)||~isscalar(acceptance.calibration)|| ...
        ~all(isfield(acceptance.sourceManifest,{'file','sha256'}))|| ...
        ~isfield(acceptance.calibration,'sha256')||~isSha256(acceptance.sourceManifest.sha256)|| ...
        ~isSha256(acceptance.calibration.sha256)
    reject('Acceptance source or calibration identity is incomplete.');
end
sourcePath=resolveRef(root,acceptance.sourceManifest);
if ~strcmpi(nbiot.ml.fileSha256(sourcePath),acceptance.sourceManifest.sha256)
    reject('Packaged source manifest changed after acceptance was written.');
end
source=readJson(sourcePath);
if ~isfield(source,'sourceSha256')||~isSha256(source.sourceSha256)
    reject('Packaged source manifest does not declare a valid computational source hash.');
end
identity=struct('sourceSha256',char(string(source.sourceSha256)), ...
    'calibrationSha256',char(string(acceptance.calibration.sha256)));
end

function validateConfigScope(cfg,scope)
if ~isstruct(cfg)||~isscalar(cfg)||~all(isfield(cfg,{'simulation','traffic','policy'}))|| ...
        ~isfield(cfg.simulation,'numUE')||~isfield(cfg.traffic,'kind')||~isfield(cfg.policy,'name')
    reject('Configuration must declare load, traffic, and Adaptive method.');
end
numUE=cfg.simulation.numUE; traffic=text(cfg.traffic.kind,'traffic kind');
method=text(cfg.policy.name,'Adaptive method');
if ~ismember(method,cellstr(string(scope.methods(:))))|| ...
        ~ismember(double(numUE),double(scope.numUE(:)))|| ...
        ~ismember(traffic,cellstr(string(scope.trafficKinds(:))))
    reject('Configuration load, traffic, or method is outside the accepted scope.');
end
switch traffic
    case 'burst'
        value=requiredNumber(cfg.traffic,'burstDurationTicks'); field='burstDurationTicks';
    case 'periodic'
        value=requiredNumber(cfg.traffic,'periodTicks'); field='periodTicks';
    case 'poisson'
        value=requiredNumber(cfg.traffic,'poissonRatePerSecond'); field='poissonRatePerSecond';
    otherwise
        reject('Configuration traffic type is unsupported.');
end
scopeValues=scope.(field);
if ~ismember(value,double(scopeValues(:)))
    reject('Configuration traffic parameter is outside the accepted scope.');
end
if isfield(cfg,'dataset')&&isfield(cfg.dataset,'windowTicks'), window=cfg.dataset.windowTicks;
elseif isfield(cfg.policy,'windowTicks'), window=cfg.policy.windowTicks;
elseif isfield(cfg,'windowTicks'), window=cfg.windowTicks;
else, reject('Configuration does not declare a feature window.'); end
if ~isscalar(window)||double(window)~=double(scope.windowTicks)
    reject('Configuration feature window is outside the accepted scope.');
end
end

function value=requiredNumber(parent,field)
if ~isfield(parent,field), reject('Configuration is missing traffic parameter %s.',field); end
value=parent.(field);
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)
    reject('Configuration traffic parameter %s is invalid.',field);
end
value=double(value);
end

function ids=normalizeComparisonIds(value)
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:))|value(:)<0|value(:)>3999|value(:)~=fix(value(:)))|| ...
        numel(unique(value))~=numel(value)
    reject('Comparison IDs must be unique integers in 0:3999.');
end
ids=double(value(:).');
end

function ids=normalizeIds(value,label,allowEmpty)
if nargin>=3&&allowEmpty&&isempty(value), ids=[]; return; end
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:))|value(:)<0|value(:)>3999|value(:)~=fix(value(:)))|| ...
        numel(unique(value))~=numel(value)
    reject('%s are invalid.',label);
end
ids=double(value(:).');
end

function path=resolveRef(root,ref)
relative=text(ref.file,'acceptance reference');
if startsWith(relative,{'/','\'})||contains(relative,':')||any(split(string(strrep(relative,'\','/')),'/')=="..")
    reject('Acceptance reference escapes its package root.');
end
path=canonicalPath(fullfile(root,strrep(relative,'/',filesep)));
prefix=[canonicalPath(root) filesep];
if ~startsWith(path,prefix,'IgnoreCase',true)||~isfile(path)
    reject('Acceptance reference is unavailable inside the package.');
end
end

function value=readJson(path)
try, value=jsondecode(fileread(path));
catch exception, reject('Cannot read acceptance evidence JSON: %s',exception.message); end
if ~isstruct(value)||~isscalar(value), reject('Acceptance evidence JSON must be one object.'); end
end

function value=text(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1, reject('%s must be scalar text.',label); end
value=strtrim(value);
end

function path=canonicalPath(path)
path=char(path);
try, path=char(java.io.File(path).getCanonicalPath()); catch, end
end

function yes=isSha256(value)
yes=(ischar(value)||(isstring(value)&&isscalar(value)))&&numel(char(value))==64&& ...
    all(ismember(lower(char(value)),'0123456789abcdef'));
end

function reject(message,varargin)
error('nbiot:ml:ModelAcceptance',message,varargin{:});
end
