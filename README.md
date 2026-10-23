# NB-IoT: интеллектуальная система анализа коллизий случайного доступа (проект 2510)

MATLAB-симулятор NB-IoT соты с физической WAVEFORM-моделью (LTE Toolbox), ML-оценкой нагрузки и
адаптивным управлением (Adaptive-P, Adaptive-RA/DT) в сравнении со статической конфигурацией.
Заказчик: МИЭМ / ДЭИ.

Код основан на прототипе NB-IOT-4 v4.0.0 (ADR-004 в `docs/DECISIONS.md`); его проектная документация —
`docs/architecture.md`, `docs/model-profile.md`, `docs/metrics-contract.md` и др.

Файлы AI-агентов (CLAUDE.md, `.claude/`, `agent-config/`, `.mcp.json`, `tools/`, `docs/TOOLS.md`) в git не
хранятся — см. `.gitignore`.

## Запуск (MATLAB R2025b + LTE Toolbox, корень проекта)

```matlab
startupProject();          % пути
startNBIoT('check');       % проверка установки и калибровки NPRACH
r = runSingleUe();         % 1 устройство, 5 с модели: ожидается 1 доставленный пакет
startNBIoT();              % GUI-демо
results = runtests('tests');  % полный набор тестов (долго)
```

## Быстрый старт для команды

1. Установить MATLAB с LTE Toolbox (+ Communications, Statistics and ML, Parallel Computing).
2. Поставить MATLAB MCP Server и скиллы в проект: `bash setup-matlab-tools.sh` (подробно — `docs/TOOLS.md`).
3. Один раз: `cd ~/Разное/Work/NB-IOT-my && bash install-agent-config.sh` — копирует субагентов
   и проектный скилл из `agent-config/` в `.claude/`.
4. `claude` — агент прочитает `CLAUDE.md` автоматически.
5. Первая фраза агенту: «Прочитай PROGRESS и продолжай по ROADMAP».

## Документы

| Файл | Зачем |
|---|---|
| `CLAUDE.md` | правила для агентов, рабочий цикл, распределение ролей |
| `docs/TZ.md` | ТЗ в markdown (исходник — `docs/TZ_original.pdf`) |
| `docs/TOOLS.md` | тулбоксы, MCP, скиллы, субагенты — что, зачем, как |
| `docs/ROADMAP.md` | этапы доработки v4 до ТЗ |
| `docs/PROGRESS.md` | текущий статус (обновляется каждую сессию) |
| `docs/DECISIONS.md` | архитектурные решения, не заданные в ТЗ |
| `agent-config/agents/` → `.claude/agents/` | субагенты: simulator-engineer, data-scientist, researcher, verifier |
| `agent-config/skills/nbiot-project-rules/` → `.claude/skills/` | конвенции кода проекта |
| `install-agent-config.sh` | копирует `agent-config/` в `.claude/` |

## Полезные фразы для управления агентами

- «Продолжи с того места, где остановились» — агент читает PROGRESS.
- «Используй simulator-engineer: реализуй CellLayout по ТЗ §10, тесты по §31».
- «Отдай этап 1 на проверку verifier».
- «Researcher, собери еженедельный отчёт за неделю N».
- «Запиши решение в DECISIONS: …».
- «Обнови PROGRESS и закоммить».
