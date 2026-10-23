classdef TestNBIoTAppUeDetails < matlab.unittest.TestCase
    methods (Test)
        function selectingDeviceShowsItsDetails(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');

            trigger(app.Figure,'Запуск');
            t.assertEqual(app.Session.Status,'running');
            stop(app.Timer);
            table=findall(app.Figure,'Tag','deviceTable');
            panel=findall(app.Figure,'Tag','selectedUeDetails');
            summary=findall(app.Figure,'Tag','runSummary');
            t.assertEqual(numel(table),1);
            t.assertEqual(numel(panel),1);
            t.assertEqual(numel(summary),1);
            summaryText=strjoin(string(summary.Value),newline);
            t.verifyTrue(contains(summaryText,'активны 0'));
            t.verifyTrue(contains(summaryText,'ещё в работе 0'));
            feval(table.CellSelectionCallback,table,struct('Indices',[1 1]));

            text=strjoin(string(panel.Value),newline);
            t.verifyTrue(contains(text,'UE 1'));
            t.verifyTrue(contains(text,'Координаты:'));
            t.verifyTrue(contains(text,'Расстояние до станции:'));
            t.verifyTrue(contains(text,'Мощность UL:'));
            t.verifyTrue(contains(text,'Опорный SNR UL/DL:'));
            t.verifyTrue(contains(text,'появится после завершения расчёта'));
            t.verifyTrue(contains(text,'Попытки доступа: 0'));
            t.verifyTrue(contains(text,'Этап: ожидание'));

            trigger(app.Figure,'Остановить');
            t.verifyEqual(app.Session.Status,'stopped');
            stoppedState=app.Session.snapshot();
            t.verifyEqual(stoppedState.ueDetails(1).radioSummary.status,'available');
            text=strjoin(string(panel.Value),newline);
            t.verifyTrue(contains(text,'Радиодиагностика: для этого UE нет измерений'));
            summaryText=strjoin(string(summary.Value),newline);
            t.verifyTrue(contains(summaryText,'Итог: stopped'));

            outputFolder=tempname;
            t.addTeardown(@() removeFolder(outputFolder));
            resultPath=app.Session.save(outputFolder);
            t.verifyTrue(isfile(resultPath));
            [savedFolder,stem]=fileparts(resultPath);
            t.verifyTrue(isfile(fullfile(savedFolder,[stem '_radio.csv'])));
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

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
