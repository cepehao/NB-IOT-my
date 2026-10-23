classdef TestProtocolCodec < matlab.unittest.TestCase
    methods (Test)
        function rarWireFields(t)
            f=struct('subcarrierSpacing',1,'subcarrierIndication',12,'schedulingDelay',0, ...
                'repetitionNumber',1,'mcs',2,'rapid',7,'timingAdvance',9,'rnti',256);
            bits=nbiot.ra.encodeMessage('RAR',f); q=nbiot.ra.decodeMessage('RAR',bits);
            t.verifyEqual(q.rapid,7); t.verifyEqual(q.rnti,256);
            t.verifyEqual(q.subcarrierIndication,12); t.verifyEqual(q.mcs,2);
            t.verifyEqual(bits(29:33),zeros(5,1,'int8'));
        end
        function contentionIdentity(t)
            f=struct('token',uint64(123456789)); bits=nbiot.ra.encodeMessage('Msg4',f);
            q=nbiot.ra.decodeMessage('Msg4',bits); t.verifyEqual(q.token,f.token);
            bits(end)=1; t.verifyError(@() nbiot.ra.decodeMessage('Msg4',bits),'nbiot:protocol:Malformed');
        end
        function receiptSequenceAndPadding(t)
            f=struct('sequence',65535,'fragmentIndex',8,'status',1);
            q=nbiot.ra.decodeMessage('receipt',nbiot.ra.encodeMessage('receipt',f));
            t.verifyEqual(q.sequence,65535); t.verifyEqual(q.fragmentIndex,8);
        end
        function boundaryBitOrdering(t)
            t.verifyEqual(nbiot.util.toBits(129,8),int8([1;0;0;0;0;0;0;1]));
            t.verifyEqual(nbiot.util.fromBits(int8([1;0;1])),uint64(5));
        end
    end
end
