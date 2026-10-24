function series=windowKpi(cfg,packets,attempts,observed,actualTick,queueSamples,controllerLog)
%WINDOWKPI Временные ряды KPI по окнам 500 мс (ТЗ §27, графики ТЗ §46.9).
%   Два вида знаменателей: события, произошедшие в окне (доставлено/отброшено/начато в окне), и
%   когорта пакетов, созданных в окне (их итоговая доля доставки) — их нельзя смешивать.
%   Также throughput окна, очереди и число решений/переключений контроллера.
% Имена столбцов: окно, пакеты (в окне и когорта), попытки RA, декодирования, throughput,
names={'windowId','startTick','endTick','created','deliveredInWindow','droppedInWindow', ...
    'cohortDelivered','cohortDropped','cohortUnfinished','cohortDeliveryProbability', ...
    'raStarted','raSucceededInWindow','raFailedInWindow','ulTbDecoded','ulCrcFailures','throughputBitsPerSecond'};
% очереди BS и UE, контроллер.
names=[names,{'meanBsQueueLength','maxBsQueueLength','meanUeQueueLength', ...
    'maxUeQueueLength','controllerApplicable','controllerDecisions','configurationSwitches'}];
% Без сэмплов очередей — пустая матрица.
if nargin<6, queueSamples=zeros(0,3); end
% Без журнала контроллера — пустой.
if nargin<7, controllerLog=struct([]); end
% Строки таблицы.
rows={};
% Для каждого окна (по 500 мс до горизонта):
for first=0:cfg.dataset.windowTicks:actualTick-1
    % конец окна;
    last=min(first+cfg.dataset.windowTicks,actualTick);
    % счётчики окна и когорты;
    created=0; delivered=0; dropped=0; cohortDelivered=0; cohortDropped=0; cohortUnfinished=0;
    % для каждого пакета:
    for p=reshape(packets,1,[])
        % создан в окне — входит в когорту;
        inCohort=double(p.createdTick)>=first && double(p.createdTick)<last;
        % создано в окне;
        created=created+inCohort;
        % доставлено в окне (s, e];
        delivered=delivered+(strcmp(p.status,'delivered') && p.deliveredTick>first && p.deliveredTick<=last);
        % отброшено в окне [s, e);
        dropped=dropped+(strcmp(p.status,'dropped') && p.terminalTick>=first && p.terminalTick<last);
        % для пакетов когорты —
        if inCohort
            % сколько из них в итоге доставлено,
            cohortDelivered=cohortDelivered+strcmp(p.status,'delivered');
            % отброшено,
            cohortDropped=cohortDropped+strcmp(p.status,'dropped');
            % не завершено.
            cohortUnfinished=cohortUnfinished+strcmp(p.status,'unfinished');
        end
    end
    % Счётчики попыток RA.
    started=0; succeeded=0; failed=0;
    % Для каждой попытки:
    for a=reshape(attempts,1,[])
        % начата в окне;
        started=started+(a.startTick>=first && a.startTick<last);
        % успешно завершена в окне (s, e];
        succeeded=succeeded+(strcmp(a.status,'success') && a.endTick>first && a.endTick<=last);
        % неуспешно завершена в окне.
        failed=failed+(strcmp(a.status,'failure') && a.endTick>=first && a.endTick<last);
    end
    % Счётчики декодирований.
    decoded=0; crcFailures=0;
    % Для каждого события BS:
    for e=reshape(observed,1,[])
        % декодирование с CRC, готовое в окне (s, e] —
        if e.tick>first && e.tick<=last && strcmp(e.kind,'phy_decode') && e.fields.hasCrc
            % +1 декодирование, +1 ошибка при CRC fail.
            decoded=decoded+1; crcFailures=crcFailures+double(e.fields.crcError~=0);
        end
    end
    % Доля доставки когорты (NaN без пакетов).
    if created==0, probability=NaN; else, probability=cohortDelivered/created; end
    % Throughput окна: полезные биты доставленных в окне / длительность окна (с).
    throughput=delivered*cfg.traffic.packetBytes*8/((last-first)*cfg.simulation.tickSeconds);
    % Сэмплы очереди BS окна.
    queues=[];
    % Для каждого события BS:
    for e=reshape(observed,1,[])
        % сэмпл очереди внутри окна —
        if e.tick>=first && e.tick<last && strcmp(e.kind,'bs_queue')
            % в список.
            queues(end+1)=e.fields.pendingRequests; %#ok<AGROW>
        end
    end
    % Сэмплы очередей UE окна.
    q=queueSamples(queueSamples(:,1)>=first & queueSamples(:,1)<last,:);
    % По умолчанию — нет данных.
    meanUe=NaN; maxUe=NaN;
    % Средняя очередь на UE и максимум.
    if ~isempty(q), meanUe=sum(q(:,2))/(size(q,1)*cfg.simulation.numUE); maxUe=max(q(:,3)); end
    % Максимум очереди BS.
    maxBs=NaN; if ~isempty(queues), maxBs=max(queues); end
    % Контроллер действует только для адаптивных методов.
    controllerApplicable=~strcmp(char(string(cfg.policy.name)),'Static');
    % По умолчанию — нет данных.
    controllerDecisions=NaN; configurationSwitches=NaN;
    % Для адаптивных:
    if controllerApplicable
        % нули по умолчанию;
        controllerDecisions=0; configurationSwitches=0;
        % если журнал решений есть —
        if ~isempty(controllerLog)
            % тики решений;
            decisionTicks=[controllerLog.decisionTick];
            % решения внутри окна;
            inWindow=decisionTicks>=first&decisionTicks<last;
            % их число;
            controllerDecisions=sum(inWindow);
            % тики решений с переключением конфигурации;
            switchTicks=decisionTicks([controllerLog.switched]);
            % число переключений в окне.
            configurationSwitches=sum(switchTicks>=first&switchTicks<last);
        end
    end
    % Строка окна.
    rows(end+1,:)={floor(first/cfg.dataset.windowTicks)+1,first,last,created,delivered,dropped, ...
        cohortDelivered,cohortDropped,cohortUnfinished,probability,started,succeeded,failed,decoded,crcFailures,throughput, ...
        mean(queues),maxBs,meanUe,maxUe,controllerApplicable,controllerDecisions,configurationSwitches}; %#ok<AGROW>
end
% Нет окон — пустая таблица с теми же столбцами;
if isempty(rows), series=array2table(zeros(0,numel(names)),'VariableNames',names);
% иначе — таблица из строк.
else, series=cell2table(rows,'VariableNames',names); end
% Описание соглашений об интервалах.
series.Properties.Description='Arrivals/drops/starts use [start,end); receiver completions use (start,end]. Cohorts classified at export horizon.';
end
