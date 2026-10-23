function refresh=shouldRefreshDisplay(currentTick,lastDisplayTick,runFinished)
%SHOULDREFRESHDISPLAY Decide when the UI redraws during a model run.
%   Нужно ли перерисовать GUI на этом тике (период обновления 100 мс, ТЗ §46.16).
refresh=logical(runFinished) || currentTick-lastDisplayTick>=100;
end
