function lockCleanup=acquireRealizationRegistryLock(registryFile)
%ACQUIREREALIZATIONREGISTRYLOCK Serialize registry read/check/write operations.
lockFolder=[char(registryFile) '.lock']; lock=java.io.File(lockFolder); clock=tic;
while ~lock.mkdir()
    if toc(clock)>=30
        error('nbiot:experiments:RegistryLocked',...
            'Could not acquire registry lock %s; inspect active writers and stale lock folders.',lockFolder);
    end
    pause(.05);
end
lockCleanup=onCleanup(@() releaseLock(lockFolder));
end

function releaseLock(lockFolder)
lock=java.io.File(lockFolder);
if lock.exists() && ~lock.delete()
    warning('nbiot:experiments:RegistryLockCleanup',...
        'Could not release registry lock folder %s.',lockFolder);
end
end
