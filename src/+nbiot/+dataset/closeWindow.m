function [obs,target]=closeWindow(observed,truth,first,last,raIntegral,activeIntegral,queueIntegral,realizationId,windowTicks,resourceOccupancy,action)
%CLOSEWINDOW Строка датасета для окна [FIRST, LAST) (ТЗ §22): признаки BS и target.
%   OBS — признаки только из журнала наблюдений BS (разрешённые виды событий; исход декодирования
%   у UE запрещён — nbiot:dataset:Leakage); TARGET — из истины и интегралов по тикам окна.
%   Также в признаки входят занятость ресурсов окна и действие контроллера, действовавшее в окне.
% События журнала BS, произошедшие в окне [first, last).
e=observed([observed.tick]>=first & [observed.tick]<last);
% Длина окна по умолчанию — 500 мс.
if nargin<9, windowTicks=500; end
% Нет данных о занятости ресурсов — NaN.
if nargin<10||isempty(resourceOccupancy), resourceOccupancy=missingOccupancy(); end
% Нет данных о действии контроллера — NaN.
if nargin<11||isempty(action), action=missingAction(); end
% Проверка занятости (доли или NaN) и действия (действовало до начала окна).
validateDerivedInputs(resourceOccupancy,action,first);
% События истины в окне — только для target.
t=truth([truth.tick]>=first & [truth.tick]<last);
% Накопители: преамбулы, метрики пиков, энергия, декодирования, ошибки CRC, RAR, grants, очередь BS.
det=0; peak=[]; maxPeak=[]; energy=[]; dec=0; failures=0; rar=0; grants=0; queues=[];
% Схема датасета (разрешённые виды событий).
s=nbiot.dataset.featureSchema();
% Для каждого события BS в окне:
for k=1:numel(e)
    % вид события должен быть разрешён — иначе ошибка (защита от утечки);
    if ~ismember(e(k).kind,s.allowedObservationKinds), error('nbiot:dataset:Source','Unapproved observed source.'); end
    % поля события;
    f=e(k).fields;
    % по виду события:
    switch e(k).kind
        % результат детектора NPRACH —
        case 'nprach_detection'
            % число обнаруженных преамбул, средняя и максимальная метрика, энергия принятого сигнала;
            det=det+f.count; peak(end+1)=f.meanMetric; maxPeak(end+1)=f.maxMetric; energy(end+1)=f.energyW; %#ok<AGROW>
        % результат декодирования —
        case 'phy_decode'
            % только на BS (приёмник 0): исход декодирования у UE BS не знает;
            if f.receiverId~=0, error('nbiot:dataset:Leakage','UE decoder outcome is not a BS observation.'); end
            % блоки с CRC: число декодирований и число ошибок CRC;
            if f.hasCrc, dec=dec+1; failures=failures+double(f.crcError~=0); end
        % выдан RAR — счётчик RAR +1;
        case 'rar_sent', rar=rar+1;
        % выдан grant — счётчик grants +1;
        case 'grant', grants=grants+1;
        % сэмпл очереди запросов BS — в список.
        case 'bs_queue', queues(end+1)=f.pendingRequests; %#ok<AGROW>
    end
end
% Номер окна с единицы.
windowId=floor(first/windowTicks)+1;
% Строка признаков в порядке featureSchema: ключи, число преамбул, средняя метрика, максимальная,
% средняя энергия, декодирования, ошибки CRC, RAR, grants, средняя очередь, занятость, P, доля RA.
obs={realizationId,windowId,first,last,det,average(peak),maximum(maxPeak), ...
    average(energy),dec,failures,rar,grants,average(queues), ...
    resourceOccupancy.ulRaOccupancy,resourceOccupancy.ulDtOccupancy, ...
    resourceOccupancy.dlRaOccupancy,resourceOccupancy.dlDtOccupancy, ...
    action.accessProbability,action.raShare};
% Target: среднее по тикам число UE в RA и с работой, средняя очередь, число Msg1 и UE, передавших Msg1.
% Передачи Msg1 в окне (из истины) и список передававших UE.
msg=t(strcmp({t.kind},'msg1')); users=[];
% Номера UE, передававших Msg1.
for k=1:numel(msg), users(end+1)=msg(k).fields.ueId; end %#ok<AGROW>
% Длина окна в тиках.
width=last-first;
% Строка target: ключи; средние за окно по тикам (интегралы / длина): UE в RA, UE с работой,
% очередь на UE; число Msg1; число разных UE, передававших Msg1.
target={realizationId,windowId,first,last,raIntegral/width,activeIntegral/width, ...
    queueIntegral/width,numel(msg),numel(unique(users))};
end
% Среднее; пустой список → 0.
function m=average(x), if isempty(x), m=0; else, m=mean(x); end, end
% Максимум; пустой список → 0.
function m=maximum(x), if isempty(x), m=0; else, m=max(x); end, end

% Занятость ресурсов неизвестна — все доли NaN.
function occupancy=missingOccupancy()
occupancy=struct('ulRaOccupancy',NaN,'ulDtOccupancy',NaN, ...
    'dlRaOccupancy',NaN,'dlDtOccupancy',NaN);
end

% Действие контроллера неизвестно — NaN.
function action=missingAction()
action=struct('accessProbability',NaN,'raShare',NaN,'effectiveTick',NaN);
end

% Проверка вспомогательных входов окна:
function validateDerivedInputs(occupancy,action,first)
% имена долей занятости;
occupancyNames={'ulRaOccupancy','ulDtOccupancy','dlRaOccupancy','dlDtOccupancy'};
% для каждой доли:
for k=1:numel(occupancyNames)
    % имя поля;
    name=occupancyNames{k};
    % поле должно существовать в одной struct;
    if ~isstruct(occupancy)||~isscalar(occupancy)||~isfield(occupancy,name)
        error('nbiot:dataset:FeatureValues','Resource occupancy is missing %s.',name);
    end
    % значение;
    value=occupancy.(name);
    % NaN или доля в [0, 1].
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||isinf(value)|| ...
            (isfinite(value)&&(value<0||value>1))
        error('nbiot:dataset:FeatureValues','Resource occupancy %s must be NaN or a fraction.',name);
    end
end
% Поля действия: P и доля RA;
actionNames={'accessProbability','raShare'};
% для каждого:
for k=1:numel(actionNames)
    % имя поля;
    name=actionNames{k};
    % поле должно существовать;
    if ~isstruct(action)||~isscalar(action)||~isfield(action,name)
        error('nbiot:dataset:FeatureValues','The previous action is missing %s.',name);
    end
    % значение;
    value=action.(name);
    % NaN или доля в [0, 1].
    if ~isnumeric(value)||~isreal(value)||~isscalar(value)||isinf(value)|| ...
            (isfinite(value)&&(value<0||value>1))
        error('nbiot:dataset:FeatureValues','Action value %s must be NaN or a fraction.',name);
    end
end
% Тик начала действия — конечное число или NaN.
if ~isfield(action,'effectiveTick')||~isnumeric(action.effectiveTick)|| ...
        ~isreal(action.effectiveTick)||~isscalar(action.effectiveTick)||isinf(action.effectiveTick)
    error('nbiot:dataset:FeatureValues','Action effectiveTick must be a finite tick or NaN.');
end
% Действие должно было начаться не позже начала окна — иначе это значение «из будущего».
if isfinite(action.effectiveTick)&&(action.effectiveTick<0|| ...
        action.effectiveTick~=fix(action.effectiveTick)||action.effectiveTick>first)
    error('nbiot:dataset:FutureAction','The action was not active during the closed observation window.');
end
end
