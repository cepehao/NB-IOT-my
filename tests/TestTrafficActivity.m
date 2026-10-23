classdef TestTrafficActivity < matlab.unittest.TestCase
    methods (Test)
        function defaultsAndLegacyConfigsAreNormalized(t)
            cfg=nbiot.config.defaultConfig();
            t.verifyTrue(isfield(cfg.traffic,'activityMode'), ...
                'defaultConfig must provide traffic.activityMode.');
            t.verifyTrue(isfield(cfg.traffic,'activeUeIds'), ...
                'defaultConfig must provide traffic.activeUeIds.');
            if isfield(cfg.traffic,'activityMode')
                t.verifyEqual(cfg.traffic.activityMode,'all');
            end
            if isfield(cfg.traffic,'activeUeIds')
                t.verifyEmpty(cfg.traffic.activeUeIds);
            end

            complete=cfg;
            complete.simulation.numUE=2;
            complete.traffic.activityMode='explicit';
            complete.traffic.activeUeIds=[2 1];
            normalized=nbiot.config.validateConfig(complete);
            t.verifyEqual(normalized.traffic.activeUeIds,[1 2], ...
                'Explicit active UE identifiers must be sorted.');

            missingMode=complete;
            missingMode.traffic=rmfield(missingMode.traffic,'activityMode');
            normalized=nbiot.config.validateConfig(missingMode);
            t.verifyTrue(isfield(normalized.traffic,'activityMode'), ...
                'A legacy traffic struct missing activityMode must be normalized.');
            if isfield(normalized.traffic,'activityMode')
                t.verifyEqual(normalized.traffic.activityMode,'all');
            end

            missingIds=complete;
            missingIds.traffic=rmfield(missingIds.traffic,'activeUeIds');
            normalized=nbiot.config.validateConfig(missingIds);
            t.verifyTrue(isfield(normalized.traffic,'activeUeIds'), ...
                'A legacy traffic struct missing activeUeIds must be normalized.');
            if isfield(normalized.traffic,'activeUeIds')
                t.verifyEmpty(normalized.traffic.activeUeIds, ...
                    'The default activeUeIds value is empty.');
            end

            legacy=complete;
            legacy.traffic=rmfield(legacy.traffic, ...
                {'activityMode','activeUeIds'});
            normalized=nbiot.config.validateConfig(legacy);
            t.verifyTrue(isfield(normalized.traffic,'activityMode'));
            t.verifyTrue(isfield(normalized.traffic,'activeUeIds'));
            if isfield(normalized.traffic,'activityMode')
                t.verifyEqual(normalized.traffic.activityMode,'all');
            end
            if isfield(normalized.traffic,'activeUeIds')
                t.verifyEmpty(normalized.traffic.activeUeIds);
            end
        end

        function rejectsInvalidExplicitUeLists(t)
            cfg=trafficConfig('burst');
            cfg.traffic.activityMode='explicit';
            invalidIds={ [1 1],0,3,NaN,1.5 };
            labels={'duplicate identifier','zero identifier','identifier above numUE', ...
                'NaN identifier','fractional identifier'};
            for k=1:numel(invalidIds)
                candidate=cfg;
                candidate.traffic.activeUeIds=invalidIds{k};
                t.verifyError(@() nbiot.config.validateConfig(candidate), ...
                    'nbiot:config:InvalidValue',labels{k});
            end
        end

        function allModePreservesLegacyArrivalsForEveryTrafficKind(t)
            kinds={'burst','periodic','poisson'};
            for k=1:numel(kinds)
                cfg=trafficConfig(kinds{k});
                sources=nbiot.randomness.RandomSources(43,7);
                expected=legacyArrivalReference(cfg,sources);
                actual=nbiot.traffic.generateArrivals(cfg,sources);
                t.verifyEqual(actual,expected, ...
                    sprintf('%s all-mode arrivals must match the legacy output.',kinds{k}));
            end
        end

        function explicitGroupPreservesItsStreamsAndEmptySelectsNoUes(t)
            kinds={'burst','periodic','poisson'};
            for k=1:numel(kinds)
                allCfg=trafficConfig(kinds{k});
                allArrivals=nbiot.traffic.generateArrivals(allCfg, ...
                    nbiot.randomness.RandomSources(43,7));

                selectedCfg=allCfg;
                selectedCfg.traffic.activityMode='explicit';
                selectedCfg.traffic.activeUeIds=2;
                [selectedSources,readSelectedRequests]=countingSources(43,7);
                selected=nbiot.traffic.generateArrivals(selectedCfg,selectedSources);
                selectedRequests=readSelectedRequests();
                t.verifyEqual({selectedRequests.kind},{'traffic','payload'}, ...
                    sprintf('%s must request only the selected UE traffic and payload streams.',kinds{k}));
                t.verifyEqual([selectedRequests.ueId],[2 2], ...
                    sprintf('%s must not request streams for inactive UE 1.',kinds{k}));
                selectedIds=unique(double([selected.ueId]));
                t.verifyEqual(selectedIds,2, ...
                    sprintf('%s explicit group must contain only UE 2.',kinds{k}));
                ue2=allArrivals(double([allArrivals.ueId])==2);
                t.verifyEqual(rmfield(selected,'packetId'),rmfield(ue2,'packetId'), ...
                    sprintf('%s UE 2 times and payloads must match all mode.',kinds{k}));

                emptyCfg=allCfg;
                emptyCfg.traffic.activityMode='explicit';
                emptyCfg.traffic.activeUeIds=[];
                [emptySources,readEmptyRequests]=countingSources(43,7);
                noArrivals=nbiot.traffic.generateArrivals(emptyCfg,emptySources);
                t.verifyEmpty(noArrivals, ...
                    sprintf('%s explicit empty group must create no arrivals.',kinds{k}));
                t.verifyEmpty(readEmptyRequests(), ...
                    sprintf('%s explicit empty group must request no traffic or payload streams.',kinds{k}));
            end
        end
    end
end

function cfg=trafficConfig(kind)
cfg=nbiot.config.defaultConfig();
cfg.simulation.numUE=2;
cfg.simulation.durationTicks=5000;
cfg.traffic.kind=kind;
cfg.traffic.packetBytes=2;
cfg.traffic.poissonRatePerSecond=20;
cfg.traffic.activityMode='all';
cfg.traffic.activeUeIds=[];
end

function [sources,readRequests]=countingSources(seed,realizationId)
backing=nbiot.randomness.RandomSources(seed,realizationId);
requests=struct('kind',{},'ueId',{});
sources=struct();
sources.stream=@recordedStream;
readRequests=@snapshotRequests;

    function value=recordedStream(name,direction,receiverId,blockId)
        requests(end+1)=struct('kind',char(name),'ueId',double(receiverId)); %#ok<AGROW>
        value=backing.stream(name,direction,receiverId,blockId);
    end

    function value=snapshotRequests()
        value=requests;
    end
end

function arrivals=legacyArrivalReference(cfg,sources)
% Characterization oracle for the pre-U2 all-device traffic path.
cfg=nbiot.config.validateConfig(cfg);
t=cfg.traffic;
horizon=cfg.simulation.durationTicks;
arrivals=struct('packetId',{},'ueId',{},'createdTick',{},'sequence',{}, ...
    'payloadBits',{},'continuousTimeSeconds',{});
for id=1:cfg.simulation.numUE
    trafficStream=sources.stream('traffic',0,id,0);
    times=[];
    switch t.kind
        case 'burst'
            times=t.burstStartTick+t.burstDurationTicks*rand(trafficStream);
        case 'periodic'
            phase=t.periodTicks*rand(trafficStream);
            times=phase:t.periodTicks:horizon;
        case 'poisson'
            if t.poissonRatePerSecond>0
                x=0;
                while true
                    x=x-log(max(realmin,rand(trafficStream)))/ ...
                        (t.poissonRatePerSecond*cfg.simulation.tickSeconds);
                    if x>=horizon, break; end
                    times(end+1)=x; %#ok<AGROW>
                end
            end
    end
    ticks=ceil(times);
    keep=ticks<horizon;
    ticks=ticks(keep);
    times=times(keep);
    if numel(ticks)>65535
        error('nbiot:traffic:SequenceOverflow','UE %d exceeds sequence space',id);
    end
    payloadStream=sources.stream('payload',0,id,0);
    for k=1:numel(ticks)
        arrivals(end+1)=struct('packetId',uint32(0),'ueId',uint32(id), ...
            'createdTick',uint64(ticks(k)),'sequence',uint16(k), ...
            'payloadBits',int8(rand(payloadStream,8*t.packetBytes,1)>=.5), ...
            'continuousTimeSeconds',times(k)*cfg.simulation.tickSeconds); %#ok<AGROW>
    end
end
if ~isempty(arrivals)
    keys=[double([arrivals.createdTick])' double([arrivals.ueId])' ...
        double([arrivals.sequence])'];
    [~,order]=sortrows(keys,[1 2 3]);
    arrivals=arrivals(order);
    for k=1:numel(arrivals), arrivals(k).packetId=uint32(k); end
end
end
