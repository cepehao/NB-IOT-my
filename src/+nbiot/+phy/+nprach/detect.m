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
% Порог из калибровки.
threshold=cfg.phy.nprachThreshold;
% Порог должен быть загружен и лежать в (0, 1].
assert(isfinite(threshold) && threshold>0 && threshold<=1,...
    'nbiot:phy:Calibration','Set a calibrated NPRACH threshold before simulation.');
% Шаг 1: статистика присутствия каждой из 12 преамбул.
[metrics,~]=nbiot.phy.nprach.groupMetrics(cfg,rx,occasion);
% Пустой список обнаружений.
detected=struct('nInit',{},'metric',{},'matchScore',{},'delaySeconds',{},'cfoHz',{},'threshold',{},'readyTick',{});
% Кандидаты — преамбулы с метрикой не ниже порога.
selected=find(metrics>=threshold);
% Кандидатов нет — ничего не обнаружено.
if isempty(selected), return; end
% The group statistic proposes candidates; a full-waveform match at estimated
% timing/CFO confirms them. Fitted stronger candidates are removed before the
% next candidate is measured. No UE truth or actual channel taps are used.
[~,order]=sort(metrics(selected),'descend'); selected=selected(order);
% Банк шаблонов и частота отсчётов.
bank=nbiot.phy.nprach.templates(cfg); fs=1920000;
% Остаток сигнала (после вычитания найденных) и столбцы-модели найденных сигналов.
residual=rx; columns=complex(zeros(numel(rx.waveform),0));
% Для каждого кандидата (от сильнейшего):
for index=selected'
    % шаг 2: согласованная фильтрация остатка — задержка, CFO и нормированный пик;
    [delay,cfo,matchScore]=estimateParameters(cfg,residual,occasion,bank,index);
    % пик ниже порога — кандидат не подтверждён;
    if matchScore<threshold, continue; end
    % подтверждён: NInit (с нуля), метрика, пик, задержка (с), CFO (Гц), порог, тик готовности результата.
    detected(end+1)=struct('nInit',index-1,'metric',metrics(index),'matchScore',matchScore,...
        'delaySeconds',delay,'cfoHz',cfo,'threshold',threshold,...
        'readyTick',occasion.startTick+6+cfg.phy.processingTicks); %#ok<AGROW>
    % Если кандидатов несколько —
    if numel(selected)>1
        % шаблон с оценённой дробной задержкой;
        [wave,offset]=nbiot.channel.fractionalDelay(bank{index}.waveform,...
            delay*fs,cfg.channel.fractionalFilterLength);
        % абсолютные номера отсчётов этого сигнала;
        samples=occasion.startTick*1920+offset+(0:numel(wave)-1)';
        % их позиции в окне приёма; какие из них внутри окна;
        at=samples-rx.startSample+1; keep=at>=1 & at<=numel(rx.waveform);
        % модель сигнала на всём окне (нули вне сигнала);
        column=complex(zeros(numel(rx.waveform),1));
        % шаблон с задержкой и поворотом фазы на оценённый CFO;
        column(at(keep))=wave(keep).*exp(1i*2*pi*cfo*samples(keep)/fs);
        % добавляем в набор моделей найденных сигналов;
        columns(:,end+1)=column; %#ok<AGROW>
        % МНК: комплексные амплитуды всех найденных сигналов в принятом;
        coefficients=columns\rx.waveform(:);
        % шаг 3: остаток = принятое − вклад всех найденных (следующий кандидат ищется в остатке).
        residual.waveform=rx.waveform(:)-columns*coefficients;
    end
end
% Результат упорядочен по NInit.
[~,order]=sort([detected.nInit]); detected=detected(order);
end

%ESTIMATEPARAMETERS Оценка задержки и CFO преамбулы INDEX: для каждой гипотезы CFO из
%   cfg.phy.nprachCfoGridHz — корреляция через FFT с шаблоном в диапазоне задержек −8..+20 мкс,
%   нормированная на энергию; уточнение пика параболической интерполяцией по задержке и по CFO.
%   BEST — нормированный пик (0..1), сравнивается с тем же порогом.
function [bestDelay,bestCfo,best]=estimateParameters(cfg,rx,occasion,bank,index)
% Частота отсчётов; диапазон задержек −8..+20 мкс в отсчётах.
fs=1920000; delays=round((-8e-6:1/fs:20e-6)*fs);
% Диапазон задержек с запасом на половину фильтра.
delays=min(delays):max(delays)+ceil(cfg.channel.fractionalFilterLength/2);
% Длина шаблона; первый отсчёт окна поиска.
count=numel(bank{1}.waveform); first=occasion.startTick*1920+min(delays);
% Окно принятого сигнала, покрывающее все задержки, столбцом.
w=nbiot.phy.extractWindow(rx,first,count+max(delays)-min(delays)); w=w(:);
% Сетка гипотез CFO; длина БПФ для свёртки (степень двойки).
cfo=cfg.phy.nprachCfoGridHz; len=2^nextpow2(numel(w)+count-1);
% Кэш FFT сопряжённых шаблонов всех 12 преамбул (не зависят от UE).
persistent referenceFft referenceKey
% Ключ кэша спектров шаблонов: длина БПФ и конфигурация.
cacheKey=[len cfg.phy.cellId cfg.ra.periodTicks];
% Если кэш пуст или конфигурация изменилась —
if isempty(referenceFft) || ~isequal(referenceKey,cacheKey)
    % спектры 12 шаблонов;
    referenceFft=complex(zeros(len,12));
    % спектр сопряжённого обращённого шаблона = согласованный фильтр в частотной области;
    for i=1:12, referenceFft(:,i)=fft(conj(flipud(bank{i}.waveform)),len); end
    % запоминаем ключ.
    referenceKey=cacheKey;
end
% Энергия окна приёма длиной в шаблон при каждом сдвиге (для нормировки).
energy=conv(abs(w).^2,ones(count,1),'valid');
% Энергия шаблона кандидата.
referenceEnergy=sum(abs(bank{index}.waveform).^2);
% Лучший пик, его задержка и CFO; пики по гипотезам CFO.
best=0; bestDelay=0; bestCfo=cfo(1); peaks=zeros(size(cfo));
% Для каждой гипотезы CFO:
for fi=1:numel(cfo)
    % компенсируем CFO поворотом фазы по абсолютному времени;
    corrected=w.*exp(-1i*2*pi*cfo(fi)*(first+(0:numel(w)-1)')/fs);
    % корреляция с шаблоном через БПФ;
    corr=ifft(fft(corrected,len).*referenceFft(:,index));
    % нормированная корреляция |r|² / (E_окна · E_шаблона) ∈ [0, 1] для каждой задержки;
    normalized=abs(corr(count:count+numel(energy)-1)).^2./max(energy*referenceEnergy,realmin);
    % максимум по задержке; запоминаем пик гипотезы;
    [peak,at]=max(normalized); peaks(fi)=peak;
    % если пик лучший —
    if peak>best
        % дробная поправка задержки (по умолчанию 0);
        fraction=0;
        % если пик не на краю —
        if at>1 && at<numel(normalized)
            % три соседних значения вокруг пика;
            a=normalized(at-1); b=normalized(at); c=normalized(at+1);
            % знаменатель параболы;
            denominator=a-2*b+c;
            % вершина параболы через три точки (ограничена ±0,5 отсчёта);
            if denominator<0, fraction=max(-.5,min(.5,.5*(a-c)/denominator)); end
        end
        % запоминаем пик, задержку (с) и CFO.
        best=peak; bestDelay=(min(delays)+at-1+fraction)/fs; bestCfo=cfo(fi);
    end
end
% Гипотеза CFO с наибольшим пиком.
[~,fi]=max(peaks);
% Если она не на краю равномерной сетки —
if fi>1 && fi<numel(cfo) && abs((cfo(fi+1)-cfo(fi))-(cfo(fi)-cfo(fi-1)))<eps
    % параболическая интерполяция по CFO:
    a=peaks(fi-1); b=peaks(fi); c=peaks(fi+1); denominator=a-2*b+c;
    % если вершина существует (максимум) —
    if denominator<0
        % поправка в долях шага сетки (±0,5);
        fraction=max(-.5,min(.5,.5*(a-c)/denominator));
        % уточнённая оценка CFO.
        bestCfo=cfo(fi)+fraction*(cfo(fi+1)-cfo(fi));
    end
end
end

