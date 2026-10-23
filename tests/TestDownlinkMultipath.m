classdef TestDownlinkMultipath < matlab.unittest.TestCase
    methods (Test)
        function defaultDelayBoundaryAndCfoRemainDecodable(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            scheduler=nbiot.scheduler.Scheduler(cfg,nbiot.scheduler.ResourceCalendar(cfg));
            dl=scheduler.downlink('Receipt','DT',128,400,101);
            bits=int8(mod((0:87)',2));
            [data,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
            control=nbiot.phy.npdcch.buildTransmission(cfg,dl.controlGrant,dl.dci);
            distance=hypot(cfg.cell.radiusM,cfg.cell.bsHeightM-cfg.cell.ueHeightM);
            edge=distance/299792458*cfg.simulation.sampleRateHz;
            lastTap=edge+max(cfg.channel.tapDelaysSeconds)*cfg.simulation.sampleRateHz;
            t.verifyLessThan(lastTap,1920000/(2*6*15000));
            for delay=[0 edge lastTap]
                for cfo=[-cfg.channel.cfoLimitHz 0 cfg.channel.cfoLimitHz]
                    rx=delayed(data,delay,cfo);
                    [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,dl.payloadGrant,[]);
                    t.verifyFalse(decoded.crcError); t.verifyEqual(decoded.decodedBits,bits);
                    decoded=nbiot.phy.npdcch.receive(cfg,delayed(control,delay,cfo),dl.controlGrant);
                    t.verifyFalse(decoded.crcError); t.verifyEqual(decoded.dci,dl.dci);
                end
            end
        end

        function savedNoisyFailureCannotAcceptWrongPayload(t)
            f=fixture(); cfg=nbiot.config.defaultConfig();
            [decoded,~]=nbiot.phy.npdsch.receive(cfg,f.rx,f.grant.payloadGrant,[]);
            % A future improved receiver may decode this noisy window. CRC
            % acceptance still requires the exact payload; zero BLER is not assumed.
            if ~decoded.crcError, t.verifyEqual(decoded.decodedBits,f.expectedPayload); end
            t.verifyEqual(decoded.hasCrc,true);
        end

        function wrongRntiRejectsPhysicalDownlink(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            scheduler=nbiot.scheduler.Scheduler(cfg,nbiot.scheduler.ResourceCalendar(cfg));
            dl=scheduler.downlink('Receipt','DT',128,400,101); bits=int8(mod((0:87)',2));
            [data,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
            control=nbiot.phy.npdcch.buildTransmission(cfg,dl.controlGrant,dl.dci);
            edge=hypot(cfg.cell.radiusM,cfg.cell.bsHeightM-cfg.cell.ueHeightM)/299792458*1920000;
            wrongControl=dl.controlGrant; wrongControl.rnti=102;
            wrongData=dl.payloadGrant; wrongData.rnti=102;
            for delay=[0 edge]
                for cfo=[-200 0 200]
                    decoded=nbiot.phy.npdcch.receive(cfg,delayed(control,delay,cfo),wrongControl);
                    t.verifyTrue(decoded.hasCrc); t.verifyTrue(decoded.crcError); t.verifyEmpty(decoded.dci);
                    [decoded,~]=nbiot.phy.npdsch.receive(cfg,delayed(data,delay,cfo),wrongData,[]);
                    t.verifyTrue(decoded.hasCrc); t.verifyTrue(decoded.crcError);
                end
            end
        end

        function noiseOnlyCannotPassThisCrcRegression(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            scheduler=nbiot.scheduler.Scheduler(cfg,nbiot.scheduler.ResourceCalendar(cfg));
            dl=scheduler.downlink('Receipt','DT',128,400,101);
            for g=[dl.controlGrant dl.payloadGrant]
                sources=nbiot.randomness.RandomSources(42,3600);
                for trial=1:10
                    stream=sources.stream('noise',1,1,950000+trial);
                    count=(g.endTick-g.startTick)*1920+256;
                    rx=struct('waveform',complex(randn(stream,count,1),randn(stream,count,1)),...
                        'sampleRateHz',1920000,'startSample',g.startTick*1920-128);
                    if strcmp(g.kind,'NPDCCH'), decoded=nbiot.phy.npdcch.receive(cfg,rx,g);
                    else, [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,g,[]); end
                    t.verifyTrue(decoded.hasCrc); t.verifyTrue(decoded.crcError);
                end
            end
            % Finite regression only: CRC acceptance is never claimed impossible.
        end

        function savedMultipathWithoutNoiseIsDecodable(t)
            f=fixture(); cfg=nbiot.config.defaultConfig();
            [tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,f.grant.payloadGrant,f.expectedPayload,[]);
            rx=f.rx; rx.waveform=complex(zeros(size(rx.waveform)));
            for tap=1:numel(f.taps)
                [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,...
                    f.delaySamples+cfg.channel.tapDelaysSeconds(tap)*1920000,65);
                at=tx.startSample+offset-rx.startSample+1;
                rx.waveform(at:at+numel(w)-1)=rx.waveform(at:at+numel(w)-1)+f.taps(tap)*w;
            end
            rx.waveform=rx.waveform.*exp(1i*2*pi*f.cfoHz*(rx.startSample+(0:numel(rx.waveform)-1)')/1920000);
            [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,f.grant.payloadGrant,[]);
            t.verifyFalse(decoded.crcError); t.verifyEqual(decoded.decodedBits,f.expectedPayload);
        end

        function outsideProfileDelayCannotAcceptWrongPayload(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            scheduler=nbiot.scheduler.Scheduler(cfg,nbiot.scheduler.ResourceCalendar(cfg));
            dl=scheduler.downlink('Receipt','DT',128,400,101); bits=int8(mod((0:87)',2));
            [tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
            delay=11.5; t.verifyGreaterThan(delay,1920000/(2*6*15000));
            [decoded,~]=nbiot.phy.npdsch.receive(cfg,delayed(tx,delay,0),dl.payloadGrant,[]);
            if ~decoded.crcError, t.verifyEqual(decoded.decodedBits,bits); end
        end

        function freshDefaultMultipathCornerIsDecodableWithoutNoise(t)
            data=load(fullfile(fileparts(mfilename('fullpath')),'fixtures',...
                'dl-multipath-clean-corner.mat'),'failure'); f=data.failure;
            cfg=nbiot.config.defaultConfig();
            [tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,f.grant.payloadGrant,f.expectedPayload,[]);
            rx=f.rx; rx.waveform=complex(zeros(size(rx.waveform)));
            for tap=1:numel(f.taps)
                [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,...
                    f.delaySamples+cfg.channel.tapDelaysSeconds(tap)*1920000,65);
                at=tx.startSample+offset-rx.startSample+1;
                rx.waveform(at:at+numel(w)-1)=rx.waveform(at:at+numel(w)-1)+f.taps(tap)*w;
            end
            rx.waveform=rx.waveform.*exp(1i*2*pi*f.cfoHz*(rx.startSample+(0:numel(rx.waveform)-1)')/1920000);
            [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,f.grant.payloadGrant,[]);
            t.verifyFalse(decoded.crcError); t.verifyEqual(decoded.decodedBits,f.expectedPayload);
        end

        function awgnNoiseEstimateCannotCollapseToMachineEpsilon(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            scheduler=nbiot.scheduler.Scheduler(cfg,nbiot.scheduler.ResourceCalendar(cfg));
            dl=scheduler.downlink('Receipt','DT',128,400,101); bits=int8(mod((0:87)',2));
            [tx,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
            signal=[complex(zeros(128,1));tx.waveform;complex(zeros(128,1))];
            sources=nbiot.randomness.RandomSources(42,3001); stream=sources.stream('noise',1,1,990002);
            noise=sqrt(.01/2)*(randn(stream,size(signal))+1i*randn(stream,size(signal)));
            rx=struct('waveform',signal+noise,'sampleRateHz',1920000,'startSample',tx.startSample-128);
            [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,dl.payloadGrant,[]);
            enb=struct('NNCellID',cfg.phy.cellId,'NBRefP',1,'OperationMode','Standalone',...
                'NFrame',floor(dl.payloadGrant.ticks(end)/10),'NSubframe',mod(dl.payloadGrant.ticks(end),10),...
                'NBULSubcarrierSpacing','15kHz','Windowing',0);
            first=dl.payloadGrant.ticks(end)*1920-rx.startSample+1;
            gridNoise=lteSCFDMADemodulate(enb,noise(first:first+1919),0.55);
            reference=mean(abs(gridNoise(:)).^2);
            t.verifyGreaterThan(decoded.measurements.noiseEstimate,reference*.05);
            t.verifyLessThan(decoded.measurements.noiseEstimate,reference*20);
        end
    end
end

function f=fixture()
data=load(fullfile(fileparts(mfilename('fullpath')),'fixtures','dl-multipath-noisy-failure.mat'),'failure');
f=data.failure;
end

function rx=delayed(tx,delay,cfo)
[w,offset]=nbiot.channel.fractionalDelay(tx.waveform,delay,65);
first=tx.startSample+offset; w=w.*exp(1i*2*pi*cfo*(first+(0:numel(w)-1)')/1920000);
wave=complex(zeros(numel(tx.waveform)+256,1)); at=offset+129; wave(at:at+numel(w)-1)=w;
rx=struct('waveform',wave,'sampleRateHz',1920000,'startSample',tx.startSample-128);
end
