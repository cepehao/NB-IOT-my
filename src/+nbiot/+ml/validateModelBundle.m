function bundle=validateModelBundle(bundleOrFile,schema)
%VALIDATEMODELBUNDLE Check schema, transformations, model metadata and file hash.
%   Проверка сохранённой ML-модели (bundle): схема признаков, преобразование, метаданные, хеш.
canonical=currentSchema();
if nargin<2||isempty(schema)
    schema=canonical;
else
    validateSchemaAssertion(schema,canonical);
    schema=canonical;
end
if ischar(bundleOrFile)||(isstring(bundleOrFile)&&isscalar(bundleOrFile))
    file=char(string(bundleOrFile));
    if ~isfile(file), error('nbiot:ml:MissingModel','Model package file does not exist.'); end
    [folder,base,extension]=fileparts(file);
    if ~strcmpi(extension,'.mat'), error('nbiot:ml:PackageFile','Model package must be a MAT file.'); end
    sidecar=fullfile(folder,[base '.json']);
    if ~isfile(sidecar), error('nbiot:ml:PackageManifest','Model package manifest is missing.'); end
    try
        manifest=jsondecode(fileread(sidecar));
    catch exception
        error('nbiot:ml:PackageManifest','Cannot read model manifest: %s',exception.message);
    end
    if ~isfield(manifest,'artifactFile')||~strcmp(manifest.artifactFile,[base extension])|| ...
            ~isfield(manifest,'artifactSha256')
        error('nbiot:ml:PackageManifest','Model manifest does not match the selected file.');
    end
    actualHash=nbiot.ml.fileSha256(file);
    if ~strcmpi(actualHash,char(string(manifest.artifactSha256)))
        error('nbiot:ml:PackageHash','Model package checksum does not match its manifest.');
    end
    loaded=load(file,'bundle');
    if ~isfield(loaded,'bundle'), error('nbiot:ml:PackageFile','MAT file does not contain a model bundle.'); end
    bundle=loaded.bundle;
    if ~manifestMatches(manifest,bundle)
        error('nbiot:ml:PackageManifest','Model manifest metadata does not match the package.');
    end
else
    bundle=bundleOrFile;
end
validateStructure(bundle,schema);
end

function validateStructure(bundle,schema)
required={'formatVersion','modelName','model','schemaVersion','featureNames','keyNames', ...
    'targetName','transform','trainingIds','validationIds','testIds','seed','status','dataKind'};
if ~isstruct(bundle)||~isscalar(bundle)||~all(isfield(bundle,required))
    error('nbiot:ml:InvalidModel','Model bundle is missing required metadata.');
end
if ~strcmp(bundle.formatVersion,'load-model-bundle-v1')|| ...
        ~strcmp(bundle.schemaVersion,char(string(schema.version)))|| ...
        ~strcmp(bundle.targetName,'meanRaUe')
    error('nbiot:ml:SchemaMismatch','Model target or feature schema is incompatible.');
end
expectedFeatures=schema.inputNames;
expectedKeys=schema.keyNames;
if ~isequal(cellstr(string(bundle.featureNames)),expectedFeatures)|| ...
        ~isequal(cellstr(string(bundle.keyNames)),expectedKeys)
    error('nbiot:ml:FeatureSchema','Model feature order is incompatible.');
end
allowedNames={'linearRegression','decisionTree','randomForest','gradientBoosting'};
if ~any(strcmp(bundle.modelName,allowedNames))||~ismethod(bundle.model,'predict')
    error('nbiot:ml:InvalidModel','Model type or prediction method is invalid.');
end
if ~isstruct(bundle.transform)||~all(isfield(bundle.transform,{'median','mean','scale'}))
    error('nbiot:ml:InvalidModel','Model transformations are missing.');
end
featureCount=numel(expectedFeatures);
for field={'median','mean','scale'}
    values=bundle.transform.(field{1});
    if ~isnumeric(values)||~isrow(values)||numel(values)~=featureCount||any(~isfinite(values))
        error('nbiot:ml:InvalidModel','Model transformation values are invalid.');
    end
end
if any(bundle.transform.scale<=0)
    error('nbiot:ml:InvalidModel','Feature scales must be positive.');
end
if ~strcmp(bundle.status,'development')|| ...
        ~ismember(bundle.dataKind,{'development-fixture','candidate-training'})
    error('nbiot:ml:InvalidModel','Unsupported model status or training-data purpose.');
end
idFields={'trainingIds','validationIds','testIds'}; idValues=cell(1,3);
for k=1:3
    values=bundle.(idFields{k});
    if ~isnumeric(values)||~isvector(values)||isempty(values)||any(~isfinite(values))|| ...
            numel(unique(values))~=numel(values)
        error('nbiot:ml:InvalidModel','Model split IDs must be non-empty unique numeric IDs.');
    end
    idValues{k}=double(values(:));
end
if ~isempty(intersect(idValues{1},idValues{2}))||~isempty(intersect(idValues{1},idValues{3}))|| ...
        ~isempty(intersect(idValues{2},idValues{3}))
    error('nbiot:ml:GroupLeakage','Saved model split IDs overlap.');
end
end

function schema=currentSchema()
schema=nbiot.dataset.featureSchema();
schema.keyNames=schema.observationNames(1:4);
schema.inputNames=schema.observationNames(5:end);
schema.targetName='meanRaUe';
end

function validateSchemaAssertion(asserted,canonical)
if ~isstruct(asserted)||~isscalar(asserted)|| ...
        ~all(isfield(asserted,{'version','keyNames','inputNames','targetName'}))
    error('nbiot:ml:FeatureSchema','Schema assertion must declare version, keys, inputs and target.');
end
try
    version=char(string(asserted.version));
    keys=normalizeNames(asserted.keyNames);
    inputs=normalizeNames(asserted.inputNames);
    target=char(string(asserted.targetName));
catch
    error('nbiot:ml:FeatureSchema','Schema assertion is malformed.');
end
if ~strcmp(version,canonical.version)||~isequal(keys,canonical.keyNames)|| ...
        ~isequal(inputs,canonical.inputNames)||~strcmp(target,canonical.targetName)
    error('nbiot:ml:FeatureSchema','Schema assertion cannot extend the canonical whitelist.');
end
end

function names=normalizeNames(value)
names=cellstr(string(value));
names=reshape(names,1,[]);
if any(cellfun(@isempty,names))
    error('nbiot:ml:FeatureSchema','Schema names must be non-empty text.');
end
end

function matches=manifestMatches(manifest,bundle)
required={'formatVersion','modelName','schemaVersion','targetName','featureNames', ...
    'keyNames','seed','status','trainingIds','validationIds','testIds'};
if ~all(isfield(manifest,required)), matches=false; return; end
matches=strcmp(char(string(manifest.formatVersion)),bundle.formatVersion)&& ...
    strcmp(char(string(manifest.modelName)),bundle.modelName)&& ...
    strcmp(char(string(manifest.schemaVersion)),bundle.schemaVersion)&& ...
    strcmp(char(string(manifest.targetName)),bundle.targetName)&& ...
    isequal(string(manifest.featureNames(:)),string(bundle.featureNames(:)))&& ...
    isequal(string(manifest.keyNames(:)),string(bundle.keyNames(:)))&& ...
    isequal(double(manifest.seed),double(bundle.seed))&& ...
    strcmp(char(string(manifest.status)),bundle.status)&& ...
    isequal(double(manifest.trainingIds(:)),double(bundle.trainingIds(:)))&& ...
    isequal(double(manifest.validationIds(:)),double(bundle.validationIds(:)))&& ...
    isequal(double(manifest.testIds(:)),double(bundle.testIds(:)));
if matches&&isfield(manifest,'dataKind')
    matches=strcmp(char(string(manifest.dataKind)),char(string(bundle.dataKind)));
end
end
