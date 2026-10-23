function result=finalizeCheckpointResult(resultFcn,progressFile,update)
%FINALIZECHECKPOINTRESULT Publish finalizing before invoking the result callback.
update.phase='result-finalizing'; update.status='running';
update.errorIdentifier=''; update.failedPhase='';
nbiot.experiments.writeRuntimeProgress(progressFile,update);
try
    % Match the wrapper caller's output request. In particular, @()error(...)
    % must execute its body rather than fail an output-arity check first.
    % Each branch invokes the callback exactly once; never retry a callback.
    if nargout==0
        resultFcn();
        result=[];
    else
        result=resultFcn();
    end
catch exception
    update.phase='failed'; update.status='failed';
    update.failedPhase='result-finalizing'; update.errorIdentifier=exception.identifier;
    nbiot.experiments.writeRuntimeProgress(progressFile,update);
    rethrow(exception);
end
end
