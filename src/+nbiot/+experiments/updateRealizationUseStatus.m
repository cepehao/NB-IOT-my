function updateRealizationUseStatus(registryFile,role,ids,status)
%UPDATEREALIZATIONUSESTATUS Close a previously registered planned allocation.
if ~ismember(status,{'completed','failed'})
    error('nbiot:experiments:RegistryEntry','Final status must be completed or failed.');
end
lockCleanup=nbiot.experiments.acquireRealizationRegistryLock(registryFile); %#ok<NASGU>
registry=readRegistry(registryFile); role=char(string(role)); ids=double(ids(:).');
if isempty(registry.assignments)
    error('nbiot:experiments:RegistryEntry','No planned allocation exists for this role and ID set.');
end
match=[];
for k=1:numel(registry.assignments)
    a=registry.assignments(k);
    if strcmp(a.role,role)&&strcmp(a.status,'planned')&&isequal(double(a.ids(:).'),ids)
        match=k; break
    end
end
if isempty(match)
    error('nbiot:experiments:RegistryEntry','No matching planned allocation exists for this role and ID set.');
end
registry.assignments(match).status=status;
folder=fileparts(registryFile); temporary=[tempname(folder) '.json'];
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:RegistryWrite','Cannot create temporary registry file.'); end
closeFile=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(registry,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes), error('nbiot:experiments:RegistryWrite','Could not write complete registry.'); end
clear closeFile
[ok,message]=movefile(temporary,registryFile,'f');
if ~ok, error('nbiot:experiments:RegistryWrite','Cannot commit registry: %s',message); end
end

function registry=readRegistry(path)
if ~isfile(path), error('nbiot:experiments:RegistryFile','Registry file does not exist: %s.',path); end
try
    registry=jsondecode(fileread(path));
catch exception
    error('nbiot:experiments:RegistryFormat','Cannot decode registry: %s',exception.message);
end
required={'schemaVersion','validRange','roles','reservations','assignments'};
if ~all(isfield(registry,required))||registry.schemaVersion~=1||numel(registry.validRange)~=2
    error('nbiot:experiments:RegistryFormat','Registry schema is invalid or unsupported.');
end
if isempty(registry.reservations), registry.reservations=struct('role',{},'range',{},'source',{},'note',{}); end
if isempty(registry.assignments), registry.assignments=struct('role',{},'ids',{},'source',{},'status',{}); end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
