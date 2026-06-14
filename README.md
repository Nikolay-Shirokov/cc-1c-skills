# 1C Skills for Claude Code

> **Проект живой, активно развивается** — добавляются новые возможности, отлавливаются и исправляются баги, производится оптимизация. Следите за обновлениями.

Набор навыков для AI-агентов (в первую очередь для [Claude Code](https://docs.anthropic.com/en/docs/claude-code/skills)), помогающий охватить полный цикл разработки на платформе 1С:Предприятие 8.3 — от создания конфигураций, расширений, внешних обработок и отчётов до загрузки изменений в информационную базу, обновления, запуска, публикации на веб-сервере (портативная версия Apache), тестирования через веб-клиент и записи видеоинструкций.

Навыки дают модели готовые абстракции над XML-форматами и CLI конфигуратора — чтобы работать с сутью задачи, а не с деталями реализации. А веб-тестирование даёт ей глаза и руки для взаимодействия с интерфейсом 1С.

## Версии навыков для разных платформ

> **PS** — версия со скриптами на PowerShell (стандартная, для Windows). **Py** — версия со скриптами на Python (если PowerShell не подходит). Можно начать с **PS** — это основной вариант.

**Claude Code** [PS](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/main) · [Py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-claude-code-py) — **Cursor** [PS](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cursor) · [Py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cursor-py) — **Codex** [PS](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codex) · [Py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codex-py) — [Другие платформы →](#поддерживаемые-платформы)

## Быстрый старт

Скопируйте каталог `.claude/skills/` из этого репозитория в корень вашего проекта. Навыки станут доступны при запуске Claude Code из этого каталога.

```
МойПроект/
├── .claude/skills/    ← скопировать сюда
└── ...
```

Или установите как плагин Claude Code:

```
/plugin marketplace add https://github.com/Nikolay-Shirokov/cc-1c-skills
/plugin install 1c-skills@cc-1c-skills        # PowerShell (Windows)
/plugin install 1c-skills-py@cc-1c-skills     # Python (Linux/Mac или если PS недоступен)
```

Или установите как плагин OpenAI Codex:

```
codex plugin marketplace add Nikolay-Shirokov/cc-1c-skills
codex /plugins   # выберите 1c-skills (PowerShell) или 1c-skills-py (Python) и нажмите Install
```

Или используйте скрипт установки:

```bash
git clone https://github.com/Nikolay-Shirokov/cc-1c-skills.git tools/cc-1c-skills

# Копия (рекомендуется): независимая копия, обновление — повторный запуск
python tools/cc-1c-skills/scripts/switch.py claude-code --project-dir .

# Ссылки (экспериментально): обновления подхватываются через git pull
python tools/cc-1c-skills/scripts/switch.py claude-code --project-dir . --link

# Интерактивный режим: пошаговый выбор платформы, способа установки и рантайма
python tools/cc-1c-skills/scripts/switch.py
```

Не обязательно запоминать команды и параметры — просто опишите задачу своими словами, Claude сам подберёт нужные навыки. Слеш-команды (например `/epf-init МояОбработка`) тоже работают — для точного контроля.

## Группы навыков

| Группа | Навыки | Описание | Гайд |
|--------|--------|----------|------|
| Внешние обработки (EPF) | 7 навыков `/epf-*` | Создание, сборка, разборка, валидация обработок из XML-исходников | [Подробнее](docs/epf-guide.md) |
| Внешние отчёты (ERF) | 4 навыка `/erf-*` | Создание, сборка, разборка, валидация внешних отчётов | [Подробнее](docs/epf-guide.md#внешние-отчёты-erf) |
| Универсальные операции | `/template-add`, `/template-remove`, `/help-add`, `/form-remove` | Добавление/удаление макетов, форм, справки для любых объектов | [Подробнее](docs/epf-guide.md#универсальные-навыки) |
| Табличный документ (MXL) | 4 навыка `/mxl-*` | Анализ, создание, компиляция макетов печатных форм | [Подробнее](docs/mxl-guide.md) |
| Управляемые формы (Form) | 6 навыков `/form-*` | Создание, анализ, генерация, модификация, валидация управляемых форм | [Подробнее](docs/form-guide.md) |
| Роли (Role) | 3 навыка `/role-*` | Анализ прав роли, создание из JSON DSL, валидация | [Подробнее](docs/role-guide.md) |
| Схема компоновки (СКД) | 4 навыка `/skd-*` | Анализ, генерация из JSON DSL, точечное редактирование, валидация схем компоновки данных | [Подробнее](docs/skd-guide.md) |
| Метаданные конфигурации | 5 навыков `/meta-*` | Создание, анализ, редактирование, удаление, валидация объектов метаданных (23 типа) | [Подробнее](docs/meta-guide.md) |
| Корневая конфигурация | 4 навыка `/cf-*` | Создание, анализ, редактирование, валидация корневых файлов конфигурации | [Подробнее](docs/cf-guide.md) |
| Расширения (CFE) | 5 навыков `/cfe-*` | Создание, заимствование, перехват методов, валидация, анализ расширений | [Подробнее](docs/cfe-guide.md) |
| Подсистемы (Subsystem) | 4 навыка `/subsystem-*` | Анализ, создание, редактирование, валидация подсистем конфигурации | [Подробнее](docs/subsystem-guide.md) |
| Командный интерфейс (CI) | 2 навыка `/interface-*` | Редактирование и валидация CommandInterface.xml подсистем | [Подробнее](docs/subsystem-guide.md) |
| Базы данных (DB) | 9 навыков `/db-*` | Создание баз, загрузка/выгрузка конфигураций, обновление БД, загрузка из Git | [Подробнее](docs/db-guide.md) |
| Веб-публикация (Web) | 4 навыка `/web-*` | Публикация баз через Apache, статус, остановка, удаление публикаций | [Подробнее](docs/web-guide.md) |
| Тестирование (Web) | `/web-test` | Взаимодействие с веб-клиентом 1С — навигация, формы, таблицы, отчёты, тестирование | [Подробнее](docs/web-test-guide.md) |
| Запись видео (Web) | `/web-test` | Запись видеоинструкций с субтитрами, подсветкой и TTS-озвучкой | [Подробнее](docs/web-test-recording-guide.md) |
| Регресс прикладного решения (Web) | `/web-test` | Автоматический регресс конфигурации: тесты, проверки, отчёты, прогон после правок | [Подробнее](docs/web-test-regression-guide.md) |
| Утилиты | `/img-grid` | Наложение сетки на изображение для определения пропорций колонок | — |

## Требования

- **Windows** с PowerShell 5.1+ (входит в Windows) — рантайм по умолчанию
- **1С:Предприятие 8.3** — для сборки/разборки EPF/ERF (навыки генерации XML работают без платформы)
- **Node.js 18+** — для `/web-test` (тестирование через браузер)

<a id="поддерживаемые-платформы"></a>
### Другие AI-платформы

Навыки построены на открытом стандарте [Agent Skills](https://agentskills.io/specification) и совместимы с любой платформой, поддерживающей этот формат. Самый быстрый путь — скачать готовую сборку под нужную платформу из ветки ниже (**Code → Download ZIP**) и распаковать в корень своего проекта.

#### Поддерживаемые платформы

| Платформа | Целевой каталог | PowerShell | Python |
|-----------|----------------|------------|--------|
| Claude Code | `.claude/skills/` | [main](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/main) | [port-claude-code-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-claude-code-py) |
| Cursor | `.cursor/skills/` | [port-cursor](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cursor) | [port-cursor-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cursor-py) |
| OpenAI Codex | `.codex/skills/` | [port-codex](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codex) | [port-codex-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codex-py) |
| GitHub Copilot | `.github/skills/` | [port-copilot](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-copilot) | [port-copilot-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-copilot-py) |
| Augment | `.augment/skills/` | [port-augment](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-augment) | [port-augment-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-augment-py) |
| Cline | `.cline/skills/` | [port-cline](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cline) | [port-cline-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-cline-py) |
| Kilo Code | `.kilocode/skills/` | [port-kilo](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-kilo) | [port-kilo-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-kilo-py) |
| Kiro | `.kiro/skills/` | [port-kiro](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-kiro) | [port-kiro-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-kiro-py) |
| Gemini CLI | `.gemini/skills/` | [port-gemini](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-gemini) | [port-gemini-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-gemini-py) |
| OpenCode | `.opencode/skills/` | [port-opencode](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-opencode) | [port-opencode-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-opencode-py) |
| Roo Code | `.roo/skills/` | [port-roo](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-roo) | [port-roo-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-roo-py) |
| Windsurf | `.windsurf/skills/` | [port-windsurf](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-windsurf) | [port-windsurf-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-windsurf-py) |
| Yandex Code Assistant | `.codeassistant/skills/` | [port-codeassistant](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codeassistant) | [port-codeassistant-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-codeassistant-py) |
| Agent Skills | `.agents/skills/` | [port-agents](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-agents) | [port-agents-py](https://github.com/Nikolay-Shirokov/cc-1c-skills/tree/port-agents-py) |

Готовые ветки `port-*` пересобираются автоматически на каждое изменение в навыках. Если нужна свежая сборка прямо сейчас — соберите [локально через `switch.py`](#альтернативный-способ--собрать-локально-через-switchpy).

Некоторые платформы (Augment, Cline, VS Code/Copilot) также сканируют `.claude/skills/` как fallback — для них достаточно `main`.

<a id="альтернативный-способ--собрать-локально-через-switchpy"></a>
#### Альтернативный способ — собрать локально через `switch.py`

Если нужна свежая сборка под свою платформу (или платформа ещё не в матрице port-веток):

```bash
python scripts/switch.py                                       # интерактивный режим
python scripts/switch.py cursor                                # скопировать навыки для Cursor
python scripts/switch.py cursor --runtime python               # Cursor + Python-рантайм
python scripts/switch.py claude-code --project-dir /my/proj    # установить копию в проект
python scripts/switch.py claude-code --project-dir /my/proj --link  # ссылки вместо копий
python scripts/switch.py --undo cursor                         # удалить копию / ссылки
```

Если репозиторий склонирован внутрь проекта (например, в `tools/cc-1c-skills`), используйте `--project-dir` для установки навыков в целевой проект.

**Ссылки vs копии.** Флаг `--link` (экспериментальный) создаёт directory junction (Windows) или symlink (Linux/Mac) вместо копирования файлов. Обновления в источнике автоматически подхватываются во всех подключённых проектах — достаточно `git pull`. Ссылки доступны только для платформы Claude Code (для остальных платформ требуется перезапись путей в SKILL.md). Удаление ссылок: `--undo` — безопасно удаляет только ссылки, не трогая источник.

> ⚠ **Известные ограничения `--link`:** Node.js резолвит `__dirname` через junction к реальному пути источника, а не к каталогу проекта. Это может приводить к тому, что навыки с Node.js-скриптами (например, `/web-test`) будут записывать файлы в каталог репозитория навыков вместо каталога проекта. При возникновении проблем переключитесь на копирование (без `--link`).

Автоактивация — основной режим: просто опишите задачу своими словами, ассистент сам подберёт нужный навык по `description` в SKILL.md. Слеш-команды (например `/epf-init`) — для точного контроля, когда нужно вызвать конкретный навык.

### Переключение рантайма (PowerShell ↔ Python)

На Windows рекомендуется PS1-рантайм (по умолчанию). Python-порты — для **Linux/Mac** или если PowerShell недоступен. PS1-скрипты — мастер-версия; Python-порты производные (см. [Python Porting Guide](docs/python-porting-guide.md)).

```bash
python scripts/switch.py --runtime python      # переключить на Python
python scripts/switch.py --runtime powershell  # вернуть на PowerShell
```

Дополнительные зависимости Python-рантайма:
- `lxml>=4.9.0` — для навыков, работающих с DOM (edit/validate/info)
- `psutil>=5.9.0` — для web-навыков (управление Apache)

Параметры скриптов идентичны для обоих рантаймов — переключение меняет только интерпретатор в вызовах. Подробнее: [Python Porting Guide](docs/python-porting-guide.md).

## Спецификации

Полный индекс с оглавлением по всем 44 типам объектов: **[Сводный индекс спецификаций](docs/1c-specs-index.md)**

- [XML-формат выгрузки обработок](docs/1c-epf-spec.md) — структура XML-файлов, namespace, элементы форм
- [XML-формат внешних отчётов](docs/1c-erf-spec.md) — отличия ERF от EPF, Properties, MainDataCompositionSchema
- [Управляемая форма](docs/1c-form-spec.md) — Form.xml, элементы, команды, реквизиты
- [Встроенная справка](docs/1c-help-spec.md) — Help.xml, HTML-страницы, кнопка справки на форме
- [Пакетный режим конфигуратора 1С](docs/build-spec.md) — команды `1cv8.exe`, DESIGNER, ENTERPRISE, CREATEINFOBASE
- [Табличный документ (MXL)](docs/1c-spreadsheet-spec.md) — XML-формат SpreadsheetDocument, совместимость версий
- [MXL DSL](docs/mxl-dsl-spec.md) — JSON-формат описания макета для `/mxl-compile` и `/mxl-decompile`
- [Form DSL](docs/form-dsl-spec.md) — JSON-формат описания формы для `/form-compile`
- [Роли (Rights.xml)](docs/1c-role-spec.md) — XML-формат прав роли, типы объектов, RLS
- [Role DSL](docs/role-dsl-spec.md) — JSON-формат описания ролей для `/role-compile`
- [Схема компоновки данных (DCS)](docs/1c-dcs-spec.md) — XML-формат DataCompositionSchema, 930 схем проанализировано
- [SKD DSL](docs/skd-dsl-spec.md) — JSON-формат описания СКД для `/skd-compile`
- [Объекты конфигурации](docs/1c-config-objects-spec.md) — XML-формат объектов метаданных конфигурации (23 типа)
- [Подсистемы и командный интерфейс](docs/1c-subsystem-spec.md) — XML-формат подсистем, CommandInterface.xml, секции видимости/размещения/порядка
- [Корневая конфигурация](docs/1c-configuration-spec.md) — XML-формат Configuration.xml, ConfigDumpInfo.xml, Languages/, 44 типа ChildObjects
- [Расширения конфигурации (CFE)](docs/1c-extension-spec.md) — XML-формат выгрузки расширений конфигурации
- [Веб-публикация 1С](docs/web-spec.md) — VRD, httpd.conf, wsap24.dll, portable Apache

## Структура репозитория

```
.claude/skills/          # Навыки Claude Code
├── epf-init/            # Создание обработки
├── epf-build/           # Сборка EPF
├── epf-dump/            # Разборка EPF
├── epf-bsp-init/        # Регистрация БСП
├── epf-bsp-add-command/ # Команда БСП
├── epf-validate/        # Валидация обработки
├── erf-init/            # Создание внешнего отчёта
├── erf-build/           # Сборка ERF
├── erf-dump/            # Разборка ERF
├── erf-validate/        # Валидация отчёта
├── template-add/        # Добавление макета (универсальный)
├── template-remove/     # Удаление макета (универсальный)
├── form-add/            # Добавление формы (универсальный)
├── form-remove/         # Удаление формы (универсальный)
├── help-add/            # Добавление справки (универсальный)
├── mxl-info/            # Анализ макета
├── mxl-validate/        # Валидация макета
├── mxl-compile/         # Компиляция макета из JSON
├── mxl-decompile/       # Декомпиляция макета в JSON
├── form-info/           # Анализ структуры управляемой формы
├── form-compile/        # Компиляция формы из JSON
├── form-validate/       # Валидация формы
├── form-edit/           # Добавление элементов в форму
├── form-patterns/       # Справочник паттернов компоновки форм
├── role-info/           # Анализ прав роли
├── role-compile/        # Создание роли из JSON DSL
├── role-validate/       # Валидация роли
├── skd-info/            # Анализ схемы компоновки данных
├── skd-compile/         # Компиляция СКД из JSON DSL
├── skd-edit/            # Точечное редактирование СКД (25 операций)
├── skd-validate/        # Валидация СКД
├── meta-info/           # Структура объекта метаданных
├── meta-compile/        # Создание объекта метаданных
├── meta-edit/           # Редактирование объекта метаданных
├── meta-remove/         # Удаление объекта метаданных
├── meta-validate/       # Валидация объекта метаданных
├── cf-info/             # Анализ структуры конфигурации
├── cf-init/             # Создание пустой конфигурации
├── cf-edit/             # Редактирование конфигурации
├── cf-validate/         # Валидация конфигурации
├── cfe-init/            # Создание расширения
├── cfe-borrow/          # Заимствование объектов
├── cfe-patch-method/    # Перехват методов
├── cfe-validate/        # Валидация расширения
├── cfe-diff/            # Анализ и сравнение
├── subsystem-info/      # Анализ структуры подсистемы
├── subsystem-compile/   # Создание подсистемы из JSON
├── subsystem-edit/      # Редактирование подсистемы
├── subsystem-validate/  # Валидация подсистемы
├── interface-edit/      # Редактирование CommandInterface.xml
├── interface-validate/  # Валидация CommandInterface.xml
├── db-list/             # Управление реестром баз данных
├── db-create/           # Создание информационной базы
├── db-dump-cf/          # Выгрузка конфигурации в CF
├── db-load-cf/          # Загрузка конфигурации из CF
├── db-dump-xml/         # Выгрузка конфигурации в XML
├── db-load-xml/         # Загрузка конфигурации из XML
├── db-update/           # Обновление конфигурации БД
├── db-run/              # Запуск 1С:Предприятие
├── db-load-git/         # Загрузка изменений из Git
├── web-publish/         # Публикация базы через Apache
├── web-info/            # Статус Apache и публикаций
├── web-stop/            # Остановка Apache
├── web-unpublish/       # Удаление публикации
├── web-test/            # Тестирование через веб-клиент 1С
└── img-grid/            # Сетка для анализа изображений
scripts/
└── switch.py              # Переключение платформы и рантайма (13 платформ)
docs/
├── epf-guide.md            # Гайд: внешние обработки и отчёты
├── mxl-guide.md            # Гайд: табличный документ
├── form-guide.md           # Гайд: управляемые формы
├── role-guide.md           # Гайд: роли
├── skd-guide.md            # Гайд: схема компоновки данных
├── meta-guide.md           # Гайд: объекты метаданных конфигурации
├── cf-guide.md             # Гайд: корневые файлы конфигурации
├── cfe-guide.md            # Гайд: расширения конфигурации (CFE)
├── subsystem-guide.md      # Гайд: подсистемы и командный интерфейс
├── v8-project-guide.md     # Гайд: конфигурация проекта (.v8-project.json)
├── db-guide.md             # Гайд: базы данных 1С
├── web-guide.md            # Гайд: веб-публикация через Apache
├── web-test-guide.md       # Гайд: тестирование через веб-клиент
├── web-test-recording-guide.md # Гайд: запись видеоинструкций
├── web-test-regression-guide.md # Гайд: регресс прикладного решения
├── 1c-epf-spec.md          # Спецификация XML-формата (EPF)
├── 1c-erf-spec.md          # Спецификация XML-формата (ERF)
├── 1c-form-spec.md         # Спецификация управляемых форм
├── 1c-help-spec.md         # Спецификация встроенной справки
├── 1c-config-objects-spec.md # Спецификация объектов конфигурации
├── build-spec.md           # Пакетный режим конфигуратора 1С
├── 1c-spreadsheet-spec.md  # Спецификация табличного документа
├── mxl-dsl-spec.md         # Спецификация MXL DSL
├── form-dsl-spec.md        # Спецификация Form DSL
├── meta-dsl-spec.md        # Спецификация Meta DSL
├── 1c-role-spec.md         # Спецификация ролей (Rights.xml)
├── 1c-dcs-spec.md          # Спецификация СКД (DataCompositionSchema)
├── skd-dsl-spec.md         # Спецификация SKD DSL
├── role-dsl-spec.md        # Спецификация Role DSL
├── 1c-extension-spec.md    # Спецификация расширений конфигурации (CFE)
├── 1c-subsystem-spec.md    # Спецификация подсистем и командного интерфейса
├── web-spec.md             # Спецификация веб-публикации (VRD, httpd.conf, Apache)
└── python-porting-guide.md # Руководство по Python-портам навыков
```
