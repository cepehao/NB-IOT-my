classdef TestEngine < matlab.unittest.TestCase
    methods (Test)
        function stableCompletionOrder(t)
            q=nbiot.engine.EventQueue(); q.push(8,'first',1); q.push(3,'early',2); q.push(8,'second',3);
            t.verifyEqual(q.nextTick(),3); e=q.popReady(8);
            t.verifyEqual({e.kind},{'early','first','second'}); t.verifyEqual(q.count(),0);
        end
        function waitsForPhysicalEnd(t)
            q=nbiot.engine.EventQueue(); q.push(33,'rx',struct());
            t.verifyEmpty(q.popReady(32)); t.verifyEqual(q.count(),1);
        end
    end
end
