function verifyModelAcceptanceRuntimeIdentity(accepted,currentSourceSha256,currentCalibrationSha256)
%VERIFYMODELACCEPTANCERUNTIMEIDENTITY Compare active code/calibration to evidence.
try
    required={'sourceSha256','calibrationSha256'};
    if ~isstruct(accepted)||~isscalar(accepted)||~all(isfield(accepted,required))
        reject('Accepted runtime evidence identity is incomplete.');
    end
    expectedSource=sha256Text(accepted.sourceSha256,'accepted computational source hash');
    expectedCalibration=sha256Text(accepted.calibrationSha256,'accepted calibration hash');
    currentSource=sha256Text(currentSourceSha256,'current computational source hash');
    currentCalibration=sha256Text(currentCalibrationSha256,'current calibration file hash');
    if ~strcmpi(expectedSource,currentSource)
        reject('Current computational source manifest differs from accepted evidence.');
    end
    if ~strcmpi(expectedCalibration,currentCalibration)
        reject('Current calibration file differs from accepted evidence.');
    end
catch exception
    if strcmp(exception.identifier,'nbiot:ml:ModelAcceptance'), rethrow(exception); end
    error('nbiot:ml:ModelAcceptance','Runtime evidence identity verification failed: %s',exception.message);
end
end

function value=sha256Text(value,label)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||size(value,1)~=1||numel(value)~=64|| ...
        any(~ismember(lower(value),'0123456789abcdef'))
    reject('%s is invalid.',label);
end
value=lower(value);
end

function reject(message,varargin)
error('nbiot:ml:ModelAcceptance',message,varargin{:});
end
