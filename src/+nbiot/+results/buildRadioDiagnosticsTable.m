function output=buildRadioDiagnosticsTable(result)
%BUILDRADIODIAGNOSTICSTABLE Flatten radio diagnostics for CSV export.
%   Радиодиагностика в плоскую таблицу для экспорта CSV.
names={'scope','measurement','occasionId','attemptId','otherAttemptId', ...
    'ueId','nInit','contextId','channel','numerator','denominator','value', ...
    'unit','estimate','configured','error','provenance'};
types={'string','string','double','double','double','double','double', ...
    'double','string','double','double','double','string','double', ...
    'double','double','string'};
output=table('Size',[0 numel(names)],'VariableTypes',types,'VariableNames',names);
if ~isstruct(result)||~isscalar(result)||~isfield(result,'radioDiagnostics')|| ...
        ~isstruct(result.radioDiagnostics)||~isscalar(result.radioDiagnostics)
    return;
end
d=result.radioDiagnostics;
if isfield(d,'preamble')
    p=d.preamble;
    for field={'transmittedAttempts','transmittedKeys','detectedCandidates', ...
            'detectedKeys','misses','falseAlarms','falseAlarmOpportunities'}
        if isfield(p,field{1}), output=addCount(output,'preamble',field{1},p.(field{1}),'count'); end
    end
    output=addRatio(output,'preamble','detectionProbability', ...
        p.detectedKeys,p.transmittedKeys,p.detectionProbability,'probability');
    output=addRatio(output,'preamble','missProbability', ...
        p.misses,p.transmittedKeys,p.missProbability,'probability');
    output=addRatio(output,'preamble','falseAlarmProbability', ...
        p.falseAlarms,p.falseAlarmOpportunities,p.falseAlarmProbability,'probability');
end
if isfield(d,'collision')
    c=d.collision;
    for field={'logicalGroups','logicalAttempts','physicalOverlapPairs','physicalAttempts'}
        if isfield(c,field{1}), output=addCount(output,'collision',field{1},c.(field{1}),'count'); end
    end
    output=addRatio(output,'collision','logicalAttemptProbability', ...
        c.logicalAttempts,c.attempts,c.logicalAttemptProbability,'probability');
    output=addRatio(output,'collision','physicalAttemptProbability', ...
        c.physicalAttempts,c.attempts,c.physicalAttemptProbability,'probability');
end
if isfield(d,'capture')
    c=d.capture;
    for field={'eligiblePairs','censoredPairs','equalPowerPairs','capturedPairs'}
        if isfield(c,field{1}), output=addCount(output,'capture',field{1},c.(field{1}),'pairs'); end
    end
    output=addRatio(output,'capture','captureProbability', ...
        c.capturedPairs,c.eligiblePairs,c.probability,'probability');
end
if isfield(d,'perAttempt')
    for k=1:numel(d.perAttempt)
        a=d.perAttempt(k);
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',NaN,'channel','NPRACH');
        output=addAttempt(output,identity,'receivedPowerW',a.receivedPowerW,'W',a.provenance);
        output=addAttempt(output,identity,'interferencePowerW',a.interferencePowerW,'W',a.provenance);
        output=addAttempt(output,identity,'noisePowerW',a.noisePowerW,'W',a.provenance);
        output=addAttempt(output,identity,'sinrDb',a.sinrDb,'dB',a.provenance);
    end
end
if isfield(d,'receiverEstimates')
    for k=1:numel(d.receiverEstimates)
        a=d.receiverEstimates(k);
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',NaN,'channel','NPRACH');
        output=addEstimate(output,identity,'delay',a.estimatedDelaySeconds, ...
            a.configuredDelaySeconds,a.delayErrorSeconds,'s');
        output=addEstimate(output,identity,'cfo',a.estimatedCfoHz, ...
            a.configuredCfoHz,a.cfoErrorHz,'Hz');
    end
end
if isfield(d,'npuschReceiverEstimates')
    for k=1:numel(d.npuschReceiverEstimates)
        a=d.npuschReceiverEstimates(k);
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',a.contextId,'channel',a.channel);
        output=addEstimate(output,identity,'delay',a.estimatedDelaySeconds, ...
            a.configuredDelaySeconds,a.delayErrorSeconds,'s');
        output=addEstimate(output,identity,'cfo',a.estimatedCfoHz, ...
            a.configuredCfoHz,a.cfoErrorHz,'Hz');
        output=addAttempt(output,identity,'noiseEstimate',a.noiseEstimate,'receiver units','receiver');
    end
end
end

function output=addCount(output,scope,measurement,value,unit)
output=[output;makeRow(scope,measurement,NaN,NaN,NaN,NaN,NaN,NaN,'', ...
    value,1,value,unit,NaN,NaN,NaN,'diagnostic')]; %#ok<AGROW>
end

function output=addRatio(output,scope,measurement,numerator,denominator,value,unit)
output=[output;makeRow(scope,measurement,NaN,NaN,NaN,NaN,NaN,NaN,'', ...
    numerator,denominator,value,unit,NaN,NaN,NaN,'diagnostic')]; %#ok<AGROW>
end

function output=addAttempt(output,identity,measurement,value,unit,provenance)
output=[output;makeRow('attempt',measurement,identity.occasionId, ...
    identity.attemptId,NaN,identity.ueId,identity.nInit, ...
    identity.contextId,identity.channel,NaN,NaN,value,unit,NaN,NaN,NaN,provenance)]; %#ok<AGROW>
end

function output=addEstimate(output,identity,measurement,estimate,configured,error,unit)
output=[output;makeRow('receiver-estimate',measurement,identity.occasionId, ...
    identity.attemptId,NaN,identity.ueId,identity.nInit, ...
    identity.contextId,identity.channel,NaN,NaN,estimate,unit, ...
    estimate,configured,error,'receiver')]; %#ok<AGROW>
end

function row=makeRow(scope,measurement,occasionId,attemptId,otherAttemptId, ...
        ueId,nInit,contextId,channel,numerator,denominator,value,unit, ...
        estimate,configured,error,provenance)
row=table(string(scope),string(measurement),occasionId,attemptId,otherAttemptId, ...
    ueId,nInit,contextId,string(channel),numerator,denominator,value, ...
    string(unit),estimate,configured,error,string(provenance), ...
    'VariableNames',{'scope','measurement','occasionId','attemptId', ...
    'otherAttemptId','ueId','nInit','contextId','channel','numerator', ...
    'denominator','value','unit','estimate','configured','error','provenance'});
end
