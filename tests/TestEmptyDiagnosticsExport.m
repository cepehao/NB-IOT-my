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
            caseKey='empty_diagnostics';
            caseFolder=fullfile(folder,caseKey);
            metadata=struct('caseKey',caseKey, ...
                'configSha256',nbiot.results.configSha256(cfg), ...
                'sourceSha256',repmat('a',1,64), ...
                'calibrationSha256',repmat('c',1,64), ...
                'environment',result.environment);

            destination=nbiot.results.saveResult(result,caseFolder,metadata);
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

            marker=jsondecode(fileread(fullfile(caseFolder,'case-complete.json')));
            diagnosticAt=find(endsWith(string({marker.tables.file}), ...
                '_diagnostics.csv'),1);
            t.verifyFalse(isempty(diagnosticAt));
            if ~isempty(diagnosticAt)
                csvPath=fullfile(caseFolder,char(string( ...
                    marker.tables(diagnosticAt).file)));
                imported=readtable(csvPath,'VariableNamingRule','preserve', ...
                    'TextType','string');
                t.verifyEqual(height(imported),0);
                t.verifyEqual(imported.Properties.VariableNames, ...
                    loaded.datasetDiagnostics.Properties.VariableNames);
            end
        end
    end
end

function cleanupFolder(folder)
assert(startsWith(char(java.io.File(folder).getCanonicalPath()), ...
    char(java.io.File(tempdir).getCanonicalPath()),'IgnoreCase',true));
if isfolder(folder), rmdir(folder,'s'); end
end
