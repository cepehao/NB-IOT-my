classdef TestUciPresence < matlab.unittest.TestCase
    methods (Test)
        function foreignRntiControlDoesNotPassPresenceGate(t)
            cfg=nbiot.config.defaultConfig();
            g=TestUciPresence.controlGrant(cfg,100);
            for other=201:208
                for bit=0:1
                    txGrant=g; txGrant.rnti=other;
                    [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,txGrant,int8(bit),[]);
                    rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
                    [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
                    t.verifyFalse(decoded.measurements.uciDetected,sprintf('Foreign RNTI %d bit %d was treated as UCI for RNTI 100.',other,bit));
                end
            end
        end
        function ownAckAndNackRemainDetected(t)
            cfg=nbiot.config.defaultConfig(); g=TestUciPresence.controlGrant(cfg,100);
            for bit=0:1
                [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(bit),[]);
                rx=struct('waveform',tx.waveform,'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample);
                [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
                t.verifyTrue(decoded.measurements.uciDetected);
                t.verifyEqual(decoded.decodedBits,int8(bit));
                t.verifyFalse(decoded.hasCrc); t.verifyTrue(isnan(decoded.crcError));
            end
        end
    end
    methods (Static,Access=private)
        function g=controlGrant(cfg,rnti)
            p=cfg.phy.ack; start=40;
            g=struct('grantId',1,'direction','UL','kind','Control','phase','DT',...
                'startTick',start,'endTick',start+p.durationTicks,...
                'ticks',start:start+p.durationTicks-1,'rnti',rnti,'ndi',0,'rv',0,...
                'frequencyStartHz',0,'bandwidthHz',15000,'profile',p);
        end
    end
end
