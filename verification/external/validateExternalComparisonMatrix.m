function contract = validateExternalComparisonMatrix(matrix,options)
%VALIDATEEXTERNALCOMPARISONMATRIX Bind the review matrix to the executed sweep.
requiredOptions={'counts','burstDurations','methods','realizationIds'};
if ~isstruct(options)||~isscalar(options)||~all(isfield(options,requiredOptions))
    error('nbiot:externalStage:ScenarioOptions', ...
        'Comparison options must define counts, burst durations, methods and realization IDs.');
end

counts=integerVector(options.counts,'counts',1,65535);
burstDurations=integerVector(options.burstDurations,'burstDurations',1,2^24-1);
realizationIds=integerVector(options.realizationIds,'realizationIds',0,4095);

requested=string(options.methods(:).');
standard=["Static","Adaptive-P","Adaptive-RA/DT"];
if isempty(requested)||any(ismissing(requested))||any(strlength(requested)==0)|| ...
        numel(unique(requested))~=numel(requested)||numel(requested)<2|| ...
        any(~ismember(requested,standard))
    error('nbiot:externalStage:ScenarioOptions', ...
        'Comparison methods must be at least two distinct supported methods.');
end
methods=standard(ismember(standard,requested));

if isfield(options,'config')
    cfg=options.config;
else
    cfg=nbiot.config.defaultConfig();
end
if ~isstruct(cfg)||~isscalar(cfg)||~isfield(cfg,'simulation')|| ...
        ~isstruct(cfg.simulation)||~isscalar(cfg.simulation)|| ...
        ~isfield(cfg.simulation,'durationTicks')
    error('nbiot:externalStage:ScenarioOptions', ...
        'The comparison simulation duration is missing.');
end
durationTicks=integerScalar(cfg.simulation.durationTicks, ...
    'durationTicks',1,2^24-1);

requiredMatrix={'method','numUE','durationTicks','burstDurationTicks', ...
    'realizationId','scenarioIdentity'};
if ~isstruct(matrix)||isempty(matrix)||~all(isfield(matrix,requiredMatrix))
    error('nbiot:externalStage:ScenarioIdentity', ...
        'Comparison scenario identity records are required.');
end

expectedKeys=strings(0,1);
for count=counts
    for burst=burstDurations
        for realizationId=realizationIds
            for method=methods
                expectedKeys(end+1,1)=rowKey(count,burst,durationTicks, ...
                    realizationId,method); %#ok<AGROW>
            end
        end
    end
end

actualKeys=strings(numel(matrix),1);
groupKeys=strings(numel(matrix),1);
identities=strings(numel(matrix),1);
methodValues=strings(numel(matrix),1);
canonicalMatrix=repmat(struct('method','','numUE',0,'durationTicks',0, ...
    'burstDurationTicks',0,'realizationId',0,'scenarioIdentity',''), ...
    1,numel(matrix));
for index=1:numel(matrix)
    methodValues(index)=string(matrix(index).method);
    identities(index)=string(matrix(index).scenarioIdentity);
    numUE=integerScalar(matrix(index).numUE,'numUE',1,65535);
    rowDuration=integerScalar(matrix(index).durationTicks, ...
        'durationTicks',1,2^24-1);
    burst=integerScalar(matrix(index).burstDurationTicks, ...
        'burstDurationTicks',1,2^24-1);
    realizationId=integerScalar(matrix(index).realizationId, ...
        'realizationId',0,4095);
    if ismissing(methodValues(index))||strlength(methodValues(index))==0|| ...
            ~ismember(methodValues(index),standard)|| ...
            ismissing(identities(index))||strlength(identities(index))==0
        error('nbiot:externalStage:ScenarioIdentity', ...
            'Every scenario row needs a supported method and a nonempty identity.');
    end
    actualKeys(index)=rowKey(numUE,burst,rowDuration,realizationId, ...
        methodValues(index));
    groupKeys(index)=rowKey(numUE,burst,rowDuration,realizationId,'');
    canonicalMatrix(index)=struct('method',char(methodValues(index)), ...
        'numUE',numUE,'durationTicks',rowDuration, ...
        'burstDurationTicks',burst,'realizationId',realizationId, ...
        'scenarioIdentity',char(identities(index)));
end

if numel(matrix)~=numel(expectedKeys)|| ...
        numel(unique(actualKeys))~=numel(actualKeys)|| ...
        ~isequal(sort(actualKeys),sort(expectedKeys))
    error('nbiot:externalStage:ScenarioOptions', ...
        'Scenario identity rows must exactly match the executed sweep options.');
end
for key=unique(groupKeys).'
    at=groupKeys==key;
    if numel(unique(identities(at)))~=1||numel(unique(methodValues(at)))<2
        error('nbiot:externalStage:ScenarioIdentity', ...
            'Compared methods must share one scenario identity for every case.');
    end
end

[~,order]=sort(actualKeys);
contract=struct();
contract.counts=counts;
contract.burstDurations=burstDurations;
contract.methods=cellstr(methods);
contract.realizationIds=realizationIds;
contract.durationTicks=durationTicks;
contract.scenarioMatrix=canonicalMatrix(order);
end

function values=integerVector(value,name,minimum,maximum)
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)
    error('nbiot:externalStage:ScenarioOptions', ...
        'Comparison option %s must be a nonempty integer vector.',name);
end
values=double(value(:).');
if any(~isfinite(values))||any(values~=fix(values))|| ...
        any(values<minimum)||any(values>maximum)|| ...
        numel(unique(values))~=numel(values)
    error('nbiot:externalStage:ScenarioOptions', ...
        'Comparison option %s contains unsupported integer values.',name);
end
end

function value=integerScalar(value,name,minimum,maximum)
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)|| ...
        value~=fix(value)||value<minimum||value>maximum
    error('nbiot:externalStage:ScenarioIdentity', ...
        'Scenario field %s must be an in-range integer.',name);
end
value=double(value);
end

function key=rowKey(numUE,burst,durationTicks,realizationId,method)
key=string(sprintf('%.0f|%.0f|%.0f|%.0f|%s', ...
    numUE,burst,durationTicks,realizationId,char(method)));
end
