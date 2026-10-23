classdef TestNBIoTAppComparisonSummary < matlab.unittest.TestCase
    methods (Test)
        function loadsAndDisplaysAllThreeModesWithoutRerunning(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeSummaryFixture(folder);
            dialogs=struct('chooseComparisonFolder',@() folder);
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Открыть сводку сравнения');

            methodTable=findall(app.Figure,'Tag','methodSummaryTable');
            pairedTable=findall(app.Figure,'Tag','pairedSummaryTable');
            metric=findall(app.Figure,'Tag','methodSummaryMetric');
            burst=findall(app.Figure,'Tag','methodSummaryBurst');
            axesHandle=findall(app.Figure,'Tag','methodSummaryAxes');
            t.verifyEqual(height(cell2table(methodTable.Data)),3);
            t.verifyEqual(height(cell2table(pairedTable.Data)),3);
            t.verifyEqual(metric.Value,'deliveryProbability');
            t.verifyEqual(burst.Value,100);
            t.verifyEqual(numel(findobj(axesHandle,'Type','line', ...
                'Tag','methodSummaryLine')),3);
            supportedMetrics=fieldnames(nbiot.experiments.comparisonKpis(struct(),'Static'));
            t.verifyEqual(numel(metric.ItemsData),numel(supportedMetrics));
            t.verifyFalse(any(strcmp(metric.Items,metric.ItemsData)));
            t.verifyTrue(any(strcmp(metric.Items,'95-й процентиль задержки, мс')));
            t.verifyTrue(any(strcmp(metric.ItemsData,'p95DelayTicks')));

            metric.Value='p95DelayTicks';
            feval(metric.ValueChangedFcn,metric,[]);
            t.verifyTrue(contains(axesHandle.Title.String,'95-й процентиль задержки'));

            metric.Value='throughputBitsPerSecond';
            feval(metric.ValueChangedFcn,metric,[]);
            t.verifyEqual(height(cell2table(methodTable.Data)),3);
            t.verifyTrue(contains(axesHandle.Title.String,'Скорость доставки'));
        end

        function invalidSummaryFolderIsExplainedWithoutChangingSession(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            spy=DialogSpy();
            dialogs=struct('chooseComparisonFolder',@() folder, ...
                'showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Открыть сводку сравнения');

            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось открыть сравнение');
            t.verifyTrue(contains(spy.LastMessage,'method-summary.csv'));
        end
    end
end

function writeSummaryFixture(folder)
methods=["Static";"Adaptive-P";"Adaptive-RA/DT"];
metricNames=string(fieldnames(nbiot.experiments.comparisonKpis(struct(),'Static')));
metric=repelem(metricNames,3,1);
method=repmat(methods,numel(metricNames),1);
rowCount=numel(method);
methodValues=repmat([.6;.7;.65],numel(metricNames),1);
methodSummary=table(ones(rowCount,1),100*ones(rowCount,1),method,metric, ...
    2*ones(rowCount,1),zeros(rowCount,1),methodValues, ...
    .05*ones(rowCount,1),methodValues-.2,methodValues+.2, ...
    'VariableNames',{'numUE','burstDurationTicks','method','metric', ...
    'runCount','incompleteCount','mean','standardError','ci95Low','ci95High'});
methodA=repmat(["Static";"Static";"Adaptive-P"],numel(metricNames),1);
methodB=repmat(["Adaptive-P";"Adaptive-RA/DT";"Adaptive-RA/DT"],numel(metricNames),1);
pairedMetric=repelem(metricNames,3,1);
pairCount=numel(methodA);
differences=repmat([.1;.05;-.05],numel(metricNames),1);
pairedDifferences=table(ones(pairCount,1),100*ones(pairCount,1),methodA,methodB,pairedMetric, ...
    2*ones(pairCount,1),zeros(pairCount,1),differences, ...
    .03*ones(pairCount,1),differences-.1,differences+.1, ...
    'VariableNames',{'numUE','burstDurationTicks','methodA','methodB', ...
    'metric','pairCount','incompletePairCount','meanDifference', ...
    'standardError','ci95Low','ci95High'});
writetable(methodSummary,fullfile(folder,'method-summary.csv'));
writetable(pairedDifferences,fullfile(folder,'paired-comparison.csv'));
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
