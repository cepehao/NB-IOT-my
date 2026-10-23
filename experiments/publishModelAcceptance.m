function metadata=publishModelAcceptance(options)
%PUBLISHMODELACCEPTANCE Publish a separate reviewed acceptance or rejection record.
try
    required={'candidateFile','reviewFile','outputFile'};
    if ~isstruct(options)||~isscalar(options)||~all(isfield(options,required))|| ...
            ~all(ismember(fieldnames(options),required))
        reject('Options must contain candidateFile, reviewFile, and outputFile only.');
    end
    candidateFile=canonicalPath(text(options.candidateFile,'candidateFile'));
    reviewFile=canonicalPath(text(options.reviewFile,'reviewFile'));
    outputFile=canonicalPath(text(options.outputFile,'outputFile'));
    if ~isfile(candidateFile)||~isfile(reviewFile), reject('Candidate or review JSON is missing.'); end
    if isfile(outputFile), reject('Review output already exists; it is never overwritten.'); end
    root=fileparts(candidateFile);
    if ~strcmpi(fileparts(outputFile),root)
        reject('Published acceptance must remain beside its portable candidate package.');
    end
    candidate=readJson(candidateFile,'candidate');
    if ~strcmp(text(candidate.status,'candidate status'),'candidate')
        reject('Only a candidate acceptance can be published.');
    end
    review=readJson(reviewFile,'review');
    reviewFields={'decision','reviewer','reviewedAtUtc','evidenceDigest','protocolSha256','limitations'};
    if ~all(isfield(review,reviewFields))|| ...
            ~ismember(text(review.decision,'review decision'),{'accepted','rejected'})|| ...
            isempty(strtrim(text(review.reviewer,'reviewer')))|| ...
            isempty(strtrim(text(review.limitations,'review limitations')))
        reject('Review must contain a decision, reviewer, time, evidence digest, protocol hash, and limitations.');
    end
    decision=text(review.decision,'review decision');
    evidence=nbiot.ml.checkModelAcceptanceEvidence(candidateFile,root);
    if isempty(evidence.evidenceDigest)|| ...
            ~strcmpi(text(review.evidenceDigest,'review evidence digest'),evidence.evidenceDigest)|| ...
            ~strcmpi(text(review.protocolSha256,'review protocol hash'),candidate.protocol.sha256)
        reject('Review does not match candidate evidence or protocol.');
    end
    evaluation=readJson(resolveRef(root,candidate.evaluation),'evaluation');
    if parseUtc(review.reviewedAtUtc,'reviewedAtUtc')< ...
            parseUtc(evaluation.completedAtUtc,'evaluation completedAtUtc')
        reject('Scientific review must follow completed evaluation.');
    end
    if ~strcmp(text(candidate.evidenceKind,'evidence kind'),'scientific-candidate')
        reject('Local development/test-fixture evidence cannot be published as scientific acceptance.');
    end
    if strcmp(decision,'accepted')
        if ~evidence.passed|| ...
                (isfield(candidate,'unmetRequirements')&&~isempty(candidate.unmetRequirements))
            reject('Accepted review requires complete, passing scientific evidence.');
        end
    end
    candidate.status=decision;
    candidate.review=review;
    if strcmp(decision,'accepted')
        candidate.unmetRequirements={};
    elseif ~evidence.passed
        candidate.unmetRequirements=evidence.errors;
    elseif ~isfield(candidate,'unmetRequirements')
        candidate.unmetRequirements={};
    end
    writeJsonAtomic(outputFile,candidate);
    readback=nbiot.ml.checkModelAcceptanceEvidence(outputFile,root);
    if ~strcmpi(readback.evidenceDigest,evidence.evidenceDigest)
        deleteIfPresent(outputFile);
        reject('Published review record does not preserve the candidate evidence digest.');
    end
    if strcmp(decision,'accepted')&&~readback.passed
        deleteIfPresent(outputFile);
        reject('Published acceptance failed readback validation: %s',strjoin(readback.errors,'; '));
    end
    metadata=struct('status',decision,'acceptanceSha256',nbiot.ml.fileSha256(outputFile), ...
        'evidenceDigest',evidence.evidenceDigest,'file',outputFile);
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Cannot publish model review record: %s',exception.message);
end
end

function writeJsonAtomic(path,value)
temp=[path '.tmp-' char(java.util.UUID.randomUUID())];
cleanup=onCleanup(@() deleteIfPresent(temp)); %#ok<NASGU>
fid=fopen(temp,'w','n','UTF-8');
if fid<0, reject('Cannot create a temporary review record.'); end
closeGuard=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
clear closeGuard
jsondecode(fileread(temp));
if isfile(path), reject('Review output appeared during publication; it was not overwritten.'); end
[ok,message]=movefile(temp,path);
if ~ok, reject('Cannot atomically place review output: %s.',message); end
end

function deleteIfPresent(path)
if isfile(path), delete(path); end
end

function value=readJson(path,label)
try, value=jsondecode(fileread(path));
catch exception, reject('Cannot read %s JSON: %s.',label,exception.message); end
if ~isstruct(value)||~isscalar(value), reject('%s JSON must contain one object.',label); end
end

function value=text(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1, reject('%s must be scalar text.',label); end
value=strtrim(value);
end

function path=resolveRef(root,ref)
relative=text(ref.file,'acceptance reference');
if isempty(relative)||startsWith(relative,{'/','\'})||contains(relative,':')|| ...
        any(split(string(strrep(relative,'\','/')),'/')=="..")
    reject('Acceptance reference escapes its package root.');
end
path=canonicalPath(fullfile(root,strrep(relative,'/',filesep)));
prefix=[canonicalPath(root) filesep];
if ~startsWith(path,prefix,'IgnoreCase',true)||~isfile(path)
    reject('Acceptance reference is unavailable inside the package.');
end
end

function value=parseUtc(value,label)
value=text(value,label);
try, value=datetime(value,'InputFormat',"yyyy-MM-dd'T'HH:mm:ss'Z'",'TimeZone','UTC');
catch exception, reject('%s is not a valid UTC timestamp: %s.',label,exception.message); end
if isnat(value), reject('%s is not a valid UTC timestamp.',label); end
end

function path=canonicalPath(path)
path=char(path);
try, path=char(java.io.File(path).getCanonicalPath()); catch, end
end

function reject(message,varargin)
error('nbiot:ml:ModelAcceptance',message,varargin{:});
end
