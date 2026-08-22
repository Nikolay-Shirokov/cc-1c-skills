# form-add v1.28 — Add managed form to 1C config object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[string]$ObjectPath,

	[Parameter(Mandatory)]
	[string]$FormName,

	[string]$Synonym = $FormName,

	# Пусто = основная форма вида (Primary в таблице): у справочника это форма объекта,
	# у регистра сведений — форма записи, у журнала — форма списка. Жёсткое "Object"
	# по умолчанию было бы неверным для видов, у которых формы объекта не бывает.
	[string]$Purpose = "",

	# Алиас с дефисом внутри имени: вызов вида --set-default PowerShell разбирает как имя
	# параметра "set-default" и без алиаса отвечает отказом биндинга. Написания -SetDefault,
	# --SetDefault и --setdefault совпадают с именем параметра и так.
	[Alias('set-default')]
	[switch]$SetDefault
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

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

# --- Фаза 1: Определение типа объекта ---

# Resolve ObjectPath (directory → .xml)
if (-not [System.IO.Path]::IsPathRooted($ObjectPath)) {
	$ObjectPath = Join-Path (Get-Location).Path $ObjectPath
}
if (Test-Path $ObjectPath -PathType Container) {
	$dirName = Split-Path $ObjectPath -Leaf
	$candidate = Join-Path $ObjectPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $ObjectPath) "$dirName.xml"
	if (Test-Path $candidate) { $ObjectPath = $candidate }
	elseif (Test-Path $sibling) { $ObjectPath = $sibling }
}

if (-not (Test-Path $ObjectPath)) {
	Write-Error "Файл объекта не найден: $ObjectPath"
	exit 1
}

$objectXmlFull = Resolve-Path $ObjectPath
Assert-EditAllowed $objectXmlFull.Path 'editable'
# Версию берём прежде всего из корня самого объекта — он её несёт всегда, а у автономной
# внешней обработки/отчёта подниматься к Configuration.xml просто некуда.
$script:formatVersion = $null
$objHead = [System.IO.File]::ReadAllText($objectXmlFull.Path, [System.Text.Encoding]::UTF8)
$objHead = $objHead.Substring(0, [Math]::Min(2000, $objHead.Length))
if ($objHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { $script:formatVersion = $Matches[1] }
if (-not $script:formatVersion) { $script:formatVersion = Detect-FormatVersion (Split-Path $objectXmlFull.Path -Parent) }

# Объявления пространств имён — одной переменной на корень: места эмиссии их только
# интерполируют. Правки шапки (как xmlns:pal в формате 2.21) делаются здесь, в одном месте.
$script:xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
$script:formNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# 2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
# Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
# дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$script:xmlnsDecl = $script:xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
	$script:formNsDecl = $script:formNsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($objectXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

# Определяем тип объекта по корневому тегу внутри MetaDataObject
$metaDataObject = $xmlDoc.SelectSingleNode("//md:MetaDataObject", $nsMgr)
if (-not $metaDataObject) {
	# Пробуем без namespace (fallback)
	$metaDataObject = $xmlDoc.DocumentElement
}

# --- Таблица видов: вид → допустимые назначения ---
#
# Одна запись на вид вместо разрозненных списков «поддерживаемые типы», «объектные типы»,
# «обработко-подобные» и «карта типов реквизита». Раньше они расходились молча: DocumentJournal
# был среди поддерживаемых, но не в карте типов, и в форму уходило `cfg:.Журнал` — платформа
# такую выгрузку не принимает, а навык рапортовал успех.
#
# MainAttr — тип главного реквизита; `{0}` подставляется именем объекта:
#   "DynamicList" — динамический список (добавляется Settings/MainTable);
#   $null         — произвольная форма, блока Attributes нет вовсе.
# Slot — свойство объекта под «основную форму»; $null — такого свойства у вида нет.
# Эталон таблицы — docs/1c-form-spec.md, сверяется гардом check-form-purposes.mjs.

$formKinds = @{
	"Catalog" = @{
		"Object"       = @{ MainAttr = "CatalogObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"Folder"       = @{ MainAttr = "CatalogObject.{1}"; AttrName = "Объект"; Slot = "DefaultFolderForm"; SavedData = $true }
		"List"         = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice"       = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"FolderChoice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultFolderChoiceForm" }
		"Custom"       = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ChartOfCharacteristicTypes" = @{
		"Object"       = @{ MainAttr = "ChartOfCharacteristicTypesObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"Folder"       = @{ MainAttr = "ChartOfCharacteristicTypesObject.{1}"; AttrName = "Объект"; Slot = "DefaultFolderForm"; SavedData = $true }
		"List"         = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice"       = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"FolderChoice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultFolderChoiceForm" }
		"Custom"       = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"Document" = @{
		"Object" = @{ MainAttr = "DocumentObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ChartOfAccounts" = @{
		"Object" = @{ MainAttr = "ChartOfAccountsObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ChartOfCalculationTypes" = @{
		"Object" = @{ MainAttr = "ChartOfCalculationTypesObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ExchangePlan" = @{
		"Object" = @{ MainAttr = "ExchangePlanObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"BusinessProcess" = @{
		"Object" = @{ MainAttr = "BusinessProcessObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"Task" = @{
		"Object" = @{ MainAttr = "TaskObject.{1}"; AttrName = "Объект"; Slot = "DefaultObjectForm"; SavedData = $true; Primary = $true }
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"DataProcessor" = @{
		"Object" = @{ MainAttr = "DataProcessorObject.{1}"; AttrName = "Объект"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"Report" = @{
		"Object" = @{ MainAttr = "ReportObject.{1}"; AttrName = "Объект"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ExternalDataProcessor" = @{
		"Object" = @{ MainAttr = "ExternalDataProcessorObject.{1}"; AttrName = "Объект"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"ExternalReport" = @{
		"Object" = @{ MainAttr = "ExternalReportObject.{1}"; AttrName = "Объект"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"InformationRegister" = @{
		"Record"    = @{ MainAttr = "InformationRegisterRecordManager.{1}"; AttrName = "Запись"; Slot = "DefaultRecordForm"; SavedData = $true; Primary = $true }
		"List"      = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm" }
		"RecordSet" = @{ MainAttr = "InformationRegisterRecordSet.{1}"; AttrName = "Набор"; Slot = $null; SavedData = $true }
		"Custom"    = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"AccumulationRegister" = @{
		"List"      = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm"; Primary = $true }
		"RecordSet" = @{ MainAttr = "AccumulationRegisterRecordSet.{1}"; AttrName = "Набор"; Slot = $null; SavedData = $true }
		"Custom"    = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"AccountingRegister" = @{
		"List"      = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm"; Primary = $true }
		"RecordSet" = @{ MainAttr = "AccountingRegisterRecordSet.{1}"; AttrName = "Набор"; Slot = $null; SavedData = $true }
		"Custom"    = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"CalculationRegister" = @{
		"List"      = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm"; Primary = $true }
		"RecordSet" = @{ MainAttr = "CalculationRegisterRecordSet.{1}"; AttrName = "Набор"; Slot = $null; SavedData = $true }
		"Custom"    = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"DocumentJournal" = @{
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"FilterCriterion" = @{
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultForm"; Primary = $true }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"Enum" = @{
		"List"   = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultListForm"; Primary = $true }
		"Choice" = @{ MainAttr = "DynamicList"; AttrName = "Список"; Slot = "DefaultChoiceForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
	"SettingsStorage" = @{
		"Save"   = @{ MainAttr = $null; AttrName = $null; Slot = "DefaultSaveForm"; Primary = $true }
		"Load"   = @{ MainAttr = $null; AttrName = $null; Slot = "DefaultLoadForm" }
		"Custom" = @{ MainAttr = $null; AttrName = $null; Slot = $null }
	}
}

# Виды, у которых свойство DefaultForm есть, но собственных форм не бывает — отказ с причиной,
# а не «тип не поддерживается».
$noOwnForms = @{
	"Constant" = "у константы нет собственных форм — используйте общую форму (CommonForm)"
}

$supportedTypes = @($formKinds.Keys) + @($noOwnForms.Keys)

# Отдельный факт, не выводимый из таблицы назначений: у форм обработок и отчётов в метаданных
# формы есть <ExtendedPresentation>.
$processorLikeTypes = @("DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport")

# Вид объекта — первый элемент-потомок MetaDataObject, а не первое совпавшее по всему документу
# имя. Поиск по документу зависел от порядка перебора видов: у бизнес-процесса есть свойство
# <Task>, и он определялся как задача, после чего имя объекта не находилось вовсе.
$objectType = $null
$objectNode = $null
foreach ($child in $metaDataObject.ChildNodes) {
	if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
		$objectType = $child.LocalName
		$objectNode = $child
		break
	}
}

if ($objectType -and -not ($formKinds.ContainsKey($objectType) -or $noOwnForms.ContainsKey($objectType))) {
	Write-Error "Тип объекта '$objectType' не поддерживается. Поддерживаемые типы: $(($formKinds.Keys | Sort-Object) -join ', ')"
	exit 1
}

if (-not $objectType) {
	Write-Error "Не удалось определить тип объекта. Поддерживаемые типы: $(($formKinds.Keys | Sort-Object) -join ', ')"
	exit 1
}

if ($noOwnForms.ContainsKey($objectType)) {
	Write-Error "$objectType не поддерживается: $($noOwnForms[$objectType])"
	exit 1
}

# Имя объекта из Properties/Name
$objectName = $xmlDoc.SelectSingleNode("//md:${objectType}/md:Properties/md:Name", $nsMgr).InnerText
if (-not $objectName) {
	Write-Error "Не удалось определить имя объекта из Properties/Name"
	exit 1
}

Write-Host ""
Write-Host "=== form-add ==="
Write-Host ""
Write-Host "Object: $objectType.$objectName"

# --- Фаза 2: Валидация Purpose ---

# Назначение ищем в таблице регистронезависимо — как принимает PowerShell (в py-порту .lower()).
$kindPurposes = $formKinds[$objectType]

# Обиходные написания назначения приводим к канону молча: русское название вида формы и
# английское с суффиксом Form. Ключ нормализуем — регистр, пробелы и разделители не значимы.
# Канон в документации один; здесь только приём ошибочного ввода, чтобы вызов не падал на форме
# записи вместо назначения. Применимость назначения к виду объекта проверяется ниже как обычно.
$purposeSynonyms = @{
	"формаобъекта"="Object"; "формаэлемента"="Object"; "формадокумента"="Object"
	"объект"="Object"; "элемент"="Object"; "документ"="Object"; "objectform"="Object"
	"формасписка"="List"; "список"="List"; "listform"="List"
	"формавыбора"="Choice"; "выбор"="Choice"; "choiceform"="Choice"
	"формагруппы"="Folder"; "группа"="Folder"; "folderform"="Folder"
	"формавыборагруппы"="FolderChoice"; "выборгруппы"="FolderChoice"; "folderchoiceform"="FolderChoice"
	"формазаписи"="Record"; "запись"="Record"; "recordform"="Record"
	"форманаборазаписей"="RecordSet"; "наборзаписей"="RecordSet"; "recordsetform"="RecordSet"
	"формасохранения"="Save"; "формасохранениянастроек"="Save"; "сохранение"="Save"; "saveform"="Save"
	"формазагрузки"="Load"; "формазагрузкинастроек"="Load"; "загрузка"="Load"; "loadform"="Load"
	"произвольная"="Custom"; "произвольнаяформа"="Custom"; "customform"="Custom"
}
if ($Purpose) {
	$purposeProbe = ($Purpose -replace '[\s_-]', '').ToLowerInvariant()
	$isKnownPurpose = $false
	foreach ($p in $kindPurposes.Keys) {
		if ($p.ToLowerInvariant() -eq $Purpose.ToLowerInvariant()) { $isKnownPurpose = $true; break }
	}
	if (-not $isKnownPurpose -and $purposeSynonyms.ContainsKey($purposeProbe)) {
		$Purpose = $purposeSynonyms[$purposeProbe]
	}
}
if (-not $Purpose) {
	foreach ($p in $kindPurposes.Keys) {
		if ($kindPurposes[$p].Primary) { $Purpose = $p; break }
	}
}
$purposeKey = $null
foreach ($p in $kindPurposes.Keys) {
	if ($p.ToLowerInvariant() -eq $Purpose.ToLowerInvariant()) { $purposeKey = $p; break }
}
if (-not $purposeKey) {
	Write-Error "Назначение '$Purpose' недопустимо для $objectType. Допустимые: $(($kindPurposes.Keys | Sort-Object) -join ', ')"
	exit 1
}
$Purpose = $purposeKey
$purposeRule = $kindPurposes[$Purpose]

# Гард от повторения дефекта: запись таблицы обязана быть заполненной. Пустой MainAttr — это
# произвольная форма (законное состояние), а вот наполовину заполненная запись означала бы, что
# таблицу правили невнимательно, и в XML уйдёт мусор вроде `cfg:.Журнал`.
if ($purposeRule.MainAttr -and -not $purposeRule.AttrName) {
	Write-Error "Внутренняя ошибка таблицы видов: у $objectType/$Purpose задан MainAttr без AttrName"
	exit 1
}

# --- Фаза 3: Создание файлов ---

$objectDir = [System.IO.Path]::ChangeExtension($objectXmlFull.Path, $null).TrimEnd('.')
$formsDir = Join-Path $objectDir "Forms"
$formMetaPath = Join-Path $formsDir "$FormName.xml"

if (Test-Path $formMetaPath) {
	Write-Error "Форма уже существует: $formMetaPath"
	exit 1
}

$formDir = Join-Path $formsDir $FormName
$formExtDir = Join-Path $formDir "Ext"
$formModuleDir = Join-Path $formExtDir "Form"

New-Item -ItemType Directory -Path $formModuleDir -Force | Out-Null

$encBom = New-Object System.Text.UTF8Encoding($true)

# --- 3a. Метаданные формы ---

$formUuid = [guid]::NewGuid().ToString()

# ExtendedPresentation — only for DataProcessor, Report, ExternalDataProcessor, ExternalReport forms
$extPresentationLine = ""
if ($objectType -in $processorLikeTypes) {
	$extPresentationLine = "`n`t`t`t<ExtendedPresentation/>"
}

# Использование в режиме совместимости интерфейса — свойство формата 2.21 (8.5),
# сразу после UsePurposes (проверено по выгрузке 8.5, до ExtendedPresentation).
$useInIfcLine = ""
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$useInIfcLine = "`n`t`t`t<UseInInterfaceCompatibilityMode>Any</UseInInterfaceCompatibilityMode>"
}

$formMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $($script:xmlnsDecl) version="$($script:formatVersion)">
	<Form uuid="$formUuid">
		<Properties>
			<Name>$FormName</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$Synonym</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
				<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
			</UsePurposes>$useInIfcLine$extPresentationLine
		</Properties>
	</Form>
</MetaDataObject>
"@

# XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.
#
# Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
# копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
#
# Модуль .bsl сюда НЕ идёт — он пишется отдельно.
function Write-XmlFile([string]$path, [string]$text, $encoding) {
	$t = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($path, $t.TrimEnd("`r", "`n"), $encoding)
}

Write-XmlFile $formMetaPath $formMetaXml $encBom

# --- 3b. Form.xml ---

$formXmlPath = Join-Path $formExtDir "Form.xml"

# Одна ветка вместо трёх: что писать, решает запись таблицы видов. Раньше тип главного
# реквизита брался из отдельной карты, и отсутствие вида в ней давало `cfg:.Имя` — молча.
$attributesBlock = ""
if ($purposeRule.MainAttr) {
	$mainAttrType = $purposeRule.MainAttr -f $objectType, $objectName
	$mainAttrName = $purposeRule.AttrName

	# Динамический список несёт MainTable, остальные типы — SavedData по записи таблицы.
	$tailLines = ""
	if ($mainAttrType -eq "DynamicList") {
		$mainTable = "$objectType.$objectName"
		$tailLines = "`n`t`t`t<Settings xsi:type=""DynamicList"">`n`t`t`t`t<MainTable>$mainTable</MainTable>`n`t`t`t</Settings>"
	} elseif ($purposeRule.SavedData) {
		$tailLines = "`n`t`t`t<SavedData>true</SavedData>"
	}

	$attributesBlock = @"

	<Attributes>
		<Attribute name="$mainAttrName" id="1">
			<Type>
				<v8:Type>cfg:$mainAttrType</v8:Type>
			</Type>
			<MainAttribute>true</MainAttribute>$tailLines
		</Attribute>
	</Attributes>
"@
}

# Произвольная форма (MainAttr = $null) — без блока Attributes вовсе. В типовых это самая
# частая форма после объектной: 907 у справочников, 941 у документов, 3482 у отчётов.
$formXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Form $($script:formNsDecl) version="$($script:formatVersion)">
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>true</Autofill>
	</AutoCommandBar>
	<ChildItems/>$attributesBlock
</Form>
"@

if (Test-Path $formXmlPath) {
	Write-Host "[SKIP] Form.xml already exists: $formXmlPath — not overwriting"
} else {
	Write-XmlFile $formXmlPath $formXml $encBom
}

# --- 3c. Module.bsl ---

$modulePath = Join-Path $formModuleDir "Module.bsl"

$moduleBsl = @"
#Область ОбработчикиСобытийФормы

#КонецОбласти

#Область ОбработчикиСобытийЭлементовФормы

#КонецОбласти

#Область ОбработчикиКомандФормы

#КонецОбласти

#Область ОбработчикиОповещений

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти
"@

if (Test-Path $modulePath) {
	Write-Host "[SKIP] Module.bsl already exists: $modulePath — not overwriting"
} else {
	# Модуль пишем в каноне платформы: CRLF в разделителях строк (корпус: 2643 CRLF,
	# чисто-LF 0 из 3001). Хвостовой перевод НЕ навязываем — у платформы он
	# неканоничен (1235 модулей с ним, 766 без). Шаблон берёт переводы строк из
	# самого скрипта, а он в репозитории хранится с LF.
	$moduleBsl = ($moduleBsl -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($modulePath, $moduleBsl, $encBom)
}

# --- Фаза 4: Регистрация в родительском объекте ---

$childObjects = $xmlDoc.SelectSingleNode("//md:${objectType}/md:ChildObjects", $nsMgr)
if (-not $childObjects) {
	Write-Error "Не найден элемент ChildObjects в $ObjectPath"
	exit 1
}

# Добавить <Form>$FormName</Form> — идемпотентно (не дублировать уже зарегистрированную)
$alreadyRegistered = [bool]$childObjects.SelectSingleNode("md:Form[text()='$FormName']", $nsMgr)

if (-not $alreadyRegistered) {
$formElem = $xmlDoc.CreateElement("Form", "http://v8.1c.ru/8.3/MDClasses")
$formElem.InnerText = $FormName

# Ищем первый <Template> для вставки перед ним
$firstTemplate = $childObjects.SelectSingleNode("md:Template", $nsMgr)
# Ищем первую <TabularSection> для вставки перед ней (если нет Template)
$firstTabular = $childObjects.SelectSingleNode("md:TabularSection", $nsMgr)

# Определяем точку вставки: перед Template, перед TabularSection, или в конец
$insertBefore = $null
if ($firstTemplate) {
	$insertBefore = $firstTemplate
} elseif ($firstTabular) {
	$insertBefore = $firstTabular
}

if ($insertBefore) {
	# Вставить перед найденным элементом, с переносом строки
	$whitespace = $xmlDoc.CreateWhitespace("`n`t`t`t")
	$childObjects.InsertBefore($formElem, $insertBefore) | Out-Null
	$childObjects.InsertBefore($whitespace, $formElem) | Out-Null
	# Переставляем: whitespace перед formElem — неправильный порядок
	# Правильно: formElem, затем whitespace перед insertBefore
	# InsertBefore возвращает вставленный узел, порядок: ... formElem whitespace insertBefore ...
	# На самом деле нам нужно: ... \n\t\t\tformElem \n\t\t\tinsertBefore
	# Удалим и вставим правильно
	$childObjects.RemoveChild($whitespace) | Out-Null
	$childObjects.RemoveChild($formElem) | Out-Null

	$childObjects.InsertBefore($formElem, $insertBefore) | Out-Null
	# Whitespace нужен ДО formElem (перенос строки + отступ)
	# Но перед insertBefore уже должен быть whitespace от предыдущего элемента
	# Нам нужно добавить whitespace ПОСЛЕ formElem (перед insertBefore)
	$ws = $xmlDoc.CreateWhitespace("`n`t`t`t")
	$childObjects.InsertBefore($ws, $insertBefore) | Out-Null
} else {
	# Добавить в конец ChildObjects
	if ($childObjects.ChildNodes.Count -eq 0) {
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
		$childObjects.AppendChild($formElem) | Out-Null
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
	} else {
		$lastChild = $childObjects.LastChild
		if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
			$childObjects.InsertBefore($xmlDoc.CreateWhitespace("`n`t`t`t"), $lastChild) | Out-Null
			$childObjects.InsertBefore($formElem, $lastChild) | Out-Null
		} else {
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
			$childObjects.AppendChild($formElem) | Out-Null
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
		}
	}
}
}

# --- SetDefault ---

$existingForms = $childObjects.SelectNodes("md:Form", $nsMgr)
$isFirstFormForPurpose = $false
$defaultPropName = $null
$defaultValue = "$objectType.$objectName.Form.$FormName"

# Свойство «основная форма» — из записи таблицы. Раньше выбиралось по одному Purpose без учёта
# вида, и для журнала писалось DefaultListForm, которого у журнала нет: слот не находился, навык
# молча ничего не делал.
$defaultPropName = $purposeRule.Slot

$defaultNode = $null
if ($defaultPropName) {
	$defaultNode = $xmlDoc.SelectSingleNode("//md:${objectType}/md:Properties/md:$defaultPropName", $nsMgr)
	if ($defaultNode) {
		$isFirstFormForPurpose = [string]::IsNullOrWhiteSpace($defaultNode.InnerText)
	}
}

$defaultUpdated = $false
if ($SetDefault -or $isFirstFormForPurpose) {
	if ($defaultNode) {
		$defaultNode.InnerText = $defaultValue
		$defaultUpdated = $true
	}
}

# Сохранить с BOM
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $encBom
$settings.Indent = $false
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

# Через MemoryStream, а не прямо в файл: нужен шаг пост-обработки строки.
$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$xmlDoc.Save($writer)
$writer.Flush(); $writer.Close()

$xmlText = [System.Text.Encoding]::UTF8.GetString($memStream.ToArray())
$memStream.Close()
if ($xmlText.Length -gt 0 -and $xmlText[0] -eq [char]0xFEFF) { $xmlText = $xmlText.Substring(1) }
$xmlText = $xmlText.Replace('encoding="utf-8"', 'encoding="UTF-8"')
# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
# поэтому они идут первыми ветками альтернации и возвращаются как есть.
$xmlText = [regex]::Replace($xmlText, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
$targetEol = if ((Test-Path -LiteralPath $objectXmlFull.Path) -and ([System.IO.File]::ReadAllText($objectXmlFull.Path) -notmatch "`r`n")) { "`n" } else { "`r`n" }
$xmlText = ($xmlText -replace "`r`n", "`n") -replace "`n", $targetEol
[System.IO.File]::WriteAllText($objectXmlFull.Path, $xmlText, $encBom)

# --- Фаза 5: Вывод ---

# Относительные пути для вывода
$basePath = Split-Path $objectXmlFull.Path -Parent
# Определяем корень (ищем родительский каталог типа Documents, Catalogs и т.д.)
$relFormMeta = $formMetaPath.Replace($basePath, "").TrimStart("\", "/")
$relFormXml = $formXmlPath.Replace($basePath, "").TrimStart("\", "/")
$relModule = $modulePath.Replace($basePath, "").TrimStart("\", "/")

$objFileName = [System.IO.Path]::GetFileName($ObjectPath)
$objDirName = Split-Path $ObjectPath -Parent
$objBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ObjectPath)

Write-Host "Created:"
Write-Host "  Metadata: $objDirName\$objBaseName\Forms\$FormName.xml"
Write-Host "  Form:     $objDirName\$objBaseName\Forms\$FormName\Ext\Form.xml"
Write-Host "  Module:   $objDirName\$objBaseName\Forms\$FormName\Ext\Form\Module.bsl"
Write-Host ""
if ($alreadyRegistered) {
	Write-Host "Already registered: <Form>$FormName</Form> in ChildObjects (skipped duplicate)"
} else {
	Write-Host "Registered: <Form>$FormName</Form> in ChildObjects"
}
if ($defaultUpdated) {
	Write-Host "${defaultPropName}: $defaultValue"
} elseif (-not $defaultPropName) {
	# Молчать здесь нельзя: пользователь ждёт, что форма станет основной, а свойства под неё
	# у платформы нет (форма набора записей, произвольная форма).
	Write-Host "Основной не назначена: у $objectType нет свойства для формы с назначением $Purpose"
}
Write-Host ""
