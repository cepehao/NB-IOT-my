function hex=configSha256(cfg,canonicalOrder)
%CONFIGSHA256 Hash a run configuration independently of its output location.
% Default preserves schema-1 hashes. Schema 2 explicitly selects canonical order.
if nargin<2, canonicalOrder=false; end
if isfield(cfg,'logging') && isfield(cfg.logging,'outputFolder')
    cfg.logging.outputFolder='<case-output>';
end
if canonicalOrder, cfg=canonical(cfg); end
bytes=unicode2native(jsonencode(cfg),'UTF-8');
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(uint8(bytes(:)),'int8'));
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function value=canonical(value)
if isstruct(value)
    value=orderfields(value); names=fieldnames(value);
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
end
end
