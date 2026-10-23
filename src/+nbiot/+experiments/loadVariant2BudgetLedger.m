function ledger=loadVariant2BudgetLedger(path,createIfMissing)
%LOADVARIANT2BUDGETLEDGER Read or initialize the shared Stage 2/Stage 3 budget.
%   Учёт вычислительного бюджета серий. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
if nargin<2, createIfMissing=false; end
if ~(ischar(path)||(isstring(path)&&isscalar(path)))|| ...
        isempty(char(path))||~(islogical(createIfMissing)&&isscalar(createIfMissing))
    error('nbiot:experiments:Variant2BudgetLedger','Invalid budget-ledger path or create flag.');
end
path=char(path);
if ~isfile(path)
    if ~createIfMissing
        error('nbiot:experiments:Variant2BudgetLedger', ...
            'The shared 57600-second compute ledger is missing: %s',path);
    end
    ledger=struct('schemaVersion',1,'budgetSeconds',57600,'elapsedSeconds',0, ...
        'startedAtUtc',utcNow(),'updatedAtUtc',utcNow(), ...
        'phaseTimes',struct('phase',{},'startedAtUtc',{},'finishedAtUtc',{}, ...
            'elapsedSeconds',{},'caseKey',{}), ...
        'warnings',struct('timestampUtc',{},'phase',{},'elapsedSeconds',{},'message',{}), ...
        'pendingCases',[],'activeCase',emptyActiveCase(), ...
        'accountingVersion',2,'attempts',emptyAttempts());
    nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
    return
end
try
    ledger=jsondecode(fileread(path));
catch exception
    error('nbiot:experiments:Variant2BudgetLedger', ...
        'Cannot read the shared compute ledger: %s',exception.message);
end
required={'schemaVersion','budgetSeconds','elapsedSeconds','startedAtUtc', ...
    'updatedAtUtc','phaseTimes','warnings','pendingCases','activeCase'};
if ~isstruct(ledger)||~isscalar(ledger)||~all(isfield(ledger,required))|| ...
        ledger.schemaVersion~=1||ledger.budgetSeconds~=57600|| ...
        ~isnumeric(ledger.elapsedSeconds)||~isscalar(ledger.elapsedSeconds)|| ...
        ~isfinite(ledger.elapsedSeconds)||ledger.elapsedSeconds<0
    error('nbiot:experiments:Variant2BudgetLedger', ...
        'Shared compute ledger schema or elapsed budget is invalid.');
end
if isempty(ledger.phaseTimes)
    ledger.phaseTimes=struct('phase',{},'startedAtUtc',{},'finishedAtUtc',{}, ...
        'elapsedSeconds',{},'caseKey',{});
end
if isempty(ledger.warnings)
    ledger.warnings=struct('timestampUtc',{},'phase',{},'elapsedSeconds',{},'message',{});
end
if isempty(ledger.activeCase)
    ledger.activeCase=emptyActiveCase();
end
if ~isfield(ledger,'accountingVersion')
    ledger.accountingVersion=2;
elseif ~isnumeric(ledger.accountingVersion)||~isscalar(ledger.accountingVersion)|| ...
        ledger.accountingVersion~=2
    error('nbiot:experiments:Variant2BudgetLedger', ...
        'Shared compute ledger accounting version is unsupported.');
end
if ~isfield(ledger,'attempts')||isempty(ledger.attempts)
    ledger.attempts=emptyAttempts();
elseif ~isstruct(ledger.attempts)
    error('nbiot:experiments:Variant2BudgetLedger','Budget ledger attempts must be a structure array.');
end
attemptFields={'attemptId','runId','caseKey','startedAtUtc','finishedAtUtc','status', ...
    'observedSeconds','chargedSeconds','processReportSha256'};
if ~all(isfield(ledger.attempts,attemptFields))
    error('nbiot:experiments:Variant2BudgetLedger','Budget ledger attempt schema is invalid.');
end
if ~isempty(ledger.attempts)
    ids={ledger.attempts.attemptId};
    if any(cellfun(@isempty,ids))||numel(unique(ids))~=numel(ids)
        error('nbiot:experiments:Variant2BudgetLedger','Budget ledger attempt IDs must be nonempty and unique.');
    end
    for k=1:numel(ledger.attempts)
        attempt=ledger.attempts(k);
        if isempty(char(string(attempt.runId)))||isempty(char(string(attempt.caseKey)))|| ...
                ~ismember(char(string(attempt.status)), ...
                {'active','completed','paused','needs-attention','interrupted'})|| ...
                ~isnumeric(attempt.observedSeconds)||~isscalar(attempt.observedSeconds)|| ...
                ~isfinite(attempt.observedSeconds)||attempt.observedSeconds<0|| ...
                ~isnumeric(attempt.chargedSeconds)||~isscalar(attempt.chargedSeconds)|| ...
                ~isfinite(attempt.chargedSeconds)||attempt.chargedSeconds<0
            error('nbiot:experiments:Variant2BudgetLedger','Budget ledger attempt values are invalid.');
        end
        reportHash=char(string(attempt.processReportSha256));
        if ~isempty(reportHash)&&isempty(regexp(reportHash,'^[0-9a-fA-F]{64}$','once'))
            error('nbiot:experiments:Variant2BudgetLedger','Attempt process-report SHA-256 is invalid.');
        end
    end
end
end

function active=emptyActiveCase()
active=struct('runId','','attemptId','','caseKey','','numUE',0,'startedAtUtc','', ...
    'lastProgressAtUtc','','runFolder','');
end

function attempts=emptyAttempts()
attempts=struct('attemptId',{},'runId',{},'caseKey',{},'startedAtUtc',{}, ...
    'finishedAtUtc',{},'status',{},'observedSeconds',{},'chargedSeconds',{}, ...
    'processReportSha256',{});
end

function value=utcNow()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS'));
end
