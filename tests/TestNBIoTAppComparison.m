classdef TestNBIoTAppComparison < matlab.unittest.TestCase
    methods (Test)
        function selectedKpiFilesAreShownAsSeparateSeries(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            first=table([100;200],[25;50],[0.5;1], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            second=table([100;300],[10;40],[0.2;0.8], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            writetable(first,fullfile(folder,'first_kpi.csv'));
            writetable(second,fullfile(folder,'second_kpi.csv'));
            dialogs=struct('chooseOutputDirectory',@() folder, ...
                'chooseKpiFile',@() deal({'first_kpi.csv','second_kpi.csv'},folder));

            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            button=findall(app.Figure,'Tag','savedKpiButton');
            t.assertEqual(numel(button),1);
            feval(button.ButtonPushedFcn,button,[]);

            savedTable=findall(app.Figure,'Tag','savedKpiTable');
            savedAxes=findall(app.Figure,'Tag','savedKpiAxes');
            t.verifyEqual(savedTable.Data,table2cell(first));
            firstLine=findobj(savedAxes,'Type','line','DisplayName','first_kpi.csv');
            secondLine=findobj(savedAxes,'Type','line','DisplayName','second_kpi.csv');
            t.verifyTrue(isgraphics(firstLine,'line'));
            t.verifyTrue(isgraphics(secondLine,'line'));
            if isgraphics(firstLine,'line')
                t.verifyEqual(firstLine.XData,[0.1 0.2],'AbsTol',1e-12);
                t.verifyEqual(firstLine.YData,[25 50]);
            end
            if isgraphics(secondLine,'line')
                t.verifyEqual(secondLine.XData,[0.1 0.3],'AbsTol',1e-12);
                t.verifyEqual(secondLine.YData,[10 40]);
            end
            metricPicker=findall(app.Figure,'Tag','savedKpiMetric');
            t.assertEqual(numel(metricPicker),1);
            metricPicker.Value='cohortDeliveryProbability';
            feval(metricPicker.ValueChangedFcn,metricPicker,[]);
            firstProbability=findobj(savedAxes,'Type','line','DisplayName','first_kpi.csv');
            secondProbability=findobj(savedAxes,'Type','line','DisplayName','second_kpi.csv');
            t.verifyEqual(firstProbability.YData,[0.5 1]);
            t.verifyEqual(secondProbability.YData,[0.2 0.8]);
            info=findall(app.Figure,'Tag','savedKpiInfo');
            t.verifyTrue(contains(info.Text,'2 запуск'));
        end
    end
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
