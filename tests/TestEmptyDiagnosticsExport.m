classdef TestEmptyDiagnosticsExport < matlab.unittest.TestCase
    methods(Test)
        function zeroWindowCsvRoundTripsWithMatDiagnostics(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() cleanupFolder(folder));

            cfg=nbiot.config.defaultConfig();
            cfg.simulation.numUE=1;
            cfg.simulation.durationTicks=500;
            cfg.dataset.windowTicks=500;
            cfg.simulation.realizationId=2;
            cfg.traffic.kind='none';
            cfg.phy.nprachThreshold=1;
            sim=nbiot.NBIoTSimulator(cfg);
            sim.run(100);
            result=sim.result();

            t.verifyEqual(result.actualTick,100);
            t.verifyEqual(height(result.dataset.observations),0);
            t.verifyEqual(height(result.dataset.targets),0);
            t.verifyEqual(height(result.dataset.diagnostics),0);
            destination=nbiot.results.saveResult(result,folder);
            t.verifyTrue(isfile(destination));
            loaded=load(destination,'datasetDiagnostics');
            t.verifyEqual(height(loaded.datasetDiagnostics),0);
            t.verifyEqual(loaded.datasetDiagnostics,result.dataset.diagnostics);
            availabilityNames={'logicalAvailable','physicalAvailable', ...
                'accessAvailable','retryAvailable','delayAvailable'};
            for k=1:numel(availabilityNames)
                t.verifyClass(loaded.datasetDiagnostics.(availabilityNames{k}), ...
                    'logical');
            end

            % CSV диагностики окон пишется и при нуле окон, со всеми столбцами.
            csvPath=fullfile(folder,'static-v1_n1_r0002_diagnostics.csv');
            t.verifyTrue(isfile(csvPath));
            imported=readtable(csvPath,'VariableNamingRule','preserve','TextType','string');
            t.verifyEqual(height(imported),0);
            t.verifyEqual(imported.Properties.VariableNames, ...
                loaded.datasetDiagnostics.Properties.VariableNames);
        end
    end
end

function cleanupFolder(folder)
assert(startsWith(char(java.io.File(folder).getCanonicalPath()), ...
    char(java.io.File(tempdir).getCanonicalPath()),'IgnoreCase',true));
if isfolder(folder), rmdir(folder,'s'); end
end
