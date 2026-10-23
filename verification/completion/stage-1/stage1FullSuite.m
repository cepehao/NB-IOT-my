stageRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
cd(stageRoot); addpath(stageRoot); setupProject();
fprintf('MATLAB_VERSION=%s RELEASE=%s\n',version,version('-release'));
r=runtests('tests','IncludeSubfolders',true);
fprintf('STAGE1_FULL_SUITE total=%d passed=%d failed=%d incomplete=%d\n',numel(r),sum([r.Passed]),sum([r.Failed]),sum([r.Incomplete]));
assertSuccess(r);
