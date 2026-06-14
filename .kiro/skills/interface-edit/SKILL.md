---
name: interface-edit
description: Настройка командного интерфейса подсистемы 1С. Используй когда нужно скрыть или показать команды, разместить в группах, настроить порядок
argument-hint: <CIPath> <Operation> <Value>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /interface-edit — редактирование CommandInterface.xml

Точечное редактирование файла командного интерфейса подсистемы 1С.

## Параметры

| Параметр | Обяз. | Описание |
|----------|:-----:|----------|
| CIPath | да | Путь к CommandInterface.xml |
| Operation | нет | Операция: hide, show, place, order, subsystem-order, group-order |
| Value | нет | Значение для операции |
| DefinitionFile | нет | JSON-файл с массивом операций (альтернатива Operation) |
| CreateIfMissing | нет | Создать файл если не существует |
| NoValidate | нет | Пропустить авто-валидацию |

## Команда

### Inline mode

```powershell
python ".kiro/skills/interface-edit/scripts/interface-edit.py" -CIPath '<path>' -Operation hide -Value '<cmd>'
```

### JSON mode

```powershell
python ".kiro/skills/interface-edit/scripts/interface-edit.py" -CIPath '<path>' -DefinitionFile '<json>'
```

## Операции

| Операция | Значение | Описание |
|----------|----------|----------|
| hide | Cmd.Name или массив | Скрыть команду (CommandsVisibility, false) |
| show | Cmd.Name или массив | Показать команду (visibility, true) |
| place | {"command":"...","group":"CommandGroup.X"} | Разместить команду в группе |
| order | {"group":"...","commands":[...]} | Задать порядок команд в группе |
| subsystem-order | ["Subsystem.X.Subsystem.A",...] | Порядок дочерних подсистем |
| group-order | ["NavigationPanelOrdinary",...] | Порядок групп |

## Примеры

```powershell
# Скрыть команду
... -CIPath Subsystems/Продажи/Ext/CommandInterface.xml -Operation hide -Value "Catalog.Товары.StandardCommand.OpenList"

# Показать команду
... -Operation show -Value "Report.Продажи.Command.Отчёт"

# Разместить в группе
... -Operation place -Value '{"command":"Report.X.Command.Y","group":"CommandGroup.Отчеты"}'

# Задать порядок подсистем
... -Operation subsystem-order -Value '["Subsystem.X.Subsystem.A","Subsystem.X.Subsystem.B"]'

# Создать новый CI
... -CIPath <new-path> -Operation subsystem-order -Value '[...]' -CreateIfMissing
```

## Верификация

```
/interface-validate <CIPath>
```
