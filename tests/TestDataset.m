classdef TestDataset < matlab.unittest.TestCase
    methods (Test)
        function schemaAddsOnlyTimedBsFeaturesAndRetainsLegacyVersion(t)
            current=nbiot.dataset.featureSchema();
            t.verifyEqual(current.version,'bs-known-v2.0');
            t.verifyTrue(all(ismember({'ulRaOccupancy','ulDtOccupancy', ...
                'dlRaOccupancy','dlDtOccupancy','accessProbability','raShare'}, ...
                current.observationNames)));

            legacy=nbiot.dataset.featureSchema('static-v1.0');
            t.verifyEqual(legacy.version,'static-v1.0');
            t.verifyEqual(numel(legacy.observationNames),13);
        end

        function closeWindowUsesOnlyItsClosedOccupancyAndPriorAction(t)
            empty=struct('tick',{},'kind',{},'fields',{});
            occupancy=struct('ulRaOccupancy',.1,'ulDtOccupancy',.2, ...
                'dlRaOccupancy',.3,'dlDtOccupancy',.4);
            action=struct('accessProbability',.75,'raShare',.2,'effectiveTick',0);

            [observations,~]=nbiot.dataset.closeWindow(empty,empty,0,500, ...
                0,0,0,7,500,occupancy,action);
            schema=nbiot.dataset.featureSchema();
            row=cell2table(observations,'VariableNames',schema.observationNames);

            t.verifyEqual(row.ulRaOccupancy,.1);
            t.verifyEqual(row.ulDtOccupancy,.2);
            t.verifyEqual(row.dlRaOccupancy,.3);
            t.verifyEqual(row.dlDtOccupancy,.4);
            t.verifyEqual(row.accessProbability,.75);
            t.verifyEqual(row.raShare,.2);
            t.verifyFalse(any(ismember({'meanRaUe','meanActiveUe'}, ...
                schema.observationNames)));
        end

        function absentDerivedInputsStayMissingInsteadOfZero(t)
            empty=struct('tick',{},'kind',{},'fields',{});
            [observations,~]=nbiot.dataset.closeWindow(empty,empty,0,500, ...
                0,0,0,7,500);
            schema=nbiot.dataset.featureSchema();
            row=cell2table(observations,'VariableNames',schema.observationNames);

            t.verifyTrue(all(isnan(row{1,{'ulRaOccupancy','ulDtOccupancy', ...
                'dlRaOccupancy','dlDtOccupancy','accessProbability','raShare'}})));
        end

        function futureActionCannotDescribeClosedWindow(t)
            empty=struct('tick',{},'kind',{},'fields',{});
            occupancy=struct('ulRaOccupancy',0,'ulDtOccupancy',0, ...
                'dlRaOccupancy',0,'dlDtOccupancy',0);
            action=struct('accessProbability',0.5,'raShare',0.2,'effectiveTick',500);

            t.verifyError(@() nbiot.dataset.closeWindow(empty,empty,0,500, ...
                0,0,0,7,500,occupancy,action), ...
                'nbiot:dataset:FutureAction');
        end

        function observationDoesNotUseLabels(t)
            e=struct('tick',{},'kind',{},'fields',{});
            [a,x]=nbiot.dataset.closeWindow(e,e,0,500,1000,1500,0,0);
            [b,y]=nbiot.dataset.closeWindow(e,e,0,500,9000,8000,0,0);
            t.verifyEqual(a,b); t.verifyNotEqual(x,y); t.verifyEqual(a{5},0);
        end
        function rejectsUeDecoderLeakage(t)
            e=struct('tick',10,'kind','phy_decode','fields',struct('receiverId',1));
            empty=struct('tick',{},'kind',{},'fields',{});
            t.verifyError(@() nbiot.dataset.closeWindow(e,empty,0,500,0,0,0,0),'nbiot:dataset:Leakage');
        end
        function splitsEntireIndependentRealizations(t)
            manifest=nbiot.dataset.buildManifest(0:99);
            t.verifyEqual([sum(manifest.split=="train") sum(manifest.split=="validation") sum(manifest.split=="test")],[70 15 15]);
            t.verifyEqual(height(manifest),numel(unique(manifest.externalRealizationId)));
        end
    end
end
