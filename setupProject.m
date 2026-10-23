function root=setupProject()
%SETUPPROJECT Add explicit project folders and the shared test fixture helpers.
%   Добавляет на путь src, configs, examples, experiments и tests/helpers.
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'src'),fullfile(root,'configs'),fullfile(root,'examples'), ...
    fullfile(root,'experiments'),fullfile(root,'tests','helpers'));
end
