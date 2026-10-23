function [sim,info]=loadCheckpoint(folder,expectedIdentity,execution)
%LOADCHECKPOINT Verify identity and hashes, then restore the newest valid state.
totalClock=tic;
timing=struct('hashSeconds',0,'loadSeconds',0,'restoreSeconds',0,'totalSeconds',0,'bytes',0);
if nargin<3, execution=struct(); end
if ~(ischar(folder)||(isstring(folder)&&isscalar(folder)))|| ...
        ~isfolder(folder)||~isstruct(expectedIdentity)||~isscalar(expectedIdentity)
    error('nbiot:experiments:CheckpointOptions', ...
        'Expected an existing checkpoint folder and scalar runtime identity.');
end
folder=char(java.io.File(char(folder)).getCanonicalPath());
manifestPath=fullfile(folder,'checkpoint-manifest.json');
if ~isfile(manifestPath)
    error('nbiot:experiments:CheckpointMissing','Checkpoint manifest does not exist.');
end
try
    manifest=jsondecode(fileread(manifestPath));
catch exception
    error('nbiot:experiments:CheckpointFormat', ...
        'Cannot read checkpoint manifest: %s',exception.message);
end
if ~isfield(manifest,'manifestVersion')||manifest.manifestVersion~=1|| ...
        ~isfield(manifest,'checkpointSchemaVersion')|| ...
        manifest.checkpointSchemaVersion~=1|| ...
        ~isfield(manifest,'identity')||~isfield(manifest,'identitySha256')|| ...
        ~isfield(manifest,'checkpoints')
    error('nbiot:experiments:CheckpointFormat','Checkpoint manifest schema is invalid.');
end
expectedSha=nbiot.experiments.checkpointIdentityHash(expectedIdentity);
manifestSha=nbiot.experiments.checkpointIdentityHash(manifest.identity);
if ~strcmp(expectedSha,manifest.identitySha256)||~strcmp(manifestSha,manifest.identitySha256)
    error('nbiot:experiments:CheckpointIdentity', ...
        'Checkpoint source, configuration, calibration, model, policy, input or runtime identity has changed.');
end
entries=manifest.checkpoints;
if isempty(entries)
    error('nbiot:experiments:CheckpointMissing','Checkpoint manifest contains no verified states.');
end
newest=entries(end); failures={};
for k=numel(entries):-1:1
    entry=entries(k);
    try
        if ~all(isfield(entry,{'file','sha256','tick','savedAtUtc'}))|| ...
                ~safeFileName(entry.file)
            error('nbiot:experiments:CheckpointCorrupt','Checkpoint entry is malformed.');
        end
        fileName=char(entry.file); checkpointPath=fullfile(folder,fileName);
        if ~isfile(checkpointPath)
            error('nbiot:experiments:CheckpointCorrupt','Checkpoint data file is missing.');
        end
        phaseClock=tic;
        try
            actualHash=fileHash(checkpointPath);
        catch exception
            timing.hashSeconds=timing.hashSeconds+toc(phaseClock);
            rethrow(exception);
        end
        timing.hashSeconds=timing.hashSeconds+toc(phaseClock);
        if ~strcmp(actualHash,char(entry.sha256))
            error('nbiot:experiments:CheckpointCorrupt','Checkpoint data hash does not match the manifest.');
        end
        phaseClock=tic;
        try
            data=load(checkpointPath,'payload');
        catch exception
            timing.loadSeconds=timing.loadSeconds+toc(phaseClock);
            rethrow(exception);
        end
        timing.loadSeconds=timing.loadSeconds+toc(phaseClock);
        payload=data.payload;
        if ~isstruct(payload)||~all(isfield(payload,{'header','state'}))|| ...
                payload.header.checkpointSchemaVersion~=1|| ...
                ~strcmp(payload.header.identitySha256,manifest.identitySha256)|| ...
                payload.header.tick~=entry.tick||payload.state.currentTick~=entry.tick
            error('nbiot:experiments:CheckpointCorrupt','Checkpoint payload header or tick is inconsistent.');
        end
        phaseClock=tic;
        try
            sim=nbiot.NBIoTSimulator.fromCheckpointState(payload.state,execution);
        catch exception
            timing.restoreSeconds=timing.restoreSeconds+toc(phaseClock);
            rethrow(exception);
        end
        timing.restoreSeconds=timing.restoreSeconds+toc(phaseClock);
        fallbackUsed=(k<numel(entries));
        info=struct('checkpointFile',fileName,'checkpointPath',checkpointPath, ...
            'checkpointTick',double(entry.tick),'newestCheckpointFile',char(newest.file), ...
            'newestCheckpointTick',double(newest.tick),'fallbackUsed',fallbackUsed, ...
            'lostTicks',max(0,double(newest.tick)-double(entry.tick)), ...
            'identitySha256',manifest.identitySha256,'graphLinksValidated',true, ...
            'fallbackReason','','recoveryRecord','');
        if fallbackUsed
            info.fallbackReason=strjoin(failures,' | ');
            info.recoveryRecord=writeRecoveryRecord(folder,info);
        end
        fileInfo=dir(checkpointPath); timing.bytes=double(fileInfo.bytes);
        timing.totalSeconds=toc(totalClock);
        info.timing=timing;
        return
    catch exception
        if strcmp(exception.identifier,'nbiot:experiments:CheckpointRecoveryRecord')
            rethrow(exception);
        end
        failures{end+1}=sprintf('%s: %s',char(entry.file),exception.message); %#ok<AGROW>
    end
end
error('nbiot:experiments:CheckpointCorrupt', ...
    'No valid checkpoint could be restored: %s',strjoin(failures,' | '));
end

function path=writeRecoveryRecord(folder,info)
record=struct('recordedAtUtc',char(datetime('now','TimeZone','UTC', ...
    'Format','yyyy-MM-dd HH:mm:ss.SSS')),'fallbackUsed',true, ...
    'newestCheckpointFile',info.newestCheckpointFile, ...
    'newestCheckpointTick',info.newestCheckpointTick, ...
    'usedCheckpointFile',info.checkpointFile,'usedTick',info.checkpointTick, ...
    'lostTicks',info.lostTicks,'reason',info.fallbackReason);
path=fullfile(folder,'checkpoint-recovery.json');
temporary=[path '.' char(java.util.UUID.randomUUID()) '.tmp'];
try
    bytes=unicode2native(jsonencode(record,'PrettyPrint',true),'UTF-8');
    fid=fopen(temporary,'w','n','UTF-8');
    if fid<0, error('nbiot:experiments:CheckpointWrite','Cannot create recovery record.'); end
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    if fwrite(fid,bytes,'uint8')~=numel(bytes)
        error('nbiot:experiments:CheckpointWrite','Could not write recovery record.');
    end
    clear cleanup
    [ok,message]=movefile(temporary,path,'f');
    if ~ok, error('nbiot:experiments:CheckpointWrite','Cannot publish recovery record: %s',message); end
catch exception
    deleteIfPresent(temporary);
    error('nbiot:experiments:CheckpointRecoveryRecord', ...
        'Fallback was detected but could not be recorded: %s',exception.message);
end
end

function valid=safeFileName(value)
value=char(string(value));
valid=~isempty(value)&&isempty(fileparts(value))&& ...
    ~ismember(value,{'.','..'})&&startsWith(value,'checkpoint-tick-');
end

function digest=fileHash(path)
try
    digest=nbiot.ml.fileSha256(path);
catch exception
    error('nbiot:experiments:CheckpointCorrupt', ...
        'Cannot hash checkpoint data (%s): %s',exception.identifier,exception.message);
end
end

function deleteIfPresent(path)
if isfile(path), delete(path); end
end
