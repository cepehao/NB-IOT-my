classdef TestLinkBudget < matlab.unittest.TestCase
    methods (Test)
        function analyticalReferenceValuesMatchProfile(test)
            cfg=nbiot.config.defaultConfig();
            ue=struct('ueId',{uint32(7),uint32(8)}, ...
                'pathLossDb',{121.53263341066987,0});

            links=nbiot.channel.evaluateLinks(cfg,ue);
            pathLossAtReferenceDb=20*log10(4*pi*cfg.channel.carrierHz* ...
                cfg.channel.referenceDistanceM/299792458);
            pathLossAtOneKmDb=pathLossAtReferenceDb+ ...
                10*cfg.channel.pathLossExponent*log10(1000/cfg.channel.referenceDistanceM);
            bsNoiseAt180kDbm=10*log10(1.380649e-23*cfg.channel.temperatureK* ...
                10^(cfg.channel.bsNoiseFigureDb/10)*180000)+30;

            test.verifyEqual(pathLossAtReferenceDb,51.53263341066987,'AbsTol',1e-10);
            test.verifyEqual(pathLossAtOneKmDb,121.53263341066987,'AbsTol',1e-10);
            test.verifyEqual(bsNoiseAt180kDbm,-116.42246214319505,'AbsTol',1e-10);
            test.verifyEqual([links.ueId].',uint32([7;8]));
            test.verifyEqual([links.referenceBandwidthHz].',[180000;180000]);
            test.verifyEqual([links.receivedPowerUlDbm].',[-98.53263341066987;23], ...
                'AbsTol',1e-10);
            test.verifyEqual([links.receivedPowerDlDbm].',[-98.53263341066987;23], ...
                'AbsTol',1e-10);
            test.verifyEqual([links.noisePsdBsWPerHz].', ...
                repmat(1.2661386918778057e-20,2,1),'RelTol',1e-12);
            test.verifyEqual([links.noisePsdUeWPerHz].', ...
                repmat(2.006694593468753e-20,2,1),'RelTol',1e-12);
            test.verifyEqual([links.referenceSnrUlDb].', ...
                [17.889828732525174;139.42246214319505],'AbsTol',1e-9);
            test.verifyEqual([links.referenceSnrDlDb].', ...
                [15.889828732525174;137.42246214319505],'AbsTol',1e-9);
        end

        function scenarioStoresOneLinkBudgetRowPerUe(test)
            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=3;
            cfg.traffic.kind='none';
            scenario=nbiot.scenario.buildScenario(cfg);

            test.verifyTrue(isstruct(scenario.linkBudget));
            test.verifyEqual(numel(scenario.linkBudget),3);
            test.verifyEqual([scenario.linkBudget.ueId].', ...
                uint32([scenario.ue.ueId].'));
            test.verifyEqual({scenario.ue.coverageClass},repmat({'CE0'},1,3));
        end

        function tenDbMorePathLossLowersPowerAndReferenceSnr(test)
            cfg=nbiot.config.defaultConfig();
            ue=struct('ueId',{uint32(1),uint32(2)}, ...
                'pathLossDb',{80,90});

            links=nbiot.channel.evaluateLinks(cfg,ue);

            test.verifyEqual(diff([links.receivedPowerUlDbm]),-10,'AbsTol',1e-12);
            test.verifyEqual(diff([links.referenceSnrUlDb]),-10,'AbsTol',1e-12);
        end
    end
end
