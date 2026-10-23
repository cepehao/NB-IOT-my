function result=runExperiment(cfg,scenario,execution,controllerOptions)
%RUNEXPERIMENT Construct, run and return a waveform experiment.
if nargin<1, cfg=nbiot.config.defaultConfig(); end
if nargin<2, scenario=[]; end
if nargin<3, execution=struct(); end
if nargin<4, controllerOptions=struct(); end
sim=nbiot.NBIoTSimulator(cfg,scenario,execution,controllerOptions);
sim.run(); result=sim.result();
end
