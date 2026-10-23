function [lines,hiddenCount]=formatObservedEvents(events,showZeroDetection)
%FORMATOBSERVEDEVENTS Format base-station-observed radio events for the UI.
if nargin<2||isempty(showZeroDetection), showZeroDetection=false; end
if ~islogical(showZeroDetection)||~isscalar(showZeroDetection)
    error('nbiot:ui:ObservedEventFilter', ...
        'showZeroDetection must be a logical scalar.');
end
lines=cell(0,1); hiddenCount=0;
if isempty(events), return; end
required={'tick','kind','fields'};
if ~isstruct(events)||~all(isfield(events,required)), return; end
for k=1:numel(events)
    event=events(k); fields=event.fields;
    if ~isstruct(fields)||~isscalar(fields), continue; end
    switch char(event.kind)
        case 'nprach_detection'
            if ~all(isfield(fields,{'count','maxMetric'})), continue; end
            if ~showZeroDetection&&isnumeric(fields.count)&& ...
                    isscalar(fields.count)&&isfinite(fields.count)&&fields.count==0
                hiddenCount=hiddenCount+1;
                continue;
            end
            line=sprintf('t=%.0f мс · Обнаружение доступа: кандидатов %.0f, показатель %.3g', ...
                event.tick,fields.count,fields.maxMetric);
        case 'grant'
            if ~all(isfield(fields,{'phase','rnti','format','startTick','endTick'})), continue; end
            line=sprintf(['t=%.0f мс · Назначен будущий интервал управляющей передачи ' ...
                'для %s, формат %s, RNTI %.0f: %.0f–%.0f мс'], ...
                event.tick,char(fields.phase),char(fields.format),fields.rnti, ...
                fields.startTick,fields.endTick);
        case 'rar_sent'
            if ~isfield(fields,'rnti'), continue; end
            line=sprintf(['t=%.0f мс · Подготовлен ответ на запрос доступа (RAR) ' ...
                'для RNTI %.0f'],event.tick,fields.rnti);
        case 'phy_decode'
            if ~all(isfield(fields,{'channel','phase','rnti','hasCrc','crcError','receiverId'}))|| ...
                    fields.receiverId~=0
                continue;
            end
            if ~fields.hasCrc
                outcome='без CRC';
            elseif fields.crcError==0
                outcome='CRC OK';
            else
                outcome='ошибка CRC';
            end
            channel=char(fields.channel); phase=char(fields.phase);
            if strcmpi(channel,'Msg3')&&strcmpi(phase,'RA')
                label='Приём служебного сообщения Msg3/RA';
            else
                label=sprintf('Приём %s/%s',channel,phase);
            end
            line=sprintf('t=%.0f мс · %s, RNTI %.0f: %s',event.tick, ...
                label,fields.rnti,outcome);
        otherwise
            continue;
    end
    lines{end+1,1}=line; %#ok<AGROW>
end
end
