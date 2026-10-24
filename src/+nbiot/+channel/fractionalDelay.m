function [waveform,startOffsetSamples,kernel]=fractionalDelay(waveform,delaySamples,filterLength)
%FRACTIONALDELAY Дробная задержка сигнала FIR-фильтром windowed-sinc (ТЗ §17: timing offset).
%   [Y, OFFSET, KERNEL] = nbiot.channel.fractionalDelay(X, DELAYSAMPLES, L).
%   Ядро: sinc(n − дробная часть) с окном Ханна длиной L (нечётная, по умолчанию 65), сумма = 1.
%   Y — полная свёртка; OFFSET = целая часть задержки − (L−1)/2 — сдвиг начала Y в отсчётах.
%   При пустом X возвращает только KERNEL (так его использует RadioChannel).
% Длина фильтра по умолчанию — 65 отсчётов.
if nargin<3, filterLength=65; end
% Задержка — конечное действительное число отсчётов.
validateattributes(delaySamples,{'numeric'},{'scalar','real','finite'});
% Длина фильтра — целое >= 3, нечётное (симметричное ядро).
validateattributes(filterLength,{'numeric'},{'scalar','integer','>=',3}); assert(mod(filterLength,2)==1);
% Целая часть задержки; половина длины фильтра; индексы ядра −half..half.
integer=floor(delaySamples); half=(filterLength-1)/2; n=(-half:half)';
% Аргумент sinc со сдвигом на дробную часть; ядро; где аргумент не ноль.
z=n-(delaySamples-integer); kernel=ones(size(z)); nz=z~=0;
% sinc(z) = sin(πz)/(πz); в нуле значение 1 (уже задано).
kernel(nz)=sin(pi*z(nz))./(pi*z(nz));
% Окно Ханна по длине фильтра и нормировка суммы ядра на 1 (без изменения мощности).
kernel=kernel.*(0.5+0.5*cos(pi*n/(half+1))); kernel=kernel/sum(kernel);
% Сдвиг начала результата относительно входа: целая задержка − половина фильтра.
startOffsetSamples=integer-half;
% Без сигнала — пустой результат (нужно только ядро); иначе — полная свёртка с ядром.
if isempty(waveform), waveform=complex(zeros(0,1)); else, waveform=conv(double(waveform(:)),kernel); end
end
