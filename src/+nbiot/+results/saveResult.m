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
if nargin<2 || isempty(folder), folder=result.config.logging.outputFolder; end
if ~isfolder(folder), mkdir(folder); end
runName=exportStem(result);
destination=fullfile(folder,[runName '.mat']);
saveVariables={'result'};
if hasDatasetDiagnostics(result)
    datasetDiagnostics=result.dataset.diagnostics; %#ok<NASGU>
    saveVariables{end+1}='datasetDiagnostics';
end
save(destination,saveVariables{:},'-v7.3');
writeExports(result,folder,runName);
end

function runName=exportStem(result)
%EXPORTSTEM Имя файлов прогона по методу управления, числу UE и номеру реализации.
method='Static';
if isfield(result.config,'policy')&&isfield(result.config.policy,'name')
    method=char(string(result.config.policy.name));
end
switch method
    case 'Static', prefix='static-v1';
    case 'Adaptive-P', prefix='adaptive-p-v1';
    case 'Adaptive-RA/DT', prefix='adaptive-ra-dt-v1';
    otherwise, error('nbiot:results:Method','Unsupported result method %s.',method);
end
runName=sprintf('%s_n%d_r%04d',prefix, ...
    result.config.simulation.numUE,result.config.simulation.realizationId);
end

function writeExports(result,folder,runName)
%WRITEEXPORTS Записывает CSV-таблицы результата рядом с MAT-файлом.
tableData={result.ueSummary,result.kpiTimeSeries,result.dataset.observations, ...
    result.dataset.targets,result.resourceUsage,result.dataset.manifest, ...
    nbiot.results.buildKpiSummaryTable(result)};
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv', ...
    '_resources.csv','_split.csv','_summary.csv'};
if isfield(result,'controllerLog')&&~isempty(result.controllerLog)
    tableData{end+1}=struct2table(result.controllerLog,'AsArray',true);
    suffixes{end+1}='_controller.csv';
end
if isfield(result,'radioDiagnostics')
    tableData{end+1}=nbiot.results.buildRadioDiagnosticsTable(result);
    suffixes{end+1}='_radio.csv';
end
if isfield(result,'groupKpi')
    tableData{end+1}=result.groupKpi;
    suffixes{end+1}='_groups.csv';
end
if hasDatasetDiagnostics(result)
    tableData{end+1}=diagnosticsCsvTable(result.dataset.diagnostics);
    suffixes{end+1}='_diagnostics.csv';
end
for k=1:numel(suffixes)
    writetable(tableData{k},fullfile(folder,[runName suffixes{k}]));
end
end

function value=diagnosticsCsvTable(value)
%DIAGNOSTICSCSVTABLE Логические флаги доступности → строки 'true'/'false' для однозначного CSV.
availabilityNames={'logicalAvailable','physicalAvailable','accessAvailable', ...
    'retryAvailable','delayAvailable'};
for k=1:numel(availabilityNames)
    name=availabilityNames{k};
    if ~ismember(name,value.Properties.VariableNames), continue; end
    flags=value.(name);
    if islogical(flags)
        normalized=flags;
    elseif isnumeric(flags)&&isreal(flags)&&all(isfinite(flags(:)))&& ...
            all(flags(:)==0|flags(:)==1)
        normalized=logical(flags);
    else
        continue
    end
    tokens=repmat("false",size(normalized));
    tokens(normalized)="true";
    value.(name)=tokens;
end
end

function yes=hasDatasetDiagnostics(result)
%HASDATASETDIAGNOSTICS Есть ли в результате таблица диагностики окон датасета.
yes=isfield(result,'dataset')&&isstruct(result.dataset)&& ...
    isfield(result.dataset,'diagnostics')&&istable(result.dataset.diagnostics);
end
