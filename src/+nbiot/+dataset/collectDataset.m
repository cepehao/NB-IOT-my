function summary=collectDataset(cfgs,outputFolder,options)
%COLLECTDATASET Прогоняет список сценариев и собирает один датасет для обучения (ТЗ §22, §28–29).
%   SUMMARY = nbiot.dataset.collectDataset(CFGS, OUTPUTFOLDER, OPTIONS)
%
%   CFGS — cell-массив конфигураций (nbiot.config.defaultConfig с изменёнными полями), по одной на прогон.
%   Каждая конфигурация — отдельный прогон; разные внешние реализации задаются
%   cfg.simulation.realizationId (0..3999: от него зависит роль train/validation/test, ТЗ §40).
%
%   OUTPUTFOLDER — папка результатов (рекомендуется внутри results/, она не попадает в git):
%     dataset.csv          — все окна всех успешных прогонов: описание прогона + признаки BS + target;
%     runs.csv             — по строке на прогон: параметры, статус, время расчёта, основные KPI;
%     runs/run_NNNN/       — полный результат каждого прогона (nbiot.results.saveResult), если saveRuns.
%
%   OPTIONS (все необязательны):
%     calibrationFile   — файл калибровки NPRACH (по умолчанию results/nprach-calibration.mat проекта);
%                         подставляется, если в cfg порог не загружен;
%     controllerOptions — опции контроллера для Adaptive-* (оценщик): struct для всех прогонов или
%                         cell-массив по одной на прогон; для Static — пустая struct;
%     useParallel       — true: прогоны параллельно (parfor по прогонам, нужен Parallel Computing Toolbox);
%     saveRuns          — сохранять ли полный результат каждого прогона (по умолчанию true);
%     overwrite         — перезаписать существующий dataset.csv (по умолчанию false — ошибка).
%
%   Столбцы dataset.csv:
%     runIndex, policyName, numUE, trafficKind, seed, split — описание прогона (НЕ признаки модели);
%     realizationId, windowId, startTick, endTick           — ключи окна 500 мс;
%     featureSchema().inputNames                            — признаки BS (вход модели);
%     meanRaUe (основной target), meanActiveUe, meanWaitingQueuePerUe, msg1Transmissions,
%     uniqueMsg1Ue                                          — истина симулятора (только как target).
%
%   SUMMARY: dataset (table), runs (table), files (пути), failed (число неуспешных прогонов).
%   Неуспешный прогон не останавливает сбор: он отмечается в runs.csv и не попадает в dataset.csv.
% Опции по умолчанию — пустая struct.
if nargin<3||isempty(options), options=struct(); end
% Массив struct конфигураций превращаем в cell (одна конфигурация — один элемент).
if isstruct(cfgs), cfgs=num2cell(cfgs); end
% Нужен непустой cell-массив конфигураций.
if ~iscell(cfgs)||isempty(cfgs)
    error('nbiot:dataset:Scenarios','Supply a nonempty cell array of configurations.');
end
% Подставляем значения опций по умолчанию и проверяем их.
options=withDefaults(options,numel(cfgs));
% Путь итогового датасета.
datasetFile=fullfile(outputFolder,'dataset.csv');
% Путь сводки по прогонам.
runsFile=fullfile(outputFolder,'runs.csv');
% Не перезаписываем существующий датасет без явного разрешения.
if isfile(datasetFile)&&~options.overwrite
    error('nbiot:dataset:Exists','%s already exists; set options.overwrite=true or choose another folder.',datasetFile);
end
% Создаём папку результатов, если её нет.
if ~isfolder(outputFolder), mkdir(outputFolder); end

% Калибровка NPRACH подставляется один раз на стороне клиента (воркерам не нужен файл).
% Для каждой конфигурации:
for k=1:numel(cfgs)
    % если порог детектора NPRACH не загружен —
    if ~isfinite(cfgs{k}.phy.nprachThreshold)
        % загружаем калибровку из файла;
        cfgs{k}=nbiot.phy.nprach.loadCalibration(cfgs{k},options.calibrationFile);
    end
    % проверяем конфигурацию заранее, чтобы ошибка была до долгих расчётов;
    nbiot.config.validateConfig(cfgs{k});
    % Номера 4000+ зарезервированы под калибровку NPRACH; роль train/validation/test — по 0..3999.
    % номер реализации должен быть 0..3999.
    if cfgs{k}.simulation.realizationId>=4000
        error('nbiot:dataset:RealizationId','Configuration %d: realizationId must be in 0..3999.',k);
    end
end

% Число прогонов; заготовки для строк датасета и строк сводки по каждому прогону.
count=numel(cfgs); rows=cell(count,1); runRows=cell(count,1);
% Локальные копии опций (нужны для parfor: воркер получает только переменные цикла).
controllerOptions=options.controllerOptions; saveRuns=options.saveRuns;
% Параллельный режим:
if options.useParallel
    % прогоны распределяются по воркерам пула (каждый прогон независим);
    parfor k=1:count
        % прогон k → строки датасета и строка сводки.
        [rows{k},runRows{k}]=runOne(k,cfgs{k},controllerOptions{k},outputFolder,saveRuns);
    end
% Последовательный режим:
else
    % прогоны по очереди;
    for k=1:count
        % прогон k → строки датасета и строка сводки;
        [rows{k},runRows{k}]=runOne(k,cfgs{k},controllerOptions{k},outputFolder,saveRuns);
        % печать прогресса: номер прогона, статус, время расчёта.
        fprintf('collectDataset: run %d/%d %s (%.1f s)\n',k,count, ...
            runRows{k}.status,runRows{k}.elapsedSeconds);
    end
end
% Убираем пустые результаты (неуспешные прогоны).
rows=rows(~cellfun(@isempty,rows));
% Склеиваем строки всех прогонов в одну таблицу.
dataset=vertcat(rows{:});
% Если успешных прогонов нет — пустая таблица.
if isempty(dataset), dataset=table(); end
% Склеиваем сводку по прогонам.
runs=vertcat(runRows{:});
% Записываем датасет в CSV.
writetable(dataset,datasetFile);
% Записываем сводку по прогонам в CSV.
writetable(runs,runsFile);
% Результат: таблицы, пути к файлам, число неуспешных прогонов.
summary=struct('dataset',dataset,'runs',runs, ...
    'files',struct('dataset',datasetFile,'runs',runsFile,'runsFolder',fullfile(outputFolder,'runs')), ...
    'failed',sum(runs.status~="completed"));
end

%RUNONE Один прогон: результат → строки датасета (окна) и строка сводки прогона.
function [rows,runRow]=runOne(k,cfg,controllerOptions,outputFolder,saveRuns)
%RUNONE Один прогон: результат → строки датасета (окна) и строка сводки прогона.
% Засекаем время расчёта.
started=tic;
% Схема датасета (ключи, признаки, target).
schema=nbiot.dataset.featureSchema();
% Функция: N строк описания прогона (номер, метод, число UE, тип трафика, seed).
describe=@(n) table(repmat(k,n,1),repmat(string(cfg.policy.name),n,1), ...
    repmat(cfg.simulation.numUE,n,1),repmat(string(cfg.traffic.kind),n,1), ...
    repmat(cfg.simulation.seed,n,1), ...
    'VariableNames',{'runIndex','policyName','numUE','trafficKind','seed'});
% Запускаем прогон;
try
    % nbiot.runExperiment — создание симулятора, расчёт до горизонта, результат.
    result=nbiot.runExperiment(cfg,[],controllerOptions);
% Исключение (например, нет оценщика для Adaptive) —
catch exception
    % Ошибка конфигурации/опций прогона: фиксируется, сбор остальных прогонов продолжается.
    % время до ошибки; строк датасета нет;
    elapsed=toc(started); rows=table();
    % строка сводки со статусом failed, текстом ошибки и NaN вместо KPI;
    runRow=[describe(1),table(cfg.simulation.realizationId,"failed",string(exception.message),elapsed, ...
        NaN,NaN,NaN,NaN,NaN,NaN,'VariableNames',runColumns())];
    return;
end
% Время расчёта прогона.
elapsed=toc(started);
% Итоговые KPI прогона.
kpi=result.kpiSummary;
% Текст ошибки (пусто, если прогон без ошибки).
message="";
% Если в результате есть ошибка —
if isfield(result,'error')&&isstruct(result.error)&&isfield(result.error,'message')
    % берём её сообщение.
    message=string(result.error.message);
end
% Строка сводки: описание, реализация, статус, ошибка, время, создано/доставлено, основные вероятности и throughput.
runRow=[describe(1),table(cfg.simulation.realizationId,string(result.status),message,elapsed, ...
    kpi.created,kpi.delivered,kpi.raSuccessProbability,kpi.deliveryProbability, ...
    kpi.throughputBitsPerSecond,kpi.collisionAttemptProbability,'VariableNames',runColumns())];
% Если нужно —
if saveRuns
    % сохраняем полный результат прогона в runs/run_NNNN (MAT + CSV).
    nbiot.results.saveResult(result,fullfile(outputFolder,'runs',sprintf('run_%04d',k)));
end
% Неуспешный или незавершённый прогон в датасет не попадает.
if ~strcmp(result.status,'completed')
    rows=table(); return;
end
% Признаки BS по окнам.
observations=result.dataset.observations;
% Target по окнам (те же ключи окон, в том же порядке).
targets=result.dataset.targets;
% Ключи окон признаков и target совпадают (проверяется в NBIoTSimulator.result).
% Столбцы target без ключей окна.
targetColumns=setdiff(schema.targetNames,schema.keyNames,'stable');
% Роль реализации этого прогона: train / validation / test.
split=result.dataset.manifest.split(result.dataset.manifest.externalRealizationId== ...
    cfg.simulation.realizationId);
% Число окон прогона.
n=height(observations);
% Строки датасета: описание прогона, роль, ключи окна, признаки модели, target.
rows=[describe(n),table(repmat(string(split),n,1),'VariableNames',{'split'}), ...
    observations(:,[schema.keyNames schema.inputNames]),targets(:,targetColumns)];
end

%RUNCOLUMNS Столбцы сводки прогона в runs.csv (после описания прогона).
function names=runColumns()
%RUNCOLUMNS Столбцы сводки прогона в runs.csv (после описания прогона).
% Имена столбцов сводки прогона.
names={'realizationId','status','errorMessage','elapsedSeconds','created','delivered', ...
    'raSuccessProbability','deliveryProbability','throughputBitsPerSecond','collisionAttemptProbability'};
end

%WITHDEFAULTS Значения опций по умолчанию и проверка опций контроллера.
function options=withDefaults(options,count)
%WITHDEFAULTS Значения опций по умолчанию и проверка опций контроллера.
% Корень проекта (на 4 уровня выше этого файла).
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
% Значения по умолчанию: файл калибровки, без контроллера, последовательно, с сохранением, без перезаписи.
defaults=struct('calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'controllerOptions',struct(),'useParallel',false,'saveRuns',true,'overwrite',false);
% Переданные поля опций;
names=fieldnames(options);
% неизвестные поля —
unknown=setdiff(names,fieldnames(defaults));
% ошибка;
if ~isempty(unknown), error('nbiot:dataset:Options','Unknown option %s.',unknown{1}); end
% переданные значения заменяют значения по умолчанию.
for k=1:numel(names), defaults.(names{k})=options.(names{k}); end
% Итоговые опции.
options=defaults;
% Одна struct опций контроллера —
if isstruct(options.controllerOptions)
    % повторяется для каждого прогона;
    options.controllerOptions=repmat({options.controllerOptions},count,1);
% иначе нужен cell-массив по одной struct на прогон.
elseif ~iscell(options.controllerOptions)||numel(options.controllerOptions)~=count
    error('nbiot:dataset:Options','controllerOptions must be one struct or one cell per configuration.');
end
end
