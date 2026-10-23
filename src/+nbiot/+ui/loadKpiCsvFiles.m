function loaded=loadKpiCsvFiles(filePaths)
%LOADKPICSVFILES Read one or more saved KPI tables for display/comparison.
if ischar(filePaths) || isstring(filePaths)
    filePaths=cellstr(filePaths);
end
if ~iscell(filePaths) || isempty(filePaths)
    error('nbiot:ui:KpiFiles','Choose one or more saved KPI CSV files.');
end

paths=cell(size(filePaths));
tables=cell(size(filePaths));
reportMetadata=cell(size(filePaths));
required={'endTick','throughputBitsPerSecond','cohortDeliveryProbability'};
for k=1:numel(filePaths)
    path=filePaths{k};
    if isstring(path) && isscalar(path), path=char(path); end
    if ~ischar(path) || isempty(strtrim(path))
        error('nbiot:ui:KpiFiles','Each selected file must have a non-empty path.');
    end
    if ~isfile(path)
        error('nbiot:ui:KpiFile','Saved KPI file does not exist: %s',path);
    end
    [~,base,extension]=fileparts(path);
    if strcmpi(extension,'.csv')&&endsWith(base,'_summary','IgnoreCase',true)
        error('nbiot:ui:KpiSummaryCsv', ...
            'Это итоговая сводка запуска, а здесь нужны KPI по временным окнам. Выберите файл *_kpi.csv.');
    end
    data=readtable(path);
    if ~all(ismember(required,data.Properties.VariableNames)) || ...
            ~isnumeric(data.endTick) || ~isnumeric(data.throughputBitsPerSecond)
        error('nbiot:ui:KpiSchema', ...
            'KPI CSV must contain numeric endTick/throughputBitsPerSecond and cohortDeliveryProbability columns.');
    end
    paths{k}=path;
    tables{k}=data;
    reportMetadata{k}=nbiot.ui.loadReportMetadata(path);
end
loaded=struct('files',{paths},'tables',{tables},'reportMetadata',{reportMetadata});
end
