classdef TestAdaptiveIntegration < matlab.unittest.TestCase
    methods (Test)
        function adaptiveModeRequiresAnExplicitCompatibleModel(t)
            cfg=smallAdaptiveConfig('Adaptive-P');
            t.verifyError(@() nbiot.NBIoTSimulator(cfg,[],localDevelopment()), ...
                'nbiot:controller:ModelRequired');
        end

        function closedWindowPredictionIsAppliedAndRecorded(t)
            cfg=smallAdaptiveConfig('Adaptive-P');
            options=developmentController(4);
            options.policy=struct('maximumLoad',123);
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment(),options);
            simulator.run();
            result=simulator.result();

            if ~strcmp(result.status,'completed')
                error('TestAdaptiveIntegration:SimulationFailure', ...
                    'Adaptive run ended as %s: %s',result.status,result.error.message);
            end
            t.verifyEqual(result.status,'completed');
            t.verifyEqual([result.controllerLog.decisionTick],[0 500]);
            t.verifyEqual(result.controllerLog(1).reason,'no-prior-window');
            t.verifyEqual(result.controllerLog(2).featureWindowEndTick,500);
            t.verifyEqual(result.controllerLog(2).estimateValue,4);
            featureRow=find(result.dataset.observations.endTick==500,1);
            savedFeatures=jsondecode(result.controllerLog(2).featureValuesJson);
            t.verifyEqual(result.dataset.observations.accessProbability,[1;0.5]);
            t.verifyEqual(result.dataset.observations.raShare,[0.1;0.1]);
            t.verifyEqual(savedFeatures.detectedCandidates, ...
                result.dataset.observations.detectedCandidates(featureRow));
            t.verifyEqual(savedFeatures.accessProbability, ...
                result.dataset.observations.accessProbability(featureRow));
            t.verifyEqual(savedFeatures.raShare, ...
                result.dataset.observations.raShare(featureRow));
            t.verifyFalse(isfield(savedFeatures,'meanRaUe'));
            t.verifyEqual(result.controllerLog(2).proposedAccessProbability,0.5);
            t.verifyTrue(result.controllerLog(2).applied);
            t.verifyEqual(result.controllerLog(2).appliedAccessProbability,0.5);
            t.verifyEqual(result.config.policy.accessProbability,1);
            t.verifyEqual(result.controllerModel.status,'development');
            t.verifyEqual(result.controllerModel.admissionStatus,'development-only');
            t.verifyEqual(result.controllerLogSchemaVersion,1);
            t.verifyEqual(result.controllerPolicy.maximumLoad,123);

            live=simulator.snapshot();
            t.verifyEqual(live.controllerDiagnosticTargets.endTick,[500;1000]);
            t.verifyEqual(live.controllerDiagnosticTargets.meanRaUe, ...
                result.dataset.targets.meanRaUe);

            t.verifyTrue(all(result.kpiTimeSeries.controllerApplicable));
            t.verifyEqual(sum(result.kpiTimeSeries.controllerDecisions),2);
            t.verifyEqual(sum(result.kpiTimeSeries.configurationSwitches),1);
        end

        function adaptiveResourceModeChangesOnlyTheFutureShare(t)
            cfg=smallAdaptiveConfig('Adaptive-RA/DT');
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment(),developmentController(8));
            simulator.run();
            result=simulator.result();

            assertCompleted(result);
            t.verifyEqual(result.controllerLog(2).proposedAccessProbability,1);
            t.verifyEqual(result.controllerLog(2).proposedRaShare,0.3);
            t.verifyTrue(result.controllerLog(2).applied);
            t.verifyEqual(result.runtimeAction.accessProbability,1);
            t.verifyEqual(result.runtimeAction.raShare,0.3);
            t.verifyEqual(result.controllerLogSchemaVersion,1);
        end

        function invalidPredictionLeavesTheCurrentActionInPlace(t)
            cfg=smallAdaptiveConfig('Adaptive-P');
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment(),developmentController(NaN));
            simulator.run();
            result=simulator.result();

            assertCompleted(result);
            t.verifyFalse(result.controllerLog(2).estimateValid);
            t.verifyFalse(result.controllerLog(2).applied);
            t.verifyEqual(result.controllerLog(2).estimateReason,'nonfinite-prediction');
            t.verifyEqual(result.controllerLog(2).reason,'invalid-estimate');
            t.verifyEqual(result.runtimeAction.accessProbability,1);
            t.verifyEqual(result.kpiSummary.controller.configurationSwitches,0);
        end

        function externalAdaptiveRequiresPersistedAcceptanceBeforeConstruction(t)
            cfg=smallAdaptiveConfig('Adaptive-P');
            execution=struct('profile','external-machine','role','final-comparison', ...
                'maxUE',2,'maxCaseSeconds',300,'maxSuiteSeconds',900);
            options=developmentController(4);
            options.allowDevelopmentModel=false;

            t.verifyError(@() nbiot.NBIoTSimulator(cfg,[],execution,options), ...
                'nbiot:ml:ModelAcceptance');
        end
    end
end

function cfg=smallAdaptiveConfig(method)
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=1000;
cfg.traffic.kind='none';
cfg.policy.name=method;
cfg.policy.windowTicks=500;
cfg.dataset.windowTicks=500;
root=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(root,'results','nprach-calibration.mat'));
end

function options=developmentController(prediction)
schema=nbiot.dataset.featureSchema();
featureNames=schema.observationNames(5:end);
keyNames=schema.observationNames(1:4);
featureCount=numel(featureNames);
bundle=struct('formatVersion','load-model-bundle-v1', ...
    'modelName','linearRegression','model',FixedRegressionPredictor(prediction), ...
    'schemaVersion',schema.version,'featureNames',{featureNames}, ...
    'keyNames',{keyNames},'targetName','meanRaUe', ...
    'transform',struct('median',zeros(1,featureCount),'mean',zeros(1,featureCount), ...
        'scale',ones(1,featureCount)), ...
    'trainingIds',1,'validationIds',2,'testIds',3,'seed',1, ...
    'status','development','dataKind','development-fixture');
options=struct('model',bundle,'allowDevelopmentModel',true);
end

function assertCompleted(result)
if ~strcmp(result.status,'completed')
    error('TestAdaptiveIntegration:SimulationFailure', ...
        'Adaptive run ended as %s: %s',result.status,result.error.message);
end
end
