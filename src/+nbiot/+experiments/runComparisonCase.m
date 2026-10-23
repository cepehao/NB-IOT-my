function record=runComparisonCase(cfg,method,caseFolder,options)
%RUNCOMPARISONCASE Run or resume one method for a paired external realization.
%   Один метод (Static/Adaptive-P/Adaptive-RA/DT) на заданной внешней реализации (ТЗ §28, §63).
if nargin<4||~isstruct(options)||~isscalar(options)
    error('nbiot:experiments:ComparisonCaseOptions','A scalar case-options structure is required.');
end
method=char(string(method));
if ~ismember(method,{'Static','Adaptive-P','Adaptive-RA/DT'})
    error('nbiot:experiments:ComparisonMethod','Unsupported comparison method %s.',method);
end
if ~isfolder(caseFolder)&&isfile(caseFolder)
    error('nbiot:experiments:ComparisonCaseFolder','Case path must be a folder.');
end
cfg.policy.name=method;
if strcmp(method,'Adaptive-P')||strcmp(method,'Adaptive-RA/DT')
    cfg.policy.windowTicks=500;
    cfg.dataset.windowTicks=500;
end
cfg.logging.outputFolder=caseFolder;
[runtimeOptions,admissionIdentity]=runtimeIdentityOptions(cfg,options,method);
metadata=nbiot.experiments.runtimeManifest(cfg,runtimeOptions);
if ~isempty(fieldnames(admissionIdentity))
    nbiot.ml.verifyModelAcceptanceRuntimeIdentity(admissionIdentity, ...
        metadata.sourceSha256,metadata.calibrationSha256);
end

if isfield(options,'resume')&&options.resume&&isfolder(caseFolder)
    attempts=dir(fullfile(caseFolder,'run-*'));
    attempts=attempts([attempts.isdir]);
    for k=numel(attempts):-1:1
        candidate=fullfile(attempts(k).folder,attempts(k).name);
        report=nbiot.results.verifyCase(candidate,metadata);
        if report.passed&&strcmp(report.status,'completed')
            marker=jsondecode(fileread(fullfile(candidate,'case-complete.json')));
            resultPath=fullfile(candidate,char(string(marker.resultFile)));
            saved=load(resultPath,'kpiSummary');
            record=caseRecord(cfg,method,report.status,double(marker.elapsedSeconds), ...
                resultPath,metadata,saved.kpiSummary,'');
            return;
        end
    end
end

runner=[];
if isfield(options,'runExperimentFcn'), runner=options.runExperimentFcn; end
meta=nbiot.experiments.runStaticCase(cfg,caseFolder,metadata,runner,runtimeOptions);
saved=load(meta.resultFile,'kpiSummary');
record=caseRecord(cfg,method,meta.status,meta.elapsedSeconds,meta.resultFile, ...
    meta,saved.kpiSummary,'');
end

function [runtimeOptions,admissionIdentity]=runtimeIdentityOptions(cfg,options,method)
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
runtimeOptions=struct('projectRoot',root,'execution',options.execution, ...
    'calibrationFile',options.calibrationFile,'scenario',options.scenario, ...
    'controllerPolicy',options.controllerPolicy,'runner',[], ...
    'identityRoot',root,'modelAcceptanceFile','', ...
    'admissionEvidenceDigest','','inputFiles',{{}},'policyFiles',{{}}, ...
    'expectedInputFileHashes',[]);
admissionIdentity=struct();
if ~isempty(options.modelFile)
    runtimeOptions.modelFiles={options.modelFile};
else
    runtimeOptions.modelFiles={};
end
runner=[];
if isfield(options,'runExperimentFcn'), runner=options.runExperimentFcn; end
runtimeOptions.runner=runner;
if ~isempty(runner)
    runtimeOptions.runnerFiles=options.runnerFiles;
    runtimeOptions.runnerInputs=options.runnerInputs;
    runtimeOptions.runnerDependenciesDeclared=options.runnerDependenciesDeclared;
end
if isfield(options,'modelAcceptanceFile')&&~isempty(options.modelAcceptanceFile)
    runtimeOptions.modelAcceptanceFile=char(string(options.modelAcceptanceFile));
    runtimeOptions.inputFiles={runtimeOptions.modelAcceptanceFile};
    runtimeOptions.identityRoot=fileparts(absolutePath(runtimeOptions.modelAcceptanceFile));
end
admission=struct();
if isfield(options,'admissionMetadata')&&isstruct(options.admissionMetadata)&& ...
        isscalar(options.admissionMetadata)
    admission=options.admissionMetadata;
end
externalAdaptive=ismember(method,{'Adaptive-P','Adaptive-RA/DT'})&& ...
    isfield(options.execution,'profile')&& ...
    strcmp(char(string(options.execution.profile)),'external-machine');
if externalAdaptive
    validated=nbiot.ml.validateModelAcceptance( ...
        runtimeOptions.modelAcceptanceFile,options.modelFile, ...
        options.controllerPolicy,options.execution, ...
        cfg.simulation.realizationId,cfg);
    currentSource=optimizationSourceManifest(runtimeOptions.projectRoot);
    nbiot.ml.verifyModelAcceptanceRuntimeIdentity(validated,currentSource.sha256, ...
        nbiot.ml.fileSha256(options.calibrationFile));
    admissionIdentity=validated;
    validated.modelSha256=nbiot.ml.fileSha256(options.modelFile);
    validated.policyFile=policyFileFromAcceptance(runtimeOptions.modelAcceptanceFile);
    validated.comparisonIds=double(cfg.simulation.realizationId);
    if ~isempty(fieldnames(admission))
        verifyAdmissionSnapshot(admission,validated, ...
            runtimeOptions.modelAcceptanceFile,cfg.simulation.realizationId);
    end
    admission=validated;
elseif isfield(options,'policyFile')&&~isempty(options.policyFile)
    runtimeOptions.policyFiles={options.policyFile};
end
if isfield(admission,'evidenceDigest')&&~isempty(admission.evidenceDigest)
    runtimeOptions.admissionEvidenceDigest=admission.evidenceDigest;
end
if externalAdaptive
    evidenceFiles=admission.evidenceFiles;
    runtimeOptions.inputFiles=[{runtimeOptions.modelAcceptanceFile} {evidenceFiles.path}];
    expected=struct('path',runtimeOptions.modelAcceptanceFile, ...
        'sha256',admission.acceptanceSha256);
    runtimeOptions.expectedInputFileHashes=[expected; evidenceFiles(:)];
end
if isfield(admission,'policyFile')&&~isempty(admission.policyFile)
    runtimeOptions.policyFiles={admission.policyFile};
end
if ismember(method,{'Adaptive-P','Adaptive-RA/DT'})
    controllerOptions=struct('model',options.modelFile, ...
        'allowDevelopmentModel',options.allowDevelopmentModel);
    if ~isempty(fieldnames(options.controllerPolicy))
        controllerOptions.policy=options.controllerPolicy;
    end
    if isfield(options,'modelAcceptanceFile')&&~isempty(options.modelAcceptanceFile)
        controllerOptions.modelAcceptanceFile=options.modelAcceptanceFile;
    end
    runtimeOptions.controllerOptions=controllerOptions;
end
end

function verifyAdmissionSnapshot(snapshot,validated,acceptancePath,realizationId)
required={'admissionStatus','acceptanceSha256','policySha256','evidenceDigest', ...
    'review','scope','modelSha256','policyFile','comparisonIds','evidenceFiles'};
if ~isstruct(snapshot)||~isscalar(snapshot)||~all(isfield(snapshot,required))|| ...
        ~strcmp(textValue(snapshot.admissionStatus),'accepted')|| ...
        ~strcmpi(textValue(snapshot.acceptanceSha256),validated.acceptanceSha256)|| ...
        ~strcmpi(textValue(snapshot.policySha256),validated.policySha256)|| ...
        ~strcmpi(textValue(snapshot.evidenceDigest),validated.evidenceDigest)|| ...
        ~strcmpi(textValue(snapshot.modelSha256),validated.modelSha256)|| ...
        ~sameScalarStruct(snapshot.review,validated.review)|| ...
        ~sameScalarStruct(snapshot.scope,validated.scope)
    error('nbiot:ml:ModelAcceptance', ...
        'The supplied model admission snapshot differs from persisted acceptance evidence.');
end
snapshotPolicyFile=textValue(snapshot.policyFile);
validatedPolicyFile=validated.policyFile;
if ~strcmpi(absolutePath(snapshotPolicyFile),absolutePath(validatedPolicyFile))
    error('nbiot:ml:ModelAcceptance', ...
        'The supplied model admission policy path differs from persisted acceptance evidence.');
end
ids=snapshot.comparisonIds;
if ~isnumeric(ids)||isempty(ids)||~isreal(ids)||any(~isfinite(ids(:)))|| ...
        any(ids(:)~=fix(ids(:)))||numel(unique(double(ids(:))))~=numel(ids)|| ...
        ~ismember(double(realizationId),double(ids(:)))
    error('nbiot:ml:ModelAcceptance', ...
        'The supplied model admission snapshot does not include this comparison realization.');
end
if ~sameEvidenceFileSet(snapshot.evidenceFiles,validated.evidenceFiles,acceptancePath)
    error('nbiot:ml:ModelAcceptance', ...
        'The supplied model admission evidence file set differs from current persisted evidence.');
end
try
    savedPolicy=jsondecode(fileread(validatedPolicyFile));
    if ~strcmpi(nbiot.controller.policySha256(savedPolicy),validated.policySha256)
        error('nbiot:ml:ModelAcceptance','The packaged controller policy changed after preflight.');
    end
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','The packaged controller policy is no longer valid: %s.',exception.message);
end
end

function yes=sameScalarStruct(left,right)
yes=false;
if ~isstruct(left)||~isscalar(left)||~isstruct(right)||~isscalar(right), return; end
leftNames=sort(fieldnames(left)); rightNames=sort(fieldnames(right));
if ~isequal(leftNames,rightNames), return; end
for k=1:numel(leftNames)
    name=leftNames{k};
    if ~isequaln(left.(name),right.(name)), return; end
end
yes=true;
end

function yes=sameEvidenceFileSet(left,right,acceptancePath)
left=canonicalEvidenceFileSnapshot(left,acceptancePath);
right=canonicalEvidenceFileSnapshot(right,acceptancePath);
yes=numel(left)==numel(right);
if ~yes, return; end
for k=1:numel(left)
    if ~strcmpi(left(k).path,right(k).path)||~strcmpi(left(k).sha256,right(k).sha256)
        yes=false; return;
    end
end
end

function files=canonicalEvidenceFileSnapshot(files,acceptancePath)
if ~isstruct(files)||isempty(files)||~all(isfield(files,{'path','sha256'}))
    error('nbiot:ml:ModelAcceptance', ...
        'The validated model admission does not include its evidence file snapshot.');
end
root=absolutePath(fileparts(acceptancePath)); seen={};
normalized=repmat(struct('path','','sha256',''),numel(files),1);
for k=1:numel(files)
    pathValue=files(k).path; hashValue=files(k).sha256;
    if isstring(pathValue)&&isscalar(pathValue), pathValue=char(pathValue); end
    if isstring(hashValue)&&isscalar(hashValue), hashValue=char(hashValue); end
    if ~ischar(pathValue)||size(pathValue,1)~=1||~ischar(hashValue)|| ...
            numel(hashValue)~=64||any(~ismember(lower(hashValue),'0123456789abcdef'))
        error('nbiot:ml:ModelAcceptance', ...
            'The validated model admission contains an invalid evidence file record.');
    end
    path=absolutePath(pathValue);
    if ~startsWith(path,[root filesep],'IgnoreCase',true)||any(strcmpi(path,seen))||~isfile(path)
        error('nbiot:ml:ModelAcceptance', ...
            'The validated model admission contains an outside or duplicate evidence path.');
    end
    seen{end+1}=path; %#ok<AGROW>
    normalized(k)=struct('path',path,'sha256',lower(hashValue));
end
[~,order]=sort(lower(string({normalized.path})));
files=normalized(order);
end

function value=textValue(value)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1
    error('nbiot:ml:ModelAcceptance','The supplied model admission snapshot contains invalid text.');
end
end

function path=policyFileFromAcceptance(acceptancePath)
try
    acceptance=jsondecode(fileread(acceptancePath));
    relative=char(string(acceptance.policy.file));
    if isempty(relative)||startsWith(relative,{'/','\'})||contains(relative,':')|| ...
            any(split(string(strrep(relative,'\','/')),'/')=="..")
        error('nbiot:ml:ModelAcceptance','Acceptance policy reference is not package-relative.');
    end
    root=absolutePath(fileparts(acceptancePath));
    path=absolutePath(fullfile(root,strrep(relative,'/',filesep)));
    if ~startsWith(path,[root filesep],'IgnoreCase',true)||~isfile(path)
        error('nbiot:ml:ModelAcceptance','Acceptance policy file is outside or missing from its package.');
    end
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Cannot resolve the accepted policy file: %s.',exception.message);
end
end

function path=absolutePath(path)
path=char(java.io.File(char(path)).getCanonicalPath());
end

function record=caseRecord(cfg,method,status,elapsedSeconds,resultFile,metadata,kpi,errorMessage)
record=struct('numUE',double(cfg.simulation.numUE), ...
    'burstDurationTicks',double(cfg.traffic.burstDurationTicks), ...
    'realizationId',double(cfg.simulation.realizationId),'method',string(method), ...
    'status',string(status),'elapsedSeconds',double(elapsedSeconds), ...
    'resultFile',string(resultFile),'caseKey',string(metadata.caseKey), ...
    'inputSha256',string(fieldOr(metadata,'inputSha256','')), ...
    'configSha256',string(metadata.configSha256), ...
    'sourceSha256',string(metadata.sourceSha256), ...
    'calibrationSha256',string(metadata.calibrationSha256), ...
    'errorIdentifier',"",'errorMessage',string(errorMessage));
comparisonMetrics=nbiot.experiments.comparisonKpis(kpi,method);
names=fieldnames(comparisonMetrics);
for k=1:numel(names), record.(names{k})=comparisonMetrics.(names{k}); end
end

function value=fieldOr(input,name,fallback)
value=fallback;
if isstruct(input)&&isfield(input,name), value=input.(name); end
end
