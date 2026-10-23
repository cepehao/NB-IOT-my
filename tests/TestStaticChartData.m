classdef TestStaticChartData < matlab.unittest.TestCase
    methods (Test)
        function derivesStaticSeriesWithExplicitDenominators(t)
            result=chartFixture();
            data=nbiot.ui.buildStaticChartData(result);

            t.verifyEqual(data.endTimeSeconds,[.5;1]);
            t.verifyEqual(data.meanActiveUe,[1.5;2]);
            t.verifyEqual(data.actualLoadMeanRaUe,[.5;1.5]);
            t.verifyEqual(data.collisionProbability,[.5;1]);
            t.verifyEqual(data.successfulRa,[1;2]);
            t.verifyEqual(data.staticAccessProbability,[1;1]);
            t.verifyTrue(all(isnan(data.predictedLoadMeanRaUe)));
            t.verifyTrue(all(isnan(data.adaptiveAccessProbability)));
            t.verifyEqual(data.throughputBitsPerSecond,[32;64]);
            t.verifyEqual(data.meanDeliveryDelaySeconds,[.21;.1],'AbsTol',1e-12);
            t.verifyEqual(data.dataBler,[.5;0]);
            t.verifyEqual(data.ulOccupancy(1),4/(2*500*48),'AbsTol',1e-12);
            t.verifyEqual(data.ulOccupancy(2),0);
            t.verifyTrue(all(isfinite(data.dlOccupancy)));
        end

        function incompleteTrailingWindowIsNotPresentedAsClosed(t)
            result=chartFixture();
            result.dataset.targets=result.dataset.targets(1,:);
            data=nbiot.ui.buildStaticChartData(result);
            t.verifyEqual(height(data),1);
            t.verifyEqual(data.windowId,1);
        end
    end
end

function result=chartFixture()
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=2;
cfg.simulation.durationTicks=1000;
cfg.dataset.windowTicks=500;
series=table([1;2],[0;500],[500;1000],[1;2],[32;64], ...
    'VariableNames',{'windowId','startTick','endTick','raSucceededInWindow','throughputBitsPerSecond'});
targets=table([1;1],[1;2],[0;500],[500;1000],[.5;1.5],[1.5;2], ...
    'VariableNames',{'realizationId','windowId','startTick','endTick','meanRaUe','meanActiveUe'});
ra=struct('startTick',{10,40,510},'collision',{true,false,true});
packets=struct('createdTick',{40,600},'deliveredTick',{250,700}, ...
    'status',{'delivered','delivered'});
observed=struct('tick',{100,300,750},'kind',{'phy_decode','phy_decode','phy_decode'}, ...
    'fields',{decodeFields(0),decodeFields(1),decodeFields(0)});
transmission=struct('direction','UL','ticks',1,'frequencyStartHz',0,'bandwidthHz',7500);
truth=struct('tick',1,'kind','transmission','fields',transmission);
result=struct('config',cfg,'status','completed','actualTick',1000, ...
    'kpiTimeSeries',series,'dataset',struct('targets',targets), ...
    'raLog',ra,'packetLog',packets,'observedLog',observed,'truthLog',truth);
end

function fields=decodeFields(crcError)
fields=struct('receiverId',0,'hasCrc',true,'channel','Data','crcError',crcError);
end
