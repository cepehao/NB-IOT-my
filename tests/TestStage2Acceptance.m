classdef TestStage2Acceptance < matlab.unittest.TestCase
    methods (Test)
        function requiresTechnicalReviewRecord(t)
            t.verifyError(@() acceptStage2Evidence('', '', struct()),...
                'nbiot:stage2:ReviewRequired');
            review=technicalReview(); review.notes=' ';
            t.verifyError(@() acceptStage2Evidence('', '', review),...
                'nbiot:stage2:ReviewRequired');
            review=technicalReview(); review.reviewer='';
            t.verifyError(@() acceptStage2Evidence('', '', review),...
                'nbiot:stage2:ReviewRequired');
            review=technicalReview(); review.scope={'targeted-tests'};
            t.verifyError(@() acceptStage2Evidence('', '', review),...
                'nbiot:stage2:ReviewRequired');
        end
        function administrativeReviewChangesDoNotInvalidatePhysicalRun(t)
            root=projectRoot(); addpath(fullfile(root,'verification','completion','stage-2'));
            expected=struct('relativePath',{'src/simulator.m',...
                'verification/completion/stage-2/acceptStage2Evidence.m'},...
                'sha256',{repmat('a',1,64),repmat('b',1,64)});
            actual=expected; actual(2).sha256=repmat('c',1,64);
            t.verifyTrue(stage2PhysicalArtifactsMatch(expected,actual));
            actual(1).sha256=repmat('d',1,64);
            t.verifyFalse(stage2PhysicalArtifactsMatch(expected,actual));
        end
        function rejectsMissingEvidenceAfterReview(t)
            t.verifyError(@() acceptStage2Evidence('missing-targeted.log',...
                'missing-stage2-report.mat',technicalReview()),...
                'nbiot:stage2:Evidence');
        end
        function rejectsLegacyPhysicalEvidenceWithoutRunProvenance(t)
            root=projectRoot(); stageFolder=fullfile(root,'verification','completion','stage-2');
            sourceFolder=tempname(stageFolder); replayFolder=tempname(stageFolder);
            mkdir(sourceFolder); mkdir(replayFolder);
            cleanup=onCleanup(@() removeFolders(sourceFolder,replayFolder));
            writeText([sourceFolder '.log'],...
                'Known weak-UE CRC failure was not reproduced.');
            failure=[];
            try
                recoverStage2Physical(sourceFolder,replayFolder);
            catch exception
                failure=exception;
            end
            t.verifyNotEmpty(failure,'Legacy physical evidence must be rejected.');
            if ~isempty(failure)
                t.verifyEqual(failure.identifier,'nbiot:stage2:Recovery');
                t.verifyTrue(contains(failure.message,'physical-run-report.mat'),failure.message);
            end
        end
        function recoveryRejectsSiblingPathOutsideProjectRoot(t)
            root=projectRoot();
            sibling=[root '-archive-' char(java.util.UUID.randomUUID())];
            mkdir(sibling);
            cleanup=onCleanup(@() removeFolders(sibling,''));
            replayFolder=fullfile(root,'verification','completion','stage-2');
            failure=[];
            try
                recoverStage2Physical(sibling,replayFolder);
            catch exception
                failure=exception;
            end
            t.verifyNotEmpty(failure,'Sibling path must be rejected before evidence loading.');
            if ~isempty(failure)
                t.verifyEqual(failure.identifier,'nbiot:stage2:Recovery');
                t.verifyTrue(contains(failure.message,'inside the project root'),failure.message);
            end
        end
        function revalidationProvenanceMustMatchRunCalibrationAndRegistry(t)
            [runReport,manifest]=revalidationFixture();
            t.verifyError(@() validateStage2RevalidationProvenance(...
                runReport,manifest,'different-calibration',...
                runReport.revalidation.officialRegistrySha256AfterRun),...
                'nbiot:stage2:Provenance');
            t.verifyError(@() validateStage2RevalidationProvenance(...
                runReport,manifest,runReport.calibrationSha256,'different-registry'),...
                'nbiot:stage2:Provenance');
            validateStage2RevalidationProvenance(...
                runReport,manifest,runReport.calibrationSha256,...
                runReport.revalidation.officialRegistrySha256AfterRun);
            runReport.revalidation.previousReceiverIds=[21:30 41:50];
            manifest.previousReceiverIds=runReport.revalidation.previousReceiverIds;
            validateStage2RevalidationProvenance(...
                runReport,manifest,runReport.calibrationSha256,...
                runReport.revalidation.officialRegistrySha256AfterRun);
        end
        function revalidationProvenanceAcceptsJsonColumnVectors(t)
            [runReport,manifest]=revalidationFixture();
            manifest.collisionIds=manifest.collisionIds(:);
            manifest.previousReceiverIds=manifest.previousReceiverIds(:);
            manifest.freshReceiverIds=manifest.freshReceiverIds(:);
            validateStage2RevalidationProvenance(...
                runReport,manifest,runReport.calibrationSha256,...
                runReport.revalidation.officialRegistrySha256AfterRun);
            manifest.collisionIds(1)=manifest.collisionIds(1)+100;
            t.verifyError(@() validateStage2RevalidationProvenance(...
                runReport,manifest,runReport.calibrationSha256,...
                runReport.revalidation.officialRegistrySha256AfterRun),...
                'nbiot:stage2:Provenance');
        end
        function revalidationPreflightIsReadOnlyAndUsesPairedIds(t)
            root=projectRoot(); registryPath=fullfile(root,'experiments','realizationRegistry.json');
            before=fileread(registryPath); registry=jsondecode(before);
            hasFailedCollision=any(arrayfun(@(a)strcmp(a.role,'stage-2-collision-diagnostics')&&...
                strcmp(a.status,'failed'),registry.assignments));
            hasFailedReceiver=any(arrayfun(@(a)strcmp(a.role,'stage-2-receiver-diagnostics')&&...
                strcmp(a.status,'failed'),registry.assignments));
            if ~hasFailedCollision||~hasFailedReceiver
                t.verifyError(@() runStage2Revalidation(true),'nbiot:stage2:Revalidation');
                t.verifyEqual(fileread(registryPath),before,...
                    'An ineligible revalidation preflight must leave the registry unchanged.');
                return
            end
            oldCollision={}; oldReceiver=[];
            for k=1:numel(registry.assignments)
                assignment=registry.assignments(k);
                if strcmp(assignment.role,'stage-2-collision-diagnostics')&&strcmp(assignment.status,'failed')
                    oldCollision{end+1}=sort(double(assignment.ids(:).')); %#ok<AGROW>
                elseif strcmp(assignment.role,'stage-2-receiver-diagnostics')&&strcmp(assignment.status,'failed')
                    oldReceiver=[oldReceiver double(assignment.ids(:).')]; %#ok<AGROW>
                end
            end
            oldReceiver=sort(unique(oldReceiver));
            plan=runStage2Revalidation(true);
            t.verifyEqual(fileread(registryPath),before);
            t.verifyTrue(any(cellfun(@(ids)isequal(sort(plan.collisionIds),ids),oldCollision)));
            t.verifyEqual(numel(plan.freshReceiverIds),10);
            t.verifyEmpty(intersect(plan.freshReceiverIds,oldReceiver));
            t.verifyEmpty(intersect(plan.freshReceiverIds,plan.collisionIds));
            t.verifyFalse(isfile(fullfile(root,strrep(plan.temporaryRegistry,'/',filesep))));
            t.verifyFalse(isfolder(fullfile(root,strrep(plan.outputFolder,'/',filesep))));
        end
        function cleanHighSnrAndNoiseOnlyControlsMustPass(t)
            checks=receiverFixture();
            nbiot.experiments.validateStage2ReceiverChecks(checks);
            bad=checks; row=find(string(bad.condition)=="noise20",1);
            bad.ownDetected(row)=false; bad.miss(row)=true;
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(bad),...
                'nbiot:stage2:ReceiverEvidence');
            bad=checks; row=find(string(bad.condition)=="noiseOnly",1);
            bad.falseAlarm(row)=true;
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(bad),...
                'nbiot:stage2:ReceiverEvidence');
            bad=checks; rows=string(bad.condition)=="cfoMinus200";
            bad.estimatedCfoHz(rows)=0;
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(bad),...
                'nbiot:stage2:ReceiverEvidence');
            bad=checks; rows=string(bad.condition)=="delayPlus2us";
            bad.estimatedDelaySamples(rows)=bad.estimatedDelaySamples(rows)+2.1;
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(bad),...
                'nbiot:stage2:ReceiverEvidence');
            bad=checks; rows=string(bad.condition)=="delayPlus2us";
            cleanRows=string(bad.condition)=="clean";
            bad.estimatedDelaySamples(rows)=median(bad.estimatedDelaySamples(cleanRows));
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(bad),...
                'nbiot:stage2:ReceiverEvidence');
        end
        function incompleteReceiverMatrixIsRejected(t)
            checks=receiverFixture(); checks(end,:)=[];
            t.verifyError(@() nbiot.experiments.validateStage2ReceiverChecks(checks),...
                'nbiot:stage2:ReceiverEvidence');
        end
    end
end

function review=technicalReview()
review=struct('reviewer','/root/review_stage2',...
    'scope',{{'targeted-tests','physical-results','limitations'}},...
    'notes','Independent evidence review completed.');
end

function root=projectRoot()
root=fileparts(fileparts(mfilename('fullpath')));
end

function [runReport,manifest]=revalidationFixture()
sha=@(letter) repmat(letter,1,64);
revalidation=struct('mode','paired-rerun-after-cfo-detector-fix',...
    'collisionIdsReusedFromFailedRun',true,'collisionIds',1:10,...
    'previousReceiverIds',21:30,'freshReceiverIds',31:40,...
    'officialRegistrySha256BeforeRun',sha('a'),...
    'officialRegistrySha256AfterRun',sha('b'),...
    'officialRegistryBeforeSnapshot','physical-revalidation/official-registry-before-run.json',...
    'officialRegistryAfterSnapshot','physical-revalidation/official-registry-after-run.json',...
    'temporaryRegistry','verification/completion/stage-2/temp-registry.json',...
    'temporaryRegistrySha256',sha('c'),'sourceManifestSha256',sha('d'),...
    'calibrationSha256',sha('e'),'receiverRevision','group-partial-cfo-match-v3',...
    'matlabRelease','2025b');
runReport=struct('revalidation',revalidation,'calibrationSha256',revalidation.calibrationSha256,...
    'receiverRevision',revalidation.receiverRevision,...
    'sourceManifest',struct('sha256',revalidation.sourceManifestSha256));
runReport.matlabRelease=revalidation.matlabRelease;
manifest=revalidation;
end

function writeText(path,value)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'Could not write test fixture.');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(value,'UTF-8'),'uint8');
end

function removeFolders(varargin)
for k=1:nargin
    path=varargin{k};
    if ~isempty(path)&&isfolder(path), rmdir(path,'s'); end
end
end

function checks=receiverFixture()
kinds=["clean","noise20","noiseMinus20","cfoMinus200","cfoPlus200",...
    "delayMinus2us","delayPlus2us","noiseOnly"];
condition=strings(80,1); id=zeros(80,1); present=false(80,1); ownDetected=false(80,1);
miss=false(80,1); falseAlarm=false(80,1); estimatedDelaySamples=NaN(80,1);
estimatedCfoHz=NaN(80,1); actualDelaySamples=zeros(80,1); actualCfoHz=zeros(80,1);
at=0;
for kind=kinds
    signalPresent=kind~="noiseOnly";
    for realization=1000:1009
        at=at+1; condition(at)=kind; id(at)=realization; present(at)=signalPresent;
        ownDetected(at)=signalPresent;
        if signalPresent, estimatedDelaySamples(at)=.5; estimatedCfoHz(at)=0; end
        if kind=="cfoMinus200", actualCfoHz(at)=-200; end
        if kind=="cfoPlus200", actualCfoHz(at)=200; end
        if kind=="delayMinus2us", actualDelaySamples(at)=-2e-6*1920000; end
        if kind=="delayPlus2us", actualDelaySamples(at)=2e-6*1920000; end
        actualDelaySamples(at)=actualDelaySamples(at)+...
            (2*50/299792458)*1920000;
        if signalPresent
            estimatedDelaySamples(at)=actualDelaySamples(at);
            estimatedCfoHz(at)=actualCfoHz(at);
        end
    end
end
checks=table(condition,id,present,ownDetected,miss,falseAlarm,estimatedDelaySamples,...
    estimatedCfoHz,actualDelaySamples,actualCfoHz);
end
