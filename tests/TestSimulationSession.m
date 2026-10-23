classdef TestSimulationSession < matlab.unittest.TestCase
    methods (Test)
        function idleSnapshotShowsTheStaticBaselineAction(t)
            session=nbiot.ui.SimulationSession(localDevelopment());
            t.addTeardown(@() session.close());

            state=session.snapshot();

            t.verifyEqual(state.transmittedPacketCount,0);
            t.verifyEqual(state.controllerMethod,'Static');
            t.verifyEqual(state.runtimeAction.accessProbability,1);
            t.verifyEqual(state.runtimeAction.raShare,0.1);
            t.verifyEqual(state.runtimeAction.effectiveTick,0);
        end

        function pauseStopPartialSaveAndResetKeepSessionStateConsistent(t)
            [cfg,session,folder]=fixture();
            t.addTeardown(@() session.close());
            t.addTeardown(@() removeFolder(folder));

            session.start(cfg);
            t.verifyEqual(session.Status,'running');
            t.verifyError(@() session.start(cfg),'nbiot:ui:SessionState');

            beforePause=session.snapshot();
            session.pause();
            session.advance(2);
            afterPausedAdvance=session.snapshot();
            t.verifyEqual(session.Status,'paused');
            t.verifyEqual(afterPausedAdvance.tick,beforePause.tick);

            session.resume();
            session.advance(2);
            t.verifyEqual(session.Status,'running');
            session.stop();
            t.verifyEqual(session.Status,'stopped');
            stoppedState=session.snapshot();
            t.verifyEqual(stoppedState.ueDetails(1).radioSummary.status,'available');
            result=session.getResult();
            t.verifyEqual(result.status,'stopped');
            t.verifyEqual(result.stopReason,'user-stop');
            t.verifyEqual(result.harqLogSchemaVersion,2);

            resultPath=session.save(folder);
            [resultFolder,stem]=fileparts(resultPath);
            t.verifyTrue(isfile(resultPath));
            t.verifyTrue(isfile(fullfile(resultFolder,[stem '_kpi.csv'])));
            report=nbiot.results.verifyCase(resultFolder);
            t.verifyTrue(report.passed,strjoin(report.errors,'; '));
            t.verifyEqual(report.status,'stopped');
            t.verifyError(@() session.save(resultFolder),'nbiot:ui:OutputExists');

            session.reset();
            t.verifyEqual(session.Status,'idle');
            t.verifyFalse(session.hasResult());
        end

        function closingPausedSessionStopsIt(t)
            [cfg,session,folder]=fixture();
            t.addTeardown(@() session.close());
            t.addTeardown(@() removeFolder(folder));

            session.start(cfg);
            session.pause();
            session.close();

            t.verifyEqual(session.Status,'stopped');
            result=session.getResult();
            t.verifyEqual(result.status,'stopped');
            t.verifyEqual(result.stopReason,'user-stop');
        end

        function invalidStartInputsAreRejectedBeforeSimulation(t)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=10;
            cfg.traffic.kind='none';
            session=nbiot.ui.SimulationSession(localDevelopment());
            t.addTeardown(@() session.close());
            t.verifyError(@() session.start(cfg),'nbiot:phy:Calibration');
            t.verifyEqual(session.Status,'idle');

            cfg.simulation.numUE=11;
            t.verifyError(@() session.start(cfg),'nbiot:experiments:ExecutionBudget');
            t.verifyEqual(session.Status,'idle');
            t.verifyFalse(session.hasResult());
        end

        function simulatorConstructionFailureIsRecorded(t)
            cfg=calibratedFixtureConfig();
            session=nbiot.ui.SimulationSession(localDevelopment(),@throwSimulatorConstruction);
            t.addTeardown(@() session.close());
            t.verifyError(@() session.start(cfg),'test:ui:SimulatorConstruction');
            t.verifyEqual(session.Status,'failed');
            t.verifyEqual(session.LastError,'fixture construction failed');
        end

        function simulatorRuntimeFailureBecomesFailedSession(t)
            cfg=calibratedFixtureConfig();
            session=nbiot.ui.SimulationSession(localDevelopment(),@makeFailingSimulator);
            t.addTeardown(@() session.close());
            session.start(cfg);
            session.advance(2);
            t.verifyEqual(session.Status,'failed');
            t.verifyEqual(session.LastError,'fixture simulation failure');
            state=session.snapshot();
            t.verifyEqual(state.error,'fixture simulation failure');
        end

        function liveSnapshotIncludesMsg3AndDataCrcCounts(t)
            [cfg,session,folder]=fixture();
            t.addTeardown(@() session.close());
            t.addTeardown(@() removeFolder(folder));
            session.start(cfg);
            state=session.snapshot();
            t.verifyEqual(state.transmittedPacketCount,0);
            t.verifyEqual(state.crcCounters,struct('msg3Errors',0,'dataErrors',0));
            t.verifyEqual(state.controllerMethod,'Static');
            t.verifyEqual(state.controllerDiagnosticTargets, ...
                table(zeros(0,1),zeros(0,1),'VariableNames',{'endTick','meanRaUe'}));
            t.verifyEqual(numel(state.ueDetails),1);
            t.verifyEqual(state.ueDetails(1).ueId,1);
            t.verifyEqual(state.ueDetails(1).state,'IDLE');
            t.verifyEqual(state.ueDetails(1).queueLength,0);
            t.verifyEqual(state.ueDetails(1).raAttempts,0);
            t.verifyTrue(isfinite(state.ueDetails(1).distanceM));
            t.verifyTrue(isfinite(state.ueDetails(1).receivedPowerUlDbm));
            t.verifyEqual(state.ueDetails(1).radioSummary.status,'pending');
            t.verifyTrue(isfinite(state.ueDetails(1).radioSummary.referenceSnrUlDb));
        end

        function observedRadioEventsAreReadIncrementally(t)
            cfg=calibratedFixtureConfig();
            events=struct('tick',{8,24},'kind',{'nprach_detection','grant'}, ...
                'fields',{struct('count',1),struct('phase','Msg3')});
            session=nbiot.ui.SimulationSession(localDevelopment(),@makeRadioEventSimulator);
            t.addTeardown(@() session.close());
            session.start(cfg);

            [first,cursor]=session.observedEventsSince(0);
            [next,sameCursor]=session.observedEventsSince(cursor);

            t.verifyEqual(first,events);
            t.verifyEqual(cursor,2);
            t.verifyEmpty(next);
            t.verifyEqual(sameCursor,cursor);
        end
    end
end

function [cfg,session,folder]=fixture()
projectRoot=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=10;
cfg.traffic.kind='none';
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(projectRoot,'results','nprach-calibration.mat'));
session=nbiot.ui.SimulationSession(localDevelopment());
folder=tempname;
end

function cfg=calibratedFixtureConfig()
projectRoot=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1;
cfg.simulation.durationTicks=10;
cfg.traffic.kind='none';
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(projectRoot,'results','nprach-calibration.mat'));
end

function simulator=throwSimulatorConstruction(~,~,~)
simulator=[]; %#ok<NASGU>
error('test:ui:SimulatorConstruction','fixture construction failed');
end

function simulator=makeFailingSimulator(~,~,~)
simulator=FailingSimulatorStub();
end

function simulator=makeRadioEventSimulator(~,~,~)
events=struct('tick',{8,24},'kind',{'nprach_detection','grant'}, ...
    'fields',{struct('count',1),struct('phase','Msg3')});
simulator=RadioEventSimulatorStub(events);
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
