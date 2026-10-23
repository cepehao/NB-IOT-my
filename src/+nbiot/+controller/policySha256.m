function digest=policySha256(policy)
%POLICYSHA256 SHA-256 канонической записи политики контроллера (для журнала решений и воспроизводимости).
defaults=adaptiveDefaults();
required=fieldnames(defaults);
if ~isstruct(policy)||~isscalar(policy)|| ...
        numel(fieldnames(policy))~=numel(required)|| ...
        ~isequal(sort(fieldnames(policy)),sort(required))
    error('nbiot:controller:PolicyDigest', ...
        'Policy fields must exactly match adaptiveDefaults.');
end

canonical=struct();
for k=1:numel(required)
    name=required{k}; expected=defaults.(name); value=policy.(name);
    if isnumeric(expected)
        if ~isnumeric(value)||~isreal(value)||isempty(value)||any(~isfinite(value(:)))
            error('nbiot:controller:PolicyDigest', ...
                'Numeric policy fields must contain finite real values.');
        end
        if isscalar(expected)
            if ~isscalar(value)
                error('nbiot:controller:PolicyDigest', ...
                    'Scalar policy fields must remain scalar.');
            end
        elseif ~isvector(value)||numel(value)~=numel(expected)
            error('nbiot:controller:PolicyDigest', ...
                'Policy vector fields must match adaptiveDefaults dimensions.');
        else
            value=reshape(double(value),1,[]);
        end
        if isscalar(value), value=double(value); end
    else
        if isstring(value)&&isscalar(value), value=char(value); end
        if ~ischar(value)||size(value,1)~=1
            error('nbiot:controller:PolicyDigest', ...
                'Text policy fields must be scalar character vectors.');
        end
    end
    canonical.(name)=value;
end

try
    bytes=unicode2native(jsonencode(canonical),'UTF-8');
    md=java.security.MessageDigest.getInstance('SHA-256');
    md.update(typecast(uint8(bytes),'int8'));
    digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
catch exception
    error('nbiot:controller:PolicyDigest', ...
        'Cannot compute canonical policy digest: %s',exception.message);
end
end
