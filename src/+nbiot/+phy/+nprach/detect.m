function [detected,metrics]=detect(cfg,rx,occasion)
%DETECT Многопользовательский детектор NPRACH (ТЗ §14 п.10–12, §15–16).
%   [DETECTED, METRICS] = detect(CFG, RX, OCCASION)
%   1) METRICS(12) — статистика присутствия каждой преамбулы (nbiot.phy.nprach.groupMetrics);
%      кандидаты — те, у кого METRICS >= порог калибровки cfg.phy.nprachThreshold.
%   2) Кандидаты подтверждаются по убыванию метрики: согласованная фильтрация с шаблоном по сетке
%      CFO и задержке (estimateParameters); затем подтверждённые сигналы вычитаются из принятого
%      (МНК по всем найденным), чтобы сильная преамбула не маскировала слабую (capture/near-far).
%   Выход DETECTED: nInit, метрика, matchScore, оценки задержки (с) и CFO (Гц), порог, тик готовности.
%   Детектор не знает, какие UE передавали, и не использует истинный канал.
%   Штатный lteNPRACHDetect не применяется: он возвращает только одну, сильнейшую преамбулу (ADR-002).
threshold=cfg.phy.nprachThreshold;
assert(isfinite(threshold) && threshold>0 && threshold<=1,...
    'nbiot:phy:Calibration','Set a calibrated NPRACH threshold before simulation.');
[metrics,~]=nbiot.phy.nprach.groupMetrics(cfg,rx,occasion);
detected=struct('nInit',{},'metric',{},'matchScore',{},'delaySeconds',{},'cfoHz',{},'threshold',{},'readyTick',{});
selected=find(metrics>=threshold);
if isempty(selected), return; end
% The group statistic proposes candidates; a full-waveform match at estimated
% timing/CFO confirms them. Fitted stronger candidates are removed before the
% next candidate is measured. No UE truth or actual channel taps are used.
[~,order]=sort(metrics(selected),'descend'); selected=selected(order);
bank=nbiot.phy.nprach.templates(cfg); fs=1920000;
residual=rx; columns=complex(zeros(numel(rx.waveform),0));
for index=selected'
    [delay,cfo,matchScore]=estimateParameters(cfg,residual,occasion,bank,index);
    if matchScore<threshold, continue; end
    detected(end+1)=struct('nInit',index-1,'metric',metrics(index),'matchScore',matchScore,...
        'delaySeconds',delay,'cfoHz',cfo,'threshold',threshold,...
        'readyTick',occasion.startTick+6+cfg.phy.processingTicks); %#ok<AGROW>
    if numel(selected)>1
        [wave,offset]=nbiot.channel.fractionalDelay(bank{index}.waveform,...
            delay*fs,cfg.channel.fractionalFilterLength);
        samples=occasion.startTick*1920+offset+(0:numel(wave)-1)';
        at=samples-rx.startSample+1; keep=at>=1 & at<=numel(rx.waveform);
        column=complex(zeros(numel(rx.waveform),1));
        column(at(keep))=wave(keep).*exp(1i*2*pi*cfo*samples(keep)/fs);
        columns(:,end+1)=column; %#ok<AGROW>
        coefficients=columns\rx.waveform(:);
        residual.waveform=rx.waveform(:)-columns*coefficients;
    end
end
[~,order]=sort([detected.nInit]); detected=detected(order);
end

%ESTIMATEPARAMETERS Оценка задержки и CFO преамбулы INDEX: для каждой гипотезы CFO из
%   cfg.phy.nprachCfoGridHz — корреляция через FFT с шаблоном в диапазоне задержек −8..+20 мкс,
%   нормированная на энергию; уточнение пика параболической интерполяцией по задержке и по CFO.
%   BEST — нормированный пик (0..1), сравнивается с тем же порогом.
function [bestDelay,bestCfo,best]=estimateParameters(cfg,rx,occasion,bank,index)
fs=1920000; delays=round((-8e-6:1/fs:20e-6)*fs);
delays=min(delays):max(delays)+ceil(cfg.channel.fractionalFilterLength/2);
count=numel(bank{1}.waveform); first=occasion.startTick*1920+min(delays);
w=nbiot.phy.extractWindow(rx,first,count+max(delays)-min(delays)); w=w(:);
cfo=cfg.phy.nprachCfoGridHz; len=2^nextpow2(numel(w)+count-1);
% Кэш FFT сопряжённых шаблонов всех 12 преамбул (не зависят от UE).
persistent referenceFft referenceKey
cacheKey=[len cfg.phy.cellId cfg.ra.periodTicks];
if isempty(referenceFft) || ~isequal(referenceKey,cacheKey)
    referenceFft=complex(zeros(len,12));
    for i=1:12, referenceFft(:,i)=fft(conj(flipud(bank{i}.waveform)),len); end
    referenceKey=cacheKey;
end
energy=conv(abs(w).^2,ones(count,1),'valid');
referenceEnergy=sum(abs(bank{index}.waveform).^2);
best=0; bestDelay=0; bestCfo=cfo(1); peaks=zeros(size(cfo));
for fi=1:numel(cfo)
    corrected=w.*exp(-1i*2*pi*cfo(fi)*(first+(0:numel(w)-1)')/fs);
    corr=ifft(fft(corrected,len).*referenceFft(:,index));
    normalized=abs(corr(count:count+numel(energy)-1)).^2./max(energy*referenceEnergy,realmin);
    [peak,at]=max(normalized); peaks(fi)=peak;
    if peak>best
        fraction=0;
        if at>1 && at<numel(normalized)
            a=normalized(at-1); b=normalized(at); c=normalized(at+1);
            denominator=a-2*b+c;
            if denominator<0, fraction=max(-.5,min(.5,.5*(a-c)/denominator)); end
        end
        best=peak; bestDelay=(min(delays)+at-1+fraction)/fs; bestCfo=cfo(fi);
    end
end
[~,fi]=max(peaks);
if fi>1 && fi<numel(cfo) && abs((cfo(fi+1)-cfo(fi))-(cfo(fi)-cfo(fi-1)))<eps
    a=peaks(fi-1); b=peaks(fi); c=peaks(fi+1); denominator=a-2*b+c;
    if denominator<0
        fraction=max(-.5,min(.5,.5*(a-c)/denominator));
        bestCfo=cfo(fi)+fraction*(cfo(fi+1)-cfo(fi));
    end
end
end

