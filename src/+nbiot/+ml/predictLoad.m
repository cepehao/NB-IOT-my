function estimate=predictLoad(bundleOrFile,observationRow,publicLimits)
%PREDICTLOAD Predict meanRaUe from one complete BS observation window.
bundle=nbiot.ml.validateModelBundle(bundleOrFile);
if ~istable(observationRow)||height(observationRow)~=1
    error('nbiot:ml:Observation','Supply exactly one named BS observation row.');
end
expected=[bundle.keyNames,bundle.featureNames];
if ~isequal(observationRow.Properties.VariableNames,expected)
    error('nbiot:ml:FeatureOrder','Observation columns must match the saved key and feature order exactly.');
end
if ~isnumeric(observationRow{:,expected})||any(~isfinite(observationRow{:,bundle.keyNames}),'all')
    error('nbiot:ml:Observation','Observation keys and feature values must be numeric.');
end
validateLimits(publicLimits);
x=double(observationRow{:,bundle.featureNames});
for column=1:size(x,2)
    x(isnan(x(:,column)),column)=bundle.transform.median(column);
end
x=(x-bundle.transform.mean)./bundle.transform.scale;
prediction=double(predict(bundle.model,x));
if ~isscalar(prediction), error('nbiot:ml:Prediction','Model must return one numeric estimate.'); end
estimate=struct('value',prediction,'valid',false, ...
    'featureWindowEndTick',double(observationRow.endTick), ...
    'reason','nonfinite-prediction');
if ~isfinite(prediction), return; end
if prediction<publicLimits.minimum||prediction>publicLimits.maximum
    estimate.reason='prediction-outside-public-limits';
    return;
end
estimate.valid=true; estimate.reason='ok';
end

function validateLimits(limits)
if ~isstruct(limits)||~isscalar(limits)||~all(isfield(limits,{'minimum','maximum'}))|| ...
        ~isnumeric(limits.minimum)||~isscalar(limits.minimum)||~isfinite(limits.minimum)|| ...
        ~isnumeric(limits.maximum)||~isscalar(limits.maximum)||~isfinite(limits.maximum)|| ...
        limits.minimum<0||limits.maximum<limits.minimum
    error('nbiot:ml:PublicLimits','Public limits need finite minimum and maximum values.');
end
end
