function bits=packDci(dci)
% TS36.212 6.4.3: N0 and normal N1 have 23 bits, MSB first.
if strcmp(dci.format,'N0')
    fields={'subcarrierIndication','resourceAssignment','schedulingDelay','mcs','rv','repetitionNumber','ndi','dciRepetitions'};
    widths=[6 3 2 4 1 3 1 2]; bits=int8(0);
elseif strcmp(dci.format,'N1')
    if isfield(dci,'order'), order=dci.order; else, order=0; end
    bits=int8([1;order]);
    if order
        bits=[bits;put(dci.nprachRepetitions,2);put(dci.subcarrierIndication,6);ones(13,1,'int8')]; return;
    end
    fields={'schedulingDelay','resourceAssignment','mcs','repetitionNumber','ndi','ackResource','dciRepetitions'};
    widths=[3 3 4 4 1 4 2];
else
    error('nbiot:phy:DciFormat','Only N0 and N1 are supported.');
end
for k=1:numel(fields), bits=[bits;put(dci.(fields{k}),widths(k))]; end %#ok<AGROW>
assert(numel(bits)==23,'nbiot:phy:DciLength','Invalid DCI length.');
end
function b=put(v,n)
validateattributes(v,{'numeric','logical'},{'scalar','integer','>=',0,'<',2^n});
b=int8(bitget(uint32(v),n:-1:1)');
end
