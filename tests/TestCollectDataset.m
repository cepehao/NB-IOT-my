classdef TestCollectDataset < matlab.unittest.TestCase
    %TESTCOLLECTDATASET Сбор датасета из нескольких прогонов (ТЗ §22, §40).
    methods (Test)
        function twoRunsProduceOneDatasetWithSplitsAndNoLeakage(t)
            folder=tempname; t.addTeardown(@() removeFolder(folder));
            % Реализации 0 и 17: train и test (id mod 20).
            cfgs={tinyConfig(0,1,0.1),tinyConfig(17,0.5,0.2)};
            summary=nbiot.dataset.collectDataset(cfgs,folder);

            t.verifyEqual(summary.failed,0);
            t.verifyEqual(summary.runs.status,["completed";"completed"]);
            t.verifyTrue(isfile(fullfile(folder,'dataset.csv')));
            t.verifyTrue(isfile(fullfile(folder,'runs.csv')));
            t.verifyTrue(isfile(fullfile(folder,'runs','run_0001','static-v1_n1_r0000.mat')));
            t.verifyTrue(isfile(fullfile(folder,'runs','run_0002','static-v1_n1_r0017_observations.csv')));

            d=summary.dataset;
            % Горизонт 1000 мс → два окна по 500 мс на прогон.
            t.verifyEqual(height(d),4);
            t.verifyEqual(d.runIndex,[1;1;2;2]);
            t.verifyEqual(d.split,["train";"train";"test";"test"]);
            schema=nbiot.dataset.featureSchema();
            t.verifyTrue(all(ismember(schema.inputNames,d.Properties.VariableNames)));
            t.verifyTrue(ismember('meanRaUe',d.Properties.VariableNames));
            % Режим управления виден в признаках (действовал в окне).
            t.verifyEqual(d.accessProbability,[1;1;0.5;0.5]);
            t.verifyEqual(d.raShare,[0.1;0.1;0.2;0.2]);
            % Target не входит в список признаков модели (ТЗ §40).
            t.verifyFalse(any(ismember(schema.targetNames(5:end),schema.inputNames)));

            imported=readtable(fullfile(folder,'dataset.csv'),'TextType','string');
            t.verifyEqual(height(imported),4);
        end

        function existingDatasetIsNotOverwrittenByDefault(t)
            folder=tempname; t.addTeardown(@() removeFolder(folder));
            nbiot.dataset.collectDataset({tinyConfig(0,1,0.1)},folder,struct('saveRuns',false));
            t.verifyError(@() nbiot.dataset.collectDataset({tinyConfig(0,1,0.1)},folder), ...
                'nbiot:dataset:Exists');
            summary=nbiot.dataset.collectDataset({tinyConfig(1,1,0.1)},folder, ...
                struct('saveRuns',false,'overwrite',true));
            t.verifyEqual(unique(summary.dataset.realizationId),1);
        end

        function failedRunIsRecordedAndSkipped(t)
            folder=tempname; t.addTeardown(@() removeFolder(folder));
            bad=tinyConfig(2,1,0.1); bad.policy.name='Adaptive-P';   % без оценщика — ошибка прогона
            summary=nbiot.dataset.collectDataset({tinyConfig(0,1,0.1),bad},folder, ...
                struct('saveRuns',false));
            t.verifyEqual(summary.failed,1);
            t.verifyEqual(summary.runs.status(2),"failed");
            t.verifyTrue(contains(summary.runs.errorMessage(2),'estimator'));
            t.verifyEqual(unique(summary.dataset.runIndex),1);
        end

        function calibrationRealizationIdsAreRejected(t)
            t.verifyError(@() nbiot.dataset.collectDataset({tinyConfig(4000,1,0.1)},tempname), ...
                'nbiot:dataset:RealizationId');
        end
    end
end

function cfg=tinyConfig(realizationId,accessProbability,raShare)
%TINYCONFIG 1 UE рядом с BS, горизонт 1 с, один пакет в начале — быстрый прогон.
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=1000;
cfg.simulation.realizationId=realizationId;
cfg.cell.radiusM=20; cfg.cell.indoorFraction=0;
cfg.traffic.kind='burst'; cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=1;
cfg.policy.accessProbability=accessProbability; cfg.policy.raShare=raShare;
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
