function [decode,state]=receive(cfg,rx,g,state)
%RECEIVE Приём NPDSCH на UE: dlReceiveGrid по подкадрам, lteNPDSCHDecode, lteNDLSCHDecode с CRC.
%   DECODE.crcError = 0 — блок принят; мягкий буфер сохраняется для повтора с тем же NDI.
if nargin<4 || isempty(state), state=struct(); end
nbiot.phy.requireToolbox({'lteNPDSCHDecode','lteNDLSCHDecode','lteDLChannelEstimate'});
if ~isfield(state,'ndi') || state.ndi~=g.ndi, state=struct('ndi',g.ndi,'transport',[]); end
[enb,chs]=nbiot.phy.dlConfig(cfg,g,false); dstate=[];
for t=g.ticks(:)'
    enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    [grid,h,n,sync]=nbiot.phy.dlReceiveGrid(cfg,rx,t);
    [sym,hs]=lteExtractResources(lteNPDSCHIndices(enb,chs),grid,h);
    [cw,dstate]=lteNPDSCHDecode(enb,chs,sym,hs,n,dstate);
end
assert(dstate.EndOfTx,'nbiot:phy:Bundle','NPDSCH receive bundle incomplete.');
[bits,err,state.transport]=lteNDLSCHDecode(g.profile.tbs,cw,state.transport);
decode=struct('decodedBits',int8(bits(:)),'hasCrc',true,'crcError',logical(err),...
    'status','crc_failure','measurements',struct('noiseEstimate',n,'synchronization',sync));
if err==0, decode.status='decoded'; end
end
