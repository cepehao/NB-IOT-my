classdef TestCollisionCapture < matlab.unittest.TestCase
    % Аналитические проверки геометрии, мощности/шума, ядра задержки и границ BACKOFF (ТЗ §31–32, §38).
    methods (Test)
        function analyticalGeometryAndIndoorLoss(t)
            c=nbiot.config.defaultConfig(); c.simulation.numUE=200; c.traffic.kind='none';
            c.cell.radiusM=500; c.cell.minDistanceM=25; c.cell.bsHeightM=20;
            c.channel.shadowIndoorDb=0; c.channel.shadowOutdoorDb=0;
            s=nbiot.scenario.buildScenario(c); u=s.ue;
            radius=hypot([u.xM],[u.yM]); d=hypot(radius,18.5);
            median=20*log10(4*pi*c.channel.carrierHz*c.channel.referenceDistanceM/299792458)+...
                10*c.channel.pathLossExponent*log10(d/c.channel.referenceDistanceM);
            t.verifyNumElements(u,200); t.verifyGreaterThanOrEqual(radius,25);
            t.verifyLessThanOrEqual(radius,500); t.verifyEqual([u.distanceM],d,'AbsTol',1e-10);
            t.verifyEqual([u.medianPathLossDb],median,'AbsTol',1e-10);
            t.verifyEqual([u.pathLossDb],median+20*double([u.indoor]),'AbsTol',1e-10);
            t.verifyEqual(sum([u.indoor]),60);
            % Area-uniform radius squared: deterministic analytic distribution check.
            z=(radius.^2-25^2)/(500^2-25^2);
            t.verifyLessThan(abs(mean(z)-.5),.1);
            t.verifyEqual(s,nbiot.scenario.buildScenario(c));
        end
        function analyticalPhysicalPowerFadingAndNoise(t)
            [c,s,sources]=TestWaveformChannel.fixture(); c.channel.bsNoiseFigureDb=-Inf;
            s.ue(1).distanceM=0; s.ue(1).syncOffsetSeconds=0; s.ue(1).cfoHz=0;
            s.ue(1).pathLossDb=50; s.ue(1).tapsUl=[1;0;0];
            tx=TestWaveformChannel.tx(1,100,2000);
            ch=nbiot.channel.RadioChannel(c,s,sources); ch.add(tx); rx=ch.receive('UL',0,200,1900);
            expected=10^((23-30-50)/10);
            t.verifyEqual(mean(abs(rx.waveform).^2),expected,'RelTol',1e-10);
            s.ue(1).tapsUl=[2;0;0]; ch=nbiot.channel.RadioChannel(c,s,sources); ch.add(tx);
            faded=ch.receive('UL',0,200,1900);
            t.verifyEqual(mean(abs(faded.waveform).^2),4*expected,'RelTol',1e-10);
            c.channel.bsNoiseFigureDb=5; ch=nbiot.channel.RadioChannel(c,s,sources);
            noise=ch.receive('UL',0,0,192000);
            variance=1.380649e-23*290*10^(5/10)*1920000;
            t.verifyEqual(mean(abs(noise.waveform).^2),variance,'RelTol',.015);
            t.verifyEqual(10*log10(expected/variance),...
                23-50-(10*log10(variance)+30),'AbsTol',1e-10);
        end
        function kernelControlsAndExplicitFixedStep(t)
            c=nbiot.config.defaultConfig(); c.simulation.numUE=3; c.simulation.durationTicks=1500;
            c.simulation.seed=17; c.cell.radiusM=500; c.cell.minDistanceM=20;
            c.channel.carrierHz=1800e6; c.channel.penetrationIndoorDb=10;
            c.channel.uePowerDbm=18; c.channel.cfoSigmaHz=20; c.channel.syncLimitSeconds=1e-6;
            c.channel.tapDelaysSeconds=[0 .1 .5]*1e-6; c.channel.tapPowersDb=[0 -4 -8];
            c.traffic.kind='poisson'; c.traffic.poissonRatePerSecond=.5;
            c.traffic.packetBytes=26; c.traffic.queueLimit=4; c.ra.maxAttempts=2;
            c.policy.windowTicks=250; c.dataset.windowTicks=250;
            t.verifyEqual(nbiot.config.validateConfig(c),c);
            c.simulation.tickSeconds=.002;
            t.verifyError(@() nbiot.config.validateConfig(c),'nbiot:config:InvalidValue');
            c.simulation.tickSeconds=.001; c.phy.data.spacingHz=3750;
            t.verifyError(@() nbiot.config.validateConfig(c),'nbiot:config:UnsupportedProfile');
        end
        function backoffWaitAndMaximumAttemptBoundary(t)
            c=nbiot.config.defaultConfig(); c.simulation.numUE=1; c.simulation.durationTicks=100;
            c.traffic.burstStartTick=0; c.traffic.burstDurationTicks=1; c.phy.nprachThreshold=1;
            sim=nbiot.NBIoTSimulator(c); sim.run(1); t.verifyEqual(sim.devices.get(1).state,'WAIT_RA');
            sim.run(8); d=sim.devices.get(1); t.assertEqual(d.state,'WAIT_RAR');
            t.verifyEqual(d.attemptNumber,1); d.deadlineTick=9; sim.devices.set(1,d); sim.step();
            d=sim.devices.get(1); t.verifyEqual(d.state,'BACKOFF');
            stream=nbiot.randomness.RandomSources(42,0).stream('backoff',0,1,1);
            t.verifyEqual(d.nextAllowedTick,9+ceil(rand(stream)*c.ra.backoffTicks));
            sim.step(); t.verifyEqual(sim.devices.get(1).attemptNumber,1);
            d=sim.devices.get(1); d.state='WAIT_RAR'; d.attemptNumber=8; d.deadlineTick=11;
            sim.devices.set(1,d); sim.step();
            t.verifyEqual(sim.devices.get(1).state,'IDLE');
            t.verifyEqual(sim.packets.packets.reason,'ra_limit');
            t.verifyEqual(sim.attempts(1).status,'failure');
        end
    end
end
function cleanupFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end

