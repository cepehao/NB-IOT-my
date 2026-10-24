function [tx,state]=buildTransmission(cfg,g,bits,state)
%BUILDTRANSMISSION Waveform NPUSCH для назначения G (ТЗ §20 п.1–2): Msg3, данные или ACK.
%   [TX, STATE] = buildTransmission(CFG, G, BITS, STATE)
%   Формат 1 (Data): канальное кодирование lteNULSCH с CRC, турбо-код, rate matching под RV;
%   формат 2 (Control): 1 бит UCI, без CRC. Затем по слотам 0,5 мс: символы lteNPUSCH, опорные
%   DM-RS lteNPUSCHDRS, SC-FDMA lteSCFDMAModulate (960 отсчётов на слот при 1,92 МГц).
%   BITS — int8 0/1, длина = TBS профиля (бит). Повторы NRep чередуют RV: g.rv и 2−g.rv (TS 36.213).
%   STATE — состояние кодера для HARQ (NDI, RV).
% Без состояния кодера — пустое.
if nargin<4, state=[]; end
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNULSCH','lteNPUSCH','lteNPUSCHDRS','lteSCFDMAModulate'});
% Параметры LTE Toolbox (ue, chs) для назначения и профиль канала.
[ue,chs]=nbiot.phy.npusch.configure(cfg,g); p=g.profile;
% Число бит должно равняться TBS профиля.
assert(numel(bits)==p.tbs,'nbiot:phy:TBS','Payload length must equal transport block size.');
% Состояние кодера символов (номер слота); номер блока повторов; число слотов передачи.
estate=struct('SlotIdx',0); block=0; nslots=p.nru*p.nulSlots*p.repetitions;
% Число слотов = NRU · NULSlots · NRep; буфер на всю передачу.
wave=complex(zeros(nslots*960,1));
% Ресурсы NPUSCH: info.G — число кодированных бит на транспортный блок.
[~,info]=lteNPUSCHIndices(ue,chs);
% Данные (формат 1):
if strcmp(p.format,'Data')
    % две версии избыточности: заданная RV и парная (0↔2) для чередования повторов; буфер кодовых слов;
    rv=[g.rv 2-mod(g.rv,4)]; cws=zeros(info.G,2,'int8');
    % кодирование UL-SCH для каждой RV: CRC, турбо-код, согласование скорости под G бит.
    for j=1:2, chs.RV=rv(j); cws(:,j)=lteNULSCH(chs,info.G,bits); end
else
    % ACK (формат 2): RV не используется; кодирование 1 бита UCI; одно слово для обоих вариантов.
    rv=[0 0]; cws=lteNULSCH(bits); cws=[cws cws];
end
% Абсолютный номер слота задаёт NFrame/NSlot — от них зависят скремблирование и DM-RS.
for s=0:nslots-1
    % абсолютный номер слота (2 слота на тик) → номер слота в кадре и номер кадра;
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    % позиция внутри передачи; RV текущего блока повторов (чередуется по блокам);
    chs.SlotIdx=estate.SlotIdx; chs.RV=rv(mod(block,2)+1);
    % пустая ресурсная сетка UL одного слота;
    grid=lteNBResourceGrid(ue);
    % символы NPUSCH (модуляция, скремблирование) кладутся в ресурсы канала;
    grid(lteNPUSCHIndices(ue,chs))=lteNPUSCH(ue,chs,cws(:,mod(block,2)+1),estate);
    % опорный сигнал DM-RS и обновлённое состояние;
    [dmrs,estate]=lteNPUSCHDRS(ue,chs,estate);
    % DM-RS — в его ресурсы;
    grid(lteNPUSCHDRSIndices(ue,chs))=dmrs;
    % SC-FDMA модуляция слота;
    [w,modinfo]=lteSCFDMAModulate(ue,chs,grid);
    % слот = 960 отсчётов при 1,92 МГц;
    assert(modinfo.SamplingRate==1920000 && size(w,1)==960,'nbiot:phy:SampleRate','Unexpected SC-FDMA slot shape.');
    % кладём слот в общий буфер;
    wave(s*960+(1:960))=w;
    % закончился блок повторов — следующий блок (сменится RV).
    if estate.EndOfBlk, block=block+1; end
end
% Кодер должен дойти до конца передачи.
assert(estate.EndOfTx,'nbiot:phy:Bundle','NPUSCH encoder did not complete bundle.');
% Состояние для HARQ: кодер, NDI, RV.
state=struct('encoder',estate,'ndi',g.ndi,'rv',g.rv);
% Передача UL (направление 0) для канала.
tx=nbiot.phy.transmission(cfg,g,wave,0);
end
