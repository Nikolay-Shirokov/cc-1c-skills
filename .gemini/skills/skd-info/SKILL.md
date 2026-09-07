---
name: skd-info
description: Анализ структуры схемы компоновки данных 1С (СКД) — наборы, поля, параметры, варианты. Используй для понимания отчёта — источник данных (запрос), доступные поля, параметры
argument-hint: <TemplatePath> [-Mode overview|query|fields|links|calculated|resources|params|variant|templates|trace|full] [-Name <dataset|variant|field|group>] [-Raw]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /skd-info — Анализ схемы компоновки данных

Читает Template.xml схемы компоновки данных (СКД) и выводит компактную сводку. Заменяет необходимость читать тысячи строк XML.

## Параметры и команда

| Параметр | Описание |
|----------|----------|
| `TemplatePath` | Путь к Template.xml или каталогу макета (авто-резолв в `Ext/Template.xml`) |
| `Mode` | Режим анализа (по умолчанию `overview`) |
| `Name` | Имя набора (query), поля (fields/calculated/resources/trace), варианта (variant) или группировки/поля (templates) |
| `Batch` | Номер пакета запроса, 0 = все (только query) |
| `Raw` | (только query) сырой текст запроса целиком, без заголовков/оглавления/разделителей пакетов. Для выгрузки в `.sql` и возврата через `skd-edit set-query @file` |
| `Limit` / `Offset` | Пагинация (по умолчанию 150 строк; `-Raw` не усекается) |
| `OutFile` | Записать результат в файл (UTF-8 BOM) |

```powershell
powershell.exe -NoProfile -File ".gemini/skills/skd-info/scripts/skd-info.ps1" -TemplatePath "<путь>"
```

С указанием режима:
```powershell
... -Mode query -Name НоменклатураСЦенами
... -Mode query -Name ДанныеТ13 -Batch 3
... -Mode query -Name ДанныеТ13 -Raw -OutFile query.sql
... -Mode fields -Name КадастроваяСтоимость
... -Mode calculated -Name КоэффициентКи
... -Mode resources -Name СуммаНалога
... -Mode trace -Name "Коэффициент Ки"
... -Mode variant -Name 1
... -Mode templates
... -Mode templates -Name ВидНалоговойБазы
```

## Режимы

| Режим | Без `-Name` | С `-Name` |
|-------|-------------|-----------|
| `overview` | Навигационная карта схемы + подсказки Next | — |
| `query` | — | Текст запроса набора (с оглавлением батчей); `-Raw` — чистая выгрузка для правки |
| `fields` | Карта: имена полей по наборам | Деталь поля: набор, тип, роль, формат |
| `links` | Все связи наборов | — |
| `calculated` | Карта: имена вычисляемых полей | Выражение + заголовок + ограничения |
| `resources` | Карта: имена ресурсов (`*` = групповые формулы) | Формулы агрегации по группировкам |
| `params` | Таблица параметров: тип, значение, видимость | — |
| `variant` | Список вариантов | Структура группировок + фильтры + вывод |
| `templates` | Карта привязок шаблонов (field/group) | Содержимое шаблона: строки, ячейки, выражения |
| `trace` | — | Полная цепочка: набор → вычисление → ресурс |
| `full` | Полная сводка: overview + query + fields + resources + params + variant | — |

Паттерн: без `-Name` — карта/индекс, с `-Name` — деталь конкретного элемента. Режим `full` объединяет 6 ключевых режимов в один вызов.

## Типичный workflow

1. `overview` — понять структуру, увидеть подсказки
2. `trace -Name <поле>` — узнать как считается колонка отчёта (от заголовка до запроса за один вызов)
3. `query -Name <набор>` — посмотреть текст SQL-запроса
4. `variant -Name <N>` — посмотреть группировки и фильтры варианта

Переработка запроса (round-trip): `query -Name <набор> -Raw -OutFile q.sql` →
правка `q.sql` → `/skd-edit <tpl> -Operation set-query -Value "@q.sql"`. Флаг
`-Raw` отдаёт запрос целиком без декораций, поэтому выгрузка ↔ возврат
точны (включая многопакетные запросы с временными таблицами).

## Верификация

```
/skd-info <path>                            — overview (точка входа)
/skd-info <path> -Mode trace -Name <field>  — трассировка поля
```
