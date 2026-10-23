classdef TestDiagnosticCapture < matlab.unittest.TestCase
 methods(Test)
  function selectedWindowKeepsTruthSeparateAndReplaysExactly(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
   cfg.logging.saveWaveforms=true; cfg.phy.nprachThreshold=1;
   sim=nbiot.NBIoTSimulator(cfg); sim.run(100); before=sim.snapshot();
   out=tempname; t.addTeardown(@() removeFolder(out)); mkdir(out);
   options=struct('direction','UL','receiverId',0,'startSample',99*1920,...
    'endSample',100*1920,'byteBudget',512*1024,'outputFolder',out);
   artifact=captureFailure(sim,options);
   receiver=load(artifact.receiverFile); truth=load(artifact.truthFile);
   t.verifyFalse(isfield(receiver,'truth')); t.verifyFalse(isfield(receiver,'scenario'));
   t.verifyTrue(isfield(truth,'truth')); t.verifyLessThanOrEqual(artifact.totalBytes,options.byteBudget);
   t.verifyEqual(receiver.rx,sim.channel.receive('UL',0,99*1920,100*1920));
   t.verifyEqual(sim.snapshot(),before);
  end
  function captureDoesNotChangeEventsKpiOrRandomness(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
   cfg.logging.saveWaveforms=true; cfg.phy.nprachThreshold=1; cfg.simulation.durationTicks=500;
   a=nbiot.NBIoTSimulator(cfg); a.run(100); b=nbiot.NBIoTSimulator(cfg); b.run(100);
   out=tempname; t.addTeardown(@() removeFolder(out)); mkdir(out);
   captureFailure(a,struct('direction','DL','receiverId',1,'startSample',99*1920,...
    'endSample',100*1920,'byteBudget',512*1024,'outputFolder',out));
   a.run(); b.run(); x=a.result(); y=b.result(); x.profiling=[]; y.profiling=[];
   t.verifyEqual(x,y);
  end
  function serializedBudgetFailureRollsBackItsPrivateFolder(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
   cfg.phy.nprachThreshold=1; cfg.logging.saveWaveforms=true;
   sim=nbiot.NBIoTSimulator(cfg); sim.run(10);
   out=tempname; t.addTeardown(@() removeFolder(out)); mkdir(out);
   options=struct('direction','UL','receiverId',0,'startSample',9*1920,...
    'endSample',10*1920,'byteBudget',512*1024,'outputFolder',out);
   artifact=captureFailure(sim,options); rawBytes=16*1920;
   options.byteBudget=floor((rawBytes+artifact.totalBytes)/2);
   t.verifyGreaterThan(options.byteBudget,rawBytes);
   t.verifyError(@() captureFailure(sim,options),'nbiot:diagnostics:Budget');
   t.verifyNumElements(dir(fullfile(out,'capture-*')),1);
   t.verifyTrue(isfile(artifact.markerFile));
  end
  function budgetAndDisabledCaptureFailBeforeWriting(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
   cfg.phy.nprachThreshold=1; sim=nbiot.NBIoTSimulator(cfg); sim.run(10);
   out=tempname; t.addTeardown(@() removeFolder(out)); mkdir(out);
   options=struct('direction','UL','receiverId',0,'startSample',9*1920,...
    'endSample',10*1920,'byteBudget',1,'outputFolder',out);
   t.verifyError(@() captureFailure(sim,options),'nbiot:diagnostics:Disabled');
   cfg.logging.saveWaveforms=true; sim=nbiot.NBIoTSimulator(cfg); sim.run(10);
   t.verifyError(@() captureFailure(sim,options),'nbiot:diagnostics:Budget');
   t.verifyEmpty(dir(fullfile(out,'capture-*')));
  end
 end
end
function removeFolder(folder)
assert(startsWith(char(java.io.File(folder).getCanonicalPath()),...
    char(java.io.File(tempdir).getCanonicalPath()),'IgnoreCase',true),'Unexpected cleanup path');
if isfolder(folder), rmdir(folder,'s'); end
end
