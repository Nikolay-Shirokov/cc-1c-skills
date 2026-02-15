---
name: subsystem-validate
description: Валидация подсистемы 1С. Используй после создания или модификации подсистемы для проверки корректности
argument-hint: <SubsystemPath> [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /subsystem-validate — валидация подсистемы 1С

Проверяет структурную корректность XML-файла подсистемы из выгрузки конфигурации.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `SubsystemPath` | Путь к XML-файлу подсистемы |
| `MaxErrors` | Максимум ошибок до остановки (по умолчанию 30) |
| `OutFile` | Записать результат в файл |

```powershell
powershell.exe -NoProfile -File '.claude\skills\subsystem-validate\scripts\subsystem-validate.ps1' -SubsystemPath '<путь>'
```

## Проверки (13)

1. XML well-formedness + root structure (MetaDataObject/Subsystem)
2. Properties — 9 обязательных свойств
3. Name — непустой, валидный идентификатор
4. Synonym — непустой (хотя бы один v8:item)
5. Булевы свойства — содержат true/false
6. Content — формат xr:Item, xsi:type
7. Content — нет дубликатов
8. ChildObjects — элементы непустые
9. ChildObjects — нет дубликатов
10. ChildObjects → файлы существуют
11. CommandInterface.xml — well-formedness
12. Picture — формат ссылки
13. UseOneCommand=true → ровно 1 элемент в Content
