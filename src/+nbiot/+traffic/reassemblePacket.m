function [payload,map]=reassemblePacket(blocks)
%REASSEMBLEPACKET Сборка пакета из принятых TB 256 бит (обратное к segmentPacket).
%   Проверяет номер пакета, индексы, число фрагментов, длину данных и нулевой padding;
%   при нарушении — nbiot:traffic:MalformedPacket.
% Нужен непустой cell-массив блоков.
if ~iscell(blocks)||isempty(blocks), error('nbiot:traffic:MalformedPacket','Nonempty TB cell array required'); end
% Число блоков; заготовки для полезных данных, их длин и номера пакета.
count=numel(blocks); payload=cell(count,1); valid=zeros(count,1); sequence=[];
% Для каждого блока:
for k=1:count
 % блок — ровно 256 бит 0/1, иначе ошибка;
 b=blocks{k}; if numel(b)~=256||any(b(:)~=0&b(:)~=1), error('nbiot:traffic:MalformedPacket','Expected binary 256-bit TB'); end
 % разбор заголовка: номер пакета (16 бит), индекс фрагмента (8), число фрагментов (8), число полезных бит (8);
 b=int8(b(:)); seq=unpack(b(1:16)); idx=unpack(b(17:24)); n=unpack(b(25:32)); v=unpack(b(33:40));
 % номер пакета берём из первого блока;
 if isempty(sequence), sequence=seq; end
 % проверка согласованности: тот же номер пакета, индексы по порядку, число фрагментов совпадает,
 % полезных бит 1..208 (все блоки, кроме последнего, полные), резерв и padding нулевые;
 if seq~=sequence||idx~=k-1||n~=count||v<1||v>208||any(b(41:48))||any(b(49+v:end))||(k<count&&v~=208)
  error('nbiot:traffic:MalformedPacket','Invalid sequence, index, count, length or padding');
 end
 % запоминаем длину и полезные биты блока.
 valid(k)=v; payload{k}=b(49:48+v);
end
% Склеиваем полезные биты всех блоков; карта: номер пакета, число фрагментов, длины, общий размер.
payload=vertcat(payload{:}); map=struct('sequence',uint16(sequence),'fragmentCount',count,'validPayloadBits',valid,'totalPayloadBits',numel(payload));
end
% Двоичный вектор (старший бит первым) → число.
function x=unpack(b), x=sum(double(b(:)').*2.^(numel(b)-1:-1:0)); end
