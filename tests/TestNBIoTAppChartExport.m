classdef TestNBIoTAppChartExport < matlab.unittest.TestCase
    methods (Test)
        function emptySavedReportPointsToKpiCsvAction(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));

            report=findall(app.Figure,'Tag','savedReportCard');
            t.assertEqual(numel(report),1);
            reportText=strjoin(string(report.Value),newline);
            t.verifyTrue(contains(reportText,'Отчёт ещё не открыт.'),reportText);
            t.verifyTrue(contains(reportText,'Открыть/сравнить KPI CSV'),reportText);
        end

        function chartExportFeedbackStartsWithoutFalseSuccess(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));

            exportButton=findall(app.Figure,'Tag','exportChartsButton');
            status=findall(app.Figure,'Tag','chartExportInfo');
            path=findall(app.Figure,'Tag','chartExportPath');
            openFolder=findall(app.Figure,'Tag','openChartFolderButton');
            t.assertEqual(numel(exportButton),1);
            t.verifyEqual(string(exportButton.Enable),"off");
            t.assertEqual(numel(status),1);
            t.verifyFalse(contains(status.Text,'Сохранено'));
            t.assertEqual(numel(path),1);
            t.verifyEqual(strtrim(strjoin(string(path.Value),newline)),"");
            t.assertEqual(numel(openFolder),1);
            t.verifyEqual(string(openFolder.Enable),"off");
            t.verifyEqual(string(openFolder.Text),"Открыть папку");
        end
    end
end

function closeApp(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end
