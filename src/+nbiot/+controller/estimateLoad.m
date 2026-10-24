function estimate=estimateLoad(estimator,observationRow,maximumLoad)
%ESTIMATELOAD Оценка нагрузки по признакам одного закрытого окна (ТЗ §21, §23).
%   ESTIMATE = nbiot.controller.estimateLoad(ESTIMATOR, OBSERVATIONROW, MAXIMUMLOAD)
%   OBSERVATIONROW — строка датасета (ключи окна + признаки BS); оценщику ESTIMATOR передаются только
%   признаки featureSchema().inputNames — ключи окна и истинная нагрузка не передаются (ТЗ §40).
%   ESTIMATE: value — оценка (среднее число UE в фазе RA), valid, featureWindowEndTick, reason:
%     'ok' | 'nonfinite-prediction' | 'prediction-outside-public-limits' (вне [0, MAXIMUMLOAD]).
%   Недопустимая оценка не применяется: контроллер оставляет текущую конфигурацию.
schema=nbiot.dataset.featureSchema();
if ~istable(observationRow)||height(observationRow)~=1|| ...
        ~all(ismember(schema.observationNames,observationRow.Properties.VariableNames))
    error('nbiot:controller:Observation','Supply exactly one dataset observation row.');
end
features=observationRow(:,schema.inputNames);
value=estimator(features);
if ~isnumeric(value)||~isscalar(value)
    error('nbiot:controller:Prediction','The estimator must return one numeric value.');
end
value=double(value);
estimate=struct('value',value,'valid',false, ...
    'featureWindowEndTick',double(observationRow.endTick),'reason','nonfinite-prediction');
if ~isfinite(value), return; end
if value<0||value>maximumLoad
    estimate.reason='prediction-outside-public-limits';
    return;
end
estimate.valid=true; estimate.reason='ok';
end
