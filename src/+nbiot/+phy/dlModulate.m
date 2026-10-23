function w=dlModulate(enb,grid)
%DLMODULATE OFDM-модуляция одного подкадра NB-IoT DL (12 поднесущих × 14 символов → 1920 отсчётов).
%   Используется lteSCFDMAModulate со сдвигом на половину поднесущей, как в примере MathWorks NPDSCH.
enb.NBULSubcarrierSpacing='15kHz';
[w,info]=lteSCFDMAModulate(enb,grid);
assert(info.SamplingRate==1920000 && size(w,1)==1920,...
    'nbiot:phy:SampleRate','Unexpected narrowband OFDM subframe size.');
end
