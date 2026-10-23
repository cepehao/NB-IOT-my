classdef TestScheduledStage2Budget < matlab.unittest.TestCase
    methods (Test)
        function exhaustedSuitePausesBeforeStartingNextCollisionCase(t)
            testRoot=tempname; mkdir(testRoot);
            cleanup=onCleanup(@() cleanupFolder(testRoot)); %#ok<NASGU>
            outputFolder=fullfile(testRoot,'physical');
            execution=struct('profile','scheduled-local', ...
                'role','stage-2-collision-diagnostics','maxUE',10, ...
                'maxCaseSeconds',120,'maxSuiteSeconds',eps, ...
                'timePolicy','finish-current');

            report=validateCollisionCapture(struct('repeats',1, ...
                'conditionIds',7,'outputFolder',outputFolder, ...
                'runReceiverChecks',false,'runInterferenceReplay',false, ...
                'manageRegistry',false,'execution',execution));

            t.verifyEqual(report.status,'budget-paused');
            t.verifyEmpty(report.trials);
            t.verifyNotEmpty(report.pendingCases);
            t.verifyTrue(isfile(fullfile(outputFolder,'report.mat')));
            t.verifyTrue(isfile(fullfile(outputFolder,'trials.csv')));
            t.verifyNotEmpty(report.registrySha256);
            progress=stage2PhysicalProgress('read',fullfile(outputFolder,'progress.json'));
            assigned=progress.assignedIds;
            t.verifyEqual(progress.status,'budget-paused');
            t.verifyEqual(numel(progress.pendingCaseKeys),1);
            t.verifyEqual(progress.caseRecords(1).status,'planned');

            execution.maxSuiteSeconds=300;
            resumed=validateCollisionCapture(struct('repeats',1, ...
                'conditionIds',7,'outputFolder',outputFolder, ...
                'runReceiverChecks',false,'runInterferenceReplay',false, ...
                'manageRegistry',false,'execution',execution,'resume',true));

            t.verifyEqual(resumed.status,'completed');
            t.verifyEqual(height(resumed.trials),1);
            t.verifyEqual(resumed.trials.realizationId,assigned(1));
            progress=stage2PhysicalProgress('verify',fullfile(outputFolder,'progress.json'));
            t.verifyEqual(progress.status,'completed');
        end

        function sharedBudgetCrossingFinishesCurrentAndDoesNotStartNext(t)
            testRoot=tempname; mkdir(testRoot);
            cleanup=onCleanup(@() cleanupFolder(testRoot)); %#ok<NASGU>
            outputFolder=fullfile(testRoot,'physical');
            ledgerPath=fullfile(testRoot,'budget-ledger.json');
            ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,true);
            ledger.elapsedSeconds=ledger.budgetSeconds-0.001;
            nbiot.experiments.saveVariant2BudgetLedger(ledgerPath,ledger);
            execution=struct('profile','scheduled-local', ...
                'role','stage-2-collision-diagnostics','maxUE',10, ...
                'maxCaseSeconds',300,'maxSuiteSeconds',300, ...
                'timePolicy','finish-current');

            report=validateCollisionCapture(struct('repeats',2, ...
                'conditionIds',7,'outputFolder',outputFolder, ...
                'runReceiverChecks',false,'runInterferenceReplay',false, ...
                'manageRegistry',false,'execution',execution, ...
                'budgetLedgerFile',ledgerPath));

            progress=stage2PhysicalProgress('read',fullfile(outputFolder,'progress.json'));
            ledger=nbiot.experiments.loadVariant2BudgetLedger(ledgerPath,false);
            t.verifyEqual(report.status,'budget-paused');
            t.verifyEqual(height(report.trials),1);
            t.verifyEqual(progress.caseRecords(1).status,'completed');
            t.verifyEqual(progress.caseRecords(2).status,'planned');
            t.verifyEqual(numel(progress.pendingCaseKeys),1);
            t.verifyGreaterThan(ledger.elapsedSeconds,ledger.budgetSeconds);
            t.verifyFalse(isfield(ledger.activeCase,'caseKey')&&~isempty(ledger.activeCase.caseKey));
            t.verifyNotEmpty(ledger.warnings);
        end
    end
end

function cleanupFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
