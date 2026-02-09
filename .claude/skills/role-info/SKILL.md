---
name: role-info
description: Компактная сводка прав роли 1С из Rights.xml — объекты, права, RLS, шаблоны ограничений
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
| `-MaxPerGroup` | нет | Макс. объектов на группу (по умолчанию 20). `0` = без ограничений |
| `-OutFile` | нет | Записать результат в файл (UTF-8 BOM). Без этого — вывод в консоль |

**Важно:** Всегда используй `-OutFile` и читай результат через Read tool. Прямой вывод в консоль через bash ломает кириллицу.

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
```

### Обозначения

- `[RLS]` — право с ограничением на уровне записей (restrictionByCondition)
- `-View`, `-Edit` — запрещённые права (в секции Denied, при `-ShowDenied`)
- Вложенные объекты показываются с суффиксом: `Контрагенты.StandardAttribute.PredefinedDataName`
