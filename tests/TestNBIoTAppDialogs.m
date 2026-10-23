classdef TestNBIoTAppDialogs < matlab.unittest.TestCase
    methods (Test)
        function liveRunHasDedicatedSummaryAndEventLog(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            summary=findall(app.Figure,'Tag','runSummary');
            controllerSummary=findall(app.Figure,'Tag','controllerSummary');
            controllerHistory=findall(app.Figure,'Tag','controllerHistory');
            eventLog=findall(app.Figure,'Tag','eventLog');
            radioEventLog=findall(app.Figure,'Tag','radioEventLog');
            t.verifyEqual(numel(summary),1);
            t.verifyEqual(numel(controllerSummary),1);
            t.verifyTrue(contains(controllerSummary.Text,'Static'));
            t.verifyEqual(numel(controllerHistory),1);
            t.verifyEmpty(controllerHistory.Data);
            t.verifyEqual(numel(eventLog),1);
            t.assertEqual(numel(radioEventLog),1);
            t.verifyEqual(radioEventLog.Value,{'Радиособытий пока нет'});
        end

        function journalCanBeOpenedFocusedAndRecreatedAfterClose(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            openButton=findall(app.Figure,'Tag','openRadioJournalButton');
            zeroFilter=findall(app.Figure,'Tag','showZeroDetectionEvents');
            hiddenCount=findall(app.Figure,'Tag','hiddenZeroDetectionCount');
            t.assertEqual(numel(openButton),1);
            t.assertEqual(string(openButton.Text),"Развернуть журнал");
            t.assertEqual(numel(zeroFilter),1);
            t.verifyFalse(zeroFilter.Value);
            t.assertEqual(numel(hiddenCount),1);

            feval(openButton.ButtonPushedFcn,openButton,[]);
            first=findall(groot,'Tag','radioEventJournalFigure');
            t.assertEqual(numel(first),1);
            journalText=findall(first,'Tag','radioEventJournalText');
            t.assertEqual(numel(journalText),1);
            t.verifyEqual(string(journalText.Editable),"off");
            t.verifyEqual(string(journalText.WordWrap),"off");
            t.verifyGreaterThanOrEqual(first.Position(4),600);
            feval(openButton.ButtonPushedFcn,openButton,[]);
            second=findall(groot,'Tag','radioEventJournalFigure');
            t.verifyEqual(numel(second),1);
            t.verifyEqual(second,first);

            close(first);
            t.verifyEmpty(findall(groot,'Tag','radioEventJournalFigure'));
            feval(openButton.ButtonPushedFcn,openButton,[]);
            reopened=findall(groot,'Tag','radioEventJournalFigure');
            t.verifyEqual(numel(reopened),1);
        end

        function configurationAndLiveJournalRemainScrollable(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            numUe=findall(app.Figure,'Tag','numUE');
            radioEvents=findall(app.Figure,'Tag','radioEventLog');
            t.assertEqual(numel(numUe),1);
            t.assertEqual(numel(radioEvents),1);
            t.verifyEqual(string(numUe.Parent.Scrollable),"on");
            t.verifyEqual(string(radioEvents.Parent.Scrollable),"on");
            screen=get(groot,'ScreenSize');
            t.verifyLessThanOrEqual(app.Figure.Position(3),screen(3));
        end

        function requestedSmallDisplayFitsMainAndJournalWindows(t)
            screenWidth=1000; screenHeight=700;
            mainWidth=min(1320,max(1,screenWidth-20));
            mainHeight=min(850,max(1,screenHeight-60));
            journalWidth=min(1080,max(1,screenWidth-40));
            journalHeight=min(700,max(1,screenHeight-80));
            t.verifyEqual([mainWidth mainHeight],[980 640]);
            t.verifyEqual([journalWidth journalHeight],[960 620]);
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            source=fileread(fullfile(projectRoot,'apps','NBIoTApp.m'));
            t.verifyTrue(contains(source, ...
                'windowWidth=min(1320,max(1,screen(3)-20));'));
            t.verifyTrue(contains(source, ...
                'windowHeight=min(850,max(1,screen(4)-60));'));
            t.verifyTrue(contains(source, ...
                'width=min(1080,max(1,screen(3)-40));'));
            t.verifyTrue(contains(source, ...
                'height=min(700,max(1,screen(4)-80));'));
        end

        function metricHelpPanelExplainsDisplayedCounters(t)
            app=openNBIoTApp();
            t.addTeardown(@() closeApp(app));
            toggle=findall(app.Figure,'Tag','metricExplanationsToggle');
            panel=findall(app.Figure,'Tag','metricExplanationsPanel');
            details=findall(app.Figure,'Tag','metricExplanationsText');
            t.assertEqual(numel(toggle),1);
            t.verifyEqual(string(toggle.Text),"Что означают показатели");
            t.assertEqual(numel(panel),1);
            t.assertEqual(numel(details),1);
            t.verifyEqual(string(panel.Visible),"off");

            feval(toggle.ButtonPushedFcn,toggle,[]);
            t.verifyEqual(string(panel.Visible),"on");
            text=strjoin(string(details.Value),newline);
            t.verifyTrue(contains(text,'Создано'),text);
            t.verifyTrue(contains(text,'Доставлено'),text);
            t.verifyTrue(contains(text,'непустой очередью UE'),text);
        end

        function invalidStartIsWrittenToEventLogAndShown(t)
            spy=DialogSpy();
            dialogs=struct('showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'tapDelaysSeconds','not-a-number');
            trigger(app.Figure,'Запуск');

            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(spy.LastMessage,'конечных чисел'));
            eventLog=findall(app.Figure,'Tag','eventLog');
            t.verifyTrue(contains(strjoin(string(eventLog.Value),newline),'Запуск не выполнен'));
        end

        function staticChannelAndRandomAccessFieldsReachSessionConfig(t)
            spy=DialogSpy();
            dialogs=struct('showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            tags={'referenceDistanceM','temperatureK','fractionalFilterLength', ...
                'raPeriodTicks','raStartOffsetTicks','rarPp','contentionPp'};
            for k=1:numel(tags)
                t.assertEqual(numel(findall(app.Figure,'Tag',tags{k})),1, ...
                    ['Missing Static setting: ' tags{k}]);
            end

            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1);
            setField(app.Figure,'trafficKind','none');
            setField(app.Figure,'referenceDistanceM',12.5);
            setField(app.Figure,'temperatureK',300);
            setField(app.Figure,'fractionalFilterLength',65);
            setField(app.Figure,'raPeriodTicks',80);
            setField(app.Figure,'raStartOffsetTicks',10);
            setField(app.Figure,'rarPp',12);
            setField(app.Figure,'contentionPp',20);
            trigger(app.Figure,'Запуск');
            t.assertTrue(any(strcmp(app.Session.Status,{'running','completed'})),spy.LastMessage);
            if strcmp(app.Session.Status,'running'), stop(app.Timer); end

            cfg=app.Session.Config;
            t.verifyEqual(cfg.channel.referenceDistanceM,12.5);
            t.verifyEqual(cfg.channel.temperatureK,300);
            t.verifyEqual(cfg.channel.fractionalFilterLength,65);
            t.verifyEqual(cfg.ra.periodTicks,80);
            t.verifyEqual(cfg.ra.startOffsetTicks,10);
            t.verifyEqual(cfg.ra.rarPp,12);
            t.verifyEqual(cfg.ra.contentionPp,20);
        end

        function calibrationBoundSettingChangeIsExplained(t)
            spy=DialogSpy();
            dialogs=struct('showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',10);
            setField(app.Figure,'trafficKind','none');
            setField(app.Figure,'raPeriodTicks',100);
            trigger(app.Figure,'Запуск');

            t.verifyEqual(app.Session.Status,'idle');
            t.verifyEqual(spy.LastTitle,'Не удалось запустить');
            t.verifyTrue(contains(spy.LastMessage,'recalibrate'),spy.LastMessage);
        end

        function savedKpiPickerComparesSelectedSeries(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            first=table([100;200],[25;50],[0.5;1], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            second=table([100;300],[10;40],[0.2;0.8], ...
                'VariableNames',{'endTick','throughputBitsPerSecond','cohortDeliveryProbability'});
            writetable(first,fullfile(folder,'first_kpi.csv'));
            writetable(second,fullfile(folder,'second_kpi.csv'));
            dialogs=struct('chooseOutputDirectory',@() folder, ...
                'chooseKpiFile',@() deal({'first_kpi.csv','second_kpi.csv'},folder));

            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            app.Figure.Visible='off';
            button=findall(app.Figure,'Tag','savedKpiButton');
            t.assertEqual(numel(button),1);
            feval(button.ButtonPushedFcn,button,[]);

            savedTable=findall(app.Figure,'Tag','savedKpiTable');
            savedAxes=findall(app.Figure,'Tag','savedKpiAxes');
            t.verifyEqual(savedTable.Data,table2cell(first));
            line=findobj(savedAxes,'Type','line');
            t.verifyEqual(numel(line),2);
            firstLine=findobj(savedAxes,'Type','line','DisplayName','first_kpi.csv');
            secondLine=findobj(savedAxes,'Type','line','DisplayName','second_kpi.csv');
            t.verifyEqual(firstLine.XData,[0.1 0.2],'AbsTol',1e-12);
            t.verifyEqual(firstLine.YData,[25 50]);
            t.verifyEqual(secondLine.XData,[0.1 0.3],'AbsTol',1e-12);
            t.verifyEqual(secondLine.YData,[10 40]);

            sizes=[1280 900;1000 700];
            savedAxesPanel=savedAxes.Parent.Parent;
            savedGrid=savedTable.Parent;
            t.verifyEqual(savedAxesPanel.Parent,savedGrid);
            t.verifyEqual(savedAxesPanel.Layout.Row,6);
            t.verifyEqual(string(savedGrid.Scrollable),"on");
            for sizeIndex=1:size(sizes,1)
                app.Figure.Position=[10 10 sizes(sizeIndex,:)];
                drawnow;
                t.verifyEqual(savedAxes.Layout.Row,1, ...
                    'The axes belongs in row 1 of its one-row nested grid.');
                t.verifyEqual(savedAxes.Layout.Column,1);
                % Размеры в пикселях появляются только при реальной раскладке окна; в matlab -batch
                % (без экрана) сетка не раскладывается и высоты равны 0 — там проверяем лишь структуру.
                if batchStartupOptionUsed, continue; end
                t.verifyGreaterThanOrEqual(savedTable.Position(4),140, ...
                    'The saved KPI table must have a usable scrollable viewport.');
                t.verifyGreaterThanOrEqual(savedAxesPanel.Position(4),200, ...
                    sprintf('The saved KPI chart panel is too short: %s', ...
                    mat2str(savedAxesPanel.Position)));
            end
        end

        function saveButtonWritesFilesUnderChosenFolder(t)
            outputFolder=tempname; mkdir(outputFolder);
            t.addTeardown(@() removeFolder(outputFolder));
            dialogs=struct('chooseOutputDirectory',@() outputFolder, ...
                'chooseKpiFile',@() deal(0,0));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',10);
            setField(app.Figure,'trafficKind','none');
            trigger(app.Figure,'Запуск');
            started=tic;
            while strcmp(app.Session.Status,'running') && toc(started)<60
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            runStatus=findall(app.Figure,'Tag','runStatus');
            t.assertEqual(numel(runStatus),1);
            t.verifyTrue(contains(runStatus.Text,'Завершён'),runStatus.Text);
            t.verifyTrue(contains(runStatus.Text,'с модели'),runStatus.Text);
            t.verifyTrue(contains(runStatus.Text,'Реальное время с запуска'),runStatus.Text);

            trigger(app.Figure,'Сохранить');
            t.verifyTrue(isfile(app.Session.SavedPath));
            [resultFolder,stem]=fileparts(app.Session.SavedPath);
            t.verifyTrue(startsWith(resultFolder,outputFolder));
            t.verifyTrue(isfile(fullfile(resultFolder,[stem '_kpi.csv'])));
            result=app.Session.getResult();
            t.verifyEqual(result.status,'completed');
            t.verifyEqual(app.Session.Config.simulation.numUE,1);
            t.verifyEqual(app.Session.Config.simulation.durationTicks,10);
            summary=findall(app.Figure,'Tag','runSummary');
            t.assertEqual(numel(summary),1);
            waitStarted=tic;
            while ~contains(strjoin(string(summary.Value),newline),'RA: попыток') && toc(waitStarted)<5
                drawnow; pause(.01);
            end
            summaryText=strjoin(string(summary.Value),newline);
            t.verifyTrue(contains(summaryText,'RA: попыток'),char(summaryText));
            t.verifyTrue(contains(summaryText,'CRC Msg3'),char(summaryText));
            t.verifyTrue(contains(summaryText,'CRC Data'),char(summaryText));
        end

        function completedSavedRunExportsDevelopmentDataset(t)
            parent=tempname; mkdir(parent);
            t.addTeardown(@() removeFolder(parent));
            spy=DialogSpy();
            openFolderSpy=DialogSpy();
            chartRoot=fullfile(parent,'путь с пробелами'); mkdir(chartRoot);
            chartChoice=containers.Map('KeyType','char','ValueType','any');
            chartChoice('mode')='cancel'; chartChoice('folder')=chartRoot;
            dialogs=struct('chooseOutputDirectory',@() parent, ...
                'chooseDatasetOutputDirectory',@() parent, ...
                'chooseChartOutputDirectory',@() chooseChartFolder(chartChoice), ...
                'openFolder',@(path) openFolderSpy.capture(path,'Открытие папки'), ...
                'chooseKpiFile',@() deal(0,0), ...
                'showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',10);
            setField(app.Figure,'trafficKind','none');
            trigger(app.Figure,'Запуск');
            started=tic;
            while strcmp(app.Session.Status,'running') && toc(started)<60
                drawnow; pause(.02);
            end
            t.assertEqual(app.Session.Status,'completed',app.Session.LastError);
            runSummary=findall(app.Figure,'Tag','runSummary');
            summaryText=strjoin(string(runSummary.Value),newline);
            t.verifyTrue(contains(summaryText,'P95 задержка: —'));
            t.verifyTrue(contains(summaryText, ...
                'тире означает «нет данных»'));
            t.verifyTrue(contains(summaryText,'Занятость UL/DL/NPRACH:'));
            chartTab=findall(app.Figure,'Tag','resultChartsTab');
            chartInfo=findall(app.Figure,'Tag','staticChartInfo');
            activeAxes=findall(app.Figure,'Tag','staticChartActiveUe');
            t.verifyEqual(numel(chartTab),1);
            t.verifyEqual(numel(findall(app.Figure,'-regexp','Tag','^staticChart')),9);
            t.verifyTrue(contains(chartInfo.Text,'Итоговые Static-графики'),chartInfo.Text);
            t.verifyTrue(contains(chartInfo.Text,'500 мс'),chartInfo.Text);
            activeLine=findobj(activeAxes,'Type','line');
            t.assertEqual(numel(activeLine),1);
            t.verifyNotEmpty(activeLine.XData);
            t.verifyTrue(all(activeLine.XData<=.01+1e-12));
            trigger(app.Figure,'Сохранить');

            button=findall(app.Figure,'Tag','savedDatasetButton');
            t.assertEqual(numel(button),1);
            t.assertEqual(string(button.Enable),"on");
            feval(button.ButtonPushedFcn,button,[]);

            outputs=dir(fullfile(parent,'nbiot-dataset-development-*'));
            t.assertEqual(numel(outputs),1);
            output=fullfile(outputs(1).folder,outputs(1).name);
            t.verifyTrue(isfile(fullfile(output,'dataset.mat')));
            t.verifyTrue(isfile(fullfile(output,'manifest.json')));
            saved=load(fullfile(output,'dataset.mat'),'data');
            t.verifyEqual(saved.data.rowInfo.split,"development");
            t.verifyEqual(saved.data.manifest.independentRealizations,1);
            info=findall(app.Figure,'Tag','savedKpiInfo');
            t.verifyTrue(contains(info.Text,'тестовые данные'));
            t.verifyEmpty(spy.LastMessage);

            exportButton=findall(app.Figure,'Tag','exportChartsButton');
            chartStatus=findall(app.Figure,'Tag','chartExportInfo');
            chartPath=findall(app.Figure,'Tag','chartExportPath');
            openFolderButton=findall(app.Figure,'Tag','openChartFolderButton');
            t.assertEqual(numel(exportButton),1);
            t.assertEqual(numel(chartStatus),1);
            t.assertEqual(numel(chartPath),1);
            t.assertEqual(numel(openFolderButton),1);

            feval(exportButton.ButtonPushedFcn,exportButton,[]);
            t.verifyEqual(chartStatus.Text,'Экспорт графиков отменён.');
            t.verifyFalse(contains(chartStatus.Text,'Сохранено'));
            t.verifyEqual(strtrim(strjoin(string(chartPath.Value),newline)),"");
            t.verifyEqual(string(openFolderButton.Enable),"off");
            t.verifyEmpty(dir(fullfile(chartRoot,'nbiot-charts-*')));

            chartChoice('mode')='error';
            feval(exportButton.ButtonPushedFcn,exportButton,[]);
            t.verifyTrue(contains(chartStatus.Text,'Не удалось экспортировать графики'), ...
                chartStatus.Text);
            t.verifyFalse(contains(chartStatus.Text,'Сохранено'));
            t.verifyEqual(strtrim(strjoin(string(chartPath.Value),newline)),"");
            t.verifyEqual(string(openFolderButton.Enable),"off");

            chartChoice('mode')='success';
            feval(exportButton.ButtonPushedFcn,exportButton,[]);
            t.verifyTrue(contains(chartStatus.Text,'Сохранено 8 графиков PNG'), ...
                chartStatus.Text);
            t.verifyEqual(string(openFolderButton.Enable),"on");
            outputPath=strjoin(string(chartPath.Value),newline);
            t.verifyTrue(isfolder(outputPath),char(outputPath));
            t.verifyTrue(contains(outputPath,'путь с пробелами'),char(outputPath));
            t.verifyEqual(numel(dir(fullfile(outputPath,'*.png'))),8);
            feval(openFolderButton.ButtonPushedFcn,openFolderButton,[]);
            t.verifyEqual(openFolderSpy.LastTitle,'Открытие папки');
            t.verifyEqual(openFolderSpy.LastMessage,char(outputPath));

            trigger(app.Figure,'Сброс');
            t.verifyEmpty(findobj(activeAxes,'Type','line'));
            t.verifyTrue(contains(chartInfo.Text,'появятся после завершения'));
        end

        function stoppedRunCanBeSavedButCannotExportDevelopmentData(t)
            parent=tempname; mkdir(parent);
            t.addTeardown(@() removeFolder(parent));
            spy=DialogSpy();
            dialogs=struct('chooseOutputDirectory',@() parent, ...
                'chooseDatasetOutputDirectory',@() parent, ...
                'showAlert',@(message,title) spy.capture(message,title));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            setField(app.Figure,'numUE',1);
            setField(app.Figure,'durationTicks',1000);
            setField(app.Figure,'trafficKind','none');
            trigger(app.Figure,'Запуск');
            t.assertEqual(app.Session.Status,'running');
            trigger(app.Figure,'Остановить');

            t.assertEqual(app.Session.Status,'stopped');
            stopped=app.Session.getResult();
            t.verifyEqual(stopped.status,'stopped');
            datasetButton=findall(app.Figure,'Tag','savedDatasetButton');
            t.assertEqual(numel(datasetButton),1);
            t.verifyEqual(string(datasetButton.Enable),"off");

            trigger(app.Figure,'Сохранить');
            t.verifyTrue(isfile(app.Session.SavedPath));
            feval(datasetButton.ButtonPushedFcn,datasetButton,[]);
            t.verifyEqual(spy.LastTitle,'Экспорт датасета');
            t.verifyTrue(contains(spy.LastMessage,'Сначала завершите расчёт'));
            t.verifyEmpty(dir(fullfile(parent,'nbiot-dataset-development-*')));

            trigger(app.Figure,'Сброс');
            setField(app.Figure,'durationTicks',1000);
            trigger(app.Figure,'Запуск');
            t.assertEqual(app.Session.Status,'running');
            close(app.Figure);
            t.verifyFalse(isvalid(app.Figure));
            t.verifyEqual(app.Session.Status,'stopped');
            t.verifyFalse(isvalid(app.Timer));
        end
    end
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

function folder=chooseChartFolder(choice)
switch choice('mode')
    case 'cancel'
        folder=0;
    case 'error'
        folder=fullfile(choice('folder'),'not an existing folder');
    otherwise
        folder=choice('folder');
end
end
