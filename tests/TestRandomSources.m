classdef TestRandomSources < matlab.unittest.TestCase
 methods (Test)
  function replayIndependentOfOrder(test)
   r=nbiot.randomness.RandomSources(42,0);
   a=randn(r.stream('noise',0,0,101),40,1);
   randn(r.stream('noise',1,7,10),200,1);
   b=randn(r.stream('noise',0,0,101),40,1);
   test.verifyEqual(a,b); test.verifyNotEqual(a,randn(r.stream('noise',0,0,102),40,1));
   r2=nbiot.randomness.RandomSources(42,1); test.verifyNotEqual(a,randn(r2.stream('noise',0,0,101),40,1));
  end
  function exactMappingAndBounds(test)
   test.verifyEqual(nbiot.randomness.substreamKey('layout',0,0,0),1+2^41);
   test.verifyEqual(nbiot.randomness.substreamKey('token',1,65535,2^24-1),24*2^40);
   test.verifyError(@()nbiot.randomness.substreamKey('noise','UL',0,1),'nbiot:randomness:InvalidKey');
   test.verifyError(@()nbiot.randomness.substreamKey('noise',0,0,2^24),'nbiot:randomness:InvalidKey');
  end
 end
end
