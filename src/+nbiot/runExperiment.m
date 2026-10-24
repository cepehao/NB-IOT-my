function result=runExperiment(cfg,scenario,controllerOptions)
%RUNEXPERIMENT Один полный прогон симулятора: создать, выполнить до горизонта, вернуть результат.
%   RESULT = nbiot.runExperiment(CFG) — сценарий строится по cfg.simulation.seed/realizationId.
%   RESULT = nbiot.runExperiment(CFG, SCENARIO) — на готовой внешней реализации (ТЗ §63:
%   Static и Adaptive сравниваются на одном SCENARIO).
%   RESULT = nbiot.runExperiment(CFG, SCENARIO, CONTROLLEROPTIONS) — для Adaptive-*: оценщик нагрузки
%   и политика (nbiot.controller.prepareRuntime).
%   CFG должен содержать калиброванный порог NPRACH (nbiot.phy.nprach.loadCalibration).
%   См. также nbiot.NBIoTSimulator.
% Без аргументов — базовая конфигурация ТЗ.
if nargin<1, cfg=nbiot.config.defaultConfig(); end
% Без сценария — он будет построен симулятором по seed и номеру реализации.
if nargin<2, scenario=[]; end
% Без опций контроллера — режим Static.
if nargin<3, controllerOptions=struct(); end
% Создание симулятора: проверка конфигурации, сценарий, все модули.
sim=nbiot.NBIoTSimulator(cfg,scenario,controllerOptions);
% Прогон до горизонта и сборка результата.
sim.run(); result=sim.result();
end
