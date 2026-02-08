---
name: epf-build
description: Собрать внешнюю обработку 1С (EPF) из XML-исходников
argument-hint: <ProcessorName>
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# /epf-build — Сборка обработки

Собирает EPF-файл из XML-исходников с помощью платформы 1С.

## Usage

```
/epf-build <ProcessorName> [SrcDir] [OutDir]
```

| Параметр      | Обязательный | По умолчанию | Описание                             |
|---------------|:------------:|--------------|--------------------------------------|
| ProcessorName | да           | —            | Имя обработки (имя корневого XML)    |
| SrcDir        | нет          | `src`        | Каталог исходников                   |
| OutDir        | нет          | `build`      | Каталог для результата               |

## Переменные окружения

| Переменная | Описание                              | Пример                                        |
|------------|---------------------------------------|-----------------------------------------------|
| V8_PATH    | Каталог bin платформы 1С              | `C:\Program Files\1cv8\8.3.25.1257\bin`       |
| V8_BASE    | Путь к пустой файловой ИБ            | `.\base`                                      |

## Команды

### 1. Создать пустую ИБ (если нет)

```cmd
"%V8_PATH%\1cv8.exe" CREATEINFOBASE File="%V8_BASE%"
```

### 2. Сборка EPF из XML

```cmd
"%V8_PATH%\1cv8.exe" DESIGNER /F "%V8_BASE%" /DisableStartupDialogs /LoadExternalDataProcessorOrReportFromFiles "<SrcDir>\<ProcessorName>.xml" "<OutDir>\<ProcessorName>.epf" /Out "<OutDir>\build.log"
```

## Коды возврата

| Код | Описание                    |
|-----|-----------------------------|
| 0   | Успешная сборка             |
| 1   | Ошибка (см. лог)           |

## Автоопределение платформы (Windows)

Если `V8_PATH` не задан, можно найти автоматически:

```powershell
$v8 = Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort-Object -Descending | Select-Object -First 1
```

## Пример полного цикла

```powershell
$env:V8_PATH = "C:\Program Files\1cv8\8.3.25.1257\bin"
$env:V8_BASE = ".\base"

# Создать ИБ
& "$env:V8_PATH\1cv8.exe" CREATEINFOBASE "File=$env:V8_BASE"

# Собрать
& "$env:V8_PATH\1cv8.exe" DESIGNER /F $env:V8_BASE /DisableStartupDialogs /LoadExternalDataProcessorOrReportFromFiles "src\МояОбработка.xml" "build\МояОбработка.epf" /Out "build\build.log"
```