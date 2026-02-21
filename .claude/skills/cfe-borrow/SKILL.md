---
name: cfe-borrow
description: Заимствование объектов из конфигурации 1С в расширение (CFE). Используй когда нужно перехватить метод, изменить форму или добавить реквизит к существующему объекту конфигурации
argument-hint: -ExtensionPath <path> -ConfigPath <path> -Object "Catalog.Контрагенты"
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /cfe-borrow — Заимствование объектов из конфигурации

Заимствует объекты из основной конфигурации в расширение. Создаёт XML-файлы с `ObjectBelonging=Adopted` и `ExtendedConfigurationObject`, добавляет запись в ChildObjects расширения.

## Предусловие

Расширение должно быть создано (`/cfe-init`) и содержать валидный `Configuration.xml`.

### Авто-определение ConfigPath

Если пользователь не указал `-ConfigPath` — попробуй определить автоматически:
1. Прочитай `.v8-project.json` из корня проекта
2. Разреши целевую базу (по имени, ветке или `default` — алгоритм из `/db-list`)
3. Если у базы есть поле `configSrc` — используй как `-ConfigPath`
4. Если `configSrc` нет — спроси у пользователя

## Параметры

| Параметр | Описание |
|----------|----------|
| `ExtensionPath` | Путь к каталогу расширения (обязат.) |
| `ConfigPath` | Путь к конфигурации-источнику (обязат.) |
| `Object` | Что заимствовать (обязат.), batch через `;;` |

## Формат -Object

- `Catalog.Контрагенты` — справочник
- `CommonModule.РаботаСФайлами` — общий модуль
- `Document.РеализацияТоваров` — документ
- `Enum.ВидыОплат` — перечисление
- `Catalog.Контрагенты.Form.ФормаЭлемента` — форма объекта (заимствование формы)
- `Catalog.X ;; CommonModule.Y ;; Enum.Z` — несколько объектов
Поддерживаются все 44 типа объектов конфигурации.

### Заимствование форм

Формат `Тип.Имя.Form.ИмяФормы` заимствует форму конкретного объекта. Если родительский объект ещё не заимствован — он будет заимствован автоматически.

Создаётся:
1. **Метаданные формы** — `Forms/ИмяФормы.xml` с `ObjectBelonging=Adopted`, `FormType=Managed`
2. **Form.xml** — `Forms/ИмяФормы/Ext/Form.xml` с копией исходной формы + `<BaseForm>` (начальное состояние)
3. **Module.bsl** — пустой файл `Forms/ИмяФормы/Ext/Form/Module.bsl`
4. **Регистрация** — `<Form>` в ChildObjects родительского объекта

## Команда

```powershell
powershell.exe -NoProfile -File .claude/skills/cfe-borrow/scripts/cfe-borrow.ps1 -ExtensionPath src -ConfigPath C:\cfsrc\erp -Object "Catalog.Контрагенты"
```

## Примеры

```powershell
# Заимствовать один объект
... -ExtensionPath src -ConfigPath C:\cfsrc\erp -Object "Catalog.Контрагенты"

# Заимствовать форму (автоматически заимствует родительский объект)
... -ExtensionPath src -ConfigPath C:\cfsrc\erp -Object "Catalog.Контрагенты.Form.ФормаЭлемента"

# Несколько объектов за раз
... -ExtensionPath src -ConfigPath C:\cfsrc\erp -Object "Catalog.Контрагенты ;; CommonModule.ОбщийМодуль ;; Enum.ВидыОплат"
```

## Верификация

```
/cfe-validate <ExtensionPath>
```

