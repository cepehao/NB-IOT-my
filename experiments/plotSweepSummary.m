function report=plotSweepSummary(input,outputFolder)
% Verified independent runs; failed/partial rows remain in the audit.
%   Графики серии прогонов по нагрузкам (ТЗ §29).
if istable(input), manifest=input; else, manifest=readtable(input,'TextType','string'); end
required={'numUE','burstDurationTicks','realizationId','status','resultFile','caseKey','configSha256','sourceSha256','calibrationSha256'};
assert(all(ismember(required,manifest.Properties.VariableNames)),'nbiot:results:Manifest','Missing manifest columns.');
assert(height(manifest)>0,'nbiot:results:Manifest','Manifest is empty.');
assert(numel(unique(string(manifest.sourceSha256)))==1 && numel(unique(string(manifest.calibrationSha256)))==1,...
 'nbiot:results:MixedVersions','Summarize each source/calibration revision separately.');
keys=string(manifest.numUE)+"/"+string(manifest.burstDurationTicks)+"/"+string(manifest.realizationId);
assert(numel(unique(keys))==height(manifest),'nbiot:results:DuplicateRealization','Repeated external realization in a condition.');
if isfolder(outputFolder), error('nbiot:results:OutputExists','Use fresh summary folder.'); end
audit=manifest; audit.integrityPassed=false(height(manifest),1); audit.integrityError=strings(height(manifest),1);
loaded=cell(height(manifest),1);
for k=1:height(manifest)
 path=char(string(manifest.resultFile(k))); folder=fileparts(path);
 expected=struct();
 for field={'caseKey','configSha256','sourceSha256','calibrationSha256'}
  expected.(field{1})=char(string(manifest.(field{1})(k)));
 end
 checked=nbiot.results.verifyCase(folder,expected);
 if checked.passed
  data=load(path,'result'); result=data.result;
  matched=strcmp(result.status,char(string(manifest.status(k)))) && ...
   result.config.simulation.numUE==manifest.numUE(k) && ...
   result.config.simulation.realizationId==manifest.realizationId(k) && ...
   result.config.traffic.burstDurationTicks==manifest.burstDurationTicks(k);
  audit.integrityPassed(k)=matched;
  if matched, loaded{k}=result; else, audit.integrityError(k)="Manifest and MAT identity/status differ."; end
 else
  audit.integrityError(k)=string(strjoin(checked.errors,'; '));
 end
end
pairs=unique(manifest(:,{'numUE','burstDurationTicks'}),'rows'); conditionRows={}; metricRows={};
names={'raSuccessProbability','deliveryProbability','throughputBitsPerSecond','meanDelayTicks',...
 'dataBler','ulOccupancy','dlOccupancy','dropProbability','dropped','unfinished',...
 'meanWaitingQueuePerUe','meanRaUe'};
for ci=1:height(pairs)
 select=manifest.numUE==pairs.numUE(ci) & manifest.burstDurationTicks==pairs.burstDurationTicks(ci);
 statuses=string(manifest.status(select)); good=select & audit.integrityPassed & string(manifest.status)=="completed";
 accepted=loaded(good); raSuccess=0; raStarted=0; delivered=0; created=0;
 for j=1:numel(accepted)
  a=accepted{j}.kpiSummary; raSuccess=raSuccess+a.raSuccess; raStarted=raStarted+a.raStarted;
  delivered=delivered+a.delivered; created=created+a.created;
 end
 conditionRows(end+1,:)={pairs.numUE(ci),pairs.burstDurationTicks(ci),sum(select),sum(good),...
  sum(statuses=="failed"),sum(statuses=="partial"),sum(statuses=="stopped"),...
  sum(~ismember(statuses,["completed","failed","partial","stopped"])),...
  sum(select & ~audit.integrityPassed),raSuccess,raStarted,delivered,created}; %#ok<AGROW>
 for f=1:numel(names)
  x=NaN(numel(accepted),1);
  for j=1:numel(accepted)
   r=accepted{j};
   if f<=10
    x(j)=r.kpiSummary.(names{f});
   else
    targets=r.dataset.targets; widths=targets.endTick-targets.startTick;
    if sum(widths)>0, x(j)=sum(targets.(names{f}).*widths)/sum(widths); end
   end
  end
  x=x(isfinite(x)); n=numel(x); mu=NaN; se=NaN; lo=NaN; hi=NaN;
  if n>0, mu=mean(x); end
  if n>1
   se=std(x,0)/sqrt(n); df=n-1; q=betaincinv(.05,df/2,.5); critical=sqrt(df*(1/q-1));
   lo=mu-critical*se; hi=mu+critical*se;
  end
  metricRows(end+1,:)={pairs.numUE(ci),pairs.burstDurationTicks(ci),names{f},numel(accepted),n,mu,se,lo,hi}; %#ok<AGROW>
 end
end
conditions=cell2table(conditionRows,'VariableNames',{'numUE','burstDurationTicks','totalRuns','completedRuns',...
 'failedRuns','partialRuns','stoppedRuns','otherStatusRuns','integrityFailures',...
 'raSuccessNumerator','raStartedDenominator','deliveredNumerator','createdDenominator'});
metrics=cell2table(metricRows,'VariableNames',{'numUE','burstDurationTicks','metric','completedRuns','finiteRuns','mean','standardError','ci95Low','ci95High'});
mkdir(outputFolder); writetable(audit,fullfile(outputFolder,'audit.csv'));
writetable(conditions,fullfile(outputFolder,'conditions.csv')); writetable(metrics,fullfile(outputFolder,'metrics.csv'));
report=struct('conditions',conditions,'metrics',metrics,'audit',audit,...
 'sourceSha256',char(string(manifest.sourceSha256(1))),...
 'calibrationSha256',char(string(manifest.calibrationSha256(1))),...
 'ciDefinition','Two-sided Student-t across finite external independent completed runs; n<2 gives NaN CI. Queue/RA integrals are first averaged within each run, never treated as independent windows. Intervals are not clipped to physical limits.',...
 'statusDefinition','All input runs remain in audit. Only integrity-verified completed runs enter statistics.');
save(fullfile(outputFolder,'report.mat'),'report');
figureHandle=figure('Visible','off','Position',[100 100 1600 1100]);
cleanup=onCleanup(@() close(figureHandle)); %#ok<NASGU>
tiledlayout(3,4,'TileSpacing','compact'); bursts=unique(manifest.burstDurationTicks);
for f=1:numel(names)
 nexttile; hold on;
 for duration=bursts'
  rows=metrics(strcmp(metrics.metric,names{f}) & metrics.burstDurationTicks==duration,:); rows=sortrows(rows,'numUE');
  errorbar(rows.numUE,rows.mean,rows.mean-rows.ci95Low,rows.ci95High-rows.mean,'-o',...
   'DisplayName',sprintf('burst %g ms',duration));
 end
 title(names{f},'Interpreter','none'); xlabel('UE count'); grid on;
 if f==1, legend('Location','best'); end
end
exportgraphics(figureHandle,fullfile(outputFolder,'summary.png'),'Resolution',160);
end

