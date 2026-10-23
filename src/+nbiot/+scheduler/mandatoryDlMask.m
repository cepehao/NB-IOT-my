function [mask,kinds]=mandatoryDlMask(durationTicks,cellId)
% Release-13 FDD mask, schedulingInfoSIB1=0 (four repetitions).
% Each repetition spans eight even frames in its 160 ms transmission block;
% blocks repeat every 640 ms, initial frame = 16*(NCellID mod 4).
t=(0:durationTicks-1)'; frame=floor(t/10); sf=mod(t,10);
npbch=sf==0; npss=sf==5; nsss=sf==9 & mod(frame,2)==0;
relative=mod(frame-16*mod(cellId,4),64);
sib1=sf==4 & relative<16 & mod(relative,2)==0;
mask=npbch|npss|nsss|sib1;
kinds=struct('npbch',npbch,'npss',npss,'nsss',nsss,'sib1',sib1);
end
