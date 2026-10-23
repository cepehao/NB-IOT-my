classdef TestLayout < matlab.unittest.TestCase
 methods (Test)
  function geometryAndStaticStreams(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=40; c.traffic.kind='none';
   r=nbiot.randomness.RandomSources(42,0); s=nbiot.scenario.buildScenario(c,r);
   test.verifyEqual(sum([s.ue.indoor]),12); radius=hypot([s.ue.xM],[s.ue.yM]);
   test.verifyGreaterThanOrEqual(radius,10); test.verifyLessThanOrEqual(radius,1000);
   test.verifyEqual([s.ue.distanceM],sqrt(radius.^2+28.5^2),'AbsTol',1e-10);
   test.verifyLessThanOrEqual(abs([s.ue.cfoHz]),200); test.verifyLessThanOrEqual(abs([s.ue.syncOffsetSeconds]),2e-6);
   test.verifyEqual(s,nbiot.scenario.buildScenario(c,r)); test.verifyNotEqual(s.ue(1).tapsUl,s.ue(1).tapsDl);
  end
 end
end
