function bits=generatePayload(packetId,sizeBytes,sources)
%GENERATEPAYLOAD Случайная полезная нагрузка пакета PACKETID размером SIZEBYTES (поток 'payload').
%   Отдельная утилита; сценарий использует потоки по UE (generateArrivals).
% Номер пакета — целое 1..2^24−1 (используется как блок ключа случайности).
validateattributes(packetId,{'numeric'},{'scalar','integer','>=',1,'<=',2^24-1});
% Размер — целое положительное число байт.
validateattributes(sizeBytes,{'numeric'},{'scalar','integer','positive'});
% Поток 'payload', адресованный номером пакета.
s=sources.stream('payload',0,0,packetId);
% 8·размер случайных бит 0/1 столбцом int8.
bits=int8(rand(s,8*sizeBytes,1)>=.5);
end
