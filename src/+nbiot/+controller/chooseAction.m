function action=chooseAction(method,estimate,bsState,currentAction,policyConfig)
%CHOOSEACTION Propose a bounded action from one recent, validated load estimate.
if nargin<5||isempty(policyConfig), policyConfig=adaptiveDefaults(); end
method=char(string(method));
allowed={'Static','Adaptive-P','Adaptive-RA/DT'};
if ~any(strcmp(method,allowed))
    error('nbiot:controller:Method','Unknown control method.');
end
validatePolicy(policyConfig);
validateAction(currentAction);
if ~isstruct(bsState)||~isscalar(bsState)||~all(isfield(bsState,{'tick','durationTicks'}))|| ...
        ~validTick(bsState.tick)||~validTick(bsState.durationTicks)||bsState.durationTicks<1
    error('nbiot:controller:State','BS state needs nonnegative integer tick and positive durationTicks.');
end
action=struct('accessProbability',currentAction.accessProbability, ...
    'raShare',currentAction.raShare,'effectiveTick',double(bsState.tick), ...
    'decisionTick',double(bsState.tick),'estimateValue',NaN,'reason','unchanged');
if strcmp(method,'Static'), action.reason='static'; return; end
if bsState.tick==0
    action.effectiveTick=0; action.reason='no-prior-window'; return;
end
if bsState.tick>=bsState.durationTicks
    action.effectiveTick=bsState.durationTicks; action.reason='after-horizon'; return;
end
if mod(bsState.tick,policyConfig.windowTicks)~=0
    action.reason='not-decision-boundary'; return;
end
if ~isstruct(estimate)||~isscalar(estimate)|| ...
        ~all(isfield(estimate,{'valid','value','featureWindowEndTick'}))
    action.reason='invalid-estimate'; return;
end
if ~isequal(estimate.valid,true)||~isnumeric(estimate.value)||~isscalar(estimate.value)|| ...
        ~isfinite(estimate.value)||estimate.value<0||estimate.value>policyConfig.maximumLoad
    action.reason='invalid-estimate'; return;
end
if ~validTick(estimate.featureWindowEndTick)||estimate.featureWindowEndTick~=bsState.tick
    action.reason='stale-window'; return;
end
loadEstimate=double(estimate.value);
action.estimateValue=loadEstimate;
if strcmp(method,'Adaptive-P')
    action.accessProbability=selectLevel(loadEstimate, ...
        policyConfig.accessLoadThresholds,policyConfig.accessProbabilityLevels);
    action.raShare=policyConfig.staticRaShare;
else
    action.accessProbability=policyConfig.staticAccessProbability;
    action.raShare=selectLevel(loadEstimate, ...
        policyConfig.raLoadThresholds,policyConfig.raShareLevels);
end
action.effectiveTick=double(bsState.tick);
action.reason='load-threshold';
end

function value=selectLevel(loadEstimate,thresholds,levels)
index=find(loadEstimate<=thresholds,1,'first');
if isempty(index), index=numel(levels); end
value=levels(index);
end

function validateAction(action)
if ~isstruct(action)||~isscalar(action)|| ...
        ~all(isfield(action,{'accessProbability','raShare'}))
    error('nbiot:controller:Action','Current action needs accessProbability and raShare.');
end
p=action.accessProbability; share=action.raShare;
if ~isnumeric(p)||~isscalar(p)||~isfinite(p)||p<0||p>1|| ...
        ~isnumeric(share)||~isscalar(share)||~isfinite(share)||share<=0||share>=1
    error('nbiot:controller:Action','Current action is outside supported limits.');
end
end

function validatePolicy(policy)
required={'windowTicks','staticAccessProbability','staticRaShare', ...
    'accessLoadThresholds','accessProbabilityLevels','raLoadThresholds', ...
    'raShareLevels','maximumLoad'};
if ~isstruct(policy)||~isscalar(policy)||~all(isfield(policy,required))
    error('nbiot:controller:Policy','Adaptive policy is missing required fields.');
end
if ~validTick(policy.windowTicks)||policy.windowTicks<1|| ...
        ~isfinite(policy.staticAccessProbability)||policy.staticAccessProbability<0|| ...
        policy.staticAccessProbability>1||~isfinite(policy.staticRaShare)|| ...
        policy.staticRaShare<=0||policy.staticRaShare>=1|| ...
        ~isnumeric(policy.maximumLoad)||~isscalar(policy.maximumLoad)|| ...
        ~isfinite(policy.maximumLoad)||policy.maximumLoad<0
    error('nbiot:controller:Policy','Adaptive policy limits are invalid.');
end
validateLevels(policy.accessLoadThresholds,policy.accessProbabilityLevels,-1);
validateLevels(policy.raLoadThresholds,policy.raShareLevels,1);
end

function validateLevels(thresholds,levels,direction)
if ~isnumeric(levels)||~isrow(levels)||isempty(levels)||any(~isfinite(levels))|| ...
        any(direction*diff(levels)<=0)||~isnumeric(thresholds)|| ...
        (~isempty(thresholds)&&~isrow(thresholds))|| ...
        numel(thresholds)~=numel(levels)-1||any(~isfinite(thresholds))|| ...
        any(thresholds<0)||any(diff(thresholds)<=0)
    error('nbiot:controller:Policy','Thresholds and action levels must be ordered finite rows.');
end
end

function yes=validTick(value)
yes=isnumeric(value)&&isscalar(value)&&isreal(value)&&isfinite(value)&& ...
    value>=0&&value==fix(value);
end
