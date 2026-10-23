function fields = decodeMessage(kind,bits)
%DECODEMESSAGE Validate the decoded wire bits, not the transmitted payload.
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
