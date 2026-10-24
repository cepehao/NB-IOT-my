function count=countTransmittedPackets(journal,actualTick)
%COUNTTRANSMITTEDPACKETS Count unique packets with a started NPUSCH data emission.
%   Число пакетов, у которых началась передача данных по NPUSCH (для snapshot, ТЗ §46.6).
% Горизонт — неотрицательный целый тик.
validateattributes(actualTick,{'numeric'},{'scalar','real','finite','integer','nonnegative'});
% Журнал HARQ — struct событий (тик, вид, поля).
if ~isstruct(journal)||(~isempty(journal)&&~all(isfield(journal,{'tick','kind','fields'})))
    error('nbiot:metrics:TransmittedPacketCount','The transmission journal has an unsupported format.');
end
% Счётчик.
count=0;
% Номера пакетов с начатой передачей.
packetIds=zeros(1,0);
% Признак: у какого-то события нет номера пакета.
identityMissing=false;
% Для каждого события журнала:
for k=1:numel(journal)
    % интересуют только начатые передачи данных до горизонта;
    if journal(k).tick>=actualTick|| ...
            ~any(strcmp(journal(k).kind,{'emitted','unmatchedEmission'}))
        continue;
    end
    % поля события;
    fields=journal(k).fields;
    % нет номера пакета —
    if ~isstruct(fields)||~isfield(fields,'packetId')
        % отмечаем и пропускаем;
        identityMissing=true;
        continue;
    end
    % номер пакета;
    packetId=fields.packetId;
    % номер должен быть конечным неотрицательным целым;
    if ~isnumeric(packetId)||~isscalar(packetId)||~isreal(packetId)|| ...
            ~isfinite(packetId)||packetId<1||packetId~=fix(packetId)
        error('nbiot:metrics:TransmittedPacketCount','A transmission has an invalid packet identity.');
    end
    % запоминаем.
    packetIds(end+1)=double(packetId); %#ok<AGROW>
end
% Если номера были не у всех —
if identityMissing
    % число неизвестно;
    count=NaN;
else
    % иначе — число разных пакетов.
    count=numel(unique(packetIds));
end
end
