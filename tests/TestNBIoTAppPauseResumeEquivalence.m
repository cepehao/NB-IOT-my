classdef TestNBIoTAppPauseResumeEquivalence < matlab.unittest.TestCase
    methods (Test)
        function pausingAndResumingUiPreservesCliResult(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',5000);
            setField(app.Figure,'radiusM',20);
            setField(app.Figure,'indoorFraction',0);
            setField(app.Figure,'shadowOutdoorDb',0);
            setField(app.Figure,'shadowIndoorDb',0);
            setField(app.Figure,'cfoSigmaHz',0);
            setField(app.Figure,'syncLimitSeconds',0);
            setField(app.Figure,'trafficKind','burst');
            setField(app.Figure,'burstStartTick',0);
            setField(app.Figure,'burstDurationTicks',1);

            trigger(app.Figure,'Запуск');
            started=tic;
            state=app.Session.snapshot();
            while strcmp(app.Session.Status,'running') && state.tick<100 && toc(started)<30
                drawnow; pause(.01);
                state=app.Session.snapshot();
            end
            t.assertEqual(app.Session.Status,'running');
            beforePause=state;
            t.assertGreaterThanOrEqual(beforePause.tick,100);

            trigger(app.Figure,'Пауза');
            paused=app.Session.snapshot();
            drawnow; pause(.15);
            afterWait=app.Session.snapshot();
            t.verifyEqual(app.Session.Status,'paused');
            t.verifyEqual(afterWait.tick,paused.tick);

            trigger(app.Figure,'Продолжить');
            while strcmp(app.Session.Status,'running') && toc(started)<120
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            uiResult=app.Session.getResult();
            t.verifyEqual(uiResult.kpiSummary.delivered,1);
            t.verifyEqual(uiResult.kpiSummary.deliveredPayloadBits,1600);
            t.verifyTrue(isfield(uiResult,'radioDiagnostics'));
            t.verifyTrue(isfield(uiResult,'radioReceptionLog'));
            state=app.Session.snapshot();
            t.verifyEqual(state.ueDetails(1).radioSummary.status,'available');
            t.verifyEqual(state.ueDetails(1).radioSummary.perAttempt, ...
                uiResult.radioDiagnostics.perAttempt([uiResult.radioDiagnostics.perAttempt.ueId]==1));
            table=findall(app.Figure,'Tag','deviceTable');
            feval(table.CellSelectionCallback,table,struct('Indices',[1 1]));
            details=findall(app.Figure,'Tag','selectedUeDetails');
            detailText=strjoin(string(details.Value),newline);
            t.verifyTrue(contains(detailText,'Опорный SNR UL/DL:'));
            t.verifyTrue(contains(detailText,'Диагностический SINR NPRACH'));
            summary=findall(app.Figure,'Tag','runSummary');
            summaryText=strjoin(string(summary.Value),newline);
            t.verifyTrue(contains(summaryText,'Столкновения NPRACH:'));
            outputFolder=tempname;
            t.addTeardown(@() removeFolder(outputFolder));
            resultPath=app.Session.save(outputFolder);
            t.verifyTrue(isfile(resultPath));
            [savedFolder,stem]=fileparts(resultPath);
            t.verifyTrue(isfile(fullfile(savedFolder,[stem '_radio.csv'])));
            screenshotPath=fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                'verification','local','gui-radio-diagnostics-preview-20261014.png');
            drawnow;
            exportapp(app.Figure,screenshotPath);
            t.verifyTrue(isfile(screenshotPath));
            radioLog=findall(app.Figure,'Tag','radioEventLog');
            t.assertEqual(numel(radioLog),1);
            radioText=strjoin(string(radioLog.Value),newline);
            t.verifyTrue(contains(radioText,'Выдано разрешение')||contains(radioText,'Приём'), ...
                char(radioText));
            t.verifyFalse(contains(radioText,'packet_delivered'));
            t.verifyFalse(contains(radioText,'transmission'));

            cliResult=nbiot.runExperiment(uiResult.config,[],localDevelopment());
            fields={'config','scenario','status','stopReason','actualTick','randomness', ...
                'packetLog','raLog','observedLog','truthLog','phyLog','kpiSummary', ...
                'kpiTimeSeries','ueSummary','resourceUsage','harqLog', ...
                'harqLogSchemaVersion','radioDiagnostics','radioReceptionLog', ...
                'queueSamples','dataset'};
            for k=1:numel(fields)
                name=fields{k};
                t.verifyEqual(uiResult.(name),cliResult.(name), ...
                    ['UI and CLI differ in ' name]);
            end
            uiLifecycleKinds={uiResult.lifecycleLog.kind};
            cliLifecycleKinds={cliResult.lifecycleLog.kind};
            t.verifyEqual(uiLifecycleKinds,cliLifecycleKinds);
            t.verifyEqual(sum(strcmp(uiLifecycleKinds,'simulation_started')),1);
            t.verifyEqual(sum(strcmp(uiLifecycleKinds,'simulation_completed')),1);
        end
    end
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
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
