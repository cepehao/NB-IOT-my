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
cfg=nbiot.config.validateConfig(cfg); t=cfg.traffic; horizon=cfg.simulation.durationTicks;
arrivals=struct('packetId',{},'ueId',{},'createdTick',{},'sequence',{},'payloadBits',{},'continuousTimeSeconds',{});
ueIds=1:cfg.simulation.numUE;
if strcmp(t.activityMode,'explicit'), ueIds=t.activeUeIds; end
for id=ueIds
 s=sources.stream('traffic',0,id,0); times=[];
 switch t.kind
  case 'burst', times=t.burstStartTick+t.burstDurationTicks*rand(s);
  case 'periodic', phase=t.periodTicks*rand(s); times=phase:t.periodTicks:horizon;
  case 'poisson'
   if t.poissonRatePerSecond>0
    x=0; while true, x=x-log(max(realmin,rand(s)))/(t.poissonRatePerSecond*cfg.simulation.tickSeconds); if x>=horizon, break; end, times(end+1)=x; end %#ok<AGROW>
   end
 end
 ticks=ceil(times); keep=ticks<horizon; ticks=ticks(keep); times=times(keep);
 if numel(ticks)>65535, error('nbiot:traffic:SequenceOverflow','UE %d exceeds sequence space',id); end
 p=sources.stream('payload',0,id,0);
 for k=1:numel(ticks)
  a=struct('packetId',uint32(0),'ueId',uint32(id),'createdTick',uint64(ticks(k)),'sequence',uint16(k),'payloadBits',int8(rand(p,8*t.packetBytes,1)>=.5),'continuousTimeSeconds',times(k)*cfg.simulation.tickSeconds);
  arrivals(end+1)=a; %#ok<AGROW>
 end
end
if ~isempty(arrivals)
 [~,idx]=sortrows([double([arrivals.createdTick])' double([arrivals.ueId])' double([arrivals.sequence])'],[1 2 3]); arrivals=arrivals(idx);
 for k=1:numel(arrivals), arrivals(k).packetId=uint32(k); end
end
end
