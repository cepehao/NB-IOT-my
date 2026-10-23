classdef TestExternalStageContracts < matlab.unittest.TestCase
    methods (Test)
        function dispatcherUsesFixedStageNamesAndNoDynamicEvaluation(t)
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(projectRoot,'verification','external'));
            identifier='';
            try
                runExternalStage(tempname,'run arbitrary code', ...
                    tempname,repmat('0',1,64));
            catch exception
                identifier=exception.identifier;
            end
            dispatcher=readDispatcher();
            hasDynamicDispatch=contains(dispatcher,'eval(')|| ...
                contains(dispatcher,'str2func(');
            rejectsUnknown=strcmp(identifier,'nbiot:externalStage:Stage');
            fprintf('BOUNDED_TEST_CONTROL unknownStage=%d noDynamicEvaluation=%d\n', ...
                rejectsUnknown,~hasDynamicDispatch);
            t.verifyTrue(rejectsUnknown);
            t.verifyFalse(hasDynamicDispatch);
        end

        function freezeStageReadsSelectedModelAsText(t)
            dispatcher=readDispatcher();
            passed=contains(dispatcher, ...
                "'selectedModel',char(string(frozen.selectedModel))");
            fprintf('BOUNDED_TEST_CONTRACT freeze-selected-model-as-text pass=%d\n',passed);
            t.verifyTrue(passed);
        end

        function compareStageRejectsIncompleteSweep(t)
            dispatcher=readDispatcher();
            passed=contains(dispatcher,'comparison.status')&& ...
                contains(dispatcher,"'completed'")&& ...
                contains(dispatcher,'CompareIncomplete');
            fprintf('BOUNDED_TEST_CONTRACT compare-incomplete-is-failure pass=%d\n',passed);
            t.verifyTrue(passed);
        end

        function dataAndCompareRequireReviewedResourceBudget(t)
            dispatcher=readDispatcher();
            passed=contains(dispatcher,'manifest.resourceStatus')&& ...
                contains(dispatcher,"'target-reviewed'")&& ...
                contains(dispatcher,"'measured-and-target-reviewed'");
            fprintf('BOUNDED_TEST_CONTRACT resource-budget-review-gate pass=%d\n',passed);
            t.verifyTrue(passed);
        end

        function comparisonMatrixMustMatchSweepOptions(t)
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(projectRoot,'verification','external'));
            options=struct('counts',200,'burstDurations',50, ...
                'methods',["Static","Adaptive-P"], ...
                'realizationIds',1800,'config',nbiot.config.defaultConfig());
            matrix=struct( ...
                'method',{'Static','Adaptive-P'}, ...
                'numUE',{100,100}, ...
                'durationTicks',{5000,5000}, ...
                'burstDurationTicks',{50,50}, ...
                'realizationId',{1800,1800}, ...
                'scenarioIdentity',{'shared-scenario','shared-scenario'});
            t.verifyError(@()validateExternalComparisonMatrix(matrix,options), ...
                'nbiot:externalStage:ScenarioOptions');
            options.counts=100;
            identifier='';
            try
                validateExternalComparisonMatrix(matrix,options);
            catch exception
                identifier=exception.identifier;
            end
            t.verifyEmpty(identifier);
            fprintf('BOUNDED_TEST_CONTRACT comparison-options-matrix-mismatch-blocked pass=1\n');
        end

        function admitUsesPortableCandidatePackageForPublisher(t)
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(projectRoot,'verification','external'));
            addpath(fullfile(projectRoot,'tests'));
            fixture=TestModelAcceptance.fixtureForEvidenceSnapshotTest(t);
            candidate=prepareModelAcceptance(fixture.prepareOptions);
            originalFiles=fixtureFileHashes(fixture.root);

            packageRoot=tempname;
            mkdir(packageRoot);
            t.addTeardown(@() removeFixtureFolder(packageRoot));
            projectFolder=fullfile(packageRoot,'project');
            mkdir(projectFolder);
            candidateSourceFolder=fullfile(projectFolder,'candidate-source');
            copyFixtureTree(fixture.root,candidateSourceFolder);

            registryFolder=fullfile(projectFolder,'experiments');
            mkdir(registryFolder);
            verificationFolder=fullfile(projectFolder,'verification');
            mkdir(verificationFolder);
            mkdir(fullfile(verificationFolder,'external'));
            mkdir(fullfile(verificationFolder,'completion','stage-2'));
            registryFile=fullfile(registryFolder,'realizationRegistry.json');
            writeFixtureJson(registryFile,struct('schemaVersion',1,'reservations',[]));
            reviewFolder=fullfile(packageRoot,'reviews');
            mkdir(reviewFolder);
            reviewFile=fullfile(reviewFolder,'admission-review.json');
            evidence=nbiot.ml.checkModelAcceptanceEvidence(candidate,fixture.root);
            review=struct('decision','rejected','reviewer','test fixture only', ...
                'reviewedAtUtc','2026-10-19T08:00:00Z', ...
                'evidenceDigest',evidence.evidenceDigest, ...
                'protocolSha256',candidate.protocol.sha256, ...
                'limitations','synthetic fixture; not a scientific or professor decision');
            writeFixtureJson(reviewFile,review);

            inputDigest=repmat('a',1,64);
            stage=struct('name','admit','status','running', ...
                'inputDigest',inputDigest, ...
                'configuration',struct('candidateFile', ...
                    'project/candidate-source/candidate.json'));
            manifest=struct('registry',struct( ...
                'packagePath','project/experiments/realizationRegistry.json', ...
                'sha256',nbiot.ml.fileSha256(registryFile)));
            writeFixtureJson(fullfile(packageRoot,'manifest.json'),manifest);
            writeFixtureJson(fullfile(packageRoot,'stages.json'), ...
                struct('stages',stage));

            outputFolder=fullfile(packageRoot,'stage-results','admit',inputDigest);
            mkdir(outputFolder);
            candidatePackageFolder=fullfile(outputFolder,'results','candidate-package');
            copiedCandidate=fullfile(candidatePackageFolder,'candidate.json');
            copiedAcceptance=fullfile(candidatePackageFolder,'model-acceptance.json');
            reportFile=fullfile(outputFolder,'stage-report.json');
            previousPath=path;
            pathGuard=onCleanup(@() path(previousPath)); %#ok<NASGU>
            previousEnvironment=externalStageEnvironment();
            environmentGuard=onCleanup(@() restoreExternalStageEnvironment( ...
                previousEnvironment)); %#ok<NASGU>
            setenv('NBIOT_EXTERNAL_STAGE_PROFILE','external-machine');
            setenv('NBIOT_EXTERNAL_STAGE_NAME','admit');
            setenv('NBIOT_EXTERNAL_STAGE_INPUT_DIGEST',inputDigest);
            setenv('NBIOT_EXTERNAL_STAGE_REPORT_PATH',reportFile);

            failureIdentifier='';
            failureMessage='';
            try
                runExternalStage(packageRoot,'admit',outputFolder,inputDigest,reviewFile);
            catch exception
                failureIdentifier=exception.identifier;
                failureMessage=exception.message;
            end
            fprintf(['BOUNDED_TEST admit-portable-package copied=%d ' ...
                'publisherReachedFixtureGate=%d acceptanceWritten=%d\n'], ...
                isfile(copiedCandidate), ...
                contains(failureMessage, ...
                    'Local development/test-fixture evidence cannot be published'), ...
                isfile(copiedAcceptance));

            t.verifyEqual(failureIdentifier,'nbiot:ml:ModelAcceptance');
            t.verifySubstring(failureMessage, ...
                'Local development/test-fixture evidence cannot be published as scientific acceptance.');
            t.verifyTrue(isfile(copiedCandidate), ...
                'The real dispatcher must place a portable candidate beside publisher output.');
            t.verifyFalse(isfile(copiedAcceptance), ...
                'A test-only candidate must never produce a published acceptance.');
            t.verifyEqual(fixtureFileHashes(candidatePackageFolder),originalFiles, ...
                'The copied candidate package must preserve every evidence file byte-for-byte.');
            t.verifyEqual(fixtureFileHashes(fixture.root),originalFiles, ...
                'The dispatcher must leave the original candidate and evidence unchanged.');
            t.verifyFalse(isfile(reportFile), ...
                'A rejected fixture review cannot create a completed admit report.');
        end

    end
end

function source=readDispatcher()
projectRoot=fileparts(fileparts(mfilename('fullpath')));
source=fileread(fullfile(projectRoot,'verification','external', ...
    'runExternalStage.m'));
end

function entries=fixtureFileHashes(root)
listing=dir(fullfile(root,'**','*'));
entries=struct('path',{},'sha256',{});
prefix=[root filesep];
for k=1:numel(listing)
    if listing(k).isdir,continue;end
    path=fullfile(listing(k).folder,listing(k).name);
    entries(end+1)=struct('path',strrep(path(numel(prefix)+1:end),'\','/'), ...
        'sha256',nbiot.ml.fileSha256(path)); %#ok<AGROW>
end
[~,order]=sort({entries.path});
entries=entries(order);
end

function copyFixtureTree(source,destination)
if ~isfolder(destination),mkdir(destination);end
listing=dir(source);
for k=1:numel(listing)
    if ismember(listing(k).name,{'.','..'}),continue;end
    sourcePath=fullfile(source,listing(k).name);
    destinationPath=fullfile(destination,listing(k).name);
    if listing(k).isdir
        copyFixtureTree(sourcePath,destinationPath);
    else
        [ok,message]=copyfile(sourcePath,destinationPath);
        assert(ok,'Could not copy test candidate evidence: %s',message);
    end
end
end

function writeFixtureJson(path,value)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not create a test-only JSON fixture.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8'),'uint8');
end

function removeFixtureFolder(path)
if isfolder(path),rmdir(path,'s');end
end

function value=externalStageEnvironment()
names={'NBIOT_EXTERNAL_STAGE_PROFILE','NBIOT_EXTERNAL_STAGE_NAME', ...
    'NBIOT_EXTERNAL_STAGE_INPUT_DIGEST','NBIOT_EXTERNAL_STAGE_REPORT_PATH'};
value=struct();
for k=1:numel(names),value.(names{k})=getenv(names{k});end
end

function restoreExternalStageEnvironment(value)
names=fieldnames(value);
for k=1:numel(names),setenv(names{k},value.(names{k}));end
end
