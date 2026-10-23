classdef TestController < matlab.unittest.TestCase
    methods (Test)
        function startupDoesNotInventLoadWithoutPriorWindow(t)
            [policy,current,estimate,state]=fixture();
            action=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(action.accessProbability,current.accessProbability);
            t.verifyEqual(action.raShare,current.raShare);
            t.verifyEqual(action.effectiveTick,0);
            t.verifyEqual(action.reason,'no-prior-window');
        end

        function adaptivePChangesOnlyProbabilityAndUsesConfiguredLevels(t)
            [policy,current,estimate,state]=fixture();
            estimate.valid=true; estimate.value=4; estimate.featureWindowEndTick=500;
            state.tick=500;
            action=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(action.accessProbability,0.5);
            t.verifyEqual(action.raShare,current.raShare);
            t.verifyEqual(action.effectiveTick,500);
            t.verifyEqual(action.reason,'load-threshold');
        end

        function adaptiveResourceModeChangesOnlyShareAndKeepsPAtOne(t)
            [policy,current,estimate,state]=fixture();
            estimate.valid=true; estimate.value=8; estimate.featureWindowEndTick=500;
            state.tick=500;
            action=nbiot.controller.chooseAction('Adaptive-RA/DT',estimate,state,current,policy);
            t.verifyEqual(action.accessProbability,1);
            t.verifyEqual(action.raShare,0.3);
            t.verifyEqual(action.effectiveTick,500);
        end

        function policyCanContainOneSelectableLevel(t)
            policy=adaptiveDefaults();
            policy.accessProbabilityLevels=0.5;
            policy.accessLoadThresholds=[];
            current=struct('accessProbability',0.5,'raShare',0.1);
            estimate=struct('valid',true,'value',100,'featureWindowEndTick',500);
            state=struct('tick',500,'durationTicks',1000);

            action=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);

            t.verifyEqual(action.accessProbability,0.5);
        end

        function staleOrPostHorizonEstimateDoesNotChangeAction(t)
            [policy,current,estimate,state]=fixture();
            estimate.valid=true; estimate.value=8; estimate.featureWindowEndTick=500;
            state.tick=1000;
            stale=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(stale.accessProbability,current.accessProbability);
            t.verifyEqual(stale.reason,'stale-window');
            estimate.valid=false; state.tick=500;
            invalid=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(invalid.accessProbability,current.accessProbability);
            t.verifyEqual(invalid.reason,'invalid-estimate');
            estimate.valid=true; estimate.value=4; estimate.featureWindowEndTick=4500;
            state.tick=4500;
            finalDecision=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(finalDecision.effectiveTick,4500);
            state.tick=state.durationTicks;
            estimate.featureWindowEndTick=state.tick;
            finished=nbiot.controller.chooseAction('Adaptive-P',estimate,state,current,policy);
            t.verifyEqual(finished.accessProbability,current.accessProbability);
            t.verifyEqual(finished.reason,'after-horizon');
        end

        function applyAtBoundaryChangesRuntimeButKeepsStaticConfig(t)
            simulator=smallSimulator();
            simulator.run(500);
            action=struct('accessProbability',0.5,'raShare',0.1,'effectiveTick',500);
            [applied,reason]=nbiot.controller.applyAction(simulator,action);
            t.verifyTrue(applied,reason);
            t.verifyEqual(simulator.runtimeAction.accessProbability,0.5);
            t.verifyEqual(simulator.runtimeAction.raShare,0.1);
            t.verifyEqual(simulator.cfg.policy.accessProbability,1);
            t.verifyEqual(simulator.cfg.policy.raShare,0.1);
        end

        function adaptiveResourceShareChangesOnlyFutureCalendarWindow(t)
            simulator=smallSimulator();
            simulator.run(500);
            action=struct('accessProbability',1,'raShare',0.2,'effectiveTick',500);
            [applied,reason]=nbiot.controller.applyAction(simulator,action);
            t.verifyTrue(applied,reason);
            t.verifyEqual(simulator.runtimeAction.accessProbability,1);
            t.verifyEqual(simulator.runtimeAction.raShare,0.2);
            usage=simulator.calendar.usage();
            firstWindow=usage.startTick==0 & usage.direction==0;
            secondWindow=usage.startTick==500 & usage.direction==0;
            t.verifyEqual(usage.raQuotaUnits(firstWindow), ...
                floor(0.1*usage.availableUnits(firstWindow)));
            t.verifyEqual(usage.raQuotaUnits(secondWindow), ...
                floor(0.2*usage.availableUnits(secondWindow)));
            t.verifyEqual(simulator.cfg.policy.raShare,0.1);
        end

        function invalidActionDoesNotPartiallyChangeRuntime(t)
            simulator=smallSimulator();
            simulator.run(500);
            action=struct('accessProbability',0.4,'raShare',0.3,'effectiveTick',500);
            [applied,reason]=nbiot.controller.applyAction(simulator,action);
            t.verifyFalse(applied);
            t.verifyEqual(reason,'unsupported-action');
            t.verifyEqual(simulator.runtimeAction.accessProbability,1);
            t.verifyEqual(simulator.runtimeAction.raShare,0.1);
        end

        function resourceConflictRejectsActionWithoutChangingRuntimeOrQuotas(t)
            simulator=smallSimulator();
            simulator.run(500);
            occupiedNprach=[];
            for first=simulator.cfg.ra.startOffsetTicks:simulator.cfg.ra.periodTicks: ...
                    simulator.cfg.simulation.durationTicks-6
                if first>=500&&first<1000
                    occupiedNprach=[occupiedNprach,first:first+5]; %#ok<AGROW>
                end
            end
            candidates=setdiff(500:999,occupiedNprach,'stable');
            plan=struct('direction','UL','phase','DT','ticks',candidates(1:361), ...
                'frequencyStartHz',0,'bandwidthHz',180000,'grantId',999999);
            t.verifyTrue(simulator.calendar.reserveTransaction(plan));

            action=struct('accessProbability',1,'raShare',0.3,'effectiveTick',500);
            [applied,reason]=simulator.applyRuntimeAction(action);
            t.verifyFalse(applied);
            t.verifyEqual(reason,'resource-budget-conflict');
            t.verifyEqual(simulator.runtimeAction.raShare,0.1);
            usage=simulator.calendar.usage();
            ulWindow=usage.startTick==500&usage.direction==0;
            dlWindow=usage.startTick==500&usage.direction==1;
            t.verifyEqual(usage.raQuotaUnits(ulWindow), ...
                floor(0.1*usage.availableUnits(ulWindow)));
            t.verifyEqual(usage.raQuotaUnits(dlWindow), ...
                floor(0.1*usage.availableUnits(dlWindow)));
        end
    end
end

function [policy,current,estimate,state]=fixture()
policy=adaptiveDefaults();
current=struct('accessProbability',1,'raShare',0.1);
estimate=struct('valid',false,'value',NaN,'featureWindowEndTick',NaN);
state=struct('tick',0,'durationTicks',5000);
end

function simulator=smallSimulator()
projectRoot=fileparts(fileparts(mfilename('fullpath')));
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.durationTicks=1000;
cfg.traffic.kind='none';
cfg=nbiot.experiments.loadCalibration(cfg, ...
    fullfile(projectRoot,'results','nprach-calibration.mat'));
simulator=nbiot.NBIoTSimulator(cfg,[],localDevelopment());
end
