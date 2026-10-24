function destination=saveResult(result,folder)
%SAVERESULT Сохраняет результат прогона: MAT и CSV-таблицы (ТЗ §46.14, §47).
%   DESTINATION = nbiot.results.saveResult(RESULT, FOLDER) — путь к MAT-файлу.
%   FOLDER по умолчанию — result.config.logging.outputFolder (results/, не в git).
%   Имя: <метод>_n<число UE>_r<номер реализации>, например static-v1_n100_r0000.
%   Файлы:
%     <имя>.mat               — struct result целиком (+ datasetDiagnostics), формат v7.3;
%     <имя>_summary.csv       — итоговые KPI одной строкой (ТЗ §27);
%     <имя>_kpi.csv           — KPI по окнам 500 мс;
%     <имя>_observations.csv  — признаки BS по окнам (вход ML, ТЗ §22);
%     <имя>_targets.csv       — целевые величины по окнам (истина, ТЗ §22);
%     <имя>_ue.csv            — таблица по UE (ТЗ §47 Per-UE);
%     <имя>_resources.csv     — квоты и занятость RA/DT по окнам;
%     <имя>_split.csv         — роль реализации: train/validation/test;
%     <имя>_controller.csv    — журнал решений контроллера (только Adaptive-*);
%     <имя>_radio.csv, _groups.csv, _diagnostics.csv — радиодиагностика, KPI по группам UE,
%                               диагностика окон (если есть в результате).
%   Существующие файлы с тем же именем перезаписываются.
% Папка по умолчанию — из конфигурации.
if nargin<2 || isempty(folder), folder=result.config.logging.outputFolder; end
% Создаём папку, если её нет.
if ~isfolder(folder), mkdir(folder); end
% Имя прогона: метод, число UE, номер реализации.
runName=exportStem(result);
% Путь к MAT-файлу.
destination=fullfile(folder,[runName '.mat']);
% Сохраняемые переменные.
saveVariables={'result'};
% Если есть диагностика окон датасета —
if hasDatasetDiagnostics(result)
    % отдельная переменная;
    datasetDiagnostics=result.dataset.diagnostics; %#ok<NASGU>
    % добавляем в список.
    saveVariables{end+1}='datasetDiagnostics';
end
% Сохраняем MAT (v7.3 — для больших результатов).
save(destination,saveVariables{:},'-v7.3');
% Пишем CSV-таблицы рядом.
writeExports(result,folder,runName);
end

function runName=exportStem(result)
%EXPORTSTEM Имя файлов прогона по методу управления, числу UE и номеру реализации.
% Метод по умолчанию — Static.
method='Static';
% Если политика указана —
if isfield(result.config,'policy')&&isfield(result.config.policy,'name')
    % имя метода.
    method=char(string(result.config.policy.name));
end
% Префикс имени по методу:
switch method
    % Static;
    case 'Static', prefix='static-v1';
    % Adaptive-P;
    case 'Adaptive-P', prefix='adaptive-p-v1';
    % Adaptive-RA/DT;
    case 'Adaptive-RA/DT', prefix='adaptive-ra-dt-v1';
    % иной метод — ошибка.
    otherwise, error('nbiot:results:Method','Unsupported result method %s.',method);
end
% Имя: префикс, число UE, номер реализации.
runName=sprintf('%s_n%d_r%04d',prefix, ...
    result.config.simulation.numUE,result.config.simulation.realizationId);
end

function writeExports(result,folder,runName)
%WRITEEXPORTS Записывает CSV-таблицы результата рядом с MAT-файлом.
% Таблицы: UE, KPI по окнам, признаки и цели датасета, ...
tableData={result.ueSummary,result.kpiTimeSeries,result.dataset.observations, ...
    result.dataset.targets,result.resourceUsage,result.dataset.manifest, ...
    nbiot.results.buildKpiSummaryTable(result)};
% ... и суффиксы их файлов.
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv', ...
    '_resources.csv','_split.csv','_summary.csv'};
% Если есть журнал контроллера —
if isfield(result,'controllerLog')&&~isempty(result.controllerLog)
    % его таблица;
    tableData{end+1}=struct2table(result.controllerLog,'AsArray',true);
    % файл _controller.csv.
    suffixes{end+1}='_controller.csv';
end
% Если есть радиодиагностика —
if isfield(result,'radioDiagnostics')
    % её таблица;
    tableData{end+1}=nbiot.results.buildRadioDiagnosticsTable(result);
    % файл _radio.csv.
    suffixes{end+1}='_radio.csv';
end
% Если есть KPI групп —
if isfield(result,'groupKpi')
    % таблица;
    tableData{end+1}=result.groupKpi;
    % файл _groups.csv.
    suffixes{end+1}='_groups.csv';
end
% Если есть диагностика окон —
if hasDatasetDiagnostics(result)
    % её таблица для CSV;
    tableData{end+1}=diagnosticsCsvTable(result.dataset.diagnostics);
    % файл _diagnostics.csv.
    suffixes{end+1}='_diagnostics.csv';
end
% Для каждой таблицы:
for k=1:numel(suffixes)
    % пишем CSV.
    writetable(tableData{k},fullfile(folder,[runName suffixes{k}]));
end
end

function value=diagnosticsCsvTable(value)
%DIAGNOSTICSCSVTABLE Логические флаги доступности → строки 'true'/'false' для однозначного CSV.
% Столбцы-признаки доступности диагностики.
availabilityNames={'logicalAvailable','physicalAvailable','accessAvailable', ...
    'retryAvailable','delayAvailable'};
% Для каждого такого столбца:
for k=1:numel(availabilityNames)
    % имя;
    name=availabilityNames{k};
    % нет столбца — дальше;
    if ~ismember(name,value.Properties.VariableNames), continue; end
    % значения;
    flags=value.(name);
    % логические —
    if islogical(flags)
        % как есть;
        normalized=flags;
    % числовые 0/1 —
    elseif isnumeric(flags)&&isreal(flags)&&all(isfinite(flags(:)))&& ...
            all(flags(:)==0|flags(:)==1)
        % в логические;
        normalized=logical(flags);
    else
        continue
    end
    % в CSV — текст "true"/"false";
    tokens=repmat("false",size(normalized));
    % истинные значения;
    tokens(normalized)="true";
    % заменяем столбец.
    value.(name)=tokens;
end
end

function yes=hasDatasetDiagnostics(result)
%HASDATASETDIAGNOSTICS Есть ли в результате таблица диагностики окон датасета.
% Есть ли в результате таблица диагностики окон датасета.
yes=isfield(result,'dataset')&&isstruct(result.dataset)&& ...
    isfield(result.dataset,'diagnostics')&&istable(result.dataset.diagnostics);
end
