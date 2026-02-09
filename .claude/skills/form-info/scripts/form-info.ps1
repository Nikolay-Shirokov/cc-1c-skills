param(
	[Parameter(Mandatory=$true)]
	[string]$FormPath,
	[int]$Limit = 150,
	[int]$Offset = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Validate path ---

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}

# --- Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load((Resolve-Path $FormPath).Path)

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("d", "http://v8.1c.ru/8.3/xcf/logform")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("cfg", "http://v8.1c.ru/8.1/data/enterprise/current-config")
$ns.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")

$root = $xmlDoc.DocumentElement

# --- Helper: extract multilang text ---

function Get-MLText($node) {
	if (-not $node) { return "" }
	$content = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($content) { return $content.InnerText }
	$text = $node.InnerText.Trim()
	if ($text) { return $text }
	return ""
}

# --- Helper: format type compactly ---

function Format-Type($typeNode) {
	if (-not $typeNode -or -not $typeNode.HasChildNodes) { return "" }

	$typeSet = $typeNode.SelectSingleNode("v8:TypeSet", $ns)
	if ($typeSet) {
		$val = $typeSet.InnerText
		# Strip cfg: prefix for DefinedType, keep as-is
		if ($val -like "cfg:*") { $val = $val.Substring(4) }
		return $val
	}

	$types = $typeNode.SelectNodes("v8:Type", $ns)
	if ($types.Count -eq 0) { return "" }

	$parts = @()
	foreach ($t in $types) {
		$raw = $t.InnerText
		switch -Wildcard ($raw) {
			"xs:string" {
				$sq = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:Length", $ns)
				$len = if ($sq) { [int]$sq.InnerText } else { 0 }
				if ($len -gt 0) { $parts += "string($len)" } else { $parts += "string" }
			}
			"xs:decimal" {
				$nq = $typeNode.SelectSingleNode("v8:NumberQualifiers", $ns)
				if ($nq) {
					$d = $nq.SelectSingleNode("v8:Digits", $ns)
					$f = $nq.SelectSingleNode("v8:FractionDigits", $ns)
					$digits = if ($d) { $d.InnerText } else { "0" }
					$frac = if ($f) { $f.InnerText } else { "0" }
					$parts += "decimal($digits,$frac)"
				} else {
					$parts += "decimal"
				}
			}
			"xs:boolean" { $parts += "boolean" }
			"xs:dateTime" {
				$dq = $typeNode.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns)
				if ($dq) {
					switch ($dq.InnerText) {
						"Date" { $parts += "date" }
						"Time" { $parts += "time" }
						default { $parts += "dateTime" }
					}
				} else {
					$parts += "dateTime"
				}
			}
			"xs:binary" { $parts += "binary" }
			"cfg:*" { $parts += $raw.Substring(4) }
			"v8:ValueTable" { $parts += "ValueTable" }
			"v8:ValueTree" { $parts += "ValueTree" }
			"v8:ValueListType" { $parts += "ValueList" }
			"v8:TypeDescription" { $parts += "TypeDescription" }
			"v8:Universal" { $parts += "Universal" }
			"v8:FixedArray" { $parts += "FixedArray" }
			"v8:FixedStructure" { $parts += "FixedStructure" }
			"v8ui:FormattedString" { $parts += "FormattedString" }
			"v8ui:Picture" { $parts += "Picture" }
			"v8ui:Color" { $parts += "Color" }
			"v8ui:Font" { $parts += "Font" }
			"dcsset:*" { $parts += $raw.Replace("dcsset:", "DCS.") }
			"dcssch:*" { $parts += $raw.Replace("dcssch:", "DCS.") }
			"dcscor:*" { $parts += $raw.Replace("dcscor:", "DCS.") }
			default { $parts += $raw }
		}
	}

	return ($parts -join " | ")
}

# --- Helper: check if title differs from name ---

function Test-TitleDiffers($node, [string]$name) {
	$titleNode = $node.SelectSingleNode("d:Title", $ns)
	if (-not $titleNode) { return $null }
	$titleText = Get-MLText $titleNode
	if (-not $titleText) { return $null }
	# Normalize: remove spaces, lowercase
	$normTitle = ($titleText -replace '\s', '').ToLower()
	$normName = $name.ToLower()
	if ($normTitle -eq $normName) { return $null }
	return $titleText
}

# --- Helper: get events as compact string ---

function Get-EventsStr($node) {
	$eventsNode = $node.SelectSingleNode("d:Events", $ns)
	if (-not $eventsNode) { return "" }
	$evts = @()
	foreach ($e in $eventsNode.SelectNodes("d:Event", $ns)) {
		$evts += $e.GetAttribute("name")
	}
	if ($evts.Count -eq 0) { return "" }
	return " {$($evts -join ', ')}"
}

# --- Helper: get flags ---

function Get-Flags($node) {
	$flags = @()
	$vis = $node.SelectSingleNode("d:Visible", $ns)
	if ($vis -and $vis.InnerText -eq "false") { $flags += "visible:false" }
	$en = $node.SelectSingleNode("d:Enabled", $ns)
	if ($en -and $en.InnerText -eq "false") { $flags += "enabled:false" }
	$ro = $node.SelectSingleNode("d:ReadOnly", $ns)
	if ($ro -and $ro.InnerText -eq "true") { $flags += "ro" }
	if ($flags.Count -eq 0) { return "" }
	return " [$($flags -join ',')]"
}

# --- Element type abbreviations ---

$skipElements = @{
	"ExtendedTooltip" = $true
	"ContextMenu" = $true
	"AutoCommandBar" = $true
	"SearchStringAddition" = $true
	"ViewStatusAddition" = $true
	"SearchControlAddition" = $true
	"ColumnGroup" = $true
}

function Get-ElementTag($node) {
	$localName = $node.LocalName
	switch ($localName) {
		"UsualGroup" {
			$groupNode = $node.SelectSingleNode("d:Group", $ns)
			$orient = ""
			if ($groupNode) {
				switch ($groupNode.InnerText) {
					"Vertical" { $orient = ":V" }
					"Horizontal" { $orient = ":H" }
					"AlwaysHorizontal" { $orient = ":AH" }
					"AlwaysVertical" { $orient = ":AV" }
				}
			}
			$beh = $node.SelectSingleNode("d:Behavior", $ns)
			$collapse = ""
			if ($beh -and $beh.InnerText -eq "Collapsible") { $collapse = ",collapse" }
			return "[Group$orient$collapse]"
		}
		"InputField" { return "[Input]" }
		"CheckBoxField" { return "[Check]" }
		"LabelDecoration" { return "[Label]" }
		"LabelField" { return "[LabelField]" }
		"PictureDecoration" { return "[Picture]" }
		"PictureField" { return "[PicField]" }
		"CalendarField" { return "[Calendar]" }
		"Table" { return "[Table]" }
		"Button" { return "[Button]" }
		"CommandBar" { return "[CmdBar]" }
		"Pages" { return "[Pages]" }
		"Page" { return "[Page]" }
		"Popup" { return "[Popup]" }
		"ButtonGroup" { return "[BtnGroup]" }
		default { return "[$localName]" }
	}
}

# --- Count significant children (for Page summary) ---

function Count-SignificantChildren($childItemsNode) {
	if (-not $childItemsNode) { return 0 }
	$count = 0
	foreach ($child in $childItemsNode.ChildNodes) {
		if ($child.NodeType -ne "Element") { continue }
		if ($skipElements.ContainsKey($child.LocalName)) { continue }
		$count++
	}
	return $count
}

# --- Build element tree recursively ---

$treeLines = [System.Collections.Generic.List[string]]::new()

function Build-Tree($childItemsNode, [string]$prefix, [bool]$isLast) {
	if (-not $childItemsNode) { return }

	# Collect significant children
	$children = @()
	foreach ($child in $childItemsNode.ChildNodes) {
		if ($child.NodeType -ne "Element") { continue }
		if ($skipElements.ContainsKey($child.LocalName)) { continue }
		$children += $child
	}

	for ($i = 0; $i -lt $children.Count; $i++) {
		$child = $children[$i]
		$last = ($i -eq $children.Count - 1)
		$connector = if ($last) { [char]0x2514 + [string][char]0x2500 } else { [char]0x251C + [string][char]0x2500 }
		$continuation = if ($last) { "  " } else { [string][char]0x2502 + " " }

		$tag = Get-ElementTag $child
		$name = $child.GetAttribute("name")
		$flags = Get-Flags $child
		$events = Get-EventsStr $child

		# DataPath or CommandName
		$binding = ""
		$dp = $child.SelectSingleNode("d:DataPath", $ns)
		if ($dp) {
			$binding = " -> $($dp.InnerText)"
		} else {
			$cn = $child.SelectSingleNode("d:CommandName", $ns)
			if ($cn) { $binding = " -> $($cn.InnerText)" }
		}

		# Title differs?
		$titleStr = ""
		$diffTitle = Test-TitleDiffers $child $name
		if ($diffTitle) { $titleStr = " [title:$diffTitle]" }

		$line = "$prefix$connector $tag $name$binding$flags$titleStr$events"
		$treeLines.Add($line)

		# Recurse into containers (but not Page — show summary)
		$localName = $child.LocalName
		if ($localName -eq "Page") {
			$ci = $child.SelectSingleNode("d:ChildItems", $ns)
			$cnt = Count-SignificantChildren $ci
			# Append count to last line
			$idx = $treeLines.Count - 1
			$treeLines[$idx] = $treeLines[$idx] + " ($cnt items)"
		} elseif ($localName -in @("UsualGroup", "Pages", "Table", "CommandBar", "ButtonGroup", "Popup")) {
			$ci = $child.SelectSingleNode("d:ChildItems", $ns)
			if ($ci) {
				Build-Tree $ci "$prefix$continuation" $last
			}
		}
	}
}

# --- Determine form name and object from path ---

$resolvedPath = (Resolve-Path $FormPath).Path
$parts = $resolvedPath -split '[/\\]'

$formName = ""
$objectContext = ""

# Look for /Forms/<FormName>/Ext/Form.xml pattern
$formsIdx = -1
for ($i = $parts.Count - 1; $i -ge 0; $i--) {
	if ($parts[$i] -eq "Forms") { $formsIdx = $i; break }
}

if ($formsIdx -ge 0 -and ($formsIdx + 1) -lt $parts.Count) {
	$formName = $parts[$formsIdx + 1]
	# Object is 2 levels up: .../<ObjectType>/<ObjectName>/Forms/...
	if ($formsIdx -ge 2) {
		$objType = $parts[$formsIdx - 2]
		$objName = $parts[$formsIdx - 1]
		$objectContext = "$objType.$objName"
	}
} else {
	# CommonForms pattern: .../<ObjectType>/<FormName>/Ext/Form.xml
	$extIdx = -1
	for ($i = $parts.Count - 1; $i -ge 0; $i--) {
		if ($parts[$i] -eq "Ext") { $extIdx = $i; break }
	}
	if ($extIdx -ge 2) {
		$formName = $parts[$extIdx - 1]
		$objType = $parts[$extIdx - 2]
		$objectContext = $objType
	} else {
		$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
	}
}

# --- Collect output ---

$lines = @()

# Header
$header = "=== Form: $formName"
if ($objectContext) { $header += " ($objectContext)" }
$header += " ==="
$lines += $header

# --- Form properties ---

$propNames = @(
	"Title", "Width", "Height", "Group",
	"WindowOpeningMode", "EnterKeyBehavior", "AutoTitle", "AutoURL",
	"AutoFillCheck", "Customizable", "CommandBarLocation",
	"SaveDataInSettings", "AutoSaveDataInSettings",
	"AutoTime", "UsePostingMode", "RepostOnWrite",
	"UseForFoldersAndItems",
	"ReportResult", "DetailsData", "ReportFormType",
	"VerticalScroll", "ScalingMode"
)

$props = @()
foreach ($pn in $propNames) {
	$pNode = $root.SelectSingleNode("d:$pn", $ns)
	if ($pNode) {
		$val = Get-MLText $pNode
		if (-not $val) { $val = $pNode.InnerText }
		$props += "$pn=$val"
	}
}

if ($props.Count -gt 0) {
	$lines += ""
	$lines += "Properties: $($props -join ', ')"
}

# --- Excluded commands ---

$excludedCmds = @()
foreach ($ec in $root.SelectNodes("d:CommandSet/d:ExcludedCommand", $ns)) {
	$excludedCmds += $ec.InnerText
}

# --- Form events ---

$formEvents = $root.SelectSingleNode("d:Events", $ns)
if ($formEvents -and $formEvents.HasChildNodes) {
	$lines += ""
	$lines += "Events:"
	foreach ($e in $formEvents.SelectNodes("d:Event", $ns)) {
		$eName = $e.GetAttribute("name")
		$eHandler = $e.InnerText
		$lines += "  $eName -> $eHandler"
	}
}

# --- Element tree ---

$childItems = $root.SelectSingleNode("d:ChildItems", $ns)
if ($childItems) {
	$lines += ""
	$lines += "Elements:"
	Build-Tree $childItems "  " $false
	$lines += $treeLines.ToArray()
}

# --- Attributes ---

$attrsNode = $root.SelectSingleNode("d:Attributes", $ns)
if ($attrsNode) {
	$attrLines = @()
	foreach ($attr in $attrsNode.SelectNodes("d:Attribute", $ns)) {
		$aName = $attr.GetAttribute("name")
		$typeNode = $attr.SelectSingleNode("d:Type", $ns)
		$typeStr = Format-Type $typeNode

		$mainAttr = $attr.SelectSingleNode("d:MainAttribute", $ns)
		$isMain = ($mainAttr -and $mainAttr.InnerText -eq "true")

		$prefix = if ($isMain) { "*" } else { " " }
		$mainSuffix = if ($isMain) { " (main)" } else { "" }

		# DynamicList: show MainTable
		$settings = $attr.SelectSingleNode("d:Settings", $ns)
		$dynTable = ""
		if ($settings -and $typeStr -eq "DynamicList") {
			$mt = $settings.SelectSingleNode("d:MainTable", $ns)
			if ($mt) { $dynTable = " -> $($mt.InnerText)" }
		}

		# ValueTable/ValueTree columns
		$colStr = ""
		$columns = $attr.SelectSingleNode("d:Columns", $ns)
		if ($columns -and ($typeStr -eq "ValueTable" -or $typeStr -eq "ValueTree")) {
			$cols = @()
			foreach ($col in $columns.SelectNodes("d:Column", $ns)) {
				$cName = $col.GetAttribute("name")
				$cTypeNode = $col.SelectSingleNode("d:Type", $ns)
				$cType = Format-Type $cTypeNode
				if ($cType) { $cols += "$cName`: $cType" } else { $cols += $cName }
			}
			if ($cols.Count -gt 0) {
				$colStr = " [$($cols -join ', ')]"
			}
		}

		$line = "  $prefix$aName`: $typeStr$colStr$dynTable$mainSuffix"
		if (-not $typeStr -and -not $colStr -and -not $dynTable) {
			$line = "  $prefix$aName$mainSuffix"
		}
		$attrLines += $line
	}
	if ($attrLines.Count -gt 0) {
		$lines += ""
		$lines += "Attributes:"
		$lines += $attrLines
	}
}

# --- Parameters ---

$paramsNode = $root.SelectSingleNode("d:Parameters", $ns)
if ($paramsNode) {
	$paramLines = @()
	foreach ($param in $paramsNode.SelectNodes("d:Parameter", $ns)) {
		$pName = $param.GetAttribute("name")
		$typeNode = $param.SelectSingleNode("d:Type", $ns)
		$typeStr = Format-Type $typeNode

		$keyParam = $param.SelectSingleNode("d:KeyParameter", $ns)
		$isKey = ($keyParam -and $keyParam.InnerText -eq "true")
		$keySuffix = if ($isKey) { " (key)" } else { "" }

		if ($typeStr) {
			$paramLines += "  $pName`: $typeStr$keySuffix"
		} else {
			$paramLines += "  $pName$keySuffix"
		}
	}
	if ($paramLines.Count -gt 0) {
		$lines += ""
		$lines += "Parameters:"
		$lines += $paramLines
	}
}

# --- Commands ---

$cmdsNode = $root.SelectSingleNode("d:Commands", $ns)
if ($cmdsNode) {
	$cmdLines = @()
	foreach ($cmd in $cmdsNode.SelectNodes("d:Command", $ns)) {
		$cName = $cmd.GetAttribute("name")
		$action = $cmd.SelectSingleNode("d:Action", $ns)
		$shortcut = $cmd.SelectSingleNode("d:Shortcut", $ns)

		$actionStr = if ($action) { " -> $($action.InnerText)" } else { "" }
		$scStr = if ($shortcut) { " [$($shortcut.InnerText)]" } else { "" }

		$cmdLines += "  $cName$actionStr$scStr"
	}
	if ($cmdLines.Count -gt 0) {
		$lines += ""
		$lines += "Commands:"
		$lines += $cmdLines
	}
}

# --- Truncation protection ---

$totalLines = $lines.Count

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$lines = $lines[$Offset..($totalLines - 1)]
}

if ($lines.Count -gt $Limit) {
	$shown = $lines[0..($Limit - 1)]
	foreach ($l in $shown) { Write-Host $l }
	$remaining = $totalLines - $Offset - $Limit
	Write-Host ""
	Write-Host "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
} else {
	foreach ($l in $lines) { Write-Host $l }
}
