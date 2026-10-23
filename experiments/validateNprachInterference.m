function report=validateNprachInterference(options)
% Physical no-NPRACH windows; truth is used only to score false detections.
if nargin<1, options=struct(); end
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
defaults=struct('numWindows',20000,'numWorkers',3,'batchSize',250,...
    'realizationId',4004,'kinds',{{'Data','Msg3','Control'}},'snrDb',[20 40],...
    'timingProfile','ul-roundtrip-plus-sync',...
    'calibrationFile',fullfile(root,'results','nprach-calibration.mat'),...
    'outputFolder',fullfile(root,'results','nprach-interference'));
names=fieldnames(defaults);
for k=1:numel(names), if ~isfield(options,names{k}), options.(names{k})=defaults.(names{k}); end, end
validateattributes(options.numWindows,{'numeric'},{'scalar','integer','positive'});
validateattributes(options.numWorkers,{'numeric'},{'scalar','integer','>=',0,'<=',3});
validateattributes(options.batchSize,{'numeric'},{'scalar','integer','positive'});
if isfolder(options.outputFolder), error('nbiot:validation:OutputExists','Use a fresh output folder.'); end
mkdir(options.outputFolder); cfg=nbiot.experiments.loadCalibration(nbiot.config.defaultConfig(),options.calibrationFile);
assert(strcmp(options.timingProfile,'ul-roundtrip-plus-sync'),...
    'nbiot:validation:Timing','Unsupported timing profile.');
source=optimizationSourceManifest(root); clockStart=tic;
conditions=struct('kind',{},'snrDb',{},'id',{});
for k=1:numel(options.kinds)
    for snr=options.snrDb
        conditions(end+1)=struct('kind',options.kinds{k},'snrDb',snr,'id',numel(conditions)+1); %#ok<AGROW>
    end
end
jobs=struct('condition',{},'first',{},'count',{},'file',{});
for ci=1:numel(conditions)
    for first=1:options.batchSize:options.numWindows
        count=min(options.batchSize,options.numWindows-first+1);
        jobs(end+1)=struct('condition',conditions(ci),'first',first,'count',count,...
            'file',fullfile(options.outputFolder,sprintf('case%d-batch%06d.mat',ci,first))); %#ok<AGROW>
    end
end
ownedPool=false; pool=[];
if options.numWorkers>0
    pool=gcp('nocreate');
    if isempty(pool), pool=parpool('Processes',options.numWorkers); ownedPool=true; end
    if ~isa(pool,'parallel.ProcessPool')||pool.NumWorkers~=options.numWorkers
        error('nbiot:validation:Pool','Expected requested process pool.');
    end
end
cleanup=onCleanup(@() closePool(pool,ownedPool)); %#ok<NASGU>
answers=cell(numel(jobs),1);
if options.numWorkers==0
    for j=1:numel(jobs)
        answers{j}=runBatch(root,cfg,options,jobs(j),source.sha256);
        fprintf('NPRACH_INTERFERENCE batches=%d/%d seconds=%.1f\n',j,numel(jobs),toc(clockStart));
    end
else
    futures=parallel.FevalFuture.empty(0,numel(jobs));
    for j=1:numel(jobs), futures(j)=parfeval(pool,@runBatch,1,root,cfg,options,jobs(j),source.sha256); end
    for completed=1:numel(jobs)
        [j,value]=fetchNext(futures); answers{j}=value;
        fprintf('NPRACH_INTERFERENCE batches=%d/%d seconds=%.1f\n',completed,numel(jobs),toc(clockStart));
    end
end
for j=1:numel(jobs)
    assert(answers{j}.condition.id==jobs(j).condition.id && ...
        answers{j}.firstTrial==jobs(j).first && answers{j}.count==jobs(j).count,...
        'nbiot:validation:Batch','Worker batch identity mismatch.');
end
rows={};
for ci=1:numel(conditions)
    hits=0; total=0;
    for j=1:numel(jobs)
        if jobs(j).condition.id==ci, hits=hits+answers{j}.falseWindows; total=total+answers{j}.count; end
    end
    if hits==0, lo=0; else, lo=betaincinv(.025,hits,total-hits+1); end
    if hits==total, hi=1; else, hi=betaincinv(.975,hits+1,total-hits); end
    rows(end+1,:)={conditions(ci).kind,conditions(ci).snrDb,total,hits,lo,hi,hi<=.001}; %#ok<AGROW>
end
results=cell2table(rows,'VariableNames',{'kind','sampleSnrDb','windows','falseWindows','pfaLo95','pfaHi95','passed'});
report=struct('passed',all(results.passed),'results',results,'options',options,...
    'sourceManifest',source,'receiverRevision',nbiot.phy.nprach.receiverRevision(),...
    'threshold',cfg.phy.nprachThreshold,'elapsedSeconds',toc(clockStart),...
    'scope','Independent payload, Rayleigh taps, CFO uniform +/-200 Hz. UL roundtrip propagation across default cell plus synchronization offset +/-2 us, with no timing advance. Real adjacent NPUSCH waveforms; no NPRACH. Noise scaled to received-window sample SNR.');
save(fullfile(options.outputFolder,'report.mat'),'report','-v7.3');
writetable(results,fullfile(options.outputFolder,'summary.csv')); disp(results);
fprintf('NPRACH_INTERFERENCE_DONE accepted=%d windows=%d seconds=%.3f\n',report.passed,sum(results.windows),report.elapsedSeconds);
end

function summary=runBatch(root,cfg,options,job,sourceSha256)
addpath(root); setupProject();
sources=nbiot.randomness.RandomSources(cfg.simulation.seed,options.realizationId);
occasion=struct('occasionId',1,'startTick',8); lengthRx=10752+256; first=8*1920-128;
metrics=zeros(12,job.count); energy=zeros(job.count,1); falseDetails=cell(job.count,1);
edge=hypot(cfg.cell.radiusM,cfg.cell.bsHeightM-cfg.cell.ueHeightM)/299792458*1920000;
for i=1:job.count
    trial=job.first+i-1; block=1000000+job.condition.id*100000+trial;
    if strcmp(job.condition.kind,'Data'), p=cfg.phy.data;
    elseif strcmp(job.condition.kind,'Msg3'), p=cfg.phy.msg3;
    elseif strcmp(job.condition.kind,'Control'), p=cfg.phy.ack;
    else, error('nbiot:validation:Kind','Unsupported NPUSCH kind.'); end
    bitsStream=sources.stream('payload',0,1,block); bits=int8(randi(bitsStream,[0 1],p.tbs,1));
    g=struct('grantId',1,'direction','UL','kind',job.condition.kind,'phase','DT',...
        'startTick',8,'endTick',8+p.durationTicks,'ticks',8:8+p.durationTicks-1,...
        'rnti',100,'ndi',0,'rv',0,'frequencyStartHz',45000,...
        'bandwidthHz',15000*p.numSubcarriers,'profile',p);
    [tx,~]=nbiot.phy.npusch.buildTransmission(cfg,g,bits,[]);
    ch=sources.stream('channel',0,1,block); taps=sqrt(10.^(cfg.channel.tapPowersDb(:)/10)/2).*...
        (randn(ch,numel(cfg.channel.tapPowersDb),1)+1i*randn(ch,numel(cfg.channel.tapPowersDb),1));
    delay=2*rand(ch)*edge+(2*rand(ch)-1)*cfg.channel.syncLimitSeconds*1920000;
    cfo=(2*rand(ch)-1)*cfg.channel.cfoLimitHz;
    wave=complex(zeros(lengthRx,1));
    for tap=1:numel(taps)
        [w,offset]=nbiot.channel.fractionalDelay(tx.waveform,...
            delay+cfg.channel.tapDelaysSeconds(tap)*1920000,cfg.channel.fractionalFilterLength);
        samples=tx.startSample+offset+(0:numel(w)-1)'; at=samples-first+1;
        keep=at>=1 & at<=lengthRx;
        wave(at(keep))=wave(at(keep))+taps(tap)*w(keep).*exp(1i*2*pi*cfo*samples(keep)/1920000);
    end
    power=mean(abs(wave(129:end-128)).^2); noise=sources.stream('noise',0,0,block);
    wave=wave+sqrt(power/(2*10^(job.condition.snrDb/10)))*...
        (randn(noise,lengthRx,1)+1i*randn(noise,lengthRx,1));
    rx=struct('waveform',wave,'sampleRateHz',1920000,'startSample',first);
    [detected,metrics(:,i)]=nbiot.phy.nprach.detect(cfg,rx,occasion); energy(i)=sum(abs(wave).^2);
    if ~isempty(detected), falseDetails{i}=struct('trial',trial,'detected',detected,'rx',rx); end
end
summary=struct('count',job.count,'falseWindows',sum(any(metrics>=cfg.phy.nprachThreshold,1)),...
    'firstTrial',job.first,'condition',job.condition,'sourceSha256',sourceSha256);
save(job.file,'summary','metrics','energy','falseDetails','-v7.3');
end

function closePool(pool,owned)
if owned && ~isempty(pool) && isvalid(pool), delete(pool); end
end
