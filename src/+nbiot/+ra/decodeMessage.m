function fields = decodeMessage(kind,bits)
%DECODEMESSAGE Разбор принятых 88 бит управляющего сообщения KIND (ТЗ §18–19).
%   KIND: 'RAR' — MAC RAR NB-IoT (BI-подзаголовок, RAPID, TA 11 бит, UL grant 15 бит, Temp C-RNTI 16 бит;
%   TS 36.321 §6.1.5, TS 36.213 §16.3.3); 'Msg3' — token 48 бит + номер пакета 16 бит;
%   'Msg4' — MAC CE contention resolution identity (LCID 28) + padding (LCID 31);
%   'receipt' — квитанция модели: метка 0xA1, номер пакета, индекс фрагмента, статус.
%   Проверяет заголовки, зарезервированные биты и нулевой хвост; при ошибке — nbiot:protocol:Malformed
%   (сообщение считается непринятым). Разбираются принятые биты, не переданные.
% Принятые биты — столбец int8.
bits=int8(bits(:));
% Управляющее сообщение — ровно 88 бит (TBS NPDSCH/Msg3 профиля) со значениями 0/1.
if numel(bits)~=88 || any(bits~=0 & bits~=1)
    error('nbiot:protocol:Malformed','Expected an 88-bit message.');
end
% Вспомогательная функция: биты с a по z (с единицы) → число.
u=@(a,z) double(nbiot.util.fromBits(bits(a:z)));
% Разбор по типу сообщения:
switch lower(string(kind))
    % RAR (Msg2, MAC PDU по TS 36.321 §6.1.5):
    case "rar"
        % заголовки: [1 0 0 0] — подзаголовок Backoff Indicator, BI = 1; [0 1] — подзаголовок RAPID;
        % бит 17 и биты 29–33 — резерв (нули); иначе сообщение повреждено.
        if ~isequal(bits(1:4),int8([1;0;0;0])) || u(5,8)~=1 || ...
                ~isequal(bits(9:10),int8([0;1])) || bits(17)~=0 || any(bits(29:33))
            error('nbiot:protocol:Malformed','Invalid RAR header or reserved bits.');
        end
        % Поля: RAPID (номер преамбулы = NInit) — биты 11–16; timing advance — 18–28 (11 бит);
        % UL grant для Msg3 (15 бит): разнос поднесущих 34, поднесущие 35–40, задержка 41–42, повторы 43–45,
        % MCS 46–48; Temporary C-RNTI — 49–64; окно BACKOFF модели — 256 мс.
        fields=struct('rapid',u(11,16),'timingAdvance',u(18,28), ...
            'subcarrierSpacing',u(34,34),'subcarrierIndication',u(35,40), ...
            'schedulingDelay',u(41,42),'repetitionNumber',u(43,45), ...
            'mcs',u(46,48),'rnti',u(49,64),'backoffTicks',256);
        % Полезные данные RAR заканчиваются на бите 64; дальше — padding.
        tail=65;
    % Msg3:
    case "msg3"
        % идентификатор конкуренции (48 бит) и номер пакета (16 бит); padding с бита 65.
        fields=struct('token',nbiot.util.fromBits(bits(1:48)),'sequence',u(49,64)); tail=65;
    % Msg4 (contention resolution):
    case "msg4"
        % заголовки MAC: [0 0 1] + LCID 28 (идентификатор конкуренции), [0 0 0] + LCID 31 (padding);
        % иначе сообщение повреждено.
        if ~isequal(bits(1:3),int8([0;0;1])) || u(4,8)~=28 || ...
                any(bits(9:11)) || u(12,16)~=31
            error('nbiot:protocol:Malformed','Invalid contention-resolution MAC header.');
        end
        % Идентификатор конкуренции — биты 17–64; padding с бита 65.
        fields=struct('token',nbiot.util.fromBits(bits(17:64))); tail=65;
    % Квитанция о доставке (формат модели):
    case "receipt"
        % метка 0xA1 в первых 8 битах и нулевой резерв 41–48 — иначе повреждено.
        if u(1,8)~=hex2dec('A1') || any(bits(41:48))
            error('nbiot:protocol:Malformed','Invalid receipt wrapper version/reserved bits.');
        end
        % Номер пакета (9–24), индекс последнего фрагмента (25–32), статус (33–40); padding с бита 49.
        fields=struct('sequence',u(9,24),'fragmentIndex',u(25,32),'status',u(33,40)); tail=49;
    % Другой тип —
    otherwise
        error('nbiot:protocol:Kind','Unsupported message %s.',kind);
end
% Хвост сообщения после полезных полей обязан быть нулевым.
if any(bits(tail:end)), error('nbiot:protocol:Malformed','Nonzero control padding.'); end
end
