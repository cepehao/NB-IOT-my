function match=stage2PhysicalArtifactsMatch(expected,actual)
%STAGE2PHYSICALARTIFACTSMATCH Compare sources that can affect physical results.
% Acceptance workflow and its tests do not participate in physical sampling.
administrative={...
    'verification/completion/stage-2/acceptStage2Evidence.m',...
    'tests/TestStage2Acceptance.m'};
expected=removeAdministrative(expected,administrative);
actual=removeAdministrative(actual,administrative);
if ~isstruct(expected)||~isstruct(actual)||...
        ~all(isfield(expected,{'relativePath','sha256'}))||...
        ~all(isfield(actual,{'relativePath','sha256'}))||...
        numel(expected)~=numel(actual)
    match=false; return
end
[expectedPaths,expectedOrder]=sort(string({expected.relativePath}));
[actualPaths,actualOrder]=sort(string({actual.relativePath}));
match=isequal(expectedPaths,actualPaths);
if match
    match=isequal(string({expected(expectedOrder).sha256}),...
        string({actual(actualOrder).sha256}));
end
end

function artifacts=removeAdministrative(artifacts,administrative)
if ~isstruct(artifacts)||~isfield(artifacts,'relativePath'), return; end
paths=string({artifacts.relativePath});
keep=~ismember(paths,string(administrative));
artifacts=artifacts(keep);
end
