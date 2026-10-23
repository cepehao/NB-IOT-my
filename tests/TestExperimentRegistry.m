classdef TestExperimentRegistry < matlab.unittest.TestCase
    methods (Test)
        function availableIdsExcludeRangesAndAssignments(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            nbiot.experiments.registerRealizationUse(file,'development',[20 21],'fixture','completed');
            ids=nbiot.experiments.availableRealizationIds(file,'training',0:30);
            t.verifyEqual(ids,[10:19 22:30]);
        end
        function rejectsCrossRoleReuseAndReservedIds(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            nbiot.experiments.registerRealizationUse(file,'development',20,'fixture','completed');
            t.verifyError(@() nbiot.experiments.registerRealizationUse(file,'training',20,'second use'),...
                'nbiot:experiments:RegistryConflict');
            t.verifyError(@() nbiot.experiments.registerRealizationUse(file,'training',5,'reserved'),...
                'nbiot:experiments:RegistryConflict');
        end
        function rejectsUnknownRoleAndOutOfRangeIds(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            t.verifyError(@() nbiot.experiments.availableRealizationIds(file,'unknown',10:20),...
                'nbiot:experiments:RegistryRole');
            t.verifyError(@() nbiot.experiments.registerRealizationUse(file,'training',4096,'fixture'),...
                'nbiot:experiments:RegistryIds');
        end
        function closesPlannedAllocationWithoutReusingItsIds(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            nbiot.experiments.registerRealizationUse(file,'development',[20 21],'fixture','planned');
            nbiot.experiments.updateRealizationUseStatus(file,'development',[20 21],'completed');
            ids=nbiot.experiments.availableRealizationIds(file,'training',10:30);
            t.verifyEqual(ids,[10:19 22:30]);
        end
        function failedAllocationsRemainReserved(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            nbiot.experiments.registerRealizationUse(file,'development',[20 21],'failed fixture','failed');
            ids=nbiot.experiments.availableRealizationIds(file,'training',10:30);
            t.verifyEqual(ids,[10:19 22:30]);
        end
        function reconcilesFailedAllocationOnlyWithRecoveryAudit(t)
            file=makeRegistry(); cleanup=onCleanup(@() removeRegistry(file)); %#ok<NASGU>
            nbiot.experiments.registerRealizationUse(file,'development',[20 21],'physical run','failed');
            nbiot.experiments.registerRealizationUse(file,'validation',[23 24],'receiver run','failed');
            t.verifyError(@() nbiot.experiments.reconcileFailedRealizationUse(...
                file,'development',[20 21],'recovery','not-a-sha','reconstructed report'),...
                'nbiot:experiments:Recovery');
            digest=repmat('a',1,64);
            nbiot.experiments.reconcileFailedRealizationUse(...
                file,'development',[20 21],'recovery',digest,...
                'All saved physical artifacts were validated and the missing replay was rerun.');
            digest2=repmat('b',1,64);
            nbiot.experiments.reconcileFailedRealizationUse(...
                file,'validation',[23 24],'recovery',digest2,...
                'The receiver matrix was revalidated from saved measurements.');
            registry=jsondecode(fileread(file));
            t.verifyEqual(registry.assignments(1).status,'completed');
            t.verifyEqual(registry.assignments(1).recovery.evidenceManifestSha256,digest);
            t.verifyEqual(registry.assignments(1).recovery.source,'recovery');
            t.verifyEqual(registry.assignments(2).status,'completed');
            t.verifyEqual(registry.assignments(2).recovery.evidenceManifestSha256,digest2);
            t.verifyEqual(nbiot.experiments.availableRealizationIds(file,'training',20:24),22);
            nbiot.experiments.registerRealizationUse(file,'training',22,'after recovery','planned');
            registry=jsondecode(fileread(file));
            t.verifyEqual(registry.assignments(3).status,'planned');
            t.verifyEmpty(registry.assignments(3).recovery);
        end
    end
end

function file=makeRegistry()
folder=tempname; mkdir(folder); file=fullfile(folder,'registry.json');
registry=struct('schemaVersion',1,'validRange',[0 4095],...
    'roles',{{'development','training','validation'}},...
    'reservations',struct('role','legacy','range',[0 9],'source','fixture','note','reserved'),...
    'assignments',[]);
fid=fopen(file,'w','n','UTF-8'); bytes=unicode2native(jsonencode(registry),'UTF-8'); fwrite(fid,bytes,'uint8'); fclose(fid);
end

function removeRegistry(file)
folder=fileparts(file); if isfolder(folder), rmdir(folder,'s'); end
end
