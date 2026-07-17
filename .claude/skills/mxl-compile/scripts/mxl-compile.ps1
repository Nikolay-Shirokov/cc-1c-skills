# mxl-compile v1.4 — Compile 1C spreadsheet from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
	$underline = if ($fontDef.underline -eq $true) { "true" } else { "false" }
	$strikeout = if ($fontDef.strikeout -eq $true) { "true" } else { "false" }

	$idx = $script:fontEntries.Count
	$script:fontMap[$name] = $idx
	$script:fontEntries += @{
		Face      = $face
		Size      = $size
		Bold      = $bold
		Italic    = $italic
		Underline = $underline
		Strikeout = $strikeout
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

$hasThinBorders = $false
$hasThickBorders = $false

# Scan styles for border usage
if ($def.styles) {
	foreach ($prop in $def.styles.PSObject.Properties) {
		$s = $prop.Value
		if ($s.border -and $s.border -ne "none") {
			if ($s.borderWidth -eq "thick") {
				$hasThickBorders = $true
			} else {
				$hasThinBorders = $true
			}
		}
	}
}

$thinLineIndex = -1
$thickLineIndex = -1
$lineCount = 0
if ($hasThinBorders) {
	$thinLineIndex = $lineCount; $lineCount++
}
if ($hasThickBorders) {
	$thickLineIndex = $lineCount; $lineCount++
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

# --- 4a. Auto-calculate defaultWidth from page format ---

$pageTargets = @{
	"A4-landscape" = 780
	"A4-portrait"  = 540
}

if ($def.page) {
	$pageName = "$($def.page)"
	$targetWidth = $null

	if ($pageName -match '^\d+$') {
		$targetWidth = [int]$pageName
	} elseif ($pageTargets.ContainsKey($pageName)) {
		$targetWidth = $pageTargets[$pageName]
	} else {
		Write-Warning "Unknown page format '$pageName'. Known: $($pageTargets.Keys -join ', '), or a number."
	}

	if ($targetWidth) {
		$totalUnits = 0.0
		$absoluteSum = 0
		$specifiedCols = @{}

		if ($def.columnWidths) {
			foreach ($prop in $def.columnWidths.PSObject.Properties) {
				$val = "$($prop.Value)"
				$cols = Parse-ColumnSpec $prop.Name
				foreach ($c in $cols) {
					$specifiedCols[[int]$c] = $true
					if ($val -match '^([0-9.]+)x$') {
						$totalUnits += [double]$Matches[1]
					} else {
						$absoluteSum += [int]$val
					}
				}
			}
		}

		for ($c = 1; $c -le $totalColumns; $c++) {
			if (-not $specifiedCols.ContainsKey($c)) {
				$totalUnits += 1.0
			}
		}

		if ($totalUnits -gt 0) {
			$defaultWidth = [int][math]::Round(($targetWidth - $absoluteSum) / $totalUnits)
		}
	}
}

# Build column width map: 1-based col -> width
$colWidthMap = @{}
if ($def.columnWidths) {
	foreach ($prop in $def.columnWidths.PSObject.Properties) {
		$val = "$($prop.Value)"
		if ($val -match '^([0-9.]+)x$') {
			$width = [int][math]::Round([double]$Matches[1] * $defaultWidth)
		} else {
			$width = [int]$val
		}
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
	$ha = ""; $va = ""; $nf = ""
	$wrap = $false

	if ($styleName -and $def.styles) {
		$style = $def.styles.$styleName
		if ($style) {
			# Font
			if ($style.font -and $fontMap.Contains($style.font)) {
				$fontIdx = $fontMap[$style.font]
			}

			# Borders
			if ($style.border -and $style.border -ne "none") {
				$lineIdx = if ($style.borderWidth -eq "thick") { $thickLineIndex } else { $thinLineIndex }
				foreach ($side in ($style.border -split ',')) {
					switch ($side.Trim()) {
						"all"    { $lb = $lineIdx; $tb = $lineIdx; $rb = $lineIdx; $bb = $lineIdx }
						"left"   { $lb = $lineIdx }
						"top"    { $tb = $lineIdx }
						"right"  { $rb = $lineIdx }
						"bottom" { $bb = $lineIdx }
					}
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

			# Number format
			if ($style.format) { $nf = $style.format }
		}
	}

	return @{
		FontIdx      = $fontIdx
		LB           = $lb; TB = $tb; RB = $rb; BB = $bb
		HA           = $ha; VA = $va
		Wrap         = $wrap
		FillType     = $fillType
		NumberFormat = $nf
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
		[string]$numberFormat = "",
		[int]$width = -1,
		[int]$height = -1
	)
	return "f=$fontIdx|lb=$lb|tb=$tb|rb=$rb|bb=$bb|ha=$ha|va=$va|wr=$wrap|ft=$fillType|nf=$numberFormat|w=$width|h=$height"
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
foreach ($col in ($colWidthMap.Keys | Sort-Object)) {
	$w = $colWidthMap[$col]
	$key = Get-FormatKey -width $w
	$idx = Register-Format -key $key -props @{ Width = $w }
	$colFormatMap[[int]$col] = $idx
}

# 6c. Scan areas for row heights and cell formats
# We need to do two passes: first collect all formats, then generate XML

# Helper: escape XML special characters
function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

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
		-wrap $resolved.Wrap -fillType $resolved.FillType `
		-numberFormat $resolved.NumberFormat
	$props = @{
		FontIdx      = $resolved.FontIdx
		LB           = $resolved.LB; TB = $resolved.TB
		RB           = $resolved.RB; BB = $resolved.BB
		HA           = $resolved.HA; VA = $resolved.VA
		Wrap         = $resolved.Wrap
		FillType     = $resolved.FillType
		NumberFormat = $resolved.NumberFormat
	}
	return Register-Format -key $key -props $props
}

# Pre-register all formats from areas
foreach ($area in $def.areas) {
	foreach ($row in $area.rows) {
		# Skip empty row placeholder
		if ($row.empty) { continue }

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
	$activeRowspans = @()  # @{ColStart=1-based; ColEnd=1-based; EndLocalRow=int}
	$localRow = 0

	foreach ($row in $area.rows) {
		# Empty row placeholder: emit N empty rows
		if ($row.empty) {
			$count = [int]$row.empty
			for ($ei = 0; $ei -lt $count; $ei++) {
				X "`t<rowsItem>"
				X "`t`t<index>$globalRow</index>"
				X "`t`t<row>"
				X "`t`t`t<empty>true</empty>"
				X "`t`t</row>"
				X "`t</rowsItem>"
				$globalRow++; $localRow++
			}
			continue
		}

		# Build set of columns occupied by rowspans from previous rows
		$rowspanOccupied = @{}  # 1-based col -> $true
		foreach ($rs in $activeRowspans) {
			if ($localRow -gt $rs.StartLocalRow -and $localRow -le $rs.EndLocalRow) {
				for ($c = $rs.ColStart; $c -le $rs.ColEnd; $c++) {
					$rowspanOccupied[$c] = $true
				}
			}
		}

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

			# Build set of occupied columns (1-based): explicit cells + rowspan from above
			$occupiedCols = @{}
			foreach ($rsk in $rowspanOccupied.Keys) { $occupiedCols[$rsk] = $true }
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
				$rowspan = if ($cell.rowspan) { [int]$cell.rowspan } else { 1 }
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

				# Track rowspan for subsequent rows
				if ($rowspan -gt 1) {
					$activeRowspans += @{
						ColStart      = $colStart
						ColEnd        = $colStart + $colSpan - 1
						StartLocalRow = $localRow
						EndLocalRow   = $localRow + $rowspan - 1
					}
				}

				# Collect merge (horizontal, vertical, or both)
				if ($colSpan -gt 1 -or $rowspan -gt 1) {
					$merge = @{ R = $globalRow; C = $colStart - 1; W = $colSpan - 1 }
					if ($rowspan -gt 1) { $merge.H = $rowspan - 1 }
					$merges += $merge
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
			# Row with only rowStyle, no explicit cells — fill non-rowspan columns
			$rowHasContent = $true
			$gapFmtIdx = Register-CellFormat -styleName $row.rowStyle -fillType ""
			for ($c = 1; $c -le $totalColumns; $c++) {
				if ($rowspanOccupied.ContainsKey($c)) { continue }
				$rowCells += @{
					Col       = $c - 1
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
					X "`t`t`t`t`t`t`t<v8:content>$(Esc-Xml $cellInfo.Text)</v8:content>"
					X "`t`t`t`t`t`t</v8:item>"
					X "`t`t`t`t`t</tl>"
				}

				if ($cellInfo.Template) {
					X "`t`t`t`t`t<tl>"
					X "`t`t`t`t`t`t<v8:item>"
					X "`t`t`t`t`t`t`t<v8:lang>ru</v8:lang>"
					X "`t`t`t`t`t`t`t<v8:content>$(Esc-Xml $cellInfo.Template)</v8:content>"
					X "`t`t`t`t`t`t</v8:item>"
					X "`t`t`t`t`t</tl>"
				}

				X "`t`t`t`t</c>"
				X "`t`t`t</c>"
			}
		}

		X "`t`t</row>"
		X "`t</rowsItem>"

		$localRow++
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
	if ($m.H) { X "`t`t<h>$($m.H)</h>" }
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
if ($hasThinBorders) {
	X "`t<line width=`"1`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
	X "`t</line>"
}
if ($hasThickBorders) {
	X "`t<line width=`"2`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
	X "`t</line>"
}

# 7i. Font palette
foreach ($fe in $fontEntries) {
	X "`t<font faceName=`"$($fe.Face)`" height=`"$($fe.Size)`" bold=`"$($fe.Bold)`" italic=`"$($fe.Italic)`" underline=`"$($fe.Underline)`" strikeout=`"$($fe.Strikeout)`" kind=`"Absolute`" scale=`"100`"/>"
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
	if ($fmt.NumberFormat) {
		X "`t`t<format>"
		X "`t`t`t<v8:item>"
		X "`t`t`t`t<v8:lang>ru</v8:lang>"
		X "`t`t`t`t<v8:content>$(Esc-Xml $fmt.NumberFormat)</v8:content>"
		X "`t`t`t</v8:item>"
		X "`t`t</format>"
	}

	X "`t</format>"
}

# 7k. Close document
X '</document>'

# --- 8. Write output ---

$enc = New-Object System.Text.UTF8Encoding($true)
$resolvedPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
Assert-EditAllowed $resolvedPath 'editable'
[System.IO.File]::WriteAllText($resolvedPath, $xml.ToString(), $enc)

# --- 9. Summary ---

Write-Host "[OK] Compiled: $OutputPath"
if ($def.page) {
	Write-Host "     Page: $pageName -> target $targetWidth, defaultWidth=$defaultWidth"
}
Write-Host "     Areas: $($namedItems.Count), Rows: $totalRowCount, Columns: $totalColumns"
Write-Host "     Fonts: $($fontEntries.Count), Lines: $lineCount, Formats: $($formatRegistry.Count)"
Write-Host "     Merges: $($merges.Count)"
