# mxl-validate v1.8 — Validate 1C spreadsheet
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Position=0)]
	[Alias('Path')]
	[string]$TemplatePath,
	[string]$ProcessorName,
	[string]$TemplateName,
	[string]$SrcDir = "src",
	[switch]$Detailed,
	[int]$MaxErrors = 20
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve template path ---

if (-not $TemplatePath) {
	if (-not $ProcessorName -or -not $TemplateName) {
		Write-Error "Specify -TemplatePath or both -ProcessorName and -TemplateName"
		exit 1
	}
	$TemplatePath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $SrcDir $ProcessorName) "Templates") $TemplateName) "Ext") "Template.xml"
}

# A: Directory → Ext/Template.xml
if (Test-Path $TemplatePath -PathType Container) {
	$TemplatePath = Join-Path (Join-Path $TemplatePath "Ext") "Template.xml"
}
# B1: Missing Ext/ (e.g. Templates/Макет/Template.xml → Templates/Макет/Ext/Template.xml)
if (-not (Test-Path $TemplatePath)) {
	$fn = [System.IO.Path]::GetFileName($TemplatePath)
	if ($fn -eq "Template.xml") {
		$c = Join-Path (Join-Path (Split-Path $TemplatePath) "Ext") $fn
		if (Test-Path $c) { $TemplatePath = $c }
	}
}
# B2: Descriptor (Templates/Макет.xml → Templates/Макет/Ext/Template.xml)
if (-not (Test-Path $TemplatePath) -and $TemplatePath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::GetFileNameWithoutExtension($TemplatePath)
	$dir = Split-Path $TemplatePath
	$c = Join-Path (Join-Path (Join-Path $dir $stem) "Ext") "Template.xml"
	if (Test-Path $c) { $TemplatePath = $c }
}

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

# --- Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load((Resolve-Path $TemplatePath).Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("d", "http://v8.1c.ru/8.2/data/spreadsheet")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$nsMgr.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

$root = $xmlDoc.DocumentElement

# --- Counters ---

$errors = 0
$warnings = 0
$stopped = $false
$script:okCount = 0

function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Write-Host "[OK]    $msg" }
}

function Report-Error {
	param([string]$msg)
	$script:errors++
	Write-Host "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}

function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Write-Host "[WARN]  $msg"
}

$templateName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($TemplatePath)))
if ($Detailed) {
	# Форма имени та же, что в итоговой строке и у py-порта: раньше шапка -Detailed
	# печаталась без префикса «Template.», и вывод портов расходился одной строкой.
	Write-Host "=== Validation: Template.$templateName ==="
	Write-Host ""
}

# --- Collect palettes ---

$lineNodes = $root.SelectNodes("d:line", $nsMgr)
$lineCount = $lineNodes.Count

$fontNodes = @()
foreach ($node in $root.ChildNodes) {
	if ($node.LocalName -eq "font") { $fontNodes += $node }
}
$fontCount = $fontNodes.Count

$formatNodes = @()
foreach ($node in $root.ChildNodes) {
	if ($node.LocalName -eq "format") { $formatNodes += $node }
}
$formatCount = $formatNodes.Count

$pictureNodes = $root.SelectNodes("d:picture", $nsMgr)
$pictureCount = $pictureNodes.Count

# --- Collect column sets ---

$columnSets = @{}  # id -> size
$defaultColCount = 0

foreach ($cols in $root.SelectNodes("d:columns", $nsMgr)) {
	$sizeNode = $cols.SelectSingleNode("d:size", $nsMgr)
	$idNode = $cols.SelectSingleNode("d:id", $nsMgr)
	$size = if ($sizeNode) { [int]$sizeNode.InnerText } else { 0 }

	if ($idNode) {
		$columnSets[$idNode.InnerText] = $size
	} else {
		$defaultColCount = $size
	}
}

# --- Check 1: height vs actual rows ---

$rowNodes = $root.SelectNodes("d:rowsItem", $nsMgr)
$heightNode = $root.SelectSingleNode("d:height", $nsMgr)
$docHeight = if ($heightNode) { [int]$heightNode.InnerText } else { 0 }

# Find max row index (not all rows have rowsItem - implicit rows are skipped)
$maxRowIndex = -1
foreach ($ri in $rowNodes) {
	$idxNode = $ri.SelectSingleNode("d:index", $nsMgr)
	if ($idxNode) {
		$idx = [int]$idxNode.InnerText
		if ($idx -gt $maxRowIndex) { $maxRowIndex = $idx }
	}
}

$expectedMinHeight = $maxRowIndex + 1
if ($docHeight -ge $expectedMinHeight) {
	Report-OK "height ($docHeight) >= max row index + 1 ($expectedMinHeight), rowsItem count=$($rowNodes.Count)"
} else {
	Report-Error "height=$docHeight but max row index=$maxRowIndex (need at least $expectedMinHeight)"
}
# --- Check 2: vgRows <= height ---

$vgRowsNode = $root.SelectSingleNode("d:vgRows", $nsMgr)
if ($vgRowsNode) {
	$vgRows = [int]$vgRowsNode.InnerText
	if ($vgRows -le $docHeight) {
		Report-OK "vgRows ($vgRows) <= height ($docHeight)"
	} else {
		Report-Warn "vgRows ($vgRows) > height ($docHeight)"
	}
}

# --- Build row data for checks ---

$maxFormatRef = 0
$maxFontRef = 0
$maxLineRef = 0

# Check format palette references in formats (font, border indices)
foreach ($fmt in $formatNodes) {
	$fontIdx = $fmt.SelectSingleNode("d:font", $nsMgr)
	if ($fontIdx) {
		$val = [int]$fontIdx.InnerText
		if ($val -gt $maxFontRef) { $maxFontRef = $val }
	}

	foreach ($border in @("d:leftBorder", "d:topBorder", "d:rightBorder", "d:bottomBorder", "d:drawingBorder")) {
		$borderNode = $fmt.SelectSingleNode($border, $nsMgr)
		if ($borderNode) {
			$val = [int]$borderNode.InnerText
			if ($val -gt $maxLineRef) { $maxLineRef = $val }
		}
	}
}

# --- Check 10: font indices in formats ---

if ($fontCount -gt 0) {
	if ($maxFontRef -lt $fontCount) {
		Report-OK "Font refs: max=$maxFontRef, palette size=$fontCount"
	} else {
		Report-Error "Font index $maxFontRef exceeds palette size ($fontCount)"
	}
} elseif ($maxFontRef -gt 0) {
	Report-Error "Font index $maxFontRef referenced but no fonts defined"
} else {
	Report-OK "No font references"
}

# --- Check 11: line/border indices in formats ---

if ($lineCount -gt 0) {
	if ($maxLineRef -lt $lineCount) {
		Report-OK "Line/border refs: max=$maxLineRef, palette size=$lineCount"
	} else {
		Report-Error "Line index $maxLineRef exceeds palette size ($lineCount)"
	}
} elseif ($maxLineRef -gt 0) {
	Report-Error "Line index $maxLineRef referenced but no lines defined"
} else {
	Report-OK "No line/border references"
}

# --- Check 3, 4, 5, 6: row/cell checks ---

$maxCellFormatRef = 0
$maxRowFormatRef = 0
$maxDefaultColIdx = 0
$rowIndex = 0

foreach ($ri in $rowNodes) {
	if ($stopped) { break }

	$idxNode = $ri.SelectSingleNode("d:index", $nsMgr)
	$rowIndex = if ($idxNode) { [int]$idxNode.InnerText } else { $rowIndex }

	$row = $ri.SelectSingleNode("d:row", $nsMgr)
	if (-not $row) { continue }

	# Row formatIndex
	$rowFmtNode = $row.SelectSingleNode("d:formatIndex", $nsMgr)
	if ($rowFmtNode) {
		$val = [int]$rowFmtNode.InnerText
		if ($val -gt $maxRowFormatRef) { $maxRowFormatRef = $val }
		if ($val -gt $formatCount) {
			Report-Error "Row ${rowIndex}: formatIndex=$val > format palette size ($formatCount)"
		}
	}

	# Check columnsID
	$rowColsId = $null
	$colsIdNode = $row.SelectSingleNode("d:columnsID", $nsMgr)
	if ($colsIdNode) {
		$rowColsId = $colsIdNode.InnerText
		if (-not $columnSets.ContainsKey($rowColsId)) {
			Report-Error "Row ${rowIndex}: columnsID '$($rowColsId.Substring(0,8))...' not found in column sets"
		}
	}

	# Determine column count for this row
	$rowColCount = $defaultColCount
	if ($rowColsId -and $columnSets.ContainsKey($rowColsId)) {
		$rowColCount = $columnSets[$rowColsId]
	}

	# Cell checks
	foreach ($cGroup in $row.SelectNodes("d:c", $nsMgr)) {
		$iNode = $cGroup.SelectSingleNode("d:i", $nsMgr)
		if ($iNode) {
			$colIdx = [int]$iNode.InnerText
			# Track max index for default column set only
			if (-not $rowColsId -and $colIdx -gt $maxDefaultColIdx) {
				$maxDefaultColIdx = $colIdx
			}
			# Check against row's column count
			if ($rowColCount -gt 0 -and $colIdx -ge $rowColCount) {
				Report-Error "Row ${rowIndex}: column index $colIdx >= column count ($rowColCount)"
			}
		}

		$cell = $cGroup.SelectSingleNode("d:c", $nsMgr)
		if ($cell) {
			$fNode = $cell.SelectSingleNode("d:f", $nsMgr)
			if ($fNode) {
				$val = [int]$fNode.InnerText
				if ($val -gt $maxCellFormatRef) { $maxCellFormatRef = $val }
				if ($val -gt $formatCount) {
					Report-Error "Row ${rowIndex}: cell format index $val > format palette size ($formatCount)"
				}
			}
			# Примечание — четвёртый владелец формата, и его ссылка тоже бывает битой.
			$noteNode = $cell.SelectSingleNode("d:note", $nsMgr)
			if ($noteNode) {
				$nf = $noteNode.SelectSingleNode("d:formatIndex", $nsMgr)
				if ($nf -and [int]$nf.InnerText -gt $formatCount) {
					Report-Error "Row ${rowIndex}: note format index $($nf.InnerText) > format palette size ($formatCount)"
				}
			}
		}
	}

	$rowIndex++
}

# Summary checks for format refs
if (-not $stopped) {
	if ($maxCellFormatRef -le $formatCount -and $maxRowFormatRef -le $formatCount) {
		Report-OK "Format refs: max cell=$maxCellFormatRef, max row=$maxRowFormatRef, palette size=$formatCount"
	}
}

# Check column format indices
foreach ($cols in $root.SelectNodes("d:columns", $nsMgr)) {
	if ($stopped) { break }
	foreach ($ci in $cols.SelectNodes("d:columnsItem", $nsMgr)) {
		$col = $ci.SelectSingleNode("d:column", $nsMgr)
		if ($col) {
			$fmtNode = $col.SelectSingleNode("d:formatIndex", $nsMgr)
			if ($fmtNode) {
				$val = [int]$fmtNode.InnerText
				if ($val -gt $formatCount) {
					$colIdx = $ci.SelectSingleNode("d:index", $nsMgr).InnerText
					Report-Error "Column ${colIdx}: formatIndex=$val > format palette size ($formatCount)"
				}
			}
		}
	}
}

# --- Check 5: column index summary ---

if (-not $stopped) {
	Report-OK "Column indices: max in default set=$maxDefaultColIdx, default column count=$defaultColCount"
}

# --- Check 7, 8: named areas ---

foreach ($ni in $root.SelectNodes("d:namedItem", $nsMgr)) {
	if ($stopped) { break }

	$niType = $ni.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	$name = $ni.SelectSingleNode("d:name", $nsMgr).InnerText

	if ($niType -like "*NamedItemCells*") {
		$area = $ni.SelectSingleNode("d:area", $nsMgr)
		$beginRow = [int]$area.SelectSingleNode("d:beginRow", $nsMgr).InnerText
		$endRow = [int]$area.SelectSingleNode("d:endRow", $nsMgr).InnerText

		# Check row bounds (skip -1 which means "all")
		if ($beginRow -ne -1 -and $beginRow -ge $docHeight) {
			Report-Error "Area '$name': beginRow=$beginRow >= height=$docHeight"
		}
		if ($endRow -ne -1 -and $endRow -ge $docHeight) {
			Report-Error "Area '$name': endRow=$endRow >= height=$docHeight"
		}

		# Check columnsID reference
		$colsIdNode = $area.SelectSingleNode("d:columnsID", $nsMgr)
		if ($colsIdNode) {
			$colsId = $colsIdNode.InnerText
			if (-not $columnSets.ContainsKey($colsId)) {
				Report-Error "Area '$name': columnsID '$($colsId.Substring(0,8))...' not found"
			}
		}
	}
}

# --- Check 9: merge bounds ---

foreach ($merge in $root.SelectNodes("d:merge", $nsMgr)) {
	if ($stopped) { break }

	$r = [int]$merge.SelectSingleNode("d:r", $nsMgr).InnerText
	$c = [int]$merge.SelectSingleNode("d:c", $nsMgr).InnerText
	$wNode = $merge.SelectSingleNode("d:w", $nsMgr)
	$hNode = $merge.SelectSingleNode("d:h", $nsMgr)

	# r=-1 means all rows, skip bound check
	if ($r -ne -1 -and $r -ge $docHeight) {
		Report-Error "Merge at row=${r}, col=${c}: row >= height ($docHeight)"
	}

	if ($hNode -and $r -ne -1) {
		$h = [int]$hNode.InnerText
		if (($r + $h) -ge $docHeight) {
			Report-Error "Merge at row=${r}: extends to row $($r + $h) >= height ($docHeight)"
		}
	}

	# Check columnsID in merge
	$colsIdNode = $merge.SelectSingleNode("d:columnsID", $nsMgr)
	if ($colsIdNode) {
		$colsId = $colsIdNode.InnerText
		if (-not $columnSets.ContainsKey($colsId)) {
			Report-Error "Merge at row=${r}, col=${c}: columnsID '$($colsId.Substring(0,8))...' not found"
		}
	}
}

# --- Check 12: drawing picture indices ---

foreach ($drawing in $root.SelectNodes("d:drawing", $nsMgr)) {
	if ($stopped) { break }

	$picIdxNode = $drawing.SelectSingleNode("d:pictureIndex", $nsMgr)
	if ($picIdxNode) {
		$picIdx = [int]$picIdxNode.InnerText
		if ($picIdx -gt $pictureCount) {
			$drawId = $drawing.SelectSingleNode("d:id", $nsMgr).InnerText
			Report-Error "Drawing id=${drawId}: pictureIndex=$picIdx > picture count ($pictureCount)"
		}
	}
	# Оформление рисунка — такая же запись палитры форматов, как у ячейки, и висячая
	# ссылка на неё так же валит загрузку макета.
	$fmtIdxNode = $drawing.SelectSingleNode("d:formatIndex", $nsMgr)
	if ($fmtIdxNode) {
		$fmtIdx = [int]$fmtIdxNode.InnerText
		if ($fmtIdx -gt $formatCount) {
			$drawId = $drawing.SelectSingleNode("d:id", $nsMgr).InnerText
			Report-Error "Drawing id=${drawId}: formatIndex=$fmtIdx > format palette size ($formatCount)"
		}
	}
}

# --- Check 13: value cells (input fields) ---
# Свойства containsValue/valueType/controlType принадлежат ЯЧЕЙКЕ: на корпусе ERP
# (370 197 ссылок) на такие записи палитры ссылаются только <f>, ни строка, ни колонка,
# ни defaultFormatIndex. Ячейка со значением текста не несёт — ни одна из 370 197.

$valueFormatIdx = @{}
$controlGuids = @('381ed624-9217-4e63-85db-c4c3cb87daae', '35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26')
for ($i = 0; $i -lt $formatNodes.Count; $i++) {
	$fmt = $formatNodes[$i]
	$contains = $fmt.SelectSingleNode("d:containsValue", $nsMgr)
	$vt = $fmt.SelectSingleNode("d:valueType", $nsMgr)
	if (-not $contains -and -not $vt) { continue }
	$num = $i + 1
	$valueFormatIdx[$num] = $true
	if (-not $contains -or $contains.InnerText.Trim() -cne 'true') {
		Report-Error "Format ${num}: <valueType> without <containsValue>true</containsValue>"
	} elseif (-not $vt) {
		Report-Error "Format ${num}: <containsValue> without <valueType>"
	}
	if ($vt) {
		foreach ($child in $vt.ChildNodes) {
			if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
			$tag = $child.get_LocalName()
			if ($tag -cne 'Type' -and $tag -cne 'TypeSet' -and $tag -notlike '*Qualifiers') {
				Report-Error "Format ${num}: unexpected <$tag> inside <valueType>"
			}
		}
	}
	$ctl = $fmt.SelectSingleNode("d:controlType", $nsMgr)
	if ($ctl -and ($controlGuids -notcontains $ctl.InnerText.Trim().ToLowerInvariant())) {
		Report-Warn "Format ${num}: unknown controlType $($ctl.InnerText.Trim())"
	}
	# Флажок Конфигуратор предлагает только для булева и числа. Движок принимает его на любом
	# типе (проверено сборкой EPF и обратной выгрузкой), поэтому это предупреждение, а не ошибка:
	# собрать такую ячейку в Конфигураторе нельзя, и почти наверняка это описка.
	if ($ctl -and $ctl.InnerText.Trim().ToLowerInvariant() -ceq $controlGuids[1] -and $vt) {
		$kinds = @()
		foreach ($child in $vt.ChildNodes) {
			if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
			if ($child.get_LocalName() -ceq 'Type') { $kinds += $child.InnerText.Trim() }
		}
		if (-not (($kinds.Count -eq 1) -and ($kinds[0] -ceq 'xs:boolean' -or $kinds[0] -ceq 'xs:decimal'))) {
			Report-Warn "Format ${num}: checkbox control on a type other than Boolean or Number"
		}
	}
}

foreach ($ri in $root.SelectNodes("d:rowsItem", $nsMgr)) {
	if ($stopped) { break }
	$row = $ri.SelectSingleNode("d:row", $nsMgr)
	if (-not $row) { continue }
	$idxNode = $ri.SelectSingleNode("d:index", $nsMgr)
	$rn = if ($idxNode) { $idxNode.InnerText } else { '?' }
	$rowFmt = $row.SelectSingleNode("d:formatIndex", $nsMgr)
	if ($rowFmt -and $valueFormatIdx.ContainsKey([int]$rowFmt.InnerText)) {
		Report-Warn "Row ${rn}: formatIndex points to a value format (cell-only property)"
	}
	foreach ($cGroup in $row.SelectNodes("d:c", $nsMgr)) {
		$cell = $cGroup.SelectSingleNode("d:c", $nsMgr)
		if (-not $cell) { continue }
		$fNode = $cell.SelectSingleNode("d:f", $nsMgr)
		if (-not $fNode -or -not $valueFormatIdx.ContainsKey([int]$fNode.InnerText)) {
			# Значение и настройки элемента управления бывают только у ячейки-поля ввода:
			# на корпусе ни одного <v> и ни одного <control> в обычной ячейке.
			if ($cell.SelectSingleNode("d:v", $nsMgr)) {
				Report-Error "Row ${rn}: cell carries value but its format has no containsValue"
			}
			if ($cell.SelectSingleNode("d:control", $nsMgr)) {
				Report-Error "Row ${rn}: cell carries control settings but its format has no containsValue"
			}
			continue
		}
		if ($cell.SelectSingleNode("d:tl", $nsMgr)) {
			Report-Error "Row ${rn}: cell contains a value and text at the same time"
		}
	}
}
foreach ($cols in $root.SelectNodes("d:columns", $nsMgr)) {
	foreach ($ci in $cols.SelectNodes("d:columnsItem", $nsMgr)) {
		$col = $ci.SelectSingleNode("d:column", $nsMgr)
		if (-not $col) { continue }
		$fmtNode = $col.SelectSingleNode("d:formatIndex", $nsMgr)
		if ($fmtNode -and $valueFormatIdx.ContainsKey([int]$fmtNode.InnerText)) {
			$colIdxNode = $ci.SelectSingleNode("d:index", $nsMgr)
			$colIdxText = if ($colIdxNode) { $colIdxNode.InnerText } else { '?' }
			Report-Warn "Column ${colIdxText}: formatIndex points to a value format (cell-only property)"
		}
	}
}
$dfi = $root.SelectSingleNode("d:defaultFormatIndex", $nsMgr)
if ($dfi -and $valueFormatIdx.ContainsKey([int]$dfi.InnerText)) {
	Report-Warn "defaultFormatIndex points to a value format (cell-only property)"
}
if ($valueFormatIdx.Count -gt 0) {
	Report-OK "Value cells: $($valueFormatIdx.Count) value formats"
}

# --- Check 14: группировки строк и колонок ---
# Диапазоны группировок либо вложены, либо не пересекаются: на корпусе 40 620 886 пар
# непересекающихся и 599 958 вложенных, частичных пересечений нет ни одного.

foreach ($tag in @('vg', 'hg')) {
	$ranges = @()
	foreach ($g in $root.SelectNodes("d:$tag", $nsMgr)) {
		$bNode = $g.SelectSingleNode("d:b", $nsMgr)
		if (-not $bNode) {
			Report-Error "Group <$tag>: <b> is missing"
			continue
		}
		$b = [int]$bNode.InnerText
		$eNode = $g.SelectSingleNode("d:e", $nsMgr)
		$e = if ($eNode) { [int]$eNode.InnerText } else { $b }
		if ($e -lt $b) { Report-Error "Group <$tag> $b..${e}: range is reversed" }
		if ($tag -ceq 'vg' -and $docHeight -gt 0 -and $b -ge $docHeight) {
			Report-Warn "Group <vg> starts at row $b, beyond document height ($docHeight)"
		}
		$ranges += ,@($b, $e)
	}
	for ($i = 0; $i -lt $ranges.Count; $i++) {
		for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
			$a = $ranges[$i]; $c = $ranges[$j]
			if ($a[1] -lt $c[0] -or $c[1] -lt $a[0]) { continue }
			if (($a[0] -le $c[0] -and $c[1] -le $a[1]) -or ($c[0] -le $a[0] -and $a[1] -le $c[1])) { continue }
			Report-Error "Groups <$tag> $($a[0])..$($a[1]) and $($c[0])..$($c[1]) overlap partially"
		}
	}
	if ($ranges.Count -gt 0) { Report-OK "Groups <$tag>: $($ranges.Count)" }
}

# --- Summary ---

$checks = $script:okCount + $errors + $warnings

if ($errors -eq 0 -and $warnings -eq 0 -and -not $Detailed) {
	Write-Host "=== Validation OK: Template.$templateName ($checks checks) ==="
} else {
	Write-Host ""

	if ($stopped) {
		Write-Host "Stopped after $MaxErrors errors. Fix and re-run."
	}

	Write-Host "=== Result: $errors errors, $warnings warnings ($checks checks) ==="
}

if ($errors -gt 0) {
	exit 1
} else {
	exit 0
}
