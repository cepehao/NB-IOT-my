classdef SimulationSession < handle
    %SIMULATIONSESSION Own one bounded simulator session for the user interface.
    %   Сессия расчёта для GUI (ТЗ §46.5): запуск/пауза/продолжение/стоп шагами модели;
    %   GUI не меняет RNG и шаг модели (ТЗ §46.15–46.17).
    properties (SetAccess=private)
        Status = 'idle'
        Config = struct()
        LastError = ''
        SavedPath = ''
    end
    properties (Access=private)
        Simulator = []
        Execution = struct()
        SimulatorFactory = []
    end
    methods
        function obj=SimulationSession(execution,simulatorFactory)
            if nargin<1 || isempty(execution), execution=localDevelopment(); end
            if nargin<2 || isempty(simulatorFactory)
                % Keep the production path on the physical simulator by default.
                simulatorFactory=@(cfg,scenario,budget,controllerOptions) ...
                    nbiot.NBIoTSimulator(cfg,scenario,budget,controllerOptions);
            end
            if ~isa(simulatorFactory,'function_handle')
                error('nbiot:ui:SimulatorFactory','Simulator factory must be a function handle.');
            end
            obj.Execution=execution;
            obj.SimulatorFactory=simulatorFactory;
        end
        function start(obj,cfg,controllerOptions)
            if nargin<3||isempty(controllerOptions), controllerOptions=struct(); end
            if ~strcmp(obj.Status,'idle')
                error('nbiot:ui:SessionState','Reset the session before starting another run.');
            end
            if ~isstruct(controllerOptions)||~isscalar(controllerOptions)
                error('nbiot:ui:ControllerOptions', ...
                    'Controller options must be a scalar structure.');
            end
            budget=nbiot.experiments.validateExecutionBudget(cfg,obj.Execution);
            cfg=nbiot.config.validateConfig(cfg);
            if cfg.simulation.numUE>budget.maxUE
                error('nbiot:ui:ExecutionLimit', ...
                    'The configured device count exceeds the selected execution profile.');
            end
            if cfg.simulation.durationTicks>5000
                error('nbiot:ui:ExecutionHorizon', ...
                    'The supported UI horizon is limited to 5000 ticks.');
            end
            if ~isfinite(cfg.phy.nprachThreshold)
                error('nbiot:phy:Calibration','Load a matching accepted NPRACH calibration before starting.');
            end
            nbiot.phy.requireToolbox();
            obj.LastError=''; obj.SavedPath=''; obj.Config=cfg;
            try
                factoryInputCount=nargin(obj.SimulatorFactory);
                if factoryInputCount<0||factoryInputCount>=4
                    obj.Simulator=obj.SimulatorFactory( ...
                        cfg,[],obj.Execution,controllerOptions);
                elseif isempty(fieldnames(controllerOptions))
                    obj.Simulator=obj.SimulatorFactory(cfg,[],obj.Execution);
                else
                    error('nbiot:ui:SimulatorFactoryOptions', ...
                        'The simulator factory cannot accept controller options.');
                end
                obj.Status='running';
            catch exception
                obj.LastError=exception.message;
                obj.Status='failed';
                rethrow(exception);
            end
        end
        function advance(obj,ticks)
            if nargin<2, ticks=20; end
            validateattributes(ticks,{'numeric'},{'scalar','integer','positive','<=',1000});
            if ~strcmp(obj.Status,'running'), return; end
            if strcmp(obj.Simulator.status,'ready')
                untilTick=min(obj.Config.simulation.durationTicks,ticks-1);
            else
                untilTick=min(obj.Config.simulation.durationTicks,obj.Simulator.currentTick+ticks);
            end
            obj.Simulator.run(untilTick);
            switch obj.Simulator.status
                case 'completed'
                    obj.Status='completed';
                case {'stopped','failed'}
                    obj.Status=obj.Simulator.status;
                    if isfield(obj.Simulator.errorInfo,'message')
                        obj.LastError=obj.Simulator.errorInfo.message;
                    end
                otherwise
                    obj.Status='running';
            end
        end
        function pause(obj)
            if strcmp(obj.Status,'running'), obj.Status='paused'; end
        end
        function resume(obj)
            if strcmp(obj.Status,'paused'), obj.Status='running'; end
        end
        function stop(obj)
            if any(strcmp(obj.Status,{'running','paused'}))
                if ~isempty(obj.Simulator)
                    obj.Simulator.stop('user-stop');
                end
                obj.Status='stopped';
            end
        end
        function reset(obj)
            obj.stop();
            obj.Simulator=[]; obj.Config=struct(); obj.Status='idle';
            obj.LastError=''; obj.SavedPath='';
        end
        function state=snapshot(obj)
            state=struct();
            state.status=obj.Status; state.tick=0; state.durationTicks=0;
            state.packetCounters=struct(); state.deviceTable=cell(0,4);
            state.transmittedPacketCount=0;
            state.crcCounters=struct('msg3Errors',0,'dataErrors',0);
            state.runtimeAction=struct('accessProbability',1,'raShare',0.1,'effectiveTick',0);
            state.controllerLatestEstimate=struct('valid',false,'value',NaN, ...
                'featureWindowEndTick',NaN,'reason','not-started');
            state.controllerLog=struct([]); state.controllerMethod='Static';
            state.controllerDiagnosticTargets=table(zeros(0,1),zeros(0,1), ...
                'VariableNames',{'endTick','meanRaUe'});
            state.liveRadioDiagnostics=struct('asOfTick',0,'status','pending', ...
                'summary',struct('available',false,'actualTick',0, ...
                'lastEventTick',NaN),'perUe',struct([]));
            state.ueDetails=struct('ueId',{},'xM',{},'yM',{},'distanceM',{}, ...
                'indoor',{},'receivedPowerUlDbm',{},'receivedPowerDlDbm',{}, ...
                'raAttempts',{},'state',{},'queueLength',{},'radioSummary',{});
            state.tickSeconds=1e-3;
            state.positions=zeros(0,2); state.radiusM=NaN; state.error=obj.LastError;
            if isempty(obj.Simulator), return; end
            base=obj.Simulator.snapshot();
            state.tick=base.tick; state.durationTicks=obj.Config.simulation.durationTicks;
            state.tickSeconds=obj.Config.simulation.tickSeconds;
            state.packetCounters=base.packetCounters;
            if isfield(base,'transmittedPacketCount')
                state.transmittedPacketCount=base.transmittedPacketCount;
            end
            if isfield(base,'crcCounters'), state.crcCounters=base.crcCounters; end
            if isfield(base,'runtimeAction'), state.runtimeAction=base.runtimeAction; end
            if isfield(base,'controllerLatestEstimate')
                state.controllerLatestEstimate=base.controllerLatestEstimate;
            end
            if isfield(base,'controllerLog'), state.controllerLog=base.controllerLog; end
            if isfield(base,'controllerMethod'), state.controllerMethod=base.controllerMethod; end
            if isfield(base,'controllerDiagnosticTargets')
                state.controllerDiagnosticTargets=base.controllerDiagnosticTargets;
            end
            devices=base.devices; positions=obj.Simulator.scenario.ue;
            rows=cell(numel(devices),4);
            radioTemplate=struct('status','pending', ...
                'referenceSnrUlDb',NaN,'referenceSnrDlDb',NaN, ...
                'perAttempt',struct([]),'receiverEstimates',struct([]), ...
                'npuschReceiverEstimates',struct([]));
            detailTemplate=struct('ueId',0,'xM',0,'yM',0,'distanceM',0, ...
                'indoor',false,'receivedPowerUlDbm',NaN,'receivedPowerDlDbm',NaN, ...
                'raAttempts',0,'state','','queueLength',0, ...
                'radioSummary',radioTemplate);
            details=repmat(detailTemplate,numel(devices),1);
            if ~isempty(devices)
                linkBudget=obj.Simulator.scenario.linkBudget;
                attemptCounts=zeros(numel(devices),1);
                attempts=obj.Simulator.attempts;
                for attemptIndex=1:numel(attempts)
                    ueId=double(attempts(attemptIndex).ueId);
                    if ueId>=1&&ueId<=numel(attemptCounts)&&ueId==fix(ueId)
                        attemptCounts(ueId)=attemptCounts(ueId)+1;
                    end
                end
            end
            for k=1:numel(devices)
                rows{k,1}=k; rows{k,2}=devices(k).state;
                rows{k,3}=obj.Simulator.packets.queueLength(k);
                rows{k,4}=logical(positions(k).indoor);
                details(k)=struct('ueId',double(positions(k).ueId), ...
                    'xM',double(positions(k).xM),'yM',double(positions(k).yM), ...
                    'distanceM',double(positions(k).distanceM), ...
                    'indoor',logical(positions(k).indoor), ...
                    'receivedPowerUlDbm',double(linkBudget(k).receivedPowerUlDbm), ...
                    'receivedPowerDlDbm',double(linkBudget(k).receivedPowerDlDbm), ...
                    'raAttempts',attemptCounts(k),'state',char(devices(k).state), ...
                    'queueLength',obj.Simulator.packets.queueLength(k), ...
                    'radioSummary',struct('status','pending', ...
                        'referenceSnrUlDb',double(linkBudget(k).referenceSnrUlDb), ...
                        'referenceSnrDlDb',double(linkBudget(k).referenceSnrDlDb), ...
                        'perAttempt',struct([]),'receiverEstimates',struct([]), ...
                        'npuschReceiverEstimates',struct([])));
            end
            if ismethod(obj.Simulator,'liveRadioDiagnostics')
                live=obj.Simulator.liveRadioDiagnostics();
                state.liveRadioDiagnostics=live;
                for k=1:numel(details)
                    details(k).radioSummary=radioSummaryForLiveUe( ...
                        details(k).radioSummary,live,details(k).ueId);
                end
            end
            if any(strcmp(obj.Status,{'completed','stopped','failed'}))
                batchDiagnostics=[];
                if ismethod(obj.Simulator,'result')
                    try
                        finalResult=obj.Simulator.result();
                        if isstruct(finalResult)&&isscalar(finalResult)&& ...
                                isfield(finalResult,'radioDiagnostics')&& ...
                                isstruct(finalResult.radioDiagnostics)&& ...
                                isscalar(finalResult.radioDiagnostics)
                            batchDiagnostics=finalResult.radioDiagnostics;
                        end
                    catch
                        batchDiagnostics=[];
                    end
                end
                lastEventTick=NaN;
                if isstruct(state.liveRadioDiagnostics)&& ...
                        isfield(state.liveRadioDiagnostics,'summary')&& ...
                        isstruct(state.liveRadioDiagnostics.summary)&& ...
                        isscalar(state.liveRadioDiagnostics.summary)&& ...
                        isfield(state.liveRadioDiagnostics.summary,'lastEventTick')
                    lastEventTick=state.liveRadioDiagnostics.summary.lastEventTick;
                end
                state.liveRadioDiagnostics.asOfTick=state.tick;
                if ~isempty(batchDiagnostics)
                    batchDiagnostics.lastEventTick=lastEventTick;
                    state.liveRadioDiagnostics.summary=batchDiagnostics;
                    if isfield(batchDiagnostics,'available')&& ...
                            islogical(batchDiagnostics.available)&& ...
                            isscalar(batchDiagnostics.available)&& ...
                            batchDiagnostics.available
                        state.liveRadioDiagnostics.status='available';
                    else
                        state.liveRadioDiagnostics.status='unavailable';
                    end
                    for k=1:numel(details)
                        details(k).radioSummary=radioSummaryForUe( ...
                            details(k).radioSummary,batchDiagnostics,details(k).ueId);
                    end
                else
                    state.liveRadioDiagnostics.status='unavailable';
                    state.liveRadioDiagnostics.summary=struct( ...
                        'available',false,'actualTick',state.tick, ...
                        'lastEventTick',lastEventTick);
                    for k=1:numel(details)
                        details(k).radioSummary.status='unavailable';
                    end
                end
            end
            state.deviceTable=rows;
            state.ueDetails=details;
            state.positions=[[positions.xM].',[positions.yM].'];
            state.radiusM=obj.Config.cell.radiusM;
            state.status=obj.Status; state.error=obj.LastError;
        end
        function [events,nextIndex]=observedEventsSince(obj,afterIndex)
            if nargin<2, afterIndex=0; end
            events=struct('tick',{},'kind',{},'fields',{});
            nextIndex=afterIndex;
            if isempty(obj.Simulator), return; end
            if ismethod(obj.Simulator,'observedEventsSince')
                [events,nextIndex]=obj.Simulator.observedEventsSince(afterIndex);
            end
        end
        function result=getResult(obj)
            if isempty(obj.Simulator)
                error('nbiot:ui:SessionState','There is no simulation result to save.');
            end
            result=obj.Simulator.result();
        end
        function data=liveStaticChartData(obj)
            if isempty(obj.Simulator)
                error('nbiot:ui:SessionState','There is no simulation result to display.');
            end
            data=nbiot.ui.buildStaticChartData(obj.Simulator.result());
        end
        function value=hasResult(obj)
            value=~isempty(obj.Simulator);
        end
        function destination=save(obj,folder)
            if isempty(obj.Simulator)
                error('nbiot:ui:SessionState','There is no simulation result to save.');
            end
            if isfolder(folder)
                contents=dir(folder); contents=contents(~ismember({contents.name},{'.','..'}));
                if ~isempty(contents)
                    error('nbiot:ui:OutputExists','Choose an empty folder for the exported result.');
                end
            elseif isfile(folder)
                error('nbiot:ui:OutputExists','The output path is an existing file.');
            end
            result=obj.Simulator.result();
            root=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
            metadata=nbiot.experiments.runtimeManifest(obj.Config,struct('projectRoot',root));
            destination=nbiot.results.saveResult(result,folder,metadata);
            obj.SavedPath=destination;
        end
        function close(obj)
            obj.stop();
        end
    end
end

function summary=radioSummaryForUe(summary,diagnostics,ueId)
if ~isstruct(diagnostics)||~isscalar(diagnostics)|| ...
        ~isfield(diagnostics,'available')||~islogical(diagnostics.available)|| ...
        ~isscalar(diagnostics.available)
    summary.status='unavailable';
    return;
end
summary.status='available';
summary.perAttempt=radioRowsForUe(diagnostics,'perAttempt',ueId);
summary.receiverEstimates=radioRowsForUe(diagnostics,'receiverEstimates',ueId);
summary.npuschReceiverEstimates=radioRowsForUe( ...
    diagnostics,'npuschReceiverEstimates',ueId);
end

function summary=radioSummaryForLiveUe(summary,live,ueId)
if ~isstruct(live)||~isscalar(live)|| ...
        ~all(isfield(live,{'status','summary','perUe'}))|| ...
        ~isstruct(live.summary)||~isscalar(live.summary)
    summary.status='unavailable';
    return;
end
if isfield(live.summary,'available')&&islogical(live.summary.available)&& ...
        isscalar(live.summary.available)&&live.summary.available
    summary.status='available';
elseif ischar(live.status)|| (isstring(live.status)&&isscalar(live.status))
    summary.status=char(string(live.status));
else
    summary.status='pending';
end
if ~isstruct(live.perUe)||isempty(live.perUe)|| ...
        ~isfield(live.perUe,'ueId')
    return;
end
ueIds=[live.perUe.ueId];
match=find(isfinite(ueIds)&ueIds==ueId,1,'last');
if isempty(match), return; end
ue=live.perUe(match);
copyFields={'perAttempt','receiverEstimates','npuschReceiverEstimates'};
for k=1:numel(copyFields)
    field=copyFields{k};
    if isfield(ue,field)&&isstruct(ue.(field))
        summary.(field)=ue.(field);
    end
end
end

function rows=radioRowsForUe(diagnostics,name,ueId)
rows=struct([]);
if ~isfield(diagnostics,name)||~isstruct(diagnostics.(name))|| ...
        isempty(diagnostics.(name))||~isfield(diagnostics.(name),'ueId')
    return;
end
rows=diagnostics.(name);
ids=[rows.ueId];
if ~isnumeric(ids)||numel(ids)~=numel(rows)
    rows=struct([]);
    return;
end
rows=rows(isfinite(ids)&ids==ueId);
end
