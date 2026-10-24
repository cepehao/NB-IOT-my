function runtime=prepareRuntime(cfg,options)
%PREPARERUNTIME Подготовка контроллера перед запуском (ТЗ §23–26).
%   RUNTIME = nbiot.controller.prepareRuntime(CFG, OPTIONS)
%   CFG.policy.name: 'Static' — контроллер выключен, OPTIONS должен быть пустым;
%   'Adaptive-P' | 'Adaptive-RA/DT' — нужен оценщик нагрузки:
%     OPTIONS.estimator   — функция оценка = f(признаки), где признаки — таблица из одной строки
%                           со столбцами nbiot.dataset.featureSchema().inputNames (только наблюдения BS,
%                           ТЗ §40), оценка — число (среднее число UE в фазе RA, meanRaUe).
%                           Сюда подключается обученная модель (например, из Python).
%     OPTIONS.policy      — (необязательно) поля, переопределяющие configs/adaptiveDefaults
%                           (пороги, уровни P и долей RA, maximumLoad).
%     OPTIONS.description — (необязательно) текстовое описание оценщика для результата.
%   Начальная конфигурация согласуется с методом: Adaptive-P — доля RA 10 %, Adaptive-RA/DT — P = 1;
%   окна контроллера и датасета — 500 мс (ТЗ §23).
%   RUNTIME: enabled, method, policy, estimator, modelMetadata (описание оценщика для результата).
if nargin<2||isempty(options), options=struct(); end
if ~isstruct(options)||~isscalar(options)
    error('nbiot:controller:Options','Controller options must be a scalar structure.');
end
unknown=setdiff(fieldnames(options),{'estimator','policy','description'});
if ~isempty(unknown)
    error('nbiot:controller:Options','Unsupported controller option: %s',unknown{1});
end
method=char(string(cfg.policy.name));
runtime=struct('enabled',false,'method',method,'policy',adaptiveDefaults(), ...
    'estimator',[],'modelMetadata',struct('estimator','','description','','status','not-applicable'));
if strcmp(method,'Static')
    if ~isempty(fieldnames(options))
        error('nbiot:controller:Options','Static runs do not accept controller options.');
    end
    return;
end
if ~any(strcmp(method,{'Adaptive-P','Adaptive-RA/DT'}))
    error('nbiot:controller:Method','Unknown control method.');
end
% Адаптивный метод без оценщика нагрузки невозможен (ТЗ §46.4).
if ~isfield(options,'estimator')||~isa(options.estimator,'function_handle')
    error('nbiot:controller:EstimatorRequired', ...
        'Adaptive runs require options.estimator: a function handle features -> load estimate.');
end
policy=adaptiveDefaults();
if isfield(options,'policy')&&~isempty(options.policy)
    if ~isstruct(options.policy)||~isscalar(options.policy)|| ...
            ~all(ismember(fieldnames(options.policy),fieldnames(policy)))
        error('nbiot:controller:Options','Adaptive policy contains unsupported fields.');
    end
    names=fieldnames(options.policy);
    for k=1:numel(names), policy.(names{k})=options.policy.(names{k}); end
end
if policy.windowTicks~=500||cfg.policy.windowTicks~=500||cfg.dataset.windowTicks~=500
    error('nbiot:controller:Window','Adaptive decisions and observations must use 500 ms windows.');
end
% Начальная конфигурация должна быть допустимой точкой выбранного метода.
if strcmp(method,'Adaptive-P')
    if cfg.policy.raShare~=policy.staticRaShare|| ...
            ~ismember(cfg.policy.accessProbability,policy.accessProbabilityLevels)
        error('nbiot:controller:Configuration', ...
            'Adaptive-P requires RA/DT=10/90 and a supported starting P value.');
    end
elseif cfg.policy.accessProbability~=policy.staticAccessProbability|| ...
        ~ismember(cfg.policy.raShare,policy.raShareLevels)
    error('nbiot:controller:Configuration', ...
        'Adaptive-RA/DT requires P=1 and a supported starting RA/DT share.');
end
description='';
if isfield(options,'description'), description=char(string(options.description)); end
metadata=struct('estimator',func2str(options.estimator),'description',description,'status','supplied');
runtime=struct('enabled',true,'method',method,'policy',policy, ...
    'estimator',options.estimator,'modelMetadata',metadata);
end
