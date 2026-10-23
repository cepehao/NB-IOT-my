function validateStage2ReceiverChecks(checks)
%VALIDATESTAGE2RECEIVERCHECKS Enforce deterministic Stage 2 receiver controls.
%   Контрольные проверки приёмника Stage 2. [инфраструктура v4: приёмка/внешние запуски, не требование ТЗ]
required={'condition','id','present','ownDetected','miss','falseAlarm',...
    'estimatedDelaySamples','estimatedCfoHz','actualDelaySamples','actualCfoHz'};
if ~istable(checks)||~all(ismember(required,checks.Properties.VariableNames))
    error('nbiot:stage2:ReceiverEvidence','Receiver check table is missing required measurements.');
end
kinds=["clean","noise20","noiseMinus20","cfoMinus200","cfoPlus200",...
    "delayMinus2us","delayPlus2us","noiseOnly"];
if height(checks)~=80||~isequal(reshape(unique(string(checks.condition),'stable'),1,[]),kinds)
    error('nbiot:stage2:ReceiverEvidence','Receiver checks must contain the eight defined conditions.');
end
for kind=kinds
    rows=checks(string(checks.condition)==kind,:);
    if height(rows)~=10||numel(unique(rows.id))~=10||...
            any(~isfinite(rows.actualDelaySamples))||any(~isfinite(rows.actualCfoHz))||...
            any(rows.present~=(kind~="noiseOnly"))||...
            any(rows.ownDetected&(~isfinite(rows.estimatedDelaySamples)|~isfinite(rows.estimatedCfoHz)))
        error('nbiot:stage2:ReceiverEvidence',...
            'Receiver condition %s has incomplete measurements or duplicate IDs.',kind);
    end
end
clean=checks(string(checks.condition)=="clean",:);
if ~all(clean.present&clean.ownDetected&~clean.miss&~clean.falseAlarm)
    error('nbiot:stage2:ReceiverEvidence','Clean receiver control must detect all signals without false alarms.');
end
for kind=["cfoMinus200","cfoPlus200"]
    rows=checks(string(checks.condition)==kind,:);
    expected=-200; if kind=="cfoPlus200", expected=200; end
    if ~all(rows.actualCfoHz==expected)||...
            ~all(rows.present&rows.ownDetected&~rows.miss&~rows.falseAlarm)||...
            any(abs(rows.estimatedCfoHz-rows.actualCfoHz)>50)
        error('nbiot:stage2:ReceiverEvidence',...
            'CFO control %s must detect all signals without false alarms and estimate within 50 Hz.',kind);
    end
end
baselineDelay=median(clean.actualDelaySamples);
baselineEstimate=median(clean.estimatedDelaySamples);
for kind=["delayMinus2us","delayPlus2us"]
    rows=checks(string(checks.condition)==kind,:);
    offset=-2e-6*1920000; if kind=="delayPlus2us", offset=2e-6*1920000; end
    if any(abs(rows.actualDelaySamples-baselineDelay-offset)>.01)||...
            ~all(rows.present&rows.ownDetected&~rows.miss&~rows.falseAlarm)||...
            any(sign(offset)*(rows.estimatedDelaySamples-baselineEstimate)<=0)||...
            any(abs(rows.estimatedDelaySamples-rows.actualDelaySamples)>2)
        error('nbiot:stage2:ReceiverEvidence',...
            'Timing control %s must detect all signals, follow the offset direction, and estimate within 2 samples.',kind);
    end
end
highSnr=checks(string(checks.condition)=="noise20",:);
noiseOnly=checks(string(checks.condition)=="noiseOnly",:);
if ~all(highSnr.present&highSnr.ownDetected&~highSnr.miss&~highSnr.falseAlarm)||...
        any(noiseOnly.present|noiseOnly.ownDetected|noiseOnly.miss|noiseOnly.falseAlarm)
    error('nbiot:stage2:ReceiverEvidence',...
        'Receiver controls failed: clean/+20 dB must detect all signals and noise-only must have no false alarms.');
end
end
