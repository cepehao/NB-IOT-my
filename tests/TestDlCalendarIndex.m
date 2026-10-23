classdef TestDlCalendarIndex < matlab.unittest.TestCase
    methods (Test)
        function prefixSelectionMatchesLegacyAcrossHorizon(t)
            cfg=nbiot.config.defaultConfig(); calendar=nbiot.scheduler.ResourceCalendar(cfg);
            scheduler=nbiot.scheduler.Scheduler(cfg,calendar);
            properties=metaclass(scheduler).PropertyList;
            names={properties.Name};
            t.verifyTrue(any(strcmp(names,'availableDlTicks')),'Scheduler should cache immutable DL ticks.');
            t.verifyTrue(any(strcmp(names,'availableDlPrefix')),'Scheduler should cache the DL prefix count.');

            mask=calendar.mandatoryMask(:).'; duration=numel(mask);
            available=find(~mask)-1; prefix=[0 cumsum(~mask)];
            p=nbiot.phy.ProfileTables.profile('downlink');
            p.nsf=nbiot.phy.ProfileTables.dlSubframes(0);
            p.repetitions=nbiot.phy.ProfileTables.dlRepetitions(1);
            count=p.nsf*p.repetitions;
            selectedFirst=[0 1 max(0,duration-2) duration-1 duration duration+5];
            matches=true(duration+6,8); mismatch='';

            for first=0:duration+5
                allowed=first:duration-1;
                if first<duration, allowed=allowed(~mask(allowed+1)); else, allowed=[]; end
                for delay=0:7
                    offset=nbiot.phy.ProfileTables.n1Delay(delay,4);
                    legacy=[]; indexed=[];
                    if numel(allowed)>=offset+count
                        legacy=allowed(offset+(1:count));
                    end
                    if first<duration
                        at=prefix(first+1)+1;
                        if at+offset+count-1<=numel(available)
                            indexed=available(at+offset+(0:count-1));
                        end
                    end
                    matches(first+1,delay+1)=isequal(indexed,legacy);
                    if ~matches(first+1,delay+1) && isempty(mismatch)
                        mismatch=sprintf('first=%d delay=%d indexed=%s legacy=%s', ...
                            first,delay,mat2str(indexed),mat2str(legacy));
                    end
                    if any(first==selectedFirst)
                        dci=struct('format','N1','order',0,'mcs',6,'resourceAssignment',0, ...
                            'repetitionNumber',1,'schedulingDelay',delay,'ndi',0);
                        actual=scheduler.reconstructDownlink(dci,first-5,100);
                        if isempty(legacy), t.verifyEmpty(actual);
                        else, t.verifyEqual(actual.ticks,legacy); end
                    end
                end
            end
            t.verifyTrue(all(matches,'all'),mismatch);
        end
    end
end
