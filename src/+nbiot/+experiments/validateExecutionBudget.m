function budget=validateExecutionBudget(cfg,execution,numCases)
%VALIDATEEXECUTIONBUDGET Reject unsafe launches before any output/RNG work.
if nargin<2 || isempty(execution), execution=struct(); end
if nargin<3, numCases=1; end
base=struct('profile','local-development','role','development', ...
    'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900, ...
    'timePolicy','hard-stop');
if ~isstruct(execution)||~isscalar(execution)||~all(ismember(fieldnames(execution),fieldnames(base)))
    reject('Expected a scalar execution budget with supported fields.');
end
names=fieldnames(execution); budget=base;
for k=1:numel(names), budget.(names{k})=execution.(names{k}); end
if ~(ischar(budget.profile)||(isstring(budget.profile)&&isscalar(budget.profile))) || ...
        ~ismember(string(budget.profile), ...
            ["local-development","external-machine","scheduled-local"])
    reject('Unknown execution profile.');
end
if ~(ischar(budget.timePolicy)||(isstring(budget.timePolicy)&&isscalar(budget.timePolicy))) || ...
        ~ismember(string(budget.timePolicy),["hard-stop","finish-current"])
    reject('Unknown execution time policy.');
end
if ~(ischar(budget.role)||(isstring(budget.role)&&isscalar(budget.role))) || isempty(strtrim(char(budget.role)))
    reject('An experiment role is required.');
end
budget.profile=char(budget.profile); budget.role=char(budget.role);
budget.timePolicy=char(budget.timePolicy);
limits={'maxUE','maxCaseSeconds','maxSuiteSeconds'};
for k=1:numel(limits)
    value=budget.(limits{k});
    if ~isnumeric(value)||~isscalar(value)||~isreal(value)||~isfinite(value)||value<=0
        reject('Execution limits must be finite positive scalars.');
    end
end
if budget.maxUE~=fix(budget.maxUE)||budget.maxUE>65535 || ...
        ~isnumeric(numCases)||~isscalar(numCases)||~isreal(numCases)||~isfinite(numCases)||numCases<1||numCases~=fix(numCases)
    reject('Device and case limits must be valid integers.');
end
if strcmp(budget.profile,'external-machine')
    if ~all(isfield(execution,[{'role'},limits]))
        reject('External runs require explicit role, maxUE, maxCaseSeconds and maxSuiteSeconds.');
    end
    if ~strcmp(budget.timePolicy,'hard-stop')
        reject('External-machine runs retain the declared hard-stop time policy.');
    end
elseif strcmp(budget.profile,'scheduled-local')
    if ~all(isfield(execution,[{'role'},limits]))
        reject('Scheduled local runs require explicit role, maxUE, maxCaseSeconds and maxSuiteSeconds.');
    end
    if ~ismember(budget.role,{'stage-2-collision-diagnostics','stage-3-load-pilot'})
        reject('Scheduled local runs are restricted to Stage 2 diagnostics and the four-load probe.');
    end
    roleMaxUE=2500;
    if strcmp(budget.role,'stage-2-collision-diagnostics'), roleMaxUE=10; end
    if budget.maxUE>roleMaxUE||budget.maxCaseSeconds>57600||budget.maxSuiteSeconds>57600
        reject('Scheduled local runs exceed the role-specific UE or 57600-second budget limit.');
    end
    if strcmp(budget.timePolicy,'finish-current')&& ...
            ~ismember(budget.role,{'stage-2-collision-diagnostics','stage-3-load-pilot'})
        reject('finish-current is reserved for the two authorized local experiment roles.');
    end
    if isfield(cfg,'simulation')&&isfield(cfg.simulation,'durationTicks')&&cfg.simulation.durationTicks>5000
        reject('Scheduled local physical horizons are limited to 5000 ticks.');
    end
else
    if budget.maxUE>10||budget.maxCaseSeconds>300||budget.maxSuiteSeconds>900 || ~strcmp(budget.role,'development')
        reject('Local runs are development only: at most 10 UE, 300 seconds/case and 900 seconds/suite.');
    end
    if ~strcmp(budget.timePolicy,'hard-stop')
        reject('Local development runs retain the hard-stop time policy.');
    end
    if isfield(cfg,'simulation')&&isfield(cfg.simulation,'durationTicks')&&cfg.simulation.durationTicks>5000
        reject('Local physical horizons are limited to 5000 ticks before resource allocation.');
    end
end
if ~isstruct(cfg)||~isfield(cfg,'simulation')||~isfield(cfg.simulation,'numUE')
    reject('A configuration with simulation.numUE is required.');
end
count=cfg.simulation.numUE;
if ~isnumeric(count)||~isscalar(count)||~isreal(count)||~isfinite(count)||count<1||count~=fix(count)||count>budget.maxUE
    reject('Device count exceeds the declared execution budget.');
end
if strcmp(budget.timePolicy,'hard-stop')&&numCases*budget.maxCaseSeconds>budget.maxSuiteSeconds
    reject('The case count exceeds the declared suite time budget.');
end
budget.numCases=double(numCases);
end
function reject(message)
error('nbiot:experiments:ExecutionBudget','%s',message);
end
