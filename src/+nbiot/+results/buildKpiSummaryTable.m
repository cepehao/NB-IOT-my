function summary=buildKpiSummaryTable(result)
%BUILDKPISUMMARYTABLE Flatten final scalar KPIs into one CSV-friendly row.
%   Итоговые скалярные KPI одной строкой таблицы (для CSV, ТЗ §46.14).
required={'status','config','kpiSummary'};
if ~isstruct(result)||~isscalar(result)||~all(isfield(result,required))|| ...
        ~isstruct(result.kpiSummary)||~isscalar(result.kpiSummary)
    error('nbiot:results:KpiSummary','Result does not match the final KPI summary schema.');
end
method='Static';
if isfield(result.config,'policy')&&isfield(result.config.policy,'name')
    method=char(string(result.config.policy.name));
end
numUE=NaN; durationTicks=NaN;
if isfield(result.config,'simulation')&&isstruct(result.config.simulation)
    if isfield(result.config.simulation,'numUE'), numUE=double(result.config.simulation.numUE); end
    if isfield(result.config.simulation,'durationTicks')
        durationTicks=double(result.config.simulation.durationTicks);
    end
end
row=struct('runStatus',string(result.status), ...
    'method',string(method),'numUE',numUE,'durationTicks',durationTicks);
row=appendScalars(row,result.kpiSummary,'kpi');
summary=struct2table(row,'AsArray',true);
end

function row=appendScalars(row,value,prefix)
if isstruct(value)&&isscalar(value)
    names=fieldnames(value);
    for k=1:numel(names)
        row=appendScalars(row,value.(names{k}),[prefix '_' names{k}]);
    end
elseif isnumeric(value)&&isreal(value)&&isscalar(value)
    row.(matlab.lang.makeValidName(prefix))=double(value);
elseif islogical(value)&&isscalar(value)
    row.(matlab.lang.makeValidName(prefix))=value;
elseif isstring(value)&&isscalar(value)
    row.(matlab.lang.makeValidName(prefix))=value;
elseif ischar(value)&&isrow(value)
    row.(matlab.lang.makeValidName(prefix))=string(value);
end
end
