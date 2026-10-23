% Verify dataset-role separation without running a network simulation.
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDirectory));
cd(projectRoot);
setupProject();

logFile = fullfile('verification', 'local', ...
    'dataset-role-separation-final-20261013.log');
if isfile(logFile)
    delete(logFile);
end
diary(logFile);
diaryCleanup = onCleanup(@() diary('off')); %#ok<NASGU>

files = {
    'src/+nbiot/+dataset/assembleLoadDataset.m'
    'src/+nbiot/+dataset/summarizeLoadDataset.m'
    'experiments/buildLoadDataset.m'
    'src/+nbiot/+ui/exportDevelopmentDataset.m'
    'tests/TestLoadDataset.m'
    };
diagnosticCount = 0;
for fileIndex = 1:numel(files)
    messages = checkcode(files{fileIndex}, '-id');
    fprintf('%s: %d checkcode message(s)\n', ...
        files{fileIndex}, numel(messages));
    diagnosticCount = diagnosticCount + numel(messages);
    for messageIndex = 1:numel(messages)
        fprintf('  %s line %d: %s\n', messages(messageIndex).id, ...
            messages(messageIndex).line, messages(messageIndex).message);
    end
end
assert(diagnosticCount == 0, 'checkcode messages remain');

results = runtests('tests/TestLoadDataset.m');
assertSuccess(results);
fprintf('PASS: TestLoadDataset %d/%d.\n', sum([results.Passed]), numel(results));
