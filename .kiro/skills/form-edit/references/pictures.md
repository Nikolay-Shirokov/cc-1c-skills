# Картинки: декорация, поле-картинка, значки

## Ссылка на картинку

Везде, где ключ ждёт картинку (`src`, `valuesPicture`, `headerPicture`, `footerPicture`, `rowsPicture`, `picture` страницы):

```json
"StdPicture.Information"                                      // картинка платформы
"CommonPicture.Логотип"                                       // общая картинка конфигурации
"abs:Picture.png"                                             // картинка, встроенная в форму
{ "src": "StdPicture.ExecuteTask", "loadTransparent": true }  // с прозрачным фоном
```

У кнопок, подменю и команд `picture` по умолчанию загружается прозрачной; у остальных — нет.

## Картинка-декорация (`picture`)

```json
{ "picture": "Логотип", "src": "CommonPicture.Логотип", "pictureSize": "Proportionally", "width": 20, "height": 5 }
```

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `src` | ссылка | Что показать |
| `pictureSize` | `Proportionally` / `Stretch` / `AutoSize` / `Tile` / `ByFontSize` / `RealSizeIgnoreScale` / `AutoSizeIgnoreScale` | Как вписать в размер элемента |
| `hyperlink` | bool | Кликабельная картинка (событие `Click`) |
| `zoomable` | bool | Можно увеличивать |
| `width` / `height` | число | Размер |

## Поле-картинка (`picField`)

Картинка из данных: изображение из реквизита или значок по значению (булево, число).

```json
{ "picField": "Фото", "path": "Фотография", "pictureSize": "Proportionally" }
{ "picField": "Важно", "path": "Список.Важно", "valuesPicture": "StdPicture.Favorites" }
```

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `valuesPicture` | ссылка | Набор значков по значению. Без него поле, привязанное к булеву или числу, ничего не рисует |
| `nonselectedPictureText` | строка | Текст, когда картинки нет |
| `hyperlink` | bool | Кликабельная (событие `Click`) |

## Значки в таблице

| Ключ | Где | Назначение |
|------|-----|-----------|
| `headerPicture` / `footerPicture` | колонка таблицы | Значок в шапке / подвале колонки |
| `rowsPicture` | таблица | Набор значков строк |

Значок строки динамического списка (`rowPictureDataPath`) — `references/dynamic-list.md`.
