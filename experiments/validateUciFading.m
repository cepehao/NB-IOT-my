function report=validateUciFading(options)
% Statistical valid-resource UCI risk; does not eliminate known aliases.
if nargin<1, options=struct(); end
if ~isfield(options,'outputFolder'), options.outputFolder=fullfile(fileparts(fileparts(mfilename('fullpath'))),'results','uci-fading'); end
if ~isfield(options,'numWorkers'), options.numWorkers=2; end
assert(~isfolder(options.outputFolder),'Use fresh output'); mkdir(options.outputFolder);
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject;
cfg=nbiot.config.defaultConfig(); source=optimizationSourceManifest(root); timer=tic;
kinds={'Noise','ForeignACK','ForeignNACK','OwnACK','OwnNACK'}; counts=[6000 6000 6000 1000 1000];
pool=parpool('Processes',options.numWorkers); cleanup=onCleanup(@() delete(pool)); %#ok<NASGU>
futures=parallel.FevalFuture.empty(0,5);
for ci=1:5, futures(ci)=parfeval(pool,@condition,1,root,cfg,kinds{ci},counts(ci),ci,options.outputFolder,source.sha256); end
answers=cell(5,1);
for done=1:5
 [ci,value]=fetchNext(futures); answers{ci}=value;
 fprintf('UCI_FADING condition=%s falseAck=%d/%d wrongOwn=%d absentOwn=%d seconds=%.1f\n',...
  value.kind,value.falseAck,value.n,value.wrongOwn,value.absentOwn,toc(timer));
end
rows={};
for ci=1:5
 a=answers{ci}; falseCi=interval(a.falseAck,a.n); ownCi=interval(a.wrongOwn+a.absentOwn,a.n);
 rows(end+1,:)={a.kind,a.n,a.falseAck,a.falsePresence,a.wrongOwn,a.absentOwn,...
  falseCi(1),falseCi(2),ownCi(1),ownCi(2),a.cfoRmseHz,a.timingRmseSamples}; %#ok<AGROW>
end
results=cell2table(rows,'VariableNames',{'condition','trials','falseAck','falsePresence','wrongOwnBit','absentOwn',...
 'falseAckLo95','falseAckHi95','ownFailureLo95','ownFailureHi95','cfoRmseHz','timingRmseSamples'});
report=struct('results',results,'passedStatisticalFalseAckGate',all(results.falseAckHi95(1:3)<=.001),...
 'sourceManifest',source,'options',options,'elapsedSeconds',toc(timer),...
 'scope','Independent payload/RNTI, Rayleigh taps, CFO uniform +/-200 Hz, residual post-TA delay +/-4.34 samples, conditional received sample SNR20 dB. Noise-only standard complex AWGN. Exact known alias remains separately reproduced; statistics do not prove universal rejection.');
save(fullfile(options.outputFolder,'report.mat'),'report'); writetable(results,fullfile(options.outputFolder,'summary.csv')); disp(results);
end
function summary=condition(root,cfg,kind,n,ci,folder,sourceSha)
addpath(root); setupProject; sources=nbiot.randomness.RandomSources(42,3800);
p=cfg.phy.ack; start=40;
g=struct('grantId',1,'direction','UL','kind','Control','phase','DT','startTick',start,...
 'endTick',start+p.durationTicks,'ticks',start:start+p.durationTicks-1,'rnti',100,'ndi',0,'rv',0,...
 'frequencyStartHz',0,'bandwidthHz',15000,'profile',p);
[ownAck,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(1),[]);
[ownNack,~]=nbiot.phy.npusch.buildTransmission(cfg,g,int8(0),[]);
first=start*1920-128; count=numel(ownAck.waveform)+256; falseAck=0; falsePresence=0;
wrongOwn=0; absentOwn=0; cfoErrors=zeros(n,1); timingErrors=zeros(n,1); falseCases={};
for trial=1:n
 block=2100000+ci*100000+trial; stream=sources.stream('channel',0,1,block);
 actualCfo=(2*rand(stream)-1)*200; delay=(2*rand(stream)-1)*(cfg.channel.syncLimitSeconds*1920000+.5);
 wave=complex(zeros(count,1));
 if ~strcmp(kind,'Noise')
  if strcmp(kind,'OwnACK'), tx=ownAck; bit=1;
  elseif strcmp(kind,'OwnNACK'), tx=ownNack; bit=0;
  else
   foreign=g; foreign.rnti=randi(stream,65534); if foreign.rnti>=100, foreign.rnti=foreign.rnti+1; end
   bit=double(strcmp(kind,'ForeignACK')); [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,foreign,int8(bit),[]);
  end
  taps=sqrt(10.^(cfg.channel.tapPowersDb(:)/10)/2).*(randn(stream,3,1)+1i*randn(stream,3,1));
  for tap=1:3
   [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,delay+cfg.channel.tapDelaysSeconds(tap)*1920000,65);
   samples=tx.startSample+offset+(0:numel(w)-1)'; at=samples-first+1; keep=at>=1 & at<=count;
   wave(at(keep))=wave(at(keep))+taps(tap)*w(keep).*exp(1i*2*pi*actualCfo*samples(keep)/1920000);
  end
  power=mean(abs(wave(129:end-128)).^2); noisePower=power/100;
 else, noisePower=1;
 end
 noise=sources.stream('noise',0,0,block); wave=wave+sqrt(noisePower/2)*(randn(noise,count,1)+1i*randn(noise,count,1));
 rx=struct('waveform',wave,'sampleRateHz',1920000,'startSample',first);
 [decoded,~]=nbiot.phy.npusch.receive(cfg,rx,g,[]);
 present=decoded.measurements.uciDetected; own=startsWith(kind,'Own');
 ack=present && ~isempty(decoded.decodedBits) && decoded.decodedBits(1)==1;
 if own
  absentOwn=absentOwn+~present;
  wrongOwn=wrongOwn+(present && (isempty(decoded.decodedBits)||decoded.decodedBits(1)~=bit));
 else
  falsePresence=falsePresence+present; falseAck=falseAck+ack;
  if ack, falseCases{end+1}=struct('trial',trial,'rx',rx,'decoded',decoded); end %#ok<AGROW>
 end
 cfoErrors(trial)=decoded.measurements.cfoHz-actualCfo;
 timingErrors(trial)=decoded.measurements.timing.delaySamples-delay;
 if mod(trial,1000)==0, fprintf('UCI_FADING %s %d/%d\n',kind,trial,n); end
end
if strcmp(kind,'Noise'), cfoErrors(:)=NaN; timingErrors(:)=NaN; end
summary=struct('kind',kind,'n',n,'falseAck',falseAck,'falsePresence',falsePresence,'wrongOwn',wrongOwn,...
 'absentOwn',absentOwn,'cfoRmseHz',rms(cfoErrors),'timingRmseSamples',rms(timingErrors),'sourceSha256',sourceSha);
save(fullfile(folder,[kind '.mat']),'summary','cfoErrors','timingErrors','falseCases','-v7.3');
end
function ci=interval(k,n)
if k==0, lo=0; else, lo=betaincinv(.025,k,n-k+1); end
if k==n, hi=1; else, hi=betaincinv(.975,k+1,n-k); end
ci=[lo hi];
end

