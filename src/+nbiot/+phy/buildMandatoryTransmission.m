function tx=buildMandatoryTransmission(cfg,tick)
%BUILDMANDATORYTRANSMISSION Обязательный DL-сигнал соты на тике TICK (NPSS, NSSS, NPBCH, SIB1-NB).
%   Фаза пакета SIB1-NB вычисляется из абсолютного номера кадра, поэтому функция без состояния.
%   Пустой результат — в этом подкадре обязательного сигнала нет.
[~,kinds]=nbiot.scheduler.mandatoryDlMask(tick+1,cfg.phy.cellId);
state=[];
if kinds.sib1(end)
    startFrame=16*mod(cfg.phy.cellId,4);
    relative=mod(floor(tick/10)-startFrame,256);
    index=8*floor(relative/64)+floor(mod(relative,64)/2);
    state=struct('sibEncoder',struct('SubframeIdx',index));
end
tx=nbiot.phy.mandatoryDL(cfg,tick,state);
end
