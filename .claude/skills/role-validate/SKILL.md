---
name: role-validate
description: Валидация структурной корректности роли 1С (Rights.xml) — формат, права, RLS, шаблоны
argument-hint: <RightsPath>
allowed-tools:
  - Bash
  - Read
---

# /role-validate — валидация роли 1С

Проверяет корректность `Rights.xml` роли: формат XML, namespace, глобальные флаги, типы объектов, имена прав, RLS-ограничения, шаблоны. Опционально проверяет метаданные роли (UUID, имя, синоним).

## Использование

```
/role-validate <RightsPath> [MetadataPath]
```

## Запуск скрипта

```powershell
powershell.exe -NoProfile -File .claude\skills\role-validate\scripts\role-validate.ps1 -RightsPath <path> [-MetadataPath <path>] [-OutFile <output.txt>]
```

### Параметры

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-RightsPath` | да | Путь к `Rights.xml` роли |
| `-MetadataPath` | нет | Путь к метаданным роли (`Roles/ИмяРоли.xml`) |
| `-OutFile` | нет | Записать результат в файл (UTF-8 BOM). Без этого — вывод в консоль |

**Важно:** Для кириллических путей используй `-OutFile` и читай результат через Read tool.

## Проверки

### Rights.xml
1. XML well-formed — парсинг без ошибок
2. Корневой элемент `<Rights>` с namespace `http://v8.1c.ru/8.2/roles`
3. Три глобальных флага: `setForNewObjects`, `setForAttributesByDefault`, `independentRightsOfChildObjects`
4. Для каждого `<object>`:
   - `<name>` не пуст
   - Тип объекта распознан (Catalog, Document, InformationRegister и т.д.)
   - Каждое `<right>` имеет `<name>` и `<value>` (`true`/`false`)
   - Имя права валидно для данного типа объекта (с подсказкой при опечатке)
5. Вложенные объекты (3+ сегмента через `.`): допустимы только View, Edit (или Use для IntegrationServiceChannel)
6. RLS `<restrictionByCondition>`: `<condition>` не пуст
7. Шаблоны `<restrictionTemplate>`: `<name>` и `<condition>` не пусты

### Метаданные (опционально)
- Элемент `<Role>` найден
- UUID в корректном формате
- `<Name>` не пуст
- `<Synonym>` присутствует

## Формат вывода

```
Validating: Roles/МояРоль/Ext/Rights.xml
  OK  XML well-formed
  OK  Root element: <Rights> with correct namespace
  OK  3 global flags present
  WARN  Document.Реализация: unknown right 'Rea'. Did you mean: Read?
  OK  12 objects, 45 rights
  OK  2 RLS restrictions
  OK  1 templates: ДляОбъекта

  OK  Metadata: UUID valid (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
  OK  Metadata: Name = МояРоль
  OK  Metadata: Synonym present
---
Result: 0 error(s), 1 warning(s)
```

### Уровни сообщений

| Маркер | Значение |
|--------|----------|
| `OK` | Проверка пройдена |
| `WARN` | Предупреждение (неизвестный тип объекта, подозрительное имя права) |
| `ERR` | Ошибка (невалидный XML, отсутствие обязательных элементов) |

Код возврата: `0` — без ошибок, `1` — есть ошибки.

## Примеры

### Только Rights.xml

```
/role-validate upload/acc_8.3.20/Roles/БазовыеПраваБП/Ext/Rights.xml
```

### С проверкой метаданных

```
/role-validate Roles/МояРоль/Ext/Rights.xml Roles/МояРоль.xml
```

### Верификация после /role-compile

```
/role-compile role.json Roles/
/role-validate Roles/МояРоль/Ext/Rights.xml Roles/МояРоль.xml
```
