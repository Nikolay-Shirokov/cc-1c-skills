# Companion-панели и расширенная подсказка элемента

Любой элемент формы может нести свой собственный контент в трёх companion-свойствах: расширенную подсказку (`extendedTooltip`), командную панель (`commandBar`) и контекстное меню (`contextMenu`). Все три задаются ключами прямо на объекте элемента.

```jsonc
{ "table": "Список", "path": "Список",
  "commandBar": { "children": [ … ] },
  "contextMenu": { "children": [ … ] },
  "extendedTooltip": "Двойной клик открывает карточку" }
```

## Расширенная подсказка (`extendedTooltip`)

Подсказка-надпись рядом с элементом. Две формы записи.

**Текст-форма** — просто текст подсказки:

```jsonc
"extendedTooltip": "Укажите ИНН контрагента"
"extendedTooltip": { "ru": "Сумма с НДС", "en": "Amount incl. VAT" }
"extendedTooltip": { "text": "Всего <b>с НДС</b>", "formatted": true }
```

- строка — ru-текст;
- `{ "ru": …, "en": … }` — многоязычный (как `title`);
- `{ "text": …, "formatted": true }` — форматированный текст (inline-разметка 1С: `<b>…</>`, `<i>`, `<u>`, `<color web:Red>…</>`, `<bgColor …>`, `<font …>`, `<fontSize …>`, `<link URL>…</>`, `<img …>`; закрывающий тег — `</>`). `formatted` нужен только когда текст содержит такую разметку.

**Own-content форма** — объект с раскладкой/оформлением/флагами, когда подсказке нужны размеры, цвет, гиперссылка и т.п.:

```jsonc
"extendedTooltip": {
  "text": "Перейти к инструкции",
  "hyperlink": true,
  "textColor": "web:Blue",
  "events": { "URLProcessing": "ПодсказкаОбработкаНавигационнойСсылки" }
}
```

Ключи own-content объекта (все необязательны):

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `text` | string/ML | Текст подсказки (с `formatted` — форматированный) |
| `formatted` | bool | Интерпретировать inline-разметку в `text` |
| `tooltip` | string/ML | Всплывающая подсказка самой расширенной подсказки (редко; ≠ обычному `tooltip` элемента) |
| `hyperlink` | bool | Сделать подсказку гиперссылкой |
| `visible` / `enabled` | bool | Видимость / доступность подсказки |
| `width` / `height` | number | Размеры |
| `maxWidth` / `autoMaxWidth` | number / bool | Максимальная ширина / авто-максимум |
| `titleHeight` | number | Высота заголовка |
| `horizontalStretch` | bool | Горизонтальное растяжение |
| `verticalAlign` | string | Вертикальное выравнивание |
| `textColor` / `font` | string/object | Цвет текста / шрифт (см. `references/appearance.md`) |
| `events` | object | Обработчики событий подсказки, напр. `{ "URLProcessing": "Имя" }` у гиперссылочной подсказки |

## Командная панель (`commandBar`)

Собственная командная панель элемента (обычно таблицы или группы).

**Значение** — массив или объект:

```jsonc
"commandBar": [ { "button": "Создать", "command": "СоздатьЭлемент" } ]

"commandBar": {
  "autofill": false,
  "horizontalAlign": "Right",
  "children": [
    { "button": "Создать", "command": "СоздатьЭлемент" },
    { "buttonGroup": "Печать", "children": [ … ] }
  ]
}
```

- массив `[ … ]` — краткая запись для `{ "children": [ … ] }`;
- объект — `children` плюс необязательные `autofill` и `horizontalAlign`.

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `children` | array | Содержимое панели — обычная грамматика кнопок (см. основную инструкцию) |
| `autofill` | bool | `false` — подавить автозаполнение панели стандартными командами. Необязательно (по умолчанию панель автозаполняется) |
| `horizontalAlign` | string | Горизонтальное выравнивание содержимого: `Left` / `Center` / `Right`. Необязательно |

`children` — кнопки: `button` (с `command` / `commandName` / `stdCommand`), `buttonGroup`, `popup` — как в основной инструкции по кнопкам.

> Для таблицы динамического списка панель по умолчанию подавлена (чтобы не дублировать командную панель формы). Чтобы оставить автозаполняемую панель у самой таблицы — задайте `commandBar: { "autofill": true }`.

## Контекстное меню (`contextMenu`)

Собственное контекстное меню элемента. Грамматика та же, что у `commandBar`, но без `horizontalAlign`.

```jsonc
"contextMenu": [ { "button": "Карта маршрута", "commandName": "CommonCommand.КартаМаршрута" } ]

"contextMenu": {
  "autofill": false,
  "children": [
    { "button": "Скопировать ссылку", "command": "СкопироватьСсылку" }
  ]
}
```

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `children` | array | Пункты меню — обычная грамматика кнопок |
| `autofill` | bool | `false` — подавить автозаполнение меню. Необязательно |

## Пример: таблица со своим меню и инфо-баннером

```jsonc
{ "table": "Заказы", "path": "Объект.Заказы",
  "extendedTooltip": {
    "text": "Строки с просрочкой выделены <color web:FireBrick>красным</>",
    "formatted": true
  },
  "commandBar": {
    "autofill": false,
    "horizontalAlign": "Right",
    "children": [
      { "button": "Добавить", "command": "ДобавитьЗаказ" },
      { "button": "Удалить", "command": "УдалитьЗаказ" }
    ]
  },
  "contextMenu": {
    "children": [
      { "button": "Открыть документ", "command": "ОткрытьЗаказ" },
      { "buttonGroup": "Экспорт", "children": [
        { "button": "В Excel", "command": "ВыгрузитьВExcel" } ] }
    ]
  } }
```
