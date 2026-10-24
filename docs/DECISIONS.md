# DECISIONS — журнал архитектурных решений (ADR)

> Любое решение, которого нет в ТЗ явно (выбор модели канала, окна BACKOFF, порогов детектора и т.п.),
> записывается сюда **до** реализации. Формат: номер · статус · контекст · решение · последствия · ссылка на ТЗ.
> Статусы: `proposed` (предложено агентом) → `accepted` (подтверждено человеком) / `rejected`.
> Агент может реализовывать `proposed`, но обязан сообщить о нём пользователю.

---

## ADR-000 · accepted · Язык и платформа
- Контекст: команда рассматривала Julia; ТЗ §51 требует MATLAB для основной модели и WAVEFORM.
- Решение: ядро, PHY, контроллер, GUI — MATLAB + LTE Toolbox. Julia/Python — только `aux/`
  для вспомогательного анализа. Подтвердить у заказчика, если Julia всё же нужна.
- ТЗ: §1, §51.

## ADR-001 · accepted · Окружение
- MATLAB: R2025b (25.2.0.2998904), Java не включена (MCP-сессия)
- LTE Toolbox: 25.2
- Communications Toolbox: 25.2
- Statistics and ML Toolbox: 25.2
- Parallel Computing Toolbox: 25.2, локальный кластер `parcluster('local')`: 12 воркеров
- Также есть: 5G Toolbox, DSP System, Signal Processing, Deep Learning, MATLAB Test, MATLAB Report Generator (25.2)
- ОС / CPU / RAM: macOS 15.3.1 / Apple M4 Pro, 12 ядер / 24 ГБ
- Источник: `detect_matlab_toolboxes` (MATLAB MCP Server v0.15.0), 2026-10-23.
- MCP/скиллы ставятся только на уровне проекта (`setup-matlab-tools.sh`, `.mcp.json`, `.claude/skills`),
  без глобальной установки toolkit.

## ADR-002 · accepted · API LTE Toolbox для NB-IoT (R2025b, проверено через MCP 2026-10-23)
- **NPRACH:** `[w,info,grid] = lteNPRACH(ue,chs)`, `info = lteNPRACHInfo(ue,chs)`,
  `[indout,offset,detinfo] = lteNPRACHDetect(ue,chs,waveform[,threshold])` (с R2023a).
  - `ue`: `NNCellID` (0…503), `NBULSubcarrierSpacing` ('3.75kHz'|'15kHz' — влияет на частоту
    дискретизации выхода), `Windowing` (опц.).
  - `chs`: `NPRACHFormat` ('0'|'1'|'2'), `Periodicity` (мс; 40…2560 для 0/1), `SubcarrierOffset`
    (0,2,12,18,24,34,36), `NumSubcarriers` (12,24,36,48), `NRep` (1…128), `StartTime` (8…1024 мс,
    опц.), `NInit` (0…NumSubcarriers−1 — **это и есть «номер преамбулы»**), `NPRACHPower` (дБ, опц.).
  - Формат 0, 15 kHz UE: Δf преамбулы 3750 Гц, Nfft 512, fs = 1.92 МГц; waveform длиной
    Periodicity·fs (80 мс → 153 600 отсчётов, в основном нули до/после преамбулы).
  - `lteNPRACHDetect` — алгоритм «Differential Processing With Minimum Combinations»; возвращает
    **только сильнейший** NInit, но `detinfo.DetectionPeaks` содержит пик для **каждого** NInit,
    `detinfo.DetectionThreshold` — порог (по умолчанию ≈0.025 для конфигурации ниже).
  - Проверено (seed 42, формат 0, 48 поднесущих, NRep 1, SNR 0 дБ): два UE NInit=0 и NInit=17
    (−6 дБ, сдвиг 20 отсчётов) → пики 0.66 и 0.34, остальные ≤0.016 — оба различимы.
  - Время (M4 Pro, 1 поток): генерация преамбулы ≈7 мс, детекция одного окна 80 мс ≈160 мс.
- **NPUSCH / UL-SCH:** `lteNULSCH`, `lteNULSCHDecode` (выдаёт `BLKCRC`), `lteNPUSCH`,
  `lteNPUSCHDecode`, `lteNPUSCHIndices`, `lteNPUSCHDRS`, `lteNPUSCHDRSIndices`;
  поля `chs`: `NPUSCHFormat`, `NBULSubcarrierSet`, `NRU`, `NRUsc`, `NULSlots`, `NRep`, `Modulation`,
  `RV`, `RNTI`; `ue`: `NNCellID`, `NSlot`, `NFrame`, `NBULSubcarrierSpacing`.
- **NPDCCH / NPDSCH:** `lteNPDCCH`, `lteNPDCCHDecode`, `lteNPDCCHIndices`, `lteNPDSCH`,
  `lteNPDSCHDecode`, `lteNPDSCHIndices`, `lteNDLSCH`, `lteNDLSCHDecode`; `enb`: `NNCellID`,
  `NBRefP`, `NFrame`, `NSubframe`. Функций `lteNDCI*` нет; v4 упаковывает поля DCI N0/N1 сам
  (`+phy/+npdcch/packDci.m`) и кодирует через `lteDCIEncode`/`lteDCIDecode`, RAR/Msg4 — свой формат битов.
- **Общие:** `lteSCFDMAModulate/Demodulate`, `lteOFDMModulate/Demodulate`, `lteNBResourceGrid`,
  `lteNRS`, `lteNPSS`, `lteNSSS`, `lteNPBCH`, `lteCRCEncode/Decode`, `lteFadingChannel`,
  `lteFrequencyOffset`.
- **Примеры MathWorks (`openExample('lte/<имя>')`):** `NPRACHDetectionExample`,
  `DetectNPRACHPreambleWithTimingOffsetExample`, `NPUSCHBlockErrorRateExample`,
  `NPDSCHBlockErrorRateExample`, `NBIoTUplinkWaveformGenerationExample`,
  `NBIoTDownlinkWaveformGenerationExample` — опорные для этапов 3–5.
- **Сделано в v4 самостоятельно (ADR-004):** многопреамбульный детектор поверх `DetectionPeaks` (порог по целевой P_FA),
  классификатор detection/miss/логическая и физическая коллизия/capture/false alarm, сложение
  сигналов UE с задержкой/CFO/каналом, RAR/DCI-биты, contention resolution.
- **Следствия для производительности:** базовые преамбулы кэшировать по NInit (≤48 вариантов) и
  только сдвигать/масштабировать; детекция — одна на окно NPRACH, не на UE. 5 с / 80 мс ≈ 62 окна ×
  ≈0.16 с ≈ 10 с на прогон только на детекцию → реалистично для ≥100 реализаций на `parfor` (12 воркеров).

## ADR-003 · superseded (ADR-005) · Конфигурация NPRACH
- Предлагалось: формат 0, CE0, NRep 1, 48 поднесущих. Заменено профилем v4: формат 0, период 80 мс,
  StartTime 8 мс, **12 поднесущих** (NInit 0–11), NRep 1, CE0 — см. ADR-005 и `docs/model-profile.md`.

## ADR-004 · accepted · Основа кода — NB-IOT-4 v4.0.0
- Контекст: в команде уже был прототип (NB-IOT-4 v4.0.0, 20.10.2026, ~46 тыс. строк MATLAB, ~130 тестов),
  написанный по тому же ТЗ (PDF совпадает побайтово с `docs/TZ_original.pdf`).
- Решение (пользователь, 2026-10-23): перенести код, тесты, конфиги, отчёты, `verification/` и документы
  v4 в корень репозитория и дорабатывать его; история коммитов v4 не переносится. Не перенесены:
  Windows-ярлыки `.cmd` и корневые README/AGENTS/RELEASE/PACKAGE-MANIFEST (лежат в `docs/legacy-v4/`),
  дубль PDF ТЗ, локальные результаты прогонов.
- Проверка после переноса (MATLAB R2025b, macOS): `startNBIoT('check')` OK; `runSingleUe` 1 UE —
  delivered 1/1, 12,5 с; результаты полного набора тестов — в PROGRESS.
- Последствия: наш план «с нуля» (ROADMAP v1) заменён планом доработки; конвенции кода — по факту v4
  (скилл `nbiot-project-rules` переписан). `verification/` и инфраструктура приёмки v4 оставлены, так как
  на них ссылаются тесты; упрощение — отдельная задача.

## ADR-005 · accepted · Профиль модели v4 — базовый профиль проекта
- Источник: `docs/model-profile.md`, `docs/architecture.md` (решения v4, согласованные с владельцем).
- Ключевое: одна сота, неподвижные UE; Cat-NB1, Standalone, FDD, 1×1; 3D-расстояние; path loss
  log-distance (d0 = 10 м, n = 3,5); shadowing σ 8/10 дБ; penetration 0/20 дБ; fading — 3 отвода
  Rayleigh (0/0,3/0,9 мкс; 0/−3/−6 дБ), постоянный в реализации; CFO — усечённая N(0, 50²) в ±200 Гц;
  все UE в CE0; мощность UE 23 дБм без power control.
- NPRACH: формат 0, 80 мс, StartTime 8, 12 поднесущих, NRep 1; многопреамбульный детектор — банк
  шаблонов всех NInit с перебором CFO/задержки, порог из калибровки `results/nprach-calibration.mat`.
- NPUSCH: Msg3 TBS 88, данные TBS 256 (MCS 4, I_RU 3), ACK 1 бит; HARQ — 1 процесс, до 4 передач, RV 0/2/0/2.
- RA: 8 попыток Msg1, BACKOFF равномерно 0–256 мс, RAR window pp10, contention timer pp16.
- RA/DT: доля «полоса × время» на окне 500 мс отдельно в UL и DL; Static: P = 1, RA/DT = 10/90.
- Датасет: окна 500 мс; target — среднее число UE в RA-состояниях; split 70/15/15 по реализациям.
- Adaptive: пробные пороги `configs/adaptiveDefaults.m` (`docs/adaptive-control.md`) — **proposed**,
  подбирать по данным.

## ADR-006 · accepted · Репозиторий — только ядро симулятора
- Контекст (пользователь, 2026-10-24): у проекта два направления — научное (сценарии моделирования и
  датасеты из MATLAB, обучение моделей) и продуктовое (GUI-приложение с моделями в управлении). Чтобы вести
  их рационально, ядро симулятора отделено от остального.
- Решение: в репозитории остаётся только ядро (`src/+nbiot`: модель, PHY, канал, RA, планировщик,
  контроллер с тремя политиками, KPI, датасет, сохранение), конфигурации, примеры и тесты ядра.
  Удалены (есть в истории git): GUI (`apps/`, `+ui`, точки входа демо), обучение и допуск моделей в MATLAB
  (`+ml`), обвязка v4 (`verification/`, `+experiments`: реестр реализаций, бюджеты, чекпоинты, внешние
  стадии, PowerShell), старые скрипты серий `experiments/`, документы v4 про приёмку/GUI/ML.
- Изменения API: `NBIoTSimulator(cfg, scenario, controllerOptions)` и `runExperiment(cfg, scenario,
  controllerOptions)` без бюджета времени; калибровка — `nbiot.phy.nprach.loadCalibration`;
  `saveResult(result, folder)` пишет MAT + CSV без манифестов и хешей; чекпоинты и живая радиодиагностика
  для GUI удалены.
- Гайд по файлам: `docs/SIMULATOR_GUIDE.md`.

## ADR-007 · accepted · Обучение моделей в Python; подключение к ядру через оценщик
- Решение (пользователь, 2026-10-24): модели оценки нагрузки обучаются в Python. Ядро от Python не
  зависит.
- Интерфейс: для Adaptive-* `controllerOptions.estimator` — функция `оценка = f(признаки)`, где признаки —
  таблица одной строки со столбцами `featureSchema().inputNames` (только наблюдения BS, ТЗ §40); оценка —
  meanRaUe. Ядро проверяет оценку (`nbiot.controller.estimateLoad`) и решает по порогам политики.
- Датасет для обучения — CSV из `saveResult`: `*_observations.csv`, `*_targets.csv`, `*_split.csv`.
- Открыто: где живёт код на Python и как модель исполняется в MATLAB (pyrun / ONNX / экспорт параметров).

## Шаблон

```
## ADR-NNN · proposed · Заголовок
- Контекст:
- Варианты:
- Решение:
- Последствия:
- ТЗ:
```

## Список решений, которые предстоит принять
Закрыты ADR-005 (профиль v4): path loss, fading, coverage class, порог NPRACH, contention resolution,
BACKOFF, HARQ, окно датасета, разбиение выборок, Static.

Открыто (см. также `docs/requirements-decisions.md`):
- Стратегия ускорения и целевое время прогона (профилирование — первая задача)
- Матрица опытов, число реализаций, обязательность 5000 UE, вычислительный бюджет
- Научные пороги качества ML и правило выбора модели
- Пороги и гистерезис Adaptive-P / Adaptive-RA/DT по реальным данным
- App Designer `.mlapp` vs программный `uifigure`
- Что из инфраструктуры приёмки v4 (`verification/`, внешние стадии, бюджеты) оставить
