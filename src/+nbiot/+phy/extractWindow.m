function w=extractWindow(rx,startSample,count)
%EXTRACTWINDOW COUNT отсчётов принятого сигнала RX, начиная с абсолютного отсчёта STARTSAMPLE.
%   Ошибка nbiot:phy:RxWindow, если окно приёма не покрывает запрошенный интервал.
% Принятый сигнал должен быть на частоте 1,92 МГц.
assert(rx.sampleRateHz==1920000,'nbiot:phy:SampleRate','Expected 1.92 MHz.');
% Индекс (с единицы) первого нужного отсчёта внутри принятого окна.
first=startSample-rx.startSample+1;
% Запрошенный интервал должен целиком лежать в принятом окне.
assert(first>=1 && first+count-1<=size(rx.waveform,1),'nbiot:phy:RxWindow','Receive window does not cover requested physical samples.');
% Вырезаем COUNT отсчётов.
w=rx.waveform(first:first+count-1,:);
end
