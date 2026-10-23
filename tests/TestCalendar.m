classdef TestCalendar < matlab.unittest.TestCase
    methods (Test)
        function atomicConflict(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg);
            a=TestCalendar.plan('UL','RA',0:2,0,45000,1);
            b=TestCalendar.plan('UL','RA',2:4,0,45000,2);
            before=c.usage(); t.verifyFalse(c.reserveTransaction([a b])); t.verifyEqual(c.usage(),before);
            t.verifyTrue(c.reserveTransaction(a)); t.verifyFalse(c.reserveTransaction(b));
        end
        function mandatoryAndMonitoring(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg);
            p=TestCalendar.plan('DL','RA',0,0,180000,1); t.verifyFalse(c.canReserve(p));
            t.verifyEqual(c.monitoringTicks(0),[1 2 3 4]);
            [~,k]=nbiot.scheduler.mandatoryDlMask(2560,1);
            expected=(164:20:304)+(0:640:1920)'; t.verifyEqual(find(k.sib1)-1,sort(expected(:)));
        end
        function quotaAndRelease(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg);
            a=TestCalendar.plan('UL','RA',0:49,0,180000,1); t.verifyTrue(c.reserveTransaction(a));
            b=TestCalendar.plan('UL','RA',50,0,3750,2); t.verifyFalse(c.canReserve(b));
            other=b; other.ticks=500; t.verifyTrue(c.canReserve(other));
            c.releaseUnstarted(1,1); t.verifyFalse(c.canReserve(b));
            c.releaseUnstarted(1,0); t.verifyTrue(c.canReserve(b));
        end
        function disjointFrequencyAndDirection(t)
            cfg=nbiot.config.defaultConfig(); c=nbiot.scheduler.ResourceCalendar(cfg);
            a=TestCalendar.plan('UL','DT',1:4,0,45000,1); b=a; b.frequencyStartHz=45000; b.grantId=2;
            d=TestCalendar.plan('DL','DT',1:4,0,180000,3); t.verifyTrue(c.reserveTransaction([a b d]));
        end
    end
    methods (Static)
        function p=plan(direction,phase,ticks,f,b,id)
            p=struct('direction',direction,'phase',phase,'ticks',ticks,'frequencyStartHz',f,'bandwidthHz',b,'grantId',id);
        end
    end
end
