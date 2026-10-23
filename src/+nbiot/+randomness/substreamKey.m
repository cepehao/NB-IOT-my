function key = substreamKey(sourceName,direction,receiverId,blockId)
%SUBSTREAMKEY Номер подпотока mrg32k3a для источника случайности (ТЗ §42).
%   KEY = 1 + blockId + 2^24·(receiverId + 2^16·(direction + 2·sourceCode)).
%   SOURCENAME — имя из списка ниже (код = позиция); DIRECTION 0..1; RECEIVERID 0..65535 (UE);
%   BLOCKID 0..2^24−1 (возможность доступа, номер попытки, блок времени). Ключи не пересекаются.
%   Новый источник случайности добавляется только в конец списка — иначе изменятся все ключи.
names={'layout','traffic','shadowing','channel','CFO','timing','noise','payload','access','backoff','token'};
code=find(strcmpi(sourceName,names),1);
if isempty(code), error('nbiot:randomness:InvalidKey','Unknown source name'); end
values={direction,receiverId,blockId}; limits=[1 65535 16777215];
for k=1:3, x=values{k}; if ~isnumeric(x)||~isscalar(x)||~isreal(x)||~isfinite(x)||x~=fix(x)||x<0||x>limits(k), error('nbiot:randomness:InvalidKey','Invalid numeric key component %d',k); end, end
key=1+double(blockId)+2^24*(double(receiverId)+2^16*(double(direction)+2*code));
end
