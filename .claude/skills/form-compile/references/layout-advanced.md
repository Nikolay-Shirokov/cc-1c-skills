# Тонкая компоновка

Интервалы и ширина колонок внутри группы — `references/groups-pages.md`. Все ключи необязательны.

## Размеры

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `width` / `height` | число | Размер |
| `autoMaxWidth` / `autoMaxHeight` | `false` | Снять автоматический предел: поле на всю доступную ширину / высоту |
| `horizontalStretch` / `verticalStretch` | bool | Растягивать по ширине / высоте вместе с окном |
| `maxWidth` / `maxHeight` | число | Жёсткий предел размера |
| `titleHeight` | число | Высота заголовка |

```json
{ "input": "Комментарий", "path": "Объект.Комментарий", "multiLine": true, "autoMaxWidth": false }
{ "input": "Поиск", "path": "СтрокаПоиска", "horizontalStretch": true, "maxWidth": 60 }
```

## Выравнивание

| Ключ | Значения | Что выравнивает |
|------|----------|-----------------|
| `groupHorizontalAlign` | `Left` / `Center` / `Right` | Сам элемент в отведённом ему месте группы |
| `groupVerticalAlign` | `Top` / `Center` / `Bottom` | То же по вертикали |
| `horizontalAlign` | `Left` / `Center` / `Right` | Текст или значение внутри элемента |
| `verticalAlign` | `Top` / `Center` / `Bottom` | То же по вертикали |

```json
{ "button": "ОК", "command": "ОК", "groupHorizontalAlign": "Right" }
{ "input": "Сумма", "path": "Объект.Сумма", "horizontalAlign": "Right" }
```

## Ввод и фокус

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `skipOnInput` | bool | Пропускать при переходе по Enter/Tab |
| `defaultItem` | `true` | Фокус при открытии формы |
| `shortcut` | `"Ctrl+F"` и т.п. | Сочетание клавиш для перехода к элементу |

## Узкие экраны (`displayImportance`)

`VeryHigh` / `High` / `Usual` / `Low` / `VeryLow` — при нехватке места менее важные элементы сворачиваются первыми.

```json
{ "input": "Комментарий", "path": "Объект.Комментарий", "displayImportance": "Low" }
```
