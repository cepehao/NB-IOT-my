function [tx,state]=buildTransmission(cfg,g,bits,state)
if nargin<4, state=[]; end
nbiot.phy.requireToolbox({'lteNULSCH','lteNPUSCH','lteNPUSCHDRS','lteSCFDMAModulate'});
[ue,chs]=nbiot.phy.npusch.configure(cfg,g); p=g.profile;
assert(numel(bits)==p.tbs,'nbiot:phy:TBS','Payload length must equal transport block size.');
estate=struct('SlotIdx',0); block=0; nslots=p.nru*p.nulSlots*p.repetitions;
wave=complex(zeros(nslots*960,1));
[~,info]=lteNPUSCHIndices(ue,chs);
if strcmp(p.format,'Data')
    rv=[g.rv 2-mod(g.rv,4)]; cws=zeros(info.G,2,'int8');
    for j=1:2, chs.RV=rv(j); cws(:,j)=lteNULSCH(chs,info.G,bits); end
else
    rv=[0 0]; cws=lteNULSCH(bits); cws=[cws cws];
end
for s=0:nslots-1
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    chs.SlotIdx=estate.SlotIdx; chs.RV=rv(mod(block,2)+1);
    grid=lteNBResourceGrid(ue);
    grid(lteNPUSCHIndices(ue,chs))=lteNPUSCH(ue,chs,cws(:,mod(block,2)+1),estate);
    [dmrs,estate]=lteNPUSCHDRS(ue,chs,estate);
    grid(lteNPUSCHDRSIndices(ue,chs))=dmrs;
    [w,modinfo]=lteSCFDMAModulate(ue,chs,grid);
    assert(modinfo.SamplingRate==1920000 && size(w,1)==960,'nbiot:phy:SampleRate','Unexpected SC-FDMA slot shape.');
    wave(s*960+(1:960))=w;
    if estate.EndOfBlk, block=block+1; end
end
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPUSCH encoder did not complete bundle.');
state=struct('encoder',estate,'ndi',g.ndi,'rv',g.rv);
tx=nbiot.phy.transmission(cfg,g,wave,0);
end
