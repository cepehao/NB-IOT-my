classdef TestMonitoringTickIndex < matlab.unittest.TestCase
    methods (Test)
        function prefixSelectionMatchesLegacyAcrossHorizon(t)
            cfg=nbiot.config.defaultConfig(); calendar=nbiot.scheduler.ResourceCalendar(cfg);
            properties=metaclass(calendar).PropertyList;
            names={properties.Name};
            t.verifyTrue(any(strcmp(names,'monitoringDlTicks')),'Calendar should cache immutable monitoring ticks.');
            t.verifyTrue(any(strcmp(names,'monitoringDlPrefix')),'Calendar should cache the DL prefix count.');

            mask=calendar.mandatoryMask(:).'; duration=numel(mask);
            matches=true(duration+6,1); mismatch='';
            for baseTick=0:duration+5
                candidates=baseTick:duration-1;
                if ~isempty(candidates), candidates=candidates(~mask(candidates+1)); end
                expected=candidates(1:min(4,numel(candidates)));
                actual=calendar.monitoringTicks(baseTick);
                matches(baseTick+1)=isequal(actual,expected) && isrow(actual);
                if ~matches(baseTick+1) && isempty(mismatch)
                    mismatch=sprintf('baseTick=%d actual=%s expected=%s', ...
                        baseTick,mat2str(actual),mat2str(expected));
                end
            end
            t.verifyTrue(all(matches),mismatch);
            t.verifyEqual(calendar.monitoringTicks(0),[1 2 3 4]);
        end
    end
end
