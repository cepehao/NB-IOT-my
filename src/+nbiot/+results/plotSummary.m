function fig=plotSummary(result)
%PLOTSUMMARY Figures use observed run data; no fitted success curves.
fig=figure('Name','NB-IoT Static results'); tiledlayout(2,2);
nexttile; bar([result.kpiSummary.delivered result.kpiSummary.dropped result.kpiSummary.unfinished]);
xticklabels({'Delivered','Dropped','Unfinished'}); ylabel('Packets'); grid on;
nexttile; plot(result.dataset.targets.startTick,result.dataset.targets.meanRaUe,'-o'); xlabel('Time (ms)'); ylabel('Mean UE in RA'); grid on;
nexttile; plot(result.dataset.observations.startTick,result.dataset.observations.detectedCandidates,'-o'); xlabel('Time (ms)'); ylabel('Detected candidates'); grid on;
nexttile; bar([result.kpiSummary.ulOccupancy result.kpiSummary.dlOccupancy]); xticklabels({'UL','DL'}); ylabel('Allocation occupancy'); ylim([0 1]); grid on;
end
