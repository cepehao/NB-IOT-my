function lines=formatUeDetail(detail)
%FORMATUEDETAIL Format one device's current simulation state for the UI.
%   Карточка выбранного UE (ТЗ §46.10): координаты, расстояние, мощность, состояние, попытки.
required={'ueId','xM','yM','distanceM','indoor','receivedPowerUlDbm', ...
    'receivedPowerDlDbm','raAttempts','state','queueLength'};
if ~isstruct(detail)||~isscalar(detail)||~all(isfield(detail,required))
    error('nbiot:ui:UeDetail','Selected-device details do not match the supported format.');
end
numbers={'ueId','xM','yM','distanceM','raAttempts','queueLength'};
for k=1:numel(numbers)
    value=detail.(numbers{k});
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||~isfinite(value)
        error('nbiot:ui:UeDetail','Selected-device field %s must be one finite number.',numbers{k});
    end
end
if detail.ueId<1||detail.ueId~=fix(detail.ueId)||detail.distanceM<0|| ...
        detail.raAttempts<0||detail.raAttempts~=fix(detail.raAttempts)|| ...
        detail.queueLength<0||detail.queueLength~=fix(detail.queueLength)|| ...
        ~islogical(detail.indoor)||~isscalar(detail.indoor)|| ...
        ~(ischar(detail.state)||(isstring(detail.state)&&isscalar(detail.state)))
    error('nbiot:ui:UeDetail','Selected-device details contain an invalid value.');
end
location='снаружи';
if detail.indoor, location='внутри здания'; end
stateCode=upper(char(string(detail.state)));
state=stateLabel(stateCode);
lines={sprintf('UE %d',detail.ueId), ...
    sprintf('Координаты: X = %.1f м; Y = %.1f м',detail.xM,detail.yM), ...
    sprintf('Расстояние до станции: %.1f м · %s',detail.distanceM,location), ...
    ['Мощность UL: ' powerText(detail.receivedPowerUlDbm)], ...
    ['Мощность DL: ' powerText(detail.receivedPowerDlDbm)], ...
    sprintf('Попытки доступа: %d',detail.raAttempts), ...
    ['Этап: ' stateCode ' — ' state], ...
    ['Очередь: ' packetCountText(detail.queueLength)]};
if isfield(detail,'radioSummary')&&isstruct(detail.radioSummary)&& ...
        isscalar(detail.radioSummary)
    lines=[lines radioLines(detail.radioSummary)]; %#ok<AGROW>
end
end

function lines=radioLines(radio)
lines={};
if isfield(radio,'referenceSnrUlDb')||isfield(radio,'referenceSnrDlDb')
    lines{end+1}=sprintf('Опорный SNR UL/DL: %s / %s дБ', ...
        numberText(numberValue(radio,'referenceSnrUlDb'),'%.1f'), ...
        numberText(numberValue(radio,'referenceSnrDlDb'),'%.1f'));
end
status='unavailable';
if isfield(radio,'status')&&(ischar(radio.status)|| ...
        (isstring(radio.status)&&isscalar(radio.status)))
    status=char(string(radio.status));
end
if strcmp(status,'pending')
    lines{end+1}='Радиодиагностика: появится после завершения расчёта';
    return;
elseif strcmp(status,'unavailable')
    lines{end+1}='Радиодиагностика: нет данных';
    return;
elseif ~strcmp(status,'available')
    lines{end+1}='Радиодиагностика: нет данных';
    return;
end

attempts=structArrayField(radio,'perAttempt');
for k=1:numel(attempts)
    lines{end+1}=sprintf('Диагностический SINR NPRACH, попытка %s: %s дБ', ...
        numberText(numberValue(attempts(k),'attemptId'),'%.0f'), ...
        dbText(numberValue(attempts(k),'sinrDb'))); %#ok<AGROW>
end
nprach=structArrayField(radio,'receiverEstimates');
for k=1:numel(nprach)
    lines{end+1}=sprintf('Оценка NPRACH, окно %s: задержка %s мс; CFO %s Гц%s', ...
        numberText(numberValue(nprach(k),'occasionId'),'%.0f'), ...
        millisecondsText(numberValue(nprach(k),'estimatedDelaySeconds')), ...
        numberText(numberValue(nprach(k),'estimatedCfoHz'),'%.3g'), ...
        estimateErrors(nprach(k))); %#ok<AGROW>
end
npusch=structArrayField(radio,'npuschReceiverEstimates');
for k=1:numel(npusch)
    channel='—';
    if isfield(npusch(k),'channel')&&(ischar(npusch(k).channel)|| ...
            (isstring(npusch(k).channel)&&isscalar(npusch(k).channel)))
        channel=char(string(npusch(k).channel));
    end
    lines{end+1}=sprintf('Оценка NPUSCH %s: задержка %s мс; CFO %s Гц%s', ...
        channel,millisecondsText(numberValue(npusch(k),'estimatedDelaySeconds')), ...
        numberText(numberValue(npusch(k),'estimatedCfoHz'),'%.3g'), ...
        estimateErrors(npusch(k))); %#ok<AGROW>
end
if isempty(attempts)&&isempty(nprach)&&isempty(npusch)
    lines{end+1}='Радиодиагностика: для этого UE нет измерений';
end
end

function text=estimateErrors(estimate)
text='';
if ~isfield(estimate,'truthAvailable')||~islogical(estimate.truthAvailable)|| ...
        ~isscalar(estimate.truthAvailable)||~estimate.truthAvailable
    return;
end
delayError=numberValue(estimate,'delayErrorSeconds');
cfoError=numberValue(estimate,'cfoErrorHz');
if isfinite(delayError)||isfinite(cfoError)
    text=sprintf(' (ошибка: задержка %s мс; CFO %s Гц)', ...
        signedText(delayError*1e3),signedText(cfoError));
end
end

function rows=structArrayField(source,name)
rows=struct([]);
if isstruct(source)&&isscalar(source)&&isfield(source,name)&&isstruct(source.(name))
    rows=source.(name);
end
end

function value=numberValue(source,name)
value=NaN;
if isstruct(source)&&isfield(source,name)&&isnumeric(source.(name))&& ...
        isreal(source.(name))&&isscalar(source.(name))&&~isinf(source.(name))
    value=double(source.(name));
end
end

function text=millisecondsText(seconds)
text=numberText(1000*seconds,'%.3g');
end

function text=dbText(value)
text=numberText(value,'%.3g');
end

function text=numberText(value,format)
if nargin<2, format='%.3g'; end
if ~isnumeric(value)||~isscalar(value)||~isreal(value)||~isfinite(value)
    text='—';
else
    text=sprintf(format,double(value));
end
end

function text=signedText(value)
if ~isnumeric(value)||~isscalar(value)||~isreal(value)||~isfinite(value)
    text='—';
else
    text=sprintf('%+.3g',double(value));
end
end

function value=powerText(number)
if ~isnumeric(number)||~isreal(number)||~isscalar(number)||~isfinite(number)
    value='—';
else
    if number<0
        value=sprintf('−%.1f дБм',abs(double(number)));
    else
        value=sprintf('%.1f дБм',number);
    end
end
end

function label=stateLabel(state)
switch state
    case 'IDLE', label='устройство свободно и сейчас не передаёт';
    case 'WAIT_RA', label='подготовка попытки доступа к сети';
    case 'WAIT_RAR', label='ожидание ответа станции на запрос доступа';
    case 'WAIT_MSG4', label='завершение служебной процедуры доступа';
    case 'BACKOFF', label='ожидание перед повторной попыткой доступа';
    case 'DATA', label='передача полезных данных';
    case 'WAIT_RECEIPT', label='ожидание подтверждения доставки данных';
    case 'MSG4_ACK', label='подтверждение служебной процедуры доступа';
    case 'RECEIPT_ACK', label='подтверждение доставки данных';
    otherwise, label=state;
end
end

function text=packetCountText(count)
remainder100=mod(count,100); remainder10=mod(count,10);
if remainder100>=11&&remainder100<=14
    noun='пакетов';
elseif remainder10==1
    noun='пакет';
elseif remainder10>=2&&remainder10<=4
    noun='пакета';
else
    noun='пакетов';
end
text=sprintf('%d %s',count,noun);
end
