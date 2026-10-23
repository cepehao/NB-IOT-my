% Run the registry contract tests and inspect available IDs without allocation.
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDirectory));
cd(projectRoot);
setupProject();

logFile = fullfile('verification', 'local', 'registry-inventory-20261013.log');
if isfile(logFile)
    delete(logFile);
end
diary(logFile);
diaryCleanup = onCleanup(@() diary('off')); %#ok<NASGU>

files = {
    'src/+nbiot/+experiments/availableRealizationIds.m'
    };
diagnosticCount = 0;
for fileIndex = 1:numel(files)
    messages = checkcode(files{fileIndex}, '-id');
    fprintf('%s: %d checkcode messages\n', ...
        files{fileIndex}, numel(messages));
    diagnosticCount = diagnosticCount + numel(messages);
end
assert(diagnosticCount == 0, 'checkcode messages remain');

results = runtests('tests/TestExperimentRegistry.m');
assertSuccess(results);
fprintf('PASS: TestExperimentRegistry %d/%d.\n', ...
    sum([results.Passed]), numel(results));

registryFile = fullfile('experiments', 'realizationRegistry.json');
available = nbiot.experiments.availableRealizationIds( ...
    registryFile, 'training', 0:3999);
fprintf('Read-only inventory: %d of 4000 IDs currently eligible in 0:3999.\n', ...
    numel(available));
fprintf('No IDs were allocated; reservations remain unchanged.\n');
