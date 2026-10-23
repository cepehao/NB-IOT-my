function view=loadReportMetadata(kpiFile)
%LOADREPORTMETADATA Read the small report sidecar linked to a KPI CSV.
% The reader intentionally never loads the simulation MAT file or calls verifyCase.
view=emptyView('unavailable','Отчёт не найден.');
try
    if isstring(kpiFile)&&isscalar(kpiFile), kpiFile=char(kpiFile); end
    if ~ischar(kpiFile)||isempty(strtrim(kpiFile))
        view=emptyView('invalid','Не задан файл KPI.'); return
    end
    if ~isfile(kpiFile)
        view=emptyView('invalid','Файл KPI не найден.'); return
    end
    [folder,base,extension]=fileparts(kpiFile);
    if isempty(folder), folder=pwd; end
    if ~strcmpi(extension,'.csv')||~endsWith(base,'_kpi','IgnoreCase',true)
        view=emptyView('unavailable','Выбранный файл не является таблицей *_kpi.csv.'); return
    end
    [inside,~]=insideFolder(folder,kpiFile);
    if ~inside
        view=emptyView('invalid','Файл KPI должен находиться внутри папки случая.'); return
    end
    kpiName=[base extension]; summaryName=[base(1:end-4) '_summary.csv'];
    reportName=[base(1:end-4) '_report.json'];
    markerPath=fullfile(folder,'case-complete.json');
    reportPath=fullfile(folder,reportName);
    if ~isfile(markerPath)
        if isfile(reportPath)
            view=emptyView('invalid','Маркер завершённого случая отсутствует.');
        else
            view=emptyView('unavailable','Связанный отчёт недоступен для отдельного KPI CSV.');
        end
        return
    end
    try
        marker=jsondecode(fileread(markerPath));
    catch exception
        view=emptyView('invalid',['Маркер случая повреждён: ' exception.message]); return
    end
    if ~isstruct(marker)||~isscalar(marker)||~all(isfield(marker, ...
            {'caseKey','exportStem','tableExportVersion','files','tables'}))
        view=emptyView('invalid','Маркер случая не содержит связи с KPI и итоговой таблицей.'); return
    end
    if ~strcmp(char(string(marker.exportStem)),base(1:end-4))
        view=emptyView('invalid','Выбранный KPI не относится к указанному случаю.'); return
    end
    version=double(marker.tableExportVersion);
    if ~isscalar(version)||~isfinite(version)
        view=emptyView('invalid','Версия таблиц в маркере некорректна.'); return
    end
    [ok,reason]=verifyLinkedCsv(folder,marker,kpiName,summaryName);
    if ~ok
        view=emptyView('invalid',reason); return
    end
    if version==6
        view=readVerifiedSidecar(folder,kpiFile,marker,kpiName,summaryName,reportName);
    elseif any(version==[2 3 4 5])
        fields=legacyFields(kpiFile,fullfile(folder,summaryName));
        if ~balancedCounts(fields)
            view=unbalancedCountView(char(string(marker.caseKey)),fields);
        else
            view=struct('status','partial','caseKey',char(string(marker.caseKey)), ...
                'fields',fields,'unavailableFields',{missingFields(fields)}, ...
                'reason','Сохранённые таблицы связаны и проверены; часть сведений отсутствует в старом формате.');
        end
    else
        view=emptyView('invalid','Версия таблиц случая не поддерживается.');
    end
catch exception
    view=emptyView('invalid',['Не удалось проверить метаданные отчёта: ' exception.message]);
end
end

function view=readVerifiedSidecar(folder,kpiFile,marker,kpiName,summaryName,reportName)
view=emptyView('invalid','Метаданные отчёта не прошли проверку.');
if ~isfield(marker,'reportMetadataFile')||~isfield(marker,'canonicalConfigSha256')
    view.reason='В маркере отсутствует ссылка на сводку отчёта.'; return
end
sidecarName=char(string(marker.reportMetadataFile));
if ~strcmp(sidecarName,reportName)
    [~,detail]=insideFolder(folder,fullfile(folder,sidecarName));
    if isempty(detail), detail='Ссылка на сводку должна совпадать с выбранным случаем.'; end
    view.reason=detail; return
end
[sidecarPath,inside,detail]=referencedPath(folder,sidecarName);
if ~inside, view.reason=detail; return; end
[record,ok]=findFileRecord(marker,sidecarName);
if ~ok, view.reason='Маркер не содержит контрольную запись сводки отчёта.'; return; end
[valid,detail]=verifyFileRecord(sidecarPath,record);
if ~valid, view.reason=detail; return; end
try
    report=jsondecode(fileread(sidecarPath));
catch exception
    view.reason=['Файл сводки отчёта повреждён: ' exception.message]; return
end
required={'schemaVersion','caseKey','canonicalConfigSha256','fields', ...
    'unavailableFields','reason','files'};
if ~isstruct(report)||~isscalar(report)||~all(isfield(report,required))|| ...
        ~isequal(double(report.schemaVersion),1)
    view.reason='Формат сводки отчёта не поддерживается.'; return
end
fieldNames=fieldnames(emptyFields());
if ~isstruct(report.fields)||~isscalar(report.fields)||~all(isfield(report.fields,fieldNames))
    view.reason='Сводка не содержит полный набор полей отчёта.'; return
end
caseKey=char(string(marker.caseKey));
if ~strcmp(char(string(report.caseKey)),caseKey)
    view.reason='Сводка отчёта относится к другому случаю.'; return
end
canonicalHash=char(string(marker.canonicalConfigSha256));
if ~isSha256(canonicalHash)||~strcmpi(char(string(report.canonicalConfigSha256)),canonicalHash)
    view.reason='Хеш конфигурации сводки не совпадает с маркером случая.'; return
end
if ~isstruct(report.files)||~isscalar(report.files)|| ...
        ~all(isfield(report.files,{'kpi','summary'}))
    view.reason='В сводке отсутствуют ссылки на KPI и итоговую таблицу.'; return
end
links={report.files.kpi,report.files.summary}; expectedNames={kpiName,summaryName};
for index=1:numel(links)
    ref=links{index};
    if ~isstruct(ref)||~isscalar(ref)||~isfield(ref,'name')
        view.reason='Ссылка на KPI или итоговую таблицу неполная.'; return
    end
    [path,inside,detail]=referencedPath(folder,char(string(ref.name)));
    if ~inside, view.reason=detail; return; end
    if ~strcmp(char(string(ref.name)),expectedNames{index})
        view.reason='Сводка ссылается на файлы другого случая.'; return
    end
    [markerRecord,found]=findFileRecord(marker,expectedNames{index});
    if ~found||~sameRecord(ref,markerRecord)
        view.reason='Контрольные записи KPI или итоговой таблицы не совпадают.'; return
    end
    [valid,detail]=verifyFileRecord(path,ref);
    if ~valid, view.reason=detail; return; end
end
[inside,detail]=insideFolder(folder,kpiFile);
if ~inside, view.reason=detail; return; end
fields=normalizeFields(report.fields);
if isempty(fields), view.reason='Сводка не содержит полей отчёта.'; return; end
if ~balancedCounts(fields)
    view=unbalancedCountView(caseKey,fields);
    return
end
view=struct('status','verified','caseKey',caseKey,'fields',fields, ...
    'unavailableFields',{missingFields(fields)},'reason','');
end

function fields=legacyFields(kpiPath,summaryPath)
fields=emptyFields();
summary=readtable(summaryPath,'VariableNamingRule','preserve','TextType','string');
if height(summary)<1, error('nbiot:ui:ReportSummary','Связанная итоговая таблица пуста.'); end
fields.mode=summaryText(summary,{'method'});
fields.numUE=summaryNumber(summary,{'numUE'});
fields.durationTicks=summaryNumber(summary,{'durationTicks'});
fields.actualTick=summaryNumber(summary,{'kpi_service_actualTick','kpi_actualTick'});
fields.durationSeconds=summaryNumber(summary,{'kpi_durationSeconds'});
fields.created=summaryNumber(summary,{'kpi_created'});
fields.delivered=summaryNumber(summary,{'kpi_delivered'});
fields.dropped=summaryNumber(summary,{'kpi_dropped'});
fields.unfinished=summaryNumber(summary,{'kpi_unfinished'});
kpi=readtable(kpiPath,'VariableNamingRule','preserve','TextType','string');
fields.kpiWindowTicks=inferWindowTicks(kpi);
end

function fields=normalizeFields(input)
fields=emptyFields();
if ~isstruct(input)||~isscalar(input), fields=[]; return; end
names=fieldnames(fields);
for k=1:numel(names)
    name=names{k}; if ~isfield(input,name), continue; end
    if ischar(fields.(name))
        if ischar(input.(name))||(isstring(input.(name))&&isscalar(input.(name)))
            fields.(name)=char(string(input.(name)));
        end
    else
        value=input.(name);
        if isempty(value)
            fields.(name)=NaN;
        elseif isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)
            fields.(name)=double(value);
        end
    end
end
end

function fields=emptyFields()
fields=struct('mode','','numUE',NaN,'activeUE',NaN,'trafficType','', ...
    'payloadBytes',NaN,'periodTicks',NaN,'durationTicks',NaN, ...
    'actualTick',NaN,'tickSeconds',NaN,'durationSeconds',NaN, ...
    'kpiWindowTicks',NaN,'planned',NaN,'created',NaN,'delivered',NaN, ...
    'dropped',NaN,'unfinished',NaN);
end

function missing=missingFields(fields)
names=fieldnames(fields); missing={};
for k=1:numel(names)
    value=fields.(names{k});
    if (isnumeric(value)&&isscalar(value)&&isnan(value))|| ...
            (ischar(value)&&isempty(value))
        missing{end+1}=names{k}; %#ok<AGROW>
    end
end
end

function ok=balancedCounts(fields)
values=[fields.created fields.delivered fields.dropped fields.unfinished];
if any(~isfinite(values)), ok=true; return; end
ok=all(values>=0&values==fix(values))&& ...
    values(1)==values(2)+values(3)+values(4);
end

function view=unbalancedCountView(caseKey,fields)
view=struct('status','invalid','caseKey',caseKey,'fields',fields, ...
    'unavailableFields',{missingFields(fields)}, ...
    'reason','Числа созданных, доставленных, неудачных и незавершённых пакетов не сходятся.');
end

function value=inferWindowTicks(kpi)
value=NaN;
if ~istable(kpi)||~all(ismember({'startTick','endTick'},kpi.Properties.VariableNames))||height(kpi)==0
    return
end
widths=double(kpi.endTick)-double(kpi.startTick);
widths=widths(isfinite(widths)&widths>0);
if ~isempty(widths), value=max(widths); end
end

function value=summaryNumber(data,names)
value=NaN;
for k=1:numel(names)
    name=names{k};
    if ismember(name,data.Properties.VariableNames)
        column=data.(name); item=column(1);
        if isnumeric(item)&&isreal(item)&&isscalar(item)&&isfinite(item), value=double(item); end
        return
    end
end
end

function value=summaryText(data,names)
value='';
for k=1:numel(names)
    name=names{k};
    if ismember(name,data.Properties.VariableNames)
        column=data.(name); item=column(1);
        if isstring(item)||ischar(item), value=char(string(item)); end
        return
    end
end
end

function [ok,reason]=verifyLinkedCsv(folder,marker,kpiName,summaryName)
ok=false; reason='';
records=marker.files; if iscell(records), records=[records{:}]; end
if ~isstruct(records)||~isfield(records,'name')
    reason='Маркер не содержит корректный список файлов.'; return
end
for recordIndex=1:numel(records)
    [~,inside,detail]=referencedPath(folder,char(string(records(recordIndex).name)));
    if ~inside, reason=detail; return; end
end
for name={kpiName,summaryName}
    [path,inside,detail]=referencedPath(folder,name{1});
    if ~inside, reason=detail; return; end
    [record,found]=findFileRecord(marker,name{1});
    if ~found, reason=['Маркер не содержит файл ' name{1} '.']; return; end
    [valid,detail]=verifyFileRecord(path,record);
    if ~valid, reason=detail; return; end
    if ~hasTable(marker,name{1}), reason=['Маркер не связывает таблицу ' name{1} '.']; return; end
end
ok=true;
end

function yes=hasTable(marker,name)
yes=false; tables=marker.tables;
if iscell(tables), tables=[tables{:}]; end
if ~isstruct(tables)||~all(isfield(tables,'file')), return; end
yes=any(strcmp(cellstr(string({tables.file})),name));
end

function [record,found]=findFileRecord(marker,name)
record=struct(); found=false; records=marker.files;
if iscell(records), records=[records{:}]; end
if ~isstruct(records)||~all(isfield(records,{'name','bytes','sha256'})), return; end
matches=find(strcmp(cellstr(string({records.name})),name));
if numel(matches)~=1, return; end
record=records(matches); found=true;
end

function same=sameRecord(first,second)
same=isfield(first,'bytes')&&isfield(first,'sha256')&& ...
    isequal(double(first.bytes),double(second.bytes))&& ...
    strcmpi(char(string(first.sha256)),char(string(second.sha256)));
end

function [ok,reason]=verifyFileRecord(path,record)
ok=false; reason='';
if ~isfile(path), reason=['Файл отсутствует: ' path]; return; end
if ~isstruct(record)||~isscalar(record)||~all(isfield(record,{'bytes','sha256'}))
    reason='Контрольная запись файла неполная.'; return
end
try
    d=dir(path); actualHash=hashFile(path);
    ok=double(record.bytes)==d.bytes&& ...
        strcmpi(char(string(record.sha256)),actualHash);
catch exception
    reason=['Не удалось проверить файл: ' exception.message]; return
end
if ~ok, reason='Размер или SHA-256 связанного файла изменился.'; end
end

function [path,inside,reason]=referencedPath(folder,name)
if isstring(name)&&isscalar(name), name=char(name); end
if ~ischar(name)||isempty(name)
    path=''; inside=false; reason='Ссылка на файл пуста.'; return
end
path=fullfile(folder,name);
[inside,reason]=insideFolder(folder,path);
if ~inside, reason='Ссылка должна оставаться внутри папки случая.'; end
end

function [inside,reason]=insideFolder(folder,path)
inside=false; reason='Файл должен находиться внутри папки случая.';
try
    root=char(java.io.File(folder).getCanonicalPath());
    candidate=char(java.io.File(path).getCanonicalPath());
    prefix=[root filesep];
    inside=numel(candidate)>numel(prefix)&&strncmpi(candidate,prefix,numel(prefix));
catch
end
end

function yes=isSha256(value)
yes=ischar(value)&&~isempty(regexp(value,'^[0-9a-fA-F]{64}$','once'));
end

function hex=hashFile(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:ui:ReportHash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function view=emptyView(status,reason)
view=struct('status',status,'caseKey','','fields',emptyFields(), ...
    'unavailableFields',{{'report'}},'reason',reason);
end
