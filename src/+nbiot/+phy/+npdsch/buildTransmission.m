function [tx,state]=buildTransmission(cfg,g,bits,state)
%BUILDTRANSMISSION Waveform NPDSCH (ТЗ §19): RAR, Msg4 или квитанция. Кодирование lteNDLSCH (CRC 24,
%   турбо-код), символы lteNPDSCH по подкадрам G.ticks, NRS, OFDM-модуляция. BITS — int8, длина = TBS.
if nargin<4, state=[]; end
nbiot.phy.requireToolbox({'lteNDLSCH','lteNPDSCH','lteNRS','lteSCFDMAModulate'});
assert(numel(bits)==g.profile.tbs,'nbiot:phy:TBS','NPDSCH payload does not match TBS.');
[enb,chs]=nbiot.phy.dlConfig(cfg,g,false); [~,info]=lteNPDSCHIndices(enb,chs);
cw=lteNDLSCH(info.G,bits); estate=[];
wave=complex(zeros((g.endTick-g.startTick)*1920,1)); ranges=zeros(numel(g.ticks),2);
for k=1:numel(g.ticks)
    t=g.ticks(k); enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    grid=complex(zeros(12,14)); [sym,estate]=lteNPDSCH(enb,chs,cw,estate);
    grid(lteNPDSCHIndices(enb,chs))=sym; grid(lteNRSIndices(enb))=lteNRS(enb);
    w=nbiot.phy.dlModulate(enb,grid); offset=(t-g.startTick)*1920;
    wave(offset+(1:1920))=w; ranges(k,:)=[offset offset+1920];
end
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPDSCH bundle incomplete.');
state=struct('encoder',estate,'ndi',g.ndi); tx=nbiot.phy.transmission(cfg,g,wave,1,ranges);
end
