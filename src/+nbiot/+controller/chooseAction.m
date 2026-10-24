function action=chooseAction(method,estimate,bsState,currentAction,policyConfig)
%CHOOSEACTION Решение контроллера по оценке нагрузки (ТЗ §23–25): выбор из допустимого множества.
%   ACTION = chooseAction(METHOD, ESTIMATE, BSSTATE, CURRENTACTION, POLICY)
%   METHOD: 'Static' (ничего не меняет) | 'Adaptive-P' | 'Adaptive-RA/DT'.
%   ESTIMATE — ML-оценка нагрузки (meanRaUe — среднее число UE в фазе RA) по закрытому окну,
%   которое должно заканчиваться ровно на текущем тике (иначе 'stale-window').
%   Правило: уровень = первый, у которого оценка <= порога (пороги возрастают):
%     Adaptive-P     — меньше P при росте нагрузки (ТЗ §24), доля RA остаётся 10 %;
%     Adaptive-RA/DT — больше доля RA при росте нагрузки (ТЗ §25), P = 1.
%   ACTION.reason: 'load-threshold' — предложено изменение; иначе причина, почему действия нет
%   (static, no-prior-window, not-decision-boundary, invalid-estimate, stale-window, after-horizon).
% Политика по умолчанию — пробные пороги configs/adaptiveDefaults.
if nargin<5||isempty(policyConfig), policyConfig=adaptiveDefaults(); end
% Имя метода как строка char.
method=char(string(method));
% Допустимые методы управления (ТЗ §23–26).
allowed={'Static','Adaptive-P','Adaptive-RA/DT'};
% Неизвестный метод —
if ~any(strcmp(method,allowed))
    error('nbiot:controller:Method','Unknown control method.');
end
% Проверка политики: поля, пределы, упорядоченность порогов и уровней.
validatePolicy(policyConfig);
% Проверка текущего действия: P в [0,1], доля RA в (0,1).
validateAction(currentAction);
% Состояние BS: текущий тик и горизонт — неотрицательные целые, горизонт >= 1.
if ~isstruct(bsState)||~isscalar(bsState)||~all(isfield(bsState,{'tick','durationTicks'}))|| ...
        ~validTick(bsState.tick)||~validTick(bsState.durationTicks)||bsState.durationTicks<1
    error('nbiot:controller:State','BS state needs nonnegative integer tick and positive durationTicks.');
end
% Заготовка решения: по умолчанию сохранить текущие P и долю RA, действовать с текущего тика.
action=struct('accessProbability',currentAction.accessProbability, ...
    'raShare',currentAction.raShare,'effectiveTick',double(bsState.tick), ...
    'decisionTick',double(bsState.tick),'estimateValue',NaN,'reason','unchanged');
% Static ничего не меняет.
if strcmp(method,'Static'), action.reason='static'; return; end
% На тике 0 закрытого окна наблюдений ещё нет —
if bsState.tick==0
    % решения нет (no-prior-window).
    action.effectiveTick=0; action.reason='no-prior-window'; return;
end
% На горизонте и после него решения не принимаются.
if bsState.tick>=bsState.durationTicks
    action.effectiveTick=bsState.durationTicks; action.reason='after-horizon'; return;
end
% Решения — только на границах окна (кратно 500 мс).
if mod(bsState.tick,policyConfig.windowTicks)~=0
    action.reason='not-decision-boundary'; return;
end
% Оценка должна быть struct с полями valid, value, featureWindowEndTick —
if ~isstruct(estimate)||~isscalar(estimate)|| ...
        ~all(isfield(estimate,{'valid','value','featureWindowEndTick'}))
    action.reason='invalid-estimate'; return;
end
% и допустимой: valid = true, конечное число в [0, maximumLoad];
if ~isequal(estimate.valid,true)||~isnumeric(estimate.value)||~isscalar(estimate.value)|| ...
        ~isfinite(estimate.value)||estimate.value<0||estimate.value>policyConfig.maximumLoad
    action.reason='invalid-estimate'; return;
end
% оценка должна относиться к окну, закончившемуся ровно сейчас (иначе устарела).
if ~validTick(estimate.featureWindowEndTick)||estimate.featureWindowEndTick~=bsState.tick
    action.reason='stale-window'; return;
end
% Оценка нагрузки (среднее число UE в фазе RA).
loadEstimate=double(estimate.value);
% Сохраняем её в решении для журнала.
action.estimateValue=loadEstimate;
% Adaptive-P (ТЗ §24):
if strcmp(method,'Adaptive-P')
    % P выбирается по порогам нагрузки (больше нагрузка — меньше P);
    action.accessProbability=selectLevel(loadEstimate, ...
        policyConfig.accessLoadThresholds,policyConfig.accessProbabilityLevels);
    % доля RA остаётся базовой (10 %).
    action.raShare=policyConfig.staticRaShare;
else
    % Adaptive-RA/DT (ТЗ §25): P = 1,
    action.accessProbability=policyConfig.staticAccessProbability;
    % а доля RA выбирается по порогам (больше нагрузка — больше доля RA: 10/20/30 %).
    action.raShare=selectLevel(loadEstimate, ...
        policyConfig.raLoadThresholds,policyConfig.raShareLevels);
end
% Действие с текущего тика (граница окна).
action.effectiveTick=double(bsState.tick);
% Причина: изменение по порогам нагрузки — симулятор применит его.
action.reason='load-threshold';
end

%SELECTLEVEL Уровень действия для оценки нагрузки по возрастающим порогам.
% Выбор уровня по оценке нагрузки:
function value=selectLevel(loadEstimate,thresholds,levels)
% первый порог, который не меньше оценки;
index=find(loadEstimate<=thresholds,1,'first');
% если оценка больше всех порогов — последний уровень;
if isempty(index), index=numel(levels); end
% значение действия этого уровня.
value=levels(index);
end

%VALIDATEACTION Текущее действие: P в [0,1], доля RA в (0,1).
% Проверка текущего действия:
function validateAction(action)
% это одна struct с полями accessProbability и raShare;
if ~isstruct(action)||~isscalar(action)|| ...
        ~all(isfield(action,{'accessProbability','raShare'}))
    error('nbiot:controller:Action','Current action needs accessProbability and raShare.');
end
% значения P и доли RA;
p=action.accessProbability; share=action.raShare;
% P в [0, 1], доля RA строго внутри (0, 1).
if ~isnumeric(p)||~isscalar(p)||~isfinite(p)||p<0||p>1|| ...
        ~isnumeric(share)||~isscalar(share)||~isfinite(share)||share<=0||share>=1
    error('nbiot:controller:Action','Current action is outside supported limits.');
end
end

%VALIDATEPOLICY Полнота и корректность политики (окно, базовые значения, пороги, уровни, максимум).
% Проверка политики:
function validatePolicy(policy)
% обязательные поля политики;
required={'windowTicks','staticAccessProbability','staticRaShare', ...
    'accessLoadThresholds','accessProbabilityLevels','raLoadThresholds', ...
    'raShareLevels','maximumLoad'};
% все поля присутствуют;
if ~isstruct(policy)||~isscalar(policy)||~all(isfield(policy,required))
    error('nbiot:controller:Policy','Adaptive policy is missing required fields.');
end
% окно — целое >= 1; базовые P в [0,1] и доля RA в (0,1); maximumLoad — конечное >= 0;
if ~validTick(policy.windowTicks)||policy.windowTicks<1|| ...
        ~isfinite(policy.staticAccessProbability)||policy.staticAccessProbability<0|| ...
        policy.staticAccessProbability>1||~isfinite(policy.staticRaShare)|| ...
        policy.staticRaShare<=0||policy.staticRaShare>=1|| ...
        ~isnumeric(policy.maximumLoad)||~isscalar(policy.maximumLoad)|| ...
        ~isfinite(policy.maximumLoad)||policy.maximumLoad<0
    error('nbiot:controller:Policy','Adaptive policy limits are invalid.');
end
% уровни P должны убывать (direction −1) при росте порогов;
validateLevels(policy.accessLoadThresholds,policy.accessProbabilityLevels,-1);
% уровни доли RA должны возрастать (direction +1).
validateLevels(policy.raLoadThresholds,policy.raShareLevels,1);
end

%VALIDATELEVELS Пороги возрастают; уровни упорядочены (P — по убыванию, доля RA — по возрастанию).
% Проверка порогов и уровней:
function validateLevels(thresholds,levels,direction)
% уровни — непустая строка конечных чисел, монотонных в направлении DIRECTION; порогов на один меньше
% уровней; пороги конечные, неотрицательные, строго возрастают.
if ~isnumeric(levels)||~isrow(levels)||isempty(levels)||any(~isfinite(levels))|| ...
        any(direction*diff(levels)<=0)||~isnumeric(thresholds)|| ...
        (~isempty(thresholds)&&~isrow(thresholds))|| ...
        numel(thresholds)~=numel(levels)-1||any(~isfinite(thresholds))|| ...
        any(thresholds<0)||any(diff(thresholds)<=0)
    error('nbiot:controller:Policy','Thresholds and action levels must be ordered finite rows.');
end
end

% Тик — неотрицательное конечное целое число:
function yes=validTick(value)
% проверка типа, конечности, знака и целочисленности.
yes=isnumeric(value)&&isscalar(value)&&isreal(value)&&isfinite(value)&& ...
    value>=0&&value==fix(value);
end
