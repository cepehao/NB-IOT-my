classdef TestNBIoTAppLiveCharts < matlab.unittest.TestCase
    methods (Test)
        function staticChartsShowClosedWindowBeforeRunCompletes(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');

            trigger(app.Figure,'Запуск');
            t.assertEqual(app.Session.Status,'running');
            stop(app.Timer);
            app.Session.advance(501);
            t.assertEqual(app.Session.Status,'running');
            feval(app.Timer.TimerFcn,app.Timer,[]);

            chart=findall(app.Figure,'Tag','staticChartActiveUe');
            info=findall(app.Figure,'Tag','staticChartInfo');
            t.assertEqual(numel(chart),1);
            t.assertEqual(numel(info),1);
            lines=findobj(chart,'Type','line');
            t.verifyNotEmpty(lines);
            if ~isempty(lines)
                t.verifyEqual(lines(1).XData,.5,'AbsTol',1e-12);
            end
            t.verifyTrue(contains(info.Text,'Промежуточные'));
            t.verifyTrue(contains(info.Text,'500 мс'));
            t.verifyEqual(app.Session.Status,'running');
        end
    end
end

function setField(fig,tag,value)
control=findall(fig,'Tag',tag);
assert(isscalar(control),['Expected one UI field tagged ' tag]);
control.Value=value;
end

function trigger(fig,label)
button=findall(fig,'Text',label);
assert(isscalar(button),['Expected one button: ' label]);
feval(button.ButtonPushedFcn,button,[]);
end

function closeApp(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end
