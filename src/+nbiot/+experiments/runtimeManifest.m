function metadata=runtimeManifest(cfg,options)
%RUNTIMEMANIFEST Registered computational identities, independent of docs.
%   Описание вычислительной среды и версий кода для результата. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
if nargin<2, options=struct(); end
% Hooks other than the explicitly registered runner have no identity contract.
rejectUnknownHooks(options,{'runner','runExperimentFcn'});
rejectUnknownHooks(cfg,{});
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
options=defaults(options,struct('projectRoot',root,'calibrationFile','', ...
    'modelFiles',{{}},'policyFiles',{{}},'inputFiles',{{}},'scenario',[], ...
    'runner',[],'runnerFiles',{{}},'runnerInputs',struct(),'runnerDependenciesDeclared',false, ...
    'controllerPolicy',[],'identityRoot','','modelAcceptanceFile','', ...
    'admissionEvidenceDigest','','expectedInputFileHashes',[]));
if isempty(options.identityRoot), options.identityRoot=options.projectRoot; end
source=optimizationSourceManifest(options.projectRoot);
canonicalCfg=cfg;
if isfield(canonicalCfg,'logging'), canonicalCfg.logging.outputFolder='<case-output>'; end
if isfield(canonicalCfg,'calibrationReport'), canonicalCfg=rmfield(canonicalCfg,'calibrationReport'); end
if isfield(canonicalCfg,'calibrationFileSha256'), canonicalCfg=rmfield(canonicalCfg,'calibrationFileSha256'); end
if isempty(options.calibrationFile)
    if isfield(cfg,'calibrationFileSha256'), calibration=char(string(cfg.calibrationFileSha256));
    elseif isfield(cfg,'calibrationReport'), calibration=hashValue(cfg.calibrationReport);
    else, calibration=hashValue(cfg.phy); end
else, calibration=hashFile(options.calibrationFile); end
if ~isSha256(calibration)
    error('nbiot:experiments:RuntimeIdentity','Calibration identity must be SHA-256.');
end
model=hashFiles(options.modelFiles,options.identityRoot);
identityInputs=cellstr(string(options.inputFiles));
if ~isempty(options.modelAcceptanceFile)
    acceptancePath=char(string(options.modelAcceptanceFile));
    existingPaths=cellfun(@absolutePath,identityInputs,'UniformOutput',false);
    if ~any(strcmpi(existingPaths,absolutePath(acceptancePath)))
        identityInputs{end+1}=acceptancePath;
    end
end
evidenceDigest=char(string(options.admissionEvidenceDigest));
if ~isempty(evidenceDigest)&&~isSha256(evidenceDigest)
    error('nbiot:experiments:RuntimeIdentity','Admission evidence digest must be SHA-256.');
end
inputFileEntries=hashFileEntries(identityInputs,options.identityRoot);
verifyExpectedInputFileHashes(inputFileEntries,options.expectedInputFileHashes,options.identityRoot);
inputs=hashValue(struct('files',hashValue(inputFileEntries), ...
    'scenario',options.scenario,'admissionEvidenceDigest',evidenceDigest));
controllerPolicy=[];
if isfield(cfg,'policy')&&isfield(cfg.policy,'name')&& ...
        ~strcmp(char(string(cfg.policy.name)),'Static')
    controllerPolicy=adaptiveDefaults();
    if ~isempty(options.controllerPolicy)
        if ~isstruct(options.controllerPolicy)||~isscalar(options.controllerPolicy)
            error('nbiot:experiments:ControllerPolicy','Controller policy must be a scalar structure.');
        end
        names=fieldnames(options.controllerPolicy);
        if ~all(ismember(names,fieldnames(controllerPolicy)))
            error('nbiot:experiments:ControllerPolicy','Controller policy contains unsupported fields.');
        end
        for k=1:numel(names), controllerPolicy.(names{k})=options.controllerPolicy.(names{k}); end
    end
end
policy=hashValue(struct('configuration',cfg.policy, ...
    'files',hashFiles(options.policyFiles,options.identityRoot), ...
    'controllerPolicy',controllerPolicy));
if isempty(options.runner)
    runner=hashValue(struct('function','nbiot.runExperiment','source',source.sha256));
else
    info=functions(options.runner);
    if ~options.runnerDependenciesDeclared || strcmp(info.type,'anonymous') || ...
            ~isfield(info,'file') || isempty(info.file)
        error('nbiot:experiments:UnregisteredDependency','External runner and dependencies must be explicitly registered.');
    end
    registered=cellstr(string(options.runnerFiles));
    paths=cellfun(@absolutePath,registered,'UniformOutput',false);
    if ~any(strcmpi(absolutePath(info.file),paths))
        error('nbiot:experiments:UnregisteredDependency','Runner defining file is not registered.');
    end
    captured=struct();
    if isfield(info,'workspace')
        for w=1:numel(info.workspace)
            workspace=info.workspace{w}; names=fieldnames(workspace);
            for k=1:numel(names)
                name=names{k}; value=workspace.(name);
                if isa(value,'function_handle') && isequal(value,options.runner), continue; end
                if ~isfield(options.runnerInputs,name) || ~strcmp(hashValue(options.runnerInputs.(name)),hashValue(value))
                    error('nbiot:experiments:UnregisteredDependency','Captured runner input %s must be registered with its actual value.',name);
                end
                captured.(name)=value;
            end
        end
    end
    runner=hashValue(struct('function',info.function, ...
        'files',hashFiles(registered,options.projectRoot), ...
        'capturedInputs',captured,'registeredInputs',options.runnerInputs));
end
sourceProfile='static-v1';
if isfield(cfg,'policy')&&isfield(cfg.policy,'name')&& ...
        ~strcmp(char(string(cfg.policy.name)),'Static')
    sourceProfile='adaptive-development';
end
environment=struct('matlabVersion',version,'release',version('-release'), ...
    'lteVersion',ver('lte'),'computer',computer,'validatedInMatlab',false,'sourceProfile',sourceProfile);
resultSchemaVersion=2;
if ~isempty(controllerPolicy), resultSchemaVersion=3; end
metadata=struct('runtimeVersion',1,'resultSchemaVersion',resultSchemaVersion, ...
    'configSha256',nbiot.results.configSha256(cfg,true), ...
    'canonicalConfigSha256',hashValue(canonicalCfg),'sourceSha256',source.sha256, ...
    'calibrationSha256',calibration,'modelSha256',model,'policySha256',policy, ...
    'inputSha256',inputs,'runnerSha256',runner,'environment',environment);
if ~isempty(controllerPolicy), metadata.controllerPolicy=controllerPolicy; end
identity=struct('method',cfg.policy.name,'configuration',metadata.canonicalConfigSha256, ...
    'traffic',cfg.traffic,'realization',cfg.simulation.realizationId, ...
    'calibration',calibration,'model',model,'policy',policy,'inputs',inputs,'runner',runner);
caseVersion='case-v2';
if resultSchemaVersion==3, caseVersion='case-v3'; end
metadata.caseKey=[caseVersion '-' hashValue(identity)];
end

function value=canonical(value)
if isstruct(value)
    value=orderfields(value);
    names=fieldnames(value);
    for i=1:numel(value)
        for k=1:numel(names), value(i).(names{k})=canonical(value(i).(names{k})); end
    end
elseif iscell(value)
    for k=1:numel(value), value{k}=canonical(value{k}); end
elseif isnumeric(value) || islogical(value)
    dataClass=class(value); dataShape=size(value); sparseStorage=issparse(value); realStorage=isreal(value);
    if islogical(value)
        realBytes=uint8(full(value(:))); imaginaryBytes=uint8([]);
    else
        realBytes=typecast(full(real(value(:))),'uint8');
        imaginaryBytes=typecast(full(imag(value(:))),'uint8');
    end
    value=struct('numericClass',dataClass,'shape',dataShape,'sparseStorage',sparseStorage,'realStorage',realStorage, ...
        'realBytes',lower(reshape(dec2hex(realBytes,2).',1,[])), ...
        'imaginaryBytes',lower(reshape(dec2hex(imaginaryBytes,2).',1,[])));
elseif isa(value,'function_handle') || (isobject(value) && ~isstring(value))
    error('nbiot:experiments:UnregisteredDependency','Dynamic function/object inputs cannot be identified.');
end
end
function digest=hashValue(value)
digest=hashBytes(unicode2native(jsonencode(canonical(value)),'UTF-8'));
end
function digest=hashFiles(paths,identityRoot)
entries=hashFileEntries(paths,identityRoot);
digest=hashValue(entries);
end
function entries=hashFileEntries(paths,identityRoot)
paths=cellstr(string(paths)); entries=struct('path',{},'sha256',{});
for k=1:numel(paths)
    entries(end+1)=struct('path',identityPath(paths{k},identityRoot), ...
        'sha256',hashFile(paths{k})); %#ok<AGROW>
end
if ~isempty(entries), [~,order]=sort({entries.path}); entries=entries(order); end
end
function verifyExpectedInputFileHashes(actual,expected,identityRoot)
if isempty(expected), return; end
if ~isstruct(expected)||~all(isfield(expected,{'path','sha256'}))|| ...
        numel(expected)~=numel(actual)
    error('nbiot:ml:ModelAcceptance', ...
        'Runtime inputs do not match the file set validated during model admission.');
end
expectedPaths=cell(1,numel(expected));
for k=1:numel(expected)
    path=expected(k).path; digest=expected(k).sha256;
    if isstring(path)&&isscalar(path), path=char(path); end
    if isstring(digest)&&isscalar(digest), digest=char(digest); end
    if ~ischar(path)||size(path,1)~=1||~ischar(digest)||numel(digest)~=64|| ...
            any(~ismember(lower(digest),'0123456789abcdef'))
        error('nbiot:ml:ModelAcceptance', ...
            'The preflight runtime input snapshot contains an invalid file record.');
    end
    expectedPaths{k}=identityPath(path,identityRoot);
end
if numel(unique(lower(string(expectedPaths))))~=numel(expectedPaths)
    error('nbiot:ml:ModelAcceptance', ...
        'The preflight runtime input snapshot contains duplicate files.');
end
for k=1:numel(expected)
    at=find(strcmpi({actual.path},expectedPaths{k}));
    if numel(at)~=1||~strcmpi(actual(at).sha256,char(string(expected(k).sha256)))
        error('nbiot:ml:ModelAcceptance', ...
            'Validated evidence changed after comparison preflight: %s.',expectedPaths{k});
    end
end
end
function path=identityPath(path,identityRoot)
canonicalFile=absolutePath(path); canonicalRoot=absolutePath(identityRoot);
prefix=[canonicalRoot filesep];
if startsWith(canonicalFile,prefix,'IgnoreCase',true)
    path=canonicalFile(numel(prefix)+1:end);
else
    path=canonicalFile;
end
path=strrep(path,'\','/');
end
function yes=isSha256(value)
yes=(ischar(value)||(isstring(value)&&isscalar(value)))&&numel(char(value))==64&& ...
    all(ismember(lower(char(value)),'0123456789abcdef'));
end
function path=absolutePath(path)
path=char(java.io.File(char(path)).getCanonicalPath());
end
function digest=hashFile(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:experiments:UnregisteredDependency','Cannot identify dependency %s.',path); end
c=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=hashBytes(fread(fid,Inf,'*uint8'));
end
function hex=hashBytes(bytes)
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(uint8(bytes(:)),'int8'));
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
function value=defaults(value,base)
names=fieldnames(base);
for k=1:numel(names)
    if ~isfield(value,names{k}), value.(names{k})=base.(names{k}); end
end
end

function rejectUnknownHooks(value,allowed)
if ~isstruct(value), return; end
names=fieldnames(value);
for i=1:numel(value)
    for k=1:numel(names)
        name=names{k}; item=value(i).(name);
        hook=~isempty(regexpi(name,'hook|fcn|function','once')) || isa(item,'function_handle');
        if hook && ~isempty(item) && ~ismember(name,allowed)
            error('nbiot:experiments:UnregisteredDependency','External hook %s has no registered identity contract.',name);
        end
        if ~ismember(name,allowed), rejectUnknownHooks(item,{}); end
    end
end
end
