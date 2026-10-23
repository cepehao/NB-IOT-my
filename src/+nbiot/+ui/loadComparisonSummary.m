function loaded=loadComparisonSummary(folder)
%LOADCOMPARISONSUMMARY Load saved three-method comparison tables for display.
%   Загрузка таблиц сравнения трёх методов для отображения (ТЗ §46.9 п.11–12).
if isstring(folder)&&isscalar(folder), folder=char(folder); end
if ~ischar(folder)||size(folder,1)~=1||isempty(strtrim(folder))||~isfolder(folder)
    error('nbiot:ui:ComparisonFolder','Choose a folder with a saved comparison summary.');
end
methodFile=fullfile(folder,'method-summary.csv');
pairedFile=fullfile(folder,'paired-comparison.csv');
if ~isfile(methodFile)||~isfile(pairedFile)
    error('nbiot:ui:ComparisonFiles', ...
        'The folder must contain method-summary.csv and paired-comparison.csv.');
end
try
    methods=readtable(methodFile);
    pairs=readtable(pairedFile);
catch exception
    error('nbiot:ui:ComparisonRead','Cannot read saved comparison tables: %s',exception.message);
end
methodRequired={'numUE','burstDurationTicks','method','metric','runCount', ...
    'incompleteCount','mean','standardError','ci95Low','ci95High'};
pairRequired={'numUE','burstDurationTicks','methodA','methodB','metric', ...
    'pairCount','incompletePairCount','meanDifference','standardError','ci95Low','ci95High'};
if ~istable(methods)||~all(ismember(methodRequired,methods.Properties.VariableNames))|| ...
        ~istable(pairs)||~all(ismember(pairRequired,pairs.Properties.VariableNames))
    error('nbiot:ui:ComparisonSchema','Comparison tables do not match the saved summary format.');
end
methodNames=["Static";"Adaptive-P";"Adaptive-RA/DT"];
methodValues=string(methods.method);
if ~all(ismember(methodNames,unique(methodValues)))
    error('nbiot:ui:ComparisonMethods','Summary must include Static and both Adaptive modes.');
end
pairNames=["Static|Adaptive-P";"Static|Adaptive-RA/DT"; ...
    "Adaptive-P|Adaptive-RA/DT"];
pairValues=string(pairs.methodA)+"|"+string(pairs.methodB);
if ~all(ismember(pairNames,unique(pairValues)))
    error('nbiot:ui:ComparisonPairs','Summary must include all three pairwise method comparisons.');
end
metricNames=string(fieldnames(nbiot.experiments.comparisonKpis(struct(),'Static')));
if any(~ismember(string(methods.metric),metricNames))|| ...
        any(~ismember(string(pairs.metric),metricNames))
    error('nbiot:ui:ComparisonMetric','Comparison summary contains an unsupported metric.');
end
validateNumeric(methods,{'numUE','burstDurationTicks','runCount','incompleteCount'});
validateNumeric(pairs,{'numUE','burstDurationTicks','pairCount','incompletePairCount'});
if any(methods.numUE<1)||any(methods.numUE~=fix(methods.numUE))|| ...
        any(methods.burstDurationTicks<1)||any(methods.burstDurationTicks~=fix(methods.burstDurationTicks))|| ...
        any(methods.runCount<0)||any(methods.runCount~=fix(methods.runCount))|| ...
        any(methods.incompleteCount<0)||any(methods.incompleteCount~=fix(methods.incompleteCount))|| ...
        any(pairs.numUE<1)||any(pairs.numUE~=fix(pairs.numUE))|| ...
        any(pairs.burstDurationTicks<1)||any(pairs.burstDurationTicks~=fix(pairs.burstDurationTicks))|| ...
        any(pairs.pairCount<0)||any(pairs.pairCount~=fix(pairs.pairCount))|| ...
        any(pairs.incompletePairCount<0)||any(pairs.incompletePairCount~=fix(pairs.incompletePairCount))
    error('nbiot:ui:ComparisonCounts','Comparison counts and conditions must be nonnegative integers.');
end
validateUniqueRows(methods,{'numUE','burstDurationTicks','method','metric'});
validateUniqueRows(pairs,{'numUE','burstDurationTicks','methodA','methodB','metric'});
conditions=unique(methods(:,{'numUE','burstDurationTicks','metric'}),'rows');
for index=1:height(conditions)
    selection=methods.numUE==conditions.numUE(index)& ...
        methods.burstDurationTicks==conditions.burstDurationTicks(index)& ...
        string(methods.metric)==string(conditions.metric(index));
    if ~all(ismember(methodNames,unique(methodValues(selection))))
        error('nbiot:ui:ComparisonMethods', ...
            'Each condition and metric must include all three methods.');
    end
    pairSelection=pairs.numUE==conditions.numUE(index)& ...
        pairs.burstDurationTicks==conditions.burstDurationTicks(index)& ...
        string(pairs.metric)==string(conditions.metric(index));
    if ~all(ismember(pairNames,unique(pairValues(pairSelection))))
        error('nbiot:ui:ComparisonPairs', ...
            'Each condition and metric must include all three pairwise comparisons.');
    end
end
figureFile=fullfile(folder,'comparison-summary.png');
if ~isfile(figureFile), figureFile=''; end
loaded=struct('methodSummary',methods,'pairedDifferences',pairs, ...
    'sourceFolder',folder,'figureFile',figureFile, ...
    'metrics',unique(string(methods.metric),'stable'), ...
    'burstDurations',unique(methods.burstDurationTicks,'stable'));
end

function validateNumeric(data,fields)
for index=1:numel(fields)
    values=data.(fields{index});
    if ~isnumeric(values)||~iscolumn(values)||any(~isfinite(values))
        error('nbiot:ui:ComparisonSchema', ...
            'Comparison column %s must contain finite numeric values.',fields{index});
    end
end
end

function validateUniqueRows(data,fields)
values=string(data.(fields{1}));
for index=2:numel(fields)
    current=string(data.(fields{index}));
    values=values+"|"+current;
end
if numel(unique(values))~=numel(values)
    error('nbiot:ui:ComparisonDuplicates','Comparison table has duplicate condition rows.');
end
end
