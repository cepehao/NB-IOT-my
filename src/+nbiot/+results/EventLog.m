classdef EventLog < handle
    %EVENTLOG Append-only semantic events; receiver features have a whitelist.
    %   Журнал событий (тик, вид, поля) только на дозапись; основа журналов наблюдений и истины.
    properties (Access=private)
        % Буфер событий (ячейки), начальная ёмкость 256.
        buffer = cell(256,1)
        % Число записанных событий.
        used = 0
    end
    methods
        %APPEND Добавляет событие (тик, вид, поля) в конец журнала.
        function append(obj,tick,kind,fields)
            % Номер нового события.
            obj.used=obj.used+1;
            % Буфер полон — удваиваем ёмкость.
            if obj.used>numel(obj.buffer), obj.buffer=[obj.buffer;cell(numel(obj.buffer),1)]; end
            % Записываем событие.
            obj.buffer{obj.used}=struct('tick',double(tick),'kind',char(kind),'fields',fields);
        end
        %ALL Все события журнала массивом struct.
        function events=all(obj)
            % Пустой журнал — пустой массив с нужными полями;
            if obj.used==0, events=struct('tick',{},'kind',{},'fields',{});
            % иначе — все записанные события.
            else, events=vertcat(obj.buffer{1:obj.used}); end
        end
        %SINCE События после номера AFTERINDEX и новый курсор (инкрементальное чтение).
        function [events,nextIndex]=since(obj,afterIndex)
            % По умолчанию — с начала.
            if nargin<2, afterIndex=0; end
            % Курсор — целое от 0 до числа событий.
            if ~isnumeric(afterIndex)||~isreal(afterIndex)||~isscalar(afterIndex)|| ...
                    ~isfinite(afterIndex)||afterIndex~=fix(afterIndex)|| ...
                    afterIndex<0||afterIndex>obj.used
                % иначе ошибка.
                error('nbiot:results:EventLogCursor', ...
                    'Event cursor must be an integer between 0 and the current event count.');
            end
            % Новый курсор — текущее число событий.
            nextIndex=obj.used;
            % Новых событий нет —
            if afterIndex==obj.used
                events=struct('tick',{},'kind',{},'fields',{});
            else
                events=vertcat(obj.buffer{afterIndex+1:obj.used});
            end
        end
    end
end
