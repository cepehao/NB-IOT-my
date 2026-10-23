function [waveform,startOffsetSamples,kernel]=fractionalDelay(waveform,delaySamples,filterLength)
% Full convolution; timestamp offset compensates FIR implementation latency.
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
