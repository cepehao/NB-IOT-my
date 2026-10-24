function tx=buildMandatoryTransmission(cfg,tick)
%BUILDMANDATORYTRANSMISSION Обязательный DL-сигнал соты на тике TICK (NPSS, NSSS, NPBCH, SIB1-NB).
%   Фаза пакета SIB1-NB вычисляется из абсолютного номера кадра, поэтому функция без состояния.
%   Пустой результат — в этом подкадре обязательного сигнала нет.
% Какие обязательные сигналы выпадают на этот тик.
[~,kinds]=nbiot.scheduler.mandatoryDlMask(tick+1,cfg.phy.cellId);
% Состояние кодера SIB1-NB по умолчанию — пустое.
state=[];
% Если это подкадр SIB1-NB —
if kinds.sib1(end)
    % начальный кадр блоков SIB1: 16·(NCellID mod 4);
    startFrame=16*mod(cfg.phy.cellId,4);
    % номер кадра относительно начала периода 256 кадров;
    relative=mod(floor(tick/10)-startFrame,256);
    % номер подкадра внутри пакета повторов SIB1 (8 подкадров на повтор);
    index=8*floor(relative/64)+floor(mod(relative,64)/2);
    % состояние кодера, указывающее этот подкадр.
    state=struct('sibEncoder',struct('SubframeIdx',index));
end
% Формирование обязательного подкадра.
tx=nbiot.phy.mandatoryDL(cfg,tick,state);
end
