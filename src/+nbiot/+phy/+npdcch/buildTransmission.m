function tx=buildTransmission(cfg,g,dci)
%BUILDTRANSMISSION Waveform NPDCCH с DCI (ТЗ §19): упаковка полей DCI (packDci, 23 бита),
%   кодирование с CRC, маскированным RNTI (lteDCIEncode), символы lteNPDCCH по подкадрам G.ticks
%   с повторами, NRS в каждом подкадре, OFDM-модуляция (1920 отсчётов на подкадр).
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNPDCCH','lteDCIEncode','lteNRS','lteSCFDMAModulate'});
% Параметры соты (enb) и канала NPDCCH (chs) для назначения.
[enb,chs]=nbiot.phy.dlConfig(cfg,g,true);
% info.G — число кодированных бит NPDCCH.
[~,info]=lteNPDCCHIndices(enb,chs);
% Поля DCI → 23 бита → кодирование с CRC, маскированным RNTI получателя (lteDCIEncode).
cw=lteDCIEncode(struct('RNTI',double(g.rnti),'PDCCHFormat',1),nbiot.phy.npdcch.packDci(dci),info.G);
% Состояние кодера; буфер waveform на все тики назначения; активные интервалы по подкадрам.
estate=[]; wave=complex(zeros((g.endTick-g.startTick)*1920,1)); ranges=zeros(numel(g.ticks),2);
% Для каждого подкадра назначения:
for k=1:numel(g.ticks)
    % тик подкадра → номер кадра и подкадра;
    t=g.ticks(k); enb.NFrame=floor(t/10); enb.NSubframe=mod(t,10);
    % пустая сетка DL: 12 поднесущих × 14 символов;
    grid=complex(zeros(12,14));
    % символы NPDCCH этого подкадра (с учётом повторов);
    [sym,estate]=lteNPDCCH(enb,chs,cw,estate);
    % кладём их в ресурсы NPDCCH;
    grid(lteNPDCCHIndices(enb,chs))=sym;
    % добавляем опорные сигналы NRS (по ним UE оценивает канал);
    grid(lteNRSIndices(enb))=lteNRS(enb);
    % OFDM-модуляция подкадра (1920 отсчётов); смещение подкадра в буфере;
    w=nbiot.phy.dlModulate(enb,grid); offset=(t-g.startTick)*1920;
    % кладём в буфер и отмечаем активный интервал.
    wave(offset+(1:1920))=w; ranges(k,:)=[offset offset+1920];
end
% Кодер должен выдать весь пакет повторов.
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPDCCH bundle incomplete.');
% Передача DL (направление 1) от BS.
tx=nbiot.phy.transmission(cfg,g,wave,1,ranges);
end
