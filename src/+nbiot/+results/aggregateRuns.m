function summary=aggregateRuns(results)
%AGGREGATERUNS Uncertainty across independent runs, not correlated windows.
%   Агрегация KPI по независимым реализациям: среднее и доверительный интервал (ТЗ §29).
% Массив struct → cell для единообразия.
if ~iscell(results), results=num2cell(results); end
% Агрегируемые KPI.
names={'raSuccessProbability','deliveryProbability','throughputBitsPerSecond','meanDelayTicks','dataBler','ulOccupancy','dlOccupancy'};
% Строки таблицы и суммы для объединённых (pooled) оценок.
rows={}; successes=0; attempts=0; delivered=0; created=0;
% Для каждого прогона:
for k=1:numel(results)
    % агрегируются только завершённые прогоны;
    if ~strcmp(results{k}.status,'completed'), error('nbiot:experiments:Incomplete','Exclude/report failed and partial runs before aggregation.'); end
    % KPI прогона; суммы успешных и начатых попыток RA;
    a=results{k}.kpiSummary; successes=successes+a.raSuccess; attempts=attempts+a.raStarted;
    % суммы доставленных и созданных пакетов.
    delivered=delivered+a.delivered; created=created+a.created;
end
% Для каждого KPI:
for f=1:numel(names)
    % значения по прогонам (только конечные) и их число;
    x=cellfun(@(r)r.kpiSummary.(names{f}),results); x=x(isfinite(x)); n=numel(x);
    % нет значений — всё NaN;
    if n==0, mu=NaN; se=NaN; lo=NaN; hi=NaN;
    % одно — среднее без интервала;
    elseif n==1, mu=x; se=NaN; lo=NaN; hi=NaN;
    else
        % иначе среднее и стандартная ошибка;
        mu=mean(x); se=std(x,0)/sqrt(n);
        % Two-sided Student t(.975,df) via base MATLAB inverse beta.
        df=n-1; q=betaincinv(.05,df/2,.5); critical=sqrt(df*(1/q-1));
        % 95 % доверительный интервал.
        lo=mu-critical*se; hi=mu+critical*se;
    end
    % строка таблицы.
    rows(end+1,:)={names{f},n,mu,se,lo,hi}; %#ok<AGROW>
end
% Таблица по прогонам и суммы числителей/знаменателей.
summary=struct('perRun',cell2table(rows,'VariableNames',{'metric','runCount','mean','standardError','ci95Low','ci95High'}), ...
    'raSuccessNumerator',successes,'raStartedDenominator',attempts,'deliveredNumerator',delivered,'createdDenominator',created);
% Объединённые вероятности успешного доступа и доставки.
summary.pooledRaSuccess=divide(successes,attempts); summary.pooledDelivery=divide(delivered,created);
end
%DIVIDE Деление; при нулевом знаменателе — NaN.
function value=divide(a,b), if b==0, value=NaN; else, value=a/b; end, end
