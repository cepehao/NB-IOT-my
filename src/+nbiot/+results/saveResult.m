function destination=saveResult(result,folder,metadata)
%SAVERESULT Save legacy exports, or transactionally commit a manifested case.
%   Сохранение результата: MAT + CSV-таблицы (ТЗ §46.14, §47) в results/ (не в git).
if nargin<2 || isempty(folder), folder=result.config.logging.outputFolder; end
if nargin<3
    destination=saveLegacyResult(result,folder);
else
    destination=saveCaseResult(result,folder,metadata);
end
end

function destination=saveLegacyResult(result,folder)
if ~isfolder(folder), mkdir(folder); end
runName=exportStem(result);
destination=fullfile(folder,[runName '.mat']); temporary=[tempname(folder) '.mat'];
if isAdaptiveResult(result) && any(cellfun(@(name) isfile(fullfile(folder,name)), ...
        exportFiles(runName,true,isfield(result,'radioDiagnostics'), ...
        isfield(result,'groupKpi'),hasDatasetDiagnostics(result))))
    error('nbiot:results:DuplicateRun', ...
        'Refusing to overwrite an existing Adaptive result with stem %s.',runName);
end
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
saveVariables={'result'};
if hasDatasetDiagnostics(result)
    datasetDiagnostics=result.dataset.diagnostics;
    saveVariables{end+1}='datasetDiagnostics';
end
save(temporary,saveVariables{:},'-v7.3');
check=whos('-file',temporary);
assert(any(strcmp({check.name},'result')),'nbiot:results:Save','MAT result missing.');
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:results:Save','%s',message); end
writeExports(result,folder,runName);
end

function destination=saveCaseResult(result,folder,metadata)
required={'caseKey','configSha256','sourceSha256','calibrationSha256','environment'};
runtimeFields={'runtimeVersion','resultSchemaVersion','canonicalConfigSha256', ...
    'modelSha256','policySha256','inputSha256','runnerSha256'};
if isfield(metadata,'runtimeVersion')
    if isfield(metadata,'resultSchemaVersion')&&metadata.resultSchemaVersion==3
        runtimeFields=[runtimeFields {'controllerPolicy'}];
    end
    required=[required runtimeFields];
end
for k=1:numel(required)
    if ~isfield(metadata,required{k})
        error('nbiot:results:Metadata','Missing case metadata field %s.',required{k});
    end
end
hashFields={'configSha256','sourceSha256','calibrationSha256'};
if isfield(metadata,'runtimeVersion')
    expectedSchema=2+double(isAdaptiveResult(result));
    if metadata.runtimeVersion~=1 || metadata.resultSchemaVersion~=expectedSchema
        error('nbiot:results:Metadata','Unsupported runtime or result schema.');
    end
    hashFields=[hashFields {'canonicalConfigSha256','modelSha256','policySha256', ...
        'inputSha256','runnerSha256'}];
    if isfield(result,'resultSchemaVersion') && ~isequal(result.resultSchemaVersion,expectedSchema)
        error('nbiot:results:Metadata','Unsupported in-memory result schema.');
    end
    if expectedSchema==3 && (~isfield(result,'controllerPolicy') || ...
            ~isequaln(result.controllerPolicy,metadata.controllerPolicy) || ...
            ~isfield(result,'controllerLogSchemaVersion') || result.controllerLogSchemaVersion~=1)
        error('nbiot:results:Metadata','Adaptive result and controller policy metadata must agree.');
    end
    result.resultSchemaVersion=expectedSchema;
end
for k=1:numel(hashFields)
    value=char(string(metadata.(hashFields{k})));
    if isempty(regexp(value,'^[0-9a-fA-F]{64}$','once'))
        error('nbiot:results:Metadata','%s must be a SHA-256 hex digest.',hashFields{k});
    end
end
if ~strcmp(nbiot.results.configSha256(result.config,isfield(metadata,'runtimeVersion')),metadata.configSha256)
    error('nbiot:results:Metadata','Configuration hash does not match the result.');
end
if ~isfolder(folder), mkdir(folder); end
items=dir(folder); items=items(~ismember({items.name},{'.','..'}));
if ~isempty(items)
    error('nbiot:results:DuplicateCase', ...
        'Refusing to overwrite non-empty case directory for key %s.',metadata.caseKey);
end
runName=exportStem(result); destination=fullfile(folder,[runName '.mat']);
temporary=[tempname(folder) '.mat'];
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
caseMetadata=identity(metadata,result.status);
configSnapshot=result.config; resultStatus=result.status;
kpiSummary=result.kpiSummary; environmentSnapshot=result.environment;
datasetSchema=struct();
if isfield(result.dataset,'schema'), datasetSchema=result.dataset.schema; end
resultSchemaVersion=1;
if isfield(metadata,'runtimeVersion'), resultSchemaVersion=metadata.resultSchemaVersion; end
saveVariables={'result','caseMetadata','configSnapshot','resultStatus', ...
    'kpiSummary','environmentSnapshot','resultSchemaVersion','datasetSchema'};
if hasDatasetDiagnostics(result)
    datasetDiagnostics=result.dataset.diagnostics;
    saveVariables{end+1}='datasetDiagnostics';
end
save(temporary,saveVariables{:},'-v7.3');
check=whos('-file',temporary);
requiredVariables={'result','caseMetadata','configSnapshot','resultStatus', ...
    'kpiSummary','environmentSnapshot'};
if hasDatasetDiagnostics(result), requiredVariables{end+1}='datasetDiagnostics'; end
if ~all(ismember(requiredVariables,{check.name}))
    error('nbiot:results:Save','MAT result is missing required snapshot variables.');
end
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:results:Save','%s',message); end
tables=writeExports(result,folder,runName);

report=nbiot.results.verifyCase(folder,metadata,result,false);
if ~report.passed
    error('nbiot:results:Verify','Staged case did not pass readback: %s',strjoin(report.errors,'; '));
end
reportMetadata=nbiot.results.buildReportMetadata(result);
reportMetadata.caseKey=char(string(metadata.caseKey));
if isfield(metadata,'canonicalConfigSha256')
    reportMetadata.canonicalConfigSha256=char(string(metadata.canonicalConfigSha256));
else
    reportMetadata.canonicalConfigSha256=nbiot.results.configSha256(result.config,true);
end
reportMetadataFile=[runName '_report.json'];
reportMetadata.files=struct( ...
    'kpi',fileRecord(folder,[runName '_kpi.csv']), ...
    'summary',fileRecord(folder,[runName '_summary.csv']));
writeJsonAtomic(fullfile(folder,reportMetadataFile),reportMetadata);
marker=identity(metadata,result.status);
marker.manifestVersion=1;
if isfield(metadata,'runtimeVersion'), marker.manifestVersion=2; end
if isfield(metadata,'runtimeVersion')&&metadata.resultSchemaVersion==3
    marker.manifestVersion=3;
    marker.resultSchemaVersion=3;
    marker.controllerLogSchemaVersion=result.controllerLogSchemaVersion;
end
marker.tableExportVersion=2;
if isfield(result,'radioDiagnostics'), marker.tableExportVersion=3; end
if isfield(result,'groupKpi'), marker.tableExportVersion=4; end
if hasDatasetDiagnostics(result)
    marker.tableExportVersion=5;
    marker.diagnosticsSchemaVersion='window-diagnostics-v1';
end
marker.tableExportVersion=6;
marker.canonicalConfigSha256=reportMetadata.canonicalConfigSha256;
marker.reportMetadataFile=reportMetadataFile;
marker.resultFile=[runName '.mat'];
marker.exportStem=runName; marker.tables=tables;
marker.balances=balanceSnapshot(result.kpiSummary);
marker.elapsedSeconds=elapsedSeconds(result);
names=[{marker.resultFile} {tables.file} {reportMetadataFile}];
files=repmat(struct('name','','bytes',0,'sha256',''),numel(names),1);
for k=1:numel(names)
    path=fullfile(folder,names{k}); d=dir(path);
    if isempty(d), error('nbiot:results:Save','Missing staged export %s.',names{k}); end
    files(k)=struct('name',names{k},'bytes',d.bytes,'sha256',hashFile(path));
end
marker.files=files;
markerPath=fullfile(folder,'case-complete.json');
temporaryMarker=[tempname(folder) '.json'];
markerCleanup=onCleanup(@() removeTemporary(temporaryMarker)); %#ok<NASGU>
fid=fopen(temporaryMarker,'wb');
if fid<0, error('nbiot:results:Save','Cannot write completion marker.'); end
writeCleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(marker),'UTF-8'),'uint8');
clear writeCleanup
[ok,message]=movefile(temporaryMarker,markerPath,'f');
if ~ok, error('nbiot:results:Save','Cannot commit completion marker: %s',message); end

report=nbiot.results.verifyCase(folder,metadata);
if ~report.passed
    delete(markerPath);
    error('nbiot:results:Verify','Committed case failed integrity check: %s',strjoin(report.errors,'; '));
end
end

function runName=exportStem(result)
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

function tables=writeExports(result,folder,runName)
tableData={result.ueSummary,result.kpiTimeSeries,result.dataset.observations, ...
    result.dataset.targets,result.resourceUsage,result.dataset.manifest};
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv', ...
    '_resources.csv','_split.csv'};
if isAdaptiveResult(result)
    if ~isfield(result,'controllerLog')||~isfield(result,'controllerLogSchemaVersion')|| ...
            result.controllerLogSchemaVersion~=1
        error('nbiot:results:ControllerSchema','Adaptive export requires controller log schema version 1.');
    end
    tableData{end+1}=struct2table(result.controllerLog,'AsArray',true);
    suffixes{end+1}='_controller.csv';
end
tableData{end+1}=nbiot.results.buildKpiSummaryTable(result);
suffixes{end+1}='_summary.csv';
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
tables=repmat(struct('file','','variableNames',{{}},'rows',0),numel(suffixes),1);
for k=1:numel(suffixes)
    file=[runName suffixes{k}]; writetable(tableData{k},fullfile(folder,file));
    tables(k)=struct('file',file,'variableNames',{tableData{k}.Properties.VariableNames}, ...
        'rows',height(tableData{k}));
end
end

function value=diagnosticsCsvTable(value)
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

function files=exportFiles(runName,includeController,includeRadio,includeGroups,includeDiagnostics)
if nargin<3, includeRadio=false; end
if nargin<4, includeGroups=false; end
if nargin<5, includeDiagnostics=false; end
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv', ...
    '_resources.csv','_split.csv','_summary.csv'};
if includeController, suffixes{end+1}='_controller.csv'; end
if includeRadio, suffixes{end+1}='_radio.csv'; end
if includeGroups, suffixes{end+1}='_groups.csv'; end
if includeDiagnostics, suffixes{end+1}='_diagnostics.csv'; end
files=[{[runName '.mat']},cellfun(@(suffix) [runName suffix],suffixes,'UniformOutput',false)];
end

function yes=hasDatasetDiagnostics(result)
yes=isstruct(result)&&isscalar(result)&&isfield(result,'dataset')&& ...
    isstruct(result.dataset)&&isscalar(result.dataset)&&isfield(result.dataset,'diagnostics');
end

function yes=isAdaptiveResult(result)
yes=isfield(result,'config')&&isfield(result.config,'policy')&& ...
    isfield(result.config.policy,'name')&& ...
    any(strcmp(char(string(result.config.policy.name)),{'Adaptive-P','Adaptive-RA/DT'}));
end

function metadata=identity(input,status)
metadata=struct('caseKey',char(string(input.caseKey)), ...
    'configSha256',char(string(input.configSha256)), ...
    'sourceSha256',char(string(input.sourceSha256)), ...
    'calibrationSha256',char(string(input.calibrationSha256)), ...
    'environment',input.environment,'status',char(string(status)));
if isfield(input,'runtimeVersion')
    names={'runtimeVersion','resultSchemaVersion','canonicalConfigSha256', ...
        'modelSha256','policySha256','inputSha256','runnerSha256'};
    for k=1:numel(names), metadata.(names{k})=input.(names{k}); end
    if isfield(input,'controllerPolicy'), metadata.controllerPolicy=input.controllerPolicy; end
end
end

function balances=balanceSnapshot(kpi)
names={'created','delivered','dropped','unfinished', ...
    'raStarted','raSuccess','raFailed','raUnfinished'};
for k=1:numel(names)
    if ~isfield(kpi,names{k})
        error('nbiot:results:Balance','KPI summary lacks %s.',names{k});
    end
end
balances=struct();
for k=1:numel(names), balances.(names{k})=kpi.(names{k}); end
end

function value=elapsedSeconds(result)
value=0;
if isfield(result,'profiling') && isfield(result.profiling,'elapsedSeconds')
    value=double(result.profiling.elapsedSeconds);
end
end

function hex=hashFile(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:results:Hash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function record=fileRecord(folder,name)
path=fullfile(folder,name); d=dir(path);
if isempty(d), error('nbiot:results:Save','Missing staged export %s.',name); end
record=struct('name',name,'bytes',d.bytes,'sha256',hashFile(path));
end

function writeJsonAtomic(path,value)
folder=fileparts(path); temporary=[tempname(folder) '.json'];
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'wb');
if fid<0, error('nbiot:results:Save','Cannot write report metadata.'); end
writeCleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value),'UTF-8'),'uint8');
clear writeCleanup
[ok,message]=movefile(temporary,path,'f');
if ~ok, error('nbiot:results:Save','Cannot publish report metadata: %s',message); end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
