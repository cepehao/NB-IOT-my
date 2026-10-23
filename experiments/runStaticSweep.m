function manifest=runStaticSweep(options)
%RUNSTATICSWEEP Run or resume cases without replacing accepted result bundles.
%   Серия прогонов Static по реализациям с возобновлением.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root); addpath(fullfile(root,'experiments')); setupProject();
if nargin<1, options=struct(); end
options=defaults(options,struct('counts',[100 500 1000 2500 5000], ...
    'burstDurations',[10 100 500],'realizationIds',0:2, ...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'outputFolder',fullfile(root,'results','sweep'),'resume',true, ...
    'runExperimentFcn',[],'scenario',[],'execution',struct()));
options.execution=preflightExecution(options);
suiteClock=tic;
if ~isfolder(options.outputFolder), mkdir(options.outputFolder); end
options.projectRoot=root; options.runner=options.runExperimentFcn;
rows={};
for count=options.counts
    for duration=options.burstDurations
        burstFolder=fullfile(options.outputFolder,sprintf('burst_%04dms',duration));
        if ~isfolder(burstFolder), mkdir(burstFolder); end
        for id=options.realizationIds
            if toc(suiteClock)>=options.execution.maxSuiteSeconds
                error('nbiot:experiments:ExecutionTimeout','Sweep suite wall-time budget exhausted.');
            end
            cfg=nbiot.config.defaultConfig();
            if isfield(options,'config'), cfg=options.config; end
            cfg.simulation.numUE=count;
            cfg.simulation.realizationId=id; cfg.traffic.burstDurationTicks=duration;
            cfg=nbiot.experiments.loadCalibration(cfg,options.calibrationFile);
            metadata=nbiot.experiments.runtimeManifest(cfg,options);
            caseKey=metadata.caseKey; caseFolder=fullfile(burstFolder,caseKey);
            cfg.logging.outputFolder=caseFolder;
            if ~isfolder(caseFolder), mkdir(caseFolder); end

            [accepted,acceptedFolder,acceptedMarker]=findAcceptedCase( ...
                caseFolder,metadata,options.resume);
            if accepted
                status=char(string(acceptedMarker.status));
                elapsedSeconds=double(acceptedMarker.elapsedSeconds);
                resultFile=fullfile(acceptedFolder,char(string(acceptedMarker.resultFile)));
            else
                [result,attemptFolder]=runCase(cfg,caseFolder,metadata,options.runExperimentFcn,options.scenario,options.execution);
                status=char(string(result.status));
                elapsedSeconds=elapsed(result);
                marker=jsondecode(fileread(fullfile(attemptFolder,'case-complete.json')));
                resultFile=fullfile(attemptFolder,char(string(marker.resultFile)));
            end
            rows(end+1,:)={count,duration,id,status,elapsedSeconds,resultFile, ...
                caseKey,metadata.configSha256,metadata.sourceSha256,metadata.calibrationSha256}; %#ok<AGROW>
            updateManifest(options.outputFolder,rows);
            if ~strcmp(status,'completed')
                warning('nbiot:experiments:Failed','Stopped at %s.',resultFile);
                manifest=makeManifest(rows); return
            end
        end
    end
end
manifest=makeManifest(rows);
end

function [accepted,folder,marker]=findAcceptedCase(caseFolder,expected,resume)
accepted=false; folder=''; marker=struct();
if ~resume || ~isfolder(caseFolder), return; end
attempts=dir(fullfile(caseFolder,'run-*'));
attempts=attempts([attempts.isdir]);
for k=numel(attempts):-1:1
    candidate=fullfile(attempts(k).folder,attempts(k).name);
    report=nbiot.results.verifyCase(candidate,expected);
    if report.passed && strcmp(report.status,'completed')
        marker=jsondecode(fileread(fullfile(candidate,'case-complete.json')));
        folder=candidate; accepted=true; return
    end
end
end

function [result,finalFolder]=runCase(cfg,caseFolder,metadata,runner,scenario,execution)
id=char(java.util.UUID.randomUUID());
stage=fullfile(caseFolder,['.staging-' id]);
finalFolder=fullfile(caseFolder,['run-' id]);
if isfolder(stage) || isfolder(finalFolder)
    error('nbiot:experiments:AttemptCollision','Generated attempt directory already exists.');
end
[ok,message]=mkdir(stage);
if ~ok, error('nbiot:experiments:Stage','Cannot create case staging directory: %s',message); end
if isempty(runner)
    result=nbiot.runExperiment(cfg,scenario,execution);
else
    result=runner(cfg);
end
nbiot.results.saveResult(result,stage,metadata);
[ok,message]=movefile(stage,finalFolder);
if ~ok, error('nbiot:experiments:Commit','Cannot commit case directory: %s',message); end
end

function execution=preflightExecution(options)
cfg=nbiot.config.defaultConfig();
count=max(options.counts); cfg.simulation.numUE=count;
budget=nbiot.experiments.validateExecutionBudget(cfg,options.execution, ...
    numel(options.counts)*numel(options.burstDurations)*numel(options.realizationIds));
% budget.numCases is derived, not an accepted user execution field.
execution=rmfield(budget,'numCases');
end

function updateManifest(folder,rows)
manifest=makeManifest(rows); destination=fullfile(folder,'manifest.csv');
temporary=[tempname(folder) '.csv']; cleanup=onCleanup(@() removeTemporary(temporary)); %#ok<NASGU>
writetable(manifest,temporary);
[ok,message]=movefile(temporary,destination,'f');
if ~ok, error('nbiot:experiments:Manifest','Cannot atomically update manifest: %s',message); end
end

function manifest=makeManifest(rows)
manifest=cell2table(rows,'VariableNames',{'numUE','burstDurationTicks', ...
    'realizationId','status','elapsedSeconds','resultFile','caseKey', ...
    'configSha256','sourceSha256','calibrationSha256'});
end

function value=elapsed(result)
value=0;
if isfield(result,'profiling') && isfield(result.profiling,'elapsedSeconds')
    value=double(result.profiling.elapsedSeconds);
end
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
