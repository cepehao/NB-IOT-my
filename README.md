# NB-IoT: ядро симулятора анализа коллизий случайного доступа (проект 2510)

MATLAB-симулятор соты NB-IoT с физической WAVEFORM-моделью радиоинтерфейса (LTE Toolbox): NPRACH,
NPUSCH, NPDCCH/NPDSCH, полная процедура случайного доступа, передача данных с проверкой CRC,
контроллер со стратегиями Static, Adaptive-P и Adaptive-RA/DT, KPI и датасет для обучения моделей.
Заказчик: МИЭМ / ДЭИ.

Этот репозиторий — **только ядро симулятора**, без графического интерфейса. Его используют из
MATLAB-скриптов: моделируют сценарии, считают KPI, выгружают датасет. Модели оценки нагрузки обучаются
в Python и подключаются к ядру как функция-оценщик. GUI-приложение — отдельное направление.
Код основан на прототипе NB-IOT-4 v4.0.0 (`docs/DECISIONS.md`, ADR-004, ADR-006, ADR-007).

## Требования

MATLAB R2025b, LTE Toolbox. Для параллельных серий — Parallel Computing Toolbox.

## Запуск (корень проекта)

```matlab
startupProject();                                  % пути
r = runSingleUe();                                 % проверка: 1 устройство, доставлен 1 пакет
cfg = nbiot.config.defaultConfig();                % параметры (ТЗ §10, §13, §30)
cfg = nbiot.phy.nprach.loadCalibration(cfg, fullfile(pwd,'results','nprach-calibration.mat'));
result = nbiot.runExperiment(cfg);                 % один прогон Static
nbiot.results.saveResult(result, fullfile(pwd,'results','run'));   % MAT + CSV
results = runtests('tests');                       % тесты (долго)
```

Подробно — **[docs/SIMULATOR_GUIDE.md](docs/SIMULATOR_GUIDE.md)**: что делает каждый файл, как устроен
прогон, что лежит в результате, как подключить модель.

## Документы

| Файл | Зачем |
|---|---|
| `docs/SIMULATOR_GUIDE.md` | Гайд по ядру и всем файлам |
| `docs/TZ.md` | ТЗ (исходник — `docs/TZ_original.pdf`) |
| `docs/ROADMAP.md` | Этапы доработки |
| `docs/PROGRESS.md` | Текущий статус |
| `docs/DECISIONS.md` | Решения, не заданные в ТЗ |
| `docs/model-profile.md`, `docs/architecture.md`, `docs/metrics-contract.md` | Профиль модели, архитектура и определения KPI (из v4) |

Файлы AI-агентов (CLAUDE.md, `.claude/`, `agent-config/`, `.mcp.json`, `tools/`, `docs/TOOLS.md`) в git не
хранятся — см. `.gitignore`. Установка MCP и скиллов для агентов — `bash setup-matlab-tools.sh`.
