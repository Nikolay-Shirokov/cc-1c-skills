---
name: role-validate
description: Валидация роли 1С. Используй после создания или модификации роли для проверки корректности
argument-hint: <RightsPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
---

# /role-validate — валидация роли 1С

Проверяет корректность `Rights.xml` роли: формат XML, namespace, глобальные флаги, типы объектов, имена прав, RLS-ограничения, шаблоны. Опционально проверяет метаданные роли (UUID, имя, синоним).

## Использование

```
/role-validate Roles/МояРоль
```

## Параметры

| Параметр     | Обяз. | Умолч. | Описание                                        |
|--------------|:-----:|---------|-------------------------------------------------|
| RightsPath   | да    | —       | Путь к роли (директория или `Rights.xml`)        |
| Detailed     | нет   | —       | Показывать [OK] для каждой проверки              |
| MaxErrors    | нет   | 30      | Макс. ошибок до остановки (по умолчанию 30)      |
| OutFile      | нет   | —       | Записать результат в файл (UTF-8 BOM)            |

**Важно:** Для кириллических путей используй `-OutFile` и читай результат через Read tool.

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/role-validate/scripts/role-validate.ps1 -RightsPath "Roles/МояРоль"
```

## Проверки

| # | Проверка | Серьёзность |
|---|----------|-------------|
| 1 | XML well-formed — парсинг без ошибок | ERROR |
| 2 | Корневой элемент `<Rights>` с namespace `http://v8.1c.ru/8.2/roles` | ERROR |
| 3 | Три глобальных флага: setForNewObjects, setForAttributesByDefault, independentRightsOfChildObjects | ERROR |
| 4 | Объекты: name не пуст, тип распознан, права валидны для типа (с подсказкой при опечатке) | ERROR/WARN |
| 5 | Вложенные объекты (3+ сегмента): допустимы только View, Edit (или Use для IntegrationServiceChannel) | ERROR |
| 6 | RLS `<restrictionByCondition>`: condition не пуст | ERROR |
| 7 | Шаблоны `<restrictionTemplate>`: name и condition не пусты | ERROR |
| 8 | Метаданные (если MetadataPath): UUID, Name, Synonym | ERROR/WARN |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
