classdef TestExternalRegistryTransitions < matlab.unittest.TestCase
    methods (Test)
        function fullManifestAllowsTwoRegistryTransitionsAndRejectsUnapprovedRewrite(t)
            % Нужны PowerShell и фикстура супервизора (в поставке v4 её нет) — иначе пропуск.
            fixtureScript=fullfile(fileparts(mfilename('fullpath')),'fixtures', ...
                'InvokeBoundedProcess-registry-transition-fixture.ps1');
            t.assumeTrue(ispc && isfile(fixtureScript),'Requires Windows PowerShell and its supervisor fixture.');
            sourceRoot=fileparts(fileparts(mfilename('fullpath')));
            fixtureRoot=fullfile(tempdir,['nbiot-registry-transitions-' ...
                char(java.util.UUID.randomUUID())]);
            [created,~]=mkdir(fixtureRoot);
            t.assertTrue(created,'The isolated full-source fixture must be created.');
            cleanupFixture=onCleanup(@() removeFixtureTree(fixtureRoot)); %#ok<NASGU>

            copyProjectSources(sourceRoot,fixtureRoot);
            calibrationPath=fullfile(fixtureRoot,'results','calibration.mat');
            registryPath=fullfile(fixtureRoot,'experiments', ...
                'realizationRegistry.json');
            writeText(calibrationPath,'Test fixture only; never loaded as MAT data.');
            writeText(registryPath,jsonencode(registryFixture()));
            writeTestSupervisor(sourceRoot,fixtureRoot);

            options=struct('projectRoot',fixtureRoot, ...
                'outputFolder',fullfile(fixtureRoot,'verification','external', ...
                    'registry-transition-package'), ...
                'calibrationFile','results/calibration.mat', ...
                'registryFile','experiments/realizationRegistry.json', ...
                'caseMatrix',table("Static",2,60,"burst",2, ...
                    'VariableNames',{'method','numUE','durationTicks', ...
                    'trafficKind','burstDurationTicks'}), ...
                'idAssignments',table(1500,"stage-3-load-pilot", ...
                    'VariableNames',{'externalRealizationId','role'}), ...
                'resourceBudget',struct('targetMachine','test-fixture-machine', ...
                    'availableMemoryBytes',1073741824,'maxUE',5000, ...
                    'maxCaseSeconds',30,'maxSuiteSeconds',60,'maxProcesses',1), ...
                'stageOptions',struct('pilot',struct( ...
                    'pilot5000ApprovalFile','reviews/pilot-5000-approval.json')));
            manifest=prepareExternalRun(options);
            t.assertGreaterThanOrEqual(numel(manifest.codeFiles),300, ...
                'The regression must exercise the full source manifest, not an empty or stub-only manifest.');
            writeTestSupervisor(sourceRoot,options.outputFolder);
            t.verifyEqual(manifest.registry.packagePath, ...
                'project/experiments/realizationRegistry.json');
            fprintf('BOUNDED_TEST full-code-manifest-entries=%d process-only=1\n', ...
                numel(manifest.codeFiles));

            helper=fullfile(sourceRoot,'tests','fixtures', ...
                'testExternalRegistryTransitions.ps1');
            [status,output]=runProcessOnlyHelper(helper, ...
                options.outputFolder,sourceRoot);
            fprintf('%s',output);
            t.verifyEqual(status,0,sprintf( ...
                'The isolated two-transition process-only contract failed:\n%s',output));
            t.verifySubstring(output, ...
                'REGISTRY_SEQUENCE=stage2-advance;pilot-refresh;next-stage-pass;unauthorized-rewrite-blocked');
        end
    end
end

function copyProjectSources(sourceRoot,destinationRoot)
rootFiles={'README.md','setupProject.m','AGENTS.md','RELEASE.md'};
for k=1:numel(rootFiles)
    copyIfPresent(sourceRoot,destinationRoot,rootFiles{k});
end
folders={'apps','configs','docs','examples','experiments','src','tests'};
allowed={'.m','.md','.json','.txt'};
for k=1:numel(folders)
    listing=dir(fullfile(sourceRoot,folders{k},'**','*'));
    for j=1:numel(listing)
        if listing(j).isdir, continue; end
        source=fullfile(listing(j).folder,listing(j).name);
        [~,~,extension]=fileparts(source);
        if ~any(strcmpi(extension,allowed)), continue; end
        relative=relativeSourcePath(sourceRoot,source);
        if isUnsafeSource(relative), continue; end
        copyIfPresent(sourceRoot,destinationRoot,relative);
    end
end
stage2=dir(fullfile(sourceRoot,'verification','completion', ...
    'stage-2','*.m'));
for k=1:numel(stage2)
    if ~stage2(k).isdir
        copyIfPresent(sourceRoot,destinationRoot, ...
            relativeSourcePath(sourceRoot, ...
            fullfile(stage2(k).folder,stage2(k).name)));
    end
end
runnerSources={ ...
    'verification/completion/stage-2/runStage2Physical.ps1', ...
    'verification/completion/stage-3/runVariant2.ps1', ...
    'verification/completion/stage-3/runLoadPilot.ps1', ...
    'verification/local/InvokeScheduledProcess.ps1', ...
    'verification/local/InvokeBoundedProcess.ps1', ...
    'verification/external/validateExternalPreflight.m', ...
    'verification/local/OwnedProcessJob.cs', ...
    'verification/external/runExternalStages.ps1', ...
    'verification/external/testExternalStages.ps1', ...
    'verification/external/external-stages.schema.json', ...
    'verification/external/runExternalStage.m', ...
    'verification/external/validateExternalComparisonMatrix.m'};
for k=1:numel(runnerSources)
    copyIfPresent(sourceRoot,destinationRoot,runnerSources{k});
end
end

function copyIfPresent(sourceRoot,destinationRoot,relative)
source=fullfile(sourceRoot,strrep(relative,'/',filesep));
if ~isfile(source), return; end
destination=fullfile(destinationRoot,strrep(relative,'/',filesep));
parent=fileparts(destination);
if ~isfolder(parent), mkdir(parent); end
[ok,message]=copyfile(source,destination);
assert(ok,'Could not mirror source fixture file: %s',message);
end

function value=relativeSourcePath(sourceRoot,source)
prefix=[sourceRoot filesep];
assert(strncmpi(source,prefix,numel(prefix)), ...
    'A mirrored source file must remain below the source root.');
value=source(numel(prefix)+1:end);
end

function yes=isUnsafeSource(value)
value=lower(strrep(value,'\','/'));
blocked={'.env','secret','credential','password','token','private-key', ...
    '.pem','.pfx','.key'};
yes=any(cellfun(@(part)contains(value,part),blocked));
end

function registry=registryFixture()
registry=struct('schemaVersion',1, ...
    'roles',{{'stage-3-load-pilot','training'}}, ...
    'reservations',struct('role','legacy-holdout','range',[0 999]), ...
    'assignments',struct('role','stage-3-load-pilot','ids',1064, ...
    'status','failed'));
end

function writeTestSupervisor(sourceRoot,packageRoot)
source=fullfile(sourceRoot,'tests','fixtures', ...
    'InvokeBoundedProcess-registry-transition-fixture.ps1');
destination=fullfile(packageRoot,'project','verification','local', ...
    'InvokeBoundedProcess.ps1');
parent=fileparts(destination);
if ~isfolder(parent), mkdir(parent); end
[ok,message]=copyfile(source,destination);
assert(ok,'Could not install the process-only test supervisor: %s',message);
end

function writeText(path,value)
parent=fileparts(path);
if ~isfolder(parent), mkdir(parent); end
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not create an isolated registry test input.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function removeFixtureTree(path)
candidate=char(java.io.File(path).getCanonicalPath());
tempRoot=char(java.io.File(tempdir).getCanonicalPath());
prefix=[tempRoot filesep];
if ~strncmpi(candidate,prefix,numel(prefix))||strcmpi(candidate,tempRoot)
    error('The test cleanup target escaped its unique temporary fixture root.');
end
if isfolder(candidate), rmdir(candidate,'s'); end
end

function [status,output]=runProcessOnlyHelper(helper,packageFolder,workingDirectory)
capturePath=fullfile(tempdir,['nbiot-registry-transition-helper-' ...
    char(java.util.UUID.randomUUID()) '.txt']);
arguments=java.util.ArrayList();
powerShellPath=fullfile(getenv('SystemRoot'),'System32', ...
    'WindowsPowerShell','v1.0','powershell.exe');
assert(isfile(powerShellPath), ...
    'The Windows PowerShell executable required by the process-only fixture is missing.');
arguments.add(java.lang.String(powerShellPath));
arguments.add(java.lang.String('-NoLogo'));
arguments.add(java.lang.String('-NoProfile'));
arguments.add(java.lang.String('-NonInteractive'));
arguments.add(java.lang.String('-ExecutionPolicy'));
arguments.add(java.lang.String('Bypass'));
arguments.add(java.lang.String('-File'));
arguments.add(java.lang.String(helper));
arguments.add(java.lang.String('-PackageFolder'));
arguments.add(java.lang.String(packageFolder));
builder=java.lang.ProcessBuilder(arguments);
builder.directory(java.io.File(workingDirectory));
builder.redirectErrorStream(true);
builder.redirectOutput(java.io.File(capturePath));
process=[];
try
    process=builder.start();
    process.getOutputStream().close();
    finished=process.waitFor(int64(60), ...
        java.util.concurrent.TimeUnit.SECONDS);
    if ~finished
        process.destroyForcibly();
        process.waitFor();
        status=124;
        output='PROCESS_ONLY_HELPER_TIMED_OUT after 60 seconds.';
    else
        status=process.exitValue();
        if isfile(capturePath), output=fileread(capturePath); else, output=''; end
    end
catch exception
    if ~isempty(process)
        process.destroyForcibly();
        try, process.waitFor(); catch, end
    end
    if isfile(capturePath), delete(capturePath); end
    rethrow(exception);
end
if isfile(capturePath), delete(capturePath); end
end
