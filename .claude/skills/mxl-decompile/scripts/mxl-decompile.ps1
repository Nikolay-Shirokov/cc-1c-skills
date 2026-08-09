# mxl-decompile v1.2 — Decompile 1C spreadsheet to JSON (+плоский режим, области всех типов, поля ввода)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$TemplatePath,

	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and parse XML ---

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load((Resolve-Path $TemplatePath).Path)

$root = $xmlDoc.DocumentElement
if ($root.NamespaceURI -ne "http://v8.1c.ru/8.2/data/spreadsheet") {
	Write-Error "Not a spreadsheet template: root <$($root.Name)> in namespace '$($root.NamespaceURI)'. Expected a Template.xml of a spreadsheet document."
	exit 1
}
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("d", "http://v8.1c.ru/8.2/data/spreadsheet")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

# --- 1a. Language settings ---

$langSettings = $null
$lsNode = $root.SelectSingleNode("d:languageSettings", $ns)
if ($lsNode) {
	$cur = $lsNode.SelectSingleNode("d:currentLanguage", $ns)
	$dflt = $lsNode.SelectSingleNode("d:defaultLanguage", $ns)
	$list = @()
	foreach ($li in $lsNode.SelectNodes("d:languageInfo", $ns)) {
		$item = [ordered]@{}
		foreach ($f in @("id", "code", "description")) {
			$n = $li.SelectSingleNode("d:$f", $ns)
			if ($n) { $item[$f] = $n.InnerText }
		}
		$list += $item
	}
	$langSettings = [ordered]@{}
	if ($cur) { $langSettings["current"] = $cur.InnerText }
	if ($dflt) { $langSettings["default"] = $dflt.InnerText }
	if ($list.Count -gt 0) { $langSettings["list"] = [array]$list }
}

# Main language of the template, detected from the cell texts themselves:
# currentLanguage is not reliable (templates carry texts under another language,
# and some have no languageSettings at all)
$langCounts = @{}
foreach ($item in $root.SelectNodes("d:rowsItem//d:tl/v8:item", $ns)) {
	$lNode = $item.SelectSingleNode("v8:lang", $ns)
	if (-not $lNode) { continue }
	$l = $lNode.InnerText
	if ($langCounts.ContainsKey($l)) { $langCounts[$l]++ } else { $langCounts[$l] = 1 }
}

$textLang = $null
$bestCount = 0
foreach ($l in ($langCounts.Keys | Sort-Object)) {
	if ($langCounts[$l] -gt $bestCount) { $textLang = $l; $bestCount = $langCounts[$l] }
}
if (-not $textLang) {
	# No texts at all — fall back to what the template declares
	$textLang = if ($langSettings -and $langSettings["current"]) { $langSettings["current"] } else { "ru" }
}

# --- 2. Extract font palette ---

$invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Font height can be fractional (8.3, 6.8) and is always written with a dot,
# so it must be parsed and formatted culture-independently
function ConvertTo-Number {
	param([string]$s, [double]$fallback = 0)
	if ([string]::IsNullOrWhiteSpace($s)) { return $fallback }
	$value = 0.0
	if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$value)) {
		# Keep whole numbers as integers so the DSL stays readable
		if ($value -eq [math]::Floor($value)) { return [int]$value }
		return $value
	}
	return $fallback
}

$rawFonts = @()
foreach ($fNode in $root.SelectNodes("d:font", $ns)) {
	# A system font (`ref` + kind="WindowsFont") carries almost no attributes and
	# follows the OS settings — inventing a size for it changes how it looks
	$heightAttr = $fNode.GetAttribute("height")
	$rawFonts += @{
		Face      = $fNode.GetAttribute("faceName")
		Size      = ConvertTo-Number $heightAttr
		HasSize   = -not [string]::IsNullOrEmpty($heightAttr)
		Bold      = $fNode.GetAttribute("bold") -eq "true"
		Italic    = $fNode.GetAttribute("italic") -eq "true"
		Underline = $fNode.GetAttribute("underline") -eq "true"
		Strikeout = $fNode.GetAttribute("strikeout") -eq "true"
		Ref       = $fNode.GetAttribute("ref")
		Kind      = $fNode.GetAttribute("kind")
		# Which style attributes the element actually carried — a system font may
		# spell out bold="false", and dropping it changes the element
		HasStyleAttrs = -not [string]::IsNullOrEmpty($fNode.GetAttribute("bold"))
	}
}

# --- 3. Extract line palette ---

$rawLines = @()
foreach ($lNode in $root.SelectNodes("d:line", $ns)) {
	$style = "Solid"
	$sNode = $lNode.SelectSingleNode("v8ui:style", $ns)
	if ($sNode) { $style = $sNode.InnerText }
	$rawLines += @{ Width = ConvertTo-Number $lNode.GetAttribute("width"); Style = $style }
}

# A border index pointing at a line with style None means "no border"
function Test-LineVisible {
	param([int]$idx)
	if ($idx -lt 0) { return $false }
	if ($idx -ge $rawLines.Count) { return $true }
	return $rawLines[$idx].Style -ne "None"
}

# --- 3a. Input cell control types ---

# Platform GUIDs of cell control types (constants, same in every configuration)
$controlTypeNames = @{
	"381ed624-9217-4e63-85db-c4c3cb87daae" = "field"     # input field
	"35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26" = "checkbox"  # checkbox
}

# valueType XML -> compact DSL object
function ConvertFrom-ValueTypeNode {
	param($vtNode)
	if (-not $vtNode) { return $null }

	$tNode = $vtNode.SelectSingleNode("v8:Type", $ns)
	if (-not $tNode) { return $null }
	$xsType = $tNode.InnerText

	$out = [ordered]@{}

	switch ($xsType) {
		"xs:decimal" {
			$out["type"] = "number"
			$q = $vtNode.SelectSingleNode("v8:NumberQualifiers", $ns)
			if ($q) {
				$n = $q.SelectSingleNode("v8:Digits", $ns)
				if ($n) { $out["digits"] = [int]$n.InnerText }
				$n = $q.SelectSingleNode("v8:FractionDigits", $ns)
				if ($n) { $out["fractionDigits"] = [int]$n.InnerText }
				$n = $q.SelectSingleNode("v8:AllowedSign", $ns)
				if ($n -and $n.InnerText -ne "Any") { $out["allowedSign"] = $n.InnerText }
			}
		}
		"xs:string" {
			$out["type"] = "string"
			$q = $vtNode.SelectSingleNode("v8:StringQualifiers", $ns)
			if ($q) {
				$n = $q.SelectSingleNode("v8:Length", $ns)
				if ($n) { $out["length"] = [int]$n.InnerText }
				$n = $q.SelectSingleNode("v8:AllowedLength", $ns)
				if ($n -and $n.InnerText -ne "Variable") { $out["allowedLength"] = $n.InnerText }
			}
		}
		"xs:boolean" {
			$out["type"] = "boolean"
		}
		default {
			# xs:dateTime and anything else date-like
			$out["type"] = "date"
			$q = $vtNode.SelectSingleNode("v8:DateQualifiers", $ns)
			if ($q) {
				$n = $q.SelectSingleNode("v8:DateFractions", $ns)
				if ($n -and $n.InnerText -ne "Date") { $out["dateFractions"] = $n.InnerText }
			}
			if ($xsType -ne "xs:dateTime") { $out["xsType"] = $xsType }
		}
	}

	return $out
}

# --- 4. Extract format palette ---

# Format children the DSL models itself; the rest is carried over verbatim
$modelledFormatChildren = @(
	"font", "leftBorder", "topBorder", "rightBorder", "bottomBorder", "border",
	"width", "height", "horizontalAlignment", "verticalAlignment", "textPlacement",
	"fillType", "format", "textColor", "borderColor", "hidden", "indent",
	"containsValue", "valueType", "controlType"
)

# Namespaces live on the document element, a fragment must not repeat them
function Strip-Xmlns {
	param([string]$xml)
	return ($xml -replace '\s+xmlns(:[A-Za-z0-9_]+)?="[^"]*"', '')
}

$rawFormats = @()
foreach ($fmtNode in $root.SelectNodes("d:format", $ns)) {
	$fmt = @{
		FontIdx = -1
		LB = -1; TB = -1; RB = -1; BB = -1
		Width = 0; Height = 0; HasWidth = $false; HasHeight = $false
		HA = ""; VA = ""
		Wrap = ""; FillType = ""; DataFormat = ""   # Wrap holds textPlacement: Wrap, Auto or Cut
		DataFormatByLang = $null
		TextColor = ""; BorderColor = ""; Hidden = ""; Indent = 0; HasIndent = $false
		ContainsValue = $false; ControlType = ""; ValueType = $null
	}

	$n = $fmtNode.SelectSingleNode("d:font", $ns)
	if ($n) { $fmt.FontIdx = [int]$n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:leftBorder", $ns)
	if ($n) { $fmt.LB = [int]$n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:topBorder", $ns)
	if ($n) { $fmt.TB = [int]$n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:rightBorder", $ns)
	if ($n) { $fmt.RB = [int]$n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:bottomBorder", $ns)
	if ($n) { $fmt.BB = [int]$n.InnerText }

	# <border> sets all four sides at once. The platform uses either this form or
	# the per-side one, never both — and never spells out four equal sides.
	$n = $fmtNode.SelectSingleNode("d:border", $ns)
	if ($n) {
		$all = [int]$n.InnerText
		$fmt.LB = $all; $fmt.TB = $all; $fmt.RB = $all; $fmt.BB = $all
	}

	# 0 is a real value here, so presence is tracked separately
	$n = $fmtNode.SelectSingleNode("d:width", $ns)
	if ($n) { $fmt.Width = [int]$n.InnerText; $fmt.HasWidth = $true }
	$n = $fmtNode.SelectSingleNode("d:height", $ns)
	if ($n) { $fmt.Height = [int]$n.InnerText; $fmt.HasHeight = $true }

	$n = $fmtNode.SelectSingleNode("d:horizontalAlignment", $ns)
	if ($n) { $fmt.HA = $n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:verticalAlignment", $ns)
	if ($n) { $fmt.VA = $n.InnerText }

	$n = $fmtNode.SelectSingleNode("d:textPlacement", $ns)
	if ($n) { $fmt.Wrap = $n.InnerText }

	$n = $fmtNode.SelectSingleNode("d:fillType", $ns)
	if ($n) { $fmt.FillType = $n.InnerText }

	# Number format is multilingual just like cell text
	$dfItems = $fmtNode.SelectNodes("d:format/v8:item", $ns)
	if ($dfItems.Count -eq 1) {
		$cN = $dfItems[0].SelectSingleNode("v8:content", $ns)
		$lN = $dfItems[0].SelectSingleNode("v8:lang", $ns)
		if ($cN) { $fmt.DataFormat = $cN.InnerText }
		if ($lN -and $lN.InnerText -ne $textLang) {
			$fmt.DataFormatByLang = [ordered]@{ $lN.InnerText = $fmt.DataFormat }
		}
	} elseif ($dfItems.Count -gt 1) {
		$fmt.DataFormatByLang = [ordered]@{}
		foreach ($it in $dfItems) {
			$cN = $it.SelectSingleNode("v8:content", $ns)
			$lN = $it.SelectSingleNode("v8:lang", $ns)
			if (-not $cN -or -not $lN) { continue }
			$fmt.DataFormatByLang[$lN.InnerText] = $cN.InnerText
			if (-not $fmt.DataFormat) { $fmt.DataFormat = $cN.InnerText }
		}
	}

	$n = $fmtNode.SelectSingleNode("d:textColor", $ns)
	if ($n) { $fmt.TextColor = $n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:borderColor", $ns)
	if ($n) { $fmt.BorderColor = $n.InnerText }
	# Templates spell out hidden=false too; dropping it changes the format
	$n = $fmtNode.SelectSingleNode("d:hidden", $ns)
	if ($n) { $fmt.Hidden = $n.InnerText }
	# indent=0 is spelled out in templates, so presence is tracked separately
	$n = $fmtNode.SelectSingleNode("d:indent", $ns)
	if ($n) { $fmt.Indent = [int]$n.InnerText; $fmt.HasIndent = $true }

	# Input cell (containsValue + valueType + controlType)
	$n = $fmtNode.SelectSingleNode("d:containsValue", $ns)
	if ($n -and $n.InnerText -eq "true") { $fmt.ContainsValue = $true }
	$n = $fmtNode.SelectSingleNode("d:controlType", $ns)
	if ($n) { $fmt.ControlType = $n.InnerText }
	$vtNode = $fmtNode.SelectSingleNode("d:valueType", $ns)
	if ($vtNode) { $fmt.ValueType = ConvertFrom-ValueTypeNode $vtNode }

	# Everything the DSL does not model — carried over verbatim, in the order the
	# platform wrote it. Without this the property is silently dropped.
	$extra = @()
	$order = @()
	foreach ($ch in $fmtNode.ChildNodes) {
		$order += $ch.Name
		# An empty <format> holds no number format to model — keep it as is
		if ($ch.Name -eq "format" -and $dfItems.Count -eq 0) {
			$extra += [ordered]@{ name = $ch.Name; xml = (Strip-Xmlns $ch.OuterXml) }
			continue
		}
		if ($modelledFormatChildren -contains $ch.Name) { continue }
		$extra += [ordered]@{ name = $ch.Name; xml = (Strip-Xmlns $ch.OuterXml) }
	}
	$fmt.Extra = $extra
	$fmt.Order = $order

	$rawFormats += $fmt
}

function Get-Format {
	param([int]$idx)
	if ($idx -le 0 -or $idx -gt $rawFormats.Count) { return $null }
	return $rawFormats[$idx - 1]
}

# --- 5. Extract columns and default width ---

$colNode = $root.SelectSingleNode("d:columns", $ns)
$totalColumns = [int]$colNode.SelectSingleNode("d:size", $ns).InnerText

$colFormatIndices = @{}
foreach ($ci in $colNode.SelectNodes("d:columnsItem", $ns)) {
	$colIdx = [int]$ci.SelectSingleNode("d:index", $ns).InnerText
	$fmtIdx = [int]$ci.SelectSingleNode("d:column/d:formatIndex", $ns).InnerText
	$colFormatIndices[$colIdx] = $fmtIdx
}

# Extra column sets (a second <columns> with its own id, referenced by rows via
# <columnsID>) are not describable in the DSL. Say so instead of quietly mixing
# their geometry into the default set.
$columnSetCount = $root.SelectNodes("d:columns", $ns).Count
if ($columnSetCount -gt 1) {
	Write-Warning "Template has $columnSetCount column sets; the DSL describes only the default one. Rows bound to another set will come out with the default geometry."
}

# <size> is not always trustworthy: templates ship with size=0 or with a size
# smaller than the columns their cells actually use. Widen to what is used —
# but only with one column set, otherwise cells belong to different geometries.
$maxCol = -1
foreach ($k in $colFormatIndices.Keys) { if ($k -gt $maxCol) { $maxCol = $k } }
foreach ($ri in $root.SelectNodes("d:rowsItem", $ns)) {
	if ($columnSetCount -gt 1) { break }
	$rowNode = $ri.SelectSingleNode("d:row", $ns)
	if (-not $rowNode) { continue }
	$c = -1
	foreach ($cGroup in $rowNode.SelectNodes("d:c", $ns)) {
		$iNode = $cGroup.SelectSingleNode("d:i", $ns)
		if ($iNode) { $c = [int]$iNode.InnerText } else { $c++ }
		if ($c -gt $maxCol) { $maxCol = $c }
	}
}
# Merges are deliberately left out: stock templates do extend a merge past the
# last column, and widening the document for that would change its geometry
if (($maxCol + 1) -gt $totalColumns) { $totalColumns = $maxCol + 1 }
if ($totalColumns -lt 1) { $totalColumns = 1 }

$defaultFmtIdx = 0
$n = $root.SelectSingleNode("d:defaultFormatIndex", $ns)
if ($n) { $defaultFmtIdx = [int]$n.InnerText }

# 0 means the template declares no default width and every column without an
# explicit one takes the platform's own. Inventing a number here shrinks those
# columns — do not guess.
$defaultWidth = 0
if ($defaultFmtIdx -gt 0) {
	$defFmt = Get-Format $defaultFmtIdx
	if ($defFmt -and $defFmt.Width -gt 0) { $defaultWidth = $defFmt.Width }
}

# Build column width map (1-based col → width), only non-default
$colWidthMap = [ordered]@{}
foreach ($col0 in ($colFormatIndices.Keys | Sort-Object)) {
	$fmt = Get-Format $colFormatIndices[$col0]
	if ($fmt -and $fmt.Width -gt 0 -and $fmt.Width -ne $defaultWidth) {
		$col1 = [string]($col0 + 1)
		$colWidthMap.Add($col1, $fmt.Width)
	}
}

# --- 5a. Document height ---

# Needed before merges: a merge pointing past the last row belongs to no cell
$docHeight = 0
$declaredHeight = 0
$hNode = $root.SelectSingleNode("d:height", $ns)
if ($hNode) { $docHeight = [int]$hNode.InnerText; $declaredHeight = $docHeight }
foreach ($ri in $root.SelectNodes("d:rowsItem", $ns)) {
	$idxNode = $ri.SelectSingleNode("d:index", $ns)
	if (-not $idxNode) { continue }
	# Rows past <height> matter only when they actually carry something:
	# templates often keep empty rowsItem entries beyond the declared height
	$rowNode = $ri.SelectSingleNode("d:row", $ns)
	if (-not $rowNode -or -not $rowNode.SelectSingleNode("d:c", $ns)) { continue }
	$last = [int]$idxNode.InnerText
	$itNode = $ri.SelectSingleNode("d:indexTo", $ns)
	if ($itNode) { $last = [int]$itNode.InnerText }
	if (($last + 1) -gt $docHeight) { $docHeight = $last + 1 }
}

# --- 6. Extract merges ---

$mergeMap = @{}
$mergeColsByRow = @{}
$extraMerges = @()
foreach ($mNode in $root.SelectNodes("d:merge", $ns)) {
	$r = [int]$mNode.SelectSingleNode("d:r", $ns).InnerText
	$c = [int]$mNode.SelectSingleNode("d:c", $ns).InnerText
	$wNode = $mNode.SelectSingleNode("d:w", $ns)
	$w = if ($wNode) { [int]$wNode.InnerText } else { 0 }
	$hNode = $mNode.SelectSingleNode("d:h", $ns)
	$h = if ($hNode) { [int]$hNode.InnerText } else { 0 }

	# -1 means "all rows" / "all columns", and a row past the end of the document
	# has no cell either — such merges are carried over verbatim
	if ($r -lt 0 -or $c -lt 0 -or $r -ge $docHeight) {
		$extraMerges += [ordered]@{ r = $r; c = $c; w = $w; h = $h }
		continue
	}

	$mergeMap["$r,$c"] = @{ W = $w; H = $h }
	if (-not $mergeColsByRow.ContainsKey($r)) { $mergeColsByRow[$r] = @() }
	$mergeColsByRow[$r] += $c
}

# --- 7. Extract named items ---

$namedAreas = @()
foreach ($niNode in $root.SelectNodes("d:namedItem", $ns)) {
	$xsiType = $niNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsiType -ne "NamedItemCells") { continue }

	$areaNode = $niNode.SelectSingleNode("d:area", $ns)
	$areaType = $areaNode.SelectSingleNode("d:type", $ns).InnerText

	$namedAreas += @{
		Name     = $niNode.SelectSingleNode("d:name", $ns).InnerText
		Type     = $areaType
		BeginRow = [int]$areaNode.SelectSingleNode("d:beginRow", $ns).InnerText
		EndRow   = [int]$areaNode.SelectSingleNode("d:endRow", $ns).InnerText
		BeginCol = [int]$areaNode.SelectSingleNode("d:beginColumn", $ns).InnerText
		EndCol   = [int]$areaNode.SelectSingleNode("d:endColumn", $ns).InnerText
	}
}

# Block mode (areas = sequence of row blocks) describes the document without loss
# only when every area is a Rows area, no two of them overlap, and together they
# cover every row. Otherwise fall back to flat mode: whole grid in "rows" plus
# coordinates in "namedAreas".
$rowAreas = @($namedAreas | Where-Object { $_.Type -eq "Rows" })
$flatMode = $rowAreas.Count -ne $namedAreas.Count

# Degenerate ranges (empty or inverted) cannot be expressed as a block
foreach ($a in $rowAreas) {
	if ($a.BeginRow -lt 0 -or $a.EndRow -lt $a.BeginRow) { $flatMode = $true; break }
}

if (-not $flatMode) {
	for ($i = 0; $i -lt $rowAreas.Count -and -not $flatMode; $i++) {
		for ($j = $i + 1; $j -lt $rowAreas.Count; $j++) {
			if ($rowAreas[$i].BeginRow -le $rowAreas[$j].EndRow -and
				$rowAreas[$j].BeginRow -le $rowAreas[$i].EndRow) {
				$flatMode = $true
				break
			}
		}
	}
}

if (-not $flatMode -and $docHeight -gt 0) {
	$covered = @{}
	foreach ($a in $rowAreas) {
		for ($r = $a.BeginRow; $r -le $a.EndRow; $r++) { $covered[$r] = $true }
	}
	for ($r = 0; $r -lt $docHeight; $r++) {
		if (-not $covered.ContainsKey($r)) { $flatMode = $true; break }
	}
}

# --- 8. Extract rows ---

# Cell children the DSL models itself; the rest is carried over verbatim
$modelledCellChildren = @("f", "parameter", "detailParameter", "tl")

$rowData = @{}
foreach ($riNode in $root.SelectNodes("d:rowsItem", $ns)) {
	$rowIdx = [int]$riNode.SelectSingleNode("d:index", $ns).InnerText
	$rowNode = $riNode.SelectSingleNode("d:row", $ns)

	$indexTo = $rowIdx
	$itNode = $riNode.SelectSingleNode("d:indexTo", $ns)
	if ($itNode) { $indexTo = [int]$itNode.InnerText }

	$rowFmtIdx = 0
	$fmtNode = $rowNode.SelectSingleNode("d:formatIndex", $ns)
	if ($fmtNode) { $rowFmtIdx = [int]$fmtNode.InnerText }

	$isEmpty = $false
	$emptyNode = $rowNode.SelectSingleNode("d:empty", $ns)
	if ($emptyNode -and $emptyNode.InnerText -eq "true") { $isEmpty = $true }

	$cells = @()
	if (-not $isEmpty) {
		$col = -1
		foreach ($cGroup in $rowNode.SelectNodes("d:c", $ns)) {
			$iNode = $cGroup.SelectSingleNode("d:i", $ns)
			if ($iNode) { $col = [int]$iNode.InnerText }
			else { $col++ }

			$cContent = $cGroup.SelectSingleNode("d:c", $ns)
			if (-not $cContent) { continue }

			$cellFmtIdx = 0
			$fNode = $cContent.SelectSingleNode("d:f", $ns)
			if ($fNode) { $cellFmtIdx = [int]$fNode.InnerText }

			$param = $null
			$pNode = $cContent.SelectSingleNode("d:parameter", $ns)
			if ($pNode) { $param = $pNode.InnerText }

			$detail = $null
			$dNode = $cContent.SelectSingleNode("d:detailParameter", $ns)
			if ($dNode) { $detail = $dNode.InnerText }

			# Cell text can carry several languages; keep the plain string form
			# when there is only the document language
			$text = $null
			$textByLang = $null
			$tlItems = $cContent.SelectNodes("d:tl/v8:item", $ns)
			if ($tlItems.Count -eq 1) {
				$cNode = $tlItems[0].SelectSingleNode("v8:content", $ns)
				$lNode = $tlItems[0].SelectSingleNode("v8:lang", $ns)
				if ($cNode) { $text = $cNode.InnerText }
				if ($lNode -and $lNode.InnerText -ne $textLang) {
					$textByLang = [ordered]@{ $lNode.InnerText = $text }
				}
			} elseif ($tlItems.Count -gt 1) {
				$textByLang = [ordered]@{}
				foreach ($it in $tlItems) {
					$cNode = $it.SelectSingleNode("v8:content", $ns)
					$lNode = $it.SelectSingleNode("v8:lang", $ns)
					if (-not $cNode -or -not $lNode) { continue }
					$textByLang[$lNode.InnerText] = $cNode.InnerText
					if (-not $text) { $text = $cNode.InnerText }
				}
			}

			# Everything else the cell carries — value, control, note and the like.
			# Kept verbatim so nothing is silently dropped.
			$extra = @()
			foreach ($ch in $cContent.ChildNodes) {
				# An empty <tl> holds no text to model — carry it over as is
				if ($ch.Name -eq "tl" -and $tlItems.Count -gt 0) { continue }
				if ($ch.Name -ne "tl" -and $modelledCellChildren -contains $ch.Name) { continue }
				$extra += [ordered]@{ name = $ch.Name; xml = (Strip-Xmlns $ch.OuterXml) }
			}

			$cells += @{
				Col        = $col
				FormatIdx  = $cellFmtIdx
				Param      = $param
				Detail     = $detail
				Text       = $text
				TextByLang = $textByLang
				Extra      = $extra
			}
		}
	}

	for ($r = $rowIdx; $r -le $indexTo; $r++) {
		$rowData[$r] = @{
			FormatIdx = $rowFmtIdx
			Cells     = $cells
			Empty     = $isEmpty
		}
	}
}

# --- 9. Build style key (ignoring fillType) ---

function Get-BorderDesc {
	param($fmt)
	if (-not $fmt) { return @{ Border = "none"; Thick = $false } }

	$lb = Test-LineVisible $fmt.LB; $tb = Test-LineVisible $fmt.TB
	$rb = Test-LineVisible $fmt.RB; $bb = Test-LineVisible $fmt.BB

	if (-not $lb -and -not $tb -and -not $rb -and -not $bb) {
		return @{ Border = "none"; Thick = $false }
	}

	$thick = $false
	foreach ($bIdx in @($fmt.LB, $fmt.TB, $fmt.RB, $fmt.BB)) {
		if ($bIdx -ge 0 -and $bIdx -lt $rawLines.Count -and
			$rawLines[$bIdx].Style -ne "None" -and $rawLines[$bIdx].Width -ge 2) {
			$thick = $true; break
		}
	}

	# Per-side line identity: needed both to tell Dotted from Solid and to notice
	# that sides of one cell use different lines
	$perSide = [ordered]@{}
	foreach ($pair in @(@("top", $fmt.TB), @("bottom", $fmt.BB), @("left", $fmt.LB), @("right", $fmt.RB))) {
		$idx = $pair[1]
		if (-not (Test-LineVisible $idx)) { continue }
		if ($idx -ge 0 -and $idx -lt $rawLines.Count) {
			$perSide[$pair[0]] = @{ Style = $rawLines[$idx].Style; Width = $rawLines[$idx].Width }
		} else {
			$perSide[$pair[0]] = @{ Style = "Solid"; Width = 1 }
		}
	}

	# The compact form only covers plain solid lines of one width on every side
	$uniform = $true
	$firstKey = $null
	foreach ($k in $perSide.Keys) {
		$s = $perSide[$k]
		$key = "$($s.Width)|$($s.Style)"
		if ($s.Style -ne "Solid") { $uniform = $false; break }
		if ($null -eq $firstKey) { $firstKey = $key }
		elseif ($key -ne $firstKey) { $uniform = $false; break }
	}

	if ($lb -and $tb -and $rb -and $bb) {
		return @{ Border = "all"; Thick = $thick; PerSide = $perSide; Uniform = $uniform }
	}

	$sides = @()
	if ($tb) { $sides += "top" }
	if ($bb) { $sides += "bottom" }
	if ($lb) { $sides += "left" }
	if ($rb) { $sides += "right" }

	return @{ Border = ($sides -join ","); Thick = $thick; PerSide = $perSide; Uniform = $uniform }
}

# Stable text form of the per-side border description
function Get-BorderKey {
	param($bd)
	$parts = @()
	foreach ($k in $bd.PerSide.Keys) {
		$s = $bd.PerSide[$k]
		$parts += "$k=$($s.Width)/$($s.Style)"
	}
	return ($parts -join ";")
}

function Get-StyleKey {
	param($fmt)
	if (-not $fmt) { return "empty" }
	# -1 means the format has no <font> at all, which is not the same as font 0
	$fi = $fmt.FontIdx
	$bd = Get-BorderDesc $fmt
	$bc = $fmt.BorderColor
	$bk = Get-BorderKey $bd
	# Carried-over properties are part of the style: two formats differing only in
	# them must not collapse into one
	$ex = ""
	if ($fmt.Extra -and $fmt.Extra.Count -gt 0) {
		$ex = (@($fmt.Extra | ForEach-Object { $_.xml }) -join "")
	}
	$dfl = ""
	if ($fmt.DataFormatByLang) {
		$dfl = (@($fmt.DataFormatByLang.Keys | ForEach-Object { "$_=$($fmt.DataFormatByLang[$_])" }) -join ";")
	}
	return "f=$fi|b=$bk|ha=$($fmt.HA)|va=$($fmt.VA)|wr=$($fmt.Wrap)|df=$($fmt.DataFormat)|dfl=$dfl|tc=$($fmt.TextColor)|bc=$bc|hd=$($fmt.Hidden)|in=$(if ($fmt.HasIndent) { $fmt.Indent } else { '-' })|w=$(if ($fmt.HasWidth) { $fmt.Width } else { '-' })|h=$(if ($fmt.HasHeight) { $fmt.Height } else { '-' })|ex=$ex"
}

# --- 10. Name fonts ---

$fontNames = @{}
$fontDefs = [ordered]@{}

if ($rawFonts.Count -gt 0) {
	$fontNames[0] = "default"
	$fontDefs["default"] = $rawFonts[0]
}

function Get-FontKey {
	param($f)
	$size = if ($f.HasSize) { [System.Convert]::ToString($f.Size, $invariant) } else { "-" }
	return "$($f.Face)|$size|$($f.Bold)|$($f.Italic)|$($f.Underline)|$($f.Strikeout)|$($f.Ref)|$($f.Kind)"
}

$fontKeyMap = @{}
$fontKeyMap[(Get-FontKey $rawFonts[0])] = "default"

for ($i = 1; $i -lt $rawFonts.Count; $i++) {
	$f = $rawFonts[$i]
	$df = $rawFonts[0]

	# Dedup: if identical font already named, reuse
	$fKey = Get-FontKey $f
	if ($fontKeyMap.ContainsKey($fKey)) {
		$fontNames[$i] = $fontKeyMap[$fKey]
		continue
	}

	$name = $null

	if ($f.Face -eq $df.Face -and $f.Size -eq $df.Size) {
		if ($f.Bold -and -not $df.Bold -and -not $f.Italic -and -not $f.Underline -and -not $f.Strikeout) {
			$name = "bold"
		} elseif ($f.Italic -and -not $df.Italic -and -not $f.Bold) {
			$name = "italic"
		} elseif ($f.Underline -and -not $df.Underline -and -not $f.Bold -and -not $f.Italic) {
			$name = "underline"
		}
	} elseif ($f.Face -eq $df.Face -and $f.Size -gt $df.Size -and $f.Bold) {
		$name = "header"
	} elseif ($f.Face -eq $df.Face -and $f.Size -lt $df.Size) {
		$name = "small"
	}

	if (-not $name) {
		$parts = @()
		if ($f.Face -and $f.Face -ne $df.Face) { $parts += $f.Face.ToLower() }
		$parts += [System.Convert]::ToString($f.Size, $invariant)
		if ($f.Bold) { $parts += "bold" }
		if ($f.Italic) { $parts += "italic" }
		if ($f.Underline) { $parts += "underline" }
		if ($f.Strikeout) { $parts += "strikeout" }
		$name = $parts -join "-"
	}

	$baseName = $name; $suffix = 2
	while ($fontDefs.Contains($name)) { $name = "$baseName$suffix"; $suffix++ }

	$fontNames[$i] = $name
	$fontDefs[$name] = $f
	$fontKeyMap[$fKey] = $name
}

# --- 11. Collect and name styles ---

$styleKeys = [ordered]@{}
$formatToStyleKey = @{}

foreach ($r in $rowData.Values) {
	foreach ($cell in $r.Cells) {
		$fmt = Get-Format $cell.FormatIdx
		if (-not $fmt) { continue }
		$key = Get-StyleKey $fmt
		if (-not $styleKeys.Contains($key)) { $styleKeys[$key] = $fmt }
		$formatToStyleKey[$cell.FormatIdx] = $key
	}
}

function Name-Style {
	param($fmt)
	if (-not $fmt) { return "default" }
	$parts = @()

	$fi = if ($fmt.FontIdx -ge 0) { $fmt.FontIdx } else { 0 }
	if ($fontNames.ContainsKey($fi) -and $fontNames[$fi] -ne "default") {
		$parts += $fontNames[$fi]
	}

	$bd = Get-BorderDesc $fmt
	if ($bd.Border -ne "none") {
		if ($bd.Border -eq "all") { $parts += "bordered" }
		else { $parts += "border-$($bd.Border)" }
	}

	if ($fmt.HA -eq "Center") { $parts += "center" }
	elseif ($fmt.HA -eq "Right") { $parts += "right" }
	if ($fmt.VA -eq "Center") { $parts += "vcenter" }
	elseif ($fmt.VA -eq "Top") { $parts += "vtop" }
	elseif ($fmt.VA -eq "Bottom") { $parts += "vbottom" }
	if ($fmt.Wrap -eq "Wrap") { $parts += "wrap" }
	elseif ($fmt.Wrap) { $parts += $fmt.Wrap.ToLower() }
	if ($fmt.DataFormat) { $parts += "fmt" }

	if ($parts.Count -eq 0) { return "default" }
	return ($parts -join "-")
}

$styleNames = [ordered]@{}
$styleDefs = [ordered]@{}

foreach ($key in $styleKeys.Keys) {
	$fmt = $styleKeys[$key]
	$name = Name-Style $fmt

	$baseName = $name; $suffix = 2
	while ($styleDefs.Contains($name)) { $name = "$baseName$suffix"; $suffix++ }

	$styleNames[$key] = $name

	$sDef = [ordered]@{}
	if ($fmt.FontIdx -lt 0) {
		# The format names no font at all — an empty name says exactly that
		$sDef["font"] = ""
	} elseif ($fontNames.ContainsKey($fmt.FontIdx) -and $fontNames[$fmt.FontIdx] -ne "default") {
		$sDef["font"] = $fontNames[$fmt.FontIdx]
	}
	# Any token the platform uses, not just the three or four common ones
	if ($fmt.HA) { $sDef["align"] = $fmt.HA.ToLower() }
	if ($fmt.VA) { $sDef["valign"] = $fmt.VA.ToLower() }
	$bd = Get-BorderDesc $fmt
	if ($bd.Border -ne "none") {
		if ($bd.Uniform) {
			$sDef["border"] = $bd.Border
			if ($bd.Thick) { $sDef["borderWidth"] = "thick" }
		} else {
			# Sides differ in line style or width — describe each on its own
			$borders = [ordered]@{}
			foreach ($k in $bd.PerSide.Keys) {
				$s = $bd.PerSide[$k]
				$borders[$k] = [ordered]@{ style = $s.Style; width = $s.Width }
			}
			$sDef["borders"] = $borders
		}
	}
	if ($fmt.Wrap -eq "Wrap") { $sDef["wrap"] = $true }
	elseif ($fmt.Wrap) { $sDef["textPlacement"] = $fmt.Wrap.ToLower() }
	if ($fmt.DataFormatByLang) { $sDef["format"] = $fmt.DataFormatByLang }
	elseif ($fmt.DataFormat) { $sDef["format"] = $fmt.DataFormat }
	# A cell format can carry width/height of its own, zero included
	if ($fmt.HasWidth) { $sDef["width"] = $fmt.Width }
	if ($fmt.HasHeight) { $sDef["height"] = $fmt.Height }
	if ($fmt.TextColor) { $sDef["textColor"] = $fmt.TextColor }
	if ($fmt.BorderColor) { $sDef["borderColor"] = $fmt.BorderColor }
	if ($fmt.Hidden) { $sDef["hidden"] = ($fmt.Hidden -eq "true") }
	if ($fmt.HasIndent) { $sDef["indent"] = $fmt.Indent }

	# Properties the DSL does not model, plus the element order of the original
	# format so the compiler can reproduce it exactly
	if ($fmt.Extra -and $fmt.Extra.Count -gt 0) {
		$sDef["extra"] = [array]$fmt.Extra
		$sDef["order"] = [array]$fmt.Order
	}

	$styleDefs[$name] = $sDef
}

function Get-StyleName {
	param([int]$fmtIdx)
	$key = $formatToStyleKey[$fmtIdx]
	if ($key -and $styleNames.Contains($key)) { return $styleNames[$key] }
	return "default"
}

# --- 12. Build rows and areas ---

# One document row -> DSL row object
function Build-DslRow {
	param([int]$globalRow)

	$rd = $rowData[$globalRow]
	$mergeCols = if ($mergeColsByRow.ContainsKey($globalRow)) { $mergeColsByRow[$globalRow] } else { @() }

	if (-not $rd -or $rd.Empty) {
		# A row without cells can still carry a height and anchor merges
		$keptFmt = if ($rd) { $rd.FormatIdx } else { 0 }
		$rowFmt = Get-Format $keptFmt
		$hasHeight = $rowFmt -and $rowFmt.Height -gt 0

		if ($mergeCols.Count -eq 0 -and -not $hasHeight) { return [ordered]@{} }
		$rd = @{ FormatIdx = $keptFmt; Cells = @(); Empty = $false }
	}

	$dslRow = [ordered]@{}

	# Row height
	if ($rd.FormatIdx -gt 0) {
		$rowFmt = Get-Format $rd.FormatIdx
		if ($rowFmt -and $rowFmt.Height -gt 0) { $dslRow["height"] = $rowFmt.Height }
	}

	# Separate content cells from gap-fill cells
	$contentCells = @()
	$gapCells = @()

	foreach ($cell in $rd.Cells) {
		$cf = Get-Format $cell.FormatIdx
		$hasContent = $cell.Param -or $cell.Text -or ($cf -and $cf.ContainsValue) -or
			($cell.Extra -and $cell.Extra.Count -gt 0)
		$hasMerge = $mergeMap.ContainsKey("$globalRow,$($cell.Col)")

		if ($hasContent -or $hasMerge) {
			$contentCells += $cell
		} else {
			$gapCells += $cell
		}
	}

	# Detect rowStyle
	$rowStyleName = $null
	$rowStyleKey = $null

	# rowStyle fills every column of the row on compile, so it is only safe when the
	# row is materialized over the full width and all gap cells share one style
	$rowIsFull = $rd.Cells.Count -ge $totalColumns

	if ($gapCells.Count -gt 0 -and $rowIsFull) {
		$gapKeys = @{}
		foreach ($gc in $gapCells) {
			$fmt = Get-Format $gc.FormatIdx
			$gapKeys[(Get-StyleKey $fmt)] = $true
		}

		if ($gapKeys.Count -eq 1) {
			$rowStyleKey = @($gapKeys.Keys)[0]
			if ($styleNames.Contains($rowStyleKey)) {
				$rowStyleName = $styleNames[$rowStyleKey]
			}
		}
	}

	# Gap cells that rowStyle does not cover have to be written out explicitly,
	# otherwise their borders are lost
	if (-not $rowStyleName) {
		foreach ($gc in $gapCells) { $contentCells += $gc }
		$gapCells = @()
	}

	if ($rowStyleName -and $rowStyleName -ne "default") { $dslRow["rowStyle"] = $rowStyleName }

	# Build cell list
	$dslCells = @()

	foreach ($cell in ($contentCells | Sort-Object { $_.Col })) {
		$dslCell = [ordered]@{ col = $cell.Col + 1 }

		# Span/rowspan from merge
		$mk = "$globalRow,$($cell.Col)"
		if ($mergeMap.ContainsKey($mk)) {
			$m = $mergeMap[$mk]
			if ($m.W -gt 0) { $dslCell["span"] = $m.W + 1 }
			if ($m.H -gt 0) { $dslCell["rowspan"] = $m.H + 1 }
			# A 1x1 merge record carries no span but still exists in the document
			if ($m.W -eq 0 -and $m.H -eq 0) { $dslCell["merge"] = $true }
		}

		# Style
		$cellFmt = Get-Format $cell.FormatIdx
		$cellStyleKey = Get-StyleKey $cellFmt

		if ($cell.FormatIdx -le 0) {
			# The cell names no format at all — an empty style says exactly that
			$dslCell["style"] = ""
		} elseif ($rowStyleKey -and $cellStyleKey -eq $rowStyleKey) {
			# Inherits rowStyle
		} else {
			$sn = Get-StyleName $cell.FormatIdx
			if ($sn -ne "default" -or -not $rowStyleName) {
				$dslCell["style"] = $sn
			}
		}

		# Content
		$fillType = if ($cellFmt) { $cellFmt.FillType } else { "" }

		$textValue = if ($cell.TextByLang) { $cell.TextByLang } else { $cell.Text }

		# A detail parameter can stand on its own, without a parameter
		if ($cell.Detail) { $dslCell["detail"] = $cell.Detail }

		if ($cell.Param) {
			$dslCell["param"] = $cell.Param
		} elseif ($fillType -eq "Template" -and $cell.Text) {
			$dslCell["template"] = $textValue
		} elseif ($cell.Text) {
			$dslCell["text"] = $textValue
		}

		if ($cell.Extra -and $cell.Extra.Count -gt 0) { $dslCell["extra"] = [array]$cell.Extra }

		# A cell can declare a fill type without carrying content — the compiler
		# would not guess it from the content, so state it
		$autoFill = ""
		if ($dslCell["param"]) { $autoFill = "Parameter" }
		elseif ($dslCell["template"]) { $autoFill = "Template" }
		elseif ($dslCell["text"]) { $autoFill = "Text" }
		if ($fillType -and $fillType -ne $autoFill) { $dslCell["fillType"] = $fillType }

		# Input cell
		if ($cellFmt -and $cellFmt.ContainsValue) {
			$ct = $cellFmt.ControlType
			if ($ct -and $controlTypeNames.ContainsKey($ct)) { $dslCell["input"] = $controlTypeNames[$ct] }
			elseif ($ct) { $dslCell["input"] = $ct }
			else { $dslCell["input"] = "field" }

			if ($cellFmt.ValueType) { $dslCell["valueType"] = $cellFmt.ValueType }
		}

		$dslCells += $dslCell
	}

	# Merges anchored at positions without a cell record — emit a bare cell so the
	# merge survives the round trip
	$knownCols = @{}
	foreach ($cell in $rd.Cells) { $knownCols[$cell.Col] = $true }
	foreach ($mc in $mergeCols) {
		if ($knownCols.ContainsKey($mc)) { continue }
		$m = $mergeMap["$globalRow,$mc"]
		$dslCell = [ordered]@{ col = $mc + 1 }
		if ($m.W -gt 0) { $dslCell["span"] = $m.W + 1 }
		if ($m.H -gt 0) { $dslCell["rowspan"] = $m.H + 1 }
		if ($m.W -eq 0 -and $m.H -eq 0) { $dslCell["merge"] = $true }
		$dslCells += $dslCell
	}

	if ($dslCells.Count -gt 0) {
		$dslRow["cells"] = [array]($dslCells | Sort-Object { $_.col })
	}
	return $dslRow
}

# Compress consecutive empty rows ({}) into { empty = N }
function Compress-EmptyRows {
	param($rows)
	$compressed = @()
	$emptyRun = 0
	foreach ($r in $rows) {
		if ($r.Count -eq 0) {
			$emptyRun++
		} else {
			if ($emptyRun -gt 0) {
				if ($emptyRun -eq 1) { $compressed += [ordered]@{} }
				else { $compressed += [ordered]@{ empty = $emptyRun } }
				$emptyRun = 0
			}
			$compressed += $r
		}
	}
	if ($emptyRun -gt 0) {
		if ($emptyRun -eq 1) { $compressed += [ordered]@{} }
		else { $compressed += [ordered]@{ empty = $emptyRun } }
	}
	return ,$compressed
}

$dslAreas = @()
$dslRows = @()
$dslNamedAreas = @()

if ($flatMode) {
	# Whole grid in one "rows" list, areas keep their absolute coordinates
	$allRows = @()
	for ($globalRow = 0; $globalRow -lt $docHeight; $globalRow++) {
		$allRows += Build-DslRow $globalRow
	}
	$dslRows = Compress-EmptyRows $allRows

	foreach ($area in $namedAreas) {
		# Each bound is written on its own: the platform does emit half-open areas
		# such as beginColumn=-1 with endColumn=41 ("from the first column")
		$na = [ordered]@{ name = $area.Name; type = $area.Type }
		if ($area.BeginRow -ge 0) { $na["firstRow"] = $area.BeginRow + 1 }
		if ($area.EndRow -ge 0) { $na["lastRow"] = $area.EndRow + 1 }
		if ($area.BeginCol -ge 0) { $na["firstCol"] = $area.BeginCol + 1 }
		if ($area.EndCol -ge 0) { $na["lastCol"] = $area.EndCol + 1 }
		$dslNamedAreas += $na
	}
} else {
	# Blocks are written out one after another, so they must go in row order —
	# the template lists namedItem elements in arbitrary order
	foreach ($area in ($namedAreas | Sort-Object { $_.BeginRow })) {
		$areaRows = @()
		for ($globalRow = $area.BeginRow; $globalRow -le $area.EndRow; $globalRow++) {
			$areaRows += Build-DslRow $globalRow
		}

		$dslAreas += [ordered]@{
			name = $area.Name
			rows = [array](Compress-EmptyRows $areaRows)
		}
	}
}

# --- 13. Compress columnWidths ---

$compressedWidths = [ordered]@{}
if ($colWidthMap.Count -gt 0) {
	$grouped = $colWidthMap.Keys | Group-Object { $colWidthMap[$_] }
	foreach ($g in $grouped) {
		$width = [int]$g.Name
		$cols = @($g.Group | Sort-Object { [int]$_ })

		$ranges = @()
		$rangeStart = $cols[0]; $rangePrev = $cols[0]

		for ($i = 1; $i -lt $cols.Count; $i++) {
			if ([int]$cols[$i] -eq [int]$rangePrev + 1) {
				$rangePrev = $cols[$i]
			} else {
				if ($rangeStart -eq $rangePrev) { $ranges += "$rangeStart" }
				else { $ranges += "$rangeStart-$rangePrev" }
				$rangeStart = $cols[$i]; $rangePrev = $cols[$i]
			}
		}
		if ($rangeStart -eq $rangePrev) { $ranges += "$rangeStart" }
		else { $ranges += "$rangeStart-$rangePrev" }

		foreach ($range in $ranges) { $compressedWidths[$range] = $width }
	}
}

# --- 14. Build fonts output ---

$fontsOut = [ordered]@{}
foreach ($name in $fontDefs.Keys) {
	$f = $fontDefs[$name]
	$fOut = [ordered]@{ face = $f.Face }
	if ($f.HasSize) { $fOut["size"] = $f.Size }

	$isSystemFont = $f.Ref -or ($f.Kind -and $f.Kind -ne "Absolute")
	if ($isSystemFont -and $f.HasStyleAttrs) {
		# Spell them out, false included, exactly as the template does
		$fOut["bold"] = $f.Bold
		$fOut["italic"] = $f.Italic
		$fOut["underline"] = $f.Underline
		$fOut["strikeout"] = $f.Strikeout
	} else {
		if ($f.Bold) { $fOut["bold"] = $true }
		if ($f.Italic) { $fOut["italic"] = $true }
		if ($f.Underline) { $fOut["underline"] = $true }
		if ($f.Strikeout) { $fOut["strikeout"] = $true }
	}

	if ($f.Ref) { $fOut["ref"] = $f.Ref }
	if ($f.Kind -and $f.Kind -ne "Absolute") { $fOut["kind"] = $f.Kind }
	$fontsOut[$name] = $fOut
}

# --- 15. Assemble result ---

$result = [ordered]@{
	columns      = $totalColumns
	defaultWidth = $defaultWidth
}
# Some templates keep leftover rows past their declared height — carry the
# declared value over so the geometry of the document does not change
if ($flatMode -and $declaredHeight -gt 0 -and $declaredHeight -ne $docHeight) {
	$result["height"] = $declaredHeight
}
# Only worth carrying when the template is not the plain single-language default
$multiLang = $langSettings -and $langSettings["list"] -and $langSettings["list"].Count -gt 1
if ($textLang -ne "ru" -or $multiLang) {
	$langsOut = if ($langSettings) { $langSettings } else { [ordered]@{} }
	$langsOut["text"] = $textLang
	$result["languages"] = $langsOut
}
if ($compressedWidths.Count -gt 0) { $result["columnWidths"] = $compressedWidths }
# Remove empty "default" style
if ($styleDefs.Contains("default") -and $styleDefs["default"].Count -eq 0) {
	$styleDefs.Remove("default")
}

# Remove unused styles
$usedStyles = @{}
$allDslRows = @()
if ($flatMode) { $allDslRows = $dslRows }
else { foreach ($a in $dslAreas) { $allDslRows += $a.rows } }

foreach ($r in $allDslRows) {
	if ($r.rowStyle) { $usedStyles[$r.rowStyle] = $true }
	if ($r.cells) { foreach ($c in $r.cells) { if ($c.style) { $usedStyles[$c.style] = $true } } }
}
$toRemove = @($styleDefs.Keys | Where-Object { -not $usedStyles.ContainsKey($_) })
foreach ($s in $toRemove) { $styleDefs.Remove($s)
}

$result["fonts"] = $fontsOut
$result["styles"] = $styleDefs
if ($extraMerges.Count -gt 0) { $result["extraMerges"] = [array]$extraMerges }
if ($flatMode) {
	$result["rows"] = [array]$dslRows
	$result["namedAreas"] = [array]$dslNamedAreas
} else {
	$result["areas"] = [array]$dslAreas
}

# --- 16. Convert to JSON and fix Unicode ---

$json = $result | ConvertTo-Json -Depth 10

# PS 5.1 escapes non-ASCII as \uXXXX — unescape back to UTF-8
$json = [regex]::Replace($json, '\\u([0-9A-Fa-f]{4})', {
	param($m)
	[char][int]("0x" + $m.Groups[1].Value)
})

# --- 17. Output ---

if ($OutputPath) {
	$enc = New-Object System.Text.UTF8Encoding($false)
	$resolvedOut = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
	[System.IO.File]::WriteAllText($resolvedOut, $json, $enc)
	Write-Host "[OK] Decompiled: $OutputPath"
} else {
	Write-Output $json
}

$rowCount = if ($flatMode) { $dslRows.Count } else { $rowData.Count }
$byType = @($namedAreas | Group-Object { $_.Type } | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ", "
$mode = if ($flatMode) { "flat" } else { "blocks" }
$inputCells = @($rawFormats | Where-Object { $_.ContainsValue }).Count

Write-Host "     Mode: $mode, Areas: $($namedAreas.Count) ($byType), Rows: $rowCount, Columns: $totalColumns" -ForegroundColor DarkGray
Write-Host "     Fonts: $($fontDefs.Count), Styles: $($styleDefs.Count), Merges: $($mergeMap.Count + $extraMerges.Count), Input formats: $inputCells" -ForegroundColor DarkGray
