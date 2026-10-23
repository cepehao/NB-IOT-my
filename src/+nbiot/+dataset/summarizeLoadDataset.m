function [summary,coverage]=summarizeLoadDataset(data)
%SUMMARIZELOADDATASET Describe independent-ID and scenario coverage.
%   Сводка датасета: число независимых реализаций, нагрузки, сценарии, покрытие выборок.
required={'observations','rowInfo','schema','manifest'};
if ~isstruct(data)||~isscalar(data)||~all(isfield(data,required))|| ...
        ~istable(data.observations)||~istable(data.rowInfo)|| ...
        ~isstruct(data.manifest)||~isfield(data.manifest,'inputs')|| ...
        ~isfield(data.manifest,'assignments')||~istable(data.manifest.assignments)
    error('nbiot:dataset:Report','Dataset lacks the tables or manifest needed for a coverage report.');
end
inputs=data.manifest.inputs;
inputFields={'caseKey','realizationId','numUE','trafficKind','burstDurationTicks', ...
    'periodTicks','poissonRatePerSecond','configuredAccessProbability','configuredRaShare'};
if isempty(inputs)||~isstruct(inputs)||~all(isfield(inputs,inputFields))
    error('nbiot:dataset:Report','Dataset manifest lacks scenario metadata for its cases.');
end
assignments=data.manifest.assignments;
assignmentFields={'externalRealizationId','split','experimentRole'};
if ~all(ismember(assignmentFields,assignments.Properties.VariableNames))|| ...
        ~all(ismember({'caseKey','realizationId'},data.rowInfo.Properties.VariableNames))
    error('nbiot:dataset:Report','Dataset lacks explicit ID roles or case keys.');
end

caseCount=numel(inputs);
caseKeys=strings(caseCount,1);
realizationIds=zeros(caseCount,1);
numUE=zeros(caseCount,1);
trafficKinds=strings(caseCount,1);
burstDurationTicks=nan(caseCount,1);
periodTicks=nan(caseCount,1);
poissonRatePerSecond=nan(caseCount,1);
configuredAccessProbability=nan(caseCount,1);
configuredRaShare=nan(caseCount,1);
split=strings(caseCount,1);
experimentRole=strings(caseCount,1);
windowCount=zeros(caseCount,1);
observedAccessProbabilityValues=strings(caseCount,1);
observedRaShareValues=strings(caseCount,1);

for caseIndex=1:caseCount
    caseKeys(caseIndex)=string(inputs(caseIndex).caseKey);
    realizationIds(caseIndex)=double(inputs(caseIndex).realizationId);
    numUE(caseIndex)=double(inputs(caseIndex).numUE);
    trafficKinds(caseIndex)=string(inputs(caseIndex).trafficKind);
    burstDurationTicks(caseIndex)=double(inputs(caseIndex).burstDurationTicks);
    periodTicks(caseIndex)=double(inputs(caseIndex).periodTicks);
    poissonRatePerSecond(caseIndex)=double(inputs(caseIndex).poissonRatePerSecond);
    configuredAccessProbability(caseIndex)=double(inputs(caseIndex).configuredAccessProbability);
    configuredRaShare(caseIndex)=double(inputs(caseIndex).configuredRaShare);

    assignmentAt=find(assignments.externalRealizationId==realizationIds(caseIndex));
    if numel(assignmentAt)~=1
        error('nbiot:dataset:Report','Each case must have exactly one ID role assignment.');
    end
    split(caseIndex)=string(assignments.split(assignmentAt));
    experimentRole(caseIndex)=string(assignments.experimentRole(assignmentAt));

    rowMask=string(data.rowInfo.caseKey)==caseKeys(caseIndex);
    windowCount(caseIndex)=sum(rowMask);
    if windowCount(caseIndex)==0
        error('nbiot:dataset:Report','A manifest case has no aligned observation rows.');
    end
    observedAccessProbabilityValues(caseIndex)=settingValues( ...
        data.observations,'accessProbability',rowMask);
    observedRaShareValues(caseIndex)=settingValues(data.observations,'raShare',rowMask);
end

coverage=table(caseKeys,realizationIds,split,experimentRole,numUE,trafficKinds, ...
    burstDurationTicks,periodTicks,poissonRatePerSecond, ...
    configuredAccessProbability,configuredRaShare, ...
    observedAccessProbabilityValues,observedRaShareValues,windowCount, ...
    'VariableNames',{'caseKey','realizationId','split','experimentRole','numUE', ...
    'trafficKind','burstDurationTicks','periodTicks','poissonRatePerSecond', ...
    'configuredAccessProbability','configuredRaShare', ...
    'observedAccessProbabilityValues','observedRaShareValues','windowCount'});

assignments=unique(assignments(:,{'split','experimentRole'}),'rows','stable');
independentIds=zeros(height(assignments),1);
for groupIndex=1:height(assignments)
    match=string(data.manifest.assignments.split)==string(assignments.split(groupIndex))& ...
        string(data.manifest.assignments.experimentRole)== ...
        string(assignments.experimentRole(groupIndex));
    independentIds(groupIndex)=sum(match);
end
assignments.independentRealizations=independentIds;

schema=data.schema;
if ~isstruct(schema)||~all(isfield(schema,{'version','inputNames','targetName'}))
    error('nbiot:dataset:Report','Dataset feature schema is incomplete.');
end
rolesExplicit=isfield(data.manifest,'experimentRolesExplicit')&& ...
    isequal(data.manifest.experimentRolesExplicit,true);
allocationsVerified=isfield(data.manifest,'allocationsVerified')&& ...
    isequal(data.manifest.allocationsVerified,true);
summary=struct('formatVersion','load-dataset-summary-v1', ...
    'datasetKind',char(string(data.manifest.kind)), ...
    'schemaVersion',char(string(schema.version)), ...
    'targetName',char(string(schema.targetName)), ...
    'featureNames',{cellstr(string(schema.inputNames))}, ...
    'rowCount',height(data.rowInfo),'caseCount',caseCount, ...
    'independentRealizations',height(data.manifest.assignments), ...
    'experimentRolesExplicit',rolesExplicit,'allocationsVerified',allocationsVerified, ...
    'groupCounts',table2struct(assignments), ...
    'trafficKinds',{cellstr(unique(trafficKinds,'stable'))}, ...
    'numUEValues',finiteUnique(numUE), ...
    'configuredAccessProbabilityValues',finiteUnique(configuredAccessProbability), ...
    'configuredRaShareValues',finiteUnique(configuredRaShare), ...
    'observedAccessProbabilityValues',settingValues(data.observations,'accessProbability',true(height(data.observations),1)), ...
    'observedRaShareValues',settingValues(data.observations,'raShare',true(height(data.observations),1)));
if isfield(data.manifest,'diagnosticsComplete')&&isfield(data.manifest,'diagnosticsSchemaVersion')
    summary.diagnosticsComplete=isequal(data.manifest.diagnosticsComplete,true);
    summary.diagnosticsSchemaVersion=char(string(data.manifest.diagnosticsSchemaVersion));
end
end

function text=settingValues(observations,name,rowMask)
text="";
if ~ismember(name,observations.Properties.VariableNames)
    return
end
values=observations.(name);
if ~isnumeric(values)||numel(values)~=numel(rowMask)
    error('nbiot:dataset:Report','Observed setting %s must be a numeric window column.',name);
end
values=sort(unique(double(values(rowMask))));
values=values(isfinite(values));
if ~isempty(values)
    text=strjoin(compose('%.6g',values),';');
end
end

function values=finiteUnique(values)
values=unique(double(values(isfinite(values))));
values=values(:).';
end
