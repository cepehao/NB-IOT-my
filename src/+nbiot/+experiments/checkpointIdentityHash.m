function digest=checkpointIdentityHash(identity)
%CHECKPOINTIDENTITYHASH Stable hash for the serializable runtime identity.
%   Хеш идентичности чекпоинта (продолжение долгого прогона).
if ~isstruct(identity)||~isscalar(identity)
    error('nbiot:experiments:CheckpointIdentity','Checkpoint identity must be a scalar structure.');
end
bytes=unicode2native(jsonencode(canonical(identity)),'UTF-8');
sha=java.security.MessageDigest.getInstance('SHA-256');
sha.update(typecast(uint8(bytes(:)),'int8'));
digest=lower(reshape(dec2hex(typecast(sha.digest(),'uint8'),2).',1,[]));
end

function value=canonical(value)
if isstruct(value)
    value=orderfields(value); names=fieldnames(value);
    for i=1:numel(value)
        for k=1:numel(names), value(i).(names{k})=canonical(value(i).(names{k})); end
    end
elseif iscell(value)
    for k=1:numel(value), value{k}=canonical(value{k}); end
elseif isa(value,'function_handle')|| (isobject(value)&&~isstring(value))
    error('nbiot:experiments:CheckpointIdentity', ...
        'Runtime identity cannot contain executable handles or MATLAB objects.');
end
end
