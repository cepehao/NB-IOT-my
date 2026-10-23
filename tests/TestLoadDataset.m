classdef TestLoadDataset < matlab.unittest.TestCase
    methods (Test)
        function canonicalSchemaDeclaresOrderedKeysInputsAndTarget(t)
            schema=nbiot.dataset.featureSchema('bs-known-v2.0');
            expectedInputs={'detectedCandidates','meanPeakMetric','maxPeakMetric', ...
                'meanRxEnergyW','ulTbDecodes','ulCrcFailures','rarSent','grantsSent', ...
                'pendingRequestsMean','ulRaOccupancy','ulDtOccupancy','dlRaOccupancy', ...
                'dlDtOccupancy','accessProbability','raShare'};
            t.verifyEqual(schema.keyNames,schema.observationNames(1:4));
            t.verifyEqual(schema.inputNames,expectedInputs);
            t.verifyEqual(schema.targetName,'meanRaUe');
        end

        function joinsTargetsByWindowAndExcludesKeysFromFeatures(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct('reverseTargets',true));
            data=nbiot.dataset.assembleLoadDataset({file},splits(7,"train"));
            t.verifyEqual(data.targets.meanRaUe,[1;2]);
            t.verifyEqual(height(data.features),2);
            t.verifyFalse(any(ismember(data.features.Properties.VariableNames, ...
                {'realizationId','windowId','startTick','endTick','meanRaUe'})));
            t.verifyEqual(data.manifest.kind,'development-fixture');
        end
        function legacySchemaLoadsWithoutInventingNewFeatures(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            withSnapshot=fixture(folder,7,3,struct('legacySchema',true));
            withoutSnapshot=fixture(folder,8,3,struct( ...
                'legacySchema',true,'withoutSchemaSnapshot',true));

            first=nbiot.dataset.assembleLoadDataset({withSnapshot},splits(7,"train"));
            second=nbiot.dataset.assembleLoadDataset({withoutSnapshot},splits(8,"train"));

            legacyFeatures={'detectedCandidates','meanPeakMetric','maxPeakMetric', ...
                'meanRxEnergyW','ulTbDecodes','ulCrcFailures','rarSent', ...
                'grantsSent','pendingRequestsMean'};
            t.verifyEqual(first.schema.version,'static-v1.0');
            t.verifyEqual(second.schema.version,'static-v1.0');
            t.verifyEqual(first.features.Properties.VariableNames,legacyFeatures);
            t.verifyEqual(second.features.Properties.VariableNames,legacyFeatures);
            t.verifyFalse(any(ismember({'ulRaOccupancy','accessProbability'}, ...
                first.features.Properties.VariableNames)));
        end
        function casesWithDifferentFeatureVersionsCannotBeMixed(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            current=fixture(folder,7,3,struct());
            legacy=fixture(folder,8,3,struct('legacySchema',true));

            t.verifyError(@() nbiot.dataset.assembleLoadDataset( ...
                {current,legacy},splits([7;8],["train";"validation"])), ...
                'nbiot:dataset:Schema');
        end
        function allLoadsOfOneIdStayInOneGroup(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct()); b=fixture(folder,7,4,struct());
            data=nbiot.dataset.assembleLoadDataset({a,b},splits(7,"development"));
            t.verifyEqual(data.manifest.independentRealizations,1);
            t.verifyEqual(data.rowInfo.split,repmat("development",4,1));
            t.verifyEqual(height(data.features),4);
            t.verifyEqual(width(data.features),15);
            if ~isfield(data,'diagnostics')
                t.verifyFail('Assembler does not expose window diagnostics yet.'); return
            end
            t.verifyEqual(height(data.diagnostics),4);
            t.verifyEqual(unique(data.diagnostics.caseKey), ...
                sort(unique(data.rowInfo.caseKey)));
            keys=data.diagnostics(:,{'caseKey','realizationId','windowId','startTick','endTick'});
            t.verifyEqual(height(unique(keys,'rows')),4);
            t.verifyTrue(data.manifest.diagnosticsComplete);
        end

        function diagnosticsMustAlignWithEveryCaseWindow(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct());
            caseFolder=fileparts(file);
            if ~rewriteDiagnostics(caseFolder,'shift-start')
                t.verifyFail('saveResult did not export diagnostics.csv.'); return
            end

            report=nbiot.results.verifyCase(caseFolder);
            t.verifyFalse(report.passed);
            t.verifyTrue(contains(lower(strjoin(report.errors,' ')),'diagnostic'));
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({file},splits(7,"train")), ...
                'nbiot:dataset:InvalidCase');
        end

        function historicalCaseKeepsDiagnosticsUnavailable(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct('omitDiagnostics',true));

            data=nbiot.dataset.assembleLoadDataset({file},splits(7,"development"));

            if ~isfield(data,'diagnostics')
                t.verifyFail('Assembler does not expose unavailable historical diagnostics yet.'); return
            end
            t.verifyEqual(height(data.diagnostics),2);
            t.verifyEqual(data.diagnostics.windowId,[1;2]);
            t.verifyFalse(any(data.diagnostics.logicalAvailable));
            t.verifyFalse(any(data.diagnostics.physicalAvailable));
            t.verifyTrue(all(isnan(data.diagnostics.logicalCollisionGroups)));
            t.verifyFalse(data.manifest.diagnosticsComplete);
        end

        function missingOrDuplicateDiagnosticRowsCannotMultiplyJoin(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            missing=fixture(folder,7,3,struct());
            if ~rewriteDiagnostics(fileparts(missing),'delete-row')
                t.verifyFail('saveResult did not export diagnostics.csv.'); return
            end
            missingReport=nbiot.results.verifyCase(fileparts(missing));
            t.verifyFalse(missingReport.passed);

            duplicate=fixture(folder,8,3,struct());
            if ~rewriteDiagnostics(fileparts(duplicate),'duplicate-row')
                t.verifyFail('saveResult did not export diagnostics.csv.'); return
            end
            duplicateReport=nbiot.results.verifyCase(fileparts(duplicate));
            t.verifyFalse(duplicateReport.passed);
        end
        function experimentRolesAreRecordedSeparatelyFromSplitGroups(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct('nonFixture',true));
            splitManifest=table(7,"test","final-comparison", ...
                'VariableNames',{'externalRealizationId','split','experimentRole'});

            data=nbiot.dataset.assembleLoadDataset({file},splitManifest);

            t.verifyEqual(data.rowInfo.split,repmat("test",2,1));
            t.verifyTrue(ismember('experimentRole',data.rowInfo.Properties.VariableNames));
            if ismember('experimentRole',data.rowInfo.Properties.VariableNames)
                t.verifyEqual(data.rowInfo.experimentRole,repmat("final-comparison",2,1));
            end
            t.verifyTrue(ismember('experimentRole',data.manifest.assignments.Properties.VariableNames));
            if ismember('experimentRole',data.manifest.assignments.Properties.VariableNames)
                t.verifyEqual(data.manifest.assignments.experimentRole,"final-comparison");
            end
            t.verifyTrue(data.manifest.experimentRolesExplicit);
            t.verifyEqual(data.manifest.kind,'final-comparison');
        end
        function experimentRoleMustMatchItsSplitGroup(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct());
            splitManifest=table(7,"train","final-comparison", ...
                'VariableNames',{'externalRealizationId','split','experimentRole'});

            t.verifyError(@() nbiot.dataset.assembleLoadDataset({file},splitManifest), ...
                'nbiot:dataset:RoleManifest');
        end
        function trainingBuilderRejectsFinalComparisonData(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct()); destination=fullfile(folder,'training-data');
            opts=struct('resultFiles',{{file}}, ...
                'splitManifest',table(7,"test","final-comparison", ...
                    'VariableNames',{'externalRealizationId','split','experimentRole'}), ...
                'outputFolder',destination,'purpose','training');

            t.verifyError(@() buildLoadDataset(opts),'nbiot:dataset:FinalComparison');
            t.verifyFalse(isfolder(destination));
        end
        function trainingBuilderRequiresExplicitExperimentRoles(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct()); destination=fullfile(folder,'training-data');
            opts=struct('resultFiles',{{file}},'splitManifest',splits(7,"development"), ...
                'outputFolder',destination,'purpose','training');

            t.verifyError(@() buildLoadDataset(opts),'nbiot:dataset:RoleManifest');
            t.verifyFalse(isfolder(destination));
        end
        function trainingBuilderChecksDeclaredRolesAgainstRegistry(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            files={fixture(folder,7,3,struct('nonFixture',true)), ...
                fixture(folder,8,3,struct('nonFixture',true)), ...
                fixture(folder,9,3,struct('nonFixture',true))};
            roles=table([7;8;9],["train";"validation";"test"], ...
                ["training";"validation";"model-test"], ...
                'VariableNames',{'externalRealizationId','split','experimentRole'});
            registryFile=writeRoleRegistry(folder,[7;8;9], ...
                ["training";"validation";"model-test"]);
            destination=fullfile(folder,'training-data');
            opts=struct('resultFiles',{files},'splitManifest',roles, ...
                'outputFolder',destination,'purpose','training','registryFile',registryFile);

            data=buildLoadDataset(opts);

            t.verifyTrue(data.manifest.allocationsVerified);
            t.verifyTrue(data.manifest.experimentRolesExplicit);
            t.verifyEqual(data.manifest.assignments.experimentRole, ...
                ["training";"validation";"model-test"]);
            t.verifyEqual(data.rowInfo.experimentRole, ...
                ["training";"training";"validation";"validation";"model-test";"model-test"]);
            saved=jsondecode(fileread(fullfile(destination,'manifest.json')));
            t.verifyEqual(string({saved.assignments.experimentRole}).', ...
                ["training";"validation";"model-test"]);
        end
        function datasetReportShowsRoleCountsTrafficAndAccessSettings(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            files={ ...
                fixture(folder,7,3,struct('trafficKind','burst', ...
                    'accessProbability',1,'raShare',.1)), ...
                fixture(folder,8,4,struct('trafficKind','periodic', ...
                    'accessProbability',.5,'raShare',.2)), ...
                fixture(folder,9,5,struct('trafficKind','poisson', ...
                    'accessProbability',.25,'raShare',.3))};
            splitManifest=table([7;8;9],["train";"validation";"test"], ...
                ["training";"validation";"model-test"], ...
                'VariableNames',{'externalRealizationId','split','experimentRole'});
            data=nbiot.dataset.assembleLoadDataset(files,splitManifest);

            [report,coverage]=nbiot.dataset.summarizeLoadDataset(data);

            t.verifyEqual(report.schemaVersion,'bs-known-v2.0');
            t.verifyEqual(report.rowCount,6);
            t.verifyEqual(report.independentRealizations,3);
            t.verifyEqual(sort(string(report.trafficKinds)), ...
                ["burst";"periodic";"poisson"]);
            t.verifyEqual(sort(report.configuredAccessProbabilityValues),[.25 .5 1]);
            t.verifyEqual(sort(report.configuredRaShareValues),[.1 .2 .3]);
            t.verifyEqual(sort(coverage.numUE),[3;4;5]);
            t.verifyTrue(any(coverage.burstDurationTicks==100));
            t.verifyTrue(any(coverage.periodTicks==1000));
            t.verifyTrue(any(coverage.poissonRatePerSecond==.2));
            burst=coverage(coverage.trafficKind=="burst",:);
            t.verifyTrue(contains(burst.observedAccessProbabilityValues,"0.75"));
            t.verifyTrue(contains(burst.observedRaShareValues,"0.2"));
            t.verifyEqual(sum([report.groupCounts.independentRealizations]),3);
        end
        function conflictingIdGroupsAreRejected(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct());
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({file}, ...
                splits([7;7],["train";"test"])), 'nbiot:dataset:GroupLeakage');
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({file},splits(8,"train")), ...
                'nbiot:dataset:SplitManifest');
        end
        function duplicateCaseAndWindowAreRejected(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            file=fixture(folder,7,3,struct());
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({file,file},splits(7,"train")), ...
                'nbiot:dataset:Duplicate');
            other=fixture(folder,8,3,struct('duplicateWindow',true));
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({other},splits(8,"train")), ...
                'nbiot:dataset:Duplicate');
        end
        function missingTargetAndInvalidIntervalAreRejected(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct('missingTarget',true));
            b=fixture(folder,8,3,struct('invalidInterval',true));
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({a},splits(7,"train")), ...
                'nbiot:dataset:WindowAlignment');
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({b},splits(8,"train")), ...
                'nbiot:dataset:WindowAlignment');
        end
        function truthColumnAndUnknownSchemaAreRejected(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct('truthColumn',true));
            b=fixture(folder,8,3,struct('unknownSchema',true));
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({a},splits(7,"train")), ...
                'nbiot:dataset:Leakage');
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({b},splits(8,"train")), ...
                'nbiot:dataset:Schema');
        end
        function incompleteAndCorruptPackagesAreRejected(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct('stopped',true));
            b=fixture(folder,8,3,struct());
            csv=strrep(b,'.mat','_observations.csv');
            fid=fopen(csv,'a'); fprintf(fid,'corruption\n'); fclose(fid);
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({a},splits(7,"train")), ...
                'nbiot:dataset:ResultStatus');
            t.verifyError(@() nbiot.dataset.assembleLoadDataset({b},splits(8,"train")), ...
                'nbiot:dataset:InvalidCase');
        end
        function builderRequiresExplicitInputsAndDoesNotOverwrite(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct()); destination=fullfile(folder,'dataset');
            opts=struct('resultFiles',{{a}},'splitManifest',splits(7,"development"), ...
                'outputFolder',destination);
            data=buildLoadDataset(opts);
            t.verifyEqual(height(data.features),2);
            t.verifyTrue(isfile(fullfile(destination,'dataset.mat')));
            t.verifyTrue(isfile(fullfile(destination,'manifest.json')));
            t.verifyTrue(isfile(fullfile(destination,'dataset-summary.json')));
            t.verifyTrue(isfile(fullfile(destination,'scenario-coverage.csv')));
            t.verifyTrue(isfile(fullfile(destination,'diagnostics.csv')));
            if ~isfile(fullfile(destination,'artifacts.json'))
                t.verifyFail('Dataset builder did not write artifacts.json.'); return
            end
            artifacts=jsondecode(fileread(fullfile(destination,'artifacts.json')));
            t.verifyEqual(artifacts.schemaVersion,1);
            expectedArtifactNames={'dataset.mat','observations.csv','targets.csv', ...
                'features.csv','rows.csv','manifest.json','dataset-summary.json', ...
                'scenario-coverage.csv','diagnostics.csv'};
            artifactNames=string({artifacts.files.name});
            t.verifyEqual(sort(cellstr(artifactNames)),sort(expectedArtifactNames));
            t.verifyEqual(numel(unique(artifactNames)),numel(artifactNames), ...
                'Artifact names must be unique.');
            t.verifyFalse(any(artifactNames=="artifacts.json"), ...
                'artifacts.json must not contain its own digest entry.');
            for k=1:numel(artifacts.files)
                record=artifacts.files(k);
                artifactPath=fullfile(destination,char(string(record.name)));
                t.verifyTrue(isfile(artifactPath),sprintf('Missing artifact: %s',record.name));
                if isfile(artifactPath)
                    info=dir(artifactPath);
                    t.verifyEqual(double(record.bytes),double(info.bytes), ...
                        sprintf('Wrong byte count for %s.',record.name));
                    t.verifyEqual(lower(char(string(record.sha256))),sha256(artifactPath), ...
                        sprintf('Wrong SHA-256 for %s.',record.name));
                end
            end
            t.verifyTrue(data.manifest.diagnosticsComplete);
            t.verifyEqual(data.manifest.diagnosticsSchemaVersion,'window-diagnostics-v1');
            exportedManifest=jsondecode(fileread(fullfile(destination,'manifest.json')));
            t.verifyEqual(exportedManifest.diagnosticsSchemaVersion,'window-diagnostics-v1');
            summary=jsondecode(fileread(fullfile(destination,'dataset-summary.json')));
            t.verifyEqual(summary.independentRealizations,1);
            t.verifyEqual(summary.schemaVersion,'bs-known-v2.0');
            coverage=readtable(fullfile(destination,'scenario-coverage.csv'), ...
                'TextType','string');
            t.verifyEqual(coverage.trafficKind,"burst");
            t.verifyError(@() buildLoadDataset(opts),'nbiot:dataset:Output');
            t.verifyError(@() buildLoadDataset(struct()),'nbiot:dataset:Options');
        end
        function uiExportWritesDevelopmentOnlyBundleAndHonorsLocalLimit(t)
            [folder,cleanup]=workspace(); %#ok<ASGLU>
            a=fixture(folder,7,3,struct()); destination=fullfile(folder,'ui-dataset');
            summary=nbiot.ui.exportDevelopmentDataset(a,destination);
            t.verifyEqual(summary.realizationId,7);
            t.verifyEqual(summary.rows,2);
            t.verifyTrue(isfile(fullfile(destination,'dataset.mat')));
            saved=load(fullfile(destination,'dataset.mat'),'data');
            t.verifyEqual(saved.data.manifest.kind,'development-fixture');
            t.verifyEqual(saved.data.rowInfo.split,repmat("development",2,1));
            t.verifyTrue(saved.data.manifest.experimentRolesExplicit);
            t.verifyEqual(saved.data.rowInfo.experimentRole,repmat("development",2,1));
            t.verifyError(@() nbiot.ui.exportDevelopmentDataset(a,destination), ...
                'nbiot:dataset:Output');

            overLimit=fixture(folder,8,11,struct()); blocked=fullfile(folder,'blocked-ui-dataset');
            t.verifyError(@() nbiot.ui.exportDevelopmentDataset(overLimit,blocked), ...
                'nbiot:experiments:ExecutionBudget');
            t.verifyFalse(isfolder(blocked));
        end
    end
end
function [folder,cleanup]=workspace()
folder=tempname; mkdir(folder); cleanup=onCleanup(@() rmdir(folder,'s'));
end
function manifest=splits(ids,groups,roles)
manifest=table(double(ids(:)),string(groups(:)),'VariableNames',{'externalRealizationId','split'});
if nargin>=3, manifest.experimentRole=string(roles(:)); end
end
function file=fixture(root,id,count,options)
cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=count; cfg.simulation.realizationId=id;
cfg.simulation.durationTicks=1000;
if isfield(options,'trafficKind'), cfg.traffic.kind=char(string(options.trafficKind)); end
if isfield(options,'accessProbability'), cfg.policy.accessProbability=options.accessProbability; end
if isfield(options,'raShare'), cfg.policy.raShare=options.raShare; end
schema=nbiot.dataset.featureSchema();
obsValues=[id 1 0 500 5 .2 .4 1e-10 1 0 2 2 1; ...
    id 2 500 1000 7 .3 .5 2e-10 2 1 3 3 2];
if isfield(options,'legacySchema')
    schema=nbiot.dataset.featureSchema('static-v1.0');
else
    occupancyValues=[.05 .02 .01 .03 1 .1; .12 .04 .02 .05 .75 .2];
    obsValues=[obsValues,occupancyValues];
end
obs=array2table(obsValues,'VariableNames',schema.observationNames);
targets=array2table([id 1 0 500 1 2 0 2 1; id 2 500 1000 2 3 0 3 2], ...
    'VariableNames',schema.targetNames);
if isfield(options,'reverseTargets'), targets=targets([2 1],:); end
if isfield(options,'duplicateWindow'), obs=obs([1 1],:); end
if isfield(options,'missingTarget'), targets=targets(1,:); end
if isfield(options,'invalidInterval'), obs.endTick(1)=501; end
if isfield(options,'truthColumn'), obs.meanRaUe=[1;2]; end
if isfield(options,'unknownSchema'), schema.version='unsupported'; end
sourceProfile='development-fixture';
if isfield(options,'nonFixture'), sourceProfile='static-v1'; end
environment=struct('matlabVersion',version,'release',version('-release'),'lteVersion',ver('lte'), ...
    'computer',computer,'validatedInMatlab',false,'sourceProfile',sourceProfile);
status='completed'; if isfield(options,'stopped'), status='stopped'; end
dataset=struct('observations',obs,'targets',targets, ...
    'manifest',nbiot.dataset.buildManifest(id),'schema',schema);
if isfield(options,'withoutSchemaSnapshot'), dataset=rmfield(dataset,'schema'); end
result=struct('config',cfg,'status',status,'environment',environment, ...
    'kpiSummary',struct('created',0,'delivered',0,'dropped',0,'unfinished',0, ...
    'raStarted',0,'raSuccess',0,'raFailed',0,'raUnfinished',0), ...
    'ueSummary',table((1:count).',zeros(count,1),zeros(count,1),zeros(count,1),zeros(count,1), ...
    'VariableNames',{'ueId','created','delivered','dropped','unfinished'}), ...
    'kpiTimeSeries',obs(:,{'windowId','startTick','endTick'}), ...
    'resourceUsage',table("fixture",0,'VariableNames',{'resource','units'}), ...
    'dataset',dataset, ...
    'profiling',struct('elapsedSeconds',0));
diagnostics=table(repmat(id,2,1),(1:2).',[0;500],[500;1000], ...
    [1;0],[2;0],[1;0],[2;0],[1;0],[1;1],[490;NaN],[1;0], ...
    [0;1],[0;1],[1;1],[1;1],[1;1],[1;1],[1;0],[1000;1000], ...
    'VariableNames',{'realizationId','windowId','startTick','endTick', ...
    'logicalCollisionGroups','logicalCollidingAttempts','physicalOverlapPairs', ...
    'physicalCollidingAttempts','successfulAccesses','raRetryTransmissions', ...
    'meanDelayTicks','delaySampleCount','unfinishedAccessCohort', ...
    'unfinishedPacketCohort','logicalAvailable','physicalAvailable', ...
    'accessAvailable','retryAvailable','delayAvailable','outcomeHorizonTick'});
if ~isfield(options,'omitDiagnostics')||~options.omitDiagnostics
    dataset.diagnostics=diagnostics;
end
result.dataset=dataset;
metadata=struct('caseKey',sprintf('fixture-%d-%d',id,count), ...
    'configSha256',nbiot.results.configSha256(cfg),'sourceSha256',repmat('b',1,64), ...
    'calibrationSha256',repmat('a',1,64),'environment',environment);
file=nbiot.results.saveResult(result,fullfile(root,metadata.caseKey),metadata);
end

function found=rewriteDiagnostics(caseFolder,mode)
found=false;
markerPath=fullfile(caseFolder,'case-complete.json');
marker=jsondecode(fileread(markerPath));
at=find(contains(string({marker.tables.file}),'_diagnostics.csv'),1);
if isempty(at), return; end
record=marker.tables(at);
path=fullfile(caseFolder,record.file);
if ~isfile(path), return; end
diagnostics=readtable(path,'VariableNamingRule','preserve');
switch mode
    case 'shift-start'
        diagnostics.startTick(1)=diagnostics.startTick(1)+1;
    case 'delete-row'
        diagnostics(1,:)=[];
    case 'duplicate-row'
        diagnostics(end+1,:)=diagnostics(1,:);
    otherwise
        error('test:UnknownMutation','Unknown diagnostics fixture mutation.');
end
writetable(diagnostics,path);
record.rows=height(diagnostics);
record.variableNames=diagnostics.Properties.VariableNames;
marker.tables(contains(string({marker.tables.file}),'_diagnostics.csv'))=record;
fileAt=find(strcmp({marker.files.name},record.file),1);
bytes=dir(path); marker.files(fileAt).bytes=bytes.bytes;
marker.files(fileAt).sha256=sha256(path);
writeText(markerPath,jsonencode(marker));
found=true;
end

function digest=sha256(path)
md=java.security.MessageDigest.getInstance('SHA-256'); fid=fopen(path,'rb');
assert(fid>=0,'test:FixtureRead','Could not open fixture file.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
while ~feof(fid), md.update(typecast(fread(fid,1024*1024,'*uint8'),'int8')); end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function writeText(path,value)
fid=fopen(path,'wb'); assert(fid>=0,'test:FixtureWrite','Could not update fixture marker.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function path=writeRoleRegistry(root,ids,roles)
assignments=repmat(struct('role','','ids',0,'status','completed'),numel(ids),1);
for k=1:numel(ids)
    assignments(k).role=char(roles(k)); assignments(k).ids=double(ids(k));
end
registry=struct('schemaVersion',1,'assignments',assignments, ...
    'reservations',struct('role',{},'range',{}));
path=fullfile(root,'registry.json'); fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not create registry fixture.');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(registry),'UTF-8'),'uint8');
end
