function [bundles,report]=trainLoadModels(options)
%TRAINLOADMODELS Train the four load models from one explicitly named dataset.
%   Обучение четырёх ML-моделей по указанному датасету (обёртка над nbiot.ml.trainLoadModels).
if nargin~=1||~isstruct(options)||~isscalar(options)
    error('nbiot:ml:RunnerOptions', ...
        'Supply one options structure with datasetFile and outputFolder.');
end
allowed={'datasetFile','outputFolder','trainingOptions'};
unknown=setdiff(fieldnames(options),allowed);
if ~isempty(unknown)
    error('nbiot:ml:RunnerOptions','Unsupported runner option: %s',unknown{1});
end
required={'datasetFile','outputFolder'};
if ~all(isfield(options,required))
    error('nbiot:ml:RunnerOptions','datasetFile and outputFolder are required.');
end

datasetFile=pathText(options.datasetFile,'datasetFile');
outputFolder=pathText(options.outputFolder,'outputFolder');
if ~isfile(datasetFile)
    error('nbiot:ml:DatasetFile','The explicitly selected dataset file does not exist.');
end
[~,~,extension]=fileparts(datasetFile);
if ~strcmpi(extension,'.mat')
    error('nbiot:ml:DatasetFile','The dataset must be a MAT file containing variable data.');
end
contents=whos('-file',datasetFile);
if ~any(strcmp({contents.name},'data'))
    error('nbiot:ml:DatasetFile','The selected MAT file does not contain variable data.');
end
loaded=load(datasetFile,'data');

if isfield(options,'trainingOptions')
    trainingOptions=options.trainingOptions;
    if ~isstruct(trainingOptions)||~isscalar(trainingOptions)
        error('nbiot:ml:RunnerOptions','trainingOptions must be a scalar structure.');
    end
else
    trainingOptions=mlTrainingDefaults();
end
% The caller-selected destination is authoritative for all model outputs.
trainingOptions.outputFolder=outputFolder;
% The selected file is the provenance source; caller-supplied overrides are ignored.
trainingOptions.datasetFile=datasetFile;
[bundles,report]=nbiot.ml.trainLoadModels(loaded.data,trainingOptions);
end

function value=pathText(value,fieldName)
if isstring(value)&&isscalar(value), value=char(value); end
if ~ischar(value)||isempty(strtrim(value))||size(value,1)~=1
    error('nbiot:ml:RunnerOptions','%s must be a non-empty path.',fieldName);
end
end
