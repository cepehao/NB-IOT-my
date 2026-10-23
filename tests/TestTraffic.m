classdef TestTraffic < matlab.unittest.TestCase
 methods (Test)
  function burstReplay(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=20;
   r=nbiot.randomness.RandomSources(42,0); a=nbiot.traffic.generateArrivals(c,r);
   test.verifyEqual(a,nbiot.traffic.generateArrivals(c,r)); test.verifyNumElements(a,20);
   test.verifyGreaterThanOrEqual(double([a.createdTick]),1000); test.verifyLessThanOrEqual(double([a.createdTick]),1100);
   test.verifyClass(a(1).payloadBits,'int8'); test.verifyNumElements(a(1).payloadBits,1600);
  end
  function periodicSpacingAndHorizon(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=3; c.traffic.kind='periodic';
   a=nbiot.traffic.generateArrivals(c,nbiot.randomness.RandomSources(42,0));
   for id=1:3, x=a([a.ueId]==id); test.verifyEqual(diff(double([x.createdTick])),1000*ones(1,numel(x)-1)); end
   test.verifyLessThan(double([a.createdTick]),5000);
  end
  function emptyAndZeroRate(test)
   c=nbiot.config.defaultConfig(); c.traffic.kind='none'; r=nbiot.randomness.RandomSources(42,0);
   test.verifyEmpty(nbiot.traffic.generateArrivals(c,r)); c.traffic.kind='poisson'; c.traffic.poissonRatePerSecond=0;
   test.verifyEmpty(nbiot.traffic.generateArrivals(c,r));
  end
  function poissonEnsembleCount(test)
   % 2000 independent UE, expected 2000 arrivals over five seconds.
   c=nbiot.config.defaultConfig(); c.simulation.numUE=2000; c.traffic.kind='poisson';
   a=nbiot.traffic.generateArrivals(c,nbiot.randomness.RandomSources(42,5));
   test.verifyLessThan(abs(numel(a)-2000),250);
   test.verifyGreaterThan(double([a.createdTick]),0);
   test.verifyLessThan(double([a.createdTick]),5000);
  end
 end
end
