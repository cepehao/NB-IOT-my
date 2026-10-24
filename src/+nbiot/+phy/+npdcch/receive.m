function decode=receive(cfg,rx,g)
%RECEIVE Декодирование кандидата поиска NPDCCH на UE (ТЗ §19).
%   G — только публичный кандидат: подкадры, RNTI, ожидаемый формат. По каждому подкадру — приём
%   (dlReceiveGrid) и lteNPDCCHDecode; затем lteDCIDecode снимает CRC и возвращает RNTI.
%   CRC считается пройденным, если RNTI совпал с ожидаемым и формат DCI подходит.
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNPDCCHDecode','lteDCIDecode','lteDLChannelEstimate'});
% Search-space input carries no payload assignment, grant ID or UE identity.
g.startTick=min(g.ticks); [enb,chs]=nbiot.phy.dlConfig(cfg,g,true); dstate=[];
% Для каждого подкадра кандидата:
for t=g.ticks(:)'
    % номер кадра и подкадра;
    enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    % приём подкадра: синхронизация, CFO, оценка канала и шума;
    [grid,h,n,sync]=nbiot.phy.dlReceiveGrid(cfg,rx,t);
    % символы NPDCCH и оценки канала на них;
    [sym,hs]=lteExtractResources(lteNPDCCHIndices(enb,chs),grid,h);
    % демодуляция в мягкие биты с накоплением по повторам.
    [cw,dstate]=lteNPDCCHDecode(enb,chs,sym,hs,n,dstate);
end
% Декодер должен получить весь пакет повторов.
assert(dstate.EndOfTx,'nbiot:phy:Bundle','Monitoring candidate incomplete.');
% Декодирование DCI: 23 бита и RNTI, которым маскирован CRC.
[bits,rnti]=lteDCIDecode(23,cw);
% Ошибка, если RNTI не тот, что ищет UE (чужой DCI или шум).
err=double(rnti)~=double(g.rnti); dci=[];
% RNTI совпал —
if ~err
    % разбираем поля DCI;
    dci=nbiot.phy.npdcch.unpackDci(bits);
    % формат DCI должен быть тем, что ищем, иначе считаем ошибкой.
    if isfield(g,'format') && ~isempty(g.format) && ~strcmp(dci.format,g.format), err=true; dci=[]; end
end
% Результат: DCI, биты, CRC есть, признак ошибки, статус, измерения.
decode=struct('dci',dci,'decodedBits',int8(bits),'hasCrc',true,'crcError',logical(err),...
    'status','crc_failure','measurements',struct('noiseEstimate',n,'synchronization',sync));
% Без ошибки — статус decoded.
if ~err, decode.status='decoded'; end
end
