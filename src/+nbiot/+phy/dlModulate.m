function w=dlModulate(enb,grid)
% NB-IoT DL uses half-subcarrier shifted OFDM, as in MathWorks NPDSCH example.
enb.NBULSubcarrierSpacing='15kHz';
[w,info]=lteSCFDMAModulate(enb,grid);
assert(info.SamplingRate==1920000 && size(w,1)==1920,...
    'nbiot:phy:SampleRate','Unexpected narrowband OFDM subframe size.');
end
