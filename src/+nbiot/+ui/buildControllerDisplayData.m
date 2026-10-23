function view=buildControllerDisplayData(state)
%BUILDCONTROLLERDISPLAYDATA Format controller values for display only.
required={'controllerMethod','controllerLatestEstimate','runtimeAction', ...
    'controllerLog','controllerDiagnosticTargets','tickSeconds'};
if ~isstruct(state)||~isscalar(state)||~all(isfield(state,required))|| ...
        ~isstruct(state.controllerLatestEstimate)||~isscalar(state.controllerLatestEstimate)|| ...
        ~isstruct(state.runtimeAction)||~isscalar(state.runtimeAction)|| ...
        ~istable(state.controllerDiagnosticTargets)
    error('nbiot:ui:ControllerDisplay','Controller display input does not match the session snapshot.');
end
estimateFields={'valid','value','featureWindowEndTick','reason'};
actionFields={'accessProbability','raShare'};
targetFields={'endTick','meanRaUe'};
if ~all(isfield(state.controllerLatestEstimate,estimateFields))|| ...
        ~all(isfield(state.runtimeAction,actionFields))|| ...
        ~all(ismember(targetFields,state.controllerDiagnosticTargets.Properties.VariableNames))|| ...
        ~isnumeric(state.tickSeconds)||~isscalar(state.tickSeconds)|| ...
        ~isfinite(state.tickSeconds)||state.tickSeconds<=0
    error('nbiot:ui:ControllerDisplay','Controller display input has invalid fields.');
end

method=char(string(state.controllerMethod));
accessProbability=double(state.runtimeAction.accessProbability);
raShare=double(state.runtimeAction.raShare);
if ~isscalar(accessProbability)||~isfinite(accessProbability)||accessProbability<0||accessProbability>1|| ...
        ~isscalar(raShare)||~isfinite(raShare)||raShare<=0||raShare>=1
    error('nbiot:ui:ControllerDisplay','Current controller settings are outside supported limits.');
end
actionText=sprintf('P = %.2f · RA/DT = %d/%d',accessProbability, ...
    round(100*raShare),round(100*(1-raShare)));
if strcmp(method,'Static')
    summary=['Static · ' actionText ' · прогноз не используется'];
else
    estimate=state.controllerLatestEstimate;
    forecast=NaN; actual=NaN;
    if islogical(estimate.valid)&&isscalar(estimate.valid)&&estimate.valid&& ...
            isnumeric(estimate.value)&&isscalar(estimate.value)&&isfinite(estimate.value)
        forecast=double(estimate.value);
        actual=actualForWindow(state.controllerDiagnosticTargets,estimate.featureWindowEndTick);
    end
    if isfinite(forecast)&&isfinite(actual)
        summary=sprintf('%s · Прогноз: %.2f UE · Факт: %.2f UE · Ошибка: %+.2f UE · %s', ...
            method,forecast,actual,forecast-actual,actionText);
    elseif isfinite(forecast)
        summary=sprintf('%s · Прогноз: %.2f UE · Факт пока не рассчитан · %s', ...
            method,forecast,actionText);
    else
        summary=sprintf('%s · Прогноз пока недоступен · %s',method,actionText);
    end
end

view.summary=summary;
view.history=emptyHistory();
view.historyDisplay=cell(0,8);
log=state.controllerLog;
if isempty(log), return; end
logFields={'decisionTick','featureWindowEndTick','estimateValue','estimateValid', ...
    'appliedAccessProbability','appliedRaShare','applied','switched','reason'};
if ~isstruct(log)||~all(isfield(log,logFields))
    error('nbiot:ui:ControllerDisplay','Controller decision history does not match the supported schema.');
end
count=numel(log);
decisionTimeSeconds=NaN(count,1);
forecastMeanRaUe=NaN(count,1);
actualLoadMeanRaUe=NaN(count,1);
forecastErrorMeanRaUe=NaN(count,1);
accessProbability=NaN(count,1);
raShareHistory=NaN(count,1);
raDtShare=strings(count,1);
applied=false(count,1);
reason=strings(count,1);
for k=1:count
    record=log(k);
    decisionTimeSeconds(k)=double(record.decisionTick)*double(state.tickSeconds);
    accessProbability(k)=double(record.appliedAccessProbability);
    raShare=double(record.appliedRaShare);
    raShareHistory(k)=raShare;
    raDtShare(k)=sprintf('%d/%d',round(100*raShare),round(100*(1-raShare)));
    applied(k)=logical(record.applied);
    reason(k)=reasonText(char(string(record.reason)),logical(record.applied),logical(record.switched));
    if islogical(record.estimateValid)&&isscalar(record.estimateValid)&&record.estimateValid&& ...
            isnumeric(record.estimateValue)&&isscalar(record.estimateValue)&&isfinite(record.estimateValue)
        forecastMeanRaUe(k)=double(record.estimateValue);
        actualLoadMeanRaUe(k)=actualForWindow( ...
            state.controllerDiagnosticTargets,record.featureWindowEndTick);
        if isfinite(actualLoadMeanRaUe(k))
            forecastErrorMeanRaUe(k)=forecastMeanRaUe(k)-actualLoadMeanRaUe(k);
        end
    end
end
view.history=table(decisionTimeSeconds,forecastMeanRaUe,actualLoadMeanRaUe, ...
    forecastErrorMeanRaUe,accessProbability,raShareHistory,raDtShare,applied,reason, ...
    'VariableNames',{'decisionTimeSeconds','forecastMeanRaUe','actualLoadMeanRaUe', ...
    'forecastErrorMeanRaUe','accessProbability','raShare','raDtShare','applied','reason'});
view.historyDisplay=cell(count,8);
for k=1:count
    if applied(k), appliedText='Да'; else, appliedText='Нет'; end
    view.historyDisplay(k,:)={formatNumber(decisionTimeSeconds(k),'%.3f'), ...
        formatNumber(forecastMeanRaUe(k),'%.2f'), ...
        formatNumber(actualLoadMeanRaUe(k),'%.2f'), ...
        formatNumber(forecastErrorMeanRaUe(k),'%+.2f'), ...
        formatNumber(accessProbability(k),'%.2f'),char(raDtShare(k)), ...
        appliedText,char(reason(k))};
end
end

function value=actualForWindow(targets,endTick)
value=NaN;
if ~isnumeric(endTick)||~isscalar(endTick)||~isfinite(endTick), return; end
match=find(double(targets.endTick)==double(endTick),1,'last');
if ~isempty(match)
    actual=targets.meanRaUe(match);
    if isnumeric(actual)&&isscalar(actual)&&isfinite(actual), value=double(actual); end
end
end

function history=emptyHistory()
history=table(zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),strings(0,1),false(0,1),strings(0,1), ...
    'VariableNames',{'decisionTimeSeconds','forecastMeanRaUe','actualLoadMeanRaUe', ...
    'forecastErrorMeanRaUe','accessProbability','raShare','raDtShare','applied','reason'});
end

function text=formatNumber(value,formatSpec)
if isnumeric(value)&&isscalar(value)&&isfinite(value)
    text=sprintf(formatSpec,value);
else
    text='—';
end
end

function text=reasonText(reason,applied,switched)
if applied
    if switched, text='настройка изменена'; else, text='настройка применена'; end
    return;
end
switch reason
    case 'no-prior-window', text='ожидает первое закрытое окно';
    case 'invalid-estimate', text='прогноз недоступен';
    case 'prediction-error', text='ошибка прогноза';
    case 'resource-budget-conflict', text='нельзя изменить долю ресурсов';
    case 'after-horizon', text='расчёт завершён';
    case 'not-decision-boundary', text='ожидает следующее окно';
    case 'stale-window', text='данные окна устарели';
    case 'wrong-effective-tick', text='неверный момент изменения';
    otherwise, text=reason;
end
end
