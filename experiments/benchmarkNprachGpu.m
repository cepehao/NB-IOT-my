function report=benchmarkNprachGpu()
% Offline FFT diagnostic only; production detector always retains CPU.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject;
out=fullfile(root,'results','gpu-fft'); assert(~isfolder(out),'Use fresh output'); mkdir(out);
cfg=nbiot.config.defaultConfig(); bank=nbiot.phy.nprach.templates(cfg);
source=optimizationSourceManifest(root); info=gpuDeviceTable;
report=struct('sourceManifest',source,'matlabRelease',version('-release'),...
 'devices',info,'enabledInSimulator',false,'precision','complex double');
if gpuDeviceCount('available')==0
 report.available=false; save(fullfile(out,'report.mat'),'report'); return;
end
device=gpuDevice; report.available=true;
report.device=struct('name',device.Name,'computeCapability',device.ComputeCapability,...
 'totalMemory',device.TotalMemory,'availableMemoryBefore',device.AvailableMemory);
fs=1920000; count=numel(bank{1}.waveform); delays=-15:71; first=8*1920+min(delays);
s=load(fullfile(root,'verification','fixtures','r1-weak-parameters.mat'),'rx');
original=nbiot.phy.extractWindow(s.rx,first,count+max(delays)-min(delays)); original=original(:);
len=2^nextpow2(numel(original)+count-1);
references=complex(zeros(len,12));
for index=1:12, references(:,index)=fft(conj(flipud(bank{index}.waveform)),len); end
referenceEnergy=sum(abs(bank{1}.waveform).^2); cfos=cfg.phy.nprachCfoGridHz;
rows={}; checks={}; timer=tic;
for batch=[1 8 32]
 rngLocal=RandStream('mt19937ar','Seed',123+batch);
 wave=repmat(original,1,batch)+sqrt(.001/2)*(randn(rngLocal,numel(original),batch)+1i*randn(rngLocal,numel(original),batch));
 energy=zeros(numel(delays),batch);
 for k=1:batch, energy(:,k)=conv(abs(wave(:,k)).^2,ones(count,1),'valid'); end
 correction=exp(-1i*2*pi*((first+(0:size(wave,1)-1)')/fs)*cfos);
 baseline=loopKernel(wave,references,correction,energy,referenceEnergy,count,len);
 matrix=matrixKernel(wave,references,correction,energy,referenceEnergy,count,len);
 cpuLoopSeconds=timeit(@() loopKernel(wave,references,correction,energy,referenceEnergy,count,len));
 cpuMatrixSeconds=timeit(@() matrixKernel(wave,references,correction,energy,referenceEnergy,count,len));
 gpuStatus='measured'; gpuKernelSeconds=NaN; gpuHostSeconds=NaN; deltaGpu=NaN; gridEqual=false; decisionEqual=false;
 try
  gpuWave=gpuArray(wave); gpuRef=gpuArray(references); gpuCorrection=gpuArray(correction); gpuEnergy=gpuArray(energy);
  actual=gather(matrixKernel(gpuWave,gpuRef,gpuCorrection,gpuEnergy,referenceEnergy,count,len));
  gpuKernelSeconds=gputimeit(@() matrixKernel(gpuWave,gpuRef,gpuCorrection,gpuEnergy,referenceEnergy,count,len));
  gpuHostSeconds=timeit(@() hostGpu(wave,gpuRef,gpuCorrection,energy,referenceEnergy,count,len));
  deltaGpu=max(abs(baseline(:)-actual(:)));
  [a,ia]=max(reshape(baseline,[],12,batch),[],1);
  [b,ib]=max(reshape(actual,[],12,batch),[],1);
  gridEqual=isequal(ia,ib);
  threshold=.0013808158865320679;
  decisionEqual=isequal(a>=threshold,b>=threshold);
  % Numerical margin check around each CPU peak, independent of fixed threshold.
  decisionEqual=decisionEqual && all(reshape(b<a+1e-10,[],1)) && all(reshape(b>a-1e-10,[],1));
  assert(deltaGpu<=1e-10 && gridEqual && decisionEqual,'GPU numerical criteria failed');
 catch exception
  gpuStatus=exception.identifier;
 end
 deltaMatrix=max(abs(baseline(:)-matrix(:)));
 assert(deltaMatrix<=1e-10,'CPU matrix numerical criteria failed');
 rows(end+1,:)={batch,cpuLoopSeconds,cpuMatrixSeconds,gpuKernelSeconds,gpuHostSeconds,...
  cpuLoopSeconds/gpuHostSeconds,deltaMatrix,deltaGpu,gridEqual,decisionEqual,gpuStatus}; %#ok<AGROW>
 checks{end+1}=struct('batch',batch,'cpuScores',baseline,'cpuMatrixScores',matrix); %#ok<AGROW>
 clear gpuWave gpuRef gpuCorrection gpuEnergy actual
 fprintf('GPU_FFT batch=%d CPU=%.5f matrix=%.5f GPUresident=%.5f GPUhost=%.5f delta=%.3g status=%s\n',...
  batch,cpuLoopSeconds,cpuMatrixSeconds,gpuKernelSeconds,gpuHostSeconds,deltaGpu,gpuStatus);
end
report.results=cell2table(rows,'VariableNames',{'batchWindows','cpuLoopSeconds','cpuMatrixSeconds',...
 'gpuResidentSeconds','gpuIncludingTransfersSeconds','kernelHostSpeedup','cpuMatrixMaxDifference',...
 'gpuMaxDifference','delayCfoGridEqual','thresholdDecisionsEqual','gpuStatus'});
report.checks=checks; report.elapsedSeconds=toc(timer);
report.device.availableMemoryAfter=device.AvailableMemory;
report.scope='17 CFO hypotheses x all 12 public templates. Kernel-only benchmark, cached template FFT. CPU loop vs matrix vs GPU complex-double batched windows, with upload/download separately timed. Presence v2 uses non-FFT group projections, and SIC parameter estimation uses selected candidates: no simulator speedup or production GPU activation is inferred.';
save(fullfile(out,'report.mat'),'report','-v7.3'); writetable(report.results,fullfile(out,'summary.csv')); disp(report.results);
end

function scores=loopKernel(w,reference,correction,energy,referenceEnergy,count,len)
B=size(w,2); D=size(energy,1); F=size(correction,2); scores=zeros(D,F,12,B);
for b=1:B
 for f=1:F
  wf=fft(w(:,b).*correction(:,f),len);
  for index=1:12
   corr=ifft(wf.*reference(:,index));
   scores(:,f,index,b)=abs(corr(count:count+D-1)).^2./max(energy(:,b)*referenceEnergy,realmin);
  end
 end
end
end

function scores=matrixKernel(w,reference,correction,energy,referenceEnergy,count,len)
B=size(w,2); D=size(energy,1); F=size(correction,2);
scores=zeros(D,F,12,B,'like',real(w));
for f=1:F
 wf=reshape(fft(w.*correction(:,f),len,1),len,1,B);
 corr=ifft(wf.*reference,[],1);
 normalized=abs(corr(count:count+D-1,:,:)).^2./max(reshape(energy*referenceEnergy,D,1,B),realmin);
 scores(:,f,:,:)=reshape(normalized,D,1,12,B);
end
end

function scores=hostGpu(w,reference,correction,energy,referenceEnergy,count,len)
scores=gather(matrixKernel(gpuArray(w),reference,correction,gpuArray(energy),referenceEnergy,count,len));
end
