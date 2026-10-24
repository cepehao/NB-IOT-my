function summary=buildKpiSummaryTable(result)
%BUILDKPISUMMARYTABLE Flatten final scalar KPIs into one CSV-friendly row.
%   Итоговые скалярные KPI одной строкой таблицы (для CSV, ТЗ §46.14).
% Обязательные поля результата.
required={'status','config','kpiSummary'};
% Нужен скалярный struct с этими полями и struct KPI;
if ~isstruct(result)||~isscalar(result)||~all(isfield(result,required))|| ...
        ~isstruct(result.kpiSummary)||~isscalar(result.kpiSummary)
    % иначе ошибка.
    error('nbiot:results:KpiSummary','Result does not match the final KPI summary schema.');
end
% Метод по умолчанию — Static.
method='Static';
% Если в конфигурации указана политика —
if isfield(result.config,'policy')&&isfield(result.config.policy,'name')
    % имя метода из неё.
    method=char(string(result.config.policy.name));
end
% Число UE и длительность по умолчанию неизвестны.
numUE=NaN; durationTicks=NaN;
% Если в конфигурации есть раздел simulation —
if isfield(result.config,'simulation')&&isstruct(result.config.simulation)
    % число UE;
    if isfield(result.config.simulation,'numUE'), numUE=double(result.config.simulation.numUE); end
    % длительность в тиках;
    if isfield(result.config.simulation,'durationTicks')
        durationTicks=double(result.config.simulation.durationTicks);
    end
end
% Строка: статус, метод, число UE, длительность.
row=struct('runStatus',string(result.status), ...
    'method',string(method),'numUE',numUE,'durationTicks',durationTicks);
% Добавляем все скалярные KPI с префиксом kpi_.
row=appendScalars(row,result.kpiSummary,'kpi');
% Таблица из одной строки.
summary=struct2table(row,'AsArray',true);
end

%APPENDSCALARS Рекурсивно добавляет скалярные поля VALUE как столбцы PREFIX_имя.
function row=appendScalars(row,value,prefix)
% Скалярный struct —
if isstruct(value)&&isscalar(value)
    % его поля;
    names=fieldnames(value);
    % для каждого поля —
    for k=1:numel(names)
        % рекурсивно с расширенным префиксом.
        row=appendScalars(row,value.(names{k}),[prefix '_' names{k}]);
    end
% Число —
elseif isnumeric(value)&&isreal(value)&&isscalar(value)
    % столбец double.
    row.(matlab.lang.makeValidName(prefix))=double(value);
% Логическое —
elseif islogical(value)&&isscalar(value)
    % столбец logical.
    row.(matlab.lang.makeValidName(prefix))=value;
% Строка string —
elseif isstring(value)&&isscalar(value)
    % столбец string.
    row.(matlab.lang.makeValidName(prefix))=value;
% Строка char —
elseif ischar(value)&&isrow(value)
    % столбец string.
    row.(matlab.lang.makeValidName(prefix))=string(value);
end
end
