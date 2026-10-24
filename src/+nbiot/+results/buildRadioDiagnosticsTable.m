function output=buildRadioDiagnosticsTable(result)
%BUILDRADIODIAGNOSTICSTABLE Flatten radio diagnostics for CSV export.
%   Радиодиагностика в плоскую таблицу для экспорта CSV.
% Столбцы длинной таблицы: область, измерение, идентификаторы, значение, единицы, источник и т. п.
names={'scope','measurement','occasionId','attemptId','otherAttemptId', ...
    'ueId','nInit','contextId','channel','numerator','denominator','value', ...
    'unit','estimate','configured','error','provenance'};
% Типы столбцов.
types={'string','string','double','double','double','double','double', ...
    'double','string','double','double','double','string','double', ...
    'double','double','string'};
% Пустая таблица нужной формы.
output=table('Size',[0 numel(names)],'VariableTypes',types,'VariableNames',names);
% Нет радиодиагностики —
if ~isstruct(result)||~isscalar(result)||~isfield(result,'radioDiagnostics')|| ...
        ~isstruct(result.radioDiagnostics)||~isscalar(result.radioDiagnostics)
    % возвращаем пустую таблицу.
    return;
end
% Радиодиагностика.
d=result.radioDiagnostics;
% Обнаружение преамбул:
if isfield(d,'preamble')
    % раздел;
    p=d.preamble;
    % счётчики передач, обнаружений, пропусков, ложных тревог —
    for field={'transmittedAttempts','transmittedKeys','detectedCandidates', ...
            'detectedKeys','misses','falseAlarms','falseAlarmOpportunities'}
        % строки-счётчики;
        if isfield(p,field{1}), output=addCount(output,'preamble',field{1},p.(field{1}),'count'); end
    end
    % вероятность обнаружения (числитель, знаменатель, значение);
    output=addRatio(output,'preamble','detectionProbability', ...
        p.detectedKeys,p.transmittedKeys,p.detectionProbability,'probability');
    % вероятность пропуска;
    output=addRatio(output,'preamble','missProbability', ...
        p.misses,p.transmittedKeys,p.missProbability,'probability');
    % вероятность ложной тревоги.
    output=addRatio(output,'preamble','falseAlarmProbability', ...
        p.falseAlarms,p.falseAlarmOpportunities,p.falseAlarmProbability,'probability');
end
% Коллизии:
if isfield(d,'collision')
    % раздел;
    c=d.collision;
    % счётчики логических и физических коллизий —
    for field={'logicalGroups','logicalAttempts','physicalOverlapPairs','physicalAttempts'}
        % строки-счётчики;
        if isfield(c,field{1}), output=addCount(output,'collision',field{1},c.(field{1}),'count'); end
    end
    % вероятность логической коллизии;
    output=addRatio(output,'collision','logicalAttemptProbability', ...
        c.logicalAttempts,c.attempts,c.logicalAttemptProbability,'probability');
    % вероятность физической коллизии.
    output=addRatio(output,'collision','physicalAttemptProbability', ...
        c.physicalAttempts,c.attempts,c.physicalAttemptProbability,'probability');
end
% Capture:
if isfield(d,'capture')
    % раздел;
    c=d.capture;
    % счётчики пар —
    for field={'eligiblePairs','censoredPairs','equalPowerPairs','capturedPairs'}
        % строки-счётчики (пары);
        if isfield(c,field{1}), output=addCount(output,'capture',field{1},c.(field{1}),'pairs'); end
    end
    % вероятность capture.
    output=addRatio(output,'capture','captureProbability', ...
        c.capturedPairs,c.eligiblePairs,c.probability,'probability');
end
% По попыткам:
if isfield(d,'perAttempt')
    % для каждой попытки:
    for k=1:numel(d.perAttempt)
        % запись;
        a=d.perAttempt(k);
        % идентификаторы попытки;
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',NaN,'channel','NPRACH');
        % мощность сигнала (Вт);
        output=addAttempt(output,identity,'receivedPowerW',a.receivedPowerW,'W',a.provenance);
        % мощность помехи (Вт);
        output=addAttempt(output,identity,'interferencePowerW',a.interferencePowerW,'W',a.provenance);
        % мощность шума (Вт);
        output=addAttempt(output,identity,'noisePowerW',a.noisePowerW,'W',a.provenance);
        % SINR (дБ).
        output=addAttempt(output,identity,'sinrDb',a.sinrDb,'dB',a.provenance);
    end
end
% Оценки детектора NPRACH:
if isfield(d,'receiverEstimates')
    % для каждой оценки:
    for k=1:numel(d.receiverEstimates)
        % запись;
        a=d.receiverEstimates(k);
        % идентификаторы;
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',NaN,'channel','NPRACH');
        % задержка: оценка, истина, ошибка (с);
        output=addEstimate(output,identity,'delay',a.estimatedDelaySeconds, ...
            a.configuredDelaySeconds,a.delayErrorSeconds,'s');
        % CFO: оценка, истина, ошибка (Гц).
        output=addEstimate(output,identity,'cfo',a.estimatedCfoHz, ...
            a.configuredCfoHz,a.cfoErrorHz,'Hz');
    end
end
% Оценки приёмника NPUSCH:
if isfield(d,'npuschReceiverEstimates')
    % для каждой оценки:
    for k=1:numel(d.npuschReceiverEstimates)
        % запись;
        a=d.npuschReceiverEstimates(k);
        % идентификаторы;
        identity=struct('occasionId',a.occasionId,'attemptId',a.attemptId, ...
            'ueId',a.ueId,'nInit',a.nInit,'contextId',a.contextId,'channel',a.channel);
        % задержка;
        output=addEstimate(output,identity,'delay',a.estimatedDelaySeconds, ...
            a.configuredDelaySeconds,a.delayErrorSeconds,'s');
        % CFO;
        output=addEstimate(output,identity,'cfo',a.estimatedCfoHz, ...
            a.configuredCfoHz,a.cfoErrorHz,'Hz');
        % оценка шума приёмника.
        output=addAttempt(output,identity,'noiseEstimate',a.noiseEstimate,'receiver units','receiver');
    end
end
end

%ADDCOUNT Добавляет строку-счётчик.
function output=addCount(output,scope,measurement,value,unit)
% Строка без идентификаторов попытки.
output=[output;makeRow(scope,measurement,NaN,NaN,NaN,NaN,NaN,NaN,'', ...
    value,1,value,unit,NaN,NaN,NaN,'diagnostic')]; %#ok<AGROW>
end

%ADDRATIO Добавляет строку-вероятность с числителем и знаменателем.
function output=addRatio(output,scope,measurement,numerator,denominator,value,unit)
% Строка без идентификаторов попытки.
output=[output;makeRow(scope,measurement,NaN,NaN,NaN,NaN,NaN,NaN,'', ...
    numerator,denominator,value,unit,NaN,NaN,NaN,'diagnostic')]; %#ok<AGROW>
end

%ADDATTEMPT Добавляет строку-измерение попытки.
function output=addAttempt(output,identity,measurement,value,unit,provenance)
% Строка с идентификаторами попытки.
output=[output;makeRow('attempt',measurement,identity.occasionId, ...
    identity.attemptId,NaN,identity.ueId,identity.nInit, ...
    identity.contextId,identity.channel,NaN,NaN,value,unit,NaN,NaN,NaN,provenance)]; %#ok<AGROW>
end

%ADDESTIMATE Добавляет строку оценки приёмника (оценка, истина, ошибка).
function output=addEstimate(output,identity,measurement,estimate,configured,error,unit)
% Строка с идентификаторами попытки.
output=[output;makeRow('receiver-estimate',measurement,identity.occasionId, ...
    identity.attemptId,NaN,identity.ueId,identity.nInit, ...
    identity.contextId,identity.channel,NaN,NaN,estimate,unit, ...
    estimate,configured,error,'receiver')]; %#ok<AGROW>
end

%MAKEROW Одна строка таблицы радиодиагностики.
function row=makeRow(scope,measurement,occasionId,attemptId,otherAttemptId, ...
        ueId,nInit,contextId,channel,numerator,denominator,value,unit, ...
        estimate,configured,error,provenance)
% Таблица из одной строки с нужными столбцами.
row=table(string(scope),string(measurement),occasionId,attemptId,otherAttemptId, ...
    ueId,nInit,contextId,string(channel),numerator,denominator,value, ...
    string(unit),estimate,configured,error,string(provenance), ...
    'VariableNames',{'scope','measurement','occasionId','attemptId', ...
    'otherAttemptId','ueId','nInit','contextId','channel','numerator', ...
    'denominator','value','unit','estimate','configured','error','provenance'});
end
