# mxl-decompile v1.0 — Decompile 1C spreadsheet to JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
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
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("d", "http://v8.1c.ru/8.2/data/spreadsheet")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

# --- 2. Extract font palette ---

$rawFonts = @()
foreach ($fNode in $root.SelectNodes("d:font", $ns)) {
	$rawFonts += @{
		Face      = $fNode.GetAttribute("faceName")
		Size      = [int]$fNode.GetAttribute("height")
		Bold      = $fNode.GetAttribute("bold") -eq "true"
		Italic    = $fNode.GetAttribute("italic") -eq "true"
		Underline = $fNode.GetAttribute("underline") -eq "true"
		Strikeout = $fNode.GetAttribute("strikeout") -eq "true"
	}
}

# --- 3. Extract line palette ---

$rawLines = @()
foreach ($lNode in $root.SelectNodes("d:line", $ns)) {
	$rawLines += @{ Width = [int]$lNode.GetAttribute("width") }
}

# --- 4. Extract format palette ---

$rawFormats = @()
foreach ($fmtNode in $root.SelectNodes("d:format", $ns)) {
	$fmt = @{
		FontIdx = -1
		LB = -1; TB = -1; RB = -1; BB = -1
		Width = 0; Height = 0
		HA = ""; VA = ""
		Wrap = $false; FillType = ""; DataFormat = ""
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

	$n = $fmtNode.SelectSingleNode("d:width", $ns)
	if ($n) { $fmt.Width = [int]$n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:height", $ns)
	if ($n) { $fmt.Height = [int]$n.InnerText }

	$n = $fmtNode.SelectSingleNode("d:horizontalAlignment", $ns)
	if ($n) { $fmt.HA = $n.InnerText }
	$n = $fmtNode.SelectSingleNode("d:verticalAlignment", $ns)
	if ($n) { $fmt.VA = $n.InnerText }

	$n = $fmtNode.SelectSingleNode("d:textPlacement", $ns)
	if ($n -and $n.InnerText -eq "Wrap") { $fmt.Wrap = $true }

	$n = $fmtNode.SelectSingleNode("d:fillType", $ns)
	if ($n) { $fmt.FillType = $n.InnerText }

	$n = $fmtNode.SelectSingleNode("d:format/v8:item/v8:content", $ns)
	if ($n) { $fmt.DataFormat = $n.InnerText }

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

$defaultFmtIdx = 0
$n = $root.SelectSingleNode("d:defaultFormatIndex", $ns)
if ($n) { $defaultFmtIdx = [int]$n.InnerText }

$defaultWidth = 10
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

# --- 6. Extract merges ---

$mergeMap = @{}
foreach ($mNode in $root.SelectNodes("d:merge", $ns)) {
	$r = [int]$mNode.SelectSingleNode("d:r", $ns).InnerText
	$c = [int]$mNode.SelectSingleNode("d:c", $ns).InnerText
	$w = [int]$mNode.SelectSingleNode("d:w", $ns).InnerText
	$hNode = $mNode.SelectSingleNode("d:h", $ns)
	$h = if ($hNode) { [int]$hNode.InnerText } else { 0 }
	$mergeMap["$r,$c"] = @{ W = $w; H = $h }
}

# --- 7. Extract named items ---

$namedAreas = @()
foreach ($niNode in $root.SelectNodes("d:namedItem", $ns)) {
	$xsiType = $niNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsiType -ne "NamedItemCells") { continue }

	$areaNode = $niNode.SelectSingleNode("d:area", $ns)
	$areaType = $areaNode.SelectSingleNode("d:type", $ns).InnerText
	if ($areaType -ne "Rows") { continue }

	$namedAreas += @{
		Name     = $niNode.SelectSingleNode("d:name", $ns).InnerText
		BeginRow = [int]$areaNode.SelectSingleNode("d:beginRow", $ns).InnerText
		EndRow   = [int]$areaNode.SelectSingleNode("d:endRow", $ns).InnerText
	}
}

# --- 8. Extract rows ---

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

			$text = $null
			$tNode = $cContent.SelectSingleNode("d:tl/v8:item/v8:content", $ns)
			if ($tNode) { $text = $tNode.InnerText }

			$cells += @{
				Col       = $col
				FormatIdx = $cellFmtIdx
				Param     = $param
				Detail    = $detail
				Text      = $text
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

	$lb = $fmt.LB -ge 0; $tb = $fmt.TB -ge 0
	$rb = $fmt.RB -ge 0; $bb = $fmt.BB -ge 0

	if (-not $lb -and -not $tb -and -not $rb -and -not $bb) {
		return @{ Border = "none"; Thick = $false }
	}

	$thick = $false
	foreach ($bIdx in @($fmt.LB, $fmt.TB, $fmt.RB, $fmt.BB)) {
		if ($bIdx -ge 0 -and $bIdx -lt $rawLines.Count -and $rawLines[$bIdx].Width -ge 2) {
			$thick = $true; break
		}
	}

	if ($lb -and $tb -and $rb -and $bb) {
		return @{ Border = "all"; Thick = $thick }
	}

	$sides = @()
	if ($tb) { $sides += "top" }
	if ($bb) { $sides += "bottom" }
	if ($lb) { $sides += "left" }
	if ($rb) { $sides += "right" }

	return @{ Border = ($sides -join ","); Thick = $thick }
}

function Get-StyleKey {
	param($fmt)
	if (-not $fmt) { return "empty" }
	$fi = if ($fmt.FontIdx -ge 0) { $fmt.FontIdx } else { 0 }
	$bd = Get-BorderDesc $fmt
	return "f=$fi|b=$($bd.Border)|bw=$($bd.Thick)|ha=$($fmt.HA)|va=$($fmt.VA)|wr=$($fmt.Wrap)|df=$($fmt.DataFormat)"
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
	return "$($f.Face)|$($f.Size)|$($f.Bold)|$($f.Italic)|$($f.Underline)|$($f.Strikeout)"
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
		$parts += "$($f.Size)"
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
	if ($fmt.Wrap) { $parts += "wrap" }
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
	$fi = if ($fmt.FontIdx -ge 0) { $fmt.FontIdx } else { 0 }
	if ($fontNames.ContainsKey($fi) -and $fontNames[$fi] -ne "default") {
		$sDef["font"] = $fontNames[$fi]
	}
	if ($fmt.HA) {
		$a = switch ($fmt.HA) { "Left" { "left" } "Center" { "center" } "Right" { "right" } }
		if ($a) { $sDef["align"] = $a }
	}
	if ($fmt.VA) {
		$a = switch ($fmt.VA) { "Top" { "top" } "Center" { "center" } }
		if ($a) { $sDef["valign"] = $a }
	}
	$bd = Get-BorderDesc $fmt
	if ($bd.Border -ne "none") {
		$sDef["border"] = $bd.Border
		if ($bd.Thick) { $sDef["borderWidth"] = "thick" }
	}
	if ($fmt.Wrap) { $sDef["wrap"] = $true }
	if ($fmt.DataFormat) { $sDef["format"] = $fmt.DataFormat }

	$styleDefs[$name] = $sDef
}

function Get-StyleName {
	param([int]$fmtIdx)
	$key = $formatToStyleKey[$fmtIdx]
	if ($key -and $styleNames.Contains($key)) { return $styleNames[$key] }
	return "default"
}

# --- 12. Build areas ---

$dslAreas = @()

foreach ($area in $namedAreas) {
	$areaRows = @()

	for ($globalRow = $area.BeginRow; $globalRow -le $area.EndRow; $globalRow++) {
		$rd = $rowData[$globalRow]

		if (-not $rd -or $rd.Empty) {
			$areaRows += [ordered]@{}
			continue
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
			$hasContent = $cell.Param -or $cell.Text
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

		if ($gapCells.Count -gt 0) {
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
			}

			# Style
			$cellFmt = Get-Format $cell.FormatIdx
			$cellStyleKey = Get-StyleKey $cellFmt

			if ($rowStyleKey -and $cellStyleKey -eq $rowStyleKey) {
				# Inherits rowStyle
			} else {
				$sn = Get-StyleName $cell.FormatIdx
				if ($sn -ne "default" -or -not $rowStyleName) {
					$dslCell["style"] = $sn
				}
			}

			# Content
			$fillType = if ($cellFmt) { $cellFmt.FillType } else { "" }

			if ($cell.Param) {
				$dslCell["param"] = $cell.Param
				if ($cell.Detail) { $dslCell["detail"] = $cell.Detail }
			} elseif ($fillType -eq "Template" -and $cell.Text) {
				$dslCell["template"] = $cell.Text
			} elseif ($cell.Text) {
				$dslCell["text"] = $cell.Text
			}

			$dslCells += $dslCell
		}

		if ($dslCells.Count -gt 0) { $dslRow["cells"] = [array]$dslCells }
		$areaRows += $dslRow
	}

	# Compress consecutive empty rows ({}) into { empty = N }
	$compressedRows = @()
	$emptyRun = 0
	foreach ($r in $areaRows) {
		if ($r.Count -eq 0) {
			$emptyRun++
		} else {
			if ($emptyRun -gt 0) {
				if ($emptyRun -eq 1) { $compressedRows += [ordered]@{} }
				else { $compressedRows += [ordered]@{ empty = $emptyRun } }
				$emptyRun = 0
			}
			$compressedRows += $r
		}
	}
	if ($emptyRun -gt 0) {
		if ($emptyRun -eq 1) { $compressedRows += [ordered]@{} }
		else { $compressedRows += [ordered]@{ empty = $emptyRun } }
	}

	$dslAreas += [ordered]@{
		name = $area.Name
		rows = [array]$compressedRows
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
	$fOut = [ordered]@{ face = $f.Face; size = $f.Size }
	if ($f.Bold) { $fOut["bold"] = $true }
	if ($f.Italic) { $fOut["italic"] = $true }
	if ($f.Underline) { $fOut["underline"] = $true }
	if ($f.Strikeout) { $fOut["strikeout"] = $true }
	$fontsOut[$name] = $fOut
}

# --- 15. Assemble result ---

$result = [ordered]@{
	columns      = $totalColumns
	defaultWidth = $defaultWidth
}
if ($compressedWidths.Count -gt 0) { $result["columnWidths"] = $compressedWidths }
# Remove empty "default" style
if ($styleDefs.Contains("default") -and $styleDefs["default"].Count -eq 0) {
	$styleDefs.Remove("default")
}

# Remove unused styles
$usedStyles = @{}
foreach ($a in $dslAreas) {
	foreach ($r in $a.rows) {
		if ($r.rowStyle) { $usedStyles[$r.rowStyle] = $true }
		if ($r.cells) { foreach ($c in $r.cells) { if ($c.style) { $usedStyles[$c.style] = $true } } }
	}
}
$toRemove = @($styleDefs.Keys | Where-Object { -not $usedStyles.ContainsKey($_) })
foreach ($s in $toRemove) { $styleDefs.Remove($s)
}

$result["fonts"] = $fontsOut
$result["styles"] = $styleDefs
$result["areas"] = [array]$dslAreas

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
	[System.IO.File]::WriteAllText(
		(Join-Path (Get-Location) $OutputPath),
		$json,
		$enc
	)
	Write-Host "[OK] Decompiled: $OutputPath"
} else {
	Write-Output $json
}

Write-Host "     Areas: $($namedAreas.Count), Rows: $($rowData.Count), Columns: $totalColumns" -ForegroundColor DarkGray
Write-Host "     Fonts: $($fontDefs.Count), Styles: $($styleDefs.Count), Merges: $($mergeMap.Count)" -ForegroundColor DarkGray
