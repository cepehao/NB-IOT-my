function metadata=buildReportMetadata(result)
%BUILDREPORTMETADATA Summarize facts already present in a simulation result.
%   Краткое описание прогона (параметры, итоговые KPI) для подписи сохранённых таблиц.
% This function does not start a simulation or mutate the supplied result.
fields=struct('mode','','numUE',NaN,'activeUE',NaN,'trafficType','', ...
    'payloadBytes',NaN,'periodTicks',NaN,'durationTicks',NaN, ...
    'actualTick',NaN,'tickSeconds',NaN,'durationSeconds',NaN, ...
    'kpiWindowTicks',NaN,'planned',NaN,'created',NaN,'delivered',NaN, ...
    'dropped',NaN,'unfinished',NaN);
unavailable={};
if ~isstruct(result)||~isscalar(result)||~isfield(result,'config')|| ...
        ~isstruct(result.config)||~isscalar(result.config)
    unavailable={'mode','numUE','activeUE','trafficType','payloadBytes', ...
        'durationTicks','tickSeconds','kpiWindowTicks','actualTick', ...
        'created','delivered','dropped','unfinished'};
    metadata=pack(fields,unavailable,'Нет конфигурации или итогов сохранённого запуска.');
    return
end
cfg=result.config;
if isfield(cfg,'policy')&&isstruct(cfg.policy)&&isfield(cfg.policy,'name')
    fields.mode=textValue(cfg.policy.name);
else
    unavailable{end+1}='mode';
end
if isfield(cfg,'simulation')&&isstruct(cfg.simulation)
    sim=cfg.simulation;
    fields.numUE=numericValue(sim,'numUE');
    fields.durationTicks=numericValue(sim,'durationTicks');
    fields.tickSeconds=numericValue(sim,'tickSeconds');
else
    unavailable=[unavailable {'numUE','durationTicks','tickSeconds'}]; %#ok<AGROW>
end
if isnan(fields.numUE), unavailable{end+1}='numUE'; end
if isnan(fields.durationTicks), unavailable{end+1}='durationTicks'; end
if isnan(fields.tickSeconds), unavailable{end+1}='tickSeconds'; end
if isfield(result,'actualTick')
    fields.actualTick=scalarValue(result.actualTick);
end
if isnan(fields.actualTick), unavailable{end+1}='actualTick'; end
if isfinite(fields.actualTick)&&isfinite(fields.tickSeconds)&&fields.tickSeconds>0
    fields.durationSeconds=fields.actualTick*fields.tickSeconds;
end
if isfield(cfg,'traffic')&&isstruct(cfg.traffic)
    traffic=cfg.traffic;
    if isfield(traffic,'kind'), fields.trafficType=textValue(traffic.kind); end
    if isfield(traffic,'packetBytes'), fields.payloadBytes=scalarValue(traffic.packetBytes); end
    if strcmp(fields.trafficType,'periodic')&&isfield(traffic,'periodTicks')
        fields.periodTicks=scalarValue(traffic.periodTicks);
    end
    activeCount=activeUeCount(traffic,fields.numUE);
    fields.activeUE=activeCount;
    if isnan(activeCount), unavailable{end+1}='activeUE'; end
    fields.planned=plannedCount(result,cfg,fields.trafficType,activeCount);
else
    unavailable=[unavailable {'trafficType','payloadBytes','activeUE'}]; %#ok<AGROW>
end
if isnan(fields.payloadBytes), unavailable{end+1}='payloadBytes'; end
if isempty(fields.trafficType), unavailable{end+1}='trafficType'; end
if strcmp(fields.trafficType,'periodic')&&isnan(fields.periodTicks)
    unavailable{end+1}='periodTicks';
end
if isfield(cfg,'dataset')&&isstruct(cfg.dataset)&&isfield(cfg.dataset,'windowTicks')
    fields.kpiWindowTicks=scalarValue(cfg.dataset.windowTicks);
end
if isnan(fields.kpiWindowTicks), unavailable{end+1}='kpiWindowTicks'; end
if isfield(result,'kpiSummary')&&isstruct(result.kpiSummary)
    countNames={'created','delivered','dropped','unfinished'};
    for k=1:numel(countNames)
        name=countNames{k}; fields.(name)=numericValue(result.kpiSummary,name);
        if isnan(fields.(name)), unavailable{end+1}=name; end
    end
else
    unavailable=[unavailable {'created','delivered','dropped','unfinished'}]; %#ok<AGROW>
end
reason='';
if ~isempty(unavailable)
    reason='В отчёте отсутствуют некоторые исходные поля.';
end
metadata=pack(fields,unique(unavailable,'stable'),reason);
end

function metadata=pack(fields,unavailable,reason)
metadata=struct('schemaVersion',1,'caseKey','','canonicalConfigSha256','', ...
    'fields',fields,'unavailableFields',{unavailable},'reason',reason,'files',struct());
end

function count=plannedCount(result,cfg,kind,activeCount)
count=NaN;
switch kind
    case 'none'
        count=0;
    case 'burst'
        count=activeCount;
        if isfield(result,'scenario')&&isstruct(result.scenario)&& ...
                isfield(result.scenario,'arrivals')
            count=numel(result.scenario.arrivals);
        end
    case 'periodic'
        if isfield(result,'scenario')&&isstruct(result.scenario)&& ...
                isfield(result.scenario,'arrivals')
            count=numel(result.scenario.arrivals);
            return
        end
        count=periodicCount(cfg);
end
end

function count=periodicCount(cfg)
count=NaN;
if ~all(isfield(cfg,{'simulation','traffic'}))|| ...
        ~all(isfield(cfg.simulation,{'durationTicks','numUE','seed','realizationId'}))|| ...
        ~all(isfield(cfg.traffic,{'periodTicks','activityMode'}))
    return
end
period=scalarValue(cfg.traffic.periodTicks);
horizon=scalarValue(cfg.simulation.durationTicks);
numUE=scalarValue(cfg.simulation.numUE);
if any(~isfinite([period horizon numUE]))||period<1||horizon<1||numUE<1
    return
end
ids=1:numUE;
if strcmp(textValue(cfg.traffic.activityMode),'explicit')
    if ~isfield(cfg.traffic,'activeUeIds'), return; end
    ids=double(cfg.traffic.activeUeIds(:).');
end
try
    sources=nbiot.randomness.RandomSources( ...
        cfg.simulation.seed,cfg.simulation.realizationId);
    count=0;
    for ueId=ids
        stream=sources.stream('traffic',0,ueId,0);
        phase=period*rand(stream);
        times=phase:period:horizon;
        ticks=ceil(times);
        count=count+sum(ticks<horizon);
    end
catch
    count=NaN;
end
end

function count=activeUeCount(traffic,numUE)
count=NaN;
if ~isfield(traffic,'activityMode'), return; end
mode=textValue(traffic.activityMode);
switch mode
    case 'all'
        count=numUE;
    case 'explicit'
        if isfield(traffic,'activeUeIds')&&isnumeric(traffic.activeUeIds)
            count=numel(traffic.activeUeIds);
        end
end
end

function value=numericValue(container,name)
value=NaN;
if isstruct(container)&&isfield(container,name)
    value=scalarValue(container.(name));
end
end

function value=scalarValue(input)
value=NaN;
if isnumeric(input)&&isreal(input)&&isscalar(input)&&isfinite(input)
    value=double(input);
end
end

function value=textValue(input)
value='';
if (ischar(input)&&isrow(input))||(isstring(input)&&isscalar(input))
    value=char(string(input));
end
end
