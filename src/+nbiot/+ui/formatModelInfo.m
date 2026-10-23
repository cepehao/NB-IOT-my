function lines=formatModelInfo(bundle)
%FORMATMODELINFO Describe model metadata available to the GUI.
required={'modelName','schemaVersion','targetName','featureNames', ...
    'trainingIds','validationIds','testIds','seed','status','dataKind'};
if ~isstruct(bundle)||~isscalar(bundle)||~all(isfield(bundle,required))
    error('nbiot:ui:ModelInfo','The selected model is missing display metadata.');
end
features=cellstr(string(bundle.featureNames(:)));
if isempty(features)||any(strlength(string(features))==0)|| ...
        ~(isnumeric(bundle.trainingIds)&&isvector(bundle.trainingIds))|| ...
        ~(isnumeric(bundle.validationIds)&&isvector(bundle.validationIds))|| ...
        ~(isnumeric(bundle.testIds)&&isvector(bundle.testIds))
    error('nbiot:ui:ModelInfo','The selected model metadata is incomplete.');
end
target=char(string(bundle.targetName));
if strcmp(target,'meanRaUe')
    targetText='среднее число UE в RA за окно 500 мс';
else
    targetText=target;
end
splitCounts=[numel(bundle.trainingIds),numel(bundle.validationIds),numel(bundle.testIds)];
lines={['Тип модели: ' modelLabel(bundle.modelName)], ...
    sprintf('Цель: %s (%s)',targetText,target), ...
    sprintf('Схема: %s · статус: %s · данные: %s', ...
    char(string(bundle.schemaVersion)),char(string(bundle.status)), ...
    strrep(char(string(bundle.dataKind)),'-',' ')), ...
    sprintf('Признаки (%d): %s',numel(features),strjoin(features,', ')), ...
    sprintf('Разбиение: train/validation/test — %d/%d/%d ID · seed %d', ...
    splitCounts(1),splitCounts(2),splitCounts(3),double(bundle.seed))};
if isfield(bundle,'evaluationMetrics')&&istable(bundle.evaluationMetrics)&& ...
        all(ismember({'split','mae','rmse'},bundle.evaluationMetrics.Properties.VariableNames))&& ...
        height(bundle.evaluationMetrics)>0
    lines{end+1}=['Оценки: ' metricText(bundle.evaluationMetrics)];
else
    lines{end+1}='Оценки train/test: не приложены к этому пакету';
end
end

function label=modelLabel(name)
switch char(string(name))
    case 'linearRegression', label='Линейная регрессия';
    case 'decisionTree', label='Дерево решений';
    case 'randomForest', label='Случайный лес';
    case 'gradientBoosting', label='Градиентный бустинг';
    otherwise, label=char(string(name));
end
end

function text=metricText(metrics)
parts=cell(height(metrics),1);
for k=1:height(metrics)
    split=char(string(metrics.split(k)));
    parts{k}=sprintf('%s: MAE %.3g, RMSE %.3g',split,metrics.mae(k),metrics.rmse(k));
end
text=strjoin(parts,'; ');
end
