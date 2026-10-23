classdef TestMetrics < matlab.unittest.TestCase
    methods (Test)
        function countsCensoredWorkAndUniqueBits(t)
            cfg=nbiot.config.defaultConfig();
            p=repmat(struct('status','unfinished','createdTick',0,'deliveredTick',NaN),1,3);
            p(1).status='delivered'; p(1).deliveredTick=500; p(2).status='dropped';
            a=struct('status',{'success','unfinished'},'collision',{false,true});
            empty=struct('tick',{},'kind',{},'fields',{});
            k=nbiot.metrics.summarizeKpi(cfg,p,a,empty,empty,table(),5000);
            t.verifyEqual([k.created k.delivered k.dropped k.unfinished],[3 1 1 1]);
            t.verifyEqual(k.raSuccessProbability,.5); t.verifyEqual(k.raSuccessCompletedProbability,1);
            t.verifyEqual(k.throughputBitsPerSecond,320); t.verifyEqual(k.meanDelayTicks,500);
            t.verifyTrue(isnan(k.dataBler));
        end
        function occupancyCountsOverlappingUeOnce(t)
            cfg=nbiot.config.defaultConfig(); f=struct('ticks',1:8,'frequencyStartHz',0,'bandwidthHz',45000,'direction','UL');
            e=repmat(struct('tick',1,'kind','transmission','fields',f),2,1);
            empty=struct('tick',{},'kind',{},'fields',{});
            k=nbiot.metrics.summarizeKpi(cfg,[],[],empty,e,table(),5000);
            t.verifyEqual(k.ulOccupiedUnits,8*2*12);
        end
        function summarizesAvailableRandomAccessMeasurements(t)
            cfg=nbiot.config.defaultConfig();
            packets=repmat(struct('status','unfinished','createdTick',0, ...
                'deliveredTick',NaN,'attemptCount',0),1,3);
            packets(1).attemptCount=3; packets(2).attemptCount=2;
            attempts=repmat(struct('status','success','collision',false, ...
                'capture',false,'occasionId',1,'nInit',2),1,3);
            attempts(1).collision=true; attempts(1).capture=true;
            attempts(2).collision=true; attempts(3).occasionId=2;
            observed=repmat(struct('tick',1,'kind','nprach_detection', ...
                'fields',struct('count',0)),2,1);
            observed(1).fields.count=2; observed(2).fields.count=1;
            truth=struct('tick',{},'kind',{},'fields',{});

            k=nbiot.metrics.summarizeKpi( ...
                cfg,packets,attempts,observed,truth,table(),10);

            t.verifyEqual(k.detectedCandidates,3);
            t.verifyEqual(k.logicalCollisionGroups,1);
            t.verifyEqual(k.collidingAttempts,2);
            t.verifyEqual(k.captureEvents,1);
            t.verifyEqual(k.maxRaAttemptsPerPacket,3);
        end
    end
end
