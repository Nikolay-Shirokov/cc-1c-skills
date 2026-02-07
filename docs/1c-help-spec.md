# Встроенная справка внешней обработки 1С

Спецификация добавления встроенной справки (Help) к внешней обработке (EPF) в формате XML-выгрузки версии 2.17.

## 1. Структура файлов

```
<ИмяОбработки>/
    Ext/
        Help.xml                    # Метаданные справки (обязательно)
        Help/
            ru.html                 # HTML-страница справки на русском языке
```

Справка **не регистрируется** в `ChildObjects` корневого XML обработки — достаточно наличия файлов `Help.xml` и `Help/<язык>.html` в каталоге `Ext/`.

## 2. Help.xml — метаданные справки

Пространство имён: `http://v8.1c.ru/8.3/xcf/extrnprops` (то же, что у Template.xml).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Help xmlns="http://v8.1c.ru/8.3/xcf/extrnprops"
      xmlns:xs="http://www.w3.org/2001/XMLSchema"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      version="2.17">
    <Page>ru</Page>
</Help>
```

Элемент `<Page>` указывает код языка. Имя файла страницы: `<код_языка>.html`. Может быть несколько элементов `<Page>` для разных языков.

## 3. HTML-страница справки

Формат: HTML 4.0 Transitional, кодировка UTF-8.

### Минимальный шаблон

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<html>
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
    <link rel="stylesheet" type="text/css" href="v8help://service_book/service_style"/>
</head>
<body>
    Содержимое справки
</body>
</html>
```

### Обязательные элементы head

| Элемент | Назначение |
|---------|------------|
| `<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>` | Кодировка UTF-8 |
| `<link rel="stylesheet" type="text/css" href="v8help://service_book/service_style"/>` | Стили справки 1С (протокол `v8help://`) |

### Поддерживаемая разметка

Стандартный HTML 4.0: `<h1>`..`<h4>`, `<p>`, `<ul>`, `<ol>`, `<li>`, `<table>`, `<strong>`, `<em>`, `<a>`, `<br>`, `<pre>` и др. Стили 1С автоматически форматируют заголовки и абзацы.

## 4. Метаданные формы — IncludeHelpInContents

В файле метаданных формы (`Forms/<ИмяФормы>.xml`) должен быть элемент:

```xml
<IncludeHelpInContents>false</IncludeHelpInContents>
```

Полный контекст в файле формы:

```xml
<Form uuid="...">
    <Properties>
        <Name>ОсновнаяФорма</Name>
        ...
        <FormType>Managed</FormType>
        <IncludeHelpInContents>false</IncludeHelpInContents>
        <UsePurposes>...</UsePurposes>
        <ExtendedPresentation/>
    </Properties>
</Form>
```

Значение `false` — справка не включается в общее оглавление справочной системы (стандартное поведение для внешних обработок).

## 5. Кнопка вызова справки на форме

Для вызова справки используется стандартная команда платформы `Form.StandardCommand.Help`.

### Вариант А: кнопка в AutoCommandBar формы

Простейший способ — добавить кнопку в автокомандную панель формы (`id="-1"`):

```xml
<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
    <Autofill>false</Autofill>
    <ChildItems>
        <Button name="ФормаСправка" id="<свободный_id>">
            <Type>CommandBarButton</Type>
            <CommandName>Form.StandardCommand.Help</CommandName>
            <ExtendedTooltip name="ФормаСправкаExtendedTooltip" id="<свободный_id>"/>
        </Button>
    </ChildItems>
</AutoCommandBar>
```

Кнопка появится на автокомандной панели формы (верхняя строка). Подходит для простых форм.

### Вариант Б: кнопка в пользовательской CommandBar

Если форма не использует AutoCommandBar (задан `Autofill=false`, панель скрыта или пуста), кнопку справки можно разместить в произвольной `<CommandBar>` группе среди других пользовательских кнопок:

```xml
<CommandBar name="МояКоманднаяПанель" id="...">
    <Autofill>false</Autofill>
    <HorizontalStretch>false</HorizontalStretch>
    <ExtendedTooltip name="МояКоманднаяПанельExtendedTooltip" id="..."/>
    <ChildItems>
        <!-- Другие кнопки -->
        <Button name="КнопкаДействие" id="...">
            <Type>CommandBarButton</Type>
            <CommandName>Form.Command.МояКоманда</CommandName>
            ...
        </Button>
        <!-- Кнопка справки -->
        <Button name="ФормаСправка" id="<свободный_id>">
            <Type>CommandBarButton</Type>
            <CommandName>Form.StandardCommand.Help</CommandName>
            <ExtendedTooltip name="ФормаСправкаExtendedTooltip" id="<свободный_id>"/>
        </Button>
    </ChildItems>
</CommandBar>
```

Для стандартной команды `Help` не нужно объявлять элемент в секции `<Commands>` — платформа предоставляет её автоматически.

### Важно

- `<Type>CommandBarButton</Type>` — кнопка должна быть типа CommandBarButton (внутри `<CommandBar>`)
- Никакого обработчика в Module.bsl не требуется — `Form.StandardCommand.Help` обрабатывается платформой
- Платформа сама найдёт `Help.xml` и откроет соответствующую HTML-страницу

## 6. Чек-лист добавления справки

1. Создать `<ИмяОбработки>/Ext/Help.xml` с указанием языка (`<Page>ru</Page>`)
2. Создать `<ИмяОбработки>/Ext/Help/ru.html` с содержимым справки
3. Убедиться что в `Forms/<ИмяФормы>.xml` есть `<IncludeHelpInContents>false</IncludeHelpInContents>`
4. Добавить кнопку `Form.StandardCommand.Help` в CommandBar или AutoCommandBar формы
5. Собрать EPF — проверить что справка открывается по кнопке
