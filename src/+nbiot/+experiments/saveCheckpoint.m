function [path,timing]=saveCheckpoint(sim,folder,identity)
%SAVECHECKPOINT Atomically publish a read-back-verified simulator snapshot.
totalClock=tic;
timing=struct('existingHashSeconds',0,'exportStateSeconds',0,'saveSeconds',0, ...
    'readbackSeconds',0,'hashSeconds',0,'publishSeconds',0,'totalSeconds',0,'bytes',0);
if nargin~=3||~isa(sim,'nbiot.NBIoTSimulator')|| ...
        ~(ischar(folder)||(isstring(folder)&&isscalar(folder)))|| ...
        ~isstruct(identity)||~isscalar(identity)
    error('nbiot:experiments:CheckpointOptions', ...
        'Expected a simulator, checkpoint folder and scalar runtime identity.');
end
identityFields={'caseKey','sourceSha256','configSha256','calibrationSha256','environment'};
if ~all(isfield(identity,identityFields))
    error('nbiot:experiments:CheckpointIdentity', ...
        'Runtime identity is missing its case, source, configuration, calibration or environment fields.');
end
folder=char(java.io.File(char(folder)).getCanonicalPath());
if ~isfolder(folder)
    [ok,message]=mkdir(folder);
    if ~ok, error('nbiot:experiments:CheckpointWrite','Cannot create checkpoint folder: %s',message); end
end
identitySha256=nbiot.experiments.checkpointIdentityHash(identity);
manifestPath=fullfile(folder,'checkpoint-manifest.json');
entries=struct('file',{},'sha256',{},'tick',{},'savedAtUtc',{});
if isfile(manifestPath)
    try
        previous=jsondecode(fileread(manifestPath));
    catch exception
        error('nbiot:experiments:CheckpointFormat', ...
            'Cannot read the existing checkpoint manifest: %s',exception.message);
    end
    if ~isfield(previous,'manifestVersion')||previous.manifestVersion~=1|| ...
            ~isfield(previous,'identitySha256')|| ...
            ~strcmp(previous.identitySha256,identitySha256)||~isfield(previous,'checkpoints')
        error('nbiot:experiments:CheckpointIdentity', ...
            'Existing checkpoint manifest belongs to a different identity or schema.');
    end
    for k=1:numel(previous.checkpoints)
        entry=previous.checkpoints(k);
        if ~all(isfield(entry,{'file','sha256','tick','savedAtUtc'}))|| ...
                ~safeFileName(entry.file)
            continue
        end
        oldPath=fullfile(folder,char(entry.file));
        if isfile(oldPath)
            phaseClock=tic;
            oldHash=fileHash(oldPath);
            timing.existingHashSeconds=timing.existingHashSeconds+toc(phaseClock);
            if strcmp(oldHash,char(entry.sha256)), entries(end+1)=entry; end %#ok<AGROW>
        end
    end
end
phaseClock=tic;
state=sim.exportCheckpointState();
timing.exportStateSeconds=toc(phaseClock);
if ~isempty(entries)&&state.currentTick<entries(end).tick
    error('nbiot:experiments:CheckpointOrder', ...
        'A checkpoint cannot move behind the newest verified tick.');
end
savedAtUtc=char(datetime('now','TimeZone','UTC', ...
    'Format','yyyy-MM-dd HH:mm:ss.SSS'));
runToken=char(java.util.UUID.randomUUID());
fileName=sprintf('checkpoint-tick-%010d-%s.mat',state.currentTick,runToken);
path=fullfile(folder,fileName);
temporaryMat=fullfile(folder,['.checkpoint-' runToken '.tmp.mat']);
temporaryManifest=fullfile(folder,['.manifest-' runToken '.tmp.json']);
published=false;
try
    header=struct('checkpointSchemaVersion',1,'identity',identity, ...
        'identitySha256',identitySha256,'tick',double(state.currentTick), ...
        'nextTick',double(state.nextTick),'savedAtUtc',savedAtUtc);
    payload=struct('header',header,'state',state);
    phaseClock=tic;
    save(temporaryMat,'payload','-v7.3');
    timing.saveSeconds=toc(phaseClock);
    phaseClock=tic;
    readback=load(temporaryMat,'payload');
    validatePayload(readback.payload,identitySha256,state.currentTick);
    timing.readbackSeconds=toc(phaseClock);
    phaseClock=tic;
    checkpointSha256=fileHash(temporaryMat);
    timing.hashSeconds=toc(phaseClock);
    fileInfo=dir(temporaryMat); timing.bytes=double(fileInfo.bytes);
    phaseClock=tic;
    [ok,message]=movefile(temporaryMat,path);
    timing.publishSeconds=toc(phaseClock);
    if ~ok
        error('nbiot:experiments:CheckpointWrite', ...
            'Cannot publish checkpoint data: %s',message);
    end
    entries(end+1)=struct('file',fileName,'sha256',checkpointSha256, ...
        'tick',double(state.currentTick),'savedAtUtc',savedAtUtc);
    if numel(entries)>2, entries=entries(end-1:end); end
    manifest=struct('manifestVersion',1,'checkpointSchemaVersion',1, ...
        'identity',identity,'identitySha256',identitySha256, ...
        'updatedAtUtc',savedAtUtc,'checkpoints',entries);
    phaseClock=tic;
    writeJson(temporaryManifest,manifest);
    [ok,message]=movefile(temporaryManifest,manifestPath,'f');
    timing.publishSeconds=timing.publishSeconds+toc(phaseClock);
    if ~ok
        error('nbiot:experiments:CheckpointWrite', ...
            'Cannot atomically update checkpoint manifest: %s',message);
    end
    published=true;
catch exception
    deleteIfPresent(temporaryMat); deleteIfPresent(temporaryManifest);
    if ~published, deleteIfPresent(path); end
    if startsWith(exception.identifier,'nbiot:experiments:Checkpoint')
        rethrow(exception);
    end
    error('nbiot:experiments:CheckpointWrite', ...
        'Checkpoint publication failed; the previous manifest remains active: %s', ...
        exception.message);
end
keep={entries.file};
oldFiles=dir(fullfile(folder,'checkpoint-tick-*.mat'));
for k=1:numel(oldFiles)
    if ~any(strcmp(oldFiles(k).name,keep))
        deleteIfPresent(fullfile(folder,oldFiles(k).name));
    end
end
timing.totalSeconds=toc(totalClock);
end

function validatePayload(payload,identitySha256,tick)
if ~isstruct(payload)||~all(isfield(payload,{'header','state'}))|| ...
        ~isfield(payload.header,'checkpointSchemaVersion')|| ...
        payload.header.checkpointSchemaVersion~=1|| ...
        ~strcmp(payload.header.identitySha256,identitySha256)|| ...
        payload.header.tick~=tick||payload.state.schemaVersion~=1|| ...
        payload.state.currentTick~=tick
    error('nbiot:experiments:CheckpointWrite', ...
        'Checkpoint readback did not match the state and identity being written.');
end
end

function valid=safeFileName(value)
value=char(string(value));
valid=~isempty(value)&&isempty(fileparts(value))&& ...
    ~ismember(value,{'.','..'})&&startsWith(value,'checkpoint-tick-');
end

function writeJson(path,value)
bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
fid=fopen(path,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:CheckpointWrite','Cannot create temporary manifest.'); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:experiments:CheckpointWrite','Could not write the complete temporary manifest.');
end
clear cleanup
end

function digest=fileHash(path)
try
    digest=nbiot.ml.fileSha256(path);
catch exception
    error('nbiot:experiments:CheckpointWrite', ...
        'Cannot hash checkpoint data (%s): %s',exception.identifier,exception.message);
end
end

function deleteIfPresent(path)
if isfile(path), delete(path); end
end
