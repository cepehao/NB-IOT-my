function bits=generatePayload(packetId,sizeBytes,sources)
%GENERATEPAYLOAD Standalone keyed packet payload (scenario uses per-UE streams).
validateattributes(packetId,{'numeric'},{'scalar','integer','>=',1,'<=',2^24-1});
validateattributes(sizeBytes,{'numeric'},{'scalar','integer','positive'});
s=sources.stream('payload',0,0,packetId);
bits=int8(rand(s,8*sizeBytes,1)>=.5);
end
