function [service,groups]=serviceKpi(ueSummary,actualTick,isComplete)
%SERVICEKPI Summarize service outage and KPIs by existing UE dimensions.
%   KPI обслуживания по UE и группам (indoor/outdoor, удалённость): доставка, outage (ТЗ §46.8, §46.13).
required={'indoor','coverageClass','created','delivered','dropped', ...
    'unfinished','raAttempts','raSuccesses','raFailures','raUnfinished'};
if ~istable(ueSummary)||~all(ismember(required,ueSummary.Properties.VariableNames))
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary must contain group, packet and random-access counters.');
end
if ~(isnumeric(actualTick)&&isscalar(actualTick)&&isreal(actualTick)&& ...
        isfinite(actualTick)&&actualTick>=0&&actualTick==fix(actualTick))
    error('nbiot:metrics:ServiceKpiHorizon', ...
        'actualTick must be a nonnegative integer model tick.');
end
if ~(islogical(isComplete)&&isscalar(isComplete))
    error('nbiot:metrics:ServiceKpiCompletion', ...
        'isComplete must be a logical scalar.');
end

n=height(ueSummary);
created=checkedCount(ueSummary.created,'created',n);
delivered=checkedCount(ueSummary.delivered,'delivered',n);
dropped=checkedCount(ueSummary.dropped,'dropped',n);
unfinished=checkedCount(ueSummary.unfinished,'unfinished',n);
raStarted=checkedCount(ueSummary.raAttempts,'raAttempts',n);
raSuccess=checkedCount(ueSummary.raSuccesses,'raSuccesses',n);
raFailure=checkedCount(ueSummary.raFailures,'raFailures',n);
raUnfinished=checkedCount(ueSummary.raUnfinished,'raUnfinished',n);
if any(created~=delivered+dropped+unfinished)
    error('nbiot:metrics:ServiceKpiBalance', ...
        'Per-UE packet counts must balance before computing service KPIs.');
end
if any(raStarted~=raSuccess+raFailure+raUnfinished)
    error('nbiot:metrics:ServiceKpiBalance', ...
        'Per-UE random-access counts must balance before computing service KPIs.');
end

demand=created>0;
outage=demand & delivered==0;
unfinishedUe=unfinished>0;
demandUeCount=sum(demand);
outageUeCount=sum(outage);
probability=NaN;
if isComplete
    probability=safeRatio(outageUeCount,demandUeCount);
end
service=struct( ...
    'definition','service-outage-horizon-v1', ...
    'available',logical(isComplete), ...
    'actualTick',double(actualTick), ...
    'demandUeCount',double(demandUeCount), ...
    'outageUeCount',double(outageUeCount), ...
    'unfinishedUeCount',double(sum(unfinishedUe)), ...
    'probability',double(probability));

groups=emptyGroupTable();
indoor=indoorLabels(ueSummary.indoor);
for label=["indoor","outdoor","unknown"]
    groups=appendGroup(groups,"indoor",label,indoor==label, ...
        created,delivered,dropped,unfinished,demand,outage, ...
        raStarted,raSuccess,raFailure,raUnfinished,isComplete);
end

coverage=coverageLabels(ueSummary.coverageClass);
knownCoverage=unique(coverage(coverage~="unknown"),'stable');
coverageValues=[knownCoverage(:); "unknown"];
for index=1:numel(coverageValues)
    label=coverageValues(index);
    groups=appendGroup(groups,"coverageClass",label,coverage==label, ...
        created,delivered,dropped,unfinished,demand,outage, ...
        raStarted,raSuccess,raFailure,raUnfinished,isComplete);
end
end

function values=checkedCount(input,name,n)
if ~(isnumeric(input)&&isreal(input)&&isvector(input)&&numel(input)==n)
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary.%s must be a numeric count per UE.',name);
end
values=double(input(:));
if any(~isfinite(values)|values<0|values~=fix(values))
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary.%s must contain nonnegative integer counts.',name);
end
end

function labels=indoorLabels(values)
if islogical(values)
    labels=repmat("unknown",numel(values),1);
    labels(values(:))="indoor";
    labels(~values(:))="outdoor";
elseif isnumeric(values)
    values=double(values(:));
    labels=repmat("unknown",numel(values),1);
    labels(values==1)="indoor";
    labels(values==0)="outdoor";
else
    values=lower(strtrim(string(values(:))));
    labels=repmat("unknown",numel(values),1);
    labels(values=="indoor")="indoor";
    labels(values=="outdoor")="outdoor";
end
end

function labels=coverageLabels(values)
labels=strtrim(string(values(:)));
missing=ismissing(labels)|strlength(labels)==0;
labels(missing)="unknown";
end

function groups=emptyGroupTable()
groups=table(strings(0,1),strings(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'groupDimension','groupValue','ueCount', ...
    'demandUeCount','outageUeCount','created','delivered','dropped', ...
    'unfinished','packetDeliveryProbability','serviceOutageProbability', ...
    'raStarted','raSuccess','raFailure','raUnfinished'});
end

function groups=appendGroup(groups,dimension,value,mask,created,delivered, ...
    dropped,unfinished,demand,outage,raStarted,raSuccess,raFailure, ...
    raUnfinished,isComplete)
createdCount=sum(created(mask));
deliveredCount=sum(delivered(mask));
demandCount=sum(demand(mask));
outageCount=sum(outage(mask));
serviceProbability=NaN;
if isComplete
    serviceProbability=safeRatio(outageCount,demandCount);
end
row=table(string(dimension),string(value),double(sum(mask)), ...
    double(demandCount),double(outageCount),double(createdCount), ...
    double(deliveredCount),double(sum(dropped(mask))), ...
    double(sum(unfinished(mask))),safeRatio(deliveredCount,createdCount), ...
    serviceProbability,double(sum(raStarted(mask))), ...
    double(sum(raSuccess(mask))),double(sum(raFailure(mask))), ...
    double(sum(raUnfinished(mask))), ...
    'VariableNames',groups.Properties.VariableNames);
groups=[groups;row];
end

function value=safeRatio(numerator,denominator)
value=NaN;
if denominator>0
    value=double(numerator)/double(denominator);
end
end
