classdef TestPerUeSummary < matlab.unittest.TestCase
    methods (Test)
        function combinesLinkBudgetTrafficAndAccessPerUe(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=3;
            cfg.traffic.kind='none';
            scenario=nbiot.scenario.buildScenario(cfg);
            packets=struct('ueId',{uint32(1),uint32(1),uint32(3)}, ...
                'status',{'delivered','unfinished','dropped'});
            attempts=struct('ueId',{uint32(1),uint32(1),uint32(2)}, ...
                'status',{'success','unfinished','failure'});
            deviceStates=["IDLE";"WAIT_RA";"BACKOFF"];

            summary=nbiot.results.buildUeSummary( ...
                cfg,scenario,packets,attempts,deviceStates);

            test.verifyEqual(summary.ueId,[1;2;3]);
            test.verifyEqual(summary.xM,[scenario.ue.xM].');
            test.verifyEqual(summary.indoor,[scenario.ue.indoor].');
            test.verifyEqual(summary.pathLossDb,[scenario.ue.pathLossDb].');
            test.verifyEqual(summary.receivedPowerUlDbm, ...
                [scenario.linkBudget.receivedPowerUlDbm].');
            test.verifyEqual(summary.referenceSnrDlDb, ...
                [scenario.linkBudget.referenceSnrDlDb].');
            test.verifyEqual(summary.coverageClass,repmat("CE0",3,1));
            test.verifyEqual(summary.created,[2;0;1]);
            test.verifyEqual(summary.delivered,[1;0;0]);
            test.verifyEqual(summary.dropped,[0;0;1]);
            test.verifyEqual(summary.unfinished,[1;0;0]);
            test.verifyEqual(summary.raAttempts,[2;1;0]);
            test.verifyEqual(summary.raSuccesses,[1;0;0]);
            test.verifyEqual(summary.raFailures,[0;1;0]);
            test.verifyEqual(summary.raUnfinished,[1;0;0]);
            test.verifyEqual(summary.deviceStateAtEnd,deviceStates);
            test.verifyEqual(summary.serviceOutcome,["mixed";"no-packets";"dropped"]);
        end

        function unifiedPerUeSummaryIsWrittenToCsv(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=10;
            cfg.traffic.kind='none';
            cfg.phy.nprachThreshold=1;
            sim=nbiot.NBIoTSimulator(cfg);
            sim.run();
            result=sim.result();

            test.verifyEqual(height(result.ueSummary),1);
            test.verifyEqual(result.ueSummary.raAttempts,0);
            test.verifyEqual(result.ueSummary.deviceStateAtEnd,"IDLE");
            test.verifyEqual(result.ueSummary.serviceOutcome,"no-packets");
            test.verifyTrue(isfield(result.kpiSummary,'service'));
            test.verifyTrue(result.kpiSummary.service.available);
            test.verifyEqual(result.kpiSummary.service.actualTick,10);
            test.verifyTrue(isnan(result.kpiSummary.service.probability));
            test.verifyTrue(istable(result.groupKpi));

            folder=tempname; mkdir(folder); test.addTeardown(@() removeFixture(folder));
            nbiot.results.saveResult(result,folder);
            csvPath=fullfile(folder,'static-v1_n1_r0000_ue.csv');
            exported=readtable(csvPath,'TextType','string', ...
                'VariableNamingRule','preserve');

            test.verifyEqual(exported.Properties.VariableNames, ...
                result.ueSummary.Properties.VariableNames);
            test.verifyEqual(exported.ueId,result.ueSummary.ueId);
            test.verifyEqual(exported.receivedPowerUlDbm, ...
                result.ueSummary.receivedPowerUlDbm,'AbsTol',1e-10);
            test.verifyEqual(exported.referenceSnrDlDb, ...
                result.ueSummary.referenceSnrDlDb,'AbsTol',1e-10);
            test.verifyEqual(exported.serviceOutcome, ...
                result.ueSummary.serviceOutcome);

            loaded=load(fullfile(folder,'static-v1_n1_r0000.mat'),'result');
            test.verifyEqual(loaded.result.kpiSummary.service, ...
                result.kpiSummary.service);
            test.verifyEqual(loaded.result.groupKpi,result.groupKpi);
            groupsPath=fullfile(folder,'static-v1_n1_r0000_groups.csv');
            test.verifyTrue(isfile(groupsPath));
            exportedGroups=readtable(groupsPath,'TextType','string', ...
                'VariableNamingRule','preserve');
            test.verifyEqual(exportedGroups.groupDimension, ...
                result.groupKpi.groupDimension);
            test.verifyEqual(exportedGroups.groupValue,result.groupKpi.groupValue);
            test.verifyEqual(exportedGroups.created,result.groupKpi.created);
        end
    end
end

function removeFixture(folder)
root=char(java.io.File(folder).getCanonicalPath());
tempRoot=char(java.io.File(tempdir).getCanonicalPath());
assert(startsWith(root,[tempRoot filesep],'IgnoreCase',true));
if isfolder(folder), rmdir(folder,'s'); end
end
