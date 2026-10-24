function [enb,chs]=dlConfig(cfg,grant,control)
%DLCONFIG Параметры LTE Toolbox для DL-назначения GRANT: ENB (соты, кадр/подкадр по тику) и CHS
%   (CONTROL=true — NPDCCH: NCCE, повторы, RNTI; иначе NPDSCH: число подкадров, повторы, RNTI).
% Параметры соты: NNCellID, 1 антенный порт, standalone, кадр и подкадр по тику начала, без оконирования.
enb=struct('NNCellID',cfg.phy.cellId,'NBRefP',1,'OperationMode','Standalone',...
    'NFrame',floor(grant.startTick/10),'NSubframe',mod(grant.startTick,10),...
    'Windowing',0);
% Для NPDCCH:
if control
    % обе NCCE, повторы, RNTI получателя.
    chs=struct('NCCE',[0 1],'NRep',grant.profile.repetitions,'RNTI',double(grant.rnti));
else
    % Для NPDSCH: подкадров, повторы, RNTI, тип данных — не системная информация.
    chs=struct('NSF',grant.profile.nsf,'NRep',grant.profile.repetitions,...
        'RNTI',double(grant.rnti),'NPDSCHDataType','NotBCCH');
end
end
