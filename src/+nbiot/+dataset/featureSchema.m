function s=featureSchema(version)
%FEATURESCHEMA Схема датасета (ТЗ §21–22, §40): белый список признаков BS и целевых величин.
%   Признаки (observationNames, только то, что BS знает к концу окна):
%     ключи realizationId, windowId, startTick, endTick;
%     detectedCandidates — обнаруженные преамбулы; meanPeakMetric, maxPeakMetric — метрики детектора;
%     meanRxEnergyW — энергия принятого NPRACH (Вт); ulTbDecodes, ulCrcFailures — декодирования UL и
%     ошибки CRC; rarSent, grantsSent — выданные RAR и grants; pendingRequestsMean — очередь BS;
%     (v2) занятость RA/DT в UL/DL, действовавшие в окне P и доля RA.
%   Цели (targetNames, истина симулятора — только для обучения и оценки, НЕ признаки):
%     meanRaUe — среднее число UE в фазе RA (основной target), meanActiveUe, meanWaitingQueuePerUe,
%     msg1Transmissions, uniqueMsg1Ue.
%   excludedSources — что запрещено использовать в признаках (истинные очереди, коллизии, каналы).
if nargin<1||isempty(version), version='bs-known-v2.0'; end
if isstring(version)&&isscalar(version), version=char(version); end
if ~ischar(version)||size(version,1)~=1
    error('nbiot:dataset:Schema','Feature schema version must be scalar text.');
end

s=struct();
s.version=version;
s.observationNames={'realizationId','windowId','startTick','endTick','detectedCandidates', ...
    'meanPeakMetric','maxPeakMetric','meanRxEnergyW','ulTbDecodes','ulCrcFailures', ...
    'rarSent','grantsSent','pendingRequestsMean'};
s.targetNames={'realizationId','windowId','startTick','endTick','meanRaUe', ...
    'meanActiveUe','meanWaitingQueuePerUe','msg1Transmissions','uniqueMsg1Ue'};
s.allowedObservationKinds={'nprach_detection','phy_decode','rar_sent','grant','bs_queue'};
s.units={'count','count','ms','ms','count','dimensionless','dimensionless','W', ...
    'count','count','count','count','count'};
s.availability='Event tick is receiver completion or BS decision time; windows are [startTick,endTick).';
s.excludedSources={'true UE queue','true collision labels','UE DL CRC outcomes','true channel taps','packet arrivals'};

switch version
    case 'static-v1.0'
        % Historical schema retained for explicit reading of saved cases.
    case 'bs-known-v2.0'
        s.observationNames=[s.observationNames, ...
            {'ulRaOccupancy','ulDtOccupancy','dlRaOccupancy','dlDtOccupancy', ...
            'accessProbability','raShare'}];
        s.units=[s.units,repmat({'dimensionless'},1,6)];
        s.availability=['Event tick is receiver completion or BS decision time; windows are [startTick,endTick). ' ...
            'Occupancy counts reserved resource units only inside the closed window. ' ...
            'accessProbability and raShare are the settings that governed that window. ' ...
            'No values from after endTick are allowed.'];
    otherwise
        error('nbiot:dataset:Schema','Unsupported feature schema version %s.',version);
end

if strcmp(version,'bs-known-v2.0')
    s.keyNames=s.observationNames(1:4);
    s.inputNames=s.observationNames(5:end);
    s.targetName='meanRaUe';
end
end
