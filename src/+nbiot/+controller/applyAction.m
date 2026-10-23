function [applied,reason]=applyAction(simulator,action)
%APPLYACTION Apply one validated runtime action without changing the base config.
if ~isobject(simulator)||~ismethod(simulator,'applyRuntimeAction')
    applied=false; reason='unsupported-simulator'; return;
end
[applied,reason]=simulator.applyRuntimeAction(action);
end
