classdef TestCheckpointProcessWriter < matlab.unittest.TestCase
    methods (Test)
        function writesOneUeBoundaryForSeparateReader(t)
            % Запускается только из PowerShell-оркестратора, который задаёт папку через переменную
            % окружения NB_IOT_CHECKPOINT_TEST_FOLDER; при обычном прогоне набора — пропуск.
            t.assumeNotEmpty(getenv('NB_IOT_CHECKPOINT_TEST_FOLDER'),'Run by the process orchestrator only.');
            folder=TestSimulationCheckpoint.processFolder();
            t.assertFalse(isfolder(folder),'Writer requires a fresh coordinator-selected folder.');
            mkdir(folder);
            [cfg,scenario,identity,execution]=TestSimulationCheckpoint.fixture();
            t.assertEqual(cfg.simulation.numUE,1);
            t.assertEqual(execution.profile,'local-development');
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution);
            sim.run(499);
            state=sim.exportCheckpointState(); partial=sim.result();
            writerCurrentTick=state.currentTick; writerNextTick=state.nextTick;
            pendingCount=state.receiveQueue.count(); pendingNextTick=state.receiveQueue.nextTick();
            decodeBefore=any(strcmp({partial.observedLog.kind},'phy_decode'));
            t.assertEqual(writerCurrentTick,499); t.assertEqual(writerNextTick,500);
            t.assertGreaterThan(pendingCount,0);
            t.assertGreaterThanOrEqual(pendingNextTick,writerNextTick);
            t.assertLessThanOrEqual(pendingNextTick-writerNextTick,25);
            t.assertTrue(decodeBefore);
            rngExpected=rand(state.sources.stream('noise',0,1,500),1,16);
            [checkpointPath,timing]=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            writerProcessId=feature('getpid');
            save(fullfile(folder,'resume-input.mat'),'cfg','scenario','identity','execution', ...
                'checkpointPath','writerProcessId','writerCurrentTick','writerNextTick', ...
                'pendingCount','pendingNextTick','decodeBefore','rngExpected','timing','-v7.3');
            fprintf('CHECKPOINT_PROCESS_WRITER pid=%d tick=%d nextTick=%d\n',writerProcessId,writerCurrentTick,writerNextTick);
        end
    end
end
