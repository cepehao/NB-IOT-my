classdef TestExternalGuiProfile < matlab.unittest.TestCase
    methods (Test)
        function defaultSessionUsesLocalDevelopmentBudget(t)
            [factory,readCapture]=recordingFactory();
            session=nbiot.ui.SimulationSession([],factory);
            cfg=guiConfig(2);

            session.start(cfg);
            captured=readCapture();

            t.verifyEqual(captured.calls,1);
            t.verifyEqual(captured.cfg.simulation.numUE,2);
            t.verifyEqual(captured.execution.profile,'local-development');
            t.verifyEqual(captured.execution.role,'development');
            t.verifyEqual(captured.execution.maxUE,10);
            t.verifyEqual(captured.controllerOptions,struct());
            t.verifyEqual(session.Status,'running');
            % The recording factory returns an inert value; no simulation is advanced.
        end

        function defaultLocalProfileRejectsElevenBeforeFactory(t)
            [factory,readCapture]=recordingFactory();
            session=nbiot.ui.SimulationSession([],factory);
            cfg=guiConfig(11);

            t.verifyError(@() session.start(cfg), ...
                'nbiot:experiments:ExecutionBudget');

            captured=readCapture();
            t.verifyEqual(captured.calls,0, ...
                'The local UE limit must be checked before factory construction.');
            t.verifyEqual(session.Status,'idle');
        end

        function explicitExternalBudgetIsForwardedWithoutRunning(t)
            [factory,readCapture]=recordingFactory();
            execution=externalBudget(12);
            session=nbiot.ui.SimulationSession(execution,factory);
            cfg=guiConfig(11);
            policy=nbiot.controller.buildAdaptivePolicy('Adaptive-P',[0.25 0.75],[]);
            controllerOptions=struct('model','development-model-fixture', ...
                'allowDevelopmentModel',false,'policy',policy, ...
                'modelAcceptanceFile','acceptance-package/acceptance.json');

            session.start(cfg,controllerOptions);
            captured=readCapture();

            t.verifyEqual(captured.calls,1);
            t.verifyEqual(captured.cfg.simulation.numUE,11, ...
                'Eleven-UE config is only passed to the inert fake factory.');
            t.verifyEqual(captured.execution,execution);
            t.verifyEqual(captured.controllerOptions,controllerOptions);
            t.verifyEqual(session.Status,'running');
            % No advance/result call is made; the fake factory never constructs a simulator.
        end

        function uiSessionRejectsIncompleteExternalBudgetBeforeFactory(t)
            [factory,readCapture]=recordingFactory();
            execution=struct('profile','external-machine','role','final-comparison', ...
                'maxUE',2,'maxCaseSeconds',300);
            session=nbiot.ui.SimulationSession(execution,factory);

            t.verifyError(@() session.start(guiConfig(1)), ...
                'nbiot:experiments:ExecutionBudget');

            captured=readCapture();
            t.verifyEqual(captured.calls,0, ...
                'A missing external suite budget must be rejected before simulator construction.');
            t.verifyEqual(session.Status,'idle');
        end

        function dialogSignaturesKeepDefaultAndExternalUeLimits(t)
            addAppPath(t);
            spy=DialogSpy();
            dialogs=dialogAdapters(spy);
            directApp=NBIoTApp(dialogs);
            t.addTeardown(@() closeApp(directApp));
            launcherApp=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(launcherApp));
            directEmptyOptionsApp=NBIoTApp(dialogs,struct());
            t.addTeardown(@() closeApp(directEmptyOptionsApp));
            launcherEmptyOptionsApp=openNBIoTApp(dialogs,struct());
            t.addTeardown(@() closeApp(launcherEmptyOptionsApp));

            t.verifyTrue(isvalid(directApp.Figure));
            t.verifyTrue(isvalid(launcherApp.Figure));
            t.verifyTrue(isvalid(directEmptyOptionsApp.Figure));
            t.verifyTrue(isvalid(launcherEmptyOptionsApp.Figure));
            t.verifyEqual(directApp.Session.Status,'idle');
            t.verifyEqual(launcherApp.Session.Status,'idle');
            t.verifyEqual(directEmptyOptionsApp.Session.Status,'idle');
            t.verifyEqual(launcherEmptyOptionsApp.Session.Status,'idle');
            verifyUeLimits(t,directApp.Figure,[1 10]);
            verifyUeLimits(t,launcherApp.Figure,[1 10]);
            verifyUeLimits(t,directEmptyOptionsApp.Figure,[1 10]);
            verifyUeLimits(t,launcherEmptyOptionsApp.Figure,[1 10]);
            verifyActivityControls(t,directApp.Figure);
            verifyActivityControls(t,launcherApp.Figure);

            externalOptions=struct('execution',externalBudget(12));
            externalApp=NBIoTApp(dialogs,externalOptions);
            t.addTeardown(@() closeApp(externalApp));
            t.verifyEqual(externalApp.Session.Status,'idle');
            verifyUeLimits(t,externalApp.Figure,[1 12]);
        end

        function explicitExecutionOptionsReachBothUiPolicyPreflights(t)
            addAppPath(t);
            execution=externalPreflightBudget();
            options=struct('execution',execution);

            directSpy=DialogSpy();
            directApp=NBIoTApp(dialogAdapters(directSpy),options);
            t.addTeardown(@() closeApp(directApp));
            directApp.Timer.Period=3600;
            configureTwoUePreflight(directApp.Figure,'2, 1');
            trigger(directApp.Figure,'Запуск');
            assertExternalPolicyRejectedBeforeSimulator(t,directApp,directSpy);

            activeIds=findall(directApp.Figure,'Tag','activeUeIds');
            t.assertEqual(numel(activeIds),1);
            activeIds.Value='1+1';
            trigger(directApp.Figure,'Запуск');
            t.verifyEqual(directApp.Session.Status,'idle');
            t.verifyFalse(directApp.Session.hasResult());
            t.verifyEqual(directSpy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(lower(directSpy.LastMessage),'чис') || ...
                contains(lower(directSpy.LastMessage),'ue') || ...
                contains(lower(directSpy.LastMessage),'id'), ...
                'Expression-like ID text must be rejected by numeric parsing.');
            t.verifyFalse(contains(lower(directSpy.LastMessage),'hard-stop'), ...
                'Expression-like ID text must not reach external policy validation.');

            launcherSpy=DialogSpy();
            launcherApp=openNBIoTApp(dialogAdapters(launcherSpy),options);
            t.addTeardown(@() closeApp(launcherApp));
            launcherApp.Timer.Period=3600;
            configureTwoUePreflight(launcherApp.Figure,'2, 1');
            trigger(launcherApp.Figure,'Запуск');
            assertExternalPolicyRejectedBeforeSimulator(t,launcherApp,launcherSpy);
        end

        function commaListReachesUiFactoryAsSortedActiveIds(t)
            addAppPath(t);
            [factory,readCapture]=recordingFactory();
            spy=DialogSpy();
            execution=externalBudget(2);
            options=struct('execution',execution,'simulatorFactory',factory);
            app=NBIoTApp(dialogAdapters(spy),options);
            t.addTeardown(@() closeApp(app));
            app.Timer.Period=3600;
            configureTwoUePreflight(app.Figure,'2, 1');

            trigger(app.Figure,'Запуск');
            if isvalid(app.Timer)&&strcmp(app.Timer.Running,'on'), stop(app.Timer); end

            captured=readCapture();
            t.verifyEqual(captured.calls,1, ...
                'Start must construct the supplied inert factory exactly once.');
            t.verifyEqual(captured.execution,execution);
            t.verifyEqual(captured.cfg.simulation.numUE,2);
            t.verifyEqual(captured.cfg.simulation.durationTicks,10);
            t.verifyEqual(captured.cfg.traffic.kind,'none');
            t.verifyEqual(captured.cfg.traffic.activityMode,'explicit');
            t.verifyEqual(captured.cfg.traffic.activeUeIds,[1 2], ...
                'The comma-list must arrive normalized at the simulator factory.');
            t.verifyEqual(app.Session.Config.traffic.activeUeIds,[1 2]);
            t.verifyEqual(app.Session.Status,'running');
            t.verifyFalse(app.Session.hasResult());
            t.verifyEqual(app.Timer.Running,'off', ...
                'The timer is stopped before any advance can occur.');
        end

        function explicitGroupPersistsThroughShortUiResultAndExport(t)
            parent=tempname; mkdir(parent);
            t.addTeardown(@() removeFolder(parent));
            spy=DialogSpy();
            app=openNBIoTApp(dialogAdapters(spy));
            t.addTeardown(@() closeApp(app));
            verifyActivityControls(t,app.Figure);

            setField(app.Figure,'numUE',2);
            setField(app.Figure,'durationTicks',10);
            setField(app.Figure,'trafficKind','none');
            setField(app.Figure,'activityMode','explicit');
            setField(app.Figure,'activeUeIds','2');
            trigger(app.Figure,'Запуск');
            started=tic;
            while strcmp(app.Session.Status,'running') && toc(started)<30
                drawnow; pause(.01);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            t.verifyEqual(app.Session.Config.simulation.numUE,2);
            t.verifyEqual(app.Session.Config.simulation.durationTicks,10);
            t.verifyEqual(app.Session.Config.traffic.activityMode,'explicit');
            t.verifyEqual(app.Session.Config.traffic.activeUeIds,2);

            result=app.Session.getResult();
            t.verifyEqual(result.config.traffic.activityMode,'explicit');
            t.verifyEqual(result.config.traffic.activeUeIds,2);

            runSummary=findall(app.Figure,'Tag','runSummary');
            t.assertEqual(numel(runSummary),1);
            summaryLines=string(runSummary.Value);
            t.verifyTrue(any(contains(summaryLines,'UE: всего 2')), ...
                'The display must show the total UE count.');
            t.verifyTrue(any(summaryLines=="Активная группа: 1 UE"), ...
                'The selected group count must have its own exact label and value.');

            resultPath=app.Session.save(fullfile(parent,'active-group-result'));
            saved=load(resultPath,'result');
            t.verifyEqual(saved.result.config.traffic.activityMode,'explicit');
            t.verifyEqual(saved.result.config.traffic.activeUeIds,2);
            t.verifyEqual(spy.LastMessage,'');
        end

        function externalAdaptiveRemainsClosedWithoutOrWithForeignAcceptance(t)
            cfg=adaptiveGuiConfig();
            execution=externalBudget(2);
            developmentOptions=developmentModelBundle();
            localExecution=nbiot.experiments.validateExecutionBudget(cfg);
            validRuntime=nbiot.controller.prepareRuntime( ...
                cfg,localExecution,developmentOptions);
            foreignOptions=developmentOptions;
            % Opaque untrusted placeholder: no D4 acceptance-validator API is assumed here.
            foreignOptions.modelAcceptance=struct('accepted',true, ...
                'modelHash','a-different-model');
            t.verifyTrue(validRuntime.enabled, ...
                'The development fixture must remain valid in local development.');
            t.verifyEqual(validRuntime.bundle.status,'development');
            t.verifyError(@() nbiot.controller.prepareRuntime( ...
                cfg,execution,developmentOptions), ...
                'nbiot:ml:ModelAcceptance', ...
                'External Adaptive without model acceptance must fail closed.');

            t.verifyError(@() nbiot.controller.prepareRuntime( ...
                cfg,execution,foreignOptions), ...
                'nbiot:controller:Options', ...
                'An unsupported foreign marker must not enable Adaptive.');
        end

        function externalAdaptiveReachesPersistedAdmissionWithoutDevelopmentOptIn(t)
            addAppPath(t);
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            modelFile=writeGuiModelPackage(folder);
            acceptanceFile=fullfile(folder,'acceptance.json');
            acceptance=struct('trainingIds',11,'validationIds',12,'testIds',13, ...
                'policyTuningIds',[],'scope',struct('methods',{{'Adaptive-P'}}, ...
                'numUE',2,'trafficKinds',{{'burst'}},'burstDurationTicks',100, ...
                'windowTicks',500));
            writeGuiText(acceptanceFile,jsonencode(acceptance));
            bundle=nbiot.ml.validateModelBundle(modelFile);
            t.verifyEqual(bundle.dataKind,'development-fixture');

            [factory,readCapture]=recordingFactory();
            spy=DialogSpy();
            execution=externalBudget(2); execution.role='final-comparison';
            policy=nbiot.controller.buildAdaptivePolicy('Adaptive-P',[0.25 0.75],[]);
            options=struct('execution',execution,'simulatorFactory',factory, ...
                'modelFile',modelFile,'modelAcceptanceFile',acceptanceFile, ...
                'controllerPolicy',policy);
            app=NBIoTApp(dialogAdapters(spy),options);
            t.addTeardown(@() closeApp(app));
            app.Timer.Period=3600;
            mode=findall(app.Figure,'Tag','simulationMode');
            t.assertEqual(numel(mode),1);
            mode.Value='Adaptive-P';
            feval(mode.ValueChangedFcn,mode,[]);
            developmentOptIn=findall(app.Figure,'Tag','allowDevelopmentModel');
            t.assertEqual(numel(developmentOptIn),1);
            t.verifyTrue(strcmp(developmentOptIn.Enable,'off'), ...
                'External Adaptive cannot be enabled by the development-only opt-in.');

            trigger(app.Figure,'Запуск');

            captured=readCapture();
            t.verifyEqual(captured.calls,0, ...
                'The incomplete fixture acceptance must fail before simulator construction.');
            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(lower(spy.LastMessage), ...
                'acceptance source or calibration identity is incomplete'), ...
                'The GUI must pass its normalized external budget through admission before failing closed on missing evidence.');
            t.verifyFalse(contains(lower(spy.LastMessage),'разрешение только для отладки'), ...
                'The local development opt-in must not intercept external admission.');
        end
    end
end

function [factory,readCapture]=recordingFactory()
capture=struct('calls',0,'cfg',[],'scenario',[],'execution',struct(), ...
    'controllerOptions',struct());
factory=@record;
readCapture=@read;

    function simulator=record(cfg,scenario,execution,controllerOptions)
        capture.calls=capture.calls+1;
        capture.cfg=cfg;
        capture.scenario=scenario;
        capture.execution=execution;
        capture.controllerOptions=controllerOptions;
        simulator=[];
    end

    function value=read()
        value=capture;
    end
end

function cfg=guiConfig(numUE)
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=numUE;
cfg.simulation.durationTicks=10;
cfg.traffic.kind='none';
cfg.phy.nprachThreshold=0.5;
end

function execution=externalBudget(maxUE)
execution=struct('profile','external-machine','role','u2-fake-factory', ...
    'maxUE',maxUE,'maxCaseSeconds',300,'maxSuiteSeconds',900, ...
    'timePolicy','hard-stop');
end

function execution=externalPreflightBudget()
execution=externalBudget(2);
execution.timePolicy='finish-current';
end

function dialogs=dialogAdapters(spy)
dialogs=struct('showAlert',@(message,title) spy.capture(message,title));
end

function addAppPath(test)
root=fileparts(fileparts(mfilename('fullpath')));
oldPath=path;
addpath(fullfile(root,'apps'));
test.addTeardown(@() path(oldPath));
end

function verifyActivityControls(test,fig)
mode=findall(fig,'Tag','activityMode');
activeIds=findall(fig,'Tag','activeUeIds');
test.assertEqual(numel(mode),1,'Expected one activity-mode selector.');
test.assertEqual(numel(activeIds),1,'Expected one active-UE ID field.');
choices=[string(mode.Items(:));string(mode.ItemsData(:))];
test.verifyTrue(any(choices=="all"),'The activity control must offer all mode.');
test.verifyTrue(any(choices=="explicit"), ...
    'The activity control must offer explicit mode.');
end

function verifyUeLimits(test,fig,expected)
control=findall(fig,'Tag','numUE');
test.assertEqual(numel(control),1,'Expected one UE-count control.');
test.verifyEqual(control.Limits,expected);
end

function configureTwoUePreflight(fig,activeIds)
setField(fig,'numUE',2);
setField(fig,'durationTicks',10);
setField(fig,'trafficKind','none');
setField(fig,'activityMode','explicit');
setField(fig,'activeUeIds',activeIds);
end

function assertExternalPolicyRejectedBeforeSimulator(test,app,spy)
if isvalid(app.Timer)&&strcmp(app.Timer.Running,'on'), stop(app.Timer); end
test.verifyEqual(app.Session.Status,'idle');
test.verifyFalse(app.Session.hasResult(), ...
    'The external policy must reject before simulator construction.');
test.verifyEqual(spy.LastTitle,'Не удалось запустить');
test.verifyTrue(contains(lower(spy.LastMessage),'hard-stop'),spy.LastMessage);
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

function cfg=adaptiveGuiConfig()
cfg=guiConfig(2);
cfg.policy.name='Adaptive-P';
cfg.policy.windowTicks=500;
cfg.dataset.windowTicks=500;
end

function options=developmentModelBundle()
schema=nbiot.dataset.featureSchema();
featureNames=schema.observationNames(5:end);
keyNames=schema.observationNames(1:4);
featureCount=numel(featureNames);
bundle=struct('formatVersion','load-model-bundle-v1', ...
    'modelName','linearRegression','model',FixedRegressionPredictor(1), ...
    'schemaVersion',schema.version,'featureNames',{featureNames}, ...
    'keyNames',{keyNames},'targetName','meanRaUe', ...
    'transform',struct('median',zeros(1,featureCount), ...
        'mean',zeros(1,featureCount),'scale',ones(1,featureCount)), ...
    'trainingIds',1,'validationIds',2,'testIds',3,'seed',1, ...
    'status','development','dataKind','development-fixture');
options=struct('model',bundle,'allowDevelopmentModel',true);
end

function modelFile=writeGuiModelPackage(folder)
options=developmentModelBundle(); bundle=options.model;
modelFile=fullfile(folder,'gui-model.mat');
save(modelFile,'bundle');
manifest=struct();
manifest.formatVersion=bundle.formatVersion;
manifest.modelName=bundle.modelName;
manifest.artifactFile='gui-model.mat';
manifest.artifactSha256=nbiot.ml.fileSha256(modelFile);
manifest.schemaVersion=bundle.schemaVersion;
manifest.targetName=bundle.targetName;
manifest.featureNames=bundle.featureNames;
manifest.keyNames=bundle.keyNames;
manifest.seed=bundle.seed;
manifest.status=bundle.status;
manifest.trainingIds=bundle.trainingIds;
manifest.validationIds=bundle.validationIds;
manifest.testIds=bundle.testIds;
manifest.dataKind=bundle.dataKind;
writeGuiText(fullfile(folder,'gui-model.json'),jsonencode(manifest));
end

function writeGuiText(path,value)
fid=fopen(path,'w');
if fid<0, error('TestExternalGuiProfile:Write','Cannot write GUI test fixture.'); end
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,value,'char');
end
