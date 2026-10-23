%RUNSTAGE2REVALIDATION Rerun the failed Stage 2 IDs with the corrected receiver.
function plan=runStage2Revalidation(dryRun)
if nargin<1, dryRun=false; end
assert(isscalar(dryRun)&&(islogical(dryRun)||ismember(dryRun,[0 1])),...
    'nbiot:stage2:Revalidation','dryRun must be a scalar logical flag.');
dryRun=logical(dryRun);
projectRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(projectRoot);
setupProject();
addpath(fullfile(projectRoot,'experiments'));
addpath(fullfile(projectRoot,'verification','completion','stage-2'));
stageFolder=fullfile(projectRoot,'verification','completion','stage-2');
stamp=char(datetime('now','TimeZone','UTC','Format','yyyyMMdd-HHmmss-SSS'));
outputFolder=fullfile(stageFolder,['physical-revalidation-' stamp]);
temporaryRegistry=fullfile(stageFolder,['revalidation-registry-' stamp '.json']);
temporaryRegistryCleanup=onCleanup(@() removeTemporaryRegistry(temporaryRegistry,dryRun));
registryPath=fullfile(projectRoot,'experiments','realizationRegistry.json');
parent=jsondecode(fileread(registryPath));
collisionMask=arrayfun(@(a)strcmp(a.role,'stage-2-collision-diagnostics')&&...
    strcmp(a.status,'failed'),parent.assignments);
receiverMask=arrayfun(@(a)strcmp(a.role,'stage-2-receiver-diagnostics')&&...
    strcmp(a.status,'failed'),parent.assignments);
assert(any(collisionMask)&&any(receiverMask),...
    'nbiot:stage2:Revalidation','Failed Stage 2 collision and receiver assignments are required.');
plannedReceiverMask=arrayfun(@(a)strcmp(a.role,'stage-2-receiver-diagnostics')&&...
    strcmp(a.status,'planned'),parent.assignments);
assert(~any(plannedReceiverMask),...
    'nbiot:stage2:Revalidation','A previous receiver reservation is still planned; inspect its owner before retrying.');
oldReceiverIds=[];
for k=find(receiverMask)
    oldReceiverIds=[oldReceiverIds double(parent.assignments(k).ids(:).')]; %#ok<AGROW>
end
oldReceiverIds=sort(unique(oldReceiverIds));
assert(numel(oldReceiverIds)>=10&&mod(numel(oldReceiverIds),10)==0,...
    'nbiot:stage2:Revalidation','Failed receiver assignments must contain complete ten-ID groups.');
design=validateCollisionCapture(struct('designOnly',true));
calibrationPath=fullfile(projectRoot,'results','nprach-calibration.mat');
base=nbiot.experiments.loadCalibration(nbiot.config.defaultConfig(),calibrationPath);
matchingCollisionAssignments=[];
for assignmentIndex=find(collisionMask)
    candidateRegistry=parent;
    candidateRegistry.assignments(assignmentIndex)=[];
    writeJson(temporaryRegistry,candidateRegistry);
    expectedByCondition=cell(numel(design.conditions),1);
    for k=1:numel(design.conditions)
        expectedByCondition{k}=matchingConditionIds(base,design.conditions(k),10,temporaryRegistry);
    end
    candidateCollisionIds=sort(unique([expectedByCondition{:}]));
    assignedCollisionIds=sort(double(parent.assignments(assignmentIndex).ids(:).'));
    if isequal(candidateCollisionIds,assignedCollisionIds)
        matchingCollisionAssignments(end+1)=assignmentIndex; %#ok<AGROW>
    end
end
assert(isscalar(matchingCollisionAssignments),...
    'nbiot:stage2:Revalidation','Could not identify exactly one original failed collision assignment for paired revalidation.');
collisionAssignmentIndex=matchingCollisionAssignments(1);
oldCollisionIds=sort(double(parent.assignments(collisionAssignmentIndex).ids(:).'));
temporary=parent; temporary.assignments(collisionAssignmentIndex)=[];
writeJson(temporaryRegistry,temporary);
expectedCollisionIds=oldCollisionIds;
expectedReceiverIds=nbiot.experiments.availableRealizationIds(temporaryRegistry,...
    'stage-2-receiver-diagnostics',1000:3999);
expectedReceiverIds=setdiff(expectedReceiverIds,expectedCollisionIds,'stable');
assert(numel(expectedReceiverIds)>=10,...
    'nbiot:stage2:Revalidation','Temporary registry cannot provide ten fresh receiver IDs.');
expectedReceiverIds=sort(expectedReceiverIds(1:10));
assert(isempty(intersect(expectedReceiverIds,oldReceiverIds)),...
    'nbiot:stage2:Revalidation','Temporary registry cannot provide ten fresh receiver IDs.');
occupied=[];
for k=1:numel(parent.reservations)
    reservation=parent.reservations(k);
    if isfield(reservation,'range')
        occupied=[occupied double(reservation.range(1)):double(reservation.range(2))]; %#ok<AGROW>
    else
        occupied=[occupied double(reservation.ids(:).')]; %#ok<AGROW>
    end
end
for k=1:numel(parent.assignments)
    occupied=[occupied double(parent.assignments(k).ids(:).')]; %#ok<AGROW>
end
assert(isempty(intersect(expectedReceiverIds,occupied)),...
    'nbiot:stage2:Revalidation','Fresh receiver IDs are already assigned in the official registry.');
plan=struct('outputFolder',relativePath(projectRoot,outputFolder),...
    'collisionIds',expectedCollisionIds,'previousReceiverIds',oldReceiverIds,...
    'freshReceiverIds',expectedReceiverIds,'temporaryRegistry',relativePath(projectRoot,temporaryRegistry));
if dryRun
    fprintf('STAGE2_REVALIDATION_PREFLIGHT collisionIds=%d receiverIds=%d registryUnchanged=1\n',...
        numel(plan.collisionIds),numel(plan.freshReceiverIds));
    return
end
source=relativePath(projectRoot,outputFolder);
nbiot.experiments.registerRealizationUse(registryPath,...
    'stage-2-receiver-diagnostics',expectedReceiverIds,source,'planned');
reservationCleanup=onCleanup(@() failPlannedReceiverUse(registryPath,...
    expectedReceiverIds,source));
officialRegistrySha256BeforeRun=fileHash(registryPath);
temporaryBeforeSnapshot=[outputFolder '.official-registry-before-run.json'];
[ok,message]=copyfile(registryPath,temporaryBeforeSnapshot);
assert(ok,'nbiot:stage2:Revalidation','Could not archive pre-run registry: %s.',message);

logFile=[outputFolder '.log'];
diary(logFile); diary on; diaryCleanup=onCleanup(@()diary('off'));
fprintf('STAGE2_REVALIDATION mode=paired-rerun receiverRevision=%s oldCollisionIds=%s receiverIds=%s\n',...
    nbiot.phy.nprach.receiverRevision(),mat2str(oldCollisionIds),mat2str(expectedReceiverIds));
options=struct('repeats',10,'conditionIds',1:15,'durationTicks',1500,...
    'outputFolder',outputFolder,'runReceiverChecks',true,...
    'runInterferenceReplay',false,'registryFile',temporaryRegistry,...
    'manageRegistry',false,'calibrationFile',fullfile(projectRoot,'results',...
    'nprach-calibration.mat'));
report=validateCollisionCapture(options);
collisionIds=sort(unique(double(report.trials.realizationId(:).')));
receiverIds=sort(unique(double(report.receiverChecks.id(:).')));
assert(isequal(collisionIds,expectedCollisionIds),...
    'nbiot:stage2:Revalidation','Rerun did not use the exact failed collision realization set.');
assert(numel(receiverIds)==10&&isempty(intersect(receiverIds,oldReceiverIds))&&...
    isempty(intersect(receiverIds,collisionIds)),...
    'nbiot:stage2:Revalidation','Receiver checks must use ten fresh, disjoint IDs.');
assert(isequal(receiverIds,expectedReceiverIds),...
    'nbiot:stage2:Revalidation','Physical runner did not use the precomputed fresh receiver IDs.');
assert(strcmp(fileHash(registryPath),officialRegistrySha256BeforeRun),...
    'nbiot:stage2:Revalidation','Official registry changed while the paired physical run was active.');
nbiot.experiments.updateRealizationUseStatus(registryPath,...
    'stage-2-receiver-diagnostics',receiverIds,'completed');
officialRegistrySha256AfterRun=fileHash(registryPath);
beforeSnapshot=fullfile(outputFolder,'official-registry-before-run.json');
afterSnapshot=fullfile(outputFolder,'official-registry-after-run.json');
[ok,message]=movefile(temporaryBeforeSnapshot,beforeSnapshot);
assert(ok,'nbiot:stage2:Revalidation','Could not move pre-run registry snapshot: %s.',message);
[ok,message]=copyfile(registryPath,afterSnapshot);
assert(ok,'nbiot:stage2:Revalidation','Could not archive post-run registry: %s.',message);
report.revalidation=struct('mode','paired-rerun-after-cfo-detector-fix',...
    'collisionIdsReusedFromFailedRun',true,'collisionIds',collisionIds,...
    'previousReceiverIds',oldReceiverIds,'freshReceiverIds',receiverIds,...
    'officialRegistrySha256BeforeRun',officialRegistrySha256BeforeRun,...
    'officialRegistrySha256AfterRun',officialRegistrySha256AfterRun,...
    'officialRegistryBeforeSnapshot',relativePath(projectRoot,beforeSnapshot),...
    'officialRegistryAfterSnapshot',relativePath(projectRoot,afterSnapshot),...
    'temporaryRegistry',relativePath(projectRoot,temporaryRegistry),...
    'temporaryRegistrySha256',fileHash(temporaryRegistry),...
    'sourceManifestSha256',report.sourceManifest.sha256,...
    'artifactSourceHashes',report.artifactSourceHashes,...
    'receiverRevision',report.receiverRevision,'matlabRelease',report.matlabRelease,...
    'calibrationSha256',report.calibrationSha256);
save(fullfile(outputFolder,'report.mat'),'report','-v7');
archivedRunReport=fullfile(outputFolder,'physical-run-report.mat');
[ok,message]=movefile(fullfile(outputFolder,'report.mat'),archivedRunReport);
assert(ok,'nbiot:stage2:Revalidation','Could not archive raw run report: %s.',message);
manifest=report.revalidation; manifest.schemaVersion=1;
writeJson(fullfile(outputFolder,'revalidation-manifest.json'),manifest);
fprintf('STAGE2_REVALIDATION_DONE trials=%d receiverChecks=%d output=%s\n',...
    height(report.trials),height(report.receiverChecks),outputFolder);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'nbiot:stage2:Revalidation','Cannot write %s.',path);
cleanup=onCleanup(@()fclose(fid));
bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
assert(fwrite(fid,bytes,'uint8')==numel(bytes),...
    'nbiot:stage2:Revalidation','Could not write complete JSON file.');
end

function relative=relativePath(root,path)
root=char(java.io.File(root).getCanonicalPath());
path=char(java.io.File(path).getCanonicalPath()); prefix=[root filesep];
assert(startsWith(lower(path),lower(prefix)),...
    'nbiot:stage2:Revalidation','Evidence path must remain inside the project root.');
relative=strrep(path(numel(prefix)+1:end),filesep,'/');
end

function ids=matchingConditionIds(cfg,condition,count,registryFile)
ids=[];
candidates=nbiot.experiments.availableRealizationIds(registryFile,...
    'stage-2-collision-diagnostics',1000:3999);
for id=candidates
    sources=nbiot.randomness.RandomSources(cfg.simulation.seed,id);
    indices=zeros(1,condition.numUE);
    for ue=1:condition.numUE
        stream=sources.stream('access',0,ue,1);
        rand(stream);
        indices(ue)=floor(rand(stream)*12);
    end
    same=isscalar(unique(indices));
    if (condition.samePreamble&&same)||(~condition.samePreamble&&numel(unique(indices))==condition.numUE)
        ids(end+1)=id; %#ok<AGROW>
        if numel(ids)==count, return; end
    end
end
error('nbiot:stage2:Revalidation','Temporary registry has too few matching IDs for condition %d.',condition.id);
end

function hex=fileHash(path)
fid=fopen(path,'rb');
assert(fid>=0,'nbiot:stage2:Revalidation','Cannot read %s.',path);
cleanup=onCleanup(@()fclose(fid));
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function failPlannedReceiverUse(registryPath,ids,source)
try
    if ~isfile(registryPath), return; end
    registry=jsondecode(fileread(registryPath));
    for k=1:numel(registry.assignments)
        assignment=registry.assignments(k);
        if strcmp(assignment.role,'stage-2-receiver-diagnostics')&&...
                strcmp(assignment.source,source)&&strcmp(assignment.status,'planned')&&...
                isequal(double(assignment.ids(:).'),double(ids(:).'))
            nbiot.experiments.updateRealizationUseStatus(registryPath,...
                'stage-2-receiver-diagnostics',ids,'failed');
            fprintf('STAGE2_REVALIDATION receiver assignment marked failed after incomplete run.\n');
            return
        end
    end
catch exception
    warning('nbiot:stage2:RevalidationCleanup',...
        'Could not mark pending receiver allocation failed: %s',exception.message);
end
end

function removeTemporaryRegistry(path,enabled)
if enabled&&isfile(path), delete(path); end
end
