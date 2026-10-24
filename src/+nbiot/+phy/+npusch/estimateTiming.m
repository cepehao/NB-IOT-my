function [delay,measurement]=estimateTiming(cfg,rx,g,ue,chs)
%ESTIMATETIMING Оценка задержки приёма NPUSCH по корреляции с DM-RS (ТЗ §17: timing offset).
%   Поиск в ±64 отсчётах (cfg.phy.ulTimingSearchSamples, если задан) вокруг номинального начала,
%   в пределах доступного окна приёма. DELAY — задержка в отсчётах (может быть отрицательной);
%   MEASUREMENT — пик, отношение пик/среднее, диапазон поиска. Истинная задержка не используется.
% Проверяем функцию LTE Toolbox.
nbiot.phy.requireToolbox({'lteULFrameOffsetNPUSCH'});
% Номинальный первый отсчёт передачи; её длина в отсчётах (слоты × 960).
nominal=g.startTick*1920; count=g.profile.nru*g.profile.nulSlots*g.profile.repetitions*960;
% Ширина поиска по умолчанию — ±64 отсчёта (≈ ±33 мкс).
limit=64;
% Можно переопределить в конфигурации.
if isfield(cfg.phy,'ulTimingSearchSamples'), limit=cfg.phy.ulTimingSearchSamples; end
% Ширина — целое 0..128.
validateattributes(limit,{'numeric'},{'scalar','integer','>=',0,'<=',128});
% Насколько можно сдвинуться раньше номинала, не выходя из окна приёма.
before=min(limit,nominal-rx.startSample);
% Насколько можно сдвинуться позже.
after=min(limit,rx.startSample+size(rx.waveform,1)-(nominal+count));
% Окно должно покрывать номинальную передачу.
assert(before>=0 && after>=0,'nbiot:phy:RxWindow','UL window does not cover its nominal bundle.');
% Первый отсчёт фрагмента поиска.
first=nominal-before;
% Фрагмент: один слот плюс запас поиска с обеих сторон.
wave=nbiot.phy.extractWindow(rx,first,960+before+after);
% Корреляция с DM-RS первого слота (lteULFrameOffsetNPUSCH) по всем сдвигам.
[toolboxOffset,corr]=lteULFrameOffsetNPUSCH(ue,chs,wave,struct('SlotIdx',0));
% Проверяемые сдвиги и их индексы в результате корреляции.
candidates=-before:after; indices=before+candidates+1;
% Мощность корреляции по сдвигам (сумма по антеннам).
metric=sum(abs(corr).^2,2);
% Сдвиг с максимальной корреляцией = оценка задержки.
[peak,at]=max(metric(indices)); delay=candidates(at);
% Средний уровень корреляции (для отношения пик/среднее).
reference=max(mean(metric),realmin);
% Измерения: задержка в отсчётах и секундах, пик, пик/среднее, оценка LTE Toolbox, диапазон поиска.
measurement=struct('delaySamples',delay,'delaySeconds',delay/1920000,...
    'correlationPeak',peak,'peakToMean',peak/reference,...
    'toolboxOffsetSamples',toolboxOffset,'searchSamples',[-before after]);
end
