classdef TestRuntimeManifest < matlab.unittest.TestCase
    methods (Test)
        function canonicalConfigurationAndOutputRelocation(t)
            [cfg,o]=fixture(t); a=nbiot.experiments.runtimeManifest(cfg,o);
            cfg=orderfields(cfg,flipud(fieldnames(cfg))); cfg.logging.outputFolder='elsewhere';
            b=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyEqual(a.caseKey,b.caseKey); t.verifyEqual(a.canonicalConfigSha256,b.canonicalConfigSha256);
            t.verifyEqual(a.configSha256,b.configSha256);
            t.verifyEqual(a.resultSchemaVersion,2); t.verifyEqual(a.runtimeVersion,1);
        end
        function adaptivePolicyOverrideChangesCaseIdentity(t)
            [cfg,o]=fixture(t); cfg.policy.name='Adaptive-P';
            o.controllerPolicy=struct('windowTicks',500,'maximumLoad',100000, ...
                'accessLoadThresholds',[1 3 6 10]);
            a=nbiot.experiments.runtimeManifest(cfg,o);
            o.controllerPolicy.maximumLoad=50000;
            b=nbiot.experiments.runtimeManifest(cfg,o);

            t.verifyEqual(a.resultSchemaVersion,3);
            t.verifyNotEqual(a.policySha256,b.policySha256);
            t.verifyNotEqual(a.caseKey,b.caseKey);
            t.verifyEqual(a.controllerPolicy.maximumLoad,100000);
        end
        function adaptiveVectorPolicySurvivesJsonMarkerRoundTrip(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1;
            cfg.policy.name='Adaptive-P'; cfg.policy.windowTicks=500;
            cfg.dataset.windowTicks=500;
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            result=emptyResult(cfg,metadata.environment);
            result.controllerLog=struct('decisionTick',{},'effectiveTick',{}, ...
                'featureWindowEndTick',{},'method',{},'estimateValue',{}, ...
                'estimateValid',{},'proposedAccessProbability',{},'proposedRaShare',{}, ...
                'appliedAccessProbability',{},'appliedRaShare',{},'applied',{}, ...
                'switched',{},'reason',{},'estimateReason',{}, ...
                'errorIdentifier',{},'errorMessage',{},'featureValuesJson',{});
            result.controllerLogSchemaVersion=1;
            result.controllerPolicy=metadata.controllerPolicy;

            folder=fullfile(o.projectRoot,'adaptive-vector-policy');
            nbiot.results.saveResult(result,folder,metadata);

            t.verifyTrue(nbiot.results.verifyCase(folder,metadata).passed);
        end
        function methodProbabilitySharesTrafficAndRealizationSeparateKeys(t)
            [cfg,o]=fixture(t); a=nbiot.experiments.runtimeManifest(cfg,o);
            changes={@method,@probability,@share,@traffic,@realization};
            for k=1:numel(changes)
                b=nbiot.experiments.runtimeManifest(changes{k}(cfg),o);
                t.verifyNotEqual(a.caseKey,b.caseKey);
            end
            o.scenario=struct('arrivals',1); b=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEqual(a.caseKey,b.caseKey);
        end
        function documentationIsExcludedButProductionCodeIsHashed(t)
            [cfg,o]=fixture(t); a=nbiot.experiments.runtimeManifest(cfg,o);
            write(fullfile(o.projectRoot,'README.md'),'changed');
            b=nbiot.experiments.runtimeManifest(cfg,o); t.verifyEqual(a.sourceSha256,b.sourceSha256);
            write(fullfile(o.projectRoot,'src','f.m'),'function y=f; y=2; end');
            b=nbiot.experiments.runtimeManifest(cfg,o); t.verifyNotEqual(a.sourceSha256,b.sourceSha256);
        end
        function calibrationModelPolicyAndInputAreIndependent(t)
            [cfg,o]=fixture(t); a=nbiot.experiments.runtimeManifest(cfg,o);
            pairs={'calibrationFile','calibrationSha256';'modelFiles','modelSha256'; ...
                'policyFiles','policySha256';'inputFiles','inputSha256'};
            for k=1:size(pairs,1)
                value=o.(pairs{k,1}); if iscell(value), value=value{1}; end
                write(value,['replacement' num2str(k)]);
                b=nbiot.experiments.runtimeManifest(cfg,o);
                t.verifyNotEqual(a.(pairs{k,2}),b.(pairs{k,2}));
                t.verifyEqual(a.sourceSha256,b.sourceSha256);
                a=b;
            end
        end
        function acceptanceAndPolicyContentsChangeRuntimeIdentity(t)
            [cfg,o]=fixture(t); cfg.policy.name='Adaptive-P';
            cfg.policy.windowTicks=500; cfg.dataset.windowTicks=500;
            o.controllerPolicy=adaptiveDefaults();
            acceptanceFile=fullfile(o.projectRoot,'acceptance.json');
            policyFile=fullfile(o.projectRoot,'policy.json');
            write(acceptanceFile,'acceptance-v1');
            write(policyFile,'policy-v1');
            o.modelAcceptanceFile=acceptanceFile;
            o.policyFiles={policyFile};
            o.admissionEvidenceDigest=repmat('a',1,64);
            a=nbiot.experiments.runtimeManifest(cfg,o);

            write(acceptanceFile,'acceptance-v2');
            b=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEqual(a.inputSha256,b.inputSha256);
            t.verifyNotEqual(a.caseKey,b.caseKey);

            write(acceptanceFile,'acceptance-v1');
            write(policyFile,'policy-v2');
            c=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEqual(a.policySha256,c.policySha256);
            t.verifyNotEqual(a.caseKey,c.caseKey);

            o.policyFiles={policyFile};
            o.admissionEvidenceDigest=repmat('b',1,64);
            d=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEqual(a.inputSha256,d.inputSha256);
            t.verifyNotEqual(a.caseKey,d.caseKey);
        end
        function changedEvidenceFileInvalidatesPreflightInputSnapshot(t)
            [cfg,o]=fixture(t);
            evidenceFile=fullfile(o.projectRoot,'evaluation.json');
            write(evidenceFile,'validated evidence bytes');
            o.inputFiles={evidenceFile};
            o.expectedInputFileHashes=struct('path',evidenceFile, ...
                'sha256',nbiot.ml.fileSha256(evidenceFile));
            before=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEmpty(before.inputSha256);

            write(evidenceFile,'changed after preflight');

            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o), ...
                'nbiot:ml:ModelAcceptance', ...
                'A changed evidence input must not retain a preflight identity.');
        end
        function packageRelocationPreservesContentIdentity(t)
            [cfg,o]=fixture(t);
            acceptanceFile=fullfile(o.projectRoot,'acceptance.json');
            policyFile=fullfile(o.projectRoot,'policy.json');
            write(acceptanceFile,'acceptance'); write(policyFile,'policy-json');
            o.modelAcceptanceFile=acceptanceFile; o.policyFiles={policyFile};
            o.admissionEvidenceDigest=repmat('a',1,64);
            movedRoot=tempname; mkdir(movedRoot);
            t.addTeardown(@() removeFolder(movedRoot));
            copyfile(fullfile(o.projectRoot,'src'),fullfile(movedRoot,'src'));
            for name={'calibration.mat','model.mat','policy.m','input.dat', ...
                    'acceptance.json','policy.json'}
                copyfile(fullfile(o.projectRoot,name{1}),fullfile(movedRoot,name{1}));
            end
            before=nbiot.experiments.runtimeManifest(cfg,o);
            moved=o; moved.projectRoot=movedRoot;
            moved.calibrationFile=rebasePath(o.calibrationFile,o.projectRoot,movedRoot);
            moved.modelFiles={rebasePath(o.modelFiles{1},o.projectRoot,movedRoot)};
            moved.policyFiles={rebasePath(policyFile,o.projectRoot,movedRoot)};
            moved.inputFiles={rebasePath(o.inputFiles{1},o.projectRoot,movedRoot)};
            moved.modelAcceptanceFile=rebasePath(acceptanceFile,o.projectRoot,movedRoot);
            after=nbiot.experiments.runtimeManifest(cfg,moved);

            t.verifyEqual(before.calibrationSha256,after.calibrationSha256);
            t.verifyEqual(before.modelSha256,after.modelSha256);
            t.verifyEqual(before.policySha256,after.policySha256);
            t.verifyEqual(before.inputSha256,after.inputSha256);
            t.verifyEqual(before.sourceSha256,after.sourceSha256);
            t.verifyEqual(before.caseKey,after.caseKey);
        end
        function runnerMustBeRegisteredAndHashed(t)
            [cfg,o]=fixture(t); o.runner=@fixtureRunner;
            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o),'nbiot:experiments:UnregisteredDependency');
            o.runnerDependenciesDeclared=true; o.runnerFiles={mfilename('fullpath')};
            o.runnerFiles{1}=[o.runnerFiles{1} '.m'];
            a=nbiot.experiments.runtimeManifest(cfg,o); t.verifyNotEmpty(a.runnerSha256);
            o.runnerFiles{2}=o.inputFiles{1}; write(o.runnerFiles{2},'runner-v1');
            a=nbiot.experiments.runtimeManifest(cfg,o); write(o.runnerFiles{2},'runner-v2');
            b=nbiot.experiments.runtimeManifest(cfg,o); t.verifyNotEqual(a.runnerSha256,b.runnerSha256);
        end
        function missingExternalFileFailsClosed(t)
            [cfg,o]=fixture(t); o.modelFiles={fullfile(o.projectRoot,'missing.mat')};
            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o),'nbiot:experiments:UnregisteredDependency');
        end
        function versionedSaveReadbackAndChangedIdentities(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1;
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            folder=fullfile(o.projectRoot,'bundle'); result=emptyResult(cfg,metadata.environment);
            nbiot.results.saveResult(result,folder,metadata);
            marker=jsondecode(fileread(fullfile(folder,'case-complete.json')));
            t.verifyEqual(marker.manifestVersion,2); t.verifyEqual(marker.runtimeVersion,1);
            t.verifyTrue(nbiot.results.verifyCase(folder,metadata).passed);
            fields={'modelSha256','policySha256','runnerSha256','inputSha256','calibrationSha256','sourceSha256'};
            for k=1:numel(fields)
                expected=metadata; expected.(fields{k})=repmat('0',1,64);
                t.verifyFalse(nbiot.results.verifyCase(folder,expected).passed);
            end
            marker.resultSchemaVersion=999; writeJson(fullfile(folder,'case-complete.json'),marker);
            t.verifyFalse(nbiot.results.verifyCase(folder,metadata).passed);
        end
        function damagedRuntimeIdentityIsRejected(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1;
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            folder=fullfile(o.projectRoot,'bundle'); result=emptyResult(cfg,metadata.environment);
            nbiot.results.saveResult(result,folder,metadata);
            path=fullfile(folder,'case-complete.json'); marker=jsondecode(fileread(path));
            marker=rmfield(marker,'modelSha256'); writeJson(path,marker);
            report=nbiot.results.verifyCase(folder,metadata); t.verifyFalse(report.passed);
        end
        function calculateVerifyResumeAndExternalReplacement(t)
            [~,o]=fixture(t); writeCalibration(o.calibrationFile);
            counter=fullfile(o.projectRoot,'runs.txt'); runner=countingRunner(counter);
            options=struct('counts',1,'burstDurations',100,'realizationIds',0, ...
                'calibrationFile',o.calibrationFile,'outputFolder',fullfile(o.projectRoot,'sweep'), ...
                'resume',true,'runExperimentFcn',runner,'runnerDependenciesDeclared',true, ...
                'runnerFiles',{{[mfilename('fullpath') '.m']}},'runnerInputs',struct('path',counter), ...
                'modelFiles',{o.modelFiles});
            a=runStaticSweep(options); b=runStaticSweep(options);
            t.verifyEqual(a.resultFile,b.resultFile); t.verifyEqual(countRuns(counter),1);
            t.verifyTrue(nbiot.results.verifyCase(fileparts(a.resultFile{1})).passed);
            write(o.modelFiles{1},'changed model'); c=runStaticSweep(options);
            t.verifyNotEqual(c.caseKey,a.caseKey); t.verifyEqual(countRuns(counter),2);
            cfg=nbiot.config.defaultConfig(); report=calibrationReport(cfg); report.threshold=.5;
            save(o.calibrationFile,'report'); d=runStaticSweep(options);
            t.verifyNotEqual(d.resultFile,c.resultFile); t.verifyEqual(countRuns(counter),3);
        end
        function sweepRejectsUnregisteredRunnerBeforeExecution(t)
            [~,o]=fixture(t); writeCalibration(o.calibrationFile);
            options=struct('counts',1,'burstDurations',100,'realizationIds',0, ...
                'calibrationFile',o.calibrationFile,'outputFolder',fullfile(o.projectRoot,'sweep'), ...
                'runExperimentFcn',@fixtureRunner);
            t.verifyError(@() runStaticSweep(options),'nbiot:experiments:UnregisteredDependency');
        end
        function equivalentConfigOrderResumesSameCase(t)
            [~,o]=fixture(t); writeCalibration(o.calibrationFile);
            counter=fullfile(o.projectRoot,'runs.txt'); runner=countingRunner(counter);
            cfg=nbiot.config.defaultConfig();
            options=struct('counts',1,'burstDurations',100,'realizationIds',0, ...
                'calibrationFile',o.calibrationFile,'outputFolder',fullfile(o.projectRoot,'sweep'), ...
                'resume',true,'config',cfg,'runExperimentFcn',runner,'runnerDependenciesDeclared',true, ...
                'runnerFiles',{{[mfilename('fullpath') '.m']}},'runnerInputs',struct('path',counter));
            a=runStaticSweep(options);
            cfg.policy=orderfields(cfg.policy,flipud(fieldnames(cfg.policy)));
            options.config=orderfields(cfg,flipud(fieldnames(cfg)));
            b=runStaticSweep(options);
            t.verifyEqual(a.caseKey,b.caseKey); t.verifyEqual(a.resultFile,b.resultFile);
            t.verifyEqual(countRuns(counter),1);
        end
        function malformedVersionsAndMissingRuntimeFields(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1;
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            folder=fullfile(o.projectRoot,'bundle'); result=emptyResult(cfg,metadata.environment);
            nbiot.results.saveResult(result,folder,metadata);
            path=fullfile(folder,'case-complete.json'); original=jsondecode(fileread(path));
            for field={'runtimeVersion','manifestVersion','resultSchemaVersion'}
                marker=original; marker.(field{1})=999; writeJson(path,marker);
                t.verifyFalse(nbiot.results.verifyCase(folder).passed);
            end
            for field={'canonicalConfigSha256','runnerSha256','policySha256','inputSha256'}
                marker=rmfield(original,field{1}); writeJson(path,marker);
                t.verifyFalse(nbiot.results.verifyCase(folder).passed);
            end
            marker=original; marker.modelSha256='broken'; writeJson(path,marker);
            t.verifyFalse(nbiot.results.verifyCase(folder).passed);
            marker=original; marker.resultFile='../outside.mat'; writeJson(path,marker);
            t.verifyFalse(nbiot.results.verifyCase(folder).passed);
            write(path,'[]'); t.verifyFalse(nbiot.results.verifyCase(folder).passed);
        end
        function incompatibleInMemorySchemaIsRejected(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1;
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            result=emptyResult(cfg,metadata.environment); result.resultSchemaVersion=999;
            t.verifyError(@() nbiot.results.saveResult(result,fullfile(o.projectRoot,'bundle'),metadata), ...
                'nbiot:results:Metadata');
        end
        function unknownExternalHookFailsClosed(t)
            [cfg,o]=fixture(t); o.externalHook=@fixtureRunner;
            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o),'nbiot:experiments:UnregisteredDependency');
        end
        function capturedRunnerInputsMustBeCompleteAndDifferent(t)
            [cfg,o]=fixture(t); o.runner=numericalRunner(1);
            o.runnerDependenciesDeclared=true; o.runnerFiles={[mfilename('fullpath') '.m']};
            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o),'nbiot:experiments:UnregisteredDependency');
            o.runnerInputs=struct('value',1); a=nbiot.experiments.runtimeManifest(cfg,o);
            o.runner=numericalRunner(2);
            t.verifyError(@() nbiot.experiments.runtimeManifest(cfg,o),'nbiot:experiments:UnregisteredDependency');
            o.runnerInputs=struct('value',2); b=nbiot.experiments.runtimeManifest(cfg,o);
            t.verifyNotEqual(a.runnerSha256,b.runnerSha256); t.verifyNotEqual(a.caseKey,b.caseKey);
        end
        function capturedNumericStorageCannotAlias(t)
            [cfg,o]=fixture(t); o.runnerDependenciesDeclared=true;
            o.runnerFiles={[mfilename('fullpath') '.m']};
            value=eye(2); o.runner=numericalRunner(value); o.runnerInputs=struct('value',value);
            a=nbiot.experiments.runtimeManifest(cfg,o);
            value=sparse(eye(2)); o.runner=numericalRunner(value); o.runnerInputs=struct('value',value);
            b=nbiot.experiments.runtimeManifest(cfg,o); t.verifyNotEqual(a.runnerSha256,b.runnerSha256);
            value=complex(eye(2),zeros(2)); o.runner=numericalRunner(value); o.runnerInputs=struct('value',value);
            c=nbiot.experiments.runtimeManifest(cfg,o); t.verifyNotEqual(a.runnerSha256,c.runnerSha256);
        end
        function schemaTwoCannotDowngradeMarkerVersion(t)
            [cfg,o]=fixture(t); cfg.simulation.numUE=1; metadata=nbiot.experiments.runtimeManifest(cfg,o);
            folder=fullfile(o.projectRoot,'bundle'); nbiot.results.saveResult(emptyResult(cfg,metadata.environment),folder,metadata);
            path=fullfile(folder,'case-complete.json'); marker=jsondecode(fileread(path)); marker.manifestVersion=1;
            writeJson(path,marker); t.verifyFalse(nbiot.results.verifyCase(folder).passed);
        end
        function suppliedScenarioIsUsedBySequentialAndCaseRunners(t)
            [cfg,o]=fixture(t); writeCalibration(o.calibrationFile);
            cfg.simulation.numUE=1; cfg.simulation.durationTicks=80; cfg.traffic.kind='none';
            sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId);
            scenario=nbiot.scenario.buildScenario(cfg,sources); scenario.scenarioLabel='registered-external-fixture';
            options=struct('counts',1,'burstDurations',100,'realizationIds',0, ...
                'calibrationFile',o.calibrationFile,'outputFolder',fullfile(o.projectRoot,'sweep'), ...
                'resume',true,'config',cfg,'scenario',scenario);
            a=runStaticSweep(options); saved=load(a.resultFile{1},'result');
            t.verifyEqual(saved.result.scenario,scenario);
            cfg=nbiot.experiments.loadCalibration(cfg,o.calibrationFile);
            o.scenario=scenario; o.projectRoot=fileparts(fileparts(mfilename('fullpath')));
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            b=nbiot.experiments.runStaticCase(cfg,fullfile(fileparts(o.calibrationFile),'scenario-case'),metadata,[],o);
            t.addTeardown(@() rmdir(b.caseFolder,'s'));
            saved=load(b.resultFile,'result'); t.verifyEqual(saved.result.scenario,scenario);
        end
        function loadedCalibrationCarriesItsFileDigestIntoRuntimeIdentity(t)
            [cfg,o]=fixture(t); writeCalibration(o.calibrationFile);

            cfg=nbiot.experiments.loadCalibration(cfg,o.calibrationFile);
            metadata=nbiot.experiments.runtimeManifest(cfg,o);
            oWithoutCalibrationPath=rmfield(o,'calibrationFile');
            metadataWithoutPath=nbiot.experiments.runtimeManifest(cfg,oWithoutCalibrationPath);

            t.verifyEqual(cfg.calibrationFileSha256,nbiot.ml.fileSha256(o.calibrationFile));
            t.verifyEqual(metadata.calibrationSha256,nbiot.ml.fileSha256(o.calibrationFile));
            t.verifyEqual(metadataWithoutPath.calibrationSha256,nbiot.ml.fileSha256(o.calibrationFile));
        end
    end
end

function [cfg,o]=fixture(t)
root=tempname; mkdir(root); mkdir(fullfile(root,'src'));
t.addTeardown(@() rmdir(root,'s'));
write(fullfile(root,'src','f.m'),'function y=f; y=1; end');
cfg=nbiot.config.defaultConfig();
o=struct('projectRoot',root,'calibrationFile',fullfile(root,'calibration.mat'), ...
    'modelFiles',{{fullfile(root,'model.mat')}},'policyFiles',{{fullfile(root,'policy.m')}}, ...
    'inputFiles',{{fullfile(root,'input.dat')}});
write(o.calibrationFile,'calibration'); write(o.modelFiles{1},'model');
write(o.policyFiles{1},'policy'); write(o.inputFiles{1},'input');
end
function path=rebasePath(path,oldRoot,newRoot)
relative=path(numel(oldRoot)+2:end);
path=fullfile(newRoot,relative);
end
function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
function cfg=method(cfg), cfg.policy.name='Other'; end
function cfg=probability(cfg), cfg.policy.accessProbability=.5; end
function cfg=share(cfg), cfg.policy.raShare=.2; end
function cfg=traffic(cfg), cfg.traffic.kind='periodic'; end
function cfg=realization(cfg), cfg.simulation.realizationId=1; end
function r=fixtureRunner(cfg), r=cfg; end
function runner=numericalRunner(value)
runner=@runOnce;
    function r=runOnce(cfg), r=struct('config',cfg,'value',value); end
end
function write(path,text)
fid=fopen(path,'wb'); fwrite(fid,uint8(text),'uint8'); fclose(fid);
end
function writeJson(path,value), write(path,jsonencode(value)); end
function result=emptyResult(cfg,environment)
ids=(1:cfg.simulation.numUE).'; z=zeros(size(ids));
ue=table(ids,z,z,z,z,'VariableNames',{'ueId','created','delivered','dropped','unfinished'});
empty=table(0,'VariableNames',{'windowId'});
result=struct('config',cfg,'status','completed','environment',environment, ...
    'kpiSummary',struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
        'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0), ...
    'ueSummary',ue,'kpiTimeSeries',empty,'resourceUsage',empty, ...
    'dataset',struct('observations',empty,'targets',empty,'manifest',empty));
end
function runner=countingRunner(path)
runner=@runOnce;
    function result=runOnce(cfg)
        fid=fopen(path,'a'); fprintf(fid,'run\n'); fclose(fid);
        env=struct('matlabVersion',version,'release',version('-release'), ...
            'lteVersion',ver('lte'),'computer',computer,'validatedInMatlab',false,'sourceProfile','static-v1');
        result=emptyResult(cfg,env);
    end
end
function n=countRuns(path)
n=numel(strfind(fileread(path),'run'));
end
function writeCalibration(path)
report=calibrationReport(nbiot.config.defaultConfig()); save(path,'report');
end
function report=calibrationReport(cfg)
profile=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId, ...
    'format',cfg.ra.format,'periodTicks',cfg.ra.periodTicks,'numSubcarriers',cfg.ra.numSubcarriers, ...
    'repetitions',cfg.ra.repetitions,'sampleRateHz',cfg.simulation.sampleRateHz, ...
    'fractionalFilterLength',cfg.channel.fractionalFilterLength, ...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(),'cfoLimitHz',cfg.channel.cfoLimitHz);
report=struct('accepted',true,'threshold',1,'profile',profile,'cfoGridHz',cfg.phy.nprachCfoGridHz);
end
