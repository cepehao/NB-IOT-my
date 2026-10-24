function result=finalizeResult(cfg,scenario,packets,attempts,observed,truth,usage,actualTick,status,stopReason,errorInfo,deviceStates)
%FINALIZERESULT Export completed, partial and failed runs without fake drops.
%   Сборка базового struct результата (ТЗ §47) для завершённого, частичного или неудачного прогона.
% Struct результата: конфигурация, сценарий, статус, причина остановки, горизонт, ошибка, манифест случайности.
result=struct('config',cfg,'scenario',scenario,'status',status,'stopReason',stopReason, ...
    'actualTick',actualTick,'error',errorInfo,'randomness',scenario.randomManifest);
% Версия схемы результата.
result.resultSchemaVersion=2;
% Профиль источника по умолчанию — Static.
sourceProfile='static-v1';
% Политика не Static —
if isfield(cfg,'policy')&&isfield(cfg.policy,'name')&& ...
        ~strcmp(char(string(cfg.policy.name)),'Static')
    % профиль адаптивной разработки.
    sourceProfile='adaptive-development';
end
% Окружение: версии MATLAB и LTE Toolbox, компьютер, профиль.
result.environment=struct('matlabVersion',version,'release',version('-release'),'lteVersion',ver('lte'), ...
    'computer',computer,'validatedInMatlab',false,'sourceProfile',sourceProfile);
% Журналы: пакеты, попытки RA, наблюдения BS, истина.
result.packetLog=packets; result.raLog=attempts; result.observedLog=observed; result.truthLog=truth;
% Журнал PHY: события декодирования из наблюдений и истины.
result.phyLog=[observed(strcmp({observed.kind},'phy_decode'));truth(strcmp({truth.kind},'phy_decode'))];
% Итоговые KPI (ТЗ §27).
result.kpiSummary=nbiot.metrics.summarizeKpi(cfg,packets,attempts,observed,truth,usage,actualTick);
% KPI по окнам 500 мс.
result.kpiTimeSeries=nbiot.metrics.windowKpi(cfg,packets,attempts,observed,actualTick);
% Сводка по UE.
result.ueSummary=nbiot.results.buildUeSummary(cfg,scenario,packets,attempts,deviceStates);
% Опорная полоса сети по UE.
referenceBands=unique(result.ueSummary.referenceBandwidthHz);
% Она должна быть одна, конечная и положительная;
if numel(referenceBands)~=1||~isfinite(referenceBands)||referenceBands<=0
    error('nbiot:results:NetworkBandwidth', ...
        'The result must have one finite positive network reference bandwidth.');
end
% параметры сети: несущая и полоса.
result.network=struct('carrierFrequencyHz',double(cfg.channel.carrierHz), ...
    'bandwidthHz',double(referenceBands));
% Учёт использования ресурсов.
result.resourceUsage=usage;
end
