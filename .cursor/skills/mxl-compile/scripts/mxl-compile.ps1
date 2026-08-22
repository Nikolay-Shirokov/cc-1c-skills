# mxl-compile v1.55 — Compile 1C spreadsheet from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"

# --- Разбор пользовательского JSON ---
# Одна строка в stderr вместо дампа исключения ConvertFrom-Json (issue #80): агент по стектрейсу
# идёт чинить скрипт, а не свой вызов. $source — файл или параметр. $expected заполняем только
# для полиморфного входа: у файла подсказка была бы наполнителем. -Inline печатает ещё и то,
# что доехало: у файла такого вопроса нет — путь назван, позицию дал парсер, файл на диске.
# Возврат через -NoEnumerate: без него одноэлементный
# JSON-массив разворачивался бы в скаляр вторым анруллингом.
function ConvertFrom-JsonInput([string]$text, [string]$source, [string]$expected, [switch]$Inline) {
	try {
		# PS 5.1 на пустой строке отдаёт $null, а не ошибку — навык уходил дальше с $null,
		# тогда как py-порт падал. Проверяем сами, чтобы порты вели себя одинаково.
		if ([string]::IsNullOrWhiteSpace($text)) { throw 'input is empty' }
		$parsed = $text | ConvertFrom-Json
	} catch {
		$what = if ($expected) { "$source expects $expected" } else { "Invalid JSON in $source" }
		if ($Inline) {
			$got = ($text -replace '\s+', ' ').Trim()
			$label = 'got'
			if (-not $got) { $got = '(empty)' }
			elseif ($got.Length -gt 60) { $label = 'got (first 60 chars)'; $got = $got.Substring(0, 60) }
			$what = "${what}, ${label}: ${got}"
		}
		[Console]::Error.WriteLine("[ERROR] ${what} ($($_.Exception.Message))")
		exit 1
	}
	Write-Output -NoEnumerate $parsed
}

# --- Чтение входного JSON-файла ---
# Кодировку берём из BOM — это объявление самого файла, а не догадка. Без BOM ждём строгий UTF-8:
# Get-Content -Encoding UTF8 на файле в cp1251 тихо меняет кириллицу на U+FFFD, JSON после этого
# разбирается успешно, и в конфигурацию уезжает имя из «замен». Кодовую страницу не подбираем:
# угаданное имя уйдёт в метаданные так же молча.
function Read-JsonInputFile([string]$path) {
	# Проверка здесь, а не по навыкам: часть навыков проверяла путь сама, часть — нет, и один и тот
	# же промах давал то внятную строку, то дамп MethodInvocationException. Навыки со своей
	# проверкой срабатывают раньше и сохраняют свой текст.
	if (-not (Test-Path -LiteralPath $path)) {
		[Console]::Error.WriteLine("[ERROR] File not found: $path")
		exit 1
	}
	if (Test-Path -LiteralPath $path -PathType Container) {
		[Console]::Error.WriteLine("[ERROR] Expected a JSON file, got a directory: $path")
		exit 1
	}
	$bytes = [System.IO.File]::ReadAllBytes($path)
	if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
		return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
		return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
		return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	try {
		return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
	} catch {
		$detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
		[Console]::Error.WriteLine("[ERROR] ${path} is not valid UTF-8: ${detail} - save the file as UTF-8, or add a BOM if it is UTF-16")
		exit 1
	}
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# --- Detect XML format version ---
# У корня <document> нет атрибута version, поэтому версию берём из конфигурации, в дерево
# которой пишем макет. Вне конфигурации (автономный .xml, исходники EPF) остаётся 2.17.

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

$script:outPathResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
$script:formatVersion = Detect-FormatVersion ([System.IO.Path]::GetDirectoryName($script:outPathResolved))

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	[Console]::Error.WriteLine("File not found: $JsonPath")
	exit 1
}

$json = Read-JsonInputFile $JsonPath
$def = ConvertFrom-JsonInput $json $JsonPath

# Проверяем НАЛИЧИЕ ключа, а не истинность значения: `columns: 0` — осмысленная величина
# (раскладка по умолчанию пустая, все строки живут в именованных раскладках), а пустой
# список областей встречается у макета без строк. Прежняя проверка `-not` объявляла и то
# и другое отсутствующим.
if (-not $def.PSObject.Properties['columns'] -or $null -eq $def.columns) {
	[Console]::Error.WriteLine("Required field 'columns' is missing")
	exit 1
}
if (-not $def.PSObject.Properties['areas'] -or $null -eq $def.areas) {
	[Console]::Error.WriteLine("Required field 'areas' is missing")
	exit 1
}

$totalColumns = [int]$def.columns
$defaultWidth = if ($def.defaultWidth) { [int]$def.defaultWidth } else { 10 }

# --- 2. Build font palette ---

$fontMap = [ordered]@{}   # name -> 0-based index
$fontEntries = @()        # array of hashtables

# Размер шрифта бывает дробным (8.3, 11.3). [int] его ТИХО округлял. Читаем инвариантной
# культурой и держим целым, когда дробной части нет, — иначе "10" стало бы "10.0".
function ConvertTo-FontSize {
	param($raw)
	$s = [string]$raw
	if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
	$d = 0.0
	if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 0 }
	if ($d -eq [math]::Floor($d)) { return [int]$d }
	return $d
}

# Число в XML-атрибут: интерполяция строкой отдала бы "8,3" под русской культурой.
function Format-Num {
	param($v)
	return [System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture)
}

# Шрифт бывает не собственным, а ссылкой: на элемент стиля конфигурации (style:) или на
# системный шрифт (sys:). Вид ссылки определяет kind, и он выводится из префикса.
function Get-FontRefKind {
	param([string]$ref)
	if ($ref -like 'sys:*') { return 'WindowsFont' }
	return 'StyleItem'
}

function Add-Font {
	param([string]$name, $fontDef)
	if ($fontDef.ref) {
		$script:fontMap[$name] = $script:fontEntries.Count
		$script:fontEntries += @{ Ref = "$($fontDef.ref)"; Kind = (Get-FontRefKind "$($fontDef.ref)") }
		return
	}
	$face = if ($fontDef.face) { $fontDef.face } else { "Arial" }
	$size = if ($fontDef.size) { ConvertTo-FontSize $fontDef.size } else { 10 }
	$bold = if ($fontDef.bold -eq $true) { "true" } else { "false" }
	$italic = if ($fontDef.italic -eq $true) { "true" } else { "false" }
	$underline = if ($fontDef.underline -eq $true) { "true" } else { "false" }
	$strikeout = if ($fontDef.strikeout -eq $true) { "true" } else { "false" }

	$idx = $script:fontEntries.Count
	$script:fontMap[$name] = $idx
	$script:fontEntries += @{
		Face      = $face
		Size      = $size
		Bold      = $bold
		Italic    = $italic
		Underline = $underline
		Strikeout = $strikeout
	}
}

# Add user-defined fonts
$hasDefault = $false
if ($def.fonts) {
	foreach ($prop in $def.fonts.PSObject.Properties) {
		if ($prop.Name -eq "default") { $hasDefault = $true }
		Add-Font -name $prop.Name -fontDef $prop.Value
	}
}

# Ensure default font exists
if (-not $hasDefault) {
	$defaultDef = New-Object PSObject -Property @{ face = "Arial"; size = 10 }
	Add-Font -name "default" -fontDef $defaultDef
}

# --- 3. Line palette ---
# Рамка хранится не в формате, а в палитре <line>: формат ссылается на запись индексом.
# Запись — тройка (стиль, ширина, gap); в корпусе gap всегда false, но тег платформа пишет.
$script:lineRegistry = @()

function Get-LineKey {
	# Вид линии входит в ключ: одинаковые по стилю линии рамки ячейки и рисунка — РАЗНЫЕ записи,
	# у них разный xsi:type.
	param($ln)
	return "$($ln.Style)|$($ln.Width)|$($ln.Gap)|$($ln.Kind)"
}

function Register-Line {
	# Запись палитры линий типизирована: у рамки ячейки xsi:type Cell, у линии рисунка Drawing.
	# Вид выводится из свойства, которое на линию ссылается, — отдельного ключа в DSL не нужно.
	param($ln)
	$key = Get-LineKey $ln
	for ($i = 0; $i -lt $script:lineRegistry.Count; $i++) {
		if ((Get-LineKey $script:lineRegistry[$i]) -ceq $key) { return $i }
	}
	$script:lineRegistry += $ln
	return $script:lineRegistry.Count - 1
}

function Get-LineStyles {
	# Палитра линий одна на документ, а Конфигуратор предлагает РАЗНЫЕ наборы: у рамки ячейки
	# свой (сплошная, точечная, штриховые, двойная), у линии рисунка свой (пунктирная,
	# пунктирно-точечная, точечно-пунктирно-точечная). Домен — объединение: перечень, снятый
	# только с корпуса, отвергал стили рисунков.
	return @('None', 'Solid', 'Dashed', 'Dotted', 'DashDotted', 'DashDottedDotted', 'ThinDashed', 'LargeDashed', 'ThickDashed', 'Double')
}

# --- 4. Parse column width specs ---

function Parse-ColumnSpec {
	param([string]$spec)
	$cols = @()
	foreach ($part in $spec -split ',') {
		$part = $part.Trim()
		if ($part -match '^(\d+)-(\d+)$') {
			$from = [int]$Matches[1]
			$to = [int]$Matches[2]
			for ($i = $from; $i -le $to; $i++) { $cols += $i }
		} else {
			$cols += [int]$part
		}
	}
	return $cols
}

# --- 4a. Auto-calculate defaultWidth from page format ---

$pageTargets = @{
	"A4-landscape" = 780
	"A4-portrait"  = 540
}

if ($def.page) {
	$pageName = "$($def.page)"
	$targetWidth = $null

	if ($pageName -match '^\d+$') {
		$targetWidth = [int]$pageName
	} elseif ($pageTargets.ContainsKey($pageName)) {
		$targetWidth = $pageTargets[$pageName]
	} else {
		Write-Warning "Unknown page format '$pageName'. Known: $($pageTargets.Keys -join ', '), or a number."
	}

	if ($targetWidth) {
		$totalUnits = 0.0
		$absoluteSum = 0
		$specifiedCols = @{}

		if ($def.columnWidths) {
			foreach ($prop in $def.columnWidths.PSObject.Properties) {
				$val = "$($prop.Value)"
				$cols = Parse-ColumnSpec $prop.Name
				foreach ($c in $cols) {
					$specifiedCols[[int]$c] = $true
					if ($val -match '^([0-9.]+)x$') {
						$totalUnits += [double]$Matches[1]
					} else {
						$absoluteSum += [int]$val
					}
				}
			}
		}

		for ($c = 1; $c -le $totalColumns; $c++) {
			if (-not $specifiedCols.ContainsKey($c)) {
				$totalUnits += 1.0
			}
		}

		if ($totalUnits -gt 0) {
			$defaultWidth = [int][math]::Round(($targetWidth - $absoluteSum) / $totalUnits)
		}
	}
}

# Build column width map: 1-based col -> width
function Build-ColWidthMap {
	param($widths)
	$map = @{}
	if ($widths) {
		foreach ($prop in $widths.PSObject.Properties) {
			$val = "$($prop.Value)"
			if ($val -match '^([0-9.]+)x$') {
				$width = [int][math]::Round([double]$Matches[1] * $defaultWidth)
			} else {
				$width = [int]$val
			}
			foreach ($c in (Parse-ColumnSpec $prop.Name)) { $map[$c] = $width }
		}
	}
	return $map
}

$colWidthMap = Build-ColWidthMap $def.columnWidths

# Стиль колонки — тот же именованный стиль, что у ячейки и строки: колонка третий владелец
# формата, и своих свойств у неё нет. Ключи те же, что у columnWidths.
function Build-ColStyleMap {
	param($styles)
	$map = @{}
	if ($styles) {
		foreach ($prop in $styles.PSObject.Properties) {
			# Пустое значение = колонка перечислена, формата у неё нет. Записи для авторинга
			# в этом смысла нет, поэтому в описании DSL её не показываем — она нужна
			# декомпилятору, чтобы раундтрип не терял байты.
			$v = if ($null -eq $prop.Value) { $null } else { "$($prop.Value)" }
			foreach ($c in (Parse-ColumnSpec $prop.Name)) { $map[$c] = $v }
		}
	}
	return $map
}

$colStyleMap = Build-ColStyleMap $def.columnStyles

# Колоночные раскладки: документные columns/columnWidths — раскладка по умолчанию (в XML
# элемент <columns> БЕЗ <id>, он всегда идёт первым). Дополнительные объявляются в
# columnSets, ключ — идентификатор, на него ссылается область ключом columnSet.
# Склейки по содержимому нет: в корпусе полно раскладок с одинаковым содержимым и разными
# идентификаторами, поэтому опознаёт раскладку только идентификатор.
# Платформа хранит идентификатор раскладки как UUID и другой не принимает. Имя из
# columnSets, полученное декомпиляцией, уже UUID — оставляем как есть, иначе раундтрип
# перестал бы совпадать. Читаемое имя, написанное автором, превращаем в UUID ДЕТЕРМИНИРОВАННО
# (из хэша имени), чтобы повторная компиляция давала тот же файл.
function ConvertTo-LayoutId {
	param([string]$name)
	if ($name -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
		return $name
	}
	# UUID версии 3 (имя + MD5, RFC 4122): биты версии и варианта проставляются, иначе это
	# не UUID, а просто шестнадцатеричная строка нужной формы.
	$md5 = [System.Security.Cryptography.MD5]::Create()
	$b = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name))
	$b[6] = [byte](($b[6] -band 0x0F) -bor 0x30)   # версия 3
	$b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)   # вариант RFC 4122
	$h = ($b | ForEach-Object { $_.ToString('x2') }) -join ''
	return "$($h.Substring(0,8))-$($h.Substring(8,4))-$($h.Substring(12,4))-$($h.Substring(16,4))-$($h.Substring(20,12))"
}

$columnLayouts = @()
$columnLayouts += @{ Id = $null; Name = $null; Size = $totalColumns; Widths = $colWidthMap; Styles = $colStyleMap }
if ($def.columnSets) {
	foreach ($prop in $def.columnSets.PSObject.Properties) {
		$cs = $prop.Value
		$size = if ($cs.columns) { [int]$cs.columns } else { $totalColumns }
		$columnLayouts += @{
			Id     = ConvertTo-LayoutId $prop.Name
			Name   = $prop.Name
			Size   = $size
			Widths = Build-ColWidthMap $cs.columnWidths
			Styles = Build-ColStyleMap $cs.columnStyles
		}
	}
}

# --- 5. Style resolver ---

# Значение рамки: строка стиля ("Dotted") либо объект { style, width, gap }.
# Прежняя запись borderWidth: thin/thick — это ширина 1 и 2.
function ConvertTo-LineValue {
	param($val, [string]$where)
	$style = 'Solid'; $width = 1; $gap = 'false'
	if ($val -is [string] -or $val -is [int]) {
		$style = "$val"
	} else {
		if ($null -ne $val.style) { $style = "$($val.style)" }
		if ($null -ne $val.width) { $width = "$($val.width)" }
		if ($null -ne $val.gap) { $gap = if ($val.gap -eq $true) { 'true' } else { 'false' } }
	}
	if ($style -ceq 'thin') { $style = 'Solid'; $width = 1 }
	elseif ($style -ceq 'thick') { $style = 'Solid'; $width = 2 }
	$canon = Get-LineStyles | Where-Object { $_ -eq $style } | Select-Object -First 1
	if (-not $canon) {
		[Console]::Error.WriteLine("Unknown border style `"$style`" ($where). Allowed: $((Get-LineStyles) -join ', ')")
		exit 1
	}
	return @{ Style = $canon; Width = $width; Gap = $gap }
}

# Цвет — значение с префиксом пространства имён (нотация платформы). style: объявлен в корне
# документа, web/win — нет, поэтому платформа дописывает объявление прямо на узел.
function Get-ColorNamespace {
	param([string]$val)
	if ($val -like 'web:*') { return 'http://v8.1c.ru/8.1/data/ui/colors/web' }
	if ($val -like 'win:*') { return 'http://v8.1c.ru/8.1/data/ui/colors/windows' }
	return ''
}

# Стиль строки: имя строкой либо объект { style, apply }. apply — куда лёг стиль:
# "both" (умолчание) — и в формат строки, и в форматы ячеек, как пишет платформа, когда
# автор оформляет строку целиком; "row" — только строке (так хранится, например, скрытие);
# "cells" — только ячейкам. Модификатор нужен раундтрипу, в описании DSL его нет.
function Get-RowStyleSpec {
	param($val, [string]$where)
	if ($null -eq $val) { return @{ Name = $null; Apply = 'both' } }
	if ($val -is [string]) { return @{ Name = $val; Apply = 'both' } }
	$name = "$($val.style)"
	$apply = if ($val.apply) { "$($val.apply)".ToLower() } else { 'both' }
	if ($apply -notin @('both', 'row', 'cells')) {
		[Console]::Error.WriteLine("Unknown 'apply' value `"$($val.apply)`" ($where). Allowed: both, row, cells")
		exit 1
	}
	if (-not $name) {
		[Console]::Error.WriteLine("rowStyle object requires 'style' ($where)")
		exit 1
	}
	return @{ Name = $name; Apply = $apply }
}

# Формат самой строки: собственные свойства строки (высота, скрытие) плюс стиль строки,
# если он ложится на строку. Пустой набор = у строки формата нет.
function Get-RowFormatProps {
	param($row)
	$props = @{}
	$spec = Get-RowStyleSpec $row.rowStyle "row"
	if ($spec.Name -and $spec.Apply -cne 'cells') {
		$props = Resolve-Style -styleName $spec.Name -fillType ""
	}
	if ($row.height) { $props['height'] = [int]$row.height }
	if ($row.hidden -eq $true) { $props['hidden'] = 'true' }
	return $props
}

function Resolve-Style {
	param([string]$styleName, [string]$fillType)

	# Набор свойств формата — «тег платформы → значение», только заданные. Порядок вставки
	# роли не играет: и ключ дедупликации, и эмиссия идут по каноническому порядку тегов.
	# <font> пишем только когда стиль задал шрифт: треть форматов корпуса (23 003 из 69 581)
	# обходится без него, а мы раньше подставляли шрифт по умолчанию всегда.
	$props = @{}

	if ($styleName -and $def.styles) {
		$style = $def.styles.$styleName
		if ($style) {
			$kinds = Get-FormatTagKind
			$enums = Get-FormatEnumValues
			$synonyms = Get-StyleKeySynonyms
			$where = "style `"$styleName`""

			# Прежняя запись рамки: стороны строкой + borderWidth. Разворачиваем в посторонние
			# ключи ДО общего разбора, чтобы дальше был один путь.
			$sideKeys = @{ left = 'leftBorder'; top = 'topBorder'; right = 'rightBorder'; bottom = 'bottomBorder' }
			$legacyBorder = $style.border
			if ($legacyBorder -is [string] -and $legacyBorder -and (Get-LineStyles | Where-Object { $_ -eq $legacyBorder }).Count -eq 0) {
				$ln = ConvertTo-LineValue @{ style = 'Solid'; width = $(if ("$($style.borderWidth)" -ceq 'thick') { 2 } else { 1 }) } $where
				$idx = Register-Line $ln
				foreach ($side in ($legacyBorder -split ',')) {
					$s = $side.Trim().ToLower()
					if ($s -eq 'none') { continue }
					if ($s -eq 'all') {
						foreach ($k in $sideKeys.Values) { $props[$k] = $idx }
					} elseif ($sideKeys.ContainsKey($s)) {
						$props[$sideKeys[$s]] = $idx
					} else {
						[Console]::Error.WriteLine("Unknown border side `"$($side.Trim())`" ($where). Allowed: all, left, top, right, bottom, none")
						exit 1
					}
				}
			}

			foreach ($p in $style.PSObject.Properties) {
				$raw = $p.Name
				# Синонимы: канон побеждает, сравнение без регистра и пробелов.
				$norm = ($raw -replace '\s', '').ToLower()
				$tag = if ($synonyms.ContainsKey($norm)) { $synonyms[$norm] } else { $raw }
				if ($tag -ceq 'borderWidth') { continue }
				if ($tag -ceq 'border' -and $legacyBorder -is [string] -and
					(Get-LineStyles | Where-Object { $_ -eq $legacyBorder }).Count -eq 0) { continue }

				$val = $p.Value
				if ($null -eq $val -or ($val -is [string] -and $val -eq '')) { continue }

				if ($tag -ceq 'font') {
					if ($fontMap.Contains("$val")) { $props['font'] = $fontMap["$val"] }
					continue
				}
				# wrap — не имя, а сокращение: булево вместо перечисления textPlacement.
				if ($tag -ceq 'wrap') {
					if ($val -eq $true -or "$val" -eq 'true') { $props['textPlacement'] = 'Wrap' }
					continue
				}
				if (-not $kinds.ContainsKey($tag)) {
					Write-Warning "Unknown style key '$raw' ($where) — ignored."
					continue
				}
				switch ($kinds[$tag]) {
					'line' {
						$lnVal = ConvertTo-LineValue $val $where
						$lnVal['Kind'] = if ($tag -ceq 'drawingBorder') { 'Drawing' } else { 'Cell' }
						$props[$tag] = Register-Line $lnVal
					}
					'bool' { $props[$tag] = if ($val -eq $true -or "$val" -eq 'true') { 'true' } else { 'false' } }
					'int'  { $props[$tag] = [int]$val }
					'enum' {
						$allowed = $enums[$tag]
						$canon = $allowed | Where-Object { $_ -eq "$val" } | Select-Object -First 1
						if (-not $canon) {
							[Console]::Error.WriteLine("Unknown '$tag' value `"$val`" ($where). Allowed: $($allowed -join ', ')")
							exit 1
						}
						$props[$tag] = $canon
					}
					default { $props[$tag] = "$val" }
				}
			}
		}
	}

	if ($fillType) { $props['fillType'] = $fillType }

	# Одинаковые четыре стороны платформа пишет одним <border>. Правило проверено на корпусе:
	# 70 265 свёрнутых форматов, 36 783 записанных по сторонам — и среди вторых нет ни одного
	# с четырьмя совпадающими значениями.
	$sides = @('leftBorder', 'topBorder', 'rightBorder', 'bottomBorder')
	$present = @($sides | Where-Object { $props.ContainsKey($_) })
	if ($present.Count -eq 4) {
		$vals = @($sides | ForEach-Object { $props[$_] } | Select-Object -Unique)
		if ($vals.Count -eq 1) {
			foreach ($s in $sides) { $props.Remove($s) }
			$props['border'] = $vals[0]
		}
	}
	return $props
}

# --- 5.9. Ячейка-поле ввода: тип значения и элемент управления ---
# containsValue/valueType/controlType платформа держит в записи палитры формата, но принадлежат
# они конкретной ЯЧЕЙКЕ: на корпусе ERP 370 197 ссылок на такие записи — все из <f>, ни одной
# из строки, колонки или defaultFormatIndex. Поэтому в DSL это ключи ячейки, а не стиля.

# Прощающий ввод типа — общая семья Resolve-TypeStr (эталон meta-compile). Словарь синонимов
# у каждого навыка свой: здесь только то, что бывает значением ячейки макета.
$script:typeSynonyms = @{}
$script:typeSynonyms["число"]    = "Number"
$script:typeSynonyms["строка"]   = "String"
$script:typeSynonyms["булево"]   = "Boolean"
$script:typeSynonyms["дата"]     = "Date"
$script:typeSynonyms["датавремя"] = "DateTime"
$script:typeSynonyms["время"]    = "Time"
$script:typeSynonyms["number"]   = "Number"
$script:typeSynonyms["string"]   = "String"
$script:typeSynonyms["boolean"]  = "Boolean"
$script:typeSynonyms["bool"]     = "Boolean"
$script:typeSynonyms["date"]     = "Date"
$script:typeSynonyms["datetime"] = "DateTime"
$script:typeSynonyms["time"]     = "Time"
$script:typeSynonyms["справочникссылка"]             = "CatalogRef"
$script:typeSynonyms["документссылка"]               = "DocumentRef"
$script:typeSynonyms["перечислениессылка"]           = "EnumRef"
$script:typeSynonyms["плансчетовссылка"]             = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"
$script:typeSynonyms["планвидоврасчётассылка"]       = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планвидоврасчетассылка"]       = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планобменассылка"]             = "ExchangePlanRef"
$script:typeSynonyms["бизнеспроцессссылка"]          = "BusinessProcessRef"
$script:typeSynonyms["задачассылка"]                 = "TaskRef"
$script:typeSynonyms["любаяссылка"]                  = "AnyRef"
$script:typeSynonyms["catalogref"]                   = "CatalogRef"
$script:typeSynonyms["documentref"]                  = "DocumentRef"
$script:typeSynonyms["enumref"]                      = "EnumRef"
$script:typeSynonyms["anyref"]                       = "AnyRef"
$script:typeSynonyms["определяемыйтип"]              = "DefinedType"
$script:typeSynonyms["definedtype"]                  = "DefinedType"

# Голые метатипы-категории («любой объект категории») — множество, а не тип: <v8:TypeSet>.
$script:valueTypeSets = @('CatalogRef', 'DocumentRef', 'EnumRef', 'ChartOfAccountsRef',
	'ChartOfCharacteristicTypesRef', 'ChartOfCalculationTypesRef', 'ExchangePlanRef',
	'BusinessProcessRef', 'TaskRef', 'AnyRef', 'AnyIBRef')
# Категории ссылочных типов с именем объекта — <v8:Type>.
$script:valueRefKinds = @('CatalogRef', 'DocumentRef', 'EnumRef', 'ChartOfAccountsRef',
	'ChartOfCharacteristicTypesRef', 'ChartOfCalculationTypesRef', 'ExchangePlanRef',
	'BusinessProcessRef', 'BusinessProcessRoutePointRef', 'TaskRef')

# Элемент управления. В выгрузке — GUID, имён у платформы в XML нет вовсе, поэтому канон DSL
# придуман: input и checkbox. Умолчание платформы — поле ввода для ВСЕХ типов, включая Булево
# (корпус: 63 629 форматов против 7 у флажка), поэтому input не пишем в XML как «по умолчанию»,
# а эмитим всегда — так делает платформа.
$script:valueControlGuids = @{
	'input'    = '381ed624-9217-4e63-85db-c4c3cb87daae'
	'checkbox' = '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26'
}
$script:valueControlSynonyms = @{
	# Ключи нормализованы: без пробелов, в нижнем регистре («Поле ввода» → «полеввода»).
	'полеввода' = 'input'; 'inputfield' = 'input'
	'полефлажка' = 'checkbox'; 'флажок' = 'checkbox'; 'checkboxfield' = 'checkbox'
}

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Прощающий ввод: ведущий префикс приходит копипастой из выгрузки. Без срезания он ломает
	# поиск в словаре — русское имя типа остаётся непереведённым, и платформа отвечает
	# «Неизвестное имя типа». cfg: снимаем всегда — он однозначно означает текущую конфигурацию.
	# Сгенерированный dNpM: (в корпусе на этом URI встречаются d4p1, d5p1, d6p1 — имя префикса
	# платформа выдаёт по порядку объявления) снимаем ТОЛЬКО у ссылочных типов, с точкой:
	# сам по себе префикс многозначен — в формах d5p1:Chart, d5p1:TextDocument,
	# d5p1:GeographicalSchema адресуют чужие пространства имён, и там он часть значения.
	if ($typeStr.StartsWith('cfg:')) {
		$typeStr = $typeStr.Substring(4)
	} elseif ($typeStr.Contains('.') -and $typeStr -match '^d\d+p\d+:') {
		$typeStr = $typeStr.Substring($typeStr.IndexOf(':') + 1)
	}

	# Параметризованные типы: Number(15,2), Строка(100)
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	# Ссылочные типы: СправочникСсылка.Организации → CatalogRef.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)  # includes the dot
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Простое имя
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

# Канон типа: развёрнутая запись со всеми умолчаниями. Она же ложится в ключ дедупликации
# палитры, поэтому «Число(15,3)» и «Number(15,3)» обязаны дать ОДНУ запись формата — иначе
# палитра распухнет на дубли и все ссылки <f> уедут.
# Умолчания здесь ПЛАТФОРМЕННЫЕ, а не как у реквизита метаданных: голая строка — безлимитная
# (Length 0), голое число — 0,0 (проверено на макетах, собранных Конфигуратором).
function Get-CanonValueType {
	param([string]$typeStr, [string]$where)
	$parts = @()
	$seen = @{}
	foreach ($raw in ($typeStr -split '[+|]')) {
		$p = Resolve-TypeStr $raw.Trim()
		if (-not $p) { continue }
		$canon = $null
		$kind = $null
		if ($p -ceq 'Boolean') {
			$canon = 'Boolean'; $kind = 'Boolean'
		} elseif ($p -match '^String(\((\d+)(\s*,\s*(fixed|variable))?\))?$') {
			$len = if ($Matches[2]) { $Matches[2] } else { '0' }
			$al = if ($Matches[4] -and $Matches[4].ToLowerInvariant() -eq 'fixed') { 'fixed' } else { 'variable' }
			$canon = "String($len,$al)"; $kind = 'String'
		} elseif ($p -match '^Number(\((\d+)(\s*,\s*(\d+))?(\s*,\s*(nonneg|any))?\))?$') {
			$digits = if ($Matches[2]) { $Matches[2] } else { '0' }
			$fraction = if ($Matches[4]) { $Matches[4] } else { '0' }
			$sign = if ($Matches[6] -and $Matches[6].ToLowerInvariant() -eq 'nonneg') { 'nonneg' } else { 'any' }
			$canon = "Number($digits,$fraction,$sign)"; $kind = 'Number'
		} elseif ($p -ceq 'Date' -or $p -ceq 'DateTime' -or $p -ceq 'Time') {
			$canon = $p; $kind = 'Date'
		} elseif ($p -match '^(DefinedType|Characteristic)\.(.+)$') {
			$canon = $p; $kind = "set:$p"
		} elseif ($p.Contains('.')) {
			$kindName = $p.Substring(0, $p.IndexOf('.'))
			if ($script:valueRefKinds -ccontains $kindName) {
				$canon = $p; $kind = "ref:$p"
			} else {
				[Console]::Error.WriteLine("Unknown value type `"$($raw.Trim())`" ($where). Reference kinds: $($script:valueRefKinds -join ', ')")
				exit 1
			}
		} elseif ($p.Contains(':')) {
			# Чужое пространство имён — пишем как есть: калечить его мы не вправе.
			$canon = $p; $kind = "raw:$p"
		} elseif ($script:valueTypeSets -ccontains $p) {
			$canon = $p; $kind = "set:$p"
		} else {
			[Console]::Error.WriteLine("Unknown value type `"$($raw.Trim())`" ($where). Expected: Boolean, String(N), Number(D,F), Date, <Kind>Ref.<Name> or a bare metatype")
			exit 1
		}
		# Повтор одного вида в составном типе платформа выразить не может: блок квалификаторов
		# внутри <valueType> один на вид.
		if ($seen.ContainsKey($kind)) {
			[Console]::Error.WriteLine("Duplicate type `"$canon`" in composite value type ($where)")
			exit 1
		}
		$seen[$kind] = $true
		$parts += $canon
	}
	if ($parts.Count -eq 0) {
		[Console]::Error.WriteLine("Empty value type ($where)")
		exit 1
	}
	return ($parts -join ' + ')
}

# Содержимое <valueType> по КАНОНУ — умолчаний здесь нет, они уже развёрнуты. Порядок снят
# с платформы: сначала ВСЕ <v8:Type>/<v8:TypeSet> в порядке источника, затем блоки
# квалификаторов Number → String → Date. Ссылочные типы несут ЛОКАЛЬНОЕ объявление xmlns
# на каждом узле — в макете префикс current-config всегда d4p1.
function Emit-ValueTypeContent {
	param([string]$indent, [string]$canonType)
	$cfgNs = 'http://v8.1c.ru/8.1/data/enterprise/current-config'
	$typeLines = @()
	$quals = @{}
	foreach ($p in ($canonType -split ' \+ ')) {
		if ($p -ceq 'Boolean') {
			$typeLines += "$indent<v8:Type>xs:boolean</v8:Type>"
		} elseif ($p -match '^String\((\d+),(fixed|variable)\)$') {
			$len = $Matches[1]
			$al = if ($Matches[2] -ceq 'fixed') { 'Fixed' } else { 'Variable' }
			$typeLines += "$indent<v8:Type>xs:string</v8:Type>"
			$quals['String'] = @(
				"$indent<v8:StringQualifiers>",
				"$indent`t<v8:Length>$len</v8:Length>",
				"$indent`t<v8:AllowedLength>$al</v8:AllowedLength>",
				"$indent</v8:StringQualifiers>")
		} elseif ($p -match '^Number\((\d+),(\d+),(nonneg|any)\)$') {
			$digits = $Matches[1]
			$fraction = $Matches[2]
			$sign = if ($Matches[3] -ceq 'nonneg') { 'Nonnegative' } else { 'Any' }
			$typeLines += "$indent<v8:Type>xs:decimal</v8:Type>"
			$quals['Number'] = @(
				"$indent<v8:NumberQualifiers>",
				"$indent`t<v8:Digits>$digits</v8:Digits>",
				"$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>",
				"$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>",
				"$indent</v8:NumberQualifiers>")
		} elseif ($p -ceq 'Date' -or $p -ceq 'DateTime' -or $p -ceq 'Time') {
			$typeLines += "$indent<v8:Type>xs:dateTime</v8:Type>"
			$quals['Date'] = @(
				"$indent<v8:DateQualifiers>",
				"$indent`t<v8:DateFractions>$p</v8:DateFractions>",
				"$indent</v8:DateQualifiers>")
		} elseif ($p -match '^(DefinedType|Characteristic)\.') {
			$typeLines += "$indent<v8:TypeSet xmlns:d4p1=`"$cfgNs`">d4p1:$p</v8:TypeSet>"
		} elseif ($p.Contains('.')) {
			$typeLines += "$indent<v8:Type xmlns:d4p1=`"$cfgNs`">d4p1:$p</v8:Type>"
		} elseif ($p.Contains(':')) {
			$typeLines += "$indent<v8:Type>$p</v8:Type>"
		} else {
			$typeLines += "$indent<v8:TypeSet xmlns:d4p1=`"$cfgNs`">d4p1:$p</v8:TypeSet>"
		}
	}
	foreach ($l in $typeLines) { X $l }
	foreach ($q in @('Number', 'String', 'Date')) {
		if ($quals.ContainsKey($q)) { foreach ($l in $quals[$q]) { X $l } }
	}
}

# Свойства значения ячейки — пустой набор, если ячейка обычная. Считаются ОДНОЙ функцией:
# пре-проход регистрации палитры и генерация обязаны получить один и тот же набор, иначе
# состав палитры разойдётся и все ссылки <f> сдвинутся.
function Get-CellValueProps {
	param($cell, [string]$where)
	$props = @{}
	$vt = $cell.valueType
	$ctl = $cell.controlType
	if ($null -eq $vt) {
		if ($null -ne $ctl -and "$ctl" -ne '') {
			[Console]::Error.WriteLine("Cell 'controlType' requires 'valueType' ($where)")
			exit 1
		}
		if ($null -ne $cell.PSObject.Properties['value'] -and $null -ne $cell.value) {
			[Console]::Error.WriteLine("Cell 'value' requires 'valueType' ($where)")
			exit 1
		}
		if ($null -ne $cell.control -and "$($cell.control)" -ne '') {
			[Console]::Error.WriteLine("Cell 'control' requires 'valueType' ($where)")
			exit 1
		}
		return $props
	}
	# Ячейка, содержащая значение, текста не несёт: платформа этого не допускает, и в корпусе
	# нет ни одной такой ячейки из 370 197.
	if ($null -ne $cell.text -or $null -ne $cell.template) {
		[Console]::Error.WriteLine("Cell with 'valueType' cannot have 'text' or 'template' ($where)")
		exit 1
	}
	$props['containsValue'] = 'true'
	# Пустая строка — третье состояние: <containsValue> есть, тип не задан (<valueType/>).
	$props['valueType'] = if ("$vt" -eq '') { '' } else { Get-CanonValueType "$vt" $where }

	$name = 'input'
	if ($null -ne $ctl -and "$ctl" -ne '') {
		$norm = ("$ctl" -replace '\s', '').ToLowerInvariant()
		if ($script:valueControlSynonyms.ContainsKey($norm)) { $norm = $script:valueControlSynonyms[$norm] }
		$name = $norm
	}
	if ($name -ceq 'none') { return $props }   # формат вовсе без <controlType>
	if ($script:valueControlGuids.ContainsKey($name)) {
		$props['controlType'] = $script:valueControlGuids[$name]
	} elseif ($name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
		# Неизвестный элемент управления сохраняем как есть — терять его нельзя.
		$props['controlType'] = $name
	} else {
		[Console]::Error.WriteLine("Unknown 'controlType' value `"$ctl`" ($where). Allowed: input, checkbox, none or a GUID")
		exit 1
	}
	return $props
}

# Значение ячейки-поля ввода — тег САМОЙ ячейки (<v>), а не запись палитры: у двух ячеек
# с одинаковым оформлением значения разные, и в дедупликацию формата оно не входит.
# Тип значения берём из литерала JSON и приведения НЕ делаем: платформа хранит значение с его
# собственным типом, и совпадать с объявленным он не обязан (ссылочный и составной тип она
# держит строкой, а при смене типа ячейки прежнее значение не переписывает).
function Get-CellValue {
	param($cell, [string]$canonType, [string]$where)
	$prop = $cell.PSObject.Properties['value']
	if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
	$v = $prop.Value

	if ($v -is [bool]) {
		return @{ Type = 'xs:boolean'; Text = $(if ($v) { 'true' } else { 'false' }) }
	}
	if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
		return @{ Type = 'xs:decimal'; Text = (Format-Num $v) }
	}

	$s = "$v"
	if ($s -ne '') {
		# Дата литералом JSON не выражается, поэтому едет строкой. Читаем её как дату только
		# у ячейки, объявленной датой: там платформа других значений не держит.
		if (($canonType -ceq 'Date' -or $canonType -ceq 'DateTime' -or $canonType -ceq 'Time') -and
			$s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') {
			return @{ Type = 'xs:dateTime'; Text = $s }
		}
		return @{ Type = 'xs:string'; Text = $s }
	}

	# Пустая строка — пустое значение ОБЪЯВЛЕННОГО типа: платформа так и пишет, когда текст
	# ячейки к типу не привёлся. Ссылочный и составной тип пустого значения своего вида не
	# имеют — там остаётся пустая строка.
	if ($canonType -ceq 'Boolean') { return @{ Type = 'xs:boolean'; Text = 'false' } }
	if ($canonType -like 'Number(*') { return @{ Type = 'xs:decimal'; Text = '0' } }
	if ($canonType -ceq 'Date' -or $canonType -ceq 'DateTime' -or $canonType -ceq 'Time') {
		return @{ Type = 'xs:dateTime'; Text = '0001-01-01T00:00:00' }
	}
	return @{ Type = 'xs:string'; Text = '' }
}

# Примечание к ячейке. Из четырнадцати тегов, которые пишет платформа, настоящей информации
# несут пять: текст, стиль, признак авторазмера и четыре смещения окошка. Остальное — константы
# (drawingType, pictureSize, id) либо выводится: якорь конца это координаты самой ячейки
# (1087 примечаний корпуса, без исключений), якорь начала — 1/1 (1085 из 1087).
$script:noteKeys = @('text', 'style', 'box', 'autoSize', 'anchor')
# Стиль подсказки, который даёт Конфигуратор: 926 примечаний корпуса из 1087.
$script:noteDefaultStyle = [ordered]@{
	verticalAlignment = 'Top'
	textColor = 'style:ToolTipTextColor'
	backColor = 'style:ToolTipBackColor'
}
# Размер окошка платформа подбирает по тексту, и вычислить его мы не можем. Пишем самый
# частый набор корпуса; при autoSize он всё равно пересчитывается при показе.
$script:noteDefaultBox = @{ Top = -21; Left = 21; Bottom = 51; Right = 408 }

function Test-NoteObject {
	param($el)
	foreach ($p in $el.PSObject.Properties) {
		if ($script:noteKeys -contains $p.Name) { return $true }
	}
	return $false
}

function Get-CellNote {
	param($cell, [string]$where)
	$raw = $cell.note
	if ($null -eq $raw) { return $null }

	# Как у текста ячейки: строка — текст, объект трактуется по ключам. Ключи примечания
	# и идентификаторы языков не пересекаются.
	$text = $raw
	$style = $null
	$autoSize = $true
	$box = @{} + $script:noteDefaultBox
	$anchor = @{ Row = 1; Col = 1 }

	if ($raw -is [System.Management.Automation.PSCustomObject] -and (Test-NoteObject $raw)) {
		$text = $raw.text
		if ($null -eq $text) { $text = '' }
		if ($raw.style) { $style = "$($raw.style)" }
		if ($null -ne $raw.autoSize) { $autoSize = ($raw.autoSize -eq $true -or "$($raw.autoSize)" -eq 'true') }
		foreach ($side in @('Top', 'Left', 'Bottom', 'Right')) {
			$v = $raw.box.$side
			if ($null -ne $v) { $box[$side] = [int]$v }
		}
		if ($raw.anchor) {
			if ($null -ne $raw.anchor.row) { $anchor.Row = [int]$raw.anchor.row }
			if ($null -ne $raw.anchor.col) { $anchor.Col = [int]$raw.anchor.col }
		}
	}

	return @{ Text = $text; Style = $style; AutoSize = $autoSize; Box = $box; Anchor = $anchor }
}

# --- 6. Format palette builder ---

$formatRegistry = [ordered]@{}  # key -> hashtable with properties
$formatOrder = @()              # ordered keys for index assignment

# Канонический порядок тегов внутри <format>. Снят с корпуса: 766 960 форматов, ни один
# его не нарушает — платформа пишет теги строго в этой последовательности, и от неё
# зависит побайтовое совпадение с выгрузкой.
function Get-FormatTagOrder {
	return @(
	'print', 'drawingBorder',
	'drawingHaveLeftBorder', 'drawingHaveTopBorder', 'drawingHaveRightBorder', 'drawingHaveBottomBorder',
	'font', 'leftBorder', 'topBorder', 'rightBorder', 'bottomBorder', 'border',
	'height', 'borderColor', 'width', 'autoWidthCalculation', 'widthWeightFactor',
	'horizontalAlignment', 'verticalAlignment', 'textColor', 'backColor',
	'patternColor', 'pattern', 'textPlacement', 'fillType', 'protection', 'hidden',
	'textOrientation', 'detailsUse', 'bySelectedColumns', 'markNegatives',
	'containsValue', 'valueType', 'format', 'controlType', 'hyperLink',
	'autoMarkIncomplete', 'indent', 'autoIndent', 'editFormat', 'columnSizeChange',
	'mask', 'picIndex', 'pictureSizeMode', 'picHorizontalAlignment',
	'picVerticalAlignment', 'textPosition'
	)
}

# Теги, значение которых — многоязычная строка (<v8:item> на язык), а не скаляр.
function Get-FormatMlTags {
	return @{ 'format' = $true; 'editFormat' = $true; 'mask' = $true }
}

# Тип значения каждого тега — выведен из корпуса, а не выписан на глаз.
# line  — ссылка в палитру <line>;  color — #RRGGBB / style: / web: / win:
# ml    — многоязычная строка;      enum  — замкнутый список (см. Get-FormatEnumValues)
# containsValue / valueType / controlType сюда НЕ входят: это свойства конкретной ячейки,
# а стиль — сущность общая, один на многие ячейки. По той же причине здесь нет линии рисунка
# (drawingBorder, drawingHave*Border): на корпусе все 2 135 записей с ними принадлежат только
# рисункам, у ячейки такого свойства не бывает — они задаются ключами самого рисунка.
function Get-FormatTagKind {
	return @{
		'autoIndent' = 'int'; 'autoMarkIncomplete' = 'bool'; 'autoWidthCalculation' = 'bool'
		'backColor' = 'color'; 'border' = 'line'; 'borderColor' = 'color'
		'bottomBorder' = 'line'; 'bySelectedColumns' = 'bool'; 'columnSizeChange' = 'enum'
		'detailsUse' = 'enum'
		'editFormat' = 'ml'; 'fillType' = 'enum'; 'font' = 'int'; 'format' = 'ml'
		'height' = 'int'; 'hidden' = 'bool'; 'horizontalAlignment' = 'enum'
		'hyperLink' = 'bool'; 'indent' = 'int'; 'leftBorder' = 'line'
		'markNegatives' = 'bool'; 'mask' = 'ml'; 'pattern' = 'enum'; 'patternColor' = 'color'
		'picHorizontalAlignment' = 'enum'; 'picIndex' = 'int'; 'picVerticalAlignment' = 'enum'
		'pictureSizeMode' = 'enum'; 'print' = 'bool'; 'protection' = 'bool'
		'rightBorder' = 'line'; 'textColor' = 'color'; 'textOrientation' = 'int'
		'textPlacement' = 'enum'; 'textPosition' = 'enum'; 'topBorder' = 'line'
		'verticalAlignment' = 'enum'; 'width' = 'int'; 'widthWeightFactor' = 'int'
	}
}

# Допустимые значения перечислений — тоже сняты с корпуса.
function Get-FormatEnumValues {
	return @{
		'columnSizeChange' = @('Normal', 'QuickChange')
		'detailsUse' = @('Cell', 'Row', 'WithoutProcessing')
		'fillType' = @('Parameter', 'Template', 'Text')
		'horizontalAlignment' = @('Auto', 'Center', 'Justify', 'Left', 'Right')
		# Узоры платформа нумерует подряд, без семантических имён: «Узор 1» … «Узор 17».
		'pattern' = @('WithoutPattern', 'Solid', 'Pattern1', 'Pattern2', 'Pattern3', 'Pattern4', 'Pattern5', 'Pattern6', 'Pattern7', 'Pattern8', 'Pattern9', 'Pattern10', 'Pattern11', 'Pattern12', 'Pattern13', 'Pattern14', 'Pattern15', 'Pattern16', 'Pattern17')
		'picHorizontalAlignment' = @('Auto', 'Center', 'Left', 'Right')
		'picVerticalAlignment' = @('Bottom', 'Center', 'Top')
		'pictureSizeMode' = @('AutoSize', 'Proportionally', 'RealSize')
		'textPlacement' = @('Auto', 'Block', 'Cut', 'Wrap')
		'textPosition' = @('Auto', 'Bottom', 'Right', 'Top')
		'verticalAlignment' = @('Bottom', 'Center', 'Top')
	}
}

# Прощающий ввод: ключ стиля, написанный иначе, чем тег платформы. Канон побеждает —
# если заданы оба, синоним отбрасывается. Ключи карты нормализованы (lower, без пробелов).
# Инвертированных синонимов (visible для hidden) НЕ заводим — это баг семантики, не удобство.
function Get-StyleKeySynonyms {
	return @{
		'align' = 'horizontalAlignment'; 'textalign' = 'horizontalAlignment'
		'halign' = 'horizontalAlignment'; 'горизонтальноеположение' = 'horizontalAlignment'
		'valign' = 'verticalAlignment'; 'verticalalign' = 'verticalAlignment'
		'вертикальноеположение' = 'verticalAlignment'
		'background' = 'backColor'; 'bgcolor' = 'backColor'; 'цветфона' = 'backColor'
		'color' = 'textColor'; 'forecolor' = 'textColor'; 'цветтекста' = 'textColor'
		'цветрамки' = 'borderColor'; 'цветузора' = 'patternColor'
		'borderleft' = 'leftBorder'; 'border-left' = 'leftBorder'
		'bordertop' = 'topBorder'; 'border-top' = 'topBorder'
		'borderright' = 'rightBorder'; 'border-right' = 'rightBorder'
		'borderbottom' = 'bottomBorder'; 'border-bottom' = 'bottomBorder'
		'protected' = 'protection'; 'защита' = 'protection'
		'отступ' = 'indent'; 'узор' = 'pattern'; 'гиперссылка' = 'hyperLink'
		'ориентациятекста' = 'textOrientation'; 'размещениетекста' = 'textPlacement'
		'переноспословам' = 'wrap'
	}
}

$script:formatTagOrder = Get-FormatTagOrder
$script:formatMlTags = Get-FormatMlTags
$script:formatTagKind = Get-FormatTagKind

function Get-FormatKey {
	param([hashtable]$props)
	$parts = @()
	foreach ($tag in $script:formatTagOrder) {
		if ($props.ContainsKey($tag)) { $parts += "$tag=$($props[$tag])" }
	}
	return ($parts -join '|')
}

function Register-Format {
	param([hashtable]$props)
	$key = Get-FormatKey $props
	if (-not $script:formatRegistry.Contains($key)) {
		$script:formatRegistry[$key] = $props
		$script:formatOrder += $key
	}
	# Return 1-based index
	$idx = 0
	foreach ($k in $script:formatRegistry.Keys) {
		$idx++
		if ($k -eq $key) { return $idx }
	}
	return $idx
}

# 6a. Default width format
# Формат по умолчанию платформа кладёт в палитру ПОСЛЕДНИМ: на корпусе он последний
# в 8285 макетах из 10 863, первым — в 25. Поэтому регистрируем его после всех остальных,
# уже за пре-проходом; здесь только запоминаем ширину.

# 6b. Column formats — по одной карте на каждую колоночную раскладку.
# У колонки бывает и ширина, и оформление: формат один, свойства складываются.
foreach ($layout in $columnLayouts) {
	$map = @{}  # 1-based col -> format index
	$cols = @($layout.Widths.Keys) + @($layout.Styles.Keys) | ForEach-Object { [int]$_ } |
		Select-Object -Unique | Sort-Object
	foreach ($col in $cols) {
		$styleName = if ($layout.Styles.ContainsKey($col)) { $layout.Styles[$col] } else { $null }
		# Колонка перечислена без формата вовсе (<formatIndex>0</formatIndex>): в корпусе так
		# бывает у 4% макетов. Ноль — не индекс записи, а «формата нет».
		if (-not $layout.Widths.ContainsKey($col) -and [string]::IsNullOrEmpty($styleName)) {
			$map[$col] = 0
			continue
		}
		$props = @{}
		if ($styleName) {
			# Шрифт по умолчанию колонке не навязываем: формат колонки без оформления —
			# это ровно <width>, как пишет платформа.
			$props = Resolve-Style -styleName $styleName -fillType ""
		}
		if ($layout.Widths.ContainsKey($col)) { $props['width'] = $layout.Widths[$col] }
		$map[$col] = Register-Format $props
	}
	$layout.FormatMap = $map
}
$colFormatMap = $columnLayouts[0].FormatMap

# 6c. Scan areas for row heights and cell formats
# We need to do two passes: first collect all formats, then generate XML

# Helper: escape XML special characters
function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента: только & < > . Кавычки в тексте платформа НЕ экранирует —
	# пишет литерально (проверено: 92142 сырых кавычки на корпус, ни одной &quot;). &quot; платформа
	# принимает, но при выгрузке нормализует обратно в кавычку → лишний шум в роундтрипе.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# Текст ячейки платформа хранит по элементу на язык. Конвенция ML-значений (та же, что у
# synonym/tooltip/title в метаданных и формах): объект — по элементу на язык В ПОРЯДКЕ КЛЮЧЕЙ,
# строка — один и тот же текст на всех языках макета (textLanguages, по умолчанию только ru).
$textLanguages = @('ru')
if ($def.textLanguages) {
	$declared = @($def.textLanguages | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($declared.Count -gt 0) { $textLanguages = $declared }
}

function Emit-CellText {
	param($value)
	$pairs = @()
	if ($value -is [System.Collections.IDictionary]) {
		foreach ($k in $value.Keys) { $pairs += @{ Lang = "$k"; Text = "$($value[$k])" } }
	} elseif ($value -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $value.PSObject.Properties) { $pairs += @{ Lang = $p.Name; Text = "$($p.Value)" } }
	} else {
		foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$value" } }
	}
	# Пустой текст платформа хранит ТОЛЬКО самозакрывающимся тегом: в корпусе ERP таких
	# 1 224 460, а из 780 934 непустых блоков ни одного со всеми пустыми языками нет.
	# Поэтому и пустая строка, и пустой объект дают одну и ту же запись.
	$allEmpty = $true
	foreach ($pr in $pairs) { if ("$($pr.Text)" -ne '') { $allEmpty = $false; break } }
	if ($pairs.Count -eq 0 -or $allEmpty) {
		X "`t`t`t`t`t<tl/>"
		return
	}
	X "`t`t`t`t`t<tl>"
	foreach ($p in $pairs) {
		X "`t`t`t`t`t`t<v8:item>"
		X "`t`t`t`t`t`t`t<v8:lang>$($p.Lang)</v8:lang>"
		X "`t`t`t`t`t`t`t<v8:content>$(Esc-XmlText $p.Text)</v8:content>"
		X "`t`t`t`t`t`t</v8:item>"
	}
	X "`t`t`t`t`t</tl>"
}

# Helper: determine fillType from cell content
# Text НЕ эмитим: платформа его практически не пишет — на выборке корпуса 344 981 текстовая
# ячейка из 348 023 (99,1%) ссылается на формат БЕЗ fillType. Наличие <tl> и так означает
# текст, поэтому тег избыточен. Parameter и Template платформа пишет — их оставляем.
function Get-FillType {
	param($cell)
	if ($cell.param) { return "Parameter" }
	if ($cell.template) { return "Template" }
	return ""
}

# Формат примечания — обычная запись палитры: без своего стиля берём канонический стиль подсказки.
function Register-NoteFormat {
	param($note)
	if ($note.Style) {
		$props = Resolve-Style -styleName $note.Style -fillType ""
	} else {
		$props = @{}
		foreach ($k in $script:noteDefaultStyle.Keys) { $props[$k] = $script:noteDefaultStyle[$k] }
	}
	return Register-Format $props
}

# Порядок тегов внутри <note> снят с корпуса: у всех 1087 примечаний он один и тот же,
# и все четырнадцать тегов присутствуют всегда.
function Emit-CellNote {
	param($note, [int]$fmtIdx, [int]$row, [int]$col)
	X "`t`t`t`t`t<note>"
	X "`t`t`t`t`t`t<drawingType>Comment</drawingType>"
	X "`t`t`t`t`t`t<id>0</id>"
	X "`t`t`t`t`t`t<formatIndex>$fmtIdx</formatIndex>"
	$pairs = @()
	if ($note.Text -is [System.Collections.IDictionary]) {
		foreach ($k in $note.Text.Keys) { $pairs += @{ Lang = "$k"; Text = "$($note.Text[$k])" } }
	} elseif ($note.Text -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $note.Text.PSObject.Properties) { $pairs += @{ Lang = $p.Name; Text = "$($p.Value)" } }
	} else {
		foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$($note.Text)" } }
	}
	if ($pairs.Count -eq 0) {
		X "`t`t`t`t`t`t<text/>"
	} else {
		X "`t`t`t`t`t`t<text>"
		foreach ($p in $pairs) {
			X "`t`t`t`t`t`t`t<v8:item>"
			X "`t`t`t`t`t`t`t`t<v8:lang>$($p.Lang)</v8:lang>"
			X "`t`t`t`t`t`t`t`t<v8:content>$(Esc-XmlText $p.Text)</v8:content>"
			X "`t`t`t`t`t`t`t</v8:item>"
		}
		X "`t`t`t`t`t`t</text>"
	}
	X "`t`t`t`t`t`t<beginRow>$($note.Anchor.Row)</beginRow>"
	X "`t`t`t`t`t`t<beginRowOffset>$($note.Box.Top)</beginRowOffset>"
	X "`t`t`t`t`t`t<endRow>$row</endRow>"
	X "`t`t`t`t`t`t<endRowOffset>$($note.Box.Bottom)</endRowOffset>"
	X "`t`t`t`t`t`t<beginColumn>$($note.Anchor.Col)</beginColumn>"
	X "`t`t`t`t`t`t<beginColumnOffset>$($note.Box.Left)</beginColumnOffset>"
	X "`t`t`t`t`t`t<endColumn>$col</endColumn>"
	X "`t`t`t`t`t`t<endColumnOffset>$($note.Box.Right)</endColumnOffset>"
	X "`t`t`t`t`t`t<autoSize>$(if ($note.AutoSize) { 'true' } else { 'false' })</autoSize>"
	X "`t`t`t`t`t`t<pictureSize>Stretch</pictureSize>"
	X "`t`t`t`t`t</note>"
}

# Helper: register a cell format and return its index
function Register-CellFormat {
	param($styleName, [string]$fillType, [hashtable]$valueProps)
	$resolved = Resolve-Style -styleName $styleName -fillType $fillType
	# Свойства значения кладём ПОВЕРХ стиля — до проверки на пустоту: у ячейки-поля ввода
	# оформления может не быть вовсе, и без слияния она получила бы <f>0</f>, потеряв значение.
	if ($valueProps) {
		foreach ($k in $valueProps.Keys) { $resolved[$k] = $valueProps[$k] }
	}
	# У ячейки без собственного оформления формата НЕТ вовсе: <f>0</f>, где ноль — не индекс
	# записи, а «формата нет». В корпусе так у 170 710 ячеек против 50 635, ссылающихся на
	# формат по умолчанию; <f>0</f> встречается в 71% макетов.
	if ($resolved.Count -eq 0) {
		return 0
	}
	return Register-Format $resolved
}

# --- 5.5. Шорткат строк: строка-массив ячеек ---
# Та же форма, что у макетов СКД (skd-compile): позиция ячейки = индекс в массиве,
# ">" продолжает ячейку слева, "|" — ячейку сверху, null — пустая колонка,
# "{Имя}" — параметр. Разворачиваем в обычную строку с явными col/span/rowspan,
# поэтому весь код ниже про шорткат не знает.

function Set-CellProp {
	param($cell, [string]$name, $value)
	$cell | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

# Объект описывает СВОЙСТВА ячейки или является её ЗНАЧЕНИЕМ: в первом случае среди ключей
# есть ключ схемы ячейки, во втором ключи — идентификаторы языков. Пересечений нет: в корпусе
# это ru, en, ru1, Русский.
function Test-CellObject {
	param($el)
	$cellKeys = @('col', 'span', 'rowspan', 'style', 'param', 'detail', 'text', 'template',
		'valueType', 'controlType', 'value', 'control', 'note', 'pictureParameter')
	foreach ($p in $el.PSObject.Properties) {
		if ($cellKeys -contains $p.Name) { return $true }
	}
	return $false
}

function Expand-ShorthandRow {
	param($row, [string]$areaName, [int]$rowIdx, $openByCol, [int]$maxCols)

	$cells = @()
	$placed = @{}     # 1-based col -> ячейка, занимающая колонку в ЭТОЙ строке
	$extended = @()   # ячейки, чей rowspan уже нарастили в этой строке (span>1 даёт несколько "|")
	$last = $null     # последняя реальная ячейка слева — цель для ">"
	$idx = 0

	foreach ($el in $row) {
		$idx++
		# Внутри функции пишем в stderr напрямую: Write-Error приписал бы к сообщению имя
		# функции, и текст перестал бы совпадать с py-портом.
		if ($idx -gt $maxCols) {
			[Console]::Error.WriteLine("Row exceeds 'columns' ($maxCols): area `"$areaName`", row $rowIdx")
			exit 1
		}

		if ($null -eq $el) { $last = $null; continue }

		if ($el -is [string] -and $el -eq '>') {
			if ($null -eq $last) {
				[Console]::Error.WriteLine("Row shorthand: '>' has no cell to the left: area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			$span = if ($last.span) { [int]$last.span } else { 1 }
			Set-CellProp $last 'span' ($span + 1)
			$placed[$idx] = $last
			continue
		}

		if ($el -is [string] -and $el -eq '|') {
			$above = $openByCol[$idx]
			if ($null -eq $above) {
				[Console]::Error.WriteLine("Row shorthand: '|' has no cell above: area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			if (-not ($extended -contains $above)) {
				$rowspan = if ($above.rowspan) { [int]$above.rowspan } else { 1 }
				Set-CellProp $above 'rowspan' ($rowspan + 1)
				$extended += $above
			}
			$placed[$idx] = $above
			$last = $null
			continue
		}

		if ($el -is [string]) {
			$cell = [PSCustomObject]@{ col = $idx; span = 1 }
			$m = [regex]::Match($el, '^\{(.+)\}$')
			if ($m.Success) { Set-CellProp $cell 'param' $m.Groups[1].Value }
			else { Set-CellProp $cell 'text' $el }
		} elseif (-not (Test-CellObject $el)) {
			# Объект без единого ключа ячейки — это многоязычный ТЕКСТ: в позиционной записи
			# элемент и есть значение текста, а значение текста по общей конвенции бывает
			# строкой либо объектом «язык → текст».
			$cell = [PSCustomObject]@{ col = $idx; span = 1 }
			Set-CellProp $cell 'text' $el
		} else {
			# Объектный элемент — обычная ячейка mxl, позиция берётся из индекса.
			if ($el.PSObject.Properties['col']) {
				[Console]::Error.WriteLine("Row shorthand: cell object must not carry 'col': area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			$cell = $el
			Set-CellProp $cell 'col' $idx
			if (-not $cell.span) { Set-CellProp $cell 'span' 1 }
		}

		$cells += $cell
		$placed[$idx] = $cell
		$last = $cell
		# Ячейка занимает СТОЛЬКО позиций, каков её span. У строки со следующими ">" это
		# получается само (каждый маркер съедает позицию), а объектный элемент несёт span
		# внутри — без этого сдвига всё правее него уезжало влево.
		$elSpan = if ($cell.span) { [int]$cell.span } else { 1 }
		if ($elSpan -gt 1) {
			for ($s = 1; $s -lt $elSpan; $s++) { $idx++; $placed[$idx] = $cell }
		}
	}

	# Колонки, не занятые в этой строке, теряют «ячейку сверху».
	$openByCol.Clear()
	foreach ($k in $placed.Keys) { $openByCol[$k] = $placed[$k] }

	return [PSCustomObject]@{ cells = $cells }
}

# Позиционный список ячеек опознаём по наличию хотя бы одного элемента-строки или null:
# маркеры, текст и пропуски бывают только в нём. Список из одних объектов разбирается
# как обычный — для простой строки обе трактовки дают один результат, неоднозначности нет.
function Test-PositionalCells {
	param($cells)
	if ($null -eq $cells -or -not ($cells -is [array])) { return $false }
	foreach ($el in $cells) {
		if ($null -eq $el -or $el -is [string]) { return $true }
	}
	return $false
}

# Карту занятых колонок ведём и по объектным строкам: "|" продолжает ту ячейку,
# которая реально стоит выше, независимо от того, какой формой её записали.
function Update-OpenByCol {
	param($row, $openByCol)
	$placed = @{}
	if ($row.cells) {
		foreach ($cell in $row.cells) {
			# Ячейки без col (строка с автопотоком) на этом шаге ещё не разложены — позиция
			# станет известна позже, поэтому «ячейку сверху» они не дают, и "|" под такой
			# строкой честно скажет, что сверху ничего нет.
			if (-not $cell.PSObject.Properties['col'] -or $null -eq $cell.col) { continue }
			$col = [int]$cell.col
			$span = if ($cell.span) { [int]$cell.span } else { 1 }
			for ($c = $col; $c -lt ($col + $span); $c++) { $placed[$c] = $cell }
		}
	}
	$openByCol.Clear()
	foreach ($k in $placed.Keys) { $openByCol[$k] = $placed[$k] }
}

foreach ($area in $def.areas) {
	$areaName = $area.name
	# Ширина сетки берётся из раскладки области: у каждой она своя.
	$areaMaxCols = $totalColumns
	if ($area.PSObject.Properties['columnSet'] -and "$($area.columnSet)" -ne '') {
		$lay = @($columnLayouts | Where-Object { $_.Name -eq "$($area.columnSet)" })[0]
		if ($lay) { $areaMaxCols = [int]$lay.Size }
	}
	$openByCol = @{}
	$rowIdx = 0
	$expandedRows = @()
	foreach ($row in $area.rows) {
		$rowIdx++
		if ($row -is [array]) {
			# Строка целиком массивом — сахар для { cells: [...] }.
			$expandedRows += Expand-ShorthandRow -row $row -areaName $areaName -rowIdx $rowIdx -openByCol $openByCol -maxCols $areaMaxCols
		} elseif (Test-PositionalCells $row.cells) {
			# Короткая запись — свойство СПИСКА ЯЧЕЕК, а не строки: свои height и rowStyle
			# строка при этом сохраняет.
			$expanded = Expand-ShorthandRow -row $row.cells -areaName $areaName -rowIdx $rowIdx -openByCol $openByCol -maxCols $areaMaxCols
			$row.cells = $expanded.cells
			$expandedRows += $row
		} else {
			$expandedRows += $row
			if ($row.empty) { $openByCol.Clear() } else { Update-OpenByCol -row $row -openByCol $openByCol }
		}
	}
	$area.rows = $expandedRows
}

# Pre-register all formats from areas
foreach ($area in $def.areas) {
	foreach ($row in $area.rows) {
		# Skip empty row placeholder
		if ($row.empty) { continue }

		# Формат САМОЙ строки: высота и скрытие — её собственные свойства (у ячейки таких
		# нет), плюс стиль строки, если он ложится на строку.
		$rowProps = Get-RowFormatProps $row
		if ($rowProps.Count -gt 0) { Register-Format $rowProps | Out-Null }

		$spec = Get-RowStyleSpec $row.rowStyle "row"
		$cellsStyle = if ($spec.Apply -ceq 'row') { $null } else { $spec.Name }

		# rowStyle gap-fill format (no content → no fillType)
		if ($cellsStyle) {
			Register-CellFormat -styleName $cellsStyle -fillType "" | Out-Null
		}

		# Explicit cell formats
		if ($row.cells) {
			foreach ($cell in $row.cells) {
				$cellStyle = if ($cell.style) { $cell.style } elseif ($cellsStyle) { $cellsStyle } else { "default" }
				$ft = Get-FillType $cell
				$vp = Get-CellValueProps $cell "area `"$($area.name)`""
				Register-CellFormat -styleName $cellStyle -fillType $ft -valueProps $vp | Out-Null
				$note = Get-CellNote $cell "area `"$($area.name)`""
				if ($note) { Register-NoteFormat $note | Out-Null }
			}
		}
	}
}

# 7d-ter. Колонтитулы. Шесть слотов: left/center/right у верхнего и нижнего. Слот устроен
# как ячейка — ссылка на формат плюс текст, — а формат несёт то, что в диалоге задаётся на весь
# колонтитул: шрифт, вертикальное выравнивание, признак вывода (<height> 1/-1) и страницу,
# с которой колонтитул печатается (<width>).
$script:headerSlots = @('left', 'center', 'right')

function Get-HeaderFormatIndex {
	param($hf)
	if ($null -eq $hf) { return 0 }
	$props = @{}
	if ($hf.font -and $fontMap.Contains("$($hf.font)")) { $props['font'] = $fontMap["$($hf.font)"] }
	# Признак вывода и стартовая страница осмысленны только вместе: платформа пишет их парой.
	$props['height'] = if ($hf.show -eq $false -or "$($hf.show)" -eq 'false') { -1 } else { 1 }
	$props['width'] = if ($hf.startPage) { [int]$hf.startPage } else { 1 }
	if ($hf.verticalAlignment) { $props['verticalAlignment'] = "$($hf.verticalAlignment)" }
	return Register-Format $props
}

function Emit-HeaderSlot {
	param([string]$tag, $value, [int]$fmtIdx)
	if ($null -eq $value) { return }
	# Форматированная строка платформы — тот же текст, только разметка живёт внутри содержимого
	# (<b>жирный</>, <fontsize 12>…), поэтому возим её как есть и различаем именем тега.
	$formatted = $false
	$text = $value
	if ($value -is [System.Management.Automation.PSCustomObject] -and $null -ne $value.formatted) {
		$formatted = $true
		$text = $value.formatted
	}
	$pairs = @()
	if ($text -is [System.Collections.IDictionary]) {
		foreach ($k in $text.Keys) { $pairs += @{ Lang = "$k"; Text = "$($text[$k])" } }
	} elseif ($text -is [System.Management.Automation.PSCustomObject]) {
		foreach ($pr in $text.PSObject.Properties) { $pairs += @{ Lang = $pr.Name; Text = "$($pr.Value)" } }
	} else {
		foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$text" } }
	}
	$textTag = if ($formatted) { 'tfl' } else { 'tl' }
	X "`t<$tag>"
	X "`t`t<f>$fmtIdx</f>"
	if ($pairs.Count -eq 0) {
		X "`t`t<$textTag/>"
	} else {
		X "`t`t<$textTag>"
		foreach ($pr in $pairs) {
			X "`t`t`t<v8:item>"
			X "`t`t`t`t<v8:lang>$($pr.Lang)</v8:lang>"
			# Перенос строки внутри колонтитула платформа хранит голым LF, тогда как весь файл
			# идёт CRLF. Пишем содержимое одной строкой вывода, чтобы перенос не переписался.
			X "`t`t`t`t<v8:content>$(Esc-XmlText $pr.Text)</v8:content>"
			X "`t`t`t</v8:item>"
		}
		X "`t`t</$textTag>"
	}
	X "`t</$tag>"
}

# Параметры печати. Имя ключа совпадает с именем тега в выгрузке, как у свойств стиля.
# Порядок снят с корпуса (2350 макетов): платформа пишет теги строго в этой последовательности.
function Get-PrintSettingsOrder {
	return @(
	'pageOrientation', 'scale', 'collate', 'copies', 'perPage',
	'topMargin', 'leftMargin', 'bottomMargin', 'rightMargin', 'headerSize', 'footerSize',
	'fitToPage', 'blackAndWhite', 'printerName', 'paper', 'paperSource',
	'pageWidth', 'pageHeight', 'duplexType', 'pagePlacementAlternation', 'firstPageNumber'
	)
}

function Emit-PrintSettings {
	param($ps)
	if ($null -eq $ps) { return }
	$order = Get-PrintSettingsOrder
	$known = @{}
	foreach ($k in $order) { $known[$k] = $true }
	foreach ($pr in $ps.PSObject.Properties) {
		if (-not $known.ContainsKey($pr.Name)) {
			[Console]::Error.WriteLine("printSettings: unknown key `"$($pr.Name)`". Allowed: $($order -join ', ')")
			exit 1
		}
	}
	$emitted = @()
	foreach ($tag in $order) {
		$v = $ps.$tag
		if ($null -eq $v) { continue }
		if ($v -is [bool]) { $v = if ($v) { 'true' } else { 'false' } }
		$emitted += "`t`t<$tag>$(Esc-XmlText "$v")</$tag>"
	}
	if ($emitted.Count -eq 0) { return }
	X "`t<printSettings>"
	foreach ($line in $emitted) { X $line }
	X "`t</printSettings>"
}

# Палитра картинок. Ресурс хранится двумя способами: ссылкой на библиотеку платформы
# (ref="v8ui:Имя") либо данными base64 прямо в макете (9 905 из 9 988 картинок корпуса).
# На неё ссылаются и рисунки (pictureIndex), и ячейки (picIndex в стиле) — индекс 1-based.
$pictureNames = @{}   # имя из DSL → 1-based индекс
$pictureEntries = @()

if ($def.pictures) {
	foreach ($pr in $def.pictures.PSObject.Properties) {
		# Пустая запись — законная картинка «не задана»: в корпусе таких 151, ровно по одной
		# на макет. Ошибкой считаем только запись с непонятным содержимым.
		$entry = @{ Ref = ''; Data = ''; Transparent = ''; PixelX = ''; PixelY = '' }
		if ($pr.Value.ref) { $entry.Ref = "$($pr.Value.ref)" }
		if ($null -ne $pr.Value.data) { $entry.Data = "$($pr.Value.data)" }
		# Прозрачность — одна сущность диалога, записанная двумя способами: выключенную
		# платформа хранит атрибутом, включённую — координатами пикселя, чей цвет прозрачен.
		# Поэтому и ключ один, а форма значения выбирает способ.
		$tr = $pr.Value.transparent
		if ($null -ne $tr) {
			if ($tr -is [bool] -or "$tr" -ceq 'true' -or "$tr" -ceq 'false') {
				$entry.Transparent = if ($tr -eq $true -or "$tr" -ceq 'true') { 'true' } else { 'false' }
			} elseif ($null -ne $tr.x -and $null -ne $tr.y) {
				$entry.PixelX = "$([int]$tr.x)"
				$entry.PixelY = "$([int]$tr.y)"
			} else {
				[Console]::Error.WriteLine("pictures[$($pr.Name)]: 'transparent' is either false/true or { x, y }")
				exit 1
			}
		}
		if (-not $entry.Ref -and -not $entry.Data -and ($entry.Transparent -or $entry.PixelX)) {
			[Console]::Error.WriteLine("pictures[$($pr.Name)]: 'transparent' requires 'ref' or 'data'")
			exit 1
		}
		$pictureEntries += $entry
		$pictureNames[$pr.Name] = $pictureEntries.Count
	}
}

# Рисунки: своя геометрия из двух якорей, тип, ссылка на картинку, текст, расшифровка.
# id и zOrder — данные, а не позиция: на корпусе они расходятся у 8 253 рисунков из 11 268.
$drawingTypes = @('Picture', 'Rectangle', 'Ellipse', 'Line', 'Text', 'Chart', 'GanttChart')
$drawings = @()
$drawingIdx = 0
foreach ($dr in $def.drawings) {
	$drawingIdx++
	$where = "drawings[$drawingIdx]"
	$type = if ($dr.type) { "$($dr.type)" } else { 'Picture' }
	$canonType = @($drawingTypes | Where-Object { $_ -eq $type })[0]
	if (-not $canonType) {
		[Console]::Error.WriteLine("${where}: unknown drawing 'type' `"$type`". Allowed: $($drawingTypes -join ', ')")
		exit 1
	}
	$picIdx = 0
	if ($dr.picture) {
		if (-not $pictureNames.ContainsKey("$($dr.picture)")) {
			[Console]::Error.WriteLine("${where}: unknown 'picture' `"$($dr.picture)`" — not declared in pictures")
			exit 1
		}
		$picIdx = $pictureNames["$($dr.picture)"]
	}
	# Оформление рисунка: общее — из именованного стиля, чисто рисуночное (линия и её стороны)
	# — своими ключами, поверх стиля. Тот же приём, что у ячейки с fillType и значением.
	$props = @{}
	if ($dr.style) { $props = Resolve-Style -styleName "$($dr.style)" -fillType "" }
	if ($null -ne $dr.line) {
		$lnVal = ConvertTo-LineValue $dr.line $where
		$lnVal['Kind'] = 'Drawing'
		$props['drawingBorder'] = Register-Line $lnVal
	}
	foreach ($side in @('left', 'top', 'right', 'bottom')) {
		$v = $dr.sides.$side
		if ($null -ne $v) {
			$tag = 'drawingHave' + $side.Substring(0,1).ToUpperInvariant() + $side.Substring(1) + 'Border'
			$props[$tag] = if ($v -eq $true -or "$v" -eq 'true') { 'true' } else { 'false' }
		}
	}
	$fmtIdx = 0
	if ($props.Count -gt 0) { $fmtIdx = Register-Format $props }
	function Get-Anchor {
		param($node, [string]$rowKey, [string]$colKey)
		return @{
			Row = if ($node -and $null -ne $node.row) { [int]$node.row - 1 } else { 0 }
			Col = if ($node -and $null -ne $node.col) { [int]$node.col - 1 } else { 0 }
			Dy  = if ($node -and $null -ne $node.dy) { [int]$node.dy } else { 0 }
			Dx  = if ($node -and $null -ne $node.dx) { [int]$node.dx } else { 0 }
		}
	}
	$drawings += @{
		Type        = $canonType
		Id          = if ($null -ne $dr.id) { [int]$dr.id } else { $drawingIdx }
		ZOrder      = if ($null -ne $dr.zOrder) { [int]$dr.zOrder } else { $drawingIdx }
		FormatIdx   = $fmtIdx
		Detail      = $dr.detail
		Text        = $dr.text
		Begin       = Get-Anchor $dr.begin
		End         = Get-Anchor $dr.end
		PictureSize = if ($dr.pictureSize) { "$($dr.pictureSize)" } else { 'Stretch' }
		PictureIdx  = $picIdx
		Name        = $dr.name
	}
}

# Формат по умолчанию — последняя запись палитры (см. выше).
$defaultFormatIndex = Register-Format @{ width = $defaultWidth }

# Формат колонтитула заводим здесь же: он идёт в палитре следом за умолчанием, и он
# обязан попасть в реестр ДО отсева неиспользуемых шрифтов — иначе шрифт колонтитула,
# на который больше никто не ссылается, будет выброшен.
$headerFmt = Get-HeaderFormatIndex $def.header
$footerFmt = Get-HeaderFormatIndex $def.footer

# Шрифт, на который не ссылается ни один формат, платформа в палитру не кладёт: у макета
# без оформления элемента <font> нет вовсе. Мы же всегда заводили Arial 10 по умолчанию.
# Отбрасываем неиспользуемые и перенумеровываем ссылки — индексы шрифтов позиционные.
$usedFonts = @{}
foreach ($k in $formatRegistry.Keys) {
	$fp = $formatRegistry[$k]
	if ($fp.ContainsKey('font')) { $usedFonts[[int]$fp['font']] = $true }
}
if ($usedFonts.Count -lt $fontEntries.Count) {
	$fontRemap = @{}
	$kept = @()
	for ($i = 0; $i -lt $fontEntries.Count; $i++) {
		if ($usedFonts.ContainsKey($i)) {
			$fontRemap[$i] = $kept.Count
			$kept += $fontEntries[$i]
		}
	}
	foreach ($k in @($formatRegistry.Keys)) {
		$fp = $formatRegistry[$k]
		if ($fp.ContainsKey('font')) { $fp['font'] = $fontRemap[[int]$fp['font']] }
	}
	$fontEntries = $kept
}

# --- 7. Generate XML ---

$xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

# 7a. Header
$docNsDecl = 'xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
# 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (перед style):
# платформа держит объявления по алфавиту, дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$docNsDecl = $docNsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}
X '<?xml version="1.0" encoding="UTF-8"?>'
X "<document $docNsDecl>"

# 7b. Language settings
# Языки МАКЕТА — не то же, что textLanguages: там языки, на которые разворачивается текст
# ячейки, здесь объявление в шапке. В 98% макетов ERP объявлен один ru, а текст лежит и под
# ru, и под en, поэтому выводить одно из другого нельзя. Ключи недокументированные: автору
# они не нужны, нужны раундтрипу.
$langCodes = @{ 'ru' = 'Русский'; 'en' = 'Английский' }
$langList = @()
if ($def.languages) {
	foreach ($l in @($def.languages)) {
		if ($l -is [string]) {
			$code = if ($langCodes.ContainsKey("$l")) { $langCodes["$l"] } else { "$l" }
			$langList += @{ Id = "$l"; Code = $code; Description = $code }
		} else {
			# description отсутствует и пустая строка — одно и то же: тег есть всегда, но
			# бывает самозакрывающимся (77 записей корпуса против 11 017 со значением).
			$langList += @{
				Id = "$($l.id)"
				Code = "$($l.code)"
				Description = if ($null -eq $l.description) { '' } else { "$($l.description)" }
			}
		}
	}
}
if ($langList.Count -eq 0) {
	$langList = @(@{ Id = 'ru'; Code = 'Русский'; Description = 'Русский' })
}
$currentLang = if ($def.PSObject.Properties['currentLanguage']) { $def.currentLanguage } else { 'ru' }
$defaultLang = if ($def.defaultLanguage) { "$($def.defaultLanguage)" } else { 'ru' }

X "`t<languageSettings>"
if ($null -ne $currentLang -and "$currentLang" -ne '') {
	X "`t`t<currentLanguage>$(Esc-XmlText "$currentLang")</currentLanguage>"
}
X "`t`t<defaultLanguage>$(Esc-XmlText $defaultLang)</defaultLanguage>"
foreach ($l in $langList) {
	X "`t`t<languageInfo>"
	X "`t`t`t<id>$(Esc-XmlText $l.Id)</id>"
	X "`t`t`t<code>$(Esc-XmlText $l.Code)</code>"
	if ($l.Description -eq '') {
		X "`t`t`t<description/>"
	} else {
		X "`t`t`t<description>$(Esc-XmlText $l.Description)</description>"
	}
	X "`t`t</languageInfo>"
}
X "`t</languageSettings>"

# 7c. Columns
# Раскладка по умолчанию идёт первой и без <id> — так их хранит платформа.
foreach ($layout in $columnLayouts) {
	X "`t<columns>"
	if ($layout.Id) { X "`t`t<id>$($layout.Id)</id>" }
	X "`t`t<size>$($layout.Size)</size>"

	# Emit columnsItem for columns with non-default widths
	foreach ($col in ($layout.FormatMap.Keys | Sort-Object)) {
		$fmtIdx = $layout.FormatMap[$col]
		$colIdx = $col - 1  # Convert to 0-based
		X "`t`t<columnsItem>"
		X "`t`t`t<index>$colIdx</index>"
		X "`t`t`t<column>"
		X "`t`t`t`t<formatIndex>$fmtIdx</formatIndex>"
		X "`t`t`t</column>"
		X "`t`t</columnsItem>"
	}

	X "`t</columns>"
}

# 7d. Rows — main generation loop
$globalRow = 0
$merges = @()
$namedItems = @()
# Строка документа → колоночная раскладка. Нужна для вывода привязки именованной области:
# на корпусе она совпадает с раскладкой накрытых строк у 1 021 570 областей из 1 044 339.
$rowColumnSet = @{}
$totalRowCount = 0

# Копилка подряд идущих одинаковых пустых строк — пишется одним rowsItem с indexTo.
$pendingGap = $null
function Add-GapRow {
	param([string]$key, [int]$row, [string]$columnSet, [int]$formatIdx)
	$gap = $script:pendingGap
	# -ceq: ключ несёт GUID раскладки, а обычное -eq в PowerShell регистр не различает.
	if ($gap -and $gap.Key -ceq $key -and $gap.End -eq ($row - 1)) {
		$gap.End = $row
		return
	}
	Flush-Gap
	$script:pendingGap = @{ Key = $key; Start = $row; End = $row
		ColumnSet = $columnSet; FormatIdx = $formatIdx }
}
function Flush-Gap {
	if (-not $script:pendingGap) { return }
	$gap = $script:pendingGap
	$script:pendingGap = $null
	X "`t<rowsItem>"
	X "`t`t<index>$($gap.Start)</index>"
	if ($gap.End -gt $gap.Start) { X "`t`t<indexTo>$($gap.End)</indexTo>" }
	X "`t`t<row>"
	if ($gap.ColumnSet) { X "`t`t`t<columnsID>$($gap.ColumnSet)</columnsID>" }
	if ($gap.FormatIdx -gt 0) { X "`t`t`t<formatIndex>$($gap.FormatIdx)</formatIndex>" }
	X "`t`t`t<empty>true</empty>"
	X "`t`t</row>"
	X "`t</rowsItem>"
}

foreach ($area in $def.areas) {
	$areaStartRow = $globalRow
	$areaName = $area.name
	$activeRowspans = @()  # @{ColStart=1-based; ColEnd=1-based; EndLocalRow=int}
	$localRow = 0
	# Ссылка области на колоночную раскладку — её получают все строки области.
	# Раскладка адресуется ИМЕНЕМ из columnSets — инлайновой формы в этом DSL нет ни у чего
	# (стиль и шрифт тоже только по имени). Иначе сообщение включало бы сериализованный
	# объект, а он у портов выглядит по-разному.
	if ($area.PSObject.Properties['columnSet'] -and
		($area.columnSet -is [System.Management.Automation.PSCustomObject] -or $area.columnSet -is [System.Collections.IDictionary])) {
		[Console]::Error.WriteLine("'columnSet' must be a name declared in columnSets, got an object: area `"$($area.name)`"")
		exit 1
	}
	$areaColumnSetName = if ($area.PSObject.Properties['columnSet']) { "$($area.columnSet)" } else { '' }
	$areaColumnSet = ''
	$areaLayout = $columnLayouts[0]
	if ($areaColumnSetName) {
		$areaLayout = @($columnLayouts | Where-Object { $_.Name -eq $areaColumnSetName })[0]
		if (-not $areaLayout) {
			[Console]::Error.WriteLine("Unknown 'columnSet': `"$areaColumnSetName`" is not declared in columnSets")
			exit 1
		}
		$areaColumnSet = $areaLayout.Id
	}
	# Ширина сетки — у КАЖДОЙ раскладки своя, поэтому позиции колонок сверяем с ней,
	# а не с документным columns (у макетов с раскладками умолчание бывает и пустым).
	$areaColumns = [int]$areaLayout.Size

	foreach ($row in $area.rows) {
		# Empty row placeholder: emit N empty rows
		if ($row.empty) {
			$count = [int]$row.empty
			for ($ei = 0; $ei -lt $count; $ei++) {
				Add-GapRow -key '|0' -row $globalRow -columnSet '' -formatIdx 0
				$globalRow++; $localRow++
			}
			continue
		}

		# Build set of columns occupied by rowspans from previous rows
		$rowspanOccupied = @{}  # 1-based col -> $true
		foreach ($rs in $activeRowspans) {
			if ($localRow -gt $rs.StartLocalRow -and $localRow -le $rs.EndLocalRow) {
				for ($c = $rs.ColStart; $c -le $rs.ColEnd; $c++) {
					$rowspanOccupied[$c] = $true
				}
			}
		}

		$rowHasContent = $false
		$rowCells = @()  # array of { Col(0-based), FormatIdx, Content }

		# Формат самой строки — высота, скрытие и стиль строки, если он ложится на строку
		$rowFormatIdx = 0
		$rowProps = Get-RowFormatProps $row
		if ($rowProps.Count -gt 0) { $rowFormatIdx = Register-Format $rowProps }

		$spec = Get-RowStyleSpec $row.rowStyle "row"
		$cellsStyle = if ($spec.Apply -ceq 'row') { $null } else { $spec.Name }

		if ($row.cells -and $row.cells.Count -gt 0) {
			$rowHasContent = $true

			# Прощающий ввод: строка, в которой НИ У ОДНОЙ ячейки нет col, раскладывается
			# слева направо с учётом span и rowspan сверху. Канон один и он в документации —
			# col обязателен; здесь мы лишь спасаем естественный DSL вместо тихой порчи
			# ($null -> [int]0 -> Col = -1). Смешанную строку не угадываем: это опечатка.
			$positioned = @($row.cells | Where-Object {
				$_.PSObject.Properties['col'] -and $null -ne $_.col -and "$($_.col)" -ne ""
			})
			if ($positioned.Count -eq 0) {
				$cursor = 1
				foreach ($cell in $row.cells) {
					$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
					while ($true) {
						$isFree = $true
						for ($c = $cursor; $c -lt ($cursor + $colSpan); $c++) {
							if ($rowspanOccupied[$c]) { $isFree = $false; break }
						}
						if ($isFree) { break }
						$cursor++
					}
					if (($cursor + $colSpan - 1) -gt $areaColumns) {
						[Console]::Error.WriteLine("Row exceeds 'columns' ($areaColumns): area `"$areaName`", row $($localRow + 1)")
						exit 1
					}
					$cell | Add-Member -NotePropertyName col -NotePropertyValue $cursor -Force
					$cursor += $colSpan
				}
			} elseif ($positioned.Count -ne $row.cells.Count) {
				[Console]::Error.WriteLine("Cell without 'col' mixed with positioned cells: area `"$areaName`", row $($localRow + 1)")
				exit 1
			}

			# Позиция обязана быть в 1..columns: до этой проверки нечисловой или нулевой col
			# молча превращался в Col = -1 и давал битую ячейку без единого сообщения.
			$cellIdx = 0
			foreach ($cell in $row.cells) {
				$cellIdx++
				$colParsed = 0
				if (-not [int]::TryParse("$($cell.col)", [ref]$colParsed) -or $colParsed -lt 1 -or $colParsed -gt $areaColumns) {
					[Console]::Error.WriteLine("Invalid 'col' value `"$($cell.col)`": area `"$areaName`", row $($localRow + 1), cell $cellIdx")
					exit 1
				}
			}

			# Build set of occupied columns (1-based): explicit cells + rowspan from above
			$occupiedCols = @{}
			foreach ($rsk in $rowspanOccupied.Keys) { $occupiedCols[$rsk] = $true }
			foreach ($cell in $row.cells) {
				$colStart = [int]$cell.col
				$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
				for ($c = $colStart; $c -lt ($colStart + $colSpan); $c++) {
					$occupiedCols[$c] = $true
				}
			}

			# Generate explicit cells
			foreach ($cell in $row.cells) {
				$colStart = [int]$cell.col
				$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
				$rowspan = if ($cell.rowspan) { [int]$cell.rowspan } else { 1 }
				$cellStyle = if ($cell.style) { $cell.style } elseif ($cellsStyle) { $cellsStyle } else { "default" }
				$ft = Get-FillType $cell
				$vp = Get-CellValueProps $cell "area `"$areaName`", row $($localRow + 1)"
				$fmtIdx = Register-CellFormat -styleName $cellStyle -fillType $ft -valueProps $vp
				$cellNote = Get-CellNote $cell "area `"$areaName`", row $($localRow + 1)"
				$cellNoteFmt = if ($cellNote) { Register-NoteFormat $cellNote } else { 0 }

				$cellInfo = @{
					Col       = $colStart - 1  # 0-based
					FormatIdx = $fmtIdx
					Param        = $cell.param
					Detail       = $cell.detail
					PictureParam = $cell.pictureParameter
					Text      = $cell.text
					Template  = $cell.template
					Value     = $(if ($vp.Count -gt 0) { Get-CellValue $cell "$($vp['valueType'])" "area `"$areaName`", row $($localRow + 1)" } else { $null })
					Control   = $(if ($vp.Count -gt 0) { $cell.control } else { $null })
					Note      = $cellNote
					NoteFmt   = $cellNoteFmt
				}
				$rowCells += $cellInfo

				# Track rowspan for subsequent rows
				if ($rowspan -gt 1) {
					$activeRowspans += @{
						ColStart      = $colStart
						ColEnd        = $colStart + $colSpan - 1
						StartLocalRow = $localRow
						EndLocalRow   = $localRow + $rowspan - 1
					}
				}

				# Collect merge (horizontal, vertical, or both)
				if ($colSpan -gt 1 -or $rowspan -gt 1) {
					$merge = @{ R = $globalRow; C = $colStart - 1; W = $colSpan - 1 }
					if ($rowspan -gt 1) { $merge.H = $rowspan - 1 }
					$merges += $merge
				}
			}

			# Generate gap-fill cells for rowStyle
			if ($cellsStyle) {
				$gapFmtIdx = Register-CellFormat -styleName $cellsStyle -fillType ""
				for ($c = 1; $c -le $totalColumns; $c++) {
					if (-not $occupiedCols.ContainsKey($c)) {
						$rowCells += @{
							Col       = $c - 1  # 0-based
							FormatIdx = $gapFmtIdx
							Param     = $null
							Detail    = $null
							Text      = $null
							Template  = $null
						}
					}
				}
			}

			# Sort cells by column
			$rowCells = $rowCells | Sort-Object { $_.Col }

		} elseif ($cellsStyle) {
			# Row with only rowStyle, no explicit cells — fill non-rowspan columns
			$rowHasContent = $true
			$gapFmtIdx = Register-CellFormat -styleName $cellsStyle -fillType ""
			for ($c = 1; $c -le $totalColumns; $c++) {
				if ($rowspanOccupied.ContainsKey($c)) { continue }
				$rowCells += @{
					Col       = $c - 1
					FormatIdx = $gapFmtIdx
					Param     = $null
					Detail    = $null
					Text      = $null
					Template  = $null
				}
			}
		}

		# Emit rowsItem.
		# Подряд идущие ОДИНАКОВЫЕ пустые строки платформа хранит одним элементом с indexTo;
		# непустые не схлопывает, даже когда они совпадают. Поэтому пустую строку не пишем
		# сразу, а копим в пробеле и сбрасываем, когда он оборвался.
		if (-not $rowHasContent) {
			# Пустая строка тоже принадлежит раскладке: без этой записи привязка именованной
			# области, накрывающей пустые строки, не выводилась.
			$rowColumnSet[$globalRow] = $areaColumnSet
			Add-GapRow -key "$areaColumnSet|$rowFormatIdx" -row $globalRow `
				-columnSet $areaColumnSet -formatIdx $rowFormatIdx
			$localRow++
			$globalRow++
			continue
		}
		Flush-Gap

		X "`t<rowsItem>"
		X "`t`t<index>$globalRow</index>"
		X "`t`t<row>"

		$rowColumnSet[$globalRow] = $areaColumnSet
		if ($areaColumnSet) {
			X "`t`t`t<columnsID>$areaColumnSet</columnsID>"
		}

		if ($rowFormatIdx -gt 0) {
			X "`t`t`t<formatIndex>$rowFormatIdx</formatIndex>"
		}

		# Номер колонки платформа пишет только при разрыве: подряд идущая ячейка его не
		# несёт, читатель ведёт счётчик сам. Начальное значение счётчика -1, то есть у
		# ячейки в колонке 0 номера тоже нет.
		$prevCol = -1
		foreach ($cellInfo in $rowCells) {
			X "`t`t`t<c>"
			if ($cellInfo.Col -ne ($prevCol + 1)) {
				X "`t`t`t`t<i>$($cellInfo.Col)</i>"
			}
			$prevCol = $cellInfo.Col
			X "`t`t`t`t<c>"
			X "`t`t`t`t`t<f>$($cellInfo.FormatIdx)</f>"

			if ($cellInfo.Param) {
				X "`t`t`t`t`t<parameter>$($cellInfo.Param)</parameter>"
			}

			# Проверяем НАЛИЧИЕ ключа, а не истинность: пустая строка — это текст, платформа
			# такие ячейки пишет с пустым <tl>, и по истинности он терялся.
			if ($null -ne $cellInfo.Text) { Emit-CellText $cellInfo.Text }

			if ($null -ne $cellInfo.Template) { Emit-CellText $cellInfo.Template }

			if ($null -ne $cellInfo.Value) {
				X "`t`t`t`t`t<v xsi:type=`"$($cellInfo.Value.Type)`">$(Esc-XmlText $cellInfo.Value.Text)</v>"
			}

			# Настройки элемента управления платформа сериализует в base64 и держит у самой
			# ячейки. Структуру не разбираем — возим дословно, иначе она теряется.
			if ($null -ne $cellInfo.Control -and "$($cellInfo.Control)" -ne '') {
				# Блоб платформа переносит по строкам, а X дописывает перевод строки сам —
				# поэтому каждую строку блоба пишем отдельным вызовом, иначе перевод строки
				# внутри значения разошёлся бы с остальным файлом.
				$parts = @("$($cellInfo.Control)" -split "`r?`n")
				$parts[0] = "`t`t`t`t`t<control xsi:type=`"xs:base64Binary`">$($parts[0])"
				$parts[-1] = "$($parts[-1])</control>"
				foreach ($p in $parts) { X $p }
			}

			# Расшифровка от параметра заполнения не зависит: на корпусе 20 404 ячейки несут
			# её БЕЗ параметра (у текста, у пустой ячейки, у поля ввода) против 8 582 с ним.
			# Пока она стояла внутри ветки параметра, две трети расшифровок терялись молча.
			# Порядок тегов ячейки снят с корпуса: parameter · текст · detailParameter.
			if ($cellInfo.Detail) {
				X "`t`t`t`t`t<detailParameter>$($cellInfo.Detail)</detailParameter>"
			}

			# Третий параметр ячейки — имя параметра, которым подставляют картинку. Сама
			# картинка при этом задаётся оформлением (picIndex), а параметр — тут, последним
			# из параметров ячейки (21 ячейка корпуса, порядок везде такой).
			if ($cellInfo.PictureParam) {
				X "`t`t`t`t`t<pictureParameter>$(Esc-XmlText $cellInfo.PictureParam)</pictureParameter>"
			}

			# Якорь конца примечания — координаты самой ячейки, поэтому его не задают:
			# он выводится здесь, при эмиссии.
			if ($null -ne $cellInfo.Note) {
				Emit-CellNote $cellInfo.Note $cellInfo.NoteFmt $globalRow $cellInfo.Col
			}

			X "`t`t`t`t</c>"
			X "`t`t`t</c>"
		}

		X "`t`t</row>"
		X "`t</rowsItem>"

		$localRow++
		$globalRow++
	}

	$areaEndRow = $globalRow - 1
	# Блок без имени — просто кусок сетки: строки, не принадлежащие ни одной именованной
	# области (в корпусе таких дыр 34%, а макетов вовсе без Rows-областей — 21%).
	# Имя на блоке — сахар: разворачиваем его в обычную именованную область типа Rows.
	if (-not [string]::IsNullOrEmpty($areaName)) {
		$namedItems += @{
			Name      = $areaName
			BeginRow  = $areaStartRow
			EndRow    = $areaEndRow
			BeginCol  = -1
			EndCol    = -1
			ColumnSet = $areaColumnSet
		}
	}
}
Flush-Gap

$totalRowCount = $globalRow

# 7d-bis. Именованные области, заданные координатами (namedAreas).
# Нужны для всего, что блоком не выражается: области не-Rows и пересекающиеся Rows.
# Ось, которую не указали, означает «вся» — так же устроен ТабличныйДокумент.Область().

# Диапазон — та же грамматика, что у columnWidths: число или "N-M". Список через запятую
# для области бессмыслен: область непрерывна, платформа разрывную не хранит.
function ConvertTo-AreaRange {
	param($spec, [string]$axis, [string]$where)
	if ($null -eq $spec) { return $null }
	$s = ([string]$spec).Trim()
	if ($s -eq '') { return $null }
	if ($s.Contains(',')) {
		[Console]::Error.WriteLine("namedAreas: '$axis' must be a single number or range, got list `"$s`": $where")
		exit 1
	}
	if ($s -match '^(\d+)\s*-\s*(\d+)$') {
		$from = [int]$Matches[1]; $to = [int]$Matches[2]
	} elseif ($s -match '^(\d+)$') {
		$from = [int]$Matches[1]; $to = $from
	} else {
		[Console]::Error.WriteLine("namedAreas: invalid '$axis' value `"$s`": $where")
		exit 1
	}
	# Платформа трактует 0 как 1 (см. описание Область()) — принимаем так же.
	if ($from -lt 1) { $from = 1 }
	if ($to -lt $from) {
		[Console]::Error.WriteLine("namedAreas: '$axis' range is reversed `"$s`": $where")
		exit 1
	}
	return @{ From = $from; To = $to }
}

# Прощающий ввод: платформенный адрес "R1C1:R2C2" — модель, пишущая код на встроенном
# языке, естественно потянется за ним. В документацию не выносим.
function ConvertFrom-R1C1 {
	param([string]$s)
	$m = [regex]::Match($s.Trim(), '^R(\d+)(?:C(\d+))?(?::R(\d+)(?:C(\d+))?)?$', 'IgnoreCase')
	if (-not $m.Success) {
		$m2 = [regex]::Match($s.Trim(), '^C(\d+)(?::C(\d+))?$', 'IgnoreCase')
		if (-not $m2.Success) { return $null }
		$c1 = [int]$m2.Groups[1].Value
		$c2 = if ($m2.Groups[2].Success) { [int]$m2.Groups[2].Value } else { $c1 }
		return @{ Rows = $null; Cols = @{ From = $c1; To = $c2 } }
	}
	$r1 = [int]$m.Groups[1].Value
	$r2 = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $r1 }
	$cols = $null
	if ($m.Groups[2].Success) {
		$c1 = [int]$m.Groups[2].Value
		$c2 = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { $c1 }
		$cols = @{ From = $c1; To = $c2 }
	}
	return @{ Rows = @{ From = $r1; To = $r2 }; Cols = $cols }
}

if ($def.namedAreas) {
	$naIdx = 0
	foreach ($na in $def.namedAreas) {
		$naIdx++
		$naName = "$($na.name)"
		$where = "namedAreas[$naIdx]" + $(if ($naName) { " `"$naName`"" } else { '' })
		if ([string]::IsNullOrEmpty($naName)) {
			[Console]::Error.WriteLine("namedAreas: 'name' is required: $where")
			exit 1
		}
		$rows = ConvertTo-AreaRange $na.rows 'rows' $where
		$cols = ConvertTo-AreaRange $na.cols 'cols' $where
		if (-not $rows -and -not $cols) {
			$addr = $null
			foreach ($k in 'area', 'at', 'address') {
				if ($na.PSObject.Properties[$k] -and "$($na.$k)" -ne '') { $addr = "$($na.$k)"; break }
			}
			if ($addr) {
				$parsed = ConvertFrom-R1C1 $addr
				if ($null -eq $parsed) {
					[Console]::Error.WriteLine("namedAreas: invalid address `"$addr`": $where")
					exit 1
				}
				$rows = $parsed.Rows; $cols = $parsed.Cols
			}
		}
		if (-not $rows -and -not $cols) {
			[Console]::Error.WriteLine("namedAreas: at least one of 'rows'/'cols' is required: $where")
			exit 1
		}
		# Привязка к колоночной раскладке: своим ключом либо выводится из накрытых строк.
		# Три состояния: ключа нет → выводим из накрытых строк; "" → привязки нет вовсе;
		# имя → явная привязка. На корпусе область типа Rows в 13 623 случаях повторяет
		# раскладку строк и в 8 179 её не несёт, поэтому вывод обязан переопределяться.
		$naSet = ''
		$naHasKey = [bool]$na.PSObject.Properties['columnSet']
		if ($naHasKey -and -not "$($na.columnSet)") {
			$naSet = ''
		} elseif ($naHasKey) {
			$naSetName = "$($na.columnSet)"
			$naLayout = @($columnLayouts | Where-Object { $_.Name -eq $naSetName })[0]
			if (-not $naLayout) {
				[Console]::Error.WriteLine("namedAreas: unknown 'columnSet' `"$naSetName`": $where")
				exit 1
			}
			$naSet = $naLayout.Id
		} elseif ($rows) {
			$sets = @()
			for ($r = $rows.From - 1; $r -le $rows.To - 1; $r++) {
				if ($rowColumnSet.ContainsKey($r)) { $sets += $rowColumnSet[$r] }
			}
			$uniq = @($sets | Select-Object -Unique)
			if ($uniq.Count -eq 1) { $naSet = $uniq[0] }
		}
		# DSL 1-based, XML 0-based; отсутствующая ось помечается -1.
		$namedItems += @{
			Name      = $naName
			BeginRow  = if ($rows) { $rows.From - 1 } else { -1 }
			EndRow    = if ($rows) { $rows.To - 1 } else { -1 }
			BeginCol  = if ($cols) { $cols.From - 1 } else { -1 }
			EndCol    = if ($cols) { $cols.To - 1 } else { -1 }
			ColumnSet = $naSet
		}
	}
}

# 7d-bis2. Рисунки идут сразу после строк, до колонтитулов. Порядок тегов снят с корпуса:
# у всех 11 268 рисунков он один и тот же.
foreach ($dr in $drawings) {
	X "`t<drawing>"
	X "`t`t<drawingType>$($dr.Type)</drawingType>"
	X "`t`t<id>$($dr.Id)</id>"
	X "`t`t<formatIndex>$($dr.FormatIdx)</formatIndex>"
	if ($dr.Detail) { X "`t`t<detailParameter>$($dr.Detail)</detailParameter>" }
	if ($null -ne $dr.Text) {
		$pairs = @()
		if ($dr.Text -is [System.Management.Automation.PSCustomObject]) {
			foreach ($pr in $dr.Text.PSObject.Properties) { $pairs += @{ Lang = $pr.Name; Text = "$($pr.Value)" } }
		} else {
			foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$($dr.Text)" } }
		}
		X "`t`t<text>"
		foreach ($pr in $pairs) {
			X "`t`t`t<v8:item>"
			X "`t`t`t`t<v8:lang>$($pr.Lang)</v8:lang>"
			X "`t`t`t`t<v8:content>$(Esc-XmlText $pr.Text)</v8:content>"
			X "`t`t`t</v8:item>"
		}
		X "`t`t</text>"
	}
	X "`t`t<beginRow>$($dr.Begin.Row)</beginRow>"
	X "`t`t<beginRowOffset>$($dr.Begin.Dy)</beginRowOffset>"
	X "`t`t<endRow>$($dr.End.Row)</endRow>"
	X "`t`t<endRowOffset>$($dr.End.Dy)</endRowOffset>"
	X "`t`t<beginColumn>$($dr.Begin.Col)</beginColumn>"
	X "`t`t<beginColumnOffset>$($dr.Begin.Dx)</beginColumnOffset>"
	X "`t`t<endColumn>$($dr.End.Col)</endColumn>"
	X "`t`t<endColumnOffset>$($dr.End.Dx)</endColumnOffset>"
	# autoSize у рисунка на корпусе всегда false (11 268 из 11 268), «АвтоРазмер» из
	# диалога уходит в pictureSize.
	X "`t`t<autoSize>false</autoSize>"
	X "`t`t<pictureSize>$($dr.PictureSize)</pictureSize>"
	X "`t`t<zOrder>$($dr.ZOrder)</zOrder>"
	if ($dr.PictureIdx -gt 0) { X "`t`t<pictureIndex>$($dr.PictureIdx)</pictureIndex>" }
	X "`t</drawing>"
}

# 7d-ter. Колонтитулы: шесть слотов идут после строк и перед скалярными свойствами документа.
foreach ($slot in $script:headerSlots) {
	if ($def.header) { Emit-HeaderSlot "$($slot)Header" $def.header.$slot $headerFmt }
}
foreach ($slot in $script:headerSlots) {
	if ($def.footer) { Emit-HeaderSlot "$($slot)Footer" $def.footer.$slot $footerFmt }
}

# 7e-bis. Группировки строк и колонок. Платформа хранит их плоским списком диапазонов;
# вложенность выражена вхождением одного диапазона в другой, а частичных пересечений не
# бывает вовсе (корпус: 40 620 886 пар непересекающихся, 599 958 вложенных, 0 частичных).
function Get-Groups {
	param([string]$key, [string]$axis)
	$out = @()
	$idx = 0
	foreach ($g in $def.$key) {
		$idx++
		$where = "$key[$idx]"
		$spec = "$($g.$axis)".Trim()
		if (-not $spec) {
			[Console]::Error.WriteLine("${key}: '$axis' is required: $where")
			exit 1
		}
		if ($spec -match '^(\d+)\s*-\s*(\d+)$') {
			$frm = [int]$Matches[1]; $to = [int]$Matches[2]
		} elseif ($spec -match '^\d+$') {
			$frm = [int]$spec; $to = $frm
		} else {
			[Console]::Error.WriteLine("${key}: invalid '$axis' value `"$spec`": $where")
			exit 1
		}
		if ($frm -lt 1) { $frm = 1 }
		if ($to -lt $frm) {
			[Console]::Error.WriteLine("${key}: '$axis' range is reversed `"$spec`": $where")
			exit 1
		}
		$header = ''
		if ($null -ne $g.titleLocation -and "$($g.titleLocation)" -ne '') {
			switch ("$($g.titleLocation)".Trim().ToLowerInvariant()) {
				'auto'  { $header = '' }
				'begin' { $header = 'Begin' }
				'end'   { $header = 'End' }
				default {
					[Console]::Error.WriteLine("${key}: unknown 'titleLocation' value `"$($g.titleLocation)`" ($where). Allowed: begin, end, auto")
					exit 1
				}
			}
		}
		$out += @{
			B = $frm - 1; E = $to - 1
			Name = $g.name
			Collapsed = ($g.collapsed -eq $true -or "$($g.collapsed)" -eq 'true')
			Header = $header
		}
	}
	for ($i = 0; $i -lt $out.Count; $i++) {
		for ($j = $i + 1; $j -lt $out.Count; $j++) {
			$a = $out[$i]; $b = $out[$j]
			if ($a.E -lt $b.B -or $b.E -lt $a.B) { continue }
			if (($a.B -le $b.B -and $b.E -le $a.E) -or ($b.B -le $a.B -and $a.E -le $b.E)) { continue }
			[Console]::Error.WriteLine("${key}: ranges must nest or be disjoint, got a partial overlap ($($a.B + 1)-$($a.E + 1) and $($b.B + 1)-$($b.E + 1))")
			exit 1
		}
	}
	# Порядок платформы — родитель раньше детей, по возрастанию начала.
	return @($out | Sort-Object @{ Expression = { $_.B } }, @{ Expression = { -$_.E } })
}

function Get-GroupLevels {
	# Глубина вложенности. На корпусе она совпала с <vgLevels> у всех 1797 макетов.
	param($groups)
	$depth = 0
	for ($i = 0; $i -lt $groups.Count; $i++) {
		$g = $groups[$i]; $d = 1
		for ($j = 0; $j -lt $groups.Count; $j++) {
			if ($j -eq $i) { continue }
			$o = $groups[$j]
			if ($o.B -le $g.B -and $g.E -le $o.E -and -not ($o.B -eq $g.B -and $o.E -eq $g.E)) { $d++ }
		}
		if ($d -gt $depth) { $depth = $d }
	}
	return $depth
}

function Emit-Groups {
	param([string]$tag, $groups)
	foreach ($g in $groups) {
		X "`t<$tag>"
		X "`t`t<b>$($g.B)</b>"
		if ($g.E -ne $g.B) { X "`t`t<e>$($g.E)</e>" }
		if ($null -ne $g.Name) {
			$pairs = @()
			if ($g.Name -is [System.Collections.IDictionary]) {
				foreach ($k in $g.Name.Keys) { $pairs += @{ Lang = "$k"; Text = "$($g.Name[$k])" } }
			} elseif ($g.Name -is [System.Management.Automation.PSCustomObject]) {
				foreach ($pr in $g.Name.PSObject.Properties) { $pairs += @{ Lang = $pr.Name; Text = "$($pr.Value)" } }
			} else {
				foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$($g.Name)" } }
			}
			X "`t`t<t>"
			foreach ($pr in $pairs) {
				X "`t`t`t<v8:item>"
				X "`t`t`t`t<v8:lang>$($pr.Lang)</v8:lang>"
				X "`t`t`t`t<v8:content>$(Esc-XmlText $pr.Text)</v8:content>"
				X "`t`t`t</v8:item>"
			}
			X "`t`t</t>"
		}
		# Развёрнутая группировка тега не пишет: на корпусе <o> только со значением false.
		if ($g.Collapsed) { X "`t`t<o>false</o>" }
		if ($g.Header) { X "`t`t<g>$($g.Header)</g>" }
		X "`t</$tag>"
	}
}

$rowGroups = Get-Groups 'rowGroups' 'rows'
$colGroups = Get-Groups 'columnGroups' 'cols'

# 7e. Scalar metadata
X "`t<templateMode>true</templateMode>"
X "`t<defaultFormatIndex>$defaultFormatIndex</defaultFormatIndex>"
# Рисунок расширяет документ, не создавая строк: на стендах высота равна нижней границе
# самого нижнего рисунка, при том что строк записана всего одна.
$docHeight = $totalRowCount
foreach ($dr in $drawings) {
	if (($dr.End.Row + 1) -gt $docHeight) { $docHeight = $dr.End.Row + 1 }
}
X "`t<height>$docHeight</height>"
if ($rowGroups.Count -gt 0) { X "`t<vgLevels>$(Get-GroupLevels $rowGroups)</vgLevels>" }
X "`t<vgRows>$docHeight</vgRows>"
Emit-Groups 'vg' $rowGroups
Emit-Groups 'hg' $colGroups

Emit-PrintSettings $def.printSettings

# 7f. Merges
foreach ($m in $merges) {
	X "`t<merge>"
	X "`t`t<r>$($m.R)</r>"
	X "`t`t<c>$($m.C)</c>"
	if ($m.H) { X "`t`t<h>$($m.H)</h>" }
	X "`t`t<w>$($m.W)</w>"
	X "`t</merge>"
}

# 7g. Named items
# Платформа хранит именованные элементы ОТСОРТИРОВАННЫМИ по имени: на выборке 541 макета
# с несколькими элементами иного порядка нет ни разу. Сортировка регистронезависимая и
# ординальная — Sort-Object брать нельзя, он сортирует по текущей культуре и на кириллице
# даст другой порядок. NB: имён с «ё» в выборке не встретилось, этот случай не проверен.
# Sort-Object сортирует по текущей культуре даже с -CaseSensitive, поэтому сортируем по
# ключу из кодов символов: в нём только 0-9A-F, и культурные правила его переупорядочить
# не могут. Прежний вариант давал на кириллице не тот порядок, что py-порт.
function Get-OrdinalKey {
	param([string]$name)
	return (($name.ToLowerInvariant().ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '')
}
# Имя рисунка — namedItem другого типа, но список общий: на корпусе оба вида отсортированы
# вместе по имени во всех 266 макетах с именованными рисунками.
foreach ($dr in $drawings) {
	if ($dr.Name) { $namedItems += @{ Name = "$($dr.Name)"; DrawingId = $dr.Id } }
}
$sortedNamedItems = @($namedItems | Sort-Object -Property @{ Expression = { Get-OrdinalKey $_.Name } })
foreach ($ni in $sortedNamedItems) {
	if ($ni.DrawingId) {
		X "`t<namedItem xsi:type=`"NamedItemDrawing`">"
		X "`t`t<name>$($ni.Name)</name>"
		X "`t`t<drawingID>$($ni.DrawingId)</drawingID>"
		X "`t</namedItem>"
		continue
	}
	# Тип области выводится из указанных осей, как в ТабличныйДокумент.Область():
	# нет колонок → полоса строк, нет строк → полоса колонок, обе → прямоугольник.
	$hasRows = $ni.BeginRow -ge 0
	$hasCols = $ni.BeginCol -ge 0
	$type = if ($hasRows -and $hasCols) { 'Rectangle' } elseif ($hasCols) { 'Columns' } else { 'Rows' }
	X "`t<namedItem xsi:type=`"NamedItemCells`">"
	X "`t`t<name>$($ni.Name)</name>"
	X "`t`t<area>"
	X "`t`t`t<type>$type</type>"
	X "`t`t`t<beginRow>$($ni.BeginRow)</beginRow>"
	X "`t`t`t<endRow>$($ni.EndRow)</endRow>"
	X "`t`t`t<beginColumn>$($ni.BeginCol)</beginColumn>"
	X "`t`t`t<endColumn>$($ni.EndCol)</endColumn>"
	if ($ni.ColumnSet) { X "`t`t`t<columnsID>$($ni.ColumnSet)</columnsID>" }
	X "`t`t</area>"
	X "`t</namedItem>"
}

# 7h. Line palette
foreach ($ln in $script:lineRegistry) {
	X "`t<line width=`"$($ln.Width)`" gap=`"$($ln.Gap)`">"
	$lineKind = if ($ln.Kind -ceq 'Drawing') { 'SpreadsheetDocumentDrawingLineType' } else { 'SpreadsheetDocumentCellLineType' }
	X "`t`t<v8ui:style xsi:type=`"v8ui:$lineKind`">$($ln.Style)</v8ui:style>"
	X "`t</line>"
}

# 7i. Font palette
foreach ($fe in $fontEntries) {
	if ($fe.Ref) {
		# Префикс sys в корне документа не объявлен, поэтому платформа дописывает объявление
		# прямо на узел — тот же приём, что с цветами из web-палитры.
		if ($fe.Ref -like 'sys:*') {
			X "`t<font xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" ref=`"$(Esc-Xml $fe.Ref)`" kind=`"$($fe.Kind)`"/>"
		} else {
			X "`t<font ref=`"$(Esc-Xml $fe.Ref)`" kind=`"$($fe.Kind)`"/>"
		}
		continue
	}
	X "`t<font faceName=`"$($fe.Face)`" height=`"$(Format-Num $fe.Size)`" bold=`"$($fe.Bold)`" italic=`"$($fe.Italic)`" underline=`"$($fe.Underline)`" strikeout=`"$($fe.Strikeout)`" kind=`"Absolute`" scale=`"100`"/>"
}

# 7j. Format palette
foreach ($key in $formatRegistry.Keys) {
	$fmt = $formatRegistry[$key]
	X "`t<format>"

	foreach ($tag in $script:formatTagOrder) {
		if (-not $fmt.ContainsKey($tag)) { continue }
		$val = $fmt[$tag]
		if ($script:formatMlTags.ContainsKey($tag)) {
			X "`t`t<$tag>"
			X "`t`t`t<v8:item>"
			X "`t`t`t`t<v8:lang>ru</v8:lang>"
			X "`t`t`t`t<v8:content>$(Esc-XmlText $val)</v8:content>"
			X "`t`t`t</v8:item>"
			X "`t`t</$tag>"
		} elseif ($tag -ceq 'valueType') {
			# Пустой тип — самостоятельное состояние: «содержит значение», тип не задан.
			if ("$val" -eq '') {
				X "`t`t<valueType/>"
			} else {
				X "`t`t<valueType>"
				Emit-ValueTypeContent "`t`t`t" "$val"
				X "`t`t</valueType>"
			}
		} elseif ($script:formatTagKind[$tag] -ceq 'color' -and (Get-ColorNamespace "$val")) {
			# web/win-палитры в корне документа не объявлены — платформа дописывает объявление
			# прямо на узел и пишет значение с этим префиксом.
			$ns = Get-ColorNamespace "$val"
			$name = "$val".Substring("$val".IndexOf(':') + 1)
			X "`t`t<$tag xmlns:d3p1=`"$ns`">d3p1:$name</$tag>"
		} else {
			X "`t`t<$tag>$val</$tag>"
		}
	}

	X "`t</format>"
}

# 7k. Палитра картинок — последний блок документа. Индекс здесь 0-based, а ссылки
# на него (pictureIndex рисунка, picIndex стиля) 1-based.
$picIdx = 0
foreach ($pic in $pictureEntries) {
	X "`t<picture>"
	X "`t`t<index>$picIdx</index>"
	# Прозрачность записывается перед ссылкой и не зависит от того, где лежит картинка:
	# в БП 8.3.27 таких ссылочных записей 67.
	$attr = if ($pic.Transparent) { " t=`"$($pic.Transparent)`"" } else { '' }
	if ($pic.PixelX) { $attr += " tx=`"$($pic.PixelX)`" ty=`"$($pic.PixelY)`"" }
	if ($pic.Ref) {
		X "`t`t<picture$attr ref=`"$(Esc-Xml $pic.Ref)`"/>"
	} elseif (-not $pic.Data) {
		X "`t`t<picture/>"
	} else {
		# Данные платформа переносит по строкам тем же переводом, что и весь файл, —
		# в отличие от блоба настроек элемента управления, где перенос голый LF.
		$parts = @("$($pic.Data)" -split "`r?`n")
		$parts[0] = "`t`t<picture$attr>$($parts[0])"
		$parts[-1] = "$($parts[-1])</picture>"
		foreach ($line in $parts) { X $line }
	}
	X "`t</picture>"
	$picIdx++
}

# 7l. Close document
X '</document>'

# --- 8. Write output ---

$enc = New-Object System.Text.UTF8Encoding($true)
$resolvedPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
# Каталог назначения создаём сами: типовой путь — Templates/<Имя>/Ext/Template.xml,
# и его может ещё не быть. Так делают и form-compile, и skd-compile, и py-порт этого
# навыка; без этого PS-порт падал на «Could not find a part of the path».
$outDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Assert-EditAllowed $resolvedPath 'editable'
[System.IO.File]::WriteAllText($resolvedPath, $xml.ToString().TrimEnd("`r", "`n"), $enc)

# --- 9. Summary ---

Write-Host "[OK] Compiled: $OutputPath"
if ($def.page) {
	Write-Host "     Page: $pageName -> target $targetWidth, defaultWidth=$defaultWidth"
}
Write-Host "     Areas: $($namedItems.Count), Rows: $totalRowCount, Columns: $totalColumns"
Write-Host "     Fonts: $($fontEntries.Count), Lines: $($script:lineRegistry.Count), Formats: $($formatRegistry.Count)"
Write-Host "     Merges: $($merges.Count)"
