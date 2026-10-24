function bits=packDci(dci)
%PACKDCI Упаковывает поля DCI в 23 бита, старший бит первым (TS 36.212 §6.4.3.1–6.4.3.2).
%   N0 (UL grant): флаг 0, поднесущие 6, NRU 3, задержка 2, MCS 4, RV 1, повторы 3, NDI 1, повторы DCI 2.
%   N1 (DL grant): флаг 1, NPDCCH order 1, задержка 3, NSF 3, MCS 4, повторы 4, NDI 1, ресурс ACK 4,
%   повторы DCI 2. N1 с order=1 — команда на NPRACH (повторы, поднесущая, остальное единицы).
% DCI N0 (назначение UL):
if strcmp(dci.format,'N0')
    % поля в порядке стандарта;
    fields={'subcarrierIndication','resourceAssignment','schedulingDelay','mcs','rv','repetitionNumber','ndi','dciRepetitions'};
    % их ширины в битах; первый бит 0 — признак формата N0.
    widths=[6 3 2 4 1 3 1 2]; bits=int8(0);
% DCI N1 (назначение DL):
elseif strcmp(dci.format,'N1')
    % признак NPDCCH order (по умолчанию 0);
    if isfield(dci,'order'), order=dci.order; else, order=0; end
    % первый бит 1 — признак N1, затем бит order;
    bits=int8([1;order]);
    % если это команда на NPRACH (order = 1) —
    if order
        % повторы NPRACH (2 бита), поднесущая (6 бит), остальное единицы; готово.
        bits=[bits;put(dci.nprachRepetitions,2);put(dci.subcarrierIndication,6);ones(13,1,'int8')]; return;
    end
    % поля обычного N1 в порядке стандарта;
    fields={'schedulingDelay','resourceAssignment','mcs','repetitionNumber','ndi','ackResource','dciRepetitions'};
    % их ширины в битах.
    widths=[3 3 4 4 1 4 2];
else
    error('nbiot:phy:DciFormat','Only N0 and N1 are supported.');
end
% Дописываем каждое поле нужной ширины.
for k=1:numel(fields), bits=[bits;put(dci.(fields{k}),widths(k))]; end %#ok<AGROW>
% Итог — ровно 23 бита.
assert(numel(bits)==23,'nbiot:phy:DciLength','Invalid DCI length.');
end
%PUT Число V → N бит, старший первым.
function b=put(v,n)
% V — целое 0..2^N−1.
validateattributes(v,{'numeric','logical'},{'scalar','integer','>=',0,'<',2^n});
% Биты столбцом int8.
b=int8(bitget(uint32(v),n:-1:1)');
end
