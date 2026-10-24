function result=runExperiment(cfg,scenario,controllerOptions)
%RUNEXPERIMENT Один полный прогон симулятора: создать, выполнить до горизонта, вернуть результат.
%   RESULT = nbiot.runExperiment(CFG) — сценарий строится по cfg.simulation.seed/realizationId.
%   RESULT = nbiot.runExperiment(CFG, SCENARIO) — на готовой внешней реализации (ТЗ §63:
%   Static и Adaptive сравниваются на одном SCENARIO).
%   RESULT = nbiot.runExperiment(CFG, SCENARIO, CONTROLLEROPTIONS) — для Adaptive-*: оценщик нагрузки
%   и политика (nbiot.controller.prepareRuntime).
%   CFG должен содержать калиброванный порог NPRACH (nbiot.phy.nprach.loadCalibration).
%   См. также nbiot.NBIoTSimulator.
if nargin<1, cfg=nbiot.config.defaultConfig(); end
if nargin<2, scenario=[]; end
if nargin<3, controllerOptions=struct(); end
sim=nbiot.NBIoTSimulator(cfg,scenario,controllerOptions);
sim.run(); result=sim.result();
end
