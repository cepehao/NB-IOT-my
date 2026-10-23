%RUNCFODETECTORREGRESSION Run the NPRACH interference regression tests.
projectRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(projectRoot);
setupProject();
results=runtests(fullfile(projectRoot,'tests','TestNprachInterference.m'));
assertSuccess(results);
