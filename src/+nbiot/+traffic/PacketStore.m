classdef PacketStore < handle
    %PACKETSTORE Пакеты и очереди UE (ТЗ §11, §12, §30) — источник истины о доставке.
    %   Статусы пакета: pending → delivered (все фрагменты приняты BS, CRC OK — ТЗ §27.2) |
    %   dropped (overflow — очередь полна; ra_limit — 8 попыток RA; lifetime; progress_timeout) |
    %   unfinished (не завершён к горизонту). Баланс: created = delivered + dropped + unfinished.
    %   Доставка на BS и завершение у UE (localFinished, после квитанции) — разные факты и метки времени.
    %   Очередь UE (FIFO, лимит cfg.traffic.queueLimit) включает обслуживаемый пакет.
    properties (SetAccess=private)
        % packets — все пакеты реализации: id, UE, номер, биты, фрагменты TB (blocks), принятые фрагменты,
        % статус и причина, тики создания/доставки/завершения, число попыток RA.
        packets
        % Счётчики итогов: создано, доставлено, отброшено, не завершено, доставлено полезных бит.
        counters=struct('created',0,'delivered',0,'dropped',0,'unfinished',0,'deliveredPayloadBits',0)
    end
    properties (Access=private)
        % Проверенная конфигурация (размер пакета, лимит очереди, срок жизни).
        cfg
        % Очереди пакетов по UE: cell N×1, в каждой — номера пакетов в порядке FIFO.
        queues
        % Индекс: номер пакета (uint32) → позиция в массиве packets (быстрый поиск).
        index
        % Использованные номера пакетов (sequence) по каждому UE — для контроля повторов.
        sequences
    end
    methods
        %PACKETSTORE Пустое хранилище для конфигурации CFG.
        function obj=PacketStore(cfg)
            % Проверяем конфигурацию; создаём пустые очереди для всех UE.
            obj.cfg=nbiot.config.validateConfig(cfg); obj.queues=cell(cfg.simulation.numUE,1);
            % Пустые списки номеров sequence и пустой индекс номер пакета → позиция.
            obj.sequences=cell(cfg.simulation.numUE,1); obj.index=containers.Map('KeyType','uint32','ValueType','double');
            % Пустой массив пакетов со всеми полями записи пакета.
            obj.packets=struct('packetId',{},'ueId',{},'sequence',{},'payloadBits',{},'blocks',{},'map',{},'received',{},'status',{},'reason',{},'createdTick',{},'deliveredTick',{},'terminalTick',{},'attemptCount',{},'ueConfirmed',{},'localFinished',{},'localFinishedTick',{});
        end
        %ENQUEUE Ставит поступивший пакет A в очередь UE; при переполнении — сразу dropped/overflow.
        %   Пакет режется на фрагменты TB 256 бит (segmentPacket). ACCEPTED — принят ли в очередь.
        function accepted=enqueue(obj,a)
            % Номер пакета и номер UE; проверка, что UE существует.
            id=uint32(a.packetId); ue=double(a.ueId); obj.validateUE(ue);
            % Номер пакета — целое 1..2^32−1.
            validateattributes(a.packetId,{'numeric'},{'scalar','integer','positive','<=',2^32-1});
            % Номер пакета внутри UE (sequence) — 0..65535; тик создания — неотрицательное целое.
            validateattributes(a.sequence,{'numeric'},{'scalar','integer','>=',0,'<=',65535}); obj.tick(a.createdTick);
            % Один и тот же номер пакета дважды — ошибка.
            if isKey(obj.index,id), error('nbiot:traffic:DuplicatePacket','Packet ID already exists'); end
            % Повтор sequence у одного UE сделал бы квитанцию неоднозначной — ошибка.
            if any(obj.sequences{ue}==double(a.sequence)), error('nbiot:traffic:SequenceOverflow','Sequence reuse is ambiguous in static-v1'); end
            % Нарезка полезных бит на транспортные блоки 256 бит с заголовками (segmentPacket).
            [blocks,map]=nbiot.traffic.segmentPacket(a.payloadBits,a.sequence);
            % Длина полезной нагрузки должна совпадать с размером пакета из конфигурации (в битах).
            if numel(a.payloadBits)~=obj.cfg.traffic.packetBytes*8, error('nbiot:traffic:MalformedPacket','Payload length disagrees with config'); end
            % Запись пакета: номер, UE, sequence, биты, блоки, карта блоков, принятые блоки (пока пусто),
            % статус pending, тики (доставка/завершение — NaN), 0 попыток RA, ещё не завершён у UE.
            p=struct('packetId',id,'ueId',uint32(ue),'sequence',uint16(a.sequence),'payloadBits',int8(a.payloadBits(:)),'blocks',{blocks},'map',map,'received',{cell(numel(blocks),1)},'status','pending','reason','','createdTick',uint64(a.createdTick),'deliveredTick',NaN,'terminalTick',NaN,'attemptCount',0,'ueConfirmed',false,'localFinished',false,'localFinishedTick',NaN);
            % Пакет помещается, если в очереди UE меньше queueLimit пакетов (ТЗ §30: 10).
            accepted=numel(obj.queues{ue})<obj.cfg.traffic.queueLimit;
            % Помещается — номер в конец очереди UE; иначе пакет сразу отброшен (overflow): завершён в момент
            % создания, счётчик отброшенных +1 (drop-tail).
            if accepted, obj.queues{ue}(end+1)=id; else, p.status='dropped'; p.reason='overflow'; p.terminalTick=double(a.createdTick); p.localFinished=true; p.localFinishedTick=double(a.createdTick); obj.counters.dropped=obj.counters.dropped+1; end
            % Запоминаем sequence, добавляем запись в массив, индекс → позиция, счётчик созданных +1.
            obj.sequences{ue}(end+1)=double(a.sequence); obj.packets(end+1)=p; obj.index(id)=numel(obj.packets); obj.counters.created=obj.counters.created+1;
        end
        %HEAD Номер первого пакета в очереди UE (0 — очередь пуста); QUEUELENGTH — длина очереди.
        function id=head(obj,ue)
            % Первый пакет очереди UE (0, если очередь пуста).
            obj.validateUE(ue); q=obj.queues{double(ue)}; id=uint32(0); if ~isempty(q), id=q(1); end
        end
        % Длина очереди UE (включая обслуживаемый пакет).
        function n=queueLength(obj,ue), obj.validateUE(ue); n=numel(obj.queues{double(ue)}); end
        % Запись пакета по номеру.
        function p=get(obj,id), p=obj.packets(obj.lookup(id)); end
        %INCREMENTATTEMPT Учитывает ещё одну передачу Msg1 для пакета.
        function incrementAttempt(obj,id)
            % Позиция пакета; попытка RA допустима только для ещё не завершённого (pending) пакета.
            i=obj.lookup(id); if ~strcmp(obj.packets(i).status,'pending'), error('nbiot:traffic:TerminalPacket','Cannot attempt terminal packet'); end
            % Число передач Msg1 для этого пакета +1.
            obj.packets(i).attemptCount=obj.packets(i).attemptCount+1;
        end
        %EXPIRELIFETIME Отбрасывает пакеты старше cfg.traffic.lifetimeTicks; возвращает их номера.
        function expired=expireLifetime(obj,tick)
            % Called after all receive events at the same tick are processed.
            % Проверяем тик; список отброшенных по сроку жизни.
            obj.tick(tick); expired=uint32([]);
            % Перебираем все пакеты:
            for i=1:numel(obj.packets)
                % текущая запись;
                p=obj.packets(i);
                % пакет ещё не завершён у UE и его возраст >= срока жизни —
                if ~p.localFinished && double(tick)-double(p.createdTick)>=obj.cfg.traffic.lifetimeTicks
                    % добавляем номер в список
                    expired(end+1)=p.packetId; %#ok<AGROW>
                    % и отмечаем его отброшенным с причиной lifetime.
                    obj.markTerminal(p.packetId,'dropped','lifetime',tick);
                end
            end
        end
        %LOCALFINISH Пакет завершён у UE (удаляется из очереди). CONFIRMED — получена квитанция доставки.
        function localFinish(obj,id,tick,confirmed)
            % Позиция пакета, проверка тика, запись пакета.
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i);
            % Завершение не может быть раньше создания.
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Completion precedes arrival'); end
            % CONFIRMED — логический скаляр (получена ли квитанция).
            validateattributes(confirmed,{'logical'},{'scalar'});
            % Подтвердить можно только доставленный пакет.
            if confirmed&&~strcmp(p.status,'delivered'), error('nbiot:traffic:InvalidConfirmation','Cannot confirm undelivered packet'); end
            % Уже завершён у UE — ничего не делаем.
            if p.localFinished, return; end
            % Отмечаем завершение у UE: тик и признак подтверждения; сохраняем запись.
            p.localFinished=true; p.localFinishedTick=double(tick); p.ueConfirmed=confirmed; obj.packets(i)=p;
            % Удаляем пакет из очереди своего UE — место в очереди освобождается.
            ue=double(p.ueId); obj.queues{ue}(obj.queues{ue}==p.packetId)=[];
        end
        %MARKTERMINAL Финальный неуспешный статус ('dropped' | 'unfinished') с причиной REASON.
        function markTerminal(obj,id,status,reason,tick)
            % Позиция, проверка тика, запись пакета.
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i);
            % Итоговый статус не может быть раньше создания.
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Terminal tick precedes arrival'); end
            % Допустимы только статусы dropped и unfinished.
            if ~any(strcmp(status,{'dropped','unfinished'})), error('nbiot:traffic:InvalidStatus','Only dropped or unfinished terminal status allowed'); end
            % Если пакет уже доставлен на BS — он не отбрасывается, а просто завершается у UE (без подтверждения).
            if strcmp(p.status,'delivered'), obj.localFinish(id,tick,false); return; end
            % Если пакет уже имеет итоговый статус — ничего не меняем.
            if ~strcmp(p.status,'pending'), return; end
            % Записываем статус, причину и тик.
            p.status=char(status); p.reason=char(reason); p.terminalTick=double(tick); obj.packets(i)=p;
            % Счётчик этого статуса +1; пакет завершается у UE.
            obj.counters.(status)=obj.counters.(status)+1; obj.localFinish(id,tick,false);
        end
        %MARKRECEIVED BS приняла фрагмент FRAGMENTINDEX пакета ID (биты BITS после CRC).
        %   Когда собраны все фрагменты — пакет delivered, учитываются полезные биты для throughput.
        function newlyDelivered=markReceived(obj,id,fragmentIndex,bits,tick)
            % Позиция, проверка тика, запись; по умолчанию «новой доставки нет».
            i=obj.lookup(id); obj.tick(tick); p=obj.packets(i); newlyDelivered=false;
            % Индекс фрагмента — целое 0..(число блоков − 1).
            validateattributes(fragmentIndex,{'numeric'},{'scalar','integer','>=',0,'<',numel(p.blocks)});
            % Приём не может быть раньше создания пакета.
            if tick<double(p.createdTick), error('nbiot:traffic:InvalidTime','Receive precedes arrival'); end
            % Принятые биты столбцом и исходный блок этого фрагмента.
            b=int8(bits(:)); expected=p.blocks{double(fragmentIndex)+1};
            % Проверка принятого блока: 256 бит 0/1, заголовок (48 бит) совпадает с ожидаемым, после полезных
            % бит — только нули.
            if numel(bits)~=256||any(bits(:)~=0&bits(:)~=1)||~isequal(b(1:48),expected(1:48))||any(b(49+p.map.validPayloadBits(double(fragmentIndex)+1):end))
                error('nbiot:traffic:MalformedPacket','Invalid TB header or padding');
            end
            % Пакет уже отброшен или не завершён — приём ничего не меняет.
            if any(strcmp(p.status,{'dropped','unfinished'})), return; end
            % Позиция фрагмента в cell (с единицы).
            k=double(fragmentIndex)+1;
            % Фрагмент уже был принят (повтор):
            if ~isempty(p.received{k})
                % повтор должен совпадать с ранее принятым, иначе ошибка;
                if ~isequal(p.received{k},b), error('nbiot:traffic:ConflictingFragment','Duplicate fragment differs'); end
                % и повторный приём ничего не меняет.
                return;
            end
            % Сохраняем принятый фрагмент.
            p.received{k}=b;
            % Если приняты все фрагменты пакета —
            if all(~cellfun(@isempty,p.received))
                % Reassembly relies on decoded contents, never true payload comparison.
                nbiot.traffic.reassemblePacket(p.received);
                % пакет доставлен: статус, тики доставки и завершения; это новая доставка.
                p.status='delivered'; p.deliveredTick=double(tick); p.terminalTick=double(tick); newlyDelivered=true;
                % Счётчик доставленных +1 и полезные биты пакета — в сумму для throughput.
                obj.counters.delivered=obj.counters.delivered+1; obj.counters.deliveredPayloadBits=obj.counters.deliveredPayloadBits+p.map.totalPayloadBits;
            end
            % Сохраняем обновлённую запись пакета.
            obj.packets(i)=p;
        end
        %FINALIZE На горизонте все ожидающие пакеты получают статус unfinished/horizon.
        function packets=finalize(obj,tick)
            % Проверяем тик горизонта.
            obj.tick(tick);
            % Перебираем все пакеты:
            for i=1:numel(obj.packets)
                % ещё ожидающие получают статус unfinished с причиной horizon.
                if strcmp(obj.packets(i).status,'pending'), obj.markTerminal(obj.packets(i).packetId,'unfinished','horizon',tick); end
            end
            % Возвращаем итоговый массив пакетов.
            packets=obj.packets;
        end
    end
    methods (Access=private)
        % Позиция пакета по номеру через индекс.
        function i=lookup(obj,id)
            % Номер пакета — целое 1..2^32−1.
            validateattributes(id,{'numeric'},{'scalar','integer','positive','<=',2^32-1});
            % Неизвестный номер — ошибка.
            if ~isKey(obj.index,uint32(id)), error('nbiot:traffic:UnknownPacket','Unknown packet ID'); end
            % Позиция в массиве packets.
            i=obj.index(uint32(id));
        end
        % Номер UE — целое 1..numUE.
        function validateUE(obj,ue), validateattributes(ue,{'numeric'},{'scalar','integer','>=',1,'<=',obj.cfg.simulation.numUE}); end
        % Тик — неотрицательное конечное целое.
        function tick(~,t), validateattributes(t,{'numeric'},{'scalar','real','finite','integer','nonnegative'}); end
    end
end
