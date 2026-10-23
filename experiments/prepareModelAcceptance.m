function candidate=prepareModelAcceptance(options)
%PREPAREMODELACCEPTANCE Create portable candidate metadata from existing evidence.
%   Подготовка записи допуска модели. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
try
    required={'modelFile','datasetFile','datasetManifestFile','datasetArtifactsFile', ...
        'trainingManifestFile','metricsFile','sourceManifestFile','calibrationFile', ...
        'registryFile','policyFile','protocolFile','evaluationFile','outputFile'};
    if ~isstruct(options)||~isscalar(options)||~all(isfield(options,required))|| ...
            ~all(ismember(fieldnames(options),required))
        reject('Options must contain exactly the required model-acceptance paths.');
    end
    outputFile=canonicalPath(text(options.outputFile,'outputFile'));
    if isfile(outputFile), reject('Candidate output already exists; it is never overwritten.'); end
    root=fileparts(outputFile);
    if ~isfolder(root), reject('Candidate package folder must already exist.'); end
    canonicalRoot=canonicalPath(root);
    inputNames=required(1:end-1); inputPaths=struct();
    for k=1:numel(inputNames)
        name=inputNames{k}; path=canonicalPath(text(options.(name),name));
        if ~isfile(path), reject('Required input file is missing: %s.',name); end
        relative=relativePath(canonicalRoot,path);
        if isempty(relative)||contains(relative,'..')||startsWith(relative,{'/','\'})||contains(relative,':')
            reject('Input %s must be inside the candidate package folder.',name);
        end
        inputPaths.(name)=path;
    end
    [modelFolder,modelBase,modelExt]=fileparts(inputPaths.modelFile);
    sidecar=fullfile(modelFolder,[modelBase '.json']);
    if ~strcmpi(modelExt,'.mat')||~isfile(sidecar)
        reject('The model MAT and its adjacent JSON sidecar are required.');
    end
    sidecar=canonicalPath(sidecar);
    relative=relativePath(canonicalRoot,sidecar);
    if contains(relative,'..')||contains(relative,':'), reject('Model sidecar must remain in the package.'); end

    datasetManifest=readJson(inputPaths.datasetManifestFile,'dataset manifest');
    trainingManifest=readJson(inputPaths.trainingManifestFile,'training manifest');
    modelSidecar=readJson(sidecar,'model sidecar');
    sourceManifest=readJson(inputPaths.sourceManifestFile,'source manifest');
    protocol=readJson(inputPaths.protocolFile,'evaluation protocol');
    policy=readJson(inputPaths.policyFile,'adaptive policy');
    trainingIds=requiredField(trainingManifest,'trainingIds');
    validationIds=requiredField(trainingManifest,'validationIds');
    testIds=requiredField(trainingManifest,'testIds');
    if ~all(isfield(protocol,{'scope'})), reject('Protocol scope is missing.'); end
    fixture=strcmp(text(requiredField(datasetManifest,'kind'),'dataset kind'),'development-fixture')|| ...
        strcmp(text(requiredField(trainingManifest,'dataKind'),'training dataKind'),'development-fixture')|| ...
        (isfield(modelSidecar,'dataKind')&&strcmp(text(modelSidecar.dataKind,'model dataKind'),'development-fixture'));
    if isfield(datasetManifest,'inputs')&&isstruct(datasetManifest.inputs)&&isfield(datasetManifest.inputs,'isFixture')
        fixture=fixture||any([datasetManifest.inputs.isFixture]);
    end
    if isfield(sourceManifest,'evidenceKind')&& ...
            ismember(text(sourceManifest.evidenceKind,'source evidenceKind'),{'test-fixture','development-fixture'})
        fixture=true;
    end
    if fixture, evidenceKind='test-fixture'; else, evidenceKind='scientific-candidate'; end
    protocolRef=makeRef(canonicalRoot,inputPaths.protocolFile);

    candidate=struct('schemaVersion','model-acceptance-v1','status','candidate', ...
        'evidenceKind',evidenceKind,'featureSchemaVersion',text(modelSidecar.schemaVersion,'model schema'), ...
        'model',makeRef(canonicalRoot,inputPaths.modelFile), ...
        'modelSidecar',makeRef(canonicalRoot,sidecar), ...
        'dataset',makeRef(canonicalRoot,inputPaths.datasetFile), ...
        'datasetManifest',makeRef(canonicalRoot,inputPaths.datasetManifestFile), ...
        'datasetArtifacts',makeRef(canonicalRoot,inputPaths.datasetArtifactsFile), ...
        'trainingManifest',makeRef(canonicalRoot,inputPaths.trainingManifestFile), ...
        'metrics',makeRef(canonicalRoot,inputPaths.metricsFile), ...
        'sourceManifest',makeRef(canonicalRoot,inputPaths.sourceManifestFile), ...
        'calibration',makeRef(canonicalRoot,inputPaths.calibrationFile), ...
        'registry',makeRef(canonicalRoot,inputPaths.registryFile), ...
        'policy',makeRef(canonicalRoot,inputPaths.policyFile), ...
        'protocol',makeRef(canonicalRoot,inputPaths.protocolFile), ...
        'evaluation',makeRef(canonicalRoot,inputPaths.evaluationFile), ...
        'policySha256',nbiot.controller.policySha256(policy), ...
        'trainingIds',trainingIds,'validationIds',validationIds,'testIds',testIds, ...
        'policyTuningIds',[],'scope',protocol.scope, ...
        'review',struct('decision','pending','reviewer','','reviewedAtUtc','', ...
        'evidenceDigest','','protocolSha256',protocolRef.sha256, ...
        'limitations',''));
    trainingFolder=fileparts(inputPaths.trainingManifestFile);
    freezePath=fullfile(trainingFolder,text(requiredField(trainingManifest,'freezeFile'),'freezeFile'));
    if isfile(freezePath)
        freeze=readJson(freezePath,'model selection freeze');
        if isfield(freeze,'policyTuningIds'), candidate.policyTuningIds=freeze.policyTuningIds; end
    end
    report=nbiot.ml.checkModelAcceptanceEvidence(candidate,canonicalRoot);
    candidate.review.evidenceDigest=report.evidenceDigest;
    unmet={};
    if ~report.passed, unmet=report.errors; end
    if fixture, unmet{end+1}='Development/test-fixture evidence cannot be scientifically accepted.'; end
    if ~isempty(unmet), candidate.unmetRequirements=unmet; else, candidate.unmetRequirements={}; end
    writeJsonAtomic(outputFile,candidate);
    nbiot.ml.checkModelAcceptanceEvidence(outputFile,canonicalRoot);
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Cannot prepare model-acceptance candidate: %s',exception.message);
end
end

function ref=makeRef(root,path)
relative=relativePath(root,path);
if isempty(relative)||contains(relative,'..')||contains(relative,':')
    reject('Evidence reference would escape the package root.');
end
ref=struct('file',strrep(relative,'\','/'),'sha256',nbiot.ml.fileSha256(path));
end

function path=relativePath(root,file)
root=canonicalPath(root); file=canonicalPath(file);
prefix=[root filesep];
if ~startsWith(file,prefix,'IgnoreCase',true), path=''; return; end
path=file(numel(prefix)+1:end);
end

function path=canonicalPath(path)
path=char(path);
try, path=char(java.io.File(path).getCanonicalPath()); catch, end
end

function value=readJson(path,label)
try, value=jsondecode(fileread(path));
catch exception, reject('Cannot read %s: %s.',label,exception.message); end
if ~isstruct(value)||~isscalar(value), reject('%s must contain one JSON object.',label); end
end

function value=requiredField(value,name)
if ~isstruct(value)||~isfield(value,name), reject('Required evidence field is missing: %s.',name); end
value=value.(name);
end

function value=text(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1, reject('%s must be scalar text.',label); end
end

function writeJsonAtomic(path,value)
folder=fileparts(path); temp=[path '.tmp-' char(java.util.UUID.randomUUID())];
cleanup=onCleanup(@() deleteIfPresent(temp)); %#ok<NASGU>
fid=fopen(temp,'w','n','UTF-8');
if fid<0, reject('Cannot create a temporary candidate file.'); end
closeGuard=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
clear closeGuard
check=jsondecode(fileread(temp));
if ~isstruct(check)||~strcmp(check.status,'candidate')||~strcmp(check.schemaVersion,'model-acceptance-v1')
    reject('Candidate readback verification failed.');
end
if isfile(path), reject('Candidate output appeared during preparation; it was not overwritten.'); end
[ok,message]=movefile(temp,path);
if ~ok, reject('Cannot atomically place candidate file: %s.',message); end
if ~isfile(path), reject('Candidate output is missing after rename.'); end
end

function deleteIfPresent(path)
if isfile(path), delete(path); end
end

function reject(message,varargin)
error('nbiot:ml:ModelAcceptance',message,varargin{:});
end
