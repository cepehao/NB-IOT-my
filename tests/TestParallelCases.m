classdef TestParallelCases < matlab.unittest.TestCase
    methods (Test)
        function caseAttemptsUseSeparateFolders(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFixture(folder));
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            caseFolder=fullfile(folder,'case'); cfg.logging.outputFolder=caseFolder;
            metadata=caseMetadata(cfg,'isolated-case',repmat('a',1,64));

            first=nbiot.experiments.runStaticCase(cfg,caseFolder,metadata,@mockResult);
            second=nbiot.experiments.runStaticCase(cfg,caseFolder,metadata,@mockResult);

            t.verifyEqual(first.status,'completed'); t.verifyEqual(second.status,'completed');
            t.verifyNotEqual(first.attemptFolder,second.attemptFolder);
            t.verifyTrue(nbiot.results.verifyCase(first.attemptFolder,metadata).passed);
            t.verifyTrue(nbiot.results.verifyCase(second.attemptFolder,metadata).passed);
        end

        function workerFailureLeavesUnacceptedStagingFolder(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFixture(folder));
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            caseFolder=fullfile(folder,'case'); cfg.logging.outputFolder=caseFolder;
            metadata=caseMetadata(cfg,'failed-case',repmat('a',1,64));

            t.verifyError(@() nbiot.experiments.runStaticCase( ...
                cfg,caseFolder,metadata,@failWorker),'fixture:WorkerFailure');
            staging=dir(fullfile(caseFolder,'.staging-*'));

            t.verifyEqual(numel(staging),1);
            t.verifyFalse(isfile(fullfile(staging(1).folder,staging(1).name,'case-complete.json')));
            t.verifyFalse(nbiot.results.verifyCase( ...
                fullfile(staging(1).folder,staging(1).name),metadata).passed);
        end

        function parallelRunnerReusesAcceptedCaseWithoutStartingPool(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFixture(folder));
            calibrationFile=fullfile(folder,'calibration.mat'); writeCalibration(calibrationFile);
            outputFolder=fullfile(folder,'sweep');
            burstFolder=fullfile(outputFolder,'burst_0100ms');
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
            cfg.simulation.realizationId=0; cfg.traffic.burstDurationTicks=100;
            cfg=nbiot.experiments.loadCalibration(cfg,calibrationFile);
            options=struct('counts',1,'burstDurations',100,'realizationIds',0, ...
                'calibrationFile',calibrationFile,'outputFolder',outputFolder, ...
                'resume',true,'numWorkers',2,'runExperimentFcn',@mockResult, ...
                'runner',@mockResult,'runnerDependenciesDeclared',true, ...
                'runnerFiles',{{[mfilename('fullpath') '.m']}});
            metadata=nbiot.experiments.runtimeManifest(cfg,options);
            caseFolder=fullfile(burstFolder,metadata.caseKey); cfg.logging.outputFolder=caseFolder;
            created=nbiot.experiments.runStaticCase(cfg,caseFolder,metadata,@mockResult,options);

            manifest=runStaticSweepParallel(options);
            attempts=dir(fullfile(caseFolder,'run-*'));

            t.verifyEqual(height(manifest),1);
            t.verifyEqual(manifest.resultFile{1},created.resultFile);
            t.verifyEqual(numel(attempts),1);
            t.verifyEqual(manifest.status{1},'completed');
        end

        function invalidWorkerCountIsRejected(t)
            t.verifyError(@() runStaticSweepParallel(struct('numWorkers',0)), ...
                'nbiot:experiments:ParallelWorkers');
        end
    end
end

function metadata=caseMetadata(cfg,caseKey,calibrationSha256)
root=fileparts(fileparts(mfilename('fullpath')));
source=optimizationSourceManifest(root);
environment=struct('matlabVersion',version,'release',version('-release'), ...
    'lteVersion',ver('lte'),'computer',computer, ...
    'validatedInMatlab',false,'sourceProfile','static-v1');
metadata=struct('caseKey',caseKey,'configSha256',nbiot.results.configSha256(cfg), ...
    'sourceSha256',source.sha256,'calibrationSha256',calibrationSha256, ...
    'environment',environment);
end

function result=mockResult(cfg)
environment=struct('matlabVersion',version,'release',version('-release'), ...
    'lteVersion',ver('lte'),'computer',computer, ...
    'validatedInMatlab',false,'sourceProfile','static-v1');
ue=(1:cfg.simulation.numUE).'; z=zeros(cfg.simulation.numUE,1);
ueSummary=table(ue,z,z,z,z,'VariableNames', ...
    {'ueId','created','delivered','dropped','unfinished'});
kpiTimeSeries=table(0,0,0,'VariableNames',{'windowId','startTick','endTick'});
observations=table(0,0,'VariableNames',{'realizationId','windowId'});
targets=table(0,0,'VariableNames',{'realizationId','windowId'});
split=table("train",1,'VariableNames',{'split','rows'});
resourceUsage=table("cpu",0,'VariableNames',{'resource','units'});
result=struct('config',cfg,'status','completed','environment',environment, ...
    'kpiSummary',struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
    'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0), ...
    'ueSummary',ueSummary,'kpiTimeSeries',kpiTimeSeries,'resourceUsage',resourceUsage, ...
    'dataset',struct('observations',observations,'targets',targets,'manifest',split), ...
    'profiling',struct('elapsedSeconds',0.5));
end

function result=failWorker(~)
error('fixture:WorkerFailure','Injected worker failure.');
result=[];
end

function writeCalibration(path)
cfg=nbiot.config.defaultConfig();
profile=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId, ...
    'format',cfg.ra.format,'periodTicks',cfg.ra.periodTicks, ...
    'numSubcarriers',cfg.ra.numSubcarriers,'repetitions',cfg.ra.repetitions, ...
    'sampleRateHz',cfg.simulation.sampleRateHz, ...
    'fractionalFilterLength',cfg.channel.fractionalFilterLength,...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(),'cfoLimitHz',cfg.channel.cfoLimitHz);
report=struct('accepted',true,'threshold',1,'profile',profile, ...
    'cfoGridHz',cfg.phy.nprachCfoGridHz);
save(path,'report');
end

function hex=fileHash(path)
fid=fopen(path,'rb'); bytes=fread(fid,Inf,'*uint8'); fclose(fid);
digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(bytes(:),'int8'));
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function removeFixture(folder)
if isfolder(folder), rmdir(folder,'s'); end
end


