function scenario=buildScenario(cfg,sources)
%BUILDSCENARIO Immutable geometry, slow fading and pre-generated traffic.
cfg=nbiot.config.validateConfig(cfg);
if nargin<2, sources=nbiot.randomness.RandomSources(cfg.simulation.seed,cfg.simulation.realizationId); end
n=cfg.simulation.numUE; c=cfg.cell; h=cfg.channel;
s=sources.stream('layout',0,0,0); indoor=false(n,1); [~,order]=sort(rand(s,n,1)); indoor(order(1:round(c.indoorFraction*n)))=true;
ue=repmat(struct('ueId',uint32(0),'xM',0,'yM',0,'indoor',false,'distanceM',0,'horizontalDistanceM',0,'pathLossDb',0,'medianPathLossDb',0,'shadowingDb',0,'penetrationDb',0,'cfoHz',0,'syncOffsetSeconds',0,'tapsUl',[],'tapsDl',[],'coverageClass','CE0'),n,1);
p=10.^(h.tapPowersDb(:)/10); p=p/sum(p);
ref=20*log10(4*pi*h.carrierHz*h.referenceDistanceM/299792458);
for id=1:n
 s=sources.stream('layout',0,id,0); radius=sqrt(c.minDistanceM^2+(c.radiusM^2-c.minDistanceM^2)*rand(s)); angle=2*pi*rand(s);
 u=ue(id); u.ueId=uint32(id); u.xM=radius*cos(angle); u.yM=radius*sin(angle); u.horizontalDistanceM=radius; u.indoor=indoor(id); u.distanceM=hypot(radius,c.bsHeightM-c.ueHeightM);
 u.medianPathLossDb=ref+10*h.pathLossExponent*log10(max(u.distanceM,h.referenceDistanceM)/h.referenceDistanceM);
 sigma=h.shadowOutdoorDb; if u.indoor, sigma=h.shadowIndoorDb; u.penetrationDb=h.penetrationIndoorDb; end
 s=sources.stream('shadowing',0,id,0); u.shadowingDb=sigma*randn(s); u.pathLossDb=max(0,u.medianPathLossDb+u.shadowingDb+u.penetrationDb);
 s=sources.stream('CFO',0,id,0); u.cfoHz=0;
 if h.cfoLimitHz>0&&h.cfoSigmaHz>0
  % Inverse-CDF sampling avoids unbounded rejection for narrow limits.
  a=.5*(1+erf(-h.cfoLimitHz/(h.cfoSigmaHz*sqrt(2)))); b=1-a;
  u.cfoHz=h.cfoSigmaHz*sqrt(2)*erfinv(2*(a+(b-a)*rand(s))-1);
 end
 s=sources.stream('timing',0,id,0); u.syncOffsetSeconds=(2*rand(s)-1)*h.syncLimitSeconds;
 s=sources.stream('channel',0,id,0); u.tapsUl=sqrt(p/2).*(randn(s,numel(p),1)+1i*randn(s,numel(p),1));
 s=sources.stream('channel',1,id,0); u.tapsDl=sqrt(p/2).*(randn(s,numel(p),1)+1i*randn(s,numel(p),1)); ue(id)=u;
end
scenario=struct('ue',ue,'linkBudget',nbiot.channel.evaluateLinks(cfg,ue), ...
 'arrivals',nbiot.traffic.generateArrivals(cfg,sources), ...
 'randomManifest',sources.manifest(),'externalRealizationId',sources.realizationId);
end
