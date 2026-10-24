function root=setupProject()
%SETUPPROJECT Добавляет на путь MATLAB папки ядра симулятора.
%   ROOT = setupProject() — src (пакет +nbiot), configs (готовые конфигурации и политика контроллера),
%   examples (примеры запуска) и tests/helpers (общие фикстуры тестов). Возвращает корень проекта.
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'src'),fullfile(root,'configs'),fullfile(root,'examples'), ...
    fullfile(root,'tests','helpers'));
end
