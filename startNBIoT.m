function [app,report]=startNBIoT(mode)
%STARTNBIOT Open the demo or run the installation check.
% startNBIoT; startNBIoT('check');
if nargin<1, mode='demo'; end
if ~(ischar(mode)||(isstring(mode)&&isscalar(mode))) || ...
        ~ismember(string(mode),["demo","check"])
    error('nbiot:startup:Mode','Use demo or check.');
end
root=fileparts(mfilename('fullpath'));
addpath(root); cd(root); setupProject();
app=[];
try
    if ~strcmp(version('-release'),'2025b')
        error('nbiot:startup:MatlabVersion', ...
            'Нужен MATLAB R2025b. Сейчас открыт R%s. Инструкция: README.md.',version('-release'));
    end
    lteAvailable=~isempty(ver('lte')) && exist('lteNPRACH','file')==2 ...
        && license('test','LTE_Toolbox');
    if ~lteAvailable
        error('nbiot:startup:LTE', ...
            'Установите и активируйте LTE Toolbox для MATLAB R2025b. Инструкция: README.md.');
    end
    cfg=nbiot.config.defaultConfig();
    nbiot.experiments.loadCalibration(cfg,fullfile(root,'results','nprach-calibration.mat'));
    probe=[tempname(fullfile(root,'results')) '.tmp'];
    [fid,message]=fopen(probe,'w');
    if fid<0
        error('nbiot:startup:WritableFolder', ...
            'Не удаётся сохранить результат: %s.',message);
    end
    fclose(fid); delete(probe);
    report=struct('release',version('-release'),'lteAvailable',logical(lteAvailable), ...
        'calibrationAccepted',true,'writableResults',true,'root',root);
    switch char(mode)
        case 'demo'
            run(fullfile(root,'startDemo.m'));
            app=meetingApp;
        case 'check'
            fprintf('NB-IoT: MATLAB R2025b, LTE Toolbox, calibration and results folder OK.\n');
    end
catch exception
    fprintf(2,'\nNB-IoT не удалось открыть.\n%s\nИнструкция: %s\n', ...
        exception.message,fullfile(root,'README.md'));
    rethrow(exception);
end
end
