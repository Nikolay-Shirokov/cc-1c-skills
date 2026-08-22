---
name: cfe-validate
description: Валидация расширения конфигурации 1С (CFE). Используй после создания или модификации расширения для проверки корректности
argument-hint: <ExtensionPath> [-ConfigPath <ConfigDir>] [-Detailed] [-MaxErrors 30]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-validate — валидация расширения конфигурации (CFE)

Проверяет структурную корректность расширения: XML-формат, свойства, состав, заимствованные объекты, права ролей. Аналог `/cf-validate`, но для расширений.

## Параметры

| Параметр      | Обяз. | Умолч. | Описание                                        |
|---------------|:-----:|---------|-------------------------------------------------|
| ExtensionPath | да    | —       | Путь к каталогу или Configuration.xml расширения |
| ConfigPath    | нет   | —       | Каталог конфигурации, из которой заимствованы объекты |
| Detailed      | нет   | —       | Подробный вывод (все проверки, включая успешные)  |
| MaxErrors     | нет   | 30      | Остановиться после N ошибок                      |
| OutFile       | нет   | —       | Записать результат в файл                        |

### ConfigPath

Указывай всегда, когда конфигурация-источник доступна: без неё часть ошибок заимствованных форм не ловится, и расширение может пройти валидацию, а потом быть отвергнутым платформой при загрузке.

Если пользователь не указал путь — определи сам:
1. Прочитай `.v8-project.json` из корня проекта
2. Разреши целевую базу (по имени, ветке или `default`)
3. Возьми её поле `configSrc`

## Команда

```powershell
powershell.exe -NoProfile -File ".roo/skills/cfe-validate/scripts/cfe-validate.ps1" -ExtensionPath "src\cfe\extname"
powershell.exe -NoProfile -File ".roo/skills/cfe-validate/scripts/cfe-validate.ps1" -ExtensionPath "src\cfe\extname\Configuration.xml"
powershell.exe -NoProfile -File ".roo/skills/cfe-validate/scripts/cfe-validate.ps1" -ExtensionPath "src\cfe\extname" -ConfigPath "src\cf"
```
