# 1C EPF Skills for Claude Code

Набор [Claude Code Skills](https://docs.anthropic.com/en/docs/claude-code/skills) для работы с исходниками внешних обработок 1С:Предприятия 8.3. Позволяет создавать, модифицировать и собирать обработки (`.epf`) из XML-исходников, не запоминая детали формата.

## Навыки

| Навык | Параметры | Описание |
|-------|-----------|----------|
| `/epf-init` | `<Name> [Synonym]` | Создать новую обработку (корневой XML + модуль объекта) |
| `/epf-add-form` | `<ProcessorName> <FormName> [Synonym]` | Добавить управляемую форму |
| `/epf-add-template` | `<ProcessorName> <TemplateName> <TemplateType>` | Добавить макет (HTML, Text, SpreadsheetDocument, BinaryData) |
| `/epf-add-help` | `<ProcessorName>` | Добавить встроенную справку (Help.xml + HTML) |
| `/epf-remove-form` | `<ProcessorName> <FormName>` | Удалить форму |
| `/epf-remove-template` | `<ProcessorName> <TemplateName>` | Удалить макет |
| `/epf-build` | `<ProcessorName>` | Собрать EPF из XML (документация команды 1cv8.exe) |
| `/epf-dump` | `<EpfFile>` | Разобрать EPF в XML (документация команды 1cv8.exe) |
| `/epf-bsp-init` | `<ProcessorName> <Вид>` | Добавить регистрацию БСП (СведенияОВнешнейОбработке) |
| `/epf-bsp-add-command` | `<ProcessorName> <Идентификатор>` | Добавить команду в обработку БСП |

Навыки удаления (`epf-remove-*`) не вызываются Claude автоматически — только по явной команде пользователя.

## Как пользоваться

Не обязательно запоминать команды и параметры. Просто опишите задачу своими словами — Claude сам подберёт нужные навыки:

```
> Создай обработку ЗагрузкаПрайса с формой и HTML-макетом
```

Claude выполнит `/epf-init`, `/epf-add-form`, `/epf-add-template` с правильными параметрами.

```
> Сделай из неё дополнительную обработку БСП для заполнения справочника Номенклатура
```

Claude вызовет `/epf-bsp-init` с видом ЗаполнениеОбъекта и назначением Справочник.Номенклатура.

```
> Добавь справку с описанием
```

Claude вызовет `/epf-add-help` и предложит отредактировать HTML.

```
> Собери
```

Claude вызовет `/epf-build`.

Слеш-команды (например `/epf-init МояОбработка`) тоже работают — для тех случаев, когда хочется точного контроля.

### Примеры слеш-команд

```
> /epf-init МояОбработка "Моя обработка"
> /epf-add-form МояОбработка Форма
> /epf-add-template МояОбработка Макет HTML
> /epf-add-help МояОбработка
> /epf-build МояОбработка
```

### Дополнительная печатная форма БСП

```
> /epf-init МояПечатнаяФорма "Моя печатная форма"
> /epf-bsp-init МояПечатнаяФорма печатная форма для Документ.СчетНаОплату
> /epf-add-template МояПечатнаяФорма СчетНаОплату SpreadsheetDocument
> /epf-build МояПечатнаяФорма
```

Первая добавленная форма автоматически становится основной (DefaultForm). Флаг `--main` нужен только для переназначения основной формы на другую.

После `/epf-init` создаётся структура:

```
src/
├── МояОбработка.xml                          # Корневой файл метаданных
└── МояОбработка/
    └── Ext/
        └── ObjectModule.bsl                  # Модуль объекта
```

После `/epf-add-form` и `/epf-add-template`:

```
src/
├── МояОбработка.xml
└── МояОбработка/
    ├── Ext/
    │   └── ObjectModule.bsl
    ├── Forms/
    │   ├── Форма.xml                         # Метаданные формы
    │   └── Форма/
    │       └── Ext/
    │           ├── Form.xml                  # Описание формы
    │           └── Form/
    │               └── Module.bsl            # Модуль формы
    └── Templates/
        ├── Макет.xml                         # Метаданные макета
        └── Макет/
            └── Ext/
                └── Template.html             # Содержимое макета
```

## Подключение к проекту

Скопируйте каталог `.claude/skills/` в корень вашего проекта. Навыки будут доступны при запуске Claude Code из этого каталога.

```
МойПроект/
├── .claude/skills/    ← скопировать из этого репозитория
├── src/               ← исходники обработки (создаются навыками)
└── ...
```

## Требования

- **Windows** с PowerShell 5.1+ (входит в Windows)
- **1С:Предприятие 8.3** — для сборки/разборки EPF (навыки генерации XML работают без платформы)

## Структура репозитория

```
.claude/skills/          # Навыки Claude Code
├── epf-init/            # SKILL.md + scripts/init.ps1
├── epf-add-form/        # SKILL.md + scripts/add-form.ps1
├── epf-add-template/    # SKILL.md + scripts/add-template.ps1
├── epf-remove-form/     # SKILL.md + scripts/remove-form.ps1
├── epf-remove-template/ # SKILL.md + scripts/remove-template.ps1
├── epf-build/           # SKILL.md (только документация)
├── epf-dump/            # SKILL.md (только документация)
├── epf-add-help/        # SKILL.md + scripts/add-help.ps1
├── epf-bsp-init/        # SKILL.md (шаблоны кода, без скриптов)
└── epf-bsp-add-command/ # SKILL.md (шаблоны кода, без скриптов)
docs/
├── 1c-xml-format-spec.md   # Спецификация XML-формата выгрузки
├── 1c-help-spec.md         # Спецификация встроенной справки
└── build-spec.md            # Спецификация команд сборки/разборки
```

## Спецификации

- [XML-формат выгрузки обработок](docs/1c-xml-format-spec.md) — полное описание структуры XML-файлов, namespace'ов, элементов форм
- [Встроенная справка](docs/1c-help-spec.md) — Help.xml, HTML-страницы, кнопка справки на форме
- [Сборка и разборка EPF](docs/build-spec.md) — команды `1cv8.exe`, параметры, коды возврата

## Технические детали

- Все XML-файлы создаются в **UTF-8 с BOM** (как в реальных выгрузках 1С)
- PowerShell-скрипты используют `System.Xml.XmlDocument` для модификации корневого XML
- UUID генерируются через `[guid]::NewGuid()`
- ClassId обработки фиксирован: `c3831ec8-d8d5-4f93-8a22-f9bfae07327f`
- Порядок элементов в `ChildObjects`: TabularSections → Forms → Templates
- Первая форма автоматически назначается основной (DefaultForm)
- BSP-навыки (`epf-bsp-*`) не используют скрипты — Claude модифицирует код напрямую через Read/Edit
