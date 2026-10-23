function [payload,map]=reassemblePacket(blocks)
%REASSEMBLEPACKET Reject malformed, missing or inconsistent wrappers.
if ~iscell(blocks)||isempty(blocks), error('nbiot:traffic:MalformedPacket','Nonempty TB cell array required'); end
count=numel(blocks); payload=cell(count,1); valid=zeros(count,1); sequence=[];
for k=1:count
 b=blocks{k}; if numel(b)~=256||any(b(:)~=0&b(:)~=1), error('nbiot:traffic:MalformedPacket','Expected binary 256-bit TB'); end
 b=int8(b(:)); seq=unpack(b(1:16)); idx=unpack(b(17:24)); n=unpack(b(25:32)); v=unpack(b(33:40));
 if isempty(sequence), sequence=seq; end
 if seq~=sequence||idx~=k-1||n~=count||v<1||v>208||any(b(41:48))||any(b(49+v:end))||(k<count&&v~=208)
  error('nbiot:traffic:MalformedPacket','Invalid sequence, index, count, length or padding');
 end
 valid(k)=v; payload{k}=b(49:48+v);
end
payload=vertcat(payload{:}); map=struct('sequence',uint16(sequence),'fragmentCount',count,'validPayloadBits',valid,'totalPayloadBits',numel(payload));
end
function x=unpack(b), x=sum(double(b(:)').*2.^(numel(b)-1:-1:0)); end
