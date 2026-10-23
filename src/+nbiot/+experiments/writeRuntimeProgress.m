function progress=writeRuntimeProgress(path,update)
%WRITERUNTIMEPROGRESS Atomic, best-effort instrumentation with segment clocks.
%   Запись прогресса долгого прогона в файл (наблюдение за расчётом).
% Elapsed keys use makeValidName(canonical phase), e.g. result_finalizing;
% phase and phaseContext retain their original strings. No scientific RNG use.
persistent segments
if isempty(segments), segments=containers.Map('KeyType','char','ValueType','any'); end
allowed={'phase','caseKey','currentTick','lastCheckpoint','status','workUnitsDone', ...
    'workUnitsTotal','errorIdentifier','failedPhase','phaseContext'};
phases={'initializing','checkpoint-loading','checkpointing','simulating', ...
    'result-finalizing','exporting','verifying','paused','completed','failed'};
if ~isstruct(update)||~isscalar(update)||~all(ismember(fieldnames(update),allowed))
    error('nbiot:experiments:ProgressOptions','Progress update contains unsupported fields.');
end
path=char(string(path));
previous=struct(); unreadable=false;
if ~isempty(path)&&isfile(path)
    try
        previous=jsondecode(fileread(path));
        if ~isstruct(previous)||~isscalar(previous), error('Invalid progress document.'); end
    catch
        previous=struct(); unreadable=true;
    end
end
if isfield(update,'caseKey')&&isfield(previous,'caseKey')&& ...
        ~strcmp(char(string(update.caseKey)),char(string(previous.caseKey)))
    previous=struct();
end
progress=struct('schemaVersion',2,'caseKey','','phase','initializing','status','running', ...
    'currentTick',0,'lastCheckpoint','','workUnitsDone',0,'workUnitsTotal',[], ...
    'errorIdentifier','','failedPhase','','phaseContext','');
names=fieldnames(previous);
for k=1:numel(names), progress.(names{k})=previous.(names{k}); end
names=fieldnames(update);
for k=1:numel(names), progress.(names{k})=update.(names{k}); end
textFields={'caseKey','phase','status','lastCheckpoint','errorIdentifier','failedPhase','phaseContext'};
for k=1:numel(textFields), progress.(textFields{k})=char(string(progress.(textFields{k}))); end
if ~ismember(progress.phase,phases)||~ismember(progress.status,{'running','paused','completed','failed'})
    error('nbiot:experiments:ProgressOptions','Progress phase or status is unsupported.');
end
canonicalPath=path;
if ~isempty(path), canonicalPath=char(java.io.File(path).getCanonicalPath()); end
key=jsonencode({canonicalPath,progress.caseKey});
now=char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"));
signature=struct('phase',progress.phase,'tick',progress.currentTick, ...
    'checkpoint',progress.lastCheckpoint,'workUnitsDone',progress.workUnitsDone);
if isKey(segments,key)
    segment=segments(key);
    elapsed=toc(segment.clock);
    phaseKey=matlab.lang.makeValidName(segment.phase);
    segment.durations.(phaseKey)=segment.durations.(phaseKey)+max(0,elapsed-segment.lastElapsed);
    segment.lastElapsed=elapsed;
    if ~strcmp(segment.phase,progress.phase), segment.phaseStartedAtUtc=now; end
    if ~isequaln(signature,segment.signature), segment.lastProgressAtUtc=now; end
    segment.phase=progress.phase;
    segment.signature=signature;
else
    priorSegment='';
    if isfield(previous,'processSegmentId'), priorSegment=char(string(previous.processSegmentId)); end
    segment=struct('clock',tic,'lastElapsed',0,'phase',progress.phase, ...
        'durations',struct(),'signature',signature,'phaseStartedAtUtc',now, ...
        'lastProgressAtUtc',now,'id',char(java.util.UUID.randomUUID()), ...
        'previousId',priorSegment);
end
phaseKey=matlab.lang.makeValidName(progress.phase);
if ~isfield(segment.durations,phaseKey), segment.durations.(phaseKey)=0; end
segments(key)=segment;
progress.schemaVersion=2;
progress.processSegmentId=segment.id;
progress.previousProcessSegmentId=segment.previousId;
progress.phaseStartedAtUtc=segment.phaseStartedAtUtc;
progress.lastProgressAtUtc=segment.lastProgressAtUtc;
progress.updatedAtUtc=now;
progress.phaseElapsedSeconds=segment.durations;
if unreadable, progress.previousProgressUnreadable=true; end
progress.writeSucceeded=true;
if isempty(path), return; end
try
    publish(canonicalPath,progress);
catch exception
    progress.writeSucceeded=false;
    warning('nbiot:experiments:ProgressWrite','Cannot publish runtime progress: %s',exception.message);
end
end

function publish(path,progress)
if isfolder(path), error('Progress path is an existing directory.'); end
folder=fileparts(path);
if ~isfolder(folder)
    [ok,message]=mkdir(folder);
    if ~ok, error('%s',message); end
end
temporary=[path '.' char(java.util.UUID.randomUUID()) '.tmp'];
cleanup=onCleanup(@()deleteTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('Cannot create temporary progress file.'); end
closeFile=onCleanup(@()fclose(fid));
bytes=unicode2native(jsonencode(progress),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes), error('Incomplete progress write.'); end
clear closeFile
[ok,message]=movefile(temporary,path,'f');
if ~ok, error('%s',message); end
end

function deleteTemporary(path)
try
    if isfile(path), delete(path); end
catch
    % Temporary-file cleanup must not interfere with scientific execution.
end
end
