function validateComparisonAcceptanceScope(scope,configs)
%VALIDATECOMPARISONACCEPTANCESCOPE Check every Adaptive sweep config up front.
if ~isstruct(scope)||~isscalar(scope)||~iscell(configs)||isempty(configs)
    reject('A model scope and nonempty cell array of configurations are required.');
end
required={'methods','numUE','trafficKinds','windowTicks'};
if ~all(isfield(scope,required))
    reject('Model acceptance scope is incomplete.');
end
for k=1:numel(configs)
    cfg=configs{k};
    if ~isstruct(cfg)||~isscalar(cfg)|| ...
            ~all(isfield(cfg,{'simulation','traffic','policy','dataset'}))|| ...
            ~isfield(cfg.simulation,'numUE')||~isfield(cfg.traffic,'kind')|| ...
            ~isfield(cfg.policy,'name')
        reject('A selected comparison configuration is incomplete.');
    end
    method=char(string(cfg.policy.name));
    traffic=char(string(cfg.traffic.kind));
    if ~ismember(method,cellstr(string(scope.methods(:))))|| ...
            ~ismember(double(cfg.simulation.numUE),double(scope.numUE(:)))|| ...
            ~ismember(traffic,cellstr(string(scope.trafficKinds(:))))
        reject('A selected comparison configuration is outside the accepted model scope.');
    end
    switch traffic
        case 'burst', parameter='burstDurationTicks';
        case 'periodic', parameter='periodTicks';
        case 'poisson', parameter='poissonRatePerSecond';
        otherwise, reject('Selected traffic type is outside the accepted model scope.');
    end
    if ~isfield(cfg.traffic,parameter)||~isfield(scope,parameter)|| ...
            ~containsValue(scope.(parameter),cfg.traffic.(parameter))|| ...
            ~isfield(cfg.dataset,'windowTicks')|| ...
            double(cfg.dataset.windowTicks)~=double(scope.windowTicks)
        reject('A selected traffic or feature-window configuration is outside the accepted model scope.');
    end
end
end

function yes=containsValue(values,value)
yes=ismember(double(value),double(values(:)));
end

function reject(message)
error('nbiot:ml:ModelAcceptance','%s',message);
end
