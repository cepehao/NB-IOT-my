function [metrics,groups]=groupMetrics(cfg,rx,occasion)
%GROUPMETRICS Статистика присутствия каждой из 12 преамбул NPRACH в окне возможности.
%   Для каждой из 4 групп символов формата 0: принятые отсчёты проецируются на базис шаблонов всех
%   12 преамбул, умноженных на полином 2-й степени по времени (огибающая поглощает CFO до ±200 Гц
%   и неизвестную фазу канала). Метрика преамбулы в группе — доля энергии, объяснённая её
%   «частной» компонентой (ортогональной остальным преамбулам), к остатку + этой доле.
%   Итог METRICS(12×1) = минимум по группам (преамбула должна быть во всех четырёх).
%   Окно отсчётов внутри группы выбрано так, чтобы при задержках −8..+20 мкс не захватывать CP
%   и края фильтра. Базисы и QR-разложения кэшируются (зависят только от конфигурации).
% Степень полинома огибающей: 2 (охватывает CFO до ±200 Гц профиля static-v1).
degree=2; % Quadratic envelope spans the static-v1 +/-200 Hz CFO profile.
% Кэш базисов (зависит только от конфигурации) между вызовами.
persistent cachedByDegree keyByDegree
% Первичная инициализация кэша.
if isempty(cachedByDegree), cachedByDegree=cell(1,7); keyByDegree=cell(1,7); end
% Кэш и ключ для выбранной степени.
cached=cachedByDegree{degree+1}; key=keyByDegree{degree+1};
% Банк шаблонов и частота отсчётов.
bank=nbiot.phy.nprach.templates(cfg); fs=cfg.phy.sampleRateHz;
% Длина шаблона; параметры преамбулы (число групп P, длины CP и последовательности).
n=numel(bank{1}.waveform); p=bank{1}.info.PreambleParameters;
% Длина одной группы символов; длина CP в отсчётах (T_CP в единицах Ts = 1/(15000·2048) с).
group=n/p.P; cp=round(p.T_CP*fs/(15000*2048));
% Минимальная и максимальная задержка (−8..+20 мкс) в отсчётах, с запасом на фильтр.
delayMin=round(-8e-6*fs); delayMax=round(20e-6*fs)+ceil(cfg.channel.fractionalFilterLength/2);
% Половина длины фильтра дробной задержки.
half=(cfg.channel.fractionalFilterLength-1)/2;
% Отсчёты внутри группы, которые при любой задержке не захватывают CP и края соседних групп.
at=cp+delayMax+half+1:group+delayMin-half;
% Ключ кэша: конфигурация, степень и границы окна.
cacheKey=[cfg.phy.cellId cfg.ra.periodTicks cfg.ra.format cfg.ra.repetitions degree at(1) at(end)];
% Если кэш пуст или устарел —
if isempty(cached)||~isequal(key,cacheKey)
    % нормированное время −1..1 и полиномиальный базис 1, x, x²;
    x=linspace(-1,1,numel(at))'; polynomial=zeros(numel(at),degree+1);
    % столбцы базиса;
    for order=0:degree, polynomial(:,order+1)=x.^order; end
    % кэш для 4 групп символов;
    cached=cell(4,1);
    % для каждой группы:
    for gi=1:4
        % матрица A: для каждой преамбулы — её отсчёты, умноженные на 1, x, x² (12·3 столбца);
        A=complex(zeros(numel(at),12*(degree+1)));
        % для каждой преамбулы:
        for i=1:12
            % её столбцы в A;
            cols=(i-1)*(degree+1)+(1:degree+1);
            % отсчёты шаблона в этой группе, модулированные полиномом;
            A(:,cols)=bank{i}.waveform((gi-1)*group+at).*polynomial;
        end
        % ортонормированный базис всего пространства A; заготовка «частных» базисов;
        [Q,~]=qr(A,0); partial=complex(zeros(size(A)));
        % для каждой преамбулы:
        for i=1:12
            % её столбцы и столбцы остальных преамбул;
            cols=(i-1)*(degree+1)+(1:degree+1); other=setdiff(1:size(A,2),cols);
            % базис пространства остальных преамбул;
            [Qother,~]=qr(A(:,other),0);
            % часть столбцов преамбулы, ортогональная остальным, и её ортонормированный базис;
            [Qi,~]=qr(A(:,cols)-Qother*(Qother'*A(:,cols)),0);
            % сохраняем частный базис преамбулы;
            partial(:,cols)=Qi;
        end
        % в кэш группы: полный и частные базисы.
        cached{gi}=struct('full',Q,'partial',partial);
    end
    % Запоминаем ключ и кэш.
    key=cacheKey; cachedByDegree{degree+1}=cached; keyByDegree{degree+1}=key;
end
% Метрики: 12 преамбул × 4 группы.
groups=zeros(12,4);
% Для каждой группы символов:
for gi=1:4
    % первый абсолютный отсчёт окна группы;
    first=occasion.startTick*1920+(gi-1)*group+at(1)-1;
    % отсчёты принятого сигнала в окне группы;
    w=nbiot.phy.extractWindow(rx,first,numel(at)); w=w(:);
    % базисы группы;
    Q=cached{gi}.full; partial=cached{gi}.partial;
    % энергия окна; остаток после проекции на всё пространство преамбул;
    energy=sum(abs(w).^2); leftover=w-Q*(Q'*w);
    % энергия остатка (шум/неизвестное), не меньше крошечной доли энергии;
    residual=max(sum(abs(leftover).^2),1e-12*energy);
    % энергия проекции на частный базис каждой преамбулы (по 3 компоненты);
    projected=reshape(abs(partial'*w).^2,degree+1,12);
    % суммарная энергия, объяснённая каждой преамбулой;
    removed=sum(projected,1)';
    % метрика = объяснённая / (остаток + объяснённая), не больше 1.
    groups(:,gi)=min(1,removed./max(residual+removed,realmin));
end
% Итог: минимум по 4 группам — преамбула должна присутствовать во всех.
metrics=min(groups,[],2);
end

