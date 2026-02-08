param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$json = Get-Content -Raw -Encoding UTF8 $JsonPath
$def = $json | ConvertFrom-Json

if (-not $def.columns) {
	Write-Error "Required field 'columns' is missing"
	exit 1
}
if (-not $def.areas) {
	Write-Error "Required field 'areas' is missing"
	exit 1
}

$totalColumns = [int]$def.columns
$defaultWidth = if ($def.defaultWidth) { [int]$def.defaultWidth } else { 10 }

# --- 2. Build font palette ---

$fontMap = [ordered]@{}   # name -> 0-based index
$fontEntries = @()        # array of hashtables

function Add-Font {
	param([string]$name, $fontDef)
	$face = if ($fontDef.face) { $fontDef.face } else { "Arial" }
	$size = if ($fontDef.size) { [int]$fontDef.size } else { 10 }
	$bold = if ($fontDef.bold -eq $true) { "true" } else { "false" }
	$italic = if ($fontDef.italic -eq $true) { "true" } else { "false" }

	$idx = $script:fontEntries.Count
	$script:fontMap[$name] = $idx
	$script:fontEntries += @{
		Face   = $face
		Size   = $size
		Bold   = $bold
		Italic = $italic
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

# --- 3. Determine line palette ---

$hasBorders = $false

# Scan styles for border usage
if ($def.styles) {
	foreach ($prop in $def.styles.PSObject.Properties) {
		if ($prop.Value.border -and $prop.Value.border -ne "none") {
			$hasBorders = $true
			break
		}
	}
}

$solidLineIndex = -1
if ($hasBorders) {
	$solidLineIndex = 0
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

# Build column width map: 1-based col -> width
$colWidthMap = @{}
if ($def.columnWidths) {
	foreach ($prop in $def.columnWidths.PSObject.Properties) {
		$width = [int]$prop.Value
		$columns = Parse-ColumnSpec $prop.Name
		foreach ($c in $columns) {
			$colWidthMap[$c] = $width
		}
	}
}

# --- 5. Style resolver ---

function Resolve-Style {
	param([string]$styleName, [string]$fillType)

	$fontIdx = $fontMap["default"]
	$lb = -1; $tb = -1; $rb = -1; $bb = -1
	$ha = ""; $va = ""
	$wrap = $false

	if ($styleName -and $def.styles) {
		$style = $def.styles.$styleName
		if ($style) {
			# Font
			if ($style.font -and $fontMap.Contains($style.font)) {
				$fontIdx = $fontMap[$style.font]
			}

			# Borders
			if ($style.border) {
				switch ($style.border) {
					"all" {
						$lb = $solidLineIndex; $tb = $solidLineIndex
						$rb = $solidLineIndex; $bb = $solidLineIndex
					}
					"bottom" { $bb = $solidLineIndex }
					"top"    { $tb = $solidLineIndex }
					"none"   { }
				}
			}

			# Alignment
			if ($style.align) {
				switch ($style.align) {
					"left"   { $ha = "Left" }
					"center" { $ha = "Center" }
					"right"  { $ha = "Right" }
				}
			}
			if ($style.valign) {
				switch ($style.valign) {
					"top"    { $va = "Top" }
					"center" { $va = "Center" }
				}
			}

			# Wrap
			if ($style.wrap -eq $true) { $wrap = $true }
		}
	}

	return @{
		FontIdx  = $fontIdx
		LB       = $lb; TB = $tb; RB = $rb; BB = $bb
		HA       = $ha; VA = $va
		Wrap     = $wrap
		FillType = $fillType
	}
}

# --- 6. Format palette builder ---

$formatRegistry = [ordered]@{}  # key -> hashtable with properties
$formatOrder = @()              # ordered keys for index assignment

function Get-FormatKey {
	param(
		[int]$fontIdx = -1,
		[int]$lb = -1, [int]$tb = -1, [int]$rb = -1, [int]$bb = -1,
		[string]$ha = "", [string]$va = "",
		[bool]$wrap = $false,
		[string]$fillType = "",
		[int]$width = -1,
		[int]$height = -1
	)
	return "f=$fontIdx|lb=$lb|tb=$tb|rb=$rb|bb=$bb|ha=$ha|va=$va|wr=$wrap|ft=$fillType|w=$width|h=$height"
}

function Register-Format {
	param([string]$key, [hashtable]$props)
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
$defaultFormatKey = Get-FormatKey -width $defaultWidth
$defaultFormatIndex = Register-Format -key $defaultFormatKey -props @{ Width = $defaultWidth }

# 6b. Column width formats
$colFormatMap = @{}  # 1-based col -> format index
foreach ($col in $colWidthMap.Keys) {
	$w = $colWidthMap[$col]
	$key = Get-FormatKey -width $w
	$idx = Register-Format -key $key -props @{ Width = $w }
	$colFormatMap[[int]$col] = $idx
}

# 6c. Scan areas for row heights and cell formats
# We need to do two passes: first collect all formats, then generate XML

# Helper: determine fillType from cell content
function Get-FillType {
	param($cell)
	if ($cell.param) { return "Parameter" }
	if ($cell.template) { return "Template" }
	if ($cell.text) { return "Text" }
	return ""
}

# Helper: register a cell format and return its index
function Register-CellFormat {
	param($styleName, [string]$fillType)
	$resolved = Resolve-Style -styleName $styleName -fillType $fillType
	$key = Get-FormatKey -fontIdx $resolved.FontIdx `
		-lb $resolved.LB -tb $resolved.TB -rb $resolved.RB -bb $resolved.BB `
		-ha $resolved.HA -va $resolved.VA `
		-wrap $resolved.Wrap -fillType $resolved.FillType
	$props = @{
		FontIdx  = $resolved.FontIdx
		LB       = $resolved.LB; TB = $resolved.TB
		RB       = $resolved.RB; BB = $resolved.BB
		HA       = $resolved.HA; VA = $resolved.VA
		Wrap     = $resolved.Wrap
		FillType = $resolved.FillType
	}
	return Register-Format -key $key -props $props
}

# Pre-register all formats from areas
foreach ($area in $def.areas) {
	foreach ($row in $area.rows) {
		# Row height format
		if ($row.height) {
			$hKey = Get-FormatKey -height ([int]$row.height)
			Register-Format -key $hKey -props @{ Height = [int]$row.height } | Out-Null
		}

		# rowStyle gap-fill format (no content → no fillType)
		if ($row.rowStyle) {
			Register-CellFormat -styleName $row.rowStyle -fillType "" | Out-Null
		}

		# Explicit cell formats
		if ($row.cells) {
			foreach ($cell in $row.cells) {
				$cellStyle = if ($cell.style) { $cell.style } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				Register-CellFormat -styleName $cellStyle -fillType $ft | Out-Null
			}
		}
	}
}

# --- 7. Generate XML ---

$xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

# 7a. Header
X '<?xml version="1.0" encoding="UTF-8"?>'
X '<document xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'

# 7b. Language settings
X "`t<languageSettings>"
X "`t`t<currentLanguage>ru</currentLanguage>"
X "`t`t<defaultLanguage>ru</defaultLanguage>"
X "`t`t<languageInfo>"
X "`t`t`t<id>ru</id>"
X "`t`t`t<code>Русский</code>"
X "`t`t`t<description>Русский</description>"
X "`t`t</languageInfo>"
X "`t</languageSettings>"

# 7c. Columns
X "`t<columns>"
X "`t`t<size>$totalColumns</size>"

# Emit columnsItem for columns with non-default widths
foreach ($col in ($colFormatMap.Keys | Sort-Object)) {
	$fmtIdx = $colFormatMap[$col]
	$colIdx = $col - 1  # Convert to 0-based
	X "`t`t<columnsItem>"
	X "`t`t`t<index>$colIdx</index>"
	X "`t`t`t<column>"
	X "`t`t`t`t<formatIndex>$fmtIdx</formatIndex>"
	X "`t`t`t</column>"
	X "`t`t</columnsItem>"
}

X "`t</columns>"

# 7d. Rows — main generation loop
$globalRow = 0
$merges = @()
$namedItems = @()
$totalRowCount = 0

foreach ($area in $def.areas) {
	$areaStartRow = $globalRow
	$areaName = $area.name

	foreach ($row in $area.rows) {
		$rowHasContent = $false
		$rowCells = @()  # array of { Col(0-based), FormatIdx, Content }

		# Determine row height format
		$rowFormatIdx = 0
		if ($row.height) {
			$hKey = Get-FormatKey -height ([int]$row.height)
			# Find format index for this key
			$rIdx = 0
			foreach ($k in $formatRegistry.Keys) {
				$rIdx++
				if ($k -eq $hKey) { $rowFormatIdx = $rIdx; break }
			}
		}

		if ($row.cells -and $row.cells.Count -gt 0) {
			$rowHasContent = $true

			# Build set of occupied columns (1-based)
			$occupiedCols = @{}
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
				$cellStyle = if ($cell.style) { $cell.style } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				$fmtIdx = Register-CellFormat -styleName $cellStyle -fillType $ft

				$cellInfo = @{
					Col       = $colStart - 1  # 0-based
					FormatIdx = $fmtIdx
					Param     = $cell.param
					Detail    = $cell.detail
					Text      = $cell.text
					Template  = $cell.template
				}
				$rowCells += $cellInfo

				# Collect merge
				if ($colSpan -gt 1) {
					$merges += @{
						R = $globalRow
						C = $colStart - 1
						W = $colSpan - 1
					}
				}
			}

			# Generate gap-fill cells for rowStyle
			if ($row.rowStyle) {
				$gapFmtIdx = Register-CellFormat -styleName $row.rowStyle -fillType ""
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

		} elseif ($row.rowStyle) {
			# Row with only rowStyle, no explicit cells — fill all columns
			$rowHasContent = $true
			$gapFmtIdx = Register-CellFormat -styleName $row.rowStyle -fillType ""
			for ($c = 0; $c -lt $totalColumns; $c++) {
				$rowCells += @{
					Col       = $c
					FormatIdx = $gapFmtIdx
					Param     = $null
					Detail    = $null
					Text      = $null
					Template  = $null
				}
			}
		}

		# Emit rowsItem
		X "`t<rowsItem>"
		X "`t`t<index>$globalRow</index>"
		X "`t`t<row>"

		if ($rowFormatIdx -gt 0) {
			X "`t`t`t<formatIndex>$rowFormatIdx</formatIndex>"
		}

		if (-not $rowHasContent) {
			X "`t`t`t<empty>true</empty>"
		} else {
			foreach ($cellInfo in $rowCells) {
				X "`t`t`t<c>"
				X "`t`t`t`t<i>$($cellInfo.Col)</i>"
				X "`t`t`t`t<c>"
				X "`t`t`t`t`t<f>$($cellInfo.FormatIdx)</f>"

				if ($cellInfo.Param) {
					X "`t`t`t`t`t<parameter>$($cellInfo.Param)</parameter>"
					if ($cellInfo.Detail) {
						X "`t`t`t`t`t<detailParameter>$($cellInfo.Detail)</detailParameter>"
					}
				}

				if ($cellInfo.Text) {
					X "`t`t`t`t`t<tl>"
					X "`t`t`t`t`t`t<v8:item>"
					X "`t`t`t`t`t`t`t<v8:lang>ru</v8:lang>"
					X "`t`t`t`t`t`t`t<v8:content>$($cellInfo.Text)</v8:content>"
					X "`t`t`t`t`t`t</v8:item>"
					X "`t`t`t`t`t</tl>"
				}

				if ($cellInfo.Template) {
					X "`t`t`t`t`t<tl>"
					X "`t`t`t`t`t`t<v8:item>"
					X "`t`t`t`t`t`t`t<v8:lang>ru</v8:lang>"
					X "`t`t`t`t`t`t`t<v8:content>$($cellInfo.Template)</v8:content>"
					X "`t`t`t`t`t`t</v8:item>"
					X "`t`t`t`t`t</tl>"
				}

				X "`t`t`t`t</c>"
				X "`t`t`t</c>"
			}
		}

		X "`t`t</row>"
		X "`t</rowsItem>"

		$globalRow++
	}

	$areaEndRow = $globalRow - 1
	$namedItems += @{
		Name     = $areaName
		BeginRow = $areaStartRow
		EndRow   = $areaEndRow
	}
}

$totalRowCount = $globalRow

# 7e. Scalar metadata
X "`t<templateMode>true</templateMode>"
X "`t<defaultFormatIndex>$defaultFormatIndex</defaultFormatIndex>"
X "`t<height>$totalRowCount</height>"
X "`t<vgRows>$totalRowCount</vgRows>"

# 7f. Merges
foreach ($m in $merges) {
	X "`t<merge>"
	X "`t`t<r>$($m.R)</r>"
	X "`t`t<c>$($m.C)</c>"
	X "`t`t<w>$($m.W)</w>"
	X "`t</merge>"
}

# 7g. Named items
foreach ($ni in $namedItems) {
	X "`t<namedItem xsi:type=`"NamedItemCells`">"
	X "`t`t<name>$($ni.Name)</name>"
	X "`t`t<area>"
	X "`t`t`t<type>Rows</type>"
	X "`t`t`t<beginRow>$($ni.BeginRow)</beginRow>"
	X "`t`t`t<endRow>$($ni.EndRow)</endRow>"
	X "`t`t`t<beginColumn>-1</beginColumn>"
	X "`t`t`t<endColumn>-1</endColumn>"
	X "`t`t</area>"
	X "`t</namedItem>"
}

# 7h. Line palette
if ($hasBorders) {
	X "`t<line width=`"1`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
	X "`t</line>"
}

# 7i. Font palette
foreach ($fe in $fontEntries) {
	X "`t<font faceName=`"$($fe.Face)`" height=`"$($fe.Size)`" bold=`"$($fe.Bold)`" italic=`"$($fe.Italic)`" underline=`"false`" strikeout=`"false`" kind=`"Absolute`" scale=`"100`"/>"
}

# 7j. Format palette
foreach ($key in $formatRegistry.Keys) {
	$fmt = $formatRegistry[$key]
	X "`t<format>"

	if ($fmt.FontIdx -ne $null -and $fmt.FontIdx -ge 0) {
		X "`t`t<font>$($fmt.FontIdx)</font>"
	}
	if ($fmt.LB -ne $null -and $fmt.LB -ge 0) {
		X "`t`t<leftBorder>$($fmt.LB)</leftBorder>"
	}
	if ($fmt.TB -ne $null -and $fmt.TB -ge 0) {
		X "`t`t<topBorder>$($fmt.TB)</topBorder>"
	}
	if ($fmt.RB -ne $null -and $fmt.RB -ge 0) {
		X "`t`t<rightBorder>$($fmt.RB)</rightBorder>"
	}
	if ($fmt.BB -ne $null -and $fmt.BB -ge 0) {
		X "`t`t<bottomBorder>$($fmt.BB)</bottomBorder>"
	}
	if ($fmt.Width) {
		X "`t`t<width>$($fmt.Width)</width>"
	}
	if ($fmt.Height) {
		X "`t`t<height>$($fmt.Height)</height>"
	}
	if ($fmt.HA) {
		X "`t`t<horizontalAlignment>$($fmt.HA)</horizontalAlignment>"
	}
	if ($fmt.VA) {
		X "`t`t<verticalAlignment>$($fmt.VA)</verticalAlignment>"
	}
	if ($fmt.Wrap -eq $true) {
		X "`t`t<textPlacement>Wrap</textPlacement>"
	}
	if ($fmt.FillType) {
		X "`t`t<fillType>$($fmt.FillType)</fillType>"
	}

	X "`t</format>"
}

# 7k. Close document
X '</document>'

# --- 8. Write output ---

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OutputPath), $xml.ToString(), $enc)

# --- 9. Summary ---

Write-Host "[OK] Compiled: $OutputPath"
Write-Host "     Areas: $($namedItems.Count), Rows: $totalRowCount, Columns: $totalColumns"
Write-Host "     Fonts: $($fontEntries.Count), Lines: $(if ($hasBorders) { 1 } else { 0 }), Formats: $($formatRegistry.Count)"
Write-Host "     Merges: $($merges.Count)"
