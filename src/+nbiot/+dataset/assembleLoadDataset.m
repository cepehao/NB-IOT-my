function data=assembleLoadDataset(resultFiles,splitManifest)
%ASSEMBLELOADDATASET Verify saved cases and align closed BS/target windows.
%   Сборка датасета ML из сохранённых прогонов (ТЗ §22): проверка файлов, выравнивание окон
%   признаков BS и target, разбиение по реализациям.
% Reads only MAT snapshots and CSV exports, never the full waveform result.
files=cellstr(string(resultFiles));
if isempty(files)||~isvector(files), error('nbiot:dataset:Inputs','Supply explicit MAT result files.'); end
[splits,rolesExplicit]=validateSplits(splitManifest);
schema=[]; keys={'realizationId','windowId','startTick','endTick'};
observations=[]; targets=[]; rowInfo=[]; diagnostics=[]; seen=strings(0,1);
diagnosticsComplete=true;
inputs=struct('resultFile',{},'caseKey',{},'sourceSha256',{},'calibrationSha256',{}, ...
    'markerSha256',{},'schemaVersion',{},'numUE',{},'realizationId',{},'isFixture',{}, ...
    'trafficKind',{},'burstDurationTicks',{},'periodTicks',{},'poissonRatePerSecond',{}, ...
    'configuredAccessProbability',{},'configuredRaShare',{});
for k=1:numel(files)
    [obs,answer,caseDiagnostics,hasDiagnostics,info,caseSchema]=readCase(files{k});
    if isempty(schema)
        schema=caseSchema; keys=schema.observationNames(1:4);
    elseif ~strcmp(schema.version,caseSchema.version)
        error('nbiot:dataset:Schema','Cases with different feature-schema versions cannot be mixed.');
    end
    if any(seen==string(info.caseKey)), error('nbiot:dataset:Duplicate','A case was supplied more than once.'); end
    seen(end+1)=string(info.caseKey); %#ok<AGROW>
    at=find(splits.externalRealizationId==info.realizationId);
    if numel(at)~=1, error('nbiot:dataset:SplitManifest','Each external ID needs one explicit group.'); end
    group=splits.split(at); experimentRole=splits.experimentRole(at);
    rows=table(repmat(string(info.caseKey),height(obs),1),obs.realizationId,obs.windowId, ...
        obs.startTick,obs.endTick,repmat(group,height(obs),1), ...
        repmat(experimentRole,height(obs),1), ...
        'VariableNames',{'caseKey','realizationId','windowId','startTick','endTick','split','experimentRole'});
    caseDiagnostics.caseKey=repmat(string(info.caseKey),height(caseDiagnostics),1);
    caseDiagnostics=movevars(caseDiagnostics,'caseKey','Before',1);
    if isempty(observations)
        observations=obs; targets=answer; rowInfo=rows; diagnostics=caseDiagnostics;
    else
        observations=[observations;obs]; targets=[targets;answer]; %#ok<AGROW>
        rowInfo=[rowInfo;rows]; diagnostics=[diagnostics;caseDiagnostics]; %#ok<AGROW>
    end
    diagnosticsComplete=diagnosticsComplete&&hasDiagnostics;
    inputs(end+1)=info; %#ok<AGROW>
end
if numel(unique(string({inputs.sourceSha256})))~=1 || numel(unique(string({inputs.calibrationSha256})))~=1
    error('nbiot:dataset:Schema','Do not mix computational/calibration revisions in one dataset.');
end
[rowInfo,order]=sortrows(rowInfo,{'caseKey','windowId'});
observations=observations(order,:); targets=targets(order,:); diagnostics=diagnostics(order,:);
if ~isequal(diagnostics(:,{'caseKey','realizationId','windowId','startTick','endTick'}), ...
        rowInfo(:,{'caseKey','realizationId','windowId','startTick','endTick'}))
    error('nbiot:dataset:InvalidCase','Dataset diagnostics do not align one-to-one with case windows.');
end
usedIds=unique(rowInfo.realizationId); usedSplits=splits(ismember(splits.externalRealizationId,usedIds),:);
kind='candidate-training';
if all(rowInfo.split=="development"), kind='development-simulation'; end
if all(rowInfo.experimentRole=="final-comparison"), kind='final-comparison';
elseif any(rowInfo.experimentRole=="final-comparison"), kind='mixed-experiment-roles'; end
if any([inputs.isFixture]), kind='development-fixture'; end
schema.keyNames=keys; schema.inputNames=schema.observationNames(5:end); schema.targetName='meanRaUe';
data=struct('observations',observations,'targets',targets, ...
    'features',observations(:,schema.inputNames),'rowInfo',rowInfo,'schema',schema, ...
    'manifest',struct('version',1,'kind',kind,'target','meanRaUe','schemaVersion',schema.version, ...
        'independentRealizations',numel(usedIds),'rows',height(observations), ...
        'assignments',usedSplits,'experimentRolesExplicit',rolesExplicit, ...
        'inputs',inputs,'allocationsVerified',false, ...
        'diagnosticsComplete',diagnosticsComplete, ...
        'diagnosticsSchemaVersion','window-diagnostics-v1', ...
        'normalization','Not fitted; fit transformations on train only.'), ...
    'diagnostics',diagnostics);
end

function [splits,rolesExplicit]=validateSplits(value)
required={'externalRealizationId','split'};
allowed=[required,{'experimentRole'}];
if ~istable(value)||~all(ismember(required,value.Properties.VariableNames))|| ...
        any(~ismember(value.Properties.VariableNames,allowed))||isempty(value)
    error('nbiot:dataset:SplitManifest','An explicit ID/group table is required.');
end
ids=value.externalRealizationId;
if ~isnumeric(ids)||~iscolumn(ids)||any(~isfinite(ids)|ids<0|ids>=4000|ids~=fix(ids))
    error('nbiot:dataset:SplitManifest','Main realization IDs must be integers in 0:3999.');
end
if numel(unique(ids))~=numel(ids)
    error('nbiot:dataset:GroupLeakage','A realization may appear in only one group.');
end
groups=string(value.split);
if ~iscolumn(groups)||any(~ismember(groups,["train","validation","test","development"]))
    error('nbiot:dataset:SplitManifest','Allowed groups: train, validation, test, development.');
end
rolesExplicit=ismember('experimentRole',value.Properties.VariableNames);
if rolesExplicit
    roles=string(value.experimentRole);
    if ~iscolumn(roles)||any(~ismember(roles, ...
            ["development","training","validation","model-test","final-comparison"]))
        error('nbiot:dataset:RoleManifest','Each explicit experiment role must be supported text.');
    end
else
    roles=groups;
    roles(groups=="train")="training";
    roles(groups=="test")="model-test";
end
expected=groups;
expected(groups=="train")="training";
expected(groups=="test")="model-test";
consistent=roles==expected | (groups=="test" & roles=="final-comparison");
if any(~consistent)
    error('nbiot:dataset:RoleManifest','Experiment roles must match split groups; final-comparison uses test only.');
end
splits=table(double(ids),groups,roles, ...
    'VariableNames',{'externalRealizationId','split','experimentRole'});
end

function [obs,answer,diagnostics,hasDiagnostics,info,schema]=readCase(file)
folder=fileparts(file); markerPath=fullfile(folder,'case-complete.json');
if ~isfile(file)||~isfile(markerPath), error('nbiot:dataset:InvalidCase','Missing MAT or completion marker.'); end
try
    marker=jsondecode(fileread(markerPath));
    % An untrusted marker must never direct verification outside its folder.
    names=[{marker.resultFile},{marker.files.name}];
    for j=1:numel(names)
        [part,~,~]=fileparts(names{j});
        if ~isempty(part)||contains(names{j},'..')||contains(names{j},':')
            error('nbiot:dataset:InvalidCase','Marker paths must be local basenames.');
        end
    end
    [~,name,extension]=fileparts(file);
    if ~strcmp([name extension],marker.resultFile), error('nbiot:dataset:InvalidCase','MAT path does not match marker.'); end
catch exception
    error('nbiot:dataset:InvalidCase','Invalid completion marker: %s',exception.message);
end
report=nbiot.results.verifyCase(folder);
if ~report.passed, error('nbiot:dataset:InvalidCase','Case verification failed: %s',strjoin(report.errors,'; ')); end
if ~strcmp(report.status,'completed'), error('nbiot:dataset:ResultStatus','Only completed cases may enter this dataset.'); end
variables=whos('-file',file); names={variables.name};
snapshot=load(file,'configSnapshot','environmentSnapshot'); cfg=snapshot.configSnapshot;
if ismember('datasetSchema',names)
    saved=load(file,'datasetSchema');
    storedSchema=saved.datasetSchema;
    if ~isstruct(storedSchema)||~isscalar(storedSchema)
        error('nbiot:dataset:Schema','Invalid saved feature-schema snapshot.');
    end
    if isempty(fieldnames(storedSchema))
        schema=nbiot.dataset.featureSchema('static-v1.0');
    elseif isfield(storedSchema,'version')
        schema=nbiot.dataset.featureSchema(char(string(storedSchema.version)));
    else
        error('nbiot:dataset:Schema','Saved feature-schema snapshot has no version.');
    end
else
    % Pre-snapshot manifested Static cases used the fixed v1 observation table.
    schema=nbiot.dataset.featureSchema('static-v1.0');
end
obs=readtable(fullfile(folder,[marker.exportStem '_observations.csv']), ...
    'VariableNamingRule','preserve','TextType','string');
answer=readtable(fullfile(folder,[marker.exportStem '_targets.csv']), ...
    'VariableNamingRule','preserve','TextType','string');
extra=setdiff(obs.Properties.VariableNames,schema.observationNames);
if ~isempty(extra), error('nbiot:dataset:Leakage','Non-whitelisted observation fields: %s',strjoin(extra,', ')); end
if ~isequal(obs.Properties.VariableNames,schema.observationNames)||~isequal(answer.Properties.VariableNames,schema.targetNames)
    error('nbiot:dataset:Schema','Columns must match the supported observation/target schema.');
end
keys=schema.observationNames(1:4);
validateWindowRows(obs,keys,cfg); validateWindowRows(answer,keys,cfg);
obs=sortrows(obs,keys); answer=sortrows(answer,keys);
if ~isequal(obs(:,keys),answer(:,keys)), error('nbiot:dataset:WindowAlignment','Observation/target keys must match one-to-one.'); end
[diagnostics,hasDiagnostics]=readCaseDiagnostics(folder,marker,obs,keys);
features=obs{:,schema.observationNames(5:end)};
if ~isnumeric(features)||any(isinf(features(:)))
    error('nbiot:dataset:Schema','Features must be numeric; NaN is preserved for train-only imputation.');
end
values=answer{:,schema.targetNames(5:end)};
if ~isnumeric(values)||any(~isfinite(values(:)))||any(values(:)<0)|| ...
        any(answer.meanRaUe>cfg.simulation.numUE)||any(answer.meanActiveUe>cfg.simulation.numUE)
    error('nbiot:dataset:Targets','Targets must be finite, nonnegative and consistent with the UE count.');
end
info=struct('resultFile',file,'caseKey',marker.caseKey,'sourceSha256',marker.sourceSha256, ...
    'calibrationSha256',marker.calibrationSha256,'markerSha256',fileHash(markerPath), ...
    'schemaVersion',schema.version,'numUE',cfg.simulation.numUE, ...
    'realizationId',cfg.simulation.realizationId, ...
    'isFixture',strcmp(snapshot.environmentSnapshot.sourceProfile,'development-fixture'), ...
    'trafficKind',trafficKind(cfg),'burstDurationTicks',trafficParameter(cfg,'burstDurationTicks','burst'), ...
    'periodTicks',trafficParameter(cfg,'periodTicks','periodic'), ...
    'poissonRatePerSecond',trafficParameter(cfg,'poissonRatePerSecond','poisson'), ...
    'configuredAccessProbability',policyParameter(cfg,'accessProbability'), ...
    'configuredRaShare',policyParameter(cfg,'raShare'));
end

function [diagnostics,present]=readCaseDiagnostics(folder,marker,observations,observationKeys)
diagnosticNames={'realizationId','windowId','startTick','endTick', ...
    'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
    'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
    'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
    'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
    'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'};
diagnosticKeys=diagnosticNames(1:4);
if ~isfield(marker,'diagnosticsSchemaVersion')
    diagnostics=unavailableDiagnostics(observations,observationKeys,diagnosticNames);
    present=false;
    return
end
if ~strcmp(string(marker.diagnosticsSchemaVersion),'window-diagnostics-v1')
    error('nbiot:dataset:InvalidCase','Unsupported diagnostics schema version.');
end
if ~isfield(marker,'exportStem')||~ischar(marker.exportStem)
    error('nbiot:dataset:InvalidCase','Manifested case diagnostics lack an export stem.');
end
diagnosticFile=fullfile(folder,[marker.exportStem '_diagnostics.csv']);
if ~isfile(diagnosticFile)
    error('nbiot:dataset:InvalidCase','Manifested case is missing its diagnostics CSV.');
end
try
    diagnostics=readtable(diagnosticFile,'VariableNamingRule','preserve','TextType','string');
catch exception
    error('nbiot:dataset:InvalidCase','Cannot read case diagnostics: %s',exception.message);
end
if ~isequal(diagnostics.Properties.VariableNames,diagnosticNames)|| ...
        height(diagnostics)~=height(observations)
    error('nbiot:dataset:InvalidCase','Case diagnostics have incomplete or unexpected columns/rows.');
end
numericNames=[diagnosticNames(1:14),diagnosticNames(20)];
for k=1:numel(numericNames)
    name=numericNames{k}; value=diagnostics.(name);
    if ~isnumeric(value)||~isreal(value)||~isvector(value)|| ...
            numel(value)~=height(diagnostics)||any(isinf(value(:)))
        error('nbiot:dataset:InvalidCase','Case diagnostic %s must be a real numeric column.',name);
    end
    diagnostics.(name)=double(value(:));
end
if any(~isfinite(diagnostics{:,diagnosticKeys}),'all')|| ...
        height(unique(diagnostics(:,diagnosticKeys),'rows'))~=height(diagnostics)
    error('nbiot:dataset:InvalidCase','Case diagnostics contain invalid or duplicate window keys.');
end
flagNames=diagnosticNames(15:19);
for k=1:numel(flagNames)
    name=flagNames{k}; value=diagnostics.(name);
    if islogical(value)&&isvector(value)&&numel(value)==height(diagnostics)
        diagnostics.(name)=value(:);
    elseif isnumeric(value)&&isreal(value)&&isvector(value)&&numel(value)==height(diagnostics)&& ...
            all(isfinite(value(:)))&&all(value(:)==0|value(:)==1)
        diagnostics.(name)=logical(value(:));
    else
        tokens=lower(strtrim(string(value(:))));
        if numel(tokens)~=height(diagnostics)|| ...
                any(~ismember(tokens,["true","false","1","0"]))
            error('nbiot:dataset:InvalidCase','Case diagnostic %s must contain availability flags.',name);
        end
        diagnostics.(name)=tokens=="true"|tokens=="1";
    end
end
diagnostics=sortrows(diagnostics,diagnosticKeys);
if ~isequal(double(diagnostics{:,diagnosticKeys}),double(observations{:,observationKeys}))
    error('nbiot:dataset:InvalidCase','Case diagnostics must match observation windows one-to-one.');
end
present=true;
end

function diagnostics=unavailableDiagnostics(observations,keys,names)
keyValues=double(observations{:,keys}); rowCount=height(observations);
missing=nan(rowCount,1); unavailable=false(rowCount,1);
diagnostics=table(keyValues(:,1),keyValues(:,2),keyValues(:,3),keyValues(:,4), ...
    missing,missing,missing,missing,missing,missing,missing,missing,missing,missing, ...
    unavailable,unavailable,unavailable,unavailable,unavailable,missing, ...
    'VariableNames',names);
end

function value=trafficKind(cfg)
value='unknown';
if isfield(cfg,'traffic')&&isstruct(cfg.traffic)&&isfield(cfg.traffic,'kind')
    value=char(string(cfg.traffic.kind));
end
end

function value=trafficParameter(cfg,field,kind)
value=NaN;
if strcmp(trafficKind(cfg),kind)&&isfield(cfg.traffic,field)
    value=double(cfg.traffic.(field));
end
end

function value=policyParameter(cfg,field)
value=NaN;
if isfield(cfg,'policy')&&isstruct(cfg.policy)&&isfield(cfg.policy,field)
    value=double(cfg.policy.(field));
end
end

function validateWindowRows(rows,keys,cfg)
if ~isnumeric(rows{:,keys})||any(~isfinite(rows{:,keys}),'all')
    error('nbiot:dataset:WindowAlignment','Window keys must be finite numeric values.');
end
if height(unique(rows(:,keys),'rows'))~=height(rows)
    error('nbiot:dataset:Duplicate','Duplicate window keys in one case.');
end
rows=sortrows(rows,'windowId'); horizon=cfg.simulation.durationTicks; width=cfg.dataset.windowTicks;
expected=(1:ceil(horizon/width)).';
if height(rows)~=numel(expected)||~isequal(rows.windowId,expected)|| ...
        any(rows.realizationId~=cfg.simulation.realizationId)|| ...
        ~isequal(rows.startTick,(expected-1)*width)||~isequal(rows.endTick,min(expected*width,horizon))
    error('nbiot:dataset:WindowAlignment','Only closed, aligned windows covering the completed horizon are allowed.');
end
end
function digest=fileHash(file)
md=java.security.MessageDigest.getInstance('SHA-256'); fid=fopen(file,'rb');
if fid<0, error('nbiot:dataset:InvalidCase','Cannot read source marker.'); end
cleanup=onCleanup(@() fclose(fid));
while ~feof(fid), md.update(typecast(fread(fid,1024*1024,'*uint8'),'int8')); end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
