function bits=packDci(dci)
%PACKDCI Упаковывает поля DCI в 23 бита, старший бит первым (TS 36.212 §6.4.3.1–6.4.3.2).
%   N0 (UL grant): флаг 0, поднесущие 6, NRU 3, задержка 2, MCS 4, RV 1, повторы 3, NDI 1, повторы DCI 2.
%   N1 (DL grant): флаг 1, NPDCCH order 1, задержка 3, NSF 3, MCS 4, повторы 4, NDI 1, ресурс ACK 4,
%   повторы DCI 2. N1 с order=1 — команда на NPRACH (повторы, поднесущая, остальное единицы).
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
