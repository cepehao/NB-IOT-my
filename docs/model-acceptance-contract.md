# Контракт допуска Adaptive-модели

Этот контракт отделяет сохранённую модель от научного допуска. MAT-файл остаётся неизменным со статусом `development`; проверка допуска не запускает расчёт и не меняет policy, реестр или evidence.

## Файлы и интерфейсы

- `prepareModelAcceptance(options)` создаёт новый переносимый JSON со статусом `candidate`. Все 13 путей evidence обязательны; рядом с MAT автоматически ищется одноимённый JSON sidecar. Каждый путь должен вести внутрь каталога выходного candidate. Существующий output не заменяется.
- `nbiot.ml.checkModelAcceptanceEvidence(acceptance, rootFolder)` проверяет структуру, относительные ссылки и SHA-256, связи между manifest/freeze/evaluation, split и role ID, строки dataset и метрики. Checker загружает только переменную `data` из `dataset.mat` и сверяет её manifest, назначения строк, observations, targets и diagnostics с экспортами. Он не загружает MAT-файлы модели или отдельных расчётов и не предоставляет права запуска.
- `publishModelAcceptance(options)` принимает только отдельный review JSON с решением `accepted` или `rejected`. Review должен ссылаться на тот же `evidenceDigest` и hash протокола. Результат создаётся новым файлом через временную запись и readback; исходный candidate и его evidence не переписываются.
- `nbiot.ml.validateModelAcceptance(path, modelFile, policy, execution, comparisonIds, cfg)` — публичная проверка с обязательным шестым аргументом `cfg`. Она ничего не запускает и ничего не записывает. Для допуска требуются `external-machine`, роль `final-comparison`, точное попадание конфигурации в scope и полный execution budget.

## Переносимые ссылки и identity

Acceptance JSON v1 содержит относительные refs `file` + `sha256` для модели и sidecar, dataset, manifest/artifacts, training manifest, metrics, source/calibration, registry, policy, protocol и evaluation. Ref с абсолютным путём или выходом за корень пакета отклоняется. Checker разрешает внутренние ссылки manifest только после канонизации пути и проверки, что они остаются внутри того же корня.

`evidenceDigest` вычисляется по schema, именам и hash всех refs, split IDs, `policyTuningIds`, scope, protocol SHA-256 и canonical `policySha256`. Поля `status` и `review` в digest не входят. Поэтому reviewer видит, к какому неизменному набору файлов относится решение.

## Научные и локальные данные

`evidenceKind` определяется по происхождению dataset, training manifest, sidecar, freeze/evaluation и fixture-флагам inputs. Пользовательский label сам по себе не меняет тип данных. Fixture может пройти структурную проверку для тестов, но public admission и publish отвергают fixture независимо от `status` и review. Флаги подтверждения allocations и явных experiment roles обязаны соответствовать типу evidence и в dataset, и в training manifest.

Для каждой строки `manifest.inputs` ссылка `resultFile` должна быть безопасным относительным путём внутри candidate-пакета. Рядом с ним checker требует `case-complete.json`, сверяет его hash с `markerSha256`, проверяет source/calibration identity и хеши результата, `_summary.csv`, `_observations.csv` и `_targets.csv`. Эти файлы должны быть включены в пакет; абсолютные пути и ссылки за его пределы не принимаются. Значения aggregate `observations.csv` и `targets.csv` сверяются с таблицами `data.observations`/`data.targets` внутри dataset MAT, а исходные case observations/targets — с соответствующими строками MAT по ключам окна. Для row map, aggregate tables, case exports и диагностики запрещены повторяющиеся ключи окна `(realizationId, windowId, startTick, endTick)`. Диагностика сверяется с row map и сохранённой таблицей; `sampleCount`, `idCount` и MAE/RMSE проверяются на согласованность.

Перед включением настоящего набора в candidate его нужно подготовить как переносимые package-relative evidence: собрать результаты, completion markers и требуемые CSV рядом внутри пакета и связать их в manifest. Подготовка/сбор такого набора для внешнего этапа остаётся отдельной работой T1; существующие локальные fixture не доказывают готовность научных данных.

Численные пороги не назначаются программой. Protocol обязан содержать четыре конечных неотрицательных порога, явные strata и утверждение до открытия model-test. Checker повторно вычисляет детерминированного победителя по validation MAE (с зафиксированным порядком разрешения равенства), сверяет выбор замороженной модели с training manifest и sidecar, требует в freeze ровно те же четыре уникальных модельных артефакта и связывает каждый с его sidecar. Метрики evaluation сверяются с метриками по каждому split. Простого `passed=true` недостаточно. Review должен быть после завершённой evaluation и совпадать с digest и protocol hash.

Публичный admission дополнительно сверяет полный frozen policy с `adaptiveDefaults`, canonical policy digest, сохранённый model bundle, `candidate-training`, verified allocations, отсутствие fixture/final-comparison данных в training set, непересечение comparison IDs с train/validation/model-test/policy-tuning IDs и соответствие реальной конфигурации точному scope.

До передачи настоящих scientific evidence и review научная приёмка остаётся закрытой. Успешные локальные fixture-тесты проверяют только программные отказы и связи файлов; они не подтверждают качество модели. Runtime/sweep/GUI integration относится к отдельному шагу D4-I.
