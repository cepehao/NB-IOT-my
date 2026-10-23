% Audit-close the old incomplete collection; leave all completed data intact.
root=fileparts(fileparts(fileparts(mfilename('fullpath')))); addpath(root); cd(root); setupProject();
registryFile=fullfile(root,'experiments','realizationRegistry.json');
registry=jsondecode(fileread(registryFile));
match=find(arrayfun(@(a) strcmp(a.role,'stage-3-load-pilot')&&isequal(a.ids,1064),registry.assignments));
assert(numel(match)==1&&strcmp(registry.assignments(match).status,'planned'), ...
    'Expected the one known incomplete planned allocation.');
pilot=fullfile(root,'verification','completion','stage-3','pilot-20261008-005640-821','simulation');
assert(isempty(dir(fullfile(pilot,'n05000-id1064','run-*','case-complete.json'))), ...
    'Do not mark a completed fifth case as an interrupted collection.');
counts=[100 500 1000 2500];
for count=counts
    assert(numel(dir(fullfile(pilot,sprintf('n%05d-id1064',count),'run-*','case-complete.json')))==1);
end
backup=fullfile(root,'verification','completion','stage-3','registry-before-interruption-20261013.json');
assert(~isfile(backup),'Do not overwrite an existing registry backup.');
copyfile(registryFile,backup);
nbiot.experiments.updateRealizationUseStatus(registryFile,'stage-3-load-pilot',1064,'failed');
fprintf('INTERRUPTED_PILOT id=1064 collection=failed completedCasesPreserved=4 stagingPreserved=1\n');
