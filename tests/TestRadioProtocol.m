classdef TestRadioProtocol < matlab.unittest.TestCase
    methods(Test)
        function runAndStepHaveIdenticalPhysicalResults(t)
            [cfg,scenario]=fixture(1200);
            a=nbiot.NBIoTSimulator(cfg,scenario); a.run();
            b=nbiot.NBIoTSimulator(cfg,scenario);
            while ~strcmp(b.status,'completed'), b.step(); end
            x=a.result(); y=b.result(); x.profiling=[]; y.profiling=[];
            % lifecycleLog records run()/step() calls, not physics.
            x.lifecycleLog=[]; y.lifecycleLog=[];
            t.verifyEqual(y,x); t.verifyEqual(x.kpiSummary.delivered,1);
        end
        function partialExportDoesNotMutateResume(t)
            [cfg,scenario]=fixture(1200);
            a=nbiot.NBIoTSimulator(cfg,scenario); a.run(200); snapshot=a.snapshot(); partial=a.result();
            t.verifyEqual(a.snapshot(),snapshot); t.verifyEqual(partial.status,'partial');
            a.run(); b=nbiot.NBIoTSimulator(cfg,scenario); b.run();
            x=a.result(); y=b.result(); x.profiling=[]; y.profiling=[];
            x.lifecycleLog=[]; y.lifecycleLog=[]; t.verifyEqual(x,y);
        end
        function missingCalibrationIsReportedAsFailed(t)
            [cfg,scenario]=fixture(100); cfg.phy.nprachThreshold=NaN;
            sim=nbiot.NBIoTSimulator(cfg,scenario); sim.run(); r=sim.result();
            t.verifyEqual(r.status,'failed'); t.verifyEqual(r.error.identifier,'nbiot:phy:Calibration');
        end
        function lossOfRarReachesEightAttemptLimit(t)
            [cfg,scenario]=fixture(3500); cfg.ra.rarPp=2; cfg.ra.backoffTicks=0;
            [r,removed]=runWithPhysicalLoss(cfg,scenario,'RAR',Inf);
            t.verifyGreaterThan(removed,0); t.verifyEqual(r.kpiSummary.delivered,0);
            t.verifyEqual(r.packetLog.attemptCount,8); t.verifyEqual(r.packetLog.reason,'ra_limit');
        end
        function lossOfDataN0UsesFourHarqBundles(t)
            [cfg,scenario]=fixture(2000);
            [r,removed,grants]=runWithPhysicalLoss(cfg,scenario,'DataControl',Inf);
            t.verifyEqual(removed,4); t.verifyEqual(r.kpiSummary.delivered,0);
            t.verifyEqual(r.kpiSummary.dataCrcFailures,4);
            t.verifyEqual(r.packetLog.reason,'progress_timeout');
            t.verifyEqual([grants.rv],[0 2 0 2]); t.verifyEqual(unique([grants.ndi]),0);
            t.verifyEqual(r.kpiSummary.harq.transmissionsStarted,0);
            t.verifyTrue(isnan(r.kpiSummary.harq.firstTransmissionBler));
            t.verifyEqual(r.kpiSummary.harq.firstReceiverBler,1);
        end
        function lostFirstN0DoesNotBecomeFirstTransmittedTbFailure(t)
            [cfg,scenario]=fixture(2000);
            [r,removed]=runWithPhysicalLoss(cfg,scenario,'DataControl',1);
            t.verifyEqual(removed,1); t.verifyEqual(r.kpiSummary.delivered,1);
            t.verifyEqual(r.kpiSummary.harq.firstTransmissionBler,0);
            t.verifyEqual(r.kpiSummary.harq.firstReceiverBler,1/8);
            t.verifyEqual(r.kpiSummary.harq.transmissionsStarted,8);
        end
        function lostReceiptControlCannotUndoBsDelivery(t)
            [cfg,scenario]=fixture(2600);
            [r,removed]=runWithPhysicalLoss(cfg,scenario,'Receipt',Inf);
            t.verifyGreaterThanOrEqual(removed,2); t.verifyEqual(r.kpiSummary.delivered,1);
            t.verifyEqual(r.kpiSummary.deliveredPayloadBits,1600);
            t.verifyEqual(r.kpiSummary.dropped,0); t.verifyFalse(r.packetLog.ueConfirmed);
        end
        function firstMsg4AckLossRetriesWithoutDuplicateRaSuccess(t)
            [cfg,scenario]=fixture(1400);
            [r,removed]=runWithPhysicalLoss(cfg,scenario,'Msg4Ack',1);
            t.verifyEqual(removed,1); t.verifyEqual(r.kpiSummary.raSuccess,1);
            t.verifyEqual(r.kpiSummary.delivered,1);
            t.verifyEqual(r.kpiSummary.deliveredPayloadBits,1600);
        end
        function lostReceiptAckCannotDuplicateThroughput(t)
            [cfg,scenario]=fixture(2800);
            [r,removed]=runWithPhysicalLoss(cfg,scenario,'ReceiptAck',1);
            t.verifyEqual(removed,1); t.verifyEqual(r.kpiSummary.delivered,1);
            t.verifyEqual(r.kpiSummary.deliveredPayloadBits,1600);
            t.verifyTrue(r.packetLog.ueConfirmed); t.verifyEqual(r.kpiSummary.dropped,0);
        end
        function intermediateAndLastDataTbRetryKeepUniqueDelivery(t)
            for mode={'FirstData','LastData'}
                [cfg,scenario]=fixture(1600);
                [r,removed]=runWithPhysicalLoss(cfg,scenario,mode{1},1);
                t.verifyEqual(removed,1); t.verifyEqual(r.kpiSummary.delivered,1);
                t.verifyEqual(r.kpiSummary.dataCrcFailures,1);
                t.verifyEqual(r.kpiSummary.dataDecoded,9);
                t.verifyEqual(r.kpiSummary.deliveredPayloadBits,1600);
            end
        end
        function msg4ReceiveAtDeadlinePrecedesTimeout(t)
            [cfg,scenario]=fixture(1400); sim=nbiot.NBIoTSimulator(cfg,scenario);
            while isempty(sim.contexts.entries) || ~strcmp(sim.contexts.get(1).state,'MSG4_ACK')
                sim.step(); t.assertLessThan(sim.currentTick,500);
            end
            c=sim.contexts.get(1); ready=c.schedule.payloadGrant.endTick+cfg.phy.processingTicks+1;
            sim.run(ready-1); d=sim.devices.get(1); t.assertEqual(d.state,'WAIT_MSG4');
            d.deadlineTick=ready; sim.devices.set(1,d); sim.step();
            t.verifyTrue(sim.devices.get(1).raSucceeded); t.verifyEqual(sim.attempts(1).status,'success');
            t.verifyEqual(sim.packets.counters.dropped,0);
        end
        function lifetimeAtLastDataReceiveCannotUndoDelivery(t)
            [cfg,scenario]=fixture(1400); reference=nbiot.runExperiment(cfg,scenario);
            t.assertEqual(reference.kpiSummary.delivered,1);
            cfg.traffic.lifetimeTicks=double(reference.packetLog.deliveredTick)-double(reference.packetLog.createdTick);
            result=nbiot.runExperiment(cfg,scenario);
            t.verifyEqual(result.kpiSummary.delivered,1); t.verifyEqual(result.kpiSummary.dropped,0);
            t.verifyEqual(result.kpiSummary.deliveredPayloadBits,1600);
        end
        function secondQueuedPacketUsesANewSequence(t)
            [cfg,scenario]=fixture(2200);
            second=scenario.arrivals(1); second.packetId=uint32(2); second.sequence=uint16(2);
            second.createdTick=uint64(1000); second.continuousTimeSeconds=1;
            second.payloadBits=1-second.payloadBits; scenario.arrivals(2)=second;
            result=nbiot.runExperiment(cfg,scenario);
            t.verifyEqual(result.kpiSummary.created,2); t.verifyEqual(result.kpiSummary.delivered,2);
            t.verifyEqual(result.kpiSummary.deliveredPayloadBits,3200);
            t.verifyTrue(all([result.packetLog.ueConfirmed]));
        end
    end
end

function [cfg,scenario]=fixture(duration)
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.simulation.durationTicks=duration;
cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1; cfg.cell.indoorFraction=0;
cfg.phy.nprachThreshold=.005; % Diagnostic physical fixture, not system KPI acceptance.
sources=nbiot.randomness.RandomSources(42,0); scenario=nbiot.scenario.buildScenario(cfg,sources);
u=scenario.ue(1); radius=50; distance=hypot(radius,cfg.cell.bsHeightM-cfg.cell.ueHeightM);
u.xM=radius; u.yM=0; u.horizontalDistanceM=radius; u.distanceM=distance;
u.pathLossDb=20*log10(4*pi*cfg.channel.carrierHz*10/299792458)+10*cfg.channel.pathLossExponent*log10(distance/10);
u.medianPathLossDb=u.pathLossDb; u.shadowingDb=0; u.penetrationDb=0;
u.cfoHz=0; u.syncOffsetSeconds=0; u.tapsUl=[1;0;0]; u.tapsDl=[1;0;0]; scenario.ue(1)=u;
end

function [r,removed,grants]=runWithPhysicalLoss(cfg,scenario,mode,limit)
sim=nbiot.NBIoTSimulator(cfg,scenario); seen=[]; removed=0; grants=[];
while ~strcmp(sim.status,'completed')
    prior=sim.devices.get(1); sim.step();
    for id=1:numel(sim.contexts.entries)
        c=sim.contexts.get(id); s=c.schedule;
        if isempty(s) || ~isfield(s,'controlGrant'), continue; end
        ackMode=strcmp(mode,'Msg4Ack') || strcmp(mode,'ReceiptAck');
        dataMode=strcmp(mode,'FirstData') || strcmp(mode,'LastData');
        if ackMode
            if isempty(s.ackGrant), continue; end
            g=s.ackGrant; kind=s.payloadGrant.kind;
            wanted=(strcmp(mode,'Msg4Ack') && strcmpi(kind,'Msg4')) || ...
                (strcmp(mode,'ReceiptAck') && strcmpi(kind,'Receipt'));
        elseif dataMode
            g=s.payloadGrant; device=sim.devices.get(1);
            wanted=strcmp(s.dci.format,'N0') && ...
                ((strcmp(mode,'FirstData') && device.fragmentIndex==0) || ...
                 (strcmp(mode,'LastData') && device.fragmentIndex==7));
        else
            g=s.controlGrant;
            wanted=(strcmp(mode,'DataControl') && strcmp(s.dci.format,'N0')) || ...
                (strcmp(mode,'RAR') && strcmp(s.dci.format,'N1') && strcmpi(s.payloadGrant.kind,'RAR')) || ...
                (strcmp(mode,'Receipt') && strcmp(s.dci.format,'N1') && strcmpi(s.payloadGrant.kind,'Receipt'));
        end
        if ~wanted || any(seen==g.grantId) || removed>=limit, continue; end
        if ackMode || dataMode
            % Test-only truth proves an actual ACK exists before cancellation.
            % A negative ACK alone would itself be a valid phase-rotated ACK.
            current=sim.result(); events=current.truthLog; exists=false;
            for k=1:numel(events)
                if strcmp(events(k).kind,'transmission')
                    f=events(k).fields;
                    exists=exists || (strcmp(f.direction,'UL') && f.ueId==1 && strcmp(f.channel,g.kind) && isequal(f.ticks,g.ticks));
                end
            end
            if ~exists, continue; end
            device=sim.devices.get(1); if strcmp(mode,'ReceiptAck'), device=prior; end
            if dataMode
                packet=sim.packets.get(device.packetId); bits=packet.blocks{device.fragmentIndex+1};
            else, bits=int8(1); end
            [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,bits,[]); tx.ueId=1;
            tx.timingAdvanceSeconds=device.timingAdvanceSeconds;
        else
            % BS public schedule directly proves this control was emitted.
            tx=nbiot.phy.npdcch.buildTransmission(cfg,g,s.dci);
        end
        tx.waveform=-tx.waveform; sim.channel.add(tx);
        if isempty(grants), grants=g; else, grants(end+1)=g; end
        seen(end+1)=g.grantId; removed=removed+1; %#ok<AGROW>
    end
end
r=sim.result();
end
