function summary=buildUeSummary(cfg,scenario,packets,attempts,deviceStates)
%BUILDUESUMMARY Combine per-UE scenario, radio-access and service outcomes.
%   Таблица по UE (ТЗ §47 Per-UE): геометрия, потери, мощности, SNR, CFO, попытки, итог обслуживания.
% Проверенная конфигурация.
cfg=nbiot.config.validateConfig(cfg);
% Число UE.
n=cfg.simulation.numUE;
% Сценарий должен содержать ровно N UE;
if ~isstruct(scenario)||~isfield(scenario,'ue')||numel(scenario.ue)~=n|| ...
        ~isequal(double([scenario.ue.ueId]),1:n)
    % иначе ошибка.
    error('nbiot:results:UeSummaryScenario', ...
        'Scenario must contain one ordered UE record per configured device.');
end
% Состояния устройств не переданы —
if nargin<5||isempty(deviceStates)
    % пустые строки.
    deviceStates=repmat({''},n,1);
end
% Состояния столбцом string.
deviceStates=string(deviceStates(:));
% Должно быть N состояний без пропусков.
if numel(deviceStates)~=n||any(ismissing(deviceStates))
    error('nbiot:results:UeSummaryStates', ...
        'One nonmissing final device state is required per UE.');
end

% UE сценария столбцом.
ue=scenario.ue(:);
% Бюджеты линий для всех UE.
links=nbiot.channel.evaluateLinks(cfg,ue);
% Счётчики пакетов по UE.
created=zeros(n,1); delivered=created; dropped=created; unfinished=created;
% Для каждого пакета:
for k=1:numel(packets)
    % проверенный номер UE;
    id=checkedUeId(packets(k).ueId,n);
    % создан +1;
    created(id)=created(id)+1;
    % по статусу:
    switch char(string(packets(k).status))
        % доставлен;
        case 'delivered', delivered(id)=delivered(id)+1;
        % отброшен;
        case 'dropped', dropped(id)=dropped(id)+1;
        % не завершён;
        case 'unfinished', unfinished(id)=unfinished(id)+1;
        otherwise
            % иной статус — ошибка.
            error('nbiot:results:UeSummaryPacketStatus', ...
                'Unexpected terminal packet status for UE summary.');
    end
end
% Счётчики попыток RA по UE.
raAttempts=zeros(n,1); raSuccesses=raAttempts; raFailures=raAttempts; raUnfinished=raAttempts;
% Для каждой попытки:
for k=1:numel(attempts)
    % проверенный номер UE;
    id=checkedUeId(attempts(k).ueId,n);
    % попытка +1;
    raAttempts(id)=raAttempts(id)+1;
    % по статусу:
    switch char(string(attempts(k).status))
        % успех;
        case 'success', raSuccesses(id)=raSuccesses(id)+1;
        % неуспех;
        case 'failure', raFailures(id)=raFailures(id)+1;
        % не завершена;
        case {'unfinished','started'}, raUnfinished(id)=raUnfinished(id)+1;
        otherwise
            % иной статус — ошибка.
            error('nbiot:results:UeSummaryAttemptStatus', ...
                'Unexpected random-access status for UE summary.');
    end
end

% Итог по UE.
outcome=strings(n,1);
% Для каждого UE:
for id=1:n
    % пакетов не было —
    if created(id)==0
        % no-packets;
        outcome(id)="no-packets";
    % баланс не сходится —
    elseif created(id)~=delivered(id)+dropped(id)+unfinished(id)
        % inconsistent;
        outcome(id)="inconsistent";
    else
        % иначе по распределению статусов:
        counts=[delivered(id),dropped(id),unfinished(id)];
        % несколько разных —
        if nnz(counts)>1
            % mixed;
            outcome(id)="mixed";
        % только доставленные —
        elseif delivered(id)>0
            % delivered;
            outcome(id)="delivered";
        % только отброшенные —
        elseif dropped(id)>0
            % dropped;
            outcome(id)="dropped";
        else
            % только незавершённые.
            outcome(id)="unfinished";
        end
    end
end

% Номера UE.
ids=(1:n).';
% Таблица: координаты, indoor, бюджет линии, счётчики, итог, состояние.
summary=table(ids,[ue.xM].',[ue.yM].',logical([ue.indoor].'), ...
    [ue.horizontalDistanceM].',[ue.distanceM].',[ue.medianPathLossDb].', ...
    [ue.shadowingDb].',[ue.penetrationDb].',[ue.pathLossDb].', ...
    [ue.cfoHz].',[ue.syncOffsetSeconds].',string({ue.coverageClass}.'), ...
    [links.receivedPowerUlDbm].',[links.receivedPowerDlDbm].', ...
    [links.noisePsdBsWPerHz].',[links.noisePsdUeWPerHz].', ...
    [links.referenceBandwidthHz].',[links.referenceSnrUlDb].', ...
    [links.referenceSnrDlDb].',created,delivered,dropped,unfinished, ...
    raAttempts,raSuccesses,raFailures,raUnfinished,deviceStates,outcome, ...
    'VariableNames',{'ueId','xM','yM','indoor','horizontalDistanceM', ...
    'distanceM','medianPathLossDb','shadowingDb','penetrationDb','pathLossDb', ...
    'cfoHz','syncOffsetSeconds','coverageClass','receivedPowerUlDbm', ...
    'receivedPowerDlDbm','noisePsdBsWPerHz','noisePsdUeWPerHz', ...
    'referenceBandwidthHz','referenceSnrUlDb','referenceSnrDlDb', ...
    'created','delivered','dropped','unfinished','raAttempts','raSuccesses', ...
    'raFailures','raUnfinished','deviceStateAtEnd','serviceOutcome'});
end

%CHECKEDUEID Проверка номера UE (целое 1..N).
function id=checkedUeId(value,n)
% Номер — конечное целое от 1 до N;
if ~(isnumeric(value)&&isscalar(value)&&isfinite(double(value))&& ...
        double(value)==fix(double(value))&&double(value)>=1&&double(value)<=n)
    % иначе ошибка.
    error('nbiot:results:UeSummaryId','A result log has an invalid UE identifier.');
end
% Как double.
id=double(value);
end
