---
name: meta-decompile
description: Декомпиляция объекта метаданных 1С (Catalog.xml и др.) в JSON-черновик в формате meta-compile. Используй для scaffold нового объекта по образцу. Не для точечных правок
argument-hint: <ObjectPath> [-OutputPath <out.json>]
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
---

# /meta-decompile — JSON-черновик из XML объекта метаданных

Читает XML объекта метаданных (`Catalogs/Имя.xml` и т.п.) и эмитит компактный JSON в формате `meta-compile`. **Результат — черновик**, а не обратимое представление.

## Когда использовать

- **Scaffold нового объекта по образцу** — взять существующий объект, получить JSON, поправить и скомпилировать в новый.
- **Структурный обзор** — реквизиты, табличные части, свойства в компактном виде.

## Когда **не** использовать

- **Точечные правки готового объекта** (добавить реквизит, ТЧ) → `/meta-edit`. Цикл «декомпиляция → правка JSON → компиляция» переписывает объект целиком, может терять непокрытые конструкции.

## Параметры

| Параметр | Описание |
|----------|----------|
| `ObjectPath` | Путь к XML объекта (`Catalogs/Имя.xml`), обязательный |
| `OutputPath` | Путь к выходному JSON. Если не задан — JSON в stdout |

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/meta-decompile.ps1" -ObjectPath "<Объект.xml>" -OutputPath "<out.json>"
```

## Что получаешь

JSON-черновик в формате `/meta-compile` — **не полное обратимое представление**: раундтрип `xml → json → xml` не гарантируется, часть конструкций DSL не покрывает.

Неподдерживаемый тип объекта (на текущем этапе — всё, кроме Catalog) или не-MetaDataObject root → скрипт падает с ненулевым кодом и сообщением в stderr.

## Workflow

1. `/meta-decompile <Объект.xml> -OutputPath draft.json` — получить черновик.
2. Поправить JSON под задачу.
3. `/meta-compile -JsonPath draft.json -OutputDir <ConfigDir>` — собрать.
4. `/meta-validate` + `/meta-info` — проверить.
