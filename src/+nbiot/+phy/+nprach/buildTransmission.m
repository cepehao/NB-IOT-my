function tx=buildTransmission(cfg,occasion,nInit)
%BUILDTRANSMISSION Waveform Msg1 (преамбула NPRACH) для возможности OCCASION и NINIT 0..11 (ТЗ §14 п.1–3).
%   Сигнал берётся из кэша шаблонов lteNPRACH (nbiot.phy.nprach.templates); индивидуальные мощность,
%   задержка, CFO и fading применяет канал.
validateattributes(nInit,{'numeric'},{'scalar','integer','>=',0,'<=',11});
bank=nbiot.phy.nprach.templates(cfg); t=bank{nInit+1};
g=struct('grantId',occasion.occasionId,'startTick',occasion.startTick,'kind','nprach');
if isfield(occasion,'grantId'), g.grantId=occasion.grantId; end
tx=nbiot.phy.transmission(cfg,g,t.waveform,0,t.activeRanges);
end
