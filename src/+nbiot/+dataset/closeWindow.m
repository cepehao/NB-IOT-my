function [obs,target]=closeWindow(observed,truth,first,last,raIntegral,activeIntegral,queueIntegral,realizationId,windowTicks,resourceOccupancy,action)
%CLOSEWINDOW Строка датасета для окна [FIRST, LAST) (ТЗ §22): признаки BS и target.
%   OBS — признаки только из журнала наблюдений BS (разрешённые виды событий; исход декодирования
%   у UE запрещён — nbiot:dataset:Leakage); TARGET — из истины и интегралов по тикам окна.
%   Также в признаки входят занятость ресурсов окна и действие контроллера, действовавшее в окне.
e=observed([observed.tick]>=first & [observed.tick]<last);
if nargin<9, windowTicks=500; end
if nargin<10||isempty(resourceOccupancy), resourceOccupancy=missingOccupancy(); end
if nargin<11||isempty(action), action=missingAction(); end
validateDerivedInputs(resourceOccupancy,action,first);
t=truth([truth.tick]>=first & [truth.tick]<last);
det=0; peak=[]; maxPeak=[]; energy=[]; dec=0; failures=0; rar=0; grants=0; queues=[];
s=nbiot.dataset.featureSchema();
for k=1:numel(e)
    if ~ismember(e(k).kind,s.allowedObservationKinds), error('nbiot:dataset:Source','Unapproved observed source.'); end
    f=e(k).fields;
    switch e(k).kind
        case 'nprach_detection'
            det=det+f.count; peak(end+1)=f.meanMetric; maxPeak(end+1)=f.maxMetric; energy(end+1)=f.energyW; %#ok<AGROW>
        case 'phy_decode'
            if f.receiverId~=0, error('nbiot:dataset:Leakage','UE decoder outcome is not a BS observation.'); end
            if f.hasCrc, dec=dec+1; failures=failures+double(f.crcError~=0); end
        case 'rar_sent', rar=rar+1;
        case 'grant', grants=grants+1;
        case 'bs_queue', queues(end+1)=f.pendingRequests; %#ok<AGROW>
    end
end
windowId=floor(first/windowTicks)+1;
obs={realizationId,windowId,first,last,det,average(peak),maximum(maxPeak), ...
    average(energy),dec,failures,rar,grants,average(queues), ...
    resourceOccupancy.ulRaOccupancy,resourceOccupancy.ulDtOccupancy, ...
    resourceOccupancy.dlRaOccupancy,resourceOccupancy.dlDtOccupancy, ...
    action.accessProbability,action.raShare};
% Target: среднее по тикам число UE в RA и с работой, средняя очередь, число Msg1 и UE, передавших Msg1.
msg=t(strcmp({t.kind},'msg1')); users=[];
for k=1:numel(msg), users(end+1)=msg(k).fields.ueId; end %#ok<AGROW>
width=last-first;
target={realizationId,windowId,first,last,raIntegral/width,activeIntegral/width, ...
    queueIntegral/width,numel(msg),numel(unique(users))};
end
function m=average(x), if isempty(x), m=0; else, m=mean(x); end, end
function m=maximum(x), if isempty(x), m=0; else, m=max(x); end, end

function occupancy=missingOccupancy()
occupancy=struct('ulRaOccupancy',NaN,'ulDtOccupancy',NaN, ...
    'dlRaOccupancy',NaN,'dlDtOccupancy',NaN);
end

function action=missingAction()
action=struct('accessProbability',NaN,'raShare',NaN,'effectiveTick',NaN);
end

function validateDerivedInputs(occupancy,action,first)
occupancyNames={'ulRaOccupancy','ulDtOccupancy','dlRaOccupancy','dlDtOccupancy'};
for k=1:numel(occupancyNames)
    name=occupancyNames{k};
    if ~isstruct(occupancy)||~isscalar(occupancy)||~isfield(occupancy,name)
        error('nbiot:dataset:FeatureValues','Resource occupancy is missing %s.',name);
    end
    value=occupancy.(name);
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||isinf(value)|| ...
            (isfinite(value)&&(value<0||value>1))
        error('nbiot:dataset:FeatureValues','Resource occupancy %s must be NaN or a fraction.',name);
    end
end
actionNames={'accessProbability','raShare'};
for k=1:numel(actionNames)
    name=actionNames{k};
    if ~isstruct(action)||~isscalar(action)||~isfield(action,name)
        error('nbiot:dataset:FeatureValues','The previous action is missing %s.',name);
    end
    value=action.(name);
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||isinf(value)|| ...
            (isfinite(value)&&(value<0||value>1))
        error('nbiot:dataset:FeatureValues','Action value %s must be NaN or a fraction.',name);
    end
end
if ~isfield(action,'effectiveTick')||~isnumeric(action.effectiveTick)|| ...
        ~isreal(action.effectiveTick)||~isscalar(action.effectiveTick)||isinf(action.effectiveTick)
    error('nbiot:dataset:FeatureValues','Action effectiveTick must be a finite tick or NaN.');
end
if isfinite(action.effectiveTick)&&(action.effectiveTick<0|| ...
        action.effectiveTick~=fix(action.effectiveTick)||action.effectiveTick>first)
    error('nbiot:dataset:FutureAction','The action was not active during the closed observation window.');
end
end
