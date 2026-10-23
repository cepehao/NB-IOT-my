function metrics=comparisonKpis(kpiSummary,method)
%COMPARISONKPIS Return the stable per-run KPI columns used by comparisons.
if nargin<1||isempty(kpiSummary), kpiSummary=struct(); end
if nargin<2, method='Static'; end
if ~isstruct(kpiSummary)||~isscalar(kpiSummary)
    error('nbiot:experiments:ComparisonKpi','KPI summary must be a scalar structure.');
end
method=char(string(method));
names={...
    'created','delivered','dropped','unfinished',...
    'raStarted','raSuccess','raFailed','raUnfinished','collidingAttempts',...
    'raSuccessProbability','raSuccessCompletedProbability','meanRaAttempts',...
    'deliveryProbability','deliveryCompletedProbability','dropProbability',...
    'collisionAttemptProbability','throughputBitsPerSecond',...
    'meanDelayTicks','p95DelayTicks',...
    'msg3Bler','msg3Decoded','msg3CrcFailures',...
    'dataBler','dataDecoded','dataCrcFailures',...
    'ulOccupancy','dlOccupancy','nprachOccupancy',...
    'meanBsQueueLength','maxBsQueueLength','meanUeQueueLength','maxUeQueueLength',...
    'harqBlocksStarted','harqBlocksFailed','harqBlocksCensored',...
    'harqAttemptsStarted','harqRetryAttempts','harqRetryTransmissions',...
    'harqFirstTransmissionBler','harqAllAttemptBler',...
    'controllerDecisionCount','controllerSwitches'};
metrics=struct();
for k=1:numel(names), metrics.(names{k})=NaN; end

directNames=names(1:32);
for k=1:numel(directNames)
    name=directNames{k};
    if isfield(kpiSummary,name), metrics.(name)=numericScalar(kpiSummary.(name)); end
end

harq=struct();
if isfield(kpiSummary,'harq')&&isstruct(kpiSummary.harq)&&isscalar(kpiSummary.harq)
    harq=kpiSummary.harq;
end
nestedNames={...
    'blocksStarted','harqBlocksStarted';...
    'blocksFailed','harqBlocksFailed';...
    'blocksCensored','harqBlocksCensored';...
    'attemptsStarted','harqAttemptsStarted';...
    'retryAttempts','harqRetryAttempts';...
    'retryTransmissions','harqRetryTransmissions';...
    'firstTransmissionBler','harqFirstTransmissionBler';...
    'allAttemptBler','harqAllAttemptBler'};
for k=1:size(nestedNames,1)
    source=nestedNames{k,1}; target=nestedNames{k,2};
    if isfield(harq,source), metrics.(target)=numericScalar(harq.(source)); end
end

if strcmp(method,'Static'), return; end
controller=struct();
if isfield(kpiSummary,'controller')&&isstruct(kpiSummary.controller)&& ...
        isscalar(kpiSummary.controller)
    controller=kpiSummary.controller;
end
if isfield(controller,'applicable')&&~logicalScalar(controller.applicable), return; end
if isfield(controller,'decisionCount')
    metrics.controllerDecisionCount=numericScalar(controller.decisionCount);
elseif isfield(controller,'decisions')
    metrics.controllerDecisionCount=numericScalar(controller.decisions);
end
if isfield(controller,'configurationSwitches')
    metrics.controllerSwitches=numericScalar(controller.configurationSwitches);
end
end

function value=numericScalar(input)
value=NaN;
if isnumeric(input)&&isscalar(input)&&isreal(input)&&isfinite(input)
    value=double(input);
end
end

function yes=logicalScalar(input)
yes=false;
if (islogical(input)||isnumeric(input))&&isscalar(input)&&isreal(input)&& ...
        isfinite(input)&&ismember(input,[0 1])
    yes=logical(input);
end
end
