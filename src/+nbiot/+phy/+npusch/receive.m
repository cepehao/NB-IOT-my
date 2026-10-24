function [decode,state]=receive(cfg,rx,g,state)
%RECEIVE Приём NPUSCH на BS (ТЗ §20 п.4–7, §39): синхронизация, CFO, оценка канала, декодирование, CRC.
%   [DECODE, STATE] = receive(CFG, RX, G, STATE)
%   1) задержка по DM-RS (estimateTiming); 2) CFO по фазе DM-RS между соседними слотами (шаг 0,5 мс),
%      ограничение ±cfoLimitHz; 3) по слотам: SC-FDMA демодуляция, оценка канала
%      lteULChannelEstimateNPUSCH, демодуляция lteNPUSCHDecode; 4) по окончании блока —
%      lteNULSCHDecode с мягким объединением HARQ (STATE.transport сохраняется при том же NDI).
%   DECODE: decodedBits, hasCrc (Data — true, ACK — false), crcError (0 — успех; NaN для ACK),
%   измерения (CFO, шум, тайминг) и для ACK — признак uciDetected.
%   Детектор UCI: ACK засчитывается, только если когерентны и DM-RS, и мягкие биты кодового
%   слова — иначе чужая передача могла бы дать ложный ACK.
% Без состояния HARQ — пустое.
if nargin<4 || isempty(state), state=struct(); end
% Проверяем функции LTE Toolbox.
nbiot.phy.requireToolbox({'lteNPUSCHDecode','lteNULSCHDecode','lteULChannelEstimateNPUSCH'});
% Параметры LTE Toolbox и профиль.
[ue,chs]=nbiot.phy.npusch.configure(cfg,g); p=g.profile;
% Новый NDI — новый транспортный блок: мягкий буфер HARQ сбрасывается.
if ~isfield(state,'ndi') || state.ndi~=g.ndi, state=struct('ndi',g.ndi,'transport',[]); end
% ACK не накапливается между передачами — состояние всегда новое.
if strcmp(p.format,'Control'), state=struct('ndi',g.ndi,'transport',[]); end
% Состояние декодера символов; число слотов; номер блока повторов.
dstate=struct('SlotIdx',0); nslots=p.nru*p.nulSlots*p.repetitions; block=0;
% Шаг 1: задержка по DM-RS.
[timingOffset,timing]=nbiot.phy.npusch.estimateTiming(cfg,rx,g,ue,chs);
% Первый отсчёт передачи с учётом оценённой задержки.
firstSample=g.startTick*1920+timingOffset;
% Отсчёты всей передачи.
w=nbiot.phy.extractWindow(rx,firstSample,nslots*960);
% DM-RS based CFO estimate across slots. No propagation taps enter this path.
previous=[]; products=0; pilotState=struct('SlotIdx',0);
% Для каждого слота:
for s=0:nslots-1
    % номер слота и кадра;
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    % демодуляция SC-FDMA слота;
    chs.SlotIdx=pilotState.SlotIdx; grid=lteSCFDMADemodulate(ue,chs,w(s*960+(1:960)));
    % опорный DM-RS слота;
    [ref,pilotState]=lteNPUSCHDRS(ue,chs,pilotState);
    % оценка канала на DM-RS (принятое / опорное);
    pilot=grid(lteNPUSCHDRSIndices(ue,chs))./ref;
    % произведение с DM-RS предыдущего слота — набег фазы за 0,5 мс;
    if ~isempty(previous), products=products+sum(conj(previous).*pilot); end
    % запоминаем текущий.
    previous=pilot;
end
% Шаг 2: CFO = угол набега / (2π·0,5 мс), с ограничением ±cfoLimitHz.
cfo=angle(products)/(2*pi*0.0005); cfo=max(-cfg.channel.cfoLimitHz,min(cfg.channel.cfoLimitHz,cfo));
% Компенсация CFO поворотом фазы по абсолютному времени.
w=w.*exp(-1i*2*pi*cfo*(firstSample+(0:size(w,1)-1)')/1920000);
% Окно оценки канала: 23 поднесущих по частоте, 1 символ по времени, линейная интерполяция.
cec=struct('PilotAverage','UserDefined','FreqWindow',23,'TimeWindow',1,'InterpType','linear');
% Format2 has one frequency pilot; average its three DRS symbol positions.
if strcmp(p.format,'Control'), cec.TimeWindow=3; end
% Заготовки: биты, ошибка, шум, RV по блокам, оценки канала на DM-RS.
bits=[]; err=true; noise=[]; rv=[g.rv 2-mod(g.rv,4)]; pilotEstimates=[];
% Шаг 3: для каждого слота:
for s=0:nslots-1
    % номер слота и кадра;
    absolute=2*g.startTick+s; ue.NSlot=mod(absolute,20); ue.NFrame=floor(absolute/20);
    % позиция и RV текущего блока повторов;
    chs.SlotIdx=dstate.SlotIdx; chs.RV=rv(mod(block,2)+1);
    % демодуляция SC-FDMA;
    grid=lteSCFDMADemodulate(ue,chs,w(s*960+(1:960)));
    % опорный DM-RS;
    reference=lteNPUSCHDRS(ue,chs,dstate);
    % накапливаем оценки канала на DM-RS (для детектора UCI);
    pilotEstimates=[pilotEstimates;grid(lteNPUSCHDRSIndices(ue,chs))./reference]; %#ok<AGROW>
    % оценка канала и шума по DM-RS (шум не меньше eps);
    [h,n]=lteULChannelEstimateNPUSCH(ue,chs,cec,grid,dstate); n=max(real(n),eps);
    % символы NPUSCH и оценки канала на них;
    [sym,hs]=lteExtractResources(lteNPUSCHIndices(ue,chs),grid,h);
    % эквализация и демодуляция в мягкие биты; состояние декодера;
    [cw,dstate]=lteNPUSCHDecode(ue,chs,sym,hs,n,dstate);
    % запоминаем оценку шума;
    noise(end+1)=n; %#ok<AGROW>
    % закончился блок повторов —
    if dstate.EndOfBlk
        % декодирование UL-SCH: мягкое объединение с прошлыми передачами того же блока, CRC;
        [bits,err,state.transport]=lteNULSCHDecode(chs,p.tbs,cw,state.transport);
        % следующий блок.
        block=block+1;
    end
end
% Декодер должен дойти до конца передачи.
assert(dstate.EndOfTx,'nbiot:phy:Bundle','NPUSCH receiver did not complete bundle.');
% CRC есть только у данных (формат 1).
hasCrc=strcmp(p.format,'Data');
% Данные:
if hasCrc
    % статус по результату CRC;
    if err==0, status='decoded'; else, status='crc_failure'; end
    % ошибка CRC (логическое).
    crcError=logical(err);
else
    % ACK: статус uci, ошибка CRC не определена (NaN).
    status='uci'; crcError=NaN;
end
% Когерентность DM-RS: |Σh|² / (N·Σ|h|²) — близка к 1, если сигнал реально есть.
coherence=abs(sum(pilotEstimates))^2/max(numel(pilotEstimates)*sum(abs(pilotEstimates).^2),realmin);
% Порог когерентности DM-RS по умолчанию 0,5.
uciThreshold=.5;
% Можно переопределить в конфигурации.
if isfield(cfg.phy,'uciPilotCoherenceThreshold'), uciThreshold=cfg.phy.uciPilotCoherenceThreshold; end
% DM-RS does not identify the RNTI. Foreign Control can have perfect pilot
% coherence but inconsistent soft bits after this receiver's descrambling.
% Format 2 repeats one UCI bit in a 16-bit codeword. Check that consistency
% using received LLRs only; ACK and NACK use the same presence criterion.
uciCodewordCoherence=NaN; uciCodewordThreshold=.8;
% Порог когерентности кодового слова — из конфигурации, если задан.
if isfield(cfg.phy,'uciCodewordCoherenceThreshold'), uciCodewordThreshold=cfg.phy.uciCodewordCoherenceThreshold; end
% Для ACK —
if ~hasCrc
    % мягкие биты принятого кодового слова UCI;
    soft=state.transport.CBSBuffers{1}; soft=soft(:);
    % их согласованность (бит повторён в кодовом слове — у своего сигнала значения согласованы).
    uciCodewordCoherence=abs(sum(soft))^2/max(numel(soft)*sum(abs(soft).^2),realmin);
end
% Результат: биты, наличие CRC, ошибка, статус, измерения (CFO, шум, когерентности, ACK обнаружен, тайминг).
decode=struct('decodedBits',int8(bits(:)),'hasCrc',hasCrc,'crcError',crcError,...
    'status',status,'measurements',struct('cfoHz',cfo,'noiseEstimate',mean(noise),...
    'pilotCoherence',coherence,'uciThreshold',uciThreshold,...
    'uciCodewordCoherence',uciCodewordCoherence,'uciCodewordThreshold',uciCodewordThreshold,...
    'uciDetected',~hasCrc && coherence>=uciThreshold && uciCodewordCoherence>=uciCodewordThreshold,...
    'uciReceiverRevision','pilot-and-codeword-v1','timing',timing));
end
