# Подсказки и форматированный текст

## Всплывающая подсказка

`tooltip` — текст при наведении (строка или `{ru, en}`). Как показывать:

| Ключ | Значения |
|------|----------|
| `tooltipRepresentation` | `None` / `Button` (значок «?») / `ShowBottom` / `ShowTop` / `ShowLeft` / `ShowRight` / `ShowAuto` / `Balloon` |

## Расширенная подсказка (`extendedTooltip`)

Надпись-пояснение рядом с элементом (под полем, баннер над таблицей).

```json
"extendedTooltip": "Укажите ИНН контрагента"
"extendedTooltip": { "ru": "Сумма с НДС", "en": "Amount incl. VAT" }
"extendedTooltip": { "text": "Всего <b>с НДС</b>", "formatted": true }
```

Когда подсказке нужны размер, цвет или ссылка — объект:

```json
"extendedTooltip": {
  "text": "Перейти к инструкции",
  "hyperlink": true,
  "textColor": "web:Blue",
  "events": { "URLProcessing": "ПодсказкаОбработкаНавигационнойСсылки" }
}
```

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `text` | строка или `{ru, en}` | Текст |
| `formatted` | bool | В тексте есть разметка (см. ниже) |
| `hyperlink` | bool | Подсказка — ссылка |
| `visible` / `enabled` | bool | Видимость, доступность |
| `width` / `height` / `maxWidth` / `autoMaxWidth` / `horizontalStretch` | | Размеры |
| `textColor` / `font` | | Оформление (`references/appearance.md`) |
| `events` | `{ "URLProcessing": "Имя" }` | Обработчик нажатия на ссылку |

## Форматированный текст

`title` надписи, `extendedTooltip` и `text` подсказки принимают разметку 1С:

| Разметка | Что делает |
|----------|-----------|
| `<b>…</>`, `<i>…</>`, `<u>…</>` | Жирный, курсив, подчёркивание |
| `<color web:Red>…</>`, `<bgColor web:Yellow>…</>` | Цвет текста, фона |
| `<font style:SmallTextFont>…</>`, `<fontSize 12>…</>` | Шрифт, размер |
| `<link https://…>…</>` | Ссылка (событие `URLProcessing`) |
| `<img StdPicture.Information>` | Картинка в тексте |

Закрывающий тег — всегда `</>`. Разметка распознаётся автоматически; явная форма `{ "text": …, "formatted": true }` нужна, только если текст должен считаться форматированным без видимой разметки.

```json
{ "label": "Предупреждение", "title": "Строки с просрочкой выделены <color web:FireBrick>красным</>" }
```
