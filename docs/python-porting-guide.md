# Python Porting Guide

Руководство по Python-портам навыков 1С (PS1 → Python).

## Зачем Python рядом с PS1

PowerShell 5.1 доступен только на Windows. Python-порты обеспечивают кроссплатформенность (Linux, Mac). Модель opt-in: PS1 — по умолчанию, Python — переключается скриптами.

## PS1 — мастер-версия

**Приоритет при разработке, доработке, отладке и тестировании — у PS1-скриптов.** Python-порты являются производными копиями. Порядок работы:

1. Вносите изменения в `.ps1`
2. Тестируйте и отлаживайте `.ps1`
3. Переносите готовые изменения в `.py`

Не дорабатывайте `.py` без аналогичного изменения в `.ps1` — они должны оставаться функционально идентичными.

## Переключение рантайма

```bash
# Переключить все .md в навыках на Python
python scripts/switch-to-python.py

# Вернуть на PowerShell
python scripts/switch-to-powershell.py
```

Скрипты обрабатывают все `.md` файлы в `.claude/skills/*/` (SKILL.md, json-dsl.md и др.). Идемпотентны — повторный запуск безопасен. Python-only навыки (img-grid) пропускаются при переключении на PowerShell.

## Принцип самодостаточности

Каждый `.py` — полностью автономен, как и его `.ps1`-аналог. Нет общих модулей. Это соответствует [рекомендациям Anthropic](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices) и зеркалит существующую архитектуру PS1.

Общие утилиты (5-15 строк) дублируются в каждом скрипте:

```python
def esc_xml(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def emit_mltext(lines, indent, tag, text):
    if not text:
        lines.append(f"{indent}<{tag}/>")
        return
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<v8:item>")
    lines.append(f"{indent}\t\t<v8:lang>ru</v8:lang>")
    lines.append(f"{indent}\t\t<v8:content>{esc_xml(text)}</v8:content>")
    lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</{tag}>")

def new_uuid():
    import uuid
    return str(uuid.uuid4())

def read_utf8(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return f.read()

def write_utf8_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)
```

Большие словари данных (синонимы типов, карты объектов) тоже inline — как `$script:typeSynonyms` в PS1.

## Конвенция параметров

Формат `-ParamName` сохранён для минимальных различий в SKILL.md:

```python
parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('-JsonPath', dest='JsonPath', required=True)
parser.add_argument('-NoValidate', dest='NoValidate', action='store_true')
```

Switch-параметры (`-NoValidate`) → `action='store_true'`.

## Таблица маппинга PS → Python

| PS1 | Python |
|-----|--------|
| `$script:xml = New-Object StringBuilder` | `lines = []` |
| `$xml.AppendLine($text)` | `lines.append(text)` |
| `$xml.ToString()` | `'\n'.join(lines)` |
| `[System.Xml.XmlDocument] + PreserveWhitespace` | `lxml.etree.XMLParser(remove_blank_text=False)` |
| `$xmlDoc.SelectSingleNode(xpath, $ns)` | `root.find(xpath, namespaces=NSMAP)` |
| `$xmlDoc.SelectNodes(xpath, $ns)` | `root.findall(xpath, namespaces=NSMAP)` |
| `XmlWriter + MemoryStream + BOM fix` | `etree.tostring(root, xml_declaration=True, encoding='UTF-8')` + declaration fix |
| `[System.Guid]::NewGuid().ToString()` | `str(uuid.uuid4())` |
| `$json \| ConvertFrom-Json` | `json.loads(text)` |
| `ConvertTo-Json -Depth 10` | `json.dumps(obj, ensure_ascii=False, indent=2)` |
| `New-Object System.Text.UTF8Encoding($true)` | `encoding='utf-8-sig'` |
| `Start-Process -Wait -PassThru` | `subprocess.run([...], capture_output=True)` |
| `Start-Process` (без -Wait) | `subprocess.Popen([...])` |
| `[switch]$NoValidate` | `parser.add_argument('-NoValidate', action='store_true')` |
| `[ValidateSet("a","b")]` | `choices=["a","b"]` |
| `Get-ChildItem "path\*\..."` | `glob.glob(...)` |
| `Get-Process httpd` | `psutil.process_iter(['pid','name','exe'])` |
| `Test-Path $path` | `os.path.exists(path)` |
| `Resolve-Path` | `os.path.abspath()` |
| `Join-Path $a $b` | `os.path.join(a, b)` |
| `New-Item -ItemType Directory -Force` | `os.makedirs(path, exist_ok=True)` |
| `Remove-Item -Recurse -Force` | `shutil.rmtree(path)` |
| `Write-Host "text"` | `print("text")` |
| `Write-Error "text"` | `print("text", file=sys.stderr)` |

## lxml vs stdlib

- **Compile/init скрипты** (строковая сборка): только stdlib
- **DOM-скрипты** (edit/validate/info): `lxml` с `XMLParser(remove_blank_text=False)` для сохранения whitespace
- **img-grid**: `Pillow` для чтения PNG/JPEG и отрисовки сетки поверх изображения
- **Web-скрипты**: `psutil` для работы с процессами Apache

Зависимости:
- `lxml>=4.9.0` — ~25 DOM-скриптов
- `Pillow>=10.0.0` — `/img-grid`
- `psutil>=5.9.0` — 4 web-скрипта

## Работа с BOM (UTF-8)

Кодек Python `utf-8-sig` — точный аналог `New-Object System.Text.UTF8Encoding($true)`:
- Запись: добавляет BOM (EF BB BF)
- Чтение: убирает BOM автоматически

```python
# Чтение (BOM убирается)
with open(path, 'r', encoding='utf-8-sig') as f:
    content = f.read()

# Запись (BOM добавляется)
with open(path, 'w', encoding='utf-8-sig', newline='') as f:
    f.write(content)
```

Параметр `newline=''` предотвращает двойные `\r\n` на Windows.

## Сохранение XML с lxml

```python
from lxml import etree

# Загрузка с сохранением whitespace
parser = etree.XMLParser(remove_blank_text=False)
tree = etree.parse(path, parser)
root = tree.getroot()

# Сохранение с BOM
xml_bytes = etree.tostring(tree, xml_declaration=True, encoding='UTF-8')
# Fix declaration: etree пишет одинарные кавычки и uppercase encoding,
# PS1 XmlWriter пишет двойные кавычки и lowercase encoding
xml_bytes = xml_bytes.replace(
    b"<?xml version='1.0' encoding='UTF-8'?>",
    b'<?xml version="1.0" encoding="utf-8"?>')
# Trailing newline (PS1 XmlWriter добавляет, etree — нет)
if not xml_bytes.endswith(b"\n"):
    xml_bytes += b"\n"
with open(path, 'wb') as f:
    f.write(b'\xef\xbb\xbf')  # BOM
    f.write(xml_bytes)
```

## Известные подводные камни

### Namespace в XPath
lxml требует явный namespace map. В PS1 используется `XmlNamespaceManager`:
```python
NSMAP = {'md': 'http://v8.1c.ru/8.3/MDClasses'}
node = root.find('.//md:ChildObjects/md:Form', NSMAP)
```

### d5p1: для ссылочных типов
В DCS-файлах ссылочные типы используют `d5p1:`, не `cfg:`:
```xml
<v8:Type xmlns:d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config">d5p1:CatalogRef.XXX</v8:Type>
```

### XML declaration кавычки и encoding
lxml/etree пишут `<?xml version='1.0' encoding='UTF-8'?>` (одинарные кавычки, uppercase). PS1 XmlWriter пишет `<?xml version="1.0" encoding="utf-8"?>` (двойные, lowercase). 1C принимает оба варианта, но одинарные кавычки — нестандартны. Замена всего declaration — в секции "Сохранение XML с lxml".

### etree vs XmlDocument — различия сериализации

Python etree (lxml и stdlib) сериализует XML иначе, чем PS1 XmlDocument:

| Аспект | PS1 XmlDocument | Python etree | Влияние |
|--------|----------------|--------------|---------|
| Declaration кавычки | `version="1.0"` | `version='1.0'` | Нестандартные одинарные кавычки |
| Encoding case | `encoding="utf-8"` | `encoding='UTF-8'` | Косметическое |
| Self-closing space | `<Tag />` | `<Tag/>` | Косметическое, 1C принимает оба |
| Trailing newline | Да | Нет | Расхождение при побайтовом сравнении |
| Unused xmlns | Сохраняет | Удаляет | Файл валиден, но отличается от канона |
| CR в text content | `\r` as-is | `&#13;` entity | Разный формат, одинаковый смысл |
| Пустые элементы | `<Tag>\n</Tag>` | `<Tag/>` | Косметическое |

Все эти различия обрабатываются `normalizeXmlContent()` в тест-раннере (только для `--runtime python`). PS1 тесты остаются строгими.

### Hashtable vs dict — порядок итерации

PS1 `@{}` (Hashtable) итерирует ключи в порядке хэш-кодов. Python `dict` — в порядке вставки. Если порядок элементов влияет на вывод (присвоение индексов, генерация UUID), используйте `sorted()` в Python **и** `| Sort-Object` в PS1 для детерминизма.

### Regex: (?i) inline flag в Python 3.11+

PS1: `'^(?i)desc$'` — работает. Python 3.11+: `r'^(?i)desc$'` — ошибка. Inline-флаг `(?i)` должен быть в начале строки паттерна: `r'(?i)^desc$'` или `re.IGNORECASE`.

### Обращение к отсутствующим свойствам

PS1 молча возвращает `$null` при обращении к несуществующему свойству (`.empty` на массиве). Python падает с `AttributeError`. Добавляйте `isinstance()` проверки при портировании.

## Платформозависимые заметки

Скрипты `db-*` и `web-*` используют платформу 1С (Designer CLI, Apache) — работают только на Windows. Но синтаксических ошибок на других ОС не будет: скрипт корректно сообщит об отсутствии платформы.

## Добавление нового навыка

Чеклист:
1. Создать `.ps1` скрипт
2. Создать `.py` скрипт с идентичными параметрами
3. В SKILL.md указать `powershell.exe -NoProfile -File ... .ps1` (по умолчанию)
4. Скрипт переключения автоматически подхватит новый навык

## Обновление существующего навыка

При доработке `.ps1`:
1. Применить аналогичные изменения в `.py`
2. Если затронуты inline-утилиты — обновить во всех скриптах: `grep -r "def esc_xml" .claude/skills/`

## Inline-утилиты — полный список

| Функция | Где используется |
|---------|-----------------|
| `esc_xml()` | compile, init, edit, add скрипты |
| `emit_mltext()` | compile, init, add скрипты |
| `new_uuid()` | init, add, compile скрипты |
| `read_utf8()` | все скрипты |
| `write_utf8_bom()` | все скрипты с записью |
| `paginate()` | info скрипты |
| `split_camelcase()` | info скрипты |
