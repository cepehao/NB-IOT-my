function tx=buildTransmission(cfg,occasion,nInit)
%BUILDTRANSMISSION Waveform Msg1 (преамбула NPRACH) для возможности OCCASION и NINIT 0..11 (ТЗ §14 п.1–3).
%   Сигнал берётся из кэша шаблонов lteNPRACH (nbiot.phy.nprach.templates); индивидуальные мощность,
%   задержка, CFO и fading применяет канал.
% NInit (номер преамбулы) — целое 0..11.
validateattributes(nInit,{'numeric'},{'scalar','integer','>=',0,'<=',11});
% Банк шаблонов всех 12 преамбул; берём шаблон выбранной.
bank=nbiot.phy.nprach.templates(cfg); t=bank{nInit+1};
% Назначение для передачи: номер возможности, тик начала, тип 'nprach'.
g=struct('grantId',occasion.occasionId,'startTick',occasion.startTick,'kind','nprach');
% Если у возможности есть номер назначения — используем его.
if isfield(occasion,'grantId'), g.grantId=occasion.grantId; end
% Передача UL (направление 0) с активной частью шаблона; мощность и канал — в RadioChannel.
tx=nbiot.phy.transmission(cfg,g,t.waveform,0,t.activeRanges);
end
