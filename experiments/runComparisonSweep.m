function manifest=runComparisonSweep(options)
%RUNCOMPARISONSWEEP Run or plan paired Static/Adaptive comparisons.
%   Серия парных сравнений Static / Adaptive-P / Adaptive-RA/DT на одних реализациях (ТЗ §28, §63).
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root); addpath(fullfile(root,'experiments')); setupProject();
options=normalizeOptions(options,root);
budgetCfg=options.config;
budgetCfg.simulation.numUE=max(options.counts);
nbiot.experiments.validateExecutionBudget(budgetCfg,options.execution,1);
caseCount=numel(options.counts)*numel(options.burstDurations)* ...
    numel(options.realizationIds)*numel(options.methods);
admission=struct('admissionStatus','not-preflighted');
if ~options.designOnly
    nbiot.experiments.validateExecutionBudget(budgetCfg,options.execution,caseCount);
    admission=validateExecutableModel(options);
    validateSweepConfigurationMatrix(options);
end
design=buildDesign(options,root,admission);

available=nbiot.experiments.availableRealizationIds( ...
    options.registryFile,options.execution.role,options.realizationIds);
if options.designOnly&&numel(available)~=numel(options.realizationIds)
    error('nbiot:experiments:ComparisonIds', ...
        'One or more requested realization IDs are already reserved or assigned.');
end

if options.designOnly
    ensureEmptyOrMissingOutput(options.outputFolder,{'comparison-design.csv','comparison-design.json'});
    if ~isfolder(options.outputFolder), mkdir(options.outputFolder); end
    manifest=designManifest(options,design);
    writeDesign(options.outputFolder,manifest);
    return;
end

[manifest,isNew]=openComparisonManifest(options,design);
if isNew
    if numel(available)~=numel(options.realizationIds)
        error('nbiot:experiments:ComparisonIds', ...
            'One or more requested realization IDs are already reserved or assigned.');
    end
    nbiot.experiments.registerRealizationUse(options.registryFile, ...
        options.execution.role,options.realizationIds, ...
        manifest.allocation.source,'planned');
    manifest.allocation.registered=true;
    writeManifest(options.outputFolder,manifest);
else
    allocation=lookupAllocation(options.registryFile,manifest.allocation);
    if isempty(allocation)
        if numel(available)~=numel(options.realizationIds)
            error('nbiot:experiments:ComparisonIds', ...
                'The comparison allocation is missing and one or more IDs are now in use.');
        end
        nbiot.experiments.registerRealizationUse(options.registryFile, ...
            options.execution.role,options.realizationIds, ...
            manifest.allocation.source,'planned');
        allocation=lookupAllocation(options.registryFile,manifest.allocation);
    end
    if strcmp(allocation.status,'failed')
        error('nbiot:experiments:ComparisonAllocation', ...
            'This comparison ID allocation was closed as failed and cannot be resumed.');
    end
    manifest.allocation.registered=true;
    manifest.allocation.status=allocation.status;
    writeManifest(options.outputFolder,manifest);
end

manifest.status='running';
writeManifest(options.outputFolder,manifest);
suiteClock=tic; stop=false; rowIndex=0;
for count=options.counts
    for burst=options.burstDurations
        for id=options.realizationIds
            sharedCfg=caseConfig(options,count,burst,id,'Static');
            scenario=nbiot.scenario.buildScenario(sharedCfg);
            for method=options.methods
                rowIndex=rowIndex+1;
                if toc(suiteClock)>=options.execution.maxSuiteSeconds
                    manifest.status='incomplete';
                    manifest.error='The comparison suite time limit was reached.';
                    stop=true; break;
                end
                cfg=caseConfig(options,count,burst,id,method);
                caseFolder=caseOutputFolder(options.outputFolder,count,burst,id,method);
                caseOptions=struct('execution',options.execution, ...
                    'calibrationFile',options.calibrationFile,'modelFile',options.modelFile, ...
                    'allowDevelopmentModel',options.allowDevelopmentModel, ...
                    'controllerPolicy',options.controllerPolicy,'scenario',scenario, ...
                    'modelAcceptanceFile',options.modelAcceptanceFile, ...
                    'policyFile',fieldOr(admission,'policyFile',''), ...
                    'admissionMetadata',admission, ...
                    'resume',options.resume,'runExperimentFcn',options.runExperimentFcn, ...
                    'runnerFiles',{options.runnerFiles},'runnerInputs',options.runnerInputs, ...
                    'runnerDependenciesDeclared',options.runnerDependenciesDeclared);
                try
                    record=nbiot.experiments.runComparisonCase(cfg,method,caseFolder,caseOptions);
                catch exception
                    record=failedRecord(cfg,method,exception);
                end
                manifest.cases=applyRecord(manifest.cases,rowIndex,record);
                manifest.updatedAt=utcNow();
                writeManifest(options.outputFolder,manifest);
                if record.status~="completed"
                    manifest.status='incomplete';
                    stop=true; break;
                end
            end
            if stop, break; end
        end
        if stop, break; end
    end
    if stop, break; end
end

if ~stop&&all(manifest.cases.status=="completed")
    manifest.status='completed';
    if strcmp(manifest.allocation.status,'planned')
        nbiot.experiments.updateRealizationUseStatus(options.registryFile, ...
            options.execution.role,options.realizationIds,'completed');
        manifest.allocation.status='completed';
    end
else
    manifest.status='incomplete';
end
manifest.elapsedSeconds=toc(suiteClock);
manifest.updatedAt=utcNow();
writeManifest(options.outputFolder,manifest);
end

function options=normalizeOptions(options,root)
if nargin<1||~isstruct(options)||~isscalar(options)
    error('nbiot:experiments:ComparisonOptions','Supply one scalar options structure.');
end
allowed={'designOnly','counts','burstDurations','methods','realizationIds', ...
    'calibrationFile','modelFile','allowDevelopmentModel','controllerPolicy', ...
    'modelAcceptanceFile','execution','registryFile','outputFolder','resume','config', ...
    'runExperimentFcn','runnerFiles','runnerInputs','runnerDependenciesDeclared'};
unknown=setdiff(fieldnames(options),allowed);
if ~isempty(unknown)
    error('nbiot:experiments:ComparisonOptions','Unsupported option %s.',unknown{1});
end
required={'counts','burstDurations','methods','realizationIds','calibrationFile', ...
    'execution','registryFile','outputFolder'};
missing=required(~isfield(options,required));
if ~isempty(missing)
    error('nbiot:experiments:ComparisonOptions','Missing required option %s.',missing{1});
end
base=struct('designOnly',false,'modelFile','','allowDevelopmentModel',false, ...
    'controllerPolicy',struct(),'modelAcceptanceFile','', ...
    'resume',true,'config',nbiot.config.defaultConfig(), ...
    'runExperimentFcn',[],'runnerFiles',{{}},'runnerInputs',struct(), ...
    'runnerDependenciesDeclared',false);
names=fieldnames(base);
for k=1:numel(names)
    if ~isfield(options,names{k}), options.(names{k})=base.(names{k}); end
end
if ~islogical(options.designOnly)||~isscalar(options.designOnly)|| ...
        ~islogical(options.resume)||~isscalar(options.resume)|| ...
        ~islogical(options.allowDevelopmentModel)||~isscalar(options.allowDevelopmentModel)
    error('nbiot:experiments:ComparisonOptions','designOnly, resume and allowDevelopmentModel must be scalar logicals.');
end
options.counts=positiveIntegerVector(options.counts,'counts',65535);
options.burstDurations=positiveIntegerVector(options.burstDurations,'burstDurations',2^24-1);
options.realizationIds=positiveIntegerVector(options.realizationIds,'realizationIds',4095,true);
requested=string(options.methods(:).');
standard=["Static","Adaptive-P","Adaptive-RA/DT"];
if isempty(requested)||numel(unique(requested))~=numel(requested)|| ...
        any(~ismember(requested,standard))||numel(requested)<2
    error('nbiot:experiments:ComparisonMethods','Choose at least two distinct supported methods.');
end
options.methods=standard(ismember(standard,requested));
if ~isstruct(options.execution)||~isscalar(options.execution)
    error('nbiot:experiments:ComparisonOptions','execution must be a scalar structure.');
end
if ~isstruct(options.config)||~isscalar(options.config)
    error('nbiot:experiments:ComparisonOptions','config must be a scalar structure.');
end
if ~isstruct(options.controllerPolicy)||~isscalar(options.controllerPolicy)
    error('nbiot:experiments:ComparisonOptions','controllerPolicy must be a scalar structure.');
end
if ~isstruct(options.runnerInputs)||~isscalar(options.runnerInputs)
    error('nbiot:experiments:ComparisonOptions','runnerInputs must be a scalar structure.');
end
if ~islogical(options.runnerDependenciesDeclared)||~isscalar(options.runnerDependenciesDeclared)
    error('nbiot:experiments:ComparisonOptions','runnerDependenciesDeclared must be a scalar logical.');
end
options.calibrationFile=pathText(options.calibrationFile,'calibrationFile',false);
options.registryFile=pathText(options.registryFile,'registryFile',false);
options.outputFolder=pathText(options.outputFolder,'outputFolder',true);
options.modelFile=pathText(options.modelFile,'modelFile',true);
options.modelAcceptanceFile=pathText(options.modelAcceptanceFile,'modelAcceptanceFile',true);
options.calibrationFile=absolutePath(options.calibrationFile);
options.registryFile=absolutePath(options.registryFile);
options.outputFolder=absolutePath(options.outputFolder);
if ~isempty(options.modelFile), options.modelFile=absolutePath(options.modelFile); end
if ~isempty(options.modelAcceptanceFile)
    options.modelAcceptanceFile=absolutePath(options.modelAcceptanceFile);
end
if ~isfile(options.calibrationFile)||~isfile(options.registryFile)
    error('nbiot:experiments:ComparisonInput','Calibration or realization registry does not exist.');
end
if any(ismember(options.methods,["Adaptive-P","Adaptive-RA/DT"]))&& ...
        (isempty(options.modelFile)||~isfile(options.modelFile))
    error('nbiot:experiments:ComparisonModel','Adaptive comparison requires an explicit model file.');
end
if ~isempty(options.runExperimentFcn)&&~isa(options.runExperimentFcn,'function_handle')
    error('nbiot:experiments:ComparisonRunner','runExperimentFcn must be a function handle.');
end
if ~isempty(options.runExperimentFcn)&& ...
        (~options.runnerDependenciesDeclared||isempty(options.runnerFiles))
    error('nbiot:experiments:ComparisonRunner', ...
        'Injected runners require declared source files and dependencies.');
end
options.root=root;
end

function vector=positiveIntegerVector(value,name,maximum,allowZero)
if nargin<4, allowZero=false; end
if ~isnumeric(value)||~isreal(value)||~isvector(value)||isempty(value)|| ...
        any(~isfinite(value))||any(value~=fix(value))||any(value>maximum)|| ...
        any(value<(~allowZero))||numel(unique(value))~=numel(value)
    error('nbiot:experiments:ComparisonOptions','%s must contain distinct allowed integers.',name);
end
vector=sort(double(value(:).'));
end

function value=pathText(value,name,allowEmpty)
if nargin<3, allowEmpty=false; end
if isstring(value)&&isscalar(value), value=char(value); end
if allowEmpty&&isempty(value), return; end
if ~ischar(value)||isempty(strtrim(value))||size(value,1)~=1
    error('nbiot:experiments:ComparisonOptions','%s must be a non-empty path.',name);
end
end

function path=absolutePath(path)
path=char(java.io.File(char(path)).getCanonicalPath());
end

function design=buildDesign(options,root,admission)
if nargin<3, admission=struct(); end
caseCount=numel(options.counts)*numel(options.burstDurations)* ...
    numel(options.realizationIds)*numel(options.methods);
source=optimizationSourceManifest(root);
calibrationHash=nbiot.ml.fileSha256(options.calibrationFile);
modelHash=''; if ~isempty(options.modelFile), modelHash=nbiot.ml.fileSha256(options.modelFile); end
acceptanceHash='';
if ~isempty(options.modelAcceptanceFile)&&isfile(options.modelAcceptanceFile)
    acceptanceHash=nbiot.ml.fileSha256(options.modelAcceptanceFile);
end
canonicalConfig=options.config;
canonicalConfig.simulation.numUE='<per-case>';
canonicalConfig.simulation.realizationId='<per-case>';
canonicalConfig.traffic.burstDurationTicks='<per-case>';
canonicalConfig.logging.outputFolder='<case-output>';
canonicalConfig.policy.name='<per-method>';
identity=struct('schemaVersion',1,'counts',options.counts, ...
    'burstDurations',options.burstDurations,'methods',cellstr(options.methods), ...
    'realizationIds',options.realizationIds,'config',canonicalConfig, ...
    'execution',options.execution,'calibrationSha256',calibrationHash, ...
    'modelSha256',modelHash,'allowDevelopmentModel',options.allowDevelopmentModel, ...
    'modelAcceptanceSha256',acceptanceHash, ...
    'admissionStatus',fieldOr(admission,'admissionStatus','not-validated'), ...
    'admissionPolicySha256',fieldOr(admission,'policySha256',''), ...
    'admissionEvidenceDigest',fieldOr(admission,'evidenceDigest',''), ...
    'controllerPolicy',options.controllerPolicy,'sourceSha256',source.sha256, ...
    'runnerFiles',{cellstr(string(options.runnerFiles))}, ...
    'runnerInputs',options.runnerInputs);
designHash=hashText(unicode2native(jsonencode(identity),'UTF-8'));
cases=planTable(options,caseCount);
design=struct('caseCount',caseCount,'designHash',designHash, ...
    'calibrationSha256',calibrationHash,'modelSha256',modelHash, ...
    'sourceSha256',source.sha256,'identity',identity,'cases',cases);
end

function cases=planTable(options,caseCount)
caseIndex=(1:caseCount).'; numUE=zeros(caseCount,1); burstDurationTicks=zeros(caseCount,1);
realizationId=zeros(caseCount,1); method=strings(caseCount,1); row=0;
for count=options.counts
    for burst=options.burstDurations
        for id=options.realizationIds
            for currentMethod=options.methods
                row=row+1; numUE(row)=count; burstDurationTicks(row)=burst;
                realizationId(row)=id; method(row)=currentMethod;
            end
        end
    end
end
cases=table(caseIndex,numUE,burstDurationTicks,realizationId,method, ...
    repmat("pending",caseCount,1),nan(caseCount,1),repmat("",caseCount,1), ...
    repmat("",caseCount,1),repmat("",caseCount,1),repmat("",caseCount,1), ...
    repmat("",caseCount,1),nan(caseCount,1),nan(caseCount,1),nan(caseCount,1), ...
    nan(caseCount,1),nan(caseCount,1),nan(caseCount,1),nan(caseCount,1), ...
    repmat("",caseCount,1),repmat("",caseCount,1), ...
    'VariableNames',{'caseIndex','numUE','burstDurationTicks','realizationId', ...
    'method','status','elapsedSeconds','resultFile','caseKey','inputSha256', ...
    'configSha256','sourceSha256','raSuccessProbability','deliveryProbability', ...
    'throughputBitsPerSecond','meanDelayTicks','dataBler','ulOccupancy','dlOccupancy', ...
    'errorIdentifier','errorMessage'});
emptyMetrics=nbiot.experiments.comparisonKpis(struct(),'Static');
metricNames=fieldnames(emptyMetrics);
for k=1:numel(metricNames)
    if ~ismember(metricNames{k},cases.Properties.VariableNames)
        cases.(metricNames{k})=nan(caseCount,1);
    end
end
end

function manifest=designManifest(options,design)
unmetRequirements={'Design-only mode does not establish model admission or execution readiness.'};
manifest=struct('schemaVersion',1,'designOnly',true,'status','planned', ...
    'readyForExecution',false,'unmetRequirements',{unmetRequirements}, ...
    'designHash',design.designHash,'caseCount',design.caseCount, ...
    'estimatedMaxSuiteSeconds',design.caseCount*options.execution.maxCaseSeconds, ...
    'identity',design.identity,'cases',design.cases);
end

function writeDesign(folder,manifest)
columns=manifest.cases(:,{'caseIndex','numUE','burstDurationTicks','realizationId','method','status'});
writeTableAtomic(columns,fullfile(folder,'comparison-design.csv'));
payload=struct('schemaVersion',manifest.schemaVersion,'status',manifest.status, ...
    'readyForExecution',manifest.readyForExecution, ...
    'unmetRequirements',{manifest.unmetRequirements}, ...
    'designHash',manifest.designHash,'caseCount',manifest.caseCount, ...
    'estimatedMaxSuiteSeconds',manifest.estimatedMaxSuiteSeconds, ...
    'identity',manifest.identity,'cases',table2struct(columns));
writeTextAtomic(fullfile(folder,'comparison-design.json'),jsonencode(payload));
end

function [manifest,isNew]=openComparisonManifest(options,design)
manifestPath=fullfile(options.outputFolder,'comparison-manifest.mat');
if isfile(manifestPath)
    if ~options.resume
        error('nbiot:experiments:ComparisonResume','Output already contains a comparison manifest and resume=false.');
    end
    try
        saved=load(manifestPath,'manifest');
    catch exception
        error('nbiot:experiments:ComparisonManifest','Cannot read saved manifest: %s',exception.message);
    end
    if ~isfield(saved,'manifest')||~isstruct(saved.manifest)|| ...
            ~isfield(saved.manifest,'designHash')||~strcmp(saved.manifest.designHash,design.designHash)
        error('nbiot:experiments:ComparisonIdentity', ...
            'Saved comparison plan differs in model, policy, calibration, source or case matrix.');
    end
    manifest=saved.manifest; isNew=false; return;
end
ensureEmptyOrMissingOutput(options.outputFolder,{});
if ~isfolder(options.outputFolder), mkdir(options.outputFolder); end
suiteId=char(java.util.UUID.randomUUID());
allocation=struct('role',options.execution.role,'ids',options.realizationIds, ...
    'source',['comparison-sweep:' suiteId],'registered',false,'status','planned');
manifest=struct('schemaVersion',1,'designOnly',false,'status','planned', ...
    'designHash',design.designHash,'createdAt',utcNow(),'updatedAt',utcNow(), ...
    'elapsedSeconds',0,'caseCount',design.caseCount, ...
    'estimatedMaxSuiteSeconds',design.caseCount*options.execution.maxCaseSeconds, ...
    'outputFolder',options.outputFolder,'identity',design.identity, ...
    'allocation',allocation,'cases',design.cases,'error','');
writeManifest(options.outputFolder,manifest);
isNew=true;
end

function cfg=caseConfig(options,count,burst,id,method)
cfg=options.config;
cfg.simulation.numUE=count; cfg.simulation.realizationId=id;
cfg.traffic.kind='burst'; cfg.traffic.burstDurationTicks=burst;
cfg.policy.name=char(string(method));
if ismember(string(method),["Adaptive-P","Adaptive-RA/DT"])
    cfg.policy.windowTicks=500; cfg.dataset.windowTicks=500;
    cfg.policy.accessProbability=1; cfg.policy.raShare=0.1;
end
cfg=nbiot.experiments.loadCalibration(cfg,options.calibrationFile);
end

function folder=caseOutputFolder(root,count,burst,id,method)
folder=fullfile(root,sprintf('n%05d_b%04d_id%04d',count,burst,id),methodSlug(method));
end

function slug=methodSlug(method)
switch char(string(method))
    case 'Static', slug='static';
    case 'Adaptive-P', slug='adaptive-p';
    case 'Adaptive-RA/DT', slug='adaptive-ra-dt';
    otherwise, error('nbiot:experiments:ComparisonMethod','Unsupported comparison method.');
end
end

function record=failedRecord(cfg,method,exception)
record=struct('numUE',double(cfg.simulation.numUE), ...
    'burstDurationTicks',double(cfg.traffic.burstDurationTicks), ...
    'realizationId',double(cfg.simulation.realizationId),'method',string(method), ...
    'status',"failed",'elapsedSeconds',NaN,'resultFile',"",'caseKey',"", ...
    'inputSha256',"",'configSha256',"",'sourceSha256',"", ...
    'calibrationSha256',"", ...
    'errorIdentifier',string(exception.identifier),'errorMessage',string(exception.message));
comparisonMetrics=nbiot.experiments.comparisonKpis(struct(),method);
names=fieldnames(comparisonMetrics);
for k=1:numel(names), record.(names{k})=comparisonMetrics.(names{k}); end
end

function cases=applyRecord(cases,index,record)
names=fieldnames(record);
for k=1:numel(names), cases.(names{k})(index)=record.(names{k}); end
end

function allocation=lookupAllocation(registryFile,expected)
allocation=[];
try
    registry=jsondecode(fileread(registryFile));
catch exception
    error('nbiot:experiments:ComparisonRegistry','Cannot read ID registry: %s',exception.message);
end
if ~isfield(registry,'assignments'), return; end
assignments=registry.assignments;
for k=1:numel(assignments)
    item=assignments(k);
    if strcmp(char(string(item.role)),expected.role)&& ...
            strcmp(char(string(item.source)),expected.source)&& ...
            isequal(sort(double(item.ids(:).')),sort(double(expected.ids(:).')))
        allocation=struct('status',char(string(item.status))); return;
    end
end
end

function ensureEmptyOrMissingOutput(folder,allowedNames)
if isfile(folder)
    error('nbiot:experiments:ComparisonOutput','Output folder path names an existing file.');
end
if ~isfolder(folder), return; end
contents=dir(folder); contents=contents(~ismember({contents.name},{'.','..'}));
if ~all(ismember({contents.name},allowedNames))
    error('nbiot:experiments:ComparisonOutput','Output folder already contains unrelated or scientific files.');
end
end

function writeManifest(folder,manifest)
matPath=fullfile(folder,'comparison-manifest.mat');
temporary=[tempname(folder) '.mat']; cleanup=onCleanup(@() removeTemporary(temporary));
save(temporary,'manifest','-v7.3');
moveAtomic(temporary,matPath);
writeTableAtomic(manifest.cases,fullfile(folder,'comparison-manifest.csv'));
end

function writeTableAtomic(value,path)
folder=fileparts(path); temporary=[tempname(folder) '.csv'];
cleanup=onCleanup(@() removeTemporary(temporary));
writetable(value,temporary);
moveAtomic(temporary,path);
end

function writeTextAtomic(path,value)
folder=fileparts(path); temporary=[tempname(folder) '.json'];
cleanup=onCleanup(@() removeTemporary(temporary));
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:ComparisonWrite','Cannot write plan file.'); end
fileCleanup=onCleanup(@() fclose(fid));
bytes=unicode2native(value,'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:experiments:ComparisonWrite','Could not write complete plan file.');
end
clear fileCleanup
moveAtomic(temporary,path);
end

function moveAtomic(source,destination)
[ok,message]=movefile(source,destination,'f');
if ~ok, error('nbiot:experiments:ComparisonWrite','Cannot commit file: %s',message); end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end

function value=utcNow()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss'));
end

function digest=hashText(bytes)
algorithm=java.security.MessageDigest.getInstance('SHA-256');
algorithm.update(typecast(uint8(bytes(:)),'int8'));
digest=lower(reshape(dec2hex(typecast(algorithm.digest(),'uint8'),2).',1,[]));
end

function validateSweepConfigurationMatrix(options)
policy=adaptiveDefaults();
if ~isempty(options.controllerPolicy)
    names=fieldnames(options.controllerPolicy);
    if ~all(ismember(names,fieldnames(policy)))
        error('nbiot:experiments:ControllerPolicy', ...
            'Controller policy contains unsupported fields.');
    end
    for k=1:numel(names), policy.(names{k})=options.controllerPolicy.(names{k}); end
end
for ueCount=options.counts
    for burst=options.burstDurations
        for method=options.methods
            cfg=caseConfig(options,ueCount,burst,options.realizationIds(1),method);
            cfg=nbiot.config.validateConfig(cfg);
            if ismember(method,["Adaptive-P","Adaptive-RA/DT"])
                assertControllerConfiguration(cfg,policy);
            end
        end
    end
end
end

function admission=validateExecutableModel(options)
admission=struct('admissionStatus','not-required','acceptanceSha256','', ...
    'policySha256','','evidenceDigest','','policyFile','','modelSha256','');
adaptiveMethods=options.methods(ismember(options.methods, ...
    ["Adaptive-P","Adaptive-RA/DT"]));
if isempty(adaptiveMethods), return; end

if profileIs(options.execution,'external-machine')
    firstCfg=caseConfig(options,options.counts(1),options.burstDurations(1), ...
        options.realizationIds(1),adaptiveMethods(1));
    admission=nbiot.ml.validateModelAcceptance(options.modelAcceptanceFile, ...
        options.modelFile,options.controllerPolicy,options.execution, ...
        options.realizationIds,firstCfg);
    currentSource=optimizationSourceManifest(options.root);
    nbiot.ml.verifyModelAcceptanceRuntimeIdentity(admission,currentSource.sha256, ...
        nbiot.ml.fileSha256(options.calibrationFile));
    admission.policyFile=policyFileFromAcceptance(options.modelAcceptanceFile);
    admission.modelSha256=nbiot.ml.fileSha256(options.modelFile);
    admission.comparisonIds=double(options.realizationIds(:).');
    configurationCount=numel(options.counts)*numel(options.burstDurations)*numel(adaptiveMethods);
    sweepConfigurations=cell(configurationCount,1); configIndex=0;
    for count=options.counts
        for burst=options.burstDurations
            for method=adaptiveMethods
                cfg=caseConfig(options,count,burst,options.realizationIds(1),method);
                assertControllerConfiguration(cfg,options.controllerPolicy);
                configIndex=configIndex+1;
                sweepConfigurations{configIndex}=cfg;
            end
        end
    end
    nbiot.experiments.validateComparisonAcceptanceScope(admission.scope,sweepConfigurations);
    return;
end

isLocalDevelopment=profileIs(options.execution,'local-development')&& ...
    isfield(options.execution,'role')&& ...
    strcmp(char(string(options.execution.role)),'development');
if ~isLocalDevelopment
    error('nbiot:experiments:ComparisonModel', ...
        'Adaptive execution is restricted to local development or accepted external admission.');
end
if ~options.allowDevelopmentModel
    error('nbiot:experiments:ComparisonModel', ...
        'Local Adaptive execution requires explicit allowDevelopmentModel=true.');
end
if ~isempty(options.runExperimentFcn)
    admission.admissionStatus='development-only';
    return;
end
bundle=nbiot.ml.validateModelBundle(options.modelFile);
if strcmp(bundle.status,'development')
    admission.admissionStatus='development-only';
    return;
end
error('nbiot:experiments:ComparisonModel', ...
    'Adaptive execution requires a development model in local development.');
end

function assertControllerConfiguration(cfg,policy)
if policy.windowTicks~=500||cfg.policy.windowTicks~=500||cfg.dataset.windowTicks~=500
    error('nbiot:controller:Window', ...
        'Adaptive decisions and observations must use 500 ms windows.');
end
if strcmp(cfg.policy.name,'Adaptive-P')
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
end

function path=policyFileFromAcceptance(acceptancePath)
try
    acceptance=jsondecode(fileread(acceptancePath));
    relative=char(string(acceptance.policy.file));
    if isempty(relative)||startsWith(relative,{'/','\'})||contains(relative,':')|| ...
            any(split(string(strrep(relative,'\','/')),'/')=="..")
        error('nbiot:ml:ModelAcceptance','Acceptance policy reference is not package-relative.');
    end
    root=absolutePath(fileparts(acceptancePath));
    path=absolutePath(fullfile(root,strrep(relative,'/',filesep)));
    if ~startsWith(path,[root filesep],'IgnoreCase',true)||~isfile(path)
        error('nbiot:ml:ModelAcceptance','Acceptance policy file is outside or missing from its package.');
    end
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Cannot resolve the accepted policy file: %s.',exception.message);
end
end

function yes=profileIs(execution,name)
yes=isstruct(execution)&&isscalar(execution)&&isfield(execution,'profile')&& ...
    (ischar(execution.profile)||(isstring(execution.profile)&&isscalar(execution.profile)))&& ...
    strcmp(char(string(execution.profile)),name);
end

function value=fieldOr(input,name,fallback)
value=fallback;
if isstruct(input)&&isfield(input,name), value=input.(name); end
end
