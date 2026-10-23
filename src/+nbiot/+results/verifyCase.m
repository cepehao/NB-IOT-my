function report=verifyCase(caseFolder,expected,memoryResult,requireMarker)
%VERIFYCASE Check a saved result, exported tables and run provenance.
%   Проверка сохранённого прогона: полнота файлов, таблиц и хешей. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
if nargin<2 || isempty(expected), expected=struct(); end
if nargin<3, memoryResult=[]; end
if nargin<4, requireMarker=true; end
try
    report=verifyCaseImpl(caseFolder,expected,memoryResult,requireMarker);
catch exception
    report=struct('passed',false,'status','','caseKey','','checks', ...
        struct('name','damaged-package','passed',false,'detail',exception.message), ...
        'errors',{{['damaged-package: ' exception.message]}});
end
end

function report=verifyCaseImpl(caseFolder,expected,memoryResult,requireMarker)
report=struct('passed',false,'status','','caseKey','','checks', ...
    struct('name',{},'passed',{},'detail',{}),'errors',{{}});
markerPath=fullfile(caseFolder,'case-complete.json'); marker=[];
if isfile(markerPath)
    try
        marker=jsondecode(fileread(markerPath));
    catch exception
        report=addCheck(report,'completion-marker',false,exception.message);
        report=finish(report); return
    end
elseif requireMarker
    report=addCheck(report,'completion-marker',false,'Completion marker is missing.');
    report=finish(report); return
end
includeSummary=~isempty(marker)&&isfield(marker,'tableExportVersion');
includeRadioDiagnostics=markerHasTable(marker,'_radio.csv');
includeGroupKpi=markerHasTable(marker,'_groups.csv');
includeDiagnostics=markerHasTable(marker,'_diagnostics.csv');
if isempty(marker), includeDiagnostics=hasDatasetDiagnostics(memoryResult); end
if includeSummary
    tableExportVersionOk=isnumeric(marker.tableExportVersion)&& ...
        isscalar(marker.tableExportVersion)&&any(double(marker.tableExportVersion)==[2 3 4 5 6]);
    if tableExportVersionOk
        if double(marker.tableExportVersion)==5
            tableExportVersionOk=includeDiagnostics&&isfield(marker,'diagnosticsSchemaVersion')&& ...
                strcmp(char(string(marker.diagnosticsSchemaVersion)),'window-diagnostics-v1');
        elseif double(marker.tableExportVersion)==6
            if includeDiagnostics
                tableExportVersionOk=isfield(marker,'diagnosticsSchemaVersion')&& ...
                    strcmp(char(string(marker.diagnosticsSchemaVersion)),'window-diagnostics-v1');
            else
                tableExportVersionOk=~isfield(marker,'diagnosticsSchemaVersion');
            end
        else
            tableExportVersionOk=~includeDiagnostics&&~isfield(marker,'diagnosticsSchemaVersion');
        end
    end
    report=addCheck(report,'table-export-version',tableExportVersionOk, ...
        'Unsupported or inconsistent table export version.');
    if ~tableExportVersionOk, report=finish(report); return; end
elseif ~isempty(marker)&&(includeDiagnostics||isfield(marker,'diagnosticsSchemaVersion'))
    report=addCheck(report,'table-export-version',false, ...
        'Diagnostics exports require table export version 5.');
    report=finish(report); return
end

if ~isempty(marker)
    markerFields={'manifestVersion','caseKey','configSha256','sourceSha256', ...
        'calibrationSha256','environment','status','resultFile','exportStem', ...
        'files','tables','balances','elapsedSeconds'};
    if isfield(marker,'tableExportVersion')&&isnumeric(marker.tableExportVersion)&& ...
            isscalar(marker.tableExportVersion)&&double(marker.tableExportVersion)==5
        markerFields=[markerFields {'diagnosticsSchemaVersion'}];
    end
    if isfield(marker,'tableExportVersion')&&isnumeric(marker.tableExportVersion)&& ...
            isscalar(marker.tableExportVersion)&&double(marker.tableExportVersion)==6
        markerFields=[markerFields {'reportMetadataFile','canonicalConfigSha256'}];
        if includeDiagnostics, markerFields=[markerFields {'diagnosticsSchemaVersion'}]; end
    end
    if isfield(marker,'manifestVersion')&&isequal(double(marker.manifestVersion),3)
        markerFields=[markerFields {'resultSchemaVersion','controllerLogSchemaVersion'}];
    end
    missing=markerFields(~isfield(marker,markerFields));
    report=addCheck(report,'marker-fields',isempty(missing),strjoin(missing,', '));
    if ~isempty(missing), report=finish(report); return; end
    report.status=char(string(marker.status)); report.caseKey=char(string(marker.caseKey));
    versionOk=any(double(marker.manifestVersion)==[1 2 3]);
    report=addCheck(report,'marker-version',versionOk, ...
        sprintf('manifestVersion=%s',string(marker.manifestVersion)));
    if ~versionOk, report=finish(report); return; end
    if marker.manifestVersion==1 && (isfield(marker,'runtimeVersion') || isfield(marker,'resultSchemaVersion'))
        report=addCheck(report,'marker-runtime-version',false,'Legacy marker cannot contain schema-2 runtime identity.');
        report=finish(report); return;
    end
    if marker.manifestVersion==2||marker.manifestVersion==3
        report=addCheck(report,'runtime-schema',runtimeValid(marker),'Runtime identity must have a supported result schema.');
        if ~runtimeValid(marker), report=finish(report); return; end
    end
    if marker.manifestVersion==3
        controllerSchemaOk=isequal(double(marker.resultSchemaVersion),3)&& ...
            isequal(double(marker.controllerLogSchemaVersion),1)&&isfield(marker,'controllerPolicy');
        report=addCheck(report,'controller-schema',controllerSchemaOk, ...
            'Adaptive marker requires result schema 3, controller log schema 1 and its effective policy.');
        if ~controllerSchemaOk, report=finish(report); return; end
    elseif marker.manifestVersion==2&&double(marker.resultSchemaVersion)~=2
        report=addCheck(report,'runtime-schema-version',false,'Manifest version 2 requires result schema 2.');
        report=finish(report); return;
    end
else
    report.status='staging';
end

if ~isempty(marker)
    resultFile=char(string(marker.resultFile)); exportStem=char(string(marker.exportStem));
else
    if isempty(memoryResult)
        report=addCheck(report,'result-file-name',false,'Staging verification requires the in-memory result.');
        report=finish(report); return
    end
    exportStem=stem(memoryResult); resultFile=[exportStem '.mat'];
end
matPath=fullfile(caseFolder,resultFile);
if ~isfile(matPath)
    report=addCheck(report,'mat-file',false,'Result MAT file is missing.');
    report=finish(report); return
end
try
    variables=whos('-file',matPath); variableNames={variables.name};
catch exception
    report=addCheck(report,'mat-readable',false,exception.message);
    report=finish(report); return
end
requiredVariables={'result','caseMetadata','configSnapshot','resultStatus', ...
    'kpiSummary','environmentSnapshot'};
if includeDiagnostics, requiredVariables{end+1}='datasetDiagnostics'; end
allPresent=all(ismember(requiredVariables,variableNames));
report=addCheck(report,'mat-variables',allPresent, ...
    strjoin(setdiff(requiredVariables,variableNames),', '));
if ~allPresent, report=finish(report); return; end
try
    loaded=load(matPath,'caseMetadata','configSnapshot','resultStatus', ...
        'kpiSummary','environmentSnapshot');
catch exception
    report=addCheck(report,'mat-snapshots',false,exception.message);
    report=finish(report); return
end
caseMetadata=loaded.caseMetadata;
diagnosticsSnapshot=struct();
if includeDiagnostics
    try
        diagnosticsSnapshot=load(matPath,'datasetDiagnostics','result');
        diagnosticsOk=isfield(diagnosticsSnapshot,'datasetDiagnostics')&& ...
            isfield(diagnosticsSnapshot,'result')&& ...
            validDiagnosticsResult(diagnosticsSnapshot.datasetDiagnostics,diagnosticsSnapshot.result)&& ...
            diagnosticsTablesEqual(diagnosticsSnapshot.datasetDiagnostics, ...
                diagnosticsSnapshot.result.dataset.diagnostics);
        if ~isempty(memoryResult)
            diagnosticsOk=diagnosticsOk&&hasDatasetDiagnostics(memoryResult)&& ...
                diagnosticsTablesEqual(diagnosticsSnapshot.datasetDiagnostics, ...
                    memoryResult.dataset.diagnostics);
        end
    catch exception
        diagnosticsOk=false;
        diagnosticsDetail=exception.message;
    end
    if ~exist('diagnosticsDetail','var'), diagnosticsDetail= ...
            'MAT diagnostics must match the result table, schema, and observation/target keys.'; end
    report=addCheck(report,'mat-diagnostics',diagnosticsOk,diagnosticsDetail);
    clear diagnosticsDetail
elseif includeSummary&&ismember('datasetDiagnostics',variableNames)
    report=addCheck(report,'mat-diagnostics',false, ...
        'Legacy table-export versions must not contain the new diagnostics variable.');
end
if isfield(caseMetadata,'runtimeVersion')
    versionSnapshot=load(matPath,'resultSchemaVersion');
    expectedSchema=2+double(isfield(caseMetadata,'controllerPolicy'));
    schemaOk=runtimeValid(caseMetadata) && isfield(versionSnapshot,'resultSchemaVersion') && ...
        isequal(versionSnapshot.resultSchemaVersion,expectedSchema);
    report=addCheck(report,'result-schema',schemaOk,'MAT result schema must be supported and agree with runtime identity.');
end
if isempty(marker)
    marker=caseMetadata;
    marker.resultFile=resultFile; marker.exportStem=exportStem;
    marker.balances=balanceSnapshot(loaded.kpiSummary);
    includeSummary=true;
    marker.tableExportVersion=2;
    includeRadioDiagnostics=isfield(memoryResult,'radioDiagnostics');
    includeGroupKpi=isfield(memoryResult,'groupKpi');
    marker.tables=memoryTables(memoryResult,exportStem,includeSummary, ...
        includeRadioDiagnostics,includeGroupKpi,includeDiagnostics);
    report.caseKey=char(string(marker.caseKey)); report.status=char(string(marker.status));
end

identityFields={'caseKey','configSha256','sourceSha256','calibrationSha256','environment'};
runtimeFields={'runtimeVersion','resultSchemaVersion','canonicalConfigSha256', ...
    'modelSha256','policySha256','inputSha256','runnerSha256'};
if isfield(marker,'controllerPolicy')
    runtimeFields=[runtimeFields {'controllerPolicy'}];
end
identityFields=[identityFields runtimeFields];
for k=1:numel(identityFields)
    name=identityFields{k};
    if isfield(expected,name)
        match=isfield(marker,name) && equivalent(marker.(name),expected.(name));
        report=addCheck(report,['expected-' name],match, ...
            sprintf('Expected metadata %s %s.',name,ternary(match,'matches','differs')));
    end
end

compareFields={'caseKey','configSha256','sourceSha256','calibrationSha256','environment','status'};
if isfield(marker,'runtimeVersion') || isfield(caseMetadata,'runtimeVersion')
    compareFields=[compareFields runtimeFields];
end
matched=true;
for k=1:numel(compareFields)
    name=compareFields{k};
    if ~isfield(caseMetadata,name) || ~isfield(marker,name) || ...
            ~equivalent(caseMetadata.(name),marker.(name))
        matched=false;
    end
end
report=addCheck(report,'mat-identity',matched,'MAT identity snapshot must match marker.');
try
    computed=nbiot.results.configSha256(loaded.configSnapshot,isfield(marker,'runtimeVersion'));
    configOk=strcmp(computed,char(string(marker.configSha256)));
    expectedStem=stemFromConfig(loaded.configSnapshot);
    nameOk=strcmp(exportStem,expectedStem) && strcmp(resultFile,[expectedStem '.mat']);
catch
    configOk=false;
    nameOk=false;
end
report=addCheck(report,'config-hash',configOk,'MAT configuration hash must match marker.');
report=addCheck(report,'result-file-name',nameOk,'MAT and CSV names must match the saved case configuration.');
envOk=equivalent(loaded.environmentSnapshot,marker.environment);
report=addCheck(report,'receiver-version',envOk,'Receiver environment must match marker.');
try
    kpi=balanceSnapshot(loaded.kpiSummary);
    balanceOk=equivalent(kpi,marker.balances) && ...
        double(kpi.created)==double(kpi.delivered)+double(kpi.dropped)+double(kpi.unfinished) && ...
        double(kpi.raStarted)==double(kpi.raSuccess)+double(kpi.raFailed)+double(kpi.raUnfinished);
catch
    balanceOk=false;
end
report=addCheck(report,'kpi-balance',balanceOk,'Packet and random-access totals must balance.');
if ~isempty(memoryResult)
    report=addCheck(report,'memory-status', ...
        strcmp(char(string(memoryResult.status)),char(string(loaded.resultStatus))), ...
        'Saved status must match the in-memory result.');
    report=addCheck(report,'memory-kpi',equivalent( ...
        balanceSnapshot(memoryResult.kpiSummary),balanceSnapshot(loaded.kpiSummary)), ...
        'Saved KPI summary must match the in-memory result.');
end
statusOk=strcmp(char(string(loaded.resultStatus)),char(string(marker.status)));
report=addCheck(report,'result-status',statusOk,'MAT status must match marker.');

includeController=~isempty(marker)&&isfield(marker,'manifestVersion')&&marker.manifestVersion==3;
if isempty(markerPath)||~isfile(markerPath), includeController=isAdaptiveResult(memoryResult); end
if ~isempty(markerPath) && isfile(markerPath)
    fileRecords=marker.files; if iscell(fileRecords), fileRecords=[fileRecords{:}]; end
    expectedFiles=[{resultFile},cellstr(memoryTableFiles(exportStem,includeController, ...
        includeSummary,includeRadioDiagnostics,includeGroupKpi,includeDiagnostics))];
    if isfield(marker,'tableExportVersion')&&double(marker.tableExportVersion)==6
        expectedFiles{end+1}=char(string(marker.reportMetadataFile));
    end
    actualNames=cellstr(string({fileRecords.name}));
    listOk=numel(unique(actualNames))==numel(expectedFiles) && ...
        isequal(sort(actualNames),sort(expectedFiles));
    report=addCheck(report,'file-list',listOk,'Marker must list the MAT result and all CSV exports exactly once.');
else
    includeRadioDiagnostics=~isempty(memoryResult)&&isfield(memoryResult,'radioDiagnostics');
    includeGroupKpi=~isempty(memoryResult)&&isfield(memoryResult,'groupKpi');
    expectedFiles=[{resultFile},cellstr(memoryTableFiles(exportStem,includeController, ...
        includeSummary,includeRadioDiagnostics,includeGroupKpi,includeDiagnostics))];
    present=cellfun(@(name) isfile(fullfile(caseFolder,name)),expectedFiles);
    report=addCheck(report,'file-list',all(present), ...
        'Staged case must contain MAT and all CSV exports before commit.');
    fileRecords=repmat(struct('name','','sha256','','bytes',0),0,1);
    for k=1:numel(expectedFiles)
        path=fullfile(caseFolder,expectedFiles{k});
        if isfile(path)
            d=dir(path); fileRecords(end+1)=struct('name',expectedFiles{k}, ...
                'sha256',hashFile(path),'bytes',d.bytes); %#ok<AGROW>
        end
    end
end
for k=1:numel(fileRecords)
    record=fileRecords(k); name=char(string(record.name)); path=fullfile(caseFolder,name);
    if ~isfile(path)
        report=addCheck(report,['file-' name],false,'Required file is missing.'); continue
    end
    try
        d=dir(path); hash=hashFile(path);
        fileOk=double(record.bytes)==d.bytes && strcmpi(char(string(record.sha256)),hash);
        report=addCheck(report,['file-' name],fileOk,'Byte count and SHA-256 must match marker.');
    catch exception
        report=addCheck(report,['file-' name],false,exception.message);
    end
end
if ~isempty(marker)&&isfield(marker,'tableExportVersion')&& ...
        double(marker.tableExportVersion)==6
    [reportMetadataOk,reportMetadataDetail]=verifyReportMetadata(caseFolder,marker);
    report=addCheck(report,'report-metadata',reportMetadataOk,reportMetadataDetail);
end

try
    tables=marker.tables; if iscell(tables), tables=[tables{:}]; end
    tableListOk=isstruct(tables) && all(isfield(tables,{'file','variableNames','rows'}));
    if tableListOk
        expectedTableFiles=reshape(cellstr(memoryTableFiles( ...
            exportStem,includeController,includeSummary,includeRadioDiagnostics, ...
            includeGroupKpi,includeDiagnostics)),1,[]);
        actualTableFiles=reshape(cellstr(string({tables.file})),1,[]);
        tableListOk=numel(actualTableFiles)==numel(expectedTableFiles) && ...
            numel(unique(actualTableFiles))==numel(expectedTableFiles) && ...
            isequal(sort(actualTableFiles),sort(expectedTableFiles));
    end
catch
    tableListOk=false;
end
report=addCheck(report,'table-list',tableListOk, ...
    'Marker must describe every CSV table schema exactly once.');
if ~tableListOk, report=finish(report); return; end
for k=1:numel(tables)
    tableInfo=tables(k); name=char(string(tableInfo.file)); path=fullfile(caseFolder,name);
    if ~isfile(path), continue; end
    try
        actual=readtable(path,'VariableNamingRule','preserve','TextType','string');
        schema=reshape(cellstr(string(tableInfo.variableNames)),1,[]);
        schemaOk=isequal(actual.Properties.VariableNames,schema);
        rowsOk=height(actual)==double(tableInfo.rows);
        report=addCheck(report,['schema-' name],schemaOk, ...
            sprintf('CSV columns [%s], expected [%s].', ...
            strjoin(actual.Properties.VariableNames,','),strjoin(schema,',')));
        report=addCheck(report,['rows-' name],rowsOk, ...
            sprintf('Expected %d rows; read %d.',double(tableInfo.rows),height(actual)));
        if ~isempty(memoryResult)
            expectedTable=memoryTable(memoryResult,name,includeSummary, ...
                includeRadioDiagnostics,includeGroupKpi,includeDiagnostics);
            same=strcmp(tableHash(expectedTable),hashFile(path));
            report=addCheck(report,['readback-' name],same, ...
                'CSV bytes must match a fresh export of the in-memory table.');
        end
        if includeDiagnostics&&strcmp(name,[exportStem '_diagnostics.csv'])
            roundTripOk=isfield(diagnosticsSnapshot,'datasetDiagnostics')&& ...
                diagnosticsCsvMatchesSnapshot(actual,diagnosticsSnapshot.datasetDiagnostics);
            report=addCheck(report,'diagnostics-roundtrip',roundTripOk, ...
                'Diagnostics CSV must round-trip to the MAT datasetDiagnostics table.');
        end
        if strcmp(name,[exportStem '_ue.csv'])
            ueOk=checkUeBalance(actual,marker.balances,loaded.configSnapshot.simulation.numUE);
            report=addCheck(report,'ue-balance',ueOk, ...
                'Per-UE totals and row count must balance the KPI summary.');
        end
    catch exception
        report=addCheck(report,['read-' name],false,exception.message);
    end
end
report=finish(report);
end

function tables=memoryTables(result,exportStem,includeSummary,includeRadioDiagnostics,includeGroupKpi,includeDiagnostics)
data={result.ueSummary,result.kpiTimeSeries,result.dataset.observations, ...
    result.dataset.targets,result.resourceUsage,result.dataset.manifest};
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv','_resources.csv','_split.csv'};
if isAdaptiveResult(result)
    data{end+1}=struct2table(result.controllerLog,'AsArray',true);
    suffixes{end+1}='_controller.csv';
end
if includeSummary
    data{end+1}=nbiot.results.buildKpiSummaryTable(result);
    suffixes{end+1}='_summary.csv';
end
if includeRadioDiagnostics
    data{end+1}=nbiot.results.buildRadioDiagnosticsTable(result);
    suffixes{end+1}='_radio.csv';
end
if includeGroupKpi
    data{end+1}=result.groupKpi;
    suffixes{end+1}='_groups.csv';
end
if includeDiagnostics
    data{end+1}=result.dataset.diagnostics;
    suffixes{end+1}='_diagnostics.csv';
end
tables=repmat(struct('file','','variableNames',{{}},'rows',0),numel(suffixes),1);
for k=1:numel(suffixes)
    tables(k)=struct('file',[exportStem suffixes{k}], ...
        'variableNames',{data{k}.Properties.VariableNames},'rows',height(data{k}));
end
end

function files=memoryTableFiles(exportStem,includeController,includeSummary, ...
    includeRadioDiagnostics,includeGroupKpi,includeDiagnostics)
files=string({[exportStem '_ue.csv'],[exportStem '_kpi.csv'], ...
    [exportStem '_observations.csv'],[exportStem '_targets.csv'], ...
    [exportStem '_resources.csv'],[exportStem '_split.csv']});
if includeController, files(end+1)=[exportStem '_controller.csv']; end
if includeSummary, files(end+1)=[exportStem '_summary.csv']; end
if includeRadioDiagnostics, files(end+1)=[exportStem '_radio.csv']; end
if includeGroupKpi, files(end+1)=[exportStem '_groups.csv']; end
if includeDiagnostics, files(end+1)=[exportStem '_diagnostics.csv']; end
end

function value=memoryTable(result,file,includeSummary,includeRadioDiagnostics,includeGroupKpi,includeDiagnostics)
tables={result.ueSummary,result.kpiTimeSeries,result.dataset.observations, ...
    result.dataset.targets,result.resourceUsage,result.dataset.manifest};
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv','_resources.csv','_split.csv'};
if isAdaptiveResult(result)
    tables{end+1}=struct2table(result.controllerLog,'AsArray',true);
    suffixes{end+1}='_controller.csv';
end
if includeSummary
    tables{end+1}=nbiot.results.buildKpiSummaryTable(result);
    suffixes{end+1}='_summary.csv';
end
if includeRadioDiagnostics
    tables{end+1}=nbiot.results.buildRadioDiagnosticsTable(result);
    suffixes{end+1}='_radio.csv';
end
if includeGroupKpi
    tables{end+1}=result.groupKpi;
    suffixes{end+1}='_groups.csv';
end
if includeDiagnostics
    tables{end+1}=diagnosticsCsvTable(result.dataset.diagnostics);
    suffixes{end+1}='_diagnostics.csv';
end
for k=1:numel(suffixes)
    if endsWith(file,suffixes{k}), value=tables{k}; return; end
end
error('nbiot:results:Verify','Unknown table export %s.',file);
end

function included=markerHasTable(marker,suffix)
included=false;
if isempty(marker)||~isfield(marker,'tables')||isempty(marker.tables), return; end
tables=marker.tables;
if iscell(tables), tables=[tables{:}]; end
if ~isstruct(tables)||~all(isfield(tables,'file')), return; end
included=any(endsWith(string({tables.file}),suffix));
end

function yes=hasDatasetDiagnostics(result)
yes=isstruct(result)&&isscalar(result)&&isfield(result,'dataset')&& ...
    isstruct(result.dataset)&&isscalar(result.dataset)&&isfield(result.dataset,'diagnostics');
end

function names=diagnosticsNames()
names={'realizationId','windowId','startTick','endTick', ...
    'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
    'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
    'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
    'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
    'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'};
end

function ok=validDiagnosticsResult(value,result)
ok=false;
if ~istable(value)||~isstruct(result)||~isscalar(result)|| ...
        ~isfield(result,'dataset')||~isstruct(result.dataset)|| ...
        ~all(isfield(result.dataset,{'observations','targets','diagnostics'}))
    return
end
actualTick=diagnosticsActualTick(result);
if isempty(actualTick), return; end
names=diagnosticsNames(); keys=names(1:4);
if ~isequal(value.Properties.VariableNames,names)|| ...
        ~istable(result.dataset.observations)||~istable(result.dataset.targets)|| ...
        ~all(ismember(keys,result.dataset.observations.Properties.VariableNames))|| ...
        ~all(ismember(keys,result.dataset.targets.Properties.VariableNames))|| ...
        ~diagnosticsTablesEqual(value,result.dataset.diagnostics)
    return
end
if height(unique(value(:,keys),'rows'))~=height(value), return; end
if ~isAssemblerValidationFixture(result)
    if height(value)~=height(result.dataset.observations)|| ...
            height(value)~=height(result.dataset.targets)|| ...
            ~diagnosticsKeysMatchByKey(value(:,keys),result.dataset.observations(:,keys),keys)|| ...
            ~diagnosticsKeysMatchByKey(value(:,keys),result.dataset.targets(:,keys),keys)
        return
    end
end
if ~isnumeric(actualTick)||~isscalar(actualTick)|| ...
        ~isfinite(actualTick)||actualTick<0||actualTick~=fix(actualTick)
    return
end
numericNames=names([1:14 20]);
for k=1:numel(numericNames)
    if ~isnumeric(value.(numericNames{k})), return; end
end
availabilityNames=names(15:19);
for k=1:numel(availabilityNames)
    if ~availabilityFlagColumn(value.(availabilityNames{k}),height(value)), return; end
end
if height(value)>0
    if any(~isfinite(value.realizationId))||any(value.realizationId<0|value.realizationId~=fix(value.realizationId))|| ...
            any(~isfinite(value.windowId))||any(value.windowId<1|value.windowId~=fix(value.windowId))|| ...
            any(~isfinite(value.startTick))||any(value.startTick<0|value.startTick~=fix(value.startTick))|| ...
            any(~isfinite(value.endTick))||any(value.endTick<=value.startTick|value.endTick~=fix(value.endTick))|| ...
            any(~isfinite(value.outcomeHorizonTick))|| ...
            any(value.outcomeHorizonTick~=actualTick)||any(value.endTick>value.outcomeHorizonTick)
        return
    end
end
ok=availableCountsValid(value,'logicalAvailable', ...
        {'logicalCollisionGroups','logicalCollidingAttempts'})&& ...
    availableCountsValid(value,'physicalAvailable', ...
        {'physicalOverlapPairs','physicalCollidingAttempts'})&& ...
    availableCountsValid(value,'accessAvailable', ...
        {'successfulAccesses','unfinishedAccessCohort'})&& ...
    availableCountsValid(value,'retryAvailable',{'raRetryTransmissions'})&& ...
    finiteOrUnavailableCount(value.unfinishedPacketCohort)&& ...
    delayValuesValid(value);
end

function ok=availableCountsValid(value,availabilityName,metricNames)
ok=true;
available=value.(availabilityName);
for row=1:height(value)
    for k=1:numel(metricNames)
        values=value.(metricNames{k}); metric=values(row);
        if available(row)
            valid=isfinite(metric)&&metric>=0&&metric==fix(metric);
        else
            valid=isnan(metric);
        end
        if ~valid, ok=false; return; end
    end
end
end

function ok=finiteOrUnavailableCount(values)
ok=all((isfinite(values)&values>=0&values==fix(values))|isnan(values));
end

function ok=delayValuesValid(value)
ok=true;
for row=1:height(value)
    count=value.delaySampleCount(row); meanDelay=value.meanDelayTicks(row);
    if value.delayAvailable(row)
        valid=isfinite(count)&&count>0&&count==fix(count)&& ...
            isfinite(meanDelay)&&meanDelay>=0;
    else
        valid=isnan(meanDelay)&&(isnan(count)||count==0);
    end
    if ~valid, ok=false; return; end
end
end

function same=diagnosticsTablesEqual(left,right)
same=false;
if ~istable(left)||~istable(right)|| ...
        ~isequal(left.Properties.VariableNames,right.Properties.VariableNames)|| ...
        height(left)~=height(right)
    return
end
for k=1:numel(left.Properties.VariableNames)
    a=left{:,k}; b=right{:,k};
    if (isnumeric(a)||islogical(a))&&(isnumeric(b)||islogical(b))
        same=isequaln(double(a),double(b));
    else
        same=isequaln(a,b);
    end
    if ~same, return; end
end
same=true;
end

function same=diagnosticsCsvMatchesSnapshot(csvTable,snapshot)
same=false;
names=diagnosticsNames(); availabilityNames=names(15:19);
if ~istable(csvTable)||~istable(snapshot)|| ...
        ~isequal(csvTable.Properties.VariableNames,names)|| ...
        ~isequal(snapshot.Properties.VariableNames,names)||height(csvTable)~=height(snapshot)
    return
end
% A header-only CSV has no cell values from which readtable can recover the
% original MATLAB column types. The MAT snapshot retains those types, so after
% validating the exact schema and zero row count there is no CSV data to compare.
if height(snapshot)==0
    same=true;
    return
end
for k=1:numel(availabilityNames)
    name=availabilityNames{k}; tokens=csvTable.(name);
    [csvFlags,csvFlagsValid]=diagnosticsCsvAvailability(tokens,height(csvTable));
    if ~csvFlagsValid||~availabilityFlagColumn(snapshot.(name),height(snapshot))
        return
    end
    if ~isequal(csvFlags,logical(snapshot.(name)))
        return
    end
end
nonAvailabilityNames=names(1:14);
nonAvailabilityNames=[nonAvailabilityNames names(20)];
same=diagnosticsTablesEqual(csvTable(:,nonAvailabilityNames),snapshot(:,nonAvailabilityNames));
end

function [flags,valid]=diagnosticsCsvAvailability(values,rowCount)
valid=false; flags=false(rowCount,1);
if size(values,1)~=rowCount||size(values,2)~=1, return; end
if islogical(values)
    flags=values; valid=true;
elseif isstring(values)&&~any(ismissing(values))&& ...
        all(ismember(values,["true","false"]))
    flags=values=="true"; valid=true;
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

function same=diagnosticsKeysMatchByKey(left,right,keyNames)
same=false;
if ~istable(left)||~istable(right)||height(left)~=height(right)|| ...
        ~all(ismember(keyNames,left.Properties.VariableNames))|| ...
        ~all(ismember(keyNames,right.Properties.VariableNames))
    return
end
left=sortrows(left,keyNames); right=sortrows(right,keyNames);
same=diagnosticsTablesEqual(left,right);
end

function yes=isAssemblerValidationFixture(result)
yes=false;
if ~isDevelopmentFixtureResult(result)||~isfield(result,'config')|| ...
        ~isstruct(result.config)||~isscalar(result.config)|| ...
        ~isfield(result.config,'simulation')||~isstruct(result.config.simulation)|| ...
        ~isscalar(result.config.simulation)||~isfield(result.config,'dataset')|| ...
        ~isstruct(result.config.dataset)||~isscalar(result.config.dataset)|| ...
        ~all(isfield(result.config.simulation,{'durationTicks','realizationId'}))|| ...
        ~isfield(result.config.dataset,'windowTicks')
    return
end
observations=result.dataset.observations; targets=result.dataset.targets;
keys={'realizationId','windowId','startTick','endTick'};
yes=~hasExpectedWindowKeys(observations,keys,result.config)|| ...
    ~hasExpectedWindowKeys(targets,keys,result.config);
end

function actualTick=diagnosticsActualTick(result)
actualTick=[];
if isfield(result,'actualTick')
    actualTick=result.actualTick;
    return
end
if ~isstruct(result)||~isscalar(result)||~isfield(result,'config')|| ...
        ~isstruct(result.config)||~isscalar(result.config)|| ...
        ~isfield(result.config,'simulation')||~isstruct(result.config.simulation)|| ...
        ~isscalar(result.config.simulation)||~isfield(result.config,'dataset')|| ...
        ~isstruct(result.config.dataset)||~isscalar(result.config.dataset)|| ...
        ~all(isfield(result.config.simulation,{'durationTicks','realizationId'}))|| ...
        ~isfield(result.config.dataset,'windowTicks')||~isfield(result,'dataset')|| ...
        ~isstruct(result.dataset)||~all(isfield(result.dataset,{'observations','targets','diagnostics'}))
    return
end
cfg=result.config; keys={'realizationId','windowId','startTick','endTick'};
diagnostics=result.dataset.diagnostics;
if ~istable(diagnostics)||~ismember('outcomeHorizonTick',diagnostics.Properties.VariableNames)
    return
end
horizon=cfg.simulation.durationTicks;
diagnosticHorizons=diagnostics.outcomeHorizonTick;
if ~isnumeric(horizon)||~isreal(horizon)||~isscalar(horizon)|| ...
        ~isfinite(horizon)||horizon<1||horizon~=fix(horizon)|| ...
        ~isnumeric(diagnosticHorizons)||~isreal(diagnosticHorizons)|| ...
        size(diagnosticHorizons,1)~=height(diagnostics)||size(diagnosticHorizons,2)~=1|| ...
        isempty(diagnosticHorizons)||any(~isfinite(diagnosticHorizons))|| ...
        any(diagnosticHorizons~=horizon)
    return
end
diagnosticsCoverHorizon=hasExpectedWindowKeys(diagnostics,keys,cfg);
observationsCoverHorizon=hasExpectedWindowKeys(result.dataset.observations,keys,cfg);
targetsCoverHorizon=hasExpectedWindowKeys(result.dataset.targets,keys,cfg);
% Require the diagnostic grid and at least one closed-window source table.
if diagnosticsCoverHorizon&&(observationsCoverHorizon||targetsCoverHorizon)
    actualTick=horizon;
end
end

function ok=availabilityFlagColumn(values,rowCount)
ok=false;
if size(values,1)~=rowCount||size(values,2)~=1, return; end
% Accept boolean storage only; numeric representations must be exact 0/1.
if islogical(values)
    ok=true;
elseif isnumeric(values)&&isreal(values)
    ok=all(isfinite(values(:))&(values(:)==0|values(:)==1));
end
end

function valid=hasExpectedWindowKeys(rows,keys,cfg)
valid=false;
if ~isstruct(cfg)||~isscalar(cfg)||~isfield(cfg,'simulation')|| ...
        ~isstruct(cfg.simulation)||~isscalar(cfg.simulation)|| ...
        ~isfield(cfg,'dataset')||~isstruct(cfg.dataset)||~isscalar(cfg.dataset)|| ...
        ~all(isfield(cfg.simulation,{'durationTicks','realizationId'}))|| ...
        ~isfield(cfg.dataset,'windowTicks')|| ...
        ~istable(rows)||~all(ismember(keys,rows.Properties.VariableNames))|| ...
        ~isnumeric(cfg.simulation.durationTicks)||~isreal(cfg.simulation.durationTicks)|| ...
        ~isscalar(cfg.simulation.durationTicks)|| ...
        ~isfinite(cfg.simulation.durationTicks)||cfg.simulation.durationTicks<1|| ...
        cfg.simulation.durationTicks~=fix(cfg.simulation.durationTicks)|| ...
        ~isnumeric(cfg.simulation.realizationId)||~isreal(cfg.simulation.realizationId)|| ...
        ~isscalar(cfg.simulation.realizationId)|| ...
        ~isfinite(cfg.simulation.realizationId)||cfg.simulation.realizationId<0|| ...
        cfg.simulation.realizationId~=fix(cfg.simulation.realizationId)|| ...
        ~isnumeric(cfg.dataset.windowTicks)||~isreal(cfg.dataset.windowTicks)|| ...
        ~isscalar(cfg.dataset.windowTicks)|| ...
        ~isfinite(cfg.dataset.windowTicks)||cfg.dataset.windowTicks<1|| ...
        cfg.dataset.windowTicks~=fix(cfg.dataset.windowTicks)
    return
end
windowIds=(1:ceil(cfg.simulation.durationTicks/cfg.dataset.windowTicks)).';
expected=table(repmat(cfg.simulation.realizationId,numel(windowIds),1),windowIds, ...
    (windowIds-1)*cfg.dataset.windowTicks, ...
    min(windowIds*cfg.dataset.windowTicks,cfg.simulation.durationTicks), ...
    'VariableNames',keys);
actual=sortrows(rows(:,keys),'windowId');
valid=isequaln(actual,expected);
end

function yes=isDevelopmentFixtureResult(result)
yes=isstruct(result)&&isscalar(result)&&isfield(result,'environment')&& ...
    isstruct(result.environment)&&isscalar(result.environment)&& ...
    isfield(result.environment,'sourceProfile')&& ...
    strcmp(char(string(result.environment.sourceProfile)),'development-fixture');
end

function hex=tableHash(value)
path=[tempname '.csv']; cleanup=onCleanup(@() removeTemporary(path));
writetable(value,path); hex=hashFile(path);
end

function hex=hashFile(path)
fid=fopen(path,'rb');
if fid<0, error('nbiot:results:Hash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid));
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function balances=balanceSnapshot(kpi)
names={'created','delivered','dropped','unfinished', ...
    'raStarted','raSuccess','raFailed','raUnfinished'};
balances=struct();
for k=1:numel(names)
    if ~isfield(kpi,names{k}), error('nbiot:results:Balance','Missing %s.',names{k}); end
    balances.(names{k})=kpi.(names{k});
end
end

function ok=checkUeBalance(ue,b,numUE)
required={'created','delivered','dropped','unfinished'};
if ~all(ismember(required,ue.Properties.VariableNames)) || height(ue)~=numUE
    ok=false; return
end
if any(ue.created~=ue.delivered+ue.dropped+ue.unfinished), ok=false; return; end
ok=sum(ue.created)==double(b.created) && sum(ue.delivered)==double(b.delivered) && ...
    sum(ue.dropped)==double(b.dropped) && sum(ue.unfinished)==double(b.unfinished);
end

function ok=equivalent(a,b)
if ischar(a) || isstring(a), a=char(string(a)); end
if ischar(b) || isstring(b), b=char(string(b)); end
if (isnumeric(a)||islogical(a))&&(isnumeric(b)||islogical(b))
    if ~strcmp(class(a),class(b)), ok=false; return; end
    if isvector(a)&&isvector(b)&&numel(a)==numel(b)
        ok=isequaln(a(:),b(:));
    else
        ok=isequaln(a,b);
    end
    return;
end
if isstruct(a)||isstruct(b)
    ok=false;
    if ~isstruct(a)||~isstruct(b)||numel(a)~=numel(b), return; end
    fieldsA=sort(fieldnames(a)); fieldsB=sort(fieldnames(b));
    if ~isequal(fieldsA,fieldsB), return; end
    if ~isequal(size(a),size(b))&&~(isvector(a)&&isvector(b)), return; end
    a=a(:); b=b(:);
    for row=1:numel(a)
        for field=1:numel(fieldsA)
            name=fieldsA{field};
            if ~equivalent(a(row).(name),b(row).(name)), return; end
        end
    end
    ok=true; return;
end
try
    ok=isequaln(a,b);
catch
    ok=false;
end
end

function report=addCheck(report,name,passed,detail)
passed=logical(passed);
report.checks(end+1)=struct('name',name,'passed',passed,'detail',char(string(detail)));
if ~passed, report.errors{end+1}=sprintf('%s: %s',name,char(string(detail))); end
end

function report=finish(report)
report.passed=~isempty(report.checks) && all([report.checks.passed]) && isempty(report.errors);
end

function name=stem(result)
name=stemFromConfig(result.config);
end

function name=stemFromConfig(cfg)
method='Static';
if isfield(cfg,'policy')&&isfield(cfg.policy,'name'), method=char(string(cfg.policy.name)); end
switch method
    case 'Static', prefix='static-v1';
    case 'Adaptive-P', prefix='adaptive-p-v1';
    case 'Adaptive-RA/DT', prefix='adaptive-ra-dt-v1';
    otherwise, error('nbiot:results:Method','Unsupported result method %s.',method);
end
name=sprintf('%s_n%d_r%04d',prefix,cfg.simulation.numUE,cfg.simulation.realizationId);
end

function yes=isAdaptiveResult(result)
yes=isstruct(result)&&isscalar(result)&&isfield(result,'config')&& ...
    isfield(result.config,'policy')&&isfield(result.config.policy,'name')&& ...
    any(strcmp(char(string(result.config.policy.name)),{'Adaptive-P','Adaptive-RA/DT'}));
end

function value=ternary(condition,yes,no)
if condition, value=yes; else, value=no; end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end

function ok=runtimeValid(value)
names={'runtimeVersion','resultSchemaVersion','canonicalConfigSha256', ...
    'modelSha256','policySha256','inputSha256','runnerSha256'};
ok=isstruct(value) && isscalar(value) && all(isfield(value,names));
if ~ok, return; end
schema=double(value.resultSchemaVersion);
ok=isequal(double(value.runtimeVersion),1) && any(schema==[2 3]);
if schema==3
    ok=ok&&isfield(value,'controllerPolicy')&&isstruct(value.controllerPolicy)&& ...
        isscalar(value.controllerPolicy);
end
hashes=[{'configSha256','sourceSha256','calibrationSha256'} names(3:end)];
for k=1:numel(hashes)
    ok=ok && isfield(value,hashes{k}) && ...
        ~isempty(regexp(char(string(value.(hashes{k}))),'^[0-9a-fA-F]{64}$','once'));
end
end

function [ok,detail]=verifyReportMetadata(caseFolder,marker)
ok=false; detail='Report sidecar must match the marker identity and linked CSV files.';
reportName=char(string(marker.reportMetadataFile));
[~,name,extension]=fileparts(reportName);
if ~isempty(fileparts(reportName))||~strcmp([name extension], ...
        [char(string(marker.exportStem)) '_report.json'])
    detail='Report metadata must be a local file named for this case.'; return
end
canonicalHash=char(string(marker.canonicalConfigSha256));
if isempty(regexp(canonicalHash,'^[0-9a-fA-F]{64}$','once'))
    detail='Report metadata requires the canonical configuration SHA-256.'; return
end
reportPath=fullfile(caseFolder,reportName);
if ~isfile(reportPath), detail='Report metadata sidecar is missing.'; return; end
try
    report=jsondecode(fileread(reportPath));
catch exception
    detail=['Report metadata JSON is invalid: ' exception.message]; return
end
required={'schemaVersion','caseKey','canonicalConfigSha256','fields', ...
    'unavailableFields','reason','files'};
if ~isstruct(report)||~isscalar(report)||~all(isfield(report,required))|| ...
        ~isequal(double(report.schemaVersion),1)
    detail='Report metadata schema is unsupported.'; return
end
fieldNames={'mode','numUE','activeUE','trafficType','payloadBytes','periodTicks', ...
    'durationTicks','actualTick','tickSeconds','durationSeconds','kpiWindowTicks', ...
    'planned','created','delivered','dropped','unfinished'};
if ~isstruct(report.fields)||~isscalar(report.fields)||~all(isfield(report.fields,fieldNames))
    detail='Report metadata fields are incomplete.'; return
end
if ~strcmp(char(string(report.caseKey)),char(string(marker.caseKey)))|| ...
        ~strcmpi(char(string(report.canonicalConfigSha256)),canonicalHash)
    detail='Report metadata identity differs from the completion marker.'; return
end
if ~isstruct(report.files)||~isscalar(report.files)|| ...
        ~all(isfield(report.files,{'kpi','summary'}))
    detail='Report metadata must reference the KPI and summary CSVs.'; return
end
expectedNames={[char(string(marker.exportStem)) '_kpi.csv'], ...
    [char(string(marker.exportStem)) '_summary.csv']};
refs={report.files.kpi,report.files.summary};
records=marker.files; if iscell(records), records=[records{:}]; end
for k=1:numel(refs)
    ref=refs{k};
    if ~isstruct(ref)||~isscalar(ref)||~all(isfield(ref,{'name','bytes','sha256'}))|| ...
            ~strcmp(char(string(ref.name)),expectedNames{k})
        detail='Report metadata references an unexpected CSV.'; return
    end
    matches=find(strcmp(cellstr(string({records.name})),expectedNames{k}));
    if numel(matches)~=1
        detail='Completion marker must list each referenced CSV exactly once.'; return
    end
    record=records(matches);
    if ~isequal(double(ref.bytes),double(record.bytes))|| ...
            ~strcmpi(char(string(ref.sha256)),char(string(record.sha256)))
        detail='Report metadata CSV identity differs from the completion marker.'; return
    end
end
ok=true; detail='Report metadata identity and CSV references match the completion marker.';
end
