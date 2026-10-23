function row=analyzeCollisionTrial(c,cfg,r,trace)
%ANALYZECOLLISIONTRIAL Validate one saved physical collision trial and KPI row.
%   Разбор одного физического опыта коллизии (ТЗ §34–35): строка KPI и проверка результата.
a=r.raLog; first=a([a.occasionId]==1); successful=a(strcmp({a.status},'success'));
chainValidated=true;
for k=1:numel(successful)
    at=find([trace.attemptTokens.attemptId]==successful(k).attemptId,1);
    assert(~isempty(at),'nbiot:collision:Chain','Success without attempt token.');
    token=trace.attemptTokens(at);
    accepted=trace.acceptedMsg3([trace.acceptedMsg3.token]==token.token&...
        [trace.acceptedMsg3.rnti]==token.rnti);
    assert(isfinite(token.rarTick)&&~isempty(accepted)&&any([accepted.tick]<=successful(k).endTick),...
        'nbiot:collision:Chain','Msg4 success without decoded RAR / accepted Msg3.');
    msg3=hasDecode(r.observedLog,'Msg3',token.rnti,0,[accepted.tick]);
    % RAR uses the temporary RA-RNTI; C-RNTI begins with the accepted RAR/Msg3.
    rar=hasDecode(r.truthLog,'NPDSCH',token.raRnti,successful(k).ueId,token.rarTick);
    msg4=hasDecode(r.truthLog,'NPDSCH',token.rnti,successful(k).ueId,successful(k).endTick);
    assert(msg3&&rar&&msg4,'nbiot:collision:Chain','Missing physical CRC chain evidence.');
end
assert(numel(successful)==r.kpiSummary.raSuccess,'nbiot:collision:Chain','KPI success mismatch.');
assert(numel(first)==c.numUE,'nbiot:collision:First','Every diagnostic UE must emit in first occasion.');
assert((numel(unique([first.nInit]))==1)==c.samePreamble,...
    'nbiot:collision:First','Wrong initial collision condition.');
success=first(strcmp({first.status},'success')); detected=[trace.firstDetected.nInit];
expected=unique([first.nInit]); miss=~all(ismember(expected,detected));
falseDetection=any(~ismember(detected,expected)); strong=NaN; weak=NaN;
if c.deltaDb>0
    strong=any([success.ueId]==1); weak=any([success.ueId]==c.numUE);
end
row={c.id,c.group,cfg.simulation.realizationId,c.numUE,c.deltaDb,numel(detected),...
    sum([first.collision]),numel(success),r.kpiSummary.raSuccess,r.kpiSummary.delivered,...
    strong,weak,numel(success)==c.numUE,~isempty(success),miss,falseDetection,...
    c.samePreamble&&isempty(success),chainValidated,numel(successful),...
    r.kpiSummary.dataCrcFailures,r.kpiSummary.harq.retryAttempts};
end

function found=hasDecode(events,channel,rnti,receiver,ticks)
found=false;
for k=1:numel(events)
    if strcmp(events(k).kind,'phy_decode')
        f=events(k).fields;
        found=found||(strcmp(f.channel,channel)&&f.rnti==rnti&&f.receiverId==receiver&&...
            f.hasCrc&&f.crcError==0&&ismember(events(k).tick,ticks));
    end
end
end
