classdef TestFullAdaptiveChain < matlab.unittest.TestCase
    methods (Test)
        function oneUeDeliversPacketAcrossAdaptiveDecisionAndNextWindow(t)
            cfg=smallAdaptiveConfig();
            options=developmentController(4);
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment(),options);
            simulator.run();
            result=simulator.result();

            if ~strcmp(result.status,'completed')
                error('TestFullAdaptiveChain:SimulationFailure', ...
                    'Adaptive run ended as %s: %s',result.status,result.error.message);
            end

            t.verifyEqual(result.status,'completed');
            t.verifyEqual(result.kpiSummary.created,1);
            t.verifyEqual(result.kpiSummary.delivered,1);
            t.verifyEqual(result.kpiSummary.deliveredPayloadBits,1600);
            t.verifyGreaterThan(result.kpiSummary.raSuccess,0);
            t.verifyGreaterThan(result.kpiSummary.msg3Decoded,0);
            t.verifyEqual(result.kpiSummary.msg3CrcFailures,0);
            t.verifyGreaterThan(result.kpiSummary.dataDecoded,0);
            t.verifyEqual(result.kpiSummary.dataCrcFailures,0);
            t.verifyTrue(all([result.packetLog.ueConfirmed]));
            t.verifyEqual([result.controllerLog.decisionTick],[0 500 1000]);
            t.verifyEqual(result.controllerLog(2).featureWindowEndTick,500);
            t.verifyEqual(result.controllerLog(2).estimateValue,4);
            t.verifyTrue(result.controllerLog(2).applied);
            t.verifyEqual(result.controllerLog(2).appliedAccessProbability,0.5);
            t.verifyEqual(result.runtimeAction.accessProbability,0.5);
            t.verifyEqual(result.dataset.observations.accessProbability,[1;0.5;0.5]);
            t.verifyEqual(result.dataset.observations.endTick,[500;1000;1500]);
            t.verifyEqual(result.kpiSummary.controller.configurationSwitches,1);
            t.verifyTrue(any(strcmp({result.lifecycleLog.kind},'model_loaded')));
            t.verifyTrue(isfield(result,'radioDiagnostics'));

            savedFeatures=jsondecode(result.controllerLog(2).featureValuesJson);
            t.verifyFalse(isfield(savedFeatures,'meanRaUe'));

            outputFolder=tempname;
            t.addTeardown(@() removeFolder(outputFolder));
            resultPath=nbiot.results.saveResult(result,outputFolder);
            t.verifyTrue(isfile(resultPath));
            [savedFolder,stem]=fileparts(resultPath);
            radioFile=fullfile(savedFolder,[stem '_radio.csv']);
            t.verifyTrue(isfile(radioFile));
            saved=load(resultPath,'result');
            t.verifyEqual(saved.result.radioDiagnostics,result.radioDiagnostics);
            t.verifyEqual(saved.result.radioReceptionLog,result.radioReceptionLog);
            t.verifyEqual(saved.result.lifecycleLog,result.lifecycleLog);
        end
    end
end

function cfg=smallAdaptiveConfig()
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=1500;
cfg.cell.radiusM=20;
cfg.cell.indoorFraction=0;
cfg.channel.shadowOutdoorDb=0;
cfg.channel.shadowIndoorDb=0;
cfg.channel.cfoSigmaHz=0;
cfg.channel.syncLimitSeconds=0;
cfg.traffic.kind='burst';
cfg.traffic.packetBytes=200;
cfg.traffic.burstStartTick=0;
cfg.traffic.burstDurationTicks=1;
cfg.policy.name='Adaptive-P';
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

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
