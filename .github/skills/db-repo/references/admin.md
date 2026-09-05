# Администрирование хранилища

## create — создать хранилище

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command create -InfoBasePath "C:\Bases\MyDB" -RepositoryPath "C:\Repo\MyApp" -RepositoryUser "Admin" -RepositoryPassword "…"
```

| Параметр | Описание |
|----------|----------|
| `-NoBind` | Не подключать базу к созданному хранилищу |
| `-AllowConfigurationChanges` | Включить возможность изменения, если конфигурация на поддержке без неё |
| `-ChangesAllowedRule <правило>` | Правило для объектов, изменения которых разрешены поставщиком |
| `-ChangesNotRecommendedRule <правило>` | То же для «изменения не рекомендуются» |

Правила: `ObjectNotEditable`, `ObjectIsEditableSupportEnabled`, `ObjectNotSupported`.

Без `-NoBind` база сразу подключается к созданному хранилищу. Создание — это версия 1.

Для расширения: `-Extension "<Имя>"` и отдельный путь — у расширения своё хранилище.

## add-user — создать пользователя

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command add-user -InfoBasePath "C:\Bases\MyDB" -NewUser "Ivanov" -NewUserPassword "…" -Rights LockObjects
```

| Право | Что даёт |
|-------|----------|
| `ReadOnly` | Просмотр |
| `LockObjects` | Захват объектов |
| `ManageConfigurationVersions` | Изменение состава версий |
| `Administration` | Административные функции |

`-RestoreDeletedUser` — восстановить одноимённого удалённого. Если пользователь с таким именем
существует, он **не** будет добавлен. Выполняющий должен иметь административные права.

## copy-users — скопировать пользователей из другого хранилища

```powershell
powershell.exe -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/db-repo.ps1" -Command copy-users -InfoBasePath "C:\Bases\MyDB" -SourcePath "\\srv01\repo\Other" -SourceUser "Admin" -SourcePassword "…"
```

`-SourcePath`, `-SourceUser`, `-SourcePassword` описывают хранилище-**источник**. Удалённые пользователи
не копируются; существующие не перезаписываются.
