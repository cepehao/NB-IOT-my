function bits = toBits(value,width)
%TOBITS Неотрицательное целое VALUE → столбец int8 из WIDTH бит, старший бит первым.
% Ширина поля — целое от 1 до 64 бит.
validateattributes(width,{'numeric'},{'scalar','integer','>=',1,'<=',64});
% Значение — конечное неотрицательное число.
validateattributes(value,{'numeric'},{'scalar','real','finite','nonnegative'});
% Значение должно быть целым и помещаться в WIDTH бит (меньше 2^WIDTH), иначе ошибка.
if double(value)~=fix(double(value)) || (width<64 && uint64(value)>=bitshift(uint64(1),width))
    error('nbiot:protocol:Range','Value does not fit in %d bits.',width);
end
% bitget берёт биты с WIDTH-го (старшего) по 1-й (младший); результат — столбец int8 из 0/1.
bits=int8(bitget(uint64(value),width:-1:1).');
end
