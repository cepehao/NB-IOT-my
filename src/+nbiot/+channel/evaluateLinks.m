function links=evaluateLinks(cfg,ue)
%EVALUATELINKS Опорный link budget по UE без быстрых замираний (ТЗ §13, проверка §32).
%   LINKS = nbiot.channel.evaluateLinks(CFG, UE). Для каждого UE в полосе 180 кГц:
%     receivedPowerUlDbm = P_UE − PL,  receivedPowerDlDbm = P_BS − PL   (дБм);
%     шум N = 10·lg(k·T·10^(NF/10)·B) + 30 (дБм), NF BS 5 дБ / UE 7 дБ;
%     referenceSnrUlDb / referenceSnrDlDb = P_rx − N (дБ).
%   Используется для таблиц и GUI; решения приёмников по нему НЕ принимаются (только waveform).
cfg=nbiot.config.validateConfig(cfg);
if ~isstruct(ue)||~isfield(ue,'ueId')||~isfield(ue,'pathLossDb')
    error('nbiot:channel:InvalidLinkInput', ...
        'UE input must contain ueId and pathLossDb fields.');
end
ueId=uint32([ue.ueId].');
pathLossDb=double([ue.pathLossDb].');
if numel(unique(ueId))~=numel(ueId)||any(ueId==0)|| ...
        any(~isfinite(pathLossDb))||any(pathLossDb<0)
    error('nbiot:channel:InvalidLinkInput', ...
        'UE identifiers must be unique and path loss must be finite and nonnegative.');
end

referenceBandwidthHz=180e3;
boltzmannJPerK=1.380649e-23;
channel=cfg.channel;
noisePsdBsWPerHz=boltzmannJPerK*channel.temperatureK* ...
    10^(channel.bsNoiseFigureDb/10);
noisePsdUeWPerHz=boltzmannJPerK*channel.temperatureK* ...
    10^(channel.ueNoiseFigureDb/10);
noisePowerBsDbm=10*log10(noisePsdBsWPerHz*referenceBandwidthHz)+30;
noisePowerUeDbm=10*log10(noisePsdUeWPerHz*referenceBandwidthHz)+30;
receivedPowerUlDbm=channel.uePowerDbm-pathLossDb;
receivedPowerDlDbm=channel.bsPowerDbm-pathLossDb;
referenceSnrUlDb=receivedPowerUlDbm-noisePowerBsDbm;
referenceSnrDlDb=receivedPowerDlDbm-noisePowerUeDbm;

template=struct('ueId',uint32(0),'referenceBandwidthHz',0, ...
    'receivedPowerUlDbm',0,'receivedPowerDlDbm',0, ...
    'noisePsdBsWPerHz',0,'noisePsdUeWPerHz',0, ...
    'referenceSnrUlDb',0,'referenceSnrDlDb',0);
links=repmat(template,numel(ueId),1);
for k=1:numel(ueId)
    links(k)=struct('ueId',ueId(k), ...
        'referenceBandwidthHz',referenceBandwidthHz, ...
        'receivedPowerUlDbm',receivedPowerUlDbm(k), ...
        'receivedPowerDlDbm',receivedPowerDlDbm(k), ...
        'noisePsdBsWPerHz',noisePsdBsWPerHz, ...
        'noisePsdUeWPerHz',noisePsdUeWPerHz, ...
        'referenceSnrUlDb',referenceSnrUlDb(k), ...
        'referenceSnrDlDb',referenceSnrDlDb(k));
end
end
