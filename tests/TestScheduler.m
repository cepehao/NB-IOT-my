classdef TestScheduler < matlab.unittest.TestCase
    methods (Test)
        function ackResourceZeroGoldenTiming(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg); s=nbiot.scheduler.Scheduler(cfg,c);
            % Final NPDSCH subframe n=99 ends at tick100. k0=13 means
            % ACK starts at the end of subframe111, absolute tick112.
            payload=struct('endTick',100); dci=struct('ackResource',0);
            g=s.reconstructAck(dci,payload,100);
            t.verifyEqual(g.startTick,112); t.verifyEqual(g.ticks,112:115);
            t.verifyEqual(g.frequencyStartHz,0); t.verifyEqual(g.endTick,116);
        end
        function uplinkReconstruction(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg); s=nbiot.scheduler.Scheduler(cfg,c); s.reserveNprach();
            q=s.uplink('Data','DT',0,500,100,1,2); t.assertNotEmpty(q);
            monitor=c.monitoringTicks(floor(q.controlGrant.startTick/32)*32);
            t.verifyEqual(q.controlGrant.ticks,monitor(1:2));
            g=s.reconstructUplink(q.dci,q.controlGrant.ticks,100);
            t.verifyEqual(g.ticks,q.payloadGrant.ticks); t.verifyEqual(g.grantId,0); t.verifyEqual(g.profile.tbs,256); t.verifyEqual(g.endTick-g.startTick,32);
        end
        function rarHasReservedMsg3AndNoAck(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg); s=nbiot.scheduler.Scheduler(cfg,c); s.reserveNprach();
            q=s.downlink('RAR','RA',16,400,1); t.assertNotEmpty(q); t.verifyEmpty(q.ackGrant);
            g=s.reconstructMsg3(q.rarGrant,q.payloadGrant.ticks);
            t.verifyEqual(g.ticks,q.msg3Grant.ticks); t.verifyEqual(g.profile.tbs,88); t.verifyEqual(g.profile.numSubcarriers,3);
            t.verifyEqual(g.endTick-g.startTick,8); t.verifyEqual(g.startTick,q.payloadGrant.endTick+12);
            t.verifyFalse(c.isFree(TestCalendar.plan('UL','RA',g.ticks,g.frequencyStartHz,g.bandwidthHz,99999)));
        end
        function failedTransactionHasNoPartialControl(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg); s=nbiot.scheduler.Scheduler(cfg,c);
            before=c.usage(); q=s.uplink('Data','DT',0,5,100,0,0); t.verifyEmpty(q); t.verifyEqual(c.usage(),before);
        end
        function downlinkAckReconstruction(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg); s=nbiot.scheduler.Scheduler(cfg,c);
            q=s.downlink('Receipt','DT',0,300,100); t.assertNotEmpty(q);
            g=s.reconstructDownlink(q.dci,q.controlGrant.ticks,100); a=s.reconstructAck(q.dci,g,100);
            t.verifyEqual(g.ticks,q.payloadGrant.ticks); t.verifyEqual(a.ticks,q.ackGrant.ticks); t.verifyFalse(any(c.mandatoryMask(g.ticks+1)));
        end
    end
end
