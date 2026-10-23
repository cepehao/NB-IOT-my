function tx=transmission(cfg,grant,waveform,direction,activeRanges)
%TRANSMISSION Упаковывает waveform в struct передачи для канала (nbiot.channel.RadioChannel.add).
%   Нормирует сигнал на единичную среднюю мощность по активным интервалам ACTIVERANGES ([a,b),
%   с нуля) и задаёт мощность передачи: UE — cfg.channel.uePowerDbm (UL, DIRECTION=0),
%   BS — cfg.channel.bsPowerDbm (DL, DIRECTION=1). Начало — grant.startTick·1920 отсчётов.
if nargin<5, activeRanges=[0 size(waveform,1)]; end
energy=0; count=0;
for k=1:size(activeRanges,1)
    ix=(activeRanges(k,1)+1):activeRanges(k,2);
    energy=energy+sum(abs(waveform(ix)).^2); count=count+numel(ix);
end
assert(count>0 && energy>0,'nbiot:phy:EmptyWaveform','PHY produced no active waveform.');
waveform=waveform/sqrt(energy/count);
if direction==0, power=cfg.channel.uePowerDbm; else, power=cfg.channel.bsPowerDbm; end
tx=struct('grantId',grant.grantId,'direction',direction,'waveform',double(waveform),...
    'sampleRateHz',1920000,'startSample',grant.startTick*1920,...
    'activeRanges',activeRanges,'txPowerDbm',power,'ueId',0,'kind',grant.kind);
end
