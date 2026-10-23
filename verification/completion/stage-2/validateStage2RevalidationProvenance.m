function validateStage2RevalidationProvenance(runReport,manifest,currentCalibrationSha256,currentRegistrySha256)
%VALIDATESTAGE2REVALIDATIONPROVENANCE Bind paired evidence to sampled inputs.
requiredReport={'revalidation','calibrationSha256','receiverRevision',...
    'sourceManifest','matlabRelease'};
requiredMetadata={'mode','collisionIdsReusedFromFailedRun','collisionIds',...
    'previousReceiverIds','freshReceiverIds','officialRegistrySha256BeforeRun',...
    'officialRegistrySha256AfterRun','officialRegistryBeforeSnapshot',...
    'officialRegistryAfterSnapshot','temporaryRegistry','temporaryRegistrySha256',...
    'sourceManifestSha256','calibrationSha256','receiverRevision','matlabRelease'};
if ~isstruct(runReport)||~isscalar(runReport)||~all(isfield(runReport,requiredReport))||...
        ~isstruct(manifest)||~isscalar(manifest)||~all(isfield(manifest,requiredMetadata))||...
        ~isstruct(runReport.revalidation)||~isscalar(runReport.revalidation)||...
        ~all(isfield(runReport.revalidation,requiredMetadata))
    error('nbiot:stage2:Provenance','Paired revalidation provenance is incomplete.');
end
metadata=runReport.revalidation;
if ~strcmp(metadata.mode,'paired-rerun-after-cfo-detector-fix')||...
        ~isequal(metadata.collisionIdsReusedFromFailedRun,true)
    error('nbiot:stage2:Provenance','Physical evidence is not the declared paired receiver revalidation.');
end
for k=1:numel(requiredMetadata)
    field=requiredMetadata{k};
    left=metadata.(field); right=manifest.(field);
    if ismember(field,{'collisionIds','previousReceiverIds','freshReceiverIds'})
        agrees=isnumeric(left)&&isnumeric(right)&&isequal(double(left(:)),double(right(:)));
    else
        agrees=isequal(left,right);
    end
    if ~agrees
        error('nbiot:stage2:Provenance','Run report and revalidation manifest disagree on %s.',field);
    end
end
if ~strcmp(runReport.calibrationSha256,metadata.calibrationSha256)||...
        ~strcmp(metadata.calibrationSha256,currentCalibrationSha256)
    error('nbiot:stage2:Provenance','Calibration changed after physical sampling or its recorded hash is inconsistent.');
end
if ~strcmp(runReport.sourceManifest.sha256,metadata.sourceManifestSha256)||...
        ~strcmp(runReport.receiverRevision,metadata.receiverRevision)||...
        ~strcmp(runReport.matlabRelease,metadata.matlabRelease)
    error('nbiot:stage2:Provenance','Run report and recorded source/runtime provenance disagree.');
end
if ~strcmp(metadata.officialRegistrySha256AfterRun,currentRegistrySha256)
    error('nbiot:stage2:Provenance','Official realization registry changed after the paired physical run.');
end
hashes={metadata.officialRegistrySha256BeforeRun,metadata.officialRegistrySha256AfterRun,...
    metadata.temporaryRegistrySha256,metadata.sourceManifestSha256,metadata.calibrationSha256};
if any(cellfun(@(value)isempty(regexp(char(value),'^[0-9a-f]{64}$','once')),hashes))
    error('nbiot:stage2:Provenance','A provenance SHA-256 value is malformed.');
end
collisionIds=double(metadata.collisionIds(:).');
previousReceiverIds=double(metadata.previousReceiverIds(:).');
freshReceiverIds=double(metadata.freshReceiverIds(:).');
if isempty(collisionIds)||numel(unique(collisionIds))~=numel(collisionIds)||...
        numel(previousReceiverIds)<10||mod(numel(previousReceiverIds),10)~=0||...
        numel(unique(previousReceiverIds))~=numel(previousReceiverIds)||...
        numel(freshReceiverIds)~=10||numel(unique(freshReceiverIds))~=10||...
        ~isempty(intersect(collisionIds,freshReceiverIds))||...
        ~isempty(intersect(previousReceiverIds,freshReceiverIds))
    error('nbiot:stage2:Provenance','Paired collision and receiver realization IDs are invalid or overlap.');
end
end
