function decode=receive(cfg,rx,g)
%RECEIVE Декодирование кандидата поиска NPDCCH на UE (ТЗ §19).
%   G — только публичный кандидат: подкадры, RNTI, ожидаемый формат. По каждому подкадру — приём
%   (dlReceiveGrid) и lteNPDCCHDecode; затем lteDCIDecode снимает CRC и возвращает RNTI.
%   CRC считается пройденным, если RNTI совпал с ожидаемым и формат DCI подходит.
nbiot.phy.requireToolbox({'lteNPDCCHDecode','lteDCIDecode','lteDLChannelEstimate'});
% Search-space input carries no payload assignment, grant ID or UE identity.
g.startTick=min(g.ticks); [enb,chs]=nbiot.phy.dlConfig(cfg,g,true); dstate=[];
for t=g.ticks(:)'
    enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    [grid,h,n,sync]=nbiot.phy.dlReceiveGrid(cfg,rx,t);
    [sym,hs]=lteExtractResources(lteNPDCCHIndices(enb,chs),grid,h);
    [cw,dstate]=lteNPDCCHDecode(enb,chs,sym,hs,n,dstate);
end
assert(dstate.EndOfTx,'nbiot:phy:Bundle','Monitoring candidate incomplete.');
[bits,rnti]=lteDCIDecode(23,cw);
err=double(rnti)~=double(g.rnti); dci=[];
if ~err
    dci=nbiot.phy.npdcch.unpackDci(bits);
    if isfield(g,'format') && ~isempty(g.format) && ~strcmp(dci.format,g.format), err=true; dci=[]; end
end
decode=struct('dci',dci,'decodedBits',int8(bits),'hasCrc',true,'crcError',logical(err),...
    'status','crc_failure','measurements',struct('noiseEstimate',n,'synchronization',sync));
if ~err, decode.status='decoded'; end
end
