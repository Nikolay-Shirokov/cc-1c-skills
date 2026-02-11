# mxl-validate v1.0 — Validate 1C spreadsheet
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$TemplatePath,
	[string]$ProcessorName,
	[string]$TemplateName,
	[string]$SrcDir = "src",
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

function Report-OK {
	param([string]$msg)
	Write-Host "[OK]    $msg"
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
Write-Host "=== Validation: $templateName ==="
Write-Host ""

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
}

# --- Summary ---

# :finish label equivalent
Write-Host ""
Write-Host "---"

if ($stopped) {
	Write-Host "Stopped after $MaxErrors errors. Fix and re-run."
}

if ($errors -eq 0 -and $warnings -eq 0) {
	Write-Host "All checks passed."
} else {
	Write-Host "Errors: $errors, Warnings: $warnings"
}

if ($errors -gt 0) {
	exit 1
} else {
	exit 0
}
