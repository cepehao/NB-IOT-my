classdef TestKpiCsvLoading < matlab.unittest.TestCase
    methods (Test)
        function loadsTwoSavedKpiSeriesWithTheirFileNames(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            first=table([100;200],[25;50],[0.5;1], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            second=table([100;300],[10;40],[0.2;0.8], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            firstPath=fullfile(folder,'first_kpi.csv');
            secondPath=fullfile(folder,'second_kpi.csv');
            writetable(first,firstPath); writetable(second,secondPath);

            loaded=nbiot.ui.loadKpiCsvFiles({firstPath,secondPath});

            t.verifyEqual(loaded.files,{firstPath,secondPath});
            t.verifyEqual(loaded.tables{1},first);
            t.verifyEqual(loaded.tables{2},second);
            t.verifyEqual({loaded.reportMetadata{1}.status, ...
                loaded.reportMetadata{2}.status}, ...
                {'unavailable','unavailable'});
        end

        function rejectsKpiCsvWithoutDeliveryProbability(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            malformed=table(100,25,'VariableNames', ...
                {'endTick','throughputBitsPerSecond'});
            path=fullfile(folder,'missing_column_kpi.csv');
            writetable(malformed,path);

            t.verifyError(@() nbiot.ui.loadKpiCsvFiles({path}), ...
                'nbiot:ui:KpiSchema');
        end

        function explainsThatFinalSummaryCsvIsNotWindowKpiData(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            summary=table(1,'VariableNames',{'kpi_created'});
            path=fullfile(folder,'static-v1_n1_r0000_summary.csv');
            writetable(summary,path);

            t.verifyError(@() nbiot.ui.loadKpiCsvFiles({path}), ...
                'nbiot:ui:KpiSummaryCsv');
        end
    end
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
