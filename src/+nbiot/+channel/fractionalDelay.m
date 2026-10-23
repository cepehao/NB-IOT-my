function [waveform,startOffsetSamples,kernel]=fractionalDelay(waveform,delaySamples,filterLength)
%FRACTIONALDELAY Дробная задержка сигнала FIR-фильтром windowed-sinc (ТЗ §17: timing offset).
%   [Y, OFFSET, KERNEL] = nbiot.channel.fractionalDelay(X, DELAYSAMPLES, L).
%   Ядро: sinc(n − дробная часть) с окном Ханна длиной L (нечётная, по умолчанию 65), сумма = 1.
%   Y — полная свёртка; OFFSET = целая часть задержки − (L−1)/2 — сдвиг начала Y в отсчётах.
%   При пустом X возвращает только KERNEL (так его использует RadioChannel).
if nargin<3, filterLength=65; end
validateattributes(delaySamples,{'numeric'},{'scalar','real','finite'});
validateattributes(filterLength,{'numeric'},{'scalar','integer','>=',3}); assert(mod(filterLength,2)==1);
integer=floor(delaySamples); half=(filterLength-1)/2; n=(-half:half)';
z=n-(delaySamples-integer); kernel=ones(size(z)); nz=z~=0;
kernel(nz)=sin(pi*z(nz))./(pi*z(nz));
kernel=kernel.*(0.5+0.5*cos(pi*n/(half+1))); kernel=kernel/sum(kernel);
startOffsetSamples=integer-half;
if isempty(waveform), waveform=complex(zeros(0,1)); else, waveform=conv(double(waveform(:)),kernel); end
end
