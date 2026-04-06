# skd-compile v1.6 — Compile 1C DCS from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$DefinitionFile,
	[string]$Value,
	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and validate JSON ---

if ($DefinitionFile -and $Value) {
	Write-Error "Cannot use both -DefinitionFile and -Value"
	exit 1
}
if (-not $DefinitionFile -and -not $Value) {
	Write-Error "Either -DefinitionFile or -Value is required"
	exit 1
}

if ($DefinitionFile) {
	if (-not [System.IO.Path]::IsPathRooted($DefinitionFile)) {
		$DefinitionFile = Join-Path (Get-Location).Path $DefinitionFile
	}
	if (-not (Test-Path $DefinitionFile)) {
		Write-Error "Definition file not found: $DefinitionFile"
		exit 1
	}
	$json = Get-Content -Raw -Encoding UTF8 $DefinitionFile
} else {
	$json = $Value
}

$def = $json | ConvertFrom-Json

if (-not $def.dataSets -or $def.dataSets.Count -eq 0) {
	Write-Error "JSON must have at least one entry in 'dataSets'"
	exit 1
}

# Base directory for resolving @file references in query
$script:queryBaseDir = if ($DefinitionFile) { [System.IO.Path]::GetDirectoryName($DefinitionFile) } else { (Get-Location).Path }

# --- 2. XML helpers ---

$script:xml = New-Object System.Text.StringBuilder 16384

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Resolve-QueryValue {
	param([string]$val, [string]$baseDir)
	if (-not $val.StartsWith("@")) { return $val }
	$filePath = $val.Substring(1)
	if ([System.IO.Path]::IsPathRooted($filePath)) {
		$candidates = @($filePath)
	} else {
		$candidates = @(
			(Join-Path $baseDir $filePath),
			(Join-Path (Get-Location).Path $filePath)
		)
	}
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			return (Get-Content -Raw -Encoding UTF8 $c).TrimEnd()
		}
	}
	Write-Error "Query file not found: $filePath (searched: $($candidates -join ', '))"
	exit 1
}

function Emit-MLText {
	param([string]$tag, [string]$text, [string]$indent)
	X "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

# --- 3. Resolve defaults ---

# DataSources
$dataSources = @()
if ($def.dataSources) {
	foreach ($ds in $def.dataSources) {
		$dataSources += @{
			name = "$($ds.name)"
			type = if ($ds.type) { "$($ds.type)" } else { "Local" }
		}
	}
} else {
	$dataSources += @{ name = "ИсточникДанных1"; type = "Local" }
}

$defaultSource = $dataSources[0].name

# Auto-name dataSets
$dsIndex = 1
foreach ($ds in $def.dataSets) {
	if (-not $ds.name) {
		$ds | Add-Member -NotePropertyName "name" -NotePropertyValue "НаборДанных$dsIndex" -Force
	}
	$dsIndex++
}

# --- 4. Type system ---

# Type synonyms — normalize Russian/common names to canonical DSL types
# Use case-sensitive hashtable to avoid PS 5.1 DuplicateKeyInHashLiteral
$script:typeSynonyms = New-Object System.Collections.Hashtable
# Russian names (case doesn't matter — we'll also do case-insensitive lookup)
$script:typeSynonyms["число"] = "decimal"
$script:typeSynonyms["строка"] = "string"
$script:typeSynonyms["булево"] = "boolean"
$script:typeSynonyms["дата"] = "date"
$script:typeSynonyms["датавремя"] = "dateTime"
$script:typeSynonyms["стандартныйпериод"] = "StandardPeriod"
# English canonical (lowercase for lookup)
$script:typeSynonyms["bool"] = "boolean"
$script:typeSynonyms["str"] = "string"
$script:typeSynonyms["int"] = "decimal"
$script:typeSynonyms["integer"] = "decimal"
$script:typeSynonyms["number"] = "decimal"
$script:typeSynonyms["num"] = "decimal"
# Reference synonyms (Russian, lowercase)
$script:typeSynonyms["справочникссылка"] = "CatalogRef"
$script:typeSynonyms["документссылка"] = "DocumentRef"
$script:typeSynonyms["перечислениессылка"] = "EnumRef"
$script:typeSynonyms["плансчетовссылка"] = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	# Check for parameterized types: число(15,2), строка(100), etc.
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]

		# Resolve base name (case-insensitive via .ToLower())
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }

		return $typeStr
	}

	# Check for reference types: СправочникСсылка.Организации → CatalogRef.Организации
	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)  # includes the dot
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	# Simple name lookup (case-insensitive)
	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }

	return $typeStr
}

function Emit-ValueType {
	param([string]$typeStr, [string]$indent)

	if (-not $typeStr) { return }

	# Resolve synonyms first
	$typeStr = Resolve-TypeStr $typeStr

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string or string(N)
	if ($typeStr -match '^string(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# decimal(D,F) or decimal(D,F,nonneg)
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]
		$fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# date / dateTime
	if ($typeStr -match '^(date|dateTime)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
		}
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"
		return
	}

	# StandardPeriod
	if ($typeStr -eq "StandardPeriod") {
		X "$indent<v8:Type>v8:StandardPeriod</v8:Type>"
		return
	}

	# Reference types: CatalogRef.XXX, DocumentRef.XXX, EnumRef.XXX, etc.
	# Real DCS files use inline namespace d5p1="http://v8.1c.ru/8.1/data/enterprise/current-config"
	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.') {
		X "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return
	}

	# Fallback — assume dot-qualified types are also config references
	if ($typeStr.Contains('.')) {
		X "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return
	}

	X "$indent<v8:Type>$(Esc-Xml $typeStr)</v8:Type>"
}

# --- 5. Field shorthand parser ---

function Parse-FieldShorthand {
	param([string]$s)

	$result = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @(); appearance = @{}
	}

	# Extract @roles
	$roleMatches = [regex]::Matches($s, '@(\w+)')
	foreach ($m in $roleMatches) {
		$result.roles += $m.Groups[1].Value
	}
	$s = [regex]::Replace($s, '\s*@\w+', '')

	# Extract #restrictions
	$restrictMatches = [regex]::Matches($s, '#(\w+)')
	foreach ($m in $restrictMatches) {
		$result.restrict += $m.Groups[1].Value
	}
	$s = [regex]::Replace($s, '\s*#\w+', '')

	# Split name: type
	$s = $s.Trim()
	if ($s.Contains(':')) {
		$parts = $s -split ':', 2
		$result.dataPath = $parts[0].Trim()
		$result.type = Resolve-TypeStr ($parts[1].Trim())
	} else {
		$result.dataPath = $s
	}

	$result.field = $result.dataPath
	return $result
}

# --- 6. Total field shorthand parser ---

function Parse-TotalShorthand {
	param([string]$s)

	# "DataPath: Func" or "DataPath: Func(expr)"
	$parts = $s -split ':', 2
	$dataPath = $parts[0].Trim()
	$funcPart = $parts[1].Trim()

	if ($funcPart -match '^\w+\(') {
		# Already has expression form: Func(expr)
		return @{ dataPath = $dataPath; expression = $funcPart }
	} else {
		# Short: Func → Func(DataPath)
		return @{ dataPath = $dataPath; expression = "$funcPart($dataPath)" }
	}
}

# --- 7. Parameter shorthand parser ---

function Parse-ParamShorthand {
	param([string]$s)

	$result = @{ name = ""; type = ""; value = $null; autoDates = $false }

	# Extract @autoDates flag
	if ($s -match '@autoDates') {
		$result.autoDates = $true
		$s = $s -replace '\s*@autoDates', ''
	}

	# Extract @valueList flag
	if ($s -match '@valueList') {
		$result.valueListAllowed = $true
		$s = $s -replace '\s*@valueList', ''
	}

	# Extract @hidden flag
	if ($s -match '@hidden') {
		$result.hidden = $true
		$s = $s -replace '\s*@hidden', ''
	}

	# Split "Name: Type = Value"
	if ($s -match '^([^:]+):\s*(\S+)(\s*=\s*(.+))?$') {
		$result.name = $Matches[1].Trim()
		$result.type = Resolve-TypeStr ($Matches[2].Trim())
		if ($Matches[4]) {
			$result.value = $Matches[4].Trim()
		}
	} else {
		$result.name = $s.Trim()
	}

	return $result
}

# --- 8. Calculated field shorthand parser ---

function Parse-CalcShorthand {
	param([string]$s)

	# "DataPath = Expression"
	$idx = $s.IndexOf('=')
	if ($idx -gt 0) {
		return @{
			dataPath = $s.Substring(0, $idx).Trim()
			expression = $s.Substring($idx + 1).Trim()
		}
	}
	return @{ dataPath = $s.Trim(); expression = "" }
}

# --- 8b. DataParameter shorthand parser ---
# Formats: "Период = LastMonth @user", "Организация @off @user", "Период @user"
function Parse-DataParamShorthand {
	param([string]$s)

	$result = @{ parameter = ""; value = $null; use = $true; userSettingID = $null; viewMode = $null }

	# Extract @flags
	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@quickAccess') {
		$result.viewMode = "QuickAccess"
		$s = $s -replace '\s*@quickAccess', ''
	}
	if ($s -match '@normal') {
		$result.viewMode = "Normal"
		$s = $s -replace '\s*@normal', ''
	}

	$s = $s.Trim()

	# Split "Name = Value"
	if ($s -match '^([^=]+)=\s*(.+)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()

		# Detect StandardPeriod variants
		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		if ($periodVariants -contains $valStr) {
			$result.value = @{ variant = $valStr }
		} elseif ($valStr -match '^\d{4}-\d{2}-\d{2}T') {
			$result.value = $valStr
		} elseif ($valStr -eq "true" -or $valStr -eq "false") {
			$result.value = [bool]($valStr -eq "true")
		} else {
			$result.value = $valStr
		}
	} else {
		$result.parameter = $s
	}

	return $result
}

# --- 8c. Filter item shorthand parser ---
# Formats: "Организация = _ @off @user", "Дата >= 2024-01-01T00:00:00", "Статус filled"
function Parse-FilterShorthand {
	param([string]$s)

	$result = @{ field = ""; op = "Equal"; value = $null; use = $true; userSettingID = $null; viewMode = $null; presentation = $null }

	# Extract @flags
	if ($s -match '@user') {
		$result.userSettingID = "auto"
		$s = $s -replace '\s*@user', ''
	}
	if ($s -match '@off') {
		$result.use = $false
		$s = $s -replace '\s*@off', ''
	}
	if ($s -match '@quickAccess') {
		$result.viewMode = "QuickAccess"
		$s = $s -replace '\s*@quickAccess', ''
	}
	if ($s -match '@normal') {
		$result.viewMode = "Normal"
		$s = $s -replace '\s*@normal', ''
	}
	if ($s -match '@inaccessible') {
		$result.viewMode = "Inaccessible"
		$s = $s -replace '\s*@inaccessible', ''
	}

	$s = $s.Trim()

	# Try to match: Field op Value, or Field op (no value for filled/notFilled)
	# Operators sorted longest first to match >= before >
	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'

	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$opRaw = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }

		# Map op
		$opMap = @{
			"=" = "Equal"; "<>" = "NotEqual"; ">" = "Greater"; ">=" = "GreaterOrEqual"
			"<" = "Less"; "<=" = "LessOrEqual"; "in" = "InList"; "notIn" = "NotInList"
			"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
			"contains" = "Contains"; "notContains" = "NotContains"
			"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
			"filled" = "Filled"; "notFilled" = "NotFilled"
		}
		$mapped = $opMap[$opRaw]
		if ($mapped) { $result.op = $opRaw } else { $result.op = $opRaw }

		# Parse value (skip "_" which means empty/placeholder)
		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") {
				$result.value = [bool]($valPart -eq "true")
				$result["valueType"] = "xs:boolean"
			} elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') {
				$result.value = $valPart
				$result["valueType"] = "xs:dateTime"
			} elseif ($valPart -match '^\d+(\.\d+)?$') {
				$result.value = $valPart
				$result["valueType"] = "xs:decimal"
			} elseif ($valPart -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') {
				$result.value = $valPart
				$result["valueType"] = "dcscor:DesignTimeValue"
			} else {
				$result.value = $valPart
				$result["valueType"] = "xs:string"
			}
		}
	} else {
		# No operator found — just a field name
		$result.field = $s
	}

	return $result
}

# --- 9. Comparison type mapper ---

$script:comparisonTypes = @{
	"=" = "Equal"; "<>" = "NotEqual"
	">" = "Greater"; ">=" = "GreaterOrEqual"
	"<" = "Less"; "<=" = "LessOrEqual"
	"in" = "InList"; "notIn" = "NotInList"
	"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
	"contains" = "Contains"; "notContains" = "NotContains"
	"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
	"filled" = "Filled"; "notFilled" = "NotFilled"
}

# --- 10. Output parameter type detection ---

$script:outputParamTypes = @{
	"Заголовок" = "mltext"
	"ВыводитьЗаголовок" = "dcsset:DataCompositionTextOutputType"
	"ВыводитьПараметрыДанных" = "dcsset:DataCompositionTextOutputType"
	"ВыводитьОтбор" = "dcsset:DataCompositionTextOutputType"
	"МакетОформления" = "xs:string"
	"РасположениеПолейГруппировки" = "dcsset:DataCompositionGroupFieldsPlacement"
	"РасположениеРеквизитов" = "dcsset:DataCompositionAttributesPlacement"
	"ГоризонтальноеРасположениеОбщихИтогов" = "dcscor:DataCompositionTotalPlacement"
	"ВертикальноеРасположениеОбщихИтогов" = "dcscor:DataCompositionTotalPlacement"
}

# --- 11. Emit sections ---

# === DataSources ===
function Emit-DataSources {
	foreach ($ds in $dataSources) {
		X "`t<dataSource>"
		X "`t`t<name>$(Esc-Xml $ds.name)</name>"
		X "`t`t<dataSourceType>$(Esc-Xml $ds.type)</dataSourceType>"
		X "`t</dataSource>"
	}
}

# === Fields ===
function Emit-Field {
	param($fieldDef, [string]$indent)

	if ($fieldDef -is [string]) {
		$f = Parse-FieldShorthand $fieldDef
	} else {
		$f = @{
			dataPath = if ($fieldDef.dataPath) { "$($fieldDef.dataPath)" } elseif ($fieldDef.field) { "$($fieldDef.field)" } else { "" }
			field = if ($fieldDef.field) { "$($fieldDef.field)" } else { "$($fieldDef.dataPath)" }
			title = if ($fieldDef.title) { "$($fieldDef.title)" } else { "" }
			type = if ($fieldDef.type) { Resolve-TypeStr "$($fieldDef.type)" } else { "" }
			roles = @()
			restrict = @()
			appearance = @{}
		}
		# Parse role
		if ($fieldDef.role) {
			if ($fieldDef.role -is [string]) {
				$f.roles = @($fieldDef.role)
			} else {
				# Object form — collect truthy keys
				$roleObj = $fieldDef.role
				foreach ($prop in $roleObj.PSObject.Properties) {
					if ($prop.Value -eq $true) { $f.roles += $prop.Name }
				}
			}
		}
		# Parse restrictions
		if ($fieldDef.restrict) {
			$f.restrict = @($fieldDef.restrict)
		}
		# Parse appearance
		if ($fieldDef.appearance) {
			foreach ($prop in $fieldDef.appearance.PSObject.Properties) {
				$f.appearance[$prop.Name] = "$($prop.Value)"
			}
		}
		if ($fieldDef.presentationExpression) {
			$f["presentationExpression"] = "$($fieldDef.presentationExpression)"
		}
		# attrRestrict
		if ($fieldDef.attrRestrict) {
			$f["attrRestrict"] = @($fieldDef.attrRestrict)
		}
		# role object extras
		if ($fieldDef.role -and $fieldDef.role -isnot [string]) {
			$f["roleObj"] = $fieldDef.role
		}
	}

	X "$indent<field xsi:type=`"DataSetFieldField`">"
	X "$indent`t<dataPath>$(Esc-Xml $f.dataPath)</dataPath>"
	X "$indent`t<field>$(Esc-Xml $f.field)</field>"

	# Title
	if ($f.title) {
		Emit-MLText -tag "title" -text $f.title -indent "$indent`t"
	}

	# UseRestriction
	$restrictMap = @{
		"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
		"noGroup" = "group"; "noOrder" = "order"
	}
	if ($f.restrict.Count -gt 0) {
		X "$indent`t<useRestriction>"
		foreach ($r in $f.restrict) {
			$xmlName = $restrictMap["$r"]
			if ($xmlName) {
				X "$indent`t`t<$xmlName>true</$xmlName>"
			}
		}
		X "$indent`t</useRestriction>"
	}

	# AttributeUseRestriction
	if ($f["attrRestrict"] -and $f["attrRestrict"].Count -gt 0) {
		X "$indent`t<attributeUseRestriction>"
		foreach ($r in $f["attrRestrict"]) {
			$xmlName = $restrictMap["$r"]
			if ($xmlName) {
				X "$indent`t`t<$xmlName>true</$xmlName>"
			}
		}
		X "$indent`t</attributeUseRestriction>"
	}

	# Role
	if ($f.roles.Count -gt 0 -or $f["roleObj"]) {
		X "$indent`t<role>"
		foreach ($role in $f.roles) {
			if ($role -eq "period") {
				# @period -> periodNumber + periodType (not <dcscom:period>)
				X "$indent`t`t<dcscom:periodNumber>1</dcscom:periodNumber>"
				X "$indent`t`t<dcscom:periodType>Main</dcscom:periodType>"
			} else {
				X "$indent`t`t<dcscom:$role>true</dcscom:$role>"
			}
		}
		if ($f["roleObj"]) {
			$ro = $f["roleObj"]
			if ($ro.accountTypeExpression) {
				X "$indent`t`t<dcscom:accountTypeExpression>$(Esc-Xml "$($ro.accountTypeExpression)")</dcscom:accountTypeExpression>"
			}
			if ($ro.balanceGroup) {
				X "$indent`t`t<dcscom:balanceGroup>$(Esc-Xml "$($ro.balanceGroup)")</dcscom:balanceGroup>"
			}
		}
		X "$indent`t</role>"
	}

	# ValueType
	if ($f.type) {
		X "$indent`t<valueType>"
		Emit-ValueType -typeStr $f.type -indent "$indent`t`t"
		X "$indent`t</valueType>"
	}

	# Appearance
	if ($f.appearance -and $f.appearance.Count -gt 0) {
		X "$indent`t<appearance>"
		foreach ($key in $f.appearance.Keys) {
			$val = $f.appearance[$key]
			X "$indent`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
			X "$indent`t`t`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
			if ($key -eq "ГоризонтальноеПоложение") {
				X "$indent`t`t`t<dcscor:value xsi:type=`"v8ui:HorizontalAlign`">$(Esc-Xml $val)</dcscor:value>"
			} else {
				X "$indent`t`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $val)</dcscor:value>"
			}
			X "$indent`t`t</dcscor:item>"
		}
		X "$indent`t</appearance>"
	}

	# PresentationExpression
	if ($f["presentationExpression"]) {
		X "$indent`t<presentationExpression>$(Esc-Xml $f["presentationExpression"])</presentationExpression>"
	}

	X "$indent</field>"
}

# === DataSets ===
function Emit-DataSet {
	param($ds, [string]$indent)

	# Determine type
	if ($ds.items) {
		$dsType = "DataSetUnion"
	} elseif ($ds.objectName) {
		$dsType = "DataSetObject"
	} else {
		$dsType = "DataSetQuery"
	}

	X "$indent<dataSet xsi:type=`"$dsType`">"
	X "$indent`t<name>$(Esc-Xml "$($ds.name)")</name>"

	# Fields
	if ($ds.fields) {
		foreach ($f in $ds.fields) {
			Emit-Field -fieldDef $f -indent "$indent`t"
		}
	}

	# DataSource (not for Union)
	if ($dsType -ne "DataSetUnion") {
		$src = if ($ds.source) { "$($ds.source)" } else { $defaultSource }
		X "$indent`t<dataSource>$(Esc-Xml $src)</dataSource>"
	}

	# Type-specific content
	if ($dsType -eq "DataSetQuery") {
		$queryText = Resolve-QueryValue "$($ds.query)" $script:queryBaseDir
		X "$indent`t<query>$(Esc-Xml $queryText)</query>"
		if ($ds.autoFillFields -eq $false) {
			X "$indent`t<autoFillFields>false</autoFillFields>"
		}
	} elseif ($dsType -eq "DataSetObject") {
		X "$indent`t<objectName>$(Esc-Xml "$($ds.objectName)")</objectName>"
	} elseif ($dsType -eq "DataSetUnion") {
		foreach ($item in $ds.items) {
			# Union items are nested dataSets
			Emit-DataSet -ds $item -indent "$indent`t" | Out-Null
		}
	}

	X "$indent</dataSet>"
}

function Emit-DataSets {
	foreach ($ds in $def.dataSets) {
		Emit-DataSet -ds $ds -indent "`t"
	}
}

# === DataSetLinks ===
function Emit-DataSetLinks {
	if (-not $def.dataSetLinks) { return }
	foreach ($link in $def.dataSetLinks) {
		X "`t<dataSetLink>"
		$srcDS = if ($link.source) { "$($link.source)" } elseif ($link.sourceDataSet) { "$($link.sourceDataSet)" } else { "" }
		$dstDS = if ($link.dest) { "$($link.dest)" } elseif ($link.destinationDataSet) { "$($link.destinationDataSet)" } else { "" }
		$srcEx = if ($link.sourceExpr) { "$($link.sourceExpr)" } elseif ($link.sourceExpression) { "$($link.sourceExpression)" } else { "" }
		$dstEx = if ($link.destExpr) { "$($link.destExpr)" } elseif ($link.destinationExpression) { "$($link.destinationExpression)" } else { "" }
		X "`t`t<sourceDataSet>$(Esc-Xml $srcDS)</sourceDataSet>"
		X "`t`t<destinationDataSet>$(Esc-Xml $dstDS)</destinationDataSet>"
		X "`t`t<sourceExpression>$(Esc-Xml $srcEx)</sourceExpression>"
		X "`t`t<destinationExpression>$(Esc-Xml $dstEx)</destinationExpression>"
		if ($link.parameter) {
			X "`t`t<parameter>$(Esc-Xml "$($link.parameter)")</parameter>"
		}
		X "`t</dataSetLink>"
	}
}

# === CalculatedFields ===
function Emit-CalcFields {
	if (-not $def.calculatedFields) { return }
	foreach ($cf in $def.calculatedFields) {
		if ($cf -is [string]) {
			$parsed = Parse-CalcShorthand $cf
		} else {
			$dp = if ($cf.dataPath) { "$($cf.dataPath)" } else { "$($cf.field)" }
			$parsed = @{
				dataPath = $dp
				expression = "$($cf.expression)"
			}
		}

		X "`t<calculatedField>"
		X "`t`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
		X "`t`t<expression>$(Esc-Xml $parsed.expression)</expression>"

		if ($cf -isnot [string]) {
			if ($cf.title) {
				Emit-MLText -tag "title" -text "$($cf.title)" -indent "`t`t"
			}
			if ($cf.type) {
				$cfType = Resolve-TypeStr "$($cf.type)"
				X "`t`t<valueType>"
				Emit-ValueType -typeStr $cfType -indent "`t`t`t"
				X "`t`t</valueType>"
			}
			if ($cf.restrict) {
				$restrictMap = @{
					"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
					"noGroup" = "group"; "noOrder" = "order"
				}
				X "`t`t<useRestriction>"
				foreach ($r in $cf.restrict) {
					$xmlName = $restrictMap["$r"]
					if ($xmlName) { X "`t`t`t<$xmlName>true</$xmlName>" }
				}
				X "`t`t</useRestriction>"
			}
			if ($cf.appearance) {
				X "`t`t<appearance>"
				foreach ($prop in $cf.appearance.PSObject.Properties) {
					X "`t`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
					X "`t`t`t`t<dcscor:parameter>$(Esc-Xml $prop.Name)</dcscor:parameter>"
					X "`t`t`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($prop.Value)")</dcscor:value>"
					X "`t`t`t</dcscor:item>"
				}
				X "`t`t</appearance>"
			}
		}

		X "`t</calculatedField>"
	}
}

# === TotalFields ===
function Emit-TotalFields {
	if (-not $def.totalFields) { return }
	foreach ($tf in $def.totalFields) {
		if ($tf -is [string]) {
			$parsed = Parse-TotalShorthand $tf
		} else {
			$parsed = @{
				dataPath = "$($tf.dataPath)"
				expression = "$($tf.expression)"
			}
			if ($tf.group) { $parsed.groups = @($tf.group) }
		}

		X "`t<totalField>"
		X "`t`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
		X "`t`t<expression>$(Esc-Xml $parsed.expression)</expression>"
		if ($parsed.groups) {
			foreach ($g in $parsed.groups) {
				X "`t`t<group>$(Esc-Xml "$g")</group>"
			}
		}
		X "`t</totalField>"
	}
}

# === Parameters ===

function Emit-SingleParam {
	param($p, $parsed)

	X "`t<parameter>"
	X "`t`t<name>$(Esc-Xml $parsed.name)</name>"

	# Title
	$title = if ($p -isnot [string] -and $p.title) { "$($p.title)" } else { "" }
	if ($title) {
		Emit-MLText -tag "title" -text $title -indent "`t`t"
	}

	# ValueType
	if ($parsed.type) {
		X "`t`t<valueType>"
		Emit-ValueType -typeStr $parsed.type -indent "`t`t`t"
		X "`t`t</valueType>"
	}

	# Value
	Emit-ParamValue -type $parsed.type -val $parsed.value -indent "`t`t"

	# Hidden implies useRestriction=true + availableAsField=false
	if ($parsed.hidden -eq $true) {
		$parsed.availableAsField = $false
		$parsed.useRestriction = $true
	}

	# UseRestriction
	if ($parsed.useRestriction -eq $true -or ($p -isnot [string] -and $p.useRestriction -eq $true)) {
		X "`t`t<useRestriction>true</useRestriction>"
	}

	# Expression
	if ($parsed.expression) {
		X "`t`t<expression>$(Esc-Xml $parsed.expression)</expression>"
	}

	# AvailableAsField
	if ($parsed.availableAsField -eq $false) {
		X "`t`t<availableAsField>false</availableAsField>"
	}

	# ValueListAllowed
	if ($parsed.valueListAllowed -eq $true) {
		X "`t`t<valueListAllowed>true</valueListAllowed>"
	}

	# AvailableValues
	if ($p -isnot [string] -and $p.availableValues) {
		foreach ($av in $p.availableValues) {
			$avVal = "$($av.value)"
			$avType = "xs:string"
			if ($avVal -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') {
				$avType = "dcscor:DesignTimeValue"
			}
			X "`t`t<availableValue>"
			X "`t`t`t<value xsi:type=`"$avType`">$(Esc-Xml $avVal)</value>"
			if ($av.presentation) {
				X "`t`t`t<presentation xsi:type=`"v8:LocalStringType`">"
				X "`t`t`t`t<v8:item>"
				X "`t`t`t`t`t<v8:lang>ru</v8:lang>"
				X "`t`t`t`t`t<v8:content>$(Esc-Xml "$($av.presentation)")</v8:content>"
				X "`t`t`t`t</v8:item>"
				X "`t`t`t</presentation>"
			}
			X "`t`t</availableValue>"
		}
	}

	# DenyIncompleteValues
	if ($p -isnot [string] -and $p.denyIncompleteValues -eq $true) {
		X "`t`t<denyIncompleteValues>true</denyIncompleteValues>"
	}

	# Use
	if ($p -isnot [string] -and $p.use) {
		X "`t`t<use>$(Esc-Xml "$($p.use)")</use>"
	}

	X "`t</parameter>"
}

$script:allParams = @()

function Emit-Parameters {
	if (-not $def.parameters) { return }
	foreach ($p in $def.parameters) {
		if ($p -is [string]) {
			$parsed = Parse-ParamShorthand $p
		} else {
			$parsed = @{
				name = "$($p.name)"
				type = if ($p.type) { Resolve-TypeStr "$($p.type)" } else { "" }
				value = $p.value
				autoDates = $false
			}
			if ($p.expression) { $parsed.expression = "$($p.expression)" }
			if ($p.availableAsField -eq $false) { $parsed.availableAsField = $false }
			if ($p.valueListAllowed -eq $true) { $parsed.valueListAllowed = $true }
			if ($p.hidden -eq $true) { $parsed.hidden = $true }
			if ($p.autoDates -eq $true) { $parsed.autoDates = $true }
		}

		Emit-SingleParam -p $p -parsed $parsed

		# Track parameter for auto dataParameters
		$script:allParams += @{ name = $parsed.name; hidden = [bool]$parsed.hidden; type = "$($parsed.type)"; value = $parsed.value }

		# @autoDates: auto-generate ДатаНачала and ДатаОкончания
		if ($parsed.autoDates) {
			$paramName = $parsed.name
			$beginParsed = @{
				name = "ДатаНачала"; type = "date"; value = $null
				expression = "&$paramName.ДатаНачала"; availableAsField = $false
			}
			Emit-SingleParam -p $null -parsed $beginParsed
			$endParsed = @{
				name = "ДатаОкончания"; type = "date"; value = $null
				expression = "&$paramName.ДатаОкончания"; availableAsField = $false
			}
			Emit-SingleParam -p $null -parsed $endParsed
		}
	}
}

function Emit-ParamValue {
	param([string]$type, $val, [string]$indent)

	if ($null -eq $val) { return }

	$valStr = "$val"

	if ($type -eq "StandardPeriod") {
		# val is a period variant string like "LastMonth"
		X "$indent<value xsi:type=`"v8:StandardPeriod`">"
		X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $valStr)</v8:variant>"
		X "$indent</value>"
	} elseif ($type -match '^date') {
		X "$indent<value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -eq "boolean") {
		X "$indent<value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -match '^decimal') {
		X "$indent<value xsi:type=`"xs:decimal`">$(Esc-Xml $valStr)</value>"
	} elseif ($type -match '^string') {
		X "$indent<value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</value>"
	} else {
		# Guess from value
		if ($valStr -match '^\d{4}-\d{2}-\d{2}T') {
			X "$indent<value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</value>"
		} elseif ($valStr -eq "true" -or $valStr -eq "false") {
			X "$indent<value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</value>"
		} elseif ($valStr -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or $valStr -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
			X "$indent<value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $valStr)</value>"
		} else {
			X "$indent<value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</value>"
		}
	}
}

# === AreaTemplate DSL ===

# Built-in style presets
$script:areaStylePresets = @{
	data = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = 'style:ReportGroup1BackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	header = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = 'style:ReportHeaderBackColor'; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	subheader = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = 'Center'; vAlign = $null; wrap = $true
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
	total = @{
		font = 'Arial'; fontSize = 10; bold = $false; italic = $false
		hAlign = $null; vAlign = $null; wrap = $false
		bgColor = $null; textColor = $null
		borderColor = 'style:ReportLineColor'; borders = $true
	}
}

# Load user presets from skd-styles.json (same dir as definition or cwd)
$script:userStylesLoaded = $false
foreach ($stylesDir in @($script:queryBaseDir, (Get-Location).Path)) {
	$stylesFile = Join-Path $stylesDir "skd-styles.json"
	if (Test-Path $stylesFile) {
		$userStyles = Get-Content -Raw -Encoding UTF8 $stylesFile | ConvertFrom-Json
		foreach ($prop in $userStyles.PSObject.Properties) {
			$preset = @{}
			# Start from 'data' defaults
			foreach ($k in $script:areaStylePresets['data'].Keys) {
				$preset[$k] = $script:areaStylePresets['data'][$k]
			}
			# If overriding existing preset, start from it instead
			if ($script:areaStylePresets.ContainsKey($prop.Name)) {
				foreach ($k in $script:areaStylePresets[$prop.Name].Keys) {
					$preset[$k] = $script:areaStylePresets[$prop.Name][$k]
				}
			}
			# Apply user overrides
			foreach ($up in $prop.Value.PSObject.Properties) {
				$preset[$up.Name] = $up.Value
			}
			$script:areaStylePresets[$prop.Name] = $preset
		}
		$script:userStylesLoaded = $true
		break
	}
}

function Emit-ColorValue {
	param([string]$color, [string]$indent)
	if ($color.StartsWith('style:')) {
		$styleName = $color.Substring(6)
		X "$indent<dcscor:value xmlns:d8p1=`"http://v8.1c.ru/8.1/data/ui/style`" xsi:type=`"v8ui:Color`">d8p1:$styleName</dcscor:value>"
	} else {
		X "$indent<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $color)</dcscor:value>"
	}
}

function Emit-CellAppearance {
	param($style, [double]$width = 0, [bool]$vMerge = $false, [double]$minHeight = 0, $extraItems = @())
	$ind = "`t`t`t`t`t"
	X "`t`t`t`t<dcsat:appearance>"
	# Background color
	if ($style.bgColor) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ЦветФона</dcscor:parameter>"
		Emit-ColorValue $style.bgColor "$ind`t"
		X "$ind</dcscor:item>"
	}
	# Text color
	if ($style.textColor) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ЦветТекста</dcscor:parameter>"
		Emit-ColorValue $style.textColor "$ind`t"
		X "$ind</dcscor:item>"
	}
	# Border color + border style (4 sides)
	if ($style.borders) {
		if ($style.borderColor) {
			X "$ind<dcscor:item>"
			X "$ind`t<dcscor:parameter>ЦветГраницы</dcscor:parameter>"
			Emit-ColorValue $style.borderColor "$ind`t"
			X "$ind</dcscor:item>"
		}
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>СтильГраницы</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"0`" gap=`"false`">"
		X "$ind`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">None</v8ui:style>"
		X "$ind`t</dcscor:value>"
		foreach ($side in @('Слева','Сверху','Справа','Снизу')) {
			X "$ind`t<dcscor:item>"
			X "$ind`t`t<dcscor:parameter>СтильГраницы.$side</dcscor:parameter>"
			X "$ind`t`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"1`" gap=`"false`">"
			X "$ind`t`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
			X "$ind`t`t</dcscor:value>"
			X "$ind`t</dcscor:item>"
		}
		X "$ind</dcscor:item>"
	}
	# Font
	$boldStr = if ($style.bold) { "true" } else { "false" }
	$italicStr = if ($style.italic) { "true" } else { "false" }
	X "$ind<dcscor:item>"
	X "$ind`t<dcscor:parameter>Шрифт</dcscor:parameter>"
	X "$ind`t<dcscor:value xsi:type=`"v8ui:Font`" faceName=`"$($style.font)`" height=`"$($style.fontSize)`" bold=`"$boldStr`" italic=`"$italicStr`" underline=`"false`" strikeout=`"false`" kind=`"Absolute`" scale=`"100`"/>"
	X "$ind</dcscor:item>"
	# Horizontal alignment
	if ($style.hAlign) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ГоризонтальноеПоложение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:HorizontalAlign`">$(Esc-Xml $style.hAlign)</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Vertical alignment
	if ($style.vAlign) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ВертикальноеПоложение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"v8ui:VerticalAlign`">$(Esc-Xml $style.vAlign)</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Text placement (wrap)
	if ($style.wrap) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>Размещение</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"dcscor:DataCompositionTextPlacementType`">Wrap</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Width
	if ($width -gt 0) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МинимальнаяШирина</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$width</dcscor:value>"
		X "$ind</dcscor:item>"
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МаксимальнаяШирина</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$width</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Min height
	if ($minHeight -gt 0) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>МинимальнаяВысота</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:decimal`">$minHeight</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Vertical merge
	if ($vMerge) {
		X "$ind<dcscor:item>"
		X "$ind`t<dcscor:parameter>ОбъединятьПоВертикали</dcscor:parameter>"
		X "$ind`t<dcscor:value xsi:type=`"xs:boolean`">true</dcscor:value>"
		X "$ind</dcscor:item>"
	}
	# Extra appearance items (e.g. drilldown Расшифровка)
	foreach ($ei in $extraItems) { X $ei }
	X "`t`t`t`t</dcsat:appearance>"
}

function Emit-AreaTemplateDSL {
	param($t)
	$styleName = if ($t.style) { "$($t.style)" } else { "data" }
	if (-not $script:areaStylePresets.ContainsKey($styleName)) {
		Write-Warning "Unknown area style preset '$styleName', falling back to 'data'"
		$styleName = "data"
	}
	$style = $script:areaStylePresets[$styleName]

	$rows = @($t.rows)
	$widths = if ($t.widths) { @($t.widths) } else { @() }
	$minHeight = if ($t.minHeight) { [double]$t.minHeight } else { 0 }
	$colCount = if ($widths.Count -gt 0) { $widths.Count } else { $rows[0].Count }

	# Build merge map: vMerge[row][col] = $true if cell is merged with above
	$vMerge = @{}
	for ($r = $rows.Count - 1; $r -ge 1; $r--) {
		$vMerge[$r] = @{}
		for ($c = 0; $c -lt $colCount; $c++) {
			$cellVal = $rows[$r][$c]
			if ($cellVal -is [string] -and $cellVal -eq '|') {
				$vMerge[$r][$c] = $true
			}
		}
	}
	if (-not $vMerge.ContainsKey(0)) { $vMerge[0] = @{} }

	# Build drilldown map: param_name -> drilldown_value
	$drilldownMap = @{}
	if ($t.parameters) {
		foreach ($tp in $t.parameters) {
			if ($tp.drilldown) { $drilldownMap["$($tp.name)"] = "$($tp.drilldown)" }
		}
	}

	X "`t<template>"
	X "`t`t<name>$(Esc-Xml "$($t.name)")</name>"
	X "`t`t<template xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:AreaTemplate`">"

	for ($r = 0; $r -lt $rows.Count; $r++) {
		X "`t`t`t<dcsat:item xsi:type=`"dcsat:TableRow`">"
		for ($c = 0; $c -lt $colCount; $c++) {
			$cellVal = $rows[$r][$c]
			$w = if ($c -lt $widths.Count) { [double]$widths[$c] } else { 0 }
			$isMerged = $vMerge[$r][$c] -eq $true
			# Check if this cell starts a vertical merge (next row has "|" in same column)
			$startsVMerge = $false
			for ($nr = $r + 1; $nr -lt $rows.Count; $nr++) {
				if ($vMerge[$nr][$c] -eq $true) { $startsVMerge = $true } else { break }
			}

			X "`t`t`t`t<dcsat:tableCell>"
			if ($isMerged) {
				# Merged cell — only appearance with vMerge flag + width
				Emit-CellAppearance $style $w $true
			} else {
				# Cell value
				if ($null -ne $cellVal -and $cellVal -ne '') {
					$cellStr = "$cellVal"
					if ($cellStr -match '^\{(.+)\}$') {
						# Parameter reference
						$paramName = $Matches[1]
						X "`t`t`t`t`t<dcsat:item xsi:type=`"dcsat:Field`">"
						X "`t`t`t`t`t`t<dcsat:value xsi:type=`"dcscor:Parameter`">$(Esc-Xml $paramName)</dcsat:value>"
						X "`t`t`t`t`t</dcsat:item>"
						# Build drilldown appearance extra items
						$cellExtraItems = @()
						if ($drilldownMap.ContainsKey($paramName)) {
							$ddVal = $drilldownMap[$paramName]
							$cellExtraItems += "`t`t`t`t`t<dcscor:item>"
							$cellExtraItems += "`t`t`t`t`t`t<dcscor:parameter>Расшифровка</dcscor:parameter>"
							$cellExtraItems += "`t`t`t`t`t`t<dcscor:value xsi:type=`"dcscor:Parameter`">Расшифровка_$ddVal</dcscor:value>"
							$cellExtraItems += "`t`t`t`t`t</dcscor:item>"
						}
					} else {
						# Static text
						X "`t`t`t`t`t<dcsat:item xsi:type=`"dcsat:Field`">"
						X "`t`t`t`t`t`t<dcsat:value xsi:type=`"v8:LocalStringType`">"
						X "`t`t`t`t`t`t`t<v8:item>"
						X "`t`t`t`t`t`t`t`t<v8:lang>ru</v8:lang>"
						X "`t`t`t`t`t`t`t`t<v8:content>$(Esc-Xml $cellStr)</v8:content>"
						X "`t`t`t`t`t`t`t</v8:item>"
						X "`t`t`t`t`t`t</dcsat:value>"
						X "`t`t`t`t`t</dcsat:item>"
					}
				}
				# Appearance
				$h = if ($r -eq 0) { $minHeight } else { 0 }
				if (-not $cellExtraItems) { $cellExtraItems = @() }
				Emit-CellAppearance $style $w $startsVMerge $h $cellExtraItems
				$cellExtraItems = @()
			}
			X "`t`t`t`t</dcsat:tableCell>"
		}
		X "`t`t`t</dcsat:item>"
	}

	X "`t`t</template>"
	# Parameters (reuse existing logic)
	if ($t.parameters) {
		foreach ($tp in $t.parameters) {
			X "`t`t<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:ExpressionAreaTemplateParameter`">"
			X "`t`t`t<dcsat:name>$(Esc-Xml "$($tp.name)")</dcsat:name>"
			X "`t`t`t<dcsat:expression>$(Esc-Xml "$($tp.expression)")</dcsat:expression>"
			X "`t`t</parameter>"
			# Drilldown parameter
			if ($tp.drilldown) {
				$ddVal = "$($tp.drilldown)"
				X "`t`t<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:DetailsAreaTemplateParameter`">"
				X "`t`t`t<dcsat:name>Расшифровка_$(Esc-Xml $ddVal)</dcsat:name>"
				X "`t`t`t<dcsat:fieldExpression>"
				X "`t`t`t`t<dcsat:field>ИмяРесурса</dcsat:field>"
				X "`t`t`t`t<dcsat:expression>`"$(Esc-Xml $ddVal)`"</dcsat:expression>"
				X "`t`t`t</dcsat:fieldExpression>"
				X "`t`t`t<dcsat:mainAction>DrillDown</dcsat:mainAction>"
				X "`t`t</parameter>"
			}
		}
	}
	X "`t</template>"
}

# === Templates ===
function Emit-Templates {
	if (-not $def.templates) { return }
	foreach ($t in $def.templates) {
		if ($t.rows) {
			# Compact DSL mode
			Emit-AreaTemplateDSL $t
		} else {
			# Raw XML mode
			X "`t<template>"
			X "`t`t<name>$(Esc-Xml "$($t.name)")</name>"
			if ($t.template) {
				X "`t`t$($t.template)"
			}
			if ($t.parameters) {
				foreach ($tp in $t.parameters) {
					X "`t`t<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:ExpressionAreaTemplateParameter`">"
					X "`t`t`t<dcsat:name>$(Esc-Xml "$($tp.name)")</dcsat:name>"
					X "`t`t`t<dcsat:expression>$(Esc-Xml "$($tp.expression)")</dcsat:expression>"
					X "`t`t</parameter>"
					# Drilldown parameter
					if ($tp.drilldown) {
						$ddVal = "$($tp.drilldown)"
						X "`t`t<parameter xmlns:dcsat=`"http://v8.1c.ru/8.1/data-composition-system/area-template`" xsi:type=`"dcsat:DetailsAreaTemplateParameter`">"
						X "`t`t`t<dcsat:name>Расшифровка_$(Esc-Xml $ddVal)</dcsat:name>"
						X "`t`t`t<dcsat:fieldExpression>"
						X "`t`t`t`t<dcsat:field>ИмяРесурса</dcsat:field>"
						X "`t`t`t`t<dcsat:expression>`"$(Esc-Xml $ddVal)`"</dcsat:expression>"
						X "`t`t`t</dcsat:fieldExpression>"
						X "`t`t`t<dcsat:mainAction>DrillDown</dcsat:mainAction>"
						X "`t`t</parameter>"
					}
				}
			}
			X "`t</template>"
		}
	}
}

# === GroupTemplates ===
function Emit-GroupTemplates {
	if (-not $def.groupTemplates) { return }
	foreach ($gt in $def.groupTemplates) {
		$ttype = if ($gt.templateType) { "$($gt.templateType)" } else { "Header" }
		$isHeader = ($ttype -eq 'GroupHeader')
		$tag = if ($isHeader) { 'groupHeaderTemplate' } else { 'groupTemplate' }
		$xmlTType = if ($isHeader) { 'Header' } else { $ttype }

		X "`t<$tag>"
		if ($gt.groupName) {
			X "`t`t<groupName>$(Esc-Xml "$($gt.groupName)")</groupName>"
		} elseif ($gt.groupField) {
			X "`t`t<groupField>$(Esc-Xml "$($gt.groupField)")</groupField>"
		}
		X "`t`t<templateType>$(Esc-Xml $xmlTType)</templateType>"
		X "`t`t<template>$(Esc-Xml "$($gt.template)")</template>"
		X "`t</$tag>"
	}
}

# === Settings Variants ===

function Emit-Selection {
	param($items, [string]$indent, [switch]$skipAuto)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:selection>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			if ($item -eq "Auto") {
				if (-not $skipAuto) {
					X "$indent`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
				}
			} else {
				X "$indent`t<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
				X "$indent`t`t<dcsset:field>$(Esc-Xml $item)</dcsset:field>"
				X "$indent`t</dcsset:item>"
			}
		} else {
			X "$indent`t<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
			X "$indent`t`t<dcsset:field>$(Esc-Xml "$($item.field)")</dcsset:field>"
			if ($item.title) {
				X "$indent`t`t<dcsset:lwsTitle>"
				X "$indent`t`t`t<v8:item>"
				X "$indent`t`t`t`t<v8:lang>ru</v8:lang>"
				X "$indent`t`t`t`t<v8:content>$(Esc-Xml "$($item.title)")</v8:content>"
				X "$indent`t`t`t</v8:item>"
				X "$indent`t`t</dcsset:lwsTitle>"
			}
			X "$indent`t</dcsset:item>"
		}
	}
	X "$indent</dcsset:selection>"
}

function Emit-FilterItem {
	param($item, [string]$indent)

	if ($item.group) {
		# FilterItemGroup
		$groupType = switch ("$($item.group)") {
			"And" { "AndGroup" }
			"Or"  { "OrGroup" }
			"Not" { "NotGroup" }
			default { "$($item.group)Group" }
		}
		X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
		X "$indent`t<dcsset:groupType>$groupType</dcsset:groupType>"
		if ($item.items) {
			foreach ($sub in $item.items) {
				Emit-FilterItem -item $sub -indent "$indent`t"
			}
		}
		X "$indent</dcsset:item>"
		return
	}

	# FilterItemComparison
	X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"

	if ($item.use -eq $false) {
		X "$indent`t<dcsset:use>false</dcsset:use>"
	}

	X "$indent`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml "$($item.field)")</dcsset:left>"

	$compType = $script:comparisonTypes["$($item.op)"]
	if (-not $compType) { $compType = "$($item.op)" }
	X "$indent`t<dcsset:comparisonType>$(Esc-Xml $compType)</dcsset:comparisonType>"

	# Right value
	if ($null -ne $item.value) {
		$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
		if (-not $vt) {
			$v = $item.value
			if ($v -is [bool]) {
				$vt = "xs:boolean"
			} elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
				$vt = "xs:decimal"
			} elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') {
				$vt = "xs:dateTime"
			} else {
				$vt = "xs:string"
			}
		}
		$vStr = if ($item.value -is [bool]) { "$($item.value)".ToLower() } else { Esc-Xml "$($item.value)" }
		X "$indent`t<dcsset:right xsi:type=`"$vt`">$vStr</dcsset:right>"
	}

	if ($item.presentation) {
		X "$indent`t<dcsset:presentation xsi:type=`"v8:LocalStringType`">"
		X "$indent`t`t<v8:item>"
		X "$indent`t`t`t<v8:lang>ru</v8:lang>"
		X "$indent`t`t`t<v8:content>$(Esc-Xml "$($item.presentation)")</v8:content>"
		X "$indent`t`t</v8:item>"
		X "$indent`t</dcsset:presentation>"
	}

	if ($item.viewMode) {
		X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>"
	}

	if ($item.userSettingID) {
		$uid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	if ($item.userSettingPresentation) {
		X "$indent`t<dcsset:userSettingPresentation xsi:type=`"v8:LocalStringType`">"
		X "$indent`t`t<v8:item>"
		X "$indent`t`t`t<v8:lang>ru</v8:lang>"
		X "$indent`t`t`t<v8:content>$(Esc-Xml "$($item.userSettingPresentation)")</v8:content>"
		X "$indent`t`t</v8:item>"
		X "$indent`t</dcsset:userSettingPresentation>"
	}

	X "$indent</dcsset:item>"
}

function Emit-Filter {
	param($items, [string]$indent)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:filter>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			# Parse shorthand: "Организация = _ @off @user"
			$parsed = Parse-FilterShorthand $item
			$filterObj = New-Object PSObject
			$filterObj | Add-Member -NotePropertyName "field" -NotePropertyValue $parsed.field
			$filterObj | Add-Member -NotePropertyName "op" -NotePropertyValue $parsed.op
			if ($parsed.use -eq $false) {
				$filterObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false
			}
			if ($null -ne $parsed.value) {
				$filterObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value
			}
			if ($parsed["valueType"]) {
				$filterObj | Add-Member -NotePropertyName "valueType" -NotePropertyValue $parsed["valueType"]
			}
			if ($parsed.userSettingID) {
				$filterObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID
			}
			if ($parsed.viewMode) {
				$filterObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode
			}
			Emit-FilterItem -item $filterObj -indent "$indent`t"
		} else {
			Emit-FilterItem -item $item -indent "$indent`t"
		}
	}
	X "$indent</dcsset:filter>"
}

function Emit-Order {
	param($items, [string]$indent, [switch]$skipAuto)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:order>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			if ($item -eq "Auto") {
				if (-not $skipAuto) {
					X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
				}
			} else {
				$parts = $item -split '\s+'
				$field = $parts[0]
				$dir = "Asc"
				if ($parts.Count -gt 1 -and $parts[1] -match '^(?i)desc$') { $dir = "Desc" }
				elseif ($parts.Count -gt 1 -and $parts[1] -match '^(?i)asc$') { $dir = "Asc" }
				X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
				X "$indent`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
				X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
				X "$indent`t</dcsset:item>"
			}
		}
	}
	X "$indent</dcsset:order>"
}

function Emit-AppearanceValue {
	param([string]$key, $val, [string]$indent)

	X "$indent<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	if ($val -is [PSCustomObject] -and $val.use -ne $null -and $val.use -eq $false) {
		X "$indent`t<dcscor:use>false</dcscor:use>"
		X "$indent`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
		$actualVal = "$($val.value)"
	} else {
		X "$indent`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
		$actualVal = "$val"
	}

	# Auto-detect value type
	if ($actualVal -match '^(style|web|win):') {
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $actualVal)</dcscor:value>"
	} elseif ($actualVal -eq "true" -or $actualVal -eq "false") {
		X "$indent`t<dcscor:value xsi:type=`"xs:boolean`">$actualVal</dcscor:value>"
	} elseif ($key -eq "Текст" -or $key -eq "Заголовок" -or $key -eq "Формат") {
		X "$indent`t<dcscor:value xsi:type=`"v8:LocalStringType`">"
		X "$indent`t`t<v8:item>"
		X "$indent`t`t`t<v8:lang>ru</v8:lang>"
		X "$indent`t`t`t<v8:content>$(Esc-Xml $actualVal)</v8:content>"
		X "$indent`t`t</v8:item>"
		X "$indent`t</dcscor:value>"
	} else {
		X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $actualVal)</dcscor:value>"
	}
	X "$indent</dcscor:item>"
}

function Emit-ConditionalAppearance {
	param($items, [string]$indent)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:conditionalAppearance>"
	foreach ($ca in $items) {
		X "$indent`t<dcsset:item>"

		# Selection (which fields to apply to; empty = all)
		if ($ca.selection -and $ca.selection.Count -gt 0) {
			X "$indent`t`t<dcsset:selection>"
			foreach ($sel in $ca.selection) {
				X "$indent`t`t`t<dcsset:item>"
				X "$indent`t`t`t`t<dcsset:field>$(Esc-Xml "$sel")</dcsset:field>"
				X "$indent`t`t`t</dcsset:item>"
			}
			X "$indent`t`t</dcsset:selection>"
		} else {
			X "$indent`t`t<dcsset:selection/>"
		}

		# Filter (reuse existing Emit-Filter logic)
		if ($ca.filter) {
			Emit-Filter -items $ca.filter -indent "$indent`t`t"
		}

		# Appearance (parameter-value pairs)
		if ($ca.appearance) {
			X "$indent`t`t<dcsset:appearance>"
			foreach ($prop in $ca.appearance.PSObject.Properties) {
				Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$indent`t`t`t"
			}
			X "$indent`t`t</dcsset:appearance>"
		}

		# Presentation
		if ($ca.presentation) {
			X "$indent`t`t<dcsset:presentation xsi:type=`"xs:string`">$(Esc-Xml "$($ca.presentation)")</dcsset:presentation>"
		}

		# ViewMode
		if ($ca.viewMode) {
			X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($ca.viewMode)")</dcsset:viewMode>"
		}

		# UserSettingID
		if ($ca.userSettingID) {
			$uid = if ("$($ca.userSettingID)" -eq "auto") { New-Guid-String } else { "$($ca.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}

		X "$indent`t</dcsset:item>"
	}
	X "$indent</dcsset:conditionalAppearance>"
}

function Emit-OutputParameters {
	param($params, [string]$indent)

	if (-not $params) { return }

	X "$indent<dcsset:outputParameters>"
	foreach ($prop in $params.PSObject.Properties) {
		$key = $prop.Name
		$val = "$($prop.Value)"
		$ptype = $script:outputParamTypes[$key]
		if (-not $ptype) { $ptype = "xs:string" }

		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
		X "$indent`t`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
		if ($ptype -eq "mltext") {
			X "$indent`t`t<dcscor:value xsi:type=`"v8:LocalStringType`">"
			X "$indent`t`t`t<v8:item>"
			X "$indent`t`t`t`t<v8:lang>ru</v8:lang>"
			X "$indent`t`t`t`t<v8:content>$(Esc-Xml $val)</v8:content>"
			X "$indent`t`t`t</v8:item>"
			X "$indent`t`t</dcscor:value>"
		} else {
			X "$indent`t`t<dcscor:value xsi:type=`"$ptype`">$(Esc-Xml $val)</dcscor:value>"
		}
		X "$indent`t</dcscor:item>"
	}
	X "$indent</dcsset:outputParameters>"
}

function Emit-DataParameters {
	param($items, [string]$indent)

	if (-not $items -or $items.Count -eq 0) { return }

	X "$indent<dcsset:dataParameters>"
	foreach ($dp in $items) {
		# Support string shorthand
		if ($dp -is [string]) {
			$parsed = Parse-DataParamShorthand $dp
			$dpObj = New-Object PSObject
			$dpObj | Add-Member -NotePropertyName "parameter" -NotePropertyValue $parsed.parameter
			if ($null -ne $parsed.value) {
				$dpObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value
			}
			if ($parsed.use -eq $false) {
				$dpObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false
			}
			if ($parsed.userSettingID) {
				$dpObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID
			}
			if ($parsed.viewMode) {
				$dpObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode
			}
			$dp = $dpObj
		}

		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"

		if ($dp.use -eq $false) {
			X "$indent`t`t<dcscor:use>false</dcscor:use>"
		}

		X "$indent`t`t<dcscor:parameter>$(Esc-Xml "$($dp.parameter)")</dcscor:parameter>"

		# Value
		if ($null -ne $dp.value) {
			if ($dp.value -is [PSCustomObject] -and $dp.value.variant) {
				# StandardPeriod (object form from JSON)
				X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
				X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml "$($dp.value.variant)")</v8:variant>"
				X "$indent`t`t</dcscor:value>"
			} elseif ($dp.value -is [hashtable] -and $dp.value.variant) {
				# StandardPeriod (hashtable from shorthand parser)
				X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
				X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml "$($dp.value.variant)")</v8:variant>"
				X "$indent`t`t</dcscor:value>"
			} elseif ($dp.value -is [bool]) {
				$bv = "$($dp.value)".ToLower()
				X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml $bv)</dcscor:value>"
			} elseif ("$($dp.value)" -match '^\d{4}-\d{2}-\d{2}T') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			}
		}

		if ($dp.viewMode) {
			X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($dp.viewMode)")</dcsset:viewMode>"
		}

		if ($dp.userSettingID) {
			$uid = if ("$($dp.userSettingID)" -eq "auto") { New-Guid-String } else { "$($dp.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}

		if ($dp.userSettingPresentation) {
			X "$indent`t`t<dcsset:userSettingPresentation xsi:type=`"v8:LocalStringType`">"
			X "$indent`t`t`t<v8:item>"
			X "$indent`t`t`t`t<v8:lang>ru</v8:lang>"
			X "$indent`t`t`t`t<v8:content>$(Esc-Xml "$($dp.userSettingPresentation)")</v8:content>"
			X "$indent`t`t`t</v8:item>"
			X "$indent`t`t</dcsset:userSettingPresentation>"
		}

		X "$indent`t</dcscor:item>"
	}
	X "$indent</dcsset:dataParameters>"
}

# === Structure items (recursive) ===

function Emit-GroupItems {
	param($groupBy, [string]$indent)

	if (-not $groupBy -or $groupBy.Count -eq 0) { return }

	X "$indent<dcsset:groupItems>"
	foreach ($field in $groupBy) {
		if ($field -is [string]) {
			X "$indent`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			X "$indent`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
			X "$indent`t`t<dcsset:groupType>Items</dcsset:groupType>"
			X "$indent`t`t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>"
			X "$indent`t`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
			X "$indent`t`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
			X "$indent`t</dcsset:item>"
		} else {
			# Object form
			X "$indent`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			X "$indent`t`t<dcsset:field>$(Esc-Xml "$($field.field)")</dcsset:field>"
			$gt = if ($field.groupType) { "$($field.groupType)" } else { "Items" }
			X "$indent`t`t<dcsset:groupType>$(Esc-Xml $gt)</dcsset:groupType>"
			$pat = if ($field.periodAdditionType) { "$($field.periodAdditionType)" } else { "None" }
			X "$indent`t`t<dcsset:periodAdditionType>$(Esc-Xml $pat)</dcsset:periodAdditionType>"
			X "$indent`t`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
			X "$indent`t`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
			X "$indent`t</dcsset:item>"
		}
	}
	X "$indent</dcsset:groupItems>"
}

# Parse structure string shorthand: "Организация > Номенклатура > details"
function Parse-StructureShorthand {
	param([string]$s)

	$segments = $s -split '\s*>\s*'
	$result = @()

	# Build nested groups from right to left
	$innermost = $null
	for ($i = $segments.Count - 1; $i -ge 0; $i--) {
		$seg = $segments[$i].Trim()
		$group = New-Object PSObject
		$group | Add-Member -NotePropertyName "type" -NotePropertyValue "group"

		if ($seg -match '^(?i)(details|детали)$') {
			# Empty groupBy = detailed records
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @()
		} elseif ($seg -match '^(.+)\[(.+)\]$') {
			# Named group: "ИмяГруппы[Поле]"
			$group | Add-Member -NotePropertyName "name" -NotePropertyValue $Matches[1].Trim()
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @($Matches[2].Trim())
		} else {
			$group | Add-Member -NotePropertyName "groupBy" -NotePropertyValue @($seg)
		}

		if ($null -ne $innermost) {
			$group | Add-Member -NotePropertyName "children" -NotePropertyValue @($innermost)
		}
		$innermost = $group
	}

	if ($innermost) { $result += $innermost }
	return ,$result
}

function Emit-StructureItem {
	param($item, [string]$indent)

	$type = "$($item.type)"

	if ($type -eq "group") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		Emit-GroupItems -groupBy $item.groupBy -indent "$indent`t"

		# Default order to ["Auto"] if not specified
		$orderItems = $item.order
		if (-not $orderItems) { $orderItems = @("Auto") }
		Emit-Order -items $orderItems -indent "$indent`t"

		# Default selection to ["Auto"] if not specified
		$selItems = $item.selection
		if (-not $selItems) { $selItems = @("Auto") }
		Emit-Selection -items $selItems -indent "$indent`t"

		Emit-Filter -items $item.filter -indent "$indent`t"

		if ($item.outputParameters) {
			Emit-OutputParameters -params $item.outputParameters -indent "$indent`t"
		}

		# Nested children
		if ($item.children) {
			foreach ($child in $item.children) {
				Emit-StructureItem -item $child -indent "$indent`t"
			}
		}

		X "$indent</dcsset:item>"
	}
	elseif ($type -eq "table") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemTable`">"

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		# Columns
		if ($item.columns) {
			foreach ($col in $item.columns) {
				X "$indent`t<dcsset:column>"
				Emit-GroupItems -groupBy $col.groupBy -indent "$indent`t`t"
				$colOrder = $col.order; if (-not $colOrder) { $colOrder = @("Auto") }
				Emit-Order -items $colOrder -indent "$indent`t`t"
				$colSel = $col.selection; if (-not $colSel) { $colSel = @("Auto") }
				Emit-Selection -items $colSel -indent "$indent`t`t"
				X "$indent`t</dcsset:column>"
			}
		}

		# Rows
		if ($item.rows) {
			foreach ($row in $item.rows) {
				X "$indent`t<dcsset:row>"
				if ($row.name) {
					X "$indent`t`t<dcsset:name>$(Esc-Xml "$($row.name)")</dcsset:name>"
				}
				Emit-GroupItems -groupBy $row.groupBy -indent "$indent`t`t"
				$rowOrder = $row.order; if (-not $rowOrder) { $rowOrder = @("Auto") }
				Emit-Order -items $rowOrder -indent "$indent`t`t"
				$rowSel = $row.selection; if (-not $rowSel) { $rowSel = @("Auto") }
				Emit-Selection -items $rowSel -indent "$indent`t`t"
				X "$indent`t</dcsset:row>"
			}
		}

		X "$indent</dcsset:item>"
	}
	elseif ($type -eq "chart") {
		X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemChart`">"

		if ($item.name) {
			X "$indent`t<dcsset:name>$(Esc-Xml "$($item.name)")</dcsset:name>"
		}

		# Points
		if ($item.points) {
			X "$indent`t<dcsset:point>"
			Emit-GroupItems -groupBy $item.points.groupBy -indent "$indent`t`t"
			$ptOrder = $item.points.order; if (-not $ptOrder) { $ptOrder = @("Auto") }
			Emit-Order -items $ptOrder -indent "$indent`t`t"
			$ptSel = $item.points.selection; if (-not $ptSel) { $ptSel = @("Auto") }
			Emit-Selection -items $ptSel -indent "$indent`t`t"
			X "$indent`t</dcsset:point>"
		}

		# Series
		if ($item.series) {
			X "$indent`t<dcsset:series>"
			Emit-GroupItems -groupBy $item.series.groupBy -indent "$indent`t`t"
			$srOrder = $item.series.order; if (-not $srOrder) { $srOrder = @("Auto") }
			Emit-Order -items $srOrder -indent "$indent`t`t"
			$srSel = $item.series.selection; if (-not $srSel) { $srSel = @("Auto") }
			Emit-Selection -items $srSel -indent "$indent`t`t"
			X "$indent`t</dcsset:series>"
		}

		# Selection (chart values)
		Emit-Selection -items $item.selection -indent "$indent`t"

		if ($item.outputParameters) {
			Emit-OutputParameters -params $item.outputParameters -indent "$indent`t"
		}

		X "$indent</dcsset:item>"
	}
}

function Emit-SettingsVariants {
	$variants = $def.settingsVariants

	# Default variant if none specified
	if (-not $variants -or $variants.Count -eq 0) {
		$variants = @(@{
			name = "Основной"
			presentation = "Основной"
			settings = @{
				selection = @("Auto")
				structure = @(@{
					type = "group"
					order = @("Auto")
					selection = @("Auto")
				})
			}
		})
		# Convert to PSCustomObject-like structure
		$variants = @($variants | ForEach-Object {
			$v = New-Object PSObject
			$v | Add-Member -NotePropertyName "name" -NotePropertyValue $_.name
			$v | Add-Member -NotePropertyName "presentation" -NotePropertyValue $_.presentation
			$settingsObj = New-Object PSObject
			$settingsObj | Add-Member -NotePropertyName "selection" -NotePropertyValue $_.settings.selection
			$structItem = New-Object PSObject
			$structItem | Add-Member -NotePropertyName "type" -NotePropertyValue "group"
			$structItem | Add-Member -NotePropertyName "order" -NotePropertyValue @("Auto")
			$structItem | Add-Member -NotePropertyName "selection" -NotePropertyValue @("Auto")
			$settingsObj | Add-Member -NotePropertyName "structure" -NotePropertyValue @($structItem)
			$v | Add-Member -NotePropertyName "settings" -NotePropertyValue $settingsObj
			$v
		})
	}

	foreach ($v in $variants) {
		X "`t<settingsVariant>"
		X "`t`t<dcsset:name>$(Esc-Xml "$($v.name)")</dcsset:name>"

		$pres = if ($v.presentation) { "$($v.presentation)" } elseif ($v.title) { "$($v.title)" } else { "$($v.name)" }
		X "`t`t<dcsset:presentation xsi:type=`"v8:LocalStringType`">"
		X "`t`t`t<v8:item>"
		X "`t`t`t`t<v8:lang>ru</v8:lang>"
		X "`t`t`t`t<v8:content>$(Esc-Xml $pres)</v8:content>"
		X "`t`t`t</v8:item>"
		X "`t`t</dcsset:presentation>"

		X "`t`t<dcsset:settings xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`">"

		$s = $v.settings

		# Selection (Auto items only belong at group level, not top-level settings)
		if ($s.selection) {
			Emit-Selection -items $s.selection -indent "`t`t`t" -skipAuto
		}

		# Filter
		if ($s.filter) {
			Emit-Filter -items $s.filter -indent "`t`t`t"
		}

		# Order (Auto items only belong at group level, not top-level settings)
		if ($s.order) {
			Emit-Order -items $s.order -indent "`t`t`t" -skipAuto
		}

		# ConditionalAppearance
		if ($s.conditionalAppearance) {
			Emit-ConditionalAppearance -items $s.conditionalAppearance -indent "`t`t`t"
		}

		# OutputParameters
		if ($s.outputParameters) {
			Emit-OutputParameters -params $s.outputParameters -indent "`t`t`t"
		}

		# DataParameters
		if ($s.dataParameters -eq 'auto') {
			# Auto-generate dataParameters for all non-hidden params
			$autoDP = @()
			foreach ($ap in $script:allParams) {
				if (-not $ap.hidden) {
					$dpItem = New-Object PSObject
					$dpItem | Add-Member -NotePropertyName "parameter" -NotePropertyValue $ap.name
					$dpItem | Add-Member -NotePropertyName "use" -NotePropertyValue $false
					$dpItem | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue "auto"
					$autoDP += $dpItem
				}
			}
			if ($autoDP.Count -gt 0) {
				Emit-DataParameters -items $autoDP -indent "`t`t`t"
			}
		} elseif ($s.dataParameters) {
			Emit-DataParameters -items $s.dataParameters -indent "`t`t`t"
		}

		# Structure (supports string shorthand: "Организация > details")
		if ($s.structure) {
			$structItems = $s.structure
			if ($structItems -is [string]) {
				$structItems = Parse-StructureShorthand $structItems
			}
			foreach ($item in $structItems) {
				Emit-StructureItem -item $item -indent "`t`t`t"
			}
		}

		X "`t`t</dcsset:settings>"
		X "`t</settingsVariant>"
	}
}

# --- 12. Assemble XML ---

X "<?xml version=`"1.0`" encoding=`"UTF-8`"?>"
X "<DataCompositionSchema xmlns=`"http://v8.1c.ru/8.1/data-composition-system/schema`""
X "`t`txmlns:dcscom=`"http://v8.1c.ru/8.1/data-composition-system/common`""
X "`t`txmlns:dcscor=`"http://v8.1c.ru/8.1/data-composition-system/core`""
X "`t`txmlns:dcsset=`"http://v8.1c.ru/8.1/data-composition-system/settings`""
X "`t`txmlns:v8=`"http://v8.1c.ru/8.1/data/core`""
X "`t`txmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`""
X "`t`txmlns:xs=`"http://www.w3.org/2001/XMLSchema`""
X "`t`txmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">"

Emit-DataSources
Emit-DataSets
Emit-DataSetLinks
Emit-CalcFields
Emit-TotalFields
Emit-Parameters
Emit-Templates
Emit-GroupTemplates
Emit-SettingsVariants

X '</DataCompositionSchema>'

# --- 13. Write output ---

$parentDir = [System.IO.Path]::GetDirectoryName($OutputPath)
if ($parentDir -and -not (Test-Path $parentDir)) {
	New-Item -ItemType Directory -Force $parentDir | Out-Null
}

$content = $script:xml.ToString()
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputPath, $content, $utf8Bom)

# --- 14. Statistics ---

$dsCount = $def.dataSets.Count
$fieldCount = 0
foreach ($ds in $def.dataSets) {
	if ($ds.fields) { $fieldCount += $ds.fields.Count }
}
$calcCount = if ($def.calculatedFields) { $def.calculatedFields.Count } else { 0 }
$totalCount = if ($def.totalFields) { $def.totalFields.Count } else { 0 }
$paramCount = if ($def.parameters) { $def.parameters.Count } else { 0 }
$variantCount = if ($def.settingsVariants) { $def.settingsVariants.Count } else { 1 }
$fileSize = (Get-Item $OutputPath).Length

Write-Host "OK  $OutputPath"
Write-Host "    DataSets: $dsCount  Fields: $fieldCount  Calculated: $calcCount  Totals: $totalCount  Params: $paramCount  Variants: $variantCount"
Write-Host "    Size: $fileSize bytes"
