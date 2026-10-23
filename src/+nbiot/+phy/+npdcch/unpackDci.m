function dci=unpackDci(bits)
%UNPACKDCI Разбор 23 бит DCI N0/N1 в struct полей (обратное к packDci).
bits=bits(:); assert(numel(bits)==23 && all(bits==0 | bits==1),'nbiot:phy:DciLength','Expected 23 binary DCI bits.');
if bits(1)==0
    dci=struct('format','N0'); at=2;
    fields={'subcarrierIndication','resourceAssignment','schedulingDelay','mcs','rv','repetitionNumber','ndi','dciRepetitions'};
    widths=[6 3 2 4 1 3 1 2];
else
    dci=struct('format','N1','order',double(bits(2))); at=3;
    if dci.order
        dci.nprachRepetitions=value(bits(3:4)); dci.subcarrierIndication=value(bits(5:10));
        assert(all(bits(11:23)==1),'nbiot:phy:DciReserved','Malformed NPDCCH order.'); return;
    end
    fields={'schedulingDelay','resourceAssignment','mcs','repetitionNumber','ndi','ackResource','dciRepetitions'};
    widths=[3 3 4 4 1 4 2];
end
for k=1:numel(fields), dci.(fields{k})=value(bits(at:at+widths(k)-1)); at=at+widths(k); end
end
function v=value(b), v=sum(double(b(:)').*2.^(numel(b)-1:-1:0)); end
