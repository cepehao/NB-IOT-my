function lines=formatLiveStateSummary(state)
%FORMATLIVESTATESUMMARY Summarize current UE stages and unfinished packets.
%   Текст текущего состояния: UE по этапам, незавершённые пакеты (ТЗ §46.6).
if ~isstruct(state)||~isscalar(state)|| ...
        ~all(isfield(state,{'deviceTable','packetCounters','transmittedPacketCount'}))|| ...
        ~iscell(state.deviceTable)||size(state.deviceTable,2)~=4|| ...
        ~isstruct(state.packetCounters)|| ...
        ~all(isfield(state.packetCounters,{'created','delivered','dropped'}))
    error('nbiot:ui:LiveSummary','Live state does not match the supported display format.');
end
states=upper(string(state.deviceTable(:,2)));
if isempty(states), states=strings(0,1); end
queues=zeros(size(states));
for k=1:numel(queues)
    value=state.deviceTable{k,3};
    if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<0
        error('nbiot:ui:LiveSummary','Device queue counts must be nonnegative finite numbers.');
    end
    queues(k)=double(value);
end
counters=double([state.packetCounters.created,state.packetCounters.delivered, ...
    state.packetCounters.dropped]);
if any(~isfinite(counters))||any(counters<0)||any(counters~=fix(counters))|| ...
        counters(2)+counters(3)>counters(1)
    error('nbiot:ui:LiveSummary','Packet counters are inconsistent.');
end
transmitted=state.transmittedPacketCount;
if ~isnumeric(transmitted)||~isscalar(transmitted)||~isreal(transmitted)|| ...
        ~(isnan(transmitted)||(isfinite(transmitted)&&transmitted>=0&&transmitted==fix(transmitted)))
    error('nbiot:ui:LiveSummary','Transmitted packet count must be a nonnegative integer or unavailable.');
end
active=nnz(states~="IDLE");
raStates=["WAIT_RA","WAIT_RAR","WAIT_MSG4","BACKOFF"];
transferStates=["DATA","WAIT_RECEIPT","MSG4_ACK","RECEIPT_ACK"];
ra=nnz(ismember(states,raStates)); transfer=nnz(ismember(states,transferStates));
waitingForAccess=nnz(states=="WAIT_RA");
waitingForResponse=nnz(ismember(states,["WAIT_RAR","WAIT_MSG4"]));
waitingForRetry=nnz(states=="BACKOFF");
if isnan(transmitted), transmittedText='не определено';
else, transmittedText=sprintf('%d',transmitted); end
lines={sprintf(['UE: всего %d; активны %d; передача/подтверждение %d; ' ...
    'устройств с пакетом в очереди %d'], ...
    numel(states),active,transfer,nnz(queues>0)), ...
    sprintf('RA: всего %d (ожидают доступа: %d; ответа станции: %d; повторного доступа: %d)', ...
    ra,waitingForAccess,waitingForResponse,waitingForRetry), ...
sprintf(['Пакеты: отправлено %s (передача начата); создано %d, ' ...
    'доставлено %d, отброшено %d, ещё в работе %d'], ...
        transmittedText,counters(1),counters(2),counters(3), ...
    counters(1)-counters(2)-counters(3))};
end
