# Гайд по ядру симулятора NB-IoT

Что делает каждый файл и зачем он нужен. Ядро — это MATLAB-симулятор соты NB-IoT без графического
интерфейса: его вызывают из скриптов, чтобы моделировать сценарии, получать KPI и собирать датасет для
обучения моделей (ТЗ §9, §45). Подробные формулы и параметры — в комментариях файлов и в
`docs/model-profile.md`; требования — в `docs/TZ.md`.

---

## 1. Быстрый старт

```matlab
startupProject();                                   % пути проекта
root = pwd;
cfg = nbiot.config.defaultConfig();                 % все параметры (ТЗ §10, §13, §30)
cfg.simulation.numUE = 100;                         % сценарий
cfg = nbiot.phy.nprach.loadCalibration(cfg, fullfile(root,'results','nprach-calibration.mat'));
result = nbiot.runExperiment(cfg);                  % один прогон Static до горизонта 5 с
disp(result.kpiSummary)                             % KPI (ТЗ §27)
nbiot.results.saveResult(result, fullfile(root,'results','my-run'));   % MAT + CSV
```

Адаптивный метод — тот же прогон с оценщиком нагрузки:

```matlab
cfg.policy.name = 'Adaptive-P';                     % или 'Adaptive-RA/DT'
opts = struct('estimator', @(features) myModel(features));   % features — таблица из 1 строки
result = nbiot.runExperiment(cfg, [], opts);
```

Сравнение методов на одной внешней реализации (ТЗ §63): построить сценарий один раз и передать его
во все прогоны.

```matlab
scenario = nbiot.scenario.buildScenario(cfg);       % координаты, канал, трафик — одни на всех
rStatic  = nbiot.runExperiment(cfgStatic, scenario);
rAdaptP  = nbiot.runExperiment(cfgAdaptiveP, scenario, opts);
```

Пошаговый режим: `sim = nbiot.NBIoTSimulator(cfg); sim.run(1000); s = sim.snapshot(); sim.run();`.

---

## 2. Как устроен один прогон

```
defaultConfig ─► validateConfig ─► buildScenario (UE, канал, трафик; RandomSources)
                                          │
                                          ▼
                              NBIoTSimulator.step()  × 5000 тиков по 1 мс
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ 1. завершить приёмы, готовые к тику (EventQueue → handleReceive)          │
   │    NPRACH: RadioChannel.receive → nprach.detect → контекст RA на BS       │
   │    UL/DL: npusch / npdcch / npdsch receive → протокол UE и BS             │
   │ 2. срок жизни пакетов, таймеры (окно RAR, contention, BACKOFF, лимит 8)  │
   │ 3. новые пакеты (PacketStore), IDLE → WAIT_RA                             │
   │ 4. граница окна 500 мс: строка датасета (closeWindow) + решение          │
   │    контроллера (estimateLoad → chooseAction → applyRuntimeAction)         │
   │ 5. новые передачи: служебный DL, Msg1 (NPRACH), назначения BS             │
   │    (Scheduler + ResourceCalendar), кандидаты NPDCCH; все сигналы — в канал│
   │ 6. статистика очередей                                                    │
   └──────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                    result(): журналы, KPI, датасет, таблицы ─► saveResult
```

Главный принцип: исход любого приёма решает приёмник по суммарному сигналу всех UE с шумом.
«Истина» симулятора (кто передавал, были ли коллизии) пишется отдельно и используется только
для KPI и target датасета, но не для решений приёмника или контроллера (ТЗ §40).

---

## 3. Файлы по пакетам

### Корень проекта

| Файл | Что делает | Зачем |
|---|---|---|
| `startupProject.m` | Вызывает `setupProject` и добавляет `tests/` на путь | Одна команда перед работой и тестами |
| `setupProject.m` | Добавляет на путь `src`, `configs`, `examples`, `tests/helpers` | Без него пакет `nbiot` не виден |
| `runAllTests.m` | Запускает тесты из `tests/` (фильтр по тегу) | Проверка ядра одной командой |
| `results/nprach-calibration.mat` | Принятый порог детектора NPRACH | Без него прогон завершается ошибкой калибровки |

### `src/+nbiot/` — главное

| Файл | Что делает | Зачем |
|---|---|---|
| `NBIoTSimulator.m` | Главный объект: модель времени, пошаговый цикл, протокол UE и BS (Msg1–Msg4, данные, HARQ, ACK, таймеры), вызов контроллера, сборка результата. Методы `run`, `step`, `stop`, `snapshot`, `result` | Оркеструет все модули (ТЗ §45); единственная точка запуска модели |
| `runExperiment.m` | Создаёт симулятор, выполняет до горизонта, возвращает `result` | Короткий вызов «один прогон» для скриптов |

### `+config/` — параметры

| Файл | Что делает | Зачем |
|---|---|---|
| `defaultConfig.m` | Struct со всеми параметрами с единицами: время, сота, канал, трафик, RA, PHY, политика, датасет | Единственный источник параметров (правило 7); значения из ТЗ и проектных решений |
| `validateConfig.m` | Проверяет поля, типы и диапазоны; ошибки `nbiot:config:*` | Некорректная конфигурация отсекается до запуска (ТЗ §46.2) |

### `+scenario/`, `+randomness/` — внешняя реализация

| Файл | Что делает | Зачем |
|---|---|---|
| `buildScenario.m` | Размещает UE в кольце 10–1000 м, считает потери (log-distance, shadowing, indoor 20 дБ), CFO, рассинхрон, отводы fading, расписание пакетов | Всё случайное «снаружи» генерируется один раз — одинаково для Static и Adaptive (ТЗ §28, §63) |
| `RandomSources.m` | Именованные потоки `mrg32k3a` по (seed, номер реализации) | Воспроизводимость (ТЗ §42); каждый источник независим |
| `substreamKey.m` | Номер подпотока по (источник, направление, получатель, блок) | Случайное число для UE/события не зависит от порядка вызовов |

### `+engine/`, `+devices/`, `+traffic/` — время, UE, пакеты

| Файл | Что делает | Зачем |
|---|---|---|
| `EventQueue.m` | Очередь событий «приём завершён к тику N» в стабильном порядке | Детерминированная модель времени |
| `DeviceStore.m` | Состояния всех UE (IDLE, WAIT_RA, WAIT_RAR, WAIT_MSG4, BACKOFF, DATA, WAIT_RECEIPT) и их поля | Модель состояний UE (ТЗ §12); соответствие названиям ТЗ — в шапке файла |
| `PacketStore.m` | Очереди UE (лимит 10), статусы пакетов: delivered / dropped / unfinished | Источник истины о доставке для KPI (ТЗ §27.2) |
| `generateArrivals.m` | Расписание пакетов: массовый всплеск, периодический, пуассоновский | Модели трафика (ТЗ §11) |
| `segmentPacket.m`, `reassemblePacket.m` | Пакет 200 байт ↔ 8 транспортных блоков по 256 бит с заголовком | Передача пакета блоками NPUSCH |
| `generatePayload.m` | Случайные биты пакета по номеру | Утилита (сценарий использует потоки по UE) |

### `+channel/` — радиоканал

| Файл | Что делает | Зачем |
|---|---|---|
| `RadioChannel.m` | Хранит все переданные сигналы и выдаёт принятый: потери, fading, задержка, CFO, сумма сигналов + тепловой шум | Канал на уровне отсчётов (ТЗ §13, §14 п.4–9, §17) |
| `evaluateLinks.m` | Опорный link budget по UE: мощности приёма, шум, SNR | Таблицы и проверка link budget (ТЗ §32); решения по нему не принимаются |
| `fractionalDelay.m` | Дробная задержка FIR-фильтром windowed-sinc | Задержки распространения и timing offset |
| `normalizePower.m` | Масштабирует сигнал к мощности передачи по активной части | Правильная мощность 23 дБм |

### `+phy/` — физический уровень (LTE Toolbox)

| Файл | Что делает | Зачем |
|---|---|---|
| `+nprach/templates.m` | 12 шаблонов преамбул `lteNPRACH` (формат 0) | Сигналы Msg1 без повторной генерации |
| `+nprach/buildTransmission.m` | Waveform Msg1 для выбранного NInit | Передача преамбулы UE (ТЗ §14) |
| `+nprach/groupMetrics.m` | Статистика присутствия каждой преамбулы по 4 группам символов | Первый этап обнаружения, устойчивый к CFO |
| `+nprach/detect.m` | Многопреамбульный детектор: кандидаты по порогу → подтверждение по шаблону → вычитание найденных | Обнаружение нескольких UE, коллизии, capture (ТЗ §14–16) |
| `+nprach/loadCalibration.m` | Загружает порог детектора в cfg, проверяет совместимость | Без порога расчёт не запускается |
| `+nprach/receiverRevision.m` | Версия алгоритма детектора | Привязка калибровки к версии детектора |
| `+npusch/configure.m` | Структуры `ue`/`chs` LTE Toolbox для назначения | Общая настройка передачи и приёма NPUSCH |
| `+npusch/buildTransmission.m` | Waveform NPUSCH: Msg3, данные (CRC, турбо-код, RV) или ACK | Передача UL (ТЗ §20) |
| `+npusch/estimateTiming.m` | Задержка по DM-RS | Синхронизация приёма UL |
| `+npusch/receive.m` | Приём NPUSCH: тайминг, CFO, оценка канала, декодирование, CRC, HARQ, детектор ACK | Проверка CRC — критерий доставки (ТЗ §20, §39) |
| `+npdcch/packDci.m`, `unpackDci.m` | Поля DCI N0/N1 ↔ 23 бита | Формат управляющей информации |
| `+npdcch/buildTransmission.m`, `receive.m` | Передача и приём DCI по NPDCCH | Назначения RAR, данных, Msg4 (ТЗ §19) |
| `+npdsch/buildTransmission.m`, `receive.m` | Передача и приём RAR, Msg4, квитанций по NPDSCH | Нисходящие сообщения RA (ТЗ §19) |
| `dlReceiveGrid.m` | Приём DL-подкадра: синхронизация по CP, CFO по NRS, оценка канала | Общий приёмник для NPDCCH/NPDSCH |
| `dlConfig.m`, `dlModulate.m` | Параметры и OFDM-модуляция DL-подкадра | Общие для DL-передач |
| `mandatoryDL.m`, `buildMandatoryTransmission.m` | NPSS, NSSS, NPBCH, SIB1-NB | Обязательные сигналы соты занимают DL-ресурсы |
| `ProfileTables.m` | Таблицы 3GPP: TBS, задержки, повторы, поднесущие, ресурс ACK | Параметры каналов строго по стандарту |
| `transmission.m` | Упаковка waveform в передачу для канала | Единый формат передач |
| `extractWindow.m` | Вырезает окно отсчётов из принятого сигнала | Общая утилита приёмников |
| `requireToolbox.m` | Проверяет функции LTE Toolbox | Понятная ошибка, если тулбокса нет |
| `verifyRoundtrips.m` | Передача → приём без канала для всех каналов | Самопроверка PHY (ТЗ §33, §39) |

### `+ra/`, `+scheduler/` — процедура доступа и ресурсы

| Файл | Что делает | Зачем |
|---|---|---|
| `RaContextStore.m` | Контексты RA на BS: по одному на обнаруженную преамбулу | BS знает только то, что приняла (ТЗ §18) |
| `encodeMessage.m`, `decodeMessage.m` | Биты RAR, Msg3, Msg4, квитанции и их разбор | Содержимое сообщений RA (ТЗ §19) |
| `ResourceCalendar.m` | Календари UL/DL, квоты RA/DT по окнам 500 мс | Логическое распределение RA/DT (ТЗ §25–26) |
| `Scheduler.m` | Выдача назначений (DCI + передача + Msg3/ACK одной транзакцией) | Планирование ресурсов BS |
| `mandatoryDlMask.m` | Какие DL-подкадры заняты обязательными сигналами | Недоступные ресурсы DL |

### `+controller/` — управление (ТЗ §23–26)

| Файл | Что делает | Зачем |
|---|---|---|
| `prepareRuntime.m` | Проверяет метод и опции: для Adaptive-* нужен `estimator` | Подключение оценщика нагрузки (ML-модели) |
| `estimateLoad.m` | Вызывает оценщик на признаках окна, проверяет результат | Граница между ядром и моделью: оценщик видит только признаки BS (ТЗ §40) |
| `chooseAction.m` | Выбор P (Adaptive-P) или доли RA (Adaptive-RA/DT) по порогам | Решение из допустимого множества (ТЗ §23–25) |
| `applyAction.m` | Применяет действие к симулятору | Обёртка над `applyRuntimeAction` |
| `configs/adaptiveDefaults.m` | Пробные пороги и уровни P и долей RA | Политика по умолчанию; подбирается по данным |

### `+dataset/` — данные для обучения (ТЗ §21–22)

| Файл | Что делает | Зачем |
|---|---|---|
| `featureSchema.m` | Список признаков BS и целевых величин с единицами | Белый список признаков: target не может стать признаком (ТЗ §40) |
| `closeWindow.m` | Строка датасета за окно 500 мс: признаки + target | Формирование датасета в ходе прогона |
| `windowDiagnostics.m` | Диагностика окон по истине (коллизии, приём) | Анализ, не признаки |
| `buildManifest.m` | Роль реализации: train / validation / test (70/15/15 по номеру) | Разбиение по реализациям без утечки |

### `+metrics/` — KPI (ТЗ §27)

| Файл | Что делает | Зачем |
|---|---|---|
| `summarizeKpi.m` | Итоговые KPI: успех RA, доставка, throughput, коллизии, задержки, BLER, занятость | Основные и дополнительные показатели |
| `windowKpi.m` | KPI по окнам 500 мс | Временные ряды для графиков и анализа |
| `serviceKpi.m` | KPI обслуживания по UE и группам (indoor/outdoor, удалённость) | Разрезы результатов |
| `harqSummary.m` | Статистика HARQ: первые передачи, повторы, BLER | BLER NPUSCH (ТЗ §27) |
| `radioDiagnostics.m` | Сопоставление приёмника с истиной: обнаружение, пропуск, ложная тревога, коллизии, capture, ошибки оценок | Проверка физической модели (ТЗ §15–17, §34–36) |
| `countTransmittedPackets.m` | Число пакетов, у которых началась передача данных | Счётчик для `snapshot` |

### `+results/` — результат и сохранение (ТЗ §47)

| Файл | Что делает | Зачем |
|---|---|---|
| `EventLog.m` | Журнал событий «тик, вид, поля» | Основа журналов наблюдений BS и истины |
| `finalizeResult.m` | Базовая сборка struct результата | Общая часть `result()` |
| `buildUeSummary.m` | Таблица по UE: геометрия, потери, SNR, CFO, попытки, итог | Per-UE результаты (ТЗ §47) |
| `buildKpiSummaryTable.m` | KPI одной строкой таблицы | CSV-сводка прогона |
| `buildRadioDiagnosticsTable.m` | Радиодиагностика плоской таблицей | CSV для анализа |
| `saveResult.m` | Сохраняет MAT и CSV (KPI, признаки, target, UE, ресурсы, контроллер) | Выгрузка результатов и датасета для Python |
| `aggregateRuns.m` | Среднее и доверительный интервал KPI по независимым прогонам | Статистика серий (ТЗ §29) |

### `+util/`

| Файл | Что делает | Зачем |
|---|---|---|
| `toBits.m`, `fromBits.m` | Число ↔ биты (старший первым) | Упаковка полей сообщений |

### `configs/` и `examples/`

| Файл | Что делает | Зачем |
|---|---|---|
| `configs/baselineStatic.m` | Базовая конфигурация Static | Точка отсчёта (ТЗ §26) |
| `configs/trafficPeriodic.m`, `trafficPoisson.m` | Конфигурации с другим трафиком | Готовые сценарии ТЗ §11 |
| `examples/runSingleUe.m` | 1 UE, сильный канал, ожидается доставка 1 пакета | Быстрая проверка всей цепочки (~12 с) |
| `examples/runBaseline.m` | Базовый прогон 1000 UE с сохранением | Пример полноценного сценария |
| `examples/checkEnvironment.m` | Проверка LTE Toolbox и PHY без канала | Диагностика установки |
| `examples/calibrateNprach.m` | Калибровка порога детектора NPRACH | Нужна при смене конфигурации NPRACH или детектора |

---

## 4. Что лежит в `result`

| Поле | Содержимое |
|---|---|
| `config`, `scenario`, `randomness`, `environment` | Параметры, внешняя реализация, схема случайности, версия MATLAB |
| `status`, `stopReason`, `actualTick`, `error` | Чем закончился прогон |
| `kpiSummary`, `kpiTimeSeries`, `groupKpi` | KPI итоговые, по окнам, по группам UE |
| `packetLog`, `raLog`, `harqLog` | Пакеты, попытки RA, передачи HARQ |
| `observedLog`, `truthLog`, `phyLog`, `radioReceptionLog` | Журналы: что видела BS / что было на самом деле / PHY |
| `radioDiagnostics` | Обнаружения, пропуски, ложные тревоги, коллизии, capture |
| `ueSummary`, `resourceUsage` | Таблица по UE, занятость ресурсов |
| `dataset.observations`, `dataset.targets` | Признаки BS и target по окнам — для обучения |
| `controllerLog`, `controllerPolicy`, `controllerModel`, `runtimeAction` | Решения контроллера и описание оценщика |

## 5. Как связаны ядро и модели из Python

1. Прогоны ядра → `saveResult` → `*_observations.csv` (признаки) и `*_targets.csv` (target `meanRaUe`)
   с ключами `realizationId, windowId`; роль реализации — `*_split.csv`.
2. Обучение и выбор моделей — в Python.
3. Обратно в ядро модель подключается функцией-оценщиком: `opts.estimator = @(features) ...`, где
   `features` — таблица одной строки со столбцами `nbiot.dataset.featureSchema().inputNames`.
   Ядро само проверяет оценку и применяет решение по порогам политики.

## 6. Тесты

`tests/Test*.m` — `matlab.unittest`; запуск: `startupProject(); runtests('tests')` (долго — в фоне)
или один файл. Тесты, требующие только Windows, отсутствуют. `tests/fixtures/` — сохранённые сигналы
для проверок DL; `tests/helpers/` — общие фикстуры.
