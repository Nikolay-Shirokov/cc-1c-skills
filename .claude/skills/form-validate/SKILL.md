---
name: form-validate
description: Валидация управляемой формы 1С. Используй после создания или модификации формы для проверки корректности. При наличии BaseForm автоматически проверяет callType и ID расширений
argument-hint: <FormPath> [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /form-validate — валидация управляемой формы 1С

Проверяет Form.xml на структурные ошибки: уникальность ID, наличие companion-элементов, корректность ссылок DataPath и команд.

## Использование

```
/form-validate Catalogs/Номенклатура/Forms/ФормаЭлемента
/form-validate src/МояОбработка/Forms/Форма/Ext/Form.xml
```

## Параметры

| Параметр  | Обяз. | Умолч. | Описание                                |
|-----------|:-----:|---------|-----------------------------------------|
| FormPath  | да    | —       | Путь к файлу Form.xml                   |
| Detailed  | нет   | —       | Показывать [OK] для каждой проверки      |
| MaxErrors | нет   | 30      | Остановиться после N ошибок              |

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/form-validate/scripts/form-validate.ps1 -FormPath "Catalogs/Номенклатура/Forms/ФормаЭлемента"
```

## Проверки

| # | Проверка | Серьёзность |
|---|---|---|
| 1 | Корневой элемент `<Form>`, version="2.17" | ERROR / WARN |
| 2 | `<AutoCommandBar>` присутствует, id="-1" | ERROR |
| 3 | Уникальность ID элементов (отдельный пул) | ERROR |
| 4 | Уникальность ID реквизитов (отдельный пул) | ERROR |
| 5 | Уникальность ID команд (отдельный пул) | ERROR |
| 6 | Companion-элементы (ContextMenu, ExtendedTooltip, и др.) | ERROR |
| 7 | DataPath → ссылается на существующий реквизит | ERROR |
| 8 | CommandName кнопок → ссылается на существующую команду | ERROR |
| 9 | События имеют непустые имена обработчиков | ERROR |
| 10 | Команды имеют Action (обработчик) | ERROR |
| 11 | Не более одного MainAttribute | ERROR |
| 12 | BaseForm: наличие и version (при расширении) | OK / WARN |
| 13 | callType значения: Before, After, Override | ERROR |
| 14 | ID расширения >= 1000000 для добавленных attrs/commands | WARN |
| 15 | callType без BaseForm — некорректная структура | WARN |

Exit code: 0 = OK, 1 = есть ошибки. По умолчанию краткий вывод. `-Detailed` для поштучной детализации.
