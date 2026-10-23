function validateLoadProbeRuntime(matlabRelease,lteInfo,licenseAvailable)
%VALIDATELOADPROBERUNTIME Check the supported local MATLAB/LTE runtime.
%   Проверка MATLAB/LTE Toolbox перед нагрузочным прогоном.
if nargin<3, licenseAvailable=false; end
if ~(ischar(matlabRelease)||(isstring(matlabRelease)&&isscalar(matlabRelease)))|| ...
        ~strcmp(char(string(matlabRelease)),'2025b')
    error('nbiot:experiments:LoadProbeRelease', ...
        'The local variant 2 load probe requires MATLAB R2025b.');
end
if isempty(lteInfo)||~islogical(licenseAvailable)||~isscalar(licenseAvailable)||~licenseAvailable
    error('nbiot:experiments:LoadProbeLicense', ...
        'LTE Toolbox installation and an available LTE Toolbox license are required.');
end
end
