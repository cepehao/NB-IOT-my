classdef TestSavedReportOverview < matlab.unittest.TestCase
    methods (Test)
        function metadataUsesOnlyFactsFromExistingResult(t)
            result=reportResult(100,'burst');

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyEqual(metadata.schemaVersion,1);
            t.verifyEqual(metadata.fields.mode,'Static');
            t.verifyEqual(metadata.fields.numUE,100);
            t.verifyEqual(metadata.fields.activeUE,100);
            t.verifyEqual(metadata.fields.trafficType,'burst');
            t.verifyEqual(metadata.fields.payloadBytes,200);
            t.verifyEqual(metadata.fields.actualTick,5000);
            t.verifyEqual(metadata.fields.tickSeconds,.001);
            t.verifyEqual(metadata.fields.durationSeconds,5);
            t.verifyEqual(metadata.fields.kpiWindowTicks,500);
            t.verifyEqual(metadata.fields.planned,100);
            t.verifyEqual([metadata.fields.created metadata.fields.delivered ...
                metadata.fields.dropped metadata.fields.unfinished],[100 6 86 8]);
            t.verifyEmpty(metadata.unavailableFields);
        end

        function metadataUsesDatasetWindowThatDefinesKpiRows(t)
            result=reportResult(10,'burst');
            result.config.policy.windowTicks=1000;
            result.config.dataset.windowTicks=500;
            validated=nbiot.config.validateConfig(result.config);
            t.verifyEqual(validated.policy.windowTicks,1000);
            t.verifyEqual(validated.dataset.windowTicks,500);

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyEqual(metadata.fields.kpiWindowTicks,500);
        end

        function explicitActiveGroupIsSeparateFromTotalUe(t)
            result=reportResult(10,'none');
            result.config.traffic.activityMode='explicit';
            result.config.traffic.activeUeIds=[2 8];

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyEqual(metadata.fields.numUE,10);
            t.verifyEqual(metadata.fields.activeUE,2);
            t.verifyEqual(metadata.fields.planned,0);
        end

        function periodicPlanMatchesGeneratedArrivalsAtHorizonBoundary(t)
            result=reportResult(2,'periodic');
            result.config.simulation.durationTicks=512;
            result.config.simulation.seed=findPeriodicBoundarySeed( ...
                result.config.simulation.numUE,512,80);
            result.config.traffic.periodTicks=80;
            result.actualTick=512;
            sources=nbiot.randomness.RandomSources( ...
                result.config.simulation.seed,result.config.simulation.realizationId);
            arrivals=nbiot.traffic.generateArrivals(result.config,sources);
            planned=numel(arrivals);
            result.kpiSummary=struct('created',planned,'delivered',planned, ...
                'dropped',0,'unfinished',0);

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyGreaterThan(planned,0);
            t.verifyEqual(metadata.fields.planned,planned);
            t.verifyEqual(metadata.fields.periodTicks,80);
        end

        function periodIsNotReportedForTrafficWithoutPeriod(t)
            burst=nbiot.results.buildReportMetadata(reportResult(2,'burst'));
            poisson=nbiot.results.buildReportMetadata(reportResult(2,'poisson'));

            t.verifyTrue(isnan(burst.fields.periodTicks));
            t.verifyTrue(isnan(poisson.fields.periodTicks));
        end

        function burstPlanRemainsKnownBeforeItsArrivalWindow(t)
            result=reportResult(5,'burst');
            result.actualTick=500;
            result.kpiSummary=struct('created',0,'delivered',0, ...
                'dropped',0,'unfinished',0);

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyEqual(metadata.fields.planned,5);
            t.verifyEqual(metadata.fields.created,0);
        end

        function poissonDoesNotClaimAnExactPlannedCount(t)
            result=reportResult(1,'poisson');

            metadata=nbiot.results.buildReportMetadata(result);

            t.verifyTrue(isnan(metadata.fields.planned));
        end

        function validSidecarIsVerifiedAgainstItsCaseFiles(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,100,'burst',6,[100 6 86 8]);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'verified');
            t.verifyEqual(view.fields.numUE,100);
            t.verifyEqual(view.fields.actualTick,5000);
            t.verifyEqual(view.fields.created,100);
            t.verifyEqual(view.fields.delivered,6);
            t.verifyEqual(view.fields.dropped,86);
            t.verifyEqual(view.fields.unfinished,8);
        end

        function alteredKpiBytesAndForeignIdentityAreInvalid(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,100,'burst',6,[100 6 86 8]);
            first=nbiot.ui.loadReportMetadata(kpiPath);
            t.verifyEqual(first.status,'verified');
            fid=fopen(kpiPath,'ab'); fwrite(fid,uint8('changed'),'uint8'); fclose(fid);

            changed=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(changed.status,'invalid');

            otherFolder=tempname; mkdir(otherFolder);
            t.addTeardown(@() removeFolder(otherFolder));
            [otherKpi,reportPath]=writeCaseFixture( ...
                otherFolder,1,'periodic',6,[1 1 0 0]);
            report=jsondecode(fileread(reportPath));
            report.caseKey='foreign-case';
            writeJson(reportPath,report);
            refreshManifestFile(otherFolder,'fixture_report.json',reportPath);

            foreign=nbiot.ui.loadReportMetadata(otherKpi);

            t.verifyEqual(foreign.status,'invalid');
            t.verifyNotEqual(foreign.caseKey,'foreign-case');
        end

        function changedSummaryAndSidecarInvalidateCachedVerification(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            first=nbiot.ui.loadReportMetadata(kpiPath);
            t.verifyEqual(first.status,'verified');

            summaryPath=fullfile(folder,'fixture_summary.csv');
            fid=fopen(summaryPath,'ab'); fwrite(fid,uint8('changed'),'uint8'); fclose(fid);
            summaryChanged=nbiot.ui.loadReportMetadata(kpiPath);
            t.verifyEqual(summaryChanged.status,'invalid');

            sidecarFolder=tempname; mkdir(sidecarFolder);
            t.addTeardown(@() removeFolder(sidecarFolder));
            [sidecarKpi,reportPath]=writeCaseFixture( ...
                sidecarFolder,100,'burst',6,[100 6 86 8]);
            beforeSidecarChange=nbiot.ui.loadReportMetadata(sidecarKpi);
            t.verifyEqual(beforeSidecarChange.status,'verified');
            fid=fopen(reportPath,'ab'); fwrite(fid,uint8('changed'),'uint8'); fclose(fid);
            sidecarChanged=nbiot.ui.loadReportMetadata(sidecarKpi);
            t.verifyEqual(sidecarChanged.status,'invalid');
        end

        function sidecarCanonicalHashMustMatchMarkerIdentity(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,reportPath]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            report=jsondecode(fileread(reportPath));
            report.canonicalConfigSha256=repmat('b',1,64);
            writeJson(reportPath,report);
            refreshManifestFile(folder,'fixture_report.json',reportPath);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'invalid');
            t.verifyNotEmpty(view.reason);
        end

        function sidecarMustReferenceTheSelectedKpiAndItsSummary(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,reportPath]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            summaryPath=fullfile(folder,'fixture_summary.csv');
            report=jsondecode(fileread(reportPath));
            report.files.kpi=fileRecord(summaryPath);
            writeJson(reportPath,report);
            refreshManifestFile(folder,'fixture_report.json',reportPath);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'invalid');
            t.verifyNotEmpty(view.reason);
        end

        function readerRejectsJsonWithoutMarkerAndMarkerWithoutJson(t)
            withJsonFolder=tempname; mkdir(withJsonFolder);
            t.addTeardown(@() removeFolder(withJsonFolder));
            [withJsonKpi,~]=writeCaseFixture( ...
                withJsonFolder,1,'periodic',6,[1 1 0 0]);
            delete(fullfile(withJsonFolder,'case-complete.json'));
            jsonWithoutMarker=nbiot.ui.loadReportMetadata(withJsonKpi);
            t.verifyNotEqual(jsonWithoutMarker.status,'verified');
            t.verifyNotEmpty(jsonWithoutMarker.reason);

            withMarkerFolder=tempname; mkdir(withMarkerFolder);
            t.addTeardown(@() removeFolder(withMarkerFolder));
            [withMarkerKpi,~]=writeCaseFixture( ...
                withMarkerFolder,1,'periodic',6,[1 1 0 0]);
            delete(fullfile(withMarkerFolder,'fixture_report.json'));
            missingJson=nbiot.ui.loadReportMetadata(withMarkerKpi);
            t.verifyEqual(missingJson.status,'invalid');
            t.verifyNotEmpty(missingJson.reason);
        end

        function escapedSidecarPathIsInvalid(t)
            [parent,folder]=makeIsolatedCaseFolder(t);
            [kpiPath,reportPath]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            markerPath=fullfile(folder,'case-complete.json');
            marker=jsondecode(fileread(markerPath));
            marker.reportMetadataFile=['..' filesep 'outside.json'];
            outsidePath=fullfile(parent,'outside.json');
            copyfile(reportPath,outsidePath);
            reportIndex=find(strcmp({marker.files.name},'fixture_report.json'),1);
            outsideRecord=fileRecord(outsidePath);
            outsideRecord.name=marker.reportMetadataFile;
            marker.files(reportIndex)=outsideRecord;
            writeJson(markerPath,marker);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'invalid');
            t.verifyTrue(contains(lower(view.reason),'папки случая'));
        end

        function referencedKpiAndSummaryMustStayInsideTheCaseFolder(t)
            for fileKind={'kpi','summary'}
                [parent,folder]=makeIsolatedCaseFolder(t);
                [kpiPath,reportPath]=writeCaseFixture( ...
                    folder,100,'burst',6,[100 6 86 8]);
                report=jsondecode(fileread(reportPath));
                outsideName=['..' filesep 'outside_' fileKind{1} '.csv'];
                report.files.(fileKind{1}).name=outsideName;
                writeJson(reportPath,report);
                refreshManifestFile(folder,'fixture_report.json',reportPath);
                outsidePath=fullfile(parent, ...
                    ['outside_' fileKind{1} '.csv']);
                sourcePath=fullfile(folder,['fixture_' fileKind{1} '.csv']);
                copyfile(sourcePath,outsidePath);
                outsideRecord=fileRecord(outsidePath);
                outsideRecord.name=outsideName;
                markerPath=fullfile(folder,'case-complete.json');
                marker=jsondecode(fileread(markerPath));
                originalName=['fixture_' fileKind{1} '.csv'];
                recordIndex=find(strcmp({marker.files.name},originalName),1);
                marker.files(recordIndex)=outsideRecord;
                tableIndex=find(strcmp({marker.tables.file},originalName),1);
                marker.tables(tableIndex).file=outsideName;
                writeJson(markerPath,marker);
                refreshManifestFile(folder,'fixture_report.json',reportPath);

                view=nbiot.ui.loadReportMetadata(kpiPath);

                t.verifyEqual(view.status,'invalid');
                t.verifyTrue(contains(lower(view.reason),'папки случая'));
            end
        end

        function unbalancedOutcomeCountsStayVisibleAndInvalid(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,100,'burst',6,[100 6 85 8]);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'invalid');
            t.verifyEqual(view.fields.dropped,85, ...
                'The reader must not repair inconsistent packet counts.');
        end

        function oldV3SummaryShowsAvailableFactsAsPartial(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,100,'burst',5,[100 6 86 8]);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'partial');
            t.verifyEqual(view.fields.mode,'Static');
            t.verifyEqual(view.fields.numUE,100);
            t.verifyEqual(view.fields.actualTick,5000);
            t.verifyTrue(isnan(view.fields.tickSeconds));
            t.verifyEqual(view.fields.durationSeconds,5);
            t.verifyEqual([view.fields.created view.fields.delivered ...
                view.fields.dropped view.fields.unfinished],[100 6 86 8]);
            t.verifyTrue(isnan(view.fields.activeUE));
            t.verifyTrue(isnan(view.fields.payloadBytes));
            t.verifyEqual(view.fields.trafficType,'');
        end

        function unbalancedLegacySummaryRemainsVisibleAndInvalid(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,100,'burst',5,[100 6 85 8]);

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'invalid');
            t.verifyEqual([view.fields.created view.fields.delivered ...
                view.fields.dropped view.fields.unfinished],[100 6 85 8], ...
                'The reader must preserve, not repair, legacy packet counts.');
            t.verifyNotEmpty(view.reason);
        end

        function standaloneKpiHasNoReportMetadata(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture(folder,1,'none',0,[0 0 0 0]);
            delete(fullfile(folder,'case-complete.json'));
            delete(fullfile(folder,'fixture_report.json'));

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'unavailable');
            t.verifyNotEmpty(view.reason);
        end

        function lightweightReaderAcceptsLegacyExportVersionsTwoThroughFive(t)
            for version=2:5
                folder=tempname; mkdir(folder);
                t.addTeardown(@() removeFolder(folder));
                [kpiPath,~]=writeCaseFixture( ...
                    folder,1,'periodic',version,[1 1 0 0]);

                view=nbiot.ui.loadReportMetadata(kpiPath);

                t.verifyEqual(view.status,'partial', ...
                    sprintf('tableExportVersion %d should remain readable.',version));
                t.verifyEqual(view.fields.numUE,1);
                t.verifyTrue(isnan(view.fields.tickSeconds));
                t.verifyEqual(view.fields.durationSeconds,5);
            end
        end

        function invalidMetadataDoesNotPreventKpiCsvLoading(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,reportPath]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            fid=fopen(reportPath,'ab'); fwrite(fid,uint8('broken'),'uint8'); fclose(fid);

            loaded=nbiot.ui.loadKpiCsvFiles({kpiPath});

            t.verifyEqual(height(loaded.tables{1}),2);
            t.verifyEqual(loaded.reportMetadata{1}.status,'invalid');
            t.verifyNotEmpty(loaded.reportMetadata{1}.reason);
        end

        function twoSelectedCasesKeepTheirOwnReportIdentity(t)
            firstFolder=tempname; mkdir(firstFolder);
            t.addTeardown(@() removeFolder(firstFolder));
            secondFolder=tempname; mkdir(secondFolder);
            t.addTeardown(@() removeFolder(secondFolder));
            [firstKpi,~]=writeCaseFixture( ...
                firstFolder,100,'burst',6,[100 6 86 8]);
            [secondKpi,~]=writeCaseFixture( ...
                secondFolder,1,'periodic',6,[1 1 0 0]);

            loaded=nbiot.ui.loadKpiCsvFiles({firstKpi,secondKpi});

            t.verifyEqual(loaded.reportMetadata{1}.fields.numUE,100);
            t.verifyEqual(loaded.reportMetadata{1}.fields.trafficType,'burst');
            t.verifyEqual(loaded.reportMetadata{2}.fields.numUE,1);
            t.verifyEqual(loaded.reportMetadata{2}.fields.trafficType,'periodic');
        end

        function readerWorksWithoutMatAndFullCaseVerification(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture( ...
                folder,100,'burst',6,[100 6 86 8]);
            t.verifyEmpty(dir(fullfile(folder,'*.mat')));

            view=nbiot.ui.loadReportMetadata(kpiPath);

            t.verifyEqual(view.status,'verified');
        end

        function injectedDialogSwitchesBetweenFixtureCardsWithoutStartingRun(t)
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            firstFolder=fullfile(folder,'first'); mkdir(firstFolder);
            secondFolder=fullfile(folder,'second'); mkdir(secondFolder);
            [firstKpi,~]=writeCaseFixture( ...
                firstFolder,100,'burst',6,[100 6 86 8],[],5000,'first');
            [secondKpi,~]=writeCaseFixture( ...
                secondFolder,1,'periodic',6,[1 1 0 0],[],5000,'second');
            dialogs=struct('chooseKpiFile',@() deal( ...
                {fullfile('first',getName(firstKpi)), ...
                fullfile('second',getName(secondKpi))},folder), ...
                'showAlert',@unexpectedAlert);
            oldPath=path;
            addpath(fullfile(projectRoot,'apps'));
            t.addTeardown(@() path(oldPath));
            app=NBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            app.Timer.Period=3600;

            button=findall(app.Figure,'Tag','savedKpiButton');
            t.assertEqual(numel(button),1);
            feval(button.ButtonPushedFcn,button,[]);

            card=findall(app.Figure,'Tag','savedReportCard');
            selector=findall(app.Figure,'Tag','savedReportSelector');
            nextRun=findall(app.Figure,'Tag','nextRunSettingsInfo');
            windowInfo=findall(app.Figure,'Tag','savedKpiWindowInfo');
            numUE=findall(app.Figure,'Tag','numUE');
            t.assertEqual(numel(card),1);
            t.assertEqual(numel(selector),1);
            text=join(string(card.Value),' ');
            t.verifyTrue(contains(text,'100 устройств'));
            t.verifyTrue(contains(text,'100 создано'));
            t.verifyTrue(contains(text,'8 не завершились'));
            t.verifyTrue(contains(text,'к концу наблюдения'));
            t.verifyEqual(selector.Value,1);
            t.verifyEqual(selector.ItemsData,[1 2]);
            t.verifyEqual(app.Session.Status,'idle');
            t.verifyFalse(app.Session.hasResult());
            t.verifyEqual(numUE.Value,10, ...
                'Saved values must not alter next-run controls.');
            t.assertEqual(numel(nextRun),1);
            t.verifyTrue(contains(nextRun.Text,'Настройки следующего запуска'));
            t.assertEqual(numel(windowInfo),1);
            t.verifyTrue(contains(windowInfo.Text,'500 мс'));

            selector.Value=2;
            feval(selector.ValueChangedFcn,selector,[]);
            text=join(string(card.Value),' ');
            t.verifyTrue(contains(text,'1 устройство'));
            t.verifyTrue(contains(text,'periodic'));
            t.verifyFalse(contains(text,'100 устройств'));
            t.verifyEqual(selector.Value,2);
            t.verifyEqual(app.Session.Status,'idle');
            t.verifyFalse(app.Session.hasResult());
        end

        function uiExplainsVariableAndIncompleteKpiWindows(t)
            projectRoot=fileparts(fileparts(mfilename('fullpath')));
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            [kpiPath,~]=writeCaseFixture( ...
                folder,1,'periodic',6,[1 1 0 0],[500;512],512);
            dialogs=struct('chooseKpiFile',@() deal(getName(kpiPath),folder), ...
                'showAlert',@unexpectedAlert);
            oldPath=path;
            addpath(fullfile(projectRoot,'apps'));
            t.addTeardown(@() path(oldPath));
            app=NBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));
            app.Timer.Period=3600;
            button=findall(app.Figure,'Tag','savedKpiButton');
            feval(button.ButtonPushedFcn,button,[]);

            windowInfo=findall(app.Figure,'Tag','savedKpiWindowInfo');

            t.assertEqual(numel(windowInfo),1);
            t.verifyTrue(contains(windowInfo.Text,'500 мс'));
            t.verifyTrue(contains(windowInfo.Text,'12 мс'));
            t.verifyTrue(contains(lower(windowInfo.Text),'неполное'));
        end

    end
end

function result=reportResult(numUE,trafficKind)
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=numUE;
cfg.simulation.durationTicks=5000;
cfg.traffic.kind=trafficKind;
cfg.traffic.packetBytes=200;
cfg.traffic.activityMode='all';
result=struct('config',cfg,'status','completed','actualTick',5000, ...
    'kpiSummary',struct('created',100,'delivered',6,'dropped',86, ...
        'unfinished',8));
end

function [kpiPath,reportPath]=writeCaseFixture( ...
        folder,numUE,trafficKind,version,counts,windowEnds,actualTick,stem)
if nargin<6 || isempty(windowEnds), windowEnds=[500;1000]; end
if nargin<7 || isempty(actualTick), actualTick=5000; end
if nargin<8 || isempty(stem), stem='fixture'; end
kpiPath=fullfile(folder,[stem '_kpi.csv']);
summaryPath=fullfile(folder,[stem '_summary.csv']);
reportPath=fullfile(folder,[stem '_report.json']);
kpi=table([0;500],windowEnds(:),[40;60],[.4;.6], ...
    'VariableNames',{'startTick','endTick','throughputBitsPerSecond', ...
    'cohortDeliveryProbability'});
writetable(kpi,kpiPath);
summary=table("completed","Static",numUE,5000,counts(1),counts(2), ...
    counts(3),counts(4),actualTick,actualTick*.001, ...
    'VariableNames',{'runStatus','method','numUE','durationTicks', ...
    'kpi_created','kpi_delivered','kpi_dropped','kpi_unfinished', ...
    'kpi_service_actualTick','kpi_durationSeconds'});
writetable(summary,summaryPath);
if version==6
    fields=fixtureFields(numUE,trafficKind,counts,actualTick);
    report=struct('schemaVersion',1,'caseKey',['case-' num2str(numUE) '-' trafficKind], ...
        'canonicalConfigSha256',repmat('a',1,64),'fields',fields, ...
        'unavailableFields',{{}},'reason','', ...
        'files',struct('kpi',fileRecord(kpiPath),'summary',fileRecord(summaryPath)));
    writeJson(reportPath,report);
end
tables=[tableRecord(kpiPath,kpi);tableRecord(summaryPath,summary)];
marker=struct('manifestVersion',2,'caseKey',['case-' num2str(numUE) '-' trafficKind], ...
    'canonicalConfigSha256',repmat('a',1,64),'status','completed', ...
    'exportStem',stem,'tableExportVersion',version,'tables',tables, ...
    'files',repmat(fileRecord(kpiPath),1,0));
records=[fileRecord(kpiPath);fileRecord(summaryPath)];
if version==6
    marker.reportMetadataFile=[stem '_report.json'];
    records(end+1)=fileRecord(reportPath);
end
marker.files=records;
writeJson(fullfile(folder,'case-complete.json'),marker);
end

function fields=fixtureFields(numUE,trafficKind,counts,actualTick)
activeUE=numUE;
periodTicks=NaN;
planned=NaN;
if strcmp(trafficKind,'burst'), planned=activeUE; end
if strcmp(trafficKind,'periodic'), periodTicks=1000; planned=counts(1); end
if strcmp(trafficKind,'none'), activeUE=NaN; planned=0; end
fields=struct('mode','Static','numUE',numUE,'activeUE',activeUE, ...
    'trafficType',trafficKind,'payloadBytes',200,'periodTicks',periodTicks, ...
    'durationTicks',5000,'actualTick',actualTick,'tickSeconds',.001, ...
    'durationSeconds',actualTick*.001, ...
    'kpiWindowTicks',500,'planned',planned,'created',counts(1), ...
    'delivered',counts(2),'dropped',counts(3),'unfinished',counts(4));
end

function record=tableRecord(path,value)
record=struct('file',getName(path), ...
    'variableNames',{value.Properties.VariableNames},'rows',height(value));
end

function record=fileRecord(path)
data=dir(path);
record=struct('name',string(getName(path)),'bytes',data.bytes, ...
    'sha256',fileHash(path));
end

function name=getName(path)
[~,base,extension]=fileparts(path);
name=[base extension];
end

function seed=findPeriodicBoundarySeed(numUE,horizon,period)
for seed=0:1000
    sources=nbiot.randomness.RandomSources(seed,0);
    atBoundary=false;
    for ueId=1:numUE
        stream=sources.stream('traffic',0,ueId,0);
        phase=period*rand(stream);
        times=phase:period:horizon;
        atBoundary=atBoundary||any(ceil(times)==horizon);
    end
    if atBoundary, return; end
end
error('TestSavedReportOverview:PeriodicBoundarySeed', ...
    'Could not find deterministic periodic phase at the horizon boundary.');
end

function refreshManifestFile(folder,name,path)
markerPath=fullfile(folder,'case-complete.json');
marker=jsondecode(fileread(markerPath));
index=find(strcmp({marker.files.name},name),1);
marker.files(index)=fileRecord(path);
writeJson(markerPath,marker);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(jsonencode(value),'UTF-8'),'uint8');
end

function hex=fileHash(path)
fid=fopen(path,'rb');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
digest=java.security.MessageDigest.getInstance('SHA-256');
while true
    bytes=fread(fid,4*1024*1024,'*uint8');
    if isempty(bytes), break; end
    digest.update(typecast(bytes(:),'int8'));
end
hex=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function unexpectedAlert(message,title)
error('TestSavedReportOverview:UnexpectedAlert','%s: %s',title,message);
end

function closeApp(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end

function [parent,folder]=makeIsolatedCaseFolder(testCase)
parent=tempname; mkdir(parent);
testCase.addTeardown(@() removeFolder(parent));
folder=fullfile(parent,'case'); mkdir(folder);
end
