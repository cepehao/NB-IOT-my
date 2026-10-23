function [decode,state]=receive(cfg,rx,g,state)
%RECEIVE Приём NPUSCH на BS (ТЗ §20 п.4–7, §39): синхронизация, CFO, оценка канала, декодирование, CRC.
%   [DECODE, STATE] = receive(CFG, RX, G, STATE)
%   1) задержка по DM-RS (estimateTiming); 2) CFO по фазе DM-RS между соседними слотами (шаг 0,5 мс),
%      ограничение ±cfoLimitHz; 3) по слотам: SC-FDMA демодуляция, оценка канала
%      lteULChannelEstimateNPUSCH, демодуляция lteNPUSCHDecode; 4) по окончании блока —
%      lteNULSCHDecode с мягким объединением HARQ (STATE.transport сохраняется при том же NDI).
%   DECODE: decodedBits, hasCrc (Data — true, ACK — false), crcError (0 — успех; NaN для ACK),
%   измерения (CFO, шум, тайминг) и для ACK — признак uciDetected.
%   Детектор UCI: ACK засчитывается, только если когерентны и DM-RS, и мягкие биты кодового
%   слова — иначе чужая передача могла бы дать ложный ACK.
if nargin<4 || isempty(state), state=struct(); end
nbiot.phy.requireToolbox({'lteNPUSCHDecode','lteNULSCHDecode','lteULChannelEstimateNPUSCH'});
[ue,chs]=nbiot.phy.npusch.configure(cfg,g); p=g.profile;
% Новый NDI — новый транспортный блок: мягкий буфер HARQ сбрасывается.
if ~isfield(state,'ndi') || state.ndi~=g.ndi, state=struct('ndi',g.ndi,'transport',[]); end
if strcmp(p.format,'Control'), state=struct('ndi',g.ndi,'transport',[]); end
dstate=struct('SlotIdx',0); nslots=p.nru*p.nulSlots*p.repetitions; block=0;
[timingOffset,timing]=nbiot.phy.npusch.estimateTiming(cfg,rx,g,ue,chs);
firstSample=g.startTick*1920+timingOffset;
w=nbiot.phy.extractWindow(rx,firstSample,nslots*960);
% DM-RS based CFO estimate across slots. No propagation taps enter this path.
previous=[]; products=0; pilotState=struct('SlotIdx',0);
for s=0:nslots-1
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    chs.SlotIdx=pilotState.SlotIdx; grid=lteSCFDMADemodulate(ue,chs,w(s*960+(1:960)));
    [ref,pilotState]=lteNPUSCHDRS(ue,chs,pilotState);
    pilot=grid(lteNPUSCHDRSIndices(ue,chs))./ref;
    if ~isempty(previous), products=products+sum(conj(previous).*pilot); end
    previous=pilot;
end
cfo=angle(products)/(2*pi*0.0005); cfo=max(-cfg.channel.cfoLimitHz,min(cfg.channel.cfoLimitHz,cfo));
w=w.*exp(-1i*2*pi*cfo*(firstSample+(0:size(w,1)-1)')/1920000);
% Окно оценки канала: 23 поднесущих по частоте, 1 символ по времени, линейная интерполяция.
cec=struct('PilotAverage','UserDefined','FreqWindow',23,'TimeWindow',1,'InterpType','linear');
% Format2 has one frequency pilot; average its three DRS symbol positions.
if strcmp(p.format,'Control'), cec.TimeWindow=3; end
bits=[]; err=true; noise=[]; rv=[g.rv 2-mod(g.rv,4)]; pilotEstimates=[];
for s=0:nslots-1
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    chs.SlotIdx=dstate.SlotIdx; chs.RV=rv(mod(block,2)+1);
    grid=lteSCFDMADemodulate(ue,chs,w(s*960+(1:960)));
    reference=lteNPUSCHDRS(ue,chs,dstate);
    pilotEstimates=[pilotEstimates;grid(lteNPUSCHDRSIndices(ue,chs))./reference]; %#ok<AGROW>
    [h,n]=lteULChannelEstimateNPUSCH(ue,chs,cec,grid,dstate); n=max(real(n),eps);
    [sym,hs]=lteExtractResources(lteNPUSCHIndices(ue,chs),grid,h);
    [cw,dstate]=lteNPUSCHDecode(ue,chs,sym,hs,n,dstate);
    noise(end+1)=n; %#ok<AGROW>
    if dstate.EndOfBlk
        [bits,err,state.transport]=lteNULSCHDecode(chs,p.tbs,cw,state.transport);
        block=block+1;
    end
end
assert(dstate.EndOfTx,'nbiot:phy:Bundle','NPUSCH receiver did not complete bundle.');
hasCrc=strcmp(p.format,'Data');
if hasCrc
    if err==0, status='decoded'; else, status='crc_failure'; end
    crcError=logical(err);
else
    status='uci'; crcError=NaN;
end
coherence=abs(sum(pilotEstimates))^2/max(numel(pilotEstimates)*sum(abs(pilotEstimates).^2),realmin);
uciThreshold=.5;
if isfield(cfg.phy,'uciPilotCoherenceThreshold'), uciThreshold=cfg.phy.uciPilotCoherenceThreshold; end
% DM-RS does not identify the RNTI. Foreign Control can have perfect pilot
% coherence but inconsistent soft bits after this receiver's descrambling.
% Format 2 repeats one UCI bit in a 16-bit codeword. Check that consistency
% using received LLRs only; ACK and NACK use the same presence criterion.
uciCodewordCoherence=NaN; uciCodewordThreshold=.8;
if isfield(cfg.phy,'uciCodewordCoherenceThreshold'), uciCodewordThreshold=cfg.phy.uciCodewordCoherenceThreshold; end
if ~hasCrc
    soft=state.transport.CBSBuffers{1}; soft=soft(:);
    uciCodewordCoherence=abs(sum(soft))^2/max(numel(soft)*sum(abs(soft).^2),realmin);
end
decode=struct('decodedBits',int8(bits(:)),'hasCrc',hasCrc,'crcError',crcError,...
    'status',status,'measurements',struct('cfoHz',cfo,'noiseEstimate',mean(noise),...
    'pilotCoherence',coherence,'uciThreshold',uciThreshold,...
    'uciCodewordCoherence',uciCodewordCoherence,'uciCodewordThreshold',uciCodewordThreshold,...
    'uciDetected',~hasCrc && coherence>=uciThreshold && uciCodewordCoherence>=uciCodewordThreshold,...
    'uciReceiverRevision','pilot-and-codeword-v1','timing',timing));
end
