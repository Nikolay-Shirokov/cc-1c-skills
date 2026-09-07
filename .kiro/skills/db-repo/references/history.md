# История версий хранилища

## report — отчёт по версиям

```powershell
python ".kiro/skills/db-repo/scripts/db-repo.py" -Command report -InfoBasePath "C:\Bases\MyDB" -OutputFile "C:\tmp\repo.txt"
```

| Параметр | Описание |
|----------|----------|
| `-OutputFile <путь>` | Куда сохранить отчёт. Необязателен |
| `-NBegin <номер>` | С какой версии. `-1` — только последняя |
| `-NEnd <номер>` | По какую версию |
| `-DateBegin` / `-DateEnd` | Границы по датам |
| `-GroupByObject` | Группировать по объектам |
| `-GroupByComment` | Группировать по комментарию |
| `-ReportFormat <txt\|mxl>` | По умолчанию `txt` |

`txt` — с разделителем-табуляцией, разбирается построчно.

> На боевом хранилище полный отчёт строить не надо — тысячи версий. Нужна головная
> версия — `-NBegin -1`. Длинный отчёт в вывод не печатается: сузьте выборку
> параметрами ниже.

## dump-cfg — выгрузить версию в CF

```powershell
python ".kiro/skills/db-repo/scripts/db-repo.py" -Command dump-cfg -InfoBasePath "C:\Bases\MyDB" -OutputFile "C:\tmp\v120.cf" -Version 120
```

Без `-Version` (или при `-1`) выгружается последняя версия.
