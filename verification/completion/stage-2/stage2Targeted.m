root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
cd(root); addpath(root); setupProject(); addpath(fullfile(root,'tests'));
addpath(fullfile(root,'verification','completion','stage-2'));
assert(strcmp(version('-release'),'2025b'), ...
    'nbiot:stage2:Release','Stage 2 targeted tests require MATLAB R2025b.');
lte=ver('lte'); assert(~isempty(lte), ...
    'nbiot:stage2:Toolbox','LTE Toolbox is required for Stage 2 validation.');
fprintf('MATLAB_VERSION=%s RELEASE=%s ROOT=%s\n',version,version('-release'),root);
fprintf('LTE_TOOLBOX version=%s\n',lte.Version);
testFiles={'tests/TestCollisionCapture.m','tests/TestNprachInterference.m',...
    'tests/TestStage2Acceptance.m',...
    'tests/TestExperimentRegistry.m','tests/TestLoadPilot.m',...
    'tests/TestStage2PhysicalRunner.m'};
results=[];
for k=1:numel(testFiles)
    current=runtests(testFiles{k});
    if isempty(results), results=current(:); else, results=[results; current(:)]; end %#ok<AGROW>
end
fprintf('STAGE2_TARGETED total=%d passed=%d failed=%d incomplete=%d\n',...
    numel(results),sum([results.Passed]),sum([results.Failed]),sum([results.Incomplete]));
assertSuccess(results);
