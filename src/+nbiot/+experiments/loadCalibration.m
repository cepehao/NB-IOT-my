function cfg=loadCalibration(cfg,path)
%LOADCALIBRATION Reject thresholds calibrated for a different receiver profile.
%   Загрузка порога детектора NPRACH из results/nprach-calibration.mat с проверкой, что калибровка
%   сделана для той же конфигурации NPRACH и версии детектора (receiverRevision).
if ~isfile(path), error('nbiot:phy:Calibration','Missing %s. Run calibrateNprach on the MATLAB PC.',path); end
calibrationSha=nbiot.ml.fileSha256(path);
data=load(path,'report');
if ~isfield(data,'report') || ~isfield(data.report,'accepted') || ~data.report.accepted
    error('nbiot:phy:Calibration','Calibration is absent or did not pass noise validation.');
end
r=data.report;
required=struct('version',cfg.profileVersion,'cellId',cfg.phy.cellId,'format',cfg.ra.format, ...
    'periodTicks',cfg.ra.periodTicks,'numSubcarriers',cfg.ra.numSubcarriers,'repetitions',cfg.ra.repetitions, ...
    'sampleRateHz',cfg.simulation.sampleRateHz,'fractionalFilterLength',cfg.channel.fractionalFilterLength,...
    'receiverRevision',nbiot.phy.nprach.receiverRevision(),'cfoLimitHz',cfg.channel.cfoLimitHz);
if ~isfield(r,'profile') || ~isequal(r.profile,required) || ~isequal(r.cfoGridHz,cfg.phy.nprachCfoGridHz)
    error('nbiot:phy:Calibration','Calibration profile or CFO grid differs; recalibrate.');
end
if ~strcmpi(calibrationSha,nbiot.ml.fileSha256(path))
    error('nbiot:phy:Calibration','Calibration file changed while it was being loaded.');
end
cfg.phy.nprachThreshold=r.threshold; cfg.calibrationReport=r;
cfg.calibrationFileSha256=calibrationSha;
end
