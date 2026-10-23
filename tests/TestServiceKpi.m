classdef TestServiceKpi < matlab.unittest.TestCase
    methods (Test)
        function countsServiceOutageAcrossCompletedHorizon(test)
            summary=makeSummary([true;false;false],["CE0";"CE0";"CE0"], ...
                [1;1;0],[0;1;0],[1;0;0],[0;0;0], ...
                [1;1;0],[0;1;0],[1;0;0],[0;0;0]);

            [service,groups]=nbiot.metrics.serviceKpi(summary,5000,true);

            test.verifyEqual(service.definition,'service-outage-horizon-v1');
            test.verifyTrue(service.available);
            test.verifyEqual(service.actualTick,5000);
            test.verifyEqual(service.demandUeCount,2);
            test.verifyEqual(service.outageUeCount,1);
            test.verifyEqual(service.unfinishedUeCount,0);
            test.verifyEqual(service.probability,0.5);
            indoor=groups(groups.groupDimension=="indoor",:);
            test.verifyEqual(sum(indoor.created),2);
            test.verifyEqual(sum(indoor.delivered),1);
            test.verifyEqual(sum(indoor.dropped),1);
        end

        function groupsUseAggregatedCountsAndPreserveUnknownAndEmptyRows(test)
            summary=makeSummary([1;1;NaN],["CE0";"CE0";missing], ...
                [2;1;1],[1;0;1],[1;0;0],[0;1;0], ...
                [2;1;0],[1;0;0],[1;0;0],[0;1;0]);

            [~,groups]=nbiot.metrics.serviceKpi(summary,5000,true);

            indoor=groups(groups.groupDimension=="indoor",:);
            test.verifyEqual(indoor.groupValue,["indoor";"outdoor";"unknown"]);
            indoorRow=indoor(indoor.groupValue=="indoor",:);
            test.verifyEqual(indoorRow.ueCount,2);
            test.verifyEqual(indoorRow.demandUeCount,2);
            test.verifyEqual(indoorRow.outageUeCount,1);
            test.verifyEqual(indoorRow.created,3);
            test.verifyEqual(indoorRow.delivered,1);
            test.verifyEqual(indoorRow.dropped,1);
            test.verifyEqual(indoorRow.unfinished,1);
            test.verifyEqual(indoorRow.packetDeliveryProbability,1/3,'AbsTol',1e-12);
            test.verifyEqual(indoorRow.serviceOutageProbability,0.5);
            test.verifyEqual(indoorRow.raStarted,3);
            test.verifyEqual(indoorRow.raSuccess,1);
            test.verifyEqual(indoorRow.raFailure,1);
            test.verifyEqual(indoorRow.raUnfinished,1);

            emptyOutdoor=indoor(indoor.groupValue=="outdoor",:);
            test.verifyEqual(emptyOutdoor.ueCount,0);
            test.verifyEqual(emptyOutdoor.created,0);
            test.verifyTrue(isnan(emptyOutdoor.packetDeliveryProbability));
            test.verifyTrue(isnan(emptyOutdoor.serviceOutageProbability));

            coverage=groups(groups.groupDimension=="coverageClass",:);
            test.verifyEqual(coverage.groupValue,["CE0";"unknown"]);
            unknown=coverage(coverage.groupValue=="unknown",:);
            test.verifyEqual(unknown.ueCount,1);
            test.verifyEqual(unknown.created,1);
        end

        function partialAndNoDemandResultsDoNotInventProbabilities(test)
            partialSummary=makeSummary(true,"CE0",1,0,0,1,1,0,0,1);

            [partial,partialGroups]=nbiot.metrics.serviceKpi( ...
                partialSummary,1000,false);

            test.verifyFalse(partial.available);
            test.verifyEqual(partial.actualTick,1000);
            test.verifyEqual(partial.demandUeCount,1);
            test.verifyEqual(partial.outageUeCount,1);
            test.verifyEqual(partial.unfinishedUeCount,1);
            test.verifyTrue(isnan(partial.probability));
            test.verifyTrue(all(isnan(partialGroups.serviceOutageProbability)));

            noDemand=makeSummary([true;false],["CE0";"CE0"], ...
                [0;0],[0;0],[0;0],[0;0],[0;0],[0;0],[0;0],[0;0]);
            [empty,emptyGroups]=nbiot.metrics.serviceKpi(noDemand,0,true);
            test.verifyTrue(empty.available);
            test.verifyEqual(empty.demandUeCount,0);
            test.verifyEqual(empty.outageUeCount,0);
            test.verifyTrue(isnan(empty.probability));
            test.verifyTrue(all(isnan(emptyGroups.packetDeliveryProbability)));
            test.verifyTrue(all(isnan(emptyGroups.serviceOutageProbability)));
        end
    end
end

function summary=makeSummary(indoor,coverageClass,created,delivered,dropped, ...
    unfinished,raAttempts,raSuccesses,raFailures,raUnfinished)
n=numel(created);
summary=table((1:n).',indoor(:),coverageClass(:),created(:),delivered(:), ...
    dropped(:),unfinished(:),raAttempts(:),raSuccesses(:),raFailures(:), ...
    raUnfinished(:),'VariableNames',{'ueId','indoor','coverageClass', ...
    'created','delivered','dropped','unfinished','raAttempts', ...
    'raSuccesses','raFailures','raUnfinished'});
end
