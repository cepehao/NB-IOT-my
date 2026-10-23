function ids=availableRealizationIds(registryFile,role,candidates)
%AVAILABLEREALIZATIONIDS Return candidate IDs not reserved or previously used.
lockCleanup=nbiot.experiments.acquireRealizationRegistryLock(registryFile); %#ok<NASGU>
registry=readRegistry(registryFile);
role=char(string(role));
if ~any(string(registry.roles)==string(role))
    error('nbiot:experiments:RegistryRole','Unknown realization role %s.',role);
end
if ~isnumeric(candidates)||~isreal(candidates)||~isvector(candidates)||isempty(candidates)||...
        any(~isfinite(candidates))||any(candidates~=fix(candidates))||...
        any(candidates<registry.validRange(1)|candidates>registry.validRange(2))
    error('nbiot:experiments:RegistryCandidates','Candidate IDs must be integer values in the registry range.');
end
ids=double(candidates(:).');
if numel(unique(ids))~=numel(ids)
    error('nbiot:experiments:RegistryCandidates','Candidate IDs must be unique.');
end
occupied=[];
for k=1:numel(registry.reservations)
    r=registry.reservations(k);
    if isfield(r,'range'), occupied=[occupied double(r.range(1)):double(r.range(2))]; %#ok<AGROW>
    else, occupied=[occupied double(r.ids(:).')]; end %#ok<AGROW>
end
for k=1:numel(registry.assignments), occupied=[occupied double(registry.assignments(k).ids(:).')]; end %#ok<AGROW>
ids=ids(~ismember(ids,occupied));
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
