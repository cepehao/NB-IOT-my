function report=verifyRoundtrips()
%VERIFYROUNDTRIPS Проверка PHY без канала: NPUSCH (с задержкой 11 отсчётов), NPDCCH, NPDSCH, UCI.
%   Передача → приём должна вернуть те же биты с CRC OK (ТЗ §33, §39). Вызывается из
%   examples/checkEnvironment; бросает nbiot:phy:Acceptance при сбое.
% Короткая конфигурация (512 тиков) для проверки.
cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
% Календарь и планировщик — получить корректные назначения.
calendar=nbiot.scheduler.ResourceCalendar(cfg); scheduler=nbiot.scheduler.Scheduler(cfg,calendar);
% Назначение данных UL (DCI N0 + NPUSCH) для RNTI 100.
ul=scheduler.uplink('Data','DT',0,256,100,1,0);
% 256 тестовых бит → waveform NPUSCH.
bits=int8(mod((0:255)',2)); [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,ul.payloadGrant,bits,[]);
% Принятый сигнал = переданный (без канала и шума).
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
% Приём NPUSCH.
[decoded,~]=nbiot.phy.npusch.receive(cfg,rx,ul.payloadGrant,[]);
% CRC прошёл и биты совпали.
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits),'nbiot:phy:Acceptance','NPUSCH waveform roundtrip failed.');
% A real sample delay, margins and pilot-derived timing; no channel truth input.
delaySamples=11;
% Тот же сигнал с задержкой 11 отсчётов и запасом 128 отсчётов по краям.
rx=struct('waveform',[zeros(128+delaySamples,1);tx.waveform;zeros(128-delaySamples,1)],...
    'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample-128);
% Приём с оценкой задержки.
[decoded,~]=nbiot.phy.npusch.receive(cfg,rx,ul.payloadGrant,[]);
% CRC прошёл, биты совпали, задержка оценена с точностью ±2 отсчёта.
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits) && ...
    abs(decoded.measurements.timing.delaySamples-delaySamples)<=2,...
    'nbiot:phy:Acceptance','Received DM-RS timing acceptance failed.');
% Waveform NPDCCH с DCI этого назначения.
tx=nbiot.phy.npdcch.buildTransmission(cfg,ul.controlGrant,ul.dci);
% Принятый = переданный.
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
% Кандидат поиска: подкадры, RNTI 100, формат N0.
monitor=struct('ticks',ul.controlGrant.ticks,'rnti',100,'profile',ul.controlGrant.profile,'format','N0');
% Приём DCI.
decoded=nbiot.phy.npdcch.receive(cfg,rx,monitor);
% CRC прошёл и DCI совпал.
assert(decoded.crcError==0 && isequal(decoded.dci,ul.dci),'nbiot:phy:Acceptance','NPDCCH waveform roundtrip failed.');
% Назначение DL (квитанция) для RNTI 101; 88 тестовых бит.
dl=scheduler.downlink('Receipt','DT',128,400,101); bits=int8(mod((0:87)',2));
% Waveform NPDSCH.
[tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
% Принятый = переданный.
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
% Приём NPDSCH.
[decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,dl.payloadGrant,[]);
% CRC прошёл и биты совпали.
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits),'nbiot:phy:Acceptance','NPDSCH waveform roundtrip failed.');
% Ресурс ACK из этого назначения.
g=dl.ackGrant;
% Для значений ACK 0 и 1:
for bit=0:1
    % waveform NPUSCH формата 2 с битом;
    [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(bit),[]);
    % принятый = переданный;
    rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
    % приём;
    [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
    % CRC нет, ACK обнаружен, бит совпал.
    assert(~decoded.hasCrc && isnan(decoded.crcError) && decoded.measurements.uciDetected && ...
        isequal(decoded.decodedBits,int8(bit)),'nbiot:phy:Acceptance','UCI waveform roundtrip failed.');
end
% Отчёт: все проверки пройдены, версия MATLAB.
report=struct('npusch',true,'npdcch',true,'npdsch',true,'uci',true,'release',version('-release'));
end
