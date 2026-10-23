classdef TestSchedulingFairness < matlab.unittest.TestCase
 methods(Test)
  function earliestDeadlinePrecedesContextId(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.traffic.kind='none';
   cfg.phy.nprachThreshold=1; sim=nbiot.NBIoTSimulator(cfg); sim.run(16);
   first=addRequest(sim,400,0); second=addRequest(sim,300,0);
   sim.step(); a=sim.contexts.get(first); b=sim.contexts.get(second);
   t.verifyEqual(a.state,'DATA_RX'); t.verifyEqual(b.state,'DATA_RX');
   t.verifyLessThan(b.schedule.controlGrant.startTick,a.schedule.controlGrant.startTick);
  end
  function requeuedRequestDoesNotStarveOlderPeers(t)
   cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=1; cfg.simulation.durationTicks=500;
   cfg.traffic.kind='none'; cfg.phy.nprachThreshold=1;
   sim=nbiot.NBIoTSimulator(cfg); sim.run(16);
   ids=[addRequest(sim,490,0),addRequest(sim,490,0),addRequest(sim,490,0)];
   first=sim.calendar.monitoringTicks(32); first=first(1:2);
   % Leave only one public monitoring pair available. Fill RA then DT;
   % this leaves DT quota for the allowed pair, without quota borrowing.
   for tick=find(~sim.calendar.mandatoryMask(:))'-1
    if any(first==tick), continue; end
    reserved=false;
    for phase={'RA','DT'}
     plan=struct('direction','DL','phase',phase{1},'ticks',tick,...
      'frequencyStartHz',0,'bandwidthHz',180000,'grantId',400000+tick);
     if sim.calendar.reserveTransaction(plan), reserved=true; break; end
    end
    t.assertTrue(reserved,'Unable to build a finite-resource scheduling fixture.');
   end
   sim.step(); t.verifyEqual(sim.contexts.get(ids(1)).state,'DATA_RX');
   t.verifyTrue(sim.contexts.get(ids(2)).pending); t.verifyTrue(sim.contexts.get(ids(3)).pending);
   sim.run(24); requeue(sim,ids(1));
   pair=sim.calendar.monitoringTicks(96); pair=pair(1:2);
   for tick=pair, sim.calendar.releaseUnstarted(400000+tick,25); end
   sim.step(); t.verifyEqual(sim.contexts.get(ids(2)).state,'DATA_RX');
   t.verifyTrue(sim.contexts.get(ids(1)).pending); t.verifyTrue(sim.contexts.get(ids(3)).pending);
   requeue(sim,ids(2)); pair=sim.calendar.monitoringTicks(192); pair=pair(1:2);
   for tick=pair, sim.calendar.releaseUnstarted(400000+tick,26); end
   sim.step(); t.verifyEqual(sim.contexts.get(ids(3)).state,'DATA_RX');
   t.verifyTrue(sim.contexts.get(ids(1)).pending); t.verifyTrue(sim.contexts.get(ids(2)).pending);
  end
 end
end
function id=addRequest(sim,deadline,last)
id=sim.contexts.create(0,1,deadline,0); c=sim.contexts.get(id);
c.state='DATA_PENDING'; c.lastProgressTick=last; sim.contexts.set(id,c);
end
function requeue(sim,id)
c=sim.contexts.get(id); c.state='DATA_PENDING'; c.pending=true; sim.contexts.set(id,c);
end

