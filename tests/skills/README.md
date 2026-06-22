# Регресс-тесты навыков

Snapshot-тестирование скриптов навыков: навык получает вход → генерирует файлы → результат сравнивается с эталоном.

Быстрые, файловые, без зависимости от платформы 1С.

## Запуск

```bash
node tests/skills/runner.mjs                                    # все кейсы
node tests/skills/runner.mjs cases/meta-compile                 # один навык
node tests/skills/runner.mjs cases/meta-compile/catalog-basic   # один кейс
node tests/skills/runner.mjs --verbose                          # подробный вывод (дерево)
node tests/skills/runner.mjs --update-snapshots                 # обновить эталоны
node tests/skills/runner.mjs --runtime python                   # запуск на PY-версиях
node tests/skills/runner.mjs --json report.json                 # JSON-отчёт
node tests/skills/runner.mjs --concurrency 4                    # ограничить параллельность
node tests/skills/runner.mjs --with-validation                  # + платформенная валидация
node tests/skills/runner.mjs --help                             # полный список опций
```

Exit code: 0 = все прошли, 1 = есть падения.

### Платформенная верификация снапшотов

```bash
node tests/skills/verify-snapshots.mjs --skill form-compile     # один навык
node tests/skills/verify-snapshots.mjs --case table             # один кейс
node tests/skills/verify-snapshots.mjs --help                   # полный список опций
```

Перепрогоняет навык из DSL кейса и грузит результат в 1С — отлавливает случаи, когда снапшоты обновили, но платформа уже не принимает выход.

## Интеграционные тесты

Помимо snapshot-кейсов есть многошаговые сценарии в `integration/<имя>.test.mjs` — цепочка навыков (init → compile → build → validate…), проверяющая что навыки работают вместе. Запуск:

```bash
node tests/skills/runner.mjs integration                      # все интеграционные
node tests/skills/runner.mjs integration/platform-partial     # один сценарий
```

Тест-модуль экспортирует `name`, `setup`, `steps` и опционально:

| Экспорт | Описание |
|---|---|
| `requiresPlatform` | `true` — нужен 1С (резолвится из `.v8-project.json`). Без платформы тест `○ skipped` |
| `engines` | Массив движков для **матрицы**: по умолчанию `['1cv8']`. `['1cv8','ibcmd']` — те же шаги прогоняются на обоих движках |

### Движковая матрица (1cv8 / ibcmd)

Навыки `db-*`/`epf-*` выбирают движок по имени exe в `-V8Path` (опт-ин: `ibcmd.exe` → ibcmd, иначе DESIGNER). Тест с `engines: ['1cv8','ibcmd']` прогоняется по разу на каждый движок: на ibcmd-проходе плейсхолдер `{v8path}` подставляется в `ibcmd.exe`, на 1cv8 — в каталог `bin` (авто-резолв `1cv8.exe`). Результаты помечаются суффиксом id: `… [1cv8]` / `… [ibcmd]`.

ibcmd-проход автоматически `○ skipped`, если рядом с `1cv8.exe` нет `ibcmd.exe`. Шаги тестов при этом **не меняются** — добавляется одна строка `export const engines`. Так контракт «операция держится на обоих движках» кодируется без дублирования сценария.

### Типы шагов

Шаг — это запуск навыка (`script` + `args` + опц. `input`/`validate`) либо один из вспомогательных:

| Поле шага | Действие |
|---|---|
| `script` + `args` | Запустить навык. `args` поддерживают плейсхолдеры `{workDir}`, `{inputFile}`, `{v8path}` и др. |
| `input` | JSON, передаётся навыку через temp-файл (`{inputFile}`) |
| `writeFile` + `content` | Записать файл (путь — плейсхолдеры) |
| `editFile` + `replace` + `with` | Подстановочная замена в файле (напр. вставить маркер). Падает, если паттерн не найден |
| `assertContains` + `expect` | Упасть, если файл не содержит подстроку (проверка round-trip) |
| `validate` | Доп. валидация навыком после шага (только с `--with-validation`) |

## Что делать при падении

1. Смотри **case id** в выводе — это путь к файлу кейса (можно перезапустить: `node runner.mjs <case-id>`)
2. Открой `.json` кейса — посмотри что на входе
3. Открой `snapshots/<кейс>/` — посмотри эталон
4. Если изменение **намеренное** (доработка навыка) — обнови эталон: `node runner.mjs <case-id> --update-snapshots`
5. Если **баг** — починить скрипт навыка и перезапустить тест

## Как добавить навык

1. Создать папку `tests/skills/cases/<имя-навыка>/`
2. Положить `_skill.json` — описание навыка для раннера
3. Добавить кейсы — по одному `.json` файлу на кейс

### Формат _skill.json

```json
{
  "script": "meta-compile/scripts/meta-compile",
  "setup": "empty-config",
  "args": [
    { "flag": "-JsonPath", "from": "inputFile" },
    { "flag": "-OutputDir", "from": "workDir" }
  ],
  "snapshot": {
    "root": "workDir",
    "normalizeUuids": true
  }
}
```

| Поле | Описание |
|---|---|
| `script` | Путь от `.claude/skills/`, без расширения. Раннер добавит `.ps1` (по умолчанию) или `.py` |
| `setup` | Фикстура: `"empty-config"`, `"base-config"`, `"none"`, `"fixture:<name>"` (из `fixtures/` папки навыка), `"external:<path>"` (реальная выгрузка, read-only, skip если недоступна) |
| `args` | Маппинг параметров навыка (см. ниже) |
| `snapshot` | Настройки сравнения: `root` (`"workDir"` или `"outputPath"`) и `normalizeUuids` |

### Значения `from` в args

| Значение | Что подставляется |
|---|---|
| `"inputFile"` | Путь к temp-файлу с `case.input` (JSON) |
| `"workDir"` | Рабочая директория (копия фикстуры) |
| `"outputPath"` | `workDir` + `case.outputPath` |
| `"workPath"` | `workDir` + значение из `params.<field>`. Поле указывается в `mapping.field` (по умолчанию `objectPath`) |
| `"case.<field>"` | Значение из `params.<field>` (приоритет) или корня кейса |
| `"switch"` | Флаг без значения (напр. `-Detailed`) |
| `"literal"` | Фиксированное значение из `mapping.value` |

## Как добавить кейс

Положить `.json` файл в папку навыка. Имя файла = имя кейса.

### Позитивный кейс (минимальный)

```json
{
  "name": "Простой справочник",
  "input": { "type": "Catalog", "name": "Валюты" }
}
```

Раннер проверит: exitCode=0 + выход совпадает со snapshot (если есть).

### С параметрами навыка

```json
{
  "name": "Обзор справочника",
  "params": { "objectPath": "Catalogs/Номенклатура" },
  "expect": { "stdoutContains": "Номенклатура" }
}
```

`params` — параметры для навыка. Используются через `case.<field>` и `workPath` в `_skill.json`.

`expect.stdoutContains` / `expect.stdoutNotContains` — строка **или массив строк**. Каждая подстрока проверяется на наличие (`stdoutContains`) или отсутствие (`stdoutNotContains`) в stdout навыка. Удобно для info-навыков: проверить, что нужная строка есть, а лишней — нет.

```json
{
  "name": "Представление типа у ПВХ",
  "setup": "external:C:/WS/tasks/cfsrc/erp_8.3.24",
  "params": { "objectPath": "ChartsOfCharacteristicTypes/ВидыСубконтоХозрасчетные" },
  "expect": {
    "stdoutContains": ["Представление типа: Вид субконто", "Представление объекта: Вид субконто"],
    "stdoutNotContains": "Представление списка:"
  }
}
```

### С дополнительными CLI-аргументами

```json
{
  "name": "Конфигурация с поставщиком",
  "params": { "name": "Бухгалтерия" },
  "args_extra": ["-Vendor", "Тест", "-Version", "2.0.1"]
}
```

`args_extra` — дополнительные аргументы, не описанные в `_skill.json`, передаются навыку как есть.

### С предварительными шагами

```json
{
  "name": "Добавление реквизита к справочнику",
  "preRun": [
    {
      "script": "meta-compile/scripts/meta-compile",
      "input": { "type": "Catalog", "name": "Контрагенты" },
      "args": { "-JsonPath": "{inputFile}", "-OutputDir": "{workDir}" }
    }
  ],
  "params": { "objectPath": "Catalogs/Контрагенты" },
  "input": { "operations": [{ "op": "add-attribute", "name": "ИНН", "type": "String", "length": 12 }] }
}
```

`preRun` — шаги подготовки перед основным навыком. Каждый шаг: `script` (путь без расширения), `input` (JSON), `args` (маппинг с `{workDir}` и `{inputFile}` плейсхолдерами).

### Кейс с реальной выгрузкой

```json
{
  "name": "Реальный справочник Номенклатура (БП)",
  "setup": "external:C:/WS/tasks/cfsrc/acc_8.3.24",
  "params": { "objectPath": "Catalogs/Номенклатура" },
  "expect": { "stdoutContains": "Номенклатура" }
}
```

`setup: "external:<path>"` — использует реальную выгрузку конфигурации 1С как read-only рабочую директорию (без копирования). Если путь недоступен — тест пропускается (`○ skipped`), не падает. Подходит для info/validate навыков, которые не модифицируют файлы.

### Негативный кейс

```json
{
  "name": "Ошибка: пустое имя",
  "input": { "type": "Catalog", "name": "" },
  "expectError": true
}
```

`expectError: true` — ожидается exitCode≠0. Строковое значение — проверит наличие в stderr.

### Все поля кейса

| Поле | Обязательно | Описание |
|---|---|---|
| `name` | да | Название теста (отображается в отчёте) |
| `input` | нет | JSON-объект, передаётся навыку через temp-файл |
| `params` | нет | Параметры для `case.<field>` и `workPath` маппинга |
| `setup` | нет | Переопределение setup из `_skill.json` |
| `outputPath` | нет | Относительный путь для навыков с `-OutputPath` |
| `args_extra` | нет | Массив дополнительных CLI-аргументов |
| `preRun` | нет | Массив шагов подготовки (создание объектов и т.п.) |
| `expect` | нет | Дополнительные проверки: `files`, `stdoutContains` (строка/массив), `stdoutNotContains` (строка/массив) |
| `expectError` | нет | `true` или строка — ожидается ошибка |

## Эталоны (snapshots)

Эталон — директория `snapshots/<имя-кейса>/` внутри папки навыка. Содержит ожидаемый выход навыка после нормализации.

### Создание / обновление эталонов

```bash
node tests/skills/runner.mjs --update-snapshots                     # все кейсы
node tests/skills/runner.mjs cases/meta-compile --update-snapshots  # один навык
node tests/skills/runner.mjs cases/meta-compile/enum --update-snapshots  # один кейс
```

### Когда обновлять

- После **намеренного** изменения логики навыка (новый выход — новый эталон)
- После сертификации: загрузить результат в 1С (`db-load-xml`), убедиться что платформа приняла, затем `--update-snapshots`
- **Не обновлять** если падение — неожиданный побочный эффект (это баг)

### Нормализация

Перед сравнением (и при сохранении) применяется:
- **UUID** → `UUID-001`, `UUID-002`... (по порядку появления, ссылочная целостность сохраняется)
- **BOM** (U+FEFF) — удаляется
- **Line endings** — `\r\n` → `\n`

## Структура

```
tests/skills/
  runner.mjs              # тест-раннер (snapshot-сравнение + интеграционные)
  verify-snapshots.mjs    # платформенная верификация снапшотов
  README.md               # этот файл
  .cache/                 # кэш фикстур (в .gitignore)
  integration/            # многошаговые сценарии (*.test.mjs), в т.ч. движковая матрица 1cv8/ibcmd
  cases/
    <навык>/
      _skill.json         # конфиг навыка
      <кейс>.json         # тестовый случай
      snapshots/
        <кейс>/           # эталон
      fixtures/            # broken-фикстуры (для validate-навыков)
        <имя>/             # сломанный XML, ссылка: "setup": "fixture:<имя>"
```
