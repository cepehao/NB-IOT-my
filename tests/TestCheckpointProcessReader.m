classdef TestCheckpointProcessReader < matlab.unittest.TestCase
    methods (Test)
        function resumesOneUeBoundaryFromDifferentProcess(t)
            % Запускается только из PowerShell-оркестратора, который задаёт папку через переменную
            % окружения NB_IOT_CHECKPOINT_TEST_FOLDER; при обычном прогоне набора — пропуск.
            t.assumeNotEmpty(getenv('NB_IOT_CHECKPOINT_TEST_FOLDER'),'Run by the process orchestrator only.');
            folder=TestSimulationCheckpoint.processFolder();
            inputPath=fullfile(folder,'resume-input.mat');
            t.assertTrue(isfile(inputPath),'Missing writer input must not be regenerated.');
            input=load(inputPath);
            readerProcessId=feature('getpid');
            t.assertNotEqual(readerProcessId,input.writerProcessId);
            t.assertEqual(input.writerCurrentTick,499); t.assertEqual(input.writerNextTick,500);
            t.assertGreaterThan(input.pendingCount,0);
            t.assertGreaterThanOrEqual(input.pendingNextTick,input.writerNextTick);
            t.assertLessThanOrEqual(input.pendingNextTick-input.writerNextTick,25);
            t.assertTrue(input.decodeBefore);
            t.assertEqual(input.cfg.simulation.numUE,1);
            t.assertEqual(input.execution.profile,'local-development');
            freshIdentity=nbiot.experiments.runtimeManifest(input.cfg,struct('scenario',input.scenario));
            t.assertEqual(nbiot.experiments.checkpointIdentityHash(freshIdentity), ...
                nbiot.experiments.checkpointIdentityHash(input.identity));
            [resumed,checkpointInfo]=nbiot.experiments.loadCheckpoint(folder,input.identity,input.execution);
            t.verifyEqual(checkpointInfo.checkpointTick,499);
            t.verifyFalse(checkpointInfo.fallbackUsed);
            t.verifyTrue(checkpointInfo.graphLinksValidated);
            state=resumed.exportCheckpointState();
            t.verifyEqual(state.nextTick,500);
            t.verifyGreaterThan(state.receiveQueue.count(),0);
            t.verifyEqual(state.receiveQueue.nextTick(),input.pendingNextTick);
            t.verifyEqual(rand(state.sources.stream('noise',0,1,500),1,16),input.rngExpected);
            resumed.run(); resumedResult=resumed.result();
            direct=nbiot.NBIoTSimulator(input.cfg,input.scenario,input.execution);
            direct.run(); directResult=direct.result();
            t.verifyEqual(directResult.status,'completed');
            t.verifyTrue(any([directResult.truthLog.tick]<500));
            t.verifyTrue(any([directResult.truthLog.tick]>500));
            t.verifyEqual(sum(directResult.dataset.observations.endTick==500),1);
            t.verifyGreaterThan(directResult.kpiSummary.delivered,0);
            t.verifyEqual(TestSimulationCheckpoint.scientificResult(resumedResult), ...
                TestSimulationCheckpoint.scientificResult(directResult));
            t.verifyTrue(isfile(input.checkpointPath));
            save(fullfile(folder,'resume-output.mat'),'resumedResult','directResult', ...
                'checkpointInfo','readerProcessId','-v7.3');
            fprintf('CHECKPOINT_PROCESS_READER writerPid=%d readerPid=%d scientificEqual=%d\n', ...
                input.writerProcessId,readerProcessId,isequaln( ...
                TestSimulationCheckpoint.scientificResult(resumedResult), ...
                TestSimulationCheckpoint.scientificResult(directResult)));
        end
    end
end
