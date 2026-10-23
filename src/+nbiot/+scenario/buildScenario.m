function scenario=buildScenario(cfg,sources)
%BUILDSCENARIO Внешняя реализация: размещение UE, параметры канала и расписание трафика (ТЗ §10, §13).
%   SCENARIO = nbiot.scenario.buildScenario(CFG, SOURCES) генерирует всё один раз на реализацию,
%   поэтому Static и Adaptive получают идентичные координаты, shadowing, CFO, fading и трафик
%   (ТЗ §28, §43, §63). SOURCES по умолчанию — RandomSources(seed, realizationId).
%
%   Выход SCENARIO:
%     ue(N)        — по UE: координаты xM,yM (м), indoor, расстояния (2D/3D, м), медианные потери,
%                    shadowing и penetration (дБ), итоговые pathLossDb, cfoHz (Гц), syncOffsetSeconds,
%                    отводы fading tapsUl/tapsDl (комплексные), coverageClass ('CE0' для всех).
%     linkBudget   — мощности приёма и SNR (nbiot.channel.evaluateLinks).
%     arrivals     — расписание пакетов (nbiot.traffic.generateArrivals).
%     randomManifest, externalRealizationId — для воспроизводимости (ТЗ §42).
cfg=nbiot.config.validateConfig(cfg);
if nargin<2, sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId); end
n=cfg.simulation.numUE; c=cfg.cell; h=cfg.channel;
% Ровно round(0,30·N) indoor UE: случайное подмножество (ТЗ §10, правило — решение).
s=sources.stream('layout',0,0,0); indoor=false(n,1); [~,order]=sort(rand(s,n,1)); indoor(order(1:round(c.indoorFraction*n)))=true;
ue=repmat(struct('ueId',uint32(0),'xM',0,'yM',0,'indoor',false,'distanceM',0,'horizontalDistanceM',0,'pathLossDb',0,'medianPathLossDb',0,'shadowingDb',0,'penetrationDb',0,'cfoHz',0,'syncOffsetSeconds',0,'tapsUl',[],'tapsDl',[],'coverageClass','CE0'),n,1);
% Нормированный профиль мощности отводов fading (сумма = 1).
p=10.^(h.tapPowersDb(:)/10); p=p/sum(p);
% Потери в свободном пространстве на опорном расстоянии d0 = 10 м: 20·lg(4π·f·d0/c).
ref=20*log10(4*pi*h.carrierHz*h.referenceDistanceM/299792458);
for id=1:n
 % Равномерно по площади кольца [rMin, R]: r = sqrt(rMin² + u·(R² − rMin²)), угол равномерный.
 s=sources.stream('layout',0,id,0); radius=sqrt(c.minDistanceM^2+(c.radiusM^2-c.minDistanceM^2)*rand(s)); angle=2*pi*rand(s);
 % Расстояние для потерь — трёхмерное, с учётом разницы высот BS и UE.
 u=ue(id); u.ueId=uint32(id); u.xM=radius*cos(angle); u.yM=radius*sin(angle); u.horizontalDistanceM=radius; u.indoor=indoor(id); u.distanceM=hypot(radius,c.bsHeightM-c.ueHeightM);
 % Log-distance: PL(d) = PL(d0) + 10·n·lg(d/d0), n = cfg.channel.pathLossExponent.
 u.medianPathLossDb=ref+10*h.pathLossExponent*log10(max(u.distanceM,h.referenceDistanceM)/h.referenceDistanceM);
 % Indoor: больший σ shadowing и потери проникновения 20 дБ (ТЗ §13).
 sigma=h.shadowOutdoorDb; if u.indoor, sigma=h.shadowIndoorDb; u.penetrationDb=h.penetrationIndoorDb; end
 s=sources.stream('shadowing',0,id,0); u.shadowingDb=sigma*randn(s); u.pathLossDb=max(0,u.medianPathLossDb+u.shadowingDb+u.penetrationDb);
 % CFO ~ N(0, σ²), усечённое в ±cfoLimitHz (ТЗ §13, §17).
 s=sources.stream('CFO',0,id,0); u.cfoHz=0;
 if h.cfoLimitHz>0&&h.cfoSigmaHz>0
  % Inverse-CDF sampling avoids unbounded rejection for narrow limits.
  a=.5*(1+erf(-h.cfoLimitHz/(h.cfoSigmaHz*sqrt(2)))); b=1-a;
  u.cfoHz=h.cfoSigmaHz*sqrt(2)*erfinv(2*(a+(b-a)*rand(s))-1);
 end
 % Остаточная рассинхронизация UE — равномерно в ±syncLimitSeconds.
 s=sources.stream('timing',0,id,0); u.syncOffsetSeconds=(2*rand(s)-1)*h.syncLimitSeconds;
 % Отводы Rayleigh: CN(0, p_k). UL и DL независимы (FDD), постоянны на всю реализацию.
 s=sources.stream('channel',0,id,0); u.tapsUl=sqrt(p/2).*(randn(s,numel(p),1)+1i*randn(s,numel(p),1));
 s=sources.stream('channel',1,id,0); u.tapsDl=sqrt(p/2).*(randn(s,numel(p),1)+1i*randn(s,numel(p),1)); ue(id)=u;
end
scenario=struct('ue',ue,'linkBudget',nbiot.channel.evaluateLinks(cfg,ue), ...
 'arrivals',nbiot.traffic.generateArrivals(cfg,sources), ...
 'randomManifest',sources.manifest(),'externalRealizationId',sources.realizationId);
end
