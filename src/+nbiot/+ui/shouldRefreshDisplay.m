function refresh=shouldRefreshDisplay(currentTick,lastDisplayTick,runFinished)
%SHOULDREFRESHDISPLAY Decide when the UI redraws during a model run.
refresh=logical(runFinished) || currentTick-lastDisplayTick>=100;
end
