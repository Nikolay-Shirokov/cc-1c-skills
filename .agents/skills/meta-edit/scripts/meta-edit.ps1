# meta-edit v1.22 — Edit existing 1C metadata object XML
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$DefinitionFile,

	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$ObjectPath,

	# Inline mode (alternative to DefinitionFile)
	[ValidateSet(
		"add-attribute", "add-ts", "add-dimension", "add-resource",
		"add-enumValue", "add-column", "add-form", "add-template", "add-command",
		"add-owner", "add-registerRecord", "add-basedOn", "add-inputByString",
		"add-dataLockField", "add-registeredDocument", "add-predefined",
		"remove-attribute", "remove-ts", "remove-dimension", "remove-resource",
		"remove-enumValue", "remove-column", "remove-form", "remove-template", "remove-command",
		"remove-owner", "remove-registerRecord", "remove-basedOn", "remove-inputByString",
		"remove-dataLockField", "remove-registeredDocument",
		"add-ts-attribute", "remove-ts-attribute", "modify-ts-attribute", "modify-ts",
		"modify-attribute", "modify-dimension", "modify-resource",
		"modify-enumValue", "modify-column",
		"modify-property",
		"set-owners", "set-registerRecords", "set-basedOn", "set-inputByString",
		"set-dataLockFields", "set-registeredDocuments"
	)]
	[string]$Operation,
	[string]$Value,

	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================
# Section 1: Parameters + loading
# ============================================================

# --- Mode validation ---
if ($DefinitionFile -and $Operation) {
	Write-Error "Cannot use both -DefinitionFile and -Operation"
	exit 1
}
if (-not $DefinitionFile -and -not $Operation) {
	Write-Error "Either -DefinitionFile or -Operation is required"
	exit 1
}

# --- Enum value normalization (same as meta-compile) ---
$script:enumValueAliases = @{
	"Balances" = "Balance"; "Остатки" = "Balance"; "Обороты" = "Turnovers"
	"RecordSubordinate" = "RecorderSubordinate"; "Subordinate" = "RecorderSubordinate"
	"ПодчинениеРегистратору" = "RecorderSubordinate"; "Независимый" = "Independent"
	"NotDependOnCalculationTypes" = "DontUse"; "NoDependence" = "DontUse"; "NotUsed" = "DontUse"
	"Depend" = "OnActionPeriod"; "ПоПериодуДействия" = "OnActionPeriod"
	"None" = "Nonperiodical"; "Daily" = "Day"; "Monthly" = "Month"
	"Quarterly" = "Quarter"; "Yearly" = "Year"
	"Непериодический" = "Nonperiodical"; "Секунда" = "Second"; "День" = "Day"; "Месяц" = "Month"
	"Квартал" = "Quarter"; "Год" = "Year"
	"ПозицияРегистратора" = "RecorderPosition"
	"Автоматический" = "Automatic"; "Управляемый" = "Managed"
	"Использовать" = "Use"; "НеИспользовать" = "DontUse"
	"Разрешить" = "Allow"; "Запретить" = "Deny"
	"ВДиалоге" = "InDialog"; "ВСписке" = "InList"; "ОбаСпособа" = "BothWays"
	"ВВидеНаименования" = "AsDescription"; "ВВидеКода" = "AsCode"
	"НеПроверять" = "DontCheck"; "Ошибка" = "ShowError"; "Предупреждение" = "ShowWarning"
	"НеИндексировать" = "DontIndex"; "Индексировать" = "Index"
	"ИндексироватьСДопУпорядочиванием" = "IndexWithAdditionalOrder"
}

$script:validEnumValues = @{
	"RegisterType"                   = @("Balance","Turnovers")
	"WriteMode"                      = @("Independent","RecorderSubordinate")
	"InformationRegisterPeriodicity" = @("Nonperiodical","Second","Day","Month","Quarter","Year","RecorderPosition")
	"DependenceOnCalculationTypes"   = @("DontUse","OnActionPeriod")
	"DataLockControlMode"            = @("Automatic","Managed")
	"FullTextSearch"                 = @("Use","DontUse")
	"DataHistory"                    = @("Use","DontUse")
	"DefaultPresentation"            = @("AsDescription","AsCode")
	"Posting"                        = @("Allow","Deny")
	"RealTimePosting"                = @("Allow","Deny")
	"EditType"                       = @("InDialog","InList","BothWays")
	"HierarchyType"                  = @("HierarchyFoldersAndItems","HierarchyOfItems")
	"CodeType"                       = @("String","Number")
	"CodeAllowedLength"              = @("Variable","Fixed")
	"NumberType"                     = @("String","Number")
	"NumberAllowedLength"            = @("Variable","Fixed")
	"RegisterRecordsDeletion"        = @("AutoDelete","AutoDeleteOnUnpost","AutoDeleteOff")
	"RegisterRecordsWritingOnPost"   = @("WriteModified","WriteSelected","WriteAll")
	"ReturnValuesReuse"              = @("DontUse","DuringRequest","DuringSession")
	"ReuseSessions"                  = @("DontUse","AutoUse")
	"FillChecking"                   = @("DontCheck","ShowError","ShowWarning")
	"Indexing"                       = @("DontIndex","Index","IndexWithAdditionalOrder")
}

function Normalize-EnumValue {
	param([string]$propName, [string]$value)
	# 1. Check alias dictionary — silent auto-correct
	if ($script:enumValueAliases.ContainsKey($value)) {
		return $script:enumValueAliases[$value]
	}
	# 2. Case-insensitive match against valid values — silent
	$valid = $script:validEnumValues[$propName]
	if ($valid) {
		foreach ($v in $valid) {
			if ($v -ieq $value) { return $v }
		}
		# 3. Known property, unknown value — error with hint
		Write-Error "Invalid value '$value' for property '$propName'. Valid values: $($valid -join ', ')"
		exit 1
	}
	# 4. Unknown property — pass-through (no validation data)
	return $value
}

# --- Load JSON definition (DefinitionFile mode) ---
$def = $null
if ($DefinitionFile) {
	if (-not (Test-Path $DefinitionFile)) {
		Write-Error "Definition file not found: $DefinitionFile"
		exit 1
	}
	$jsonText = Get-Content -Raw -Encoding UTF8 $DefinitionFile
	$def = $jsonText | ConvertFrom-Json
}

# --- Resolve object path ---
if (Test-Path $ObjectPath -PathType Container) {
	$dirName = Split-Path $ObjectPath -Leaf
	$candidate = Join-Path $ObjectPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $ObjectPath) "$dirName.xml"
	if (Test-Path $candidate) {
		$ObjectPath = $candidate
	} elseif (Test-Path $sibling) {
		$ObjectPath = $sibling
	} else {
		Write-Error "Directory given but no $dirName.xml found inside or as sibling"
		exit 1
	}
}
# File not found — check Dir/Name/Name.xml → Dir/Name.xml
if (-not (Test-Path $ObjectPath)) {
	$fileName = [System.IO.Path]::GetFileNameWithoutExtension($ObjectPath)
	$parentDir = Split-Path $ObjectPath
	$parentDirName = Split-Path $parentDir -Leaf
	if ($fileName -eq $parentDirName) {
		$candidate = Join-Path (Split-Path $parentDir) "$fileName.xml"
		if (Test-Path $candidate) { $ObjectPath = $candidate }
	}
}
if (-not (Test-Path $ObjectPath)) {
	Write-Error "Object file not found: $ObjectPath"
	exit 1
}
$resolvedPath = (Resolve-Path $ObjectPath).Path

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

Assert-EditAllowed $resolvedPath 'editable'

# --- Load XML ---
$script:xmlDoc = New-Object System.Xml.XmlDocument
$script:xmlDoc.PreserveWhitespace = $true
$script:xmlDoc.Load($resolvedPath)

# --- Counters ---
$script:addCount = 0
$script:removeCount = 0
$script:modifyCount = 0
$script:warnCount = 0

function Warn($msg) {
	Write-Host "[WARN] $msg" -ForegroundColor Yellow
	$script:warnCount++
}

function Info($msg) {
	Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

# ============================================================
# Section 2: Detect object type
# ============================================================

$root = $script:xmlDoc.DocumentElement
if ($root.LocalName -ne "MetaDataObject") {
	Write-Error "Root element must be MetaDataObject, got: $($root.LocalName)"
	exit 1
}

# Find the first child element — this is the object type element
$script:objElement = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element') {
		$script:objElement = $child
		break
	}
}
if (-not $script:objElement) {
	Write-Error "No object element found under MetaDataObject"
	exit 1
}

$script:objType = $script:objElement.LocalName
$script:mdNs = $script:objElement.NamespaceURI

# Find Properties and ChildObjects
$script:propertiesEl = $null
$script:childObjectsEl = $null
foreach ($child in $script:objElement.ChildNodes) {
	if ($child.NodeType -ne 'Element') { continue }
	if ($child.LocalName -eq "Properties") { $script:propertiesEl = $child }
	if ($child.LocalName -eq "ChildObjects") { $script:childObjectsEl = $child }
}

if (-not $script:propertiesEl) {
	Write-Error "No <Properties> found in $($script:objType)"
	exit 1
}

# Extract object name
$script:objName = ""
foreach ($child in $script:propertiesEl.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Name") {
		$script:objName = $child.InnerText.Trim()
		break
	}
}

Info "Object: $($script:objType).$($script:objName)"

# ============================================================
# Section 3: Synonym tables
# ============================================================

# Operation synonyms
$script:operationSynonyms = @{
	"add" = "add"; "добавить" = "add"
	"remove" = "remove"; "удалить" = "remove"
	"modify" = "modify"; "изменить" = "modify"
}

# Child type synonyms
$script:childTypeSynonyms = @{
	"attributes" = "attributes"; "реквизиты" = "attributes"; "attrs" = "attributes"
	"tabularsections" = "tabularSections"; "табличныечасти" = "tabularSections"; "тч" = "tabularSections"; "ts" = "tabularSections"
	"dimensions" = "dimensions"; "измерения" = "dimensions"; "dims" = "dimensions"
	"resources" = "resources"; "ресурсы" = "resources"; "res" = "resources"
	"enumvalues" = "enumValues"; "значения" = "enumValues"; "values" = "enumValues"
	"columns" = "columns"; "графы" = "columns"; "колонки" = "columns"
	"forms" = "forms"; "формы" = "forms"
	"templates" = "templates"; "макеты" = "templates"
	"commands" = "commands"; "команды" = "commands"
	"properties" = "properties"; "свойства" = "properties"
}

# Type synonyms (from meta-compile)
$script:typeSynonyms = New-Object System.Collections.Hashtable
$script:typeSynonyms["число"]    = "Number"
$script:typeSynonyms["строка"]   = "String"
$script:typeSynonyms["булево"]   = "Boolean"
$script:typeSynonyms["дата"]     = "Date"
$script:typeSynonyms["датавремя"]= "DateTime"
$script:typeSynonyms["хранилищезначения"] = "ValueStorage"
$script:typeSynonyms["number"]   = "Number"
$script:typeSynonyms["string"]   = "String"
$script:typeSynonyms["boolean"]  = "Boolean"
$script:typeSynonyms["date"]     = "Date"
$script:typeSynonyms["datetime"] = "DateTime"
$script:typeSynonyms["valuestorage"] = "ValueStorage"
$script:typeSynonyms["bool"]     = "Boolean"
# Reference synonyms
$script:typeSynonyms["справочникссылка"]             = "CatalogRef"
$script:typeSynonyms["документссылка"]               = "DocumentRef"
$script:typeSynonyms["перечислениессылка"]            = "EnumRef"
$script:typeSynonyms["плансчетовссылка"]              = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"]  = "ChartOfCharacteristicTypesRef"
$script:typeSynonyms["планвидоврасчётассылка"]         = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планвидоврасчетассылка"]         = "ChartOfCalculationTypesRef"
$script:typeSynonyms["планобменассылка"]               = "ExchangePlanRef"
$script:typeSynonyms["бизнеспроцессссылка"]            = "BusinessProcessRef"
$script:typeSynonyms["задачассылка"]                   = "TaskRef"
$script:typeSynonyms["определяемыйтип"]              = "DefinedType"
$script:typeSynonyms["definedtype"]                   = "DefinedType"
$script:typeSynonyms["catalogref"]                    = "CatalogRef"
$script:typeSynonyms["documentref"]                   = "DocumentRef"
$script:typeSynonyms["enumref"]                       = "EnumRef"

# ============================================================
# Section 4: Type system
# ============================================================

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Split-CamelCase {
	param([string]$name)
	if (-not $name) { return $name }
	$result = [regex]::Replace($name, '([а-яё])([А-ЯЁ])', '$1 $2')
	$result = [regex]::Replace($result, '([a-z])([A-Z])', '$1 $2')
	if ($result.Length -gt 1) {
		$result = $result.Substring(0,1) + $result.Substring(1).ToLower()
	}
	return $result
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Parameterized: Number(15,2), Строка(100)
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	# Reference: СправочникСсылка.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Simple
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

function Build-TypeContentXml {
	param([string]$indent, [string]$typeStr)
	if (-not $typeStr) { return "" }

	# Composite type: "Type1 + Type2 + Type3"
	if ($typeStr.Contains(' + ')) {
		$parts = $typeStr -split '\s*\+\s*'
		$sb = New-Object System.Text.StringBuilder
		foreach ($part in $parts) {
			$inner = Build-TypeContentXml $indent $part.Trim()
			if ($inner) { $sb.AppendLine($inner) | Out-Null }
		}
		return $sb.ToString().TrimEnd("`r","`n")
	}

	$typeStr = Resolve-TypeStr $typeStr
	$sb = New-Object System.Text.StringBuilder

	# Boolean
	if ($typeStr -eq "Boolean") {
		$sb.AppendLine("$indent<v8:Type>xs:boolean</v8:Type>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# ValueStorage
	if ($typeStr -eq "ValueStorage") {
		$sb.AppendLine("$indent<v8:Type>xs:base64Binary</v8:Type>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# String or String(N)
	if ($typeStr -match '^String(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "10" }
		$sb.AppendLine("$indent<v8:Type>xs:string</v8:Type>") | Out-Null
		$sb.AppendLine("$indent<v8:StringQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t<v8:Length>$len</v8:Length>") | Out-Null
		$sb.AppendLine("$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>") | Out-Null
		$sb.AppendLine("$indent</v8:StringQualifiers>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# Number(D,F) or Number(D,F,nonneg)
	if ($typeStr -match '^Number\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]; $fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		$sb.AppendLine("$indent<v8:Type>xs:decimal</v8:Type>") | Out-Null
		$sb.AppendLine("$indent<v8:NumberQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t<v8:Digits>$digits</v8:Digits>") | Out-Null
		$sb.AppendLine("$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>") | Out-Null
		$sb.AppendLine("$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>") | Out-Null
		$sb.AppendLine("$indent</v8:NumberQualifiers>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# Number without params → Number(10,0)
	if ($typeStr -eq "Number") {
		$sb.AppendLine("$indent<v8:Type>xs:decimal</v8:Type>") | Out-Null
		$sb.AppendLine("$indent<v8:NumberQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t<v8:Digits>10</v8:Digits>") | Out-Null
		$sb.AppendLine("$indent`t<v8:FractionDigits>0</v8:FractionDigits>") | Out-Null
		$sb.AppendLine("$indent`t<v8:AllowedSign>Any</v8:AllowedSign>") | Out-Null
		$sb.AppendLine("$indent</v8:NumberQualifiers>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# Date / DateTime
	if ($typeStr -eq "Date") {
		$sb.AppendLine("$indent<v8:Type>xs:dateTime</v8:Type>") | Out-Null
		$sb.AppendLine("$indent<v8:DateQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t<v8:DateFractions>Date</v8:DateFractions>") | Out-Null
		$sb.AppendLine("$indent</v8:DateQualifiers>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}
	if ($typeStr -eq "DateTime") {
		$sb.AppendLine("$indent<v8:Type>xs:dateTime</v8:Type>") | Out-Null
		$sb.AppendLine("$indent<v8:DateQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t<v8:DateFractions>DateTime</v8:DateFractions>") | Out-Null
		$sb.AppendLine("$indent</v8:DateQualifiers>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# DefinedType
	if ($typeStr -match '^DefinedType\.(.+)$') {
		$dtName = $Matches[1]
		$sb.AppendLine("$indent<v8:TypeSet>cfg:DefinedType.$dtName</v8:TypeSet>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# Reference types — use local xmlns declaration for 1C compatibility
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef)\.(.+)$') {
		$sb.AppendLine("$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$typeStr</v8:Type>") | Out-Null
		return $sb.ToString().TrimEnd("`r","`n")
	}

	# Fallback
	$sb.AppendLine("$indent<v8:Type>$typeStr</v8:Type>") | Out-Null
	return $sb.ToString().TrimEnd("`r","`n")
}

function Build-ValueTypeXml {
	param([string]$indent, [string]$typeStr)
	$inner = Build-TypeContentXml "$indent`t" $typeStr
	return "$indent<Type>`r`n$inner`r`n$indent</Type>"
}

function Build-FillValueXml {
	param([string]$indent, [string]$typeStr)
	if (-not $typeStr) {
		return "$indent<FillValue xsi:nil=`"true`"/>"
	}
	$typeStr = Resolve-TypeStr $typeStr
	if ($typeStr -eq "Boolean") {
		return "$indent<FillValue xsi:type=`"xs:boolean`">false</FillValue>"
	}
	if ($typeStr -match '^String') {
		return "$indent<FillValue xsi:type=`"xs:string`"/>"
	}
	if ($typeStr -match '^Number') {
		return "$indent<FillValue xsi:type=`"xs:decimal`">0</FillValue>"
	}
	return "$indent<FillValue xsi:nil=`"true`"/>"
}

function Build-MLTextXml {
	param([string]$indent, [string]$tag, [string]$text)
	if (-not $text) {
		return "$indent<$tag/>"
	}
	$lines = @(
		"$indent<$tag>"
		"$indent`t<v8:item>"
		"$indent`t`t<v8:lang>ru</v8:lang>"
		"$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
		"$indent`t</v8:item>"
		"$indent</$tag>"
	)
	return $lines -join "`r`n"
}

# ============================================================
# Section 5: DOM helpers
# ============================================================

$script:metaNs = "http://v8.1c.ru/8.3/MDClasses"
$script:xrNs = "http://v8.1c.ru/8.3/xcf/readable"
$script:v8Ns = "http://v8.1c.ru/8.1/data/core"

function Import-Fragment([string]$xmlString) {
	$wrapper = @"
<_W xmlns="http://v8.1c.ru/8.3/MDClasses"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"
    xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"
    xmlns:app="http://v8.1c.ru/8.2/managed-application/core"
    xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"
    xmlns:xs="http://www.w3.org/2001/XMLSchema">$xmlString</_W>
"@
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$nodes = @()
	foreach ($child in $frag.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $script:xmlDoc.ImportNode($child, $true)
		}
	}
	return ,$nodes
}

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	# Fallback: count depth
	$depth = 0
	$current = $container
	while ($current -and $current -ne $script:xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	$ws = $script:xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $ws) | Out-Null
	} else {
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$container.InsertBefore($ws, $trailing) | Out-Null
			$container.InsertBefore($newNode, $trailing) | Out-Null
		} else {
			$container.AppendChild($ws) | Out-Null
			$container.AppendChild($newNode) | Out-Null
			$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
			$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Remove-NodeWithWhitespace($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	$next = $node.NextSibling

	if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($prev) | Out-Null
	} elseif ($next -and ($next.NodeType -eq 'Whitespace' -or $next.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($next) | Out-Null
	}
	$parent.RemoveChild($node) | Out-Null
}

function Find-ElementByName($container, [string]$elemLocalName, [string]$nameValue) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -ne $elemLocalName) { continue }
		# Look for Properties/Name or just Name child
		$propsEl = $null
		foreach ($gc in $child.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Properties") {
				$propsEl = $gc; break
			}
		}
		$searchIn = if ($propsEl) { $propsEl } else { $child }
		foreach ($gc in $searchIn.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Name" -and $gc.InnerText.Trim() -eq $nameValue) {
				return $child
			}
		}
	}
	return $null
}

function Find-LastElementOfType($container, [string]$localName) {
	$last = $null
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $localName) {
			$last = $child
		}
	}
	return $last
}

function Find-FirstElementOfType($container, [string]$localName) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $localName) {
			return $child
		}
	}
	return $null
}

function Ensure-ChildObjectsOpen {
	if ($script:childObjectsEl) {
		# Check if it's self-closing (no child elements)
		$hasElements = $false
		foreach ($ch in $script:childObjectsEl.ChildNodes) {
			if ($ch.NodeType -eq 'Element') { $hasElements = $true; break }
		}
		if (-not $hasElements) {
			# It's empty — we need to add whitespace for proper formatting
			$indent = Get-ChildIndent $script:objElement
			$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$indent")
			$script:childObjectsEl.AppendChild($closeWs) | Out-Null
		}
		return
	}
	# No ChildObjects at all — create one after Properties
	$indent = Get-ChildIndent $script:objElement
	$coXml = "`r`n$indent<ChildObjects>`r`n$indent</ChildObjects>"
	# Insert after Properties
	$refNode = $null
	$foundProps = $false
	foreach ($child in $script:objElement.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Properties") {
			$foundProps = $true
			continue
		}
		if ($foundProps -and $child.NodeType -eq 'Element') {
			$refNode = $child
			break
		}
	}

	$coEl = $script:xmlDoc.CreateElement("ChildObjects", $script:mdNs)
	$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$indent")
	$coEl.AppendChild($closeWs) | Out-Null

	$wsB = $script:xmlDoc.CreateWhitespace("`r`n$indent")
	if ($refNode) {
		$script:objElement.InsertBefore($wsB, $refNode) | Out-Null
		$script:objElement.InsertBefore($coEl, $wsB) | Out-Null
	} else {
		# After last child
		$trailing = $script:objElement.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$script:objElement.InsertBefore($wsB, $trailing) | Out-Null
			$script:objElement.InsertBefore($coEl, $trailing) | Out-Null
		} else {
			$script:objElement.AppendChild($wsB) | Out-Null
			$script:objElement.AppendChild($coEl) | Out-Null
		}
	}
	$script:childObjectsEl = $coEl
}

function Collapse-ChildObjectsIfEmpty {
	if (-not $script:childObjectsEl) { return }
	$hasElements = $false
	foreach ($ch in $script:childObjectsEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element') { $hasElements = $true; break }
	}
	if (-not $hasElements) {
		# Remove all whitespace children
		while ($script:childObjectsEl.HasChildNodes) {
			$script:childObjectsEl.RemoveChild($script:childObjectsEl.FirstChild) | Out-Null
		}
	}
}

# ============================================================
# Section 6: Fragment builders
# ============================================================

function Parse-AttributeShorthand {
	param($val)

	if ($val -is [string]) {
		$str = "$val"
		$parsed = @{
			name = ""; type = ""; synonym = ""; comment = ""
			flags = @(); fillChecking = ""; indexing = ""
			after = ""; before = ""
		}
		# Extract positional markers: >> after Name, << before Name
		if ($str -match '\s*>>\s*after\s+(\S+)\s*$') {
			$parsed.after = $Matches[1]
			$str = ($str -replace '\s*>>\s*after\s+\S+\s*$', '').Trim()
		} elseif ($str -match '\s*<<\s*before\s+(\S+)\s*$') {
			$parsed.before = $Matches[1]
			$str = ($str -replace '\s*<<\s*before\s+\S+\s*$', '').Trim()
		}
		# Split by | for flags
		$parts = $str -split '\|', 2
		$mainPart = $parts[0].Trim()
		if ($parts.Count -gt 1) {
			$flagStr = $parts[1].Trim()
			$parsed.flags = @($flagStr -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
		}
		# Split by : for name and type
		$colonParts = $mainPart -split ':', 2
		$parsed.name = $colonParts[0].Trim()
		if ($colonParts.Count -gt 1) {
			$parsed.type = $colonParts[1].Trim()
		}
		$parsed.synonym = Split-CamelCase $parsed.name
		return $parsed
	}

	# Object form
	$name = "$($val.name)"
	$result = @{
		name        = $name
		type        = if ($val.type -is [array]) { ($val.type | ForEach-Object { "$_" }) -join ' + ' } elseif ($val.type) { "$($val.type)" } else { "" }
		synonym     = if ($val.synonym) { "$($val.synonym)" } else { Split-CamelCase $name }
		comment     = if ($val.comment) { "$($val.comment)" } else { "" }
		flags       = @(if ($val.flags) { $val.flags } else { @() })
		fillChecking = if ($val.fillChecking) { "$($val.fillChecking)" } else { "" }
		indexing    = if ($val.indexing) { "$($val.indexing)" } else { "" }
		after       = if ($val.after) { "$($val.after)" } else { "" }
		before      = if ($val.before) { "$($val.before)" } else { "" }
	}
	# Map flags to properties
	if ($result.flags -contains "req" -and -not $result.fillChecking) {
		$result.fillChecking = "ShowError"
	}
	if ($result.flags -contains "index" -and -not $result.indexing) {
		$result.indexing = "Index"
	}
	if ($result.flags -contains "indexadditional" -and -not $result.indexing) {
		$result.indexing = "IndexWithAdditionalOrder"
	}
	return $result
}

function Parse-EnumValueShorthand {
	param($val)
	if ($val -is [string]) {
		$name = "$val"
		return @{
			name    = $name
			synonym = Split-CamelCase $name
			comment = ""
			after   = ""; before = ""
		}
	}
	$name = "$($val.name)"
	return @{
		name    = $name
		synonym = if ($val.synonym) { "$($val.synonym)" } else { Split-CamelCase $name }
		comment = if ($val.comment) { "$($val.comment)" } else { "" }
		after   = if ($val.after) { "$($val.after)" } else { "" }
		before  = if ($val.before) { "$($val.before)" } else { "" }
	}
}

# Determine attribute context from object type
function Get-AttributeContext {
	switch ($script:objType) {
		"Catalog" { return "catalog" }
		"Document" { return "document" }
		{ $_ -in @("InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister") } { return "register" }
		{ $_ -in @("DataProcessor","Report","ExternalDataProcessor","ExternalReport") } { return "processor" }
		default { return "object" }
	}
}

$script:reservedAttrNames = @{
	"Ref"="Ссылка"; "DeletionMark"="ПометкаУдаления"; "Code"="Код"; "Description"="Наименование"
	"Date"="Дата"; "Number"="Номер"; "Posted"="Проведен"; "Parent"="Родитель"; "Owner"="Владелец"
	"IsFolder"="ЭтоГруппа"; "Predefined"="Предопределенный"; "PredefinedDataName"="ИмяПредопределенныхДанных"
	"Recorder"="Регистратор"; "Period"="Период"; "LineNumber"="НомерСтроки"; "Active"="Активность"
	"Order"="Порядок"; "Type"="Тип"; "OffBalance"="Забалансовый"
	"Started"="Стартован"; "Completed"="Завершен"; "HeadTask"="ВедущаяЗадача"
	"Executed"="Выполнена"; "RoutePoint"="ТочкаМаршрута"; "BusinessProcess"="БизнесПроцесс"
	"ThisNode"="ЭтотУзел"; "SentNo"="НомерОтправленного"; "ReceivedNo"="НомерПринятого"
	"CalculationType"="ВидРасчета"; "RegistrationPeriod"="ПериодРегистрации"; "ReversingEntry"="СторноЗапись"
	"Account"="Счет"; "ValueType"="ТипЗначения"; "ActionPeriodIsBasic"="ПериодДействияБазовый"
}

# Стандартные реквизиты по типу объекта (ключи из reservedAttrNames). Имя реквизита, совпадающее
# с ними (англ. ИЛИ рус.), платформа не позволит — жёсткий отказ. Контексты вне карты → предупреждение.
$script:reservedByContext = @{
	"catalog"  = @("Ref","DeletionMark","Predefined","PredefinedDataName","Code","Description","Owner","Parent","IsFolder")
	"document" = @("Ref","DeletionMark","Date","Number","Posted")
}

function Build-AttributeFragment {
	param($parsed, [string]$context, [string]$indent)

	if (-not $context) { $context = Get-AttributeContext }

	# Check reserved attribute names (типозависимо: catalog/document — жёсткий отказ; прочее — предупреждение)
	$attrName = $parsed.name
	$ctxReserved = $script:reservedByContext[$context]
	if ($ctxReserved) {
		foreach ($en in $ctxReserved) {
			$ru = $script:reservedAttrNames[$en]
			if (($attrName -ieq $en) -or ($ru -and $attrName -ieq $ru)) {
				Write-Error "Имя реквизита '$attrName' зарезервировано стандартным реквизитом ($en/$ru) объекта '$context'. Выберите другое имя."
				exit 1
			}
		}
	} elseif ($context -notin @("tabular", "processor-tabular") -and
		($script:reservedAttrNames.ContainsKey($attrName) -or ($script:reservedAttrNames.Values -contains $attrName))) {
		Write-Warning "Attribute '$attrName' conflicts with a standard attribute name. This may cause errors when loading into 1C."
	}

	$uuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder

	$sb.AppendLine("$indent<Attribute uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $parsed.synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null

	# Type
	$typeStr = $parsed.type
	if ($typeStr) {
		$sb.AppendLine($(Build-ValueTypeXml "$indent`t`t" $typeStr)) | Out-Null
	} else {
		$sb.AppendLine("$indent`t`t<Type>") | Out-Null
		$sb.AppendLine("$indent`t`t`t<v8:Type>xs:string</v8:Type>") | Out-Null
		$sb.AppendLine("$indent`t`t</Type>") | Out-Null
	}

	$sb.AppendLine("$indent`t`t<PasswordMode>false</PasswordMode>") | Out-Null
	$sb.AppendLine("$indent`t`t<Format/>") | Out-Null
	$sb.AppendLine("$indent`t`t<EditFormat/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ToolTip/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MarkNegatives>false</MarkNegatives>") | Out-Null
	$sb.AppendLine("$indent`t`t<Mask/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MultiLine>false</MultiLine>") | Out-Null
	$sb.AppendLine("$indent`t`t<ExtendedEdit>false</ExtendedEdit>") | Out-Null
	$sb.AppendLine("$indent`t`t<MinValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MaxValue xsi:nil=`"true`"/>") | Out-Null

	# FillFromFillingValue/FillValue — not for register, tabular (config TS), or processor (non-stored top-level)
	if ($context -notin @("register", "tabular", "processor")) {
		$sb.AppendLine("$indent`t`t<FillFromFillingValue>false</FillFromFillingValue>") | Out-Null
		$sb.AppendLine($(Build-FillValueXml "$indent`t`t" $typeStr)) | Out-Null
	}

	# FillChecking
	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	if ($parsed.fillChecking) { $fillChecking = Normalize-EnumValue "FillChecking" $parsed.fillChecking }
	$sb.AppendLine("$indent`t`t<FillChecking>$fillChecking</FillChecking>") | Out-Null

	$sb.AppendLine("$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameterLinks/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameters/>") | Out-Null
	$sb.AppendLine("$indent`t`t<QuickChoice>Auto</QuickChoice>") | Out-Null
	$sb.AppendLine("$indent`t`t<CreateOnInput>Auto</CreateOnInput>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceForm/>") | Out-Null
	$sb.AppendLine("$indent`t`t<LinkByType/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>") | Out-Null

	# Use — catalog only
	if ($context -eq "catalog") {
		$sb.AppendLine("$indent`t`t<Use>ForItem</Use>") | Out-Null
	}

	# Indexing/FullTextSearch/DataHistory — not for non-stored objects (processor, processor-tabular)
	if ($context -notin @("processor", "processor-tabular")) {
		$indexing = "DontIndex"
		if ($parsed.flags -contains "index") { $indexing = "Index" }
		if ($parsed.flags -contains "indexadditional") { $indexing = "IndexWithAdditionalOrder" }
		if ($parsed.indexing) { $indexing = Normalize-EnumValue "Indexing" $parsed.indexing }
		$sb.AppendLine("$indent`t`t<Indexing>$indexing</Indexing>") | Out-Null

		$sb.AppendLine("$indent`t`t<FullTextSearch>Use</FullTextSearch>") | Out-Null
		$sb.AppendLine("$indent`t`t<DataHistory>Use</DataHistory>") | Out-Null
	}

	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</Attribute>") | Out-Null
	return $sb.ToString()
}

function Build-TabularSectionFragment {
	param($tsDef, [string]$indent)

	$tsName = "$($tsDef.name)"
	$tsSynonym = if ($tsDef.synonym) { "$($tsDef.synonym)" } else { Split-CamelCase $tsName }
	$uuid = New-Guid-String
	$objType = $script:objType
	$objName = $script:objName

	$typePrefix = "${objType}TabularSection"
	$rowPrefix = "${objType}TabularSectionRow"

	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("$indent<TabularSection uuid=`"$uuid`">") | Out-Null

	# InternalInfo
	$sb.AppendLine("$indent`t<InternalInfo>") | Out-Null
	$sb.AppendLine("$indent`t`t<xr:GeneratedType name=`"$typePrefix.$objName.$tsName`" category=`"TabularSection`">") | Out-Null
	$sb.AppendLine("$indent`t`t`t<xr:TypeId>$(New-Guid-String)</xr:TypeId>") | Out-Null
	$sb.AppendLine("$indent`t`t`t<xr:ValueId>$(New-Guid-String)</xr:ValueId>") | Out-Null
	$sb.AppendLine("$indent`t`t</xr:GeneratedType>") | Out-Null
	$sb.AppendLine("$indent`t`t<xr:GeneratedType name=`"$rowPrefix.$objName.$tsName`" category=`"TabularSectionRow`">") | Out-Null
	$sb.AppendLine("$indent`t`t`t<xr:TypeId>$(New-Guid-String)</xr:TypeId>") | Out-Null
	$sb.AppendLine("$indent`t`t`t<xr:ValueId>$(New-Guid-String)</xr:ValueId>") | Out-Null
	$sb.AppendLine("$indent`t`t</xr:GeneratedType>") | Out-Null
	$sb.AppendLine("$indent`t</InternalInfo>") | Out-Null

	# Properties
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $tsName)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $tsSynonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ToolTip/>") | Out-Null
	$sb.AppendLine("$indent`t`t<FillChecking>DontCheck</FillChecking>") | Out-Null

	# StandardAttributes (LineNumber)
	$sb.AppendLine("$indent`t`t<StandardAttributes>") | Out-Null
	$sb.AppendLine("$indent`t`t`t<xr:StandardAttribute name=`"LineNumber`">") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:LinkByType/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:FillChecking>DontCheck</xr:FillChecking>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:MultiLine>false</xr:MultiLine>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:FillFromFillingValue>false</xr:FillFromFillingValue>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:CreateOnInput>Auto</xr:CreateOnInput>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:MaxValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ToolTip/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ExtendedEdit>false</xr:ExtendedEdit>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:Format/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ChoiceForm/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:QuickChoice>Auto</xr:QuickChoice>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:EditFormat/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:PasswordMode>false</xr:PasswordMode>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:DataHistory>Use</xr:DataHistory>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:MarkNegatives>false</xr:MarkNegatives>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:MinValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:Synonym/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:Comment/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:FullTextSearch>Use</xr:FullTextSearch>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ChoiceParameterLinks/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:FillValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:Mask/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t`t<xr:ChoiceParameters/>") | Out-Null
	$sb.AppendLine("$indent`t`t`t</xr:StandardAttribute>") | Out-Null
	$sb.AppendLine("$indent`t`t</StandardAttributes>") | Out-Null

	# Use — catalog only
	if ($objType -eq "Catalog") {
		$sb.AppendLine("$indent`t`t<Use>ForItem</Use>") | Out-Null
	}

	$sb.AppendLine("$indent`t</Properties>") | Out-Null

	# ChildObjects with attrs
	$columns = @()
	if ($tsDef.attrs) { $columns = @($tsDef.attrs) }
	elseif ($tsDef.attributes) { $columns = @($tsDef.attributes) }
	elseif ($tsDef.реквизиты) { $columns = @($tsDef.реквизиты) }

	$tsAttrContext = if ($script:objType -in @("DataProcessor","Report","ExternalDataProcessor","ExternalReport")) { "processor-tabular" } else { "tabular" }
	if ($columns.Count -gt 0) {
		$sb.AppendLine("$indent`t<ChildObjects>") | Out-Null
		foreach ($col in $columns) {
			$colParsed = Parse-AttributeShorthand $col
			$sb.AppendLine($(Build-AttributeFragment $colParsed $tsAttrContext "$indent`t`t")) | Out-Null
		}
		$sb.AppendLine("$indent`t</ChildObjects>") | Out-Null
	} else {
		$sb.AppendLine("$indent`t<ChildObjects/>") | Out-Null
	}

	$sb.Append("$indent</TabularSection>") | Out-Null
	return $sb.ToString()
}

function Build-DimensionFragment {
	param($parsed, [string]$registerType, [string]$indent)

	if (-not $registerType) { $registerType = $script:objType }
	$uuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder

	$sb.AppendLine("$indent<Dimension uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $parsed.synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null

	$typeStr = $parsed.type
	if ($typeStr) {
		$sb.AppendLine($(Build-ValueTypeXml "$indent`t`t" $typeStr)) | Out-Null
	} else {
		$sb.AppendLine("$indent`t`t<Type>") | Out-Null
		$sb.AppendLine("$indent`t`t`t<v8:Type>xs:string</v8:Type>") | Out-Null
		$sb.AppendLine("$indent`t`t</Type>") | Out-Null
	}

	$sb.AppendLine("$indent`t`t<PasswordMode>false</PasswordMode>") | Out-Null
	$sb.AppendLine("$indent`t`t<Format/>") | Out-Null
	$sb.AppendLine("$indent`t`t<EditFormat/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ToolTip/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MarkNegatives>false</MarkNegatives>") | Out-Null
	$sb.AppendLine("$indent`t`t<Mask/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MultiLine>false</MultiLine>") | Out-Null
	$sb.AppendLine("$indent`t`t<ExtendedEdit>false</ExtendedEdit>") | Out-Null
	$sb.AppendLine("$indent`t`t<MinValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MaxValue xsi:nil=`"true`"/>") | Out-Null

	# InformationRegister: FillFromFillingValue, FillValue
	if ($registerType -eq "InformationRegister") {
		$fillFrom = if ($parsed.flags -contains "master") { "true" } else { "false" }
		$sb.AppendLine("$indent`t`t<FillFromFillingValue>$fillFrom</FillFromFillingValue>") | Out-Null
		$sb.AppendLine("$indent`t`t<FillValue xsi:nil=`"true`"/>") | Out-Null
	}

	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	$sb.AppendLine("$indent`t`t<FillChecking>$fillChecking</FillChecking>") | Out-Null

	$sb.AppendLine("$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameterLinks/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameters/>") | Out-Null
	$sb.AppendLine("$indent`t`t<QuickChoice>Auto</QuickChoice>") | Out-Null
	$sb.AppendLine("$indent`t`t<CreateOnInput>Auto</CreateOnInput>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceForm/>") | Out-Null
	$sb.AppendLine("$indent`t`t<LinkByType/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>") | Out-Null

	# InformationRegister: Master, MainFilter, DenyIncompleteValues
	if ($registerType -eq "InformationRegister") {
		$master = if ($parsed.flags -contains "master") { "true" } else { "false" }
		$mainFilter = if ($parsed.flags -contains "mainfilter") { "true" } else { "false" }
		$denyIncomplete = if ($parsed.flags -contains "denyincomplete") { "true" } else { "false" }
		$sb.AppendLine("$indent`t`t<Master>$master</Master>") | Out-Null
		$sb.AppendLine("$indent`t`t<MainFilter>$mainFilter</MainFilter>") | Out-Null
		$sb.AppendLine("$indent`t`t<DenyIncompleteValues>$denyIncomplete</DenyIncompleteValues>") | Out-Null
	}

	# AccumulationRegister: DenyIncompleteValues
	if ($registerType -eq "AccumulationRegister") {
		$denyIncomplete = if ($parsed.flags -contains "denyincomplete") { "true" } else { "false" }
		$sb.AppendLine("$indent`t`t<DenyIncompleteValues>$denyIncomplete</DenyIncompleteValues>") | Out-Null
	}

	$indexing = "DontIndex"
	if ($parsed.flags -contains "index") { $indexing = "Index" }
	$sb.AppendLine("$indent`t`t<Indexing>$indexing</Indexing>") | Out-Null

	$sb.AppendLine("$indent`t`t<FullTextSearch>Use</FullTextSearch>") | Out-Null

	# AccumulationRegister: UseInTotals
	if ($registerType -eq "AccumulationRegister") {
		$useInTotals = if ($parsed.flags -contains "nouseintotals") { "false" } else { "true" }
		$sb.AppendLine("$indent`t`t<UseInTotals>$useInTotals</UseInTotals>") | Out-Null
	}

	# InformationRegister: DataHistory
	if ($registerType -eq "InformationRegister") {
		$sb.AppendLine("$indent`t`t<DataHistory>Use</DataHistory>") | Out-Null
	}

	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</Dimension>") | Out-Null
	return $sb.ToString()
}

function Build-ResourceFragment {
	param($parsed, [string]$registerType, [string]$indent)

	if (-not $registerType) { $registerType = $script:objType }
	$uuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder

	$sb.AppendLine("$indent<Resource uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $parsed.synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null

	$typeStr = $parsed.type
	if ($typeStr) {
		$sb.AppendLine($(Build-ValueTypeXml "$indent`t`t" $typeStr)) | Out-Null
	} else {
		# Default: Number(15,2)
		$sb.AppendLine("$indent`t`t<Type>") | Out-Null
		$sb.AppendLine("$indent`t`t`t<v8:Type>xs:decimal</v8:Type>") | Out-Null
		$sb.AppendLine("$indent`t`t`t<v8:NumberQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t`t`t`t<v8:Digits>15</v8:Digits>") | Out-Null
		$sb.AppendLine("$indent`t`t`t`t<v8:FractionDigits>2</v8:FractionDigits>") | Out-Null
		$sb.AppendLine("$indent`t`t`t`t<v8:AllowedSign>Any</v8:AllowedSign>") | Out-Null
		$sb.AppendLine("$indent`t`t`t</v8:NumberQualifiers>") | Out-Null
		$sb.AppendLine("$indent`t`t</Type>") | Out-Null
	}

	$sb.AppendLine("$indent`t`t<PasswordMode>false</PasswordMode>") | Out-Null
	$sb.AppendLine("$indent`t`t<Format/>") | Out-Null
	$sb.AppendLine("$indent`t`t<EditFormat/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ToolTip/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MarkNegatives>false</MarkNegatives>") | Out-Null
	$sb.AppendLine("$indent`t`t<Mask/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MultiLine>false</MultiLine>") | Out-Null
	$sb.AppendLine("$indent`t`t<ExtendedEdit>false</ExtendedEdit>") | Out-Null
	$sb.AppendLine("$indent`t`t<MinValue xsi:nil=`"true`"/>") | Out-Null
	$sb.AppendLine("$indent`t`t<MaxValue xsi:nil=`"true`"/>") | Out-Null

	# InformationRegister: FillFromFillingValue, FillValue
	if ($registerType -eq "InformationRegister") {
		$sb.AppendLine("$indent`t`t<FillFromFillingValue>false</FillFromFillingValue>") | Out-Null
		$sb.AppendLine("$indent`t`t<FillValue xsi:nil=`"true`"/>") | Out-Null
	}

	$fillChecking = "DontCheck"
	if ($parsed.flags -contains "req") { $fillChecking = "ShowError" }
	$sb.AppendLine("$indent`t`t<FillChecking>$fillChecking</FillChecking>") | Out-Null

	$sb.AppendLine("$indent`t`t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameterLinks/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceParameters/>") | Out-Null
	$sb.AppendLine("$indent`t`t<QuickChoice>Auto</QuickChoice>") | Out-Null
	$sb.AppendLine("$indent`t`t<CreateOnInput>Auto</CreateOnInput>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceForm/>") | Out-Null
	$sb.AppendLine("$indent`t`t<LinkByType/>") | Out-Null
	$sb.AppendLine("$indent`t`t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>") | Out-Null

	# InformationRegister: Indexing, FullTextSearch, DataHistory
	if ($registerType -eq "InformationRegister") {
		$sb.AppendLine("$indent`t`t<Indexing>DontIndex</Indexing>") | Out-Null
		$sb.AppendLine("$indent`t`t<FullTextSearch>Use</FullTextSearch>") | Out-Null
		$sb.AppendLine("$indent`t`t<DataHistory>Use</DataHistory>") | Out-Null
	}

	# AccumulationRegister: FullTextSearch
	if ($registerType -eq "AccumulationRegister") {
		$sb.AppendLine("$indent`t`t<FullTextSearch>Use</FullTextSearch>") | Out-Null
	}

	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</Resource>") | Out-Null
	return $sb.ToString()
}

function Build-EnumValueFragment {
	param($parsed, [string]$indent)

	$uuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("$indent<EnumValue uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $parsed.name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $parsed.synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null
	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</EnumValue>") | Out-Null
	return $sb.ToString()
}

function Build-ColumnFragment {
	param($colDef, [string]$indent)

	$uuid = New-Guid-String
	$name = ""
	$synonym = ""
	$indexing = "DontIndex"
	$references = @()

	if ($colDef -is [string]) {
		$name = "$colDef"
		$synonym = Split-CamelCase $name
	} else {
		$name = "$($colDef.name)"
		$synonym = if ($colDef.synonym) { "$($colDef.synonym)" } else { Split-CamelCase $name }
		if ($colDef.indexing) { $indexing = "$($colDef.indexing)" }
		if ($colDef.references) { $references = @($colDef.references) }
	}

	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("$indent<Column uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null
	$sb.AppendLine("$indent`t`t<Indexing>$indexing</Indexing>") | Out-Null
	if ($references.Count -gt 0) {
		$sb.AppendLine("$indent`t`t<References>") | Out-Null
		foreach ($ref in $references) {
			$sb.AppendLine("$indent`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">$ref</xr:Item>") | Out-Null
		}
		$sb.AppendLine("$indent`t`t</References>") | Out-Null
	} else {
		$sb.AppendLine("$indent`t`t<References/>") | Out-Null
	}
	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</Column>") | Out-Null
	return $sb.ToString()
}

function Build-SimpleChildFragment {
	param([string]$tagName, [string]$name, [string]$indent)
	# For Form, Template, Command — just a name wrapper
	$uuid = New-Guid-String
	$synonym = Split-CamelCase $name
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("$indent<$tagName uuid=`"$uuid`">") | Out-Null
	$sb.AppendLine("$indent`t<Properties>") | Out-Null
	$sb.AppendLine("$indent`t`t<Name>$(Esc-Xml $name)</Name>") | Out-Null
	$sb.AppendLine($(Build-MLTextXml "$indent`t`t" "Synonym" $synonym)) | Out-Null
	$sb.AppendLine("$indent`t`t<Comment/>") | Out-Null
	# Forms get additional properties
	if ($tagName -eq "Form") {
		$sb.AppendLine("$indent`t`t<FormType>Ordinary</FormType>") | Out-Null
		$sb.AppendLine("$indent`t`t<IncludeHelpInContents>false</IncludeHelpInContents>") | Out-Null
		$sb.AppendLine("$indent`t`t<UsePurposes/>") | Out-Null
	}
	if ($tagName -eq "Template") {
		$sb.AppendLine("$indent`t`t<TemplateType>SpreadsheetDocument</TemplateType>") | Out-Null
	}
	if ($tagName -eq "Command") {
		$sb.AppendLine("$indent`t`t<Group>FormNavigationPanelGoTo</Group>") | Out-Null
		$sb.AppendLine("$indent`t`t<Representation>Auto</Representation>") | Out-Null
		$sb.AppendLine("$indent`t`t<ToolTip/>") | Out-Null
		$sb.AppendLine("$indent`t`t<Picture/>") | Out-Null
		$sb.AppendLine("$indent`t`t<Shortcut/>") | Out-Null
	}
	$sb.AppendLine("$indent`t</Properties>") | Out-Null
	$sb.Append("$indent</$tagName>") | Out-Null
	return $sb.ToString()
}

# ============================================================
# Section 7: Name uniqueness check
# ============================================================

function Get-AllChildNames {
	$names = @{}
	if (-not $script:childObjectsEl) { return $names }
	foreach ($child in $script:childObjectsEl.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$propsEl = $null
		foreach ($gc in $child.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Properties") {
				$propsEl = $gc; break
			}
		}
		if (-not $propsEl) { continue }
		foreach ($gc in $propsEl.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Name") {
				$n = $gc.InnerText.Trim()
				if ($n) { $names[$n] = $child.LocalName }
				break
			}
		}
		# Also check ChildObjects of TabularSections for nested names
		if ($child.LocalName -eq "TabularSection") {
			foreach ($tsCh in $child.ChildNodes) {
				if ($tsCh.NodeType -eq 'Element' -and $tsCh.LocalName -eq "ChildObjects") {
					foreach ($tsChild in $tsCh.ChildNodes) {
						if ($tsChild.NodeType -ne 'Element') { continue }
						$tsProps = $null
						foreach ($gc in $tsChild.ChildNodes) {
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Properties") {
								$tsProps = $gc; break
							}
						}
						if ($tsProps) {
							foreach ($gc in $tsProps.ChildNodes) {
								if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Name") {
									# TS attr names don't conflict with top-level
									break
								}
							}
						}
					}
				}
			}
		}
	}
	return $names
}

# ============================================================
# Section 8: Context and allowed child types
# ============================================================

$script:validChildTypes = @{
	"Catalog"                    = @("attributes","tabularSections","forms","templates","commands")
	"Document"                   = @("attributes","tabularSections","forms","templates","commands")
	"ExchangePlan"               = @("attributes","tabularSections","forms","templates","commands")
	"ChartOfAccounts"            = @("attributes","tabularSections","forms","templates","commands")
	"ChartOfCharacteristicTypes" = @("attributes","tabularSections","forms","templates","commands")
	"ChartOfCalculationTypes"    = @("attributes","tabularSections","forms","templates","commands")
	"BusinessProcess"            = @("attributes","tabularSections","forms","templates","commands")
	"Task"                       = @("attributes","tabularSections","forms","templates","commands")
	"Report"                     = @("attributes","tabularSections","forms","templates","commands")
	"DataProcessor"              = @("attributes","tabularSections","forms","templates","commands")
	"Enum"                       = @("enumValues","forms","templates","commands")
	"InformationRegister"        = @("dimensions","resources","attributes","forms","templates","commands")
	"AccumulationRegister"       = @("dimensions","resources","attributes","forms","templates","commands")
	"AccountingRegister"         = @("dimensions","resources","attributes","forms","templates","commands")
	"CalculationRegister"        = @("dimensions","resources","attributes","forms","templates","commands")
	"DocumentJournal"            = @("columns","forms","templates","commands")
	"Constant"                   = @("forms")
}

# Canonical child order in ChildObjects
$script:childOrder = @(
	"Resource", "Dimension", "Attribute", "TabularSection",
	"AccountingFlag", "ExtDimensionAccountingFlag",
	"EnumValue", "Column", "AddressingAttribute", "Recalculation",
	"Form", "Template", "Command"
)

# Map from DSL child type to XML element name
$script:childTypeToXmlTag = @{
	"attributes"      = "Attribute"
	"tabularSections" = "TabularSection"
	"dimensions"      = "Dimension"
	"resources"       = "Resource"
	"enumValues"      = "EnumValue"
	"columns"         = "Column"
	"forms"           = "Form"
	"templates"       = "Template"
	"commands"        = "Command"
}

# ============================================================
# Section 9: DSL key normalization
# ============================================================

function Resolve-OperationKey([string]$key) {
	$k = $key.ToLower().Trim()
	if ($script:operationSynonyms.ContainsKey($k)) {
		return $script:operationSynonyms[$k]
	}
	return $null
}

function Resolve-ChildTypeKey([string]$key) {
	$k = $key.ToLower().Trim()
	if ($script:childTypeSynonyms.ContainsKey($k)) {
		return $script:childTypeSynonyms[$k]
	}
	return $null
}

# ============================================================
# Section 9.5: Inline mode converter
# ============================================================

function Split-ByCommaOutsideParens([string]$str) {
	$result = @()
	$depth = 0
	$current = ""
	foreach ($ch in $str.ToCharArray()) {
		if ($ch -eq '(') { $depth++ }
		elseif ($ch -eq ')') { $depth-- }
		if ($ch -eq ',' -and $depth -eq 0) {
			$result += $current
			$current = ""
		} else {
			$current += $ch
		}
	}
	if ($current) { $result += $current }
	return ,$result
}

function Convert-InlineToDefinition([string]$operation, [string]$value) {
	# Parse operation: "add-attribute" → ("add", "attribute")
	$opParts = $operation -split '-', 2
	$op = $opParts[0]      # add, remove, modify, set
	$target = $opParts[1]  # attribute, ts, owner, owners, property, etc.

	# Complex property targets
	$complexTargetMap = @{
		"owner" = "Owners"; "owners" = "Owners"
		"registerRecord" = "RegisterRecords"; "registerRecords" = "RegisterRecords"
		"basedOn" = "BasedOn"
		"inputByString" = "InputByString"
		"dataLockField" = "DataLockFields"; "dataLockFields" = "DataLockFields"
		"registeredDocument" = "RegisteredDocuments"; "registeredDocuments" = "RegisteredDocuments"
	}

	if ($complexTargetMap.ContainsKey($target)) {
		$propName = $complexTargetMap[$target]
		$values = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		# For InputByString, auto-prefix with MetaType.Name.
		if ($propName -eq "InputByString") {
			$prefix = "$($script:objType).$($script:objName)."
			$values = @($values | ForEach-Object {
				if ($_ -notmatch '\.') {
					"$prefix$_"
				} elseif ($_ -notmatch '^(Catalog|Document|InformationRegister|AccumulationRegister|AccountingRegister|CalculationRegister|ChartOfCharacteristicTypes|ChartOfCalculationTypes|ChartOfAccounts|ExchangePlan|BusinessProcess|Task|Enum|Report|DataProcessor)\.') {
					"$prefix$_"
				} else { $_ }
			})
		}
		$def = New-Object PSCustomObject
		$complexAction = if ($op -eq "set") { "set" } else { $op }
		$def | Add-Member -NotePropertyName "_complex" -NotePropertyValue @(
			@{ action = $complexAction; property = $propName; values = $values }
		)
		return $def
	}

	# Предопределённые (Ext/Predefined.xml) — отдельный файл; строим { <op>: { predefined: [...] } }.
	if ($target -eq 'predefined') {
		$items = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		$inner = New-Object PSCustomObject
		$inner | Add-Member -NotePropertyName 'predefined' -NotePropertyValue $items
		$def = New-Object PSCustomObject
		$def | Add-Member -NotePropertyName $op -NotePropertyValue $inner
		return $def
	}

	# TS attribute operations: dot notation "TSName.AttrDef"
	if ($target -eq "ts-attribute") {
		$items = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		# Group by TS name
		$tsGroups = [ordered]@{}
		foreach ($item in $items) {
			$dotIdx = $item.IndexOf('.')
			if ($dotIdx -le 0) {
				Warn "Invalid ts-attribute format (expected TSName.AttrDef): $item"
				continue
			}
			$tsName = $item.Substring(0, $dotIdx).Trim()
			$rest = $item.Substring($dotIdx + 1).Trim()
			if (-not $tsGroups.Contains($tsName)) {
				$tsGroups[$tsName] = @()
			}
			$tsGroups[$tsName] += $rest
		}

		# Build: { modify: { tabularSections: { TSName: { add/remove/modify: ... } } } }
		$tsModObj = New-Object PSCustomObject
		foreach ($tsName in $tsGroups.Keys) {
			$tsChanges = New-Object PSCustomObject
			switch ($op) {
				"add" {
					$tsChanges | Add-Member -NotePropertyName "add" -NotePropertyValue $tsGroups[$tsName]
				}
				"remove" {
					$tsChanges | Add-Member -NotePropertyName "remove" -NotePropertyValue $tsGroups[$tsName]
				}
				"modify" {
					$attrModObj = New-Object PSCustomObject
					foreach ($elemDef in $tsGroups[$tsName]) {
						$colonIdx = $elemDef.IndexOf(':')
						if ($colonIdx -le 0) {
							Warn "Invalid modify format (expected Name: key=val): $elemDef"
							continue
						}
						$elemName = $elemDef.Substring(0, $colonIdx).Trim()
						$changesPart = $elemDef.Substring($colonIdx + 1).Trim()
						$changesObj = New-Object PSCustomObject
						$changePairs = Split-ByCommaOutsideParens $changesPart
						foreach ($cp in $changePairs) {
							$cp = $cp.Trim()
							$eqIdx = $cp.IndexOf('=')
							if ($eqIdx -gt 0) {
								$ck = $cp.Substring(0, $eqIdx).Trim()
								$cv = $cp.Substring($eqIdx + 1).Trim()
								$changesObj | Add-Member -NotePropertyName $ck -NotePropertyValue $cv
							}
						}
						$attrModObj | Add-Member -NotePropertyName $elemName -NotePropertyValue $changesObj
					}
					$tsChanges | Add-Member -NotePropertyName "modify" -NotePropertyValue $attrModObj
				}
			}
			$tsModObj | Add-Member -NotePropertyName $tsName -NotePropertyValue $tsChanges
		}
		$def = New-Object PSCustomObject
		$modifyObj = New-Object PSCustomObject
		$modifyObj | Add-Member -NotePropertyName "tabularSections" -NotePropertyValue $tsModObj
		$def | Add-Member -NotePropertyName "modify" -NotePropertyValue $modifyObj
		return $def
	}

	# Target → JSON DSL child type
	$targetMap = @{
		"attribute" = "attributes"
		"ts" = "tabularSections"
		"dimension" = "dimensions"
		"resource" = "resources"
		"enumValue" = "enumValues"
		"column" = "columns"
		"form" = "forms"
		"template" = "templates"
		"command" = "commands"
		"property" = "properties"
	}

	$childType = $targetMap[$target]
	if (-not $childType) {
		Write-Error "Unknown inline target: $target"
		exit 1
	}

	$def = New-Object PSCustomObject

	switch ($op) {
		"add" {
			$items = @()
			if ($childType -eq "tabularSections") {
				# TS format: "TSName: attr1_shorthand, attr2_shorthand, ..."
				$tsValues = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
				foreach ($tsVal in $tsValues) {
					$colonIdx = $tsVal.IndexOf(':')
					if ($colonIdx -gt 0) {
						$tsName = $tsVal.Substring(0, $colonIdx).Trim()
						$attrsPart = $tsVal.Substring($colonIdx + 1).Trim()
						# Split attrs by comma (paren-aware), reassemble if part doesn't start with "Name:"
						$rawParts = Split-ByCommaOutsideParens $attrsPart
						$attrStrs = @()
						$current = ""
						foreach ($rp in $rawParts) {
							$rp = $rp.Trim()
							if ($current -and $rp -match '^[А-Яа-яЁёA-Za-z_]\w*\s*:') {
								$attrStrs += $current
								$current = $rp
							} elseif ($current) {
								$current += ", $rp"
							} else {
								$current = $rp
							}
						}
						if ($current) { $attrStrs += $current }
						$items += [PSCustomObject]@{ name = $tsName; attrs = $attrStrs }
					} else {
						# Just a name, no attrs
						$items += $tsVal
					}
				}
			} else {
				# Batch split by ;;
				$items = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			}
			$addObj = New-Object PSCustomObject
			$addObj | Add-Member -NotePropertyName $childType -NotePropertyValue $items
			$def | Add-Member -NotePropertyName "add" -NotePropertyValue $addObj
		}
		"remove" {
			$items = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			$removeObj = New-Object PSCustomObject
			$removeObj | Add-Member -NotePropertyName $childType -NotePropertyValue $items
			$def | Add-Member -NotePropertyName "remove" -NotePropertyValue $removeObj
		}
		"modify" {
			if ($childType -eq "properties") {
				# "CodeLength=11 ;; DescriptionLength=150"
				$kvPairs = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
				$propsObj = New-Object PSCustomObject
				foreach ($kv in $kvPairs) {
					$eqIdx = $kv.IndexOf('=')
					if ($eqIdx -gt 0) {
						$k = $kv.Substring(0, $eqIdx).Trim()
						$v = $kv.Substring($eqIdx + 1).Trim()
						$propsObj | Add-Member -NotePropertyName $k -NotePropertyValue $v
					} else {
						Warn "Invalid property format (expected Key=Value): $kv"
					}
				}
				$modifyObj = New-Object PSCustomObject
				$modifyObj | Add-Member -NotePropertyName "properties" -NotePropertyValue $propsObj
				$def | Add-Member -NotePropertyName "modify" -NotePropertyValue $modifyObj
			} else {
				# "ElementName: key=val, key=val ;; Element2: key=val"
				$elemDefs = @($value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
				$childModObj = New-Object PSCustomObject
				foreach ($elemDef in $elemDefs) {
					$colonIdx = $elemDef.IndexOf(':')
					if ($colonIdx -le 0) {
						Warn "Invalid modify format (expected Name: key=val): $elemDef"
						continue
					}
					$elemName = $elemDef.Substring(0, $colonIdx).Trim()
					$changesPart = $elemDef.Substring($colonIdx + 1).Trim()
					$changesObj = New-Object PSCustomObject
					$changePairs = Split-ByCommaOutsideParens $changesPart
					foreach ($cp in $changePairs) {
						$cp = $cp.Trim()
						$eqIdx = $cp.IndexOf('=')
						if ($eqIdx -gt 0) {
							$ck = $cp.Substring(0, $eqIdx).Trim()
							$cv = $cp.Substring($eqIdx + 1).Trim()
							$changesObj | Add-Member -NotePropertyName $ck -NotePropertyValue $cv
						}
					}
					$childModObj | Add-Member -NotePropertyName $elemName -NotePropertyValue $changesObj
				}
				$modifyObj = New-Object PSCustomObject
				$modifyObj | Add-Member -NotePropertyName $childType -NotePropertyValue $childModObj
				$def | Add-Member -NotePropertyName "modify" -NotePropertyValue $modifyObj
			}
		}
	}

	return $def
}

# ============================================================
# Section 10: ADD operations
# ============================================================

function Find-InsertionPoint {
	param([string]$xmlTag, $parsed)
	# Returns $refNode for Insert-BeforeElement (null = append)

	if (-not $script:childObjectsEl) { return $null }

	# Positional: after/before
	if ($parsed.after) {
		$afterEl = Find-ElementByName $script:childObjectsEl $xmlTag $parsed.after
		if ($afterEl) {
			# Insert after = insert before the next element sibling
			$next = $afterEl.NextSibling
			while ($next -and $next.NodeType -ne 'Element') { $next = $next.NextSibling }
			if ($next -and $next.LocalName -eq $xmlTag) { return $next }
			return $null  # append
		} else {
			Warn "after='$($parsed.after)': element '$($parsed.after)' not found in $xmlTag, appending"
		}
	}
	if ($parsed.before) {
		$beforeEl = Find-ElementByName $script:childObjectsEl $xmlTag $parsed.before
		if ($beforeEl) { return $beforeEl }
		Warn "before='$($parsed.before)': element '$($parsed.before)' not found in $xmlTag, appending"
	}

	# Default: after last element of this type, or in canonical position
	$lastOfType = Find-LastElementOfType $script:childObjectsEl $xmlTag
	if ($lastOfType) {
		$next = $lastOfType.NextSibling
		while ($next -and $next.NodeType -ne 'Element') { $next = $next.NextSibling }
		return $next  # null means append (which is correct: after last of type)
	}

	# No elements of this type yet — find canonical position
	$tagIdx = [array]::IndexOf($script:childOrder, $xmlTag)
	if ($tagIdx -lt 0) { return $null }

	# Find first element of any type that comes AFTER in the canonical order
	for ($i = $tagIdx + 1; $i -lt $script:childOrder.Count; $i++) {
		$nextTag = $script:childOrder[$i]
		$firstOfNext = Find-FirstElementOfType $script:childObjectsEl $nextTag
		if ($firstOfNext) { return $firstOfNext }
	}

	return $null  # append at end
}

function Process-Add($addDef) {
	$addDef.PSObject.Properties | ForEach-Object {
		$rawKey = $_.Name
		$items = $_.Value
		if ($rawKey -in @('predefined','предопределенные','предопределённые')) {
			Add-PredefinedItems $items
			return
		}
		$childType = Resolve-ChildTypeKey $rawKey

		if (-not $childType) {
			Warn "Unknown add child type: $rawKey"
			return
		}

		# Validate allowed
		$allowed = $script:validChildTypes[$script:objType]
		if ($allowed -and $childType -notin $allowed) {
			Warn "$childType not allowed for $($script:objType), skipping"
			return
		}

		$xmlTag = $script:childTypeToXmlTag[$childType]
		if (-not $xmlTag) {
			Warn "No XML tag mapping for $childType"
			return
		}

		Ensure-ChildObjectsOpen
		$indent = Get-ChildIndent $script:childObjectsEl
		$existingNames = Get-AllChildNames

		switch ($childType) {
			"attributes" {
				foreach ($item in $items) {
					$parsed = Parse-AttributeShorthand $item
					if ($existingNames.ContainsKey($parsed.name)) {
						Warn "Attribute '$($parsed.name)' already exists, skipping"
						continue
					}
					$context = Get-AttributeContext
					$fragmentXml = Build-AttributeFragment $parsed $context $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "Attribute" $parsed
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added attribute: $($parsed.name)"
					$script:addCount++
					$existingNames[$parsed.name] = "Attribute"
				}
			}
			"tabularSections" {
				foreach ($item in $items) {
					$tsName = if ($item -is [string]) { "$item" } else { "$($item.name)" }
					if ($existingNames.ContainsKey($tsName)) {
						Warn "TabularSection '$tsName' already exists, skipping"
						continue
					}
					$tsDef = if ($item -is [string]) { @{ name = $item } } else { $item }
					$fragmentXml = Build-TabularSectionFragment $tsDef $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "TabularSection" @{ after = ""; before = "" }
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added tabular section: $tsName"
					$script:addCount++
					$existingNames[$tsName] = "TabularSection"
				}
			}
			"dimensions" {
				foreach ($item in $items) {
					$parsed = Parse-AttributeShorthand $item
					if ($existingNames.ContainsKey($parsed.name)) {
						Warn "Dimension '$($parsed.name)' already exists, skipping"
						continue
					}
					$fragmentXml = Build-DimensionFragment $parsed $script:objType $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "Dimension" $parsed
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added dimension: $($parsed.name)"
					$script:addCount++
					$existingNames[$parsed.name] = "Dimension"
				}
			}
			"resources" {
				foreach ($item in $items) {
					$parsed = Parse-AttributeShorthand $item
					if ($existingNames.ContainsKey($parsed.name)) {
						Warn "Resource '$($parsed.name)' already exists, skipping"
						continue
					}
					$fragmentXml = Build-ResourceFragment $parsed $script:objType $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "Resource" $parsed
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added resource: $($parsed.name)"
					$script:addCount++
					$existingNames[$parsed.name] = "Resource"
				}
			}
			"enumValues" {
				foreach ($item in $items) {
					$parsed = Parse-EnumValueShorthand $item
					if ($existingNames.ContainsKey($parsed.name)) {
						Warn "EnumValue '$($parsed.name)' already exists, skipping"
						continue
					}
					$fragmentXml = Build-EnumValueFragment $parsed $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "EnumValue" $parsed
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added enum value: $($parsed.name)"
					$script:addCount++
					$existingNames[$parsed.name] = "EnumValue"
				}
			}
			"columns" {
				foreach ($item in $items) {
					$colName = if ($item -is [string]) { "$item" } else { "$($item.name)" }
					if ($existingNames.ContainsKey($colName)) {
						Warn "Column '$colName' already exists, skipping"
						continue
					}
					$fragmentXml = Build-ColumnFragment $item $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint "Column" @{ after = ""; before = "" }
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added column: $colName"
					$script:addCount++
					$existingNames[$colName] = "Column"
				}
			}
			{ $_ -in @("forms","templates","commands") } {
				$tagMap = @{ "forms" = "Form"; "templates" = "Template"; "commands" = "Command" }
				$tag = $tagMap[$childType]
				foreach ($item in $items) {
					$itemName = if ($item -is [string]) { "$item" } else { "$($item.name)" }
					if ($existingNames.ContainsKey($itemName)) {
						Warn "$tag '$itemName' already exists, skipping"
						continue
					}
					$fragmentXml = Build-SimpleChildFragment $tag $itemName $indent
					$nodes = Import-Fragment $fragmentXml
					$refNode = Find-InsertionPoint $tag @{ after = ""; before = "" }
					foreach ($node in $nodes) {
						Insert-BeforeElement $script:childObjectsEl $node $refNode $indent
					}
					Info "Added $($tag.ToLower()): $itemName"
					$script:addCount++
					$existingNames[$itemName] = $tag
				}
			}
		}
	}
}

# ============================================================
# Section 11: REMOVE operations
# ============================================================

function Process-Remove($removeDef) {
	$removeDef.PSObject.Properties | ForEach-Object {
		$rawKey = $_.Name
		$names = $_.Value
		$childType = Resolve-ChildTypeKey $rawKey

		if (-not $childType) {
			Warn "Unknown remove child type: $rawKey"
			return
		}
		if ($childType -eq "properties") {
			Warn "Cannot remove properties — use modify instead"
			return
		}

		$xmlTag = $script:childTypeToXmlTag[$childType]
		if (-not $xmlTag -or -not $script:childObjectsEl) {
			Warn "No ChildObjects or unknown tag for $childType"
			return
		}

		foreach ($name in $names) {
			$nameStr = "$name"
			$el = Find-ElementByName $script:childObjectsEl $xmlTag $nameStr
			if (-not $el) {
				Warn "$xmlTag '$nameStr' not found, skipping remove"
				continue
			}
			Remove-NodeWithWhitespace $el
			Info "Removed $($xmlTag.ToLower()): $nameStr"
			$script:removeCount++
		}
	}

	# Collapse if empty
	Collapse-ChildObjectsIfEmpty
}

# ============================================================
# Section 12: MODIFY operations
# ============================================================

function Modify-Properties($propsDef) {
	$propsDef.PSObject.Properties | ForEach-Object {
		$propName = $_.Name
		$propValue = $_.Value

		# Find the property element in Properties
		$propEl = $null
		foreach ($child in $script:propertiesEl.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $propName) {
				$propEl = $child
				break
			}
		}

		if (-not $propEl) {
			# create-if-missing: известное свойство создаём (порядок 1С терпит — append); неизвестное → ошибка (опечатка)
			if ($script:knownObjectProps -notcontains $propName) {
				Write-Error "modify-property: неизвестное свойство '$propName' — нет такого свойства объекта (опечатка?)"
				exit 1
			}
			$newNodes = Import-Fragment "<$propName/>"
			if ($newNodes.Count -gt 0) {
				Insert-PropertyInOrder $script:propertiesEl $newNodes[0] $null $propName
				$propEl = $newNodes[0]
			} else {
				Warn "Property '$propName': could not create element"
				return
			}
		}

		# Complex property: Owners, RegisterRecords, BasedOn, InputByString
		if ($script:complexPropertyMap.ContainsKey($propName)) {
			$valuesList = @()
			if ($propValue -is [array]) {
				$valuesList = @($propValue | ForEach-Object { "$_" })
			} else {
				$valuesList = @("$propValue" -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
			}
			Set-ComplexProperty $propName $valuesList
			return
		}

		# Handle boolean values
		$valueStr = "$propValue"
		if ($propValue -is [bool]) {
			$valueStr = if ($propValue) { "true" } else { "false" }
		}

		# Structural value-type property (корневой <Type> у Константы, ПВХ) —
		# перестроить дескриптор типа через Build-ValueTypeXml (не расплющивать в скаляр)
		if ($propName -ceq "Type") {
			$typeIndent = Get-ChildIndent $script:propertiesEl
			$newTypeXml = Build-ValueTypeXml $typeIndent $valueStr
			$newTypeNodes = Import-Fragment $newTypeXml
			if ($newTypeNodes.Count -gt 0) {
				# ReplaceChild сохраняет whitespace до/после узла на месте (без склейки отступов)
				$script:propertiesEl.ReplaceChild($newTypeNodes[0], $propEl) | Out-Null
				Info "Modified property: Type = $valueStr"
				$script:modifyCount++
			}
			return
		}

		# Guard: не расплющивать структурное свойство (с дочерними узлами) в скалярный текст —
		# это молча повредит XML. Завершаем ошибкой ДО записи файла.
		$hasChildElements = $false
		foreach ($ch in $propEl.ChildNodes) {
			if ($ch.NodeType -eq 'Element') { $hasChildElements = $true; break }
		}
		if ($hasChildElements) {
			Write-Error "modify-property: свойство '$propName' структурное (содержит дочерние узлы) — установка скалярного текста повредит XML; не поддерживается"
			exit 1
		}

		$propEl.InnerText = $valueStr
		Info "Modified property: $propName = $valueStr"
		$script:modifyCount++
	}
}

function Modify-ChildElements($modifyDef, [string]$childType) {
	$xmlTag = $script:childTypeToXmlTag[$childType]
	if (-not $xmlTag -or -not $script:childObjectsEl) {
		Warn "No ChildObjects or unknown tag for $childType"
		return
	}

	$modifyDef.PSObject.Properties | ForEach-Object {
		$elemName = $_.Name
		$changes = $_.Value

		$el = Find-ElementByName $script:childObjectsEl $xmlTag $elemName
		if (-not $el) {
			Warn "$xmlTag '$elemName' not found for modify"
			return
		}

		# Find Properties inside the element
		$propsEl = $null
		foreach ($gc in $el.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Properties") {
				$propsEl = $gc; break
			}
		}
		if (-not $propsEl) {
			Warn "$xmlTag '$elemName': no Properties element found"
			return
		}

		$changes.PSObject.Properties | ForEach-Object {
			$changeProp = $_.Name
			$changeValue = $_.Value

			# TS child attribute operations (add/remove/modify attrs inside a TabularSection)
			if ($xmlTag -eq "TabularSection" -and $changeProp -in @("add","remove","modify")) {
				# Find ChildObjects inside this TS element
				$tsChildObjEl = $null
				foreach ($gc in $el.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "ChildObjects") {
						$tsChildObjEl = $gc; break
					}
				}

				switch ($changeProp) {
					"add" {
						if (-not $tsChildObjEl) {
							Warn "TS '$elemName' has no ChildObjects element, cannot add attributes"
							return
						}
						# Ensure ChildObjects is open (not self-closing empty)
						$hasTsChildElements = $false
						foreach ($ch in $tsChildObjEl.ChildNodes) {
							if ($ch.NodeType -eq 'Element') { $hasTsChildElements = $true; break }
						}
						if (-not $hasTsChildElements) {
							$tsCoIndent = Get-ChildIndent $el
							$tsCloseWs = $script:xmlDoc.CreateWhitespace("`r`n$tsCoIndent")
							$tsChildObjEl.AppendChild($tsCloseWs) | Out-Null
						}
						foreach ($attrDef in @($changeValue)) {
							$parsed = Parse-AttributeShorthand $attrDef
							$existing = Find-ElementByName $tsChildObjEl "Attribute" $parsed.name
							if ($existing) {
								Warn "Attribute '$($parsed.name)' already exists in TS '$elemName', skipping"
								continue
							}
							$tsAttrIndent = Get-ChildIndent $tsChildObjEl
							$tsAttrContext = if ($script:objType -in @("DataProcessor","Report","ExternalDataProcessor","ExternalReport")) { "processor-tabular" } else { "tabular" }
							$fragmentXml = Build-AttributeFragment $parsed $tsAttrContext $tsAttrIndent
							$nodes = Import-Fragment $fragmentXml
							$savedCO = $script:childObjectsEl
							$script:childObjectsEl = $tsChildObjEl
							$refNode = Find-InsertionPoint "Attribute" $parsed
							$script:childObjectsEl = $savedCO
							foreach ($node in $nodes) {
								Insert-BeforeElement $tsChildObjEl $node $refNode $tsAttrIndent
							}
							Info "Added attribute to TS '$elemName': $($parsed.name)"
							$script:addCount++
						}
					}
					"remove" {
						if (-not $tsChildObjEl) {
							Warn "TS '$elemName' has no ChildObjects, cannot remove attributes"
							return
						}
						foreach ($attrName in @($changeValue)) {
							$attrEl = Find-ElementByName $tsChildObjEl "Attribute" "$attrName"
							if (-not $attrEl) {
								Warn "Attribute '$attrName' not found in TS '$elemName', skipping"
								continue
							}
							Remove-NodeWithWhitespace $attrEl
							Info "Removed attribute from TS '$elemName': $attrName"
							$script:removeCount++
						}
					}
					"modify" {
						if (-not $tsChildObjEl) {
							Warn "TS '$elemName' has no ChildObjects, cannot modify attributes"
							return
						}
						# Temporarily swap childObjectsEl and recurse
						$savedChildObjEl = $script:childObjectsEl
						$script:childObjectsEl = $tsChildObjEl
						Modify-ChildElements $changeValue "attributes"
						$script:childObjectsEl = $savedChildObjEl
					}
				}
				return  # Skip normal property modification
			}

			switch ($changeProp) {
				"name" {
					# Rename
					$nameEl = $null
					foreach ($gc in $propsEl.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Name") {
							$nameEl = $gc; break
						}
					}
					if ($nameEl) {
						$oldName = $nameEl.InnerText.Trim()
						$newName = "$changeValue"
						$nameEl.InnerText = $newName

						# Update Synonym if it was auto-generated (matches old CamelCase split)
						$oldSynonym = Split-CamelCase $oldName
						$synEl = $null
						foreach ($gc in $propsEl.ChildNodes) {
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Synonym") {
								$synEl = $gc; break
							}
						}
						if ($synEl) {
							# Check if current synonym matches auto-generated from old name
							$currentSyn = ""
							foreach ($item in $synEl.ChildNodes) {
								if ($item.NodeType -eq 'Element' -and $item.LocalName -eq "item") {
									foreach ($gc in $item.ChildNodes) {
										if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "content") {
											$currentSyn = $gc.InnerText.Trim()
										}
									}
								}
							}
							if ($currentSyn -eq $oldSynonym -or -not $currentSyn) {
								$newSynonym = Split-CamelCase $newName
								$synXml = Build-MLTextXml (Get-ChildIndent $propsEl) "Synonym" $newSynonym
								$newSynNodes = Import-Fragment $synXml
								if ($newSynNodes.Count -gt 0) {
									$propsEl.InsertAfter($newSynNodes[0], $synEl) | Out-Null
									Remove-NodeWithWhitespace $synEl
								}
							}
						}

						Info "Renamed ${xmlTag}: $oldName -> $newName"
						$script:modifyCount++
					}
				}
				"type" {
					# Change type
					$typeEl = $null
					foreach ($gc in $propsEl.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Type") {
							$typeEl = $gc; break
						}
					}
					$newTypeStr = "$changeValue"
					$typeIndent = Get-ChildIndent $propsEl
					$newTypeXml = Build-ValueTypeXml $typeIndent $newTypeStr

					$newTypeNodes = Import-Fragment $newTypeXml
					if ($typeEl -and $newTypeNodes.Count -gt 0) {
						$propsEl.InsertAfter($newTypeNodes[0], $typeEl) | Out-Null
						Remove-NodeWithWhitespace $typeEl
					} elseif ($newTypeNodes.Count -gt 0) {
						# No existing Type — insert after Comment
						$commentEl = $null
						foreach ($gc in $propsEl.ChildNodes) {
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Comment") {
								$commentEl = $gc; break
							}
						}
						if ($commentEl) {
							Insert-BeforeElement $propsEl $newTypeNodes[0] $commentEl.NextSibling $typeIndent
						}
					}

					# Also update FillValue if present
					$fillValEl = $null
					foreach ($gc in $propsEl.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "FillValue") {
							$fillValEl = $gc; break
						}
					}
					if ($fillValEl) {
						$fillIndent = Get-ChildIndent $propsEl
						$newFillXml = Build-FillValueXml $fillIndent $newTypeStr
						$newFillNodes = Import-Fragment $newFillXml
						if ($newFillNodes.Count -gt 0) {
							$propsEl.InsertAfter($newFillNodes[0], $fillValEl) | Out-Null
							Remove-NodeWithWhitespace $fillValEl
						}
					}

					Info "Changed type of $xmlTag '$elemName': $newTypeStr"
					$script:modifyCount++
				}
				"synonym" {
					$synEl = $null
					foreach ($gc in $propsEl.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "Synonym") {
							$synEl = $gc; break
						}
					}
					$synIndent = Get-ChildIndent $propsEl
					$newSynXml = Build-MLTextXml $synIndent "Synonym" "$changeValue"
					$newSynNodes = Import-Fragment $newSynXml
					if ($synEl -and $newSynNodes.Count -gt 0) {
						$propsEl.InsertAfter($newSynNodes[0], $synEl) | Out-Null
						Remove-NodeWithWhitespace $synEl
					}
					Info "Changed synonym of $xmlTag '$elemName': $changeValue"
					$script:modifyCount++
				}
				"Format" {
					if (Set-AttrPropertyElement $propsEl "Format" (Build-MLTextXml (Get-ChildIndent $propsEl) "Format" "$changeValue")) {
						Info "Set $xmlTag '$elemName'.Format"; $script:modifyCount++
					}
				}
				"EditFormat" {
					if (Set-AttrPropertyElement $propsEl "EditFormat" (Build-MLTextXml (Get-ChildIndent $propsEl) "EditFormat" "$changeValue")) {
						Info "Set $xmlTag '$elemName'.EditFormat"; $script:modifyCount++
					}
				}
				"ToolTip" {
					if (Set-AttrPropertyElement $propsEl "ToolTip" (Build-MLTextXml (Get-ChildIndent $propsEl) "ToolTip" "$changeValue")) {
						Info "Set $xmlTag '$elemName'.ToolTip"; $script:modifyCount++
					}
				}
				"ChoiceForm" {
					if (Set-AttrPropertyElement $propsEl "ChoiceForm" "<ChoiceForm>$(Esc-Xml "$changeValue")</ChoiceForm>") {
						Info "Set $xmlTag '$elemName'.ChoiceForm"; $script:modifyCount++
					}
				}
				"MinValue" {
					if (Set-AttrPropertyElement $propsEl "MinValue" (Build-MinMaxValueXml "MinValue" $changeValue)) {
						Info "Set $xmlTag '$elemName'.MinValue"; $script:modifyCount++
					}
				}
				"MaxValue" {
					if (Set-AttrPropertyElement $propsEl "MaxValue" (Build-MinMaxValueXml "MaxValue" $changeValue)) {
						Info "Set $xmlTag '$elemName'.MaxValue"; $script:modifyCount++
					}
				}
				"LinkByType" {
					if (Set-AttrPropertyElement $propsEl "LinkByType" (Build-LinkByTypeXml (Get-ChildIndent $propsEl) $changeValue)) {
						Info "Set $xmlTag '$elemName'.LinkByType"; $script:modifyCount++
					}
				}
				"ChoiceParameterLinks" {
					if (Set-AttrPropertyElement $propsEl "ChoiceParameterLinks" (Build-ChoiceParameterLinksXml (Get-ChildIndent $propsEl) $changeValue)) {
						Info "Set $xmlTag '$elemName'.ChoiceParameterLinks"; $script:modifyCount++
					}
				}
				"ChoiceParameters" {
					if (Set-AttrPropertyElement $propsEl "ChoiceParameters" (Build-ChoiceParametersXml (Get-ChildIndent $propsEl) $changeValue)) {
						Info "Set $xmlTag '$elemName'.ChoiceParameters"; $script:modifyCount++
					}
				}
				"FillValue" {
					if (Set-AttrPropertyElement $propsEl "FillValue" (Build-FillValueExplicitXml (Get-AttrTypeStrFromXml $propsEl) $changeValue)) {
						Info "Set $xmlTag '$elemName'.FillValue"; $script:modifyCount++
					}
				}
				default {
					# Scalar property change (Indexing, FillChecking, Use, etc.)
					$scalarEl = $null
					foreach ($gc in $propsEl.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq $changeProp) {
							$scalarEl = $gc; break
						}
					}
					if ($scalarEl) {
						$valueStr = "$changeValue"
						if ($changeValue -is [bool]) {
							$valueStr = if ($changeValue) { "true" } else { "false" }
						} else {
							$valueStr = Normalize-EnumValue $changeProp $valueStr
						}
						$scalarEl.InnerText = $valueStr
						Info "Modified $xmlTag '$elemName'.$changeProp = $valueStr"
						$script:modifyCount++
					} else {
						# create-if-missing: известное свойство создаём в позиции; неизвестное → ошибка (опечатка)
						if ($script:knownChildProps -notcontains $changeProp) {
							Write-Error "modify: неизвестное свойство '$changeProp' у $xmlTag '$elemName' (опечатка?)"
							exit 1
						}
						$valueStr = "$changeValue"
						if ($changeValue -is [bool]) {
							$valueStr = if ($changeValue) { "true" } else { "false" }
						} else {
							$valueStr = Normalize-EnumValue $changeProp $valueStr
						}
						$newNodes = Import-Fragment "<$changeProp>$(Esc-Xml $valueStr)</$changeProp>"
						if ($newNodes.Count -gt 0) {
							Insert-PropertyInOrder $propsEl $newNodes[0] $script:attrPropOrder $changeProp
							Info "Created $xmlTag '$elemName'.$changeProp = $valueStr"
							$script:modifyCount++
						}
					}
				}
			}
		}
	}
}

function Process-Modify($modifyDef) {
	$modifyDef.PSObject.Properties | ForEach-Object {
		$rawKey = $_.Name
		$value = $_.Value
		$childType = Resolve-ChildTypeKey $rawKey

		if (-not $childType) {
			Warn "Unknown modify child type: $rawKey"
			return
		}

		if ($childType -eq "properties") {
			Modify-Properties $value
		} else {
			Modify-ChildElements $value $childType
		}
	}
}

# ============================================================
# Section 12.5: Complex property helpers
# ============================================================

$script:complexPropertyMap = @{
	"Owners"          = @{ tag = "xr:Item"; attr = 'xsi:type="xr:MDObjectRef"' }
	"RegisterRecords" = @{ tag = "xr:Item"; attr = 'xsi:type="xr:MDObjectRef"' }
	"BasedOn"         = @{ tag = "xr:Item"; attr = 'xsi:type="xr:MDObjectRef"' }
	"InputByString"   = @{ tag = "xr:Field"; attr = $null }
	"DataLockFields"      = @{ tag = "xr:Field"; attr = $null; expand = $true }
	"RegisteredDocuments" = @{ tag = "xr:Item"; attr = 'xsi:type="xr:MDObjectRef"' }
}

# Известные свойства объекта (union по корпусу acc+erp 8.3.24) — allowlist для modify-property.
# Известное отсутствующее свойство create-if-missing создаётся; неизвестное (опечатка) → ошибка.
$script:knownObjectProps = @(
	'ActionPeriod','ActionPeriodUse','Addressing','AutoOrderByCode','Autonumbering','AuxiliaryChoiceForm',
	'AuxiliaryFolderChoiceForm','AuxiliaryFolderForm','AuxiliaryForm','AuxiliaryListForm','AuxiliaryObjectForm',
	'AuxiliaryRecordForm','AuxiliarySettingsForm','BaseCalculationTypes','BasePeriod','BasedOn',
	'CharacteristicExtValues','Characteristics','ChartOfAccounts','ChartOfCalculationTypes','CheckUnique',
	'ChoiceDataGetModeOnInputByString','ChoiceFoldersAndItems','ChoiceForm','ChoiceHistoryOnInput','ChoiceMode',
	'ChoiceParameterLinks','ChoiceParameters','CodeAllowedLength','CodeLength','CodeMask','CodeSeries','CodeType',
	'Comment','Correspondence','CreateOnInput','CreateTaskInPrivilegedMode','CurrentPerformer','DataHistory',
	'DataLockControlMode','DataLockFields','DefaultChoiceForm','DefaultFolderChoiceForm','DefaultFolderForm',
	'DefaultForm','DefaultListForm','DefaultObjectForm','DefaultPresentation','DefaultRecordForm','DefaultSettingsForm',
	'DefaultVariantForm','DependenceOnCalculationTypes','DescriptionLength','DistributedInfoBase','EditFormat',
	'EditType','EnableTotalsSliceFirst','EnableTotalsSliceLast','EnableTotalsSplitting',
	'ExecuteAfterWriteDataHistoryVersionProcessing','Explanation','ExtDimensionTypes','ExtendedEdit',
	'ExtendedListPresentation','ExtendedObjectPresentation','ExtendedPresentation','ExtendedRecordPresentation',
	'FillChecking','FoldersOnTop','Format','FullTextSearch','FullTextSearchOnInputByString','Hierarchical',
	'HierarchyType','IncludeConfigurationExtensions','IncludeHelpInContents','InformationRegisterPeriodicity',
	'InputByString','LevelCount','LimitLevelCount','LinkByType','ListPresentation','MainAddressingAttribute',
	'MainDataCompositionSchema','MainFilterOnPeriod','MarkNegatives','Mask','MaxExtDimensionCount','MaxValue',
	'MinValue','MultiLine','Name','NumberAllowedLength','NumberLength','NumberPeriodicity','NumberType','Numerator',
	'ObjectPresentation','OrderLength','Owners','PasswordMode','PeriodAdjustmentLength','Periodicity',
	'PostInPrivilegedMode','Posting','PredefinedDataUpdate','QuickChoice','RealTimePosting','RecordPresentation',
	'RegisterRecords','RegisterRecordsDeletion','RegisterRecordsWritingOnPost','RegisterType','RegisteredDocuments',
	'Schedule','ScheduleDate','ScheduleValue','SearchStringModeOnInputByString','SequenceFilling','SettingsStorage',
	'StandardAttributes','StandardTabularSections','SubordinationUse','Synonym','Task','TaskNumberAutoPrefix',
	'ToolTip','Type','UnpostInPrivilegedMode','UpdateDataHistoryImmediatelyAfterWrite','UseStandardCommands',
	'VariantsStorage','WriteMode'
)

# Известные свойства дочерних элементов (union Attribute/Dimension/Resource по корпусу) — allowlist default-ветки
# modify-attribute/-dimension/-resource.
$script:knownChildProps = @(
	'AccountingFlag','Balance','BaseDimension','ChoiceFoldersAndItems','ChoiceForm','ChoiceHistoryOnInput',
	'ChoiceParameterLinks','ChoiceParameters','Comment','CreateOnInput','DataHistory','DenyIncompleteValues',
	'DocumentMap','EditFormat','ExtDimensionAccountingFlag','ExtendedEdit','FillChecking','FillFromFillingValue',
	'FillValue','Format','FullTextSearch','Indexing','LinkByType','MainFilter','MarkNegatives','Mask','Master',
	'MaxValue','MinValue','MultiLine','Name','PasswordMode','QuickChoice','RegisterRecordsMap','ScheduleLink',
	'Synonym','ToolTip','Type','Use','UseInTotals'
)

# Канонический порядок свойств реквизита (последовательность Build-AttributeFragment) — для вставки в позицию.
# Порядок 1С терпит (cert), но держим канонический для консистентности с meta-compile.
$script:attrPropOrder = @(
	'Name','Synonym','Comment','Type','PasswordMode','Format','EditFormat','ToolTip','MarkNegatives','Mask',
	'MultiLine','ExtendedEdit','MinValue','MaxValue','FillFromFillingValue','FillValue','FillChecking',
	'ChoiceFoldersAndItems','ChoiceParameterLinks','ChoiceParameters','QuickChoice','CreateOnInput','ChoiceForm',
	'LinkByType','ChoiceHistoryOnInput','Use','Indexing','FullTextSearch','DataHistory'
)

# Вставить новый элемент свойства в Properties в канонической позиции (по orderArray); если свойства нет в
# orderArray (или orderArray пуст) — append. Порядок 1С терпит, канонический — для консистентности/снапшотов.
function Insert-PropertyInOrder($propsEl, $newNode, $orderArray, $propName) {
	$childIndent = "$(Get-ChildIndent $propsEl)"
	$refNode = $null
	$idx = if ($orderArray) { [array]::IndexOf($orderArray, $propName) } else { -1 }
	if ($idx -ge 0) {
		foreach ($ch in $propsEl.ChildNodes) {
			if ($ch.NodeType -eq 'Element') {
				$ci = [array]::IndexOf($orderArray, $ch.LocalName)
				if ($ci -gt $idx) { $refNode = $ch; break }
			}
		}
	}
	Insert-BeforeElement $propsEl $newNode $refNode $childIndent
}

# Заменить существующий элемент свойства реквизита новым фрагментом (по образцу ветки type),
# либо создать в канонической позиции, если его нет. Возвращает $true при успехе.
function Set-AttrPropertyElement($propsEl, $propName, $fragmentXml) {
	$newNodes = Import-Fragment $fragmentXml
	if ($newNodes.Count -eq 0) { return $false }
	$existing = $null
	foreach ($ch in $propsEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $propName) { $existing = $ch; break }
	}
	if ($existing) {
		# InsertBefore+RemoveChild сохраняет ведущий/хвостовой whitespace позиции existing
		# (InsertAfter+Remove-NodeWithWhitespace склеил бы: удаляет ведущий ws как отдельный узел).
		$propsEl.InsertBefore($newNodes[0], $existing) | Out-Null
		$propsEl.RemoveChild($existing) | Out-Null
	} else {
		Insert-PropertyInOrder $propsEl $newNodes[0] $script:attrPropOrder $propName
	}
	return $true
}

# MinValue/MaxValue — типизированное значение (порт Emit-MinMaxValue): nil / xs:string / xs:decimal.
function Build-MinMaxValueXml([string]$tag, $val) {
	if ($null -eq $val -or "$val" -eq '') { return "<$tag xsi:nil=`"true`"/>" }
	$t = if ($val -is [string]) { 'xs:string' } else { 'xs:decimal' }
	return "<$tag xsi:type=`"$t`">$(Esc-Xml "$val")</$tag>"
}

# --- Порт из meta-compile: развёртка путей данных + связи выбора / тип по ссылке (structural modify) ---

# Свойство из dict/PSCustomObject по списку синонимов (первый найденный, иначе $null).
function Get-ChElProp($obj, [string[]]$names) {
	if ($null -eq $obj) { return $null }
	foreach ($n in $names) {
		if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($n)) { return $obj[$n] } }
		elseif ($obj.PSObject -and $obj.PSObject.Properties[$n]) { return $obj.PSObject.Properties[$n].Value }
	}
	return $null
}

# Стандартный реквизит рус/англ → английский (для Catalog/Document); использует существующие reserved-карты.
function Resolve-StdAttrEn([string]$name) {
	$ctx = switch ("$script:objType") { 'Catalog' { 'catalog' } 'Document' { 'document' } default { $null } }
	if (-not $ctx) { return $null }
	$stdSet = $script:reservedByContext[$ctx]
	foreach ($en in $stdSet) {
		$ru = $script:reservedAttrNames[$en]
		if (($name -ieq $en) -or ($ru -and $name -ieq $ru)) { return $en }
	}
	return $null
}

# Прощающий ввод пути данных: короткое имя реквизита → полный путь объекта (порт Expand-DataPath).
function Expand-DataPath([string]$dp) {
	if (-not $dp) { return $dp }
	$s = "$dp"
	if ($s -match '[:/]') { return $s }
	if ($s -match '^-?\d+$') { return $s }
	if ($s -match '^(StandardAttribute|Attribute)\.') { return "$($script:objType).$($script:objName).$s" }
	if (-not $s.Contains('.')) {
		$en = Resolve-StdAttrEn $s
		if ($en) { return "$($script:objType).$($script:objName).StandardAttribute.$en" }
		return "$($script:objType).$($script:objName).Attribute.$s"
	}
	return $s
}

# Shorthand "name=path" | "name=path:Clear|DontChange" → {name, dataPath, valueChange?}.
function ConvertFrom-ChLinkShorthand([string]$s) {
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$o = @{ name = $s.Substring(0, $eq).Trim() }; $rest = $s.Substring($eq + 1).Trim()
	if ($rest -match '^(.*):(?i:(Clear|DontChange|очистить|неизменять))$') { $o['dataPath'] = $matches[1].Trim(); $o['valueChange'] = $matches[2] }
	else { $o['dataPath'] = $rest }
	return $o
}

# LinkByType — {dataPath, linkItem?} (порт Emit-LinkByType). Строка → dataPath, linkItem=0.
function Build-LinkByTypeXml([string]$indent, $spec) {
	if (-not $spec) { return "$indent<LinkByType/>" }
	if ($spec -is [string]) { $dp = "$spec"; $li = 0 }
	else {
		$dp = "$(Get-ChElProp $spec @('dataPath','path','путь'))"
		$liRaw = Get-ChElProp $spec @('linkItem','элементСвязи')
		$li = if ($null -ne $liRaw) { $liRaw } else { 0 }
	}
	if (-not $dp) { return "$indent<LinkByType/>" }
	$dp = Expand-DataPath $dp
	$lines = @(
		"$indent<LinkByType>"
		"$indent`t<xr:DataPath>$(Esc-Xml "$dp")</xr:DataPath>"
		"$indent`t<xr:LinkItem>$li</xr:LinkItem>"
		"$indent</LinkByType>"
	)
	return $lines -join "`r`n"
}

# ChoiceParameterLinks — [{name, dataPath, valueChange?}] (порт Emit-ChoiceParameterLinks). valueChange дефолт Clear.
function Build-ChoiceParameterLinksXml([string]$indent, $cpl) {
	if (-not $cpl -or @($cpl).Count -eq 0) { return "$indent<ChoiceParameterLinks/>" }
	$sb = New-Object System.Text.StringBuilder
	$sb.Append("$indent<ChoiceParameterLinks>") | Out-Null
	foreach ($lk in @($cpl)) {
		if ($lk -is [string]) { $lk = ConvertFrom-ChLinkShorthand $lk }
		$name = Get-ChElProp $lk @('name','имя')
		$dp = Expand-DataPath (Get-ChElProp $lk @('dataPath','path','путь'))
		$vcRaw = Get-ChElProp $lk @('valueChange','режимИзменения')
		$vc = 'Clear'
		if ($vcRaw) {
			$vc = switch -Regex ("$vcRaw".ToLower()) {
				'^(clear|очистить|очистка)$'             { 'Clear'; break }
				'^(dontchange|неизменять|неменять|нет)$' { 'DontChange'; break }
				default                                  { "$vcRaw" }
			}
		}
		$sb.Append("`r`n$indent`t<xr:Link>") | Out-Null
		$sb.Append("`r`n$indent`t`t<xr:Name>$(Esc-Xml "$name")</xr:Name>") | Out-Null
		$sb.Append("`r`n$indent`t`t<xr:DataPath xsi:type=`"xs:string`">$(Esc-Xml "$dp")</xr:DataPath>") | Out-Null
		$sb.Append("`r`n$indent`t`t<xr:ValueChange>$vc</xr:ValueChange>") | Out-Null
		$sb.Append("`r`n$indent`t</xr:Link>") | Out-Null
	}
	$sb.Append("`r`n$indent</ChoiceParameterLinks>") | Out-Null
	return $sb.ToString()
}

# --- Порт из meta-compile: значения параметров выбора (ChoiceParameters) ---

$script:fillRefRoots = @{
	'перечисление'='Enum'; 'справочник'='Catalog'; 'документ'='Document';
	'плансчетов'='ChartOfAccounts'; 'планвидовхарактеристик'='ChartOfCharacteristicTypes';
	'планвидоврасчета'='ChartOfCalculationTypes'; 'планвидоврасчёта'='ChartOfCalculationTypes';
	'планобмена'='ExchangePlan'; 'бизнеспроцесс'='BusinessProcess'; 'задача'='Task';
	'enum'='Enum'; 'catalog'='Catalog'; 'document'='Document'; 'chartofaccounts'='ChartOfAccounts';
	'chartofcharacteristictypes'='ChartOfCharacteristicTypes'; 'chartofcalculationtypes'='ChartOfCalculationTypes';
	'exchangeplan'='ExchangePlan'; 'businessprocess'='BusinessProcess'; 'task'='Task'
}
$script:fillEmptyRefWords = @('emptyref','пустаяссылка')
$script:fillEnumValWords  = @('enumvalue','значениеперечисления')
$script:accountTypeValues = @('Active','Passive','ActivePassive')
$script:fillRefKindRoot = @{
	'catalogref'='Catalog'; 'documentref'='Document'; 'enumref'='Enum';
	'chartofaccountsref'='ChartOfAccounts'; 'chartofcharacteristictypesref'='ChartOfCharacteristicTypes';
	'chartofcalculationtypesref'='ChartOfCalculationTypes'; 'exchangeplanref'='ExchangePlan';
	'businessprocessref'='BusinessProcess'; 'taskref'='Task'
}

function ConvertTo-ChScalar([string]$s) {
	$t = "$s".Trim()
	if ($t -match '^(?i:true|истина)$')  { return $true }
	if ($t -match '^(?i:false|ложь)$') { return $false }
	if ($t -match '^-?\d+$')       { return [int]$t }
	if ($t -match '^-?\d+\.\d+$')  { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
	return $t
}

function Format-FillNum($n) {
	if ($n -is [double] -or $n -is [decimal]) { return $n.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
	return "$n"
}

function Normalize-FillRef([string]$s) {
	if ([string]::IsNullOrEmpty($s)) { return $null }
	if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F-]+$') { return $s }
	$parts = $s -split '\.'
	if ($parts.Count -lt 2) { return $null }
	$root = $script:fillRefRoots[$parts[0].ToLower()]
	if (-not $root) { return $null }
	$typeName = $parts[1]
	if ($root -eq 'Enum') {
		if ($parts.Count -eq 2) { return $null }
		if ($parts.Count -eq 3) {
			if ($script:fillEmptyRefWords -contains $parts[2].ToLower()) { return "Enum.$typeName.EmptyRef" }
			return "Enum.$typeName.EnumValue.$($parts[2])"
		}
		$member = $parts[2]
		if ($script:fillEnumValWords -contains $member.ToLower()) { $rest = $parts[3..($parts.Count-1)] -join '.' }
		else { $rest = $parts[2..($parts.Count-1)] -join '.' }
		return "Enum.$typeName.EnumValue.$rest"
	}
	$tail = @($parts[1..($parts.Count-1)])
	for ($i = 0; $i -lt $tail.Count; $i++) {
		if ($script:fillEmptyRefWords -contains $tail[$i].ToLower()) { $tail[$i] = 'EmptyRef' }
	}
	return "$root." + ($tail -join '.')
}

function Expand-ChoiceRefValue([string]$value, [string]$typeStr) {
	if (-not $typeStr) { return $null }
	$t = Resolve-TypeStr $typeStr
	$root = $null; $tn = $null
	if ($t -match '^(\w+Ref)\.(.+)$') { $root = $script:fillRefKindRoot[$Matches[1].ToLower()]; $tn = $Matches[2] }
	elseif ($t -match '^([^.]+)\.(.+)$') { $root = $script:fillRefRoots[$Matches[1].ToLower()]; $tn = $Matches[2] }
	if (-not $root) { return $null }
	if ($script:fillEmptyRefWords -contains "$value".ToLower()) { return "$root.$tn.EmptyRef" }
	if ($root -eq 'Enum') { return "Enum.$tn.EnumValue.$value" }
	return "$root.$tn.$value"
}

function Normalize-ChoiceValue($value) {
	if ($value -is [bool]) { return @{ XsiType='xs:boolean'; Text=$(if ($value) { 'true' } else { 'false' }) } }
	if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
		return @{ XsiType='xs:decimal'; Text=(Format-FillNum $value) }
	}
	$s = "$value"
	if ($s -eq '') { return @{ XsiType='xs:string'; Text='' } }
	if ($s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') { return @{ XsiType='xs:dateTime'; Text=$s } }
	$ref = Normalize-FillRef $s
	if ($ref) { return @{ XsiType='xr:DesignTimeRef'; Text=$ref } }
	if ($script:accountTypeValues -contains $s) { return @{ XsiType='ent:AccountType'; Text=$s } }
	return @{ XsiType='xs:string'; Text=$s }
}

function Normalize-ChoiceValueT($value, [string]$typeStr) {
	if ($typeStr -and ($value -is [string]) -and (-not "$value".Contains('.'))) {
		$ex = Expand-ChoiceRefValue "$value" $typeStr
		if ($ex) { return @{ XsiType='xr:DesignTimeRef'; Text=$ex } }
	}
	return Normalize-ChoiceValue $value
}

function ConvertFrom-ChParamShorthand([string]$s) {
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$name = $s.Substring(0, $eq).Trim(); $rest = $s.Substring($eq + 1)
	if ($rest -match ',') {
		$vals = @(); foreach ($p in ($rest -split ',')) { $vals += ,(ConvertTo-ChScalar $p) }
		return @{ name = $name; value = $vals }
	}
	return @{ name = $name; value = (ConvertTo-ChScalar $rest) }
}

# ChoiceParameters — [{name, type?, value?}] (порт Emit-ChoiceParameters). Значение на app:value (xsi:type=тип);
# массив → v8:FixedArray с v8:Value; без value → nil. Требует xmlns:app в Import-Fragment.
function Build-ChoiceParametersXml([string]$indent, $cp) {
	if (-not $cp -or @($cp).Count -eq 0) { return "$indent<ChoiceParameters/>" }
	$sb = New-Object System.Text.StringBuilder
	$sb.Append("$indent<ChoiceParameters>") | Out-Null
	foreach ($item in @($cp)) {
		if ($item -is [string]) { $item = ConvertFrom-ChParamShorthand $item }
		$name = Get-ChElProp $item @('name','имя')
		$ptype = Get-ChElProp $item @('type','тип')
		$hasVal = $false; $val = $null
		if ($item -is [System.Collections.IDictionary]) {
			if ($item.Contains('value')) { $hasVal = $true; $val = $item['value'] }
			elseif ($item.Contains('значение')) { $hasVal = $true; $val = $item['значение'] }
		} elseif ($item.PSObject) {
			if ($item.PSObject.Properties['value']) { $hasVal = $true; $val = $item.PSObject.Properties['value'].Value }
			elseif ($item.PSObject.Properties['значение']) { $hasVal = $true; $val = $item.PSObject.Properties['значение'].Value }
		}
		$valIsArray = ($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])
		$sb.Append("`r`n$indent`t<app:item name=`"$(Esc-Xml "$name")`">") | Out-Null
		if (-not $hasVal) {
			$sb.Append("`r`n$indent`t`t<app:value xsi:nil=`"true`"/>") | Out-Null
		} elseif ($valIsArray) {
			$sb.Append("`r`n$indent`t`t<app:value xsi:type=`"v8:FixedArray`">") | Out-Null
			foreach ($v in $val) {
				$norm = Normalize-ChoiceValueT $v $ptype
				if ([string]::IsNullOrEmpty($norm.Text)) { $sb.Append("`r`n$indent`t`t`t<v8:Value xsi:type=`"$($norm.XsiType)`"/>") | Out-Null }
				else { $sb.Append("`r`n$indent`t`t`t<v8:Value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</v8:Value>") | Out-Null }
			}
			$sb.Append("`r`n$indent`t`t</app:value>") | Out-Null
		} else {
			$norm = Normalize-ChoiceValueT $val $ptype
			if ([string]::IsNullOrEmpty($norm.Text)) { $sb.Append("`r`n$indent`t`t<app:value xsi:type=`"$($norm.XsiType)`"/>") | Out-Null }
			else { $sb.Append("`r`n$indent`t`t<app:value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</app:value>") | Out-Null }
		}
		$sb.Append("`r`n$indent`t</app:item>") | Out-Null
	}
	$sb.Append("`r`n$indent</ChoiceParameters>") | Out-Null
	return $sb.ToString()
}

# --- Порт из meta-compile: явное значение заполнения (FillValue) ---

$script:fillBoolTrue  = @('true','истина','да')
$script:fillBoolFalse = @('false','ложь','нет')

function Esc-XmlText([string]$s) { return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;') }

function Get-FillTypeCategory([string]$typeStr) {
	if (-not $typeStr) { return 'String' }
	if ($typeStr -match '\+') { return 'Other' }
	$t = Resolve-TypeStr $typeStr
	if ($t -match '^Boolean$')          { return 'Boolean' }
	if ($t -match '^String(\(|$)')      { return 'String' }
	if ($t -match '^Number(\(|$)')      { return 'Number' }
	if ($t -match '^(Date|DateTime)$')  { return 'Date' }
	return 'Other'
}

function Expand-FillShortRef([string]$s, [string]$typeStr) {
	if (-not $typeStr) { return $null }
	if ($typeStr -match '\+') { return $null }
	$t = Resolve-TypeStr $typeStr
	if ($t -notmatch '^(\w+Ref)\.(.+)$') { return $null }
	$root = $script:fillRefKindRoot[$Matches[1].ToLower()]
	if (-not $root) { return $null }
	$typeName = $Matches[2]
	if ($script:fillEmptyRefWords -contains $s.ToLower()) { return "$root.$typeName.EmptyRef" }
	if ($root -eq 'Enum') { return "Enum.$typeName.EnumValue.$s" }
	return "$root.$typeName.$s"
}

function Resolve-FillValueSpec([string]$s, [string]$typeStr) {
	$cat = Get-FillTypeCategory $typeStr
	if ($s -eq '') { return @{ XsiType='xs:string'; Text='' } }
	if ($cat -eq 'String') { return @{ XsiType='xs:string'; Text=$s } }
	if ($cat -eq 'Boolean' -or ($script:fillBoolTrue -contains $s.ToLower()) -or ($script:fillBoolFalse -contains $s.ToLower())) {
		if ($script:fillBoolTrue  -contains $s.ToLower()) { return @{ XsiType='xs:boolean'; Text='true' } }
		if ($script:fillBoolFalse -contains $s.ToLower()) { return @{ XsiType='xs:boolean'; Text='false' } }
	}
	if ($cat -eq 'Number') { return @{ XsiType='xs:decimal'; Text=$s } }
	if ($cat -eq 'Date' -or $s -match '^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$') {
		if ($s -match '^\d{4}-\d{2}-\d{2}$') { $s = "${s}T00:00:00" }
		return @{ XsiType='xs:dateTime'; Text=$s }
	}
	$ref = Normalize-FillRef $s
	if ($ref) { return @{ XsiType='xr:DesignTimeRef'; Text=$ref } }
	$short = Expand-FillShortRef $s $typeStr
	if ($short) { return @{ XsiType='xr:DesignTimeRef'; Text=$short } }
	return @{ XsiType='xs:string'; Text=$s }
}

# Извлечь тип реквизита из XML (<Type>/<v8:Type>) → DSL-typeStr для категоризации FillValue.
function Get-AttrTypeStrFromXml($propsEl) {
	$typeEl = $null
	foreach ($ch in $propsEl.ChildNodes) { if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'Type') { $typeEl = $ch; break } }
	if (-not $typeEl) { return "" }
	$mapped = @()
	foreach ($ch in $typeEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'Type') {
			$t = $ch.InnerText.Trim()
			$colon = $t.IndexOf(':'); if ($colon -ge 0) { $t = $t.Substring($colon + 1) }
			switch -Regex ($t) {
				'^string$'   { $mapped += 'String'; break }
				'^decimal$'  { $mapped += 'Number'; break }
				'^boolean$'  { $mapped += 'Boolean'; break }
				'^dateTime$' { $mapped += 'Date'; break }
				default      { $mapped += $t }
			}
		}
	}
	if ($mapped.Count -eq 0) { return "" }
	if ($mapped.Count -gt 1) { return ($mapped -join ' + ') }
	return $mapped[0]
}

# FillValue — явное значение (порт Emit-FillValue, ветка hasSpec). Маркеры {nil}/{emptyRef}; иначе по типу.
function Build-FillValueExplicitXml([string]$typeStr, $spec) {
	if ($null -eq $spec) { return "<FillValue xsi:nil=`"true`"/>" }
	if ($spec -is [bool]) { return "<FillValue xsi:type=`"xs:boolean`">$(if ($spec) { 'true' } else { 'false' })</FillValue>" }
	if ($spec -is [int] -or $spec -is [long] -or $spec -is [double] -or $spec -is [decimal]) { return "<FillValue xsi:type=`"xs:decimal`">$(Format-FillNum $spec)</FillValue>" }
	if ((Get-ChElProp $spec @('nil')) -eq $true) { return "<FillValue xsi:nil=`"true`"/>" }
	if ((Get-ChElProp $spec @('emptyRef','пустаяссылка')) -eq $true) { return "<FillValue xsi:type=`"xr:DesignTimeRef`"/>" }
	$r = Resolve-FillValueSpec "$spec" $typeStr
	if ($r.Text -eq '' -and $r.XsiType -eq 'xs:string') { return "<FillValue xsi:type=`"xs:string`"/>" }
	return "<FillValue xsi:type=`"$($r.XsiType)`">$(Esc-XmlText $r.Text)</FillValue>"
}

function Find-PropertyElement([string]$propName) {
	foreach ($child in $script:propertiesEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $propName) {
			return $child
		}
	}
	return $null
}

function Get-ComplexPropertyValues([System.Xml.XmlElement]$propEl) {
	$values = @()
	foreach ($child in $propEl.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$values += $child.InnerText.Trim()
		}
	}
	return $values
}

function Add-ComplexPropertyItem([string]$propertyName, [string[]]$values) {
	$mapEntry = $script:complexPropertyMap[$propertyName]
	if (-not $mapEntry) { Warn "Unknown complex property: $propertyName"; return }
	if ($mapEntry.expand) { $values = @($values | ForEach-Object { Expand-DataPath "$_" }) }

	$propEl = Find-PropertyElement $propertyName
	if (-not $propEl) {
		Warn "Property element '$propertyName' not found in Properties"
		return
	}

	# Get existing values to check duplicates
	$existing = Get-ComplexPropertyValues $propEl

	$indent = Get-ChildIndent $script:propertiesEl
	$childIndent = "$indent`t"

	# Check if element is self-closing (empty)
	$isEmpty = $true
	foreach ($ch in $propEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element') { $isEmpty = $false; break }
	}

	# If self-closing / empty, add closing whitespace
	if ($isEmpty -and $propEl.ChildNodes.Count -eq 0) {
		$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$indent")
		$propEl.AppendChild($closeWs) | Out-Null
	}

	foreach ($val in $values) {
		if ($val -in $existing) {
			Warn "$propertyName already contains '$val', skipping"
			continue
		}
		$tag = $mapEntry.tag
		$attrStr = $mapEntry.attr
		if ($attrStr) {
			$fragXml = "<$tag $attrStr>$(Esc-Xml $val)</$tag>"
		} else {
			$fragXml = "<$tag>$(Esc-Xml $val)</$tag>"
		}
		$nodes = Import-Fragment $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $propEl $node $null $childIndent
		}
		Info "Added $propertyName item: $val"
		$script:addCount++
	}
}

function Remove-ComplexPropertyItem([string]$propertyName, [string[]]$values) {
	$mapEntry = $script:complexPropertyMap[$propertyName]
	if ($mapEntry -and $mapEntry.expand) { $values = @($values | ForEach-Object { Expand-DataPath "$_" }) }
	$propEl = Find-PropertyElement $propertyName
	if (-not $propEl) {
		Warn "Property element '$propertyName' not found in Properties"
		return
	}

	foreach ($val in $values) {
		$found = $false
		foreach ($child in @($propEl.ChildNodes)) {
			if ($child.NodeType -eq 'Element' -and $child.InnerText.Trim() -eq $val) {
				Remove-NodeWithWhitespace $child
				Info "Removed $propertyName item: $val"
				$script:removeCount++
				$found = $true
				break
			}
		}
		if (-not $found) {
			Warn "$propertyName item '$val' not found, skipping"
		}
	}

	# Collapse if empty
	$hasElements = $false
	foreach ($ch in $propEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element') { $hasElements = $true; break }
	}
	if (-not $hasElements) {
		while ($propEl.HasChildNodes) {
			$propEl.RemoveChild($propEl.FirstChild) | Out-Null
		}
	}
}

function Set-ComplexProperty([string]$propertyName, [string[]]$values) {
	$mapEntry = $script:complexPropertyMap[$propertyName]
	if (-not $mapEntry) { Warn "Unknown complex property: $propertyName"; return }
	if ($mapEntry.expand) { $values = @($values | ForEach-Object { Expand-DataPath "$_" }) }

	$propEl = Find-PropertyElement $propertyName
	if (-not $propEl) {
		Warn "Property element '$propertyName' not found in Properties"
		return
	}

	$indent = Get-ChildIndent $script:propertiesEl
	$childIndent = "$indent`t"

	# Remove all existing children
	while ($propEl.HasChildNodes) {
		$propEl.RemoveChild($propEl.FirstChild) | Out-Null
	}

	if ($values.Count -eq 0) {
		# Leave self-closing
		Info "Cleared $propertyName"
		$script:modifyCount++
		return
	}

	# Add closing whitespace
	$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$indent")
	$propEl.AppendChild($closeWs) | Out-Null

	# Add each value
	foreach ($val in $values) {
		$tag = $mapEntry.tag
		$attrStr = $mapEntry.attr
		if ($attrStr) {
			$fragXml = "<$tag $attrStr>$(Esc-Xml $val)</$tag>"
		} else {
			$fragXml = "<$tag>$(Esc-Xml $val)</$tag>"
		}
		$nodes = Import-Fragment $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $propEl $node $null $childIndent
		}
	}
	$count = $values.Count
	Info "Set $propertyName`: $count items"
	$script:modifyCount++
}

# ============================================================
# Section 13: Main processing
# ============================================================

# ============================================================
# Predefined data (Ext/Predefined.xml) — add предопределённых (Catalog/ChartOfCharacteristicTypes).
# Существующие <Item id=GUID> сохраняются побайтово (текстовый append), новые получают свежий GUID —
# инвариант «не менять id существующей сущности».
# ============================================================

$script:predefXsiTypeByObj = @{
	'Catalog' = 'CatalogPredefinedItems'
	'ChartOfCharacteristicTypes' = 'PlanOfCharacteristicKindPredefinedItems'
}

function Get-PredefinedPath {
	$objDir = Join-Path (Split-Path $resolvedPath) $script:objName
	return (Join-Path (Join-Path $objDir "Ext") "Predefined.xml")
}

function Get-ObjectCodeType {
	foreach ($ch in $script:propertiesEl.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'CodeType') { return $ch.InnerText.Trim() }
	}
	return 'String'
}

# Элемент DSL: строка "(Код) Имя [Наименование]" ЛИБО объект {name,code,description,isFolder,childItems}.
function Resolve-PredefItem($val) {
	if ($val -is [string]) {
		$s = "$val"; $descRaw = $null; $hasDesc = $false
		if ($s -match '\[(.*)\]') { $descRaw = $Matches[1]; $hasDesc = $true; $s = $s -replace '\s*\[.*\]', '' }
		$m = [regex]::Match($s.Trim(), '^\s*(?:\(([^)]*)\)\s*)?(\S+)\s*$')
		$name = $m.Groups[2].Value
		$code = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' }
		$desc = if ($hasDesc) { $descRaw } else { Split-CamelCase $name }
		return @{ name = $name; code = $code; desc = $desc; isFolder = $false; children = @() }
	}
	$gv = { param($o, [string[]]$keys) foreach ($k in $keys) { if ($o.PSObject.Properties[$k]) { return $o.$k } } return $null }
	$name = "$(& $gv $val @('name','имя'))"
	$codeV = & $gv $val @('code','код'); $code = if ($null -ne $codeV) { "$codeV" } else { '' }
	$hasDesc = $val.PSObject.Properties['description'] -or $val.PSObject.Properties['наименование']
	$descV = & $gv $val @('description','наименование')
	$desc = if ($hasDesc) { "$descV" } else { Split-CamelCase $name }
	$isFolder = ((& $gv $val @('isFolder','группа')) -eq $true)
	$subs = & $gv $val @('childItems','подчиненные')
	return @{ name = $name; code = $code; desc = $desc; isFolder = $isFolder; children = @(if ($subs) { @($subs) } else { @() }) }
}

function Build-PredefItemXml([string]$indent, $val, [string]$codeType) {
	$r = Resolve-PredefItem $val
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append("$indent<Item id=`"$(New-Guid-String)`">`r`n")
	[void]$sb.Append("$indent`t<Name>$(Esc-XmlText $r.name)</Name>`r`n")
	if (-not $r.code) { [void]$sb.Append("$indent`t<Code/>`r`n") }
	elseif ($codeType -eq 'Number') { [void]$sb.Append("$indent`t<Code xsi:type=`"xs:decimal`">$(Esc-XmlText $r.code)</Code>`r`n") }
	else { [void]$sb.Append("$indent`t<Code>$(Esc-XmlText $r.code)</Code>`r`n") }
	if ($r.desc -eq '') { [void]$sb.Append("$indent`t<Description/>`r`n") }
	else { [void]$sb.Append("$indent`t<Description>$(Esc-XmlText $r.desc)</Description>`r`n") }
	[void]$sb.Append("$indent`t<IsFolder>$(if ($r.isFolder) { 'true' } else { 'false' })</IsFolder>`r`n")
	if ($r.children.Count -gt 0) {
		[void]$sb.Append("$indent`t<ChildItems>`r`n")
		foreach ($c in $r.children) { [void]$sb.Append((Build-PredefItemXml "$indent`t`t" $c $codeType)) }
		[void]$sb.Append("$indent`t</ChildItems>`r`n")
	}
	[void]$sb.Append("$indent</Item>`r`n")
	return $sb.ToString()
}

function Add-PredefinedItems($items) {
	$xsiType = $script:predefXsiTypeByObj[$script:objType]
	if (-not $xsiType) { Write-Error "add-predefined: тип объекта '$($script:objType)' не поддержан (только Catalog, ChartOfCharacteristicTypes)"; exit 1 }
	$codeType = Get-ObjectCodeType
	$version = $script:xmlDoc.DocumentElement.GetAttribute("version")
	$path = Get-PredefinedPath
	$itemsXml = ""
	foreach ($it in @($items)) { $itemsXml += (Build-PredefItemXml "`t" $it $codeType) }
	$utf8Bom = New-Object System.Text.UTF8Encoding($true)
	if (Test-Path $path) {
		$text = [System.IO.File]::ReadAllText($path, $utf8Bom)
		$text = $text.Replace("</PredefinedData>", "$itemsXml</PredefinedData>")
	} else {
		$extDir = Split-Path $path
		if (-not (Test-Path $extDir)) { New-Item -ItemType Directory -Path $extDir -Force | Out-Null }
		$hdr = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<PredefinedData xmlns=`"http://v8.1c.ru/8.3/xcf/predef`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xsi:type=`"$xsiType`" version=`"$version`">`r`n"
		$text = "$hdr$itemsXml</PredefinedData>`r`n"
	}
	[System.IO.File]::WriteAllText($path, $text, $utf8Bom)
	$n = @($items).Count
	Info "Added $n predefined item(s) → $path"
	$script:addCount += $n
}

# --- Inline mode conversion ---
if ($Operation) {
	$def = Convert-InlineToDefinition $Operation $Value
}
if (-not $def) {
	Write-Error "No definition loaded"
	exit 1
}

# --- Process complex property operations ---
if ($def.PSObject.Properties.Match("_complex").Count -gt 0 -and $def._complex) {
	foreach ($cop in $def._complex) {
		switch ($cop.action) {
			"add"    { Add-ComplexPropertyItem $cop.property $cop.values }
			"remove" { Remove-ComplexPropertyItem $cop.property $cop.values }
			"set"    { Set-ComplexProperty $cop.property $cop.values }
		}
	}
}

# --- Process standard operations ---
$def.PSObject.Properties | ForEach-Object {
	$prop = $_
	if ($prop.Name -eq "_complex") { return }
	$opKey = Resolve-OperationKey $prop.Name
	if (-not $opKey) {
		Warn "Unknown operation: $($prop.Name)"
		return
	}

	switch ($opKey) {
		"add"    { Process-Add $prop.Value }
		"remove" { Process-Remove $prop.Value }
		"modify" { Process-Modify $prop.Value }
	}
}

# ============================================================
# Section 14: Save + validate
# ============================================================

# Save XML
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)  # with BOM
$settings.Indent = $false  # preserve original whitespace
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

# Write using XmlWriter to get proper encoding declaration
$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$script:xmlDoc.Save($writer)
$writer.Flush()
$writer.Close()

$bytes = $memStream.ToArray()
$memStream.Close()

# Fix encoding case: utf-8 → UTF-8 (cosmetic, 1C accepts both)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
# Remove BOM from string if present (we'll add it as bytes)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
	$text = $text.Substring(1)
}
$text = $text.Replace('encoding="utf-8"', 'encoding="UTF-8"')

# Write with BOM
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedPath, $text, $utf8Bom)

Info "Saved: $resolvedPath"

# ============================================================
# Section 15: Auto-validate
# ============================================================

if (-not $NoValidate) {
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\meta-validate") "scripts\meta-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running meta-validate ---" -ForegroundColor DarkGray
		& powershell.exe -NoProfile -File $validateScript -ObjectPath $resolvedPath
	} else {
		Write-Host ""
		Write-Host "[SKIP] meta-validate not found at: $validateScript" -ForegroundColor DarkGray
	}
}

# ============================================================
# Section 16: Summary
# ============================================================

Write-Host ""
Write-Host "=== meta-edit summary ===" -ForegroundColor Green
Write-Host "  Object:   $($script:objType).$($script:objName)"
Write-Host "  Added:    $($script:addCount)"
Write-Host "  Removed:  $($script:removeCount)"
Write-Host "  Modified: $($script:modifyCount)"
if ($script:warnCount -gt 0) {
	Write-Host "  Warnings: $($script:warnCount)" -ForegroundColor Yellow
}

$totalChanges = $script:addCount + $script:removeCount + $script:modifyCount
if ($totalChanges -eq 0) {
	Write-Host "  No changes applied." -ForegroundColor Yellow
}

exit 0
