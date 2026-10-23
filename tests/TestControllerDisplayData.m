classdef TestControllerDisplayData < matlab.unittest.TestCase
    methods (Test)
        function adaptiveSummaryPairsForecastWithItsClosedWindow(t)
            state=adaptiveSnapshot();
            view=nbiot.ui.buildControllerDisplayData(state);

            t.verifyTrue(contains(view.summary,'Adaptive-P'));
            t.verifyTrue(contains(view.summary,'Прогноз: 4.00 UE'));
            t.verifyTrue(contains(view.summary,'Факт: 2.00 UE'));
            t.verifyTrue(contains(view.summary,'Ошибка: +2.00 UE'));
            t.verifyTrue(contains(view.summary,'P = 0.50'));
            t.verifyTrue(contains(view.summary,'RA/DT = 10/90'));
            t.verifyEqual(height(view.history),2);
            t.verifyEqual(view.history.decisionTimeSeconds,[0;.5]);
            t.verifyTrue(isnan(view.history.forecastErrorMeanRaUe(1)));
            t.verifyEqual(view.history.actualLoadMeanRaUe(2),2);
            t.verifyEqual(view.history.forecastErrorMeanRaUe(2),2);
            t.verifyEqual(view.history.raShare(2),0.1);
            t.verifyEqual(view.history.raDtShare(2),"10/90");
            t.verifyEqual(view.historyDisplay{1,2},'—');
            t.verifyEqual(view.historyDisplay{1,7},'Нет');
            t.verifyEqual(view.historyDisplay{2,2},'4.00');
            t.verifyEqual(view.historyDisplay{2,3},'2.00');
            t.verifyEqual(view.historyDisplay{2,4},'+2.00');
            t.verifyEqual(view.historyDisplay{2,7},'Да');
        end

        function staticSummaryDoesNotInventAnAdaptiveForecast(t)
            state=adaptiveSnapshot();
            state.controllerMethod='Static';
            state.controllerLog=struct([]);
            state.controllerLatestEstimate=struct('valid',false,'value',NaN, ...
                'featureWindowEndTick',NaN,'reason','not-started');
            state.runtimeAction=struct('accessProbability',1,'raShare',0.1,'effectiveTick',0);
            view=nbiot.ui.buildControllerDisplayData(state);

            t.verifyTrue(contains(view.summary,'Static'));
            t.verifyTrue(contains(view.summary,'прогноз не используется'));
            t.verifyTrue(contains(view.summary,'P = 1.00'));
            t.verifyTrue(contains(view.summary,'RA/DT = 10/90'));
            t.verifyEmpty(view.history);
        end

        function forecastErrorRemainsUnavailableWithoutMatchingClosedTarget(t)
            state=adaptiveSnapshot();
            state.controllerDiagnosticTargets=table(1000,7, ...
                'VariableNames',{'endTick','meanRaUe'});
            view=nbiot.ui.buildControllerDisplayData(state);

            t.verifyTrue(contains(view.summary,'Факт пока не рассчитан'));
            t.verifyTrue(isnan(view.history.actualLoadMeanRaUe(2)));
            t.verifyTrue(isnan(view.history.forecastErrorMeanRaUe(2)));
        end
    end
end

function state=adaptiveSnapshot()
initial=struct('decisionTick',0,'featureWindowEndTick',NaN, ...
    'estimateValue',NaN,'estimateValid',false, ...
    'appliedAccessProbability',1,'appliedRaShare',0.1,'applied',false, ...
    'switched',false,'reason','no-prior-window','estimateReason','no-prior-window');
decision=struct('decisionTick',500,'featureWindowEndTick',500, ...
    'estimateValue',4,'estimateValid',true, ...
    'appliedAccessProbability',0.5,'appliedRaShare',0.1,'applied',true, ...
    'switched',true,'reason','applied','estimateReason','valid');
state=struct('controllerMethod','Adaptive-P', ...
    'controllerLatestEstimate',struct('valid',true,'value',4, ...
        'featureWindowEndTick',500,'reason','valid'), ...
    'runtimeAction',struct('accessProbability',0.5,'raShare',0.1,'effectiveTick',500), ...
    'controllerDiagnosticTargets',table([500;1000],[2;7], ...
        'VariableNames',{'endTick','meanRaUe'}), ...
    'controllerLog',[initial decision],'tickSeconds',0.001);
end
