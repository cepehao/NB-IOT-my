function summary=plotComparisonSummary(input,outputFolder)
%PLOTCOMPARISONSUMMARY Summarize methods and paired differences by external ID.
%   Графики сравнения методов и парных разностей по реализациям (ТЗ §46.9 п.11–12, §63).
if isstruct(input)&&isscalar(input)&&isfield(input,'cases')
    cases=input.cases;
else
    cases=input;
end
required={'numUE','burstDurationTicks','realizationId','method','status', ...
    'raSuccessProbability','deliveryProbability','throughputBitsPerSecond', ...
    'meanDelayTicks','dataBler','ulOccupancy','dlOccupancy'};
if ~istable(cases)||~all(ismember(required,cases.Properties.VariableNames))
    error('nbiot:experiments:ComparisonData','Comparison cases lack required columns.');
end
validateUniqueCases(cases);
if nargin<2, outputFolder=''; end
if isstring(outputFolder)&&isscalar(outputFolder), outputFolder=char(outputFolder); end
if ~ischar(outputFolder)||size(outputFolder,1)~=1
    error('nbiot:experiments:ComparisonOutput','outputFolder must be a path or empty.');
end
supportedMetrics=fieldnames(nbiot.experiments.comparisonKpis(struct(),'Static'));
metrics=reshape(supportedMetrics(ismember(supportedMetrics,cases.Properties.VariableNames)),1,[]);
methodOrder=["Static","Adaptive-P","Adaptive-RA/DT"];
methods=methodOrder(ismember(methodOrder,unique(string(cases.method))));
conditions=unique(cases(:,{'numUE','burstDurationTicks'}),'rows','stable');
methodSummary=buildMethodSummary(cases,conditions,methods,metrics);
pairedDifferences=buildPairedSummary(cases,conditions,methods,metrics);
summary=struct('methodSummary',methodSummary, ...
    'pairedDifferences',pairedDifferences,'figure',[],'files',struct());
if isempty(outputFolder)
    visible='on';
else
    if isfile(outputFolder), error('nbiot:experiments:ComparisonOutput','Output path names a file.'); end
    if ~isfolder(outputFolder), mkdir(outputFolder); end
    visible='off';
end
fig=plotDeliveryDifferences(pairedDifferences,visible);
summary.figure=fig;
if ~isempty(outputFolder)
    methodPath=fullfile(outputFolder,'method-summary.csv');
    pairedPath=fullfile(outputFolder,'paired-comparison.csv');
    figurePath=fullfile(outputFolder,'comparison-summary.png');
    writetable(methodSummary,methodPath);
    writetable(pairedDifferences,pairedPath);
    exportgraphics(fig,figurePath,'Resolution',150);
    summary.files=struct('methodSummary',methodPath, ...
        'pairedDifferences',pairedPath,'figure',figurePath);
end
end

function validateUniqueCases(cases)
method=string(cases.method); status=string(cases.status);
if any(~ismember(status,["pending","running","completed","failed","stopped"]))
    error('nbiot:experiments:ComparisonData','Unknown case status in comparison data.');
end
for k=1:height(cases)
    match=cases.numUE==cases.numUE(k)& ...
        cases.burstDurationTicks==cases.burstDurationTicks(k)& ...
        cases.realizationId==cases.realizationId(k)&method==method(k);
    if sum(match)>1
        error('nbiot:experiments:ComparisonData', ...
            'Each method and external ID may have only one case per condition.');
    end
end
end

function summary=buildMethodSummary(cases,conditions,methods,metrics)
rows={};
for c=1:height(conditions)
    for m=methods
        subset=cases(cases.numUE==conditions.numUE(c)& ...
            cases.burstDurationTicks==conditions.burstDurationTicks(c)& ...
            string(cases.method)==m,:);
        completed=string(subset.status)=="completed";
        for metric=metrics
            values=double(subset.(metric{1}));
            valid=completed&isfinite(values);
            [mu,se,lo,hi]=meanInterval(values(valid));
            rows(end+1,:)={conditions.numUE(c),conditions.burstDurationTicks(c), ...
                m,string(metric{1}),sum(valid),sum(~completed|~isfinite(values)), ...
                mu,se,lo,hi}; %#ok<AGROW>
        end
    end
end
summary=cell2table(rows,'VariableNames',{'numUE','burstDurationTicks','method', ...
    'metric','runCount','incompleteCount','mean','standardError','ci95Low','ci95High'});
end

function summary=buildPairedSummary(cases,conditions,methods,metrics)
rows={};
for c=1:height(conditions)
    condition=cases.numUE==conditions.numUE(c)& ...
        cases.burstDurationTicks==conditions.burstDurationTicks(c);
    ids=unique(cases.realizationId(condition));
    for first=1:numel(methods)-1
        for second=first+1:numel(methods)
            methodA=methods(first); methodB=methods(second);
            rowsA=cases(condition&string(cases.method)==methodA,:);
            rowsB=cases(condition&string(cases.method)==methodB,:);
            for metric=metrics
                differences=[]; incomplete=0;
                for id=ids(:).'
                    a=rowsA(rowsA.realizationId==id,:);
                    b=rowsB(rowsB.realizationId==id,:);
                    if isempty(a)||isempty(b)||string(a.status(1))~="completed"|| ...
                            string(b.status(1))~="completed"
                        incomplete=incomplete+1; continue;
                    end
                    valueA=double(a.(metric{1})); valueB=double(b.(metric{1}));
                    if ~isfinite(valueA)||~isfinite(valueB)
                        incomplete=incomplete+1;
                    else
                        differences(end+1)=valueB-valueA; %#ok<AGROW>
                    end
                end
                [mu,se,lo,hi]=meanInterval(differences);
                rows(end+1,:)={conditions.numUE(c),conditions.burstDurationTicks(c), ...
                    methodA,methodB,string(metric{1}),numel(differences),incomplete, ...
                    mu,se,lo,hi}; %#ok<AGROW>
            end
        end
    end
end
summary=cell2table(rows,'VariableNames',{'numUE','burstDurationTicks', ...
    'methodA','methodB','metric','pairCount','incompletePairCount', ...
    'meanDifference','standardError','ci95Low','ci95High'});
end

function [mu,se,lo,hi]=meanInterval(values)
count=numel(values);
if count==0
    mu=NaN; se=NaN; lo=NaN; hi=NaN;
elseif count==1
    mu=values(1); se=NaN; lo=NaN; hi=NaN;
else
    mu=mean(values); se=std(values,0)/sqrt(count);
    degrees=count-1; q=betaincinv(.05,degrees/2,.5);
    critical=sqrt(degrees*(1/q-1));
    lo=mu-critical*se; hi=mu+critical*se;
end
end

function fig=plotDeliveryDifferences(summary,visible)
pairs=unique(summary(:,{'methodA','methodB'}),'rows','stable');
fig=figure('Visible',visible,'Name','Сравнение режимов NB-IoT');
if isempty(pairs)
    ax=axes(fig); text(ax,.5,.5,'Нет парных запусков для сравнения', ...
        'HorizontalAlignment','center'); axis(ax,'off'); return;
end
layout=tiledlayout(fig,1,height(pairs),'TileSpacing','compact');
for p=1:height(pairs)
    ax=nexttile(layout); hold(ax,'on'); plotted=false;
    selection=summary.methodA==pairs.methodA(p)& ...
        summary.methodB==pairs.methodB(p)&summary.metric=="deliveryProbability";
    subset=summary(selection,:);
    bursts=unique(subset.burstDurationTicks);
    for b=bursts(:).'
        values=subset(subset.burstDurationTicks==b,:);
        x=values.numUE; y=values.meanDifference;
        valid=isfinite(y);
        if any(valid)
            bounded=valid&isfinite(values.ci95Low)&isfinite(values.ci95High);
            if any(valid&~bounded)
                plot(ax,x(valid&~bounded),y(valid&~bounded),'-o', ...
                    'DisplayName',sprintf('%d ms',b));
                plotted=true;
            end
            if any(bounded)
                errorbar(ax,x(bounded),y(bounded), ...
                    y(bounded)-values.ci95Low(bounded), ...
                    values.ci95High(bounded)-y(bounded),'-o', ...
                    'DisplayName',sprintf('%d ms',b));
                plotted=true;
            end
        end
    end
    yline(ax,0,'k:'); grid(ax,'on'); hold(ax,'off');
    title(ax,sprintf('%s → %s',pairs.methodA(p),pairs.methodB(p)));
    xlabel(ax,'Число устройств'); ylabel(ax,'Разница вероятности доставки');
    if plotted, legend(ax,'show','Location','best'); end
end
title(layout,'Положительная разница означает больший показатель у второго режима');
end
