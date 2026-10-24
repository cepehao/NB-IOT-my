function bank=templates(cfg)
%TEMPLATES Банк из 12 шаблонов преамбул NPRACH (NInit 0..11), сформированных lteNPRACH (ТЗ §14 п.3).
%   Из буфера периода вырезается активная часть: 4 группы × (CP + 5 символов) = 10 752 отсчёта при
%   1,92 МГц, нормированная на единичную мощность. Кэшируются все допустимые преамбулы, а не только
%   активные: детектор не должен знать, кто передавал.
% Кэш шаблонов и ключ конфигурации между вызовами.
persistent cached key
% Ключ: соты, период, число поднесущих, повторы, формат.
k=[cfg.phy.cellId cfg.ra.periodTicks cfg.ra.numSubcarriers cfg.ra.repetitions cfg.ra.format];
% Если кэш пуст или конфигурация изменилась —
if isempty(cached) || ~isequal(key,k)
    % проверяем наличие функций LTE Toolbox;
    nbiot.phy.requireToolbox({'lteNPRACH','lteNPRACHInfo'});
    % параметры UE для lteNPRACH: соты, разнос 15 кГц (задаёт частоту 1,92 МГц), без оконирования;
    ue=struct('NNCellID',cfg.phy.cellId,'NBULSubcarrierSpacing','15kHz','Windowing',0);
    % параметры NPRACH: формат 0, период, старт 8 мс, смещение 0, 12 поднесущих, 1 повтор;
    chs=struct('NPRACHFormat','0','Periodicity',cfg.ra.periodTicks,...
        'StartTime',8,'SubcarrierOffset',0,'NumSubcarriers',12,'NRep',1);
    % поддерживается только эта конфигурация;
    assert(cfg.ra.format==0 && cfg.ra.numSubcarriers==12 && cfg.ra.repetitions==1,'nbiot:phy:Profile','NPRACH adapter supports static-v1 only.');
    % 12 шаблонов;
    cached=cell(12,1);
    % для каждого NInit 0..11:
    for i=0:11
        % waveform всего периода (lteNPRACH) и информация о ресурсах (lteNPRACHInfo);
        chs.NInit=i; w=lteNPRACH(ue,chs); info=lteNPRACHInfo(ue,chs);
        % проверка частоты отсчётов;
        assert(info.SamplingRate==1920000,'nbiot:phy:SampleRate','Unexpected NPRACH sampling rate.');
        % R2025b lteNPRACHInfo has no Subframes field. StartTime is in ms.
        first=round(chs.StartTime*info.SamplingRate/1000)+1;
        % параметры преамбулы;
        params=info.PreambleParameters;
        % длина активной части: P групп × (CP + последовательность), в отсчётах;
        count=round(params.P*(params.T_CP+params.T_SEQ)*info.SamplingRate/(15000*2048));
        % для формата 0 это 10 752 отсчёта (≈ 5,6 мс);
        assert(count==10752,'nbiot:phy:Profile','Unexpected format-0 active duration.');
        % вырезаем активную часть из буфера периода;
        active=w(first:first+count-1);
        % шаблон с единичной мощностью, информация и активный интервал [0, длина).
        cached{i+1}=struct('waveform',active/sqrt(mean(abs(active).^2)),...
            'info',info,'activeRanges',[0 count]);
    end
    % Запоминаем ключ.
    key=k;
end
% Возвращаем банк шаблонов.
bank=cached;
end
