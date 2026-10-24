function [tx,state]=buildTransmission(cfg,g,bits,state)
%BUILDTRANSMISSION Waveform NPDSCH (ТЗ §19): RAR, Msg4 или квитанция. Кодирование lteNDLSCH (CRC 24,
%   турбо-код), символы lteNPDSCH по подкадрам G.ticks, NRS, OFDM-модуляция. BITS — int8, длина = TBS.
% Без состояния кодера — пустое.
if nargin<4, state=[]; end
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNDLSCH','lteNPDSCH','lteNRS','lteSCFDMAModulate'});
% Число бит равно TBS профиля.
assert(numel(bits)==g.profile.tbs,'nbiot:phy:TBS','NPDSCH payload does not match TBS.');
% Параметры соты и NPDSCH; info.G — число кодированных бит.
[enb,chs]=nbiot.phy.dlConfig(cfg,g,false); [~,info]=lteNPDSCHIndices(enb,chs);
% Кодирование DL-SCH: CRC 24, турбо-код, согласование скорости; состояние кодера.
cw=lteNDLSCH(info.G,bits); estate=[];
% Буфер waveform на все тики назначения; активные интервалы по подкадрам.
wave=complex(zeros((g.endTick-g.startTick)*1920,1)); ranges=zeros(numel(g.ticks),2);
% Для каждого подкадра:
for k=1:numel(g.ticks)
    % номер кадра и подкадра;
    t=g.ticks(k); enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    % пустая сетка; символы NPDSCH подкадра;
    grid=complex(zeros(12,14)); [sym,estate]=lteNPDSCH(enb,chs,cw,estate);
    % символы — в ресурсы NPDSCH, NRS — в свои ресурсы;
    grid(lteNPDSCHIndices(enb,chs))=sym; grid(lteNRSIndices(enb))=lteNRS(enb);
    % OFDM-модуляция; смещение в буфере;
    w=nbiot.phy.dlModulate(enb,grid); offset=(t-g.startTick)*1920;
    % кладём в буфер и отмечаем активный интервал.
    wave(offset+(1:1920))=w; ranges(k,:)=[offset offset+1920];
end
% Кодер должен выдать весь пакет повторов.
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPDSCH bundle incomplete.');
% Состояние (кодер, NDI) и передача DL.
state=struct('encoder',estate,'ndi',g.ndi); tx=nbiot.phy.transmission(cfg,g,wave,1,ranges);
end
