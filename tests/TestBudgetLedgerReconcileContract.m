classdef TestBudgetLedgerReconcileContract < matlab.unittest.TestCase
    % Contracts for the persisted Variant 2/Stage 3 budget-ledger schema.
    methods(Test)
        function initializesAndRoundTripsAttemptAccounting(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'budget-ledger.json');

            ledger=nbiot.experiments.loadVariant2BudgetLedger(path,true);
            t.verifyEqual(ledger.schemaVersion,1);
            t.verifyEqual(ledger.budgetSeconds,57600);
            t.verifyEqual(ledger.elapsedSeconds,0);
            t.verifyEqual(ledger.accountingVersion,2);
            t.verifyEmpty(ledger.attempts);
            t.verifyEqual(fieldnames(ledger.attempts), ...
                {'attemptId';'runId';'caseKey';'startedAtUtc';'finishedAtUtc'; ...
                'status';'observedSeconds';'chargedSeconds';'processReportSha256'});

            attempt=validAttempt();
            ledger.elapsedSeconds=12.5;
            ledger.attempts=attempt;
            ledger.updatedAtUtc='2000-01-01 00:00:00.000';
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);

            restored=nbiot.experiments.loadVariant2BudgetLedger(path,false);
            t.verifyEqual(restored.elapsedSeconds,12.5);
            t.verifyEqual(restored.accountingVersion,2);
            t.verifyEqual(restored.attempts,attempt);
            t.verifyNotEqual(restored.updatedAtUtc,'2000-01-01 00:00:00.000');
            files=dir(folder); files=files(~[files.isdir]);
            t.verifyEqual({files.name},{'budget-ledger.json'}, ...
                'Atomic save must not leave temporary files behind.');
        end

        function roundTripsOptionalReconciliationAndActiveAttemptLinkage(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'linked-ledger.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(path,true);

            attempt=validAttempt();
            active=struct('runId',attempt.runId,'attemptId',attempt.attemptId, ...
                'caseKey',attempt.caseKey,'numUE',100, ...
                'startedAtUtc',attempt.startedAtUtc, ...
                'lastProgressAtUtc','2026-10-17 10:00:03.750', ...
                'runFolder',fullfile(folder,'run control'));
            reconciliation=struct('phase','accounting-reconciled', ...
                'attemptId',attempt.attemptId, ...
                'report',struct('sha256',repmat('a',1,64),'elapsedSeconds',3.75));
            ledger.activeCase=active;
            ledger.attempts=attempt;
            ledger.reconciliation=reconciliation;
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);

            restored=nbiot.experiments.loadVariant2BudgetLedger(path,false);

            t.verifyEqual(restored.activeCase,active, ...
                'Persisted activeCase must retain its run, attempt, case, progress time, and run-folder linkage.');
            t.verifyEqual(restored.attempts,attempt);
            t.verifyEqual(restored.reconciliation,reconciliation, ...
                'Optional reconciliation metadata must survive ledger round-trip.');
        end

        function legacyLedgerLoadsWithDefaultAttemptHistory(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'legacy-ledger.json');
            legacy=struct('schemaVersion',1,'budgetSeconds',57600, ...
                'elapsedSeconds',101.25,'startedAtUtc','2026-10-14 10:00:00.000', ...
                'updatedAtUtc','2026-10-14 10:01:41.250','phaseTimes',[], ...
                'warnings',[],'pendingCases',[],'activeCase',[]);
            writeJson(path,legacy);
            before=fileread(path);

            loaded=nbiot.experiments.loadVariant2BudgetLedger(path,false);

            t.verifyEqual(loaded.elapsedSeconds,101.25);
            t.verifyEqual(loaded.accountingVersion,2);
            t.verifyEmpty(loaded.attempts);
            t.verifyEqual(loaded.activeCase.runId,'');
            t.verifyEqual(fileread(path),before, ...
                'Loading a legacy ledger must not rewrite it.');
        end

        function missingLedgerIsNotCreatedWithoutExplicitFlag(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'missing-ledger.json');

            t.verifyError(@() nbiot.experiments.loadVariant2BudgetLedger(path,false), ...
                'nbiot:experiments:Variant2BudgetLedger');
            t.verifyFalse(isfile(path));
        end

        function duplicateAttemptIdsAreRejected(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'duplicate-attempts.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(path,true);
            attempt=validAttempt();
            duplicate=attempt;
            duplicate.caseKey='n00500-id0042';
            ledger.attempts=[attempt duplicate];
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);

            t.verifyError(@() nbiot.experiments.loadVariant2BudgetLedger(path,false), ...
                'nbiot:experiments:Variant2BudgetLedger');
        end

        function invalidAttemptAccountingAndReportHashAreRejected(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'invalid-attempt.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(path,true);

            attempt=validAttempt();
            attempt.observedSeconds=-0.25;
            ledger.attempts=attempt;
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
            t.verifyError(@() nbiot.experiments.loadVariant2BudgetLedger(path,false), ...
                'nbiot:experiments:Variant2BudgetLedger');

            attempt=validAttempt();
            attempt.processReportSha256='not-a-sha256';
            ledger.attempts=attempt;
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);
            t.verifyError(@() nbiot.experiments.loadVariant2BudgetLedger(path,false), ...
                'nbiot:experiments:Variant2BudgetLedger');
        end

        function unsupportedAccountingVersionIsRejected(t)
            folder=makeTemporaryFolder(t);
            path=fullfile(folder,'unsupported-accounting.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(path,true);
            ledger.accountingVersion=3;
            nbiot.experiments.saveVariant2BudgetLedger(path,ledger);

            t.verifyError(@() nbiot.experiments.loadVariant2BudgetLedger(path,false), ...
                'nbiot:experiments:Variant2BudgetLedger');
        end
    end
end

function attempt=validAttempt()
attempt=struct('attemptId','attempt-a1','runId','run-contract', ...
    'caseKey','n00100-id0042','startedAtUtc','2026-10-17 10:00:00.000', ...
    'finishedAtUtc','','status','active','observedSeconds',3.75, ...
    'chargedSeconds',1.25,'processReportSha256','');
end

function folder=makeTemporaryFolder(t)
folder=[tempname(tempdir) '_budget_ledger_contract'];
mkdir(folder);
t.addTeardown(@() removeTemporaryFolder(folder));
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root);
setupProject();
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
if fid<0
    error('TestBudgetLedgerReconcileContract:FixtureWrite','Cannot create ledger fixture.');
end
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(value,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('TestBudgetLedgerReconcileContract:FixtureWrite','Cannot write ledger fixture.');
end
end

function removeTemporaryFolder(folder)
if isfolder(folder)
    rmdir(folder,'s');
end
end
