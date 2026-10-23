classdef TestCheckpointTiming < matlab.unittest.TestCase
    methods (Test)
        function saveAndLoadExposeFiniteTimingsWithoutChangingState(t)
            [cfg,scenario,identity,execution]=TestSimulationCheckpoint.fixture();
            folder=tempname; mkdir(folder);
            t.addTeardown(@()rmdir(folder,'s'));
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            [path,timing]=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            fprintf('CHECKPOINT_TIMING_SAVE %s\n',jsonencode(timing));
            t.verifyTiming(timing,{'existingHashSeconds','exportStateSeconds','saveSeconds', ...
                'readbackSeconds','hashSeconds','publishSeconds','totalSeconds','bytes'},dir(path).bytes);
            [restored,info]=nbiot.experiments.loadCheckpoint(folder,identity,execution);
            fprintf('CHECKPOINT_TIMING_LOAD %s\n',jsonencode(info.timing));
            t.verifyTiming(info.timing,{'hashSeconds','loadSeconds','restoreSeconds','totalSeconds','bytes'},dir(path).bytes);
            t.verifyEqual(restored.currentTick,99);
            data=load(path,'payload');
            t.verifyEqual(data.payload.header.checkpointSchemaVersion,1);
            t.verifyFalse(isfield(data.payload.state,'timing'));
            manifest=jsondecode(fileread(fullfile(folder,'checkpoint-manifest.json')));
            t.verifyEqual(manifest.manifestVersion,1);
            t.verifyFalse(isfield(manifest.identity,'timing'));
            compatiblePath=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            t.verifyTrue(isfile(compatiblePath));
        end

        function rejectedNewestLoadStillContributesToTimings(t)
            [cfg,scenario,identity,execution]=TestSimulationCheckpoint.fixture();
            folder=tempname; mkdir(folder); t.addTeardown(@()rmdir(folder,'s'));
            sim=nbiot.NBIoTSimulator(cfg,scenario,execution); sim.run(99);
            first=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            sim.run(199); newest=nbiot.experiments.saveCheckpoint(sim,folder,identity);
            fid=fopen(newest,'wb'); fwrite(fid,uint8('not-a-mat-file'),'uint8'); fclose(fid);
            manifestPath=fullfile(folder,'checkpoint-manifest.json');
            manifest=jsondecode(fileread(manifestPath));
            % Controlled test corruption with a matching hash exercises load rejection.
            manifest.checkpoints(end).sha256=nbiot.ml.fileSha256(newest);
            fid=fopen(manifestPath,'w'); fprintf(fid,'%s',jsonencode(manifest)); fclose(fid);
            [restored,info]=nbiot.experiments.loadCheckpoint(folder,identity,execution);
            t.verifyEqual(restored.currentTick,99); t.verifyTrue(info.fallbackUsed);
            t.verifyEqual(info.lostTicks,100);
            t.verifyTiming(info.timing,{'hashSeconds','loadSeconds','restoreSeconds','totalSeconds','bytes'},dir(first).bytes);
            t.verifyGreaterThan(info.timing.hashSeconds,0);
            t.verifyGreaterThan(info.timing.loadSeconds,0);
            t.verifyNotEmpty(info.fallbackReason);
            fprintf('CHECKPOINT_TIMING_FALLBACK %s\n',jsonencode(info.timing));
        end
    end
    methods (Access=private)
        function verifyTiming(t,timing,names,bytes)
            t.assertEqual(sort(fieldnames(timing)),sort(names(:)));
            for k=1:numel(names)
                value=timing.(names{k});
                t.verifyClass(value,'double');
                t.verifySize(value,[1 1]);
                t.verifyTrue(isfinite(value)&&value>=0);
                if ~strcmp(names{k},'bytes'), t.verifyGreaterThanOrEqual(timing.totalSeconds,value); end
            end
            t.verifyEqual(timing.bytes,double(bytes));
            t.verifyEqual(timing.bytes,fix(timing.bytes));
        end
    end
end
