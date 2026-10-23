classdef TestNBIoTAppControllerCharts < matlab.unittest.TestCase
    methods (Test)
        function liveWindowHasSeparateControllerCharts(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));

            tab=findall(app.Figure,'Tag','controllerChartsTab');
            forecast=findall(app.Figure,'Tag','controllerChartForecast');
            access=findall(app.Figure,'Tag','controllerChartAccess');
            raDt=findall(app.Figure,'Tag','controllerChartRaDt');
            errorChart=findall(app.Figure,'Tag','controllerChartError');
            info=findall(app.Figure,'Tag','controllerChartInfo');
            t.verifyEqual(numel(tab),1);
            t.verifyEqual(numel(forecast),1);
            t.verifyEqual(numel(access),1);
            t.verifyEqual(numel(raDt),1);
            t.verifyEqual(numel(errorChart),1);
            t.verifyTrue(contains(info.Text,'Static'));
        end
    end
end

function closeApp(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end
