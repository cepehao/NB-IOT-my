classdef TestNBIoTAppModelInfo < matlab.unittest.TestCase
    methods (Test)
        function selectedModelShowsPackageInformationAndFixedBandwidth(t)
            folder=tempname; mkdir(folder);
            t.addTeardown(@() removeFolder(folder));
            writeDevelopmentModel(folder);
            dialogs=struct('chooseModelFile',@() deal('fixture.mat',folder));
            app=openNBIoTApp(dialogs);
            t.addTeardown(@() closeApp(app));

            trigger(app.Figure,'Выбрать модель');
            details=findall(app.Figure,'Tag','modelDetails');
            bandwidth=findall(app.Figure,'Tag','fixedBandwidthInfo');
            t.assertEqual(numel(details),1);
            t.assertEqual(numel(bandwidth),1);
            detailText=strjoin(string(details.Value),newline);
            t.verifyTrue(contains(detailText,'Линейная регрессия'));
            t.verifyTrue(contains(detailText,'meanRaUe'));
            t.verifyTrue(contains(detailText,'bs-known-v2'));
            t.verifyTrue(contains(detailText,'detectedCandidates'));
            t.verifyTrue(contains(detailText,'train/test: не приложены'));
            t.verifyTrue(contains(bandwidth.Text,'180 кГц'));
            t.verifyTrue(contains(bandwidth.Text,'фиксирована'));
        end
    end
end

function writeDevelopmentModel(folder)
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'tests'));
schema=nbiot.dataset.featureSchema();
featureNames=schema.observationNames(5:end);
keyNames=schema.observationNames(1:4);
featureCount=numel(featureNames);
bundle=struct('formatVersion','load-model-bundle-v1', ...
    'modelName','linearRegression','model',FixedRegressionPredictor(4), ...
    'schemaVersion',schema.version,'featureNames',{featureNames}, ...
    'keyNames',{keyNames},'targetName','meanRaUe', ...
    'transform',struct('median',zeros(1,featureCount), ...
        'mean',zeros(1,featureCount),'scale',ones(1,featureCount)), ...
    'trainingIds',1,'validationIds',2,'testIds',3,'seed',1, ...
    'status','development','dataKind','development-fixture');
path=fullfile(folder,'fixture.mat');
save(path,'bundle');
manifest=struct('artifactFile','fixture.mat', ...
    'artifactSha256',nbiot.ml.fileSha256(path), ...
    'formatVersion',bundle.formatVersion,'modelName',bundle.modelName, ...
    'schemaVersion',bundle.schemaVersion,'targetName',bundle.targetName, ...
    'featureNames',{bundle.featureNames},'keyNames',{bundle.keyNames}, ...
    'seed',bundle.seed,'status',bundle.status,'trainingIds',bundle.trainingIds, ...
    'validationIds',bundle.validationIds,'testIds',bundle.testIds);
fid=fopen(fullfile(folder,'fixture.json'),'w','n','UTF-8');
cleanup=onCleanup(@() fclose(fid));
fwrite(fid,unicode2native(jsonencode(manifest),'UTF-8'),'uint8');
end

function trigger(fig,label)
button=findall(fig,'Text',label);
assert(isscalar(button),['Expected one button: ' label]);
feval(button.ButtonPushedFcn,button,[]);
end

function closeApp(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
