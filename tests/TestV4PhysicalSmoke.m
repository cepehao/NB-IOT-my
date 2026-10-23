classdef TestV4PhysicalSmoke < matlab.unittest.TestCase
    methods (Test)
        function publicDemoDeliversPausesResumesAndSaves(t)
            app=startNBIoT();
            t.addTeardown(@() close(app.Figure));
            trigger(app.Figure,'Запуск');
            clock=tic;
            state=app.Session.snapshot();
            while strcmp(app.Session.Status,'running') && state.tick<100 && toc(clock)<45
                drawnow; pause(.01); state=app.Session.snapshot();
            end
            t.assertEqual(app.Session.Status,'running',app.Session.LastError);
            trigger(app.Figure,'Пауза');
            paused=app.Session.snapshot();
            pause(.15); drawnow;
            current=app.Session.snapshot();
            t.verifyEqual(app.Session.Status,'paused');
            t.verifyEqual(current.tick,paused.tick);
            trigger(app.Figure,'Продолжить');
            while strcmp(app.Session.Status,'running') && toc(clock)<150
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            result=app.Session.getResult();
            t.verifyEqual(result.kpiSummary.delivered,1);
            t.verifyEqual(result.kpiSummary.deliveredPayloadBits,1600);
            t.verifyEqual(result.actualTick,5000);
            output=tempname;
            resultFile=app.Session.save(output);
            t.verifyTrue(isfile(resultFile));
            report=nbiot.results.verifyCase(fileparts(resultFile));
            t.verifyTrue(report.passed,strjoin(string(report.errors),newline));
            fprintf('V4_PHYSICAL_SMOKE delivered=1 payloadBits=1600 horizon=5000 savedVerified=%d\n',report.passed);
        end
    end
end

function trigger(fig,label)
button=findall(fig,'Text',label);
assert(isscalar(button),'Expected one public action button.');
feval(button.ButtonPushedFcn,button,[]);
end
