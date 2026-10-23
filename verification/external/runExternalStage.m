function report=runExternalStage(packageFolder,stageName,outputFolder,inputDigest,reviewFile)
%RUNEXTERNALSTAGE Run one approved stage through fixed MATLAB entry points.
if nargin<5, reviewFile=''; end
validStages={'validate','pilot','data','assemble','train','freeze', ...
    'evaluate','admit','compare','summarize'};
stageName=textValue(stageName,'stageName');
if ~ismember(stageName,validStages)
    error('nbiot:externalStage:Stage','The requested external stage is not allowed.');
end
packageFolder=canonicalPath(textValue(packageFolder,'packageFolder'));
outputFolder=canonicalPath(textValue(outputFolder,'outputFolder'));
inputDigest=textValue(inputDigest,'inputDigest');
if isempty(regexp(inputDigest,'^[A-Fa-f0-9]{64}$','once'))
    error('nbiot:externalStage:Digest','A valid input digest is required.');
end
if ~strcmp(getenv('NBIOT_EXTERNAL_STAGE_PROFILE'),'external-machine')|| ...
        ~strcmp(getenv('NBIOT_EXTERNAL_STAGE_NAME'),stageName)|| ...
        ~strcmp(getenv('NBIOT_EXTERNAL_STAGE_INPUT_DIGEST'),inputDigest)
    error('nbiot:externalStage:ExecutionContext', ...
        'Run stages through runExternalStages.ps1 with the external-machine profile.');
end
if ~isfolder(packageFolder)||~isfolder(outputFolder)|| ...
        ~isWithin(outputFolder,packageFolder)||~isfile(fullfile(packageFolder,'manifest.json'))|| ...
        ~isfile(fullfile(packageFolder,'stages.json'))
    error('nbiot:externalStage:Package','The portable package or stage output folder is invalid.');
end
reportPath=textValue(getenv('NBIOT_EXTERNAL_STAGE_REPORT_PATH'),'stage report path');
if ~samePath(reportPath,fullfile(outputFolder,'stage-report.json'))||isfile(reportPath)
    error('nbiot:externalStage:Output','Stage report must use the new output folder and must not overwrite a file.');
end

projectRoot=fullfile(packageFolder,'project');
addpath(projectRoot);
addpath(fullfile(projectRoot,'experiments'));
addpath(fullfile(projectRoot,'verification','external'));
addpath(fullfile(projectRoot,'verification','completion','stage-2'));
setupProject();
manifest=readJson(fullfile(packageFolder,'manifest.json'),'package manifest');
state=readJson(fullfile(packageFolder,'stages.json'),'stage ledger');
entry=findStage(state,stageName);
if ~strcmp(entry.status,'running')||~strcmp(entry.inputDigest,inputDigest)
    error('nbiot:externalStage:State','The stage ledger does not authorize this stage input digest.');
end
registryPath=packageReference(packageFolder,manifest.registry.packagePath);
registryDigest=nbiot.ml.fileSha256(registryPath);
if ismember(stageName,{'pilot','data','compare'})&& ...
        ~ismember(char(string(manifest.resourceStatus)), ...
            {'target-reviewed','measured-and-target-reviewed'})
    error('nbiot:externalStage:ResourceBudgetReview', ...
        'The target resource budget must be reviewed before this stage.');
end
acceptanceFile=fullfile(projectRoot,'verification','completion','stage-2','acceptance.json');
if ismember(stageName,{'validate','pilot'})
    if isfile(acceptanceFile)
        calibration=packageReference(packageFolder,manifest.calibration.packagePath);
        verifyStage2AcceptanceForLoadProbe(acceptanceFile,projectRoot,calibration,registryPath);
    elseif strcmp(stageName,'pilot')
        error('nbiot:externalStage:Stage2Acceptance', ...
            'A fresh Stage 2 technical acceptance is required before the load pilot.');
    end
    if strcmpi(registryDigest,manifest.registry.sha256)
        preflight=validateExternalPreflight(packageFolder,struct('stage',stageName));
        if ~preflight.passed||~preflight.readiness.softwareReady||~preflight.readiness.stageReady
            error('nbiot:externalStage:Preflight', ...
                'Portable preflight did not approve this stage. Inspect its read-only report before retrying.');
        end
    elseif ~isfile(acceptanceFile)
        error('nbiot:externalStage:Preflight', ...
            'A changed realization registry requires fresh Stage 2 technical acceptance.');
    end
end
configuration=entry.configuration;
metadata=struct();
outputRoot=fullfile(outputFolder,'results');

switch stageName
    case 'validate'
        if ~isfile(acceptanceFile)
            report=makeReport(stageName,'awaiting-review',inputDigest,{}, ...
                struct('reason','stage-2-targeted-physical-and-technical-review-required'));
            writeReport(reportPath,report);
            return
        end
        metadata.stage2Acceptance=relativePath(packageFolder,acceptanceFile);
        metadata.stage2AcceptanceSha256=nbiot.ml.fileSha256(acceptanceFile);

    case 'pilot'
        calibration=packageReference(packageFolder,manifest.calibration.packagePath);
        registry=registryPath;
        id=pilotRealizationId(manifest.idAssignments);
        ensureEmptyFolder(outputRoot);
        budget=manifest.resourceBudget;
        execution=struct('profile','external-machine','role','stage-3-load-pilot', ...
            'maxUE',double(budget.maxUE),'maxCaseSeconds',double(budget.maxCaseSeconds), ...
            'maxSuiteSeconds',double(budget.maxSuiteSeconds),'timePolicy','hard-stop');
        pilot=runLoadPilot(struct('designOnly',false, ...
            'counts',[100 500 1000 2500 5000],'outputFolder',outputRoot, ...
            'stage2AcceptanceFile',acceptanceFile,'calibrationFile',calibration, ...
            'registryFile',registry,'realizationId',id,'execution',execution));
        memory=pilot.cases.matlabMemoryAfterBytes;
        measured=pilot.cases.wallSeconds;
        metadata=struct('resourceEvidence',struct('status','measured', ...
            'targetMachine',char(string(budget.targetMachine)), ...
            'availableMemoryBytes',double(budget.availableMemoryBytes), ...
            'maxUE',double(budget.maxUE),'maxCaseSeconds',double(budget.maxCaseSeconds), ...
            'maxSuiteSeconds',double(budget.maxSuiteSeconds), ...
            'maxProcesses',double(budget.maxProcesses), ...
            'maxMatlabMemoryAfterCaseBytes',max(memory),'maxMeasuredCaseSeconds',max(measured), ...
            'measuredSuiteSeconds',double(pilot.elapsedSeconds)), ...
            'realizationId',double(pilot.realizationId),'caseCount',height(pilot.cases));

    case 'data'
        metadata=runDataStage(configuration,manifest,packageFolder,outputRoot);

    case 'assemble'
        dataReport=dependencyReport(packageFolder,state,'data');
        groups=dataReport.metadata.groups;
        [resultFiles,splitManifest]=dataInputs(packageFolder,groups);
        ensureEmptyFolder(outputRoot);
        registry=packageReference(packageFolder,manifest.registry.packagePath);
        dataset=buildLoadDataset(struct('resultFiles',{resultFiles}, ...
            'splitManifest',splitManifest,'outputFolder',fullfile(outputRoot,'dataset'), ...
            'purpose','training','registryFile',registry));
        metadata=struct('datasetFolder',relativePath(packageFolder,fullfile(outputRoot,'dataset')), ...
            'datasetFile',relativePath(packageFolder,fullfile(outputRoot,'dataset','dataset.mat')), ...
            'datasetKind',dataset.manifest.kind,'rowCount',height(dataset.rowInfo));

    case 'train'
        assembly=dependencyReport(packageFolder,state,'assemble');
        ensureEmptyFolder(outputRoot);
        datasetFile=packageReference(packageFolder,assembly.metadata.datasetFile);
        options=struct('datasetFile',datasetFile,'outputFolder',fullfile(outputRoot,'selection'));
        if isfield(configuration,'trainingOptions')
            options.trainingOptions=configuration.trainingOptions;
        end
        [bundles,training]=trainLoadModels(options);
        metadata=struct('selectionFolder',relativePath(packageFolder,fullfile(outputRoot,'selection')), ...
            'datasetFile',relativePath(packageFolder,datasetFile), ...
            'modelCount',numel(bundles),'trainingStatus',textField(training,'status'));

    case 'freeze'
        trainReport=dependencyReport(packageFolder,state,'train');
        assembly=dependencyReport(packageFolder,state,'assemble');
        requiredConfiguration(configuration,{'policyFile','protocolFile','policyTuningIds'},stageName);
        policy=packageReference(packageFolder,configuration.policyFile);
        protocol=packageReference(packageFolder,configuration.protocolFile);
        registry=packageReference(packageFolder,manifest.registry.packagePath);
        ensureEmptyFolder(outputRoot);
        outputFile=fullfile(outputRoot,'model-freeze.json');
        frozen=freezeLoadModelSelection(struct('selectionFolder', ...
            packageReference(packageFolder,trainReport.metadata.selectionFolder), ...
            'datasetFile',packageReference(packageFolder,assembly.metadata.datasetFile), ...
            'policyFile',policy,'protocolFile',protocol,'registryFile',registry, ...
            'policyTuningIds',double(configuration.policyTuningIds(:).'), ...
            'outputFile',outputFile));
        metadata=struct('freezeFile',relativePath(packageFolder,outputFile), ...
            'selectedModel',char(string(frozen.selectedModel)), ...
            'evidenceKind',frozen.evidenceKind);

    case 'evaluate'
        freezeReport=dependencyReport(packageFolder,state,'freeze');
        trainReport=dependencyReport(packageFolder,state,'train');
        assembly=dependencyReport(packageFolder,state,'assemble');
        requiredConfiguration(configuration,{'policyFile','protocolFile'},stageName);
        ensureEmptyFolder(outputRoot);
        evaluation=evaluateFrozenLoadModels(struct( ...
            'freezeFile',packageReference(packageFolder,freezeReport.metadata.freezeFile), ...
            'datasetFile',packageReference(packageFolder,assembly.metadata.datasetFile), ...
            'modelFolder',packageReference(packageFolder,trainReport.metadata.selectionFolder), ...
            'protocolFile',packageReference(packageFolder,configuration.protocolFile), ...
            'policyFile',packageReference(packageFolder,configuration.policyFile), ...
            'registryFile',packageReference(packageFolder,manifest.registry.packagePath), ...
            'outputFolder',fullfile(outputRoot,'evaluation')));
        metadata=struct('evaluationFolder',relativePath(packageFolder,fullfile(outputRoot,'evaluation')), ...
            'evaluationStatus',textField(evaluation,'status'));

    case 'admit'
        requiredConfiguration(configuration,{'candidateFile'},stageName);
        if isempty(reviewFile)||~isfile(reviewFile)
            error('nbiot:externalStage:Review','A separate human review file is required.');
        end
        candidateFile=packageReference(packageFolder,configuration.candidateFile);
        ensureEmptyFolder(outputRoot);
        candidatePackageFolder=fullfile(outputRoot,'candidate-package');
        copyPortableCandidatePackage(packageFolder,candidateFile,candidatePackageFolder);
        candidateFile=fullfile(candidatePackageFolder,fileName(candidateFile));
        outputFile=fullfile(candidatePackageFolder,'model-acceptance.json');
        admission=publishModelAcceptance(struct('candidateFile',candidateFile, ...
            'reviewFile',reviewFile,'outputFile',outputFile));
        metadata=struct('modelAcceptanceStatus',admission.status, ...
            'candidatePackageFolder',relativePath(packageFolder,candidatePackageFolder), ...
            'acceptanceFile',relativePath(packageFolder,outputFile), ...
            'evidenceDigest',admission.evidenceDigest);

    case 'compare'
        requiredConfiguration(configuration,{'comparisonOptions','scenarioMatrix'},stageName);
        scenarioContract=validateExternalComparisonMatrix( ...
            configuration.scenarioMatrix,configuration.comparisonOptions);
        ensureEmptyFolder(outputRoot);
        options=configuration.comparisonOptions;
        options.outputFolder=fullfile(outputRoot,'comparison');
        if isfield(options,'designOnly')&&logical(options.designOnly)
            error('nbiot:externalStage:Compare','External comparison stage requires real execution, not a design-only plan.');
        end
        comparison=runComparisonSweep(options);
        if ~isstruct(comparison)||~isscalar(comparison)||~isfield(comparison,'status')|| ...
                ~strcmp(char(string(comparison.status)),'completed')
            error('nbiot:externalStage:CompareIncomplete', ...
                'The comparison sweep did not complete every requested case.');
        end
        metadata=struct('comparisonFolder',relativePath(packageFolder,options.outputFolder), ...
            'comparisonStatus',textField(comparison,'status'), ...
            'scenarioIdentity',scenarioIdentityDigest(scenarioContract));

    case 'summarize'
        requiredConfiguration(configuration,{'comparisonFile'},stageName);
        comparisonFile=packageReference(packageFolder,configuration.comparisonFile);
        cases=readtable(comparisonFile,'TextType','string');
        ensureEmptyFolder(outputRoot);
        summary=plotComparisonSummary(cases,fullfile(outputRoot,'summary'));
        metadata=struct('summaryFolder',relativePath(packageFolder,fullfile(outputRoot,'summary')), ...
            'methodCount',height(summary.methodSummary), ...
            'pairedComparisonCount',height(summary.pairedDifferences));
        if isfield(configuration,'evidenceManifest')
            acceptance=runFinalAcceptance(struct('projectRoot',projectRoot, ...
                'evidenceManifest',configuration.evidenceManifest, ...
                'outputFolder',fullfile(projectRoot,'verification','external','final-acceptance')));
            metadata.finalAcceptanceStatus=acceptance.status;
        end
end

files=outputFiles(outputFolder,outputRoot);
report=makeReport(stageName,'complete',inputDigest,files,metadata);
writeReport(reportPath,report);
end

function metadata=runDataStage(configuration,manifest,packageFolder,outputRoot)
requiredConfiguration(configuration,{'counts','burstDurations','groups'},'data');
counts=double(configuration.counts(:).');
bursts=double(configuration.burstDurations(:).');
if isempty(counts)||isempty(bursts)||any(counts~=fix(counts))|| ...
        any(counts<=0)||any(bursts~=fix(bursts))||any(bursts<=0)
    error('nbiot:externalStage:DataPlan','Data counts and burst durations must be positive integer vectors.');
end
groups=configuration.groups;
if ~isstruct(groups)||isempty(groups)
    error('nbiot:externalStage:DataPlan','At least one explicit data group is required.');
end
calibration=packageReference(packageFolder,manifest.calibration.packagePath);
registry=packageReference(packageFolder,manifest.registry.packagePath);
ensureEmptyFolder(outputRoot);
groupReports=repmat(struct('role','','split','','ids',[],'manifestFile',''),1,numel(groups));
for k=1:numel(groups)
    group=groups(k);
    requiredConfiguration(group,{'role','split','realizationIds'},'data group');
    role=textValue(group.role,'data role');
    split=textValue(group.split,'data split');
    ids=double(group.realizationIds(:).');
    if isempty(ids)||numel(unique(ids))~=numel(ids)||any(ids~=fix(ids))
        error('nbiot:externalStage:DataPlan','Each data group must use unique integer realization IDs.');
    end
    validateRoleSplit(role,split);
    ensureAssignedIds(manifest.idAssignments,role,ids);
    available=nbiot.experiments.availableRealizationIds(registry,role,ids);
    if numel(available)~=numel(ids)
        error('nbiot:externalStage:DataIds','A requested data ID is already used or reserved.');
    end
    cfg=nbiot.config.defaultConfig();
    cfg.simulation.numUE=max(counts);
    if isfield(configuration,'simulationConfig'),cfg=configuration.simulationConfig;end
    execution=struct('profile','external-machine','role',role, ...
        'maxUE',double(manifest.resourceBudget.maxUE), ...
        'maxCaseSeconds',double(manifest.resourceBudget.maxCaseSeconds), ...
        'maxSuiteSeconds',double(manifest.resourceBudget.maxSuiteSeconds), ...
        'timePolicy','hard-stop');
    numCases=numel(counts)*numel(bursts)*numel(ids);
    nbiot.experiments.validateExecutionBudget(cfg,execution,numCases);
    groupFolder=fullfile(outputRoot,role);
    registrySource=['external-stage-data/' role '/' char(java.util.UUID.randomUUID())];
    nbiot.experiments.registerRealizationUse(registry,role,ids,registrySource,'planned');
    try
        options=struct('counts',counts,'burstDurations',bursts, ...
            'realizationIds',ids,'calibrationFile',calibration, ...
            'outputFolder',groupFolder,'resume',false,'execution',execution,'config',cfg);
        sweep=runStaticSweep(options);
        if isempty(sweep)||any(string(sweep.status)~="completed")
            error('nbiot:externalStage:DataSweep','The static data sweep did not complete every case.');
        end
        nbiot.experiments.updateRealizationUseStatus(registry,role,ids,'completed');
    catch exception
        nbiot.experiments.updateRealizationUseStatus(registry,role,ids,'failed');
        rethrow(exception);
    end
    manifestFile=fullfile(groupFolder,'manifest.csv');
    groupReports(k)=struct('role',role,'split',split,'ids',ids, ...
        'manifestFile',relativePath(packageFolder,manifestFile));
end
metadata=struct('groups',groupReports,'counts',counts,'burstDurations',bursts);
end

function [resultFiles,splitManifest]=dataInputs(packageFolder,groups)
resultFiles={}; ids=[]; splits=strings(0,1); roles=strings(0,1);
for k=1:numel(groups)
    manifestFile=packageReference(packageFolder,groups(k).manifestFile);
    cases=readtable(manifestFile,'TextType','string');
    if ~all(ismember({'resultFile','status'},cases.Properties.VariableNames))|| ...
            any(cases.status~="completed")
        error('nbiot:externalStage:DataIncomplete','A data group contains incomplete cases.');
    end
    for j=1:height(cases)
        casePath=canonicalPath(char(cases.resultFile(j)));
        if ~isfile(casePath)||~isWithin(casePath,packageFolder)
            error('nbiot:externalStage:DataIncomplete','A completed result path is missing or outside the package.');
        end
        resultFiles{end+1,1}=casePath; %#ok<AGROW>
    end
    ids=[ids;double(groups(k).ids(:))]; %#ok<AGROW>
    splits=[splits;repmat(string(groups(k).split),numel(groups(k).ids),1)]; %#ok<AGROW>
    roles=[roles;repmat(string(groups(k).role),numel(groups(k).ids),1)]; %#ok<AGROW>
end
splitManifest=table(ids,splits,roles,'VariableNames', ...
    {'externalRealizationId','split','experimentRole'});
end

function validateRoleSplit(role,split)
allowed={ ...
    'training','train'; ...
    'validation','validation'; ...
    'model-test','test'; ...
    'final-comparison','test'};
match=find(strcmp(allowed(:,1),role),1);
if isempty(match)||~strcmp(allowed{match,2},split)
    error('nbiot:externalStage:DataPlan','Role and split must form a supported independent group.');
end
end

function ensureAssignedIds(assignments,role,ids)
if isempty(assignments)
    error('nbiot:externalStage:DataIds','The package has no explicit ID assignments.');
end
matches=[];
for k=1:numel(assignments)
    if strcmp(char(string(assignments(k).role)),role)
        matches(end+1)=double(assignments(k).externalRealizationId); %#ok<AGROW>
    end
end
if ~isequal(sort(matches),sort(ids))
    error('nbiot:externalStage:DataIds','Requested IDs must exactly match the package assignment for this role.');
end
end

function digest=scenarioIdentityDigest(contract)
bytes=unicode2native(jsonencode(contract),'UTF-8');
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(bytes,'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function id=pilotRealizationId(assignments)
matches=[];
for k=1:numel(assignments)
    if strcmp(char(string(assignments(k).role)),'stage-3-load-pilot')
        matches(end+1)=double(assignments(k).externalRealizationId); %#ok<AGROW>
    end
end
if numel(matches)~=1
    error('nbiot:externalStage:PilotIds','Exactly one pilot realization ID is required.');
end
id=matches(1);
end

function entry=findStage(state,name)
if ~isfield(state,'stages')||~isstruct(state.stages)
    error('nbiot:externalStage:State','Stage ledger is invalid.');
end
matches=find(strcmp({state.stages.name},name));
if numel(matches)~=1
    error('nbiot:externalStage:State','The requested stage is absent or duplicated.');
end
entry=state.stages(matches);
end

function report=dependencyReport(packageFolder,state,name)
entry=findStage(state,name);
if ~strcmp(entry.status,'completed')||isempty(entry.reportPath)||isempty(entry.outputDigest)
    error('nbiot:externalStage:Dependency','A completed dependency report is required.');
end
path=packageReference(packageFolder,entry.reportPath);
if ~strcmpi(nbiot.ml.fileSha256(path),entry.outputDigest)
    error('nbiot:externalStage:Dependency','A dependency output hash no longer matches.');
end
report=readJson(path,'stage report');
if ~strcmp(report.status,'complete')||~strcmp(report.stage,name)|| ...
        ~strcmp(report.inputDigest,entry.inputDigest)
    error('nbiot:externalStage:Dependency','A dependency completion marker is invalid.');
end
end

function files=outputFiles(stageRoot,outputRoot)
files=struct('path',{},'sha256',{});
if ~isfolder(outputRoot),return;end
listing=dir(fullfile(outputRoot,'**','*'));
for k=1:numel(listing)
    if listing(k).isdir,continue;end
    path=fullfile(listing(k).folder,listing(k).name);
    if ~isWithin(path,stageRoot),continue;end
    files(end+1)=struct('path',relativePath(stageRoot,path), ...
        'sha256',nbiot.ml.fileSha256(path)); %#ok<AGROW>
end
end

function report=makeReport(stage,status,digest,files,metadata)
report=struct('schemaVersion',1,'stage',stage,'status',status, ...
    'inputDigest',digest,'outputFiles',files,'metadata',metadata);
if isfield(metadata,'resourceEvidence'),report.resourceEvidence=metadata.resourceEvidence;end
if isfield(metadata,'modelAcceptanceStatus'),report.modelAcceptanceStatus=metadata.modelAcceptanceStatus;end
end

function writeReport(path,report)
folder=fileparts(path);
if ~isfolder(folder)||isfile(path)
    error('nbiot:externalStage:Output','Stage report destination is not a new file.');
end
fid=fopen(path,'w','n','UTF-8');
if fid<0,error('nbiot:externalStage:Output','Cannot create the stage report.');end
cleanup=onCleanup(@()fclose(fid));
bytes=unicode2native(jsonencode(report,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:externalStage:Output','Could not write the complete stage report.');
end
end

function path=packageReference(root,value)
value=textValue(value,'package-relative path');
if startsWith(value,{'/','\'})|| ...
        ~isempty(regexp(value,'^[A-Za-z]:|(^|[\\/])\.\.?([\\/]|$)','once'))
    error('nbiot:externalStage:Path','Paths must stay inside the portable package.');
end
path=canonicalPath(fullfile(root,strrep(value,'/',filesep)));
if ~isWithin(path,root)
    error('nbiot:externalStage:Path','Path escaped the portable package.');
end
end

function requiredConfiguration(value,required,stage)
if ~isstruct(value)||~isscalar(value)||~all(isfield(value,required))
    error('nbiot:externalStage:Configuration', ...
        'Stage %s is waiting for its explicit, reviewable configuration.',stage);
end
end

function ensureEmptyFolder(folder)
if isfolder(folder)
    listing=dir(folder);listing=listing(~ismember({listing.name},{'.','..'}));
    if ~isempty(listing)
        error('nbiot:externalStage:Output','Stage output folder must be new and empty.');
    end
else
    [ok,message]=mkdir(folder);
    if ~ok,error('nbiot:externalStage:Output','Cannot create stage output folder: %s',message);end
end
end

function copyPortableCandidatePackage(packageRoot,candidateFile,destination)
packageRoot=canonicalPath(packageRoot);
candidateFile=canonicalPath(candidateFile);
sourceRoot=canonicalPath(fileparts(candidateFile));
destination=canonicalPath(destination);
if ~isfile(candidateFile)||~isWithin(candidateFile,packageRoot)|| ...
        ~isWithin(sourceRoot,packageRoot)||~isWithin(destination,packageRoot)|| ...
        samePath(sourceRoot,destination)||isWithin(sourceRoot,destination)|| ...
        isWithin(destination,sourceRoot)
    error('nbiot:externalStage:CandidatePackage', ...
        'The candidate package source and destination must be separate folders inside the portable package.');
end
if isfile(destination)||isfolder(destination)
    error('nbiot:externalStage:CandidatePackage', ...
        'The portable candidate package destination must be new.');
end
[ok,message]=mkdir(destination);
if ~ok
    error('nbiot:externalStage:CandidatePackage', ...
        'Could not create the portable candidate package: %s',message);
end
copyCandidateFolder(sourceRoot,destination,sourceRoot,packageRoot);
copiedCandidate=fullfile(destination,fileName(candidateFile));
if ~isfile(copiedCandidate)|| ...
        ~strcmpi(nbiot.ml.fileSha256(candidateFile),nbiot.ml.fileSha256(copiedCandidate))
    error('nbiot:externalStage:CandidatePackage', ...
        'The portable candidate package copy failed candidate hash verification.');
end
end

function copyCandidateFolder(sourceFolder,destinationFolder,sourceRoot,packageRoot)
sourceFolder=canonicalPath(sourceFolder);
destinationFolder=canonicalPath(destinationFolder);
if ~isfolder(sourceFolder)||~isWithin(sourceFolder,sourceRoot)|| ...
        ~isWithin(sourceFolder,packageRoot)||~isWithin(destinationFolder,packageRoot)
    error('nbiot:externalStage:CandidatePackage', ...
        'A candidate package directory escaped its approved source or destination.');
end
entries=dir(sourceFolder);
for k=1:numel(entries)
    name=entries(k).name;
    if ismember(name,{'.','..'}),continue;end
    sourcePath=fullfile(sourceFolder,name);
    canonicalSourcePath=canonicalPath(sourcePath);
    if isSymbolicLink(sourcePath)||~isWithin(canonicalSourcePath,sourceRoot)|| ...
            ~isWithin(canonicalSourcePath,packageRoot)
        error('nbiot:externalStage:CandidatePackage', ...
            'Candidate package entries must remain regular paths inside the portable package.');
    end
    destinationPath=fullfile(destinationFolder,name);
    if isfile(destinationPath)||isfolder(destinationPath)
        error('nbiot:externalStage:CandidatePackage', ...
            'The portable candidate package copy cannot overwrite existing files.');
    end
    if entries(k).isdir
        [ok,message]=mkdir(destinationPath);
        if ~ok
            error('nbiot:externalStage:CandidatePackage', ...
                'Could not create a candidate package subfolder: %s',message);
        end
        copyCandidateFolder(sourcePath,destinationPath,sourceRoot,packageRoot);
    else
        if ~isfile(sourcePath)
            error('nbiot:externalStage:CandidatePackage', ...
                'Candidate package entries must be regular files or folders.');
        end
        [ok,message]=copyfile(sourcePath,destinationPath);
        if ~ok
            error('nbiot:externalStage:CandidatePackage', ...
                'Could not copy a candidate package file: %s',message);
        end
    end
end
end

function yes=isSymbolicLink(path)
try
    javaPath=java.io.File(path).toPath();
    yes=logical(java.nio.file.Files.isSymbolicLink(javaPath));
catch exception
    error('nbiot:externalStage:CandidatePackage', ...
        'Cannot verify candidate package path type: %s',exception.message);
end
end

function name=fileName(path)
[~,base,extension]=fileparts(path);
name=[base extension];
end

function path=canonicalPath(path)
path=char(java.io.File(path).getCanonicalPath());
end

function yes=isWithin(path,root)
path=canonicalPath(path);root=canonicalPath(root);
yes=strcmpi(path,root)||startsWith(path,[root filesep],'IgnoreCase',true);
end

function yes=samePath(first,second)
yes=strcmpi(canonicalPath(first),canonicalPath(second));
end

function value=relativePath(root,path)
root=canonicalPath(root);path=canonicalPath(path);
if ~isWithin(path,root)
    error('nbiot:externalStage:Path','Output path is outside the package.');
end
prefix=[root filesep];
if strcmpi(path,root),value='';else,value=strrep(path(numel(prefix)+1:end),filesep,'/');end
end

function value=readJson(path,label)
try,value=jsondecode(fileread(path));
catch exception,error('nbiot:externalStage:Json','Cannot read %s: %s',label,exception.message);end
if ~isstruct(value)||~isscalar(value)
    error('nbiot:externalStage:Json','%s must be one JSON object.',label);
end
end

function value=textField(input,name)
value='';
if isfield(input,name),value=char(string(input.(name)));end
end

function value=textValue(value,label)
if isstring(value)&&isscalar(value),value=char(value);end
if ~ischar(value)||~isrow(value)||isempty(strtrim(value))
    error('nbiot:externalStage:Input','%s must be non-empty scalar text.',label);
end
value=strtrim(value);
end
