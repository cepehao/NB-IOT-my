classdef TestLiveStateSummaryFormatting < matlab.unittest.TestCase
    methods (Test)
        function reportsLiveDeviceStagesAndUnfinishedPackets(t)
            state=struct();
            state.deviceTable={1,'IDLE',0,false;2,'WAIT_RA',1,false; ...
                3,'BACKOFF',1,false;4,'WAIT_RAR',1,false; ...
                5,'DATA',2,true;6,'WAIT_RECEIPT',1,false};
            state.packetCounters=struct('created',8,'delivered',2,'dropped',1);
            state.transmittedPacketCount=4;

            lines=nbiot.ui.formatLiveStateSummary(state);
            text=strjoin(string(lines),newline);

            t.verifyTrue(contains(text,'UE: всего 6'));
            t.verifyTrue(contains(text,'активны 5'));
            t.verifyTrue(contains(text,'RA: всего 3'));
            t.verifyTrue(contains(text,'ожидают доступа: 1'));
            t.verifyTrue(contains(text,'ответа станции: 1'));
            t.verifyTrue(contains(text,'повторного доступа: 1'));
            t.verifyTrue(contains(text,'передача/подтверждение 2'));
            t.verifyTrue(contains(text,'с пакетом в очереди 5'));
            t.verifyTrue(contains(text,'отправлено 4'));
            t.verifyTrue(contains(text,'создано 8, доставлено 2, отброшено 1'));
            t.verifyTrue(contains(text,'ещё в работе 5'));
        end
    end
end
