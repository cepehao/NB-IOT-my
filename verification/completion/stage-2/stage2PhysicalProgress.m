function progress=stage2PhysicalProgress(action,progressFile,varargin)
%STAGE2PHYSICALPROGRESS Persist and verify each atomic Stage 2 case result.
action=char(string(action));
switch action
    case 'initialize'
        [identity,caseSpecs]=arguments(varargin,2);
        if isfile(progressFile)
            error('nbiot:stage2:ProgressExists','Stage 2 progress already exists. Resume it explicitly.');
        end
        validateIdentityAndCases(identity,caseSpecs);
        identitySha256=hashText(jsonencode(identity));
        caseSpecsSha256=hashText(jsonencode(caseSpecs));
        records=repmat(emptyRecord(),numel(caseSpecs),1);
        for k=1:numel(caseSpecs)
            records(k)=struct('caseKey',caseSpecs(k).caseKey,'kind',caseSpecs(k).kind, ...
                'realizationId',caseSpecs(k).realizationId, ...
                'evidenceFile',caseSpecs(k).evidenceFile,'status','planned', ...
                'sha256','','startedAtUtc','','finishedAtUtc','');
        end
        progress=struct('schemaVersion',1,'scope',char(string(identity.scope)), ...
            'status','running','identity',identity,'identitySha256',identitySha256, ...
            'caseSpecs',caseSpecs,'caseSpecsSha256',caseSpecsSha256, ...
            'assignedIds',double(identity.assignedIds(:).'), ...
            'caseRecords',records,'pendingCaseKeys',{caseKeys(records)}, ...
            'activeCase',struct('caseKey','','startedAtUtc',''), ...
            'phase','stage-2-physical-planned','currentTick',0,'lastCheckpoint','', ...
            'owner',ownerIdentity(),'startedAtUtc',utcNow(),'updatedAtUtc',utcNow(), ...
            'completedAtUtc','');
        writeProgress(progressFile,progress);
    case 'resume'
        [identity,caseSpecs]=arguments(varargin,2);
        validateIdentityAndCases(identity,caseSpecs);
        progress=readProgress(progressFile);
        if progress.schemaVersion~=1||~strcmp(progress.scope,char(string(identity.scope)))|| ...
                ~strcmp(progress.identitySha256,hashText(jsonencode(identity)))|| ...
                ~strcmp(progress.caseSpecsSha256,hashText(jsonencode(caseSpecs)))
            error('nbiot:stage2:ProgressIdentity', ...
                'Stage 2 progress does not match the current scientific identity, matrix, or assigned IDs.');
        end
        if ~isequal(double(progress.assignedIds(:).'),double(identity.assignedIds(:).'))|| ...
                numel(progress.caseRecords)~=numel(caseSpecs)
            error('nbiot:stage2:ProgressIdentity','Stage 2 planned IDs or cases changed.');
        end
        for k=1:numel(caseSpecs)
            record=progress.caseRecords(k); spec=caseSpecs(k);
            if ~strcmp(record.caseKey,spec.caseKey)||~strcmp(record.kind,spec.kind)|| ...
                    record.realizationId~=spec.realizationId|| ...
                    ~strcmp(record.evidenceFile,spec.evidenceFile)
                error('nbiot:stage2:ProgressIdentity','Stage 2 case %d differs from the saved schedule.',k);
            end
            artifact=artifactPath(progressFile,spec.evidenceFile);
            if isfile(artifact)
                verifyArtifact(artifact,spec.caseKey,progress.identitySha256);
                digest=fileHash(artifact);
                if strcmp(record.status,'completed')&&~strcmpi(record.sha256,digest)
                    error('nbiot:stage2:ProgressEvidence', ...
                        'Completed Stage 2 evidence changed for %s.',spec.caseKey);
                end
                progress.caseRecords(k).status='completed';
                progress.caseRecords(k).sha256=digest;
                if isempty(progress.caseRecords(k).finishedAtUtc)
                    progress.caseRecords(k).finishedAtUtc=utcNow();
                end
            elseif strcmp(record.status,'completed')
                error('nbiot:stage2:ProgressEvidence', ...
                    'Completed Stage 2 evidence is missing for %s.',spec.caseKey);
            else
                progress.caseRecords(k).status='planned';
                progress.caseRecords(k).sha256='';
                progress.caseRecords(k).startedAtUtc='';
                progress.caseRecords(k).finishedAtUtc='';
            end
        end
        if strcmp(progress.status,'completed')&&any(~strcmp({progress.caseRecords.status},'completed'))
            error('nbiot:stage2:ProgressEvidence','A completed Stage 2 manifest has pending cases.');
        end
        progress.status='running'; progress.activeCase=struct('caseKey','','startedAtUtc','');
        progress.phase='stage-2-physical-resumed';
        progress.owner=ownerIdentity(); progress.updatedAtUtc=utcNow();
        progress=refreshPending(progress); writeProgress(progressFile,progress);
    case 'start'
        caseKey=char(string(arguments(varargin,1)));
        progress=readProgress(progressFile); index=caseIndex(progress,caseKey);
        if ~isempty(progress.activeCase.caseKey)||~strcmp(progress.caseRecords(index).status,'planned')
            error('nbiot:stage2:ProgressState','Stage 2 case is not available to start: %s.',caseKey);
        end
        progress.caseRecords(index).status='running';
        progress.caseRecords(index).startedAtUtc=utcNow();
        progress.activeCase=struct('caseKey',caseKey,'startedAtUtc',utcNow());
        progress.status='running'; progress.phase='stage-2-physical-case-running';
        progress.currentTick=sum(strcmp({progress.caseRecords.status},'completed'));
        progress.lastCheckpoint=caseKey; progress.updatedAtUtc=utcNow();
        progress=refreshPending(progress); writeProgress(progressFile,progress);
    case 'complete'
        [caseKey,payload]=arguments(varargin,2); caseKey=char(string(caseKey));
        if ~isstruct(payload)||~isscalar(payload)||any(strcmp(fieldnames(payload),'stage2Evidence'))
            error('nbiot:stage2:ProgressEvidence','Case payload must be a scalar structure without reserved fields.');
        end
        progress=readProgress(progressFile); index=caseIndex(progress,caseKey);
        record=progress.caseRecords(index);
        if ~strcmp(record.status,'running')||~strcmp(progress.activeCase.caseKey,caseKey)
            error('nbiot:stage2:ProgressState','Stage 2 case was not started: %s.',caseKey);
        end
        artifact=artifactPath(progressFile,record.evidenceFile);
        parent=fileparts(artifact); if ~isfolder(parent), mkdir(parent); end
        evidence=struct('caseKey',caseKey,'identitySha256',progress.identitySha256, ...
            'payload',payload,'completedAtUtc',utcNow()); %#ok<NASGU>
        variables=payload; variables.stage2Evidence=evidence;
        temporary=[artifact '.' char(java.util.UUID.randomUUID()) '.tmp.mat'];
        cleanup=onCleanup(@() deleteTemporary(temporary)); %#ok<NASGU>
        save(temporary,'-struct','variables','-v7');
        [ok,message]=movefile(temporary,artifact,'f');
        if ~ok, error('nbiot:stage2:ProgressEvidence','Cannot commit case evidence: %s.',message); end
        digest=fileHash(artifact);
        progress.caseRecords(index).status='completed';
        progress.caseRecords(index).sha256=digest;
        progress.caseRecords(index).finishedAtUtc=utcNow();
        progress.activeCase=struct('caseKey','','startedAtUtc','');
        progress.phase='stage-2-physical-case-completed';
        progress.currentTick=sum(strcmp({progress.caseRecords.status},'completed'));
        progress.lastCheckpoint=caseKey; progress.updatedAtUtc=utcNow(); progress=refreshPending(progress);
        writeProgress(progressFile,progress);
    case 'loadCase'
        caseKey=char(string(arguments(varargin,1)));
        progress=readProgress(progressFile); index=caseIndex(progress,caseKey);
        record=progress.caseRecords(index);
        artifact=artifactPath(progressFile,record.evidenceFile);
        if ~strcmp(record.status,'completed')||~isfile(artifact)|| ...
                ~strcmpi(record.sha256,fileHash(artifact))
            error('nbiot:stage2:ProgressEvidence','Case evidence is not verified: %s.',caseKey);
        end
        saved=load(artifact,'stage2Evidence');
        verifyEvidence(saved.stage2Evidence,caseKey,progress.identitySha256);
        progress=saved.stage2Evidence.payload;
    case 'pause'
        progress=readProgress(progressFile);
        if ~isempty(progress.activeCase.caseKey)
            error('nbiot:stage2:ProgressState','Cannot pause Stage 2 while a case is active.');
        end
        progress.status='budget-paused'; progress.updatedAtUtc=utcNow();
        progress.phase='budget-paused';
        progress=refreshPending(progress); writeProgress(progressFile,progress);
    case 'finish'
        progress=readProgress(progressFile);
        if any(~strcmp({progress.caseRecords.status},'completed'))|| ...
                ~isempty(progress.activeCase.caseKey)
            error('nbiot:stage2:ProgressState','Cannot finish Stage 2 while cases remain.');
        end
        progress.status='completed'; progress.completedAtUtc=utcNow();
        progress.phase='completed';
        progress.updatedAtUtc=utcNow(); progress=refreshPending(progress);
        writeProgress(progressFile,progress);
    case 'read'
        progress=readProgress(progressFile);
    case 'verify'
        progress=readProgress(progressFile);
        if ~strcmp(progress.status,'completed')||~isempty(progress.activeCase.caseKey)|| ...
                any(~strcmp({progress.caseRecords.status},'completed'))|| ...
                ~isempty(progress.pendingCaseKeys)|| ...
                ~strcmp(progress.identitySha256,hashText(jsonencode(progress.identity)))|| ...
                ~strcmp(progress.caseSpecsSha256,hashText(jsonencode(progress.caseSpecs)))|| ...
                ~isequal(double(progress.assignedIds(:).'),double(progress.identity.assignedIds(:).'))
            error('nbiot:stage2:ProgressEvidence','Stage 2 progress manifest is not a completed, internally consistent run.');
        end
        for k=1:numel(progress.caseRecords)
            record=progress.caseRecords(k);
            spec=progress.caseSpecs(k);
            if ~strcmp(record.caseKey,spec.caseKey)||~strcmp(record.kind,spec.kind)|| ...
                    record.realizationId~=spec.realizationId||~strcmp(record.evidenceFile,spec.evidenceFile)
                error('nbiot:stage2:ProgressEvidence','Stage 2 case schedule changed at %s.',record.caseKey);
            end
            artifact=artifactPath(progressFile,record.evidenceFile);
            if ~isfile(artifact)||~strcmpi(record.sha256,fileHash(artifact))
                error('nbiot:stage2:ProgressEvidence','Completed Stage 2 evidence is missing or changed: %s.',record.caseKey);
            end
            verifyArtifact(artifact,record.caseKey,progress.identitySha256);
        end
    otherwise
        error('nbiot:stage2:ProgressAction','Unknown Stage 2 progress action %s.',action);
end
end

function varargout=arguments(values,count)
if numel(values)~=count
    error('nbiot:stage2:ProgressOptions','Stage 2 progress action has invalid arguments.');
end
if count==1, varargout{1}=values{1}; else, varargout=values; end
end

function validateIdentityAndCases(identity,cases)
if ~isstruct(identity)||~isscalar(identity)||~all(isfield(identity,{'scope','assignedIds'}))|| ...
        isempty(char(string(identity.scope)))||~isnumeric(identity.assignedIds)|| ...
        ~isreal(identity.assignedIds)||isempty(identity.assignedIds)|| ...
        any(~isfinite(identity.assignedIds))||any(identity.assignedIds~=fix(identity.assignedIds))
    error('nbiot:stage2:ProgressIdentity','Stage 2 identity or assigned IDs are invalid.');
end
required={'caseKey','kind','realizationId','evidenceFile'};
if ~isstruct(cases)||isempty(cases)||~all(isfield(cases,required))|| ...
        numel(unique(string({cases.caseKey})))~=numel(cases)
    error('nbiot:stage2:ProgressIdentity','Stage 2 case schedule is invalid.');
end
for k=1:numel(cases)
    relative=char(string(cases(k).evidenceFile));
    if isempty(cases(k).caseKey)||isempty(cases(k).kind)|| ...
            ~isnumeric(cases(k).realizationId)||~isscalar(cases(k).realizationId)|| ...
            ~isfinite(cases(k).realizationId)||contains(relative,'..')|| ...
            isAbsolute(relative)
        error('nbiot:stage2:ProgressIdentity','Stage 2 case specification %d is invalid.',k);
    end
end
end

function progress=readProgress(path)
if ~isfile(path), error('nbiot:stage2:ProgressFile','Stage 2 progress file is missing.'); end
try, progress=jsondecode(fileread(path));
catch exception
    error('nbiot:stage2:ProgressFormat','Cannot decode Stage 2 progress: %s.',exception.message);
end
required={'schemaVersion','scope','status','identity','identitySha256','caseSpecs', ...
    'caseSpecsSha256','assignedIds','caseRecords','pendingCaseKeys','activeCase','owner'};
if ~isstruct(progress)||~isscalar(progress)||~all(isfield(progress,required))|| ...
        progress.schemaVersion~=1||~isstruct(progress.caseRecords)
    error('nbiot:stage2:ProgressFormat','Stage 2 progress schema is invalid.');
end
end

function index=caseIndex(progress,key)
index=find(strcmp({progress.caseRecords.caseKey},key),1);
if isempty(index), error('nbiot:stage2:ProgressCase','Unknown Stage 2 case %s.',key); end
end

function progress=refreshPending(progress)
progress.pendingCaseKeys=caseKeys(progress.caseRecords(~strcmp({progress.caseRecords.status},'completed')));
end

function keys=caseKeys(records)
if isempty(records), keys={}; else, keys=reshape({records.caseKey},1,[]); end
end

function path=artifactPath(progressFile,relative)
if isAbsolute(relative)||contains(relative,'..')
    error('nbiot:stage2:ProgressEvidence','Evidence path must stay inside the Stage 2 run folder.');
end
path=fullfile(fileparts(progressFile),strrep(relative,'/',filesep));
end

function verifyArtifact(path,key,identitySha256)
try, saved=load(path,'stage2Evidence');
catch exception
    error('nbiot:stage2:ProgressEvidence','Cannot load saved Stage 2 case %s: %s.',key,exception.message);
end
if ~isfield(saved,'stage2Evidence')
    error('nbiot:stage2:ProgressEvidence','Saved Stage 2 case lacks its atomic identity wrapper: %s.',key);
end
verifyEvidence(saved.stage2Evidence,key,identitySha256);
end

function verifyEvidence(evidence,key,identitySha256)
if ~isstruct(evidence)||~isscalar(evidence)|| ...
        ~all(isfield(evidence,{'caseKey','identitySha256','payload'}))|| ...
        ~strcmp(evidence.caseKey,key)||~strcmp(evidence.identitySha256,identitySha256)|| ...
        ~isstruct(evidence.payload)||~isscalar(evidence.payload)
    error('nbiot:stage2:ProgressEvidence','Stage 2 case identity is invalid: %s.',key);
end
end

function progress=writeProgress(path,progress)
progress=refreshPending(progress); progress.updatedAtUtc=utcNow();
folder=fileparts(path); if ~isfolder(folder), mkdir(folder); end
temporary=[path '.' char(java.util.UUID.randomUUID()) '.tmp'];
cleanup=onCleanup(@() deleteTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:stage2:ProgressWrite','Cannot create Stage 2 progress file.'); end
closeFile=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(progress,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:stage2:ProgressWrite','Cannot write complete Stage 2 progress file.');
end
clear closeFile
[ok,message]=movefile(temporary,path,'f');
if ~ok, error('nbiot:stage2:ProgressWrite','Cannot publish Stage 2 progress file: %s.',message); end
end

function record=emptyRecord()
record=struct('caseKey','','kind','','realizationId',0,'evidenceFile','', ...
    'status','','sha256','','startedAtUtc','','finishedAtUtc','');
end

function owner=ownerIdentity()
owner=struct('processId',double(feature('getpid')),'matlabRelease',version('-release'), ...
    'startedAtUtc',utcNow());
end

function value=utcNow()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS'));
end

function value=hashText(text)
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(uint8(unicode2native(text,'UTF-8')));
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function value=fileHash(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:stage2:ProgressEvidence','Cannot read evidence %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8'); if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function yes=isAbsolute(path)
path=char(string(path)); yes=startsWith(path,'/')||startsWith(path,'\\')|| ...
    ~isempty(regexp(path,'^[A-Za-z]:[\\/]','once'));
end

function deleteTemporary(path)
if isfile(path), delete(path); end
end
