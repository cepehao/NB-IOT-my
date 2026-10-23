classdef TestPhyTables < matlab.unittest.TestCase
    methods (Test)
        function profileTbAndAllocations(test)
            test.verifyEqual(nbiot.phy.ProfileTables.ulTbs(4,3,3),256);
            test.verifyEqual(nbiot.phy.ProfileTables.dlTbs(6,0),88);
            p=nbiot.phy.ProfileTables.msg3Profile(2);
            test.verifyEqual([p.nru p.tbs p.durationTicks],[1 88 8]);
            for i=0:18
                tones=nbiot.phy.ProfileTables.decodeUlAssignment(i);
                test.verifyEqual(nbiot.phy.ProfileTables.encodeUlAssignment(tones),i);
            end
            test.verifyEqual(nbiot.phy.ProfileTables.decodeUlAssignment(12),0:2);
            test.verifyError(@()nbiot.phy.ProfileTables.ulTbs(12,7,3),'nbiot:phy:Reserved');
        end
        function dciBitLayouts(test)
            n0=struct('format','N0','subcarrierIndication',12,'resourceAssignment',3,...
                'schedulingDelay',0,'mcs',4,'rv',1,'repetitionNumber',1,'ndi',1,'dciRepetitions',1);
            b=nbiot.phy.npdcch.packDci(n0);
            test.verifyEqual(b,int8([0 0 0 1 1 0 0 0 1 1 0 0 0 1 0 0 1 0 0 1 1 0 1]'));
            test.verifyEqual(nbiot.phy.npdcch.unpackDci(b),n0);
            n1=struct('format','N1','order',0,'schedulingDelay',0,'resourceAssignment',0,...
                'mcs',6,'repetitionNumber',1,'ndi',0,'ackResource',15,'dciRepetitions',1);
            test.verifyEqual(nbiot.phy.npdcch.unpackDci(nbiot.phy.npdcch.packDci(n1)),n1);
        end
        function ackTiming(test)
            [tone,k0]=nbiot.phy.ProfileTables.ackResource(15);
            test.verifyEqual([tone k0],[3 18]);
            test.verifyEqual(nbiot.phy.ProfileTables.n0Delay(0),8);
            test.verifyEqual(nbiot.phy.ProfileTables.n1Delay(1,4),4);
        end
    end
end
