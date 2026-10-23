classdef TestRadioDiagnosticsExport < matlab.unittest.TestCase
    methods (Test)
        function manifestedResultPersistsAndExportsRadioDiagnostics(t)
            [root,folder,result,metadata]=makeFixture(t,true);
            destination=nbiot.results.saveResult(result,folder,metadata);

            loaded=load(destination,'result');
            t.verifyEqual(loaded.result.radioDiagnostics,result.radioDiagnostics);
            t.verifyEqual(loaded.result.radioReceptionLog,result.radioReceptionLog);
            t.verifyEqual(loaded.result.lifecycleLog,result.lifecycleLog);
            t.verifyEqual(loaded.result.kpiSummary.service,result.kpiSummary.service);
            t.verifyEqual(loaded.result.groupKpi,result.groupKpi);
            t.verifyEqual(result.actualTick,result.config.simulation.durationTicks);
            t.verifyEqual(result.dataset.diagnostics.logicalAvailable,true);
            t.verifyEqual(result.dataset.diagnostics.logicalCollisionGroups,0);
            t.verifyEqual(result.dataset.diagnostics.physicalAvailable,true);
            t.verifyEqual(result.dataset.diagnostics.physicalOverlapPairs,0);
            t.verifyEqual(result.dataset.diagnostics.accessAvailable,true);
            t.verifyEqual(result.dataset.diagnostics.successfulAccesses,0);
            t.verifyEqual(result.dataset.diagnostics.retryAvailable,true);
            t.verifyEqual(result.dataset.diagnostics.raRetryTransmissions,0);
            t.verifyEqual(result.dataset.diagnostics.delayAvailable,false);
            t.verifyEqual(result.dataset.diagnostics.delaySampleCount,0);
            t.verifyTrue(isnan(result.dataset.diagnostics.meanDelayTicks));
            t.verifyEqual(result.dataset.diagnostics.outcomeHorizonTick,result.actualTick);
            marker=jsondecode(fileread(fullfile(folder,'case-complete.json')));
            t.verifyEqual(marker.tableExportVersion,6);
            t.verifyTrue(isfile(fullfile(folder,marker.reportMetadataFile)));
            t.verifyEqual(marker.diagnosticsSchemaVersion,'window-diagnostics-v1');
            diagnosticsSnapshot=load(destination,'datasetDiagnostics');
            t.verifyTrue(isfield(diagnosticsSnapshot,'datasetDiagnostics'));
            diagnosticFile=fullfile(folder,'static-v1_n1_r0007_diagnostics.csv');
            t.verifyTrue(isfile(diagnosticFile));
            if ~isfield(diagnosticsSnapshot,'datasetDiagnostics')||~isfile(diagnosticFile)
                return
            end
            t.verifyEqual(diagnosticsSnapshot.datasetDiagnostics,result.dataset.diagnostics);
            t.verifyTrue(any(strcmp({marker.tables.file},'static-v1_n1_r0007_diagnostics.csv')));
            t.verifyTrue(any(strcmp({marker.files.name},'static-v1_n1_r0007_diagnostics.csv')));
            diagnosticExport=readtable(diagnosticFile,'VariableNamingRule','preserve');
            keys={'realizationId','windowId','startTick','endTick'};
            t.verifyEqual(diagnosticExport(:,keys),result.dataset.diagnostics(:,keys));
            expectedAvailability=repmat("false",height(result.dataset.diagnostics),1);
            expectedAvailability(result.dataset.diagnostics.logicalAvailable)="true";
            t.verifyEqual(string(diagnosticExport.logicalAvailable),expectedAvailability);
            t.verifyEqual(isnan(diagnosticExport.meanDelayTicks), ...
                isnan(result.dataset.diagnostics.meanDelayTicks));
            radioFile=fullfile(folder,'static-v1_n1_r0007_radio.csv');
            groupsFile=fullfile(folder,'static-v1_n1_r0007_groups.csv');
            t.verifyTrue(isfile(radioFile));
            t.verifyTrue(isfile(groupsFile));
            t.verifyTrue(any(strcmp({marker.tables.file},'static-v1_n1_r0007_radio.csv')));
            t.verifyTrue(any(strcmp({marker.tables.file},'static-v1_n1_r0007_groups.csv')));
            summary=readtable(fullfile(folder,'static-v1_n1_r0007_summary.csv'), ...
                'VariableNamingRule','preserve','TextType','string');
            t.verifyEqual(summary.kpi_service_definition,"service-outage-horizon-v1");
            t.verifyEqual(summary.kpi_service_available,1);
            t.verifyEqual(summary.kpi_service_actualTick,20);
            report=nbiot.results.verifyCase(folder,metadata);
            t.verifyTrue(report.passed,evalc('disp(report.checks)'));

            groups=readtable(groupsFile,'VariableNamingRule','preserve', ...
                'TextType','string');
            t.verifyEqual(groups.groupDimension,result.groupKpi.groupDimension);
            t.verifyEqual(groups.groupValue,result.groupKpi.groupValue);
            t.verifyEqual(groups.raSuccess,result.groupKpi.raSuccess);
            radio=readtable(radioFile,'VariableNamingRule','preserve','TextType','string');
            miss=radio(radio.measurement=="missProbability",:);
            sinr=radio(radio.measurement=="sinrDb",:);
            delay=radio(radio.scope=="receiver-estimate" & radio.measurement=="delay",:);
            t.verifyEqual(miss.numerator,0);
            t.verifyEqual(miss.denominator,1);
            t.verifyEqual(sinr.value,10*log10(2),'AbsTol',1e-12);
            t.verifyEqual(height(delay),2);
            t.verifyEqual(sort(delay.channel),["Msg3";"NPRACH"]);
            t.verifyEqual(sum(contains(radio.provenance,"diagnosticTruth")),4);
            t.verifyTrue(isfolder(root));
        end

        function legacyResultWithoutRadioFieldsKeepsItsOldExports(t)
            [~,folder,result]=makeFixture(t,false);
            destination=nbiot.results.saveResult(result,folder);

            loaded=load(destination,'result');
            t.verifyFalse(isfield(loaded.result,'radioDiagnostics'));
            t.verifyFalse(isfile(fullfile(folder,'static-v1_n1_r0007_radio.csv')));
            t.verifyTrue(isfile(fullfile(folder,'static-v1_n1_r0007_summary.csv')));
        end

        function currentMetadataVersionWithoutGroupsRemainsVerifiable(t)
            [~,folder,result,metadata]=makeFixture(t,true);
            result=rmfield(result,'groupKpi');
            result.dataset=rmfield(result.dataset,'diagnostics');
            result.kpiSummary=rmfield(result.kpiSummary,'service');
            nbiot.results.saveResult(result,folder,metadata);

            marker=jsondecode(fileread(fullfile(folder,'case-complete.json')));
            t.verifyEqual(marker.tableExportVersion,6);
            t.verifyFalse(isfile(fullfile(folder,'static-v1_n1_r0007_groups.csv')));
            report=nbiot.results.verifyCase(folder,metadata);
            t.verifyTrue(report.passed,evalc('disp(report.checks)'));
        end

        function unavailableRetryMetricCannotBeReportedAsZero(t)
            [~,folder,result,metadata]=makeFixture(t,true);
            result.dataset.diagnostics.retryAvailable=false;
            result.dataset.diagnostics.raRetryTransmissions=0;

            t.verifyError(@() nbiot.results.saveResult(result,folder,metadata), ...
                'nbiot:results:Verify');
            t.verifyFalse(isfile(fullfile(folder,'case-complete.json')));
        end
    end
end

function [root,folder,result,metadata]=makeFixture(t,includeRadio)
root=tempname; mkdir(root); mkdir(fullfile(root,'src'));
t.addTeardown(@()removeFixture(root));
write(fullfile(root,'src','fixture.m'),'function value=fixture; value=1; end');
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=1; cfg.simulation.realizationId=7;
cfg.simulation.durationTicks=20;
cfg.traffic.kind='none'; cfg.logging.outputFolder=root;
options=struct('projectRoot',root, ...
    'calibrationFile',fullfile(root,'calibration.mat'), ...
    'modelFiles',{{fullfile(root,'model.mat')}}, ...
    'policyFiles',{{fullfile(root,'policy.m')}}, ...
    'inputFiles',{{fullfile(root,'input.dat')}});
write(options.calibrationFile,'calibration'); write(options.modelFiles{1},'model');
write(options.policyFiles{1},'policy'); write(options.inputFiles{1},'input');
metadata=nbiot.experiments.runtimeManifest(cfg,options);
folder=fullfile(root,'case');

environment=metadata.environment;
ueSummary=table(1,false,"CE0",0,0,0,0,1,1,0,0,'VariableNames', ...
    {'ueId','indoor','coverageClass','created','delivered','dropped', ...
    'unfinished','raAttempts','raSuccesses','raFailures','raUnfinished'});
kpiTimeSeries=table(0,0,0,'VariableNames',{'windowId','startTick','endTick'});
observations=table('Size',[0 2],'VariableTypes',{'double','double'}, ...
    'VariableNames',{'realizationId','windowId'});
targets=table('Size',[0 2],'VariableTypes',{'double','double'}, ...
    'VariableNames',{'realizationId','windowId'});
manifestTable=table("train",0,'VariableNames',{'split','rows'});
resourceUsage=table("cpu",0,'VariableNames',{'resource','units'});
result=struct('config',cfg,'status','completed','environment',environment, ...
    'resultSchemaVersion',2,'actualTick',20,'stopReason','horizon', ...
    'error',struct(),'profiling',struct('elapsedSeconds',.1), ...
    'kpiSummary',struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
        'raStarted',1,'raSuccess',1,'raFailed',0,'raUnfinished',0), ...
    'ueSummary',ueSummary,'kpiTimeSeries',kpiTimeSeries, ...
    'resourceUsage',resourceUsage,'dataset',struct( ...
        'observations',observations,'targets',targets,'manifest',manifestTable, ...
        'schema',nbiot.dataset.featureSchema()));
if includeRadio
    schema=result.dataset.schema;
    observationValues=[7 1 0 20 zeros(1,numel(schema.observationNames)-4)];
    targetValues=[7 1 0 20 zeros(1,numel(schema.targetNames)-4)];
    result.dataset.observations=array2table(observationValues, ...
        'VariableNames',schema.observationNames);
    result.dataset.targets=array2table(targetValues, ...
        'VariableNames',schema.targetNames);
    result.dataset.diagnostics=table(7,1,0,20,0,0,0,0,0,0,NaN,0,0,0, ...
        true,true,true,true,false,20, ...
        'VariableNames',{'realizationId','windowId','startTick','endTick', ...
        'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
        'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
        'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
        'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
        'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'});
    result.attempts=struct('attemptId',1,'packetId',1,'startTick',0, ...
        'endTick',20,'status','failure');
    result.packets=struct('packetId',1,'createdTick',0,'deliveredTick',NaN, ...
        'status','dropped');
else
    % Preserve this fixture as a historical result without the D3 table.
end
if includeRadio
    result.kpiSummary.service=struct('definition','service-outage-horizon-v1', ...
        'available',true,'actualTick',20,'demandUeCount',0,'outageUeCount',0, ...
        'unfinishedUeCount',0,'probability',NaN);
    result.groupKpi=table(["indoor";"coverageClass"],["outdoor";"CE0"], ...
        [1;1],[0;0],[0;0],[0;0],[0;0],[0;0],[0;0], ...
        [NaN;NaN],[NaN;NaN],[1;1],[1;1],[0;0],[0;0], ...
        'VariableNames',{'groupDimension','groupValue','ueCount', ...
        'demandUeCount','outageUeCount','created','delivered','dropped', ...
        'unfinished','packetDeliveryProbability','serviceOutageProbability', ...
        'raStarted','raSuccess','raFailure','raUnfinished'});
    truth=[evt(0,'msg1',struct('attemptId',1,'ueId',1,'packetId',1, ...
        'occasionId',1,'nInit',2)), ...
        evt(15,'ra_success',struct('attemptId',1,'ueId',1,'packetId',1))];
    candidates=struct('nInit',2,'delaySeconds',2e-6,'cfoHz',42);
    observed=evt(10,'nprach_detection',struct('occasionId',1,'readyTick',10, ...
        'candidates',candidates));
    reception=[evt(10,'nprach_component',struct('occasionId',1,'attemptId',1, ...
        'ueId',1,'nInit',2,'startSample',0,'endSampleExclusive',100, ...
        'signalPowerW',2,'interferencePowerW',.5,'noisePowerW',.5, ...
        'configuredDelaySeconds',1e-6,'configuredCfoHz',50)), ...
        evt(15,'npusch_receiver',struct('contextId',1,'occasionId',1, ...
        'nInit',2,'attemptId',1,'ueId',1,'channel','Msg3', ...
        'estimatedDelaySeconds',4e-6,'estimatedCfoHz',24, ...
        'configuredDelaySeconds',3e-6,'configuredCfoHz',20, ...
        'noiseEstimate',.25))];
    result.truthLog=truth; result.observedLog=observed;
    result.radioReceptionLog=reception; result.radioReceptionSchemaVersion=1;
    result.lifecycleLog=[evt(0,'simulation_initialized',struct('profileVersion','static-v1')), ...
        evt(0,'simulation_started',struct('untilTick',20)), ...
        evt(20,'simulation_completed',struct('actualTick',20,'reason','horizon'))];
    result.lifecycleLogSchemaVersion=1;
    result.radioDiagnostics=nbiot.metrics.radioDiagnostics(truth,observed,reception, ...
        struct('actualTick',20,'nInitValues',0:11));
end
end

function event=evt(tick,kind,fields)
event=struct('tick',double(tick),'kind',char(kind),'fields',fields);
end

function write(path,value)
fid=fopen(path,'wb'); fwrite(fid,uint8(value),'uint8'); fclose(fid);
end

function removeFixture(root)
if isfolder(root), rmdir(root,'s'); end
end
