function result=finalizeResult(cfg,scenario,packets,attempts,observed,truth,usage,actualTick,status,stopReason,errorInfo,deviceStates)
%FINALIZERESULT Export completed, partial and failed runs without fake drops.
%   Сборка базового struct результата (ТЗ §47) для завершённого, частичного или неудачного прогона.
result=struct('config',cfg,'scenario',scenario,'status',status,'stopReason',stopReason, ...
    'actualTick',actualTick,'error',errorInfo,'randomness',scenario.randomManifest);
result.resultSchemaVersion=2;
sourceProfile='static-v1';
if isfield(cfg,'policy')&&isfield(cfg.policy,'name')&& ...
        ~strcmp(char(string(cfg.policy.name)),'Static')
    sourceProfile='adaptive-development';
end
result.environment=struct('matlabVersion',version,'release',version('-release'),'lteVersion',ver('lte'), ...
    'computer',computer,'validatedInMatlab',false,'sourceProfile',sourceProfile);
result.packetLog=packets; result.raLog=attempts; result.observedLog=observed; result.truthLog=truth;
result.phyLog=[observed(strcmp({observed.kind},'phy_decode'));truth(strcmp({truth.kind},'phy_decode'))];
result.kpiSummary=nbiot.metrics.summarizeKpi(cfg,packets,attempts,observed,truth,usage,actualTick);
result.kpiTimeSeries=nbiot.metrics.windowKpi(cfg,packets,attempts,observed,actualTick);
result.ueSummary=nbiot.results.buildUeSummary(cfg,scenario,packets,attempts,deviceStates);
referenceBands=unique(result.ueSummary.referenceBandwidthHz);
if numel(referenceBands)~=1||~isfinite(referenceBands)||referenceBands<=0
    error('nbiot:results:NetworkBandwidth', ...
        'The result must have one finite positive network reference bandwidth.');
end
result.network=struct('carrierFrequencyHz',double(cfg.channel.carrierHz), ...
    'bandwidthHz',double(referenceBands));
result.resourceUsage=usage;
end
