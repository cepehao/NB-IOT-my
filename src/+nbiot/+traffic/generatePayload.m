function bits=generatePayload(packetId,sizeBytes,sources)
%GENERATEPAYLOAD Случайная полезная нагрузка пакета PACKETID размером SIZEBYTES (поток 'payload').
%   Отдельная утилита; сценарий использует потоки по UE (generateArrivals).
validateattributes(packetId,{'numeric'},{'scalar','integer','>=',1,'<=',2^24-1});
validateattributes(sizeBytes,{'numeric'},{'scalar','integer','positive'});
s=sources.stream('payload',0,0,packetId);
bits=int8(rand(s,8*sizeBytes,1)>=.5);
end
