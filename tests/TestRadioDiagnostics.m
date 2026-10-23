classdef TestRadioDiagnostics < matlab.unittest.TestCase
    methods (Test)
        function reversedDuplicateOverlapIsRejected(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3)];
            observed=radioEvent(20,1,[candidate(2,0,0),candidate(3,0,0)]);
            reception=[component(1,1,2,0,10,2),component(2,2,3,0,10,1), ...
                overlap(1,2,0,10,2,1),overlap(2,1,0,10,1,2)];
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed, ...
                reception,options(100)), 'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function repeatedOverlapIsRejected(t)
            [truth,observed,reception]=overlapCase();
            reception(end+1)=reception(end);
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function missingRequiredOverlapIsRejected(t)
            [truth,observed,reception]=overlapCase();
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception(1:2),options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function touchingIntervalsCannotHaveAnOverlap(t)
            [truth,observed,reception]=overlapCase();
            reception(2)=component(2,2,3,10,20,1);
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function incorrectIntersectionBoundsAreRejected(t)
            [truth,observed,reception]=overlapCase();
            reception(end).fields.startSample=1;
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function missingReferencedComponentIsRejected(t)
            [truth,observed,reception]=overlapCase();
            reception(end).fields.attemptIdB=99;
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function componentFromAnotherOccasionIsRejected(t)
            [truth,observed,reception]=overlapCase();
            truth(2).fields.occasionId=2;
            observed(2)=radioEvent(20,2,candidate(3,0,0));
            reception(2).fields.occasionId=2;
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function duplicateAttemptIdIsRejected(t)
            [truth,observed,reception]=overlapCase();
            truth(2).fields.attemptId=1;
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function duplicateComponentAttemptIdIsRejected(t)
            [truth,observed,reception]=overlapCase();
            reception(2).fields.attemptId=1;
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function malformedPairIdsAreRejectedBeforeGrouping(t)
            [truth,observed,reception]=overlapCase();
            for id=[NaN Inf 1.5 0 1]
                reception(end).fields.attemptIdB=id;
                t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                    'nbiot:metrics:RadioDiagnosticsEvent');
            end
        end

        function equalPowerWithKnownOutcomesHasNoCaptureDenominator(t)
            [truth,observed,reception]=overlapCase();
            truth=[truth,event(30,'ra_success',struct('attemptId',1)), ...
                event(30,'ra_failure',struct('attemptId',2))];
            reception(end).fields.signalPowerAW=1;
            d=nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100));
            t.verifyEqual(d.capture.eligiblePairs,0);
            t.verifyEqual(d.capture.equalPowerPairs,1);
            t.verifyTrue(isnan(d.capture.probability));
        end

        function conflictingOutcomesAreRejected(t)
            [truth,observed,reception]=overlapCase();
            truth=[truth,event(30,'ra_success',struct('attemptId',1)), ...
                event(30,'ra_failure',struct('attemptId',1))];
            t.verifyError(@()nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100)), ...
                'nbiot:metrics:RadioDiagnosticsEvent');
        end

        function mixedOccasionsPreserveWholeDiagnosticStruct(t)
            % Fixed input order: component IDs and occasions are deliberately unsorted.
            truth=[msg1(10,9000000001,1,2,3),msg1(10,7,2,1,2)];
            observed=[radioEvent(20,2,candidate(3,0,0)),radioEvent(20,1,candidate(2,0,0))];
            reception=[component(9000000001,1,3,0,10,2),component(7,2,2,0,10,1)];
            reception(1).fields.occasionId=2;
            d=nbiot.metrics.radioDiagnostics(truth,observed,reception,options(100));
            expected=struct('available',true,'actualTick',100, ...
                'preamble',struct('transmittedAttempts',2,'transmittedKeys',2, ...
                'detectedCandidates',2,'detectedKeys',2,'misses',0,'falseAlarms',0, ...
                'falseAlarmOpportunities',22,'detectionProbability',1,'missProbability',0,'falseAlarmProbability',0), ...
                'collision',struct('attempts',2,'logicalGroups',0,'logicalAttempts',0, ...
                'logicalAttemptProbability',0,'physicalOverlapPairs',0,'physicalAttempts',0,'physicalAttemptProbability',0), ...
                'capture',struct('eligiblePairs',0,'censoredPairs',0,'equalPowerPairs',0, ...
                'capturedPairs',0,'probability',NaN,'strongSuccessProbability',NaN,'weakSuccessProbability',NaN));
            expected.perAttempt=[expectedAttempt(2,9000000001,1,3,2),expectedAttempt(1,7,2,2,1)];
            expected.receiverEstimates=[expectedEstimate(2,3,9000000001,1),expectedEstimate(1,2,7,2)];
            expected.npuschReceiverEstimates=repmat(struct('contextId',0,'occasionId',0,'nInit',0, ...
                'attemptId',NaN,'ueId',NaN,'channel','','estimatedDelaySeconds',NaN, ...
                'configuredDelaySeconds',NaN,'delayErrorSeconds',NaN,'estimatedCfoHz',NaN, ...
                'configuredCfoHz',NaN,'cfoErrorHz',NaN,'noiseEstimate',NaN,'truthAvailable',false),0,1);
            t.verifyTrue(isequaln(d,expected));
        end
        function emptyCompletedOccasionKeepsZeroCountsAndUndefinedMissRate(t)
            truth=emptyEvents();
            observed=radioEvent(20,1,emptyCandidates());

            d=nbiot.metrics.radioDiagnostics(truth,observed,emptyEvents(),options(20));

            t.verifyEqual(d.preamble.transmittedKeys,0);
            t.verifyEqual(d.preamble.detectedKeys,0);
            t.verifyEqual(d.preamble.misses,0);
            t.verifyEqual(d.preamble.falseAlarms,0);
            t.verifyEqual(d.preamble.falseAlarmOpportunities,12);
            t.verifyTrue(isnan(d.preamble.missProbability));
            t.verifyEqual(d.preamble.falseAlarmProbability,0);
        end

        function matchesByOccasionAndPreambleAndCountsMissAndFalseAlarm(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3)];
            candidates=[candidate(2,1e-6,15),candidate(4,2e-6,15)];
            observed=radioEvent(15,1,candidates);

            d=nbiot.metrics.radioDiagnostics(truth,observed,emptyEvents(),options(100));

            t.verifyEqual(d.preamble.transmittedKeys,2);
            t.verifyEqual(d.preamble.detectedKeys,1);
            t.verifyEqual(d.preamble.misses,1);
            t.verifyEqual(d.preamble.falseAlarms,1);
            t.verifyEqual(d.preamble.falseAlarmOpportunities,10);
            t.verifyEqual(d.preamble.missProbability,.5);
            t.verifyEqual(d.preamble.detectionProbability,.5);
            t.verifyEqual(d.preamble.falseAlarmProbability,.1);
        end

        function samePreambleWithoutReceivedOverlapIsNotPhysicalCollision(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,2)];
            observed=radioEvent(20,1,candidate(2,1e-6,20));
            receptions=[component(1,1,2,0,10,2),component(2,2,2,10,20,1)];

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.collision.logicalGroups,1);
            t.verifyEqual(d.collision.logicalAttempts,2);
            t.verifyEqual(d.collision.physicalOverlapPairs,0);
            t.verifyEqual(d.collision.physicalAttempts,0);
            t.verifyEqual(d.collision.physicalAttemptProbability,0);
            t.verifyTrue(isnan(d.capture.probability));
        end

        function differentPreamblesWithReceivedOverlapArePhysicalCollision(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3)];
            observed=radioEvent(20,1,[candidate(2,1e-6,20),candidate(3,2e-6,20)]);
            receptions=[component(1,1,2,0,10,2),component(2,2,3,9,20,1), ...
                overlap(1,2,9,10,2,1)];

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.collision.logicalGroups,0);
            t.verifyEqual(d.collision.physicalOverlapPairs,1);
            t.verifyEqual(d.collision.physicalAttempts,2);
            t.verifyEqual(d.collision.physicalAttemptProbability,1);
        end

        function captureRequiresResolvedStrongSuccessAndWeakFailure(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3), ...
                event(30,'ra_success',struct('attemptId',1)), ...
                event(30,'ra_failure',struct('attemptId',2,'reason','timeout'))];
            observed=radioEvent(20,1,[candidate(2,1e-6,20),candidate(3,2e-6,20)]);
            receptions=[component(1,1,2,0,10,10),component(2,2,3,0,10,1), ...
                overlap(1,2,0,10,10,1)];

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.capture.eligiblePairs,1);
            t.verifyEqual(d.capture.capturedPairs,1);
            t.verifyEqual(d.capture.probability,1);
            t.verifyEqual(d.capture.strongSuccessProbability,1);
            t.verifyEqual(d.capture.weakSuccessProbability,0);
        end

        function captureUsesPowerMeasuredOnTheSharedInterval(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3), ...
                event(30,'ra_success',struct('attemptId',1)), ...
                event(30,'ra_failure',struct('attemptId',2,'reason','timeout'))];
            observed=radioEvent(20,1,[candidate(2,1e-6,20),candidate(3,2e-6,20)]);
            receptions=[component(1,1,2,0,10,10),component(2,2,3,0,10,1), ...
                overlap(1,2,0,10,1,10)];

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.capture.eligiblePairs,1);
            t.verifyEqual(d.capture.capturedPairs,0);
            t.verifyEqual(d.capture.probability,0);
        end

        function unresolvedOverlapIsCensoredRatherThanCountedAsFailure(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3), ...
                event(30,'ra_success',struct('attemptId',1))];
            observed=radioEvent(20,1,[candidate(2,1e-6,20),candidate(3,2e-6,20)]);
            receptions=[component(1,1,2,0,10,10),component(2,2,3,0,10,1), ...
                overlap(1,2,0,10,10,1)];

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.capture.eligiblePairs,0);
            t.verifyEqual(d.capture.censoredPairs,1);
            t.verifyEqual(d.capture.capturedPairs,0);
            t.verifyTrue(isnan(d.capture.probability));
        end

        function reportsSinrAndReceiverEstimatesSeparatelyFromConfiguredTruth(t)
            truth=msg1(10,1,1,1,2);
            observed=radioEvent(20,1,candidate(2,2e-6,42));
            receptions=component(1,1,2,0,10,2);
            receptions.fields.interferencePowerW=.5;
            receptions.fields.noisePowerW=.5;
            receptions.fields.configuredDelaySeconds=1e-6;
            receptions.fields.configuredCfoHz=50;

            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options(100));

            t.verifyEqual(d.perAttempt.sinrDb,10*log10(2),'AbsTol',1e-12);
            t.verifyEqual(d.perAttempt.provenance,'diagnosticTruth');
            t.verifyEqual(d.receiverEstimates.estimatedDelaySeconds,2e-6);
            t.verifyEqual(d.receiverEstimates.configuredDelaySeconds,1e-6);
            t.verifyEqual(d.receiverEstimates.delayErrorSeconds,1e-6,'AbsTol',1e-15);
            t.verifyEqual(d.receiverEstimates.estimatedCfoHz,42);
            t.verifyEqual(d.receiverEstimates.configuredCfoHz,50);
            t.verifyEqual(d.receiverEstimates.cfoErrorHz,-8);
        end

        function recordsNpuschReceiverEstimatesWithSeparateTruth(t)
            received=event(30,'npusch_receiver',struct('contextId',1, ...
                'occasionId',1,'nInit',2,'channel','Msg3', ...
                'estimatedDelaySeconds',4e-6,'estimatedCfoHz',24, ...
                'configuredDelaySeconds',3e-6,'configuredCfoHz',20, ...
                'noiseEstimate',.25));

            d=nbiot.metrics.radioDiagnostics(emptyEvents(),emptyEvents(), ...
                received,options(100));

            t.verifyEqual(d.npuschReceiverEstimates.channel,'Msg3');
            t.verifyEqual(d.npuschReceiverEstimates.estimatedDelaySeconds,4e-6);
            t.verifyEqual(d.npuschReceiverEstimates.configuredDelaySeconds,3e-6);
            t.verifyEqual(d.npuschReceiverEstimates.delayErrorSeconds,1e-6,'AbsTol',1e-15);
            t.verifyEqual(d.npuschReceiverEstimates.estimatedCfoHz,24);
            t.verifyEqual(d.npuschReceiverEstimates.configuredCfoHz,20);
            t.verifyEqual(d.npuschReceiverEstimates.cfoErrorHz,4);
        end

        function includesDecisionReadyAtHorizonAndExcludesLaterDecision(t)
            truth=[msg1(10,1,1,1,2),msg1(10,2,2,2,3)];
            observed=[radioEvent(20,1,candidate(2,1e-6,20)), ...
                radioEvent(21,2,candidate(3,2e-6,21))];

            d=nbiot.metrics.radioDiagnostics(truth,observed,emptyEvents(),options(20));

            t.verifyEqual(d.preamble.transmittedKeys,1);
            t.verifyEqual(d.preamble.detectedKeys,1);
            t.verifyEqual(d.preamble.misses,0);
            t.verifyEqual(d.preamble.falseAlarmOpportunities,11);
        end

        function shortPhysicalRunAddsDiagnosticsWithoutChangingExistingKpis(t)
            cfg=shortRadioConfig();
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());
            simulator.run();
            result=simulator.result();

            t.verifyEqual(result.status,'completed');
            t.verifyEqual(result.kpiSummary.raStarted,1);
            t.verifyEqual(result.kpiSummary.raSuccess,1);
            t.verifyEqual(result.kpiSummary.created,1);
            t.verifyEqual(result.kpiSummary.detectedCandidates,1);
            t.verifyEqual(numel(result.truthLog),24);
            t.verifyEqual(numel(result.observedLog),524);
            fprintf('RADIO_DIAGNOSTIC_BASELINE raStarted=%d raSuccess=%d created=%d detected=%d truthEvents=%d observedEvents=%d\n', ...
                result.kpiSummary.raStarted,result.kpiSummary.raSuccess, ...
                result.kpiSummary.created,result.kpiSummary.detectedCandidates, ...
                numel(result.truthLog),numel(result.observedLog));
            t.verifyTrue(isfield(result,'radioDiagnostics'));
            if ~isfield(result,'radioDiagnostics'), return; end
            t.verifyGreaterThanOrEqual(result.radioDiagnostics.preamble.transmittedAttempts,1);
            t.verifyNotEmpty(result.radioDiagnostics.perAttempt);
            t.verifyTrue(all(strcmp({result.radioDiagnostics.perAttempt.provenance},'diagnosticTruth')));
            t.verifyNotEmpty(result.radioDiagnostics.npuschReceiverEstimates);
            t.verifyTrue(isfield(result,'radioReceptionLog'));
            t.verifyFalse(any(arrayfun(@(e)isfield(e.fields,'waveform'), ...
                result.radioReceptionLog)));
            t.verifyTrue(any(strcmp({result.lifecycleLog.kind},'simulation_completed')));
        end

        function lifecycleJournalRecordsRequestedStopAndRuntimeFailure(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=10; cfg.traffic.kind='none';
            stopped=nbiot.NBIoTSimulator(cfg,[],localDevelopment());
            stopped.stop('user-stop'); stoppedResult=stopped.result();
            t.verifyEqual(stoppedResult.status,'stopped');
            t.verifyTrue(any(strcmp({stoppedResult.lifecycleLog.kind},'stop_requested')));

            failed=nbiot.NBIoTSimulator(cfg,[],localDevelopment());
            failed.run(); failedResult=failed.result();
            t.verifyEqual(failedResult.status,'failed');
            t.verifyTrue(any(strcmp({failedResult.lifecycleLog.kind},'simulation_failed')));
            t.verifyEqual(failedResult.lifecycleLog(end).fields.errorIdentifier, ...
                'nbiot:phy:Calibration');
        end

        function lifecycleJournalRecordsSuccessfulModelLoad(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.policy.name='Adaptive-P';
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment(),developmentController(4));

            result=simulator.result();

            at=find(strcmp({result.lifecycleLog.kind},'model_loaded'),1);
            t.verifyNotEmpty(at);
            if isempty(at), return; end
            t.verifyEqual(result.lifecycleLog(at).fields.method,'Adaptive-P');
            t.verifyEqual(result.lifecycleLog(at).fields.modelMetadata.status,'development');
        end

        function lifecycleStartAndCompletionAreNotRepeatedForRunSlices(t)
            cfg=shortRadioConfig();
            cfg.simulation.durationTicks=25;
            cfg.traffic.kind='none';
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());

            simulator.run(5);
            simulator.run(10);
            simulator.run();
            result=simulator.result();
            kinds={result.lifecycleLog.kind};

            t.verifyEqual(sum(strcmp(kinds,'simulation_started')),1);
            t.verifyEqual(sum(strcmp(kinds,'simulation_completed')),1);
            t.verifyFalse(any(strcmp(kinds,'simulation_partial')));
            t.verifyEqual(numel(result.lifecycleLog),3);
        end
    end
end

function [truth,observed,reception]=overlapCase()
truth=[msg1(10,1,1,1,2),msg1(10,2,2,1,3)];
observed=radioEvent(20,1,[candidate(2,0,0),candidate(3,0,0)]);
reception=[component(1,1,2,0,10,2),component(2,2,3,0,10,1),overlap(1,2,0,10,2,1)];
end

function c=expectedAttempt(occasionId,attemptId,ueId,nInit,power)
c=struct('occasionId',occasionId,'attemptId',attemptId,'ueId',ueId,'nInit',nInit, ...
    'receivedPowerW',power,'interferencePowerW',0,'noisePowerW',1,'sinrDb',10*log10(power),'provenance','diagnosticTruth');
end

function c=expectedEstimate(occasionId,nInit,attemptId,ueId)
c=struct('occasionId',occasionId,'nInit',nInit,'attemptId',attemptId,'ueId',ueId, ...
    'estimatedDelaySeconds',0,'configuredDelaySeconds',0,'delayErrorSeconds',0, ...
    'estimatedCfoHz',0,'configuredCfoHz',0,'cfoErrorHz',0,'truthAvailable',true);
end

function e=overlap(attemptIdA,attemptIdB,startSample,endSample,powerAW,powerBW)
e=event(20,'nprach_overlap',struct('occasionId',1, ...
    'attemptIdA',attemptIdA,'attemptIdB',attemptIdB, ...
    'startSample',startSample,'endSampleExclusive',endSample, ...
    'signalPowerAW',powerAW,'signalPowerBW',powerBW));
end

function cfg=options(actualTick)
cfg=struct('actualTick',actualTick,'nInitValues',0:11);
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

function e=radioEvent(tick,occasionId,candidates)
if isempty(candidates), count=0; else, count=numel(candidates); end
for k=1:numel(candidates), candidates(k).readyTick=tick; end
e=event(tick,'nprach_detection',struct('occasionId',occasionId, ...
    'candidates',candidates,'count',count,'readyTick',tick, ...
    'maxMetric',NaN,'meanMetric',NaN,'energyW',0));
end

function c=candidate(nInit,delaySeconds,cfoHz)
c=struct('nInit',nInit,'metric',1,'matchScore',1, ...
    'delaySeconds',delaySeconds,'cfoHz',cfoHz,'threshold',.5,'readyTick',20);
end

function c=emptyCandidates()
c=repmat(candidate(0,NaN,NaN),0,1);
end

function e=component(attemptId,ueId,nInit,startSample,endSampleExclusive,powerW)
e=event(endSampleExclusive/1920,'nprach_component',struct( ...
    'occasionId',1,'attemptId',attemptId,'ueId',ueId,'nInit',nInit, ...
    'startSample',startSample,'endSampleExclusive',endSampleExclusive, ...
    'signalPowerW',powerW,'interferencePowerW',0,'noisePowerW',1, ...
    'configuredDelaySeconds',0,'configuredCfoHz',0));
end

function cfg=shortRadioConfig()
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=500;
cfg.cell.radiusM=21;
cfg.cell.minDistanceM=20;
cfg.cell.indoorFraction=0;
cfg.channel.shadowOutdoorDb=0;
cfg.channel.shadowIndoorDb=0;
cfg.channel.cfoSigmaHz=0;
cfg.channel.syncLimitSeconds=0;
cfg.traffic.kind='burst';
cfg.traffic.burstStartTick=0;
cfg.traffic.burstDurationTicks=1;
cfg.policy.name='Static';
root=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(root,'results','nprach-calibration.mat'));
end

function options=developmentController(prediction)
schema=nbiot.dataset.featureSchema();
featureNames=schema.observationNames(5:end);
keyNames=schema.observationNames(1:4);
featureCount=numel(featureNames);
bundle=struct('formatVersion','load-model-bundle-v1', ...
    'modelName','linearRegression','model',FixedRegressionPredictor(prediction), ...
    'schemaVersion',schema.version,'featureNames',{featureNames}, ...
    'keyNames',{keyNames},'targetName','meanRaUe', ...
    'transform',struct('median',zeros(1,featureCount),'mean',zeros(1,featureCount), ...
        'scale',ones(1,featureCount)), ...
    'trainingIds',1,'validationIds',2,'testIds',3,'seed',1, ...
    'status','development','dataKind','development-fixture');
options=struct('model',bundle,'allowDevelopmentModel',true);
end
