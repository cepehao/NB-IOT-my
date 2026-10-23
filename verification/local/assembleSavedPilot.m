% Read the four existing completed cases; do not run simulation or training.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(root); cd(root); setupProject();
pilot=fullfile(root,'verification','completion','stage-3','pilot-20261008-005640-821','simulation');
files=cell(1,4); counts=[100 500 1000 2500];
for k=1:numel(counts)
    markers=dir(fullfile(pilot,sprintf('n%05d-id1064',counts(k)),'run-*','case-complete.json'));
    assert(numel(markers)==1,'Expected one preserved completed case for each existing count.');
    marker=jsondecode(fileread(fullfile(markers.folder,markers.name)));
    files{k}=fullfile(markers.folder,marker.resultFile);
end
splitManifest=table(1064,"development",'VariableNames',{'externalRealizationId','split'});
options=struct('resultFiles',{files},'splitManifest',splitManifest, ...
    'outputFolder',fullfile(root,'results','datasets','pilot-development-20261013'),'purpose','development');
data=buildLoadDataset(options);
assert(height(data.features)==40&&width(data.features)==9&&data.manifest.independentRealizations==1);
fprintf('SAVED_PILOT_DATA cases=4 rows=%d features=%d independentIDs=%d kind=%s\n', ...
    height(data.features),width(data.features),data.manifest.independentRealizations,data.manifest.kind);
