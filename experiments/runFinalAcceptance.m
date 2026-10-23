function report=runFinalAcceptance(options)
%RUNFINALACCEPTANCE Check final-acceptance evidence files and their hashes.
% The audit never runs simulations or changes evidence; it only writes review reports.
required={'projectRoot','evidenceManifest','outputFolder'};
if ~isstruct(options)||~isscalar(options)||~all(isfield(options,required))
    error('nbiot:finalAcceptance:Options', ...
        'Supply projectRoot, evidenceManifest and outputFolder.');
end
unknown=setdiff(fieldnames(options),required);
if ~isempty(unknown)
    error('nbiot:finalAcceptance:Options','Unsupported option %s.',unknown{1});
end

root=canonicalPath(options.projectRoot,'Project root');
if ~isfolder(root)
    error('nbiot:finalAcceptance:ProjectRoot','Project root does not exist.');
end
manifestPath=resolveProjectPath(root,options.evidenceManifest,'Evidence manifest');
outputFolder=resolveProjectPath(root,options.outputFolder,'Output folder');
if ~isfile(manifestPath)
    error('nbiot:finalAcceptance:Manifest','Evidence manifest does not exist.');
end
if isfile(outputFolder)
    error('nbiot:finalAcceptance:Output','Output folder points to a file.');
end
reportFiles={fullfile(outputFolder,'acceptance-review.json'), ...
    fullfile(outputFolder,'acceptance-review.md')};
if any(cellfun(@isfile,reportFiles))
    error('nbiot:finalAcceptance:OutputExists', ...
        'A review report already exists in outputFolder; choose a new folder to preserve it.');
end

try
    manifest=jsondecode(fileread(manifestPath));
catch exception
    error('nbiot:finalAcceptance:Manifest','Cannot read evidence manifest: %s',exception.message);
end
items=validateManifest(manifest,root);
requiredItems=requiredEvidence();
results=repmat(struct('key','','label','','path','','expectedSha256','', ...
    'actualSha256','','status','','details',''),1,numel(requiredItems));
for k=1:numel(requiredItems)
    key=requiredItems(k).key;
    match=find(strcmp({items.key},key),1);
    result=struct('key',key,'label',requiredItems(k).label,'path','', ...
        'expectedSha256','','actualSha256','','status','missing', ...
        'details','Evidence is not listed in the manifest.');
    if ~isempty(match)
        item=items(match);
        result.path=item.relativePath;
        result.expectedSha256=item.sha256;
        if ~isfile(item.absolutePath)
            result.details='The listed evidence file is missing.';
        else
            try
                result.actualSha256=fileSha256(item.absolutePath);
                if strcmp(result.actualSha256,result.expectedSha256)
                    result.status='verified';
                    result.details='File exists and its SHA-256 hash matches.';
                else
                    result.status='hash-mismatch';
                    result.details='File contents differ from the declared SHA-256 hash.';
                end
            catch exception
                result.status='unreadable';
                result.details=['Could not read evidence file: ' exception.message];
            end
        end
    end
    results(k)=result;
end

verified=sum(strcmp({results.status},'verified'));
missing=sum(strcmp({results.status},'missing'));
integrityErrors=sum(ismember({results.status},{'hash-mismatch','unreadable'}));
if integrityErrors>0
    status='integrity-error';
elseif verified==numel(requiredItems)
    status='ready-for-human-review';
else
    status='incomplete';
end
created=datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''');
report=struct('schemaVersion',1,'status',status,'accepted',false, ...
    'createdAtUtc',char(created),'evidence',results, ...
    'summary',struct('requiredCount',numel(requiredItems), ...
        'verifiedCount',verified,'missingCount',missing, ...
        'integrityErrorCount',integrityErrors), ...
    'limitation','Presence and file integrity only; scientific validity and final acceptance require human review.');

if ~isfolder(outputFolder), mkdir(outputFolder); end
writeText(reportFiles{1},jsonencode(report));
writeText(reportFiles{2},renderMarkdown(report));
end

function items=validateManifest(manifest,root)
if ~isstruct(manifest)||~isscalar(manifest)||~isfield(manifest,'schemaVersion')|| ...
        ~isnumeric(manifest.schemaVersion)||~isscalar(manifest.schemaVersion)|| ...
        manifest.schemaVersion~=1||~isfield(manifest,'evidence')
    error('nbiot:finalAcceptance:ManifestSchema', ...
        'Manifest must contain schemaVersion 1 and an evidence array.');
end
raw=manifest.evidence;
if isempty(raw)
    items=repmat(struct('key','','relativePath','','absolutePath','','sha256',''),0,1);
    return;
end
if ~isstruct(raw)||~isvector(raw)
    error('nbiot:finalAcceptance:ManifestSchema','Manifest evidence must be an array of objects.');
end
required=requiredEvidence();
known={required.key};
items=repmat(struct('key','','relativePath','','absolutePath','','sha256',''),1,numel(raw));
seen={};
for k=1:numel(raw)
    entry=raw(k);
    if ~all(isfield(entry,{'key','path','sha256'}))
        error('nbiot:finalAcceptance:ManifestSchema', ...
            'Each evidence entry must contain key, path and sha256.');
    end
    key=scalarText(entry.key,'Evidence key');
    if ~ismember(key,known)
        error('nbiot:finalAcceptance:UnknownEvidence','Unknown evidence key %s.',key);
    end
    if ismember(key,seen)
        error('nbiot:finalAcceptance:DuplicateEvidence','Evidence key %s is listed more than once.',key);
    end
    seen{end+1}=key; %#ok<AGROW>
    digest=lower(scalarText(entry.sha256,'Evidence SHA-256'));
    if isempty(regexp(digest,'^[0-9a-f]{64}$','once'))
        error('nbiot:finalAcceptance:ManifestSchema', ...
            'Evidence SHA-256 must contain exactly 64 hexadecimal characters.');
    end
    path=scalarText(entry.path,'Evidence path');
    absolutePath=resolveProjectPath(root,path,'Evidence file');
    relativePath=strrep(absolutePath(length(root)+2:end),filesep,'/');
    items(k)=struct('key',key,'relativePath',relativePath, ...
        'absolutePath',absolutePath,'sha256',digest);
end
end

function items=requiredEvidence()
items=struct('key',{'stage2Revalidation','independentModelEvaluation', ...
    'comparisonSweep','fullRegression','section47Audit','section50Audit', ...
    'colleagueReproduction','releasePackage'}, ...
    'label',{'Проверка Stage 2 на текущем коде', ...
    'Независимая проверка моделей на реальных данных', ...
    'Завершённое сравнение методов', ...
    'Полный набор регрессионных проверок', ...
    'Сверка состава результатов по §47', ...
    'Сверка требований по §50', ...
    'Повторение запуска на машине коллеги', ...
    'Проверенный комплект для передачи'});
end

function path=resolveProjectPath(root,value,label)
value=scalarText(value,label);
if isAbsolute(value), path=canonicalPath(value,label);
else, path=canonicalPath(fullfile(root,strrep(value,'/',filesep)),label); end
prefix=[stripTrailing(root) filesep];
if ~startsWith(lower(path),lower(prefix))
    error('nbiot:finalAcceptance:EvidencePath', ...
        '%s must stay inside projectRoot.',label);
end
end

function path=canonicalPath(value,label)
value=scalarText(value,label);
path=char(java.io.File(value).getCanonicalPath());
end

function value=scalarText(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||isempty(strtrim(value))||size(value,1)~=1
    error('nbiot:finalAcceptance:Options','%s must be non-empty scalar text.',label);
end
value=strtrim(value);
end

function yes=isAbsolute(path)
yes=~isempty(regexp(path,'^(?:[A-Za-z]:[\\/]|\\\\|/)', 'once'));
end

function path=stripTrailing(path)
while numel(path)>3&&any(path(end)==['\','/']), path(end)=[]; end
end

function digest=fileSha256(path)
md=java.security.MessageDigest.getInstance('SHA-256');
fid=fopen(path,'rb');
if fid<0, error('nbiot:finalAcceptance:ReadEvidence','Could not open evidence file.'); end
cleanup=onCleanup(@() fclose(fid));
while ~feof(fid)
    bytes=fread(fid,1024*1024,'*uint8');
    if ~isempty(bytes), md.update(typecast(bytes,'int8')); end
end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function writeText(path,value)
fid=fopen(path,'w','n','UTF-8');
if fid<0, error('nbiot:finalAcceptance:Write','Could not create %s.',path); end
cleanup=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',value);
end

function markdown=renderMarkdown(report)
if strcmp(report.status,'ready-for-human-review')
    heading='Готово к проверке человеком';
elseif strcmp(report.status,'integrity-error')
    heading='Ошибка целостности доказательств';
else
    heading='Доказательств пока недостаточно';
end
lines={['# Итоговая проверка: ' heading]; ...
    ''; ...
    ['Статус: ' char(96) report.status char(96)]; ...
    ''; ...
    'Этот файл проверяет наличие указанных материалов и совпадение контрольных сумм. Он не оценивает научную достоверность и не означает, что итоговая приёмка завершена.'; ...
    ''; ...
    '| Что проверяется | Статус | Файл |'; ...
    '|---|---|---|'};
for k=1:numel(report.evidence)
    item=report.evidence(k);
    path=item.path;
    if isempty(path), path='—'; end
    lines{end+1}=['| ' item.label ' | ' statusLabel(item.status) ' | ' char(96) path char(96) ' |']; %#ok<AGROW>
end
lines{end+1}='';
lines{end+1}='Автоматическая проверка не может выставить статус «принято»: решение остаётся за проверяющим.';
markdown=strjoin(lines,newline);
end

function label=statusLabel(status)
switch status
    case 'verified', label='файл найден, сумма совпала';
    case 'hash-mismatch', label='сумма не совпала';
    case 'unreadable', label='файл не удалось прочитать';
    otherwise, label='не найдено';
end
end
