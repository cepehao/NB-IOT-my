classdef RaContextStore < handle
    %RACONTEXTSTORE Контексты процедуры RA на стороне BS (ТЗ §18–19) — по одному на обнаруженную преамбулу.
    %   BS знает только то, что приняла по радио: NInit, возможность, оценку задержки, позже — token из
    %   Msg3. Истинных UE и числа конкурентов здесь нет (при коллизии один контекст на нескольких UE).
    %   Temporary C-RNTI = 255 + номер контекста.
    properties (SetAccess=private)
        % Поля контекста: id, rnti; nInit, occasionId — откуда обнаружена преамбула; state — этап на BS
        % (RAR_PENDING, MSG3_RX, MSG4_PENDING, MSG4_ACK, DATA_PENDING, DATA_RX, RECEIPT_PENDING,
        % RECEIPT_ACK, *_RETRY, DONE, FAILED, EXPIRED); deadlineTick; token, sequence — из Msg3;
        % nextFragment, ndi, harqTry, softBuffer — передача данных и HARQ; pending — ждёт назначения;
        % schedule — последние выданные назначения; receiptAttempts; dataComplete; delaySeconds — оценка
        % задержки по NPRACH (для timing advance в RAR).
        entries = struct('id',{},'rnti',{},'nInit',{},'occasionId',{},'state',{}, ...
            'deadlineTick',{},'token',{},'sequence',{},'nextFragment',{},'ndi',{}, ...
            'harqTry',{},'softBuffer',{},'pending',{},'schedule',{}, ...
            'receiptAttempts',{},'lastProgressTick',{},'dataComplete',{},'delaySeconds',{})
    end
    methods
        %CREATE Новый контекст для обнаруженной преамбулы NINIT на возможности OCCASIONID.
        function id=create(obj,nInit,occasionId,deadlineTick,delaySeconds)
            % Номер нового контекста — следующий по порядку.
            id=numel(obj.entries)+1;
            % Пул временных C-RNTI ограничен (255 + номер < 65536) — при исчерпании ошибка.
            if id>65000, error('nbiot:ra:RntiExhausted','Temporary RNTI pool exhausted.'); end
            % Новый контекст: Temp C-RNTI = 255 + номер; преамбула и возможность; состояние RAR_PENDING (готовить RAR);
            % дедлайн окна RAR; token и sequence появятся из Msg3; данные — с 1-го фрагмента, NDI 0, 1-я передача HARQ;
            % ждёт назначения (pending); оценка задержки NPRACH — для timing advance.
            e=struct('id',id,'rnti',255+id,'nInit',nInit,'occasionId',occasionId, ...
                'state','RAR_PENDING','deadlineTick',deadlineTick,'token',uint64(0), ...
                'sequence',0,'nextFragment',1,'ndi',0,'harqTry',1,'softBuffer',[], ...
                'pending',true,'schedule',[],'receiptAttempts',0,'lastProgressTick',0, ...
                'dataComplete',false,'delaySeconds',delaySeconds);
            % Добавляем контекст в конец массива.
            obj.entries(end+1)=e;
        end
        %GET/SET Чтение и запись контекста по номеру; FINDRNTI — номер контекста по C-RNTI (0, если нет).
        % Возвращает контекст по номеру.
        function e=get(obj,id), e=obj.entries(id); end
        % Записывает изменённый контекст.
        function set(obj,id,e), obj.entries(id)=e; end
        % Поиск контекста по C-RNTI:
        function id=findRnti(obj,rnti)
            % первый контекст с этим RNTI; если нет — 0.
            id=find([obj.entries.rnti]==rnti,1); if isempty(id), id=0; end
        end
    end
end
