# Как написать свой сценарий и собрать датасет

Гайд для научного направления: вы описываете сценарий моделирования в MATLAB-скрипте, ядро
прогоняет его и выгружает датасет (признаки базовой станции + истинная нагрузка) для обучения моделей
в Python. Устройство ядра — `docs/SIMULATOR_GUIDE.md`, требования — `docs/TZ.md` §21–22, §28–29, §40.

---

## 1. Минимальный сценарий за 5 минут

Готовый пример — `examples/collectDatasetExample.m`. Скопируйте его, например, в
`scenarios/myDataset.m` (любая папка внутри проекта), поменяйте сетку и запустите:

```matlab
startupProject();
cfgs = {};
for numUE = [10 30]
    for id = 0:4                                   % 5 независимых реализаций
        cfg = nbiot.config.defaultConfig();
        cfg.simulation.numUE = numUE;
        cfg.simulation.realizationId = id;
        cfgs{end+1} = cfg;
    end
end
summary = nbiot.dataset.collectDataset(cfgs, fullfile(pwd,'results','my-dataset'));
```

Результат — `results/my-dataset/dataset.csv`: одна строка на окно 500 мс каждого прогона.
Папка `results/` не попадает в git — датасеты в репозиторий не коммитим.

---

## 2. Как устроен сценарий

**Один прогон = одна конфигурация `cfg`.** Сценарий — это список конфигураций: вы берёте
`nbiot.config.defaultConfig()` (все параметры ТЗ по умолчанию) и меняете нужные поля. Каждый прогон
моделирует 5 с работы соты (`cfg.simulation.durationTicks = 5000` тиков по 1 мс) и даёт
`durationTicks / 500` окон датасета — по умолчанию 10.

**Внешняя реализация — `cfg.simulation.realizationId`.** От неё (вместе с `cfg.simulation.seed = 42`)
зависят координаты UE, shadowing, fading, CFO, моменты пакетов, шум. Разные номера — независимые
«миры»; одинаковый номер при разных параметрах управления — тот же мир (так сравнивают методы, ТЗ §63).

**Роль реализации в обучении задаётся номером:** `realizationId mod 20` → 0–13 `train`,
14–16 `validation`, 17–19 `test` (70/15/15). Делятся целые реализации, а не окна: соседние окна одного
прогона коррелированы, и их смешение между train и test — утечка. Допустимые номера — 0..3999
(4000+ заняты калибровкой NPRACH). **Чтобы в датасете были все три роли, берите хотя бы 20 подряд
идущих номеров** (например, `0:19`) или подбирайте номера под нужную пропорцию.

---

## 3. Что можно варьировать

Все поля — в `nbiot.config.defaultConfig` (полный список с единицами — в шапке
`src/+nbiot/+config/defaultConfig.m`). Для датасета оценки нагрузки обычно меняют:

| Что | Поле `cfg` | По умолчанию | Примечание |
|---|---|---|---|
| Число устройств | `simulation.numUE` | 1000 | ТЗ §29: 100, 500, 1000, 2500, 5000 |
| Реализация | `simulation.realizationId` | 0 | 0..3999, задаёт split |
| Тип трафика | `traffic.kind` | `'burst'` | `'burst'` (массовый, ТЗ §11.3), `'periodic'`, `'poisson'`, `'none'` |
| Всплеск: начало, длительность | `traffic.burstStartTick`, `traffic.burstDurationTicks` | 1000, 100 мс | Чем короче всплеск, тем сильнее перегрузка RA |
| Периодический трафик | `traffic.periodTicks` | 1000 мс | Пакет на UE раз в период |
| Пуассоновский трафик | `traffic.poissonRatePerSecond` | 0,2 пак/с на UE | Интенсивность |
| Размер пакета, очередь | `traffic.packetBytes`, `traffic.queueLimit` | 200 байт, 10 | ТЗ §30 |
| Активные UE | `traffic.activityMode`, `traffic.activeUeIds` | `'all'` | `'explicit'` + список номеров UE |
| Вероятность доступа P | `policy.accessProbability` | 1 | Фиксированный режим (Static) |
| Доля RA | `policy.raShare` | 0,1 | 0,1 / 0,2 / 0,3 (RA/DT 10/90, 20/80, 30/70) |
| Лимит попыток RA | `ra.maxAttempts` | 8 | ТЗ §30 |
| Длительность прогона | `simulation.durationTicks` | 5000 | Кратно 500, чтобы окна были полными |
| Геометрия, канал | `cell.*`, `channel.*` | ТЗ §10, §13 | Радиус, indoor, shadowing, мощности, CFO |

Нельзя менять (проверка `validateConfig` остановит запуск с ошибкой `nbiot:config:*`): шаг 1 мс и
частоту 1,92 МГц, формат NPRACH и таблицы каналов PHY — на них рассчитан PHY и откалиброван детектор.

**Зачем менять P и долю RA в датасете.** Эти значения входят в признаки (`accessProbability`, `raShare`):
адаптивный контроллер будет менять их на ходу, поэтому модель должна видеть данные при разных режимах.
Задать фиксированный режим можно прямо в Static: `cfg.policy.accessProbability = 0.5; cfg.policy.raShare = 0.2;`.

---

## 4. Запуск: `nbiot.dataset.collectDataset`

```matlab
summary = nbiot.dataset.collectDataset(cfgs, outputFolder, options);
```

| Опция | По умолчанию | Что делает |
|---|---|---|
| `useParallel` | `false` | `true` — прогоны параллельно на всех ядрах (`parfor`, Parallel Computing Toolbox) |
| `saveRuns` | `true` | Сохранять полный результат каждого прогона в `runs/run_NNNN/` |
| `overwrite` | `false` | Разрешить перезапись существующего `dataset.csv` |
| `calibrationFile` | `results/nprach-calibration.mat` | Порог детектора NPRACH |
| `controllerOptions` | пусто | Для Adaptive-*: оценщик нагрузки (одна struct на все прогоны или cell по прогону) |

Упавший прогон не останавливает сбор: он отмечается в `runs.csv` (`status = "failed"`, текст ошибки)
и не попадает в `dataset.csv`.

**Сколько это длится.** Расчёт идёт на уровне сигналов, поэтому он небыстрый. Замеры на этом Mac
(MATLAB R2025b, M4 Pro, массовый всплеск 100 мс, 5 с модели, один прогон):

| Устройств | Время одного прогона | Окон в датасете |
|---:|---:|---:|
| 10 | ≈ 1,5 мин (90 с) | 10 |
| 30 | ≈ 5 мин (313 с) | 10 |
| 100 | ≈ 11 мин (653 с) | 10 |

Замер 2026-10-24, seed 42, реализация 0, конфигурация по умолчанию кроме числа UE; во время замера
MATLAB параллельно выполнял другие задачи, так что на свободной машине чуть быстрее. Время растёт с
числом UE примерно линейно; 1000 UE и больше сейчас — часы на прогон.

Начинайте с малых нагрузок и нескольких реализаций, проверьте датасет, потом расширяйте.
`useParallel = true` выполняет до 12 прогонов одновременно (по числу ядер). Ускорение ядра для 1000–5000 UE
— этап 2 ROADMAP.

---

## 5. Что получится

```
results/my-dataset/
├── dataset.csv        ← все окна всех успешных прогонов (это и есть датасет)
├── runs.csv           ← по строке на прогон: параметры, статус, время, основные KPI
└── runs/run_0001/     ← полный результат прогона (MAT + CSV), если saveRuns = true
```

Столбцы `dataset.csv`:

| Группа | Столбцы | Использование в модели |
|---|---|---|
| Описание прогона | `runIndex`, `policyName`, `numUE`, `trafficKind`, `seed`, `split` | **Не признаки.** Для фильтрации, анализа и разбиения (`split`) |
| Ключи окна | `realizationId`, `windowId`, `startTick`, `endTick` | **Не признаки.** Идентификация окна |
| Признаки BS | `detectedCandidates`, `meanPeakMetric`, `maxPeakMetric`, `meanRxEnergyW`, `ulTbDecodes`, `ulCrcFailures`, `rarSent`, `grantsSent`, `pendingRequestsMean`, `ulRaOccupancy`, `ulDtOccupancy`, `dlRaOccupancy`, `dlDtOccupancy`, `accessProbability`, `raShare` | **Вход модели.** Только то, что базовая станция знает к концу окна (ТЗ §40) |
| Target | `meanRaUe` — основной (среднее число UE в фазе доступа за окно); также `meanActiveUe`, `meanWaitingQueuePerUe`, `msg1Transmissions`, `uniqueMsg1Ue` | **Только как target.** Это истина симулятора: в признаки нельзя (ТЗ §40) |

Точный список признаков с единицами — `nbiot.dataset.featureSchema()` (поля `inputNames`, `units`).
Модель в контроллере получит ровно `inputNames` в этом порядке — обучайте на них же.

**Почему `numUE` и `trafficKind` — не признаки.** Базовая станция не знает, сколько устройств
конкурирует; оценить это по наблюдениям и есть задача модели. Эти столбцы нужны только для анализа
(например, ошибка оценки по уровням нагрузки).

---

## 6. В Python

```python
import pandas as pd
df = pd.read_csv("results/my-dataset/dataset.csv")
features = ["detectedCandidates", "meanPeakMetric", "maxPeakMetric", "meanRxEnergyW",
            "ulTbDecodes", "ulCrcFailures", "rarSent", "grantsSent", "pendingRequestsMean",
            "ulRaOccupancy", "ulDtOccupancy", "dlRaOccupancy", "dlDtOccupancy",
            "accessProbability", "raShare"]
train, val, test = (df[df.split == s] for s in ("train", "validation", "test"))
X_train, y_train = train[features], train["meanRaUe"]
```

Несколько датасетов (разные сценарии) объединяются конкатенацией CSV — если номера реализаций в них
не пересекаются по смыслу. Повтор одного `realizationId` с другими параметрами — это тот же «мир»
(та же геометрия и тот же канал), он автоматически попадёт в ту же выборку.

---

## 7. Частые вопросы

- **«Калибровка не найдена»** — нужен `results/nprach-calibration.mat` (лежит в репозитории). Если меняли
  конфигурацию NPRACH — перекалибровка `examples/calibrateNprach.m` (долго).
- **В выборке нет validation/test** — номера реализаций не покрыли остатки 14–19 по модулю 20.
- **Окна неполные** — `durationTicks` не кратно 500; последнее окно короче остальных.
- **Adaptive-P / Adaptive-RA/DT в датасете** — нужен оценщик в `controllerOptions`
  (`struct('estimator', @(features) …)`), иначе прогон отметится как failed. Для начального датасета
  достаточно Static с разными фиксированными P и долями RA.
- **Свой код вокруг ядра** — можно не пользоваться `collectDataset`: `result = nbiot.runExperiment(cfg)`,
  дальше `result.dataset.observations` и `result.dataset.targets` (таблицы с одинаковыми ключами окон)
  и `nbiot.results.saveResult(result, folder)`.
