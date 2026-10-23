classdef TestNBIoTAppUsability < matlab.unittest.TestCase
    methods (Test)
        function explanationsCoverStatesAndUserQuestions(t)
            keys={'UE','IDLE','WAIT_RAR','DATA','crc_data','connection', ...
                'payload_delivery','packet_segmentation','progress', ...
                'completed_horizon','integer_counts','created','delivered', ...
                'dropped','unfinished','ra_success','throughput','delay', ...
                'data_bler','ra_dt','P','nprach_detection_zero', ...
                'metric_availability'};
            for k=1:numel(keys)
                description=nbiot.ui.explainMetric(keys{k});
                t.verifyTrue(ischar(description)|| ...
                    (isstring(description)&&isscalar(description)),keys{k});
                t.verifyNotEmpty(strtrim(string(description)),keys{k});
                t.verifyNotEqual(string(description),"Описание недоступно",keys{k});
            end

            crc=nbiot.ui.explainMetric('crc_data');
            t.verifyTrue(contains(crc,'ошиб'),crc);
            t.verifyTrue(contains(crc,'без CRC'),crc);
            connection=nbiot.ui.explainMetric('connection');
            delivery=nbiot.ui.explainMetric('payload_delivery');
            t.verifyTrue(contains(connection,'служеб'),connection);
            t.verifyTrue(contains(delivery,'полез'),delivery);
            segmentation=nbiot.ui.explainMetric('packet_segmentation');
            t.verifyTrue(contains(segmentation,'част'),segmentation);
            progress=nbiot.ui.explainMetric('progress');
            t.verifyTrue(contains(progress,'модел'),progress);
            t.verifyTrue(contains(progress,'реальн'),progress);
            horizon=nbiot.ui.explainMetric('completed_horizon');
            t.verifyTrue(contains(horizon,'не гарантирует'),horizon);
            availability=nbiot.ui.explainMetric('metric_availability');
            t.verifyTrue(contains(availability,'нет данных'),availability);
            t.verifyTrue(contains(availability,'не означает нулевую'),availability);
            t.verifyEqual(nbiot.ui.explainMetric('not_a_metric'), ...
                'Описание недоступно');
        end

        function ueStateAndIntegerIdentifiersAreReadable(t)
            detail=struct('ueId',23,'xM',10,'yM',20,'distanceM',30, ...
                'indoor',false,'receivedPowerUlDbm',NaN, ...
                'receivedPowerDlDbm',NaN,'raAttempts',2,'state','WAIT_RAR', ...
                'queueLength',3);

            lines=nbiot.ui.formatUeDetail(detail);
            text=strjoin(lines,newline);

            t.verifyTrue(contains(text,'UE 23'),text);
            t.verifyFalse(contains(text,'23.0000'),text);
            t.verifyTrue(contains(text,'WAIT_RAR'),text);
            t.verifyTrue(contains(text,'ответа станции'),text);
            t.verifyTrue(contains(text,'Очередь: 3 пакета'),text);
        end

        function missingChartMetricsAreNotReportedAsZero(t)
            result=summaryFixture();

            text=nbiot.ui.formatResultSummary(result);

            t.verifyTrue(contains(text,'создано 1, доставлено 0'),text);
            t.verifyTrue(contains(text,'задержка средняя нет данных мс'),text);
            t.verifyTrue(contains(text,'скорость нет данных бит/с'),text);
            t.verifyTrue(contains(text,'не гарантирует доставку всех сообщений'),text);
            t.verifyFalse(contains(text,'1.0000'),text);
        end
    end
end

function result=summaryFixture()
k=struct('created',1,'delivered',0,'dropped',0,'unfinished',1, ...
    'raStarted',1,'raSuccess',1,'raFailed',0,'raUnfinished',0, ...
    'raSuccessProbability',1,'meanRaAttempts',1,'maxRaAttemptsPerPacket',1, ...
    'collisionAttemptProbability',0,'detectedCandidates',0, ...
    'logicalCollisionGroups',0,'collidingAttempts',0, ...
    'msg3Decoded',1,'msg3CrcFailures',0,'msg3Bler',0, ...
    'dataDecoded',2,'dataCrcFailures',0,'dataBler',0, ...
    'deliveryProbability',0,'dropProbability',0, ...
    'throughputBitsPerSecond',NaN,'meanDelaySeconds',NaN, ...
    'p95DelaySeconds',NaN,'ulOccupancy',NaN,'dlOccupancy',NaN, ...
    'nprachOccupancy',NaN,'meanBsQueueLength',0,'maxBsQueueLength',0, ...
    'meanUeQueueLength',0,'maxUeQueueLength',0);
result=struct('status','completed', ...
    'config',struct('simulation',struct('numUE',1,'tickSeconds',0.001), ...
        'policy',struct('name','Static','accessProbability',1,'raShare',0.1)), ...
    'kpiSummary',k);
end
