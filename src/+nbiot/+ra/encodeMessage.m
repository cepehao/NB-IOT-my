function bits = encodeMessage(kind,fields)
%ENCODEMESSAGE Битовое представление управляющего сообщения KIND (88 бит = TBS NPDSCH/Msg3 профиля).
% RAR MAC PDU: BI subheader, RAPID subheader, 48-bit MAC RAR.
% NB-IoT uses a 15-bit UL grant in the 20-bit grant field (5 reserved zeros).
% TS36.321 6.1.5, TS36.213 16.3.3. Msg3 and receipt are research wrappers.
% Короткое имя функции «число → биты».
b=@nbiot.util.toBits;
% Формирование по типу сообщения:
switch lower(string(kind))
    % RAR (Msg2):
    case "rar"
        % UL grant Msg3 (15 бит): разнос поднесущих 1, поднесущие 6, задержка 2, повторы 3, MCS 3.
        grant=[b(fields.subcarrierSpacing,1);b(fields.subcarrierIndication,6); ...
            b(fields.schedulingDelay,2);b(fields.repetitionNumber,3);b(fields.mcs,3)];
        % MAC PDU: подзаголовок BI [1 0 0 0] + BI = 1 (4 бита), подзаголовок RAPID [0 1] + RAPID (6 бит),
        % резервный бит, TA (11 бит), 5 резервных нулей, UL grant, Temporary C-RNTI (16 бит) — итого 64 бита.
        bits=[int8([1;0;0;0]);b(1,4);int8([0;1]);b(fields.rapid,6); ...
            int8(0);b(fields.timingAdvance,11);zeros(5,1,'int8');grant;b(fields.rnti,16)];
    % Msg3:
    case "msg3"
        % идентификатор конкуренции (48 бит) + номер пакета (16 бит).
        bits=[b(fields.token,48);b(fields.sequence,16)];
    % Msg4:
    case "msg4"
        % E=1, LCID=28 contention identity; E=0, LCID=31 padding.
        bits=[int8([0;0;1]);b(28,5);int8([0;0;0]);b(31,5);b(fields.token,48)];
    % Квитанция:
    case "receipt"
        % метка 0xA1, номер пакета (16), индекс последнего фрагмента (8), статус (8), резерв 8 нулей.
        bits=[b(hex2dec('A1'),8);b(fields.sequence,16); ...
            b(fields.fragmentIndex,8);b(fields.status,8);zeros(8,1,'int8')];
    % Другой тип —
    otherwise
        error('nbiot:protocol:Kind','Unsupported message %s.',kind);
end
% Сообщение не должно превышать 88 бит.
if numel(bits)>88, error('nbiot:protocol:Length','Message exceeds control TBS.'); end
% Дополняем нулями до 88 бит (TBS управляющего сообщения).
bits=[bits;zeros(88-numel(bits),1,'int8')];
end
