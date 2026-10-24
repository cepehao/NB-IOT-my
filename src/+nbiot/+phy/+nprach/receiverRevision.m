function revision=receiverRevision()
%RECEIVERREVISION Идентификатор версии алгоритма детектора NPRACH. Калибровка порога
%   (results/nprach-calibration.mat) действительна только для этой версии: при изменении
%   статистики детектора версию нужно сменить и откалибровать порог заново (examples/calibrateNprach).
% Текущая версия алгоритма: групповая статистика + подтверждение по шаблону с поиском CFO.
revision='group-partial-cfo-match-v3';
end
