% Verify the model-training role boundary on synthetic data only.
scriptDirectory = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDirectory));
cd(projectRoot);
setupProject();

logFile = fullfile('verification', 'local', ...
    'model-role-guard-20261013.log');
if isfile(logFile)
    delete(logFile);
end
diary(logFile);
diaryCleanup = onCleanup(@() diary('off')); %#ok<NASGU>

files = {'src/+nbiot/+ml/trainLoadModels.m', 'tests/TestLoadModels.m'};
diagnosticCount = 0;
for fileIndex = 1:numel(files)
    messages = checkcode(files{fileIndex}, '-id');
    fprintf('%s: %d checkcode messages\n', ...
        files{fileIndex}, numel(messages));
    diagnosticCount = diagnosticCount + numel(messages);
    for messageIndex = 1:numel(messages)
        fprintf('  %s line %d: %s\n', messages(messageIndex).id, ...
            messages(messageIndex).line, messages(messageIndex).message);
    end
end
assert(diagnosticCount == 0, 'checkcode messages remain');

results = runtests('tests/TestLoadModels.m');
assertSuccess(results);
fprintf('PASS: TestLoadModels %d/%d.\n', sum([results.Passed]), numel(results));
