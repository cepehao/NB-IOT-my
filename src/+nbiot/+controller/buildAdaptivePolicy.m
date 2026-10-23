function policy=buildAdaptivePolicy(method,accessProbabilityRange,allowedRaShares)
%BUILDADAPTIVEPOLICY Политика пороговых решений по выбору пользователя в GUI (ТЗ §46.3).
%   Adaptive-P: ACCESSPROBABILITYRANGE = [pMin pMax] из поддерживаемых уровней P;
%   Adaptive-RA/DT: ALLOWEDRASHARES — подмножество {0.1, 0.2, 0.3} (RA/DT 10/90, 20/80, 30/70, ТЗ §25).
%   Пороги нагрузки берутся из configs/adaptiveDefaults для выбранных уровней.
policy=adaptiveDefaults();
method=char(string(method));
if strcmp(method,'Adaptive-P')
    if ~isnumeric(accessProbabilityRange)||~isreal(accessProbabilityRange)|| ...
            numel(accessProbabilityRange)~=2||any(~isfinite(accessProbabilityRange))|| ...
            ~isempty(allowedRaShares)
        invalidSelection();
    end
    accessProbabilityRange=double(accessProbabilityRange(:).');
    supported=policy.accessProbabilityLevels;
    if accessProbabilityRange(1)>accessProbabilityRange(2)|| ...
            any(~ismember(accessProbabilityRange,supported))
        invalidSelection();
    end
    selected=find(supported>=accessProbabilityRange(1)& ...
        supported<=accessProbabilityRange(2));
    if isempty(selected), invalidSelection(); end
    policy.accessProbabilityLevels=supported(selected);
    policy.accessLoadThresholds=thresholdsForSelection( ...
        policy.accessLoadThresholds,selected);
elseif strcmp(method,'Adaptive-RA/DT')
    if ~isempty(accessProbabilityRange)||~isnumeric(allowedRaShares)|| ...
            ~isreal(allowedRaShares)||isempty(allowedRaShares)|| ...
            any(~isfinite(allowedRaShares))
        invalidSelection();
    end
    allowedRaShares=double(allowedRaShares(:).');
    supported=policy.raShareLevels;
    if any(~ismember(allowedRaShares,supported))|| ...
            numel(unique(allowedRaShares))~=numel(allowedRaShares)
        invalidSelection();
    end
    selected=find(ismember(supported,allowedRaShares));
    policy.raShareLevels=supported(selected);
    policy.raLoadThresholds=thresholdsForSelection( ...
        policy.raLoadThresholds,selected);
else
    invalidSelection();
end
end

%THRESHOLDSFORSELECTION Пороги между выбранными уровнями (на один меньше числа уровней).
function thresholds=thresholdsForSelection(defaultThresholds,selected)
if numel(selected)<=1
    thresholds=[];
else
    thresholds=defaultThresholds(selected(2:end)-1);
end
end

function invalidSelection()
error('nbiot:controller:PolicySelection', ...
    'Choose a supported P range or one or more supported RA/DT shares.');
end
