classdef TestRadioDiagnosticsScale < matlab.unittest.TestCase
    methods (TestClassSetup)
        function helperPath(t)
            t.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(fileparts(mfilename('fullpath')),'helpers')));
        end
    end
    methods (Test)
        function tenThousandSyntheticPairsHaveExactCounts(t)
            [truth,observed,receptions,options]=makeRadioDiagnosticsScaleFixture(10000);
            started=tic;
            d=nbiot.metrics.radioDiagnostics(truth,observed,receptions,options);
            fprintf('RADIO_DIAGNOSTICS_SYNTHETIC pairs=10000 seconds=%.6f\n',toc(started));
            t.verifyEqual(d.collision.physicalOverlapPairs,10000);
            t.verifyEqual(d.capture.eligiblePairs,10000);
            t.verifyEqual(d.capture.capturedPairs,0);
            t.verifyEqual(d.capture.probability,0);
            fields=[truth(strcmp({truth.kind},'msg1')).fields];
            t.verifyLessThanOrEqual(numel(unique([fields.ueId])),10);
        end
    end
end
