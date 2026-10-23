classdef TestStartup < matlab.unittest.TestCase
    methods (Test)
        function environmentIsCheckedWithoutStartingSimulation(t)
            t.assertEqual(exist('startNBIoT','file'),2,'The entry point is missing.');
            [app,report]=startNBIoT('check');
            t.verifyEmpty(app);
            t.verifyEqual(report.release,'2025b');
            t.verifyTrue(report.lteAvailable);
            t.verifyTrue(report.calibrationAccepted);
            t.verifyTrue(report.writableResults);
        end
        function invalidModeIsRejected(t)
            t.verifyError(@() startNBIoT('unknown'),'nbiot:startup:Mode');
        end
        function demoOpensReadyWithOneDevice(t)
            app=startNBIoT();
            t.addTeardown(@() close(app.Figure));
            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(findall(app.Figure,'Tag','numUE').Value,1);
            t.verifyEqual(findall(app.Figure,'Tag','durationTicks').Value,5000);
            t.verifyEqual(findall(app.Figure,'Tag','trafficKind').Value,'burst');
        end
    end
end
