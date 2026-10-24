function [applied,reason]=applyAction(simulator,action)
%APPLYACTION Применяет действие контроллера ACTION к симулятору (обёртка над applyRuntimeAction).
%   Базовая конфигурация не меняется; действие хранится отдельно (ТЗ §23).
% Объект должен быть симулятором с методом applyRuntimeAction —
if ~isobject(simulator)||~ismethod(simulator,'applyRuntimeAction')
    % иначе действие не применено с причиной unsupported-simulator.
    applied=false; reason='unsupported-simulator'; return;
end
% Применение действия симулятором (он проверяет допустимость и квоты ресурсов).
[applied,reason]=simulator.applyRuntimeAction(action);
end
