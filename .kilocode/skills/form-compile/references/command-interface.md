# Командный интерфейс формы

Форменный ключ `commandInterface` управляет расстановкой команд по двум панелям формы:

- `commandBar` — командная панель формы;
- `navigationPanel` — панель навигации.

Указывать нужно **только команды, у которых меняется расстановка по умолчанию** (видимость, группа, порядок). Команды, которые платформа размещает автоматически и без изменений, в блок не включают.

```json
"commandInterface": {
  "commandBar": [
    { "command": "Form.Command.Печать", "defaultVisible": false, "group": "FormCommandBarImportant",
      "visible": { "common": false, "roles": { "Бухгалтер": true } } },
    "CommonCommand.История"
  ],
  "navigationPanel": {
    "important": [ { "command": "CommonCommand.СвязанныеДокументы", "defaultVisible": false, "visible": false } ],
    "seeAlso":   [ { "command": "CommonCommand.Заметки", "defaultVisible": false, "visible": false } ]
  }
}
```

## Элемент-команда

Каждый элемент панели — объект, либо строка-shorthand (= голый `command` со всеми остальными свойствами по умолчанию):

```json
"CommonCommand.История"
```

| Ключ | Тип | Назначение |
|------|-----|-----------|
| `command` | string | Ссылка на команду дословно: `CommonCommand.X`, `Document.X.StandardCommand.Y`, `Form.Command.X`, `Form.StandardCommand.OK`, `"0"` (пустой / разделитель) |
| `type` | string | `Auto` (по умолчанию, необязательно) или `Added` |
| `defaultVisible` | bool | Видимость по умолчанию. На практике задаётся только `false` — чтобы скрыть команду, которая иначе видна |
| `visible` | bool / object | Видимость с исключениями по ролям: `bool` либо `{ "common": bool, "roles": { "Имя": bool } }` |
| `group` | string | Группа размещения дословно: предопределённая (`FormCommandBarImportant`, `FormNavigationPanelGoTo`, …), именованная (`CommandGroup.X`) или GUID-группа расширения |
| `index` | int | Порядок команды внутри группы |
| `attribute` | string | Путь реквизита для элемента панели навигации |

## Две формы записи панели

Панель можно описать **плоским массивом** или **деревом по группам** — выбирайте любую.

**Плоский массив** — каждый элемент при необходимости несёт собственный `group`:

```json
"commandBar": [
  { "command": "Form.Command.Печать", "group": "FormCommandBarImportant", "defaultVisible": false },
  { "command": "CommonCommand.История", "group": "FormCommandBarImportant", "index": 1 }
]
```

**Дерево** — объект `{ группа: [команды] }`; группа берётся из ключа, элементы её не повторяют:

```json
"navigationPanel": {
  "important": [ "CommonCommand.СвязанныеДокументы" ],
  "goTo":      [ { "command": "Document.Заказ.StandardCommand.Movements", "defaultVisible": false, "visible": false } ],
  "seeAlso":   [ "CommonCommand.Заметки" ]
}
```

Ключи-группы дерева зависят от панели:

- `navigationPanel`: `important`, `goTo`, `seeAlso` (можно по-русски — `важное`, `перейти`, `смТакже`);
- `commandBar`: `important`, `createBasedOn`;
- любой другой ключ (`CommandGroup.X` или GUID) подставляется в группу дословно.

## Скрыть видимую команду

Самый частый случай — убрать команду, которую платформа показывает по умолчанию:

```json
"commandBar": [
  { "command": "Form.Command.Печать", "defaultVisible": false, "visible": false }
]
```

Показать команду только некоторым ролям:

```json
{ "command": "Form.Command.Печать", "defaultVisible": false,
  "visible": { "common": false, "roles": { "Бухгалтер": true } } }
```
