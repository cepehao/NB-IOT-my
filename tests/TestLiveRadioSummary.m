classdef TestLiveRadioSummary < matlab.unittest.TestCase
    methods (Test)
        function aggregatesIndependentOccasionsLikeBatchAndTracksLatestUeSinr(t)
            [truth,observed,reception]=twoOccasionFixture();
            accumulator=nbiot.metrics.RadioDiagnosticsAccumulator(0:3);

            live=accumulator.update(truth,observed,reception,35);

            expected=nbiot.metrics.radioDiagnostics(truth,observed,reception, ...
                struct('actualTick',35,'nInitValues',0:3));
            t.assertTrue(isscalar(live),'live must be a scalar structure.');
            t.assertEqual(live.asOfTick,35,'live.asOfTick');
            t.assertTrue(isfield(live,'status'),'live.status must be present.');
            t.assertTrue(isfield(live.summary,'lastEventTick'), ...
                'live.summary.lastEventTick must be present.');
            t.assertEqual(live.summary.lastEventTick,30,'live.summary.lastEventTick');
            t.assertEqual(rmfield(live.summary,'lastEventTick'),expected, ...
                'live.summary must match batch radioDiagnostics.');
            t.assertEqual(live.summary.preamble.transmittedKeys,3, ...
                'live.summary.preamble.transmittedKeys');
            t.assertEqual(live.summary.preamble.falseAlarmOpportunities,5, ...
                'live.summary.preamble.falseAlarmOpportunities');
            t.assertEqual(live.summary.collision.logicalGroups,0, ...
                'live.summary.collision.logicalGroups');
            t.assertEqual(live.summary.collision.physicalOverlapPairs,1, ...
                'live.summary.collision.physicalOverlapPairs');
            t.assertEqual(live.summary.collision.physicalAttempts,2, ...
                'live.summary.collision.physicalAttempts');
            t.assertEqual(live.summary.capture.censoredPairs,1, ...
                'live.summary.capture.censoredPairs');

            ue=live.perUe([live.perUe.ueId]==1);
            t.assertTrue(ue.sinrAvailable,'live.perUe(ueId=1).sinrAvailable');
            t.assertEqual(ue.sinrDb,10*log10(2), ...
                'live.perUe(ueId=1).sinrDb','AbsTol',1e-12);
            t.assertEqual(ue.sinrTick,26,'live.perUe(ueId=1).sinrTick');
            t.assertEqual(ue.lastEventTick,26,'live.perUe(ueId=1).lastEventTick');
            t.assertTrue(~isempty(ue.perAttempt), ...
                'live.perUe(ueId=1).perAttempt must not be empty.');
        end

        function lateSuccessResolvesCaptureOnlyForItsOriginalOccasion(t)
            [truth,observed,reception,lateSuccess]=twoOccasionFixture();
            [accumulator,callCount]=countingAccumulator(0:3);

            before=accumulator.update(truth,observed,reception,35);
            t.assertEqual(before.summary.capture.eligiblePairs,0, ...
                'before.summary.capture.eligiblePairs');
            t.assertEqual(before.summary.capture.censoredPairs,1, ...
                'before.summary.capture.censoredPairs');
            t.assertEqual(callCount(),2,'diagnostic callback count before late outcome');

            unchanged=accumulator.update(emptyEvents(),emptyEvents(),emptyEvents(),36);
            t.assertEqual(callCount(),2,'diagnostic callback count after empty update');
            t.assertEqual(unchanged.summary.capture.censoredPairs,1, ...
                'unchanged.summary.capture.censoredPairs');

            after=accumulator.update(lateSuccess,emptyEvents(),emptyEvents(),40);
            t.assertEqual(callCount(),3,'diagnostic callback count after late outcome');
            t.assertEqual(after.summary.capture.eligiblePairs,1, ...
                'after.summary.capture.eligiblePairs');
            t.assertEqual(after.summary.capture.censoredPairs,0, ...
                'after.summary.capture.censoredPairs');
            t.assertEqual(after.summary.capture.capturedPairs,1, ...
                'after.summary.capture.capturedPairs');
            t.assertEqual(after.summary.capture.probability,1, ...
                'after.summary.capture.probability');
            t.assertEqual(after.summary.lastEventTick,40,'after.summary.lastEventTick');

            completeTruth=[truth lateSuccess];
            expected=nbiot.metrics.radioDiagnostics(completeTruth,observed,reception, ...
                struct('actualTick',40,'nInitValues',0:3));
            t.assertEqual(rmfield(after.summary,'lastEventTick'),expected, ...
                'after.summary must match batch radioDiagnostics after late outcome.');
            ue=after.perUe([after.perUe.ueId]==1);
            t.assertEqual(ue.sinrDb,10*log10(2), ...
                'after.perUe(ueId=1).sinrDb','AbsTol',1e-12);
            t.assertEqual(ue.sinrTick,26,'after.perUe(ueId=1).sinrTick');
            t.assertEqual(ue.lastEventTick,40,'after.perUe(ueId=1).lastEventTick');

            rebuilt=nbiot.metrics.RadioDiagnosticsAccumulator(0:3);
            fromJournal=rebuilt.update(completeTruth,observed,reception,40);
            t.assertEqual(fromJournal,after, ...
                'rebuilt live summary must equal the incrementally updated summary.');
        end

        function emptyCompleteOccasionAddsFalseAlarmOpportunities(t)
            accumulator=nbiot.metrics.RadioDiagnosticsAccumulator(0:3);

            live=accumulator.update(emptyEvents(),radioDetection(5,70,[]), ...
                emptyEvents(),12);

            t.verifyTrue(live.summary.available);
            t.verifyEqual(live.summary.preamble.falseAlarmOpportunities,4);
            t.verifyEqual(live.summary.preamble.falseAlarms,0);
            t.verifyEqual(live.summary.preamble.falseAlarmProbability,0);
            t.verifyTrue(isnan(live.summary.preamble.missProbability));
        end

        function equalPowerPairIsSeparateFromCensoredCapturePairs(t)
            truth=[msg1(1,1,1,30,0),msg1(2,2,2,30,1)];
            observed=radioDetection(12,30,[0 1]);
            reception=[component(15,30,1,1,0,0,10,3), ...
                component(15,30,2,2,1,0,10,3), ...
                overlap(15,30,1,2,0,10,3,3)];
            accumulator=nbiot.metrics.RadioDiagnosticsAccumulator(0:3);

            live=accumulator.update(truth,observed,reception,35);

            t.verifyEqual(live.summary.capture.equalPowerPairs,1);
            t.verifyEqual(live.summary.capture.censoredPairs,0);
            t.verifyEqual(live.summary.capture.eligiblePairs,0);
            t.verifyTrue(isnan(live.summary.capture.probability));
        end

        function runningAndPausedSnapshotsStayLiveAndDoNotExportBatchResults(t)
            cfg=shortCalibratedConfig();
            [frequentFactory,getFrequentSimulator]=countingSimulatorFactory();
            [rareFactory,getRareSimulator]=countingSimulatorFactory();
            frequent=nbiot.ui.SimulationSession([],frequentFactory);
            rare=nbiot.ui.SimulationSession([],rareFactory);
            t.addTeardown(@() frequent.close());
            t.addTeardown(@() rare.close());

            frequent.start(cfg);
            rare.start(cfg);
            frequent.advance(2);
            rare.advance(2);
            frequentSimulator=getFrequentSimulator();
            rareSimulator=getRareSimulator();

            frequentState=frequent.snapshot();
            rareState=rare.snapshot();
            verifyLiveSnapshot(t,frequentState);
            verifyLiveSnapshot(t,rareState);
            t.verifyEqual(frequentSimulator.ResultCallCount,0);
            t.verifyEqual(rareSimulator.ResultCallCount,0);

            frequent.pause();
            pausedState=frequent.snapshot();
            t.verifyEqual(pausedState.status,'paused');
            verifyLiveSnapshot(t,pausedState);
            t.verifyEqual(frequentSimulator.ResultCallCount,0);
            frequent.resume();

            for k=1:cfg.simulation.durationTicks+2
                if any(strcmp(frequent.Status,{'completed','stopped','failed'})), break; end
                frequent.advance(1);
                state=frequent.snapshot();
                if ~any(strcmp(frequent.Status,{'completed','stopped','failed'}))
                    verifyLiveSnapshot(t,state);
                    t.verifyEqual(frequentSimulator.ResultCallCount,0);
                end
            end
            t.verifyEqual(frequent.Status,'completed');

            rare.advance(4);
            rareState=rare.snapshot();
            verifyLiveSnapshot(t,rareState);
            t.verifyEqual(rare.Status,'running');
            t.verifyEqual(rareSimulator.ResultCallCount,0);
            rare.advance(cfg.simulation.durationTicks);
            t.verifyEqual(rare.Status,'completed');

            frequentResult=frequent.getResult();
            rareResult=rare.getResult();
            terminalLive=rareSimulator.liveRadioDiagnostics();
            terminalLive.summary.collision.logicalGroups=999;
            rareSimulator.setLiveDiagnosticsOverride(terminalLive);
            terminalState=rare.snapshot();
            t.verifyEqual(terminalState.liveRadioDiagnostics.summary.collision, ...
                rareResult.radioDiagnostics.collision);
            t.verifyNotEqual(terminalState.liveRadioDiagnostics.summary.collision.logicalGroups,999);

            frequentResult.profiling=[];
            rareResult.profiling=[];
            t.verifyEqual(frequentResult,rareResult);
        end
    end
end

function verifyLiveSnapshot(t,state)
t.verifyTrue(isfield(state,'liveRadioDiagnostics'));
if ~isfield(state,'liveRadioDiagnostics'), return; end
live=state.liveRadioDiagnostics;
t.verifyTrue(isstruct(live)&&isscalar(live));
t.verifyTrue(all(isfield(live,{'asOfTick','status','summary','perUe'})));
if isstruct(live)&&isscalar(live)&&isfield(live,'summary')
    t.verifyTrue(isfield(live.summary,'available'));
end
end

function cfg=shortCalibratedConfig()
projectRoot=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=10;
cfg.traffic.kind='none';
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(projectRoot,'results','nprach-calibration.mat'));
end

function [factory,getSimulator]=countingSimulatorFactory()
simulator=[];
factory=@createSimulator;
getSimulator=@currentSimulator;

    function value=createSimulator(cfg,scenario,budget)
        simulator=LiveRadioCountingSimulator(cfg,scenario,budget);
        value=simulator;
    end

    function value=currentSimulator()
        value=simulator;
    end
end

function [truth,observed,reception,lateSuccess]=twoOccasionFixture()
truth=[msg1(1,1,1,10,0),msg1(2,2,2,10,1), ...
    msg1(16,3,1,20,0),event(30,'ra_failure',struct('attemptId',2,'reason','timeout'))];
observed=[radioDetection(12,10,[0 1]),radioDetection(24,20,0)];
reception=[component(15,10,1,1,0,0,10,4), ...
    component(15,10,2,2,1,0,10,1), ...
    overlap(15,10,1,2,0,10,4,1), ...
    component(26,20,3,1,0,20,30,2)];
lateSuccess=event(40,'ra_success',struct('attemptId',1));
end

function [accumulator,callCount]=countingAccumulator(nInitValues)
calls=0;
accumulator=nbiot.metrics.RadioDiagnosticsAccumulator(nInitValues,@countedDiagnostics);
callCount=@readCallCount;

    function diagnostics=countedDiagnostics(truth,observed,reception,options)
        calls=calls+1;
        diagnostics=nbiot.metrics.radioDiagnostics(truth,observed,reception,options);
    end

    function value=readCallCount()
        value=calls;
    end
end

function events=emptyEvents()
events=struct('tick',{},'kind',{},'fields',{});
end

function e=event(tick,kind,fields)
e=struct('tick',double(tick),'kind',char(kind),'fields',fields);
end

function e=msg1(tick,attemptId,ueId,occasionId,nInit)
e=event(tick,'msg1',struct('attemptId',attemptId,'ueId',ueId, ...
    'packetId',attemptId,'occasionId',occasionId,'nInit',nInit));
end

function e=radioDetection(tick,occasionId,nInitValues)
candidates=repmat(struct('nInit',0,'delaySeconds',0,'cfoHz',0),numel(nInitValues),1);
for k=1:numel(nInitValues)
    candidates(k).nInit=nInitValues(k);
end
e=event(tick,'nprach_detection',struct('occasionId',occasionId, ...
    'readyTick',tick,'candidates',candidates));
end

function e=component(tick,occasionId,attemptId,ueId,nInit,startSample,endSample,powerW)
e=event(tick,'nprach_component',struct('occasionId',occasionId, ...
    'attemptId',attemptId,'ueId',ueId,'nInit',nInit, ...
    'startSample',startSample,'endSampleExclusive',endSample, ...
    'signalPowerW',powerW,'interferencePowerW',0,'noisePowerW',1, ...
    'configuredDelaySeconds',0,'configuredCfoHz',0));
end

function e=overlap(tick,occasionId,attemptIdA,attemptIdB,startSample,endSample,powerAW,powerBW)
e=event(tick,'nprach_overlap',struct('occasionId',occasionId, ...
    'attemptIdA',attemptIdA,'attemptIdB',attemptIdB, ...
    'startSample',startSample,'endSampleExclusive',endSample, ...
    'signalPowerAW',powerAW,'signalPowerBW',powerBW));
end
