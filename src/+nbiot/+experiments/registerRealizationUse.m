function entry=registerRealizationUse(registryFile,role,ids,source,status)
%REGISTERREALIZATIONUSE Atomically record a completed or planned ID allocation.
%   Запись использования номера реализации в реестр. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
if nargin<5, status='completed'; end
lockCleanup=nbiot.experiments.acquireRealizationRegistryLock(registryFile); %#ok<NASGU>
registry=readRegistry(registryFile); role=char(string(role)); source=char(string(source)); status=char(string(status));
if ~any(string(registry.roles)==string(role))
    error('nbiot:experiments:RegistryRole','Unknown realization role %s.',role);
end
if ~isnumeric(ids)||~isreal(ids)||~isvector(ids)||isempty(ids)||any(~isfinite(ids))||...
        any(ids~=fix(ids))||any(ids<registry.validRange(1)|ids>registry.validRange(2))
    error('nbiot:experiments:RegistryIds','IDs must be integer values in the registry range.');
end
ids=double(ids(:).');
if numel(unique(ids))~=numel(ids)
    error('nbiot:experiments:RegistryIds','Duplicate IDs are not allowed in one allocation.');
end
if isempty(source)||~ismember(status,{'planned','completed','failed'})
    error('nbiot:experiments:RegistryEntry','Source and valid status are required.');
end
occupied=[];
for k=1:numel(registry.reservations)
    r=registry.reservations(k);
    if isfield(r,'range'), occupied=[occupied double(r.range(1)):double(r.range(2))]; %#ok<AGROW>
    else, occupied=[occupied double(r.ids(:).')]; end %#ok<AGROW>
end
for k=1:numel(registry.assignments), occupied=[occupied double(registry.assignments(k).ids(:).')]; end %#ok<AGROW>
conflict=intersect(ids,occupied);
if ~isempty(conflict)
    error('nbiot:experiments:RegistryConflict','ID(s) already reserved or assigned: %s.',mat2str(conflict));
end
if isempty(registry.assignments)
    registry.assignments=struct('role',{},'ids',{},'source',{},'status',{},'recovery',{});
elseif ~isfield(registry.assignments,'recovery')
    [registry.assignments.recovery]=deal([]);
end
entry=struct('role',role,'ids',ids,'source',source,'status',status,'recovery',[]);
registry.assignments(end+1)=entry;
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
if isempty(registry.assignments)
    registry.assignments=struct('role',{},'ids',{},'source',{},'status',{},'recovery',{});
elseif ~isfield(registry.assignments,'recovery')
    [registry.assignments.recovery]=deal([]);
end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
