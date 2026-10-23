classdef TestDatasetDiagnostics < matlab.unittest.TestCase
    methods (Test)
        function windowMetricsRespectExactBoundaryDefinitions(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);

            t.verifyEqual(rows.windowId,[1;2]);
            t.verifyEqual(rows.logicalCollisionGroups,[1;0]);
            t.verifyEqual(rows.logicalCollidingAttempts,[2;0]);
            t.verifyEqual(rows.physicalOverlapPairs,[1;0]);
            t.verifyEqual(rows.physicalCollidingAttempts,[2;0]);
            t.verifyEqual(rows.raRetryTransmissions,[1;1]);
            t.verifyEqual(rows.successfulAccesses,[1;0]);
            t.verifyEqual(rows.meanDelayTicks(1),490);
            t.verifyTrue(isnan(rows.meanDelayTicks(2)));
            t.verifyEqual(rows.delaySampleCount,[1;0]);
            t.verifyEqual(rows.delayAvailable,[true;false]);
            t.verifyEqual(rows.outcomeHorizonTick,[1000;1000]);
        end

        function diagnosticsUseOnlyPausedWindowKeys(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            keys=keys(1,:);

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,750,keys);

            t.verifyEqual(height(rows),1);
            t.verifyEqual(rows.endTick,500);
            t.verifyEqual(rows.outcomeHorizonTick,750);
        end

        function noClosedWindowKeysProduceTypedEmptyDiagnostics(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            keys=keys([],:);

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,250,keys);

            t.verifyEqual(height(rows),0);
            t.verifyTrue(ismember('realizationId',rows.Properties.VariableNames));
            t.verifyTrue(ismember('logicalAvailable',rows.Properties.VariableNames));
        end

        function emptyKeyResultHasExactColumnsAndTypes(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,250,keys([],:));
            expectedNames={'realizationId','windowId','startTick','endTick', ...
                'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
                'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
                'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
                'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
                'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'};
            expectedLogical={'logicalAvailable','physicalAvailable','accessAvailable', ...
                'retryAvailable','delayAvailable'};

            t.verifyEqual(rows.Properties.VariableNames,expectedNames);
            for k=1:numel(expectedNames)
                expectedClass='double';
                if any(strcmp(expectedNames{k},expectedLogical)), expectedClass='logical'; end
                t.verifyEqual(class(rows.(expectedNames{k})),expectedClass, ...
                    sprintf('Unexpected type for empty diagnostics column %s.',expectedNames{k}));
            end
        end

        function missingTruthAttemptsOrPacketsMakeTheirMetricsUnavailable(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();

            noTruth=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,[], ...
                observed,reception,1000,keys);
            t.verifyFalse(any(noTruth.logicalAvailable));
            t.verifyTrue(all(isnan(noTruth.logicalCollisionGroups)));
            t.verifyTrue(all(isnan(noTruth.logicalCollidingAttempts)));

            noAttempts=nbiot.dataset.windowDiagnostics(cfg,packets,[],truth, ...
                observed,reception,1000,keys);
            t.verifyFalse(any(noAttempts.accessAvailable));
            t.verifyTrue(all(isnan(noAttempts.successfulAccesses)));
            t.verifyTrue(all(isnan(noAttempts.unfinishedAccessCohort)));
            t.verifyFalse(any(noAttempts.retryAvailable));
            t.verifyTrue(all(isnan(noAttempts.raRetryTransmissions)));

            noPackets=nbiot.dataset.windowDiagnostics(cfg,[],attempts,truth, ...
                observed,reception,1000,keys);
            t.verifyFalse(any(noPackets.delayAvailable));
            t.verifyTrue(all(isnan(noPackets.delaySampleCount)));
            t.verifyTrue(all(isnan(noPackets.meanDelayTicks)));
            t.verifyTrue(all(isnan(noPackets.unfinishedPacketCohort)));

            emptyJournal=nbiot.dataset.windowDiagnostics(cfg,packets([]),attempts([]), ...
                emptyEvents(),observed,reception,1000,keys);
            t.verifyTrue(all(emptyJournal.accessAvailable));
            t.verifyEqual(emptyJournal.successfulAccesses,[0;0]);
            t.verifyEqual(emptyJournal.raRetryTransmissions,[0;0]);
            t.verifyTrue(all(emptyJournal.logicalAvailable));
            t.verifyEqual(emptyJournal.logicalCollisionGroups,[0;0]);
        end

        function typedEmptyPacketSourceIsAvailableButHasNoDelaySamples(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            packets=packets([]);

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);

            t.verifyFalse(any(rows.delayAvailable));
            t.verifyEqual(rows.delaySampleCount,[0;0]);
            t.verifyTrue(all(isnan(rows.meanDelayTicks)));
            t.verifyEqual(rows.unfinishedPacketCohort,[0;0]);
        end

        function availableReceiverWithoutOverlapPairsReportsZero(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            reception=reception([1 2 4]);
            reception(1).fields.endSampleExclusive=50;
            reception(2).fields.startSample=50;

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);

            t.verifyTrue(all(rows.physicalAvailable));
            t.verifyEqual(rows.physicalOverlapPairs,[0;0]);
            t.verifyEqual(rows.physicalCollidingAttempts,[0;0]);
        end

        function retryOrderingIsStableForPermutationsAndTiedStarts(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            tied=attempts(2); tied.attemptId=4; tied.endTick=NaN; tied.status='started';
            attempts=[attempts(1),attempts(3),attempts(2),tied];
            permuted=attempts([4 2 1 3]);

            first=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);
            second=nbiot.dataset.windowDiagnostics(cfg,packets,permuted,truth, ...
                observed,reception,1000,keys);

            t.verifyEqual(first.raRetryTransmissions,[2;1]);
            t.verifyEqual(second.raRetryTransmissions,first.raRetryTransmissions);
        end

        function terminalPartialWindowRequiresAndFollowsAnExportedKey(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            cfg.simulation.durationTicks=750;
            attempts=attempts(1:2); truth=truth(1:2);
            observed=observed(1); reception=reception(1:3);
            exportedObservationKeys=table( ...
                [cfg.simulation.realizationId;cfg.simulation.realizationId], ...
                [1;2],[0;500],[500;750], ...
                'VariableNames',{'realizationId','windowId','startTick','endTick'});
            exportedTargetKeys=table( ...
                [cfg.simulation.realizationId;cfg.simulation.realizationId], ...
                [1;2],[0;500],[500;750], ...
                'VariableNames',{'realizationId','windowId','startTick','endTick'});
            result=makeResultKeyFixture(cfg,exportedObservationKeys,exportedTargetKeys);
            t.verifyEqual(result.actualTick,cfg.simulation.durationTicks);
            exportedObservationKeys=result.dataset.observations(:,result.dataset.schema.keyNames);
            exportedTargetKeys=result.dataset.targets(:,result.dataset.schema.keyNames);
            t.verifyEqual(exportedObservationKeys,exportedTargetKeys);
            t.verifyEqual(exportedObservationKeys.windowId,[1;2]);
            t.verifyEqual(exportedObservationKeys.endTick,[500;750]);

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,750,exportedObservationKeys);

            t.verifyEqual(rows.windowId,[1;2]);
            t.verifyEqual(rows.endTick,[500;750]);
            t.verifyEqual(rows.outcomeHorizonTick,[750;750]);
            t.verifyEqual(rows.unfinishedAccessCohort(2),0);
            t.verifyEqual(rows.unfinishedPacketCohort(2),1);

            resultWithoutPartial=makeResultKeyFixture(cfg, ...
                exportedObservationKeys(1,:),exportedTargetKeys(1,:));
            withoutExportedPartial=resultWithoutPartial.dataset.observations(:, ...
                resultWithoutPartial.dataset.schema.keyNames);
            withoutTargetPartial=resultWithoutPartial.dataset.targets(:, ...
                resultWithoutPartial.dataset.schema.keyNames);
            t.verifyEqual(withoutExportedPartial,withoutTargetPartial);
            omitted=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,750,withoutExportedPartial);
            t.verifyEqual(height(omitted),1);
            t.verifyEqual(omitted.endTick,500);
        end

        function lateOutcomeIsNotUnfinishedAndStaysInItsOutcomeWindow(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            packets=packets(1);
            packets.deliveredTick=700;
            packets.status='delivered';
            attempts=attempts(1:2);
            attempts(2).startTick=499;
            attempts(2).endTick=600;
            attempts(2).status='success';
            truth=truth(1:2); observed=observed(1); reception=reception(1:3);

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);

            t.verifyEqual(rows.successfulAccesses,[0;1]);
            t.verifyEqual(rows.delaySampleCount,[0;1]);
            t.verifyTrue(isnan(rows.meanDelayTicks(1)));
            t.verifyEqual(rows.meanDelayTicks(2),690);
            t.verifyEqual(rows.unfinishedAccessCohort,[0;0]);
            t.verifyEqual(rows.unfinishedPacketCohort,[0;0]);
            t.verifyEqual(rows.outcomeHorizonTick,[1000;1000]);
        end

        function receiverReadyAfterHorizonIsNotMovedIntoLastWindow(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            observed(1).tick=1000;
            observed(1).fields.readyTick=1000;
            reception(1:3)=setEventTick(reception(1:3),1000);
            keys=keys(2,:); keys.endTick=750;

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,750,keys);

            t.verifyEqual(height(rows),1);
            t.verifyEqual(rows.logicalCollisionGroups,0);
            t.verifyEqual(rows.physicalOverlapPairs,0);
        end

        function missingPacketIdentityMakesRetryUnavailable(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            attempts=rmfield(attempts,'packetId');

            rows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,reception,1000,keys);

            t.verifyEqual(rows.retryAvailable,[false;false]);
            t.verifyTrue(all(isnan(rows.raRetryTransmissions)));
            t.verifyFalse(any(rows.retryAvailable & rows.raRetryTransmissions==0));
        end

        function absentAndPresentEmptyReceiverLogsHaveDifferentAvailability(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();

            absent=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,[],1000,keys);
            present=nbiot.dataset.windowDiagnostics(cfg,packets,attempts,truth, ...
                observed,emptyEvents(),1000,keys);

            t.verifyEqual(absent.physicalAvailable,[false;false]);
            t.verifyTrue(all(isnan(absent.physicalOverlapPairs)));
            t.verifyEqual(present.physicalAvailable,[true;true]);
            t.verifyEqual(present.physicalOverlapPairs,[0;0]);
        end

        function reversedDuplicatePhysicalPairIsRejected(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            reception(end+1)=overlapEvent(500,2,1);

            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');
        end

        function duplicateAttemptAndDetectionIdsAreRejected(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            duplicate=attempts(1); duplicate.attemptId=attempts(2).attemptId;
            attempts(end+1)=duplicate;
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');

            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            observed(end+1)=observed(1);
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');
        end

        function missingPairAttemptAndInconsistentReceiverTickAreRejected(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            reception(end)=overlapEvent(500,1,99);
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');

            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            observed(1).fields.readyTick=499;
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');
        end

        function malformedKeysAndZeroReadyTickAreRejected(t)
            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            duplicate=keys(1,:); keys=[keys;duplicate];
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');

            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            observed(1).tick=0; observed(1).fields.readyTick=0;
            reception(1:3)=setEventTick(reception(1:3),0);
            t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,keys),'nbiot:dataset:Diagnostics');

            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            invalidKeys={keys(1,:),keys(1,:),keys(1,:),keys(1,:),keys(1,:)};
            invalidKeys{1}.realizationId=invalidKeys{1}.realizationId+1;
            invalidKeys{2}.startTick=0.5;
            invalidKeys{3}.startTick=-1;
            invalidKeys{4}.startTick=600; invalidKeys{4}.endTick=500;
            invalidKeys{5}.endTick=1001;
            for k=1:numel(invalidKeys)
                t.verifyError(@() nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                    truth,observed,reception,1000,invalidKeys{k}), ...
                    'nbiot:dataset:Diagnostics');
            end

            [cfg,packets,attempts,truth,observed,reception,keys]=fixture();
            shuffled=keys([2 1],:);
            shuffledRows=nbiot.dataset.windowDiagnostics(cfg,packets,attempts, ...
                truth,observed,reception,1000,shuffled);
            t.verifyEqual(shuffledRows(:,{'realizationId','windowId','startTick','endTick'}), ...
                shuffled);
        end
    end
end

function result=makeResultKeyFixture(cfg,observationKeys,targetKeys)
schema=nbiot.dataset.featureSchema('bs-known-v2.0');
observations=array2table(zeros(height(observationKeys),numel(schema.observationNames)), ...
    'VariableNames',schema.observationNames);
targets=array2table(zeros(height(targetKeys),numel(schema.targetNames)), ...
    'VariableNames',schema.targetNames);
for k=1:numel(schema.keyNames)
    name=schema.keyNames{k};
    observations.(name)=observationKeys.(name);
    targets.(name)=targetKeys.(name);
end
result=struct('actualTick',cfg.simulation.durationTicks,'dataset',struct( ...
    'observations',observations,'targets',targets,'schema',schema));
end

function [cfg,packets,attempts,truth,observed,reception,keys]=fixture()
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=2; cfg.simulation.durationTicks=1000;
packets=repmat(struct('packetId',0,'createdTick',0,'deliveredTick',NaN,'status',''),2,1);
packets(1)=struct('packetId',1,'createdTick',10,'deliveredTick',500,'status','delivered');
packets(2)=struct('packetId',2,'createdTick',510,'deliveredTick',NaN,'status','unfinished');
attempts=repmat(struct('packetId',0,'attemptId',0,'startTick',0, ...
    'endTick',NaN,'status','','occasionId',0,'nInit',0),3,1);
attempts(1)=struct('packetId',1,'attemptId',1,'startTick',0, ...
    'endTick',400,'status','failure','occasionId',1,'nInit',2);
attempts(2)=struct('packetId',1,'attemptId',2,'startTick',499, ...
    'endTick',500,'status','success','occasionId',1,'nInit',2);
attempts(3)=struct('packetId',1,'attemptId',3,'startTick',500, ...
    'endTick',NaN,'status','started','occasionId',2,'nInit',3);
truth=[event(0,'msg1',struct('attemptId',1,'packetId',1,'ueId',1,'occasionId',1,'nInit',2)), ...
    event(499,'msg1',struct('attemptId',2,'packetId',1,'ueId',2,'occasionId',1,'nInit',2)), ...
    event(1000,'msg1',struct('attemptId',3,'packetId',1,'ueId',1,'occasionId',2,'nInit',3))];
candidate1=struct('nInit',2,'readyTick',500);
candidate2=struct('nInit',3,'readyTick',1000);
observed=[event(500,'nprach_detection',struct('occasionId',1,'readyTick',500, ...
        'candidates',candidate1)), ...
    event(1000,'nprach_detection',struct('occasionId',2,'readyTick',1000, ...
        'candidates',candidate2))];
reception=[componentEvent(500,1,1,1,2),componentEvent(500,1,2,2,2), ...
    overlapEvent(500,1,2),componentEvent(1000,2,3,1,3)];
keys=table(repmat(cfg.simulation.realizationId,2,1),[1;2],[0;500],[500;1000], ...
    'VariableNames',{'realizationId','windowId','startTick','endTick'});
end

function e=componentEvent(tick,occasionId,attemptId,ueId,nInit)
e=event(tick,'nprach_component',struct('occasionId',occasionId,'attemptId',attemptId, ...
    'ueId',ueId,'nInit',nInit,'startSample',0,'endSampleExclusive',100, ...
    'signalPowerW',1,'interferencePowerW',0,'noisePowerW',1, ...
    'configuredDelaySeconds',0,'configuredCfoHz',0));
end

function e=overlapEvent(tick,attemptIdA,attemptIdB)
e=event(tick,'nprach_overlap',struct('occasionId',1,'attemptIdA',attemptIdA, ...
    'attemptIdB',attemptIdB,'startSample',0,'endSampleExclusive',100, ...
    'signalPowerAW',1,'signalPowerBW',1));
end

function events=emptyEvents()
events=struct('tick',{},'kind',{},'fields',{});
end

function e=event(tick,kind,fields)
e=struct('tick',double(tick),'kind',char(kind),'fields',fields);
end

function events=setEventTick(events,tick)
for k=1:numel(events), events(k).tick=tick; end
end
