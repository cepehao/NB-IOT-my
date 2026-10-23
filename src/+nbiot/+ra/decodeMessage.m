function fields = decodeMessage(kind,bits)
%DECODEMESSAGE Разбор принятых 88 бит управляющего сообщения KIND (ТЗ §18–19).
%   KIND: 'RAR' — MAC RAR NB-IoT (BI-подзаголовок, RAPID, TA 11 бит, UL grant 15 бит, Temp C-RNTI 16 бит;
%   TS 36.321 §6.1.5, TS 36.213 §16.3.3); 'Msg3' — token 48 бит + номер пакета 16 бит;
%   'Msg4' — MAC CE contention resolution identity (LCID 28) + padding (LCID 31);
%   'receipt' — квитанция модели: метка 0xA1, номер пакета, индекс фрагмента, статус.
%   Проверяет заголовки, зарезервированные биты и нулевой хвост; при ошибке — nbiot:protocol:Malformed
%   (сообщение считается непринятым). Разбираются принятые биты, не переданные.
bits=int8(bits(:));
if numel(bits)~=88 || any(bits~=0 & bits~=1)
    error('nbiot:protocol:Malformed','Expected an 88-bit message.');
end
u=@(a,z) double(nbiot.util.fromBits(bits(a:z)));
switch lower(string(kind))
    case "rar"
        if ~isequal(bits(1:4),int8([1;0;0;0])) || u(5,8)~=1 || ...
                ~isequal(bits(9:10),int8([0;1])) || bits(17)~=0 || any(bits(29:33))
            error('nbiot:protocol:Malformed','Invalid RAR header or reserved bits.');
        end
        fields=struct('rapid',u(11,16),'timingAdvance',u(18,28), ...
            'subcarrierSpacing',u(34,34),'subcarrierIndication',u(35,40), ...
            'schedulingDelay',u(41,42),'repetitionNumber',u(43,45), ...
            'mcs',u(46,48),'rnti',u(49,64),'backoffTicks',256);
        tail=65;
    case "msg3"
        fields=struct('token',nbiot.util.fromBits(bits(1:48)),'sequence',u(49,64)); tail=65;
    case "msg4"
        if ~isequal(bits(1:3),int8([0;0;1])) || u(4,8)~=28 || ...
                any(bits(9:11)) || u(12,16)~=31
            error('nbiot:protocol:Malformed','Invalid contention-resolution MAC header.');
        end
        fields=struct('token',nbiot.util.fromBits(bits(17:64))); tail=65;
    case "receipt"
        if u(1,8)~=hex2dec('A1') || any(bits(41:48))
            error('nbiot:protocol:Malformed','Invalid receipt wrapper version/reserved bits.');
        end
        fields=struct('sequence',u(9,24),'fragmentIndex',u(25,32),'status',u(33,40)); tail=49;
    otherwise
        error('nbiot:protocol:Kind','Unsupported message %s.',kind);
end
if any(bits(tail:end)), error('nbiot:protocol:Malformed','Nonzero control padding.'); end
end
