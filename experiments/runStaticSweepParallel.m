function manifest=runStaticSweepParallel(options)
%RUNSTATICSWEEPPARALLEL Execute independent realizations on process workers.
%   Та же серия на параллельных процессах (parfor по реализациям).
if nargin<1, options=struct(); end
if ~isfield(options,'numWorkers'), options.numWorkers=2; end
if ~isnumeric(options.numWorkers) || ~isscalar(options.numWorkers) || ...
        ~isfinite(options.numWorkers) || options.numWorkers<1 || ...
        fix(options.numWorkers)~=options.numWorkers
    error('nbiot:experiments:ParallelWorkers','numWorkers must be a positive integer.');
end
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root); addpath(fullfile(root,'experiments')); setupProject();
options=defaults(options,struct('counts',[100 500 1000 2500 5000], ...
    'burstDurations',[10 100 500],'realizationIds',0:2, ...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'outputFolder',fullfile(root,'results','sweep-parallel'),'resume',true,'runExperimentFcn',[], ...
    'execution',struct()));
validateCases(options);
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=max(options.counts);
budget=nbiot.experiments.validateExecutionBudget(cfg,options.execution, ...
    numel(options.counts)*numel(options.burstDurations)*numel(options.realizationIds));
options.execution=rmfield(budget,'numCases');
suiteClock=tic;
options.projectRoot=root; options.runner=options.runExperimentFcn;
rows={}; jobs={}; jobRows=[];
for count=options.counts
    for duration=options.burstDurations
        burstFolder=fullfile(options.outputFolder,sprintf('burst_%04dms',duration));
        for id=options.realizationIds
            cfg=nbiot.config.defaultConfig();
            if isfield(options,'config'), cfg=options.config; end
            cfg.simulation.numUE=count;
            cfg.simulation.realizationId=id; cfg.traffic.burstDurationTicks=duration;
            cfg=nbiot.experiments.loadCalibration(cfg,options.calibrationFile);
            metadata=nbiot.experiments.runtimeManifest(cfg,options);
            caseKey=metadata.caseKey; caseFolder=fullfile(burstFolder,caseKey);
            cfg.logging.outputFolder=caseFolder;
            sourceSha256=metadata.sourceSha256; calibrationSha256=metadata.calibrationSha256;
            [accepted,attemptFolder,marker]=findAcceptedCase(caseFolder,metadata,options.resume);
            rowIndex=size(rows,1)+1;
            if accepted
                resultFile=fullfile(attemptFolder,char(string(marker.resultFile)));
                rows(rowIndex,:)={count,duration,id,char(string(marker.status)), ...
                    double(marker.elapsedSeconds),resultFile,caseKey,metadata.configSha256, ...
                    sourceSha256,calibrationSha256};
            else
                rows(rowIndex,:)={count,duration,id,'pending',NaN,'',caseKey, ...
                    metadata.configSha256,sourceSha256,calibrationSha256};
                jobs{end+1,1}=struct('cfg',cfg,'caseFolder',caseFolder, ...
                    'metadata',metadata,'caseKey',caseKey); %#ok<AGROW>
                jobRows(end+1,1)=rowIndex; %#ok<AGROW>
            end
        end
    end
end

if ~isempty(jobs)
    if strcmp(options.execution.profile,'local-development')
        error('nbiot:experiments:ExecutionBudget', ...
            'Local development uses sequential cases; new parallel jobs belong on the external machine.');
    end
    if toc(suiteClock)>=options.execution.maxSuiteSeconds
        error('nbiot:experiments:ExecutionTimeout','Parallel suite time budget exhausted before pool startup.');
    end
    pool=processPool(options.numWorkers);
    ownsPool=pool.created; pool=pool.value;
    poolCleanup=[];
    if ownsPool, poolCleanup=onCleanup(@() closePool(pool)); end %#ok<NASGU>
    workerMeta=cell(size(jobs));
    futures=parallel.FevalFuture.empty(0,1);
    try
        if toc(suiteClock)>=options.execution.maxSuiteSeconds
            error('nbiot:experiments:ExecutionTimeout','Parallel pool startup exhausted the suite budget.');
        end
        for k=1:numel(jobs)
            futures(k)=parfeval(pool,@runWorker,1,jobs{k},options.runExperimentFcn,options);
        end
        for k=1:numel(jobs)
            remaining=options.execution.maxSuiteSeconds-toc(suiteClock);
            if remaining<=0
                error('nbiot:experiments:ExecutionTimeout','Parallel suite time budget exhausted.');
            end
            [index,meta]=fetchNext(futures,remaining);
            if isempty(index)
                error('nbiot:experiments:ExecutionTimeout','Parallel suite time budget exhausted.');
            end
            workerMeta{index}=meta;
        end
    catch exception
        if ~isempty(futures), cancel(futures); end
        if strcmp(exception.identifier,'nbiot:experiments:ExecutionTimeout'), rethrow(exception); end
        error('nbiot:experiments:ParallelExecution', ...
            'Process pool stopped; accepted case folders remain available for resume. %s',exception.message);
    end
    for k=1:numel(workerMeta)
        meta=workerMeta{k}; rowIndex=jobRows(k);
        rows{rowIndex,4}=char(string(meta.status));
        rows{rowIndex,5}=double(meta.elapsedSeconds);
        rows{rowIndex,6}=char(string(meta.resultFile));
        if strcmp(meta.status,'worker-error')
            warning('nbiot:experiments:WorkerFailed','Case %s failed on worker (%s): %s', ...
                meta.caseKey,meta.errorIdentifier,meta.errorMessage);
        end
    end
end
manifest=makeManifest(rows);
if ~isfolder(options.outputFolder), mkdir(options.outputFolder); end
updateManifest(options.outputFolder,manifest);
end

function meta=runWorker(job,runner,options)
try
    meta=nbiot.experiments.runStaticCase(job.cfg,job.caseFolder,job.metadata,runner,options);
catch exception
    meta=struct('caseKey',job.caseKey,'status','worker-error','elapsedSeconds',NaN, ...
        'resultFile','','errorIdentifier',exception.identifier,'errorMessage',exception.message);
end
end

function validateCases(options)
groups={'counts','burstDurations','realizationIds'};
for k=1:numel(groups)
    name=groups{k}; values=options.(name);
    validateattributes(values,{'numeric'},{'vector','integer','nonnegative','nonempty', ...
        'finite'},mfilename,name);
    if numel(unique(values))~=numel(values)
        error('nbiot:experiments:DuplicateCase','Option %s contains duplicate values.',name);
    end
end
if any(options.counts<1) || any(options.burstDurations<1) || any(options.realizationIds>4095)
    error('nbiot:experiments:InvalidCase','Counts, burst durations or realization IDs are out of range.');
end
end

function [accepted,folder,marker]=findAcceptedCase(caseFolder,expected,resume)
accepted=false; folder=''; marker=struct();
if ~resume || ~isfolder(caseFolder), return; end
attempts=dir(fullfile(caseFolder,'run-*')); attempts=attempts([attempts.isdir]);
for k=numel(attempts):-1:1
    candidate=fullfile(attempts(k).folder,attempts(k).name);
    report=nbiot.results.verifyCase(candidate,expected);
    if report.passed && strcmp(report.status,'completed')
        folder=candidate; marker=jsondecode(fileread(fullfile(candidate,'case-complete.json')));
        accepted=true; return
    end
end
end

function value=processPool(workers)
if isempty(ver('parallel')) || ~license('test','Distrib_Computing_Toolbox')
    error('nbiot:experiments:ParallelUnavailable', ...
        'Parallel Computing Toolbox is unavailable; use runStaticSweep for sequential runs.');
end
cluster=parcluster('Processes');
if workers>cluster.NumWorkers
    error('nbiot:experiments:ParallelWorkers', ...
        'Requested %d workers; process profile allows %d. Sequential runner remains available.', ...
        workers,cluster.NumWorkers);
end
pool=gcp('nocreate'); created=false;
if isempty(pool)
    try
        pool=parpool('Processes',workers); created=true;
    catch exception
        error('nbiot:experiments:ParallelUnavailable', ...
            'Could not start a %d-worker process pool (%s). Use runStaticSweep sequentially.', ...
            workers,exception.message);
    end
elseif ~contains(class(pool),'ProcessPool')
    error('nbiot:experiments:PoolType', ...
        'An existing non-process pool is active; run the sequential sweep or close that pool explicitly.');
elseif pool.NumWorkers~=workers
    error('nbiot:experiments:PoolSize', ...
        'Existing pool has %d workers, requested %d. Close or reuse a matching process pool.', ...
        pool.NumWorkers,workers);
end
value=struct('value',pool,'created',created);
end

function closePool(pool)
try, delete(pool); catch, end
end

function manifest=makeManifest(rows)
manifest=cell2table(rows,'VariableNames',{'numUE','burstDurationTicks', ...
    'realizationId','status','elapsedSeconds','resultFile','caseKey', ...
    'configSha256','sourceSha256','calibrationSha256'});
end

function updateManifest(folder,manifest)
destination=fullfile(folder,'manifest.csv');
temporary=[tempname(folder) '.csv']; cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
writetable(manifest,temporary);
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:experiments:Manifest','Cannot atomically update manifest: %s',message); end
end

function value=defaults(value,base)
names=fieldnames(base);
for k=1:numel(names)
    if ~isfield(value,names{k}), value.(names{k})=base.(names{k}); end
end
end

function removeTemporary(path)
if isfile(path), delete(path); end
end
