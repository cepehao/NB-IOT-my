function value = fromBits(bits)
%FROMBITS Двоичный вектор (старший бит первым, до 64 бит) → uint64.
validateattributes(bits,{'numeric','logical'},{'vector','nonempty','numel',numel(bits)});
if numel(bits)>64 || any(bits~=0 & bits~=1)
    error('nbiot:protocol:Bits','Expected at most 64 binary bits.');
end
value=uint64(0);
for k=1:numel(bits), value=bitor(bitshift(value,1),uint64(bits(k))); end
end
