classdef TestUciAlias < matlab.unittest.TestCase
    methods (Test)
        function knownNoiselessAliasHasIdenticalWaveform(t)
            cfg=nbiot.config.defaultConfig(); g=controlGrant(cfg,100);
            other=g; other.rnti=2103;
            [ack,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(1),[]);
            [foreignNack,~]=nbiot.phy.npusch.buildTransmission(cfg,other,int8(0),[]);
            t.verifyEqual(foreignNack.waveform,ack.waveform);
            rx=struct('waveform',foreignNack.waveform,'sampleRateHz',1920000,...
                'startSample',foreignNack.startSample);
            [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
            t.verifyEqual(decoded.decodedBits,int8(1));
            t.verifyTrue(decoded.measurements.uciDetected);
            t.verifyFalse(decoded.hasCrc);
            t.verifyTrue(isnan(decoded.crcError));
        end

        function obsoleteAckStateDoesNotChangeContext(t)
            [sim,id,otherId]=queuedAckFixture(t);
            c=sim.contexts.get(id); c.state='DATA_PENDING'; c.pending=false;
            c.softBuffer=struct('sentinel',17); sim.contexts.set(id,c);
            unrelated=sim.contexts.get(otherId);

            sim.step();

            t.verifyEqual(sim.contexts.get(id),c);
            t.verifyEqual(sim.contexts.get(otherId),unrelated);
        end

        function obsoleteAckGrantDoesNotChangeContext(t)
            [sim,id,otherId]=queuedAckFixture(t);
            c=sim.contexts.get(id);
            c.schedule.ackGrant.grantId=c.schedule.ackGrant.grantId+100000;
            sim.contexts.set(id,c); unrelated=sim.contexts.get(otherId);

            sim.step();

            t.verifyEqual(sim.contexts.get(id),c);
            t.verifyEqual(sim.contexts.get(otherId),unrelated);
        end

        function terminalContextIdAndRntiAreNotReused(t)
            contexts=nbiot.ra.RaContextStore();
            oldId=contexts.create(0,1,100,0); old=contexts.get(oldId);
            old.state='DONE'; old.pending=false; contexts.set(oldId,old);
            newId=contexts.create(0,2,200,0); current=contexts.get(newId);
            t.verifyGreaterThan(newId,oldId);
            t.verifyNotEqual(current.rnti,old.rnti);
            t.verifyEqual(contexts.get(oldId),old);
        end
    end
end

function g=controlGrant(cfg,rnti)
p=cfg.phy.ack; start=40;
g=struct('grantId',1,'direction','UL','kind','Control','phase','DT',...
    'startTick',start,'endTick',start+p.durationTicks,'ticks',start:start+p.durationTicks-1,...
    'rnti',rnti,'ndi',0,'rv',0,'frequencyStartHz',0,'bandwidthHz',15000,'profile',p);
end

function [sim,id,otherId]=queuedAckFixture(t)
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
cfg.traffic.kind='none'; cfg.phy.nprachThreshold=1;
sim=nbiot.NBIoTSimulator(cfg);
id=sim.contexts.create(0,1,1000,0); c=sim.contexts.get(id);
c.state='MSG4_PENDING'; c.token=uint64(1); sim.contexts.set(id,c);
otherId=sim.contexts.create(1,1,1000,0); other=sim.contexts.get(otherId);
other.state='DONE'; other.pending=false; sim.contexts.set(otherId,other);
sim.step(); c=sim.contexts.get(id);
t.assertEqual(c.state,'MSG4_ACK');
completionTick=c.schedule.ackGrant.endTick+cfg.phy.processingTicks+1;
sim.run(completionTick-1);
t.assertEqual(sim.status,'partial',evalc('disp(sim.errorInfo)'));
t.assertEqual(sim.currentTick,completionTick-1);
end
