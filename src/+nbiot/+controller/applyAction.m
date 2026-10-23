function [applied,reason]=applyAction(simulator,action)
%APPLYACTION Применяет действие контроллера ACTION к симулятору (обёртка над applyRuntimeAction).
%   Базовая конфигурация не меняется; действие хранится отдельно (ТЗ §23).
if ~isobject(simulator)||~ismethod(simulator,'applyRuntimeAction')
    applied=false; reason='unsupported-simulator'; return;
end
[applied,reason]=simulator.applyRuntimeAction(action);
end
