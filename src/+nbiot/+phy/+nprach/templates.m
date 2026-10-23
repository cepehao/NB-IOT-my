function bank=templates(cfg)
% Cache all allowed starting tones, never a shortlist of active transmitters.
persistent cached key
k=[cfg.phy.cellId cfg.ra.periodTicks cfg.ra.numSubcarriers cfg.ra.repetitions cfg.ra.format];
if isempty(cached) || ~isequal(key,k)
    nbiot.phy.requireToolbox({'lteNPRACH','lteNPRACHInfo'});
    ue=struct('NNCellID',cfg.phy.cellId,'NBULSubcarrierSpacing','15kHz','Windowing',0);
    chs=struct('NPRACHFormat','0','Periodicity',cfg.ra.periodTicks,...
        'StartTime',8,'SubcarrierOffset',0,'NumSubcarriers',12,'NRep',1);
    assert(cfg.ra.format==0 && cfg.ra.numSubcarriers==12 && cfg.ra.repetitions==1,'nbiot:phy:Profile','NPRACH adapter supports static-v1 only.');
    cached=cell(12,1);
    for i=0:11
        chs.NInit=i; w=lteNPRACH(ue,chs); info=lteNPRACHInfo(ue,chs);
        assert(info.SamplingRate==1920000,'nbiot:phy:SampleRate','Unexpected NPRACH sampling rate.');
        % R2025b lteNPRACHInfo has no Subframes field. StartTime is in ms.
        first=round(chs.StartTime*info.SamplingRate/1000)+1;
        params=info.PreambleParameters;
        count=round(params.P*(params.T_CP+params.T_SEQ)*info.SamplingRate/(15000*2048));
        assert(count==10752,'nbiot:phy:Profile','Unexpected format-0 active duration.');
        active=w(first:first+count-1);
        cached{i+1}=struct('waveform',active/sqrt(mean(abs(active).^2)),...
            'info',info,'activeRanges',[0 count]);
    end
    key=k;
end
bank=cached;
end
