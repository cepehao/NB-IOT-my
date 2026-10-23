classdef TestWaveformChannel < matlab.unittest.TestCase
    methods (Test)
        function normalizationAndFractionalTimestamp(t)
            [y,p]=nbiot.channel.normalizePower([1;1;0;0],[0 2],30);
            t.verifyEqual(p,1); t.verifyEqual(mean(abs(y(1:2)).^2),1);
            [z,offset,kernel]=nbiot.channel.fractionalDelay(1,3.25,65);
            t.verifyEqual(offset,-29); t.verifyEqual(numel(z),65); t.verifyEqual(sum(kernel),1,'AbsTol',1e-12);
        end
        function sharedPhysicalPowerTemplate(t)
            [cfg,scenario,sources]=TestWaveformChannel.fixture(); a=nbiot.channel.RadioChannel(cfg,scenario,sources); b=nbiot.channel.RadioChannel(cfg,scenario,sources);
            tx=TestWaveformChannel.tx(1,100,1000); a.add(tx);
            tx.waveform=nbiot.channel.normalizePower(tx.waveform,tx.activeRanges,tx.txPowerDbm); tx.powerNormalized=true; b.add(tx);
            x=a.receive(0,0,0,3840); y=b.receive(0,0,0,3840); t.verifyEqual(x.waveform,y.waveform);
        end
        function outOfWindowTransmissionDoesNotChangeNoise(t)
            [cfg,scenario,sources]=TestWaveformChannel.fixture(); a=nbiot.channel.RadioChannel(cfg,scenario,sources); b=nbiot.channel.RadioChannel(cfg,scenario,sources);
            a.add(TestWaveformChannel.tx(1,100000,1000)); x=a.receive(0,0,0,1920); y=b.receive(0,0,0,1920); t.verifyEqual(x.waveform,y.waveform);
        end
        function windowPartitionInvariant(t)
            [cfg,scenario,sources]=TestWaveformChannel.fixture(); c=nbiot.channel.RadioChannel(cfg,scenario,sources);
            c.add(TestWaveformChannel.tx(1,100,1000));
            all=c.receive('UL',0,0,3840); a=c.receive('UL',0,0,1234); b=c.receive('UL',0,1234,3840);
            t.verifyEqual(all.waveform,[a.waveform;b.waveform],'AbsTol',1e-15);
            t.verifyEqual(sort(fieldnames(all)),sort({'waveform';'sampleRateHz';'startSample'}));
        end
        function noiseIsAddedOnceAndSignalsSum(t)
            [cfg,scenario,sources]=TestWaveformChannel.fixture(); c=nbiot.channel.RadioChannel(cfg,scenario,sources); empty=nbiot.channel.RadioChannel(cfg,scenario,sources);
            one=nbiot.channel.RadioChannel(cfg,scenario,sources); tx=TestWaveformChannel.tx(1,100,1000); one.add(tx); c.add(tx); c.add(tx);
            noise=empty.receive(0,0,0,3840); oneRx=one.receive(0,0,0,3840); sumrx=c.receive(0,0,0,3840);
            t.verifyEqual(sumrx.waveform,2*oneRx.waveform-noise.waveform,'AbsTol',1e-14);
        end
        function receiverNoiseAndTails(t)
            [cfg,scenario,sources]=TestWaveformChannel.fixture(); c=nbiot.channel.RadioChannel(cfg,scenario,sources);
            a=c.receive(1,1,0,1920); b=c.receive(1,2,0,1920); t.verifyNotEqual(a.waveform,b.waveform);
            tx=TestWaveformChannel.tx(1,100,100); c.add(tx); before=c.receive(0,0,195,260); c.discardBefore(195); after=c.receive(0,0,195,260);
            t.verifyEqual(before.waveform,after.waveform);
        end
    end
    methods (Static)
        function [cfg,scenario,sources]=fixture()
            cfg=nbiot.config.defaultConfig(); cfg.simulation.numUE=2;
            u=struct('ueId',1,'distanceM',100,'pathLossDb',50,'cfoHz',37,'syncOffsetSeconds',1e-6,'tapsUl',[1 .2i .1],'tapsDl',[1 .2 .1i]);
            scenario=struct('ue',[u u]); scenario.ue(2).ueId=2;
            sources=nbiot.randomness.RandomSources(cfg.simulation.seed,0);
        end
        function tx=tx(id,start,n)
            x=exp(1i*2*pi*(0:n-1)'/17);
            tx=struct('grantId',1,'direction','UL','waveform',x,'sampleRateHz',1920000,'startSample',start,'activeRanges',[0 n],'txPowerDbm',23,'ueId',id,'kind','Data');
        end
    end
end
