---
name: epf-add-help
description: Добавить встроенную справку к внешней обработке 1С
argument-hint: <ProcessorName>
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /epf-add-help — Добавление справки

Добавляет встроенную справку к обработке: файл метаданных `Help.xml`, HTML-страницу и при необходимости обновляет метаданные форм.

## Usage

```
/epf-add-help <ProcessorName> [Lang] [SrcDir]
```

| Параметр      | Обязательный | По умолчанию | Описание                            |
|---------------|:------------:|--------------|-------------------------------------|
| ProcessorName | да           | —            | Имя обработки                       |
| Lang          | нет          | `ru`         | Код языка справки                   |
| SrcDir        | нет          | `src`        | Каталог исходников                  |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/epf-add-help/scripts/add-help.ps1 -ProcessorName "<ProcessorName>" [-Lang "<Lang>"] [-SrcDir "<SrcDir>"]
```

## Что создаётся

```
<SrcDir>/<ProcessorName>/
    Ext/
        Help.xml                    # Метаданные справки (namespace extrnprops)
        Help/
            ru.html                 # HTML-страница справки
```

- `Help.xml` — фиксированная структура с `<Page>ru</Page>` (namespace `http://v8.1c.ru/8.3/xcf/extrnprops`)
- `ru.html` — HTML 4.0 Transitional с подключением стилей 1С (`v8help://service_book/service_style`)
- Справка **не регистрируется** в `ChildObjects` корневого XML — достаточно наличия файлов

## Что модифицируется

- Если в метаданных формы (`Forms/<FormName>.xml`) отсутствует `<IncludeHelpInContents>` — скрипт добавит `<IncludeHelpInContents>false</IncludeHelpInContents>` после `<FormType>`. Для форм, созданных через `/epf-add-form`, элемент уже есть.

## Кнопка справки на форме

После создания справки для её вызова нужна кнопка на форме. Добавь кнопку `Form.StandardCommand.Help` в AutoCommandBar формы (`Forms/<FormName>/Ext/Form.xml`).

### Текущая структура AutoCommandBar (созданная epf-add-form)

```xml
<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
    <Autofill>true</Autofill>
</AutoCommandBar>
```

### Нужно заменить на

```xml
<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
    <Autofill>true</Autofill>
    <ChildItems>
        <Button name="ФормаСправка" id="{{свободный_id}}">
            <Type>CommandBarButton</Type>
            <CommandName>Form.StandardCommand.Help</CommandName>
            <ExtendedTooltip name="ФормаСправкаExtendedTooltip" id="{{свободный_id + 1}}"/>
        </Button>
    </ChildItems>
</AutoCommandBar>
```

### Выбор id

Просмотри все `id="..."` в `Form.xml` и выбери следующий свободный числовой id. Обычно id начинаются с 1 и идут подряд. Для кнопки нужны 2 id: один для Button, один для ExtendedTooltip.

### Важно

- `Form.StandardCommand.Help` — стандартная команда платформы, не нужно объявлять в `<Commands>`
- Обработчика в Module.bsl не требуется — платформа сама найдёт `Help.xml` и откроет HTML

## Редактирование справки

После создания содержимое справки — обычный HTML. Отредактируй `Ext/Help/ru.html` в соответствии с назначением обработки. Поддерживается стандартная HTML-разметка: `<h1>`..`<h4>`, `<p>`, `<ul>`, `<ol>`, `<table>`, `<strong>`, `<em>`, `<a>`, `<pre>`.