function report=verifyOptimization(referenceFile,candidateFile,reportBase)
%VERIFYOPTIMIZATION Compare separate-process reference and candidate bundles.
%   Сравнение эталонного и оптимизированного прогонов (совпадение результатов).
if nargin<3, reportBase=fullfile(pwd,'optimization-comparison'); end
if ~ischar(referenceFile) && ~isstring(referenceFile), error('nbiot:optimization:Input','Reference path must be text.'); end
if ~ischar(candidateFile) && ~isstring(candidateFile), error('nbiot:optimization:Input','Candidate path must be text.'); end
reportBase=char(reportBase);
[folder,name,ext]=fileparts(reportBase);
if strcmpi(ext,'.mat'), reportBase=fullfile(folder,name); end
report=struct('schemaVersion',1,'passed',false,'checks',struct('name',{},'passed',{},'detail',{}), ...
    'errors',{{}},'reference',struct(),'candidate',struct(),'createdUtc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z''')));

try
    reference=loadBundle(char(referenceFile)); candidate=loadBundle(char(candidateFile));
    report.reference=summarize(reference,char(referenceFile));
    report.candidate=summarize(candidate,char(candidateFile));
    addCheck('caseId',sameField(reference.metadata,candidate.metadata,'caseId'), ...
        'Reference and candidate must use the same named scenario.');
    addCheck('configuration',isequaln(reference.result.config,candidate.result.config), ...
        'Full configuration must match exactly.');
    addCheck('scenario',isequaln(reference.result.scenario,candidate.result.scenario), ...
        'Generated physical scenario and realization manifest must match exactly.');
    addCheck('calibrationSha256',sameField(reference.metadata,candidate.metadata,'calibrationSha256'), ...
        'Both runs must use the same calibration file.');
    addCheck('environment',compatibleEnvironment(reference.metadata,candidate.metadata), ...
        'MATLAB, release, and LTE Toolbox versions must match.');
    addCheck('referenceCompleted',strcmp(reference.result.status,'completed'), ...
        ['Reference status: ' char(reference.result.status)]);
    addCheck('candidateCompleted',strcmp(candidate.result.status,'completed'), ...
        ['Candidate status: ' char(candidate.result.status)]);

    fields={'status','stopReason','actualTick','error','packetLog','raLog','observedLog', ...
        'truthLog','phyLog','kpiSummary','kpiTimeSeries','resourceUsage','dataset'};
    for k=1:numel(fields)
        field=fields{k}; present=isfield(reference.result,field) && isfield(candidate.result,field);
        equal=present && isequaln(reference.result.(field),candidate.result.(field));
        addCheck(['result.' field],equal,fieldDetail(present,equal));
    end

    suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv','_resources.csv','_split.csv'};
    if ~isfield(reference.metadata,'exportStem') || ~isfield(candidate.metadata,'exportStem') || ...
            ~strcmp(reference.metadata.exportStem,candidate.metadata.exportStem)
        addCheck('csvStem',false,'Export stems do not match.');
    else
        for k=1:numel(suffixes)
            filename=[reference.metadata.exportStem suffixes{k}];
            [referenceHash,referenceError]=hashExport(reference.metadata,filename);
            [candidateHash,candidateError]=hashExport(candidate.metadata,filename);
            equal=isempty(referenceError) && isempty(candidateError) && strcmp(referenceHash,candidateHash);
            detail=sprintf('reference=%s candidate=%s',referenceHash,candidateHash);
            if ~isempty(referenceError), detail=['reference: ' referenceError]; end
            if ~isempty(candidateError), detail=['candidate: ' candidateError]; end
            addCheck(['csv.' filename],equal,detail);
        end
    end
catch exception
    report.errors{end+1}=struct('identifier',exception.identifier,'message',exception.message);
end
report.passed=isempty(report.errors) && ~isempty(report.checks) && all([report.checks.passed]);
writeReport(report,reportBase);

    function addCheck(checkName,passed,detail)
        report.checks(end+1)=struct('name',checkName,'passed',logical(passed),'detail',char(detail));
    end
end

function bundle=loadBundle(path)
if ~isfile(path), error('nbiot:optimization:MissingBundle','Bundle not found: %s',path); end
loaded=load(path,'result','metadata');
if ~isfield(loaded,'result') || ~isfield(loaded,'metadata')
    error('nbiot:optimization:InvalidBundle','Bundle must contain result and metadata: %s',path);
end
required={'caseId','calibrationSha256','environment','exportDirectory','exportStem'};
for k=1:numel(required)
    if ~isfield(loaded.metadata,required{k})
        error('nbiot:optimization:InvalidBundle','Bundle metadata lacks %s: %s',required{k},path);
    end
end
bundle=loaded;
end

function summary=summarize(bundle,path)
summary=struct('bundleFile',path,'caseId',bundle.metadata.caseId, ...
    'calibrationSha256',bundle.metadata.calibrationSha256, ...
    'environment',bundle.metadata.environment,'sourceManifest',[],'status',bundle.result.status);
if isfield(bundle.metadata,'sourceManifest'), summary.sourceManifest=bundle.metadata.sourceManifest; end
end

function tf=sameField(a,b,name)
tf=isfield(a,name) && isfield(b,name) && isequaln(a.(name),b.(name));
end

function tf=compatibleEnvironment(a,b)
tf=isfield(a,'environment') && isfield(b,'environment') && ...
    isequaln(a.environment,b.environment);
end

function detail=fieldDetail(present,equal)
if ~present, detail='Required result field is missing from one or both bundles.';
elseif equal, detail='Exact isequaln match.';
else, detail='Values differ.';
end
end

function [hex,message]=hashExport(metadata,filename)
hex=''; message='';
path=fullfile(metadata.exportDirectory,filename);
if ~isfile(path), message=['Missing file: ' path]; return; end
try
    fid=fopen(path,'rb');
    if fid<0, error('Unable to open %s.',path); end
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    bytes=fread(fid,Inf,'*uint8');
    digest=java.security.MessageDigest.getInstance('SHA-256');
    digest.update(typecast(bytes(:),'int8'));
    raw=typecast(digest.digest(),'uint8');
    hex=lower(reshape(dec2hex(raw,2).',1,[]));
catch exception
    message=exception.message;
end
end

function writeReport(report,base)
[folder,~,~]=fileparts(base);
if ~isempty(folder) && ~isfolder(folder), mkdir(folder); end
matPath=[base '.mat']; jsonPath=[base '.json'];
save(matPath,'report');
fid=fopen(jsonPath,'w');
if fid<0, error('nbiot:optimization:Report','Cannot write %s.',jsonPath); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,jsonencode(report),'char');
end
