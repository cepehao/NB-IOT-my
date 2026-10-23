function bundlePath=runOptimizationCase(bundlePath)
%RUNOPTIMIZATIONCASE Run the fixed single-UE equivalence scenario in isolation.
if nargin<1 || ~(ischar(bundlePath) || isstring(bundlePath))
    error('nbiot:optimization:Output','Provide a new MAT bundle path.');
end
bundlePath=char(bundlePath);
if isfile(bundlePath), error('nbiot:optimization:OutputExists','Refusing to overwrite %s.',bundlePath); end
projectRoot=fileparts(fileparts(mfilename('fullpath')));
addpath(projectRoot); setupProject();
outputFolder=fileparts(bundlePath);
if isempty(outputFolder), outputFolder=pwd; bundlePath=fullfile(outputFolder,bundlePath); end
if ~isfolder(outputFolder), mkdir(outputFolder); end
exportFolder=fullfile(outputFolder,'exports');
if isfolder(exportFolder), error('nbiot:optimization:OutputExists','Refusing to reuse %s.',exportFolder); end

cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.realizationId=0;
cfg.traffic.burstDurationTicks=100;
calibrationFile=fullfile(projectRoot,'results','nprach-calibration.mat');
sourceManifest=optimizationSourceManifest(projectRoot);
calibrationSha256=fileSha256(calibrationFile);
cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
result=nbiot.runExperiment(cfg);
nbiot.results.saveResult(result,exportFolder);
if ~strcmp(result.status,'completed')
    detail=''; if ~isempty(result.error) && isfield(result.error,'message'), detail=result.error.message; end
    error('nbiot:optimization:IncompleteRun','Equivalence scenario ended as %s: %s',result.status,detail);
end
lte=ver('lte'); lteVersion=''; if ~isempty(lte), lteVersion=lte(1).Version; end
metadata=struct('caseId','static-v1-single-ue-burst100-r0000-seed42', ...
    'config',cfg,'calibrationSha256',calibrationSha256, ...
    'environment',struct('matlabVersion',version,'release',version('-release'), ...
        'lteVersion',lteVersion,'computer',computer), ...
    'sourceManifest',sourceManifest,'exportDirectory',exportFolder, ...
    'exportStem','static-v1_n1_r0000');
temporary=[tempname(outputFolder) '.mat'];
cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
save(temporary,'result','metadata','-v7.3');
[ok,message]=movefile(temporary,bundlePath);
if ~ok, error('nbiot:optimization:BundleWrite','%s',message); end
end

function hex=fileSha256(path)
if ~isfile(path), error('nbiot:optimization:Calibration','Missing calibration: %s',path); end
fid=fopen(path,'rb'); if fid<0, error('nbiot:optimization:Calibration','Cannot open %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=fread(fid,Inf,'*uint8');
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(bytes(:),'int8'));
raw=typecast(digest.digest(),'uint8'); hex=lower(reshape(dec2hex(raw,2).',1,[]));
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
