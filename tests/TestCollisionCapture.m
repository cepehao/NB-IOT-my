classdef TestCollisionCapture < matlab.unittest.TestCase
    % Small physical diagnostics; never a statistical acceptance campaign.
    methods (Test)
        function designCoversSixGroupsAndNearFar(t)
            r=validateCollisionCapture(struct('designOnly',true));
            t.verifyEqual(unique([r.conditions.group]),1:6);
            for same=[false true]
                chosen=r.conditions([r.conditions.samePreamble]==same & [r.conditions.group]~=2);
                t.verifyTrue(all(ismember([0 6 12 20 30 40],[chosen.deltaDb])));
            end
            t.verifyEqual(r.options.repeats,10);
            t.verifyEqual(r.successDefinition,'Decoded RAR, accepted CRC/protocol Msg3, matching CRC/protocol Msg4');
        end
        function largerCampaignIsRejected(t)
            t.verifyError(@() validateCollisionCapture(struct('designOnly',true,'repeats',11)),...
                'nbiot:collision:Scope');
        end
        function unsupportedConditionIsRejected(t)
            t.verifyError(@() validateCollisionCapture(struct('designOnly',true,'conditionIds',999)),...
                'nbiot:collision:Condition');
        end
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
        function physicalControlRequiresProtocolChain(t)
            testRoot=tempname; mkdir(testRoot); cleanup=onCleanup(@() cleanupFolder(testRoot)); %#ok<NASGU>
            folder=fullfile(testRoot,'output'); registryFile=isolatedRegistry(testRoot);
            r=validateCollisionCapture(struct('outputFolder',folder,'repeats',1,...
                'conditionIds',7,'runReceiverChecks',false,'runInterferenceReplay',false,...
                'registryFile',registryFile,'manageRegistry',false));
            t.verifyEqual(height(r.trials),1);
            t.verifyEqual(r.trials.logicalColliders,0);
            t.verifyLessThanOrEqual(r.trials.firstSuccess,2);
            t.verifyEqual(r.trials.chainValidated,true);
            t.verifyGreaterThanOrEqual(r.trials.chainCount,1);
            t.verifyGreaterThanOrEqual(r.trials.raSuccess,1);
            t.verifyTrue(isnan(r.trials.firstStrongSuccess));
            t.verifyFalse(any(ismember(string(r.summary.event),["firstStrongSuccess","firstWeakSuccess"])));
            t.verifyGreaterThanOrEqual(r.trials.raSuccess,r.trials.firstSuccess);
            t.verifyTrue(isfile(fullfile(folder,'report.mat')));
        end
        function interferenceReplayCapturesCRCFailureAtDecodeTick(t)
            testRoot=tempname; mkdir(testRoot); cleanup=onCleanup(@() cleanupFolder(testRoot)); %#ok<NASGU>
            folder=fullfile(testRoot,'output'); registryFile=isolatedRegistry(testRoot);
            r=validateCollisionCapture(struct('outputFolder',folder,'repeats',1,...
                'conditionIds',7,'durationTicks',1500,'runReceiverChecks',false,...
                'runInterferenceReplay',true,'registryFile',registryFile,'manageRegistry',false));
            t.verifyEqual(height(r.interferenceReplay),8);
            for delta=[0 40]
                rows=r.interferenceReplay(r.interferenceReplay.deltaDb==delta,:);
                t.verifyEqual(sort(string(rows.variant)),...
                    ["desired-clean";"desired-noisy";"full-clean";"full-noisy"]);
            end
            equalPower=r.interferenceReplay(r.interferenceReplay.deltaDb==0,:);
            fullEqual=equalPower(strcmp(equalPower.variant,'full-noisy'),:);
            desiredEqual=equalPower(strcmp(equalPower.variant,'desired-noisy'),:);
            t.verifyFalse(fullEqual.crcError);
            t.verifyTrue(fullEqual.payloadMatchesActualTx);
            t.verifyFalse(desiredEqual.crcError);
            t.verifyTrue(desiredEqual.payloadMatchesActualTx);
            nearFar=r.interferenceReplay(r.interferenceReplay.deltaDb==40,:);
            fullNear=nearFar(strcmp(nearFar.variant,'full-noisy'),:);
            desiredNear=nearFar(strcmp(nearFar.variant,'desired-noisy'),:);
            t.verifyTrue(fullNear.crcError);
            t.verifyFalse(desiredNear.crcError);
            t.verifyTrue(desiredNear.payloadMatchesActualTx);
        end
    end
end
function cleanupFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end

function registryFile=isolatedRegistry(folder)
registryFile=fullfile(folder,'realization-registry.json');
content=['{"schemaVersion":1,"validRange":[0,4095],',...
    '"roles":["stage-2-collision-diagnostics","stage-2-receiver-diagnostics"],',...
    '"reservations":[{"role":"test-holdout","range":[0,999],"source":"isolated test"},',...
    '{"role":"test-unused","range":[1001,3999],"source":"isolated test"}],',...
    '"assignments":[]}'];
fid=fopen(registryFile,'w','n','UTF-8');
assert(fid>=0,'nbiot:test:Registry','Could not create isolated test registry.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(content,'UTF-8');
assert(fwrite(fid,bytes,'uint8')==numel(bytes),...
    'nbiot:test:Registry','Could not write isolated test registry.');
end
