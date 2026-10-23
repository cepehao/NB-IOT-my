classdef TestDownlinkTiming < matlab.unittest.TestCase
    methods (Test)
        function cellEdgeDelayDoesNotBreakHighSnrDownlink(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.durationTicks=512;
            calendar=nbiot.scheduler.ResourceCalendar(cfg);
            scheduler=nbiot.scheduler.Scheduler(cfg,calendar);
            dl=scheduler.downlink('Receipt','DT',128,400,101);
            bits=int8(mod((0:87)',2));
            [dataTx,~]=nbiot.phy.npdsch.buildTransmission(cfg,dl.payloadGrant,bits,[]);
            controlTx=nbiot.phy.npdcch.buildTransmission(cfg,dl.controlGrant,dl.dci);
            for cfo=[-200 0 200]
                rx=TestDownlinkTiming.delayed(dataTx,6.4,cfo);
                [decoded,~]=nbiot.phy.npdsch.receive(cfg,rx,dl.payloadGrant,[]);
                t.verifyFalse(decoded.crcError,sprintf('NPDSCH failed at cell-edge delay, CFO %g.',cfo));
                t.verifyEqual(decoded.decodedBits,bits);
                rx=TestDownlinkTiming.delayed(controlTx,6.4,cfo);
                decoded=nbiot.phy.npdcch.receive(cfg,rx,dl.controlGrant);
                t.verifyFalse(decoded.crcError); t.verifyEqual(decoded.dci,dl.dci);
            end
        end
    end
    methods (Static,Access=private)
        function rx=delayed(tx,delay,cfo)
            [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,delay,65);
            first=tx.startSample+offset;
            w=w.*exp(1i*2*pi*cfo*(first+(0:numel(w)-1)')/1920000);
            waveform=complex(zeros(numel(tx.waveform)+256,1)); at=offset+129;
            waveform(at:at+numel(w)-1)=w;
            rx=struct('waveform',waveform,'sampleRateHz',1920000,'startSample',tx.startSample-128);
        end
    end
end
