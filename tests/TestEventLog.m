classdef TestEventLog < matlab.unittest.TestCase
    methods (Test)
        function readsOnlyEventsAfterTheRequestedCursor(t)
            log=nbiot.results.EventLog();
            log.append(1,'first',struct('value',10));
            log.append(2,'second',struct('value',20));

            [first,cursor]=log.since(0);
            t.verifyEqual({first.kind},{'first','second'});
            t.verifyEqual([first.tick],[1 2]);
            t.verifyEqual(cursor,2);

            [none,sameCursor]=log.since(cursor);
            t.verifyEmpty(none);
            t.verifyEqual(sameCursor,cursor);

            log.append(3,'third',struct('value',30));
            [last,nextCursor]=log.since(cursor);
            t.verifyEqual({last.kind},{'third'});
            t.verifyEqual(last.tick,3);
            t.verifyEqual(nextCursor,3);
        end

        function rejectsCursorOutsideCurrentLog(t)
            log=nbiot.results.EventLog();
            t.verifyError(@() log.since(-1),'nbiot:results:EventLogCursor');
            t.verifyError(@() log.since(1),'nbiot:results:EventLogCursor');
        end
    end
end
