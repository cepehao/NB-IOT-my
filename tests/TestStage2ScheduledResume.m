classdef TestStage2ScheduledResume < matlab.unittest.TestCase
    methods (Test)
        function budgetPauseKeepsVerifiedEvidenceAndPlannedIds(t)
            [folder,path,identity,cases,cleanup]=fixture(); %#ok<ASGLU>
            state=stage2PhysicalProgress('initialize',path,identity,cases);
            t.verifyEqual(state.assignedIds,[1401 1402]);
            state=stage2PhysicalProgress('start',path,'trial-01-id-1401');
            state=stage2PhysicalProgress('complete',path,'trial-01-id-1401', ...
                struct('value',17,'trace',[1 2 3]));
            state=stage2PhysicalProgress('pause',path);

            resumed=stage2PhysicalProgress('resume',path,identity,cases);

            t.verifyEqual(resumed.status,'running');
            t.verifyEqual(resumed.assignedIds(:).',[1401 1402]);
            t.verifyEqual(resumed.caseRecords(1).status,'completed');
            t.verifyEqual(resumed.caseRecords(2).status,'planned');
            payload=stage2PhysicalProgress('loadCase',path,'trial-01-id-1401');
            t.verifyEqual(payload.value,17);
            resumed=stage2PhysicalProgress('start',path,'trial-02-id-1402');
            resumed=stage2PhysicalProgress('complete',path,'trial-02-id-1402', ...
                struct('value',23,'trace',[4 5 6]));
            resumed=stage2PhysicalProgress('finish',path);
            t.verifyEqual(resumed.status,'completed');
            t.verifyEmpty(resumed.pendingCaseKeys);
        end

        function resumeRejectsDifferentScientificIdentity(t)
            [~,path,identity,cases,cleanup]=fixture(); %#ok<ASGLU>
            stage2PhysicalProgress('initialize',path,identity,cases);
            changed=identity; changed.calibrationSha256=repmat('b',1,64);

            t.verifyError(@() stage2PhysicalProgress('resume',path,changed,cases), ...
                'nbiot:stage2:ProgressIdentity');
        end

        function resumeRejectsChangedCompletedEvidence(t)
            [folder,path,identity,cases,cleanup]=fixture(); %#ok<ASGLU>
            stage2PhysicalProgress('initialize',path,identity,cases);
            stage2PhysicalProgress('start',path,'trial-01-id-1401');
            state=stage2PhysicalProgress('complete',path,'trial-01-id-1401', ...
                struct('value',17,'trace',[1 2 3]));
            stage2PhysicalProgress('pause',path);
            evidenceFile=fullfile(folder,cases(1).evidenceFile);
            fid=fopen(evidenceFile,'w'); fwrite(fid,'corrupt'); fclose(fid);

            t.verifyError(@() stage2PhysicalProgress('resume',path,identity,cases), ...
                'nbiot:stage2:ProgressEvidence');
        end
    end
end

function [folder,path,identity,cases,cleanup]=fixture()
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'verification','completion','stage-2'));
folder=tempname; mkdir(folder); cleanup=onCleanup(@() removeFolder(folder)); %#ok<NASGU>
path=fullfile(folder,'progress.json');
identity=struct('scope','stage2-physical-test','sourceManifestSha256',repmat('a',1,64), ...
    'calibrationSha256',repmat('c',1,64),'assignedIds',[1401 1402]);
cases=struct('caseKey',{'trial-01-id-1401','trial-02-id-1402'}, ...
    'kind',{'collision','collision'},'realizationId',{1401,1402}, ...
    'evidenceFile',{'trial-01-id-1401.mat','trial-02-id-1402.mat'});
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
