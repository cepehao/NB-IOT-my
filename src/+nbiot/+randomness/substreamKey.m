function key = substreamKey(sourceName,direction,receiverId,blockId)
names={'layout','traffic','shadowing','channel','CFO','timing','noise','payload','access','backoff','token'};
code=find(strcmpi(sourceName,names),1);
if isempty(code), error('nbiot:randomness:InvalidKey','Unknown source name'); end
values={direction,receiverId,blockId}; limits=[1 65535 16777215];
for k=1:3, x=values{k}; if ~isnumeric(x)||~isscalar(x)||~isreal(x)||~isfinite(x)||x~=fix(x)||x<0||x>limits(k), error('nbiot:randomness:InvalidKey','Invalid numeric key component %d',k); end, end
key=1+double(blockId)+2^24*(double(receiverId)+2^16*(double(direction)+2*code));
end
