function w=extractWindow(rx,startSample,count)
assert(rx.sampleRateHz==1920000,'nbiot:phy:SampleRate','Expected 1.92 MHz.');
first=startSample-rx.startSample+1;
assert(first>=1 && first+count-1<=size(rx.waveform,1),'nbiot:phy:RxWindow','Receive window does not cover requested physical samples.');
w=rx.waveform(first:first+count-1,:);
end
