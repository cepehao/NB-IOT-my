classdef TestObservedEventFormatting < matlab.unittest.TestCase
    methods (Test)
        function formatsObservedTimeAndFutureControlIntervalSeparately(t)
            events=struct('tick',{},'kind',{},'fields',{});
            events(end+1)=struct('tick',8,'kind','nprach_detection', ...
                'fields',struct('count',2,'maxMetric',0.75));
            events(end+1)=struct('tick',16,'kind','grant', ...
                'fields',struct('phase','Msg3','rnti',23,'format','N0','startTick',32,'endTick',34));
            events(end+1)=struct('tick',32,'kind','rar_sent', ...
                'fields',struct('rnti',23));
            events(end+1)=struct('tick',62,'kind','phy_decode', ...
                'fields',struct('channel','Msg3','phase','RA','rnti',23, ...
                    'hasCrc',true,'crcError',0,'receiverId',0,'startTick',32,'endTick',35));
            events(end+1)=struct('tick',36,'kind','phy_decode', ...
                'fields',struct('channel','Data','phase','Data','rnti',23, ...
                    'hasCrc',true,'crcError',1,'receiverId',1,'startTick',35,'endTick',36));
            events(end+1)=struct('tick',37,'kind','bs_queue', ...
                'fields',struct('pendingRequests',1));

            lines=nbiot.ui.formatObservedEvents(events);

            t.verifyEqual(lines,{ ...
                't=8 мс · Обнаружение доступа: кандидатов 2, показатель 0.75'; ...
                't=16 мс · Назначен будущий интервал управляющей передачи для Msg3, формат N0, RNTI 23: 32–34 мс'; ...
                't=32 мс · Подготовлен ответ на запрос доступа (RAR) для RNTI 23'; ...
                't=62 мс · Приём служебного сообщения Msg3/RA, RNTI 23: CRC OK'});
            t.verifyFalse(contains(lines{2},'t=34'));
            t.verifyFalse(contains(lines{3},'устройство получило'));
            t.verifyFalse(contains(lines{4},'доставка полезных данных'));
        end

        function hidesOnlyZeroDetectionRowsWithoutMutatingSource(t)
            events=struct('tick',{},'kind',{},'fields',{});
            events(end+1)=struct('tick',10,'kind','nprach_detection', ...
                'fields',struct('count',0,'maxMetric',0.1));
            events(end+1)=struct('tick',11,'kind','grant', ...
                'fields',struct('phase','Msg3','rnti',7,'format','N0','startTick',16,'endTick',18));
            events(end+1)=struct('tick',12,'kind','nprach_detection', ...
                'fields',struct('count',1,'maxMetric',0.8));
            events(end+1)=struct('tick',13,'kind','nprach_detection', ...
                'fields',struct('count',0,'maxMetric',0.2));
            source=events;

            [visible,hiddenCount]=nbiot.ui.formatObservedEvents(events);
            [allRows,allHidden]=nbiot.ui.formatObservedEvents(events,true);

            t.verifyEqual(hiddenCount,2);
            t.verifyEqual(numel(visible),2);
            t.verifyTrue(startsWith(visible{1},'t=11 мс'));
            t.verifyTrue(startsWith(visible{2},'t=12 мс'));
            t.verifyEqual(allHidden,0);
            t.verifyEqual(numel(allRows),4);
            t.verifyTrue(startsWith(allRows{1},'t=10 мс'));
            t.verifyTrue(startsWith(allRows{4},'t=13 мс'));
            t.verifyEqual(events,source);
        end
    end
end
