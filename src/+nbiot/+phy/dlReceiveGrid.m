function [grid,h,n,measurement]=dlReceiveGrid(cfg,rx,tick)
%DLRECEIVEGRID Приём одного DL-подкадра UE: синхронизация, CFO, оценка канала (ТЗ §19).
%   [GRID, H, N, MEAS] = dlReceiveGrid(CFG, RX, TICK)
%   1) Грубая синхронизация окна FFT: перебор сдвигов −16..+24 отсчётов, критерий — когерентность
%      циклического префикса (CP) принятого сигнала; когерентность NRS — только при равенстве.
%   2) Оценка остаточного CFO по фазе повторяющихся NRS на каждой поднесущей и его компенсация.
%   3) Оценка канала lteDLChannelEstimate по NRS без усреднения (сохраняет глубокие замирания),
%      шум — по разбросу NRS во времени (LTE Toolbox при окне 1×1 даёт ноль).
%   Выход: GRID 12×14, H — оценка канала, N — мощность шума, MEAS — CFO, тайминг, диагностика.
% Параметры соты для подкадра TICK.
enb=struct('NNCellID',cfg.phy.cellId,'NBRefP',1,'OperationMode','Standalone',...
    'NFrame',floor(tick/10),'NSubframe',mod(tick,10),'Windowing',0);
% Номинальное окно подкадра: 1920 отсчётов с начала тика.
w=nbiot.phy.extractWindow(rx,tick*1920,1920);
% Разнос 15 кГц — сетка 12 × 14 при 1,92 МГц.
enb.NBULSubcarrierSpacing='15kHz';
% Первичная демодуляция (окно FFT с 55 % CP).
grid=lteSCFDMADemodulate(enb,w,0.55);
% Public NRS and OFDM cyclic-prefix structure determine FFT-window timing.
% The NRS phase slope is retained as a diagnostic; selective-fade phase
% alone must not force the FFT window outside the actual received CP.
% Опорная сетка NRS этого подкадра и LS-оценки канала в позициях NRS.
ref=complex(zeros(12,14)); ref(lteNRSIndices(enb))=lteNRS(enb);
% LS-оценка канала в позициях NRS: принятое / опорное.
ls=complex(zeros(12,14)); valid=abs(ref)>0; ls(valid)=grid(valid)./ref(valid);
% Запас окна приёма до номинального начала (до 64 отсчётов).
before=min(64,tick*1920-rx.startSample);
% Запас после номинального конца.
after=min(64,rx.startSample+size(rx.waveform,1)-(tick*1920+1920));
% Окно приёма должно покрывать номинальный подкадр.
assert(before>=0 && after>=0,'nbiot:phy:RxWindow','DL window does not cover its nominal subframe.');
% A frequency-selective fade can bias the phase-slope timing estimate even
% within the default propagation range. Select a coarse FFT window by CP
% consistency, using NRS time coherence only to break close score ties.
% Длины CP (отсчёты при 1,92 МГц) для 14 символов и времена центров символов (с).
cp=[10 repmat(9,1,6) 10 repmat(9,1,6)];
% Время центра каждого из 14 символов (с) с учётом CP.
times=(cumsum([0 128+cp(1:end-1)])+cp+64)/1920000;
% Кандидаты сдвига окна FFT: −16..+24 отсчёта в пределах запаса; оценки качества.
offsets=-min(before,16):min(after,24); scores=zeros(size(offsets));
% Оценки когерентности NRS по кандидатам.
pilotScores=zeros(size(offsets));
% Для каждого кандидата сдвига:
for candidate=1:numel(offsets)
    % окно подкадра со сдвигом;
    candidateWave=nbiot.phy.extractWindow(rx,tick*1920+offsets(candidate),1920);
    % демодуляция;
    candidateGrid=lteSCFDMADemodulate(enb,candidateWave,0.55);
    % LS-оценки канала на NRS;
    pilot=complex(zeros(12,14)); pilot(valid)=candidateGrid(valid)./ref(valid);
    % когерентность NRS во времени после компенсации CFO;
    pilotScores(candidate)=pilotTimeCoherence(pilot,valid,times,cfg.channel.cfoLimitHz);
    % оценка = когерентность CP + крошечная добавка когерентности NRS (разрешает почти-ничьи).
    scores(candidate)=cyclicPrefixCoherence(candidateWave,cp)+1e-6*pilotScores(candidate);
end
% Лучший сдвиг.
[~,best]=max(scores); offset=offsets(best);
% Окно с лучшим сдвигом.
w=nbiot.phy.extractWindow(rx,tick*1920+offset,1920);
% Демодуляция и LS-оценки на NRS.
grid=lteSCFDMADemodulate(enb,w,0.55); ls(valid)=grid(valid)./ref(valid);
% Накопитель для диагностики задержки по наклону фазы.
timingProduct=0;
% Для каждого символа:
for col=1:14
    % строки NRS в символе;
    rows=find(valid(:,col));
    % если две NRS на расстоянии 6 поднесущих —
    if numel(rows)==2 && diff(rows)==6
        % произведение даёт фазовый набег между ними (пропорционален задержке).
        timingProduct=timingProduct+conj(ls(rows(1),col))*ls(rows(2),col);
    end
end
% Диагностическая оценка задержки по наклону фазы между NRS, разнесёнными на 6 поднесущих.
phaseDelay=-angle(timingProduct)*1920000/(2*pi*6*15000);
% Абсолютный первый отсчёт выбранного окна.
firstSample=tick*1920+offset;
% Окно подкадра.
w=nbiot.phy.extractWindow(rx,firstSample,1920);
% Демодуляция.
grid=lteSCFDMADemodulate(enb,w,0.55);
% LS-оценки на NRS.
ls(valid)=grid(valid)./ref(valid);
% Estimate residual frequency from repeated NRS locations on each subcarrier.
cp=[10 repmat(9,1,6) 10 repmat(9,1,6)]; times=(cumsum([0 128+cp(1:end-1)])+cp+64)/1920000;
% Накопители взвешенной оценки CFO.
num=0; den=0;
% Для каждой поднесущей:
for row=1:12
    % символы, где на ней есть NRS;
    cols=find(valid(row,:));
    % для каждой пары соседних по времени NRS:
    for j=2:numel(cols)
        % произведение оценок — поворот фазы между ними;
        a=cols(j-1); b=cols(j); product=conj(ls(row,a))*ls(row,b);
        % интервал времени и вес (амплитуда);
        dt=times(b)-times(a); weight=abs(product);
        % накапливаем частоту (угол / время) с весом.
        num=num+weight*angle(product)/dt; den=den+weight;
    end
end
% Средневзвешенный CFO (Гц).
cfo=num/max(den,realmin)/(2*pi);
% Ограничение ±cfoLimitHz.
cfo=max(-cfg.channel.cfoLimitHz,min(cfg.channel.cfoLimitHz,cfo));
% Компенсация CFO поворотом фазы по абсолютному времени.
w=w.*exp(-1i*2*pi*cfo*(firstSample+(0:1919)')/1920000);
% Демодуляция после компенсации.
grid=lteSCFDMADemodulate(enb,w,0.55);
% Preserve the measured frequency response of deep selective fades. Wide
% averaging across all twelve tones can erase its zero/phase transition.
cec=struct('Reference','NRS','PilotAverage','UserDefined','FreqWindow',1,...
    'TimeWindow',1,'InterpType','linear','InterpWindow','Causal','InterpWinSize',1);
% Оценка канала и шума LTE Toolbox по NRS.
[h,n]=lteDLChannelEstimate(enb,cec,grid);
% With a 1x1 averaging kernel LTE Toolbox reports zero pilot noise. Estimate
% it from repeated NRS locations on each tone after received CFO correction.
pilot=complex(zeros(12,14)); pilot(valid)=grid(valid)./ref(valid);
% Накопители энергии остатков NRS и степеней свободы.
noiseEnergy=0; noiseDof=0;
% Для каждой поднесущей:
for row=1:12
    % символы с NRS;
    cols=find(valid(row,:));
    % меньше двух NRS — разброс не оценить;
    if numel(cols)<2, continue; end
    % оценки на NRS; энергия отклонений от среднего (шум);
    values=pilot(row,cols); noiseEnergy=noiseEnergy+sum(abs(values-mean(values)).^2);
    % степени свободы: число NRS − 1.
    noiseDof=noiseDof+numel(cols)-1;
end
% Оценка шума по разбросу NRS.
pilotNoise=noiseEnergy/max(noiseDof,1);
% Итоговый шум: максимум оценки LTE Toolbox, оценки по NRS и eps.
n=max([real(n) pilotNoise eps]);
% Измерения: CFO, тайминг (сдвиг окна, фазовая задержка), диагностика выбора окна и шума.
measurement=struct('cfoHz',cfo,'timing',struct('delaySamples',offset,...
    'phaseDelaySamples',offset+phaseDelay,'delaySeconds',offset/1920000,...
    'unambiguousRangeSamples',[-1920000/(2*6*15000) 1920000/(2*6*15000)]),...
    'coarseOffsets',offsets,'coarseScores',scores,'pilotScores',pilotScores,...
    'noiseEstimateMethod','per-tone-time-residual','pilotNoiseEstimate',pilotNoise,...
    'receiverRevision','cp-nrs-coarse-selective-v2');
end

%CYCLICPREFIXCOHERENCE Нормированная корреляция CP с концом символа (1 — идеальное совпадение).
function score=cyclicPrefixCoherence(w,cp)
% Позиция начала символа; выборки CP и концов символов.
first=1; a=[]; b=[];
% Для каждого символа:
for symbol=1:numel(cp)
    % Ignore the first three CP samples, covering the public default excess
    % multipath delay. Both sequences are received samples, never Tx truth.
    at=first+(3:cp(symbol)-1); a=[a;w(at)]; b=[b;w(at+128)]; %#ok<AGROW>
    % переходим к следующему символу (CP + 128 отсчётов).
    first=first+cp(symbol)+128;
end
% Нормированная корреляция CP и конца символа (1 — окно FFT выбрано верно).
score=abs(a'*b)^2/max(sum(abs(a).^2)*sum(abs(b).^2),realmin);
end

%PILOTTIMECOHERENCE Когерентность NRS во времени после компенсации оценённого CFO.
function score=pilotTimeCoherence(ls,valid,times,cfoLimit)
% Накопители взвешенной оценки CFO.
num=0; den=0;
% Для каждой поднесущей:
for row=1:12
    % символы с NRS;
    cols=find(valid(row,:));
    % для каждой пары соседних NRS:
    for j=2:numel(cols)
        % произведение — поворот фазы;
        a=cols(j-1); b=cols(j); z=conj(ls(row,a))*ls(row,b);
        % интервал времени и вес;
        dt=times(b)-times(a); weight=abs(z);
        % накапливаем частоту с весом.
        num=num+weight*angle(z)/dt; den=den+weight;
    end
end
% CFO с ограничением ±cfoLimit.
cfo=max(-cfoLimit,min(cfoLimit,num/max(den,realmin)/(2*pi)));
% Энергия NRS; накопитель когерентной энергии.
energy=sum(abs(ls(valid)).^2); coherent=0;
% Для каждой поднесущей:
for row=1:12
    % символы с NRS;
    cols=find(valid(row,:));
    % нет NRS — пропуск;
    if isempty(cols), continue; end
    % компенсируем CFO;
    corrected=ls(row,cols).*exp(-1i*2*pi*cfo*times(cols));
    % когерентная сумма: при стабильном канале близка к полной энергии.
    coherent=coherent+abs(sum(corrected))^2/numel(cols);
end
% Доля когерентной энергии (0..1).
score=coherent/max(energy,realmin);
end
