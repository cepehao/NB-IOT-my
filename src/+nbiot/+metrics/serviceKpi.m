function [service,groups]=serviceKpi(ueSummary,actualTick,isComplete)
%SERVICEKPI Summarize service outage and KPIs by existing UE dimensions.
%   KPI обслуживания по UE и группам (indoor/outdoor, удалённость): доставка, outage (ТЗ §46.8, §46.13).
% Обязательные столбцы таблицы UE.
required={'indoor','coverageClass','created','delivered','dropped', ...
    'unfinished','raAttempts','raSuccesses','raFailures','raUnfinished'};
% Нужна таблица со всеми столбцами.
if ~istable(ueSummary)||~all(ismember(required,ueSummary.Properties.VariableNames))
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary must contain group, packet and random-access counters.');
end
% Горизонт — неотрицательный целый тик.
if ~(isnumeric(actualTick)&&isscalar(actualTick)&&isreal(actualTick)&& ...
        isfinite(actualTick)&&actualTick>=0&&actualTick==fix(actualTick))
    error('nbiot:metrics:ServiceKpiHorizon', ...
        'actualTick must be a nonnegative integer model tick.');
end
% Признак завершённого прогона — логический скаляр.
if ~(islogical(isComplete)&&isscalar(isComplete))
    error('nbiot:metrics:ServiceKpiCompletion', ...
        'isComplete must be a logical scalar.');
end

% Число UE.
n=height(ueSummary);
% Пакеты UE: созданы,
created=checkedCount(ueSummary.created,'created',n);
% доставлены,
delivered=checkedCount(ueSummary.delivered,'delivered',n);
% отброшены,
dropped=checkedCount(ueSummary.dropped,'dropped',n);
% не завершены.
unfinished=checkedCount(ueSummary.unfinished,'unfinished',n);
% Попытки RA UE: начаты,
raStarted=checkedCount(ueSummary.raAttempts,'raAttempts',n);
% успешны,
raSuccess=checkedCount(ueSummary.raSuccesses,'raSuccesses',n);
% неуспешны,
raFailure=checkedCount(ueSummary.raFailures,'raFailures',n);
% не завершены.
raUnfinished=checkedCount(ueSummary.raUnfinished,'raUnfinished',n);
% Баланс пакетов по каждому UE.
if any(created~=delivered+dropped+unfinished)
    error('nbiot:metrics:ServiceKpiBalance', ...
        'Per-UE packet counts must balance before computing service KPIs.');
end
% Баланс попыток по каждому UE.
if any(raStarted~=raSuccess+raFailure+raUnfinished)
    error('nbiot:metrics:ServiceKpiBalance', ...
        'Per-UE random-access counts must balance before computing service KPIs.');
end

% UE с потребностью — создали хотя бы один пакет.
demand=created>0;
% Outage — UE с потребностью, у которых не доставлен ни один пакет.
outage=demand & delivered==0;
% UE с незавершёнными пакетами.
unfinishedUe=unfinished>0;
% Число UE с потребностью.
demandUeCount=sum(demand);
% Число UE в outage.
outageUeCount=sum(outage);
% Вероятность outage — по умолчанию нет данных.
probability=NaN;
% Только для завершённого прогона —
if isComplete
    % outage / потребность.
    probability=safeRatio(outageUeCount,demandUeCount);
end
% Сводка обслуживания.
service=struct( ...
    'definition','service-outage-horizon-v1', ...
    'available',logical(isComplete), ...
    'actualTick',double(actualTick), ...
    'demandUeCount',double(demandUeCount), ...
    'outageUeCount',double(outageUeCount), ...
    'unfinishedUeCount',double(sum(unfinishedUe)), ...
    'probability',double(probability));

% Пустая таблица групп.
groups=emptyGroupTable();
% Метки indoor/outdoor по UE.
indoor=indoorLabels(ueSummary.indoor);
% Для каждой метки:
for label=["indoor","outdoor","unknown"]
    % строка группы.
    groups=appendGroup(groups,"indoor",label,indoor==label, ...
        created,delivered,dropped,unfinished,demand,outage, ...
        raStarted,raSuccess,raFailure,raUnfinished,isComplete);
end

% Метки coverage class по UE.
coverage=coverageLabels(ueSummary.coverageClass);
% Известные классы в порядке появления.
knownCoverage=unique(coverage(coverage~="unknown"),'stable');
% Плюс «unknown».
coverageValues=[knownCoverage(:); "unknown"];
% Для каждого класса:
for index=1:numel(coverageValues)
    % метка;
    label=coverageValues(index);
    % строка группы.
    groups=appendGroup(groups,"coverageClass",label,coverage==label, ...
        created,delivered,dropped,unfinished,demand,outage, ...
        raStarted,raSuccess,raFailure,raUnfinished,isComplete);
end
end

%CHECKEDCOUNT Столбец счётчиков: N неотрицательных целых.
function values=checkedCount(input,name,n)
% Числовой вектор длины N.
if ~(isnumeric(input)&&isreal(input)&&isvector(input)&&numel(input)==n)
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary.%s must be a numeric count per UE.',name);
end
% Столбцом double.
values=double(input(:));
% Конечные неотрицательные целые.
if any(~isfinite(values)|values<0|values~=fix(values))
    error('nbiot:metrics:ServiceKpiInput', ...
        'ueSummary.%s must contain nonnegative integer counts.',name);
end
end

%INDOORLABELS Признак indoor → метки indoor / outdoor / unknown.
function labels=indoorLabels(values)
% Логический признак:
if islogical(values)
    % по умолчанию unknown;
    labels=repmat("unknown",numel(values),1);
    % true → indoor;
    labels(values(:))="indoor";
    % false → outdoor.
    labels(~values(:))="outdoor";
% Числовой 0/1:
elseif isnumeric(values)
    % столбцом double;
    values=double(values(:));
    % по умолчанию unknown;
    labels=repmat("unknown",numel(values),1);
    % 1 → indoor;
    labels(values==1)="indoor";
    % 0 → outdoor.
    labels(values==0)="outdoor";
else
    % Текст: нормализуем;
    values=lower(strtrim(string(values(:))));
    % по умолчанию unknown;
    labels=repmat("unknown",numel(values),1);
    % 'indoor' → indoor;
    labels(values=="indoor")="indoor";
    % 'outdoor' → outdoor.
    labels(values=="outdoor")="outdoor";
end
end

%COVERAGELABELS Coverage class → текстовые метки (пустое → unknown).
function labels=coverageLabels(values)
% Текст без пробелов по краям.
labels=strtrim(string(values(:)));
% Пустые и отсутствующие значения.
missing=ismissing(labels)|strlength(labels)==0;
% заменяем на unknown.
labels(missing)="unknown";
end

%EMPTYGROUPTABLE Пустая таблица KPI групп с нужными столбцами.
function groups=emptyGroupTable()
% Столбцы: измерение, значение, число UE, пакеты, доставка, outage, попытки RA.
groups=table(strings(0,1),strings(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'groupDimension','groupValue','ueCount', ...
    'demandUeCount','outageUeCount','created','delivered','dropped', ...
    'unfinished','packetDeliveryProbability','serviceOutageProbability', ...
    'raStarted','raSuccess','raFailure','raUnfinished'});
end

%APPENDGROUP Добавляет строку KPI для группы UE по маске MASK.
function groups=appendGroup(groups,dimension,value,mask,created,delivered, ...
    dropped,unfinished,demand,outage,raStarted,raSuccess,raFailure, ...
    raUnfinished,isComplete)
% Создано пакетов в группе.
createdCount=sum(created(mask));
% Доставлено.
deliveredCount=sum(delivered(mask));
% UE с потребностью.
demandCount=sum(demand(mask));
% UE в outage.
outageCount=sum(outage(mask));
% Вероятность outage — по умолчанию нет данных.
serviceProbability=NaN;
% Для завершённого прогона —
if isComplete
    % outage / потребность.
    serviceProbability=safeRatio(outageCount,demandCount);
end
% Строка группы.
row=table(string(dimension),string(value),double(sum(mask)), ...
    double(demandCount),double(outageCount),double(createdCount), ...
    double(deliveredCount),double(sum(dropped(mask))), ...
    double(sum(unfinished(mask))),safeRatio(deliveredCount,createdCount), ...
    serviceProbability,double(sum(raStarted(mask))), ...
    double(sum(raSuccess(mask))),double(sum(raFailure(mask))), ...
    double(sum(raUnfinished(mask))), ...
    'VariableNames',groups.Properties.VariableNames);
% Добавляем к таблице.
groups=[groups;row];
end

%SAFERATIO Отношение; при нулевом знаменателе — NaN.
function value=safeRatio(numerator,denominator)
% По умолчанию — NaN.
value=NaN;
% Если знаменатель положителен —
if denominator>0
    % отношение.
    value=double(numerator)/double(denominator);
end
end
