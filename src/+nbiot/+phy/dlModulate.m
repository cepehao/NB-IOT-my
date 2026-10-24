function w=dlModulate(enb,grid)
%DLMODULATE OFDM-модуляция одного подкадра NB-IoT DL (12 поднесущих × 14 символов → 1920 отсчётов).
%   Используется lteSCFDMAModulate со сдвигом на половину поднесущей, как в примере MathWorks NPDSCH.
% Разнос 15 кГц задаёт сетку 12 × 14 и частоту 1,92 МГц.
enb.NBULSubcarrierSpacing='15kHz';
% Модуляция подкадра (SC-FDMA-модулятор LTE Toolbox со сдвигом на половину поднесущей).
[w,info]=lteSCFDMAModulate(enb,grid);
% Подкадр = 1920 отсчётов при 1,92 МГц.
assert(info.SamplingRate==1920000 && size(w,1)==1920,...
    'nbiot:phy:SampleRate','Unexpected narrowband OFDM subframe size.');
end
