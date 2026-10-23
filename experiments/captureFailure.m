function artifact=captureFailure(sim,options)
% Selected recent RX window only; analyzer truth lives in a separate file.
%   Сохранение окна приёма для разбора сбоя (истина — отдельным файлом).
assert(sim.cfg.logging.saveWaveforms,'nbiot:diagnostics:Disabled',...
    'Set logging.saveWaveforms=true before requesting a selected capture.');
required={'direction','receiverId','startSample','endSample','byteBudget','outputFolder'};
for k=1:numel(required), assert(isfield(options,required{k}),'nbiot:diagnostics:Options','Missing %s.',required{k}); end
validateattributes(options.startSample,{'numeric'},{'scalar','integer','nonnegative'});
validateattributes(options.endSample,{'numeric'},{'scalar','integer','>',options.startSample});
validateattributes(options.byteBudget,{'numeric'},{'scalar','integer','positive'});
assert(any(strcmpi(options.direction,{'UL','DL'})),'nbiot:diagnostics:Options','Expected UL or DL.');
validateattributes(options.receiverId,{'numeric'},{'scalar','integer','nonnegative'});
budget=options.byteBudget;
if isfield(sim.cfg.logging,'waveformByteBudget'), budget=min(budget,sim.cfg.logging.waveformByteBudget); end
assert(16*(options.endSample-options.startSample)<budget,...
    'nbiot:diagnostics:Budget','Requested complex-double RX exceeds byte budget.');
assert(options.startSample>=max(0,(sim.currentTick-128)*1920),...
    'nbiot:diagnostics:History','Requested window is older than channel retention.');
assert(options.endSample<=sim.cfg.simulation.durationTicks*1920,...
    'nbiot:diagnostics:Options','Requested window exceeds horizon.');
rx=sim.channel.receive(options.direction,options.receiverId,options.startSample,options.endSample);
cfg=sim.cfg;
% Calibration data arrays are offline evidence, not needed to replay RX.
if isfield(cfg,'calibrationReport'), cfg=rmfield(cfg,'calibrationReport'); end
result=sim.result(); truth=result.truthLog;
firstTick=options.startSample/1920; lastTick=options.endSample/1920;
truth=truth([truth.tick]>=firstTick & [truth.tick]<lastTick);
root=fileparts(fileparts(mfilename('fullpath')));
metadata=struct('options',options,'captureTick',sim.currentTick,'status',sim.status,...
 'sourceManifest',optimizationSourceManifest(root),'configSha256',nbiot.results.configSha256(cfg),...
 'matlabRelease',version('-release'),'scope','Received channel samples only. Truth file is offline analyzer evidence; not decoder input.');
folder=fullfile(options.outputFolder,['capture-' char(java.util.UUID.randomUUID())]);
if ~isfolder(options.outputFolder), mkdir(options.outputFolder); end
mkdir(folder); receiverFile=fullfile(folder,'receiver.mat'); truthFile=fullfile(folder,'truth.mat');
markerFile=fullfile(folder,'completed.json'); pendingFile=fullfile(folder,'pending.json');
cleanup=onCleanup(@() rollbackFiles(folder,receiverFile,truthFile,pendingFile,markerFile)); %#ok<NASGU>
save(receiverFile,'rx','cfg','metadata','-v7'); save(truthFile,'truth','-v7');
marker=struct('receiverSha256',hashFile(receiverFile),'truthSha256',hashFile(truthFile),...
 'byteBudget',budget,'captureTick',sim.currentTick);
fid=fopen(pendingFile,'w'); assert(fid>=0,'nbiot:diagnostics:Write','Cannot write marker.');
fileCleanup=onCleanup(@() fclose(fid)); fprintf(fid,'%s',jsonencode(marker)); clear fileCleanup
files=dir(folder); bytes=sum([files(~[files.isdir]).bytes]);
assert(bytes<=budget,'nbiot:diagnostics:Budget','Serialized capture exceeds byte budget.');
check=load(receiverFile,'rx'); assert(isequaln(check.rx,rx),'nbiot:diagnostics:Readback','RX readback differs.');
movefile(pendingFile,markerFile);
artifact=struct('receiverFile',receiverFile,'truthFile',truthFile,'markerFile',markerFile,...
 'totalBytes',bytes,'byteBudget',budget);
end
function rollbackFiles(folder,receiverFile,truthFile,pendingFile,markerFile)
if isfile(markerFile), return; end
known={receiverFile,truthFile,pendingFile};
for f=1:numel(known), if isfile(known{f}), delete(known{f}); end, end
if isfolder(folder), rmdir(folder); end
end
function value=hashFile(path)
fid=fopen(path,'rb'); assert(fid>=0); cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=fread(fid,Inf,'*uint8'); digest=java.security.MessageDigest.getInstance('SHA-256');
digest.update(bytes); raw=typecast(digest.digest(),'uint8'); value=lower(reshape(dec2hex(raw,2).',1,[]));
end
