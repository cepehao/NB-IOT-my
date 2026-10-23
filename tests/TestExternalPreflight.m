classdef TestExternalPreflight < matlab.unittest.TestCase
    methods (Test)
        function missingCalibrationReferenceFailsClosed(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            prepareExternalRun(options);
            packageRoot=options.outputFolder;
            delete(fullfile(packageRoot,'project','results','nprach-calibration.mat'));
            report=runPackagedPreflight(t,packageRoot);
            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
            t.verifyFalse(report.readiness.stageReady);
            t.verifyFalse(report.readiness.scientificAccepted);
        end

        function movedStaticPackageUsesRelativeReferencesAndStableDigests(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            prepareExternalRun(options);
            packagedPreflight=fullfile(options.outputFolder,'project', ...
                'verification','external','validateExternalPreflight.m');
            t.assertTrue(isfile(packagedPreflight), ...
                'The portable package must contain its own preflight entrypoint.');
            before=runPackagedPreflight(t,options.outputFolder);
            registryPath=fullfile(options.outputFolder,'project', ...
                'experiments','realizationRegistry.json');
            registryBefore=fileread(registryPath);
            parent=fullfile(tempdir,['external handoff ' char(java.util.UUID.randomUUID())]);
            mkdir(parent);
            parentCleanup=onCleanup(@() removeFolder(parent)); %#ok<NASGU>
            movedPackage=fullfile(parent,'portable package');
            [ok,message]=movefile(options.outputFolder,movedPackage);
            t.assertTrue(ok,message);
            removeFolder(root);
            after=runPackagedPreflight(t,movedPackage);
            movedRegistry=fullfile(movedPackage,'project','experiments','realizationRegistry.json');
            t.verifyTrue(before.passed);
            t.verifyTrue(after.passed);
            t.verifyTrue(before.readOnly);
            t.verifyTrue(after.readOnly);
            t.verifyEqual(fileread(movedRegistry),registryBefore);
            t.verifyEqual(after.sourceDigest,before.sourceDigest);
            t.verifyEqual(after.inputDigests,before.inputDigests);
            t.verifyTrue(after.readiness.softwareReady);
            t.verifyFalse(after.readiness.stageReady);
            t.verifyFalse(after.readiness.scientificAccepted);
            t.verifyFalse(contains(jsonencode(after),parent));
        end

        function manifestReferencePathMustMatchPackagedPath(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            prepareExternalRun(options);
            packageRoot=options.outputFolder;
            manifestPath=fullfile(packageRoot,'manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            manifest.calibration.path=manifest.registry.path;
            writeText(manifestPath,jsonencode(manifest));

            report=runPackagedPreflight(t,packageRoot);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
            t.verifyFalse(report.readiness.stageReady);
        end

        function sourceManifestPathMustMatchPackagedPath(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            prepareExternalRun(options);
            manifestPath=fullfile(options.outputFolder,'manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            manifest.codeFiles(1).path='changed-source.m';
            manifest.codeManifestSha256=sha256Text(jsonencode(manifest.codeFiles));
            writeText(manifestPath,jsonencode(manifest));

            report=runPackagedPreflight(t,options.outputFolder);

            t.verifyFalse(report.passed);
            t.verifyNotEmpty(report.errors);
        end

        function adaptiveModelSidecarTamperingFailsClosed(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            modelFile=fullfile(root,'results','linearRegression.mat');
            writeText(modelFile,'model fixture');
            sidecar=struct('modelName','linearRegression', ...
                'artifactFile','linearRegression.mat', ...
                'artifactSha256',nbiot.ml.fileSha256(modelFile));
            writeText(fullfile(root,'results','linearRegression.json'),jsonencode(sidecar));
            options.caseMatrix.method(:)="Adaptive-P";
            options.modelFile='results/linearRegression.mat';
            prepareExternalRun(options);
            packageRoot=options.outputFolder;
            before=runPackagedPreflight(t,packageRoot);
            t.assertTrue(before.passed,strjoin(string(before.errors),'; '));
            writeText(fullfile(packageRoot,'project','results','linearRegression.json'), ...
                jsonencode(struct('artifactFile','linearRegression.mat', ...
                'artifactSha256',repmat('0',1,64))));

            after=runPackagedPreflight(t,packageRoot);

            t.verifyFalse(after.passed);
            t.verifyFalse(after.readiness.scientificAccepted);
            t.verifyFalse(after.readiness.stageReady);
        end

        function adaptiveSidecarMustKeepMatBasenameAndFolder(t)
            [options,root,cleanup]=packageFixture(); %#ok<ASGLU>
            modelFile=fullfile(root,'results','linearRegression.mat');
            writeText(modelFile,'model fixture');
            sidecar=struct('artifactFile','linearRegression.mat', ...
                'artifactSha256',nbiot.ml.fileSha256(modelFile));
            writeText(fullfile(root,'results','linearRegression.json'),jsonencode(sidecar));
            options.caseMatrix.method(:)="Adaptive-P";
            options.modelFile='results/linearRegression.mat';
            prepareExternalRun(options);
            packageRoot=options.outputFolder;
            oldSidecar=fullfile(packageRoot,'project','results','linearRegression.json');
            newSidecar=fullfile(packageRoot,'project','results','renamed.json');
            [ok,message]=movefile(oldSidecar,newSidecar);
            t.assertTrue(ok,message);
            manifestPath=fullfile(packageRoot,'manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            manifest.model.sidecarPath='results/renamed.json';
            manifest.model.sidecarPackagePath='project/results/renamed.json';
            writeText(manifestPath,jsonencode(manifest));

            report=runPackagedPreflight(t,packageRoot);

            t.verifyFalse(report.passed);
            t.verifyFalse(report.readiness.scientificAccepted);
            t.verifyFalse(report.readiness.stageReady);
        end

        function acceptanceReviewMustMatchEvidenceDigest(t)
            evidenceDigest=repmat('a',1,64);
            [options,root,cleanup]=acceptanceBundle( ...
                'accepted','scientific-candidate',repmat('b',1,64),evidenceDigest); %#ok<ASGLU>
            prepareExternalRun(options);

            report=runPackagedPreflight(t,options.outputFolder);

            t.assertTrue(report.passed,strjoin(string(report.errors),'; '));
            t.verifyFalse(report.readiness.scientificAccepted);
        end

        function matchingButIncorrectEvidenceDigestDoesNotAcceptReview(t)
            digest=repmat('a',1,64);
            [options,root,cleanup]=acceptanceBundle( ...
                'accepted','scientific-candidate',digest,digest); %#ok<ASGLU>
            prepareExternalRun(options);

            report=runPackagedPreflight(t,options.outputFolder);

            t.assertTrue(report.passed,strjoin(string(report.errors),'; '));
            t.verifyFalse(report.readiness.scientificAccepted);
        end

        function canonicalEvidenceDigestAcceptsMatchingReview(t)
            [options,root,cleanup]=acceptanceBundle( ...
                'accepted','scientific-candidate','canonical','canonical'); %#ok<ASGLU>
            prepareExternalRun(options);

            report=runPackagedPreflight(t,options.outputFolder);

            t.assertTrue(report.passed,strjoin(string(report.errors),'; '));
            t.verifyTrue(report.readiness.scientificAccepted);
        end

        function topLevelEvidenceIndexMustMatchAcceptanceReferences(t)
            [options,root,cleanup]=acceptanceBundle( ...
                'candidate','test-fixture','',repmat('a',1,64)); %#ok<ASGLU>
            prepareExternalRun(options);
            manifestPath=fullfile(options.outputFolder,'manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            manifest.evidenceFiles(1).sha256=repmat('0',1,64);
            writeText(manifestPath,jsonencode(manifest));

            report=runPackagedPreflight(t,options.outputFolder);

            t.verifyFalse(report.passed);
            t.verifyFalse(report.readiness.scientificAccepted);
        end

        function evidenceIndexesCannotAddUnreferencedEntries(t)
            [options,root,cleanup]=acceptanceBundle( ...
                'candidate','test-fixture','',repmat('a',1,64)); %#ok<ASGLU>
            prepareExternalRun(options);
            manifestPath=fullfile(options.outputFolder,'manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            extra=manifest.evidenceFiles(1);
            extra.name='unreferencedFreeze';
            extra.path='experiments/evidence/unreferenced-freeze.json';
            extra.packagePath=['project/' extra.path];
            extra.sha256=repmat('0',1,64);
            extra.packageSha256=extra.sha256;
            manifest.modelAcceptance.references(end+1)=extra;
            manifest.evidenceFiles(end+1)=extra;
            writeText(manifestPath,jsonencode(manifest));

            report=runPackagedPreflight(t,options.outputFolder);

            t.verifyFalse(report.passed);
            t.verifyFalse(report.readiness.scientificAccepted);
        end

        function additionalFreezeReferenceIsPackagedAndVerified(t)
            [options,root,cleanup]=acceptanceBundle( ...
                'candidate','test-fixture','','canonical',true); %#ok<ASGLU>
            manifest=prepareExternalRun(options);
            freezeIndex=find(strcmp({manifest.evidenceFiles.name},'freeze'));
            t.assertEqual(numel(manifest.evidenceFiles),14);
            t.assertEqual(numel(freezeIndex),1);
            freezePath=fullfile(options.outputFolder,'project','experiments', ...
                'evidence','freeze.json');
            t.assertTrue(isfile(freezePath));

            before=runPackagedPreflight(t,options.outputFolder);
            writeText(freezePath,'tampered freeze evidence');
            after=runPackagedPreflight(t,options.outputFolder);

            t.verifyTrue(before.passed,strjoin(string(before.errors),'; '));
            t.verifyFalse(before.readiness.scientificAccepted);
            t.verifyFalse(after.passed);
            t.verifyFalse(after.readiness.scientificAccepted);
        end

        function d4EvidenceReferencesKeepBasenamesAndHashes(t)
            [options,root,cleanup]=acceptanceBundle( ...
                'candidate','test-fixture','',repmat('a',1,64)); %#ok<ASGLU>

            manifest=prepareExternalRun(options);

            t.verifyTrue(manifest.modelAcceptance.included);
            t.verifyEqual(numel(manifest.modelAcceptance.references),13);
            t.verifyEqual(manifest.evidenceFiles,manifest.modelAcceptance.references);
            for k=1:numel(manifest.modelAcceptance.references)
                item=manifest.modelAcceptance.references(k);
                t.verifyEqual(item.packagePath,['project/' item.path]);
                packaged=fullfile(options.outputFolder,strrep(item.packagePath,'/',filesep));
                t.verifyTrue(isfile(packaged));
                t.verifyEqual(nbiot.ml.fileSha256(packaged),item.packageSha256);
                t.verifyEqual(item.packageSha256,item.sha256);
            end
            t.verifyFalse(contains(jsonencode(manifest),root));
        end
    end
end

function report=runPackagedPreflight(t,packageRoot)
projectRoot=fileparts(fileparts(mfilename('fullpath')));
originalPath=path; originalFolder=pwd;
restore=onCleanup(@() restoreMatlabPath(originalPath,originalFolder)); %#ok<NASGU>
entries=strsplit(originalPath,pathsep);
keep=entries(~cellfun(@(entry)isUnderPath(entry,projectRoot),entries));
path(strjoin(keep,pathsep));
cd(tempdir);
sourceRoot=fullfile(packageRoot,'project','src');
preflightFolder=fullfile(packageRoot,'project','verification','external');
expected=fullfile(preflightFolder,'validateExternalPreflight.m');
t.assertTrue(isfile(expected),'The moved package is missing its preflight entrypoint.');
t.assertTrue(isfile(fullfile(sourceRoot,'+nbiot','+ml','fileSha256.m')), ...
    'The moved package is missing the preflight SHA-256 dependency.');
addpath(sourceRoot,preflightFolder);
clear('validateExternalPreflight');
clear('nbiot.ml.fileSha256');
t.assertEqual(canonicalPathForTest(which('validateExternalPreflight')), ...
    canonicalPathForTest(expected));
t.assertEqual(canonicalPathForTest(which('nbiot.ml.fileSha256')), ...
    canonicalPathForTest(fullfile(sourceRoot,'+nbiot','+ml','fileSha256.m')));
report=validateExternalPreflight(packageRoot);
end

function yes=isUnderPath(value,root)
yes=false;
if isempty(value), return; end
candidate=canonicalPathForTest(value);
root=canonicalPathForTest(root);
yes=strcmpi(candidate,root)||startsWith(lower(candidate),lower([root filesep]));
end

function restoreMatlabPath(originalPath,originalFolder)
cd(originalFolder);
path(originalPath);
clear('validateExternalPreflight');
clear('nbiot.ml.fileSha256');
end

function value=canonicalPathForTest(value)
value=char(java.io.File(char(value)).getCanonicalPath());
end

function [options,root,cleanup]=packageFixture()
root=tempname; mkdir(root); cleanup=onCleanup(@() removeFolder(root));
folders={'apps','configs','docs','examples','experiments','src','tests', ...
    'results','verification/external','verification/local'};
for k=1:numel(folders), mkdir(fullfile(root,strrep(folders{k},'/',filesep))); end
projectRoot=fileparts(fileparts(mfilename('fullpath')));
mkdir(fullfile(root,'src','+nbiot','+ml'));
copyfile(fullfile(projectRoot,'src','+nbiot','+ml','fileSha256.m'), ...
    fullfile(root,'src','+nbiot','+ml','fileSha256.m'));
copyfile(fullfile(projectRoot,'verification','external','validateExternalPreflight.m'), ...
    fullfile(root,'verification','external','validateExternalPreflight.m'));
writeText(fullfile(root,'setupProject.m'),'function setupProject; end');
writeText(fullfile(root,'README.md'),'Fixture project');
writeText(fullfile(root,'AGENTS.md'),'Project instructions for external handoff.');
writeText(fullfile(root,'apps','NBIoTApp.m'), ...
    '% app fixture without machine-specific paths');
writeText(fullfile(root,'verification','local','private-note.txt'),'do not package');
writeText(fullfile(root,'results','nprach-calibration.mat'),'calibration fixture');
registry=struct('schemaVersion',1,'roles',{{'stage-3-load-pilot','training'}}, ...
    'reservations',struct('role','legacy-holdout','range',[0 999]), ...
    'assignments',struct('role','stage-3-load-pilot','ids',1064,'status','failed'));
writeText(fullfile(root,'experiments','realizationRegistry.json'),jsonencode(registry));
options=struct('projectRoot',root, ...
    'outputFolder',fullfile(root,'verification','external','draft-package'), ...
    'calibrationFile','results/nprach-calibration.mat', ...
    'registryFile','experiments/realizationRegistry.json', ...
    'caseMatrix',table("Static",100,5000,"burst",100, ...
        'VariableNames',{'method','numUE','durationTicks','trafficKind','burstDurationTicks'}), ...
    'idAssignments',table(1500,"stage-3-load-pilot", ...
        'VariableNames',{'externalRealizationId','role'}));
end

function [options,root,cleanup]=acceptanceBundle(status,evidenceKind,reviewDigest,evidenceDigest,includeFreeze)
if nargin<5, includeFreeze=false; end
[options,root,cleanup]=packageFixture();
evidenceFolder=fullfile(root,'experiments','evidence'); mkdir(evidenceFolder);
modelPath=fullfile(evidenceFolder,'linearRegression.mat');
writeText(modelPath,'model fixture bytes');
modelHash=nbiot.ml.fileSha256(modelPath);
sidecarPath=fullfile(evidenceFolder,'linearRegression.json');
sidecar=struct('modelName','linearRegression','artifactFile','linearRegression.mat', ...
    'artifactSha256',modelHash);
writeText(sidecarPath,jsonencode(sidecar));
refs=struct();
refs.model=struct('file','evidence/linearRegression.mat','sha256',modelHash);
refs.modelSidecar=struct('file','evidence/linearRegression.json', ...
    'sha256',nbiot.ml.fileSha256(sidecarPath));
names={'dataset','datasetManifest','datasetArtifacts','trainingManifest','metrics', ...
    'sourceManifest','calibration','registry','policy','protocol','evaluation'};
for k=1:numel(names)
    name=names{k}; extension='.json';
    if ismember(name,{'dataset','calibration'}), extension='.mat'; end
    if strcmp(name,'metrics'), extension='.csv'; end
    filename=[name extension]; file=fullfile(evidenceFolder,filename);
    writeText(file,['fixture evidence ' name]);
    refs.(name)=struct('file',['evidence/' filename], ...
        'sha256',nbiot.ml.fileSha256(file));
end
protocolSha=refs.protocol.sha256;
review=struct('decision','pending','reviewer','','reviewedAtUtc','', ...
    'evidenceDigest','','protocolSha256','','limitations','');
if strcmp(status,'accepted')
    review=struct('decision','accepted','reviewer','fixture reviewer', ...
        'reviewedAtUtc','2026-10-19T00:00:00Z','evidenceDigest',reviewDigest, ...
        'protocolSha256',protocolSha,'limitations','Test fixture only');
end
acceptance=struct('schemaVersion','model-acceptance-v1','status',status, ...
    'evidenceKind',evidenceKind,'featureSchemaVersion','bs-known-v2.0', ...
    'evidenceDigest',evidenceDigest,'review',review, ...
    'trainingIds',11,'validationIds',21,'testIds',31,'policyTuningIds',21, ...
    'scope',struct('methods',{{'Adaptive-P','Adaptive-RA/DT'}}, ...
    'numUE',[100 500],'trafficKinds',{{'burst'}},'windowTicks',500, ...
    'burstDurationTicks',100),'policySha256',repmat('c',1,64));
names=fieldnames(refs);
for k=1:numel(names), acceptance.(names{k})=refs.(names{k}); end
if includeFreeze
    freezePath=fullfile(evidenceFolder,'freeze.json');
    writeText(freezePath,'freeze fixture');
    acceptance.freeze=struct('file','evidence/freeze.json', ...
        'sha256',nbiot.ml.fileSha256(freezePath));
end
canonicalDigest=canonicalEvidenceDigest(acceptance);
if strcmp(reviewDigest,'canonical'), reviewDigest=canonicalDigest; end
if strcmp(evidenceDigest,'canonical'), evidenceDigest=canonicalDigest; end
acceptance.evidenceDigest=evidenceDigest;
if strcmp(status,'accepted'), acceptance.review.evidenceDigest=reviewDigest; end
writeText(fullfile(root,'experiments','modelAcceptance.json'),jsonencode(acceptance));
options.modelAcceptanceFile='experiments/modelAcceptance.json';
options.caseMatrix.method(:)="Adaptive-P";
end

function digest=canonicalEvidenceDigest(acceptance)
names={'model','modelSidecar','dataset','datasetManifest','datasetArtifacts', ...
    'trainingManifest','metrics','sourceManifest','calibration','registry','policy','protocol','evaluation'};
refs=struct();
for k=1:numel(names)
    item=acceptance.(names{k});
    refs.(names{k})=struct('file',strrep(item.file,'\','/'), ...
        'sha256',lower(item.sha256));
end
scope=acceptance.scope;
canonicalScope=struct('methods',{sort(cellstr(string(scope.methods(:))).')}, ...
    'numUE',sort(double(scope.numUE(:).')), ...
    'trafficKinds',{sort(cellstr(string(scope.trafficKinds(:))).')}, ...
    'windowTicks',double(scope.windowTicks));
canonicalScope.burstDurationTicks=sort(double(scope.burstDurationTicks(:).'));
canonical=struct('schemaVersion',acceptance.schemaVersion, ...
    'featureSchemaVersion',acceptance.featureSchemaVersion,'refs',refs, ...
    'trainingIds',sort(double(acceptance.trainingIds(:).')), ...
    'validationIds',sort(double(acceptance.validationIds(:).')), ...
    'testIds',sort(double(acceptance.testIds(:).')), ...
    'policyTuningIds',sort(double(acceptance.policyTuningIds(:).')), ...
    'scope',canonicalScope,'protocolSha256',lower(acceptance.protocol.sha256), ...
    'policySha256',lower(acceptance.policySha256));
digest=sha256Text(jsonencode(canonical));
end

function writeText(path,value)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not create preflight fixture file.');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function digest=sha256Text(value)
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(typecast(uint8(unicode2native(value,'UTF-8')),'int8'));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
