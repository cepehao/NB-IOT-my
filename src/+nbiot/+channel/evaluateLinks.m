function links=evaluateLinks(cfg,ue)
%EVALUATELINKS Опорный link budget по UE без быстрых замираний (ТЗ §13, проверка §32).
%   LINKS = nbiot.channel.evaluateLinks(CFG, UE). Для каждого UE в полосе 180 кГц:
%     receivedPowerUlDbm = P_UE − PL,  receivedPowerDlDbm = P_BS − PL   (дБм);
%     шум N = 10·lg(k·T·10^(NF/10)·B) + 30 (дБм), NF BS 5 дБ / UE 7 дБ;
%     referenceSnrUlDb / referenceSnrDlDb = P_rx − N (дБ).
%   Используется для таблиц и GUI; решения приёмников по нему НЕ принимаются (только waveform).
% Проверяем конфигурацию.
cfg=nbiot.config.validateConfig(cfg);
% У UE должны быть номер и итоговые потери.
if ~isstruct(ue)||~isfield(ue,'ueId')||~isfield(ue,'pathLossDb')
    error('nbiot:channel:InvalidLinkInput', ...
        'UE input must contain ueId and pathLossDb fields.');
end
% Номера UE столбцом.
ueId=uint32([ue.ueId].');
% Итоговые потери UE (дБ) столбцом.
pathLossDb=double([ue.pathLossDb].');
% Номера уникальные и ненулевые, потери — конечные неотрицательные;
if numel(unique(ueId))~=numel(ueId)||any(ueId==0)|| ...
        any(~isfinite(pathLossDb))||any(pathLossDb<0)
    % иначе ошибка входных данных.
    error('nbiot:channel:InvalidLinkInput', ...
        'UE identifiers must be unique and path loss must be finite and nonnegative.');
end

% Опорная полоса — вся полоса NB-IoT 180 кГц.
referenceBandwidthHz=180e3;
% Постоянная Больцмана, Дж/К.
boltzmannJPerK=1.380649e-23;
% Параметры канала.
channel=cfg.channel;
% Спектральная плотность шума приёмника BS: k·T·10^(NF/10), Вт/Гц.
noisePsdBsWPerHz=boltzmannJPerK*channel.temperatureK* ...
    10^(channel.bsNoiseFigureDb/10);
% То же для приёмника UE (свой коэффициент шума).
noisePsdUeWPerHz=boltzmannJPerK*channel.temperatureK* ...
    10^(channel.ueNoiseFigureDb/10);
% Мощность шума BS в полосе 180 кГц, дБм (+30 — перевод дБВт в дБм).
noisePowerBsDbm=10*log10(noisePsdBsWPerHz*referenceBandwidthHz)+30;
% Мощность шума UE в полосе 180 кГц, дБм.
noisePowerUeDbm=10*log10(noisePsdUeWPerHz*referenceBandwidthHz)+30;
% Принимаемая мощность на BS: мощность UE − потери.
receivedPowerUlDbm=channel.uePowerDbm-pathLossDb;
% Принимаемая мощность на UE: мощность BS − потери.
receivedPowerDlDbm=channel.bsPowerDbm-pathLossDb;
% Опорный SNR UL на BS.
referenceSnrUlDb=receivedPowerUlDbm-noisePowerBsDbm;
% Опорный SNR DL на UE.
referenceSnrDlDb=receivedPowerDlDbm-noisePowerUeDbm;

% Шаблон записи link budget.
template=struct('ueId',uint32(0),'referenceBandwidthHz',0, ...
    'receivedPowerUlDbm',0,'receivedPowerDlDbm',0, ...
    'noisePsdBsWPerHz',0,'noisePsdUeWPerHz',0, ...
    'referenceSnrUlDb',0,'referenceSnrDlDb',0);
% Массив записей по числу UE.
links=repmat(template,numel(ueId),1);
% Для каждого UE:
for k=1:numel(ueId)
    % запись: номер, полоса, мощности приёма, плотности шума, SNR UL/DL.
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
