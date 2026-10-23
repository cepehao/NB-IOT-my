function result=runExperiment(cfg,scenario,execution,controllerOptions)
%RUNEXPERIMENT Один полный прогон симулятора: создать, выполнить до горизонта, вернуть результат.
%   RESULT = nbiot.runExperiment(CFG) — сценарий строится по cfg.simulation.seed/realizationId.
%   RESULT = nbiot.runExperiment(CFG, SCENARIO) — на готовой внешней реализации (ТЗ §63:
%   Static и Adaptive сравниваются на одном SCENARIO).
%   EXECUTION — бюджет времени (инфраструктура), CONTROLLEROPTIONS — модель и политика контроллера.
%   CFG должен содержать калиброванный порог NPRACH (nbiot.experiments.loadCalibration).
%   См. также nbiot.NBIoTSimulator.
if nargin<1, cfg=nbiot.config.defaultConfig(); end
if nargin<2, scenario=[]; end
if nargin<3, execution=struct(); end
if nargin<4, controllerOptions=struct(); end
sim=nbiot.NBIoTSimulator(cfg,scenario,execution,controllerOptions);
sim.run(); result=sim.result();
end
