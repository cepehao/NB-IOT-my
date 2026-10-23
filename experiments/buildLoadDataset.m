function data=buildLoadDataset(options)
%BUILDLOADDATASET Build an explicit saved-data dataset without simulation.
required={'resultFiles','splitManifest','outputFolder'};
allowed=[required,{'purpose','registryFile'}];
if nargin<1||~isstruct(options)||~isscalar(options)||~all(isfield(options,required))|| ...
        ~all(ismember(fieldnames(options),allowed))
    error('nbiot:dataset:Options','Explicit resultFiles, splitManifest and outputFolder are required.');
end
if ~isfield(options,'purpose'), options.purpose='development'; end
if ~ismember(string(options.purpose),["development","training"])
    error('nbiot:dataset:Options','Purpose must be development or training.');
end
folder=char(string(options.outputFolder));
if isempty(strtrim(folder)), error('nbiot:dataset:Output','Output folder is required.'); end
if isfolder(folder)
    contents=dir(folder); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents), error('nbiot:dataset:Output','Refusing to overwrite a nonempty dataset folder.'); end
elseif isfile(folder)
    error('nbiot:dataset:Output','Output path is a file.');
end
data=nbiot.dataset.assembleLoadDataset(options.resultFiles,options.splitManifest);
if strcmp(options.purpose,'development')
    if any(data.rowInfo.split~="development"), error('nbiot:dataset:SplitManifest','Development builds require development groups.'); end
else
    if ~isfield(data.manifest,'experimentRolesExplicit')||~data.manifest.experimentRolesExplicit
        error('nbiot:dataset:RoleManifest', ...
            'Training builds require an explicit experimentRole for every realization ID.');
    end
    if any(data.rowInfo.experimentRole=="final-comparison")
        error('nbiot:dataset:FinalComparison', ...
            'Final comparison data must remain separate from model training.');
    end
    if strcmp(data.manifest.kind,'development-fixture')||any(data.rowInfo.split=="development")|| ...
            ~isfield(options,'registryFile')||~isfile(options.registryFile)
        error('nbiot:dataset:Registry','Training builds require real cases and an explicit allocation registry.');
    end
    registry=jsondecode(fileread(options.registryFile));
    if ~isfield(registry,'schemaVersion')||registry.schemaVersion~=1||~isfield(registry,'assignments')||~isfield(registry,'reservations')
        error('nbiot:dataset:Registry','Unsupported realization registry.');
    end
    groups=data.manifest.assignments;
    for k=1:height(groups)
        role=char(groups.experimentRole(k));
        matches=false;
        for allocation=registry.assignments(:).'
            if ismember(groups.externalRealizationId(k),allocation.ids)
                if ~strcmp(allocation.role,role)||~strcmp(allocation.status,'completed')
                    error('nbiot:dataset:Registry','An ID belongs to an incompatible or unfinished allocation.');
                end
                matches=true;
            end
        end
        for reservation=registry.reservations(:).'
            if groups.externalRealizationId(k)>=min(reservation.range)&&groups.externalRealizationId(k)<=max(reservation.range)
                error('nbiot:dataset:Registry','A legacy/diagnostic reserved ID cannot enter training/test.');
            end
        end
        if ~matches, error('nbiot:dataset:Registry','A data ID lacks a completed matching allocation.'); end
    end
    data.manifest.allocationsVerified=true;
end
[datasetSummary,scenarioCoverage]=nbiot.dataset.summarizeLoadDataset(data);
if ~isfolder(folder), mkdir(folder); end
save(fullfile(folder,'dataset.mat'),'data','-v7.3');
observations=data.observations; observations.caseKey=data.rowInfo.caseKey;
targets=data.targets; targets.caseKey=data.rowInfo.caseKey;
writetable(observations,fullfile(folder,'observations.csv'));
writetable(targets,fullfile(folder,'targets.csv'));
writetable(data.features,fullfile(folder,'features.csv'));
writetable(data.rowInfo,fullfile(folder,'rows.csv'));
manifest=data.manifest; manifest.assignments=table2struct(manifest.assignments);
writeJson(fullfile(folder,'manifest.json'),manifest);
writeJson(fullfile(folder,'dataset-summary.json'),datasetSummary);
writetable(scenarioCoverage,fullfile(folder,'scenario-coverage.csv'));
diagnostics=data.diagnostics;
writetable(diagnostics,fullfile(folder,'diagnostics.csv'));
artifactNames={'dataset.mat','observations.csv','targets.csv','features.csv','rows.csv', ...
    'manifest.json','dataset-summary.json','scenario-coverage.csv','diagnostics.csv'};
artifactFiles=repmat(struct('name','','bytes',0,'sha256',''),numel(artifactNames),1);
for k=1:numel(artifactNames)
    artifactPath=fullfile(folder,artifactNames{k});
    fileInfo=dir(artifactPath);
    if isempty(fileInfo)||fileInfo.isdir
        error('nbiot:dataset:Output','Expected dataset artifact was not written: %s',artifactNames{k});
    end
    artifactFiles(k).name=artifactNames{k};
    artifactFiles(k).bytes=double(fileInfo.bytes);
    artifactFiles(k).sha256=fileSha256(artifactPath);
end
writeJson(fullfile(folder,'artifacts.json'),struct('schemaVersion',1,'files',artifactFiles));
end

function writeJson(file,value)
fid=fopen(file,'w','n','UTF-8');
if fid<0, error('nbiot:dataset:Output','Cannot write dataset report.'); end
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end

function digest=fileSha256(file)
md=java.security.MessageDigest.getInstance('SHA-256'); fid=fopen(file,'rb');
if fid<0, error('nbiot:dataset:Output','Cannot read dataset artifact for hashing.'); end
cleanup=onCleanup(@() fclose(fid));
while ~feof(fid), md.update(typecast(fread(fid,1024*1024,'*uint8'),'int8')); end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
