classdef ResourceCalendar < handle
    %RESOURCECALENDAR Календари ресурсов UL и DL и квоты RA/DT (ТЗ §25–26; docs/model-profile.md).
    %   UL: сетка 2 полуподкадра на тик (0,5 мс) × 48 тонов по 3,75 кГц (= 180 кГц).
    %   DL: 1 подкадр 180 кГц × 1 мс на тик; обязательные подкадры (NPSS, NSSS, NPBCH, SIB1-NB)
    %   недоступны (mandatoryMask). Ячейка: 0 — свободна, 1 — занята фазой RA, 2 — фазой DT.
    %   Квоты: в каждом окне cfg.policy.windowTicks (500 мс) отдельно в UL и DL доля RA
    %   floor(raShare·доступно) (Static 10 %), DT — остаток. Заимствования между фазами нет.
    %   RA включает NPRACH, RAR, Msg3, Msg4 и их управление; DT — данные, их grants и квитанции.
    %   Замечание: при Static в DL на окно ≈ 37 подкадров RA, а RAR/Msg4 занимает ≈ 4 подкадра —
    %   это ограничивает число завершаемых процедур RA (к анализу на этапе 3 ROADMAP).
    properties (SetAccess=private)
        % mandatoryMask(durationTicks×1) — обязательные DL-подкадры; durationTicks — горизонт.
        mandatoryMask
        % Горизонт в тиках.
        durationTicks
    end
    properties (Access=private)
        % Конфигурация.
        cfg
        % Календарь UL: строки — полуподкадры (0,5 мс), столбцы — 48 тонов по 3,75 кГц; 0/1(RA)/2(DT).
        ul
        % Календарь DL: строки — подкадры (1 мс); 0/1(RA)/2(DT).
        dl
        % Тики DL, доступные для поиска NPDCCH, и префиксные суммы для быстрого поиска.
        monitoringDlTicks
        % Префиксные суммы доступных DL-тиков (для быстрого поиска).
        monitoringDlPrefix
        % Доля RA по каждому окну 500 мс (Adaptive-RA/DT меняет её с границы окна).
        windowShares
        % Все выданные резервирования (для пересчёта и отчёта).
        records = struct('direction',{},'phase',{},'ticks',{},'frequencyStartHz',{},'bandwidthHz',{},'grantId',{})
    end
    methods
        %RESOURCECALENDAR Пустые календари на горизонт cfg.simulation.durationTicks.
        function obj=ResourceCalendar(cfg)
            % Конфигурация и горизонт.
            obj.cfg=cfg; obj.durationTicks=cfg.simulation.durationTicks;
            % Маска обязательных DL-подкадров на весь горизонт.
            obj.mandatoryMask=nbiot.scheduler.mandatoryDlMask(obj.durationTicks,cfg.cell.cellId);
            % Маска строкой.
            mask=obj.mandatoryMask(:).';
            % Номера доступных DL-тиков (с нуля).
            obj.monitoringDlTicks=reshape(find(~mask)-1,1,[]);
            % Префиксные суммы доступных DL-тиков.
            obj.monitoringDlPrefix=[0 cumsum(~mask)];
            % Число окон квот (по 500 мс).
            windowCount=ceil(obj.durationTicks/cfg.policy.windowTicks);
            % Начальная доля RA во всех окнах — из конфигурации (Static 10 %).
            obj.windowShares=repmat(cfg.policy.raShare,1,windowCount);
            % Пустые календари UL (2·N × 48) и DL (N × 1).
            obj.ul=zeros(2*obj.durationTicks,48,'uint8'); obj.dl=zeros(obj.durationTicks,1,'uint8');
        end
        %CANRESERVE Поместятся ли планы PLANS (без занятости и в пределах квот).
        function ok=canReserve(obj,plans)
            % Пробное резервирование без изменения календаря.
            [ok,~,~]=obj.check(plans);
        end
        %MONITORINGTICKS До 4 ближайших доступных DL-подкадров начиная с BASETICK (кандидаты поиска NPDCCH).
        function ticks=monitoringTicks(obj,baseTick)
            % Тик — неотрицательное целое.
            assert(isscalar(baseTick) && baseTick>=0 && baseTick==fix(baseTick));
            % За горизонтом кандидатов нет.
            if baseTick>=obj.durationTicks, ticks=zeros(1,0); return; end
            % Номер первого доступного DL-тика начиная с BASETICK.
            first=obj.monitoringDlPrefix(baseTick+1)+1;
            % Не больше 4 подкадров (Rmax = 4) и не дальше списка.
            last=min(first+3,numel(obj.monitoringDlTicks));
            % Доступных тиков не осталось — пусто.
            if first>last, ticks=zeros(1,0); return; end
            % Кандидатные подкадры поиска NPDCCH.
            ticks=obj.monitoringDlTicks(first:last);
        end
        %RESERVETRANSACTION Атомарно резервирует все планы PLANS (grant + передача + ACK) или ничего.
        function ok=reserveTransaction(obj,plans)
            % Проверка и пробное заполнение всех планов.
            [ok,u,d]=obj.check(plans);
            % Если всё помещается —
            if ok
                % фиксируем новые календари UL и DL;
                obj.ul=u; obj.dl=d;
                % и сохраняем записи о резервированиях.
                for k=1:numel(plans), obj.records(end+1)=obj.canonical(plans(k)); end
            end
        end
        %APPLYSHAREFROM Новая доля RA RASHARE с окна, начинающегося в EFFECTIVETICK (Adaptive-RA/DT).
        %   Отказ, если уже выданные назначения не укладываются в новые квоты.
        function applied=applyShareFrom(obj,effectiveTick,raShare)
            % По умолчанию не применено; длина окна квот.
            applied=false; windowTicks=obj.cfg.policy.windowTicks;
            % Тик — целое на границе окна внутри горизонта; доля RA строго в (0, 1);
            if ~isnumeric(effectiveTick)||~isscalar(effectiveTick)||~isfinite(effectiveTick)|| ...
                    effectiveTick<0||effectiveTick>=obj.durationTicks||effectiveTick~=fix(effectiveTick)|| ...
                    mod(effectiveTick,windowTicks)~=0||~isnumeric(raShare)||~isscalar(raShare)|| ...
                    ~isfinite(raShare)||raShare<=0||raShare>=1
                % иначе не применяем.
                return;
            end
            % Номер первого окна с новой долей.
            firstWindow=effectiveTick/windowTicks+1;
            % Новые доли: с этого окна и до конца горизонта.
            proposed=obj.windowShares; proposed(firstWindow:end)=raShare;
            % Уже выданные назначения должны уложиться в новые квоты — иначе отказ.
            if ~obj.reservationsFit(proposed), return; end
            % Применяем.
            obj.windowShares=proposed; applied=true;
        end
        %ISFREE Свободны ли все ячейки плана PLAN.
        function ok=isFree(obj,plan)
            % Строки, столбцы календаря и направление плана.
            [rows,cols,direction]=obj.indices(plan);
            % UL: все ячейки свободны; DL: подкадры свободны и не обязательные.
            if direction==0, ok=~any(obj.ul(rows,cols)~=0,'all'); else, ok=~any(obj.dl(rows)~=0|obj.mandatoryMask(rows)); end
        end
        %RELEASEUNSTARTED Снимает ещё не начавшиеся резервирования GRANTIDS и перестраивает календари.
        function releaseUnstarted(obj,grantIds,now)
            % Какие записи оставить.
            keep=true(1,numel(obj.records));
            % Для каждой записи:
            for i=1:numel(obj.records)
                % запись;
                p=obj.records(i);
                % назначение из списка, ещё не начавшееся, — снимаем.
                if ismember(p.grantId,grantIds) && min(p.ticks)>=now, keep(i)=false; end
            end
            % Оставляем записи и очищаем календари.
            obj.records=obj.records(keep); obj.ul(:)=0; obj.dl(:)=0;
            % Заново заполняем календари по оставшимся записям:
            for i=1:numel(obj.records)
                % ячейки записи; фаза: 1 — RA, 2 — DT;
                p=obj.records(i); [r,c,d]=obj.indices(p); phase=1+strcmpi(p.phase,'DT');
                % UL — ячейки сетки, DL — подкадры.
                if d==0, obj.ul(r,c)=phase; else, obj.dl(r)=phase; end
            end
        end
        %WINDOWOCCUPANCY Доли занятости RA и DT в UL и DL для закрытого окна [FIRST, LAST) — признаки датасета.
        function occupancy=windowOccupancy(obj,first,last)
            % Длина окна датасета.
            windowTicks=obj.cfg.dataset.windowTicks;
            % Начало окна — целый тик на границе окна внутри горизонта.
            validFirst=isnumeric(first)&&isreal(first)&&isscalar(first)&&isfinite(first)&& ...
                first>=0&&first<obj.durationTicks&&first==fix(first)&&mod(first,windowTicks)==0;
            % Если начало корректно —
            if validFirst
                % ожидаемый конец окна (или горизонт).
                expectedLast=min(first+windowTicks,obj.durationTicks);
            else
                % иначе конец не определён.
                expectedLast=NaN;
            end
            % Конец окна должен быть ожидаемым.
            validLast=isnumeric(last)&&isreal(last)&&isscalar(last)&&isfinite(last)&& ...
                last==expectedLast;
            % Окно некорректно —
            if ~validFirst||~validLast
                error('nbiot:scheduler:WindowOccupancy', ...
                    'Occupancy can be read only for one aligned, completed dataset window.');
            end
            % Границы окна как double.
            first=double(first); last=double(last);
            % Ячейки UL окна (полуподкадры).
            ulWindow=obj.ul(2*first+1:2*last,:);
            % Подкадры DL окна.
            dlWindow=obj.dl(first+1:last);
            % Доступные (не обязательные) подкадры DL окна.
            dlAvailable=~obj.mandatoryMask(first+1:last);
            % Число доступных ячеек UL и подкадров DL.
            ulAvailable=numel(ulWindow); dlAvailableUnits=sum(dlAvailable);
            % По умолчанию доли — NaN.
            ulRa=NaN; ulDt=NaN; dlRa=NaN; dlDt=NaN;
            % Если ячейки UL есть —
            if ulAvailable>0
                % доля ячеек UL, занятых RA;
                ulRa=double(sum(ulWindow==1,'all'))/ulAvailable;
                % доля занятых DT.
                ulDt=double(sum(ulWindow==2,'all'))/ulAvailable;
            end
            % Если доступные подкадры DL есть —
            if dlAvailableUnits>0
                % доля подкадров DL, занятых RA;
                dlRa=double(sum(dlWindow==1))/dlAvailableUnits;
                % доля занятых DT.
                dlDt=double(sum(dlWindow==2))/dlAvailableUnits;
            end
            % Доли занятости RA и DT в UL и DL.
            occupancy=struct( ...
                'ulRaOccupancy',ulRa,'ulDtOccupancy',ulDt, ...
                'dlRaOccupancy',dlRa,'dlDtOccupancy',dlDt);
        end
        %USAGE Таблица по окнам и направлениям: доступно, квоты RA/DT, занято RA/DT, в ед. и в Гц·с (ТЗ §27).
        function result=usage(obj)
            % Строки таблицы; длина окна квот.
            rows={}; w=obj.cfg.policy.windowTicks;
            % Для каждого окна:
            for first=0:w:obj.durationTicks-1
                % конец окна; ячейки UL и подкадры DL окна;
                last=min(first+w,obj.durationTicks); u=obj.ul(2*first+1:2*last,:); d=obj.dl(first+1:last);
                % для UL и DL:
                for direction=0:1
                    % UL: доступно ячеек, занято RA и DT; ячейка = 3,75 кГц × 0,5 мс (Гц·с);
                    if direction==0, available=numel(u); ra=sum(u==1,'all'); dt=sum(u==2,'all'); unit=3750*0.0005;
                    % DL: доступно подкадров (кроме обязательных), занято RA и DT; подкадр = 180 кГц × 1 мс;
                    else, available=sum(~obj.mandatoryMask(first+1:last)); ra=sum(d==1); dt=sum(d==2); unit=180000*0.001; end
                    % доля RA этого окна;
                    share=obj.windowShares(floor(first/w)+1);
                    % квота RA (округление вниз);
                    quota=floor(share*available);
                    % строка: окно, направление, доступно, квоты RA/DT, занято RA/DT, площадь в Гц·с.
                    rows(end+1,:)={first,last,direction,available,quota,available-quota,ra,dt,unit,ra*unit,dt*unit}; %#ok<AGROW>
                end
            end
            % Таблица занятости по окнам и направлениям.
            result=cell2table(rows,'VariableNames',{'startTick','endTick','direction','availableUnits','raQuotaUnits','dtQuotaUnits','raReservedUnits','dtReservedUnits','unitHzSeconds','raReservedHzSeconds','dtReservedHzSeconds'});
        end
    end
    methods (Access=private)
        %RESERVATIONSFIT Укладываются ли текущие резервирования в квоты SHARES по всем окнам.
        function fits=reservationsFit(obj,shares)
            % По умолчанию не помещается; длина окна.
            fits=false; w=obj.cfg.policy.windowTicks;
            % Для каждого окна:
            for first=0:w:obj.durationTicks-1
                % конец окна;
                last=min(first+w,obj.durationTicks);
                % ячейки UL и подкадры DL окна;
                us=obj.ul(2*first+1:2*last,:); ds=obj.dl(first+1:last);
                % доля RA окна;
                share=shares(floor(first/w)+1);
                % доступные ячейки UL и подкадры DL;
                availableUl=numel(us); availableDl=sum(~obj.mandatoryMask(first+1:last));
                % квоты RA в UL и DL;
                quotaUl=floor(share*availableUl); quotaDl=floor(share*availableDl);
                % занятость RA не больше квоты RA, DT — не больше остатка, в UL и DL;
                if sum(us==1,'all')>quotaUl||sum(us==2,'all')>availableUl-quotaUl|| ...
                        sum(ds==1)>quotaDl||sum(ds==2)>availableDl-quotaDl
                    % иначе не помещается.
                    return;
                end
            end
            % Все окна в порядке.
            fits=true;
        end
        %CHECK Пробное резервирование: без конфликтов ячеек и с соблюдением квот RA/DT во всех окнах.
        function [ok,u,d]=check(obj,plans)
            % Копии календарей для пробы; по умолчанию не помещается.
            u=obj.ul; d=obj.dl; ok=false;
            % Пустой набор планов помещается всегда.
            if isempty(plans), ok=true; return; end
            % Номера уже выданных назначений.
            ids=[obj.records.grantId];
            % Для каждого плана:
            for i=1:numel(plans)
                % назначение не должно повторяться;
                p=plans(i); if ismember(p.grantId,ids), return; end; ids(end+1)=p.grantId;
                % ячейки плана; фаза 1 (RA) или 2 (DT);
                [r,c,dir]=obj.indices(p); phase=1+strcmpi(p.phase,'DT');
                % фаза — только RA или DT;
                assert(any(strcmpi(p.phase,{'RA','DT'})));
                % UL:
                if dir==0
                    % ячейки должны быть свободны — занимаем;
                    if any(u(r,c)~=0,'all'), return; end; u(r,c)=phase;
                else
                    % DL: подкадры свободны и не обязательные — занимаем.
                    if any(d(r)~=0|obj.mandatoryMask(r)), return; end; d(r)=phase;
                end
            end
            % Длина окна квот.
            w=obj.cfg.policy.windowTicks;
            % Для каждого окна:
            for first=0:w:obj.durationTicks-1
                % конец; ячейки UL и подкадры DL в пробных календарях;
                last=min(first+w,obj.durationTicks); us=u(2*first+1:2*last,:); ds=d(first+1:last);
                % доля RA окна;
                share=obj.windowShares(floor(first/w)+1);
                % доступно и квоты RA в UL и DL;
                au=numel(us); ad=sum(~obj.mandatoryMask(first+1:last)); qu=floor(share*au); qd=floor(share*ad);
                % любое превышение квот RA или DT — не помещается.
                if sum(us==1,'all')>qu || sum(us==2,'all')>au-qu || sum(ds==1)>qd || sum(ds==2)>ad-qd, return; end
            end
            % Все планы помещаются.
            ok=true;
        end
        %INDICES Строки/столбцы календаря для плана P: UL — полуподкадры × тоны 3,75 кГц, DL — подкадры.
        function [rows,cols,d]=indices(obj,p)
            % Направление: число или 'UL'/'DL' → 0/1.
            if isnumeric(p.direction), d=double(p.direction); else, d=find(strcmpi(p.direction,{'UL','DL'}),1)-1; end
            % Только 0 или 1.
            assert(isscalar(d) && any(d==[0 1]));
            % Тики плана столбцом: непустые и без повторов.
            ticks=p.ticks(:); assert(~isempty(ticks) && numel(unique(ticks))==numel(ticks));
            % Тики — целые внутри горизонта.
            assert(all(ticks>=0 & ticks<obj.durationTicks & ticks==fix(ticks)));
            % UL:
            if d==0
                % строки — два полуподкадра на каждый тик;
                rows=reshape([2*ticks+1,2*ticks+2].',[],1);
                % начальный тон и число тонов по 3,75 кГц;
                a=p.frequencyStartHz/3750; b=p.bandwidthHz/3750;
                % целые, внутри 48 тонов; столбцы — эти тоны.
                assert(a==fix(a) && b==fix(b) && a>=0 && b>0 && a+b<=48); cols=a+(1:b);
            else
                % DL: всегда весь подкадр 180 кГц; строки — подкадры, один столбец.
                assert(p.frequencyStartHz==0 && p.bandwidthHz==180000); rows=ticks+1; cols=1;
            end
        end
        %CANONICAL Запись о резервировании (только нужные поля).
        function p=canonical(~,x)
            % Направление, фаза, тики, частота, полоса, номер назначения.
            p=struct('direction',x.direction,'phase',x.phase,'ticks',x.ticks,'frequencyStartHz',x.frequencyStartHz,'bandwidthHz',x.bandwidthHz,'grantId',x.grantId);
        end
    end
end
