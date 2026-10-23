classdef TestEndToEnd < matlab.unittest.TestCase
    methods (Test)
        function noTrafficHasTenWindowsAndNoFakeDelivery(t)
            t.assumeFalse(isempty(which('lteNPRACH')),'LTE Toolbox unavailable.');
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
            % High threshold is a diagnostic-only no-traffic fixture, not a KPI calibration.
            cfg.phy.nprachThreshold=1;
            r=nbiot.runExperiment(cfg);
            t.verifyEqual(r.status,'completed',evalc('disp(r.error)'));
            t.verifyEqual(r.kpiSummary.created,0); t.verifyEqual(r.kpiSummary.delivered,0);
            t.verifyEqual(height(r.dataset.observations),10);
        end
        function stoppingDoesNotTurnWorkIntoDrop(t)
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.burstStartTick=0;
            sim=nbiot.NBIoTSimulator(cfg); sim.stop('manual'); r=sim.result();
            t.verifyEqual(r.status,'stopped'); t.verifyEqual(r.kpiSummary.dropped,0);
        end
    end
end
