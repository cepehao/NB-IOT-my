classdef TestNprachInterference < matlab.unittest.TestCase
    methods (Test)
        function singleToneCfoDoesNotCreateOtherPreambleDetections(t)
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.005;
            occasion=struct('occasionId',1,'startTick',8);
            tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,5);
            samples=tx.startSample+(0:numel(tx.waveform)-1)';
            for cfo=[-200 200]
                wave=tx.waveform.*exp(1i*2*pi*cfo*samples/1920000);
                rx=struct('waveform',[complex(zeros(128,1));wave;complex(zeros(128,1))], ...
                    'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample-128);
                detected=nbiot.phy.nprach.detect(cfg,rx,occasion);
                diagnostic=sprintf('CFO %g produced nInit=%s matchScore=%s.', ...
                    cfo,mat2str([detected.nInit]),mat2str([detected.matchScore],6));
                t.verifyEqual([detected.nInit],5,diagnostic);
            end
        end

        function weakNearFarToneIsNotNormalizedByStrongTone(t)
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.004;
            occasion=struct('occasionId',1,'startTick',8);
            bank=nbiot.phy.nprach.templates(cfg); count=numel(bank{1}.waveform)+256;
            first=occasion.startTick*1920-128; wave=complex(zeros(count,1));
            indices=[0 6];
            for i=1:2
                tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,indices(i));
                % Two real waveforms; the weak UE is 40 dB below the strong UE.
                amplitude=[1 .01]; cfo=[-200 200]; delay=[12.8 6.4];
                [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,delay(i),65);
                start=tx.startSample+offset;
                w=amplitude(i)*w.*exp(1i*2*pi*cfo(i)*(start+(0:numel(w)-1)')/1920000);
                at=start-first+1; wave(at:at+numel(w)-1)=wave(at:at+numel(w)-1)+w;
            end
            sources=nbiot.randomness.RandomSources(42,30); noise=sources.stream('noise',0,0,990001);
            wave=wave+sqrt(.01/2)*(randn(noise,size(wave))+1i*randn(noise,size(wave)));
            rx=struct('waveform',wave,'sampleRateHz',1920000,'startSample',first);
            detected=nbiot.phy.nprach.detect(cfg,rx,occasion);
            t.verifyEqual(sort([detected.nInit]),[0 6]);
            weak=detected([detected.nInit]==6);
            if ~isempty(weak)
                t.verifyLessThanOrEqual(abs(weak.delaySeconds*1920000-6.4),8,...
                    'Weak timing must not use a strong-tone sidelobe.');
                t.verifyLessThanOrEqual(abs(weak.cfoHz-200),50);
            end
        end

        function metricIsInvariantToReceiveAmplitude(t)
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.004;
            occasion=struct('occasionId',1,'startTick',8);
            tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,0);
            rx=struct('waveform',[complex(zeros(128,1));tx.waveform;complex(zeros(128,1))],...
                'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample-128);
            [a,ma]=nbiot.phy.nprach.detect(cfg,rx,occasion);
            rx.waveform=rx.waveform*1e-6; [b,mb]=nbiot.phy.nprach.detect(cfg,rx,occasion);
            t.verifyEqual([a.nInit],[b.nInit]); t.verifyEqual(ma,mb,'AbsTol',1e-10);
        end

        function allAllowedTonesRemainIndividuallyDetectable(t)
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.004;
            occasion=struct('occasionId',1,'startTick',8);
            for index=0:11
                tx=nbiot.phy.nprach.buildTransmission(cfg,occasion,index);
                rx=struct('waveform',[complex(zeros(128,1));tx.waveform;complex(zeros(128,1))],...
                    'sampleRateHz',tx.sampleRateHz,'startSample',tx.startSample-128);
                detected=nbiot.phy.nprach.detect(cfg,rx,occasion);
                t.verifyEqual([detected.nInit],index);
            end
        end

        function silenceCannotProduceCandidates(t)
            cfg=nbiot.config.defaultConfig(); cfg.phy.nprachThreshold=.004;
            occasion=struct('occasionId',1,'startTick',8);
            rx=struct('waveform',complex(zeros(10752+256,1)),...
                'sampleRateHz',1920000,'startSample',8*1920-128);
            [detected,metrics]=nbiot.phy.nprach.detect(cfg,rx,occasion);
            t.verifyEmpty(detected); t.verifyEqual(metrics,zeros(12,1));
        end

        function oldPresenceCalibrationIsRejected(t)
            cfg=nbiot.config.defaultConfig();
            root=fileparts(fileparts(mfilename('fullpath')));
            t.verifyError(@() nbiot.phy.nprach.loadCalibration(cfg,...
                fullfile(root,'results','nprach-calibration-legacy-v1.mat')),'nbiot:phy:Calibration');
        end
    end
end


