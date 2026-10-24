function [waveform,activePowerW]=normalizePower(waveform,activeRanges,txPowerDbm)
%NORMALIZEPOWER Масштабирует waveform к мощности передачи TXPOWERDBM (ТЗ §13: 23 дБм).
%   ACTIVERANGES — интервалы [a, b) с нумерацией от 0 (начало включительно, конец исключён):
%   средняя мощность считается только по активным отсчётам, нули буфера не учитываются.
%   Выход — сигнал в физических единицах (средняя мощность активной части = 10^((P−30)/10) Вт).
% Сигнал столбцом double; маска активных отсчётов.
waveform=double(waveform(:)); mask=false(size(waveform));
% Мощность передачи — конечное число дБм.
validateattributes(txPowerDbm,{'numeric'},{'scalar','real','finite'});
% Для каждого активного интервала [a, b):
for k=1:size(activeRanges,1)
    % границы интервала;
    a=activeRanges(k,1); b=activeRanges(k,2);
    % интервал внутри сигнала, непустой, целые границы;
    assert(a>=0 && b<=numel(waveform) && b>a && a==fix(a) && b==fix(b),'nbiot:ActiveRange','Invalid active sample range.');
    % отмечаем отсчёты a+1..b (индексы MATLAB с единицы).
    mask(a+1:b)=true;
end
% Хотя бы один активный отсчёт должен быть.
assert(any(mask),'nbiot:EmptyActive','No active transmission samples.');
% Средняя мощность по активным отсчётам.
activePowerW=mean(abs(waveform(mask)).^2);
% Мощность должна быть конечной и положительной.
assert(activePowerW>0 && isfinite(activePowerW),'nbiot:WaveformPower','Active waveform must have finite positive power.');
% Целевая мощность в Вт = 10^((дБм − 30)/10); масштабируем амплитуду; возвращаем целевую мощность.
target=10^((txPowerDbm-30)/10); waveform=waveform*sqrt(target/activePowerW); activePowerW=target;
end
