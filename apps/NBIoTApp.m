function app=NBIoTApp(dialogs,options)
%NBIOTAPP Open the bounded local simulation interface.
%   Графический интерфейс симулятора (ТЗ §46): настройки, управление расчётом, состояние, KPI,
%   графики, журнал, сохранение/экспорт. Программный uifigure (App Designer — открытый вопрос, CLAUDE.md §7).
%   Все расчёты — в модулях симулятора; GUI только отображает и не меняет модель.
if nargin<1 || isempty(dialogs), dialogs=struct(); end
if ~isstruct(dialogs) || ~isscalar(dialogs)
    error('nbiot:ui:DialogAdapter','Dialog adapters must be a scalar structure.');
end
if nargin<2 || isempty(options), options=struct(); end
validateAppOptions(options);
appOptions=options;
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root); setupProject(); addpath(fullfile(root,'apps'));
execution=[];
if isfield(appOptions,'execution'), execution=appOptions.execution; end
if isstruct(execution)&&isscalar(execution)&&isempty(fieldnames(execution))
    execution=localDevelopment();
end
uiExecution=localDevelopment();
if isstruct(execution)&&isscalar(execution)
    executionNames=fieldnames(execution);
    for executionIndex=1:numel(executionNames)
        uiExecution.(executionNames{executionIndex})=execution.(executionNames{executionIndex});
    end
end
uiMaxUe=uiDeviceLimit(execution);
simulatorFactory=[];
if isfield(appOptions,'simulatorFactory'), simulatorFactory=appOptions.simulatorFactory; end
chooseOutputDirectory=@() uigetdir(fullfile(root,'results'),'Выберите папку для результата');
chooseDatasetOutputDirectory=@() uigetdir(fullfile(root,'results'),'Выберите папку для development-набора');
chooseChartOutputDirectory=@() uigetdir(fullfile(root,'results'), ...
    'Выберите папку для PNG-графиков');
openFolderAdapter=@winopen;
chooseComparisonFolder=@() uigetdir(fullfile(root,'results'), ...
    'Выберите папку со сводкой сравнения');
chooseKpiFile=@() uigetfile('*.csv', ...
    'Выберите одну или несколько таблиц KPI','MultiSelect','on');
chooseModelFile=@() uigetfile('*.mat','Выберите пакет модели нагрузки');
if isfield(dialogs,'chooseOutputDirectory')
    if ~isa(dialogs.chooseOutputDirectory,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseOutputDirectory must be a function handle.');
    end
    chooseOutputDirectory=dialogs.chooseOutputDirectory;
end
if isfield(dialogs,'chooseKpiFile')
    if ~isa(dialogs.chooseKpiFile,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseKpiFile must be a function handle.');
    end
    chooseKpiFile=dialogs.chooseKpiFile;
end
if isfield(dialogs,'chooseDatasetOutputDirectory')
    if ~isa(dialogs.chooseDatasetOutputDirectory,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseDatasetOutputDirectory must be a function handle.');
    end
    chooseDatasetOutputDirectory=dialogs.chooseDatasetOutputDirectory;
end
if isfield(dialogs,'chooseChartOutputDirectory')
    if ~isa(dialogs.chooseChartOutputDirectory,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseChartOutputDirectory must be a function handle.');
    end
    chooseChartOutputDirectory=dialogs.chooseChartOutputDirectory;
end
if isfield(dialogs,'openFolder')
    if ~isa(dialogs.openFolder,'function_handle')
        error('nbiot:ui:DialogAdapter','openFolder must be a function handle.');
    end
    openFolderAdapter=dialogs.openFolder;
end
if isfield(dialogs,'chooseModelFile')
    if ~isa(dialogs.chooseModelFile,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseModelFile must be a function handle.');
    end
    chooseModelFile=dialogs.chooseModelFile;
end
if isfield(dialogs,'chooseComparisonFolder')
    if ~isa(dialogs.chooseComparisonFolder,'function_handle')
        error('nbiot:ui:DialogAdapter','chooseComparisonFolder must be a function handle.');
    end
    chooseComparisonFolder=dialogs.chooseComparisonFolder;
end
if isfield(dialogs,'showAlert') && ~isa(dialogs.showAlert,'function_handle')
    error('nbiot:ui:DialogAdapter','showAlert must be a function handle.');
end
session=nbiot.ui.SimulationSession(execution,simulatorFactory);
selectedModelFile='';
if isfield(appOptions,'modelFile') && ~isempty(appOptions.modelFile)
    selectedModelFile=char(string(appOptions.modelFile));
end
modelSelectionError=false;
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=min(10,uiMaxUe);
calibrationFile=fullfile(root,'results','nprach-calibration.mat');
calibrationStatus='Калибровка не загружена';
try
    cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
    calibrationStatus='Калибровка загружена';
catch exception
    calibrationStatus=['Нужна калибровка: ' exception.message];
end

if strcmp(executionProfileName(uiExecution),'external-machine')
    roleLabel='external';
    if ischar(uiExecution.role)|| (isstring(uiExecution.role)&&isscalar(uiExecution.role))
        roleLabel=char(string(uiExecution.role));
    end
    appName=sprintf('NB-IoT — внешний профиль (%s)',roleLabel);
else
    appName='NB-IoT — локальный запуск';
end
screen=get(groot,'ScreenSize');
windowWidth=min(1320,max(1,screen(3)-20));
windowHeight=min(850,max(1,screen(4)-60));
windowLeft=screen(1)+(screen(3)-windowWidth)/2;
windowBottom=screen(2)+(screen(4)-windowHeight)/2;
fig=uifigure('Name',appName, ...
    'Position',[windowLeft windowBottom windowWidth windowHeight]);
fig.CloseRequestFcn=@closeApp;
showAlert=@(message,title) uialert(fig,message,title);
if isfield(dialogs,'showAlert'), showAlert=dialogs.showAlert; end
main=uigridlayout(fig,[2 2]);
main.RowHeight={48,'1x'}; main.ColumnWidth={'1.05x','1x'};
main.Padding=[12 12 12 12]; main.RowSpacing=10; main.ColumnSpacing=12;
titleLabel=uilabel(main,'Text',appName,'FontSize',20,'FontWeight','bold');
titleLabel.Layout.Row=1; titleLabel.Layout.Column=[1 2];

left=uigridlayout(main,[3 1]); left.Layout.Row=2; left.Layout.Column=1;
left.RowHeight={52,24,'1x'}; left.Padding=[0 0 0 0]; left.RowSpacing=6;
buttons=uigridlayout(left,[2 3]); buttons.RowHeight={24,24};
buttons.ColumnWidth={'1x','1x','1x'}; buttons.Padding=[0 0 0 0];
buttons.Layout.Row=1; buttons.Layout.Column=1;
startButton=uibutton(buttons,'Text','Запуск','ButtonPushedFcn',@startRun);
pauseButton=uibutton(buttons,'Text','Пауза','ButtonPushedFcn',@pauseRun);
resumeButton=uibutton(buttons,'Text','Продолжить','ButtonPushedFcn',@resumeRun);
stopButton=uibutton(buttons,'Text','Остановить','ButtonPushedFcn',@stopRun);
resetButton=uibutton(buttons,'Text','Сброс','ButtonPushedFcn',@resetRun);
saveButton=uibutton(buttons,'Text','Сохранить','ButtonPushedFcn',@saveRun);
nextRunSettingsInfo=uilabel(left, ...
    'Text','Настройки следующего запуска задаются во вкладках слева.', ...
    'Tag','nextRunSettingsInfo','FontColor',[0.25 0.35 0.5]);
nextRunSettingsInfo.Layout.Row=2; nextRunSettingsInfo.Layout.Column=1;

tabs=uitabgroup(left); tabs.Layout.Row=3; tabs.Layout.Column=1;
networkTab=uitab(tabs,'Title','Сеть');
channelTab=uitab(tabs,'Title','Канал');
trafficTab=uitab(tabs,'Title','Трафик');
controllerTab=uitab(tabs,'Title','Контроллер');
networkForm=formGrid(networkTab,30);
channelForm=formGrid(channelTab,30);
trafficForm=formGrid(trafficTab,30);
controllerForm=formGrid(controllerTab,12);
controls=struct(); paths=struct(); kinds=struct();
addDropdown(networkForm,'Режим запуска','simulationMode','policy.name', ...
    cfg.policy.name,{'Static','Adaptive-P','Adaptive-RA/DT'});
if strcmp(executionProfileName(uiExecution),'external-machine')
    ueLabel=sprintf('Устройства (внешний предел %d)',uiMaxUe);
else
    ueLabel='Устройства (местный предел 10)';
end
addNumber(networkForm,ueLabel,'numUE','simulation.numUE',cfg.simulation.numUE,[1 uiMaxUe],'integer');
addNumber(networkForm,'Длительность, мс (макс. 5000)','durationTicks','simulation.durationTicks',cfg.simulation.durationTicks,[1 5000],'integer');
addNumber(networkForm,'Seed','seed','simulation.seed',cfg.simulation.seed,[0 4294967295],'integer');
addNumber(networkForm,'Номер реализации','realizationId','simulation.realizationId',cfg.simulation.realizationId,[0 4095],'integer');
addNumber(networkForm,'Радиус соты, м','radiusM','cell.radiusM',cfg.cell.radiusM,[10 100000],'number');
addNumber(networkForm,'Минимальное расстояние, м','minDistanceM','cell.minDistanceM',cfg.cell.minDistanceM,[0 99999],'number');
addNumber(networkForm,'Доля устройств внутри зданий','indoorFraction','cell.indoorFraction',cfg.cell.indoorFraction,[0 1],'number');
addNumber(networkForm,'Высота базовой станции, м','bsHeightM','cell.bsHeightM',cfg.cell.bsHeightM,[0 1000],'number');
addNumber(networkForm,'Высота устройства, м','ueHeightM','cell.ueHeightM',cfg.cell.ueHeightM,[0 1000],'number');
addNumber(networkForm,'ID соты','cellId','cell.cellId',cfg.cell.cellId,[0 503],'integer');
row=nextRow(networkForm); note=uilabel(networkForm, ...
    'Text','Полоса: 180 кГц (фиксирована) · шаг 1 мс · канал static-v1 · начальные P и RA/DT для Static задаются во вкладке «Трафик»', ...
    'FontColor',[0.25 0.35 0.5],'Tag','fixedBandwidthInfo','WordWrap','on');
note.Layout.Row=row; note.Layout.Column=[1 2];
row=nextRow(networkForm);
selectModelButton=uibutton(networkForm,'Text','Выбрать модель', ...
    'Tag','selectModelButton','ButtonPushedFcn',@selectModel);
selectModelButton.Layout.Row=row; selectModelButton.Layout.Column=[1 2];
allowDevelopmentModel= uicheckbox(networkForm, ...
    'Text','Разрешить development-модель (только отладка)', ...
    'Value',false,'Tag','allowDevelopmentModel');
row=nextRow(networkForm); allowDevelopmentModel.Layout.Row=row;
allowDevelopmentModel.Layout.Column=[1 2];
modelStatus=uilabel(networkForm,'Text','Модель не выбрана. Для Static она не нужна.', ...
    'Tag','modelStatus','WordWrap','on');
row=nextRow(networkForm); modelStatus.Layout.Row=row; modelStatus.Layout.Column=[1 2];
modelDetails=uitextarea(networkForm,'Editable','off', ...
    'Value',{'После выбора модели здесь появятся тип, цель, версия и признаки.'}, ...
    'Tag','modelDetails');
row=nextRow(networkForm); modelDetails.Layout.Row=[row row+3];
modelDetails.Layout.Column=[1 2];

addNumber(channelForm,'Несущая частота, Гц','carrierHz','channel.carrierHz',cfg.channel.carrierHz,[1 1e12],'number');
addNumber(channelForm,'Опорное расстояние, м','referenceDistanceM','channel.referenceDistanceM',cfg.channel.referenceDistanceM,[1e-6 1e9],'number');
addNumber(channelForm,'Показатель потерь пути','pathLossExponent','channel.pathLossExponent',cfg.channel.pathLossExponent,[0.01 10],'number');
addNumber(channelForm,'Теневая вариация снаружи, дБ','shadowOutdoorDb','channel.shadowOutdoorDb',cfg.channel.shadowOutdoorDb,[0 100],'number');
addNumber(channelForm,'Теневая вариация внутри, дБ','shadowIndoorDb','channel.shadowIndoorDb',cfg.channel.shadowIndoorDb,[0 100],'number');
addNumber(channelForm,'Потери стен, дБ','penetrationIndoorDb','channel.penetrationIndoorDb',cfg.channel.penetrationIndoorDb,[0 200],'number');
addNumber(channelForm,'Мощность устройства, дБм','uePowerDbm','channel.uePowerDbm',cfg.channel.uePowerDbm,[-100 100],'number');
addNumber(channelForm,'Мощность станции, дБм','bsPowerDbm','channel.bsPowerDbm',cfg.channel.bsPowerDbm,[-100 100],'number');
addNumber(channelForm,'Шум приёмника станции, дБ','bsNoiseFigureDb','channel.bsNoiseFigureDb',cfg.channel.bsNoiseFigureDb,[0 100],'number');
addNumber(channelForm,'Шум приёмника устройства, дБ','ueNoiseFigureDb','channel.ueNoiseFigureDb',cfg.channel.ueNoiseFigureDb,[0 100],'number');
addNumber(channelForm,'Температура шума, К','temperatureK','channel.temperatureK',cfg.channel.temperatureK,[1e-6 1e6],'number');
addNumber(channelForm,'Разброс CFO, Гц','cfoSigmaHz','channel.cfoSigmaHz',cfg.channel.cfoSigmaHz,[0 10000],'number');
addNumber(channelForm,'Предел CFO, Гц','cfoLimitHz','channel.cfoLimitHz',cfg.channel.cfoLimitHz,[0 10000],'number');
addNumber(channelForm,'Предел ошибки синхронизации, с','syncLimitSeconds','channel.syncLimitSeconds',cfg.channel.syncLimitSeconds,[0 0.01],'number');
addText(channelForm,'Задержки лучей, с','tapDelaysSeconds','channel.tapDelaysSeconds',cfg.channel.tapDelaysSeconds);
addText(channelForm,'Мощности лучей, дБ','tapPowersDb','channel.tapPowersDb',cfg.channel.tapPowersDb);
addNumber(channelForm,'Длина фильтра дробной задержки','fractionalFilterLength', ...
    'channel.fractionalFilterLength',cfg.channel.fractionalFilterLength,[3 4095],'integer');
row=nextRow(channelForm); channelProfileInfo=uilabel(channelForm, ...
    'Text','Модель радиоканала: static-v1 (единственный поддерживаемый профиль)', ...
    'Tag','channelModelInfo','WordWrap','on');
channelProfileInfo.Layout.Row=row; channelProfileInfo.Layout.Column=[1 2];

addDropdown(trafficForm,'Тип трафика','trafficKind','traffic.kind',cfg.traffic.kind,{'burst','periodic','poisson','none'});
addDropdown(trafficForm,'Активная группа','activityMode','traffic.activityMode', ...
    cfg.traffic.activityMode,{'all','explicit'});
addIdText(trafficForm,'ID активных UE (через запятую)','activeUeIds', ...
    'traffic.activeUeIds',cfg.traffic.activeUeIds);
controls.activityMode.ValueChangedFcn=@updateActivityControls;
updateActivityControls();
addNumber(trafficForm,'Размер пакета, байт','packetBytes','traffic.packetBytes',cfg.traffic.packetBytes,[1 6630],'integer');
addNumber(trafficForm,'Предел очереди, пакетов','queueLimit','traffic.queueLimit',cfg.traffic.queueLimit,[1 65535],'integer');
addNumber(trafficForm,'Период, мс','periodTicks','traffic.periodTicks',cfg.traffic.periodTicks,[1 16777215],'integer');
addNumber(trafficForm,'Частота пуассоновского трафика, 1/с','poissonRatePerSecond','traffic.poissonRatePerSecond',cfg.traffic.poissonRatePerSecond,[0 100000],'number');
addNumber(trafficForm,'Начало всплеска, мс','burstStartTick','traffic.burstStartTick',cfg.traffic.burstStartTick,[0 16777215],'integer');
addNumber(trafficForm,'Длина всплеска, мс','burstDurationTicks','traffic.burstDurationTicks',cfg.traffic.burstDurationTicks,[1 16777215],'integer');
addNumber(trafficForm,'Срок жизни пакета, мс','lifetimeTicks','traffic.lifetimeTicks',cfg.traffic.lifetimeTicks,[1 16777215],'integer');
addNumber(trafficForm,'Максимум попыток доступа','maxAttempts','ra.maxAttempts',cfg.ra.maxAttempts,[1 65535],'integer');
addNumber(trafficForm,'Ожидание после неудачи, мс','backoffTicks','ra.backoffTicks',cfg.ra.backoffTicks,[0 16777215],'integer');
addNumber(trafficForm,'Период доступа, мс','raPeriodTicks','ra.periodTicks',cfg.ra.periodTicks,[1 16777215],'integer');
addNumber(trafficForm,'Смещение доступа, мс','raStartOffsetTicks','ra.startOffsetTicks',cfg.ra.startOffsetTicks,[0 16777214],'integer');
addNumber(trafficForm,'Окно ответа станции, слоты','rarPp','ra.rarPp',cfg.ra.rarPp,[1 65535],'integer');
addNumber(trafficForm,'Окно разрешения конфликта, слоты','contentionPp', ...
    'ra.contentionPp',cfg.ra.contentionPp,[1 65535],'integer');
addNumber(trafficForm,'Вероятность попытки P','accessProbability','policy.accessProbability',cfg.policy.accessProbability,[0 1],'number');
addNumericDropdown(trafficForm,'Доля ресурсов RA','raShare','policy.raShare', ...
    cfg.policy.raShare,{'10/90','20/80','30/70'},[0.1 0.2 0.3]);
row=nextRow(controllerForm);
labelHandle=uilabel(controllerForm,'Text','Начальное P для Adaptive-P');
labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
adaptiveStartProbability=uidropdown(controllerForm, ...
    'Items',{'1.00','0.75','0.50','0.25','0.10'}, ...
    'ItemsData',[1 0.75 0.5 0.25 0.1],'Value',1, ...
    'Tag','adaptiveStartProbability');
adaptiveStartProbability.Layout.Row=row; adaptiveStartProbability.Layout.Column=2;
probabilityChoices=[0.1 0.25 0.5 0.75 1];
probabilityLabels={'0.10','0.25','0.50','0.75','1.00'};
row=nextRow(controllerForm);
labelHandle=uilabel(controllerForm,'Text','Минимальное допустимое P');
labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
allowedPMin=uidropdown(controllerForm,'Items',probabilityLabels, ...
    'ItemsData',probabilityChoices,'Value',0.1,'Tag','allowedPMin');
allowedPMin.Layout.Row=row; allowedPMin.Layout.Column=2;
row=nextRow(controllerForm);
labelHandle=uilabel(controllerForm,'Text','Максимальное допустимое P');
labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
allowedPMax=uidropdown(controllerForm,'Items',probabilityLabels, ...
    'ItemsData',probabilityChoices,'Value',1,'Tag','allowedPMax');
allowedPMax.Layout.Row=row; allowedPMax.Layout.Column=2;
row=nextRow(controllerForm);
labelHandle=uilabel(controllerForm,'Text','Начальная доля RA/DT для Adaptive-RA/DT');
labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
adaptiveStartRaShare=uidropdown(controllerForm, ...
    'Items',{'10/90','20/80','30/70'},'ItemsData',[0.1 0.2 0.3], ...
    'Value',0.1,'Tag','adaptiveStartRaShare');
adaptiveStartRaShare.Layout.Row=row; adaptiveStartRaShare.Layout.Column=2;
row=nextRow(controllerForm);
labelHandle=uilabel(controllerForm,'Text','Допустимые доли ресурсов RA/DT');
labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
allowedRaShares=uilistbox(controllerForm,'Items',{'10/90','20/80','30/70'}, ...
    'ItemsData',[0.1 0.2 0.3],'Value',[0.1 0.2 0.3], ...
    'Multiselect','on','Tag','allowedRaShares');
allowedRaShares.Layout.Row=[row row+2]; allowedRaShares.Layout.Column=2;
controllerForm.UserData=row+2;
row=nextRow(controllerForm);
controllerHint=uilabel(controllerForm, ...
    'Text','В режиме Static эти поля не используются. Выберите Adaptive-P или Adaptive-RA/DT во вкладке «Сеть». Начальное значение должно входить в разрешённый набор.', ...
    'Tag','controllerSettingsInfo','WordWrap','on');
controllerHint.Layout.Row=row; controllerHint.Layout.Column=[1 2];
controls.simulationMode.ValueChangedFcn=@updateModeControls;
updateModeControls();

right=uigridlayout(main,[4 1]); right.Layout.Row=2; right.Layout.Column=2;
right.RowHeight={44,24,42,'1x'}; right.Padding=[0 0 0 0]; right.RowSpacing=8;
statusLabel=uilabel(right,'Text',calibrationStatus,'FontSize',14, ...
    'FontWeight','bold','WordWrap','on','Tag','runStatus');
progress= uigauge(right,'linear','Limits',[0 100]); progress.Layout.Row=2;
liveToolbar=uigridlayout(right,[1 3]); liveToolbar.Layout.Row=3;
liveToolbar.ColumnWidth={132,'1x',104};
liveToolbar.RowHeight={32}; liveToolbar.Padding=[0 0 0 0]; liveToolbar.ColumnSpacing=6;
openRadioJournalButton=uibutton(liveToolbar,'Text','Развернуть журнал', ...
    'Tag','openRadioJournalButton','ButtonPushedFcn',@openRadioJournal);
showZeroDetectionEvents=uicheckbox(liveToolbar, ...
    'Text','Показывать проверки без запросов','Value',false, ...
    'Tag','showZeroDetectionEvents','Tooltip', ...
    'Проверка с нулём кандидатов означает, что запрос не обнаружен; это не ошибка и не подключение.', ...
    'ValueChangedFcn',@refreshRadioEventPresentation);
hiddenZeroDetectionCount=uilabel(liveToolbar,'Text','Скрыто: 0', ...
    'Tag','hiddenZeroDetectionCount','HorizontalAlignment','right');
displayTabs=uitabgroup(right); displayTabs.Layout.Row=4;
liveTab=uitab(displayTabs,'Title','Текущий запуск');
savedTab=uitab(displayTabs,'Title','Сохранённые результаты');
liveGrid=uigridlayout(liveTab,[13 1],'Scrollable','on');
liveGrid.Padding=[6 6 6 6]; liveGrid.RowSpacing=4;
liveGrid.RowHeight={145,64,22,70,22,140,22,44,96,22,56,22,84};
mapPanel=uipanel(liveGrid,'BorderType','none'); mapPanel.Layout.Row=1;
mapGrid=uigridlayout(mapPanel,[1 1]); mapGrid.Padding=[0 0 0 0];
map=uiaxes(mapGrid); map.Layout.Row=1; map.Layout.Column=1;
title(map,'Расположение устройств'); xlabel(map,'X, м'); ylabel(map,'Y, м');
axis(map,'equal'); grid(map,'on');
deviceTable=uitable(liveGrid,'Data',cell(0,4), ...
    'ColumnName',{'UE','Состояние','Пакетов в очереди','В здании'}, ...
    'Tag','deviceTable','CellSelectionCallback',@selectUe);
uilabel(liveGrid,'Text','Сведения о выбранном устройстве','FontWeight','bold');
selectedUeDetails=uitextarea(liveGrid,'Editable','off', ...
    'Value',{'Выберите UE в таблице, чтобы посмотреть подробности.'}, ...
    'Tag','selectedUeDetails');
uilabel(liveGrid,'Text','Сводка запуска','FontWeight','bold');
summary=uitextarea(liveGrid,'Editable','off', ...
    'Value',initialRunSummary(cfg,uiExecution,calibrationStatus));
summary.Tag='runSummary';
uilabel(liveGrid,'Text','Прогноз и решения контроллера','FontWeight','bold');
controllerSummary=uilabel(liveGrid,'Text','Static · P = 1.00 · RA/DT = 10/90 · прогноз не используется', ...
    'WordWrap','on','Tag','controllerSummary');
controllerHistory=uitable(liveGrid,'Data',cell(0,8), ...
    'ColumnName',{'Время, с','Прогноз','Факт','Ошибка','P','RA/DT','Применено','Причина'}, ...
    'ColumnWidth',{65,75,50,65,32,62,90,75}, ...
    'Tag','controllerHistory');
uilabel(liveGrid,'Text','Действия и ошибки','FontWeight','bold');
eventLog=uitextarea(liveGrid,'Editable','off','Value',{'Окно готово'});
eventLog.Tag='eventLog';
uilabel(liveGrid,'Text','Радиособытия, наблюдаемые базовой станцией','FontWeight','bold');
radioEventLog=uitextarea(liveGrid,'Editable','off','Value',{'Радиособытий пока нет'});
radioEventLog.Tag='radioEventLog';
initialControllerView=nbiot.ui.buildControllerDisplayData(session.snapshot());
controllerSummary.Text=initialControllerView.summary;
controllerHistory.Data=initialControllerView.historyDisplay;
savedGrid=uigridlayout(savedTab,[13 1],'Scrollable','on');
savedGrid.RowHeight={38,30,88,30,'1x','1x',26,28,34,38,30,38,38};
uibutton(savedGrid,'Text','Открыть/сравнить KPI CSV','Tag','savedKpiButton', ...
    'ButtonPushedFcn',@loadSavedKpi);
savedReportSelector=uidropdown(savedGrid,'Items',{'Отчёт не выбран'}, ...
    'ItemsData',1,'Value',1,'Enable','off','Tag','savedReportSelector', ...
    'ValueChangedFcn',@reportSelectionChanged);
savedReportCard=uitextarea(savedGrid,'Editable','off', ...
    'Value',{'Отчёт ещё не открыт. Нажмите Открыть/сравнить KPI CSV.'}, ...
    'Tag','savedReportCard');
savedReportCard.WordWrap='on';
savedReportCard.Layout.Row=3;
savedMetric=uidropdown(savedGrid,'Items',{'Скорость доставки, бит/с'}, ...
    'ItemsData',{'throughputBitsPerSecond'},'Value','throughputBitsPerSecond', ...
    'Tag','savedKpiMetric','ValueChangedFcn',@plotSavedKpi);
savedMetric.Layout.Row=4;
savedTable=uitable(savedGrid,'Data',cell(0,0),'ColumnName',{},'Tag','savedKpiTable');
savedTable.Layout.Row=5;
savedAxesPanel=uipanel(savedGrid,'BorderType','none'); savedAxesPanel.Layout.Row=6;
savedAxesGrid=uigridlayout(savedAxesPanel,[1 1]); savedAxesGrid.Padding=[0 0 0 0];
savedAxes=uiaxes(savedAxesGrid); savedAxes.Layout.Row=1; savedAxes.Layout.Column=1;
title(savedAxes,'Сравнение сохранённых результатов');
savedAxes.Tag='savedKpiAxes';
xlabel(savedAxes,'Время модели, с'); ylabel(savedAxes,'бит/с'); grid(savedAxes,'on');
savedKpiWindowInfo=uilabel(savedGrid, ...
    'Text','Длина окна KPI появится после загрузки отчёта.', ...
    'Tag','savedKpiWindowInfo','WordWrap','on');
savedKpiWindowInfo.Layout.Row=7;
savedInfo=uilabel(savedGrid,'Text','Выберите один или несколько *_kpi.csv. Таблица показывает первый файл; график сравнивает выбранные запуски.');
savedInfo.Tag='savedKpiInfo';
savedInfo.Layout.Row=8;
savedDatasetButton=uibutton(savedGrid,'Text','Экспортировать development-набор', ...
    'Tag','savedDatasetButton','Enable','off','ButtonPushedFcn',@exportDataset);
savedDatasetButton.Layout.Row=9;
chartExportInfo=uilabel(savedGrid,'Text','Графики ещё не сохранены.', ...
    'Tag','chartExportInfo','WordWrap','on');
chartExportInfo.Layout.Row=10;
chartExportPath=uitextarea(savedGrid,'Editable','off','Value',{''}, ...
    'Tag','chartExportPath','WordWrap','off');
chartExportPath.Layout.Row=11;
exportChartsButton=uibutton(savedGrid,'Text','Экспортировать графики PNG', ...
    'Tag','exportChartsButton','Enable','off','ButtonPushedFcn',@exportCharts);
exportChartsButton.Layout.Row=12;
openChartFolderButton=uibutton(savedGrid,'Text','Открыть папку', ...
    'Tag','openChartFolderButton','Enable','off','ButtonPushedFcn',@openChartOutputFolder);
openChartFolderButton.Layout.Row=13;
comparisonTab=uitab(displayTabs,'Title','Сравнение режимов','Tag','methodSummaryTab');
comparisonGrid=uigridlayout(comparisonTab,[7 2]);
comparisonGrid.RowHeight={34,28,22,'1x',22,'1x','1.1x'};
comparisonGrid.ColumnWidth={'1x','1x'};
comparisonGrid.Padding=[6 6 6 6]; comparisonGrid.RowSpacing=5;
loadMethodSummaryButton=uibutton(comparisonGrid,'Text','Открыть сводку сравнения', ...
    'Tag','loadMethodSummaryButton','ButtonPushedFcn',@loadSavedMethodComparison);
loadMethodSummaryButton.Layout.Row=1; loadMethodSummaryButton.Layout.Column=1;
methodSummaryMetric=uidropdown(comparisonGrid, ...
    'Items',{'Вероятность доставки'},'ItemsData',{'deliveryProbability'}, ...
    'Value','deliveryProbability','Tag','methodSummaryMetric', ...
    'ValueChangedFcn',@refreshSavedMethodComparison);
methodSummaryMetric.Layout.Row=1; methodSummaryMetric.Layout.Column=2;
methodSummaryBurst=uidropdown(comparisonGrid,'Items',{'Сначала загрузите сводку'}, ...
    'ItemsData',0,'Value',0,'Tag','methodSummaryBurst', ...
    'ValueChangedFcn',@refreshSavedMethodComparison);
methodSummaryBurst.Layout.Row=2; methodSummaryBurst.Layout.Column=1;
methodSummaryInfo=uilabel(comparisonGrid, ...
    'Text','Таблицы читают готовые сводки; пересчёт симуляции не запускается.', ...
    'Tag','methodSummaryInfo','WordWrap','on');
methodSummaryInfo.Layout.Row=2; methodSummaryInfo.Layout.Column=2;
methodSummaryHeading=uilabel(comparisonGrid, ...
    'Text','Среднее по режимам и 95% интервал');
methodSummaryHeading.Layout.Row=3; methodSummaryHeading.Layout.Column=[1 2];
methodSummaryTable=uitable(comparisonGrid,'Data',cell(0,8), ...
    'ColumnName',{'Устройства','Всплеск, мс','Режим','Полных','Неполных', ...
    'Среднее','Нижняя граница','Верхняя граница'},'Tag','methodSummaryTable');
methodSummaryTable.Layout.Row=4; methodSummaryTable.Layout.Column=[1 2];
pairedSummaryHeading=uilabel(comparisonGrid, ...
    'Text','Парное различие: второй режим минус первый');
pairedSummaryHeading.Layout.Row=5; pairedSummaryHeading.Layout.Column=[1 2];
pairedSummaryTable=uitable(comparisonGrid,'Data',cell(0,9), ...
    'ColumnName',{'Устройства','Всплеск, мс','Режим 1','Режим 2','Пар', ...
    'Неполных пар','Разница средних','Нижняя граница','Верхняя граница'}, ...
    'Tag','pairedSummaryTable');
pairedSummaryTable.Layout.Row=6; pairedSummaryTable.Layout.Column=[1 2];
methodSummaryAxes=uiaxes(comparisonGrid,'Tag','methodSummaryAxes');
methodSummaryAxes.Layout.Row=7; methodSummaryAxes.Layout.Column=[1 2];
title(methodSummaryAxes,'Средний показатель по трём режимам');
xlabel(methodSummaryAxes,'Число устройств'); ylabel(methodSummaryAxes,'Вероятность доставки');
grid(methodSummaryAxes,'on');
chartTab=uitab(displayTabs,'Title','Графики запуска','Tag','resultChartsTab');
chartGrid=uigridlayout(chartTab,[7 2],'Scrollable','on');
chartGrid.RowHeight={34,30,0,'1x','1x','1x','1x'};
chartGrid.ColumnWidth={'1x','1x'};
chartGrid.Padding=[6 6 6 6]; chartGrid.RowSpacing=6; chartGrid.ColumnSpacing=8;
chartInfo=uilabel(chartGrid,'Text', ...
    'Итоговые Static-графики. Фактическая нагрузка и столкновения — диагностические данные; Adaptive-прогноз пока недоступен.', ...
    'WordWrap','on','Tag','staticChartInfo');
chartInfo.Layout.Row=1; chartInfo.Layout.Column=[1 2];
metricExplanationsToggle=uibutton(chartGrid,'Text','Что означают показатели', ...
    'Tag','metricExplanationsToggle','ButtonPushedFcn',@toggleMetricExplanations);
metricExplanationsToggle.Layout.Row=2; metricExplanationsToggle.Layout.Column=[1 2];
metricExplanationsPanel=uipanel(chartGrid,'BorderType','none', ...
    'Tag','metricExplanationsPanel','Visible','off');
metricExplanationsPanel.Layout.Row=3; metricExplanationsPanel.Layout.Column=[1 2];
metricExplanationGrid=uigridlayout(metricExplanationsPanel,[1 1]);
metricExplanationGrid.Padding=[0 0 0 0];
metricExplanationsText=uitextarea(metricExplanationGrid,'Editable','off', ...
    'WordWrap','on','Value',metricExplanationLines(), ...
    'Tag','metricExplanationsText');
metricExplanationsText.Layout.Row=1; metricExplanationsText.Layout.Column=1;
chartSpecs={ ...
    'activeUe','staticChartActiveUe','Средняя активность UE','Устройств'; ...
    'actualLoad','staticChartActualLoad','Фактическая нагрузка (диагностика)','UE в RA'; ...
    'collisions','staticChartCollisions','Столкновения попыток RA','%'; ...
    'successfulRa','staticChartSuccessfulRa','Успешные попытки RA','Попыток'; ...
    'throughput','staticChartThroughput','Скорость доставки','бит/с'; ...
    'delay','staticChartDelay','Задержка доставленных пакетов','мс'; ...
    'dataBler','staticChartDataBler','Data BLER','%'; ...
    'occupancy','staticChartOccupancy','Занятость ресурсов','%'};
chartAxes=struct();
for chartIndex=1:size(chartSpecs,1)
    key=chartSpecs{chartIndex,1};
    chartPanel=uipanel(chartGrid,'BorderType','none');
    chartPanel.Layout.Row=ceil(chartIndex/2)+3;
    chartPanel.Layout.Column=mod(chartIndex-1,2)+1;
    chartPanelGrid=uigridlayout(chartPanel,[1 1]);
    chartPanelGrid.Padding=[0 0 0 0];
    ax=uiaxes(chartPanelGrid,'Tag',chartSpecs{chartIndex,2});
    ax.Layout.Row=1; ax.Layout.Column=1;
    title(ax,chartSpecs{chartIndex,3}); xlabel(ax,'Время модели, с');
    ylabel(ax,chartSpecs{chartIndex,4}); grid(ax,'on');
    chartAxes.(key)=ax;
end
controllerChartTab=uitab(displayTabs,'Title','Прогноз и управление','Tag','controllerChartsTab');
controllerChartGrid=uigridlayout(controllerChartTab,[3 2]);
controllerChartGrid.RowHeight={30,'1x','1x'};
controllerChartGrid.ColumnWidth={'1x','1x'};
controllerChartGrid.Padding=[6 6 6 6];
controllerChartInfo=uilabel(controllerChartGrid, ...
    'Text','Static · прогноз и адаптивные графики не используются.', ...
    'WordWrap','on','Tag','controllerChartInfo');
controllerChartInfo.Layout.Row=1; controllerChartInfo.Layout.Column=[1 2];
controllerChartAxes=struct();
controllerChartAxes.forecast=uiaxes(controllerChartGrid,'Tag','controllerChartForecast');
controllerChartAxes.forecast.Layout.Row=2; controllerChartAxes.forecast.Layout.Column=1;
title(controllerChartAxes.forecast,'Фактическая нагрузка и прогноз');
xlabel(controllerChartAxes.forecast,'Время модели, с');
ylabel(controllerChartAxes.forecast,'UE в RA'); grid(controllerChartAxes.forecast,'on');
controllerChartAxes.access=uiaxes(controllerChartGrid,'Tag','controllerChartAccess');
controllerChartAxes.access.Layout.Row=2; controllerChartAxes.access.Layout.Column=2;
title(controllerChartAxes.access,'Вероятность доступа P');
xlabel(controllerChartAxes.access,'Время модели, с');
ylabel(controllerChartAxes.access,'P'); ylim(controllerChartAxes.access,[0 1]);
grid(controllerChartAxes.access,'on');
controllerChartAxes.raDt=uiaxes(controllerChartGrid,'Tag','controllerChartRaDt');
controllerChartAxes.raDt.Layout.Row=3; controllerChartAxes.raDt.Layout.Column=1;
title(controllerChartAxes.raDt,'Доля ресурсов RA/DT');
xlabel(controllerChartAxes.raDt,'Время модели, с');
ylabel(controllerChartAxes.raDt,'RA, %'); ylim(controllerChartAxes.raDt,[0 100]);
grid(controllerChartAxes.raDt,'on');
controllerChartAxes.error=uiaxes(controllerChartGrid,'Tag','controllerChartError');
controllerChartAxes.error.Layout.Row=3; controllerChartAxes.error.Layout.Column=2;
title(controllerChartAxes.error,'Ошибка прогноза');
xlabel(controllerChartAxes.error,'Время модели, с');
ylabel(controllerChartAxes.error,'Прогноз − факт, UE'); grid(controllerChartAxes.error,'on');
clearControllerCharts();
staticChartsReady=false;
timerHandle=timer('ExecutionMode','fixedSpacing','Period',0.05,'BusyMode','drop', ...
    'TimerFcn',@advanceRun,'ErrorFcn',@timerFailed);
lastDisplayTick=0;
lastStaticChartWindow=0;
radioEventCursor=0; radioLogLines=cell(0,1);
radioHiddenCount=0; radioJournalFigure=[]; radioJournalText=[];
chartExportOutputPath=''; runStartedAt=[];
latestUeDetails=struct([]); selectedUeId=NaN; latestDisplayState=[];
savedComparison=[]; savedLabels={}; savedMethodComparison=[];
app=struct('Figure',fig,'Session',session,'Timer',timerHandle);
refreshButtons();
appendLog('Окно готово к запуску');

    function addNumber(parent,label,key,path,value,limits,kind)
        row=nextRow(parent); labelHandle=uilabel(parent,'Text',label,'Interpreter','none');
        labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
        field=uieditfield(parent,'numeric','Value',value,'Limits',limits);
        field.Layout.Row=row; field.Layout.Column=2; field.Tag=key;
        controls.(key)=field; paths.(key)=path; kinds.(key)=kind;
    end
    function addText(parent,label,key,path,value)
        row=nextRow(parent); labelHandle=uilabel(parent,'Text',label,'Interpreter','none');
        labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
        field=uieditfield(parent,'text','Value',strjoin(compose('%.12g',value),' '));
        field.Layout.Row=row; field.Layout.Column=2; field.Tag=key;
        controls.(key)=field; paths.(key)=path; kinds.(key)='vector';
    end
    function addIdText(parent,label,key,path,value)
        row=nextRow(parent); labelHandle=uilabel(parent,'Text',label,'Interpreter','none');
        labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
        field=uieditfield(parent,'text','Value',joinIds(value), ...
            'Tooltip','Например: 2, 4, 5; пустой список означает никого.');
        field.Layout.Row=row; field.Layout.Column=2; field.Tag=key;
        controls.(key)=field; paths.(key)=path; kinds.(key)='activeIds';
    end
    function addDropdown(parent,label,key,path,value,items)
        row=nextRow(parent); labelHandle=uilabel(parent,'Text',label);
        labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
        field=uidropdown(parent,'Items',items,'Value',value);
        field.Layout.Row=row; field.Layout.Column=2; field.Tag=key;
        controls.(key)=field; paths.(key)=path; kinds.(key)='text';
    end
    function addNumericDropdown(parent,label,key,path,value,items,itemsData)
        row=nextRow(parent); labelHandle=uilabel(parent,'Text',label);
        labelHandle.Layout.Row=row; labelHandle.Layout.Column=1;
        field=uidropdown(parent,'Items',items,'ItemsData',itemsData,'Value',value);
        field.Layout.Row=row; field.Layout.Column=2; field.Tag=key;
        controls.(key)=field; paths.(key)=path; kinds.(key)='number';
    end
    function row=nextRow(parent)
        if isempty(parent.UserData), parent.UserData=0; end
        row=parent.UserData+1; parent.UserData=row;
    end
    function cfgOut=readConfiguration()
        cfgOut=nbiot.config.defaultConfig();
        names=fieldnames(controls);
        for ix=1:numel(names)
            key=names{ix}; control=controls.(key); kind=kinds.(key);
            value=control.Value;
            if strcmp(kind,'activeIds')
                if strcmp(char(controls.activityMode.Value),'explicit')
                    value=parseActiveUeIds(value);
                else
                    value=[];
                end
            elseif strcmp(kind,'vector')
                value=parseVector(value);
            elseif strcmp(kind,'integer')
                if value~=fix(value), error('nbiot:ui:InvalidInput','Поле «%s» должно быть целым числом.',key); end
            end
            cfgOut=setNested(cfgOut,paths.(key),value);
        end
        if strcmp(cfgOut.policy.name,'Adaptive-P')
            cfgOut.policy.accessProbability=adaptiveStartProbability.Value;
            cfgOut.policy.raShare=0.1;
        elseif strcmp(cfgOut.policy.name,'Adaptive-RA/DT')
            cfgOut.policy.accessProbability=1;
            cfgOut.policy.raShare=adaptiveStartRaShare.Value;
        end
        cfgOut.logging.outputFolder=fullfile(root,'results','ui-local');
        cfgOut=nbiot.config.validateConfig(cfgOut);
        cfgOut=nbiot.experiments.loadCalibration(cfgOut,calibrationFile);
    end
    function startRun(~,~)
        if ~strcmp(session.Status,'idle'), return; end
        try
            cfgToRun=readConfiguration();
            executionBudget=nbiot.experiments.validateExecutionBudget(cfgToRun,execution);
            controllerOptions=controllerOptionsFor(cfgToRun);
            % The current runtime validator deliberately rejects unsupported or
            % externally unaccepted Adaptive models before any factory is called.
            nbiot.controller.prepareRuntime(cfgToRun,executionBudget,controllerOptions);
            runStartedAt=tic;
            session.start(cfgToRun,controllerOptions);
            clearStaticCharts(); clearControllerCharts();
            clearChartExportFeedback();
            lastStaticChartWindow=0;
            radioEventCursor=0; radioLogLines=cell(0,1); radioHiddenCount=0;
            radioEventLog.Value={'Радиособытий пока нет'};
            hiddenZeroDetectionCount.Text='Скрыто: 0';
            updateRadioJournal();
            updateView(session.snapshot());
            lastDisplayTick=0;
            setConfigurationEnabled(false);
            statusLabel.Text=statusText(session.Status,0, ...
                cfgToRun.simulation.durationTicks,runElapsedSeconds());
            appendLog(sprintf('Запуск %s · %s · максимум %d UE / 5000 мс.', ...
                cfgToRun.policy.name,executionProfileName(uiExecution),executionBudget.maxUE));
            refreshButtons();
            start(timerHandle);
        catch exception
            runStartedAt=[];
            statusLabel.Text='Запуск не выполнен';
            appendLog(['Запуск не выполнен: ' exception.message]);
            setConfigurationEnabled(true); refreshButtons();
            showAlert(exception.message,'Не удалось запустить');
        end
    end
    function selectModel(~,~)
        [file,folder]=chooseModelFile();
        if isequal(file,0)||isempty(file), return; end
        selectedModelFile=''; allowDevelopmentModel.Value=false;
        try
            candidate=fullfile(char(string(folder)),char(string(file)));
            bundle=nbiot.ml.validateModelBundle(candidate);
            if ~strcmp(bundle.status,'development')
                error('nbiot:ui:ModelStatus', ...
                    'Окно сейчас принимает только явно помеченные development-модели.');
            end
            selectedModelFile=candidate;
            modelSelectionError=false;
            modelStatus.Text=sprintf('Пакет проверен: %s · development',bundle.modelName);
            modelForDisplay=bundle;
            modelForDisplay.evaluationMetrics= ...
                nbiot.ui.loadModelEvaluationMetrics(candidate,bundle);
            modelDetails.Value=nbiot.ui.formatModelInfo(modelForDisplay);
            appendLog(['Выбрана development-модель: ' bundle.modelName]);
        catch exception
            modelSelectionError=true;
            modelStatus.Text=['Модель не подходит: ' exception.message];
            modelDetails.Value={'Сведения о модели не показаны, так как пакет не прошёл проверку.'};
            appendLog(['Модель не подходит: ' exception.message]);
            showAlert(exception.message,'Модель не подходит');
        end
        updateModeControls();
    end
    function options=controllerOptionsFor(cfgToRun)
        options=struct();
        if strcmp(cfgToRun.policy.name,'Static'), return; end
        if isempty(selectedModelFile)
            error('nbiot:ui:ModelRequired', ...
                'Для адаптивного режима сначала выберите совместимую модель.');
        end
        bundle=nbiot.ml.validateModelBundle(selectedModelFile);
        if ~strcmp(bundle.status,'development')
            error('nbiot:ui:ModelStatus', ...
                'Эта модель не прошла независимую проверку для обычного запуска.');
        end
        if strcmp(executionProfileName(uiExecution),'external-machine')
            if ~isfield(appOptions,'controllerPolicy')||isempty(appOptions.controllerPolicy)
                error('nbiot:ui:ControllerPolicyRequired', ...
                    'Для внешнего Adaptive требуется полный зафиксированный controllerPolicy.');
            end
            if ~isfield(appOptions,'modelAcceptanceFile')||isempty(appOptions.modelAcceptanceFile)
                error('nbiot:ui:ModelAcceptanceRequired', ...
                    'Для внешнего Adaptive требуется сохранённый допуск модели.');
            end
            % External capability is decided only by the persisted D4 admission
            % validator. The GUI development opt-in never grants that capability.
            options=struct('model',selectedModelFile,'allowDevelopmentModel',false, ...
                'policy',appOptions.controllerPolicy, ...
                'modelAcceptanceFile',checkedModelPath( ...
                    appOptions.modelAcceptanceFile,'modelAcceptanceFile'));
            return;
        end
        if ~allowDevelopmentModel.Value
            error('nbiot:ui:DevelopmentModelOptIn', ...
                'Для учебной модели явно включите разрешение только для отладки.');
        end
        method=cfgToRun.policy.name;
        accessRange=[]; allowedShares=[];
        if strcmp(method,'Adaptive-P')
            accessRange=[allowedPMin.Value allowedPMax.Value];
        else
            allowedShares=allowedRaShares.Value;
        end
        policy=nbiot.controller.buildAdaptivePolicy(method,accessRange,allowedShares);
        if isfield(appOptions,'controllerPolicy') && ~isempty(appOptions.controllerPolicy)
            policy=appOptions.controllerPolicy;
        end
        options=struct('model',selectedModelFile,'allowDevelopmentModel',true,'policy',policy);
        if isfield(appOptions,'modelAcceptanceFile') && ~isempty(appOptions.modelAcceptanceFile)
            options.modelAcceptanceFile=checkedModelPath(appOptions.modelAcceptanceFile, ...
                'modelAcceptanceFile');
        end
    end
    function updateActivityControls(~,~)
        isExplicit=strcmp(char(controls.activityMode.Value),'explicit');
        controls.activeUeIds.Enable=onOff(isExplicit && strcmp(controls.activityMode.Enable,'on'));
    end
    function updateModeControls(~,~)
        method=controls.simulationMode.Value;
        accessControl=controls.accessProbability;
        shareControl=controls.raShare;
        adaptive=~strcmp(method,'Static');
        if strcmp(method,'Adaptive-P')
            shareControl.Value=0.1;
        elseif strcmp(method,'Adaptive-RA/DT')
            accessControl.Value=1;
        end
        accessControl.Enable=onOff(strcmp(method,'Static') && strcmp(session.Status,'idle'));
        shareControl.Enable=onOff(strcmp(method,'Static') && strcmp(session.Status,'idle'));
        adaptiveStartRaShare.Enable=onOff(strcmp(method,'Adaptive-RA/DT') && ...
            strcmp(session.Status,'idle'));
        adaptiveStartProbability.Enable=onOff(strcmp(method,'Adaptive-P') && ...
            strcmp(session.Status,'idle'));
        allowedPMin.Enable=onOff(strcmp(method,'Adaptive-P') && ...
            strcmp(session.Status,'idle'));
        allowedPMax.Enable=onOff(strcmp(method,'Adaptive-P') && ...
            strcmp(session.Status,'idle'));
        allowedRaShares.Enable=onOff(strcmp(method,'Adaptive-RA/DT') && ...
            strcmp(session.Status,'idle'));
        selectModelButton.Enable=onOff(adaptive && strcmp(session.Status,'idle'));
        allowDevelopmentModel.Enable=onOff(adaptive && ...
            strcmp(executionProfileName(uiExecution),'local-development') && ...
            strcmp(session.Status,'idle'));
        if modelSelectionError
            return;
        elseif adaptive && isempty(selectedModelFile)
            modelStatus.Text='Выберите совместимый пакет. Development-модель разрешена только для отладки.';
        elseif ~adaptive && isempty(selectedModelFile)
            modelStatus.Text='Модель не выбрана. Для Static она не нужна.';
        end
    end
    function advanceRun(~,~)
        if ~strcmp(session.Status,'running'), return; end
        try
            session.advance(20); state=session.snapshot();
            if nbiot.ui.shouldRefreshDisplay(state.tick,lastDisplayTick, ...
                    ~strcmp(session.Status,'running'))
                updateView(state); lastDisplayTick=state.tick;
            else
                drawnow limitrate;
            end
            if ~strcmp(session.Status,'running')
                stop(timerHandle); setConfigurationEnabled(true);
                statusLabel.Text=statusText(session.Status,state.tick, ...
                    state.durationTicks,runElapsedSeconds());
                if ~isempty(state.error), appendLog(state.error); end
                appendLog(['Сценарий завершён: ' statusText(session.Status, ...
                    state.tick,state.durationTicks,runElapsedSeconds())]);
                if any(strcmp(session.Status,{'completed','stopped','failed'}))
                    try
                        output=session.getResult(); appendSummary(nbiot.ui.formatResultSummary(output));
                        if strcmp(session.Status,'completed'), drawStaticCharts(output); end
                    catch exception
                        appendSummary(exception.message);
                    end
                end
                refreshButtons();
            end
        catch exception
            try
                session.stop();
            catch
            end
            stop(timerHandle); setConfigurationEnabled(true); statusLabel.Text='Ошибка';
            appendLog(['Ошибка обновления: ' exception.message]); refreshButtons();
        end
    end
    function pauseRun(~,~)
        if strcmp(session.Status,'running')
            stop(timerHandle); session.pause(); state=session.snapshot();
            statusLabel.Text=statusText(session.Status,state.tick, ...
                state.durationTicks,runElapsedSeconds());
            appendLog('Расчёт приостановлен'); refreshButtons();
        end
    end
    function resumeRun(~,~)
        if strcmp(session.Status,'paused')
            session.resume(); state=session.snapshot();
            statusLabel.Text=statusText(session.Status,state.tick, ...
                state.durationTicks,runElapsedSeconds());
            start(timerHandle); appendLog('Расчёт продолжен'); refreshButtons();
        end
    end
    function stopRun(~,~)
        session.stop(); if isvalid(timerHandle), stop(timerHandle); end
        setConfigurationEnabled(true); state=session.snapshot(); updateView(state);
        appendLog('Расчёт остановлен пользователем');
        try
            appendSummary(nbiot.ui.formatResultSummary(session.getResult()));
        catch exception
            appendSummary(exception.message);
        end
        refreshButtons();
    end
    function resetRun(~,~)
        if isvalid(timerHandle), stop(timerHandle); end
        session.reset(); setConfigurationEnabled(true); cla(map); deviceTable.Data=cell(0,4);
        clearStaticCharts(); clearControllerCharts();
        progress.Value=0; statusLabel.Text=calibrationStatus; lastDisplayTick=0;
        lastStaticChartWindow=0;
        latestUeDetails=struct([]); selectedUeId=NaN; latestDisplayState=[];
        selectedUeDetails.Value={'Выберите UE в таблице, чтобы посмотреть подробности.'};
        try
            summaryConfig=readConfiguration();
        catch
            summaryConfig=cfg;
        end
        summary.Value=initialRunSummary(summaryConfig,uiExecution,calibrationStatus);
        eventLog.Value={'Окно готово к запуску'};
        radioEventCursor=0; radioLogLines=cell(0,1); radioHiddenCount=0;
        radioEventLog.Value={'Радиособытий пока нет'};
        hiddenZeroDetectionCount.Text='Скрыто: 0'; updateRadioJournal();
        runStartedAt=[]; clearChartExportFeedback();
        appendLog('Сессия сброшена'); refreshButtons();
    end
    function saveRun(~,~)
        if strcmp(session.Status,'idle'), return; end
        folder=chooseOutputDirectory();
        if isequal(folder,0), return; end
        stamp=char(datetime('now','Format','yyyyMMdd-HHmmss'));
        target=fullfile(folder,['nbiot-' stamp]);
        try
            destination=session.save(target);
            appendLog(['Результат сохранён: ' destination]); statusLabel.Text='Результат сохранён';
            refreshButtons();
        catch exception
            appendLog(['Не удалось сохранить: ' exception.message]);
            showAlert(exception.message,'Не удалось сохранить');
        end
    end
    function exportDataset(~,~)
        if ~strcmp(session.Status,'completed') || isempty(session.SavedPath) || ~isfile(session.SavedPath)
            showAlert('Сначала завершите расчёт и сохраните его результат.','Экспорт датасета');
            return;
        end
        parent=chooseDatasetOutputDirectory();
        if isequal(parent,0), return; end
        stamp=char(datetime('now','Format','yyyyMMdd-HHmmss'));
        target=fullfile(char(parent),['nbiot-dataset-development-' stamp]);
        try
            exported=nbiot.ui.exportDevelopmentDataset(session.SavedPath,target);
            savedInfo.Text=sprintf('Development-набор: %d окон · ID %d · тестовые данные', ...
                exported.rows,exported.realizationId);
            appendLog(sprintf('Development-набор сохранён: %s',exported.outputFolder));
        catch exception
            appendLog(['Не удалось экспортировать набор: ' exception.message]);
            showAlert(exception.message,'Не удалось экспортировать набор');
        end
    end
    function exportCharts(~,~)
        clearChartExportFeedback();
        if ~staticChartsReady||~any(strcmp(session.Status,{'completed','stopped'}))
            chartExportInfo.Text='Сначала завершите или остановите запуск, чтобы сохранить графики.';
            return;
        end
        try
            parent=chooseChartOutputDirectory();
            if isequal(parent,0)||isempty(parent)
                chartExportInfo.Text='Экспорт графиков отменён.';
                return;
            end
            parent=validatedLocalFolder(parent);
            stamp=char(datetime('now','Format','yyyyMMdd-HHmmss'));
            target=fullfile(parent,['nbiot-charts-' stamp]);
            files=nbiot.ui.exportStaticCharts(chartAxes,target);
            if isstring(files), files=cellstr(files); end
            if ischar(files), files=cellstr(files); end
            if ~iscell(files)||isempty(files)
                error('nbiot:ui:ChartExportFiles', ...
                    'Экспорт не вернул пути к PNG-файлам.');
            end
            files=cellfun(@(path) char(string(path)),files,'UniformOutput',false);
            validPng=cellfun(@(path) isPngFile(path)&&isfile(path),files);
            if ~all(validPng)||~isfolder(target)
                error('nbiot:ui:ChartExportFiles', ...
                    'Не все созданные PNG-файлы доступны по возвращённым путям.');
            end
            chartExportOutputPath=validatedLocalFolder(target);
            chartExportInfo.Text=sprintf('Сохранено %d графиков PNG',nnz(validPng));
            chartExportPath.Value={chartExportOutputPath};
            openChartFolderButton.Enable='on';
            appendLog(sprintf('Сохранено графиков PNG: %d · %s', ...
                nnz(validPng),chartExportOutputPath));
        catch exception
            chartExportOutputPath='';
            chartExportInfo.Text=['Не удалось экспортировать графики: ' exception.message];
            chartExportPath.Value={''}; openChartFolderButton.Enable='off';
            appendLog(['Не удалось экспортировать графики: ' exception.message]);
        end
    end
    function openChartOutputFolder(~,~)
        try
            path=validatedLocalFolder(chartExportOutputPath);
            openFolderAdapter(path);
        catch exception
            chartExportInfo.Text=['Не удалось открыть папку: ' exception.message];
            appendLog(['Не удалось открыть папку графиков: ' exception.message]);
        end
    end
    function clearChartExportFeedback()
        chartExportOutputPath='';
        chartExportInfo.Text='Графики ещё не сохранены.';
        chartExportPath.Value={''};
        openChartFolderButton.Enable='off';
    end
    function path=validatedLocalFolder(value)
        if ~(ischar(value)&&isrow(value))&&~(isstring(value)&&isscalar(value))
            error('nbiot:ui:ChartExportFolder','Выберите локальную папку.');
        end
        path=char(string(value));
        if isempty(strtrim(path))||contains(path,'://')||contains(path,char(0))|| ...
                ~isfolder(path)
            error('nbiot:ui:ChartExportFolder', ...
                'Папка должна существовать и иметь локальный абсолютный путь.');
        end
        if ispc
            isAbsolute=~isempty(regexp(path,'^[A-Za-z]:[\\/]', 'once'));
        else
            isAbsolute=startsWith(path,filesep);
        end
        if ~isAbsolute
            error('nbiot:ui:ChartExportFolder', ...
                'Папка должна иметь локальный абсолютный путь.');
        end
        [ok,attributes]=fileattrib(path);
        if ~ok||~isfield(attributes,'Name')
            error('nbiot:ui:ChartExportFolder','Не удалось проверить локальную папку.');
        end
        path=char(attributes.Name);
    end
    function yes=isPngFile(path)
        if ~(ischar(path)&&isrow(path)), yes=false; return; end
        [~,~,extension]=fileparts(path);
        yes=strcmpi(extension,'.png');
    end
    function loadSavedKpi(~,~)
        [files,folder]=chooseKpiFile();
        if isequal(files,0), return; end
        try
            if ischar(files) || isstring(files), files=cellstr(files); end
            if ~iscell(files) || isempty(files)
                error('nbiot:ui:KpiFiles','Выберите один или несколько KPI CSV.');
            end
            selectedPaths=cellfun(@(file) fullfile(folder,char(string(file))), ...
                files,'UniformOutput',false);
            comparison=nbiot.ui.loadKpiCsvFiles(selectedPaths);
            first=comparison.tables{1};
            savedTable.Data=table2cell(first);
            savedTable.ColumnName=first.Properties.VariableNames;
            labels=cell(size(comparison.files));
            for index=1:numel(comparison.files)
                [~,base,extension]=fileparts(comparison.files{index});
                labels{index}=[base extension];
            end
            savedComparison=comparison;
            savedLabels=labels;
            caseLabels=cell(size(labels));
            for index=1:numel(labels)
                view=comparison.reportMetadata{index};
                if isempty(view.caseKey), caseLabels{index}=labels{index};
                else, caseLabels{index}=[view.caseKey ' · ' labels{index}]; end
            end
            savedReportSelector.Items=caseLabels;
            savedReportSelector.ItemsData=1:numel(labels);
            savedReportSelector.Value=1;
            savedReportSelector.Enable='on';
            [metricFields,metricLabels]=availableKpiMetrics(comparison.tables);
            savedMetric.ItemsData=[];
            savedMetric.Items=metricLabels;
            savedMetric.ItemsData=metricFields;
            savedMetric.Value='throughputBitsPerSecond';
            plotSavedKpi();
            updateSavedReportSelection();
            savedInfo.Text=sprintf('%d запуск(а/ов) на графике · таблица: %s · без пересчёта', ...
                numel(labels),labels{1});
            appendLog(sprintf('Загружено KPI-файлов: %d',numel(labels)));
        catch exception
            appendLog(['Не удалось прочитать KPI: ' exception.message]);
            showAlert(exception.message,'Не удалось прочитать KPI');
        end
    end
    function reportSelectionChanged(~,~)
        updateSavedReportSelection();
    end
    function updateSavedReportSelection()
        if isempty(savedComparison)||isempty(savedComparison.reportMetadata), return; end
        index=savedReportSelector.Value;
        if isempty(index)||~isnumeric(index)||index<1||index>numel(savedComparison.tables)
            return
        end
        selected=savedComparison.tables{index};
        savedTable.Data=table2cell(selected);
        savedTable.ColumnName=selected.Properties.VariableNames;
        view=savedComparison.reportMetadata{index};
        savedReportCard.Value=reportCardLines(view,savedLabels{index});
        savedKpiWindowInfo.Text=kpiWindowText(selected,view);
        savedInfo.Text=sprintf('%d запуск(а/ов) на графике · таблица: %s · без пересчёта', ...
            numel(savedLabels),savedLabels{index});
    end
    function loadSavedMethodComparison(~,~)
        folder=chooseComparisonFolder();
        if isequal(folder,0)||isempty(folder), return; end
        try
            savedMethodComparison=nbiot.ui.loadComparisonSummary(folder);
            metrics=savedMethodComparison.metrics;
            metricLabels=cell(numel(metrics),1);
            for index=1:numel(metrics)
                metricLabels{index}=metricLabel(char(metrics(index)));
            end
            methodSummaryMetric.Items=metricLabels;
            methodSummaryMetric.ItemsData=cellstr(metrics(:));
            if any(metrics=="deliveryProbability")
                methodSummaryMetric.Value='deliveryProbability';
            else
                methodSummaryMetric.Value=char(metrics(1));
            end
            durations=savedMethodComparison.burstDurations(:);
            durationLabels=cellstr(compose('%d мс',durations));
            methodSummaryBurst.Items=[{'Все варианты'};durationLabels];
            methodSummaryBurst.ItemsData=[0;durations];
            if isempty(durations), methodSummaryBurst.Value=0;
            else, methodSummaryBurst.Value=durations(1); end
            refreshSavedMethodComparison();
            methodSummaryInfo.Text=sprintf( ...
                'Загружено из %s · показаны полные и неполные случаи.',folder);
            appendLog('Загружена сводка трёх режимов');
        catch exception
            appendLog(['Не удалось открыть сравнение: ' exception.message]);
            showAlert(exception.message,'Не удалось открыть сравнение');
        end
    end
    function refreshSavedMethodComparison(~,~)
        if isempty(savedMethodComparison), return; end
        methods=savedMethodComparison.methodSummary;
        pairs=savedMethodComparison.pairedDifferences;
        selectedMetric=string(methodSummaryMetric.Value);
        selectedBurst=methodSummaryBurst.Value;
        methodMask=string(methods.metric)==selectedMetric;
        pairMask=string(pairs.metric)==selectedMetric;
        if selectedBurst~=0
            methodMask=methodMask&methods.burstDurationTicks==selectedBurst;
            pairMask=pairMask&pairs.burstDurationTicks==selectedBurst;
        end
        methodColumns={'numUE','burstDurationTicks','method','runCount', ...
            'incompleteCount','mean','ci95Low','ci95High'};
        pairColumns={'numUE','burstDurationTicks','methodA','methodB','pairCount', ...
            'incompletePairCount','meanDifference','ci95Low','ci95High'};
        methodView=methods(methodMask,methodColumns);
        pairView=pairs(pairMask,pairColumns);
        methodSummaryTable.Data=table2cell(methodView);
        pairedSummaryTable.Data=table2cell(pairView);
        cla(methodSummaryAxes); hold(methodSummaryAxes,'on');
        methodOrder=["Static";"Adaptive-P";"Adaptive-RA/DT"];
        bursts=unique(methodView.burstDurationTicks,'stable');
        for methodIndex=1:numel(methodOrder)
            for burstIndex=1:numel(bursts)
                rows=methodView(string(methodView.method)==methodOrder(methodIndex)& ...
                    methodView.burstDurationTicks==bursts(burstIndex),:);
                if isempty(rows), continue; end
                rows=sortrows(rows,'numUE');
                displayName=char(methodOrder(methodIndex));
                if selectedBurst==0
                    displayName=sprintf('%s · %d мс',displayName,bursts(burstIndex));
                end
                plot(methodSummaryAxes,rows.numUE,rows.mean,'-o', ...
                    'DisplayName',displayName,'Tag','methodSummaryLine');
                intervalRows=isfinite(rows.ci95Low)&isfinite(rows.ci95High);
                if any(intervalRows)
                    errorbar(methodSummaryAxes,rows.numUE(intervalRows), ...
                        rows.mean(intervalRows), ...
                        rows.mean(intervalRows)-rows.ci95Low(intervalRows), ...
                        rows.ci95High(intervalRows)-rows.mean(intervalRows), ...
                        'LineStyle','none','HandleVisibility','off');
                end
            end
        end
        hold(methodSummaryAxes,'off');
        if ~isempty(findobj(methodSummaryAxes,'Type','line','Tag','methodSummaryLine'))
            legend(methodSummaryAxes,'show','Location','best');
        end
        title(methodSummaryAxes,['Сравнение: ' metricLabel(char(selectedMetric))]);
        xlabel(methodSummaryAxes,'Число устройств');
        ylabel(methodSummaryAxes,metricLabel(char(selectedMetric)));
        grid(methodSummaryAxes,'on');
    end
    function plotSavedKpi(~,~)
        if isempty(savedComparison), return; end
        metric=savedMetric.Value;
        cla(savedAxes);
        hold(savedAxes,'on');
        for index=1:numel(savedComparison.tables)
            series=savedComparison.tables{index};
            plot(savedAxes,double(series.endTick)*.001,double(series.(metric)), ...
                '-o','DisplayName',savedLabels{index});
        end
        hold(savedAxes,'off');
        if numel(savedLabels)>1
            legend(savedAxes,'show','Interpreter','none','Location','best');
        else
            legend(savedAxes,'off');
        end
        title(savedAxes,['Сравнение: ' metricLabel(metric)]);
        xlabel(savedAxes,'Время модели, с');
        ylabel(savedAxes,metricLabel(metric));
        grid(savedAxes,'on');
    end
    function lines=reportCardLines(view,fileLabel)
        fields=view.fields;
        lines={sprintf('Отчёт: %s · %s',view.caseKey,reportStatusText(view.status))};
        identity={};
        if ~isempty(fields.mode), identity{end+1}=fields.mode; end %#ok<AGROW>
        if ~isempty(fields.trafficType), identity{end+1}=fields.trafficType; end %#ok<AGROW>
        if ~isempty(identity), lines{end+1}=['Режим и трафик: ' strjoin(identity,' · ')]; end %#ok<AGROW>
        if isfinite(fields.numUE)
            line=sprintf('%s всего',deviceCountText(fields.numUE));
            if isfinite(fields.activeUE), line=[line ' · ' deviceCountText(fields.activeUE) ' активны']; end
            lines{end+1}=['Устройства: ' line]; %#ok<AGROW>
        else
            lines{end+1}='Устройства: нет данных в отчёте'; %#ok<AGROW>
        end
        loadParts={};
        if isfinite(fields.payloadBytes), loadParts{end+1}=sprintf('%g байт на пакет',fields.payloadBytes); end %#ok<AGROW>
        if strcmp(fields.trafficType,'periodic')&&isfinite(fields.periodTicks)
            loadParts{end+1}=sprintf('период %g тиков',fields.periodTicks); %#ok<AGROW>
        elseif ~isempty(fields.trafficType)&&~strcmp(fields.trafficType,'none')&& ...
                ~strcmp(fields.trafficType,'periodic')
            loadParts{end+1}=['тип ' fields.trafficType]; %#ok<AGROW>
        end
        if ~isempty(loadParts), lines{end+1}=['Нагрузка: ' strjoin(loadParts,' · ')]; %#ok<AGROW>
        elseif isempty(fields.trafficType), lines{end+1}='Нагрузка: нет данных в отчёте'; %#ok<AGROW>
        end
        if isfinite(fields.durationSeconds)
            lines{end+1}=sprintf('Длительность: %s с модели',numberText(fields.durationSeconds)); %#ok<AGROW>
        elseif isfinite(fields.durationTicks)&&isfinite(fields.tickSeconds)
            lines{end+1}=sprintf('Длительность: %s с модели', ...
                numberText(fields.durationTicks*fields.tickSeconds)); %#ok<AGROW>
        else
            lines{end+1}='Длительность: нет данных в отчёте'; %#ok<AGROW>
        end
        if isfinite(fields.planned)
            lines{end+1}=sprintf('План: %g пакетов',fields.planned); %#ok<AGROW>
        elseif strcmp(fields.trafficType,'poisson')
            lines{end+1}='План: точное число для пуассоновского трафика заранее неизвестно'; %#ok<AGROW>
        else
            lines{end+1}='План: нет данных в отчёте'; %#ok<AGROW>
        end
        countNames={'created','delivered','dropped','unfinished'};
        countLabels={'создано','доставлено','неудач','не завершились'};
        counts=cell(1,numel(countNames)); available=true;
        for item=1:numel(countNames)
            value=fields.(countNames{item});
            if ~isfinite(value), available=false; break; end
            counts{item}=sprintf('%g %s',value,countLabels{item});
        end
        if available
            lines{end+1}=['Итоги: ' strjoin(counts,' · ') ' к концу наблюдения']; %#ok<AGROW>
        else
            lines{end+1}='Итоги: нет данных в отчёте'; %#ok<AGROW>
        end
        if strcmp(view.status,'partial')||strcmp(view.status,'invalid')
            if ~isempty(view.reason), lines{end+1}=view.reason; end %#ok<AGROW>
        end
        if isempty(view.caseKey), lines{1}=sprintf('Отчёт: %s · %s',fileLabel,reportStatusText(view.status)); end
    end
    function text=kpiWindowText(series,view)
        if ~all(ismember({'startTick','endTick'},series.Properties.VariableNames))||height(series)==0
            text='Длина окна KPI не указана в отчёте.'; return
        end
        widths=double(series.endTick)-double(series.startTick);
        widths=widths(isfinite(widths)&widths>0);
        if isempty(widths), text='Длина окна KPI не указана в отчёте.'; return; end
        nominal=view.fields.kpiWindowTicks;
        if ~isfinite(nominal), nominal=max(widths); end
        tickSeconds=view.fields.tickSeconds;
        label=windowLengthLabel(nominal,tickSeconds);
        if any(widths<nominal)
            tailLabel=windowLengthLabel(widths(end),tickSeconds);
            text=sprintf('Окна KPI: %s; последнее окно %s — неполное.',label,tailLabel);
        elseif numel(unique(widths))>1
            other=unique(widths(widths~=nominal));
            text=sprintf('Окна KPI разной длины: %s и %s.',label, ...
                strjoin(arrayfun(@(value) windowLengthLabel(value,tickSeconds), ...
                other,'UniformOutput',false),', '));
        else
            text=['Окно KPI: ' label '.'];
        end
    end
    function text=reportStatusText(status)
        switch char(string(status))
            case 'verified', text='проверен';
            case 'partial', text='частично проверен';
            case 'invalid', text='не прошёл проверку';
            otherwise, text='недоступен';
        end
    end
    function text=deviceCountText(value)
        count=double(value);
        if count==fix(count)
            lastTwo=mod(count,100); lastOne=mod(count,10);
            if lastTwo>=11&&lastTwo<=14, noun='устройств';
            elseif lastOne==1, noun='устройство';
            elseif lastOne>=2&&lastOne<=4, noun='устройства';
            else, noun='устройств'; end
            text=sprintf('%g %s',count,noun);
        else
            text=sprintf('%g устройств',count);
        end
    end
    function text=numberText(value)
        text=sprintf('%.4g',double(value));
    end
    function text=windowLengthLabel(ticks,tickSeconds)
        if isfinite(tickSeconds)&&tickSeconds>0
            text=sprintf('%s мс',numberText(ticks*tickSeconds*1000));
        else
            text=sprintf('%g тиков',ticks);
        end
    end
    function toggleMetricExplanations(~,~)
        rowHeights=chartGrid.RowHeight;
        if strcmp(metricExplanationsPanel.Visible,'on')
            metricExplanationsPanel.Visible='off';
            rowHeights{3}=0;
            metricExplanationsToggle.Text='Что означают показатели';
        else
            metricExplanationsPanel.Visible='on';
            rowHeights{3}=150;
            metricExplanationsToggle.Text='Скрыть пояснения показателей';
        end
        chartGrid.RowHeight=rowHeights;
    end
    function lines=metricExplanationLines()
        keys={'created','delivered','dropped','unfinished','ra_success', ...
            'throughput','delay','data_bler','ra_dt','P','bs_queue', ...
            'ue_queue','ue_nonempty_queues','crc_data','connection', ...
            'payload_delivery','packet_segmentation','progress', ...
            'completed_horizon','integer_counts','metric_availability'};
        labels={'Создано','Доставлено','Потеряно','Незавершено', ...
            'Успешный доступ RA','Скорость доставки','Задержка','Data BLER', ...
            'RA/DT','P','Очередь BS','Очередь UE', ...
            'Устройства с непустой очередью','CRC Data','Подключение', ...
            'Доставка полезной нагрузки','Части сообщения','Ход расчёта', ...
            'Горизонт наблюдения','ID и счётчики','Доступность данных'};
        lines=cell(numel(keys),1);
        for explanationIndex=1:numel(keys)
            lines{explanationIndex}=sprintf('%s — %s',labels{explanationIndex}, ...
                nbiot.ui.explainMetric(keys{explanationIndex}));
        end
    end
    function drawStaticCharts(result)
        values=nbiot.ui.buildStaticChartData(result);
        drawStaticChartValues(values);
        staticChartsReady=~isempty(values);
        chartInfo.Text=sprintf(['Итоговые Static-графики · %d окон KPI по 500 мс. ' ...
            'Фактическая нагрузка и столкновения показаны отдельно как диагностика; ' ...
            'прогноз и Adaptive-графики пока недоступны.'],height(values));
    end
    function drawStaticChartValues(values)
        time=values.endTimeSeconds;
        plotChart(chartAxes.activeUe,time,values.meanActiveUe,'Средняя активность UE','Устройств');
        plotChart(chartAxes.actualLoad,time,values.actualLoadMeanRaUe, ...
            'Фактическая нагрузка (диагностика)','UE в RA');
        plotChart(chartAxes.collisions,time,100*values.collisionProbability, ...
            'Столкновения попыток RA','%');
        plotChart(chartAxes.successfulRa,time,values.successfulRa,'Успешные попытки RA','Попыток');
        plotChart(chartAxes.throughput,time,values.throughputBitsPerSecond,'Скорость доставки','бит/с');
        plotChart(chartAxes.delay,time,1000*values.meanDeliveryDelaySeconds, ...
            'Задержка доставленных пакетов','мс');
        plotChart(chartAxes.dataBler,time,100*values.dataBler,'Data BLER','%');
        cla(chartAxes.occupancy); hold(chartAxes.occupancy,'on');
        plot(chartAxes.occupancy,time,100*values.ulOccupancy,'-o','DisplayName','UL');
        plot(chartAxes.occupancy,time,100*values.dlOccupancy,'-o','DisplayName','DL');
        hold(chartAxes.occupancy,'off');
        title(chartAxes.occupancy,'Занятость ресурсов');
        xlabel(chartAxes.occupancy,'Время модели, с'); ylabel(chartAxes.occupancy,'%');
        grid(chartAxes.occupancy,'on'); legend(chartAxes.occupancy,'show','Location','best');
    end
    function updateStaticChartsDuringRun(state)
        if ~strcmp(state.controllerMethod,'Static')||~session.hasResult()|| ...
                strcmp(session.Status,'completed')
            return;
        end
        windowTicks=session.Config.dataset.windowTicks;
        closedWindowCount=floor(min(state.tick,state.durationTicks)/windowTicks);
        if closedWindowCount<=lastStaticChartWindow, return; end
        values=session.liveStaticChartData();
        if isempty(values), return; end
        drawStaticChartValues(values);
        staticChartsReady=true;
        lastStaticChartWindow=height(values);
        chartInfo.Text=sprintf(['Промежуточные Static-графики · окно KPI — 500 мс; ' ...
            'показаны закрытые окна до %.3f с. Графики обновляются после каждого окна; ' ...
            'фактическая нагрузка и столкновения — диагностика.'], ...
            values.endTimeSeconds(end));
    end
    function clearStaticCharts()
        staticChartsReady=false;
        keys=fieldnames(chartAxes);
        for clearIndex=1:numel(keys)
            key=keys{clearIndex}; ax=chartAxes.(key);
            cla(ax);
            specIndex=find(strcmp(chartSpecs(:,1),key),1);
            title(ax,chartSpecs{specIndex,3});
            xlabel(ax,'Время модели, с'); ylabel(ax,chartSpecs{specIndex,4});
            grid(ax,'on');
        end
        legend(chartAxes.occupancy,'off');
        chartInfo.Text=['Графики появятся после завершения локального запуска. ' ...
            'Фактическая нагрузка и столкновения — диагностика; прогноз и Adaptive-графики пока недоступны.'];
    end
    function clearControllerCharts()
        keys=fieldnames(controllerChartAxes);
        for clearIndex=1:numel(keys)
            key=keys{clearIndex}; cla(controllerChartAxes.(key));
        end
        controllerChartInfo.Text='Для Static прогноз и адаптивные графики не используются.';
    end
    function drawControllerCharts(history,method)
        clearControllerCharts();
        if strcmp(method,'Static')||isempty(history), return; end
        time=history.decisionTimeSeconds;
        actual=history.actualLoadMeanRaUe;
        forecast=history.forecastMeanRaUe;
        hold(controllerChartAxes.forecast,'on');
        if any(isfinite(actual))
            plot(controllerChartAxes.forecast,time,actual,'-o', ...
                'DisplayName','Фактическая нагрузка (диагностика)');
        end
        if any(isfinite(forecast))
            plot(controllerChartAxes.forecast,time,forecast,'--s','DisplayName','Прогноз');
        end
        hold(controllerChartAxes.forecast,'off');
        legend(controllerChartAxes.forecast,'show','Location','best');
        access=history.accessProbability;
        if any(isfinite(access))
            plot(controllerChartAxes.access,time,access,'-o');
        end
        raShare=history.raShare;
        if any(isfinite(raShare))
            plot(controllerChartAxes.raDt,time,100*raShare,'-o');
        end
        errorValues=history.forecastErrorMeanRaUe;
        if any(isfinite(errorValues))
            plot(controllerChartAxes.error,time,errorValues,'-o');
            yline(controllerChartAxes.error,0,'k:');
        end
        controllerChartInfo.Text=sprintf(['%s · DEVELOPMENT-модель, только отладка. ' ...
            'Фактическая нагрузка и ошибка показаны только для диагностики.'],method);
    end
    function plotChart(ax,time,series,caption,units)
        cla(ax); plot(ax,time,series,'-o'); title(ax,caption);
        xlabel(ax,'Время модели, с'); ylabel(ax,units); grid(ax,'on');
    end
    function [fields,labels]=availableKpiMetrics(tables)
        fields={}; labels={};
        candidates=tables{1}.Properties.VariableNames;
        excluded={'windowId','startTick','endTick'};
        for candidateIndex=1:numel(candidates)
            field=candidates{candidateIndex};
            if any(strcmp(field,excluded)), continue; end
            presentNumeric=true;
            for tableIndex=1:numel(tables)
                current=tables{tableIndex};
                if ~ismember(field,current.Properties.VariableNames) || ...
                        ~isnumeric(current.(field))
                    presentNumeric=false;
                    break;
                end
            end
            if presentNumeric
                fields{end+1}=field; %#ok<AGROW>
                labels{end+1}=metricLabel(field); %#ok<AGROW>
            end
        end
    end
    function label=metricLabel(field)
        switch field
            case 'throughputBitsPerSecond', label='Скорость доставки, бит/с';
            case 'cohortDeliveryProbability', label='Вероятность доставки';
            case 'created', label='Создано пакетов';
            case 'delivered', label='Доставлено пакетов';
            case 'dropped', label='Потеряно пакетов';
            case 'unfinished', label='Незавершённые пакеты';
            case 'raSuccess', label='Успешный доступ';
            case 'raFailed', label='Неудачные попытки доступа';
            case 'raUnfinished', label='Незавершённые попытки доступа';
            case 'collidingAttempts', label='Попытки с коллизией';
            case 'raSuccessProbability', label='Вероятность успеха доступа';
            case 'raSuccessCompletedProbability', label='Успех среди завершённых попыток';
            case 'meanRaAttempts', label='Среднее число попыток доступа';
            case 'deliveryProbability', label='Вероятность доставки';
            case 'deliveryCompletedProbability', label='Доставка среди завершённых пакетов';
            case 'dropProbability', label='Вероятность потери';
            case 'collisionAttemptProbability', label='Доля попыток с коллизией';
            case 'meanDelayTicks', label='Средняя задержка, мс';
            case 'p95DelayTicks', label='95-й процентиль задержки, мс';
            case 'msg3Bler', label='Доля ошибок Msg3';
            case 'msg3Decoded', label='Принятые блоки Msg3';
            case 'msg3CrcFailures', label='Ошибки CRC Msg3';
            case 'dataBler', label='Доля ошибок данных';
            case 'dataDecoded', label='Принятые блоки данных';
            case 'dataCrcFailures', label='Ошибки CRC данных';
            case 'ulOccupancy', label='Доля занятости UL';
            case 'dlOccupancy', label='Доля занятости DL';
            case 'nprachOccupancy', label='Доля занятости NPRACH';
            case 'deliveredInWindow', label='Доставлено пакетов';
            case 'droppedInWindow', label='Отброшено пакетов';
            case 'raStarted', label='Попытки доступа';
            case 'raSucceededInWindow', label='Успешные попытки доступа';
            case 'raFailedInWindow', label='Неудачные попытки доступа';
            case 'ulTbDecoded', label='Принятые блоки данных';
            case 'ulCrcFailures', label='Ошибки CRC';
            case 'meanBsQueueLength', label='Средняя очередь станции';
            case 'maxBsQueueLength', label='Максимальная очередь станции';
            case 'meanUeQueueLength', label='Средняя очередь устройств';
            case 'maxUeQueueLength', label='Максимальная очередь устройств';
            case 'harqBlocksStarted', label='Начатые блоки HARQ';
            case 'harqBlocksFailed', label='Неуспешные блоки HARQ';
            case 'harqBlocksCensored', label='Блоки HARQ без завершения';
            case 'harqAttemptsStarted', label='Начатые попытки HARQ';
            case 'harqRetryAttempts', label='Повторные попытки HARQ';
            case 'harqRetryTransmissions', label='Повторные передачи HARQ';
            case 'harqFirstTransmissionBler', label='Ошибки HARQ при первой передаче';
            case 'harqAllAttemptBler', label='Ошибки HARQ по всем передачам';
            case 'controllerDecisionCount', label='Решения контроллера';
            case 'controllerSwitches', label='Переключения настроек';
            case 'controllerDecisions', label='Решения контроллера';
            case 'configurationSwitches', label='Переключения настроек';
            otherwise, label=field;
        end
    end
    function updateView(state)
        latestDisplayState=state;
        [newEvents,radioEventCursor]=session.observedEventsSince(radioEventCursor);
        [newLines,newHidden]=nbiot.ui.formatObservedEvents( ...
            newEvents,showZeroDetectionEvents.Value);
        if ~isempty(newLines)||newHidden>0
            radioLogLines=[radioLogLines;newLines];
            radioHiddenCount=radioHiddenCount+newHidden;
            updateRadioEventControls();
        end
        tick=min(state.tick,state.durationTicks);
        progress.Value=100*tick/max(1,state.durationTicks);
        statusLabel.Text=statusText(session.Status,tick,state.durationTicks, ...
            runElapsedSeconds());
        if isfield(state,'ueDetails'), latestUeDetails=state.ueDetails; end
        deviceTable.Data=state.deviceTable;
        refreshSelectedUeDetails();
        if ~isempty(state.positions)
            cla(map); hold(map,'on');
            scatter(map,state.positions(:,1),state.positions(:,2),36,'filled');
            plot(map,0,0,'kp','MarkerSize',13,'MarkerFaceColor',[0.9 0.25 0.2]);
            plot(map,state.radiusM*cos(linspace(0,2*pi,100)), ...
                state.radiusM*sin(linspace(0,2*pi,100)),'k:');
            xlim(map,[-state.radiusM*1.05 state.radiusM*1.05]);
            ylim(map,[-state.radiusM*1.05 state.radiusM*1.05]);
            hold(map,'off');
        end
        refreshRunSummary(state);
        controllerView=nbiot.ui.buildControllerDisplayData(state);
        controllerSummary.Text=controllerView.summary;
        controllerHistory.Data=controllerView.historyDisplay;
        drawControllerCharts(controllerView.history,state.controllerMethod);
        updateStaticChartsDuringRun(state);
        refreshButtons();
        drawnow limitrate;
    end
    function refreshRadioEventPresentation(~,~)
        [allEvents,radioEventCursor]=session.observedEventsSince(0);
        [radioLogLines,radioHiddenCount]=nbiot.ui.formatObservedEvents( ...
            allEvents,showZeroDetectionEvents.Value);
        updateRadioEventControls();
    end
    function elapsed=runElapsedSeconds()
        if isempty(runStartedAt), elapsed=NaN;
        else, elapsed=toc(runStartedAt); end
    end
    function updateRadioEventControls()
        if isempty(radioLogLines)
            radioEventLog.Value={'Радиособытий пока нет'};
        else
            radioEventLog.Value=radioLogLines;
        end
        hiddenZeroDetectionCount.Text=sprintf('Скрыто: %d',radioHiddenCount);
        updateRadioJournal();
    end
    function position=journalPosition()
        screen=get(groot,'ScreenSize');
        width=min(1080,max(1,screen(3)-40));
        height=min(700,max(1,screen(4)-80));
        left=screen(1)+(screen(3)-width)/2;
        bottom=screen(2)+(screen(4)-height)/2;
        position=[left bottom width height];
    end
    function openRadioJournal(~,~)
        if ~isempty(radioJournalFigure)&&isgraphics(radioJournalFigure)
            focus(radioJournalText);
            return;
        end
        radioJournalFigure=uifigure('Name','Журнал радиособытий', ...
            'Position',journalPosition(),'Tag','radioEventJournalFigure');
        radioJournalFigure.CloseRequestFcn=@closeRadioJournal;
        journalGrid=uigridlayout(radioJournalFigure,[2 1]);
        journalGrid.RowHeight={32,'1x'};
        journalGrid.Padding=[10 10 10 10]; journalGrid.RowSpacing=8;
        uilabel(journalGrid,'Text', ...
            'Наблюдаемые события базовой станции · выделите текст для копирования', ...
            'FontWeight','bold');
        radioJournalText=uitextarea(journalGrid,'Editable','off', ...
            'WordWrap','off','FontName','Consolas','FontSize',12, ...
            'Tag','radioEventJournalText');
        updateRadioJournal();
        focus(radioJournalText);
    end
    function updateRadioJournal()
        if isempty(radioJournalText)||~isgraphics(radioJournalText), return; end
        if isempty(radioLogLines)
            radioJournalText.Value={'Радиособытий пока нет'};
        else
            radioJournalText.Value=radioLogLines;
        end
    end
    function closeRadioJournal(source,~)
        try
            if ~isempty(source)&&isgraphics(source)
                source.CloseRequestFcn=[];
                delete(source);
            end
        catch
        end
        radioJournalFigure=[]; radioJournalText=[];
    end
    function refreshRunSummary(state)
        tick=min(state.tick,state.durationTicks);
        crc=state.crcCounters;
        liveSummary=nbiot.ui.formatLiveStateSummary(state);
        radioSummary=nbiot.ui.formatLiveRadioSummary( ...
            state.liveRadioDiagnostics,selectedUeId,state.tickSeconds);
        summaryConfig=session.Config;
        if isempty(fieldnames(summaryConfig)), summaryConfig=cfg; end
        summaryLines=[{sprintf( ...
            'Время модели: %.3f / %.3f с; CRC Msg3: %d ошибок; CRC Data: %d ошибок', ...
            tick*state.tickSeconds,state.durationTicks*state.tickSeconds, ...
            crc.msg3Errors,crc.dataErrors)}; ...
            activeGroupSummaryLines(summaryConfig);liveSummary(:);radioSummary(:)];
        summary.Value=summaryLines(:);
    end
    function selectUe(~,eventData)
        if isempty(eventData.Indices)
            selectedUeId=NaN;
        else
            row=eventData.Indices(1,1);
            if row>=1&&row<=numel(latestUeDetails)
                selectedUeId=double(latestUeDetails(row).ueId);
            else
                selectedUeId=NaN;
            end
        end
        refreshSelectedUeDetails();
        if ~isempty(latestDisplayState)
            refreshRunSummary(latestDisplayState);
        end
    end
    function refreshSelectedUeDetails()
        if ~isfinite(selectedUeId)||isempty(latestUeDetails)
            selectedUeDetails.Value={'Выберите UE в таблице, чтобы посмотреть подробности.'};
            return;
        end
        index=find(double([latestUeDetails.ueId])==selectedUeId,1);
        if isempty(index)
            selectedUeId=NaN;
            selectedUeDetails.Value={'Выберите UE в таблице, чтобы посмотреть подробности.'};
            return;
        end
        detailLines=nbiot.ui.formatUeDetail(latestUeDetails(index));
        if ~isempty(latestDisplayState)&&isfield(latestDisplayState,'liveRadioDiagnostics')
            radioLines=nbiot.ui.formatLiveRadioSummary( ...
                latestDisplayState.liveRadioDiagnostics,selectedUeId, ...
                latestDisplayState.tickSeconds);
            if ~isempty(radioLines)
                perUeRadioMask=cellfun(@(line) ...
                    contains(lower(line),'sinr ue')|| ...
                    contains(lower(line),'последнее событие ue'),radioLines);
                perUeRadioLines=radioLines(perUeRadioMask);
                if ~isempty(perUeRadioLines)
                    detailLines=[detailLines(1),perUeRadioLines,detailLines(2:end)];
                end
            end
        end
        selectedUeDetails.Value=detailLines;
    end
    function refreshButtons()
        active=any(strcmp(session.Status,{'running','paused'}));
        startButton.Enable=onOff(strcmp(session.Status,'idle'));
        pauseButton.Enable=onOff(strcmp(session.Status,'running'));
        resumeButton.Enable=onOff(strcmp(session.Status,'paused'));
        stopButton.Enable=onOff(active);
        resetButton.Enable=onOff(~strcmp(session.Status,'idle'));
        saveButton.Enable=onOff(session.hasResult());
        savedDatasetButton.Enable=onOff(strcmp(session.Status,'completed') && ...
            ~isempty(session.SavedPath) && isfile(session.SavedPath));
        exportChartsButton.Enable=onOff(staticChartsReady&& ...
            any(strcmp(session.Status,{'completed','stopped'})));
    end
    function setConfigurationEnabled(enabled)
        names=fieldnames(controls);
        for index=1:numel(names)
            controls.(names{index}).Enable=onOff(enabled);
        end
        method=controls.simulationMode.Value;
        adaptive=~strcmp(method,'Static');
        controls.accessProbability.Enable=onOff(enabled && ...
            strcmp(method,'Static'));
        controls.raShare.Enable=onOff(enabled && strcmp(method,'Static'));
        adaptiveStartRaShare.Enable=onOff(enabled && strcmp(method,'Adaptive-RA/DT'));
        adaptiveStartProbability.Enable=onOff(enabled && strcmp(method,'Adaptive-P'));
        allowedPMin.Enable=onOff(enabled && strcmp(method,'Adaptive-P'));
        allowedPMax.Enable=onOff(enabled && strcmp(method,'Adaptive-P'));
        allowedRaShares.Enable=onOff(enabled && strcmp(method,'Adaptive-RA/DT'));
        selectModelButton.Enable=onOff(enabled && adaptive);
        allowDevelopmentModel.Enable=onOff(enabled && adaptive && ...
            strcmp(executionProfileName(uiExecution),'local-development'));
        updateActivityControls();
    end
    function appendSummary(line)
        current=summary.Value; if ischar(current), current={current}; end
        current{end+1}=char(line);
        if numel(current)>100, current=current(end-99:end); end
        summary.Value=current;
    end
    function appendLog(line)
        current=eventLog.Value; if ischar(current), current={current}; end
        timestamp=char(datetime('now','Format','HH:mm:ss'));
        current{end+1}=[timestamp ' · ' char(line)];
        if numel(current)>200, current=current(end-199:end); end
        eventLog.Value=current;
    end
    function timerFailed(~,event)
        try
            session.stop();
        catch
        end
        try
            if isa(event.Data,'MException'), appendLog(event.Data.message); end
        catch
        end
        try
            stop(timerHandle);
        catch
        end
        setConfigurationEnabled(true);
        statusLabel.Text='Ошибка таймера'; refreshButtons();
    end
    function closeApp(~,~)
        try
            if isvalid(timerHandle), stop(timerHandle); delete(timerHandle); end
        catch
        end
        try
            if ~isempty(radioJournalFigure)&&isgraphics(radioJournalFigure)
                radioJournalFigure.CloseRequestFcn=[];
                delete(radioJournalFigure);
            end
        catch
        end
        radioJournalFigure=[]; radioJournalText=[];
        session.close(); fig.CloseRequestFcn=[]; delete(fig);
    end
end

function validateAppOptions(options)
if ~isstruct(options)||~isscalar(options)
    error('nbiot:ui:Options','Application options must be a scalar structure.');
end
supported={'execution','simulatorFactory','modelFile','modelAcceptanceFile','controllerPolicy'};
unknown=setdiff(fieldnames(options),supported);
if ~isempty(unknown)
    error('nbiot:ui:Options','Unsupported application option: %s',unknown{1});
end
if isfield(options,'execution') && ~isempty(options.execution) && ...
        (~isstruct(options.execution)||~isscalar(options.execution))
    error('nbiot:ui:Options','execution must be a scalar execution-budget structure.');
end
if isfield(options,'simulatorFactory') && ~isempty(options.simulatorFactory) && ...
        ~isa(options.simulatorFactory,'function_handle')
    error('nbiot:ui:Options','simulatorFactory must be a function handle.');
end
for pathName={'modelFile','modelAcceptanceFile'}
    key=pathName{1};
    if ~isfield(options,key)||isempty(options.(key)), continue; end
    value=options.(key);
    if ~(ischar(value)&&isrow(value))&&~(isstring(value)&&isscalar(value))
        error('nbiot:ui:Options','%s must be a text file path.',key);
    end
    if strlength(string(value))==0
        error('nbiot:ui:Options','%s cannot be an empty file path.',key);
    end
end
if isfield(options,'controllerPolicy') && ~isempty(options.controllerPolicy) && ...
        (~isstruct(options.controllerPolicy)||~isscalar(options.controllerPolicy))
    error('nbiot:ui:Options','controllerPolicy must be a scalar structure.');
end
end

function limit=uiDeviceLimit(execution)
limit=10;
if ~isstruct(execution)||~isscalar(execution)|| ...
        ~all(isfield(execution,{'profile','maxUE'}))
    return;
end
profile=execution.profile;
if ~(ischar(profile)||(isstring(profile)&&isscalar(profile)))|| ...
        ~strcmp(char(string(profile)),'external-machine')
    return;
end
value=execution.maxUE;
if isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&& ...
        value==fix(value)&&value>=1&&value<=65535
    % Only expose a larger UI limit when the complete external budget passes
    % the same validator used immediately before simulator construction.
    probe=nbiot.config.defaultConfig();
    probe.simulation.numUE=1;
    try
        budget=nbiot.experiments.validateExecutionBudget(probe,execution);
        limit=double(budget.maxUE);
    catch
        limit=10;
    end
end
end

function profile=executionProfileName(execution)
profile='local-development';
if ~isstruct(execution)||~isscalar(execution)||~isfield(execution,'profile')
    return;
end
value=execution.profile;
if ischar(value)&&isrow(value)
    profile=value;
elseif isstring(value)&&isscalar(value)
    profile=char(value);
end
end

function path=checkedModelPath(value,fieldName)
if ~(ischar(value)&&isrow(value))&&~(isstring(value)&&isscalar(value))
    error('nbiot:ui:Options','%s must be a text file path.',fieldName);
end
path=char(string(value));
if isempty(path)||~isfile(path)
    error('nbiot:ui:ModelPath','The configured %s file does not exist.',fieldName);
end
end

function lines=initialRunSummary(configuration,execution,calibrationStatus)
if strcmp(executionProfileName(execution),'external-machine')
    role='external';
    if ischar(execution.role)|| (isstring(execution.role)&&isscalar(execution.role))
        role=char(string(execution.role));
    end
    profileLine=['Профиль запуска: внешний · ' role];
else
    profileLine='Профиль запуска: local-development';
end
lines=[{profileLine};activeGroupSummaryLines(configuration);{calibrationStatus}];
end

function lines=activeGroupSummaryLines(configuration)
total=double(configuration.simulation.numUE);
if strcmp(char(string(configuration.traffic.activityMode)),'all')
    active=total;
else
    active=numel(configuration.traffic.activeUeIds);
end
lines={sprintf('UE: всего %d',total);sprintf('Активная группа: %d UE',active)};
end

function text=joinIds(ids)
if isempty(ids), text=''; return; end
text=char(strjoin(compose('%.0f',double(ids(:).')) ,', '));
end

function ids=parseActiveUeIds(textValue)
if isstring(textValue)&&isscalar(textValue)
    raw=char(textValue);
elseif ischar(textValue)&&isrow(textValue)
    raw=textValue;
else
    error('nbiot:ui:InvalidInput','Введите список числовых UE ID через запятую.');
end
raw=strtrim(raw);
if isempty(raw), ids=zeros(1,0); return; end
tokens=regexp(raw,',','split');
tokens=cellfun(@strtrim,tokens,'UniformOutput',false);
if any(cellfun(@isempty,tokens))
    error('nbiot:ui:InvalidInput','Введите непустые числовые UE ID через запятую.');
end
ids=cellfun(@str2double,tokens);
if ~isreal(ids)||any(~isfinite(ids))||any(ids~=fix(ids))
    error('nbiot:ui:InvalidInput','UE ID должны быть конечными целыми числами.');
end
end

function value=parseVector(textValue)
tokens=regexp(strtrim(char(textValue)),'[,;\s]+','split');
if isempty(tokens) || (isscalar(tokens) && isempty(tokens{1}))
    value=[]; return;
end
value=cellfun(@str2double,tokens);
if any(~isfinite(value)), error('nbiot:ui:InvalidInput','Введите список конечных чисел через пробел.'); end
end

function cfg=setNested(cfg,path,value)
parts=strsplit(path,'.');
if isscalar(parts)
    cfg.(parts{1})=value;
else
    cfg.(parts{1})=setNested(cfg.(parts{1}),strjoin(parts(2:end),'.'),value);
end
end

function state=onOff(condition)
if condition, state='on'; else, state='off'; end
end

function text=statusText(status,tick,duration,elapsedSeconds)
switch char(string(status))
    case 'running', phase='Выполняется';
    case 'paused', phase='Пауза';
    case 'completed', phase='Завершён';
    case 'stopped', phase='Остановлен';
    case 'failed', phase='Ошибка';
    otherwise, phase=char(string(status));
end
text=sprintf('%s · %.3f / %.3f с модели',phase,tick*.001,duration*.001);
if nargin>=4&&isnumeric(elapsedSeconds)&&isscalar(elapsedSeconds)&&isfinite(elapsedSeconds)
    text=sprintf('%s\nРеальное время с запуска: %.2f с',text,elapsedSeconds);
end
end

function grid=formGrid(parent,rows)
grid=uigridlayout(parent,[rows 2],'Scrollable','on');
grid.ColumnWidth={'1x',150}; grid.RowHeight=repmat({26},1,rows);
grid.Padding=[8 8 8 8]; grid.RowSpacing=3; grid.UserData=0;
end
