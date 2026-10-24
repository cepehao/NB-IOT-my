function [mask,kinds]=mandatoryDlMask(durationTicks,cellId)
%MANDATORYDLMASK Обязательные DL-подкадры соты на горизонте (FDD, Release 13; schedulingInfoSIB1 = 0).
%   NPBCH — подкадр 0 каждого кадра; NPSS — подкадр 5; NSSS — подкадр 9 чётных кадров;
%   SIB1-NB — подкадр 4 чётных кадров в первых 16 кадрах каждого блока 640 мс,
%   начальный кадр 16·(NCellID mod 4). MASK — логический столбец; KINDS — маски по типам.
% Тики 0..N−1; номер кадра (10 подкадров) и подкадра для каждого тика.
t=(0:durationTicks-1)'; frame=floor(t/10); sf=mod(t,10);
% NPBCH — подкадр 0; NPSS — подкадр 5; NSSS — подкадр 9 чётных кадров.
npbch=sf==0; npss=sf==5; nsss=sf==9 & mod(frame,2)==0;
% Номер кадра относительно начала блока SIB1 (период 64 кадра = 640 мс).
relative=mod(frame-16*mod(cellId,4),64);
% SIB1-NB — подкадр 4 чётных кадров в первых 16 кадрах блока.
sib1=sf==4 & relative<16 & mod(relative,2)==0;
% Обязательный подкадр — любой из этих сигналов.
mask=npbch|npss|nsss|sib1;
% Маски по типам сигналов.
kinds=struct('npbch',npbch,'npss',npss,'nsss',nsss,'sib1',sib1);
end
