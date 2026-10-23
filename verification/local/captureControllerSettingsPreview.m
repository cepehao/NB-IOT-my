projectRoot=fileparts(fileparts(fileparts(mfilename('fullpath'))));
cd(projectRoot); addpath(projectRoot); setupProject(); addpath(fullfile(projectRoot,'apps'));
app=NBIoTApp();
cleanup=onCleanup(@() closePreview(app));
mode=findall(app.Figure,'Tag','simulationMode');
mode.Value='Adaptive-P'; feval(mode.ValueChangedFcn,mode,[]);
selector=findall(app.Figure,'Tag','allowedRaShares');
controllerTab=selector.Parent.Parent;
controllerTab.Parent.SelectedTab=controllerTab;
drawnow; pause(0.5);
exportapp(app.Figure,fullfile(projectRoot,'verification','local','gui-controller-settings-preview-20261013.png'));
clear cleanup
function closePreview(app)
try
    if isvalid(app.Figure), close(app.Figure); end
catch
end
end
