classdef TestConfig < matlab.unittest.TestCase
 methods (Test)
  function baseline(test)
   c=nbiot.config.validateConfig(nbiot.config.defaultConfig());
   test.verifyEqual(c.simulation.durationTicks,5000); test.verifyEqual(c.traffic.queueLimit,10);
   test.verifyEqual(c.phy.data.tbs,256); test.verifyTrue(isnan(c.phy.nprachThreshold));
  end
  function invalidInputs(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=0;
   test.verifyError(@()nbiot.config.validateConfig(c),'nbiot:config:InvalidValue');
   c=nbiot.config.defaultConfig(); c.traffic.queueLimit=-1;
   test.verifyError(@()nbiot.config.validateConfig(c),'nbiot:config:InvalidValue');
   c=nbiot.config.defaultConfig(); c.phy.data.repetitions=3;
   test.verifyError(@()nbiot.config.validateConfig(c),'nbiot:config:UnsupportedProfile');
   c=nbiot.config.defaultConfig(); c.ra.periodTicks=10; c.ra.startOffsetTicks=8;
   test.verifyError(@()nbiot.config.validateConfig(c),'nbiot:config:ResourceInfeasible');
  end
 end
end
