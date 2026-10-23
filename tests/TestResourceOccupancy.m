classdef TestResourceOccupancy < matlab.unittest.TestCase
    methods (Test)
        function countsOnlyReservationsInsideTheClosedWindow(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.durationTicks=10;
            cfg.policy.windowTicks=5;
            cfg.dataset.windowTicks=5;
            calendar=nbiot.scheduler.ResourceCalendar(cfg);
            first=plan('RA',0,1);
            second=plan('DT',5,2);
            test.verifyTrue(calendar.reserveTransaction(first));
            test.verifyTrue(calendar.reserveTransaction(second));

            firstWindow=calendar.windowOccupancy(0,5);
            secondWindow=calendar.windowOccupancy(5,10);

            expectedFraction=2/(5*2*48);
            test.verifyEqual(firstWindow.ulRaOccupancy,expectedFraction,'AbsTol',1e-12);
            test.verifyEqual(firstWindow.ulDtOccupancy,0);
            test.verifyEqual(secondWindow.ulRaOccupancy,0);
            test.verifyEqual(secondWindow.ulDtOccupancy,expectedFraction,'AbsTol',1e-12);
        end

        function onlyAlignedCompletedWindowsAreAccepted(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.durationTicks=10;
            cfg.policy.windowTicks=5;
            calendar=nbiot.scheduler.ResourceCalendar(cfg);

            test.verifyError(@() calendar.windowOccupancy(1,6), ...
                'nbiot:scheduler:WindowOccupancy');
        end
    end
end

function reservation=plan(phase,tick,grantId)
reservation=struct('direction','UL','phase',phase,'ticks',tick, ...
    'frequencyStartHz',0,'bandwidthHz',3750,'grantId',grantId);
end
