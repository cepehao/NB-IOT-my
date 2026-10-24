function [decode,state]=receive(cfg,rx,g,state)
%RECEIVE Приём NPDSCH на UE: dlReceiveGrid по подкадрам, lteNPDSCHDecode, lteNDLSCHDecode с CRC.
%   DECODE.crcError = 0 — блок принят; мягкий буфер сохраняется для повтора с тем же NDI.
% Без состояния HARQ — пустое.
if nargin<4 || isempty(state), state=struct(); end
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNPDSCHDecode','lteNDLSCHDecode','lteDLChannelEstimate'});
% Новый NDI — новый блок: мягкий буфер сбрасывается.
if ~isfield(state,'ndi') || state.ndi~=g.ndi, state=struct('ndi',g.ndi,'transport',[]); end
% Параметры соты и NPDSCH; состояние декодера.
[enb,chs]=nbiot.phy.dlConfig(cfg,g,false); dstate=[];
% Для каждого подкадра:
for t=g.ticks(:)'
    % номер кадра и подкадра;
    enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    % приём подкадра: синхронизация, CFO, оценка канала;
    [grid,h,n,sync]=nbiot.phy.dlReceiveGrid(cfg,rx,t);
    % символы NPDSCH и оценки канала на них;
    [sym,hs]=lteExtractResources(lteNPDSCHIndices(enb,chs),grid,h);
    % демодуляция в мягкие биты с накоплением по повторам.
    [cw,dstate]=lteNPDSCHDecode(enb,chs,sym,hs,n,dstate);
end
% Декодер должен получить весь пакет повторов.
assert(dstate.EndOfTx,'nbiot:phy:Bundle','NPDSCH receive bundle incomplete.');
% Декодирование DL-SCH с проверкой CRC (мягкий буфер сохраняется).
[bits,err,state.transport]=lteNDLSCHDecode(g.profile.tbs,cw,state.transport);
% Результат: биты, CRC есть, ошибка, статус, измерения.
decode=struct('decodedBits',int8(bits(:)),'hasCrc',true,'crcError',logical(err),...
    'status','crc_failure','measurements',struct('noiseEstimate',n,'synchronization',sync));
% CRC прошёл — статус decoded.
if err==0, decode.status='decoded'; end
end
