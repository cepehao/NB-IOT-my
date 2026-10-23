function [tx,state]=mandatoryDL(cfg,tick,state)
%MANDATORYDL Формирует обязательный подкадр DL соты: NPSS, NSSS, NPBCH (MIB-NB) или SIB1-NB.
%   Эти сигналы занимают ресурсы DL и создают реальную нагрузку на канал; сами по себе процедуру
%   поиска соты не моделируют (UE заранее знает параметры соты, ADR-005). STATE — состояние
%   кодера SIB1-NB между подкадрами пакета.
if nargin<3 || isempty(state), state=struct('sibEncoder',[]); end
nbiot.phy.requireToolbox({'lteNPSS','lteNSSS','lteNPBCH','lteBCH','lteNRS','lteNDLSCH'});
[mask,kinds]=nbiot.scheduler.mandatoryDlMask(tick+1,cfg.phy.cellId);
if ~mask(end), tx=[]; return; end
enb=struct('NNCellID',cfg.phy.cellId,'NBRefP',1,'OperationMode','Standalone',...
    'NFrame',floor(tick/10),'NSubframe',mod(tick,10),'Windowing',0);
grid=complex(zeros(12,14));
if kinds.npss(end)
    grid(lteNPSSIndices(enb))=lteNPSS(enb); kind='NPSS';
elseif kinds.nsss(end)
    grid(lteNSSSIndices(enb))=lteNSSS(enb); kind='NSSS';
elseif kinds.npbch(end)
    % Fixed bootstrap MIB-NB payload: schedulingInfoSIB1=0. SFN MSBs vary.
    mib=zeros(34,1,'int8'); mib(1:4)=int8(bitget(uint16(floor(enb.NFrame/64)),4:-1:1)');
    cw=lteBCH(mib,1600,1); grid(lteNPBCHIndices(enb))=lteNPBCH(enb,cw);
    grid(lteNRSIndices(enb))=lteNRS(enb); kind='NPBCH';
else
    % SIB1-NB: NPDSCH 8 подкадров × 4 повтора, RNTI 0xFFFF, фиксированная полезная нагрузка.
    chs=struct('NSF',8,'NRep',4,'NPDSCHDataType','SIB1NB','RNTI',65535);
    [~,info]=lteNPDSCHIndices(enb,chs); cw=lteNDLSCH(info.G,zeros(208,1,'int8'));
    % SIB1-NB is a fixed bootstrap bit payload; full ASN.1 RRC is out of scope.
    [sym,state.sibEncoder]=lteNPDSCH(enb,chs,cw,state.sibEncoder);
    grid(lteNPDSCHIndices(enb,chs))=sym; grid(lteNRSIndices(enb))=lteNRS(enb); kind='SIB1NB';
end
g=struct('grantId',0,'kind',kind,'startTick',tick);
tx=nbiot.phy.transmission(cfg,g,nbiot.phy.dlModulate(enb,grid),1);
end
