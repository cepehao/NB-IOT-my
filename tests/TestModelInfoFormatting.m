classdef TestModelInfoFormatting < matlab.unittest.TestCase
    methods (Test)
        function showsModelTypeFeaturesTargetVersionAndMissingScores(t)
            bundle=struct('modelName','linearRegression', ...
                'schemaVersion','bs-known-v2.0','targetName','meanRaUe', ...
                'featureNames',{{'meanDetections','meanBsQueueLength'}}, ...
                'trainingIds',[1 4],'validationIds',2,'testIds',3, ...
                'seed',17,'status','development','dataKind','development-fixture');

            lines=nbiot.ui.formatModelInfo(bundle);
            text=strjoin(string(lines),newline);

            t.verifyTrue(contains(text,'Линейная регрессия'));
            t.verifyTrue(contains(text,'meanRaUe'));
            t.verifyTrue(contains(text,'bs-known-v2.0'));
            t.verifyTrue(contains(text,'meanDetections'));
            t.verifyTrue(contains(text,'meanBsQueueLength'));
            t.verifyTrue(contains(text,'Оценки train/test: не приложены'));
            t.verifyTrue(contains(text,'2/1/1'));
        end

        function includesScoresWhenTheyAreAttachedToThePackage(t)
            bundle=struct('modelName','decisionTree', ...
                'schemaVersion','bs-known-v2.0','targetName','meanRaUe', ...
                'featureNames',{{'detectedCandidates'}}, ...
                'trainingIds',1,'validationIds',2,'testIds',3, ...
                'seed',1,'status','development','dataKind','candidate-training', ...
                'evaluationMetrics',table(["train";"test"],[.2;.4],[.3;.5], ...
                    'VariableNames',{'split','mae','rmse'}));

            lines=nbiot.ui.formatModelInfo(bundle);
            text=strjoin(string(lines),newline);

            t.verifyTrue(contains(text,'train: MAE 0.2, RMSE 0.3'));
            t.verifyTrue(contains(text,'test: MAE 0.4, RMSE 0.5'));
        end
    end
end
