classdef TestTransmittedPacketCount < matlab.unittest.TestCase
    methods (Test)
        function countsDistinctPacketsWithAnEmissionBeforeCurrentTick(t)
            events(1)=record(1,'scheduled',101);
            events(2)=record(2,'emitted',101);
            events(3)=record(3,'emitted',101);
            events(4)=record(3,'unmatchedEmission',202);
            events(5)=record(4,'emitted',303);

            count=nbiot.metrics.countTransmittedPackets(events,4);

            t.verifyEqual(count,2);
        end

        function emptyJournalHasNoTransmittedPackets(t)
            events=struct('tick',{},'kind',{},'fields',{});

            t.verifyEqual(nbiot.metrics.countTransmittedPackets(events,0),0);
        end

        function legacyEmissionWithoutPacketIdentityIsUnavailable(t)
            event=struct('tick',1,'kind','emitted', ...
                'fields',struct('contextId',1,'packetSequence',4));

            t.verifyTrue(isnan(nbiot.metrics.countTransmittedPackets(event,2)));
        end
    end
end

function event=record(tick,kind,packetId)
event=struct('tick',tick,'kind',kind,'fields',struct('packetId',packetId));
end
