function report=verifyRoundtrips()
% Actual waveform acceptance, invoked explicitly on a licensed MATLAB PC.
cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
calendar=nbiot.scheduler.ResourceCalendar(cfg); scheduler=nbiot.scheduler.Scheduler(cfg,calendar);
ul=scheduler.uplink('Data','DT',0,256,100,1,0);
bits=int8(mod((0:255)',2)); [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,ul.payloadGrant,bits,[]);
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
[decoded,~]=nbiot.phy.npusch.receive(cfg,rx,ul.payloadGrant,[]);
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits),'nbiot:phy:Acceptance','NPUSCH waveform roundtrip failed.');
% A real sample delay, margins and pilot-derived timing; no channel truth input.
delaySamples=11;
rx=struct('waveform',[zeros(128+delaySamples,1);tx.waveform;zeros(128-delaySamples,1)],...
    'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample-128);
[decoded,~]=nbiot.phy.npusch.receive(cfg,rx,ul.payloadGrant,[]);
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits) && ...
    abs(decoded.measurements.timing.delaySamples-delaySamples)<=2,...
    'nbiot:phy:Acceptance','Received DM-RS timing acceptance failed.');
tx=nbiot.phy.npdcch.buildTransmission(cfg,ul.controlGrant,ul.dci);
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
monitor=struct('ticks',ul.controlGrant.ticks,'rnti',100,'profile',ul.controlGrant.profile,'format','N0');
decoded=nbiot.phy.npdcch.receive(cfg,rx,monitor);
assert(decoded.crcError==0 && isequal(decoded.dci,ul.dci),'nbiot:phy:Acceptance','NPDCCH waveform roundtrip failed.');
dl=scheduler.downlink('Receipt','DT',128,400,101); bits=int8(mod((0:87)',2));
[tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
[decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,dl.payloadGrant,[]);
assert(decoded.crcError==0 && isequal(bits,decoded.decodedBits),'nbiot:phy:Acceptance','NPDSCH waveform roundtrip failed.');
g=dl.ackGrant;
for bit=0:1
    [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(bit),[]);
    rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
    [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
    assert(~decoded.hasCrc && isnan(decoded.crcError) && decoded.measurements.uciDetected && ...
        isequal(decoded.decodedBits,int8(bit)),'nbiot:phy:Acceptance','UCI waveform roundtrip failed.');
end
report=struct('npusch',true,'npdcch',true,'npdsch',true,'uci',true,'release',version('-release'));
end
