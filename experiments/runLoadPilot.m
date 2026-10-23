function report=runLoadPilot(options)
%RUNLOADPILOT Measure one full Static case at each planned UE count.
%   Пилот: один прогон Static на каждом уровне числа UE (ТЗ §29).
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
addpath(fullfile(root,'verification','completion','stage-2'));
if nargin<1, options=struct(); end
defaults=struct('designOnly',false,'counts',[100 500 1000 2500 5000],...
    'outputFolder','','stage2AcceptanceFile',fullfile(root,'verification','completion','stage-2','acceptance.json'),...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'),...
    'registryFile',fullfile(root,'experiments','realizationRegistry.json'),'realizationId',[], ...
    'execution',struct());
assert(isstruct(options)&&isscalar(options),'nbiot:experiments:PilotOptions','Scalar options required.');
names=fieldnames(options);
if ~all(ismember(names,fieldnames(defaults)))
    error('nbiot:experiments:PilotOptions','Unknown load-pilot option.');
end
for k=1:numel(names), defaults.(names{k})=options.(names{k}); end
options=defaults;
allowed=[100 500 1000 2500 5000];
if ~isnumeric(options.counts)||~isequal(double(options.counts(:).'),allowed)
    error('nbiot:experiments:PilotOptions','The budget pilot requires the complete ordered count set [100 500 1000 2500 5000].');
end
plan=struct('counts',double(options.counts(:).'),'durationTicks',5000,...
    'burstDurationTicks',100,'policy','Static','requiresStage2Acceptance',true,...
    'scope','One external realization paired across load sizes; no Stage 7 series.');
if options.designOnly, report=plan; return; end
budgetCfg=nbiot.config.defaultConfig(); budgetCfg.simulation.numUE=max(plan.counts);
execution=nbiot.experiments.validateExecutionBudget(budgetCfg,options.execution,numel(plan.counts));
options.execution=rmfield(execution,'numCases');
acceptance=verifyStage2AcceptanceForLoadProbe(options.stage2AcceptanceFile,root, ...
    options.calibrationFile,options.registryFile);
assert(strcmp(version('-release'),'2025b'), ...
    'nbiot:experiments:PilotRelease','The bounded load pilot requires MATLAB R2025b.');
lte=ver('lte'); assert(~isempty(lte), ...
    'nbiot:experiments:PilotToolbox','LTE Toolbox is required for the bounded load pilot.');
if isempty(options.outputFolder)
    options.outputFolder=getenv('NBIOT_PILOT_OUTPUT');
    if isempty(options.outputFolder)
        options.outputFolder=fullfile(root,'verification','completion','stage-3',...
            ['pilot-' char(datetime('now','Format','yyyyMMdd-HHmmss-SSS'))]);
    end
end
if isfolder(options.outputFolder)
    contents=dir(options.outputFolder); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents), error('nbiot:experiments:PilotOutput','Output folder must be empty.'); end
else
    [ok,message]=mkdir(options.outputFolder);
    if ~ok, error('nbiot:experiments:PilotOutput','%s',message); end
end
available=nbiot.experiments.availableRealizationIds(options.registryFile,'stage-3-load-pilot',1000:3999);
if isempty(options.realizationId)
    if isempty(available), error('nbiot:experiments:PilotIds','No unassigned main-range ID remains.'); end
    realizationId=available(1);
else
    realizationId=options.realizationId;
    if ~isscalar(realizationId)||~ismember(realizationId,available)
        error('nbiot:experiments:PilotIds','Requested ID is already held or outside the available main range.');
    end
end
relativeOutput=strrep(options.outputFolder,[root filesep],'');
nbiot.experiments.registerRealizationUse(options.registryFile,'stage-3-load-pilot',...
    realizationId,relativeOutput,'planned');
failureGuard=onCleanup(@() markPilotFailedIfPlanned(options.registryFile,realizationId)); %#ok<NASGU>
clockStart=tic; rows={}; failed=false;
for count=plan.counts
    caseFolder=fullfile(options.outputFolder,sprintf('n%05d-id%04d',count,realizationId));
    wall=tic; engine=NaN; memBytes=NaN; outputBytes=NaN;
    try
        cfg=nbiot.config.defaultConfig();
        cfg.simulation.durationTicks=plan.durationTicks; cfg.simulation.numUE=count;
        cfg.simulation.realizationId=realizationId; cfg.policy.name='Static';
        cfg.traffic.burstStartTick=0; cfg.traffic.burstDurationTicks=plan.burstDurationTicks;
        cfg=nbiot.experiments.loadCalibration(cfg,options.calibrationFile);
        if toc(clockStart)>=options.execution.maxSuiteSeconds
            error('nbiot:experiments:ExecutionTimeout','Load pilot suite time budget exhausted.');
        end
        meta=nbiot.experiments.runStaticCase(cfg,caseFolder,[],[], ...
            struct('projectRoot',root,'execution',options.execution));
        wallSeconds=toc(wall); engine=meta.elapsedSeconds;
        memBytes=matlabMemoryBytes();
        outputBytes=sum([meta.files.bytes]);
        saved=load(meta.resultFile,'kpiSummary','resultStatus'); k=saved.kpiSummary;
        actualTicks=round(k.durationSeconds/cfg.simulation.tickSeconds);
        rows(end+1,:)={count,realizationId,meta.status,wallSeconds,engine,memBytes,...
            outputBytes,k.created,k.delivered,k.dropped,k.unfinished,k.raStarted,k.raSuccess,...
            k.raFailed,actualTicks,meta.resultFile,''}; %#ok<AGROW>
        fprintf('LOAD_PILOT ue=%d id=%d status=%s wall=%.3f engine=%.3f bytes=%d delivered=%d/%d\n',...
            count,realizationId,meta.status,wallSeconds,engine,outputBytes,k.delivered,k.created);
        if ~strcmp(meta.status,'completed'), failed=true; break; end
    catch exception
        rows(end+1,:)={count,realizationId,'failed',toc(wall),engine,memBytes,...
            outputBytes,NaN,NaN,NaN,NaN,NaN,NaN,NaN,NaN,'',exception.message}; %#ok<AGROW>
        failed=true;
        fprintf(2,'LOAD_PILOT_FAILED ue=%d id=%d identifier=%s message=%s\n',...
            count,realizationId,exception.identifier,exception.message);
        break;
    end
end
cases=cell2table(rows,'VariableNames',{'numUE','realizationId','status','wallSeconds',...
    'engineSeconds','matlabMemoryAfterBytes','outputBytes','created','delivered','dropped',...
    'unfinished','raStarted','raSuccess','raFailed','actualTicks','resultFile','error'});
report=struct('plan',plan,'cases',cases,'realizationId',realizationId,...
    'role','stage-3-load-pilot','matlabVersion',version,'matlabRelease',version('-release'),...
    'lteVersion',lte,'sourceManifest',optimizationSourceManifest(root),...
    'runnerSha256',fileHash(fullfile(root,'experiments','runLoadPilot.m')),...
    'acceptanceSha256',fileHash(options.stage2AcceptanceFile),...
    'calibrationSha256',fileHash(options.calibrationFile),...
    'registrySha256BeforeClose',fileHash(options.registryFile),...
    'elapsedSeconds',toc(clockStart),'processPeakMemory','See PowerShell host-memory-summary.json');
save(fullfile(options.outputFolder,'load-pilot.mat'),'report','-v7');
writetable(cases,fullfile(options.outputFolder,'load-pilot.csv'));
status='completed'; if failed, status='failed'; end
nbiot.experiments.updateRealizationUseStatus(options.registryFile,'stage-3-load-pilot',realizationId,status);
report.registrySha256AfterClose=fileHash(options.registryFile);
save(fullfile(options.outputFolder,'load-pilot.mat'),'report','-v7');
if failed, error('nbiot:experiments:PilotFailed','Pilot stopped on the first failed load; inspect load-pilot.csv and case evidence.'); end
fprintf('LOAD_PILOT_DONE id=%d cases=%d seconds=%.3f\n',realizationId,height(cases),report.elapsedSeconds);
clear failureGuard
end

function acceptance=verifyStage2Acceptance(path,root,calibrationFile)
if ~isfile(path), error('nbiot:experiments:PilotGate','Stage 2 requires a technical acceptance.json before the load pilot.'); end
try, acceptance=jsondecode(fileread(path));
catch exception, error('nbiot:experiments:PilotGate','Cannot decode Stage 2 acceptance: %s',exception.message); end
if ~isfield(acceptance,'schemaVersion')||acceptance.schemaVersion~=2||...
        ~isfield(acceptance,'status')||~strcmp(acceptance.status,'accepted-for-stage-3')||...
        ~isfield(acceptance,'humanReviewed')||acceptance.humanReviewed||...
        ~isfield(acceptance,'technicalReview')||...
        ~isfield(acceptance.technicalReview,'reviewer')||...
        isempty(strtrim(char(string(acceptance.technicalReview.reviewer))))||...
        ~isfield(acceptance.technicalReview,'notes')||...
        isempty(strtrim(char(string(acceptance.technicalReview.notes))))||...
        ~isfield(acceptance,'physicalReport')||~isfield(acceptance,'physicalReportSha256')||...
        ~isfield(acceptance,'targetedLog')||~isfield(acceptance,'targetedLogSha256')||...
        ~isfield(acceptance,'artifactSourceHashes')||~isfield(acceptance,'registrySha256')||...
        ~isfield(acceptance,'sourceManifestSha256')||~isfield(acceptance,'calibrationSha256')||...
        ~isfield(acceptance,'receiverRevision')||...
        ~isfield(acceptance,'acceptanceLogicSha256')||...
        ~isfield(acceptance,'artifactComparatorSha256')
    error('nbiot:experiments:PilotGate','Stage 2 technical acceptance record is incomplete.');
end
physical=fullfile(root,strrep(acceptance.physicalReport,'/',filesep));
targeted=fullfile(root,strrep(acceptance.targetedLog,'/',filesep));
if ~isfile(physical)||~isfile(targeted)||~strcmp(fileHash(physical),acceptance.physicalReportSha256)||...
        ~strcmp(fileHash(targeted),acceptance.targetedLogSha256)
    error('nbiot:experiments:PilotGate','Stage 2 evidence is missing or changed after acceptance.');
end
saved=load(physical,'report');
if ~isfield(saved,'report')
    error('nbiot:experiments:PilotGate','Stage 2 physical report is missing its report variable.');
end
currentArtifacts=stage2ArtifactHashes(root);
currentManifest=optimizationSourceManifest(root);
calibrationPath=fullfile(root,'results','nprach-calibration.mat');
if ~isfield(saved.report,'artifactSourceHashes')||~isfield(saved.report,'registrySha256')||...
        ~isfield(saved.report,'sourceManifest')||~isfield(saved.report.sourceManifest,'sha256')||...
        ~isfield(saved.report,'calibrationSha256')||...
        ~stage2PhysicalArtifactsMatch(saved.report.artifactSourceHashes,acceptance.artifactSourceHashes)||...
        ~stage2PhysicalArtifactsMatch(saved.report.artifactSourceHashes,currentArtifacts)||...
        ~strcmp(saved.report.sourceManifest.sha256,acceptance.sourceManifestSha256)||...
        ~strcmp(currentManifest.sha256,acceptance.sourceManifestSha256)||...
        ~strcmp(fileHash(calibrationPath),acceptance.calibrationSha256)||...
        ~strcmp(fileHash(calibrationFile),acceptance.calibrationSha256)||...
        ~strcmp(saved.report.calibrationSha256,acceptance.calibrationSha256)||...
        ~strcmp(nbiot.phy.nprach.receiverRevision(),acceptance.receiverRevision)||...
        ~strcmp(fileHash(which('acceptStage2Evidence')),acceptance.acceptanceLogicSha256)||...
        ~strcmp(fileHash(which('stage2PhysicalArtifactsMatch')),acceptance.artifactComparatorSha256)||...
        ~strcmp(saved.report.registrySha256,acceptance.registrySha256)||...
        ~strcmp(fileHash(fullfile(root,'experiments','realizationRegistry.json')),acceptance.registrySha256)
    error('nbiot:experiments:PilotGate','Stage 2 source code or registry changed after acceptance.');
end
end

function bytes=matlabMemoryBytes()
bytes=NaN;
try, m=memory; if isfield(m,'MemUsedMATLAB'), bytes=double(m.MemUsedMATLAB); end
catch, end
end

function hex=fileHash(path)
fid=fopen(path,'rb'); if fid<0, error('nbiot:experiments:Hash','Cannot read %s.',path); end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8'); if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function markPilotFailedIfPlanned(registryFile,realizationId)
try
    nbiot.experiments.updateRealizationUseStatus(registryFile,'stage-3-load-pilot',realizationId,'failed');
catch
    % Completed/failed allocations are already closed; only abandoned plans need this fallback.
end
end
