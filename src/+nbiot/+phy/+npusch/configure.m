function [ue,chs]=configure(cfg,g)
%CONFIGURE Структуры UE и CHS для функций LTE Toolbox NPUSCH по назначению G.
%   Номера поднесущих 15 кГц — из частотного сдвига назначения (или явного subcarrierSet);
%   модуляция: Data — QPSK, Control (ACK) — BPSK; групповой скачок DM-RS включён.
p=g.profile;
% Calendar frequency is offset from lower edge of the 180 kHz allocation.
tone=round(g.frequencyStartHz/15000);
if isfield(p,'subcarrierSet'), tones=p.subcarrierSet; else, tones=tone+(0:p.numSubcarriers-1); end
assert(p.spacingHz==15000,'nbiot:phy:Profile','Only 15 kHz NPUSCH is configured.');
ue=struct('NNCellID',cfg.phy.cellId,'NBULSubcarrierSpacing','15kHz',...
    'NFrame',floor(g.startTick/10),'NSlot',mod(2*g.startTick,20),'Windowing',0);
if isfield(p,'modulation'), modulation=p.modulation;
elseif strcmp(p.format,'Control'), modulation='BPSK'; else, modulation='QPSK'; end
chs=struct('NPUSCHFormat',p.format,'NBULSubcarrierSet',tones,'NRUsc',numel(tones),...
    'NRU',p.nru,'NULSlots',p.nulSlots,'NRep',p.repetitions,'Modulation',modulation,...
    'RNTI',double(g.rnti),'NLayers',1,'CyclicShift',0,'SlotIdx',0,...
    'SeqGroupHopping','on','SeqGroup',0,'RV',g.rv,'NTurboDecIts',cfg.phy.decoderIterations);
end
