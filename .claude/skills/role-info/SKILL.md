---
name: role-info
description: Компактная сводка прав роли 1С из Rights.xml — объекты, права, RLS, шаблоны ограничений. Используй для аудита прав — какие объекты и действия доступны, ограничения RLS
argument-hint: <RightsPath>
allowed-tools:
  - Bash
  - Read
---

# /role-info — анализ роли 1С

Парсит `Rights.xml` роли и выдаёт компактную сводку: объекты сгруппированы по типу, показаны только разрешённые права. Сжатие: тысячи строк XML → 50–150 строк текста.

## Использование

```
/role-info <RightsPath>
```

**RightsPath** — путь к файлу `Rights.xml` роли (обычно `Roles/ИмяРоли/Ext/Rights.xml`).

## Запуск скрипта

```powershell
powershell.exe -File .claude\skills\role-info\scripts\role-info.ps1 -RightsPath <path> -OutFile <output.txt>
```

### Параметры

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-RightsPath` | да | Путь к Rights.xml |
| `-ShowDenied` | нет | Показать запрещённые права (по умолчанию скрыты) |
| `-Limit` | нет | Макс. строк вывода (по умолчанию `150`). `0` = без ограничений |
| `-Offset` | нет | Пропустить N строк — для пагинации (по умолчанию `0`) |
| `-OutFile` | нет | Записать результат в файл (UTF-8 BOM). Без этого — вывод в консоль |

**Важно:** Всегда используй `-OutFile` и читай результат через Read tool. Прямой вывод в консоль через bash ломает кириллицу.

Для большой роли при усечении вывода:
```powershell
... -Offset 150            # пагинация: пропустить первые 150 строк
```

## Формат вывода

```
=== Role: БазовыеПраваБП --- "Базовые права: Бухгалтерия предприятия" ===

Properties: setForNewObjects=false, setForAttributesByDefault=true, independentRightsOfChildObjects=false

Allowed rights:

  Catalog (8):
    Контрагенты: Read, View, InputByString
    Банки: Read, View, InputByString
    ...

  Document (12):
    РеализацияТоваровУслуг: Read, View, Posting, InteractivePosting
    ...

  InformationRegister (6):
    ЦеныНоменклатуры: Read [RLS], Update
    ...

Denied: 18 rights (use -ShowDenied to list)

RLS: 4 restrictions
Templates: ДляРегистра, ПоЗначениям

---
Total: 138 allowed, 18 denied

[TRUNCATED] Shown 150 of 220 lines. Use -Offset 150 to continue.
```

Используйте `-Offset N` и `-Limit N` для постраничного просмотра.

### Обозначения

- `[RLS]` — право с ограничением на уровне записей (restrictionByCondition)
- `-View`, `-Edit` — запрещённые права (в секции Denied, при `-ShowDenied`)
- Вложенные объекты показываются с суффиксом: `Контрагенты.StandardAttribute.PredefinedDataName`
