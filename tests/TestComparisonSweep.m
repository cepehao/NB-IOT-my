classdef TestComparisonSweep < matlab.unittest.TestCase
    methods (Test)
        function designOnlyBuildsFullPairedMatrixWithoutAllocatingIds(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model placeholder');
            outputFolder=fullfile(folder,'comparison-plan');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.designOnly=true;
            before=fileread(registryFile);

            plan=runComparisonSweep(options);

            t.verifyTrue(plan.designOnly);
            t.verifyEqual(plan.status,'planned');
            t.verifyFalse(plan.readyForExecution, ...
                'A design-only plan must never claim execution readiness.');
            t.verifyNotEmpty(plan.unmetRequirements);
            t.verifyEqual(height(plan.cases),4500);
            t.verifyTrue(all(isnan(plan.cases.p95DelayTicks)));
            t.verifyTrue(all(isnan(plan.cases.nprachOccupancy)));
            t.verifyEqual(unique(plan.cases.method), ...
                ["Adaptive-P";"Adaptive-RA/DT";"Static"]);
            groups=unique(plan.cases(:,{'numUE','burstDurationTicks','realizationId'}),'rows');
            for groupIndex=1:height(groups)
                same=plan.cases.numUE==groups.numUE(groupIndex)& ...
                    plan.cases.burstDurationTicks==groups.burstDurationTicks(groupIndex)& ...
                    plan.cases.realizationId==groups.realizationId(groupIndex);
                t.verifyEqual(sum(same),3);
            end
            t.verifyTrue(all(plan.cases.status=="pending"));
            t.verifyEqual(fileread(registryFile),before);
            t.verifyTrue(isfile(fullfile(outputFolder,'comparison-design.csv')));
            t.verifyFalse(isfile(fullfile(outputFolder,'comparison-manifest.mat')));
        end

        function localLongPlanIsRejectedBeforeOutputOrIdReservation(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model placeholder');
            outputFolder=fullfile(folder,'must-not-exist');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.counts=2500;
            options.burstDurations=100;
            options.realizationIds=1200;
            options.methods=["Static" "Adaptive-P"];
            options.execution=struct('profile','local-development','role','development', ...
                'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900);
            options.designOnly=false;
            before=fileread(registryFile);

            t.verifyError(@() runComparisonSweep(options), ...
                'nbiot:experiments:ExecutionBudget');

            t.verifyFalse(isfolder(outputFolder));
            t.verifyEqual(fileread(registryFile),before);
        end

        function externalInjectedRunnerRequiresAdmissionBeforeReservation(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model placeholder');
            counterFile=fullfile(folder,'runner-count.txt');
            outputFolder=fullfile(folder,'must-not-exist');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.counts=1; options.burstDurations=10; options.realizationIds=1200;
            options.methods=["Static" "Adaptive-P"];
            options.runExperimentFcn=countingRunner(counterFile);
            options.runnerFiles={fullfile(fileparts(which('setupProject')), ...
                'tests','TestComparisonSweep.m')};
            options.runnerInputs=struct('counterFile',counterFile);
            options.runnerDependenciesDeclared=true;
            before=fileread(registryFile);

            t.verifyError(@() runComparisonSweep(options), ...
                'nbiot:ml:ModelAcceptance');

            t.verifyEqual(countRunnerCalls(counterFile),0, ...
                'The injected runner must not execute before external admission.');
            t.verifyEqual(fileread(registryFile),before, ...
                'Admission failure must precede realization reservation.');
            t.verifyFalse(isfolder(outputFolder), ...
                'Admission failure must precede output creation.');
        end

        function sweepRejectsStaleSourceEvidenceBeforeReservation(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model placeholder');
            outputFolder=fullfile(folder,'must-not-exist');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.counts=1; options.burstDurations=10; options.realizationIds=1200;
            options.methods=["Static" "Adaptive-P"];
            options.modelAcceptanceFile=writeRuntimeIdentityAcceptance(folder, ...
                options.calibrationFile,'source-mismatch');
            before=fileread(registryFile);

            exception=[];
            try
                runComparisonSweep(options);
            catch caught
                exception=caught;
            end
            t.verifyNotEmpty(exception);
            if ~isempty(exception)
                t.verifyEqual(exception.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(exception.message, ...
                    'Current computational source manifest differs from accepted evidence.'));
            end
            t.verifyEqual(fileread(registryFile),before, ...
                'A stale source manifest must be rejected before realization reservation.');
            t.verifyFalse(isfolder(outputFolder), ...
                'A stale source manifest must be rejected before comparison output creation.');
        end

        function sweepRejectsStaleCalibrationEvidenceBeforeReservation(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model placeholder');
            outputFolder=fullfile(folder,'must-not-exist');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.counts=1; options.burstDurations=10; options.realizationIds=1200;
            options.methods=["Static" "Adaptive-P"];
            options.modelAcceptanceFile=writeRuntimeIdentityAcceptance(folder, ...
                options.calibrationFile,'calibration-mismatch');
            before=fileread(registryFile);

            exception=[];
            try
                runComparisonSweep(options);
            catch caught
                exception=caught;
            end
            t.verifyNotEmpty(exception);
            if ~isempty(exception)
                t.verifyEqual(exception.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(exception.message, ...
                    'Current calibration file differs from accepted evidence.'));
            end
            t.verifyEqual(fileread(registryFile),before, ...
                'A stale calibration must be rejected before realization reservation.');
            t.verifyFalse(isfolder(outputFolder), ...
                'A stale calibration must be rejected before comparison output creation.');
        end

        function preflightRejectsOneOutOfScopeSweepConfiguration(t)
            scope=struct('methods',{{'Adaptive-P'}},'numUE',1, ...
                'trafficKinds',{{'burst'}},'burstDurationTicks',10,'windowTicks',500);
            first=nbiot.config.defaultConfig();
            first.simulation.numUE=1; first.traffic.kind='burst';
            first.traffic.burstDurationTicks=10; first.policy.name='Adaptive-P';
            first.policy.windowTicks=500; first.dataset.windowTicks=500;
            second=first; second.simulation.numUE=2;
            nbiot.experiments.validateComparisonAcceptanceScope(scope,{first});

            t.verifyError(@() nbiot.experiments.validateComparisonAcceptanceScope( ...
                scope,{first,second}), 'nbiot:ml:ModelAcceptance');
        end

        function evidenceMutationAfterSweepPreflightIsRejectedBeforeCaseRunner(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'opaque test model');
            acceptanceFile=fullfile(folder,'acceptance.json'); writeText(acceptanceFile,'test-only acceptance bytes');
            policyFile=fullfile(folder,'policy.json');
            policy=adaptiveDefaults(); writeJson(policyFile,policy);
            calibrationFile=fullfile(folder,'calibration.mat'); writeText(calibrationFile,'test calibration');
            evidenceFile=fullfile(folder,'evaluation.json'); writeText(evidenceFile,'validated before sweep');
            originalEvidenceHash=nbiot.ml.fileSha256(evidenceFile);
            writeText(evidenceFile,'changed after sweep preflight');
            counterFile=fullfile(folder,'runner-count.txt');
            execution=struct('profile','external-machine','role','final-comparison', ...
                'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900, ...
                'timePolicy','hard-stop');
            scope=struct('methods',{{'Adaptive-P'}},'numUE',1, ...
                'trafficKinds',{{'burst'}},'burstDurationTicks',10,'windowTicks',500);
            admission=struct('admissionStatus','accepted', ...
                'acceptanceSha256',nbiot.ml.fileSha256(acceptanceFile), ...
                'policySha256',nbiot.controller.policySha256(policy), ...
                'evidenceDigest',repmat('a',1,64),'scope',scope, ...
                'modelSha256',nbiot.ml.fileSha256(modelFile), ...
                'policyFile',policyFile,'comparisonIds',1200, ...
                'evidenceFiles',struct('path',evidenceFile, ...
                    'sha256',originalEvidenceHash));
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1; cfg.simulation.realizationId=1200;
            cfg.traffic.kind='burst'; cfg.traffic.burstDurationTicks=10;
            options=struct('execution',execution,'calibrationFile',calibrationFile, ...
                'scenario',[],'controllerPolicy',policy,'modelFile',modelFile, ...
                'allowDevelopmentModel',false,'modelAcceptanceFile',acceptanceFile, ...
                'admissionMetadata',admission,'resume',false, ...
                'runExperimentFcn',countingRunnerThatFails(counterFile), ...
                'runnerFiles',{{fullfile(fileparts(which('setupProject')), ...
                    'tests','TestComparisonSweep.m')}}, ...
                'runnerInputs',struct('counterFile',counterFile), ...
                'runnerDependenciesDeclared',true);

            t.verifyError(@() nbiot.experiments.runComparisonCase( ...
                cfg,'Adaptive-P',fullfile(folder,'case'),options), ...
                'nbiot:ml:ModelAcceptance', ...
                ['The negative stale-snapshot fixture must fail closed before the ' ...
                'case runner; it does not represent accepted scientific evidence.']);
            t.verifyEqual(countRunnerCalls(counterFile),0, ...
                'Evidence changed after sweep preflight must not reach a later case runner.');
            t.verifyFalse(isfolder(fullfile(folder,'case')), ...
                'Stale evidence must be rejected before case output is created.');
        end

        function directExternalCaseRejectsCallerFabricatedAdmissionSnapshotBeforeRunner(t)
            [folder,cfg,options,counterFile,caseFolder]=directExternalCaseSnapshotFixture();
            t.addTeardown(@() removeFolder(folder));

            t.verifyError(@() nbiot.experiments.runComparisonCase( ...
                cfg,'Adaptive-P',caseFolder,options), 'nbiot:ml:ModelAcceptance');
            t.verifyEqual(countRunnerCalls(counterFile),0, ...
                'A caller-supplied accepted snapshot cannot skip persisted evidence validation.');
            t.verifyFalse(isfolder(caseFolder), ...
                'Invalid persisted acceptance must fail before case output creation.');
        end

        function directExternalCaseRejectsStaleSourceManifestBeforeRunner(t)
            [folder,cfg,options,counterFile,caseFolder]=directExternalCaseSnapshotFixture();
            t.addTeardown(@() removeFolder(folder));
            acceptance=readJson(options.modelAcceptanceFile);
            sourcePath=fullfile(folder,acceptance.sourceManifest.file);
            source=readJson(sourcePath);
            source.sourceSha256(1)=char('0'+(source.sourceSha256(1)=='0'));
            writeJson(sourcePath,source);
            acceptance.sourceManifest.sha256=nbiot.ml.fileSha256(sourcePath);
            writeJson(options.modelAcceptanceFile,acceptance);

            exception=[];
            try
                nbiot.experiments.runComparisonCase(cfg,'Adaptive-P',caseFolder,options);
            catch caught
                exception=caught;
            end
            t.verifyNotEmpty(exception);
            if ~isempty(exception)
                t.verifyEqual(exception.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(exception.message, ...
                    'Current computational source manifest differs from accepted evidence.'));
            end
            t.verifyEqual(countRunnerCalls(counterFile),0);
            t.verifyFalse(isfolder(caseFolder), ...
                'A stale source manifest must be rejected before case output creation.');
        end

        function directExternalCaseRejectsStaleCalibrationBeforeRunner(t)
            [folder,cfg,options,counterFile,caseFolder]=directExternalCaseSnapshotFixture();
            t.addTeardown(@() removeFolder(folder));
            cfg.calibrationFileSha256(1)=char('0'+(cfg.calibrationFileSha256(1)=='0'));

            exception=[];
            try
                nbiot.experiments.runComparisonCase(cfg,'Adaptive-P',caseFolder,options);
            catch caught
                exception=caught;
            end
            t.verifyNotEmpty(exception);
            if ~isempty(exception)
                t.verifyEqual(exception.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(exception.message, ...
                    'Current calibration file differs from accepted evidence.'));
            end
            t.verifyEqual(countRunnerCalls(counterFile),0);
            t.verifyFalse(isfolder(caseFolder), ...
                'A stale calibration must be rejected before case output creation.');
        end

        function directExternalCaseRejectsOutOfScopeTrafficBeforeRunner(t)
            [folder,cfg,options,counterFile,caseFolder]=directExternalCaseSnapshotFixture();
            t.addTeardown(@() removeFolder(folder));
            cfg.traffic.kind='periodic'; cfg.traffic.periodTicks=20;

            exception=[];
            try
                nbiot.experiments.runComparisonCase(cfg,'Adaptive-P',caseFolder,options);
            catch caught
                exception=caught;
            end
            t.verifyNotEmpty(exception, ...
                'Out-of-scope traffic must throw before the comparison runner.');
            if ~isempty(exception)
                t.verifyEqual(exception.identifier,'nbiot:ml:ModelAcceptance');
                t.verifyTrue(contains(exception.message, ...
                    'Configuration load, traffic, or method is outside the accepted scope.'), ...
                    'Rejection must come from the current case scope check, not a later fixture error.');
            end
            t.verifyEqual(countRunnerCalls(counterFile),0, ...
                'Current traffic must be checked against persisted scope before runner invocation.');
            t.verifyFalse(isfolder(caseFolder), ...
                'Out-of-scope traffic must fail before case output creation.');
        end

        function summaryUsesPairedDifferencesAndOmitsOneIdIntervals(t)
            cases=summaryFixture();
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));

            summary=plotComparisonSummary(cases,folder);

            staticAdaptive=find(summary.pairedDifferences.methodA=="Static" & ...
                summary.pairedDifferences.methodB=="Adaptive-P" & ...
                summary.pairedDifferences.metric=="throughputBitsPerSecond");
            t.assertEqual(numel(staticAdaptive),1);
            row=summary.pairedDifferences(staticAdaptive,:);
            t.verifyEqual(row.pairCount,2);
            t.verifyEqual(row.meanDifference,25,'AbsTol',1e-12);
            t.verifyTrue(isfinite(row.ci95Low)&&isfinite(row.ci95High));

            staticP95=find(summary.methodSummary.method=="Static" & ...
                summary.methodSummary.metric=="p95DelayTicks");
            t.assertEqual(numel(staticP95),1);
            t.verifyEqual(summary.methodSummary.mean(staticP95),150,'AbsTol',1e-12);
            staticDropped=find(summary.methodSummary.method=="Static" & ...
                summary.methodSummary.metric=="dropped");
            t.assertEqual(numel(staticDropped),1);
            t.verifyEqual(summary.methodSummary.mean(staticDropped),1.5,'AbsTol',1e-12);
            adaptiveSwitches=find(summary.pairedDifferences.methodA=="Adaptive-P" & ...
                summary.pairedDifferences.methodB=="Adaptive-RA/DT" & ...
                summary.pairedDifferences.metric=="controllerSwitches");
            t.assertEqual(numel(adaptiveSwitches),1);
            t.verifyEqual(summary.pairedDifferences.meanDifference(adaptiveSwitches),-1, ...
                'AbsTol',1e-12);

            staticRa=find(summary.pairedDifferences.methodA=="Static" & ...
                summary.pairedDifferences.methodB=="Adaptive-RA/DT" & ...
                summary.pairedDifferences.metric=="throughputBitsPerSecond");
            row=summary.pairedDifferences(staticRa,:);
            t.verifyEqual(row.pairCount,1);
            t.verifyEqual(row.incompletePairCount,1);
            t.verifyTrue(isnan(row.standardError)&&isnan(row.ci95Low)&&isnan(row.ci95High));
            t.verifyTrue(isfile(fullfile(folder,'paired-comparison.csv')));
            t.verifyTrue(isfile(fullfile(folder,'comparison-summary.png')));
        end

        function summaryRejectsDuplicateRowsForSameIndependentId(t)
            cases=summaryFixture();
            cases(end+1,:)=cases(1,:);

            t.verifyError(@() plotComparisonSummary(cases), ...
                'nbiot:experiments:ComparisonData');
        end

        function stoppedPairResumesAndChangedModelOrDamagedMarkerIsHandled(t)
            folder=tempname; mkdir(folder); t.addTeardown(@() removeFolder(folder));
            registryFile=fullfile(folder,'registry.json'); writeRegistry(registryFile);
            modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'development model A');
            counterFile=fullfile(folder,'runner-count.txt');
            outputFolder=fullfile(folder,'comparison-run');
            options=externalOptions(outputFolder,registryFile,modelFile);
            options.counts=1; options.burstDurations=10; options.realizationIds=1200;
            options.methods=["Static" "Adaptive-P"];
            options.execution=struct('profile','local-development','role','development', ...
                'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900);
            options.allowDevelopmentModel=true;
            options.controllerPolicy=adaptiveDefaults();
            options.runExperimentFcn=countingRunner(counterFile);
            options.runnerFiles={fullfile(fileparts(which('setupProject')), ...
                'tests','TestComparisonSweep.m')};
            options.runnerInputs=struct('counterFile',counterFile);
            options.runnerDependenciesDeclared=true;

            first=runComparisonSweep(options);

            t.verifyEqual(first.status,'incomplete');
            t.verifyEqual(first.cases.status,["completed";"stopped"]);
            t.verifyEqual(numel(unique(first.cases.inputSha256)),1);
            firstStaticResult=char(first.cases.resultFile(1));
            firstStaticMarker=fullfile(fileparts(firstStaticResult),'case-complete.json');
            t.verifyTrue(isfile(firstStaticMarker));
            t.verifyEqual(countRunnerCalls(counterFile),2);

            writeText(modelFile,'development model B');
            t.verifyError(@() runComparisonSweep(options), ...
                'nbiot:experiments:ComparisonIdentity');
            t.verifyEqual(countRunnerCalls(counterFile),2);
            writeText(modelFile,'development model A');
            writeText(firstStaticMarker,'not-json');

            resumed=runComparisonSweep(options);

            t.verifyEqual(resumed.status,'completed');
            t.verifyEqual(resumed.cases.status,["completed";"completed"]);
            t.verifyEqual(resumed.cases.p95DelayTicks,[42;42]);
            t.verifyEqual(resumed.cases.harqRetryAttempts,[3;3]);
            t.verifyTrue(isnan(resumed.cases.controllerSwitches(1)));
            t.verifyEqual(resumed.cases.controllerSwitches(2),2);
            t.verifyNotEqual(char(resumed.cases.resultFile(1)),firstStaticResult);
            t.verifyTrue(nbiot.results.verifyCase( ...
                fileparts(char(resumed.cases.resultFile(1)))).passed);
            t.verifyEqual(countRunnerCalls(counterFile),4);
            registry=jsondecode(fileread(registryFile));
            t.verifyEqual(registry.assignments(1).status,'completed');
        end
    end
end

function options=externalOptions(outputFolder,registryFile,modelFile)
root=fileparts(fileparts(mfilename('fullpath')));
options=struct('designOnly',false,'counts',[100 500 1000 2500 5000], ...
    'burstDurations',[10 100 500],'methods',["Static" "Adaptive-P" "Adaptive-RA/DT"], ...
    'realizationIds',1000:1099, ...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'), ...
    'modelFile',modelFile,'allowDevelopmentModel',false, ...
    'execution',struct('profile','external-machine','role','final-comparison', ...
        'maxUE',5000,'maxCaseSeconds',300,'maxSuiteSeconds',2e9), ...
    'registryFile',registryFile,'outputFolder',outputFolder,'resume',true);
end

function cases=summaryFixture()
method=["Static";"Adaptive-P";"Adaptive-RA/DT"; ...
    "Static";"Adaptive-P";"Adaptive-RA/DT"];
status=["completed";"completed";"completed"; ...
    "completed";"completed";"failed"];
cases=table(ones(6,1),100*ones(6,1),[11;11;11;12;12;12], ...
    method,status,[100;120;80;200;230;NaN],[.1;.2;.05;.3;.5;NaN], ...
    [0.2;0.3;0.1;0.4;0.5;NaN],[100;110;90;200;210;NaN], ...
    [.1;.2;.05;.3;.4;NaN],[.1;.2;.05;.3;.4;NaN],[.1;.2;.05;.3;.4;NaN], ...
    [1;0;2;2;1;1],[100;110;90;200;210;205], ...
    [1;2;3;4;5;6],[.01;.02;.03;.04;.05;.06],[NaN;2;1;NaN;3;2], ...
    'VariableNames',{'numUE','burstDurationTicks','realizationId','method','status', ...
    'throughputBitsPerSecond','deliveryProbability','raSuccessProbability', ...
    'meanDelayTicks','dataBler','ulOccupancy','dlOccupancy','dropped', ...
    'p95DelayTicks','meanBsQueueLength','nprachOccupancy','controllerSwitches'});
end

function writeRegistry(path)
registry=struct('schemaVersion',1,'validRange',[0 4095], ...
    'roles',{{'development','final-comparison'}}, ...
    'reservations',struct('role',{},'range',{},'source',{},'note',{}), ...
    'assignments',struct('role',{},'ids',{},'source',{},'status',{},'recovery',{}));
writeJson(path,registry);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(value),'UTF-8'),'uint8');
end

function value=readJson(path)
value=jsondecode(fileread(path));
end

function writeText(path,value)
fid=fopen(path,'w'); cleanup=onCleanup(@() fclose(fid));
fwrite(fid,value,'char');
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end

function runner=countingRunner(counterFile)
runner=@runOnce;
    function result=runOnce(cfg)
        fid=fopen(counterFile,'a'); fprintf(fid,'%s\n',cfg.policy.name); fclose(fid);
        calls=countRunnerCalls(counterFile);
        status='completed';
        if strcmp(cfg.policy.name,'Adaptive-P')&&calls==2, status='stopped'; end
        result=mockComparisonResult(cfg,status);
    end
end

function result=mockComparisonResult(cfg,status)
environment=struct('matlabVersion',version,'release',version('-release'), ...
    'lteVersion',ver('lte'),'computer',computer,'validatedInMatlab',false, ...
    'sourceProfile','static-v1');
adaptive=ismember(char(string(cfg.policy.name)),{'Adaptive-P','Adaptive-RA/DT'});
if adaptive, environment.sourceProfile='adaptive-development'; end
ue=(1:cfg.simulation.numUE).'; zero=zeros(cfg.simulation.numUE,1);
ueSummary=table(ue,zero,zero,zero,zero,'VariableNames', ...
    {'ueId','created','delivered','dropped','unfinished'});
empty=table(zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'windowId','startTick','endTick'});
observations=table(zeros(0,1),zeros(0,1),'VariableNames', ...
    {'realizationId','windowId'});
targets=table(zeros(0,1),zeros(0,1),'VariableNames', ...
    {'realizationId','windowId'});
split=table("train",0,'VariableNames',{'split','rows'});
resourceUsage=table("cpu",0,'VariableNames',{'resource','units'});
kpi=struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
    'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0, ...
    'collidingAttempts',0,'raSuccessProbability',NaN, ...
    'raSuccessCompletedProbability',NaN,'meanRaAttempts',NaN, ...
    'deliveryProbability',NaN,'deliveryCompletedProbability',NaN, ...
    'dropProbability',NaN,'collisionAttemptProbability',NaN, ...
    'throughputBitsPerSecond',0,'meanDelayTicks',NaN,'p95DelayTicks',42, ...
    'msg3Bler',NaN,'msg3Decoded',0,'msg3CrcFailures',0, ...
    'dataBler',NaN,'dataDecoded',0,'dataCrcFailures',0, ...
    'ulOccupancy',0,'dlOccupancy',0,'nprachOccupancy',.04, ...
    'meanBsQueueLength',3,'maxBsQueueLength',6, ...
    'meanUeQueueLength',.2,'maxUeQueueLength',2, ...
    'harq',struct('attemptsStarted',5,'retryAttempts',3, ...
        'retryTransmissions',2,'blocksStarted',4,'blocksFailed',1, ...
        'blocksCensored',0,'firstTransmissionBler',.2,'allAttemptBler',.1), ...
    'controller',struct('applicable',adaptive,'decisionCount',4, ...
        'configurationSwitches',2));
result=struct('config',cfg,'status',status,'environment',environment, ...
    'kpiSummary',kpi,'ueSummary',ueSummary,'kpiTimeSeries',empty, ...
    'resourceUsage',resourceUsage,'dataset',struct('observations',observations, ...
    'targets',targets,'manifest',split,'schema',struct()), ...
    'profiling',struct('elapsedSeconds',0.01));
if adaptive
    result.controllerLog=struct('decisionTick',{},'effectiveTick',{}, ...
        'featureWindowEndTick',{},'method',{},'estimateValue',{}, ...
        'estimateValid',{},'proposedAccessProbability',{},'proposedRaShare',{}, ...
        'appliedAccessProbability',{},'appliedRaShare',{},'applied',{}, ...
        'switched',{},'reason',{},'estimateReason',{}, ...
        'errorIdentifier',{},'errorMessage',{},'featureValuesJson',{});
    result.controllerLogSchemaVersion=1;
    result.controllerPolicy=adaptiveDefaults();
end
end

function count=countRunnerCalls(path)
if ~isfile(path), count=0; return; end
lines=splitlines(strtrim(fileread(path)));
count=sum(strlength(lines)>0);
end

function runner=countingRunnerThatFails(counterFile)
runner=@runIfReached;
    function result=runIfReached(~)
        fid=fopen(counterFile,'a'); fprintf(fid,'called\n'); fclose(fid);
        error('nbiot:test:UnexpectedRunner', ...
            'A stale admission snapshot reached the comparison runner.');
        result=[]; %#ok<UNRCH>
    end
end

function [folder,cfg,options,counterFile,caseFolder]=directExternalCaseSnapshotFixture()
folder=tempname; mkdir(folder);
modelFile=fullfile(folder,'model.mat'); writeText(modelFile,'opaque test model');
acceptanceFile=fullfile(folder,'acceptance.json');
scope=struct('methods',{{'Adaptive-P'}},'numUE',1, ...
    'trafficKinds',{{'burst'}},'burstDurationTicks',10,'windowTicks',500);
acceptance=struct('trainingIds',100,'validationIds',200,'testIds',300, ...
    'policyTuningIds',[],'scope',scope);
policy=adaptiveDefaults(); policyFile=fullfile(folder,'policy.json'); writeJson(policyFile,policy);
calibrationFile=fullfile(folder,'calibration.mat'); writeText(calibrationFile,'test calibration');
projectRoot=fileparts(which('setupProject'));
source=optimizationSourceManifest(projectRoot);
sourceManifestFile=fullfile(folder,'source-manifest.json');
writeJson(sourceManifestFile,struct('sourceSha256',source.sha256));
acceptance.sourceManifest=struct('file','source-manifest.json', ...
    'sha256',nbiot.ml.fileSha256(sourceManifestFile));
acceptance.calibration=struct('file','calibration.mat', ...
    'sha256',nbiot.ml.fileSha256(calibrationFile));
writeJson(acceptanceFile,acceptance);
evidenceFile=fullfile(folder,'evaluation.json'); writeText(evidenceFile,'unvalidated caller evidence');
execution=struct('profile','external-machine','role','final-comparison', ...
    'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900,'timePolicy','hard-stop');
admission=struct('admissionStatus','accepted', ...
    'acceptanceSha256',nbiot.ml.fileSha256(acceptanceFile), ...
    'policySha256',nbiot.controller.policySha256(policy), ...
    'evidenceDigest',repmat('a',1,64),'scope',scope, ...
    'modelSha256',nbiot.ml.fileSha256(modelFile), ...
    'policyFile',policyFile,'comparisonIds',1200, ...
    'evidenceFiles',struct('path',evidenceFile, ...
        'sha256',nbiot.ml.fileSha256(evidenceFile)));
counterFile=fullfile(folder,'runner-count.txt'); caseFolder=fullfile(folder,'case');
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1;
cfg.calibrationFileSha256=nbiot.ml.fileSha256(calibrationFile);
cfg.simulation.realizationId=1200; cfg.traffic.kind='burst';
cfg.traffic.burstDurationTicks=10; cfg.policy.name='Adaptive-P';
cfg.policy.windowTicks=500; cfg.dataset.windowTicks=500;
options=struct('execution',execution,'calibrationFile',calibrationFile, ...
    'scenario',[],'controllerPolicy',policy,'modelFile',modelFile, ...
    'allowDevelopmentModel',false,'modelAcceptanceFile',acceptanceFile, ...
    'admissionMetadata',admission,'resume',false, ...
    'runExperimentFcn',countingRunnerThatFails(counterFile), ...
    'runnerFiles',{{fullfile(fileparts(which('setupProject')), ...
        'tests','TestComparisonSweep.m')}}, ...
    'runnerInputs',struct('counterFile',counterFile), ...
    'runnerDependenciesDeclared',true);
end

function acceptancePath=writeRuntimeIdentityAcceptance(folder,calibrationFile,mismatch)
projectRoot=fileparts(which('setupProject'));
source=optimizationSourceManifest(projectRoot);
sourceSha=source.sha256;
if strcmp(mismatch,'source-mismatch')
    if sourceSha(1)=='0', sourceSha(1)='1'; else, sourceSha(1)='0'; end
end
sourceManifestFile=fullfile(folder,'source-manifest.json');
writeJson(sourceManifestFile,struct('sourceSha256',sourceSha));
calibrationSha=nbiot.ml.fileSha256(calibrationFile);
if strcmp(mismatch,'calibration-mismatch')
    if calibrationSha(1)=='0', calibrationSha(1)='1'; else, calibrationSha(1)='0'; end
end
acceptance=struct('sourceManifest',struct('file','source-manifest.json', ...
    'sha256',nbiot.ml.fileSha256(sourceManifestFile)), ...
    'calibration',struct('file','calibration.mat','sha256',calibrationSha), ...
    'trainingIds',100,'validationIds',200,'testIds',300,'policyTuningIds',[], ...
    'scope',struct('methods',{{'Adaptive-P'}},'numUE',1, ...
        'trafficKinds',{{'burst'}},'burstDurationTicks',10,'windowTicks',500));
acceptancePath=fullfile(folder,'acceptance.json'); writeJson(acceptancePath,acceptance);
end
