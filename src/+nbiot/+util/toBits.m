function bits = toBits(value,width)
%TOBITS Unsigned scalar to MSB-first int8 column, without extra toolboxes.
validateattributes(width,{'numeric'},{'scalar','integer','>=',1,'<=',64});
validateattributes(value,{'numeric'},{'scalar','real','finite','nonnegative'});
if double(value)~=fix(double(value)) || (width<64 && uint64(value)>=bitshift(uint64(1),width))
    error('nbiot:protocol:Range','Value does not fit in %d bits.',width);
end
bits=int8(bitget(uint64(value),width:-1:1).');
end
