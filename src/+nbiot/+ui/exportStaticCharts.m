function files=exportStaticCharts(chartAxes,outputFolder)
%EXPORTSTATICCHARTS Save the eight Static chart axes as separate PNG files.
keys={'activeUe','actualLoad','collisions','successfulRa', ...
    'throughput','delay','dataBler','occupancy'};
names={'active-ue.png','actual-load.png','ra-collisions.png', ...
    'successful-ra.png','throughput.png','delivery-delay.png', ...
    'data-bler.png','resource-occupancy.png'};
if ~isstruct(chartAxes)||~isscalar(chartAxes)||~all(isfield(chartAxes,keys))|| ...
        ~(ischar(outputFolder)||(isstring(outputFolder)&&isscalar(outputFolder)))
    error('nbiot:ui:ChartExportInput','Chart axes and an output folder are required.');
end
outputFolder=char(string(outputFolder));
if isempty(strtrim(outputFolder))
    error('nbiot:ui:ChartExportOutput','Choose an output folder for the chart images.');
end
for k=1:numel(keys)
    if ~isgraphics(chartAxes.(keys{k}))
        error('nbiot:ui:ChartExportInput','A chart axis is not available for export.');
    end
end
if isfile(outputFolder)
    error('nbiot:ui:ChartExportOutput','The chart output path is an existing file.');
end
if isfolder(outputFolder)
    contents=dir(outputFolder); contents=contents(~ismember({contents.name},{'.','..'}));
    if ~isempty(contents)
        error('nbiot:ui:ChartExportOutput','Choose an empty folder for the chart images.');
    end
else
    [ok,message]=mkdir(outputFolder);
    if ~ok, error('nbiot:ui:ChartExportOutput','Cannot create the chart folder: %s',message); end
end
files=cell(numel(keys),1);
for k=1:numel(keys)
    files{k}=fullfile(outputFolder,names{k});
    exportgraphics(chartAxes.(keys{k}),files{k},'Resolution',150);
end
end
