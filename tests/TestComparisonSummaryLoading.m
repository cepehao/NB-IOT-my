classdef TestComparisonSummaryLoading < matlab.unittest.TestCase
    methods (Test)
        function loadsMethodAndPairedTablesForAllThreeModes(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeSummaryFixture(folder);

            loaded=nbiot.ui.loadComparisonSummary(folder);

            expectedMethods=sort(["Static";"Adaptive-P";"Adaptive-RA/DT"]);
            t.verifyEqual(unique(string(loaded.methodSummary.method)),expectedMethods);
            t.verifyEqual(height(loaded.methodSummary),9);
            t.verifyEqual(height(loaded.pairedDifferences),9);
            t.verifyTrue(any(loaded.metrics=="p95DelayTicks"));
            expectedPairs=sort(["Adaptive-P → Adaptive-RA/DT"; ...
                "Static → Adaptive-P";"Static → Adaptive-RA/DT"]);
            t.verifyEqual(unique(string(loaded.pairedDifferences.methodA+" → "+ ...
                loaded.pairedDifferences.methodB)),expectedPairs);
        end

        function rejectsSummaryFolderWithoutBothTables(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            t.verifyError(@() nbiot.ui.loadComparisonSummary(folder), ...
                'nbiot:ui:ComparisonFiles');
        end

        function rejectsSummaryMissingOneOfTheThreeModes(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeSummaryFixture(folder);
            methodFile=fullfile(folder,'method-summary.csv');
            methods=readtable(methodFile);
            methods(string(methods.method)=="Adaptive-RA/DT",:)=[];
            writetable(methods,methodFile);

            t.verifyError(@() nbiot.ui.loadComparisonSummary(folder), ...
                'nbiot:ui:ComparisonMethods');
        end
    end
end

function writeSummaryFixture(folder)
method=repmat(["Static";"Adaptive-P";"Adaptive-RA/DT"],3,1);
metric=[repmat("deliveryProbability",3,1); ...
    repmat("throughputBitsPerSecond",3,1);repmat("p95DelayTicks",3,1)];
methodSummary=table(ones(9,1),100*ones(9,1),method,metric, ...
    2*ones(9,1),zeros(9,1),[.6;.7;.65;100;120;110;100;110;105], ...
    [.05;.04;.06;10;12;11;5;6;5.5],[.4;.5;.3;60;70;50;90;98;94], ...
    [.8;.9;.9;140;170;170;110;122;116], ...
    'VariableNames',{'numUE','burstDurationTicks','method','metric', ...
    'runCount','incompleteCount','mean','standardError','ci95Low','ci95High'});
methodA=repmat(["Static";"Static";"Adaptive-P"],3,1);
methodB=repmat(["Adaptive-P";"Adaptive-RA/DT";"Adaptive-RA/DT"],3,1);
pairedMetric=[repmat("deliveryProbability",3,1); ...
    repmat("throughputBitsPerSecond",3,1);repmat("p95DelayTicks",3,1)];
pairedDifferences=table(ones(9,1),100*ones(9,1),methodA,methodB,pairedMetric, ...
    2*ones(9,1),zeros(9,1),[.1;.05;-.05;20;10;-10;10;5;-5], ...
    [.03;.04;.05;5;6;7;2;3;4],[.02;-.03;-.15;5;-3;-30;6;-1;-13], ...
    [.18;.13;.05;35;23;10;14;11;3], ...
    'VariableNames',{'numUE','burstDurationTicks','methodA','methodB', ...
    'metric','pairCount','incompletePairCount','meanDifference', ...
    'standardError','ci95Low','ci95High'});
writetable(methodSummary,fullfile(folder,'method-summary.csv'));
writetable(pairedDifferences,fullfile(folder,'paired-comparison.csv'));
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
