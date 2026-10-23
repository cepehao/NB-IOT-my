classdef TestNBIoTAppAdaptive < matlab.unittest.TestCase
    methods (Test)
        function modeChoicesKeepOnlySupportedControlsEditable(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));

            mode=findall(app.Figure,'Tag','simulationMode');
            access=findall(app.Figure,'Tag','accessProbability');
            share=findall(app.Figure,'Tag','raShare');
            adaptiveStart=findall(app.Figure,'Tag','adaptiveStartProbability');
            adaptiveRaStart=findall(app.Figure,'Tag','adaptiveStartRaShare');
            pMin=findall(app.Figure,'Tag','allowedPMin');
            pMax=findall(app.Figure,'Tag','allowedPMax');
            allowedShares=findall(app.Figure,'Tag','allowedRaShares');
            channelModel=findall(app.Figure,'Tag','channelModelInfo');
            t.assertEqual(numel(mode),1);
            t.assertEqual(numel(access),1);
            t.assertEqual(numel(share),1);
            t.assertEqual(numel(adaptiveStart),1);
            t.assertEqual(numel(adaptiveRaStart),1);
            t.assertEqual(numel(pMin),1);
            t.assertEqual(numel(pMax),1);
            t.assertEqual(numel(allowedShares),1);
            t.assertEqual(numel(channelModel),1);
            t.verifyTrue(contains(channelModel.Text,'static-v1'));
            t.verifyEqual(mode.Items,{'Static','Adaptive-P','Adaptive-RA/DT'});
            t.verifyEqual(mode.Value,'Static');

            mode.Value='Adaptive-P';
            feval(mode.ValueChangedFcn,mode,[]);
            t.verifyEqual(share.Value,0.1);
            t.verifyEqual(string(share.Enable),"off");
            t.verifyEqual(string(access.Enable),"off");
            t.verifyEqual(string(adaptiveStart.Enable),"on");
            t.verifyEqual(string(pMin.Enable),"on");
            t.verifyEqual(string(pMax.Enable),"on");
            t.verifyEqual(string(allowedShares.Enable),"off");
            t.verifyEqual(string(adaptiveRaStart.Enable),"off");

            mode.Value='Adaptive-RA/DT';
            feval(mode.ValueChangedFcn,mode,[]);
            t.verifyEqual(access.Value,1);
            t.verifyEqual(string(access.Enable),"off");
            t.verifyEqual(string(share.Enable),"off");
            t.verifyEqual(share.ItemsData,[0.1 0.2 0.3]);
            t.verifyEqual(string(adaptiveRaStart.Enable),"on");
            t.verifyEqual(string(adaptiveStart.Enable),"off");
            t.verifyEqual(string(pMin.Enable),"off");
            t.verifyEqual(string(pMax.Enable),"off");
            t.verifyEqual(string(allowedShares.Enable),"on");
        end

        function adaptiveRunNeedsACompatibleModelAndExplicitDevelopmentOptIn(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            badFile=fullfile(folder,'bad.mat');
            save(badFile,'folder');
            spy=DialogSpy();
            dialogs=struct('chooseModelFile',@() deal('bad.mat',folder), ...
                'showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Выбрать модель');
            modelStatus=findall(app.Figure,'Tag','modelStatus');
            t.verifyTrue(contains(modelStatus.Text,'не подходит'));
            t.verifyEqual(spy.LastTitle,'Модель не подходит');

            mode=findall(app.Figure,'Tag','simulationMode');
            mode.Value='Adaptive-P';
            feval(mode.ValueChangedFcn,mode,[]);
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');
            trigger(app.Figure,'Запуск');
            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(spy.LastMessage,'модель'));

            writeDevelopmentModel(folder);
            devDialogs=struct('chooseModelFile',@() deal('fixture.mat',folder), ...
                'showAlert',@(message,title) spy.capture(message,title));
            devApp=openNBIoTApp(devDialogs);
            t.addTeardown(@() closeApp(devApp));
            trigger(devApp.Figure,'Выбрать модель');
            devMode=findall(devApp.Figure,'Tag','simulationMode');
            devMode.Value='Adaptive-P';
            feval(devMode.ValueChangedFcn,devMode,[]);
            setField(devApp.Figure,'numUE',1);
            setField(devApp.Figure,'durationTicks',1000);
            setField(devApp.Figure,'trafficKind','none');
            trigger(devApp.Figure,'Запуск');
            t.verifyEqual(devApp.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(spy.LastMessage,'отладки'));
        end

        function explicitlyApprovedDevelopmentModelRunsInAdaptiveUi(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeDevelopmentModel(folder);
            dialogs=struct('chooseModelFile',@() deal('fixture.mat',folder));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Выбрать модель');
            modelStatus=findall(app.Figure,'Tag','modelStatus');
            t.verifyTrue(contains(modelStatus.Text,'development'));
            mode=findall(app.Figure,'Tag','simulationMode');
            mode.Value='Adaptive-P';
            feval(mode.ValueChangedFcn,mode,[]);
            setField(app.Figure,'adaptiveStartProbability',0.5);
            setField(app.Figure,'allowedPMin',0.25);
            setField(app.Figure,'allowedPMax',0.75);
            setField(app.Figure,'allowDevelopmentModel',true);
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');

            trigger(app.Figure,'Запуск');
            started=tic;
            while strcmp(app.Session.Status,'running') && toc(started)<120
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            result=app.Session.getResult();
            t.verifyEqual(result.config.policy.name,'Adaptive-P');
            t.verifyEqual([result.controllerLog.decisionTick],[0 500]);
            t.verifyEqual(result.controllerPolicy.accessProbabilityLevels,[0.75 0.5 0.25]);
            t.verifyEqual(result.controllerPolicy.accessLoadThresholds,[3 6]);
            t.verifyEqual(result.config.policy.accessProbability,0.5);
            t.verifyEqual(result.controllerModel.status,'development');
            runSummary=findall(app.Figure,'Tag','runSummary');
            t.verifyTrue(any(contains(string(runSummary.Value),'UE: всего 1')));
            summaryItems=string(runSummary.Value);
            t.verifyTrue(contains(summaryItems(1),'CRC Msg3'));
            t.verifyTrue(contains(summaryItems(1),'CRC Data'));
            t.verifyTrue(contains(summaryItems(2),'UE: всего 1'));
            % Строка пакетов присутствует; её позиция зависит от состава сводки.
            t.verifyTrue(any(contains(summaryItems,'Пакеты:')));
            t.verifyTrue(contains(findall(app.Figure,'Tag','controllerChartInfo').Text, ...
                'DEVELOPMENT'));
        end

        function adaptiveResourceUiPassesTheSelectedShareSet(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeDevelopmentModel(folder);
            dialogs=struct('chooseModelFile',@() deal('fixture.mat',folder));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Выбрать модель');
            mode=findall(app.Figure,'Tag','simulationMode');
            mode.Value='Adaptive-RA/DT';
            feval(mode.ValueChangedFcn,mode,[]);
            setField(app.Figure,'allowDevelopmentModel',true);
            setField(app.Figure,'allowedRaShares',[0.1 0.3]);
            setField(app.Figure,'adaptiveStartRaShare',0.3);
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');

            trigger(app.Figure,'Запуск');
            started=tic;
            while strcmp(app.Session.Status,'running') && toc(started)<120
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            result=app.Session.getResult();
            t.verifyEqual(result.controllerPolicy.raShareLevels,[0.1 0.3]);
            t.verifyEqual(result.controllerPolicy.raLoadThresholds,5);
            t.verifyEqual(result.config.policy.raShare,0.3);
        end
    end
end

function path=writeDevelopmentModel(folder)
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'tests'));
schema=nbiot.dataset.featureSchema();
featureNames=schema.observationNames(5:end);
keyNames=schema.observationNames(1:4);
featureCount=numel(featureNames);
bundle=struct('formatVersion','load-model-bundle-v1', ...
    'modelName','linearRegression','model',FixedRegressionPredictor(4), ...
    'schemaVersion',schema.version,'featureNames',{featureNames}, ...
    'keyNames',{keyNames},'targetName','meanRaUe', ...
    'transform',struct('median',zeros(1,featureCount), ...
        'mean',zeros(1,featureCount),'scale',ones(1,featureCount)), ...
    'trainingIds',1,'validationIds',2,'testIds',3,'seed',1, ...
    'status','development','dataKind','development-fixture');
path=fullfile(folder,'fixture.mat');
save(path,'bundle');
manifest=struct('artifactFile','fixture.mat', ...
    'artifactSha256',nbiot.ml.fileSha256(path), ...
    'formatVersion',bundle.formatVersion,'modelName',bundle.modelName, ...
    'schemaVersion',bundle.schemaVersion,'targetName',bundle.targetName, ...
    'featureNames',{bundle.featureNames},'keyNames',{bundle.keyNames}, ...
    'seed',bundle.seed,'status',bundle.status,'trainingIds',bundle.trainingIds, ...
    'validationIds',bundle.validationIds,'testIds',bundle.testIds);
fid=fopen(fullfile(folder,'fixture.json'),'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(manifest),'UTF-8'),'uint8');
end

function setField(fig,tag,value)
control=findall(fig,'Tag',tag);
assert(isscalar(control),['Expected one UI field tagged ' tag]);
control.Value=value;
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
