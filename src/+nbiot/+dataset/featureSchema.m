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
% Версия схемы по умолчанию — 'bs-known-v2.0' (текущая).
if nargin<1||isempty(version), version='bs-known-v2.0'; end
% Строку string приводим к char.
if isstring(version)&&isscalar(version), version=char(version); end
% Версия — одна строка текста.
if ~ischar(version)||size(version,1)~=1
    error('nbiot:dataset:Schema','Feature schema version must be scalar text.');
end

% Пустая struct схемы.
s=struct();
% Номер версии схемы.
s.version=version;
% Столбцы наблюдений: 4 ключа окна + признаки BS версии 1: обнаруженные преамбулы, средняя и максимальная
% метрика детектора, энергия принятого NPRACH (Вт), декодирования UL и ошибки CRC, выданные RAR и
% grants, средняя очередь запросов BS.
s.observationNames={'realizationId','windowId','startTick','endTick','detectedCandidates', ...
    'meanPeakMetric','maxPeakMetric','meanRxEnergyW','ulTbDecodes','ulCrcFailures', ...
    'rarSent','grantsSent','pendingRequestsMean'};
% Столбцы target: 4 ключа + истина симулятора: среднее число UE в фазе RA (основной target),
% среднее число UE с работой, средняя очередь на UE, число Msg1, число UE, передавших Msg1.
s.targetNames={'realizationId','windowId','startTick','endTick','meanRaUe', ...
    'meanActiveUe','meanWaitingQueuePerUe','msg1Transmissions','uniqueMsg1Ue'};
% Виды событий журнала BS, из которых разрешено считать признаки.
s.allowedObservationKinds={'nprach_detection','phy_decode','rar_sent','grant','bs_queue'};
% Единицы измерения столбцов наблюдений (ms — тики по 1 мс).
s.units={'count','count','ms','ms','count','dimensionless','dimensionless','W', ...
    'count','count','count','count','count'};
% Когда значение становится известным BS: событие — момент окончания приёма или решения BS.
s.availability='Event tick is receiver completion or BS decision time; windows are [startTick,endTick).';
% Источники, которые запрещено использовать в признаках (истина симулятора, ТЗ §40).
s.excludedSources={'true UE queue','true collision labels','UE DL CRC outcomes','true channel taps','packet arrivals'};

% Дополнения по версии схемы:
switch version
    % старая версия 1 — без дополнений;
    case 'static-v1.0'
        % Historical schema retained for explicit reading of saved cases.
    % версия 2:
    case 'bs-known-v2.0'
        % + занятость RA и DT в UL и DL за окно и действовавшие в окне P и доля RA;
        s.observationNames=[s.observationNames, ...
            {'ulRaOccupancy','ulDtOccupancy','dlRaOccupancy','dlDtOccupancy', ...
            'accessProbability','raShare'}];
        % их единицы — доли (безразмерные);
        s.units=[s.units,repmat({'dimensionless'},1,6)];
        % уточнённое описание момента доступности.
        s.availability=['Event tick is receiver completion or BS decision time; windows are [startTick,endTick). ' ...
            'Occupancy counts reserved resource units only inside the closed window. ' ...
            'accessProbability and raShare are the settings that governed that window. ' ...
            'No values from after endTick are allowed.'];
    % Другая версия —
    otherwise
        error('nbiot:dataset:Schema','Unsupported feature schema version %s.',version);
end

% Для версии 2 —
if strcmp(version,'bs-known-v2.0')
    % первые 4 столбца — ключи окна;
    s.keyNames=s.observationNames(1:4);
    % остальные — признаки модели (вход оценщика);
    s.inputNames=s.observationNames(5:end);
    % основной target — meanRaUe.
    s.targetName='meanRaUe';
end
end
