classdef TestPhyWaveforms < matlab.unittest.TestCase
    methods (Test)
        function actualToolboxRoundtrips(test)
            test.assumeTrue(~isempty(which('lteNPUSCH')),'Requires licensed target MATLAB LTE Toolbox.');
            report=nbiot.phy.verifyRoundtrips();
            test.verifyTrue(report.npusch && report.npdsch && report.npdcch && report.uci);
        end
        function nprachAllIndicesAndNoise(test)
            test.assumeTrue(~isempty(which('lteNPRACH')),'Requires target LTE Toolbox.');
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.9;
            occasion=struct('occasionId',1,'startTick',8);
            for i=0:11
                tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,i);
                rx=struct('waveform',[zeros(16,1);tx.waveform;zeros(128,1)],...
                    'sampleRateHz',1920000,'startSample',tx.startSample-16);
                decoded=nbiot.phy.nprach.detect(cfg,rx,occasion);
                test.verifyTrue(any([decoded.nInit]==i));
            end
            rx.waveform(:)=0; decoded=nbiot.phy.nprach.detect(cfg,rx,occasion);
            test.verifyEmpty(decoded);
        end
    end
end
