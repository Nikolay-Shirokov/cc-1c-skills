# Сервисные операции

## set-label — метка на версию

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command set-label -InfoBasePath "C:\Bases\MyDB" -Label "Релиз 1.2" -Version 120 -Comment "Передано в тест"
```

Без `-Version` метка ставится на последнюю версию. Несуществующая версия — ошибка.

## optimize — оптимизация хранения

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command optimize -InfoBasePath "C:\Bases\MyDB"
```

Оптимизирует хранение данных в хранилище. Операция долгая.

## clear-cache — очистка кеша

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command clear-cache -InfoBasePath "C:\Bases\MyDB" -CacheScope local
```

| `-CacheScope` | Что чистит |
|---------------|------------|
| `local` (по умолчанию) | Локальный кеш версий конфигурации |
| `global` | Глобальный кеш версий |
| `db` | Локальную базу данных хранилища |

Пригождается, когда хранилище ведёт себя странно после сбоя сети или отката версии.
