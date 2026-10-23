function bits = encodeMessage(kind,fields)
%ENCODEMESSAGE Wire representation; no internal UE/packet/grant IDs.
% RAR MAC PDU: BI subheader, RAPID subheader, 48-bit MAC RAR.
% NB-IoT uses a 15-bit UL grant in the 20-bit grant field (5 reserved zeros).
% TS36.321 6.1.5, TS36.213 16.3.3. Msg3 and receipt are research wrappers.
b=@nbiot.util.toBits;
switch lower(string(kind))
    case "rar"
        grant=[b(fields.subcarrierSpacing,1);b(fields.subcarrierIndication,6); ...
            b(fields.schedulingDelay,2);b(fields.repetitionNumber,3);b(fields.mcs,3)];
        bits=[int8([1;0;0;0]);b(1,4);int8([0;1]);b(fields.rapid,6); ...
            int8(0);b(fields.timingAdvance,11);zeros(5,1,'int8');grant;b(fields.rnti,16)];
    case "msg3"
        bits=[b(fields.token,48);b(fields.sequence,16)];
    case "msg4"
        % E=1, LCID=28 contention identity; E=0, LCID=31 padding.
        bits=[int8([0;0;1]);b(28,5);int8([0;0;0]);b(31,5);b(fields.token,48)];
    case "receipt"
        bits=[b(hex2dec('A1'),8);b(fields.sequence,16); ...
            b(fields.fragmentIndex,8);b(fields.status,8);zeros(8,1,'int8')];
    otherwise
        error('nbiot:protocol:Kind','Unsupported message %s.',kind);
end
if numel(bits)>88, error('nbiot:protocol:Length','Message exceeds control TBS.'); end
bits=[bits;zeros(88-numel(bits),1,'int8')];
end
