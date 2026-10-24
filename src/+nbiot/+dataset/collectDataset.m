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
if nargin<3||isempty(options), options=struct(); end
if isstruct(cfgs), cfgs=num2cell(cfgs); end
if ~iscell(cfgs)||isempty(cfgs)
    error('nbiot:dataset:Scenarios','Supply a nonempty cell array of configurations.');
end
options=withDefaults(options,numel(cfgs));
datasetFile=fullfile(outputFolder,'dataset.csv');
runsFile=fullfile(outputFolder,'runs.csv');
if isfile(datasetFile)&&~options.overwrite
    error('nbiot:dataset:Exists','%s already exists; set options.overwrite=true or choose another folder.',datasetFile);
end
if ~isfolder(outputFolder), mkdir(outputFolder); end

% Калибровка NPRACH подставляется один раз на стороне клиента (воркерам не нужен файл).
for k=1:numel(cfgs)
    if ~isfinite(cfgs{k}.phy.nprachThreshold)
        cfgs{k}=nbiot.phy.nprach.loadCalibration(cfgs{k},options.calibrationFile);
    end
    nbiot.config.validateConfig(cfgs{k});
    % Номера 4000+ зарезервированы под калибровку NPRACH; роль train/validation/test — по 0..3999.
    if cfgs{k}.simulation.realizationId>=4000
        error('nbiot:dataset:RealizationId','Configuration %d: realizationId must be in 0..3999.',k);
    end
end

count=numel(cfgs); rows=cell(count,1); runRows=cell(count,1);
controllerOptions=options.controllerOptions; saveRuns=options.saveRuns;
if options.useParallel
    parfor k=1:count
        [rows{k},runRows{k}]=runOne(k,cfgs{k},controllerOptions{k},outputFolder,saveRuns);
    end
else
    for k=1:count
        [rows{k},runRows{k}]=runOne(k,cfgs{k},controllerOptions{k},outputFolder,saveRuns);
        fprintf('collectDataset: run %d/%d %s (%.1f s)\n',k,count, ...
            runRows{k}.status,runRows{k}.elapsedSeconds);
    end
end
rows=rows(~cellfun(@isempty,rows));
dataset=vertcat(rows{:});
if isempty(dataset), dataset=table(); end
runs=vertcat(runRows{:});
writetable(dataset,datasetFile);
writetable(runs,runsFile);
summary=struct('dataset',dataset,'runs',runs, ...
    'files',struct('dataset',datasetFile,'runs',runsFile,'runsFolder',fullfile(outputFolder,'runs')), ...
    'failed',sum(runs.status~="completed"));
end

function [rows,runRow]=runOne(k,cfg,controllerOptions,outputFolder,saveRuns)
%RUNONE Один прогон: результат → строки датасета (окна) и строка сводки прогона.
started=tic;
schema=nbiot.dataset.featureSchema();
describe=@(n) table(repmat(k,n,1),repmat(string(cfg.policy.name),n,1), ...
    repmat(cfg.simulation.numUE,n,1),repmat(string(cfg.traffic.kind),n,1), ...
    repmat(cfg.simulation.seed,n,1), ...
    'VariableNames',{'runIndex','policyName','numUE','trafficKind','seed'});
try
    result=nbiot.runExperiment(cfg,[],controllerOptions);
catch exception
    % Ошибка конфигурации/опций прогона: фиксируется, сбор остальных прогонов продолжается.
    elapsed=toc(started); rows=table();
    runRow=[describe(1),table(cfg.simulation.realizationId,"failed",string(exception.message),elapsed, ...
        NaN,NaN,NaN,NaN,NaN,NaN,'VariableNames',runColumns())];
    return;
end
elapsed=toc(started);
kpi=result.kpiSummary;
message="";
if isfield(result,'error')&&isstruct(result.error)&&isfield(result.error,'message')
    message=string(result.error.message);
end
runRow=[describe(1),table(cfg.simulation.realizationId,string(result.status),message,elapsed, ...
    kpi.created,kpi.delivered,kpi.raSuccessProbability,kpi.deliveryProbability, ...
    kpi.throughputBitsPerSecond,kpi.collisionAttemptProbability,'VariableNames',runColumns())];
if saveRuns
    nbiot.results.saveResult(result,fullfile(outputFolder,'runs',sprintf('run_%04d',k)));
end
if ~strcmp(result.status,'completed')
    rows=table(); return;
end
observations=result.dataset.observations;
targets=result.dataset.targets;
% Ключи окон признаков и target совпадают (проверяется в NBIoTSimulator.result).
targetColumns=setdiff(schema.targetNames,schema.keyNames,'stable');
split=result.dataset.manifest.split(result.dataset.manifest.externalRealizationId== ...
    cfg.simulation.realizationId);
n=height(observations);
rows=[describe(n),table(repmat(string(split),n,1),'VariableNames',{'split'}), ...
    observations(:,[schema.keyNames schema.inputNames]),targets(:,targetColumns)];
end

function names=runColumns()
%RUNCOLUMNS Столбцы сводки прогона в runs.csv (после описания прогона).
names={'realizationId','status','errorMessage','elapsedSeconds','created','delivered', ...
    'raSuccessProbability','deliveryProbability','throughputBitsPerSecond','collisionAttemptProbability'};
end

function options=withDefaults(options,count)
%WITHDEFAULTS Значения опций по умолчанию и проверка опций контроллера.
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
defaults=struct('calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'controllerOptions',struct(),'useParallel',false,'saveRuns',true,'overwrite',false);
names=fieldnames(options);
unknown=setdiff(names,fieldnames(defaults));
if ~isempty(unknown), error('nbiot:dataset:Options','Unknown option %s.',unknown{1}); end
for k=1:numel(names), defaults.(names{k})=options.(names{k}); end
options=defaults;
if isstruct(options.controllerOptions)
    options.controllerOptions=repmat({options.controllerOptions},count,1);
elseif ~iscell(options.controllerOptions)||numel(options.controllerOptions)~=count
    error('nbiot:dataset:Options','controllerOptions must be one struct or one cell per configuration.');
end
end
