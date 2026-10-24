function dci=unpackDci(bits)
%UNPACKDCI Разбор 23 бит DCI N0/N1 в struct полей (обратное к packDci).
% Ровно 23 бита 0/1.
bits=bits(:); assert(numel(bits)==23 && all(bits==0 | bits==1),'nbiot:phy:DciLength','Expected 23 binary DCI bits.');
% Первый бит 0 — формат N0:
if bits(1)==0
    % формат и позиция следующего поля;
    dci=struct('format','N0'); at=2;
    % поля N0;
    fields={'subcarrierIndication','resourceAssignment','schedulingDelay','mcs','rv','repetitionNumber','ndi','dciRepetitions'};
    % их ширины.
    widths=[6 3 2 4 1 3 1 2];
else
    % Иначе N1: бит order; следующее поле с бита 3.
    dci=struct('format','N1','order',double(bits(2))); at=3;
    % Команда на NPRACH:
    if dci.order
        % повторы NPRACH и поднесущая;
        dci.nprachRepetitions=value(bits(3:4)); dci.subcarrierIndication=value(bits(5:10));
        % остальные биты — единицы; готово.
        assert(all(bits(11:23)==1),'nbiot:phy:DciReserved','Malformed NPDCCH order.'); return;
    end
    % поля обычного N1;
    fields={'schedulingDelay','resourceAssignment','mcs','repetitionNumber','ndi','ackResource','dciRepetitions'};
    % их ширины.
    widths=[3 3 4 4 1 4 2];
end
% Читаем каждое поле нужной ширины и сдвигаем позицию.
for k=1:numel(fields), dci.(fields{k})=value(bits(at:at+widths(k)-1)); at=at+widths(k); end
end
%VALUE Биты (старший первым) → число.
function v=value(b), v=sum(double(b(:)').*2.^(numel(b)-1:-1:0)); end
