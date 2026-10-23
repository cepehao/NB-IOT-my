function reconcileFailedRealizationUse(registryFile,role,ids,recoverySource,evidenceManifestSha256,reason)
%RECONCILEFAILEDREALIZATIONUSE Mark a validated, fully recovered run complete.
if ~ischar(recoverySource)||isempty(strtrim(recoverySource))||...
        ~ischar(reason)||isempty(strtrim(reason))||...
        ~ischar(evidenceManifestSha256)||isempty(regexp(evidenceManifestSha256,'^[0-9a-f]{64}$','once'))
    error('nbiot:experiments:Recovery',...
        'Recovery requires a source, a lowercase SHA-256 evidence manifest, and an audit reason.');
end
lockCleanup=nbiot.experiments.acquireRealizationRegistryLock(registryFile); %#ok<NASGU>
try
    registry=jsondecode(fileread(registryFile));
catch exception
    error('nbiot:experiments:RegistryFormat','Cannot decode registry: %s.',exception.message);
end
required={'schemaVersion','validRange','roles','reservations','assignments'};
if ~all(isfield(registry,required))||registry.schemaVersion~=1||numel(registry.validRange)~=2
    error('nbiot:experiments:RegistryFormat','Registry schema is invalid or unsupported.');
end
role=char(string(role)); ids=double(ids(:).');
if isempty(registry.assignments)
    error('nbiot:experiments:Recovery','No failed assignment matches the recovery request.');
end
match=[];
for k=1:numel(registry.assignments)
    a=registry.assignments(k);
    if strcmp(a.role,role)&&isequal(double(a.ids(:).'),ids)
        match=k; break
    end
end
if isempty(match)
    error('nbiot:experiments:Recovery','No failed assignment matches the exact role and ID set.');
end
assignment=registry.assignments(match);
if strcmp(assignment.status,'completed')&&isfield(assignment,'recovery')&&...
        isstruct(assignment.recovery)&&isfield(assignment.recovery,'evidenceManifestSha256')&&...
        strcmp(assignment.recovery.evidenceManifestSha256,evidenceManifestSha256)
    return
end
if ~strcmp(assignment.status,'failed')
    error('nbiot:experiments:Recovery','Only a failed allocation can be reconciled.');
end
registry.assignments(match).status='completed';
registry.assignments(match).recovery=struct(...
    'source',recoverySource,...
    'evidenceManifestSha256',evidenceManifestSha256,...
    'reason',reason,...
    'timestampUtc',char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss'Z'")));
folder=fileparts(registryFile); temporary=[tempname(folder) '.json'];
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:RegistryWrite','Cannot create temporary registry file.'); end
closeFile=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(registry,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:experiments:RegistryWrite','Could not write complete registry.');
end
clear closeFile
[ok,message]=movefile(temporary,registryFile,'f');
if ~ok, error('nbiot:experiments:RegistryWrite','Cannot commit registry: %s',message); end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
