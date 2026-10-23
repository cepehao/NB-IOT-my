function [delay,measurement]=estimateTiming(cfg,rx,g,ue,chs)
%ESTIMATETIMING Оценка задержки приёма NPUSCH по корреляции с DM-RS (ТЗ §17: timing offset).
%   Поиск в ±64 отсчётах (cfg.phy.ulTimingSearchSamples, если задан) вокруг номинального начала,
%   в пределах доступного окна приёма. DELAY — задержка в отсчётах (может быть отрицательной);
%   MEASUREMENT — пик, отношение пик/среднее, диапазон поиска. Истинная задержка не используется.
nbiot.phy.requireToolbox({'lteULFrameOffsetNPUSCH'});
nominal=g.startTick*1920; count=g.profile.nru*g.profile.nulSlots*g.profile.repetitions*960;
limit=64;
if isfield(cfg.phy,'ulTimingSearchSamples'), limit=cfg.phy.ulTimingSearchSamples; end
validateattributes(limit,{'numeric'},{'scalar','integer','>=',0,'<=',128});
before=min(limit,nominal-rx.startSample);
after=min(limit,rx.startSample+size(rx.waveform,1)-(nominal+count));
assert(before>=0 && after>=0,'nbiot:phy:RxWindow','UL window does not cover its nominal bundle.');
first=nominal-before;
wave=nbiot.phy.extractWindow(rx,first,960+before+after);
[toolboxOffset,corr]=lteULFrameOffsetNPUSCH(ue,chs,wave,struct('SlotIdx',0));
candidates=-before:after; indices=before+candidates+1;
metric=sum(abs(corr).^2,2);
[peak,at]=max(metric(indices)); delay=candidates(at);
reference=max(mean(metric),realmin);
measurement=struct('delaySamples',delay,'delaySeconds',delay/1920000,...
    'correlationPeak',peak,'peakToMean',peak/reference,...
    'toolboxOffsetSamples',toolboxOffset,'searchSamples',[-before after]);
end
