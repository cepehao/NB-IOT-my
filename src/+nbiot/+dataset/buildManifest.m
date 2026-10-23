function manifest=buildManifest(realizationIds)
%BUILDMANIFEST Deterministic 70/15/15 assignment of entire realizations.
ids=unique(double(realizationIds(:)));
if any(ids<0 | ids>=4000 | ids~=fix(ids)), error('nbiot:dataset:RunId','Expected main realization IDs 0:3999.'); end
% Twenty-ID blocks interleave independent realizations; never split windows.
bucket=mod(ids,20); split=repmat("train",size(ids));
split(bucket>=14 & bucket<17)="validation"; split(bucket>=17)="test";
manifest=table(ids,split,'VariableNames',{'externalRealizationId','split'});
end
