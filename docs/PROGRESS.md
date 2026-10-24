# PROGRESS — текущий статус

> Обновляется агентом **в конце каждой сессии**. Новые записи — сверху.
> Формат: дата · этап · сделано · в работе · следующий шаг · проблемы/вопросы.

## Текущее состояние

- **Текущий этап:** 1 — проектирование доработки ядра (ROADMAP). Репозиторий — только ядро симулятора.
- **Следующий шаг:** brainstorming научного направления: какие сценарии и датасеты нужны для обучения,
  матрица опытов → спецификация и план этапа 2 (производительность).
- **Блокеры:** нет. Открытые вопросы — CLAUDE.md §7.

## Статус контрольных точек (ТЗ §54)

| # | КТ | Статус |
|---|---|---|
| 1 | Сценарий развертывания | ⬜ |
| 2 | Генератор нагрузки | ⬜ |
| 3 | State machine | ⬜ |
| 4 | Link budget | ⬜ |
| 5 | NPRACH waveform | ⬜ |
| 6 | Collision analysis | ⬜ |
| 7 | RA | ⬜ |
| 8 | NPUSCH | ⬜ |
| 9 | Датасет | ⬜ |
| 10 | ML | ⬜ |
| 11 | Controller | ⬜ |
| 12 | Adaptive-P | ⬜ |
| 13 | Adaptive-RA/DT | ⬜ |
| 14 | Static | ⬜ |
| 15 | Численные эксперименты | ⬜ |
| 16 | Сравнение | ⬜ |
| 17 | GUI | ⬜ |
| 18 | Итоговый отчёт | ⬜ |

Легенда: ⬜ не начато · 🟨 в работе · 🟦 на проверке у verifier · ✅ принято

## Журнал сессий

### 2026-10-24 · выделение ядра симулятора (ADR-006, ADR-007)
- Решение пользователя: два направления — научное (ядро из MATLAB-скриптов, датасеты, обучение моделей
  в Python) и продуктовое (GUI с моделями, отдельно). Репозиторий оставлен только с ядром.
- Удалено (в истории git): `apps/`, `+ui`, `startNBIoT`/`startDemo`/`showRadioLog`; `+ml`; `+experiments`
  (реестр, бюджеты, чекпоинты, внешние стадии, допуск); `verification/`; `experiments/`; конфиги
  `localDevelopment`, `mlTrainingDefaults`; документы v4 про приёмку/GUI/ML; 75 тестов этих компонентов.
- Ядро отвязано: `NBIoTSimulator(cfg, scenario, controllerOptions)` без бюджета времени, живой
  радиодиагностики и чекпоинтов; контроллер Adaptive-* принимает оценщик `controllerOptions.estimator`
  (`nbiot.controller.prepareRuntime`, новый `estimateLoad`); калибровка — `nbiot.phy.nprach.loadCalibration`;
  `saveResult` — простой MAT + CSV; `calibrateNprach` без обвязки бюджета.
- Тесты ядра: **196 passed / 0 failed за 116 с** (`matlab -batch`, macOS). Code Analyzer — 0 синтаксических ошибок.
- Новый гайд `docs/SIMULATOR_GUIDE.md`: устройство прогона, назначение каждого файла, поля результата,
  связь с Python. Обновлены CLAUDE.md, README, ROADMAP, DECISIONS (ADR-006, ADR-007), скилл, субагенты.

### 2026-10-23 · исправление тестов и чистота репозитория
- 7 тестов, работающих только в Windows (.NET System.IO, PowerShell-оркестратор, пути с `\`), теперь
  пропускаются через assumption на других ОС, а не падают (на Windows поведение прежнее).
- 3 GUI-теста приведены к текущим подписям интерфейса v4 («Этап: IDLE…», «Логические коллизии:»,
  строка «Пакеты:» ищется без привязки к позиции).
- `TestNBIoTAppDialogs`: проверка размеров в пикселях пропускается в `matlab -batch` (окно без экрана не
  раскладывается) — нестабильность устранена; структура сетки проверяется всегда.
- Правило 12 (нет файлов в проекте): тест GUI писал PNG в `verification/local` → теперь во временную
  папку; `TestStage2Acceptance` оставлял `tp*.log` в `verification/completion/stage-2` → удаляет; добавлен
  `PathFixture` (тест не зависит от порядка). Из репозитория удалены попавшие в init commit артефакты:
  `verification/local/gui-radio-diagnostics-preview-20261014.png`, `verification/completion/stage-2/tp*.log`,
  `tests/verification/completion/evidence.json` (остаток прогона из поставки v4). В `.gitignore` — `*.log`.
- Правило 4: `+ml/trainLoadModels.m` больше не трогает глобальный `rng` — `TreeBagger` получает свой поток
  (`statset('Streams', …)`); модели идентичны прежним (проверено), ML-тесты 58/58.
- Остаётся: «магическое» число 1920 отсчётов/тик в PHY и канале (правило 7) — вынести при оптимизации
  (этап 2); обвязка v4 вне ТЗ, состояния UE vs ТЗ §12 — решения этапа 1.

### 2026-10-23 · правила и документирование кода
- Правила (CLAUDE.md §2, п. 11–13; скилл `nbiot-project-rules` §8; субагенты): строго по ТЗ; никаких
  отчётов/логов/временных файлов в репозитории (выходы — только `results/`); обязательное документирование
  кода на русском (шапка файла: назначение, раздел ТЗ, входы/выходы, единицы; H1 функций; «зачем» у
  неочевидной логики). `verifier` проверяет документацию и `git status`.
- Комментарии добавлены без изменения кода (проверено: строки кода совпадают, Code Analyzer — 0 синтаксических
  ошибок в 172 файлах): подробно — `NBIoTSimulator`, конфиг, сценарий, случайность, канал, PHY (NPRACH,
  NPUSCH, NPDCCH, NPDSCH), RA, трафик, планировщик, контроллер, датасет, KPI, обучение ML; русская шапка —
  остальные файлы `src/`, `apps/`, `configs/`, `examples/`, `experiments/`. Инфраструктура v4, не требуемая
  ТЗ, помечена в шапке «[инфраструктура v4 …]» — кандидаты на удаление на этапе проектирования.
- Находка для этапа 3: при Static квота RA в DL ≈ 37 подкадров на окно 500 мс, а RAR или Msg4 занимают
  ≈ 4 подкадра (NPDCCH 2 + NPDSCH 2) → лишь несколько завершённых RA за окно. Вероятная причина 6/100
  доставок в старом пилоте (проверить прогоном). Также: `RandomSources.stream` создаёт RandStream на каждый
  вызов, UL-сигналы в канале пересчитываются (свёртка) при каждом приёме — кандидаты для этапа 2.
- Отклонение от ТЗ §12 (записано в шапке `DeviceStore`): состояния UE названы иначе и частично слиты
  (WAIT_RAR, WAIT_MSG4, DATA, WAIT_RECEIPT вместо RA_TX/RA_PROCESSING/MSG3_TX/…/DATA_TX; DONE/DROPPED —
  статус пакета). Решить на проектировании: привести к ТЗ или зафиксировать соответствие в ADR.

### 2026-10-23 · этап 0 · чистка проекта и .gitignore
- Удалено: `reports/` (сохранённые отчёты v3 на 1/100 UE, ~91 МБ) и просмотрщики `viewSaved100.m`,
  `viewDevices100.m`, режим `startNBIoT('saved100')`; корневой `test.m`; `docs/legacy-v4/`; 31 исторический
  документ v4 (аудиты, статусы, handoff, install v3/v4, отчёты этапов) и планы v4 `docs/superpowers/`;
  из `verification/` — логи, свидетельства, CSV/MAT/PNG, история v3/v4 (код обвязки оставлен).
  Тесты, проверявшие только удалённое: `TestV4Package`, `TestLocalCompletionPipeline`,
  `TestRadioDiagnosticsSavedEvidence`, 2 метода в `TestV4Startup` (→ `TestStartup`) и `TestSavedReportOverview`.
- Скрипты демо встроены в корневые `startDemo.m` и `showRadioLog.m` (раньше вызывали `verification/local/meeting-*`).
- `.gitignore` переписан: файлы AI-агентов (CLAUDE.md, AGENTS.md, `.claude/`, `agent-config/`, `.mcp.json`,
  `tools/`, скрипты установки, `docs/TOOLS.md`, `docs/superpowers/`), результаты (кроме калибровки), `data/`,
  `logs/`, `work/`, автосохранения MATLAB, ОС/редакторы. Под git остаётся ~4 МБ.
- Тесты: полный набор `matlab -batch` — **657 passed / 11 failed / 6 incomplete из 668, 654 с**.
  Падения — те же унаследованные (7 Windows/обвязка, 3 устаревших GUI-текста) + `TestNBIoTAppDialogs/
  savedKpiPickerComparesSelectedSeries` — нестабилен только в `-batch` (раскладка окна), в обычной сессии проходит.
  `startNBIoT('check')`, `TestStartup` 3/3, `runSingleUe` delivered 1/1.

### 2026-10-23 · этап 0 · импорт NB-IOT-4 v4.0.0
- Сделано: код, тесты, конфиги, примеры, эксперименты, `reports/`, `verification/`, калибровка NPRACH и
  документы v4 перенесены в корень (ADR-004); корневые файлы выпуска — `docs/legacy-v4/`; папка
  NB-IOT-4 перемещена в Корзину. Профиль модели v4 принят (ADR-005), ADR-003 заменён. Переписаны
  CLAUDE.md (состояние, структура, запуск, открытые вопросы), скилл `nbiot-project-rules` (конвенции v4),
  ROADMAP (доработка вместо разработки с нуля), README. `startupProject` вызывает `setupProject`.
- Проверка (macOS, R2025b): `startNBIoT('check')` OK; `runSingleUe` 1/1 delivered, 12,5 с.
- Полный набор `runtests('tests')` в `matlab -batch`: **663 passed / 13 failed / 9 incomplete из 676, 726 с**.
  Исправлены 2 теста `TestRadioProtocol` (сравнивали служебный `lifecycleLog`) → 13/13.
  Разбор 13 падений — ни одного в физике/протоколе/ML:
  - 8 — только Windows/обвязка: .NET `System.IO.FileStream` (TestCheckpointFileHash, TestLoadProbe,
    TestSimulationCheckpoint), переменные окружения от PowerShell-оркестратора (TestCheckpointProcessReader/
    Writer, TestLocalCompletionPipeline), отсутствующий `.ps1` (TestExternalRegistryTransitions),
    путь с `\` (TestFinalAcceptance);
  - 3 — GUI-тексты устарели относительно интерфейса v4 (TestNBIoTAppAdaptive, …PauseResumeEquivalence,
    …UeDetails: ждут «Этап: ожидание», а UI выводит «Этап: <код> — …»); падают и в окне MATLAB;
  - 1 — файл свидетельства отсутствовал уже в поставке v4 (TestRadioDiagnosticsSavedEvidence);
  - 1 — из-за переноса: `PACKAGE-MANIFEST.json` в `docs/legacy-v4/` (TestV4Package, проверка ZIP-выпуска v4).
- Не сделано: эти 13 тестов не исправлены (решить вместе с упрощением инфраструктуры v4); git — в репозитории
  остался прежний коммит f7f71d6 (до импорта), init commit делает владелец.

### 2026-10-23 · этап 0 · завершение
- Сделано: MCP `matlab` подключён; ADR-001 (R2025b, все тулбоксы 25.2, 12 воркеров) — accepted;
  ADR-002 (NB-IoT API LTE Toolbox, сигнатуры, примеры, замеры времени) — accepted;
  ADR-003 (формат 0, CE0, NRep 1, 48 поднесущих) — proposed; каркас `src/+nbiot`, `tests/`,
  `experiments/`, `results/`, `data/models/`, `app/`; `startupProject.m`, `runAllTests.m`;
  smoke-тест `tests/EnvironmentTest.m` (вкл. NPRACH loopback, seed 42); `git init`, первый коммит.
- Тесты: 3 passed / 0 failed (`runAllTests()`).
- Главная находка: `lteNPRACHDetect` отдаёт только сильнейшую преамбулу, но `DetectionPeaks` по
  всем NInit позволяет строить многопреамбульный детектор; функций DCI для NB-IoT нет.
- Не сделано: папка `aux/` не создана (вопрос о переименовании из-за Windows открыт); вопрос
  хранения `data/models/*.mat` в git открыт.

### 2026-10-23 · этап 0 · окружение (проектная установка)
- Сделано: `install-agent-config.sh` → `.claude/agents`, `.claude/skills/nbiot-project-rules`;
  MATLAB MCP Server v0.15.0 (macos-arm64) скачан в `tools/bin/`; toolkit клонирован в
  `tools/matlab-agentic-toolkit` (коммит 7c28d73), 17 скиллов скопированы в `.claude/skills/`;
  добавлен `setup-matlab-tools.sh`; `.gitignore` дополнен `tools/`; имена скиллов в субагентах и
  TOOLS.md приведены к актуальным (`matlab-debug-code`, `matlab-review-code`, `matlab-build-app`).
- Найдено: MATLAB R2025b, в `toolbox/` есть lte, comm, stats, parallel (версии — через MCP);
  Mac M4 Pro, 12 ядер, 24 ГБ RAM, macOS 15.3.1.
- Замечания: папка `aux/` недопустима на Windows (зарезервированное имя) — предложено переименовать;
  `.gitignore` правило `data/**/*.mat` исключает и `data/models/*.mat` — решить, хранить ли модели в git.

### 2026-10-23 · этап 0
- Сделано: созданы файлы для агентов (CLAUDE.md, docs/TZ.md, TOOLS.md, ROADMAP.md, PROGRESS.md,
  DECISIONS.md, субагенты, проектный скилл).
- Следующий шаг: см. «Текущее состояние».
- Вопросы: см. CLAUDE.md §7.
