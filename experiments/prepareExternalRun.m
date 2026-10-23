function manifest=prepareExternalRun(options)
%PREPAREEXTERNALRUN Create a verified local handoff draft without running simulations.
required={'projectRoot','outputFolder','calibrationFile','registryFile', ...
    'caseMatrix','idAssignments'};
if ~isstruct(options)||~isscalar(options)||~all(isfield(options,required))
    error('nbiot:externalRun:Options','Missing required package options.');
end
root=canonicalPath(options.projectRoot);
if ~isfolder(root), error('nbiot:externalRun:ProjectRoot','Project root does not exist.'); end
outputFolder=resolveOutput(root,options.outputFolder);
if isfile(outputFolder)||isfolder(outputFolder)
    error('nbiot:externalRun:OutputExists','The package output folder already exists.');
end

calibration=resolveFile(root,options.calibrationFile,'Calibration');
calibrationHash=nbiot.ml.fileSha256(calibration);
if isfield(options,'expectedCalibrationSha256')&&~sameHash(calibrationHash,options.expectedCalibrationSha256)
    error('nbiot:externalRun:CalibrationHash','Calibration hash does not match the declared value.');
end
registryFile=resolveFile(root,options.registryFile,'Registry');
registry=jsondecode(fileread(registryFile));
validateRegistry(registry);
validateCaseMatrix(options.caseMatrix);
ids=validateAssignments(options.idAssignments,registry);

methods=string(options.caseMatrix.method);
adaptive=any(ismember(methods,["Adaptive-P","Adaptive-RA/DT"]));
model=struct('included',false,'path','','sha256','','packagePath', ...
    '','sidecarPath','','sidecarSha256','','sidecarPackagePath','');
modelFile='';
modelSidecarFile='';
acceptanceFile=''; acceptance=struct(); evidenceRefs=emptyEvidenceRefs();
if isfield(options,'modelAcceptanceFile')&&~isempty(options.modelAcceptanceFile)
    acceptanceFile=resolveFile(root,options.modelAcceptanceFile,'ModelAcceptance');
    [acceptance,evidenceRefs]=readAcceptanceReferences(root,acceptanceFile);
end
if isfield(options,'modelFile')&&~isempty(options.modelFile)
    modelFile=resolveFile(root,options.modelFile,'Model');
elseif ~isempty(acceptanceFile)
    modelFile=acceptanceModelPath(root,acceptanceFile,acceptance);
end
if isempty(modelFile)&&adaptive
    error('nbiot:externalRun:Model','Adaptive scenarios require an explicit model package.');
end
if ~isempty(modelFile)
    modelHash=nbiot.ml.fileSha256(modelFile);
    if isfield(options,'expectedModelSha256')&&~sameHash(modelHash,options.expectedModelSha256)
        error('nbiot:externalRun:ModelHash','Model hash does not match the declared value.');
    end
    modelSidecarFile=modelSidecar(modelFile,modelHash);
    modelRel=relative(root,modelFile);
    sidecarRel=relative(root,modelSidecarFile);
    if ~isempty(acceptanceFile)
        acceptedModel=acceptanceModelPath(root,acceptanceFile,acceptance);
        if ~strcmpi(modelFile,acceptedModel)
            error('nbiot:externalRun:ModelAcceptance', ...
                'The selected model does not match the model referenced by acceptance.');
        end
    end
    model=struct('included',true,'path',modelRel,'sha256',modelHash, ...
        'packagePath',['project/' modelRel], ...
        'sidecarPath',sidecarRel, ...
        'sidecarSha256',nbiot.ml.fileSha256(modelSidecarFile), ...
        'sidecarPackagePath',['project/' sidecarRel]);
end
if ~isempty(acceptanceFile)
    validateAcceptanceModelBinding(root,acceptanceFile,acceptance,modelFile,modelSidecarFile);
end
resumeCase='';
if isfield(options,'resumePath')&&~isempty(options.resumePath)
    resumeCase=validateResume(root,options.resumePath);
end

files=sourceFiles(root,registryFile);
preserveFiles={relative(root,calibration),relative(root,registryFile)};
if ~isempty(modelFile), preserveFiles=[preserveFiles,{model.path,model.sidecarPath}]; end
if ~isempty(acceptanceFile)
    preserveFiles{end+1}=relative(root,acceptanceFile); %#ok<AGROW>
    preserveFiles=[preserveFiles,{evidenceRefs.path}];
end
staging=fullfile(fileparts(outputFolder), ...
    ['.package-staging-' char(java.util.UUID.randomUUID())]);
[ok,message]=mkdir(staging);
if ~ok, error('nbiot:externalRun:Write','Could not create staging folder: %s',message); end
cleanup=onCleanup(@() removeStaging(staging));
entries=repmat(struct('path','','sha256','','packagePath','', ...
    'packageSha256','','sanitized',false),0,1);
for k=1:numel(files)
    rel=files{k}; source=fullfile(root,strrep(rel,'/',filesep));
    destination=fullfile(staging,'project',strrep(rel,'/',filesep));
    parent=fileparts(destination);
    if ~isfolder(parent), mkdir(parent); end
    [~,~,ext]=fileparts(source); sanitized=false;
    if isText(ext)&&~isCode(ext)&&~any(strcmpi(rel,preserveFiles))
        [contents,sanitized]=sanitize(fileread(source),root);
        writeText(destination,contents);
    else
        [ok,message]=copyfile(source,destination);
        if ~ok, error('nbiot:externalRun:Copy','Could not copy %s: %s',rel,message); end
    end
    entries(end+1)=struct('path',rel,'sha256',nbiot.ml.fileSha256(source), ...
        'packagePath',['project/' rel], ...
        'packageSha256',nbiot.ml.fileSha256(destination),'sanitized',sanitized); %#ok<AGROW>
end

calibrationRel=relative(root,calibration);
calibrationPackagePath=['project/' calibrationRel];
copyArtifact(calibration,fullfile(staging,strrep(calibrationPackagePath,'/',filesep)));
registryRel=relative(root,registryFile);
registryPackagePath=['project/' registryRel];
copyArtifact(registryFile,fullfile(staging,strrep(registryPackagePath,'/',filesep)));
if model.included
    copyArtifact(modelFile,fullfile(staging,strrep(model.packagePath,'/',filesep)));
    copyArtifact(modelSidecarFile,fullfile(staging,strrep(model.sidecarPackagePath,'/',filesep)));
end
evidenceEntries=emptyEvidenceEntries();
modelAcceptance=struct('included',false,'path','','sha256','','packagePath', ...
    '','packageSha256','','status','','evidenceKind','','references',evidenceEntries);
if ~isempty(acceptanceFile)
    acceptanceRel=relative(root,acceptanceFile);
    acceptancePackagePath=['project/' acceptanceRel];
    copyArtifact(acceptanceFile,fullfile(staging,strrep(acceptancePackagePath,'/',filesep)));
    modelAcceptance=struct('included',true,'path',acceptanceRel, ...
        'sha256',nbiot.ml.fileSha256(acceptanceFile), ...
        'packagePath',acceptancePackagePath, ...
        'packageSha256',nbiot.ml.fileSha256(fullfile(staging,strrep(acceptancePackagePath,'/',filesep))), ...
        'status',textField(acceptance,'status'), ...
        'evidenceKind',textField(acceptance,'evidenceKind'), ...
        'references',evidenceEntries);
    evidenceEntries=repmat(struct('name','','path','','sha256','', ...
        'packagePath','','packageSha256',''),numel(evidenceRefs),1);
    for k=1:numel(evidenceRefs)
        packagePath=['project/' evidenceRefs(k).path];
        source=evidenceRefs(k).source;
        destination=fullfile(staging,strrep(packagePath,'/',filesep));
        copyArtifact(source,destination);
        evidenceEntries(k)=struct('name',evidenceRefs(k).name, ...
            'path',evidenceRefs(k).path,'sha256',evidenceRefs(k).sha256, ...
            'packagePath',packagePath, ...
            'packageSha256',nbiot.ml.fileSha256(destination));
    end
    modelAcceptance.references=evidenceEntries;
end
if isempty(ids)
    idRows=struct('externalRealizationId',{},'role',{});
else
    idRows=table2struct(ids);
end
resourceBudget=struct(); resourceStatus='not-specified';
if isfield(options,'resourceBudget')
    [resourceBudget,resourceStatus]=validateResourceBudget(options.resourceBudget);
end
created=datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''');
manifest=struct('schemaVersion',1,'createdAtUtc',char(created), ...
    'status','draft-needs-external-review','readyForExecution',false, ...
    'projectRevision','working-tree-snapshot','matlabRelease',version('-release'), ...
    'codeFiles',entries,'codeManifestSha256',sha256Text(jsonencode(entries)), ...
    'calibration',struct('path',calibrationRel,'sha256',calibrationHash, ...
        'packagePath',calibrationPackagePath), ...
    'model',model,'caseMatrix',table2struct(options.caseMatrix), ...
    'idAssignments',idRows,'registry',struct( ...
        'path',relative(root,registryFile),'sha256',nbiot.ml.fileSha256(registryFile), ...
        'packagePath',registryPackagePath, ...
        'writerPolicy','External machine must be the only writer; this package does not reserve IDs.'), ...
    'modelAcceptance',modelAcceptance,'evidenceFiles',evidenceEntries, ...
    'resourceBudget',resourceBudget,'resourceStatus',resourceStatus, ...
    'resumeCase',resumeCase,'requiresStage2Revalidation',true, ...
    'resumePolicy','Reuse only verifyCase-passing completed cases; .staging folders are not checkpoints.', ...
    'exclusions',{{'verification/local outputs and logs; only the approved process-runner source files are included', ...
        'verification/completion evidence and previous run outputs; only Stage 2 source files and the approved Stage 2/3 wrappers are included', ...
        'results except named artifacts', ...
        '.git','.env files','credentials and private keys'}}, ...
    'expectedCommands',{{'setupProject();', ...
        'Unpack the draft and run verification/external/validateExternalPreflight.m against its package root.', ...
        'This draft does not authorize experiment stages; use the separately approved external-stage workflow after its gates are met.'}});
writeText(fullfile(staging,'manifest.json'),jsonencode(manifest));
if hasExternalStageWorkflow(root)
    writeExternalStageWorkflow(staging,root,manifest,options);
end
[ok,message]=movefile(staging,outputFolder);
if ~ok, error('nbiot:externalRun:Write','Could not finalize the handoff folder: %s',message); end
clear cleanup
end

function path=resolveOutput(root,value)
if ~(ischar(value)||(isstring(value)&&isscalar(value)))
    error('nbiot:externalRun:OutputPath','Output folder must be text.');
end
value=char(value);
if isAbsolute(value), path=canonicalPath(value); else, path=canonicalPath(fullfile(root,value)); end
external=canonicalPath(fullfile(root,'verification','external'));
if ~isWithin(external,path)||strcmpi(external,path)
    error('nbiot:externalRun:OutputPath','Output must be under verification/external.');
end
end

function path=resolveFile(root,value,kind)
identifier=['nbiot:externalRun:' kind];
if ~(ischar(value)||(isstring(value)&&isscalar(value)))
    error(identifier,'%s path must be project-relative text.',kind);
end
value=char(value);
if isAbsolute(value)||contains(value,'..')||contains(value,':')
    error(identifier,'%s path must be project-relative.',kind);
end
path=canonicalPath(fullfile(root,strrep(value,'/',filesep)));
if ~isWithin(root,path)||~isfile(path), error(identifier,'%s file is missing or outside the project.',kind); end
end

function [acceptance,refs]=readAcceptanceReferences(root,acceptanceFile)
try
    acceptance=jsondecode(fileread(acceptanceFile));
catch exception
    error('nbiot:externalRun:ModelAcceptance', ...
        'Model acceptance file is not valid JSON: %s',exception.message);
end
required={'schemaVersion','status','evidenceKind','model','modelSidecar', ...
    'dataset','datasetManifest','datasetArtifacts','trainingManifest','metrics', ...
    'sourceManifest','calibration','registry','policy','protocol','evaluation'};
if ~isstruct(acceptance)||~isscalar(acceptance)||~all(isfield(acceptance,required))|| ...
        ~strcmp(textField(acceptance,'schemaVersion'),'model-acceptance-v1')
    error('nbiot:externalRun:ModelAcceptance', ...
        'Acceptance must use the complete model-acceptance-v1 evidence schema.');
end
if ~ismember(textField(acceptance,'status'),{'candidate','accepted','rejected'})
    error('nbiot:externalRun:ModelAcceptance','Acceptance status is unsupported.');
end
refs=collectAcceptanceRefs(acceptance,'');
requiredNames=required(4:end);
if ~all(ismember(requiredNames,{refs.name}))
    error('nbiot:externalRun:ModelAcceptance', ...
        'Acceptance is missing a required D2/D4 evidence reference.');
end
acceptanceFolder=fileparts(acceptanceFile);
for k=1:numel(refs)
    value=refs(k).path;
    if isAbsolute(value)||contains(value,':')|| ...
            any(strcmp(split(strrep(value,'\','/'),'/'),'..'))
        error('nbiot:externalRun:ModelAcceptance', ...
            'An acceptance reference is not a package-relative path.');
    end
    source=canonicalPath(fullfile(acceptanceFolder,strrep(value,'/',filesep)));
    if ~isWithin(root,source)||~isfile(source)
        error('nbiot:externalRun:ModelAcceptance', ...
            'Required acceptance evidence is missing or outside the project: %s.',refs(k).name);
    end
    if ~sameHash(nbiot.ml.fileSha256(source),refs(k).sha256)
        error('nbiot:externalRun:ModelAcceptance', ...
            'Required acceptance evidence checksum differs: %s.',refs(k).name);
    end
    refs(k).path=relative(root,source);
    refs(k).source=source;
end
end

function refs=collectAcceptanceRefs(value,prefix)
refs=emptyEvidenceRefs();
if isstruct(value)&&isscalar(value)&&all(isfield(value,{'file','sha256'}))
    name=prefix;
    if isempty(name), name='reference'; end
    file=textValue(value.file,'acceptance reference file');
    hash=textValue(value.sha256,'acceptance reference hash');
    refs=struct('name',name,'path',file,'sha256',hash,'source','');
elseif isstruct(value)
    fields=fieldnames(value);
    for k=1:numel(fields)
        child=value.(fields{k});
        childPrefix=fields{k};
        if ~isempty(prefix), childPrefix=[prefix '.' childPrefix]; end
        nested=collectAcceptanceRefs(child,childPrefix);
        refs=[refs;nested(:)]; %#ok<AGROW>
    end
elseif iscell(value)
    for k=1:numel(value)
        nested=collectAcceptanceRefs(value{k},prefix);
        refs=[refs;nested(:)]; %#ok<AGROW>
    end
end
end

function path=acceptanceModelPath(root,acceptanceFile,acceptance)
if ~isfield(acceptance,'model')||~isstruct(acceptance.model)|| ...
        ~all(isfield(acceptance.model,{'file','sha256'}))
    error('nbiot:externalRun:ModelAcceptance','Acceptance has no model file reference.');
end
value=textValue(acceptance.model.file,'acceptance model file');
if isAbsolute(value)||contains(value,':')|| ...
        any(strcmp(split(strrep(value,'\','/'),'/'),'..'))
    error('nbiot:externalRun:ModelAcceptance','Acceptance model reference is not relative.');
end
path=canonicalPath(fullfile(fileparts(acceptanceFile),strrep(value,'/',filesep)));
if ~isWithin(root,path)||~isfile(path)
    error('nbiot:externalRun:ModelAcceptance','Acceptance model file is missing or outside the project.');
end
end

function path=modelSidecar(modelFile,modelHash)
[folder,base,extension]=fileparts(modelFile);
if ~strcmpi(extension,'.mat')
    error('nbiot:externalRun:ModelBundle','Adaptive model must be a MAT file.');
end
path=fullfile(folder,[base '.json']);
if ~isfile(path)
    error('nbiot:externalRun:ModelBundle', ...
        'Model MAT requires its same-name JSON sidecar.');
end
try
    sidecar=jsondecode(fileread(path));
catch exception
    error('nbiot:externalRun:ModelBundle', ...
        'Model JSON sidecar is not valid JSON: %s',exception.message);
end
if ~isstruct(sidecar)||~isscalar(sidecar)|| ...
        ~all(isfield(sidecar,{'artifactFile','artifactSha256'}))|| ...
        ~strcmp(textValue(sidecar.artifactFile,'sidecar artifactFile'),[base extension])|| ...
        ~sameHash(modelHash,sidecar.artifactSha256)
    error('nbiot:externalRun:ModelBundle', ...
        'Model sidecar must name and hash the selected MAT file.');
end
end

function validateAcceptanceModelBinding(root,acceptanceFile,acceptance,modelFile,sidecarFile)
acceptedModel=acceptanceModelPath(root,acceptanceFile,acceptance);
if isempty(modelFile)||~strcmpi(modelFile,acceptedModel)
    error('nbiot:externalRun:ModelAcceptance', ...
        'The selected model does not match the model referenced by acceptance.');
end
if ~isfield(acceptance,'modelSidecar')|| ...
        ~isstruct(acceptance.modelSidecar)||~isfield(acceptance.modelSidecar,'file')
    error('nbiot:externalRun:ModelAcceptance','Acceptance has no model sidecar reference.');
end
value=textValue(acceptance.modelSidecar.file,'acceptance model sidecar file');
acceptedSidecar=canonicalPath(fullfile(fileparts(acceptanceFile),strrep(value,'/',filesep)));
if ~isWithin(root,acceptedSidecar)||~strcmpi(acceptedSidecar,sidecarFile)
    error('nbiot:externalRun:ModelAcceptance', ...
        'The selected model sidecar does not match acceptance.');
end
end

function value=textField(item,name)
if ~isfield(item,name), error('nbiot:externalRun:ModelAcceptance','Acceptance field is missing: %s.',name); end
value=textValue(item.(name),name);
end

function value=textValue(value,name)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1||isempty(value)
    error('nbiot:externalRun:ModelAcceptance','%s must be nonempty scalar text.',name);
end
end

function refs=emptyEvidenceRefs()
refs=repmat(struct('name','','path','','sha256','','source',''),0,1);
end

function entries=emptyEvidenceEntries()
entries=repmat(struct('name','','path','','sha256','','packagePath','', ...
    'packageSha256',''),0,1);
end

function validateCaseMatrix(value)
required={'method','numUE','durationTicks','trafficKind','burstDurationTicks'};
if ~istable(value)||isempty(value)||numel(value.Properties.VariableNames)~=numel(required)|| ...
        ~all(ismember(required,value.Properties.VariableNames))
    error('nbiot:externalRun:CaseMatrix', ...
        'Case matrix columns must match the supported fields exactly.');
end
if any(~ismember(string(value.method),["Static","Adaptive-P","Adaptive-RA/DT"]))|| ...
        any(~ismember(string(value.trafficKind),["burst","periodic","poisson","none"]))
    error('nbiot:externalRun:CaseMatrix','Unsupported method or traffic type.');
end
for name={'numUE','durationTicks','burstDurationTicks'}
    values=value.(name{1});
    if ~isnumeric(values)||~isreal(values)||~iscolumn(values)||any(~isfinite(values))|| ...
            any(values<0)||any(values~=fix(values))
        error('nbiot:externalRun:CaseMatrix','Case matrix values must be nonnegative integers.');
    end
end
if any(value.numUE<1)||any(value.durationTicks<1)||any(value.burstDurationTicks>value.durationTicks)
    error('nbiot:externalRun:CaseMatrix','UE count and horizon must be positive; burst must fit the horizon.');
end
end

function ids=validateAssignments(value,registry)
if ~istable(value)||~all(ismember({'externalRealizationId','role'},value.Properties.VariableNames))
    error('nbiot:externalRun:Assignments','ID assignments need externalRealizationId and role columns.');
end
numbers=value.externalRealizationId; roles=string(value.role);
if ~isnumeric(numbers)||~iscolumn(numbers)||any(~isfinite(numbers)|numbers<0|numbers>4095|numbers~=fix(numbers))|| ...
        numel(unique(numbers))~=numel(numbers)
    error('nbiot:externalRun:DuplicateId','Assigned IDs must be unique integers in 0:4095.');
end
if any(~ismember(roles,string(registry.roles)))
    error('nbiot:externalRun:Role','An assigned role is absent from the registry.');
end
if any(ismember(numbers,registryIds(registry)))
    error('nbiot:externalRun:AllocatedId','An assigned ID is reserved or already used.');
end
ids=table(double(numbers),roles,'VariableNames',{'externalRealizationId','role'});
end

function validateRegistry(registry)
if ~isstruct(registry)||~isscalar(registry)|| ...
        ~all(isfield(registry,{'schemaVersion','roles','reservations','assignments'}))
    error('nbiot:externalRun:Registry','The realization registry is invalid.');
end
end

function ids=registryIds(registry)
ids=zeros(0,1);
for k=1:numel(registry.reservations)
    range=double(registry.reservations(k).range(:).');
    if numel(range)==2&&all(isfinite(range))&&range(1)<=range(2)
        ids=[ids;(range(1):range(2)).']; %#ok<AGROW>
    end
end
for k=1:numel(registry.assignments)
    if isfield(registry.assignments(k),'ids')&&~isempty(registry.assignments(k).ids)
        ids=[ids;double(registry.assignments(k).ids(:))]; %#ok<AGROW>
    end
end
ids=unique(ids);
end

function [budget,status]=validateResourceBudget(value)
allowed={'targetMachine','availableMemoryBytes','maxUE','maxCaseSeconds', ...
    'maxSuiteSeconds','maxProcesses'};
if ~isstruct(value)||~isscalar(value)
    error('nbiot:externalRun:ResourceBudget','Resource budget must be a scalar structure.');
end
fields=fieldnames(value);
if any(~ismember(fields,allowed))
    error('nbiot:externalRun:ResourceBudget', ...
        'Resource budget contains unsupported fields.');
end
budget=struct();
for k=1:numel(fields)
    name=fields{k}; item=value.(name);
    if strcmp(name,'targetMachine')
        if isstring(item)&&isscalar(item), item=char(item); end
        if ~ischar(item)||~isrow(item)
            error('nbiot:externalRun:ResourceBudget', ...
                'targetMachine must be a short plain-text label.');
        end
        item=strtrim(item);
        if isempty(item)||numel(item)>64||contains(item,'/')||contains(item,'\')|| ...
                contains(item,':')||contains(item,'..')||any(ismember(item,[newline char(13)]))
            error('nbiot:externalRun:ResourceBudget', ...
                'targetMachine must be a label, not a path.');
        end
        budget.(name)=item;
    else
        if ~isnumeric(item)||~isscalar(item)||~isfinite(item)||item<=0|| ...
                (ismember(name,{'availableMemoryBytes','maxUE','maxProcesses'})&&item~=fix(item))
            error('nbiot:externalRun:ResourceBudget', ...
                '%s must be a positive finite numeric limit.',name);
        end
        budget.(name)=double(item);
    end
end
status='provided-but-requires-target-review';
end

function path=validateResume(root,value)
if ~(ischar(value)||(isstring(value)&&isscalar(value)))
    error('nbiot:externalRun:Resume','Resume path must be project-relative.');
end
value=char(value);
if isAbsolute(value)||contains(value,'..')||contains(value,':')||contains(lower(value),'.staging')
    error('nbiot:externalRun:Resume','An interrupted .staging folder is not a checkpoint.');
end
folder=canonicalPath(fullfile(root,strrep(value,'/',filesep)));
if ~isWithin(root,folder)||~isfolder(folder)||~isfile(fullfile(folder,'case-complete.json'))
    error('nbiot:externalRun:Resume','Only a manifested completed case may be reused.');
end
report=nbiot.results.verifyCase(folder);
if ~report.passed||~strcmp(report.status,'completed')
    error('nbiot:externalRun:Resume','The case did not pass verifyCase as completed.');
end
path=value;
end

function files=sourceFiles(root,registryFile)
registryRelative=relative(root,registryFile);
requiredExternalSources={ ...
    'verification/external/validateExternalPreflight.m', ...
    'src/+nbiot/+ml/fileSha256.m'};
for k=1:numel(requiredExternalSources)
    source=fullfile(root,strrep(requiredExternalSources{k},'/',filesep));
    if ~isfile(source)
        error('nbiot:externalRun:PreflightSource', ...
            'Required portable preflight source is missing: %s.',requiredExternalSources{k});
    end
end
stageWorkflowSources={ ...
    'verification/external/runExternalStages.ps1', ...
    'verification/external/testExternalStages.ps1', ...
    'verification/external/external-stages.schema.json', ...
    'verification/external/runExternalStage.m', ...
    'verification/external/validateExternalComparisonMatrix.m', ...
    'docs/external-runbook.md'};
stageFlags=cellfun(@(item)isfile(fullfile(root,strrep(item,'/',filesep))), ...
    stageWorkflowSources);
boundedProcessSources={ ...
    'verification/local/InvokeBoundedProcess.ps1', ...
    'verification/local/OwnedProcessJob.cs'};
hasBoundedProcessSources=cellfun(@(item)isfile(fullfile(root, ...
    strrep(item,'/',filesep))),boundedProcessSources);
if any(stageFlags)&&(~all(stageFlags)||~all(hasBoundedProcessSources))
    error('nbiot:externalRun:StageWorkflow', ...
        ['The external-stage workflow is incomplete; include the runner, tests, schema, ' ...
        'dispatcher, comparison matrix validator, bounded process supervisor and its ' ...
        'OwnedProcessJob source, and runbook together.']);
end
folders={'apps','configs','docs','examples','experiments','src','tests'};
files={'README.md','setupProject.m'};
if isfile(fullfile(root,'AGENTS.md')), files{end+1}='AGENTS.md'; end
if isfile(fullfile(root,'RELEASE.md')), files{end+1}='RELEASE.md'; end
for k=1:numel(folders)
    folder=fullfile(root,folders{k});
    if ~isfolder(folder), continue; end
    listing=dir(fullfile(folder,'**','*'));
    for j=1:numel(listing)
        if listing(j).isdir, continue; end
        full=fullfile(listing(j).folder,listing(j).name);
        [~,~,ext]=fileparts(full);
        if ~ismember(lower(ext),{'.m','.md','.json','.txt'}), continue; end
        rel=relative(root,full);
        if ~isUnsafe(rel)&&~strcmpi(rel,registryRelative)
            files{end+1}=rel; %#ok<AGROW>
        end
    end
end
stage2Folder=fullfile(root,'verification','completion','stage-2');
stage2Sources=dir(fullfile(stage2Folder,'*.m'));
for k=1:numel(stage2Sources)
    if ~stage2Sources(k).isdir
        files{end+1}=relative(root,fullfile(stage2Sources(k).folder, ...
            stage2Sources(k).name)); %#ok<AGROW>
    end
end
runnerSources={ ...
    'verification/completion/stage-2/runStage2Physical.ps1', ...
    'verification/completion/stage-3/runVariant2.ps1', ...
    'verification/completion/stage-3/runLoadPilot.ps1', ...
    'verification/local/InvokeScheduledProcess.ps1', ...
    'verification/local/InvokeBoundedProcess.ps1', ...
    'verification/external/validateExternalPreflight.m', ...
    'verification/local/OwnedProcessJob.cs'};
if all(stageFlags), runnerSources=[runnerSources,stageWorkflowSources(1:5)]; end
for k=1:numel(runnerSources)
    if isfile(fullfile(root,strrep(runnerSources{k},'/',filesep)))
        files{end+1}=runnerSources{k}; %#ok<AGROW>
    end
end
files=sort(unique(files));
end

function yes=hasExternalStageWorkflow(root)
paths={ ...
    'verification/external/runExternalStages.ps1', ...
    'verification/external/testExternalStages.ps1', ...
    'verification/external/external-stages.schema.json', ...
    'verification/external/runExternalStage.m', ...
    'verification/external/validateExternalComparisonMatrix.m', ...
    'docs/external-runbook.md'};
flags=cellfun(@(item)isfile(fullfile(root,strrep(item,'/',filesep))),paths);
hasBoundedProcessSource=isfile(fullfile(root,'verification','local', ...
    'InvokeBoundedProcess.ps1'));
hasOwnedProcessJob=isfile(fullfile(root,'verification','local', ...
    'OwnedProcessJob.cs'));
if any(flags)&&(~all(flags)||~hasBoundedProcessSource||~hasOwnedProcessJob)
    error('nbiot:externalRun:StageWorkflow', ...
        ['The external-stage workflow is incomplete; include the runner, tests, schema, ' ...
        'dispatcher, bounded process supervisor and its OwnedProcessJob source, and runbook together.']);
end
yes=all(flags);
end

function writeExternalStageWorkflow(staging,root,manifest,options)
names={'validate','pilot','data','assemble','train','freeze','evaluate', ...
    'admit','compare','summarize'};
dependencies={ {},{'validate'},{'pilot'},{'data'},{'assemble'}, ...
    {'train'},{'freeze'},{'evaluate'},{'admit'},{'compare'} };
template=struct('name','','dependencies',{{}},'command',struct(), ...
    'inputs',struct([]),'outputs',struct([]),'executionBudget',struct(), ...
    'requiredDecision','','configuration',struct(),'status','not-started','inputDigest','', ...
    'outputDigest','','reportPath','','registryInputDigest','','worker',[]);
stages=repmat(template,1,numel(names));
manifestPath=fullfile(staging,'manifest.json');
manifestHash=nbiot.ml.fileSha256(manifestPath);
if isfield(options,'stageOptions')
    if ~isstruct(options.stageOptions)||~isscalar(options.stageOptions)|| ...
            ~all(ismember(fieldnames(options.stageOptions),names))
        error('nbiot:externalRun:StageOptions', ...
            'stageOptions must be a scalar structure with only supported stage names.');
    end
else
    options.stageOptions=struct();
end
for k=1:numel(names)
    name=names{k};
    arguments={'-batch',sprintf("report=runExternalStage(pwd,'%s');",name)};
    decision='';
    if strcmp(name,'validate'), decision='stage-2-technical-review'; end
    if strcmp(name,'pilot'), decision='professor-approval-for-5000-UE-load-pilot'; end
    if strcmp(name,'admit'), decision='model-acceptance-review'; end
    configuration=struct();
    if isfield(options.stageOptions,name)
        configuration=options.stageOptions.(name);
        if ~isstruct(configuration)||~isscalar(configuration)
            error('nbiot:externalRun:StageOptions', ...
                'Each stage configuration must be a scalar structure.');
        end
        try, configuration=jsondecode(jsonencode(configuration));
        catch exception
            error('nbiot:externalRun:StageOptions', ...
                'Stage configuration is not portable JSON: %s',exception.message);
        end
        encoded=jsonencode(configuration);
        if contains(encoded,root)||~isempty(regexp(encoded,'(?i)[A-Z]:[\\/]|\\\\','once'))
            error('nbiot:externalRun:StageOptions', ...
                'Stage configuration must use package-relative paths only.');
        end
    end
    stages(k)=struct('name',name,'dependencies',{dependencies{k}}, ...
        'command',struct('executable','matlab','arguments',{arguments}), ...
        'inputs',{{struct('path','manifest.json','sha256',manifestHash)}}, ...
        'outputs',struct([]),'executionBudget',manifest.resourceBudget, ...
        'requiredDecision',decision,'configuration',configuration, ...
        'status','not-started','inputDigest','', ...
        'outputDigest','','reportPath','','registryInputDigest','','worker',[]);
end
digest=manifest.codeManifestSha256;
runId=['run-' digest(1:16)];
state=struct('schemaVersion',1,'runId',runId,'packageDigest',digest, ...
    'registryDigest',manifest.registry.sha256, ...
    'updatedAtUtc',char(datetime('now','TimeZone','UTC', ...
    'Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z''')),'stages',stages);
writeText(fullfile(staging,'stages.json'),jsonencode(state));
packageRunbook=fullfile(staging,'project','docs','external-runbook.md');
writeText(fullfile(staging,'external-runbook.md'),fileread(packageRunbook));
end

function yes=isUnsafe(value)
value=lower(strrep(value,'\','/'));
blocked={'.env','secret','credential','password','token','private-key','.pem','.pfx','.key'};
yes=any(cellfun(@(part)contains(value,part),blocked));
end

function yes=isText(extension)
yes=ismember(lower(extension),{'.m','.md','.json','.txt','.ps1','.cs'});
end

function yes=isCode(extension)
yes=ismember(lower(extension),{'.m','.ps1','.cs'});
end

function [value,changed]=sanitize(value,root)
original=value;
value=strrep(value,root,'<PROJECT_ROOT>');
value=strrep(value,strrep(root,'\','/'),'<PROJECT_ROOT>');
value=strrep(value,strrep(root,'/','\'),'<PROJECT_ROOT>');
value=regexprep(value, ...
    '(?i)(?<![A-Za-z0-9_])[A-Z]:(?:[\\/]{1,2})(?:[^\\/\r\n"<>|?*`]+[\\/]{1,2})*[^\\/\r\n"<>|?*`]*', ...
    '<LOCAL_PATH>');
changed=~strcmp(value,original);
end

function copyArtifact(source,destination)
parent=fileparts(destination);
if ~isfolder(parent), mkdir(parent); end
if isfile(destination)
    if strcmpi(nbiot.ml.fileSha256(source),nbiot.ml.fileSha256(destination)), return; end
    error('nbiot:externalRun:Copy','A different package file already occupies the referenced path.');
end
[ok,message]=copyfile(source,destination);
if ~ok, error('nbiot:externalRun:Copy','Could not copy an artifact: %s',message); end
end

function removeStaging(path)
if isfolder(path), rmdir(path,'s'); end
end

function writeText(path,value)
parent=fileparts(path);
if ~isfolder(parent), mkdir(parent); end
fid=fopen(path,'w','n','UTF-8');
if fid<0, error('nbiot:externalRun:Write','Could not write a package file.'); end
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function yes=sameHash(actual,expected)
yes=(ischar(expected)||(isstring(expected)&&isscalar(expected)))&&strcmpi(actual,char(expected));
end

function value=relative(root,path)
root=canonicalPath(root); path=canonicalPath(path);
if ~isWithin(root,path)||strcmpi(root,path)
    error('nbiot:externalRun:Path','A package file is outside projectRoot.');
end
value=strrep(path(length(root)+2:end),filesep,'/');
end

function yes=isWithin(root,path)
root=[lower(stripTrailing(root)) filesep];
yes=startsWith(lower(path),root);
end

function value=stripTrailing(value)
while numel(value)>3&&any(value(end)==['\','/']), value(end)=[]; end
end

function path=canonicalPath(value)
if ~(ischar(value)||(isstring(value)&&isscalar(value)))
    error('nbiot:externalRun:Path','Paths must be scalar text.');
end
path=char(java.io.File(char(value)).getCanonicalPath());
end

function yes=isAbsolute(value)
yes=~isempty(regexp(value,'^(?:[A-Za-z]:[\\/]|\\\\|/)', 'once'));
end

function digest=sha256Text(value)
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(uint8(unicode2native(value,'UTF-8')),'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
