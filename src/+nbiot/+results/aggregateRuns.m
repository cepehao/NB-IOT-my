function summary=aggregateRuns(results)
%AGGREGATERUNS Uncertainty across independent runs, not correlated windows.
%   Агрегация KPI по независимым реализациям: среднее и доверительный интервал (ТЗ §29).
if ~iscell(results), results=num2cell(results); end
names={'raSuccessProbability','deliveryProbability','throughputBitsPerSecond','meanDelayTicks','dataBler','ulOccupancy','dlOccupancy'};
rows={}; successes=0; attempts=0; delivered=0; created=0;
for k=1:numel(results)
    if ~strcmp(results{k}.status,'completed'), error('nbiot:experiments:Incomplete','Exclude/report failed and partial runs before aggregation.'); end
    a=results{k}.kpiSummary; successes=successes+a.raSuccess; attempts=attempts+a.raStarted;
    delivered=delivered+a.delivered; created=created+a.created;
end
for f=1:numel(names)
    x=cellfun(@(r)r.kpiSummary.(names{f}),results); x=x(isfinite(x)); n=numel(x);
    if n==0, mu=NaN; se=NaN; lo=NaN; hi=NaN;
    elseif n==1, mu=x; se=NaN; lo=NaN; hi=NaN;
    else
        mu=mean(x); se=std(x,0)/sqrt(n);
        % Two-sided Student t(.975,df) via base MATLAB inverse beta.
        df=n-1; q=betaincinv(.05,df/2,.5); critical=sqrt(df*(1/q-1));
        lo=mu-critical*se; hi=mu+critical*se;
    end
    rows(end+1,:)={names{f},n,mu,se,lo,hi}; %#ok<AGROW>
end
summary=struct('perRun',cell2table(rows,'VariableNames',{'metric','runCount','mean','standardError','ci95Low','ci95High'}), ...
    'raSuccessNumerator',successes,'raStartedDenominator',attempts,'deliveredNumerator',delivered,'createdDenominator',created);
summary.pooledRaSuccess=divide(successes,attempts); summary.pooledDelivery=divide(delivered,created);
end
function value=divide(a,b), if b==0, value=NaN; else, value=a/b; end, end
