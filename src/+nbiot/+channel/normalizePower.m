function [waveform,activePowerW]=normalizePower(waveform,activeRanges,txPowerDbm)
%NORMALIZEPOWER Масштабирует waveform к мощности передачи TXPOWERDBM (ТЗ §13: 23 дБм).
%   ACTIVERANGES — интервалы [a, b) с нумерацией от 0 (начало включительно, конец исключён):
%   средняя мощность считается только по активным отсчётам, нули буфера не учитываются.
%   Выход — сигнал в физических единицах (средняя мощность активной части = 10^((P−30)/10) Вт).
waveform=double(waveform(:)); mask=false(size(waveform));
validateattributes(txPowerDbm,{'numeric'},{'scalar','real','finite'});
for k=1:size(activeRanges,1)
    a=activeRanges(k,1); b=activeRanges(k,2);
    assert(a>=0 && b<=numel(waveform) && b>a && a==fix(a) && b==fix(b),'nbiot:ActiveRange','Invalid active sample range.');
    mask(a+1:b)=true;
end
assert(any(mask),'nbiot:EmptyActive','No active transmission samples.');
activePowerW=mean(abs(waveform(mask)).^2);
assert(activePowerW>0 && isfinite(activePowerW),'nbiot:WaveformPower','Active waveform must have finite positive power.');
target=10^((txPowerDbm-30)/10); waveform=waveform*sqrt(target/activePowerW); activePowerW=target;
end
