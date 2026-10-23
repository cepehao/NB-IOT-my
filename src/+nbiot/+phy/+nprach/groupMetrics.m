function [metrics,groups]=groupMetrics(cfg,rx,occasion)
%GROUPMETRICS Статистика присутствия каждой из 12 преамбул NPRACH в окне возможности.
%   Для каждой из 4 групп символов формата 0: принятые отсчёты проецируются на базис шаблонов всех
%   12 преамбул, умноженных на полином 2-й степени по времени (огибающая поглощает CFO до ±200 Гц
%   и неизвестную фазу канала). Метрика преамбулы в группе — доля энергии, объяснённая её
%   «частной» компонентой (ортогональной остальным преамбулам), к остатку + этой доле.
%   Итог METRICS(12×1) = минимум по группам (преамбула должна быть во всех четырёх).
%   Окно отсчётов внутри группы выбрано так, чтобы при задержках −8..+20 мкс не захватывать CP
%   и края фильтра. Базисы и QR-разложения кэшируются (зависят только от конфигурации).
degree=2; % Quadratic envelope spans the static-v1 +/-200 Hz CFO profile.
persistent cachedByDegree keyByDegree
if isempty(cachedByDegree), cachedByDegree=cell(1,7); keyByDegree=cell(1,7); end
cached=cachedByDegree{degree+1}; key=keyByDegree{degree+1};
bank=nbiot.phy.nprach.templates(cfg); fs=cfg.phy.sampleRateHz;
n=numel(bank{1}.waveform); p=bank{1}.info.PreambleParameters;
group=n/p.P; cp=round(p.T_CP*fs/(15000*2048));
delayMin=round(-8e-6*fs); delayMax=round(20e-6*fs)+ceil(cfg.channel.fractionalFilterLength/2);
half=(cfg.channel.fractionalFilterLength-1)/2;
at=cp+delayMax+half+1:group+delayMin-half;
cacheKey=[cfg.phy.cellId cfg.ra.periodTicks cfg.ra.format cfg.ra.repetitions degree at(1) at(end)];
if isempty(cached)||~isequal(key,cacheKey)
    x=linspace(-1,1,numel(at))'; polynomial=zeros(numel(at),degree+1);
    for order=0:degree, polynomial(:,order+1)=x.^order; end
    cached=cell(4,1);
    for gi=1:4
        A=complex(zeros(numel(at),12*(degree+1)));
        for i=1:12
            cols=(i-1)*(degree+1)+(1:degree+1);
            A(:,cols)=bank{i}.waveform((gi-1)*group+at).*polynomial;
        end
        [Q,~]=qr(A,0); partial=complex(zeros(size(A)));
        for i=1:12
            cols=(i-1)*(degree+1)+(1:degree+1); other=setdiff(1:size(A,2),cols);
            [Qother,~]=qr(A(:,other),0);
            [Qi,~]=qr(A(:,cols)-Qother*(Qother'*A(:,cols)),0);
            partial(:,cols)=Qi;
        end
        cached{gi}=struct('full',Q,'partial',partial);
    end
    key=cacheKey; cachedByDegree{degree+1}=cached; keyByDegree{degree+1}=key;
end
groups=zeros(12,4);
for gi=1:4
    first=occasion.startTick*1920+(gi-1)*group+at(1)-1;
    w=nbiot.phy.extractWindow(rx,first,numel(at)); w=w(:);
    Q=cached{gi}.full; partial=cached{gi}.partial;
    energy=sum(abs(w).^2); leftover=w-Q*(Q'*w);
    residual=max(sum(abs(leftover).^2),1e-12*energy);
    projected=reshape(abs(partial'*w).^2,degree+1,12);
    removed=sum(projected,1)';
    groups(:,gi)=min(1,removed./max(residual+removed,realmin));
end
metrics=min(groups,[],2);
end

