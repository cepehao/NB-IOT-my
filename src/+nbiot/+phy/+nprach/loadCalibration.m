function cfg=loadCalibration(cfg,path)
%LOADCALIBRATION Загружает порог детектора NPRACH из файла калибровки в конфигурацию.
%   CFG = nbiot.phy.nprach.loadCalibration(CFG, PATH), обычно
%   PATH = fullfile(<корень проекта>, 'results', 'nprach-calibration.mat').
%   Калибровка (examples/calibrateNprach.m) подбирает порог по целевой вероятности ложной тревоги
%   на окнах только с шумом. Порог действителен только для той же конфигурации NPRACH и той же версии
%   детектора (nbiot.phy.nprach.receiverRevision) — иначе ошибка nbiot:phy:Calibration.
%   Выход: cfg.phy.nprachThreshold — порог (0, 1]; cfg.calibrationReport — отчёт калибровки.
if ~isfile(path)
    error('nbiot:phy:Calibration','Missing %s. Run examples/calibrateNprach.m.',path);
end
data=load(path,'report');
if ~isfield(data,'report') || ~isfield(data.report,'accepted') || ~data.report.accepted
    error('nbiot:phy:Calibration','Calibration is absent or did not pass noise validation.');
end
r=data.report;
% Профиль, для которого порог действителен: конфигурация NPRACH, канал и версия детектора.
required=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId,'format',cfg.ra.format, ...
    'periodTicks',cfg.ra.periodTicks,'numSubcarriers',cfg.ra.numSubcarriers,'repetitions',cfg.ra.repetitions, ...
    'sampleRateHz',cfg.simulation.sampleRateHz,'fractionalFilterLength',cfg.channel.fractionalFilterLength,...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(),'cfoLimitHz',cfg.channel.cfoLimitHz);
if ~isfield(r,'profile') || ~isequal(r.profile,required) || ~isequal(r.cfoGridHz,cfg.phy.nprachCfoGridHz)
    error('nbiot:phy:Calibration','Calibration profile or CFO grid differs; recalibrate.');
end
cfg.phy.nprachThreshold=r.threshold; cfg.calibrationReport=r;
end
