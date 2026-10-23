function measurement=measureCheckpointHash(path,outputFolder)
%MEASURECHECKPOINTHASH One read-only streaming SHA pass; never load payload.
path=char(java.io.File(char(string(path))).getCanonicalPath());
outputFolder=char(java.io.File(char(string(outputFolder))).getCanonicalPath());
if ~isfile(path)
    error('nbiot:verification:CheckpointHash','An existing checkpoint file is required.');
end
if isfolder(outputFolder)||isfile(outputFolder)
    error('nbiot:verification:CheckpointHash','Choose a new output folder.');
end
fileInfo=dir(path);
started=tic;
digest=nbiot.ml.fileSha256(path);
seconds=toc(started);
measurement=struct('path',path,'sha256',digest,'bytes',double(fileInfo.bytes), ...
    'seconds',seconds,'sampledPeakWorkingSetBytes',NaN, ...
    'javaHeapMaxBytes',double(java.lang.Runtime.getRuntime().maxMemory()), ...
    'javaHeapMeasurement','Runtime.maxMemory; observed effective JVM limit', ...
    'matlabRelease',version('-release'),'readOnly',true,'payloadLoaded',false);
[ok,message]=mkdir(outputFolder);
if ~ok, error('nbiot:verification:CheckpointHash','%s',message); end
fid=fopen(fullfile(outputFolder,'checkpoint-hash-measurement.json'),'w');
if fid<0, error('nbiot:verification:CheckpointHash','Cannot create measurement output.'); end
cleanup=onCleanup(@()fclose(fid));
fprintf(fid,'%s\n',jsonencode(measurement,PrettyPrint=true));
fprintf('CHECKPOINT_STREAMING_HASH bytes=%.0f seconds=%.6f sha256=%s javaHeapMaxBytes=%.0f\n', ...
    measurement.bytes,seconds,digest,measurement.javaHeapMaxBytes);
end
