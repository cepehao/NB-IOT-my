function [blocks,map]=segmentPacket(bits,sequence)
%SEGMENTPACKET MSB-first 48 bit wrapper, zero-based fragment indices.
validateattributes(bits,{'numeric','logical'},{'vector','nonempty'});
if any(bits(:)~=0&bits(:)~=1), error('nbiot:traffic:MalformedPacket','Nonbinary payload'); end
validateattributes(sequence,{'numeric'},{'scalar','integer','>=',0,'<=',65535});
bits=int8(bits(:)); count=ceil(numel(bits)/208);
if count>255, error('nbiot:traffic:MalformedPacket','Too many fragments'); end
blocks=cell(count,1); valid=zeros(count,1);
for k=1:count
 first=(k-1)*208+1; valid(k)=min(208,numel(bits)-first+1);
 header=[pack(sequence,16);pack(k-1,8);pack(count,8);pack(valid(k),8);zeros(8,1,'int8')];
 blocks{k}=[header;bits(first:first+valid(k)-1);zeros(208-valid(k),1,'int8')];
end
map=struct('sequence',uint16(sequence),'fragmentCount',count,'validPayloadBits',valid,'totalPayloadBits',numel(bits),'headerBits',48,'transportBlockBits',256);
end
function b=pack(x,n), b=int8(bitget(uint32(x),n:-1:1))'; end
