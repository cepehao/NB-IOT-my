function startupProject()
%STARTUPPROJECT Добавляет папки проекта NB-IoT и tests/ на путь MATLAB.
%   Вызывать из любой папки: startupProject(). Папки кода добавляет
%   setupProject() (src, configs, examples, experiments, tests/helpers).

root = fileparts(mfilename('fullpath'));
addpath(root);
setupProject();
addpath(fullfile(root, 'tests'));
end
