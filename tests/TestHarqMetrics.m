classdef TestHarqMetrics < matlab.unittest.TestCase
    methods (Test)
        function firstSuccess(t)
            h=nbiot.metrics.harqSummary(block(1,1,0,[0],10),10);
            t.verifyTrue(h.available); t.verifyEqual(h.blocksStarted,1);
            t.verifyEqual(h.firstTransmissionBler,0); t.verifyEqual(h.blocksAccepted,1);
            t.verifyEqual(h.retryAttempts,0); t.verifyEqual(h.blocksCensored,0);
        end
        function retrySuccessKeepsFirstFailure(t)
            h=nbiot.metrics.harqSummary(block(1,1,0,[1 0],10),10);
            t.verifyEqual(h.firstTransmissionBler,1); t.verifyEqual(h.allAttemptBler,.5);
            t.verifyEqual(h.blocksAccepted,1); t.verifyEqual(h.retryAttempts,1);
        end
        function missedN0IsReceiverFailureButNotFirstTransmission(t)
            j=block(1,1,0,[1 0],10);
            emitted=find(strcmp({j.kind},'emitted'));
            j(emitted(1))=[];
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.firstTransmissionBler,0); t.verifyEqual(h.firstReceiverBler,1);
            t.verifyEqual(h.transmissionsStarted,1); t.verifyEqual(h.retryTransmissions,0);
            t.verifyEqual(h.receiverRetryAttempts,1);
        end
        function exhaustedRetries(t)
            h=nbiot.metrics.harqSummary(block(1,1,0,[1 1 1 1],10),10);
            t.verifyEqual(h.blocksFailed,1); t.verifyEqual(h.blocksAccepted,0);
            t.verifyEqual(h.firstTransmissionBler,1); t.verifyEqual(h.retryAttempts,3);
        end
        function packetBlocksAndWrappedSequenceStayDistinct(t)
            j=[block(1,1,0,0,10);block(1,1,1,[1 0],10);block(2,1,0,1,10)];
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksStarted,3); t.verifyEqual(h.blocksAccepted,2);
            t.verifyEqual(h.blocksFailed,1); t.verifyEqual(h.firstTransmissionBler,2/3);
        end
        function exactHorizonAndPendingReception(t)
            j=block(1,1,0,0,10); f=j(1).fields; f.contextId=2; f.readyTick=11;
            f.startTick=9; f.endTick=10;
            j(end+1)=event(8,'scheduled',f);
            j(end+1)=event(9,'emitted',f);
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksAccepted,1); t.verifyEqual(h.blocksCensored,1);
            t.verifyEqual(h.firstPending,1); t.verifyEqual(h.firstDecoded,1);
            t.verifyEqual(h.blocksStarted,2); t.verifyEqual(h.attemptsStarted,2);
            t.verifyEqual(h.firstReceiverPending,1); t.verifyEqual(h.pendingAttempts,1);
        end
        function pendingRetryIsCensored(t)
            j=block(1,1,0,1,10); j(end)=[];
            f=j(1).fields; f.attempt=2; f.readyTick=11;
            j(end+1)=event(9,'scheduled',f);
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksFailed,0); t.verifyEqual(h.blocksCensored,1);
            t.verifyEqual(h.firstTransmissionBler,1); t.verifyEqual(h.pendingAttempts,1);
        end
        function crcSuccessWithInvalidHeaderIsNotAccepted(t)
            j=block(1,1,0,0,10); decoded=find(strcmp({j.kind},'decoded'));
            j(decoded).fields.accepted=false; j(end).fields.outcome='failed';
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.firstTransmissionBler,0); t.verifyEqual(h.blocksFailed,1);
        end
        function futureEventsAndLegacyAreExplicit(t)
            h=nbiot.metrics.harqSummary(block(1,1,0,0,11),10);
            t.verifyEqual(h.blocksCensored,1); t.verifyEqual(h.firstPending,1);
            h=nbiot.metrics.harqSummary([],10); t.verifyFalse(h.available);
            t.verifyTrue(isnan(h.firstTransmissionBler));
        end
        function badIdentityIsRejected(t)
            j=block(1,1,0,0,10); j(1).fields=rmfield(j(1).fields,'contextId');
            t.verifyError(@() nbiot.metrics.harqSummary(j,10),'nbiot:metrics:HarqJournal');
        end
        function schedulingAtHorizonDoesNotStartAnAttempt(t)
            j=block(1,1,0,0,11);
            j(1).tick=10; j(2).tick=10;
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksStarted,0); t.verifyEqual(h.attemptsStarted,0);
        end
        function reservationBeforeHorizonWithStartAtHorizon(t)
            j=block(1,1,0,0,13); j=j(1);
            j.tick=9; j.fields.startTick=10;
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksStarted,0); t.verifyEqual(h.attemptsStarted,0);
            t.verifyEqual(h.firstReceiverPending,0); t.verifyEqual(h.blocksCensored,0);
            t.verifyEqual(h.pendingAttempts,0); t.verifyTrue(isnan(h.firstReceiverBler));
        end
        function reservationBeforeHorizonWithStartAfterHorizon(t)
            j=block(1,1,0,0,14); j=j(1);
            j.tick=9; j.fields.startTick=11;
            h=nbiot.metrics.harqSummary(j,10);
            t.verifyEqual(h.blocksStarted,0); t.verifyEqual(h.attemptsStarted,0);
            t.verifyEqual(h.firstReceiverPending,0); t.verifyEqual(h.blocksCensored,0);
            t.verifyEqual(h.pendingAttempts,0); t.verifyTrue(isnan(h.firstReceiverBler));
        end
        function reservedRetryAtOrAfterHorizonDoesNotStart(t)
            for start=[10 11]
                j=block(1,1,0,1,8); j(end)=[];
                f=j(1).fields; f.attempt=2; f.startTick=start;
                f.endTick=start+1; f.readyTick=start+3;
                j(end+1)=event(9,'scheduled',f);
                h=nbiot.metrics.harqSummary(j,10);
                t.verifyEqual(h.blocksStarted,1); t.verifyEqual(h.blocksCensored,1);
                t.verifyEqual(h.attemptsStarted,1); t.verifyEqual(h.retryAttempts,0);
                t.verifyEqual(h.receiverRetryAttempts,0); t.verifyEqual(h.pendingAttempts,0);
                t.verifyEqual(h.firstReceiverPending,0); t.verifyEqual(h.firstReceiverBler,1);
            end
        end
        function invalidScheduledStartIsRejected(t)
            j=block(1,1,0,0,10);
            invalid={NaN,Inf,-1,.5,[0 1],[],1i,'0'};
            for k=1:numel(invalid)
                j(1).fields.startTick=invalid{k};
                t.verifyError(@() nbiot.metrics.harqSummary(j,10),'nbiot:metrics:HarqJournal');
            end
            j(1).fields=rmfield(j(1).fields,'startTick');
            t.verifyError(@() nbiot.metrics.harqSummary(j,10),'nbiot:metrics:HarqJournal');
        end
        function secondaryMetricsAndCsvCompatibility(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            p=struct('status','unfinished','createdTick',0,'deliveredTick',NaN,'terminalTick',NaN);
            a=struct('status','unfinished','collision',false,'startTick',0,'endTick',NaN);
            q=event(0,'bs_queue',struct('pendingRequests',3));
            tx=event(0,'transmission',struct('channel','NPRACH','ticks',0:1, ...
                'frequencyStartHz',0,'bandwidthHz',45000,'direction','UL'));
            k=nbiot.metrics.summarizeKpi(cfg,p,a,q,tx,table(),2);
            t.verifyEqual(k.meanRaAttempts,1); t.verifyEqual(k.nprachOccupancy,1);
            t.verifyEqual(k.meanBsQueueLength,3); t.verifyEqual(k.maxBsQueueLength,3);
            t.verifyFalse(k.controller.applicable); t.verifyTrue(isnan(k.controller.decisions));
            s=nbiot.metrics.windowKpi(cfg,p,a,q,2);
            t.verifyEqual(s.meanBsQueueLength,3);
            t.verifyEqual(s.Properties.VariableNames(1:16),{'windowId','startTick','endTick','created', ...
                'deliveredInWindow','droppedInWindow','cohortDelivered','cohortDropped','cohortUnfinished', ...
                'cohortDeliveryProbability','raStarted','raSucceededInWindow','raFailedInWindow', ...
                'ulTbDecoded','ulCrcFailures','throughputBitsPerSecond'});
        end
    end
end

function j=block(context,sequence,index,crcs,ready)
j=struct('tick',{},'kind',{},'fields',{});
for n=1:numel(crcs)
    f=struct('contextId',context,'packetSequence',sequence,'blockIndex',index, ...
        'attempt',n,'startTick',n-1,'endTick',ready-2,'readyTick',ready);
    j(end+1,1)=event(n-1,'scheduled',f);
    j(end+1,1)=event(n-1,'emitted',f);
    f.crcError=crcs(n); f.accepted=crcs(n)==0;
    j(end+1,1)=event(ready,'decoded',f);
end
f=struct('contextId',context,'packetSequence',sequence,'blockIndex',index,'attempt',numel(crcs));
if crcs(end)==0, f.outcome='accepted'; else, f.outcome='failed'; end
j(end+1,1)=event(ready,'terminal',f);
end
function e=event(tick,kind,fields)
e=struct('tick',tick,'kind',kind,'fields',fields);
end
