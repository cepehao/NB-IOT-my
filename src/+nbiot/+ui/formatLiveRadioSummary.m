function lines=formatLiveRadioSummary(live,selectedUeId,tickSeconds)
%FORMATLIVERADIOSUMMARY Format presentation-only radio diagnostics for the UI.
%   Текст живой радиодиагностики для GUI (ТЗ §46.7).
if nargin<2, selectedUeId=NaN; end
if nargin<3, tickSeconds=1e-3; end
if ~isstruct(live)||~isscalar(live)|| ...
        ~all(isfield(live,{'asOfTick','status','summary','perUe'}))|| ...
        ~isstruct(live.summary)||~isscalar(live.summary)
    error('nbiot:ui:LiveRadioSummary', ...
        'Live radio diagnostics do not match the supported display format.');
end
if ~isnumeric(live.asOfTick)||~isreal(live.asOfTick)|| ...
        ~isscalar(live.asOfTick)||~isfinite(live.asOfTick)|| ...
        live.asOfTick<0||live.asOfTick~=fix(live.asOfTick)|| ...
        ~isnumeric(tickSeconds)||~isreal(tickSeconds)|| ...
        ~isscalar(tickSeconds)||~isfinite(tickSeconds)||tickSeconds<=0
    error('nbiot:ui:LiveRadioSummary', ...
        'The current tick and tick duration must be valid finite values.');
end

summary=live.summary;
if ~isfield(summary,'lastEventTick')||~validTick(summary.lastEventTick)
    lastEventText='не зарегистрировано';
else
    lastEventText=tickText(summary.lastEventTick,tickSeconds);
end
lines={sprintf('Радиодиагностика на текущий момент: %s; последнее событие: %s', ...
    tickText(live.asOfTick,tickSeconds),lastEventText)};

available=isfield(summary,'available')&&islogical(summary.available)&& ...
    isscalar(summary.available)&&summary.available;
if available
    preamble=requiredStruct(summary,'preamble', ...
        {'transmittedAttempts','transmittedKeys','detectedCandidates', ...
        'detectedKeys','misses','falseAlarms','falseAlarmOpportunities'});
    collision=requiredStruct(summary,'collision', ...
        {'logicalGroups','logicalAttempts','physicalOverlapPairs','physicalAttempts'});
    capture=requiredStruct(summary,'capture', ...
        {'capturedPairs','eligiblePairs','censoredPairs','equalPowerPairs'});
    transmittedAttempts=countValue(preamble.transmittedAttempts,'transmittedAttempts');
    transmittedKeys=countValue(preamble.transmittedKeys,'transmittedKeys');
    detectedCandidates=countValue(preamble.detectedCandidates,'detectedCandidates');
    detectedKeys=countValue(preamble.detectedKeys,'detectedKeys');
    misses=countValue(preamble.misses,'misses');
    falseAlarms=countValue(preamble.falseAlarms,'falseAlarms');
    falseAlarmOpportunities=countValue( ...
        preamble.falseAlarmOpportunities,'falseAlarmOpportunities');
    logicalGroups=countValue(collision.logicalGroups,'logicalGroups');
    logicalAttempts=countValue(collision.logicalAttempts,'logicalAttempts');
    physicalPairs=countValue(collision.physicalOverlapPairs,'physicalOverlapPairs');
    physicalAttempts=countValue(collision.physicalAttempts,'physicalAttempts');
    capturedPairs=countValue(capture.capturedPairs,'capturedPairs');
    eligiblePairs=countValue(capture.eligiblePairs,'eligiblePairs');
    censoredPairs=countValue(capture.censoredPairs,'censoredPairs');
    equalPowerPairs=countValue(capture.equalPowerPairs,'equalPowerPairs');
    lines{end+1}=sprintf( ...
        'Передано попыток: %d; Передано ключей: %d', ...
        transmittedAttempts,transmittedKeys); %#ok<AGROW>
    lines{end+1}=sprintf( ...
        'Обнаружено кандидатов: %d; Совпало ключей: %d; Пропуски: %d', ...
        detectedCandidates,detectedKeys,misses); %#ok<AGROW>
    lines{end+1}=sprintf('Ложные тревоги: %d/%d возможностей', ...
        falseAlarms,falseAlarmOpportunities); %#ok<AGROW>
    lines{end+1}=sprintf( ...
        ['Вероятности NPRACH — обнаружение: %s; пропуск: %s; ' ...
        'ложная тревога: %s'], ...
        probabilityText(preamble,'detectionProbability'), ...
        probabilityText(preamble,'missProbability'), ...
        probabilityText(preamble,'falseAlarmProbability')); %#ok<AGROW>
    lines{end+1}=sprintf( ...
        'Логические коллизии: %d групп, %d попыток; Физические перекрытия: %d пар, %d попыток', ...
        logicalGroups,logicalAttempts,physicalPairs,physicalAttempts); %#ok<AGROW>
    lines{end+1}=sprintf( ...
        'Захват: %d/%d подходящих пар; цензурировано: %d; одинаковая мощность: %d', ...
        capturedPairs,eligiblePairs,censoredPairs,equalPowerPairs); %#ok<AGROW>
else
    lines{end+1}='Счётчики радиодиагностики пока недоступны: ожидается полная диагностика NPRACH.'; %#ok<AGROW>
end

lines{end+1}=selectedSinrText(live.perUe,selectedUeId,tickSeconds); %#ok<AGROW>
lines{end+1}=selectedLastEventText(live.perUe,selectedUeId,tickSeconds); %#ok<AGROW>
end

function text=selectedSinrText(perUe,selectedUeId,tickSeconds)
if ~isnumeric(selectedUeId)||~isreal(selectedUeId)||~isscalar(selectedUeId)|| ...
        ~isfinite(selectedUeId)||selectedUeId<1||selectedUeId~=fix(selectedUeId)
    text='SINR выбранного UE: выберите устройство в таблице.';
    return;
end
[ue,found]=selectedUe(perUe,selectedUeId);
if ~found
    text=sprintf('SINR UE %d: недоступен (измерение не зарегистрировано).',selectedUeId);
    return;
end
if ~isfield(ue,'sinrAvailable')||~islogical(ue.sinrAvailable)|| ...
        ~isscalar(ue.sinrAvailable)||~ue.sinrAvailable|| ...
        ~isfield(ue,'sinrDb')||~isnumeric(ue.sinrDb)|| ...
        ~isreal(ue.sinrDb)||~isscalar(ue.sinrDb)||~isfinite(ue.sinrDb)|| ...
        ~isfield(ue,'sinrTick')||~validTick(ue.sinrTick)
    text=sprintf('SINR UE %d: недоступен (измерений пока нет).',selectedUeId);
    return;
end
text=sprintf('SINR UE %d: %+.3g дБ, измерен на %s', ...
    selectedUeId,double(ue.sinrDb),tickText(ue.sinrTick,tickSeconds));
end

function text=selectedLastEventText(perUe,selectedUeId,tickSeconds)
if ~isnumeric(selectedUeId)||~isreal(selectedUeId)||~isscalar(selectedUeId)|| ...
        ~isfinite(selectedUeId)||selectedUeId<1||selectedUeId~=fix(selectedUeId)
    text='Последнее событие UE: выберите устройство в таблице.';
    return;
end
[ue,found]=selectedUe(perUe,selectedUeId);
if ~found||~isfield(ue,'lastEventTick')||~validTick(ue.lastEventTick)
    text=sprintf('Последнее событие UE %d: недоступно (нет данных).',selectedUeId);
    return;
end
text=sprintf('Последнее событие UE %d: %s', ...
    selectedUeId,tickText(ue.lastEventTick,tickSeconds));
end

function [ue,found]=selectedUe(perUe,selectedUeId)
ue=struct(); found=false;
if ~isstruct(perUe)||isempty(perUe)||~isfield(perUe,'ueId'), return; end
ids=[perUe.ueId];
match=find(isfinite(ids)&ids==selectedUeId,1,'last');
if isempty(match), return; end
ue=perUe(match); found=true;
end

function text=probabilityText(source,name)
text='недоступна';
if ~isfield(source,name), return; end
value=source.(name);
if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value), return; end
if value<0||value>1
    error('nbiot:ui:LiveRadioSummary', ...
        'Live diagnostic rate %s must be between zero and one.',name);
end
text=sprintf('%.1f%%',100*double(value));
end

function value=requiredStruct(source,name,required)
if ~isfield(source,name)||~isstruct(source.(name))|| ...
        ~isscalar(source.(name))||~all(isfield(source.(name),required))
    error('nbiot:ui:LiveRadioSummary', ...
        'Available live diagnostics are missing required %s fields.',name);
end
value=source.(name);
end

function value=countValue(value,name)
if ~isnumeric(value)||~isreal(value)||~isscalar(value)|| ...
        ~isfinite(value)||value<0||value~=fix(value)
    error('nbiot:ui:LiveRadioSummary', ...
        'Live diagnostic count %s must be a nonnegative integer.',name);
end
value=double(value);
end

function value=validTick(value)
value=isnumeric(value)&&isreal(value)&&isscalar(value)&& ...
    isfinite(value)&&value>=0&&value==fix(value);
end

function text=tickText(tick,tickSeconds)
text=sprintf('tick %d (%.3f с)',double(tick),double(tick)*double(tickSeconds));
end
