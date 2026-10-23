function summary=exportDevelopmentDataset(resultFile,outputFolder)
%EXPORTDEVELOPMENTDATASET Export one completed, locally bounded case as development data.
%   Экспорт датасета одного локального прогона (кнопка «Экспортировать датасет», ТЗ §46.5).
if ~(ischar(resultFile)||(isstring(resultFile)&&isscalar(resultFile))) || ...
        isempty(strtrim(char(resultFile))) || ~isfile(char(resultFile))
    error('nbiot:dataset:InvalidCase','Choose a saved, verified result MAT file.');
end
if ~(ischar(outputFolder)||(isstring(outputFolder)&&isscalar(outputFolder))) || ...
        isempty(strtrim(char(outputFolder)))
    error('nbiot:dataset:Output','Choose a folder for the exported dataset.');
end
resultFile=char(resultFile); outputFolder=char(outputFolder);
variables=whos('-file',resultFile);
names={variables.name};
if ~all(ismember({'configSnapshot','resultStatus'},names))
    error('nbiot:dataset:InvalidCase','The saved result has no verified case metadata. Save it again from the current interface.');
end
snapshot=load(resultFile,'configSnapshot','resultStatus');
if ~strcmp(char(string(snapshot.resultStatus)),'completed')
    error('nbiot:dataset:ResultStatus','Only a completed run can be exported as development data.');
end
cfg=nbiot.config.validateConfig(snapshot.configSnapshot);
execution=localDevelopment();
nbiot.experiments.validateExecutionBudget(cfg,execution,1);
assignments=table(double(cfg.simulation.realizationId),"development","development", ...
    'VariableNames',{'externalRealizationId','split','experimentRole'});
options=struct('resultFiles',{{resultFile}},'splitManifest',assignments, ...
    'outputFolder',outputFolder,'purpose','development');
data=buildLoadDataset(options);
summary=struct('outputFolder',outputFolder,'realizationId',double(cfg.simulation.realizationId), ...
    'rows',height(data.features),'kind',char(string(data.manifest.kind)));
end
