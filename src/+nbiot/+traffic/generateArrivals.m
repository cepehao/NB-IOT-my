function arrivals=generateArrivals(cfg,sources)
%GENERATEARRIVALS Расписание пакетов реализации (ТЗ §11), генерируется до запуска и не зависит от политики.
%   Типы трафика cfg.traffic.kind:
%     'burst'    — массовый доступ (основной сценарий ТЗ): каждый активный UE создаёт 1 пакет в момент,
%                  равномерно распределённый на [burstStartTick, burstStartTick + burstDurationTicks);
%     'periodic' — пакет каждые periodTicks со случайной начальной фазой;
%     'poisson'  — экспоненциальные интервалы с интенсивностью poissonRatePerSecond на UE;
%     'none'     — без трафика.
%   Активные UE: все или явный список activeUeIds. Время округляется вверх до тика; пакеты за горизонтом
%   отбрасываются. Полезная нагрузка — случайные биты из потока 'payload'. Результат отсортирован по
%   (тик, UE, номер) и пронумерован packetId = 1..K.
% Проверяем конфигурацию; параметры трафика; горизонт в тиках.
cfg=nbiot.config.validateConfig(cfg); t=cfg.traffic; horizon=cfg.simulation.durationTicks;
% Пустой массив поступлений с полями записи.
arrivals=struct('packetId',{},'ueId',{},'createdTick',{},'sequence',{},'payloadBits',{},'continuousTimeSeconds',{});
% По умолчанию трафик создают все UE.
ueIds=1:cfg.simulation.numUE;
% В режиме explicit — только UE из списка activeUeIds.
if strcmp(t.activityMode,'explicit'), ueIds=t.activeUeIds; end
% Для каждого активного UE:
for id=ueIds
 % свой поток 'traffic' (не зависит от других UE); моменты пакетов пока пусты.
 s=sources.stream('traffic',0,id,0); times=[];
 % Тип трафика:
 switch t.kind
  % массовый всплеск — один пакет в случайный момент внутри [начало, начало + длительность);
  case 'burst', times=t.burstStartTick+t.burstDurationTicks*rand(s);
  % периодический — случайная фаза в пределах периода, далее пакеты через период до горизонта;
  case 'periodic', phase=t.periodTicks*rand(s); times=phase:t.periodTicks:horizon;
  % пуассоновский —
  case 'poisson'
   % если интенсивность положительна,
   if t.poissonRatePerSecond>0
    % экспоненциальные интервалы −ln(U)/λ (λ — пакетов на тик) накапливаются до горизонта;
    % max(realmin, U) защищает от log(0).
    x=0; while true, x=x-log(max(realmin,rand(s)))/(t.poissonRatePerSecond*cfg.simulation.tickSeconds); if x>=horizon, break; end, times(end+1)=x; end %#ok<AGROW>
   end
 end
 % Непрерывные моменты → тики (вверх); отбрасываем моменты за горизонтом.
 ticks=ceil(times); keep=ticks<horizon; ticks=ticks(keep); times=times(keep);
 % Не больше 65535 пакетов на UE (поле sequence 16 бит).
 if numel(ticks)>65535, error('nbiot:traffic:SequenceOverflow','UE %d exceeds sequence space',id); end
 % Отдельный поток 'payload' на UE — содержимое пакетов не влияет на моменты трафика.
 p=sources.stream('payload',0,id,0);
 % Для каждого пакета UE:
 for k=1:numel(ticks)
  % запись поступления: номер (назначится ниже), UE, тик, sequence = порядковый номер у UE,
  % случайные биты (0/1 с вероятностью 1/2), непрерывный момент в секундах;
  a=struct('packetId',uint32(0),'ueId',uint32(id),'createdTick',uint64(ticks(k)),'sequence',uint16(k),'payloadBits',int8(rand(p,8*t.packetBytes,1)>=.5),'continuousTimeSeconds',times(k)*cfg.simulation.tickSeconds);
  % добавляем в общий массив.
  arrivals(end+1)=a; %#ok<AGROW>
 end
end
% Если поступления есть —
if ~isempty(arrivals)
 % сортируем по (тик, UE, sequence) — порядок не зависит от порядка перебора UE;
 [~,idx]=sortrows([double([arrivals.createdTick])' double([arrivals.ueId])' double([arrivals.sequence])'],[1 2 3]); arrivals=arrivals(idx);
 % и нумеруем пакеты по порядку 1..K.
 for k=1:numel(arrivals), arrivals(k).packetId=uint32(k); end
end
end
