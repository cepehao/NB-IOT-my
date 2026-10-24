%COLLECTDATASETEXAMPLE Пример сценария сбора датасета для обучения (ТЗ §22, §28–29).
%   Скопируйте файл (например, в work/myDataset.m — папка не в git), поменяйте сетку параметров и запустите.
%   Каждая комбинация параметров × номер реализации = один прогон симулятора. Все окна 500 мс
%   всех прогонов собираются в results/<имя>/dataset.csv — вход для обучения в Python.
%   Подробно — docs/DATASET_GUIDE.md.
%   Время: прогон 10 UE ≈ 1,5 мин, 30 UE ≈ 5 мин (M4 Pro); этот пример — 12 прогонов, ≈ 40 мин
%   последовательно или в несколько раз быстрее с useParallel = true.

% Корень проекта (файл лежит на уровень ниже: examples/ или work/); переходим в него и подключаем проект.
root = fileparts(fileparts(mfilename('fullpath')));
cd(root); startupProject();

% ---- 1. Сетка сценария: что варьируем --------------------------------------------------
numUEs        = [10 30];          % число устройств (ТЗ §29: 100, 500, 1000, 2500, 5000)
burstDurations = 100;             % длительность всплеска массового доступа, мс (ТЗ §11.3); можно [100 500]
policies = {                      % режим управления: фиксированные P и доля RA (Static)
    struct('accessProbability', 1.0, 'raShare', 0.1)    % базовый Static RA/DT = 10/90 (ТЗ §26)
    struct('accessProbability', 0.5, 'raShare', 0.2)    % другой режим → признаки accessProbability/raShare
};
realizationIds = [0 14 17];       % независимые внешние реализации (геометрия, канал, трафик);
                                  % роль: id mod 20 → 0–13 train, 14–16 validation, 17–19 test;
                                  % здесь по одной на роль, для обучения берите 0:19 и больше

% ---- 2. Конфигурация на каждый прогон --------------------------------------------------
cfgs = {};
for numUE = numUEs
    for burst = burstDurations
        for p = 1:numel(policies)
            for id = realizationIds
                cfg = nbiot.config.defaultConfig();
                cfg.simulation.numUE = numUE;
                cfg.simulation.realizationId = id;          % 0..3999
                cfg.traffic.kind = 'burst';
                cfg.traffic.burstStartTick = 1000;          % всплеск с 1 с
                cfg.traffic.burstDurationTicks = burst;
                cfg.policy.accessProbability = policies{p}.accessProbability;
                cfg.policy.raShare = policies{p}.raShare;
                cfgs{end+1} = cfg; %#ok<SAGROW>
            end
        end
    end
end
fprintf('Прогонов: %d\n', numel(cfgs));

% ---- 3. Прогоны и сборка датасета ------------------------------------------------------
outputFolder = fullfile(root, 'results', 'dataset-example');
summary = nbiot.dataset.collectDataset(cfgs, outputFolder, ...
    struct('useParallel', false, 'overwrite', true));   % useParallel=true — параллельно по прогонам

fprintf('Окон в датасете: %d, неуспешных прогонов: %d\n', height(summary.dataset), summary.failed);
disp(summary.runs(:, {'runIndex','numUE','realizationId','status','elapsedSeconds','deliveryProbability'}));
fprintf('Датасет: %s\n', summary.files.dataset);
