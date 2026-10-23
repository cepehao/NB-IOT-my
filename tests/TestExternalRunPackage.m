classdef TestExternalRunPackage < matlab.unittest.TestCase
    methods (Test)
        function missingCalibrationIsRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.calibrationFile='results/missing-calibration.mat';

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:Calibration');
        end

        function adaptivePackageRequiresAnExplicitModel(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.caseMatrix.method(:)="Adaptive-P";

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:Model');
        end

        function adaptiveModelWithoutSameNameJsonIsRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            writeText(fullfile(root,'results','selectedRegression.mat'),'model fixture');
            options.caseMatrix.method(:)="Adaptive-P";
            options.modelFile='results/selectedRegression.mat';

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:ModelBundle');
        end

        function adaptiveBundleKeepsOriginalBasenames(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            modelFile=fullfile(root,'results','linearRegression.mat');
            sidecarFile=fullfile(root,'results','linearRegression.json');
            writeText(modelFile,'model fixture');
            sidecar=struct('modelName','linearRegression', ...
                'artifactFile','linearRegression.mat', ...
                'artifactSha256',nbiot.ml.fileSha256(modelFile), ...
                'schemaVersion','bs-known-v2.0','targetName','meanRaUe', ...
                'trainingIds',1,'validationIds',2,'testIds',3, ...
                'status','trained','dataKind','development-fixture');
            writeText(sidecarFile,jsonencode(sidecar));
            options.caseMatrix.method(:)="Adaptive-P";
            options.modelFile='results/linearRegression.mat';

            manifest=prepareExternalRun(options);

            t.verifyEqual(manifest.model.packagePath, ...
                'project/results/linearRegression.mat');
            t.verifyTrue(isfile(fullfile(options.outputFolder,'project', ...
                'results','linearRegression.mat')));
            t.verifyTrue(isfile(fullfile(options.outputFolder,'project', ...
                'results','linearRegression.json')));
        end

        function computationalSourceBytesArePreserved(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            source=fullfile(root,'apps','NBIoTApp.m');
            sourceText=['% local source marker: ' root newline ...
                'function app=NBIoTApp; app=[]; end'];
            writeText(source,sourceText);
            original=readBytes(source);

            prepareExternalRun(options);

            packaged=fullfile(options.outputFolder,'project','apps','NBIoTApp.m');
            t.verifyEqual(readBytes(packaged),original);
        end

        function calibrationHashMismatchIsRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.expectedCalibrationSha256=repmat('0',1,64);

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:CalibrationHash');
        end

        function modelHashMismatchIsRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            writeText(fullfile(root,'results','load-model.mat'),'model fixture');
            options.caseMatrix.method(:)="Adaptive-P";
            options.modelFile='results/load-model.mat';
            options.expectedModelSha256=repmat('0',1,64);

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:ModelHash');
        end

        function resourceBudgetCannotLeakAComputerPath(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.resourceBudget=struct('targetMachine',['C:' char(92) 'private']);

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:ResourceBudget');
        end

        function malformedResourceBudgetIsRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.resourceBudget=struct('maxUE',5000,'localPath','test-only');
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:ResourceBudget');

            options.resourceBudget=struct('maxUE',0);
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:ResourceBudget');
        end

        function caseMatrixRejectsUnexpectedFields(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.caseMatrix.localPath=repmat(string(root),height(options.caseMatrix),1);

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:CaseMatrix');
        end

        function validResourceBudgetRemainsDraftForTargetReview(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.resourceBudget=struct('targetMachine','research-pc-2', ...
                'availableMemoryBytes',32*1024^3,'maxUE',5000, ...
                'maxCaseSeconds',18000,'maxSuiteSeconds',500000,'maxProcesses',2);

            manifest=prepareExternalRun(options);

            t.verifyEqual(manifest.resourceStatus,'provided-but-requires-target-review');
            t.verifyEqual(manifest.resourceBudget.targetMachine,'research-pc-2');
            t.verifyFalse(manifest.readyForExecution);
        end

        function duplicateAndAlreadyUsedIdsAreRejected(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.idAssignments=table([1500;1500], ...
                ["stage-3-load-pilot";"training"], ...
                'VariableNames',{'externalRealizationId','role'});
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:DuplicateId');

            options.idAssignments=table(1064,"stage-3-load-pilot", ...
                'VariableNames',{'externalRealizationId','role'});
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:AllocatedId');
        end

        function incompleteStagingDirectoryCannotBeResumed(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.resumePath='verification/completion/stage-3/.staging-interrupted';

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:Resume');
        end

        function mutableRegistryIsPackageStateNotFrozenCode(t)
            [options,~,cleanup]=fixture(); %#ok<ASGLU>
            manifest=prepareExternalRun(options);
            registryPath='experiments/realizationRegistry.json';
            registryEntry=any(strcmp({manifest.codeFiles.path},registryPath));
            packagedRegistry=fullfile(options.outputFolder,'project', ...
                'experiments','realizationRegistry.json');
            t.verifyFalse(registryEntry, ...
                'The working realization registry must not be frozen as a code file.');
            t.verifyEqual(manifest.registry.path,registryPath);
            t.verifyEqual(manifest.registry.packagePath, ...
                ['project/' registryPath]);
            t.verifyTrue(isfile(packagedRegistry), ...
                'The registry remains a separately tracked package input.');
            t.verifyEqual(manifest.registry.sha256, ...
                nbiot.ml.fileSha256(packagedRegistry), ...
                'The separate registry baseline hash must cover the packaged state.');
        end

        function packageUsesCurrentSourcesWithoutLocalPathsOrRegistryMutation(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            options.idAssignments=table(1500,"stage-3-load-pilot", ...
                'VariableNames',{'externalRealizationId','role'});
            registryPath=fullfile(root,'experiments','realizationRegistry.json');
            originalRegistry=fileread(registryPath);

            manifest=prepareExternalRun(options);

            t.verifyFalse(manifest.readyForExecution);
            t.verifyEqual(manifest.status,'draft-needs-external-review');
            t.verifyTrue(any(strcmp({manifest.codeFiles.path},'apps/NBIoTApp.m')));
            t.verifyTrue(any(strcmp({manifest.codeFiles.path},'AGENTS.md')));
            t.verifyTrue(isfile(fullfile(options.outputFolder,'project', ...
                'apps','NBIoTApp.m')));
            t.verifyTrue(isfile(fullfile(options.outputFolder,'project','AGENTS.md')));
            appEntry=manifest.codeFiles(strcmp({manifest.codeFiles.path},'apps/NBIoTApp.m'));
            packagedApp=fullfile(options.outputFolder,'project','apps','NBIoTApp.m');
            t.verifyEqual(nbiot.ml.fileSha256(packagedApp),appEntry.packageSha256);
            t.verifyFalse(contains(fileread(packagedApp),root));
            t.verifyTrue(isfile(fullfile(options.outputFolder,'manifest.json')));
            t.verifyFalse(contains(fileread(fullfile(options.outputFolder,'manifest.json')),root));
            t.verifyFalse(isfile(fullfile(options.outputFolder,'project', ...
                'verification','local','private-note.txt')));
            t.verifyEqual(fileread(registryPath),originalRegistry);
            t.verifyFalse(any(contains(string({manifest.codeFiles.path}),'.env')));
            t.verifyTrue(manifest.requiresStage2Revalidation);
        end

        function packageSanitizationPreservesHttpsAndRedactsWindowsPaths(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            localPath=fullfile(root,'private evidence.txt');
            externalWindowsPath=['C:' char(92) 'LocalFixture' char(92) ...
                'private' char(92) 'result.txt'];
            readme=sprintf(['See [schema](https://example.test/schema) and ' ...
                '[protocol](https://example.test/protocol). Local evidence: `%s`. ' ...
                'External evidence: `%s`.\n'],localPath,externalWindowsPath);
            schema=['{"$schema":"https://json-schema.org/draft/2020-12/schema",' ...
                '"$id":"https://example.test/external-stages.schema.json",' ...
                '"localEvidencePath":"' strrep(localPath,'\','\\') '",' ...
                '"externalEvidencePath":"' strrep(externalWindowsPath,'\','\\') '"}'];
            writeExternalWorkflowFixture(root);
            writeText(fullfile(root,'README.md'),readme);
            schemaPath=fullfile(root,'verification','external', ...
                'external-stages.schema.json');
            writeText(schemaPath,schema);

            manifest=prepareExternalRun(options);

            packagedReadme=fileread(fullfile(options.outputFolder,'project','README.md'));
            packagedSchema=fileread(fullfile(options.outputFolder,'project', ...
                'verification','external','external-stages.schema.json'));
            jsondecode(packagedSchema);
            schemaEntry=manifest.codeFiles(strcmp({manifest.codeFiles.path}, ...
                'verification/external/external-stages.schema.json'));
            t.verifySubstring(packagedReadme,'[schema](https://example.test/schema)');
            t.verifySubstring(packagedReadme,'[protocol](https://example.test/protocol)');
            t.verifySubstring(packagedSchema, ...
                '"$schema":"https://json-schema.org/draft/2020-12/schema"');
            t.verifySubstring(packagedSchema, ...
                '"$id":"https://example.test/external-stages.schema.json"');
            t.verifyFalse(contains(packagedReadme,root));
            t.verifyFalse(contains(packagedSchema,root));
            t.verifySubstring(packagedReadme,'<PROJECT_ROOT>');
            t.verifySubstring(packagedReadme,'<LOCAL_PATH>');
            t.verifySubstring(packagedSchema,'<LOCAL_PATH>');
            t.verifyEqual(numel(schemaEntry),1);
            t.verifyTrue(schemaEntry.sanitized);
        end

        function packageIncludesApprovedExternalRunnerSourcesOnly(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            runnerSources={ ...
                'verification/completion/stage-2/acceptStage2Evidence.m', ...
                'verification/completion/stage-2/checkCurrentStage2Sources.m', ...
                'verification/completion/stage-2/inspectReceiverEvidence.m', ...
                'verification/completion/stage-2/recoverStage2Physical.m', ...
                'verification/completion/stage-2/runCfoDetectorRegression.m', ...
                'verification/completion/stage-2/runStage2Calibration.m', ...
                'verification/completion/stage-2/runStage2ReceiverProbe.m', ...
                'verification/completion/stage-2/runStage2Revalidation.m', ...
                'verification/completion/stage-2/stage2ArtifactHashes.m', ...
                'verification/completion/stage-2/stage2ArtifactHashesMatch.m', ...
                'verification/completion/stage-2/stage2Physical.m', ...
                'verification/completion/stage-2/stage2PhysicalProgress.m', ...
                'verification/completion/stage-2/runStage2Physical.ps1', ...
                'verification/completion/stage-2/stage2PhysicalArtifactsMatch.m', ...
                'verification/completion/stage-2/stage2Targeted.m', ...
                'verification/completion/stage-2/validateStage2RevalidationProvenance.m', ...
                'verification/completion/stage-3/runVariant2.ps1', ...
                'verification/completion/stage-3/runLoadPilot.ps1', ...
                'verification/external/validateExternalPreflight.m', ...
                'verification/local/InvokeScheduledProcess.ps1', ...
                'verification/local/InvokeBoundedProcess.ps1', ...
                'verification/local/OwnedProcessJob.cs'};
            for k=1:numel(runnerSources)
                source=fullfile(root,strrep(runnerSources{k},'/',filesep));
                if strcmp(runnerSources{k},'verification/external/validateExternalPreflight.m')
                    continue
                end
                parent=fileparts(source);
                if ~isfolder(parent), mkdir(parent); end
                writeText(source,['runner fixture ' runnerSources{k}]);
            end
            writeText(fullfile(root,'verification','completion','stage-2','acceptance.json'), ...
                '{"status":"old-evidence"}');
            writeText(fullfile(root,'verification','completion','stage-3','interruption.json'), ...
                '{"status":"old-evidence"}');

            manifest=prepareExternalRun(options);
            packagedPaths=string({manifest.codeFiles.path});

            t.verifyTrue(all(ismember(string(runnerSources),packagedPaths)));
            for k=1:numel(runnerSources)
                entry=manifest.codeFiles(strcmp({manifest.codeFiles.path},runnerSources{k}));
                packaged=fullfile(options.outputFolder,'project', ...
                    strrep(runnerSources{k},'/',filesep));
                t.verifyTrue(isfile(packaged));
                if ~isempty(entry)&&isfile(packaged)
                    t.verifyEqual(nbiot.ml.fileSha256(packaged),entry.packageSha256);
                end
            end
            t.verifyFalse(isfile(fullfile(options.outputFolder,'project', ...
                'verification','completion','stage-2','acceptance.json')));
            t.verifyFalse(isfile(fullfile(options.outputFolder,'project', ...
                'verification','completion','stage-3','interruption.json')));
            expectedCommands=string(manifest.expectedCommands);
            t.verifyTrue(any(contains(expectedCommands,'validateExternalPreflight')));
            t.verifyFalse(any(contains(expectedCommands,'runVariant2')));
            t.verifyFalse(any(contains(expectedCommands,'runStage2Physical')));
            t.verifyFalse(any(contains(expectedCommands,'-Execute')));
            t.verifyFalse(any(contains(expectedCommands,'-Resume')));
        end

        function packageRequiresPortablePreflightAndHashDependency(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            delete(fullfile(root,'verification','external','validateExternalPreflight.m'));
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:PreflightSource');

            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            delete(fullfile(root,'src','+nbiot','+ml','fileSha256.m'));
            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:PreflightSource');
        end

        function packageDoesNotOverwriteExistingOutput(t)
            [options,root,cleanup]=fixture(); %#ok<ASGLU>
            mkdir(options.outputFolder);

            t.verifyError(@() prepareExternalRun(options), ...
                'nbiot:externalRun:OutputExists');
        end
    end
end

function [options,root,cleanup]=fixture()
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
    ['% app fixture without machine-specific paths' newline ...
    'function app=NBIoTApp; app=[]; end']);
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

function writeText(path,value)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not create package fixture file.');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function writeExternalWorkflowFixture(root)
paths={ ...
    'verification/external/runExternalStages.ps1', ...
    'verification/external/testExternalStages.ps1', ...
    'verification/external/external-stages.schema.json', ...
    'verification/external/runExternalStage.m', ...
    'verification/external/validateExternalComparisonMatrix.m', ...
    'docs/external-runbook.md', ...
    'verification/local/InvokeBoundedProcess.ps1', ...
    'verification/local/OwnedProcessJob.cs'};
for k=1:numel(paths)
    path=fullfile(root,strrep(paths{k},'/',filesep));
    parent=fileparts(path);
    if ~isfolder(parent),mkdir(parent);end
    writeText(path,['test-only workflow source: ' paths{k}]);
end
end

function bytes=readBytes(path)
fid=fopen(path,'r');
assert(fid>=0,'Could not read package fixture file.');
cleanup=onCleanup(@() fclose(fid));
bytes=fread(fid,inf,'*uint8');
end

function removeFolder(path)
if isfolder(path), rmdir(path,'s'); end
end
