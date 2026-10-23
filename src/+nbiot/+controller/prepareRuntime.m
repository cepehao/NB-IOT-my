function runtime=prepareRuntime(cfg,execution,options)
%PREPARERUNTIME Подготовка контроллера перед запуском (ТЗ §23, §46.4).
%   Static — контроллер выключен (опций быть не должно). Adaptive-* — обязательна ML-модель
%   (options.model: путь к .mat или bundle), политика (по умолчанию configs/adaptiveDefaults),
%   окна 500 мс и согласованная начальная конфигурация (Adaptive-P: RA 10 %; Adaptive-RA/DT: P = 1).
%   Проверки допуска модели (development/external) — инфраструктура v4 (docs/model-acceptance-contract.md).
%   RUNTIME: enabled, method, policy, bundle модели, метаданные модели для результата.
if nargin<3||isempty(options), options=struct(); end
if ~isstruct(options)||~isscalar(options)
    error('nbiot:controller:Options','Controller options must be a scalar structure.');
end
allowed={'model','policy','allowDevelopmentModel','modelAcceptanceFile'};
unknown=setdiff(fieldnames(options),allowed);
if ~isempty(unknown)
    error('nbiot:controller:Options','Unsupported controller option: %s',unknown{1});
end
method=char(string(cfg.policy.name));
modelMetadata=struct('modelName','','schemaVersion','','status','not-applicable', ...
    'dataKind','','sha256','','trainingIds',[],'validationIds',[],'testIds',[]);
modelMetadata.targetName='';
modelMetadata.featureNames={};
modelMetadata.seed=NaN;
modelMetadata.admissionStatus='not-applicable';
modelMetadata.acceptanceSha256='';
modelMetadata.policySha256='';
modelMetadata.evidenceDigest='';
modelMetadata.evaluationMetrics=emptyEvaluationMetrics();
modelMetadata.evaluationStatus='not-applicable';
runtime=struct('enabled',false,'method',method,'policy',adaptiveDefaults(), ...
    'bundle',[],'modelHash','','modelMetadata',modelMetadata);
if strcmp(method,'Static')
    if ~isempty(fieldnames(options))
        error('nbiot:controller:Options','Static runs do not accept controller options.');
    end
    return;
end
if ~isfield(options,'model')||isempty(options.model)
    error('nbiot:controller:ModelRequired', ...
        'Adaptive runs require an explicitly supplied compatible model.');
end
allowDevelopment=false;
if isfield(options,'allowDevelopmentModel')
    allowDevelopment=options.allowDevelopmentModel;
end
if ~islogical(allowDevelopment)||~isscalar(allowDevelopment)
    error('nbiot:controller:Options','allowDevelopmentModel must be a scalar logical.');
end
isExternal=profileIs(execution,'external-machine');
admission=struct('admissionStatus','not-applicable','acceptanceSha256','', ...
    'policySha256','','evidenceDigest','');
if isExternal
    if allowDevelopment
        error('nbiot:ml:ModelAcceptance', ...
            'allowDevelopmentModel cannot grant capability in an external run.');
    end
    policy=[];
    if isfield(options,'policy'), policy=options.policy; end
    acceptancePath='';
    if isfield(options,'modelAcceptanceFile'), acceptancePath=options.modelAcceptanceFile; end
    admissionExecution=execution;
    if isstruct(admissionExecution)&&isscalar(admissionExecution)&& ...
            isfield(admissionExecution,'numCases')
        % validateExecutionBudget adds this derived field to its returned value;
        % the public admission validator accepts only caller-supplied budget fields.
        admissionExecution=rmfield(admissionExecution,'numCases');
    end
    admission=nbiot.ml.validateModelAcceptance(acceptancePath,options.model, ...
        policy,admissionExecution,cfg.simulation.realizationId,cfg);
    policy=options.policy;
else
    policy=adaptiveDefaults();
    if isfield(options,'policy')&&~isempty(options.policy)
        if ~isstruct(options.policy)||~isscalar(options.policy)
            error('nbiot:controller:Options','Adaptive policy must be a scalar structure.');
        end
        names=fieldnames(options.policy);
        if ~all(ismember(names,fieldnames(policy)))
            error('nbiot:controller:Options','Adaptive policy contains unsupported fields.');
        end
        for k=1:numel(names), policy.(names{k})=options.policy.(names{k}); end
    end
end
if policy.windowTicks~=500||cfg.policy.windowTicks~=500||cfg.dataset.windowTicks~=500
    error('nbiot:controller:Window','Adaptive decisions and observations must use 500 ms windows.');
end
if strcmp(method,'Adaptive-P')
    if cfg.policy.raShare~=policy.staticRaShare|| ...
            ~ismember(cfg.policy.accessProbability,policy.accessProbabilityLevels)
        error('nbiot:controller:Configuration', ...
            'Adaptive-P requires RA/DT=10/90 and a supported starting P value.');
    end
elseif strcmp(method,'Adaptive-RA/DT')
    if cfg.policy.accessProbability~=policy.staticAccessProbability|| ...
            ~ismember(cfg.policy.raShare,policy.raShareLevels)
        error('nbiot:controller:Configuration', ...
            'Adaptive-RA/DT requires P=1 and a supported starting RA/DT share.');
    end
else
    error('nbiot:controller:Method','Unknown control method.');
end

modelInput=options.model;
modelHash='';
modelPath='';
if ischar(modelInput)||(isstring(modelInput)&&isscalar(modelInput))
    modelPath=char(string(modelInput));
    modelHash=nbiot.ml.fileSha256(modelPath);
end
bundle=nbiot.ml.validateModelBundle(modelInput);
if ~strcmp(bundle.status,'development')&&~isExternal
    error('nbiot:controller:ModelStatus','This runtime currently accepts development models only.');
end
if isExternal
    if ~strcmp(bundle.dataKind,'candidate-training')
        error('nbiot:ml:ModelAcceptance','External admission requires reviewed candidate-training evidence.');
    end
elseif ~allowDevelopment||~profileIs(execution,'local-development')|| ...
        ~isfield(execution,'role')||~strcmp(char(string(execution.role)),'development')
    error('nbiot:controller:DevelopmentModelRestricted', ...
        'Development models are allowed only with an explicit local development run.');
end
metadata=struct('modelName',bundle.modelName,'schemaVersion',bundle.schemaVersion, ...
    'status',bundle.status,'dataKind',bundle.dataKind, ...
    'targetName',bundle.targetName, ...
    'featureNames',{cellstr(string(bundle.featureNames(:).'))}, ...
    'seed',double(bundle.seed),'sha256',modelHash, ...
    'trainingIds',double(bundle.trainingIds(:).'), ...
    'validationIds',double(bundle.validationIds(:).'), ...
    'testIds',double(bundle.testIds(:).'));
metadata.evaluationMetrics=nbiot.ml.loadModelEvaluationMetrics(modelPath,bundle);
metadata.evaluationStatus='unavailable';
if ~isempty(metadata.evaluationMetrics)
    metadata.evaluationStatus='verified';
end
if isExternal
    metadata.admissionStatus='accepted';
    metadata.acceptanceSha256=admission.acceptanceSha256;
    metadata.policySha256=admission.policySha256;
    metadata.evidenceDigest=admission.evidenceDigest;
else
    metadata.admissionStatus='development-only';
end
runtime=struct('enabled',true,'method',method,'policy',policy, ...
    'bundle',bundle,'modelHash',modelHash,'modelMetadata',metadata);
end

function yes=profileIs(execution,name)
yes=isstruct(execution)&&isscalar(execution)&&isfield(execution,'profile')&& ...
    (ischar(execution.profile)||(isstring(execution.profile)&&isscalar(execution.profile)))&& ...
    strcmp(char(string(execution.profile)),name);
end

function metrics=emptyEvaluationMetrics()
metrics=table(strings(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'split','sampleCount','idCount','mae','rmse'});
end
