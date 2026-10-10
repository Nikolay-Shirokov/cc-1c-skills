# Свойства формы

Ключ `properties` верхнего уровня. Заголовок формы — отдельный ключ `title` (с ним автозаголовок отключается сам).

```json
{ "title": "Загрузка прайса",
  "properties": { "windowOpeningMode": "LockOwnerWindow", "commandBarLocation": "Bottom", "width": 60 } }
```

## Окно

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `windowOpeningMode` | `Modeless` / `LockOwnerWindow` / `LockWholeInterface` | Блокировать окно-владельца или весь интерфейс (модальный диалог) |
| `width` / `height` | число | Размер окна |
| `showTitle` | bool | Показывать заголовок |
| `showCloseButton` | bool | Кнопка закрытия |
| `saveWindowSettings` | bool | Запоминать размер и положение |
| `verticalScroll` | `Auto` / `useIfNecessary` / `AlwaysShow` / `Never` | Вертикальная прокрутка |
| `scale` | число | Масштаб формы |
| `autoTitle` | bool | Автозаголовок по объекту |
| `autoURL` | bool | Автоматическая навигационная ссылка |

## Раскладка формы

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `commandBarLocation` | `Top` / `Bottom` / `None` | Где командная панель формы |
| `group` | `Vertical` / `HorizontalIfPossible` / `AlwaysHorizontal` | Ориентация элементов верхнего уровня |
| `childItemsWidth` | `Equal` / `LeftWide` / `LeftNarrow` / … | Ширины колонок при горизонтальной раскладке |
| `childrenAlign` | `ItemsLeftTitlesLeft` / `ItemsRightTitlesLeft` / `None` / … | Выравнивание элементов и заголовков |
| `horizontalAlign` / `verticalAlign` | `Left` / `Center` / `Right`; `Top` / `Center` / `Bottom` | Выравнивание содержимого формы |
| `horizontalSpacing` / `verticalSpacing` | `None` / `Half` / `Single` / … | Интервалы |

## Ввод и данные

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `enterKeyBehavior` | `DefaultButton` / `NewLine` | Что делает Enter |
| `autoFillCheck` | bool | Проверять заполнение при записи |
| `saveDataInSettings` | `DontUse` / `Use` / `UseList` | Сохранять значения реквизитов в настройках; какие именно — ключ `save` у реквизита (`references/attributes-advanced.md`) |
| `autoSaveDataInSettings` | `Use` / `DontUse` | Сохранять автоматически |
| `customizable` | bool | Пользователь может настраивать форму |
| `enabled` | bool | Доступность всей формы |

## Форма документа и справочника

| Ключ | Значения | Назначение |
|------|----------|-----------|
| `autoTime` | `CurrentOrLast` / `Current` / `Last` / `DontUse` | Время нового документа |
| `usePostingMode` | `Auto` / `Regular` | Режим проведения |
| `repostOnWrite` | bool | Перепроводить при записи |
| `useForFoldersAndItems` | `Items` / `Folders` / `FoldersAndItems` | Для групп, элементов или тех и других |

Форма отчёта — `references/report-form.md`.

## Исключённые команды формы

```json
{ "excludedCommands": [ "Reread", "Copy", "SetDeletionMark" ] }
```
