function [grid,h,n,measurement]=dlReceiveGrid(cfg,rx,tick)
%DLRECEIVEGRID Приём одного DL-подкадра UE: синхронизация, CFO, оценка канала (ТЗ §19).
%   [GRID, H, N, MEAS] = dlReceiveGrid(CFG, RX, TICK)
%   1) Грубая синхронизация окна FFT: перебор сдвигов −16..+24 отсчётов, критерий — когерентность
%      циклического префикса (CP) принятого сигнала; когерентность NRS — только при равенстве.
%   2) Оценка остаточного CFO по фазе повторяющихся NRS на каждой поднесущей и его компенсация.
%   3) Оценка канала lteDLChannelEstimate по NRS без усреднения (сохраняет глубокие замирания),
%      шум — по разбросу NRS во времени (LTE Toolbox при окне 1×1 даёт ноль).
%   Выход: GRID 12×14, H — оценка канала, N — мощность шума, MEAS — CFO, тайминг, диагностика.
enb=struct('NNCellID',cfg.phy.cellId,'NBRefP',1,'OperationMode','Standalone',...
    'NFrame',floor(tick/10),'NSubframe',mod(tick,10),'Windowing',0);
w=nbiot.phy.extractWindow(rx,tick*1920,1920);
enb.NBULSubcarrierSpacing='15kHz';
grid=lteSCFDMADemodulate(enb,w,0.55);
% Public NRS and OFDM cyclic-prefix structure determine FFT-window timing.
% The NRS phase slope is retained as a diagnostic; selective-fade phase
% alone must not force the FFT window outside the actual received CP.
% Опорная сетка NRS этого подкадра и LS-оценки канала в позициях NRS.
ref=complex(zeros(12,14)); ref(lteNRSIndices(enb))=lteNRS(enb);
ls=complex(zeros(12,14)); valid=abs(ref)>0; ls(valid)=grid(valid)./ref(valid);
before=min(64,tick*1920-rx.startSample);
after=min(64,rx.startSample+size(rx.waveform,1)-(tick*1920+1920));
assert(before>=0 && after>=0,'nbiot:phy:RxWindow','DL window does not cover its nominal subframe.');
% A frequency-selective fade can bias the phase-slope timing estimate even
% within the default propagation range. Select a coarse FFT window by CP
% consistency, using NRS time coherence only to break close score ties.
% Длины CP (отсчёты при 1,92 МГц) для 14 символов и времена центров символов (с).
cp=[10 repmat(9,1,6) 10 repmat(9,1,6)];
times=(cumsum([0 128+cp(1:end-1)])+cp+64)/1920000;
offsets=-min(before,16):min(after,24); scores=zeros(size(offsets));
pilotScores=zeros(size(offsets));
for candidate=1:numel(offsets)
    candidateWave=nbiot.phy.extractWindow(rx,tick*1920+offsets(candidate),1920);
    candidateGrid=lteSCFDMADemodulate(enb,candidateWave,0.55);
    pilot=complex(zeros(12,14)); pilot(valid)=candidateGrid(valid)./ref(valid);
    pilotScores(candidate)=pilotTimeCoherence(pilot,valid,times,cfg.channel.cfoLimitHz);
    scores(candidate)=cyclicPrefixCoherence(candidateWave,cp)+1e-6*pilotScores(candidate);
end
[~,best]=max(scores); offset=offsets(best);
w=nbiot.phy.extractWindow(rx,tick*1920+offset,1920);
grid=lteSCFDMADemodulate(enb,w,0.55); ls(valid)=grid(valid)./ref(valid);
timingProduct=0;
for col=1:14
    rows=find(valid(:,col));
    if numel(rows)==2 && diff(rows)==6
        timingProduct=timingProduct+conj(ls(rows(1),col))*ls(rows(2),col);
    end
end
% Диагностическая оценка задержки по наклону фазы между NRS, разнесёнными на 6 поднесущих.
phaseDelay=-angle(timingProduct)*1920000/(2*pi*6*15000);
firstSample=tick*1920+offset;
w=nbiot.phy.extractWindow(rx,firstSample,1920);
grid=lteSCFDMADemodulate(enb,w,0.55);
ls(valid)=grid(valid)./ref(valid);
% Estimate residual frequency from repeated NRS locations on each subcarrier.
cp=[10 repmat(9,1,6) 10 repmat(9,1,6)]; times=(cumsum([0 128+cp(1:end-1)])+cp+64)/1920000;
num=0; den=0;
for row=1:12
    cols=find(valid(row,:));
    for j=2:numel(cols)
        a=cols(j-1); b=cols(j); product=conj(ls(row,a))*ls(row,b);
        dt=times(b)-times(a); weight=abs(product);
        num=num+weight*angle(product)/dt; den=den+weight;
    end
end
cfo=num/max(den,realmin)/(2*pi);
cfo=max(-cfg.channel.cfoLimitHz,min(cfg.channel.cfoLimitHz,cfo));
w=w.*exp(-1i*2*pi*cfo*(firstSample+(0:1919)')/1920000);
grid=lteSCFDMADemodulate(enb,w,0.55);
% Preserve the measured frequency response of deep selective fades. Wide
% averaging across all twelve tones can erase its zero/phase transition.
cec=struct('Reference','NRS','PilotAverage','UserDefined','FreqWindow',1,...
    'TimeWindow',1,'InterpType','linear','InterpWindow','Causal','InterpWinSize',1);
[h,n]=lteDLChannelEstimate(enb,cec,grid);
% With a 1x1 averaging kernel LTE Toolbox reports zero pilot noise. Estimate
% it from repeated NRS locations on each tone after received CFO correction.
pilot=complex(zeros(12,14)); pilot(valid)=grid(valid)./ref(valid);
noiseEnergy=0; noiseDof=0;
for row=1:12
    cols=find(valid(row,:));
    if numel(cols)<2, continue; end
    values=pilot(row,cols); noiseEnergy=noiseEnergy+sum(abs(values-mean(values)).^2);
    noiseDof=noiseDof+numel(cols)-1;
end
pilotNoise=noiseEnergy/max(noiseDof,1);
n=max([real(n) pilotNoise eps]);
measurement=struct('cfoHz',cfo,'timing',struct('delaySamples',offset,...
    'phaseDelaySamples',offset+phaseDelay,'delaySeconds',offset/1920000,...
    'unambiguousRangeSamples',[-1920000/(2*6*15000) 1920000/(2*6*15000)]),...
    'coarseOffsets',offsets,'coarseScores',scores,'pilotScores',pilotScores,...
    'noiseEstimateMethod','per-tone-time-residual','pilotNoiseEstimate',pilotNoise,...
    'receiverRevision','cp-nrs-coarse-selective-v2');
end

%CYCLICPREFIXCOHERENCE Нормированная корреляция CP с концом символа (1 — идеальное совпадение).
function score=cyclicPrefixCoherence(w,cp)
first=1; a=[]; b=[];
for symbol=1:numel(cp)
    % Ignore the first three CP samples, covering the public default excess
    % multipath delay. Both sequences are received samples, never Tx truth.
    at=first+(3:cp(symbol)-1); a=[a;w(at)]; b=[b;w(at+128)]; %#ok<AGROW>
    first=first+cp(symbol)+128;
end
score=abs(a'*b)^2/max(sum(abs(a).^2)*sum(abs(b).^2),realmin);
end

%PILOTTIMECOHERENCE Когерентность NRS во времени после компенсации оценённого CFO.
function score=pilotTimeCoherence(ls,valid,times,cfoLimit)
num=0; den=0;
for row=1:12
    cols=find(valid(row,:));
    for j=2:numel(cols)
        a=cols(j-1); b=cols(j); z=conj(ls(row,a))*ls(row,b);
        dt=times(b)-times(a); weight=abs(z);
        num=num+weight*angle(z)/dt; den=den+weight;
    end
end
cfo=max(-cfoLimit,min(cfoLimit,num/max(den,realmin)/(2*pi)));
energy=sum(abs(ls(valid)).^2); coherent=0;
for row=1:12
    cols=find(valid(row,:));
    if isempty(cols), continue; end
    corrected=ls(row,cols).*exp(-1i*2*pi*cfo*times(cols));
    coherent=coherent+abs(sum(corrected))^2/numel(cols);
end
score=coherent/max(energy,realmin);
end
