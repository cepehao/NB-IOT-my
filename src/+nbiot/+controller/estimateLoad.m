function estimate=estimateLoad(estimator,observationRow,maximumLoad)
%ESTIMATELOAD Оценка нагрузки по признакам одного закрытого окна (ТЗ §21, §23).
%   ESTIMATE = nbiot.controller.estimateLoad(ESTIMATOR, OBSERVATIONROW, MAXIMUMLOAD)
%   OBSERVATIONROW — строка датасета (ключи окна + признаки BS); оценщику ESTIMATOR передаются только
%   признаки featureSchema().inputNames — ключи окна и истинная нагрузка не передаются (ТЗ §40).
%   ESTIMATE: value — оценка (среднее число UE в фазе RA), valid, featureWindowEndTick, reason:
%     'ok' | 'nonfinite-prediction' | 'prediction-outside-public-limits' (вне [0, MAXIMUMLOAD]).
%   Недопустимая оценка не применяется: контроллер оставляет текущую конфигурацию.
% Схема датасета: ключи окна, признаки BS, имена признаков модели.
schema=nbiot.dataset.featureSchema();
% Нужна ровно одна строка таблицы со всеми столбцами наблюдений.
if ~istable(observationRow)||height(observationRow)~=1|| ...
        ~all(ismember(schema.observationNames,observationRow.Properties.VariableNames))
    error('nbiot:controller:Observation','Supply exactly one dataset observation row.');
end
% Оценщику передаются только признаки модели (inputNames), без ключей окна и без target.
features=observationRow(:,schema.inputNames);
% Вызов оценщика (например, обученной модели).
value=estimator(features);
% Оценка должна быть одним числом —
if ~isnumeric(value)||~isscalar(value)
    error('nbiot:controller:Prediction','The estimator must return one numeric value.');
end
% приводим к double.
value=double(value);
% Заготовка результата: значение, «недопустима», окно, к которому относится оценка.
estimate=struct('value',value,'valid',false, ...
    'featureWindowEndTick',double(observationRow.endTick),'reason','nonfinite-prediction');
% NaN или Inf — оценка недопустима (reason nonfinite-prediction).
if ~isfinite(value), return; end
% Оценка вне [0, maximumLoad] —
if value<0||value>maximumLoad
    % недопустима (prediction-outside-public-limits).
    estimate.reason='prediction-outside-public-limits';
    return;
end
% Иначе оценка допустима.
estimate.valid=true; estimate.reason='ok';
end
