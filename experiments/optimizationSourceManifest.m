function manifest=optimizationSourceManifest(projectRoot)
%OPTIMIZATIONSOURCEMANIFEST Hash MATLAB sources in a project snapshot.
%   Хеши исходников для сравнения версий при оптимизации.
% Only computational sources: docs, tests, outputs and nested checkouts cannot
% change the runtime identity. External runners are registered separately.
files=dir(fullfile(projectRoot,'src','**','*.m'));
entryPoints={'setupProject.m','experiments/runStaticSweep.m', ...
    'experiments/runStaticSweepParallel.m','experiments/optimizationSourceManifest.m'};
for j=1:numel(entryPoints)
    entry=dir(fullfile(projectRoot,entryPoints{j}));
    files=[files;entry(:)]; %#ok<AGROW>
end
entries=struct('file',{},'sha256',{});
for k=1:numel(files)
    path=fullfile(files(k).folder,files(k).name);
    relative=path(numel(projectRoot)+2:end);
    fid=fopen(path,'rb');
    if fid<0, error('nbiot:optimization:SourceHash','Cannot open %s.',path); end
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    bytes=fread(fid,Inf,'*uint8'); clear cleanup
    entries(end+1)=struct('file',strrep(relative,'\','/'),'sha256',sha256(bytes)); %#ok<AGROW>
end
if ~isempty(entries), [~,order]=sort({entries.file}); entries=entries(order); end
canonical='';
for k=1:numel(entries), canonical=[canonical entries(k).file char(0) entries(k).sha256 char(10)]; end %#ok<AGROW>
manifest=struct('files',entries,'sha256',sha256(unicode2native(canonical,'UTF-8')));
end

function hex=sha256(bytes)
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(uint8(bytes(:)),'int8'));
raw=typecast(digest.digest(),'uint8');
hex=lower(reshape(dec2hex(raw,2).',1,[]));
end
