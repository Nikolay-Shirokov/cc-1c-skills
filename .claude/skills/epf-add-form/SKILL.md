---
name: epf-add-form
description: Добавить управляемую форму к внешней обработке 1С
argument-hint: <ProcessorName> <FormName> [Synonym]
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-add-form — Добавление формы

Создаёт управляемую форму и регистрирует её в корневом XML обработки.

## Usage

```
/epf-add-form <ProcessorName> <FormName> [Synonym] [--main]
```

| Параметр      | Обязательный | По умолчанию | Описание                                  |
|---------------|:------------:|--------------|-------------------------------------------|
| ProcessorName | да           | —            | Имя обработки (должна существовать)       |
| FormName      | да           | —            | Имя формы                                 |
| Synonym       | нет          | = FormName   | Синоним формы                             |
| --main        | нет          | авто         | Установить как форму по умолчанию (автоматически для первой формы) |
| SrcDir        | нет          | `src`        | Каталог исходников                        |

## Команда

```powershell
pwsh -NoProfile -File .claude/skills/epf-add-form/scripts/add-form.ps1 -ProcessorName "<ProcessorName>" -FormName "<FormName>" [-Synonym "<Synonym>"] [-Main] [-SrcDir "<SrcDir>"]
```

## Что создаётся

```
<SrcDir>/<ProcessorName>/Forms/
├── <FormName>.xml                    # Метаданные формы (1 UUID)
└── <FormName>/
    └── Ext/
        ├── Form.xml                  # Описание формы (logform namespace)
        └── Form/
            └── Module.bsl           # BSL-модуль с 4 регионами
```

## Что модифицируется

- `<SrcDir>/<ProcessorName>.xml` — добавляется `<Form>` в `ChildObjects`, обновляется `DefaultForm` (автоматически если это первая форма, или явно при `--main`)

## Детали

- FormType: Managed
- UsePurposes: PlatformApplication, MobilePlatformApplication
- AutoCommandBar с id=-1
- Реквизит "Объект" с MainAttribute=true
- BSL-модуль содержит 5 регионов: ОбработчикиСобытийФормы, ОбработчикиСобытийЭлементовФормы, ОбработчикиКомандФормы, ОбработчикиОповещений, СлужебныеПроцедурыИФункции

## Спецификация

Подробности формата: `docs/1c-xml-format-spec.md`
