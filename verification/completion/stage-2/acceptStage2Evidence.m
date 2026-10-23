function acceptance=acceptStage2Evidence(targetedLog,physicalReportPath,technicalReview)
%ACCEPTSTAGE2EVIDENCE Record technically reviewed MATLAB evidence before Stage 3.
root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(root); setupProject();
addpath(fullfile(root,'verification','completion','stage-2'));
technicalReview=validateTechnicalReview(technicalReview);
if ~isfile(targetedLog)||~isfile(physicalReportPath)
    error('nbiot:stage2:Evidence','Targeted test log and physical report must both exist.');
end
logText=fileread(targetedLog);
if isempty(regexp(logText,'(?m)^MATLAB_VERSION=.*RELEASE=2025b(?:\s|$)','once'))||...
        isempty(regexp(logText,'(?m)^LTE_TOOLBOX version=.+$','once'))
    error('nbiot:stage2:Evidence','Targeted log must identify MATLAB R2025b and LTE Toolbox.');
end
if isempty(regexp(logText,'STAGE2_TARGETED total=38 passed=38 failed=0 incomplete=0','once'))
    error('nbiot:stage2:Evidence','Targeted log does not record all 38 Stage 2/receiver/registry/pilot/provenance tests passing.');
end
loaded=load(physicalReportPath,'report');
if ~isfield(loaded,'report'), error('nbiot:stage2:Evidence','Physical report variable is missing.'); end
r=loaded.report;
if ~strcmp(r.matlabRelease,'2025b')||~isfield(r,'lteVersion')||isempty(r.lteVersion)||...
        height(r.trials)~=150||numel(r.conditions)~=15||...
        ~isequal(sort([r.conditions.id]),1:15)||r.options.repeats~=10||...
        ~all(r.trials.chainValidated)||~isfield(r,'receiverChecks')||height(r.receiverChecks)~=80||...
        ~isfield(r,'interferenceReplay')||isempty(r.interferenceReplay)
    error('nbiot:stage2:Evidence','Physical report is incomplete or violates the bounded Stage 2 design.');
end
if ~isfield(r,'progressFile')||~isfile(r.progressFile)
    error('nbiot:stage2:Evidence','Physical report does not identify its Stage 2 progress manifest.');
end
progress=stage2PhysicalProgress('verify',r.progressFile);
if numel(progress.caseRecords)~=232|| ...
        ~isequal(sort(double(progress.assignedIds(:).')),...
        sort(double([r.realizationAssignments.collisionDiagnostics(:).' ...
        r.realizationAssignments.receiverDiagnostics(:).'])))
    error('nbiot:stage2:Evidence','Stage 2 progress cases or assigned IDs do not match the physical report.');
end
control=r.trials(r.trials.conditionId==7,:);
if height(control)~=10||~any(control.chainCount>0)
    error('nbiot:stage2:Evidence','Different-preamble control did not demonstrate a CRC-validated access chain.');
end
nbiot.experiments.validateStage2ReceiverChecks(r.receiverChecks);
currentArtifacts=stage2ArtifactHashes(root);
currentManifest=optimizationSourceManifest(root);
if ~isfield(r,'artifactSourceHashes')||...
        ~stage2PhysicalArtifactsMatch(r.artifactSourceHashes,currentArtifacts)||...
        ~isfield(r,'sourceManifest')||~isfield(r.sourceManifest,'sha256')||...
        ~strcmp(r.sourceManifest.sha256,currentManifest.sha256)
    error('nbiot:stage2:Evidence','Stage 2 implementation changed after the physical report was recorded.');
end
calibrationPath=fullfile(root,'results','nprach-calibration.mat');
if ~isfield(r,'calibrationSha256')||~isfield(r,'receiverRevision')||...
        ~strcmp(fileHash(calibrationPath),r.calibrationSha256)||...
        ~strcmp(r.receiverRevision,nbiot.phy.nprach.receiverRevision())
    error('nbiot:stage2:Evidence','Calibration or NPRACH receiver revision changed after the physical run.');
end
replay=r.interferenceReplay;
expectedVariants=["full-noisy","full-clean","desired-noisy","desired-clean"];
if height(replay)~=8||~isequal(unique(replay.deltaDb).',[0 40])
    error('nbiot:stage2:Evidence','The two interference replay controls are incomplete.');
end
for delta=[0 40]
    variants=reshape(unique(string(replay.variant(replay.deltaDb==delta)),'stable'),1,[]);
    if ~isequal(sort(variants),sort(expectedVariants))
        error('nbiot:stage2:Evidence','Interference replay at %d dB is missing a diagnostic variant.',delta);
    end
end
equalFull=replay(replay.deltaDb==0&strcmp(replay.variant,'full-noisy'),:);
equalDesired=replay(replay.deltaDb==0&strcmp(replay.variant,'desired-noisy'),:);
nearFull=replay(replay.deltaDb==40&strcmp(replay.variant,'full-noisy'),:);
nearDesired=replay(replay.deltaDb==40&strcmp(replay.variant,'desired-noisy'),:);
if height(equalFull)~=1||height(equalDesired)~=1||equalFull.crcError~=0||...
        ~equalFull.payloadMatchesActualTx||equalDesired.crcError~=0||~equalDesired.payloadMatchesActualTx
    error('nbiot:stage2:Evidence','Equal-power replay must decode the actual UE2 block in full and desired-only controls.');
end
if height(nearFull)~=1||height(nearDesired)~=1||nearFull.crcError==0||...
        nearDesired.crcError~=0||~nearDesired.payloadMatchesActualTx
    error('nbiot:stage2:Evidence','Near-far replay must fail CRC in the full mixture and pass on the exact desired payload.');
end
registryPath=fullfile(root,'experiments','realizationRegistry.json');
if ~isfield(r,'registrySha256')||~strcmp(fileHash(registryPath),r.registrySha256)
    error('nbiot:stage2:Evidence','Realization registry changed after the physical report was recorded.');
end
if ~all(arrayfun(@(row) numel(unique(r.trials.realizationId(r.trials.conditionId==row.id)))==10,r.conditions))
    error('nbiot:stage2:Evidence','Each physical condition must contain ten distinct realization IDs.');
end
registry=jsondecode(fileread(registryPath));
collisionIds=sort(unique(double(r.trials.realizationId(:).')));
receiverIds=sort(unique(double(r.receiverChecks.id(:).')));
if ~isequal(collisionIds,sort(double(r.realizationAssignments.collisionDiagnostics(:).')))||...
        ~isequal(receiverIds,sort(double(r.realizationAssignments.receiverDiagnostics(:).')))||...
        ~isempty(intersect(collisionIds,receiverIds))
    error('nbiot:stage2:Evidence','Measured realization IDs do not match the assigned collision/receiver sets.');
end
requireCompletedAssignment(registry,'stage-2-collision-diagnostics',collisionIds);
requireCompletedAssignment(registry,'stage-2-receiver-diagnostics',receiverIds);
recoveryManifestSha256='';
if isfield(r,'recovery')
    if ~isfield(r.recovery,'evidenceHashes')||isempty(r.recovery.evidenceHashes)||...
            ~isfield(r.recovery,'evidenceManifestSha256')
        error('nbiot:stage2:Evidence','Recovered physical evidence has no integrity manifest.');
    end
    manifestRows=strings(1,numel(r.recovery.evidenceHashes));
    for k=1:numel(r.recovery.evidenceHashes)
        item=r.recovery.evidenceHashes(k);
        path=fullfile(root,strrep(item.relativePath,'/',filesep));
        if ~isfile(path)||~strcmp(fileHash(path),item.sha256)
            error('nbiot:stage2:Evidence','Recovered input evidence changed: %s.',item.relativePath);
        end
        manifestRows(k)=string(item.relativePath)+" "+string(item.sha256);
    end
    recoveryManifestSha256=hashText(strjoin(manifestRows,newline));
    if ~strcmp(recoveryManifestSha256,r.recovery.evidenceManifestSha256)
        error('nbiot:stage2:Evidence','Recovered input evidence manifest hash does not match.');
    end
    requireRecoveredAssignment(registry,'stage-2-collision-diagnostics',collisionIds,recoveryManifestSha256);
    if isfield(r.recovery,'receiverAssignmentMode')&&...
            strcmp(r.recovery.receiverAssignmentMode,'new-completed-assignment')
        requireCompletedAssignment(registry,'stage-2-receiver-diagnostics',receiverIds);
    else
        requireRecoveredAssignment(registry,'stage-2-receiver-diagnostics',receiverIds,recoveryManifestSha256);
    end
end
relativeReport=relativeToRoot(physicalReportPath,root); relativeLog=relativeToRoot(targetedLog,root);
acceptance=struct('schemaVersion',2,'status','accepted-for-stage-3',...
    'humanReviewed',false,'technicalReview',technicalReview,...
    'matlabRelease',r.matlabRelease,...
    'physicalReport',relativeReport,'physicalReportSha256',fileHash(physicalReportPath),...
    'targetedLog',relativeLog,'targetedLogSha256',fileHash(targetedLog),...
    'artifactSourceHashes',currentArtifacts,...
    'sourceManifestSha256',currentManifest.sha256,'calibrationSha256',r.calibrationSha256,...
    'progressManifestSha256',fileHash(r.progressFile),...
    'receiverRevision',r.receiverRevision,...
    'recoveryManifestSha256',recoveryManifestSha256,...
    'acceptanceLogicSha256',fileHash(which('acceptStage2Evidence')),...
    'artifactComparatorSha256',fileHash(which('stage2PhysicalArtifactsMatch')),...
    'registrySha256',fileHash(fullfile(root,'experiments','realizationRegistry.json')),...
    'acceptedUtc',char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss'Z'")));
destination=fullfile(root,'verification','completion','stage-2','acceptance.json');
temporary=[tempname(fileparts(destination)) '.json']; cleanup=onCleanup(@() removeTemporary(temporary));
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:stage2:Evidence','Cannot write Stage 2 acceptance record.'); end
closeFile=onCleanup(@() fclose(fid));
bytes=unicode2native(jsonencode(acceptance,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes), error('nbiot:stage2:Evidence','Cannot write complete acceptance record.'); end
clear closeFile
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:stage2:Evidence','Cannot commit acceptance record: %s',message); end
fprintf('STAGE2_ACCEPTED report=%s targeted=%s sha256=%s\n',relativeReport,relativeLog,fileHash(destination));
end

function review=validateTechnicalReview(review)
required={'reviewer','scope','notes'};
if nargin<1||~isstruct(review)||~isscalar(review)||~all(isfield(review,required))
    error('nbiot:stage2:ReviewRequired',...
        'A technical review record with reviewer, scope, and notes is required.');
end
reviewer=strtrim(char(string(review.reviewer)));
notes=strtrim(char(string(review.notes)));
scope=string(review.scope(:).');
requiredScope=["targeted-tests","physical-results","limitations"];
if isempty(reviewer)||isempty(notes)||~all(ismember(requiredScope,scope))
    error('nbiot:stage2:ReviewRequired',...
        'The technical review must identify its reviewer and cover tests, physical results, and limitations.');
end
review=struct('reviewer',reviewer,'scope',{cellstr(scope)},'notes',notes);
end

function requireCompletedAssignment(registry,role,ids)
found=false;
for k=1:numel(registry.assignments)
    a=registry.assignments(k);
    found=found||(strcmp(a.role,role)&&strcmp(a.status,'completed')&&...
        isequal(sort(double(a.ids(:).')),ids));
end
if ~found
    error('nbiot:stage2:Evidence','Measured IDs have no exact completed registry assignment for role %s.',role);
end
end

function requireRecoveredAssignment(registry,role,ids,manifest)
found=false;
for k=1:numel(registry.assignments)
    a=registry.assignments(k);
    if strcmp(a.role,role)&&strcmp(a.status,'completed')&&...
            isequal(sort(double(a.ids(:).')),ids)&&isfield(a,'recovery')&&...
            isstruct(a.recovery)&&isfield(a.recovery,'evidenceManifestSha256')&&...
            strcmp(a.recovery.evidenceManifestSha256,manifest)
        found=true; break
    end
end
if ~found
    error('nbiot:stage2:Evidence','Recovered IDs lack a matching registry recovery audit for role %s.',role);
end
end

function relative=relativeToRoot(path,root)
path=char(java.io.File(path).getCanonicalPath()); root=char(java.io.File(root).getCanonicalPath());
prefix=[root filesep];
if ~startsWith(lower(path),lower(prefix))
    error('nbiot:stage2:Evidence','Evidence files must be inside the project root.');
end
relative=strrep(path(numel(prefix)+1:end),filesep,'/');
end

function hex=fileHash(path)
fid=fopen(path,'rb'); if fid<0, error('nbiot:stage2:Hash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid));
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8'); if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function hex=hashText(value)
digest=java.security.MessageDigest.getInstance('SHA-256');
bytes=unicode2native(char(value),'UTF-8'); digest.update(typecast(bytes(:),'int8'));
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
