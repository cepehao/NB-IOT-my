classdef DeviceStore < handle
    %DEVICESTORE Протокольные состояния всех UE (ТЗ §12) — массив struct, не объект на UE.
    %   Состояния в коде и их соответствие ТЗ §12:
    %     IDLE        — нет пакета (IDLE)
    %     WAIT_RA     — ожидание возможности NPRACH (WAIT_RA → RA_TX при передаче Msg1)
    %     WAIT_RAR    — Msg1 передан, ожидание RAR (RA_PROCESSING / WAIT_RAR)
    %     WAIT_MSG4   — Msg3 передан, ожидание Msg4 (MSG3_TX / WAIT_CONTENTION_RESOLUTION)
    %     BACKOFF     — ожидание повторной попытки (BACKOFF)
    %     DATA        — доступ получен, ожидание grant и передача данных (WAIT_GRANT / DATA_TX)
    %     WAIT_RECEIPT— ожидание подтверждения доставки
    %   DONE и DROPPED ТЗ — это итоговый статус пакета в PacketStore; UE при этом возвращается в IDLE.
    %   Поля BS (CRC, контексты) здесь не хранятся: UE знает только то, что принял по радио.
    properties (SetAccess=private)
        % entries(N) — поля UE: state; packetId, attemptId, attemptNumber (попытки текущего пакета),
        % lifetimeAttempt (все попытки UE); occasionId, nInit (выбранная преамбула); token (идентификатор
        % конкуренции); rnti, raRnti; timingAdvanceSeconds; дедлайны в тиках (deadlineTick — окно RAR/Msg4,
        % nextAllowedTick — конец BACKOFF, progressDeadlineTick — данные); fragmentIndex, ndi, encoderState
        % (HARQ); raSucceeded; ulBusyStartTick/UntilTick — занятость UL (полудуплекс).
        entries
    end
    methods
        %DEVICESTORE Создаёт COUNT UE в состоянии IDLE.
        function obj=DeviceStore(count)
            % Шаблон записи UE в начальном состоянии: IDLE, нет пакета и попыток, NInit = −1 (не выбран),
            % дедлайны = Inf (не заданы), NDI = −1 (передач данных ещё не было), UL свободен (−Inf).
            entry=struct('state','IDLE','packetId',0,'attemptId',0,'attemptNumber',0, ...
                'lifetimeAttempt',0,'occasionId',0,'nInit',-1,'token',uint64(0), ...
                'rnti',0,'raRnti',0,'timingAdvanceSeconds',0,'deadlineTick',Inf, ...
                'monitorStartTick',Inf,'nextAllowedTick',0,'progressDeadlineTick',Inf, ...
                'fragmentIndex',0,'ndi',-1,'encoderState',[],'raSucceeded',false, ...
                'ulBusyStartTick',-Inf,'ulBusyUntilTick',-Inf);
            % Все COUNT устройств стартуют с одинаковой начальной записью (массив struct COUNT×1).
            obj.entries=repmat(entry,count,1);
        end
        %GET/SET Чтение и запись записи UE по номеру (1-based).
        % Возвращает запись UE по номеру (struct — копия значения).
        function entry=get(obj,ueId), entry=obj.entries(ueId); end
        % Записывает изменённую запись UE обратно в массив.
        function set(obj,ueId,entry), obj.entries(ueId)=entry; end
        %RESET Возврат UE в IDLE после завершения пакета; сохраняет счётчик попыток и занятость UL.
        function reset(obj,ueId)
            % Запоминаем счётчик всех попыток UE — он нужен для ключей случайности следующих попыток.
            lifetime=obj.entries(ueId).lifetimeAttempt;
            % Запоминаем интервал занятости UL: UE может ещё передавать ACK после завершения пакета.
            busyStart=obj.entries(ueId).ulBusyStartTick; busyEnd=obj.entries(ueId).ulBusyUntilTick;
            % Создаём чистую запись (как у нового UE) и подставляем её вместо текущей.
            fresh=nbiot.devices.DeviceStore(1); obj.entries(ueId)=fresh.entries;
            % Возвращаем сохранённый счётчик попыток.
            obj.entries(ueId).lifetimeAttempt=lifetime;
            % Возвращаем сохранённую занятость UL.
            obj.entries(ueId).ulBusyStartTick=busyStart; obj.entries(ueId).ulBusyUntilTick=busyEnd;
        end
        %COUNTS RA — число UE в фазе доступа (WAIT_RA, WAIT_RAR, WAIT_MSG4, BACKOFF); ACTIVE — не в IDLE.
        function [ra,active]=counts(obj)
            % Состояния всех UE строковым массивом.
            state=string({obj.entries.state});
            % Число UE в фазе случайного доступа (ждут возможность, RAR, Msg4 или в BACKOFF).
            ra=sum(ismember(state,["WAIT_RA","WAIT_RAR","WAIT_MSG4","BACKOFF"]));
            % Число UE, которые не в IDLE (заняты обслуживанием пакета).
            active=sum(state~="IDLE");
        end
    end
end
