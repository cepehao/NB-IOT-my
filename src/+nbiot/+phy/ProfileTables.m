classdef ProfileTables
    %PROFILETABLES Таблицы 3GPP Release 13 для профиля static-v1 (TS 36.213 §16): профили каналов,
    %   TBS UL/DL, задержки планирования, повторы, назначение поднесущих, ресурс ACK.
    %   Зарезервированные комбинации стандарта дают ошибку nbiot:phy:Reserved, а не подмену значением.
    methods (Static)
        %PROFILE Константы профиля канала KIND: 'msg3' | 'data' | 'ack' | 'downlink' (RAR/Msg4/receipt) | 'npdcch'.
        %   Поля: формат, разнос поднесущих (Гц), число поднесущих, модуляция, NRU, слоты, повторы, TBS (бит),
        %   MCS, I_RU, длительность в тиках; для NPDCCH — Rmax, G, offset, NCCE.
        function p = profile(kind)
            % Value structs use copy-on-write: callers cannot mutate the cache.
            % Only immutable profile constants are cached, never grants or RX state.
            % Профили создаются один раз и хранятся между вызовами (persistent).
            persistent msg3 data ack downlink npdcch
            % Первый вызов — создаём профили:
            if isempty(msg3)
                % базовый профиль: NPUSCH Data, 15 кГц, 3 поднесущие, QPSK, 1 RU, 8 слотов, 2 повтора, TBS 88, MCS 6, I_RU 0, 8 тиков;
                base=struct('format','Data','spacingHz',15000,'numSubcarriers',3,...
                    'modulation','QPSK','nru',1,'nulSlots',8,'repetitions',2,...
                    'tbs',88,'mcs',6,'iru',0,'durationTicks',8);
                % Msg3 = базовый, индекс Msg3 в RAR = 2;
                msg3=base; msg3.rarIndex=2;
                % данные: 4 RU, TBS 256 бит, MCS 4,
                data=base; data.nru=4; data.tbs=256; data.mcs=4;
                % I_RU 3, длительность 32 тика;
                data.iru=3; data.durationTicks=32;
                % ACK: формат 2 (Control), 1 поднесущая,
                ack=base; ack.format='Control'; ack.numSubcarriers=1;
                % BPSK, 4 слота, 1 бит,
                ack.modulation='BPSK'; ack.nulSlots=4; ack.tbs=1;
                % MCS 0, 4 тика;
                ack.mcs=0; ack.durationTicks=4;
                % NPDSCH: 12 поднесущих (весь подкадр),
                downlink=base; downlink.format='NPDSCH'; downlink.numSubcarriers=12;
                % 1 подкадр, 2 тика (с повтором);
                downlink.nsf=1; downlink.durationTicks=2;
                % NPDCCH: 12 поднесущих,
                npdcch=base; npdcch.format='NPDCCH'; npdcch.numSubcarriers=12;
                % 2 тика, Rmax 4, G 8,
                npdcch.durationTicks=2; npdcch.rmax=4; npdcch.g=8;
                % смещение 0, обе NCCE (агрегация 2).
                npdcch.offset=0; npdcch.ncce=[0 1];
            end
            % Выбор профиля по виду канала:
            switch lower(char(kind))
                % Msg3 —
                case 'msg3'
                    % профиль Msg3;
                    p=msg3;
                % данные NPUSCH —
                case {'data','npusch'}
                    % профиль данных;
                    p=data;
                % ACK (UCI) —
                case {'ack','control'}
                    % профиль ACK;
                    p=ack;
                % любое сообщение NPDSCH (RAR, Msg4, квитанция) —
                case {'downlink','rar','msg4','receipt','npdsch'}
                    % профиль NPDSCH;
                    p=downlink;
                % NPDCCH (DCI N0/N1) —
                case {'npdcch','n0','n1'}
                    % профиль NPDCCH;
                    p=npdcch;
                otherwise
                    error('nbiot:phy:Profile','Unknown profile %s.',kind);
            end
        end
        %MSG3PROFILE Профиль Msg3 по индексу из RAR (TS 36.213 табл. 16.3.3-1): NRU = 4/3/1 для индекса 0/1/2.
        function p=msg3Profile(index)
            % Индекс Msg3 из RAR — 0..2.
            validateattributes(index,{'numeric'},{'scalar','integer','>=',0,'<=',2});
            % Берём базовый профиль Msg3.
            p=nbiot.phy.ProfileTables.profile('msg3');
            % NRU по индексу: 4 / 3 / 1; запоминаем индекс.
            nr=[4 3 1]; p.nru=nr(index+1); p.rarIndex=index;
            % I_RU — позиция NRU в таблице {1,2,3,4,5,6,8,10} (с нуля).
            p.iru=find([1 2 3 4 5 6 8 10]==p.nru)-1;
            % Длительность в тиках: NRU × слотов × повторов / 2 (2 слота на тик).
            p.durationTicks=p.nru*p.nulSlots*p.repetitions/2;
        end
        %ULTBS TBS NPUSCH (бит) по I_MCS, I_RU и числу поднесущих (TS 36.213 табл. 16.5.1.2-2).
        function t=ulTbs(mcs,iru,nsc)
            % I_MCS — 0..12.
            validateattributes(mcs,{'numeric'},{'scalar','integer','>=',0,'<=',12});
            % I_RU — 0..7.
            validateattributes(iru,{'numeric'},{'scalar','integer','>=',0,'<=',7});
            % Число поднесущих — 1, 3, 6 или 12.
            assert(ismember(nsc,[1 3 6 12]),'nbiot:phy:Allocation','Invalid tone count.');
            % Для одной поднесущей (single-tone):
            if nsc==1
                % MCS > 10 зарезервированы;
                assert(mcs<=10,'nbiot:phy:Reserved','Reserved single-tone MCS.');
                % перевод I_MCS → I_TBS по таблице single-tone.
                map=[0 2 1 3 4 5 6 7 8 9 10]; mcs=map(mcs+1);
            end
            % Таблица TBS (бит): строки — I_TBS 0..12, столбцы — I_RU 0..7; NaN — зарезервировано.
            a=[16 32 56 88 120 152 208 256;24 56 88 144 176 208 256 344;...
                32 72 144 176 208 256 328 424;40 104 176 208 256 328 440 568;...
                56 120 208 256 328 408 552 680;72 144 224 328 424 504 680 872;...
                88 176 256 392 504 600 808 1000;104 224 328 472 584 712 1000 NaN;...
                120 256 392 536 680 808 NaN NaN;136 296 456 616 776 936 NaN NaN;...
                144 328 504 680 872 1000 NaN NaN;176 376 584 776 1000 NaN NaN NaN;...
                208 440 680 1000 NaN NaN NaN NaN];
            % TBS по таблице; зарезервированная комбинация — ошибка.
            t=a(mcs+1,iru+1); assert(isfinite(t),'nbiot:phy:Reserved','Reserved TBS combination.');
        end
        %DLTBS TBS NPDSCH (бит) по I_MCS и I_SF (TS 36.213 табл. 16.4.1.5.1-1).
        function t=dlTbs(mcs,isf)
            % I_MCS — 0..12.
            validateattributes(mcs,{'numeric'},{'scalar','integer','>=',0,'<=',12});
            % I_SF — 0..7.
            validateattributes(isf,{'numeric'},{'scalar','integer','>=',0,'<=',7});
            % Таблица TBS NPDSCH (бит): строки — I_TBS, столбцы — I_SF; NaN — зарезервировано.
            a=[16 32 56 88 120 152 208 256;24 56 88 144 176 208 256 344;...
                32 72 144 176 208 256 328 424;40 104 176 208 256 328 440 568;...
                56 120 208 256 328 408 552 680;72 144 224 328 424 504 680 NaN;...
                88 176 256 392 504 600 NaN NaN;104 224 328 472 584 680 NaN NaN;...
                120 256 392 536 680 NaN NaN NaN;136 296 456 616 NaN NaN NaN NaN;...
                144 328 504 680 NaN NaN NaN NaN;176 376 584 NaN NaN NaN NaN NaN;...
                208 440 680 NaN NaN NaN NaN NaN];
            % TBS по таблице; зарезервированная комбинация — ошибка.
            t=a(mcs+1,isf+1); assert(isfinite(t),'nbiot:phy:Reserved','Reserved DL TBS combination.');
        end
        % Задержки планирования k0 (подкадры): N0 — TS 36.213 табл. 16.5.1-1, RAR — табл. 16.3.3-1,
        % N1 — табл. 16.4.1-1 (зависит от Rmax); NRU, число подкадров NPDSCH и повторы — по индексам DCI.
        function v=n0Delay(i), v=nbiot.phy.ProfileTables.lookup([8 16 32 64],i); end
        % Задержка Msg3 после RAR (подкадров) по индексу 0..3.
        function v=rarDelay(i), v=nbiot.phy.ProfileTables.lookup([12 16 32 64],i); end
        % Задержка NPDSCH после NPDCCH по индексу DCI N1:
        function v=n1Delay(i,rmax)
            % таблица зависит от Rmax (меньше 128 / не меньше 128);
            if rmax<128, a=[0 4 8 12 16 32 64 128]; else, a=[0 16 32 64 128 256 512 1024]; end
            % значение по индексу.
            v=nbiot.phy.ProfileTables.lookup(a,i);
        end
        % Число RU по индексу DCI (I_RU).
        function v=resourceUnits(i), v=nbiot.phy.ProfileTables.lookup([1 2 3 4 5 6 8 10],i); end
        % Число подкадров NPDSCH по индексу (I_SF) — та же таблица.
        function v=dlSubframes(i), v=nbiot.phy.ProfileTables.resourceUnits(i); end
        % Число повторов NPUSCH по индексу: 1, 2, 4, …, 128.
        function v=ulRepetitions(i), v=nbiot.phy.ProfileTables.lookup(2.^(0:7),i); end
        function v=dlRepetitions(i), v=nbiot.phy.ProfileTables.lookup([1 2 4 8 16 32 64 128 192 256 384 512 768 1024 1536 2048],i); end
        %DECODEULASSIGNMENT Индекс I_sc (0..18) → номера поднесущих 15 кГц (TS 36.213 табл. 16.5.1.1-1).
        % Индекс I_sc → номера поднесущих 15 кГц:
        function sc=decodeUlAssignment(i)
            % I_sc — 0..18;
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<=',18});
            % 0–11 — одна поднесущая; 12–15 — 3 подряд; 16–17 — 6 подряд; 18 — все 12.
            if i<12, sc=i; elseif i<16, sc=3*(i-12)+(0:2); elseif i<18, sc=6*(i-16)+(0:5); else, sc=0:11; end
        end
        %ENCODEULASSIGNMENT Обратное преобразование: набор поднесущих → I_sc.
        function i=encodeUlAssignment(sc)
            % Перебираем все индексы:
            for j=0:18
                % индекс, дающий тот же набор поднесущих.
                if isequal(sc(:)',nbiot.phy.ProfileTables.decodeUlAssignment(j)), i=j; return; end
            end
            % Набор не соответствует ни одному индексу — ошибка.
            error('nbiot:phy:Allocation','Unsupported contiguous allocation.');
        end
        %ACKRESOURCE Ресурс ACK/NACK NPUSCH формат 2 по полю DCI N1: поднесущая и задержка k0 (табл. 16.4.2-1).
        function [tone,k0]=ackResource(i)
            % Поле ресурса ACK — 0..15.
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<=',15});
            % Поднесущая ACK = поле mod 4; задержка k0 по старшей части поля: 13/15/17/18 подкадров.
            tone=mod(i,4); a=[13 15 17 18]; k0=a(floor(i/4)+1);
        end
        %NPRACHDURATIONTICKS Длительность резерва NPRACH: формат 0, 4 группы ≈ 5,6 мс → 6 тиков.
        function v=nprachDurationTicks(), v=6; end
        %LOOKUP Значение таблицы A по индексу I (с нуля) с проверкой диапазона.
        function v=lookup(a,i)
            % Индекс — целое 0..numel(A)−1; значение A(I+1).
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<',numel(a)}); v=a(i+1);
        end
    end
end
