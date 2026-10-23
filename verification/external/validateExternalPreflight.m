function report=validateExternalPreflight(packageFolder,options)
%VALIDATEEXTERNALPREFLIGHT Verify a portable handoff without running a stage.
if nargin<2, options=struct(); end
report=struct('passed',false,'readOnly',true,'readiness',struct( ...
    'softwareReady',false,'toolboxesAvailable',false,'stageReady',false, ...
    'scientificAccepted',false),'errors',{{}},'sourceDigest','', ...
    'inputDigests',struct(),'requestedStage','','toolboxes',struct( ...
    'required',{{}},'available',{{}},'missing',{{}}));
try
    if ~isstruct(options)||~isscalar(options), fail('Options must be a scalar structure.'); end
    packageRoot=canonical(packageFolder);
    if ~isfolder(packageRoot), fail('Package folder does not exist.'); end
    manifest=readJson(fullfile(packageRoot,'manifest.json'),'package manifest');
    required={'schemaVersion','matlabRelease','codeFiles','codeManifestSha256', ...
        'calibration','registry','model','caseMatrix','idAssignments','resourceStatus', ...
        'evidenceFiles'};
    if ~all(isfield(manifest,required))||manifest.schemaVersion~=1
        fail('Package manifest schema is incomplete or unsupported.');
    end
    projectRoot=inside(packageRoot,'project');
    [sourceDigest,sourceErrors]=verifySources(packageRoot,manifest);
    report.sourceDigest=sourceDigest;
    report.errors=[report.errors sourceErrors];
    report.inputDigests=struct();
    [calibration,calOk]=checkRef(packageRoot,manifest.calibration,'calibration',report);
    report.inputDigests=calibration.digests; report.errors=[report.errors calibration.errors];
    [registry,regOk]=checkRef(packageRoot,manifest.registry,'registry',report);
    report.inputDigests=merge(report.inputDigests,registry.digests);
    report.errors=[report.errors registry.errors];
    idsOk=false;
    if regOk
        registryData=readJson(registry.path,'realization registry');
        [idsOk,assignmentErrors]=checkAssignments(manifest.idAssignments,registryData);
        report.errors=[report.errors assignmentErrors];
    end
    modelOk=true; modelPresent=logical(manifest.model.included); scienceOk=false;
    if modelPresent
        modelRef=struct('path',manifest.model.path, ...
            'packagePath',manifest.model.packagePath,'sha256',manifest.model.sha256);
        [modelResult,modelOk]=checkRef(packageRoot,modelRef,'model',report);
        report.inputDigests=merge(report.inputDigests,modelResult.digests);
        report.errors=[report.errors modelResult.errors];
        sidecarRef=struct('path',manifest.model.sidecarPath, ...
            'packagePath',manifest.model.sidecarPackagePath, ...
            'sha256',manifest.model.sidecarSha256);
        [sidecarResult,sidecarOk]=checkRef(packageRoot,sidecarRef,'modelSidecar',report);
        report.inputDigests=merge(report.inputDigests,sidecarResult.digests);
        report.errors=[report.errors sidecarResult.errors]; modelOk=modelOk&&sidecarOk;
        if modelOk
            sidecar=readJson(sidecarResult.path,'model sidecar');
            [modelFolder,base,ext]=fileparts(modelResult.path);
            [sidecarFolder,sidecarBase,sidecarExt]=fileparts(sidecarResult.path);
            if ~strcmpi(ext,'.mat')||~strcmpi(sidecarExt,'.json')|| ...
                    ~strcmpi(modelFolder,sidecarFolder)||~strcmpi(base,sidecarBase)|| ...
                    ~all(isfield(sidecar,{'artifactFile','artifactSha256'}))|| ...
                    ~strcmp(char(string(sidecar.artifactFile)),[base ext])|| ...
                    ~strcmpi(char(string(sidecar.artifactSha256)),nbiot.ml.fileSha256(modelResult.path))
                modelOk=false;
                report.errors{end+1}= ...
                    'Model sidecar must be a same-name JSON file beside and bound to the MAT file.';
            end
        end
    end
    evidenceOk=true;
    if isfield(manifest,'modelAcceptance')&&logical(manifest.modelAcceptance.included)
        [evidenceOk,scienceOk,evidenceDigests,evidenceErrors]= ...
            verifyAcceptance(packageRoot,projectRoot,manifest.modelAcceptance, ...
            manifest.evidenceFiles,manifest.model);
        report.inputDigests=merge(report.inputDigests,evidenceDigests);
        report.errors=[report.errors evidenceErrors];
    elseif ~isempty(manifest.evidenceFiles)
        fail('Evidence index is present without a model acceptance package.');
    end
    report.readiness.scientificAccepted=scienceOk;
    report.passed=isempty(report.errors);
    report.readiness.softwareReady=report.passed&&isempty(sourceErrors)&& ...
        strcmp(char(string(manifest.matlabRelease)),version('-release'));
    stage=requestedStage(options); report.requestedStage=stage;
    [requiredToolboxes,availableToolboxes,missingToolboxes]=toolboxStatus(stage,manifest);
    report.toolboxes=struct('required',{requiredToolboxes}, ...
        'available',{availableToolboxes},'missing',{missingToolboxes});
    report.readiness.toolboxesAvailable=isempty(missingToolboxes);
    adaptive=hasAdaptive(manifest.caseMatrix);
    prerequisites=report.passed&&calOk&&regOk&&idsOk&&modelOk&&evidenceOk&& ...
        report.readiness.softwareReady&&report.readiness.toolboxesAvailable&&(~adaptive||scienceOk);
    if strcmp(stage,'validate')
        report.readiness.stageReady=prerequisites;
    elseif strcmp(stage,'pilot')
        report.readiness.stageReady=prerequisites&&~strcmp(char(string(manifest.resourceStatus)),'not-specified');
    elseif ismember(stage,{'data','assemble','train','freeze','evaluate','admit','compare','summarize'})
        report.readiness.stageReady=prerequisites&& ...
            ismember(char(string(manifest.resourceStatus)),{'target-reviewed','measured-and-target-reviewed'});
    end
catch exception
    report.errors{end+1}=exception.message;
    report.passed=false; report.readiness.softwareReady=false; report.readiness.stageReady=false;
end
end

function [digest,errors]=verifySources(root,manifest)
errors={}; digest=''; entries=manifest.codeFiles; rows=repmat(struct('path','','sha256',''),0,1);
if isempty(entries)||~isstruct(entries), fail('Package source manifest is empty.'); end
for k=1:numel(entries)
    item=entries(k);
    if ~all(isfield(item,{'path','sha256','packagePath','packageSha256','sanitized'}))
        fail('Package source entry is incomplete.');
    end
    rel=char(string(item.path)); packageRel=char(string(item.packagePath));
    path=inside(root,packageRel);
    sourceRel=strrep(rel,'\','/');
    if isempty(sourceRel)||startsWith(sourceRel,'/')||contains(sourceRel,':')|| ...
            any(strcmp(split(sourceRel,'/'),'..'))
        fail('Package source path is invalid.');
    end
    expectedPath=inside(root,['project/' sourceRel]);
    if ~strcmpi(path,expectedPath), fail('Source and package paths differ.'); end
    if ~startsWith(strrep(packageRel,'\','/'),'project/')||~isfile(path)
        fail(['Package source is missing: ' rel]);
    end
    actual=nbiot.ml.fileSha256(path);
    if ~strcmpi(actual,char(string(item.packageSha256))), fail(['Package source hash differs: ' rel]); end
    if ~logical(item.sanitized)&&~strcmpi(actual,char(string(item.sha256)))
        fail(['Computational/source bytes changed: ' rel]);
    end
    [~,~,ext]=fileparts(rel);
    if logical(item.sanitized)&&ismember(lower(ext),{'.m','.ps1','.cs'})
        fail(['Executable source was sanitized: ' rel]);
    end
    rows(end+1)=struct('path',rel,'sha256',actual); %#ok<AGROW>
end
[~,order]=sort({rows.path}); rows=rows(order); digest=sha256(jsonencode(rows));
if ~strcmpi(sha256(jsonencode(entries)),char(string(manifest.codeManifestSha256)))
    errors{end+1}='Source manifest digest differs.';
end
end

function [result,ok]=checkRef(root,ref,name,report)
result=struct('path','','errors',{{}},'digests',struct()); ok=false;
try
    if ~isstruct(ref)||~all(isfield(ref,{'packagePath','sha256'})), fail([name ' ref is incomplete.']); end
    result.path=inside(root,char(string(ref.packagePath)));
    if isfield(ref,'path')
        sourcePath=char(string(ref.path));
        sourcePath=strrep(sourcePath,'\','/');
        if isempty(sourcePath)||startsWith(sourcePath,'/')||contains(sourcePath,':')|| ...
                any(strcmp(split(sourcePath,'/'),'..'))
            fail([name ' source path is invalid.']);
        end
        expectedPath=inside(root,['project/' sourcePath]);
        if ~strcmpi(expectedPath,result.path)
            fail([name ' source and package paths differ.']);
        end
    end
    if ~startsWith(strrep(char(string(ref.packagePath)),'\','/'),'project/')||~isfile(result.path)
        fail([name ' ref is missing or outside the package.']);
    end
    actual=nbiot.ml.fileSha256(result.path);
    if ~strcmpi(actual,char(string(ref.sha256))), fail([name ' ref hash differs.']); end
    result.digests.(matlab.lang.makeValidName(name))=actual; ok=true;
catch exception
    result.errors{end+1}=exception.message;
end
end

function [ok,scientific,digests,errors]=verifyAcceptance( ...
        packageRoot,projectRoot,info,indexedReferences,model)
ok=false; scientific=false; digests=struct(); errors={};
try
    ref=struct('path',info.path,'packagePath',info.packagePath, ...
        'sha256',info.packageSha256);
    [result,acceptanceOk]=checkRef(packageRoot,ref,'modelAcceptance',struct());
    if ~acceptanceOk, errors=result.errors; return; end
    acceptance=readJson(result.path,'model acceptance');
    if ~strcmpi(nbiot.ml.fileSha256(result.path),char(string(info.sha256)))|| ...
            ~strcmp(char(string(acceptance.status)),char(string(info.status)))|| ...
            ~strcmp(char(string(acceptance.evidenceKind)),char(string(info.evidenceKind)))
        fail('Model acceptance metadata differs from the packaged JSON.');
    end
    required={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
        'trainingManifest','metrics','sourceManifest','calibration','registry','policy','protocol','evaluation'};
    for k=1:numel(required)
        name=required{k};
        if ~isfield(acceptance,name)||~all(isfield(acceptance.(name),{'file','sha256'}))
            fail(['Acceptance ref is missing: ' name]);
        end
    end
    refs=collectAcceptanceReferences(acceptance,'');
    names={refs.name};
    if numel(unique(names))~=numel(names)
        fail('Acceptance contains duplicate evidence reference names.');
    end
    for k=1:numel(required)
        if sum(strcmp(names,required{k}))~=1
            fail(['Acceptance must contain exactly one canonical ref: ' required{k}]);
        end
    end
    for k=1:numel(refs)
        name=refs(k).name; rel=refs(k).path; expectedHash=refs(k).sha256;
        source=inside(fileparts(result.path),rel);
        if ~isfile(source)||~strcmpi(nbiot.ml.fileSha256(source),expectedHash)
            fail(['Acceptance evidence is missing or changed: ' name]);
        end
        expectedPath=relativePath(projectRoot,source);
        refs(k).path=expectedPath;
        digests.(matlab.lang.makeValidName(['evidence_' name]))=expectedHash;
    end
    verifyEvidenceIndex(info.references,refs);
    verifyEvidenceIndex(indexedReferences,refs);
    if ~strcmpi(resolveAcceptanceModelPath(result.path,acceptance.model.file), ...
            inside(packageRoot,model.packagePath))
        fail('Acceptance model differs from packaged model.');
    end
    acceptedSidecar=resolveAcceptanceModelPath(result.path,acceptance.modelSidecar.file);
    if ~isfield(model,'sidecarPackagePath')|| ...
            ~strcmpi(acceptedSidecar,inside(packageRoot,model.sidecarPackagePath))
        fail('Acceptance model sidecar differs from packaged model sidecar.');
    end
    ok=true;
    scientific=strcmp(char(string(acceptance.status)),'accepted')&& ...
        strcmp(char(string(acceptance.evidenceKind)),'scientific-candidate')&& ...
        validReview(acceptance);
catch exception
    errors{end+1}=exception.message;
end
end

function refs=collectAcceptanceReferences(value,prefix)
refs=struct('name',{},'path',{},'sha256',{});
if isstruct(value)&&isscalar(value)&&all(isfield(value,{'file','sha256'}))
    name=prefix;
    if isempty(name), name='reference'; end
    refs=struct('name',name,'path',char(string(value.file)), ...
        'sha256',char(string(value.sha256)));
elseif isstruct(value)
    if ~isscalar(value), fail('Acceptance reference objects must be scalar structures.'); end
    fields=fieldnames(value);
    for k=1:numel(fields)
        childPrefix=fields{k};
        if ~isempty(prefix), childPrefix=[prefix '.' childPrefix]; end
        nested=collectAcceptanceReferences(value.(fields{k}),childPrefix);
        refs=[refs;nested(:)]; %#ok<AGROW>
    end
elseif iscell(value)
    for k=1:numel(value)
        nested=collectAcceptanceReferences(value{k},prefix);
        refs=[refs;nested(:)]; %#ok<AGROW>
    end
end
end

function path=resolveAcceptanceModelPath(acceptancePath,ref)
path=inside(fileparts(acceptancePath),char(string(ref)));
end

function yes=validReview(acceptance)
yes=false;
if ~isfield(acceptance,'review')||~isstruct(acceptance.review)|| ...
        ~all(isfield(acceptance.review,{'decision','reviewer','reviewedAtUtc', ...
        'evidenceDigest','protocolSha256','limitations'}))|| ...
        ~isfield(acceptance,'evidenceDigest')
    return
end
review=acceptance.review;
try
    digest=canonicalEvidenceDigest(acceptance);
catch
    return
end
yes=strcmp(char(string(review.decision)),'accepted')&& ...
    ~isempty(strtrim(char(string(review.reviewer))))&& ...
    validSha256(acceptance.evidenceDigest)&& ...
    strcmpi(char(string(acceptance.evidenceDigest)),digest)&& ...
    strcmpi(char(string(review.evidenceDigest)),digest)&& ...
    ~isempty(strtrim(char(string(review.reviewedAtUtc))))&& ...
    ~isempty(strtrim(char(string(review.limitations))) )&& ...
    isfield(acceptance,'protocol')&&isfield(acceptance.protocol,'sha256')&& ...
    strcmpi(char(string(review.protocolSha256)),char(string(acceptance.protocol.sha256)));
end

function digest=canonicalEvidenceDigest(acceptance)
names={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
    'trainingManifest','metrics','sourceManifest','calibration','registry', ...
    'policy','protocol','evaluation'};
if ~all(isfield(acceptance,names))||~all(isfield(acceptance, ...
        {'schemaVersion','featureSchemaVersion','trainingIds','validationIds', ...
        'testIds','policyTuningIds','scope','policySha256'}))
    fail('Acceptance is missing fields required for its evidence digest.');
end
refs=struct();
for k=1:numel(names)
    item=acceptance.(names{k});
    if ~isstruct(item)||~isscalar(item)||~all(isfield(item,{'file','sha256'}))
        fail(['Acceptance digest ref is malformed: ' names{k}]);
    end
    refs.(names{k})=struct( ...
        'file',strrep(acceptanceText(item.file,[names{k} ' file']), '\','/'), ...
        'sha256',lower(acceptanceText(item.sha256,[names{k} ' hash'])));
end
protocolSha=lower(acceptanceText(acceptance.protocol.sha256,'protocol hash'));
canonical=struct('schemaVersion',acceptanceText(acceptance.schemaVersion,'schemaVersion'), ...
    'featureSchemaVersion',acceptanceText(acceptance.featureSchemaVersion,'feature schema'), ...
    'refs',refs, ...
    'trainingIds',normalizeAcceptanceIds(acceptance.trainingIds,'trainingIds',false), ...
    'validationIds',normalizeAcceptanceIds(acceptance.validationIds,'validationIds',false), ...
    'testIds',normalizeAcceptanceIds(acceptance.testIds,'testIds',false), ...
    'policyTuningIds',normalizeAcceptanceIds(acceptance.policyTuningIds,'policyTuningIds',true), ...
    'scope',canonicalAcceptanceScope(acceptance.scope), ...
    'protocolSha256',protocolSha, ...
    'policySha256',lower(acceptanceText(acceptance.policySha256,'policy digest')));
digest=sha256(jsonencode(canonical));
end

function value=acceptanceText(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1
    fail('%s must be scalar text.',label);
end
value=strtrim(value);
end

function ids=normalizeAcceptanceIds(value,label,allowEmpty)
if isempty(value)&&allowEmpty, ids=[]; return; end
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:))|value(:)<0|value(:)>3999|value(:)~=fix(value(:)))
    fail('%s must contain integer IDs in 0:3999.',label);
end
ids=sort(double(value(:).'));
if numel(unique(ids))~=numel(ids), fail('%s contains duplicate IDs.',label); end
end

function value=canonicalAcceptanceScope(scope)
required={'methods','numUE','trafficKinds','windowTicks'};
allowed=[required,{'burstDurationTicks','periodTicks','poissonRatePerSecond'}];
if ~isstruct(scope)||~isscalar(scope)||~all(isfield(scope,required))|| ...
        any(~ismember(fieldnames(scope),allowed))
    fail('Acceptance scope is malformed.');
end
methods=normalizeAcceptanceTextList(scope.methods,'scope methods');
traffic=normalizeAcceptanceTextList(scope.trafficKinds,'scope trafficKinds');
numUE=normalizeAcceptanceVector(scope.numUE,'scope numUE');
if ~isnumeric(scope.windowTicks)||~isreal(scope.windowTicks)|| ...
        ~isscalar(scope.windowTicks)||~isfinite(scope.windowTicks)
    fail('Scope windowTicks must be one finite number.');
end
value=struct('methods',{sort(methods)},'numUE',sort(double(numUE(:).')), ...
    'trafficKinds',{sort(traffic)},'windowTicks',double(scope.windowTicks));
for field={'burstDurationTicks','periodTicks','poissonRatePerSecond'}
    name=field{1};
    if isfield(scope,name)
        values=normalizeAcceptanceVector(scope.(name),['scope ' name]);
        value.(name)=sort(double(values(:).'));
    end
end
end

function values=normalizeAcceptanceTextList(value,label)
try, values=cellstr(string(value(:))).';
catch, fail('%s must be a list of text values.',label); end
if isempty(values)||any(cellfun(@isempty,values))||numel(unique(values))~=numel(values)
    fail('%s must contain unique non-empty text values.',label);
end
end

function values=normalizeAcceptanceVector(value,label)
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value(:)))||numel(unique(double(value(:))))~=numel(value)
    fail('%s must contain unique finite numbers.',label);
end
values=double(value(:).');
end

function verifyEvidenceIndex(indexed,references)
required={'name','path','sha256','packagePath','packageSha256'};
if ~isstruct(indexed)||numel(indexed)~=numel(references)|| ...
        (~isempty(indexed)&&~all(isfield(indexed,required)))
    fail('Evidence reference index is incomplete or differs from acceptance references.');
end
names={indexed.name};
if numel(unique(names))~=numel(names), fail('Top-level evidence index has duplicate names.'); end
for k=1:numel(references)
    match=find(strcmp(names,references(k).name));
    if numel(match)~=1, fail('Top-level evidence index is missing a required reference.'); end
    item=indexed(match);
    if ~strcmp(item.path,references(k).path)|| ...
            ~strcmpi(item.sha256,references(k).sha256)|| ...
            ~strcmp(item.packagePath,['project/' references(k).path])|| ...
            ~strcmpi(item.packageSha256,references(k).sha256)
        fail('Top-level evidence index differs from acceptance references.');
    end
end
end

function yes=validSha256(value)
value=char(string(value));
yes=numel(value)==64&&~isempty(regexp(value,'^[0-9a-fA-F]{64}$','once'));
end

function [ok,errors]=checkAssignments(rows,registry)
ok=false; errors={};
if isempty(rows), ids=[]; roles=strings(0,1);
elseif isstruct(rows)&&all(isfield(rows,{'externalRealizationId','role'}))
    ids=double([rows.externalRealizationId]); roles=string({rows.role}).';
else
    errors={'ID assignments are malformed.'}; return
end
if any(~isfinite(ids)|ids<0|ids>4095|ids~=fix(ids))||numel(unique(ids))~=numel(ids)
    errors={'ID assignments contain invalid or duplicate values.'}; return
end
if ~isstruct(registry)||~all(isfield(registry,{'roles','reservations','assignments'}))
    errors={'Realization registry structure is invalid.'}; return
end
if any(~ismember(roles,string(registry.roles))), errors={'An ID role is absent from the registry.'}; return; end
used=[];
for k=1:numel(registry.reservations)
    range=double(registry.reservations(k).range(:).');
    if numel(range)==2&&all(isfinite(range))&&range(1)<=range(2), used=[used range(1):range(2)]; end %#ok<AGROW>
end
for k=1:numel(registry.assignments)
    if isfield(registry.assignments(k),'ids')&&~isempty(registry.assignments(k).ids)
        used=[used double(registry.assignments(k).ids(:).')]; %#ok<AGROW>
    end
end
if any(ismember(ids,used)), errors={'An assigned ID is already reserved or used.'}; return; end
ok=true;
end

function stage=requestedStage(options)
stage='';
if ~isfield(options,'stage')||isempty(options.stage), return; end
value=options.stage; if isstring(value)&&isscalar(value), value=char(value); end
allowed={'validate','pilot','data','assemble','train','freeze','evaluate','admit','compare','summarize'};
if ~ischar(value)||~ismember(value,allowed), fail('Requested stage is not allowed.'); end
stage=value;
end

function [required,available,missing]=toolboxStatus(stage,manifest)
required={};
if ~isempty(manifest.caseMatrix), required={'LTE Toolbox'}; end
if strcmp(stage,'train'), required=[required {'Statistics and Machine Learning Toolbox'}]; end
products=ver(); names={products.Name};
available=required(ismember(required,names)); missing=required(~ismember(required,names));
end

function yes=hasAdaptive(caseMatrix)
yes=false;
if isstruct(caseMatrix)&&~isempty(caseMatrix)&&isfield(caseMatrix,'method')
    yes=any(ismember(string({caseMatrix.method}),["Adaptive-P","Adaptive-RA/DT"]));
end
end

function path=inside(root,rel)
if isstring(rel)&&isscalar(rel), rel=char(rel); end
if ~ischar(rel)||isempty(rel)||absolute(rel)||contains(rel,':')|| ...
        any(strcmp(split(strrep(rel,'\','/'),'/'),'..'))
    fail('A package reference is absolute or escapes its root.');
end
root=canonical(root); path=canonical(fullfile(root,strrep(rel,'/',filesep)));
if ~within(root,path)||strcmpi(root,path), fail('A package reference escapes its root.'); end
end

function path=relativePath(root,file)
root=canonical(root); file=canonical(file);
if ~within(root,file)||strcmpi(root,file), fail('Evidence file is outside its root.'); end
path=strrep(file(length(root)+2:end),filesep,'/');
end

function yes=absolute(value)
yes=~isempty(regexp(value,'^(?:[A-Za-z]:[\\/]|\\\\|/)', 'once'));
end

function yes=within(root,path)
root=lower(stripTrailing(root)); path=lower(path);
yes=strcmp(root,path)||startsWith(path,[root filesep]);
end

function value=stripTrailing(value)
while numel(value)>3&&any(value(end)==['\','/']), value(end)=[]; end
end

function path=canonical(value)
if ~(ischar(value)||(isstring(value)&&isscalar(value))), fail('Path must be scalar text.'); end
path=char(java.io.File(char(value)).getCanonicalPath());
end

function value=merge(a,b)
value=a; names=fieldnames(b);
for k=1:numel(names), value.(names{k})=b.(names{k}); end
end

function value=readJson(path,label)
try, value=jsondecode(fileread(path));
catch exception, fail(['Cannot read ' label ': ' exception.message]);
end
if ~isstruct(value)||~isscalar(value), fail([label ' must be one JSON object.']); end
end

function digest=sha256(value)
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(uint8(unicode2native(value,'UTF-8')),'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function fail(message)
error('nbiot:externalPreflight:InvalidPackage','%s',message);
end
