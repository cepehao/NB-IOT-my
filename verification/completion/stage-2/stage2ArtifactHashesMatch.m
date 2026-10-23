function tf=stage2ArtifactHashesMatch(a,b)
%STAGE2ARTIFACTHASHESMATCH Compare manifests independent of JSON array shape.
required={'relativePath','sha256'};
if ~isstruct(a)||~isstruct(b)||isempty(a)||isempty(b)||...
        ~all(isfield(a,required))||~all(isfield(b,required))||numel(a)~=numel(b)
    tf=false; return;
end
a=a(:); b=b(:);
[~,ia]=sort({a.relativePath}); [~,ib]=sort({b.relativePath});
a=a(ia); b=b(ib);
tf=true;
for k=1:numel(a)
    if ~strcmp(a(k).relativePath,b(k).relativePath)||...
            ~strcmpi(a(k).sha256,b(k).sha256)
        tf=false; return;
    end
end
end
