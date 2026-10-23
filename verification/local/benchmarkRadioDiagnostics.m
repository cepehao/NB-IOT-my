function measurement=benchmarkRadioDiagnostics(outputFolder,pairCount)
%BENCHMARKRADIODIAGNOSTICS One synthetic diagnostic timing, never a PHY run.
validateattributes(pairCount,{'numeric'},{'scalar','real','finite','integer'});
if ~ismember(pairCount,[100 1000 10000 50000 220000])
    error('nbiot:verification:RadioBenchmarkSize','Unsupported synthetic pair count.');
end
outputFolder=char(string(outputFolder));
if isempty(outputFolder)||isfolder(outputFolder)||isfile(outputFolder)
    error('nbiot:verification:RadioBenchmarkFolder','Choose a new output folder.');
end
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
originalPath=path;
cleanup=onCleanup(@()path(originalPath));
addpath(fullfile(root,'src'),fullfile(root,'tests','helpers'));
sourceFile=fullfile(root,'src','+nbiot','+metrics','radioDiagnostics.m');
sourceSha=nbiot.ml.fileSha256(sourceFile);
[truth,observed,receptions,options]=makeRadioDiagnosticsScaleFixture(pairCount);
started=tic;
diagnostics=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options);
seconds=toc(started);
assert(diagnostics.collision.physicalOverlapPairs==pairCount);
assert(diagnostics.capture.eligiblePairs==pairCount);
assert(diagnostics.capture.capturedPairs==0 && diagnostics.capture.probability==0);
assert(strcmp(sourceSha,nbiot.ml.fileSha256(sourceFile)), ...
    'Diagnostic source changed during the benchmark.');
% External process sampler owns the memory peak; unknown is explicitly NaN.
measurement=table("indexed",double(pairCount),seconds,NaN, ...
    string(version('-release')),string(sourceSha),'VariableNames', ...
    {'implementation','pairs','seconds','sampledPeakWorkingSetBytes','matlabRelease','sourceSha256'});
[ok,message]=mkdir(outputFolder);
if ~ok, error('nbiot:verification:RadioBenchmarkFolder','%s',message); end
writetable(measurement,fullfile(outputFolder,'benchmark.csv'));
environment=struct('matlabRelease',version('-release'),'matlabVersion',version, ...
    'computer',computer,'sourceSha256',sourceSha,'syntheticPairs',double(pairCount), ...
    'physicalSimulation',false,'baselineUnavailable',true, ...
    'baselineNote','No safely isolated old-algorithm baseline is supplied by this microbenchmark.', ...
    'memoryPeakSource','External sampler only; NaN until a coordinator sample is available.');
fid=fopen(fullfile(outputFolder,'environment.json'),'w');
if fid<0, error('nbiot:verification:RadioBenchmarkFolder','Cannot write environment.json.'); end
fileCleanup=onCleanup(@()fclose(fid));
fprintf(fid,'%s\n',jsonencode(environment,PrettyPrint=true));
fprintf('RADIO_DIAGNOSTICS_BENCHMARK pairs=%d seconds=%.6f sourceSha256=%s\n',pairCount,seconds,sourceSha);
end
