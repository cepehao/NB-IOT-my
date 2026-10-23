classdef TestStaticChartExport < matlab.unittest.TestCase
    methods (Test)
        function exportsAllEightChartsAsPngFiles(t)
            parent=tempname; mkdir(parent);
            t.addTeardown(@() removeFolder(parent));
            fig=figure('Visible','off');
            t.addTeardown(@() closeFigure(fig));
            chartAxes=makeChartAxes(fig);
            outputFolder=fullfile(parent,'charts');

            files=nbiot.ui.exportStaticCharts(chartAxes,outputFolder);

            t.verifyEqual(numel(files),8);
            for k=1:numel(files)
                t.verifyTrue(isfile(files{k}));
                details=dir(files{k});
                t.verifyGreaterThan(details.bytes,100);
            end
        end

        function refusesToOverwriteAnExistingExportFolder(t)
            parent=tempname; mkdir(parent);
            t.addTeardown(@() removeFolder(parent));
            fig=figure('Visible','off');
            t.addTeardown(@() closeFigure(fig));
            chartAxes=makeChartAxes(fig);
            outputFolder=fullfile(parent,'charts'); mkdir(outputFolder);
            sentinel=fullfile(outputFolder,'keep.txt'); fid=fopen(sentinel,'w');
            cleanup=onCleanup(@() fclose(fid)); fwrite(fid,'keep','char');

            t.verifyError(@() nbiot.ui.exportStaticCharts(chartAxes,outputFolder), ...
                'nbiot:ui:ChartExportOutput');
            t.verifyTrue(isfile(sentinel));
        end
    end
end

function chartAxes=makeChartAxes(fig)
keys={'activeUe','actualLoad','collisions','successfulRa', ...
    'throughput','delay','dataBler','occupancy'};
chartAxes=struct();
for k=1:numel(keys)
    ax=subplot(4,2,k,'Parent',fig);
    plot(ax,[0 1],[k k+1]);
    title(ax,keys{k});
    chartAxes.(keys{k})=ax;
end
end

function closeFigure(fig)
if isgraphics(fig), close(fig); end
end

function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
