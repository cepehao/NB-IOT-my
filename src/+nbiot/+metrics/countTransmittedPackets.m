function count=countTransmittedPackets(journal,actualTick)
%COUNTTRANSMITTEDPACKETS Count unique packets with a started NPUSCH data emission.
%   Число пакетов, у которых началась передача данных по NPUSCH (для snapshot, ТЗ §46.6).
validateattributes(actualTick,{'numeric'},{'scalar','real','finite','integer','nonnegative'});
if ~isstruct(journal)||(~isempty(journal)&&~all(isfield(journal,{'tick','kind','fields'})))
    error('nbiot:metrics:TransmittedPacketCount','The transmission journal has an unsupported format.');
end
count=0;
packetIds=zeros(1,0);
identityMissing=false;
for k=1:numel(journal)
    if journal(k).tick>=actualTick|| ...
            ~any(strcmp(journal(k).kind,{'emitted','unmatchedEmission'}))
        continue;
    end
    fields=journal(k).fields;
    if ~isstruct(fields)||~isfield(fields,'packetId')
        identityMissing=true;
        continue;
    end
    packetId=fields.packetId;
    if ~isnumeric(packetId)||~isscalar(packetId)||~isreal(packetId)|| ...
            ~isfinite(packetId)||packetId<1||packetId~=fix(packetId)
        error('nbiot:metrics:TransmittedPacketCount','A transmission has an invalid packet identity.');
    end
    packetIds(end+1)=double(packetId); %#ok<AGROW>
end
if identityMissing
    count=NaN;
else
    count=numel(unique(packetIds));
end
end
