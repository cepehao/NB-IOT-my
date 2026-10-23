function tx=buildTransmission(cfg,g,dci)
nbiot.phy.requireToolbox({'lteNPDCCH','lteDCIEncode','lteNRS','lteSCFDMAModulate'});
[enb,chs]=nbiot.phy.dlConfig(cfg,g,true);
[~,info]=lteNPDCCHIndices(enb,chs);
cw=lteDCIEncode(struct('RNTI',double(g.rnti),'PDCCHFormat',1),nbiot.phy.npdcch.packDci(dci),info.G);
estate=[]; wave=complex(zeros((g.endTick-g.startTick)*1920,1)); ranges=zeros(numel(g.ticks),2);
for k=1:numel(g.ticks)
    t=g.ticks(k); enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    grid=complex(zeros(12,14));
    [sym,estate]=lteNPDCCH(enb,chs,cw,estate);
    grid(lteNPDCCHIndices(enb,chs))=sym;
    grid(lteNRSIndices(enb))=lteNRS(enb);
    w=nbiot.phy.dlModulate(enb,grid); offset=(t-g.startTick)*1920;
    wave(offset+(1:1920))=w; ranges(k,:)=[offset offset+1920];
end
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPDCCH bundle incomplete.');
tx=nbiot.phy.transmission(cfg,g,wave,1,ranges);
end
