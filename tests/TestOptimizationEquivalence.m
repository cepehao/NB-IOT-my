classdef TestOptimizationEquivalence < matlab.unittest.TestCase
    methods (Test)
        function identicalBundlesPass(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFixture(folder));
            baseline=makeBundle(folder,'baseline'); candidate=makeBundle(folder,'candidate');

            report=verifyOptimization(baseline,candidate,fullfile(folder,'report'));

            t.verifyTrue(report.passed,evalc('disp(report.checks)'));
            t.verifyEmpty(report.errors);
        end

        function changedPayloadFails(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFixture(folder));
            baseline=makeBundle(folder,'baseline'); candidate=makeBundle(folder,'candidate');
            b=load(candidate,'result','metadata');
            b.result.packetLog.payload(1)=uint8(99);
            result=b.result; metadata=b.metadata; save(candidate,'result','metadata');

            report=verifyOptimization(baseline,candidate,fullfile(folder,'payload-report'));

            t.verifyFalse(report.passed);
            t.verifyTrue(any(strcmp({report.checks.name},'result.packetLog') & ~[report.checks.passed]));
        end

        function changedResourceUsageFails(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFixture(folder));
            baseline=makeBundle(folder,'baseline'); candidate=makeBundle(folder,'candidate');
            b=load(candidate,'result','metadata');
            b.result.resourceUsage(1)=b.result.resourceUsage(1)+1;
            result=b.result; metadata=b.metadata; save(candidate,'result','metadata');

            report=verifyOptimization(baseline,candidate,fullfile(folder,'resource-report'));

            t.verifyFalse(report.passed);
            t.verifyTrue(any(strcmp({report.checks.name},'result.resourceUsage') & ~[report.checks.passed]));
        end
    end
end

function bundlePath=makeBundle(folder,name)
exportFolder=fullfile(folder,[name '-exports']); mkdir(exportFolder);
suffixes={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv','_resources.csv','_split.csv'};
for k=1:numel(suffixes)
    fid=fopen(fullfile(exportFolder,['fixture' suffixes{k}]),'wb');
    fwrite(fid,uint8(sprintf('fixture,%d\n',k)),'uint8'); fclose(fid);
end
result=struct('config',struct('simulation',struct('seed',42,'realizationId',0)), ...
    'scenario',struct('realizationId',0),'status','completed','actualTick',10, ...
    'stopReason','horizon','error',[],'packetLog',struct('payload',uint8([7 8])), ...
    'raLog',uint16([1 2]),'observedLog',uint16([3 4]),'truthLog',uint16([5 6]), ...
    'phyLog',uint16([7 8]),'kpiSummary',uint16([9 10]),'kpiTimeSeries',uint16([11 12]), ...
    'resourceUsage',uint16([13 14]),'dataset',uint16([15 16]));
metadata=struct('caseId','fixture','calibrationSha256',repmat('a',1,64), ...
    'environment',struct('matlabVersion',version,'release',version('-release'),'lteVersion','LTE 25.2'), ...
    'sourceManifest',struct('sha256',repmat('b',1,64)), ...
    'exportDirectory',exportFolder,'exportStem','fixture');
bundlePath=fullfile(folder,[name '.mat']); save(bundlePath,'result','metadata');
end

function removeFixture(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
