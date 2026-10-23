classdef TestResultMetadata < matlab.unittest.TestCase
    methods (Test)
        function staticResultRecordsTheOverallNetworkBand(t)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=1;
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());

            result=simulator.result();

            t.verifyEqual(result.network.carrierFrequencyHz,cfg.channel.carrierHz);
            t.verifyEqual(result.network.bandwidthHz,180000);
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            path=nbiot.results.saveResult(result,folder);
            saved=load(path,'result');
            t.verifyEqual(saved.result.network,result.network);
            summaryPath=fullfile(folder,'static-v1_n1_r0000_summary.csv');
            t.verifyTrue(isfile(summaryPath));
            summary=readtable(summaryPath,'VariableNamingRule','preserve');
            t.verifyEqual(height(summary),1);
            t.verifyEqual(string(summary.method),"Static");
            t.verifyEqual(summary.numUE,1);
            t.verifyTrue(ismember('kpi_created',summary.Properties.VariableNames));
        end

        function adaptiveResultCarriesModelScoresOnlyForItsVerifiedPackage(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            trainingOptions=mlTrainingDefaults();
            trainingOptions.seed=17;
            trainingOptions.outputFolder=fullfile(folder,'training');
            trainingOptions.forestNumTrees=2;
            trainingOptions.boostNumLearningCycles=2;
            data=smallLoadTrainingFixture();
            [bundles,trainingReport]=nbiot.ml.trainLoadModels(data,trainingOptions);
            modelIndex=find(strcmp({bundles.name},'linearRegression'),1);
            t.assertNotEmpty(modelIndex);
            modelFile=bundles(modelIndex).file;
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=1;
            cfg.policy.name='Adaptive-P';
            options=struct('model',modelFile,'allowDevelopmentModel',true);
            simulator=nbiot.NBIoTSimulator( ...
                cfg,[],localDevelopment(),options);

            result=simulator.result();
            schema=nbiot.dataset.featureSchema();
            expectedMetrics=trainingReport.metrics( ...
                string(trainingReport.metrics.model)=="linearRegression", ...
                {'split','sampleCount','idCount','mae','rmse'});

            t.verifyEqual(trainingReport.phase,'evaluated');
            t.verifyEqual(result.controllerModel.modelName,'linearRegression');
            t.verifyEqual(result.controllerModel.targetName,'meanRaUe');
            t.verifyEqual(result.controllerModel.featureNames,schema.observationNames(5:end));
            t.verifyEqual(result.controllerModel.seed,17);
            t.verifyEqual(result.controllerModel.sha256,nbiot.ml.fileSha256(modelFile));
            actualMetrics=result.controllerModel.evaluationMetrics;
            t.verifyEqual(string(result.controllerModel.evaluationMetrics.split), ...
                ["train";"validation";"test"]);
            t.verifyEqual(actualMetrics.sampleCount,expectedMetrics.sampleCount);
            t.verifyEqual(actualMetrics.idCount,expectedMetrics.idCount);
            t.verifyEqual(actualMetrics.mae,expectedMetrics.mae,'AbsTol',1e-12);
            t.verifyEqual(actualMetrics.rmse,expectedMetrics.rmse,'AbsTol',1e-12);
            t.verifyEqual(result.controllerModel.evaluationStatus,'verified');
            outputFolder=tempname; mkdir(outputFolder);
            t.addTeardown(@() removeFolder(outputFolder));
            path=nbiot.results.saveResult(result,outputFolder);
            saved=load(path,'result');
            t.verifyEqual(saved.result.controllerModel.evaluationMetrics, ...
                result.controllerModel.evaluationMetrics);
            t.verifyEqual(saved.result.controllerModel.sha256, ...
                result.controllerModel.sha256);
        end

        function staticAndUnscoredRunsDeclareModelEvaluationUnavailable(t)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=1;
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());

            result=simulator.result();

            t.verifyEqual(result.controllerModel.evaluationStatus,'not-applicable');
            t.verifyEmpty(result.controllerModel.evaluationMetrics);
        end

        function manifestedCaseIncludesVerifiedReportMetadata(t)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=1;
            cfg.traffic.kind='none';
            simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());
            result=simulator.result();
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            metadata=nbiot.experiments.runtimeManifest(cfg,struct());

            nbiot.results.saveResult(result,folder,metadata);

            marker=jsondecode(fileread(fullfile(folder,'case-complete.json')));
            reportPath=fullfile(folder,'static-v1_n1_r0000_report.json');
            t.verifyEqual(marker.tableExportVersion,6);
            t.verifyEqual(marker.reportMetadataFile,'static-v1_n1_r0000_report.json');
            t.verifyTrue(isfile(reportPath));
            t.verifyTrue(any(strcmp({marker.files.name},'static-v1_n1_r0000_report.json')));
            reportJson=jsondecode(fileread(reportPath));
            t.verifyEqual(reportJson.caseKey,metadata.caseKey);
            t.verifyEqual(reportJson.canonicalConfigSha256,metadata.canonicalConfigSha256);
            t.verifyTrue(any(strcmp({marker.files.name},reportJson.files.kpi.name)));
            savedSchema=load(fullfile(folder,marker.resultFile),'resultSchemaVersion');
            t.verifyEqual(savedSchema.resultSchemaVersion,metadata.resultSchemaVersion);
            view=nbiot.ui.loadReportMetadata( ...
                fullfile(folder,'static-v1_n1_r0000_kpi.csv'));
            t.verifyEqual(view.status,'verified');
            t.verifyEqual(view.caseKey,metadata.caseKey);
            accepted=nbiot.results.verifyCase(folder);
            t.verifyTrue(accepted.passed);

            markerWithoutSidecar=marker;
            markerWithoutSidecar.files=marker.files(~strcmp( ...
                {marker.files.name},marker.reportMetadataFile));
            writeJson(fullfile(folder,'case-complete.json'),markerWithoutSidecar);
            excluded=nbiot.results.verifyCase(folder);
            t.verifyFalse(excluded.passed);

            writeJson(fullfile(folder,'case-complete.json'),marker);
            delete(reportPath);
            missing=nbiot.results.verifyCase(folder);
            t.verifyFalse(missing.passed);

            tamperedFolder=tempname; mkdir(tamperedFolder);
            t.addTeardown(@() removeFolder(tamperedFolder));
            nbiot.results.saveResult(result,tamperedFolder,metadata);
            tamperedPath=fullfile(tamperedFolder,'static-v1_n1_r0000_report.json');
            fid=fopen(tamperedPath,'ab'); fwrite(fid,uint8('changed'),'uint8'); fclose(fid);
            tampered=nbiot.results.verifyCase(tamperedFolder);
            t.verifyFalse(tampered.passed);
        end
    end
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value),'UTF-8'),'uint8');
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
