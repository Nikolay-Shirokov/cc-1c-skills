# skd-edit v1.1 — Atomic 1C DCS editor
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$TemplatePath,

	[Parameter(Mandatory)]
	[ValidateSet(
		"add-field","add-total","add-calculated-field","add-parameter","add-filter",
		"add-dataParameter","add-order","add-selection","add-dataSetLink",
		"add-dataSet","add-variant","add-conditionalAppearance",
		"set-query","set-outputParameter","set-structure",
		"modify-field","modify-filter","modify-dataParameter",
		"clear-selection","clear-order","clear-filter",
		"remove-field","remove-total","remove-calculated-field","remove-parameter","remove-filter")]
	[string]$Operation,

	[Parameter(Mandatory)]
	[string]$Value,

	[string]$DataSet,
	[string]$Variant,
	[switch]$NoSelection
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Resolve path ---

if (-not $TemplatePath.EndsWith(".xml")) {
	$candidate = Join-Path (Join-Path $TemplatePath "Ext") "Template.xml"
	if (Test-Path $candidate) {
		$TemplatePath = $candidate
	}
}

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

$resolvedPath = (Resolve-Path $TemplatePath).Path

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

# --- 2. Type system (copied from skd-compile) ---

$script:typeSynonyms = New-Object System.Collections.Hashtable
$script:typeSynonyms["число"] = "decimal"
$script:typeSynonyms["строка"] = "string"
$script:typeSynonyms["булево"] = "boolean"
$script:typeSynonyms["дата"] = "date"
$script:typeSynonyms["датавремя"] = "dateTime"
$script:typeSynonyms["стандартныйпериод"] = "StandardPeriod"
$script:typeSynonyms["bool"] = "boolean"
$script:typeSynonyms["str"] = "string"
$script:typeSynonyms["int"] = "decimal"
$script:typeSynonyms["integer"] = "decimal"
$script:typeSynonyms["number"] = "decimal"
$script:typeSynonyms["num"] = "decimal"
$script:typeSynonyms["справочникссылка"] = "CatalogRef"
$script:typeSynonyms["документссылка"] = "DocumentRef"
$script:typeSynonyms["перечислениессылка"] = "EnumRef"
$script:typeSynonyms["плансчетовссылка"] = "ChartOfAccountsRef"
$script:typeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"

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

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }

	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$baseName = $Matches[1].Trim()
		$params = $Matches[2]
		$resolved = $script:typeSynonyms[$baseName.ToLower()]
		if ($resolved) { return "$resolved($params)" }
		return $typeStr
	}

	if ($typeStr.Contains('.')) {
		$dotIdx = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $dotIdx)
		$suffix = $typeStr.Substring($dotIdx)
		$resolved = $script:typeSynonyms[$prefix.ToLower()]
		if ($resolved) { return "$resolved$suffix" }
		return $typeStr
	}

	$resolved = $script:typeSynonyms[$typeStr.ToLower()]
	if ($resolved) { return $resolved }
	return $typeStr
}

# --- 3. Parsers ---

function Parse-FieldShorthand {
	param([string]$s)

	$result = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @()
	}

	# Extract [Title]
	if ($s -match '\[([^\]]+)\]') {
		$result.title = $Matches[1]
		$s = $s -replace '\s*\[[^\]]+\]', ''
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

function Read-FieldProperties($fieldEl) {
	$props = @{
		dataPath = ""; field = ""; title = ""; type = ""
		roles = @(); restrict = @()
	}

	foreach ($ch in $fieldEl.ChildNodes) {
		if ($ch.NodeType -ne 'Element') { continue }
		switch ($ch.LocalName) {
			"dataPath" { $props.dataPath = $ch.InnerText.Trim() }
			"field" { $props.field = $ch.InnerText.Trim() }
			"title" {
				# Extract text from LocalStringType
				foreach ($item in $ch.ChildNodes) {
					if ($item.NodeType -eq 'Element' -and $item.LocalName -eq 'item') {
						foreach ($gc in $item.ChildNodes) {
							if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'content') {
								$props.title = $gc.InnerText.Trim()
							}
						}
					}
				}
			}
			"valueType" {
				# Read type info — store the raw element for now, we'll use type from parsed if overridden
				$typeEl = $null
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'Type') {
						$typeEl = $gc; break
					}
				}
				if ($typeEl) {
					$props["_rawTypeText"] = $typeEl.InnerText.Trim()
				}
			}
			"role" {
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element') {
						if ($gc.LocalName -eq 'periodNumber') {
							$props.roles += "period"
						} elseif ($gc.InnerText.Trim() -eq 'true') {
							$props.roles += $gc.LocalName
						}
					}
				}
			}
			"useRestriction" {
				$revMap = @{ "field" = "noField"; "condition" = "noFilter"; "group" = "noGroup"; "order" = "noOrder" }
				foreach ($gc in $ch.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.InnerText.Trim() -eq 'true') {
						$mapped = $revMap[$gc.LocalName]
						if ($mapped) { $props.restrict += $mapped }
					}
				}
			}
		}
	}
	return $props
}

function Parse-TotalShorthand {
	param([string]$s)

	$parts = $s -split ':', 2
	$dataPath = $parts[0].Trim()
	$funcPart = $parts[1].Trim()

	if ($funcPart -match '^\w+\(') {
		return @{ dataPath = $dataPath; expression = $funcPart }
	} else {
		return @{ dataPath = $dataPath; expression = "$funcPart($dataPath)" }
	}
}

function Parse-CalcShorthand {
	param([string]$s)

	$title = ""
	# Extract [Title] first
	if ($s -match '\[([^\]]+)\]') {
		$title = $Matches[1]
		$s = $s -replace '\s*\[[^\]]+\]', ''
	}

	# Support "Name: Type = Expression" and "Name = Expression"
	$eqIdx = $s.IndexOf('=')
	if ($eqIdx -gt 0) {
		$left = $s.Substring(0, $eqIdx).Trim()
		$expression = $s.Substring($eqIdx + 1).Trim()

		if ($left.Contains(':')) {
			$colonIdx = $left.IndexOf(':')
			$dataPath = $left.Substring(0, $colonIdx).Trim()
			$type = Resolve-TypeStr ($left.Substring($colonIdx + 1).Trim())
			return @{ dataPath = $dataPath; expression = $expression; type = $type; title = $title }
		}
		return @{ dataPath = $left; expression = $expression; type = ""; title = $title }
	}
	return @{ dataPath = $s.Trim(); expression = ""; type = ""; title = $title }
}

function Parse-ParamShorthand {
	param([string]$s)

	$result = @{ name = ""; type = ""; value = $null; autoDates = $false }

	if ($s -match '@autoDates') {
		$result.autoDates = $true
		$s = $s -replace '\s*@autoDates', ''
	}

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

function Parse-FilterShorthand {
	param([string]$s)

	$result = @{ field = ""; op = "Equal"; value = $null; use = $true; userSettingID = $null; viewMode = $null }

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

	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'

	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$opRaw = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }

		$opMap = @{
			"=" = "Equal"; "<>" = "NotEqual"; ">" = "Greater"; ">=" = "GreaterOrEqual"
			"<" = "Less"; "<=" = "LessOrEqual"; "in" = "InList"; "notIn" = "NotInList"
			"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
			"contains" = "Contains"; "notContains" = "NotContains"
			"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
			"filled" = "Filled"; "notFilled" = "NotFilled"
		}
		$mapped = $opMap[$opRaw]
		if ($mapped) { $result.op = $mapped } else { $result.op = $opRaw }

		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") {
				$result.value = $valPart
				$result["valueType"] = "xs:boolean"
			} elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') {
				$result.value = $valPart
				$result["valueType"] = "xs:dateTime"
			} elseif ($valPart -match '^\d+(\.\d+)?$') {
				$result.value = $valPart
				$result["valueType"] = "xs:decimal"
			} else {
				$result.value = $valPart
				$result["valueType"] = "xs:string"
			}
		}
	} else {
		$result.field = $s
	}

	return $result
}

function Parse-DataParamShorthand {
	param([string]$s)

	$result = @{ parameter = ""; value = $null; use = $true; userSettingID = $null; viewMode = $null }

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

	if ($s -match '^([^=]+)=\s*(.+)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()

		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		if ($periodVariants -contains $valStr) {
			$result.value = @{ variant = $valStr }
		} elseif ($valStr -match '^\d{4}-\d{2}-\d{2}T') {
			$result.value = $valStr
		} elseif ($valStr -eq "true" -or $valStr -eq "false") {
			$result.value = $valStr
		} else {
			$result.value = $valStr
		}
	} else {
		$result.parameter = $s
	}

	return $result
}

function Parse-OrderShorthand {
	param([string]$s)
	$s = $s.Trim()
	if ($s -eq "Auto") {
		return @{ field = "Auto"; direction = "" }
	}
	$parts = $s -split '\s+', 2
	$field = $parts[0]
	$dir = "Asc"
	if ($parts.Count -gt 1 -and $parts[1] -match '(?i)^desc$') { $dir = "Desc" }
	return @{ field = $field; direction = $dir }
}

function Parse-DataSetLinkShorthand {
	param([string]$s)

	$result = @{ source = ""; dest = ""; sourceExpr = ""; destExpr = ""; parameter = "" }

	# Extract optional [param ParamName]
	if ($s -match '\[param\s+([^\]]+)\]') {
		$result.parameter = $Matches[1].Trim()
		$s = $s -replace '\s*\[param\s+[^\]]+\]', ''
	}

	# Pattern: "Source > Dest on FieldA = FieldB"
	if ($s -match '^(.+?)\s*>\s*(.+?)\s+on\s+(.+?)\s*=\s*(.+)$') {
		$result.source = $Matches[1].Trim()
		$result.dest = $Matches[2].Trim()
		$result.sourceExpr = $Matches[3].Trim()
		$result.destExpr = $Matches[4].Trim()
	} else {
		Write-Error "Invalid dataSetLink shorthand: $s. Expected: 'Source > Dest on FieldA = FieldB [param Name]'"
		exit 1
	}

	return $result
}

function Parse-DataSetShorthand {
	param([string]$s)

	$s = $s.Trim()
	# "Name: QUERY" — split on first ": " only if prefix is a single word (no spaces)
	if ($s -match '^(\S+):\s(.+)$') {
		return @{ name = $Matches[1]; query = $Matches[2] }
	}
	return @{ name = ""; query = $s }
}

function Parse-VariantShorthand {
	param([string]$s)

	$presentation = ""
	if ($s -match '\[([^\]]+)\]') {
		$presentation = $Matches[1]
		$s = $s -replace '\s*\[[^\]]+\]', ''
	}
	$name = $s.Trim()
	if (-not $presentation) { $presentation = $name }
	return @{ name = $name; presentation = $presentation }
}

function Parse-ConditionalAppearanceShorthand {
	param([string]$s)

	$result = @{ param = ""; value = ""; filter = $null; fields = @() }

	# Extract " when ..." — condition part
	$whenIdx = $s.IndexOf(' when ')
	$forIdx = $s.IndexOf(' for ')

	# Determine boundaries
	$mainEnd = $s.Length
	if ($whenIdx -ge 0 -and $forIdx -ge 0) {
		$mainEnd = [Math]::Min($whenIdx, $forIdx)
	} elseif ($whenIdx -ge 0) {
		$mainEnd = $whenIdx
	} elseif ($forIdx -ge 0) {
		$mainEnd = $forIdx
	}

	# Parse "for" fields
	if ($forIdx -ge 0) {
		$forEnd = $s.Length
		if ($whenIdx -gt $forIdx) { $forEnd = $whenIdx }
		$forPart = $s.Substring($forIdx + 5, $forEnd - $forIdx - 5).Trim()
		$result.fields = @($forPart -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	}

	# Parse "when" filter
	if ($whenIdx -ge 0) {
		$whenEnd = $s.Length
		if ($forIdx -gt $whenIdx) { $whenEnd = $forIdx }
		$whenPart = $s.Substring($whenIdx + 6, $whenEnd - $whenIdx - 6).Trim()
		$result.filter = Parse-FilterShorthand $whenPart
	}

	# Parse main part: "Param = Value"
	$mainPart = $s.Substring(0, $mainEnd).Trim()
	$eqIdx = $mainPart.IndexOf('=')
	if ($eqIdx -gt 0) {
		$result.param = $mainPart.Substring(0, $eqIdx).Trim()
		$result.value = $mainPart.Substring($eqIdx + 1).Trim()
	} else {
		$result.param = $mainPart
	}

	return $result
}

function Parse-StructureShorthand {
	param([string]$s)

	$segments = $s -split '\s*>\s*'
	$result = @()

	$innermost = $null
	for ($i = $segments.Count - 1; $i -ge 0; $i--) {
		$seg = $segments[$i].Trim()
		$group = @{ type = "group" }

		if ($seg -match '^(?i)(details|детали)$') {
			$group["groupBy"] = @()
		} else {
			$group["groupBy"] = @($seg)
		}

		if ($null -ne $innermost) {
			$group["children"] = @($innermost)
		}
		$innermost = $group
	}

	if ($innermost) { $result += $innermost }
	return ,$result
}

function Parse-OutputParamShorthand {
	param([string]$s)
	$idx = $s.IndexOf('=')
	if ($idx -gt 0) {
		return @{
			key = $s.Substring(0, $idx).Trim()
			value = $s.Substring($idx + 1).Trim()
		}
	}
	return @{ key = $s.Trim(); value = "" }
}

# --- 4. Build-* functions (XML fragment generators) ---

function Build-ValueTypeXml {
	param([string]$typeStr, [string]$indent)

	if (-not $typeStr) { return "" }
	$typeStr = Resolve-TypeStr $typeStr
	$lines = @()

	if ($typeStr -eq "boolean") {
		$lines += "$indent<v8:Type>xs:boolean</v8:Type>"
		return $lines -join "`r`n"
	}

	if ($typeStr -match '^string(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$lines += "$indent<v8:Type>xs:string</v8:Type>"
		$lines += "$indent<v8:StringQualifiers>"
		$lines += "$indent`t<v8:Length>$len</v8:Length>"
		$lines += "$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		$lines += "$indent</v8:StringQualifiers>"
		return $lines -join "`r`n"
	}

	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]
		$fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		$lines += "$indent<v8:Type>xs:decimal</v8:Type>"
		$lines += "$indent<v8:NumberQualifiers>"
		$lines += "$indent`t<v8:Digits>$digits</v8:Digits>"
		$lines += "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		$lines += "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		$lines += "$indent</v8:NumberQualifiers>"
		return $lines -join "`r`n"
	}

	if ($typeStr -match '^(date|dateTime)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
		}
		$lines += "$indent<v8:Type>xs:dateTime</v8:Type>"
		$lines += "$indent<v8:DateQualifiers>"
		$lines += "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		$lines += "$indent</v8:DateQualifiers>"
		return $lines -join "`r`n"
	}

	if ($typeStr -eq "StandardPeriod") {
		$lines += "$indent<v8:Type>v8:StandardPeriod</v8:Type>"
		return $lines -join "`r`n"
	}

	if ($typeStr -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef)\.') {
		$lines += "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return $lines -join "`r`n"
	}

	if ($typeStr.Contains('.')) {
		$lines += "$indent<v8:Type xmlns:d5p1=`"http://v8.1c.ru/8.1/data/enterprise/current-config`">d5p1:$(Esc-Xml $typeStr)</v8:Type>"
		return $lines -join "`r`n"
	}

	$lines += "$indent<v8:Type>$(Esc-Xml $typeStr)</v8:Type>"
	return $lines -join "`r`n"
}

function Build-MLTextXml {
	param([string]$tag, [string]$text, [string]$indent)
	$lines = @()
	$lines += "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	$lines += "$indent`t<v8:item>"
	$lines += "$indent`t`t<v8:lang>ru</v8:lang>"
	$lines += "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	$lines += "$indent`t</v8:item>"
	$lines += "$indent</$tag>"
	return $lines -join "`r`n"
}

function Build-RoleXml {
	param([string[]]$roles, [string]$indent)

	if (-not $roles -or $roles.Count -eq 0) { return "" }

	$lines = @()
	$lines += "$indent<role>"
	foreach ($role in $roles) {
		if ($role -eq "period") {
			$lines += "$indent`t<dcscom:periodNumber>1</dcscom:periodNumber>"
			$lines += "$indent`t<dcscom:periodType>Main</dcscom:periodType>"
		} else {
			$lines += "$indent`t<dcscom:$role>true</dcscom:$role>"
		}
	}
	$lines += "$indent</role>"
	return $lines -join "`r`n"
}

function Build-RestrictionXml {
	param([string[]]$restrict, [string]$indent)

	if (-not $restrict -or $restrict.Count -eq 0) { return "" }

	$restrictMap = @{
		"noField" = "field"; "noFilter" = "condition"; "noCondition" = "condition"
		"noGroup" = "group"; "noOrder" = "order"
	}

	$lines = @()
	$lines += "$indent<useRestriction>"
	foreach ($r in $restrict) {
		$xmlName = $restrictMap["$r"]
		if ($xmlName) {
			$lines += "$indent`t<$xmlName>true</$xmlName>"
		}
	}
	$lines += "$indent</useRestriction>"
	return $lines -join "`r`n"
}

function Build-FieldFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<field xsi:type=`"DataSetFieldField`">"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<field>$(Esc-Xml $parsed.field)</field>"

	if ($parsed.title) {
		$lines += (Build-MLTextXml -tag "title" -text $parsed.title -indent "$i`t")
	}

	if ($parsed.restrict -and $parsed.restrict.Count -gt 0) {
		$lines += (Build-RestrictionXml -restrict $parsed.restrict -indent "$i`t")
	}

	$roleXml = Build-RoleXml -roles $parsed.roles -indent "$i`t"
	if ($roleXml) { $lines += $roleXml }

	if ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	$lines += "$i</field>"
	return $lines -join "`r`n"
}

function Build-TotalFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<totalField>"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<expression>$(Esc-Xml $parsed.expression)</expression>"
	$lines += "$i</totalField>"
	return $lines -join "`r`n"
}

function Build-CalcFieldFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<calculatedField>"
	$lines += "$i`t<dataPath>$(Esc-Xml $parsed.dataPath)</dataPath>"
	$lines += "$i`t<expression>$(Esc-Xml $parsed.expression)</expression>"

	if ($parsed.title) {
		$lines += (Build-MLTextXml -tag "title" -text $parsed.title -indent "$i`t")
	}

	if ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	$lines += "$i</calculatedField>"
	return $lines -join "`r`n"
}

function Build-ParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$fragments = @()

	$lines = @()
	$lines += "$i<parameter>"
	$lines += "$i`t<name>$(Esc-Xml $parsed.name)</name>"

	if ($parsed.type) {
		$lines += "$i`t<valueType>"
		$lines += (Build-ValueTypeXml -typeStr $parsed.type -indent "$i`t`t")
		$lines += "$i`t</valueType>"
	}

	if ($null -ne $parsed.value) {
		$valStr = "$($parsed.value)"
		if ($parsed.type -eq "StandardPeriod") {
			$lines += "$i`t<value xsi:type=`"v8:StandardPeriod`">"
			$lines += "$i`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $valStr)</v8:variant>"
			$lines += "$i`t</value>"
		} elseif ($parsed.type -match '^date') {
			$lines += "$i`t<value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</value>"
		} elseif ($parsed.type -eq "boolean") {
			$lines += "$i`t<value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</value>"
		} elseif ($parsed.type -match '^decimal') {
			$lines += "$i`t<value xsi:type=`"xs:decimal`">$(Esc-Xml $valStr)</value>"
		} else {
			$lines += "$i`t<value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</value>"
		}
	}

	$lines += "$i</parameter>"
	$fragments += ($lines -join "`r`n")

	if ($parsed.autoDates) {
		$paramName = $parsed.name

		$bLines = @()
		$bLines += "$i<parameter>"
		$bLines += "$i`t<name>ДатаНачала</name>"
		$bLines += "$i`t<valueType>"
		$bLines += (Build-ValueTypeXml -typeStr "date" -indent "$i`t`t")
		$bLines += "$i`t</valueType>"
		$bLines += "$i`t<expression>$(Esc-Xml "&$paramName.ДатаНачала")</expression>"
		$bLines += "$i`t<availableAsField>false</availableAsField>"
		$bLines += "$i</parameter>"
		$fragments += ($bLines -join "`r`n")

		$eLines = @()
		$eLines += "$i<parameter>"
		$eLines += "$i`t<name>ДатаОкончания</name>"
		$eLines += "$i`t<valueType>"
		$eLines += (Build-ValueTypeXml -typeStr "date" -indent "$i`t`t")
		$eLines += "$i`t</valueType>"
		$eLines += "$i`t<expression>$(Esc-Xml "&$paramName.ДатаОкончания")</expression>"
		$eLines += "$i`t<availableAsField>false</availableAsField>"
		$eLines += "$i</parameter>"
		$fragments += ($eLines -join "`r`n")
	}

	return ,$fragments
}

function Build-FilterItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"

	if ($parsed.use -eq $false) {
		$lines += "$i`t<dcsset:use>false</dcsset:use>"
	}

	$lines += "$i`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml $parsed.field)</dcsset:left>"
	$lines += "$i`t<dcsset:comparisonType>$(Esc-Xml $parsed.op)</dcsset:comparisonType>"

	if ($null -ne $parsed.value) {
		$vt = if ($parsed["valueType"]) { $parsed["valueType"] } else { "xs:string" }
		$lines += "$i`t<dcsset:right xsi:type=`"$vt`">$(Esc-Xml "$($parsed.value)")</dcsset:right>"
	}

	if ($parsed.viewMode) {
		$lines += "$i`t<dcsset:viewMode>$(Esc-Xml $parsed.viewMode)</dcsset:viewMode>"
	}

	if ($parsed.userSettingID) {
		$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
		$lines += "$i`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	$lines += "$i</dcsset:item>"
	return $lines -join "`r`n"
}

function Build-SelectionItemFragment {
	param([string]$fieldName, [string]$indent)

	$i = $indent
	$lines = @()
	if ($fieldName -eq "Auto") {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	} else {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:SelectedItemField`">"
		$lines += "$i`t<dcsset:field>$(Esc-Xml $fieldName)</dcsset:field>"
		$lines += "$i</dcsset:item>"
	}
	return $lines -join "`r`n"
}

function Build-DataParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"

	if ($parsed.use -eq $false) {
		$lines += "$i`t<dcscor:use>false</dcscor:use>"
	}

	$lines += "$i`t<dcscor:parameter>$(Esc-Xml $parsed.parameter)</dcscor:parameter>"

	if ($null -ne $parsed.value) {
		if ($parsed.value -is [hashtable] -and $parsed.value.variant) {
			$lines += "$i`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
			$lines += "$i`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $parsed.value.variant)</v8:variant>"
			$lines += "$i`t</dcscor:value>"
		} elseif ("$($parsed.value)" -match '^\d{4}-\d{2}-\d{2}T') {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		} elseif ("$($parsed.value)" -eq "true" -or "$($parsed.value)" -eq "false") {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		} else {
			$lines += "$i`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
		}
	}

	if ($parsed.viewMode) {
		$lines += "$i`t<dcsset:viewMode>$(Esc-Xml $parsed.viewMode)</dcsset:viewMode>"
	}

	if ($parsed.userSettingID) {
		$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
		$lines += "$i`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}

	$lines += "$i</dcscor:item>"
	return $lines -join "`r`n"
}

function Build-OrderItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	if ($parsed.field -eq "Auto") {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	} else {
		$lines += "$i<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
		$lines += "$i`t<dcsset:field>$(Esc-Xml $parsed.field)</dcsset:field>"
		$lines += "$i`t<dcsset:orderType>$($parsed.direction)</dcsset:orderType>"
		$lines += "$i</dcsset:item>"
	}
	return $lines -join "`r`n"
}

function Build-DataSetLinkFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dataSetLink>"
	$lines += "$i`t<sourceDataSet>$(Esc-Xml $parsed.source)</sourceDataSet>"
	$lines += "$i`t<destinationDataSet>$(Esc-Xml $parsed.dest)</destinationDataSet>"
	$lines += "$i`t<sourceExpression>$(Esc-Xml $parsed.sourceExpr)</sourceExpression>"
	$lines += "$i`t<destinationExpression>$(Esc-Xml $parsed.destExpr)</destinationExpression>"
	if ($parsed.parameter) {
		$lines += "$i`t<parameter>$(Esc-Xml $parsed.parameter)</parameter>"
	}
	$lines += "$i</dataSetLink>"
	return $lines -join "`r`n"
}

function Build-DataSetQueryFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dataSet xsi:type=`"DataSetQuery`">"
	$lines += "$i`t<name>$(Esc-Xml $parsed.name)</name>"
	$lines += "$i`t<dataSource>$(Esc-Xml $parsed.dataSource)</dataSource>"
	$lines += "$i`t<query>$(Esc-Xml $parsed.query)</query>"
	$lines += "$i</dataSet>"
	return $lines -join "`r`n"
}

function Build-VariantFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<settingsVariant>"
	$lines += "$i`t<dcsset:name>$(Esc-Xml $parsed.name)</dcsset:name>"
	$lines += (Build-MLTextXml -tag "dcsset:presentation" -text $parsed.presentation -indent "$i`t")
	$lines += "$i`t<dcsset:settings xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`">"
	$lines += "$i`t`t<dcsset:selection>"
	$lines += "$i`t`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t`t</dcsset:selection>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"
	$lines += "$i`t`t`t<dcsset:groupItems/>"
	$lines += "$i`t`t`t<dcsset:order>"
	$lines += "$i`t`t`t`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	$lines += "$i`t`t`t</dcsset:order>"
	$lines += "$i`t`t`t<dcsset:selection>"
	$lines += "$i`t`t`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t`t`t</dcsset:selection>"
	$lines += "$i`t`t</dcsset:item>"
	$lines += "$i`t</dcsset:settings>"
	$lines += "$i</settingsVariant>"
	return $lines -join "`r`n"
}

function Build-ConditionalAppearanceItemFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item>"

	# selection
	if ($parsed.fields -and $parsed.fields.Count -gt 0) {
		$lines += "$i`t<dcsset:selection>"
		foreach ($fld in $parsed.fields) {
			$lines += "$i`t`t<dcsset:item>"
			$lines += "$i`t`t`t<dcsset:field>$(Esc-Xml $fld)</dcsset:field>"
			$lines += "$i`t`t</dcsset:item>"
		}
		$lines += "$i`t</dcsset:selection>"
	} else {
		$lines += "$i`t<dcsset:selection/>"
	}

	# filter
	if ($parsed.filter) {
		$lines += "$i`t<dcsset:filter>"
		$f = $parsed.filter
		$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"
		$lines += "$i`t`t`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml $f.field)</dcsset:left>"
		$lines += "$i`t`t`t<dcsset:comparisonType>$(Esc-Xml $f.op)</dcsset:comparisonType>"
		if ($null -ne $f.value) {
			$vt = if ($f["valueType"]) { $f["valueType"] } else { "xs:string" }
			$lines += "$i`t`t`t<dcsset:right xsi:type=`"$vt`">$(Esc-Xml "$($f.value)")</dcsset:right>"
		}
		$lines += "$i`t`t</dcsset:item>"
		$lines += "$i`t</dcsset:filter>"
	} else {
		$lines += "$i`t<dcsset:filter/>"
	}

	# appearance
	$lines += "$i`t<dcsset:appearance>"

	# Auto-detect value type
	$val = $parsed.value
	$valType = "xs:string"
	if ($val -match '^(web|style|win):') {
		$valType = "v8ui:Color"
	} elseif ($val -eq "true" -or $val -eq "false") {
		$valType = "xs:boolean"
	}

	$lines += "$i`t`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	$lines += "$i`t`t`t<dcscor:parameter>$(Esc-Xml $parsed.param)</dcscor:parameter>"
	$lines += "$i`t`t`t<dcscor:value xsi:type=`"$valType`">$(Esc-Xml $val)</dcscor:value>"
	$lines += "$i`t`t</dcscor:item>"
	$lines += "$i`t</dcsset:appearance>"

	$lines += "$i</dcsset:item>"
	return $lines -join "`r`n"
}

function Build-StructureItemFragment {
	param($item, [string]$indent)

	$i = $indent
	$lines = @()
	$lines += "$i<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"

	# groupItems
	$groupBy = $item["groupBy"]
	if (-not $groupBy -or $groupBy.Count -eq 0) {
		$lines += "$i`t<dcsset:groupItems/>"
	} else {
		$lines += "$i`t<dcsset:groupItems>"
		foreach ($field in $groupBy) {
			$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
			$lines += "$i`t`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
			$lines += "$i`t`t`t<dcsset:groupType>Items</dcsset:groupType>"
			$lines += "$i`t`t`t<dcsset:periodAdditionType>None</dcsset:periodAdditionType>"
			$lines += "$i`t`t`t<dcsset:periodAdditionBegin xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionBegin>"
			$lines += "$i`t`t`t<dcsset:periodAdditionEnd xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</dcsset:periodAdditionEnd>"
			$lines += "$i`t`t</dcsset:item>"
		}
		$lines += "$i`t</dcsset:groupItems>"
	}

	# order (Auto)
	$lines += "$i`t<dcsset:order>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>"
	$lines += "$i`t</dcsset:order>"

	# selection (Auto)
	$lines += "$i`t<dcsset:selection>"
	$lines += "$i`t`t<dcsset:item xsi:type=`"dcsset:SelectedItemAuto`"/>"
	$lines += "$i`t</dcsset:selection>"

	# Recursive children
	if ($item["children"]) {
		foreach ($child in $item["children"]) {
			$childXml = Build-StructureItemFragment -item $child -indent "$i`t"
			$lines += $childXml
		}
	}

	$lines += "$i</dcsset:item>"
	return $lines -join "`r`n"
}

function Build-OutputParamFragment {
	param($parsed, [string]$indent)

	$i = $indent
	$key = $parsed.key
	$val = $parsed.value
	$ptype = $script:outputParamTypes[$key]
	if (-not $ptype) { $ptype = "xs:string" }

	$lines = @()
	$lines += "$i<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	$lines += "$i`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"

	if ($ptype -eq "mltext") {
		$lines += "$i`t<dcscor:value xsi:type=`"v8:LocalStringType`">"
		$lines += "$i`t`t<v8:item>"
		$lines += "$i`t`t`t<v8:lang>ru</v8:lang>"
		$lines += "$i`t`t`t<v8:content>$(Esc-Xml $val)</v8:content>"
		$lines += "$i`t`t</v8:item>"
		$lines += "$i`t</dcscor:value>"
	} else {
		$lines += "$i`t<dcscor:value xsi:type=`"$ptype`">$(Esc-Xml $val)</dcscor:value>"
	}

	$lines += "$i</dcscor:item>"
	return $lines -join "`r`n"
}

# --- 5. XML helpers ---

function Import-Fragment($doc, [string]$xmlString) {
	$wrapper = @"
<_W xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:v8="http://v8.1c.ru/8.1/data/core"
    xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
    xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
    xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
    xmlns:v8ui="http://v8.1c.ru/8.1/data/ui">$xmlString</_W>
"@
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$nodes = @()
	foreach ($child in $frag.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $doc.ImportNode($child, $true)
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
	$depth = 0
	$current = $container
	while ($current -and $current -ne $xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	$ws = $xmlDoc.CreateWhitespace("`r`n$childIndent")
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
			$closeWs = $xmlDoc.CreateWhitespace("`r`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Clear-ContainerChildren($container) {
	$toRemove = @()
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$toRemove += $child
		}
	}
	foreach ($el in $toRemove) {
		Remove-NodeWithWhitespace $el
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

function Find-FirstElement($container, [string[]]$localNames, [string]$nsUri) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			foreach ($name in $localNames) {
				if ($child.LocalName -eq $name) {
					if (-not $nsUri -or $child.NamespaceURI -eq $nsUri) {
						return $child
					}
				}
			}
		}
	}
	return $null
}

function Find-LastElement($container, [string]$localName, [string]$nsUri) {
	$last = $null
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $localName) {
			if (-not $nsUri -or $child.NamespaceURI -eq $nsUri) {
				$last = $child
			}
		}
	}
	return $last
}

function Find-ElementByChildValue($container, [string]$elemName, [string]$childName, [string]$childValue, [string]$nsUri) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -ne $elemName) { continue }
		if ($nsUri -and $child.NamespaceURI -ne $nsUri) { continue }

		foreach ($gc in $child.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq $childName -and $gc.InnerText.Trim() -eq $childValue) {
				return $child
			}
		}
	}
	return $null
}

function Set-OrCreateChildElement($parent, [string]$localName, [string]$nsUri, [string]$value, [string]$indent) {
	$existing = $null
	foreach ($ch in $parent.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $localName -and $ch.NamespaceURI -eq $nsUri) {
			$existing = $ch
			break
		}
	}
	if ($existing) {
		$existing.InnerText = $value
	} else {
		$prefix = $parent.GetPrefixOfNamespace($nsUri)
		$qualName = if ($prefix) { "${prefix}:$localName" } else { $localName }
		$fragXml = "$indent<$qualName>$(Esc-Xml $value)</$qualName>"
		$nodes = Import-Fragment $xmlDoc $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $parent $node $null $indent
		}
	}
}

function Set-OrCreateChildElementWithAttr($parent, [string]$localName, [string]$nsUri, [string]$value, [string]$xsiType, [string]$indent) {
	$existing = $null
	foreach ($ch in $parent.ChildNodes) {
		if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq $localName -and $ch.NamespaceURI -eq $nsUri) {
			$existing = $ch
			break
		}
	}
	if ($existing) {
		$existing.InnerText = $value
		if ($xsiType) {
			$existing.SetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance", $xsiType) | Out-Null
		}
	} else {
		$prefix = $parent.GetPrefixOfNamespace($nsUri)
		$qualName = if ($prefix) { "${prefix}:$localName" } else { $localName }
		$typeAttr = if ($xsiType) { " xsi:type=`"$xsiType`"" } else { "" }
		$fragXml = "$indent<$qualName$typeAttr>$(Esc-Xml $value)</$qualName>"
		$nodes = Import-Fragment $xmlDoc $fragXml
		foreach ($node in $nodes) {
			Insert-BeforeElement $parent $node $null $indent
		}
	}
}

function Resolve-DataSet {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$root = $xmlDoc.DocumentElement

	if ($DataSet) {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'dataSet' -and $child.NamespaceURI -eq $schNs) {
				$nameEl = $null
				foreach ($gc in $child.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
						$nameEl = $gc
						break
					}
				}
				if ($nameEl -and $nameEl.InnerText -eq $DataSet) {
					return $child
				}
			}
		}
		Write-Error "DataSet '$DataSet' not found"
		exit 1
	}

	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'dataSet' -and $child.NamespaceURI -eq $schNs) {
			return $child
		}
	}
	Write-Error "No dataSet found in DCS"
	exit 1
}

function Resolve-VariantSettings {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
	$root = $xmlDoc.DocumentElement

	$sv = $null
	if ($Variant) {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
				$nameEl = $null
				foreach ($gc in $child.ChildNodes) {
					if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs) {
						$nameEl = $gc
						break
					}
				}
				if ($nameEl -and $nameEl.InnerText -eq $Variant) {
					$sv = $child
					break
				}
			}
		}
		if (-not $sv) {
			Write-Error "Variant '$Variant' not found"
			exit 1
		}
	} else {
		foreach ($child in $root.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
				$sv = $child
				break
			}
		}
		if (-not $sv) {
			Write-Error "No settingsVariant found in DCS"
			exit 1
		}
	}

	foreach ($gc in $sv.ChildNodes) {
		if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'settings' -and $gc.NamespaceURI -eq $setNs) {
			return $gc
		}
	}

	Write-Error "No <dcsset:settings> found in variant"
	exit 1
}

function Ensure-SettingsChild($settings, [string]$childName, [string[]]$afterSiblings) {
	$el = Find-FirstElement $settings @($childName) $setNs
	if ($el) { return $el }

	$indent = Get-ChildIndent $settings
	$fragXml = "$indent<dcsset:$childName/>"
	$nodes = Import-Fragment $xmlDoc $fragXml

	$refNode = $null
	foreach ($sibName in $afterSiblings) {
		$sib = Find-FirstElement $settings @($sibName) $setNs
		if ($sib) {
			$refNode = $sib.NextSibling
			while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
				$refNode = $refNode.NextSibling
			}
			break
		}
	}

	foreach ($node in $nodes) {
		Insert-BeforeElement $settings $node $refNode $indent
	}

	return Find-FirstElement $settings @($childName) $setNs
}

function Get-VariantName {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
	$root = $xmlDoc.DocumentElement

	if ($Variant) { return $Variant }

	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq 'settingsVariant' -and $child.NamespaceURI -eq $schNs) {
			foreach ($gc in $child.ChildNodes) {
				if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs) {
					return $gc.InnerText
				}
			}
		}
	}
	return "(unknown)"
}

function Get-DataSetName($dsNode) {
	$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
	foreach ($gc in $dsNode.ChildNodes) {
		if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $schNs) {
			return $gc.InnerText
		}
	}
	return "(unknown)"
}

function Get-ContainerChildIndent($container) {
	$hasElements = $false
	foreach ($ch in $container.ChildNodes) {
		if ($ch.NodeType -eq 'Element') { $hasElements = $true; break }
	}
	if ($hasElements) {
		return Get-ChildIndent $container
	} else {
		$parentIndent = Get-ChildIndent $container.ParentNode
		return $parentIndent + "`t"
	}
}

# --- 6. Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($resolvedPath)

$schNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
$setNs = "http://v8.1c.ru/8.1/data-composition-system/settings"
$corNs = "http://v8.1c.ru/8.1/data-composition-system/core"

# --- 7. Batch value splitting ---

if ($Operation -eq "set-query" -or $Operation -eq "set-structure" -or $Operation -eq "add-dataSet") {
	$values = @($Value)
} else {
	$values = @($Value -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- 8. Main logic ---

switch ($Operation) {
	"add-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$parsed = Parse-FieldShorthand $val
			$childIndent = Get-ChildIndent $dsNode

			# Duplicate check
			$existing = Find-ElementByChildValue $dsNode "field" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] Field `"$($parsed.dataPath)`" already exists in dataset `"$dsName`" — skipped"
				continue
			}

			$fragXml = Build-FieldFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$refNode = Find-FirstElement $dsNode @("dataSource") $schNs
			foreach ($node in $nodes) {
				Insert-BeforeElement $dsNode $node $refNode $childIndent
			}

			Write-Host "[OK] Field `"$($parsed.dataPath)`" added to dataset `"$dsName`""

			if (-not $NoSelection) {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Ensure-SettingsChild $settings "selection" @()
				$existingSel = Find-ElementByChildValue $selection "item" "field" $parsed.dataPath $setNs
				if ($existingSel) {
					Write-Host "[INFO] Field `"$($parsed.dataPath)`" already in selection — skipped"
				} else {
					$selIndent = Get-ContainerChildIndent $selection
					$selXml = Build-SelectionItemFragment -fieldName $parsed.dataPath -indent $selIndent
					$selNodes = Import-Fragment $xmlDoc $selXml
					foreach ($node in $selNodes) {
						Insert-BeforeElement $selection $node $null $selIndent
					}
					Write-Host "[OK] Field `"$($parsed.dataPath)`" added to selection of variant `"$varName`""
				}
			}
		}
	}

	"add-total" {
		foreach ($val in $values) {
			$parsed = Parse-TotalShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "totalField" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] TotalField `"$($parsed.dataPath)`" already exists — skipped"
				continue
			}

			$fragXml = Build-TotalFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$root = $xmlDoc.DocumentElement
			$lastTotal = Find-LastElement $root "totalField" $schNs
			if ($lastTotal) {
				$refNode = $lastTotal.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			Write-Host "[OK] TotalField `"$($parsed.dataPath)`" = $($parsed.expression) added"
		}
	}

	"add-calculated-field" {
		foreach ($val in $values) {
			$parsed = Parse-CalcShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "calculatedField" "dataPath" $parsed.dataPath $schNs
			if ($existing) {
				Write-Host "[WARN] CalculatedField `"$($parsed.dataPath)`" already exists — skipped"
				continue
			}

			$fragXml = Build-CalcFieldFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			$root = $xmlDoc.DocumentElement
			$lastCalc = Find-LastElement $root "calculatedField" $schNs
			if ($lastCalc) {
				$refNode = $lastCalc.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			Write-Host "[OK] CalculatedField `"$($parsed.dataPath)`" = $($parsed.expression) added"

			if (-not $NoSelection) {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Ensure-SettingsChild $settings "selection" @()
				$existingSel = Find-ElementByChildValue $selection "item" "field" $parsed.dataPath $setNs
				if ($existingSel) {
					Write-Host "[INFO] Field `"$($parsed.dataPath)`" already in selection — skipped"
				} else {
					$selIndent = Get-ContainerChildIndent $selection
					$selXml = Build-SelectionItemFragment -fieldName $parsed.dataPath -indent $selIndent
					$selNodes = Import-Fragment $xmlDoc $selXml
					foreach ($node in $selNodes) {
						Insert-BeforeElement $selection $node $null $selIndent
					}
					Write-Host "[OK] Field `"$($parsed.dataPath)`" added to selection of variant `"$varName`""
				}
			}
		}
	}

	"add-parameter" {
		foreach ($val in $values) {
			$parsed = Parse-ParamShorthand $val
			$childIndent = Get-ChildIndent $xmlDoc.DocumentElement

			# Duplicate check
			$existing = Find-ElementByChildValue $xmlDoc.DocumentElement "parameter" "name" $parsed.name $schNs
			if ($existing) {
				Write-Host "[WARN] Parameter `"$($parsed.name)`" already exists — skipped"
				continue
			}

			$fragments = Build-ParamFragment -parsed $parsed -indent $childIndent

			$root = $xmlDoc.DocumentElement
			$lastParam = Find-LastElement $root "parameter" $schNs
			if ($lastParam) {
				$refNode = $lastParam.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($fragXml in $fragments) {
				$nodes = Import-Fragment $xmlDoc $fragXml
				foreach ($node in $nodes) {
					Insert-BeforeElement $root $node $refNode $childIndent
				}
			}

			Write-Host "[OK] Parameter `"$($parsed.name)`" added"
			if ($parsed.autoDates) {
				Write-Host "[OK] Auto-parameters `"ДатаНачала`", `"ДатаОкончания`" added"
			}
		}
	}

	"add-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-FilterShorthand $val

			$filterEl = Ensure-SettingsChild $settings "filter" @("selection")
			$filterIndent = Get-ContainerChildIndent $filterEl

			$fragXml = Build-FilterItemFragment -parsed $parsed -indent $filterIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $filterEl $node $null $filterIndent
			}

			Write-Host "[OK] Filter `"$($parsed.field) $($parsed.op)`" added to variant `"$varName`""
		}
	}

	"add-dataParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-DataParamShorthand $val

			$dpEl = Ensure-SettingsChild $settings "dataParameters" @("outputParameters","conditionalAppearance","order","filter","selection")
			$dpIndent = Get-ContainerChildIndent $dpEl

			$fragXml = Build-DataParamFragment -parsed $parsed -indent $dpIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $dpEl $node $null $dpIndent
			}

			Write-Host "[OK] DataParameter `"$($parsed.parameter)`" added to variant `"$varName`""
		}
	}

	"add-order" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-OrderShorthand $val

			$orderEl = Ensure-SettingsChild $settings "order" @("filter","selection")
			$orderIndent = Get-ContainerChildIndent $orderEl

			# Duplicate check
			if ($parsed.field -eq "Auto") {
				$isDup = $false
				foreach ($ch in $orderEl.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'item') {
						$typeAttr = $ch.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
						if ($typeAttr -and $typeAttr.Contains("OrderItemAuto")) { $isDup = $true; break }
					}
				}
				if ($isDup) {
					Write-Host "[WARN] OrderItemAuto already exists in variant `"$varName`" — skipped"
					continue
				}
			} else {
				$existingOrd = Find-ElementByChildValue $orderEl "item" "field" $parsed.field $setNs
				if ($existingOrd) {
					Write-Host "[WARN] Order `"$($parsed.field)`" already exists in variant `"$varName`" — skipped"
					continue
				}
			}

			$fragXml = Build-OrderItemFragment -parsed $parsed -indent $orderIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $orderEl $node $null $orderIndent
			}

			$desc = if ($parsed.field -eq "Auto") { "Auto" } else { "$($parsed.field) $($parsed.direction)" }
			Write-Host "[OK] Order `"$desc`" added to variant `"$varName`""
		}
	}

	"add-selection" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$fieldName = $val.Trim()

			$selection = Ensure-SettingsChild $settings "selection" @()
			$selIndent = Get-ContainerChildIndent $selection

			$selXml = Build-SelectionItemFragment -fieldName $fieldName -indent $selIndent
			$selNodes = Import-Fragment $xmlDoc $selXml
			foreach ($node in $selNodes) {
				Insert-BeforeElement $selection $node $null $selIndent
			}

			Write-Host "[OK] Selection `"$fieldName`" added to variant `"$varName`""
		}
	}

	"set-query" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		$queryEl = Find-FirstElement $dsNode @("query") $schNs
		if (-not $queryEl) {
			Write-Error "No <query> element found in dataset '$dsName'"
			exit 1
		}

		# InnerText setter handles XML escaping automatically
		$queryEl.InnerText = $Value

		Write-Host "[OK] Query replaced in dataset `"$dsName`""
	}

	"set-outputParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-OutputParamShorthand $val

			$outputEl = Ensure-SettingsChild $settings "outputParameters" @("conditionalAppearance","order","filter","selection")
			$outputIndent = Get-ContainerChildIndent $outputEl

			# Remove existing parameter with same key if present
			$existingParam = Find-ElementByChildValue $outputEl "item" "parameter" $parsed.key $corNs
			if ($existingParam) {
				Remove-NodeWithWhitespace $existingParam
				Write-Host "[OK] Replaced outputParameter `"$($parsed.key)`" in variant `"$varName`""
			} else {
				Write-Host "[OK] OutputParameter `"$($parsed.key)`" added to variant `"$varName`""
			}

			$fragXml = Build-OutputParamFragment -parsed $parsed -indent $outputIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $outputEl $node $null $outputIndent
			}
		}
	}

	"set-structure" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		# Remove all existing structure items (dcsset:item elements)
		$toRemove = @()
		foreach ($ch in $settings.ChildNodes) {
			if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'item' -and $ch.NamespaceURI -eq $setNs) {
				$toRemove += $ch
			}
		}
		foreach ($el in $toRemove) {
			Remove-NodeWithWhitespace $el
		}

		# Parse structure shorthand
		$structItems = Parse-StructureShorthand $Value
		$settingsIndent = Get-ChildIndent $settings

		# Find insertion point — before outputParameters/dataParameters/conditionalAppearance/order/filter/selection or at end
		$refNode = Find-FirstElement $settings @("outputParameters","dataParameters","conditionalAppearance","order","filter","selection","item") $setNs
		if (-not $refNode) { $refNode = $null }

		foreach ($structItem in $structItems) {
			$fragXml = Build-StructureItemFragment -item $structItem -indent $settingsIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $settings $node $refNode $settingsIndent
			}
		}

		Write-Host "[OK] Structure set in variant `"$varName`": $Value"
	}

	"add-dataSetLink" {
		foreach ($val in $values) {
			$parsed = Parse-DataSetLinkShorthand $val
			$root = $xmlDoc.DocumentElement
			$childIndent = Get-ChildIndent $root

			$fragXml = Build-DataSetLinkFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last dataSetLink, or before calculatedField/totalField/parameter/...
			$lastLink = Find-LastElement $root "dataSetLink" $schNs
			if ($lastLink) {
				$refNode = $lastLink.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("calculatedField","totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			$desc = "$($parsed.source) > $($parsed.dest) on $($parsed.sourceExpr) = $($parsed.destExpr)"
			if ($parsed.parameter) { $desc += " [param $($parsed.parameter)]" }
			Write-Host "[OK] DataSetLink `"$desc`" added"
		}
	}

	"add-dataSet" {
		$root = $xmlDoc.DocumentElement
		$childIndent = Get-ChildIndent $root

		$parsed = Parse-DataSetShorthand $Value

		# Auto-name if empty
		if (-not $parsed.name) {
			$count = 0
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'dataSet' -and $ch.NamespaceURI -eq $schNs) { $count++ }
			}
			$parsed.name = "НаборДанных$($count + 1)"
		}

		# Duplicate check
		$existing = Find-ElementByChildValue $root "dataSet" "name" $parsed.name $schNs
		if ($existing) {
			Write-Host "[WARN] DataSet `"$($parsed.name)`" already exists — skipped"
		} else {
			# Get dataSource name from first existing <dataSource>
			$dsSourceEl = Find-FirstElement $root @("dataSource") $schNs
			$dsSourceName = "ИсточникДанных1"
			if ($dsSourceEl) {
				$nameEl = Find-FirstElement $dsSourceEl @("name") $schNs
				if ($nameEl) { $dsSourceName = $nameEl.InnerText.Trim() }
			}
			$parsed["dataSource"] = $dsSourceName

			$fragXml = Build-DataSetQueryFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last <dataSet>, or after <dataSource> if none
			$lastDS = Find-LastElement $root "dataSet" $schNs
			if ($lastDS) {
				$refNode = $lastDS.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = Find-FirstElement $root @("dataSetLink","calculatedField","totalField","parameter","template","groupTemplate","settingsVariant") $schNs
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			Write-Host "[OK] DataSet `"$($parsed.name)`" added (dataSource=$dsSourceName)"
		}
	}

	"add-variant" {
		$root = $xmlDoc.DocumentElement
		$childIndent = Get-ChildIndent $root

		foreach ($val in $values) {
			$parsed = Parse-VariantShorthand $val

			# Duplicate check — search for settingsVariant with matching dcsset:name
			$isDup = $false
			foreach ($ch in $root.ChildNodes) {
				if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'settingsVariant' -and $ch.NamespaceURI -eq $schNs) {
					foreach ($gc in $ch.ChildNodes) {
						if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq 'name' -and $gc.NamespaceURI -eq $setNs -and $gc.InnerText -eq $parsed.name) {
							$isDup = $true; break
						}
					}
					if ($isDup) { break }
				}
			}
			if ($isDup) {
				Write-Host "[WARN] Variant `"$($parsed.name)`" already exists — skipped"
				continue
			}

			$fragXml = Build-VariantFragment -parsed $parsed -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert after last <settingsVariant>
			$lastSV = Find-LastElement $root "settingsVariant" $schNs
			if ($lastSV) {
				$refNode = $lastSV.NextSibling
				while ($refNode -and ($refNode.NodeType -eq 'Whitespace' -or $refNode.NodeType -eq 'SignificantWhitespace')) {
					$refNode = $refNode.NextSibling
				}
			} else {
				$refNode = $null
			}

			foreach ($node in $nodes) {
				Insert-BeforeElement $root $node $refNode $childIndent
			}

			Write-Host "[OK] Variant `"$($parsed.name)`" [`"$($parsed.presentation)`"] added"
		}
	}

	"add-conditionalAppearance" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-ConditionalAppearanceShorthand $val

			$caEl = Ensure-SettingsChild $settings "conditionalAppearance" @("outputParameters","order","filter","selection")
			$caIndent = Get-ContainerChildIndent $caEl

			$fragXml = Build-ConditionalAppearanceItemFragment -parsed $parsed -indent $caIndent
			$nodes = Import-Fragment $xmlDoc $fragXml
			foreach ($node in $nodes) {
				Insert-BeforeElement $caEl $node $null $caIndent
			}

			$desc = "$($parsed.param) = $($parsed.value)"
			if ($parsed.filter) { $desc += " when $($parsed.filter.field) $($parsed.filter.op)" }
			if ($parsed.fields -and $parsed.fields.Count -gt 0) { $desc += " for $($parsed.fields -join ', ')" }
			Write-Host "[OK] ConditionalAppearance `"$desc`" added to variant `"$varName`""
		}
	}

	"clear-selection" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$selection = Find-FirstElement $settings @("selection") $setNs
		if ($selection) {
			Clear-ContainerChildren $selection
			Write-Host "[OK] Selection cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No selection section in variant `"$varName`""
		}
	}

	"clear-order" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$orderEl = Find-FirstElement $settings @("order") $setNs
		if ($orderEl) {
			Clear-ContainerChildren $orderEl
			Write-Host "[OK] Order cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No order section in variant `"$varName`""
		}
	}

	"clear-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName
		$filterEl = Find-FirstElement $settings @("filter") $setNs
		if ($filterEl) {
			Clear-ContainerChildren $filterEl
			Write-Host "[OK] Filter cleared in variant `"$varName`""
		} else {
			Write-Host "[INFO] No filter section in variant `"$varName`""
		}
	}

	"modify-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-FilterShorthand $val

			$filterEl = Find-FirstElement $settings @("filter") $setNs
			if (-not $filterEl) {
				Write-Host "[WARN] No filter section in variant `"$varName`""
				continue
			}

			$filterItem = Find-ElementByChildValue $filterEl "item" "left" $parsed.field $setNs
			if (-not $filterItem) {
				Write-Host "[WARN] Filter for `"$($parsed.field)`" not found in variant `"$varName`""
				continue
			}

			$itemIndent = Get-ChildIndent $filterItem

			# Update comparisonType
			Set-OrCreateChildElement $filterItem "comparisonType" $setNs $parsed.op $itemIndent

			# Update right value
			if ($null -ne $parsed.value) {
				$vt = if ($parsed["valueType"]) { $parsed["valueType"] } else { "xs:string" }
				Set-OrCreateChildElementWithAttr $filterItem "right" $setNs "$($parsed.value)" $vt $itemIndent
			}

			# Update use
			if ($parsed.use -eq $false) {
				Set-OrCreateChildElement $filterItem "use" $setNs "false" $itemIndent
			} else {
				# If explicitly not @off, remove use=false if exists
				$useEl = $null
				foreach ($ch in $filterItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'use' -and $ch.NamespaceURI -eq $setNs) {
						$useEl = $ch; break
					}
				}
				if ($useEl -and $useEl.InnerText -eq 'false') {
					Remove-NodeWithWhitespace $useEl
				}
			}

			# Update viewMode
			if ($parsed.viewMode) {
				Set-OrCreateChildElement $filterItem "viewMode" $setNs $parsed.viewMode $itemIndent
			}

			# Update userSettingID
			if ($parsed.userSettingID) {
				$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
				Set-OrCreateChildElement $filterItem "userSettingID" $setNs $uid $itemIndent
			}

			Write-Host "[OK] Filter `"$($parsed.field)`" modified in variant `"$varName`""
		}
	}

	"modify-dataParameter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$parsed = Parse-DataParamShorthand $val

			$dpEl = Find-FirstElement $settings @("dataParameters") $setNs
			if (-not $dpEl) {
				Write-Host "[WARN] No dataParameters section in variant `"$varName`""
				continue
			}

			$dpItem = Find-ElementByChildValue $dpEl "item" "parameter" $parsed.parameter $corNs
			if (-not $dpItem) {
				Write-Host "[WARN] DataParameter `"$($parsed.parameter)`" not found in variant `"$varName`""
				continue
			}

			$itemIndent = Get-ChildIndent $dpItem

			# Update value
			if ($null -ne $parsed.value) {
				# Remove existing value element first
				$existingVal = $null
				foreach ($ch in $dpItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'value' -and $ch.NamespaceURI -eq $corNs) {
						$existingVal = $ch; break
					}
				}
				if ($existingVal) {
					Remove-NodeWithWhitespace $existingVal
				}

				# Build new value fragment
				$valLines = @()
				if ($parsed.value -is [hashtable] -and $parsed.value.variant) {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"v8:StandardPeriod`">"
					$valLines += "$itemIndent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $parsed.value.variant)</v8:variant>"
					$valLines += "$itemIndent</dcscor:value>"
				} elseif ("$($parsed.value)" -match '^\d{4}-\d{2}-\d{2}T') {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				} elseif ("$($parsed.value)" -eq "true" -or "$($parsed.value)" -eq "false") {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				} else {
					$valLines += "$itemIndent<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($parsed.value)")</dcscor:value>"
				}
				$valXml = $valLines -join "`r`n"
				$valNodes = Import-Fragment $xmlDoc $valXml
				foreach ($node in $valNodes) {
					Insert-BeforeElement $dpItem $node $null $itemIndent
				}
			}

			# Update use
			if ($parsed.use -eq $false) {
				Set-OrCreateChildElement $dpItem "use" $corNs "false" $itemIndent
			} else {
				$useEl = $null
				foreach ($ch in $dpItem.ChildNodes) {
					if ($ch.NodeType -eq 'Element' -and $ch.LocalName -eq 'use' -and $ch.NamespaceURI -eq $corNs) {
						$useEl = $ch; break
					}
				}
				if ($useEl -and $useEl.InnerText -eq 'false') {
					Remove-NodeWithWhitespace $useEl
				}
			}

			# Update viewMode
			if ($parsed.viewMode) {
				Set-OrCreateChildElement $dpItem "viewMode" $setNs $parsed.viewMode $itemIndent
			}

			# Update userSettingID
			if ($parsed.userSettingID) {
				$uid = if ($parsed.userSettingID -eq "auto") { [System.Guid]::NewGuid().ToString() } else { $parsed.userSettingID }
				Set-OrCreateChildElement $dpItem "userSettingID" $setNs $uid $itemIndent
			}

			Write-Host "[OK] DataParameter `"$($parsed.parameter)`" modified in variant `"$varName`""
		}
	}

	"modify-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$parsed = Parse-FieldShorthand $val
			$fieldName = $parsed.dataPath

			# Find existing field
			$fieldEl = Find-ElementByChildValue $dsNode "field" "dataPath" $fieldName $schNs
			if (-not $fieldEl) {
				Write-Host "[WARN] Field `"$fieldName`" not found in dataset `"$dsName`""
				continue
			}

			# Read existing properties
			$existing = Read-FieldProperties $fieldEl

			# Merge: parsed overrides existing for non-empty values
			$merged = @{
				dataPath = $existing.dataPath
				field = $existing.field
				title = if ($parsed.title) { $parsed.title } else { $existing.title }
				type = if ($parsed.type) { $parsed.type } else { $existing.type }
				roles = if ($parsed.roles -and $parsed.roles.Count -gt 0) { $parsed.roles } else { $existing.roles }
				restrict = if ($parsed.restrict -and $parsed.restrict.Count -gt 0) { $parsed.restrict } else { $existing.restrict }
			}

			# Remember position (NextSibling after whitespace)
			$nextSib = $fieldEl.NextSibling
			while ($nextSib -and ($nextSib.NodeType -eq 'Whitespace' -or $nextSib.NodeType -eq 'SignificantWhitespace')) {
				$nextSib = $nextSib.NextSibling
			}

			# Remove old field
			$childIndent = Get-ChildIndent $dsNode
			Remove-NodeWithWhitespace $fieldEl

			# Build new field fragment with merged data
			$fragXml = Build-FieldFragment -parsed $merged -indent $childIndent
			$nodes = Import-Fragment $xmlDoc $fragXml

			# Insert at saved position
			foreach ($node in $nodes) {
				Insert-BeforeElement $dsNode $node $nextSib $childIndent
			}

			Write-Host "[OK] Field `"$fieldName`" modified in dataset `"$dsName`""
		}
	}

	"remove-field" {
		$dsNode = Resolve-DataSet
		$dsName = Get-DataSetName $dsNode

		foreach ($val in $values) {
			$fieldName = $val.Trim()

			$fieldEl = Find-ElementByChildValue $dsNode "field" "dataPath" $fieldName $schNs
			if (-not $fieldEl) {
				Write-Host "[WARN] Field `"$fieldName`" not found in dataset `"$dsName`""
				continue
			}

			Remove-NodeWithWhitespace $fieldEl
			Write-Host "[OK] Field `"$fieldName`" removed from dataset `"$dsName`""

			# Also remove from selection in variant
			try {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Find-FirstElement $settings @("selection") $setNs
				if ($selection) {
					$selItem = Find-ElementByChildValue $selection "item" "field" $fieldName $setNs
					if ($selItem) {
						Remove-NodeWithWhitespace $selItem
						Write-Host "[OK] Field `"$fieldName`" removed from selection of variant `"$varName`""
					}
				}
			} catch {
				# No variant — that's fine
			}
		}
	}

	"remove-total" {
		foreach ($val in $values) {
			$dataPath = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$totalEl = Find-ElementByChildValue $root "totalField" "dataPath" $dataPath $schNs
			if (-not $totalEl) {
				Write-Host "[WARN] TotalField `"$dataPath`" not found"
				continue
			}

			Remove-NodeWithWhitespace $totalEl
			Write-Host "[OK] TotalField `"$dataPath`" removed"
		}
	}

	"remove-calculated-field" {
		foreach ($val in $values) {
			$dataPath = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$calcEl = Find-ElementByChildValue $root "calculatedField" "dataPath" $dataPath $schNs
			if (-not $calcEl) {
				Write-Host "[WARN] CalculatedField `"$dataPath`" not found"
				continue
			}

			Remove-NodeWithWhitespace $calcEl
			Write-Host "[OK] CalculatedField `"$dataPath`" removed"

			# Also remove from selection
			try {
				$settings = Resolve-VariantSettings
				$varName = Get-VariantName
				$selection = Find-FirstElement $settings @("selection") $setNs
				if ($selection) {
					$selItem = Find-ElementByChildValue $selection "item" "field" $dataPath $setNs
					if ($selItem) {
						Remove-NodeWithWhitespace $selItem
						Write-Host "[OK] Field `"$dataPath`" removed from selection of variant `"$varName`""
					}
				}
			} catch { }
		}
	}

	"remove-parameter" {
		foreach ($val in $values) {
			$paramName = $val.Trim()
			$root = $xmlDoc.DocumentElement

			$paramEl = Find-ElementByChildValue $root "parameter" "name" $paramName $schNs
			if (-not $paramEl) {
				Write-Host "[WARN] Parameter `"$paramName`" not found"
				continue
			}

			Remove-NodeWithWhitespace $paramEl
			Write-Host "[OK] Parameter `"$paramName`" removed"
		}
	}

	"remove-filter" {
		$settings = Resolve-VariantSettings
		$varName = Get-VariantName

		foreach ($val in $values) {
			$fieldName = $val.Trim()

			$filterEl = Find-FirstElement $settings @("filter") $setNs
			if (-not $filterEl) {
				Write-Host "[WARN] No filter section in variant `"$varName`""
				continue
			}

			$filterItem = Find-ElementByChildValue $filterEl "item" "left" $fieldName $setNs
			if (-not $filterItem) {
				Write-Host "[WARN] Filter for `"$fieldName`" not found in variant `"$varName`""
				continue
			}

			Remove-NodeWithWhitespace $filterItem
			Write-Host "[OK] Filter for `"$fieldName`" removed from variant `"$varName`""
		}
	}
}

# --- 9. Save ---

$content = $xmlDoc.OuterXml
$content = $content -replace '(?<=<\?xml[^?]*encoding=")utf-8(?=")', 'UTF-8'
$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedPath, $content, $enc)

Write-Host "[OK] Saved $resolvedPath"
