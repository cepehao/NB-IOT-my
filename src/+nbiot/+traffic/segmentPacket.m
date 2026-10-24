function [blocks,map]=segmentPacket(bits,sequence)
%SEGMENTPACKET Нарезка пакета на транспортные блоки данных NPUSCH по 256 бит (TBS профиля, ТЗ §20).
%   Блок = заголовок 48 бит [номер пакета 16 | индекс фрагмента 8 (с нуля) | число фрагментов 8 |
%   число полезных бит 8 | нули 8] + до 208 бит данных + нулевой padding. Биты старшим вперёд.
%   Пакет 200 байт = 1600 бит → 8 фрагментов (7 × 208 + 144).
% Биты пакета — непустой вектор.
validateattributes(bits,{'numeric','logical'},{'vector','nonempty'});
% Только значения 0/1.
if any(bits(:)~=0&bits(:)~=1), error('nbiot:traffic:MalformedPacket','Nonbinary payload'); end
% Номер пакета sequence — 0..65535 (поле 16 бит).
validateattributes(sequence,{'numeric'},{'scalar','integer','>=',0,'<=',65535});
% Биты столбцом int8; число фрагментов = ceil(длина / 208).
bits=int8(bits(:)); count=ceil(numel(bits)/208);
% Не больше 255 фрагментов (поле 8 бит).
if count>255, error('nbiot:traffic:MalformedPacket','Too many fragments'); end
% Заготовки блоков и длин полезных данных.
blocks=cell(count,1); valid=zeros(count,1);
% Для каждого фрагмента k:
for k=1:count
 % первый бит фрагмента и число полезных бит в нём (208 или остаток в последнем);
 first=(k-1)*208+1; valid(k)=min(208,numel(bits)-first+1);
 % заголовок 48 бит: номер пакета, индекс (с нуля), число фрагментов, число полезных бит, 8 нулей;
 header=[pack(sequence,16);pack(k-1,8);pack(count,8);pack(valid(k),8);zeros(8,1,'int8')];
 % блок = заголовок + полезные биты + нулевой padding до 256 бит.
 blocks{k}=[header;bits(first:first+valid(k)-1);zeros(208-valid(k),1,'int8')];
end
% Карта нарезки: номер, число фрагментов, длины, общий размер, длина заголовка и блока.
map=struct('sequence',uint16(sequence),'fragmentCount',count,'validPayloadBits',valid,'totalPayloadBits',numel(bits),'headerBits',48,'transportBlockBits',256);
end
% Число → N бит, старший первым (столбец int8).
function b=pack(x,n), b=int8(bitget(uint32(x),n:-1:1))'; end
