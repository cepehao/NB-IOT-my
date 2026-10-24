function value = fromBits(bits)
%FROMBITS Двоичный вектор (старший бит первым, до 64 бит) → uint64.
% Проверка входа: непустой вектор чисел или логических значений.
validateattributes(bits,{'numeric','logical'},{'vector','nonempty','numel',numel(bits)});
% Не больше 64 бит (вмещается в uint64) и только значения 0/1 — иначе ошибка протокола.
if numel(bits)>64 || any(bits~=0 & bits~=1)
    error('nbiot:protocol:Bits','Expected at most 64 binary bits.');
end
% Начинаем с нуля и накапливаем число в беззнаковом 64-битном целом.
value=uint64(0);
% Для каждого бита (старший первым): сдвиг накопленного влево на 1 и запись бита в младший разряд.
for k=1:numel(bits), value=bitor(bitshift(value,1),uint64(bits(k))); end
end
