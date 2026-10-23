classdef TestUeDetailFormatting < matlab.unittest.TestCase
    methods (Test)
        function showsLocationPowerAccessAttemptsAndState(t)
            detail=struct('ueId',2,'xM',12.5,'yM',-7, ...
                'distanceM',35.2,'indoor',true, ...
                'receivedPowerUlDbm',-82.1,'receivedPowerDlDbm',-81.4, ...
                'raAttempts',3,'state','WAIT_RAR','queueLength',2);

            lines=nbiot.ui.formatUeDetail(detail);
            text=strjoin(string(lines),newline);

            t.verifyTrue(contains(text,'UE 2'));
            t.verifyTrue(contains(text,'X = 12.5 м'));
            t.verifyTrue(contains(text,'Y = -7.0 м'));
            t.verifyTrue(contains(text,'35.2 м'));
            t.verifyTrue(contains(text,'внутри здания'));
            t.verifyTrue(contains(text,'−82.1 дБм'));
            t.verifyTrue(contains(text,'3'));
            t.verifyTrue(contains(text,'ожидание ответа станции'));
            t.verifyTrue(contains(text,'2 пакета'));
        end

        function explainsUnknownStateWithoutHidingOtherDetails(t)
            detail=struct('ueId',1,'xM',0,'yM',0,'distanceM',10, ...
                'indoor',false,'receivedPowerUlDbm',NaN, ...
                'receivedPowerDlDbm',NaN,'raAttempts',0, ...
                'state','FUTURE_STATE','queueLength',0);

            lines=nbiot.ui.formatUeDetail(detail);
            text=strjoin(string(lines),newline);

            t.verifyTrue(contains(text,'Этап: FUTURE_STATE'));
            t.verifyTrue(contains(text,'Мощность UL: —'));
            t.verifyTrue(contains(text,'снаружи'));
        end

        function showsStoredSnrSinrAndReceiverEstimatesSeparately(t)
            detail=struct('ueId',1,'xM',0,'yM',0,'distanceM',10, ...
                'indoor',false,'receivedPowerUlDbm',-82, ...
                'receivedPowerDlDbm',-80,'raAttempts',2, ...
                'state','IDLE','queueLength',0);
            detail.radioSummary=struct('status','available', ...
                'referenceSnrUlDb',17.5,'referenceSnrDlDb',18, ...
                'perAttempt',struct('attemptId',{4,5},'sinrDb',{6.25,NaN}), ...
                'receiverEstimates',struct('occasionId',3, ...
                    'estimatedDelaySeconds',2e-6,'estimatedCfoHz',42, ...
                    'truthAvailable',true), ...
                'npuschReceiverEstimates',struct('channel','Msg3', ...
                    'estimatedDelaySeconds',4e-6,'estimatedCfoHz',24, ...
                    'truthAvailable',true));

            text=strjoin(string(nbiot.ui.formatUeDetail(detail)),newline);

            t.verifyTrue(contains(text,'Опорный SNR UL/DL: 17.5 / 18.0 дБ'));
            t.verifyTrue(contains(text,'Диагностический SINR NPRACH, попытка 4: 6.25 дБ'));
            t.verifyTrue(contains(text,'Диагностический SINR NPRACH, попытка 5: — дБ'));
            t.verifyTrue(contains(text,'NPRACH, окно 3: задержка 0.002 мс; CFO 42 Гц'));
            t.verifyTrue(contains(text,'NPUSCH Msg3: задержка 0.004 мс; CFO 24 Гц'));
            t.verifyFalse(contains(text,'NaN'));
        end

        function statesWhenStoredRadioDiagnosticsAreUnavailable(t)
            detail=struct('ueId',1,'xM',0,'yM',0,'distanceM',10, ...
                'indoor',false,'receivedPowerUlDbm',NaN, ...
                'receivedPowerDlDbm',NaN,'raAttempts',0, ...
                'state','IDLE','queueLength',0);
            detail.radioSummary=struct('status','unavailable', ...
                'referenceSnrUlDb',NaN,'referenceSnrDlDb',NaN, ...
                'perAttempt',struct([]),'receiverEstimates',struct([]), ...
                'npuschReceiverEstimates',struct([]));

            text=strjoin(string(nbiot.ui.formatUeDetail(detail)),newline);

            t.verifyTrue(contains(text,'Радиодиагностика: нет данных'));
            t.verifyFalse(contains(text,'NaN'));
        end
    end
end
