# mxl-compile v1.15 — Compile 1C spreadsheet from JSON (+плоский режим, области всех типов, поля ввода)
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

# --- Detect XML format version ---
# У корня <document> нет атрибута version, поэтому версию берём из конфигурации, в дерево
# которой пишем макет. Вне конфигурации (автономный .xml, исходники EPF) остаётся 2.17.

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

$script:outPathResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
$script:formatVersion = Detect-FormatVersion ([System.IO.Path]::GetDirectoryName($script:outPathResolved))

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
if ($def.rows -and $def.areas) {
	Write-Error "Fields 'rows' and 'areas' are mutually exclusive: 'rows' is the flat mode (whole grid + namedAreas), 'areas' is the block mode"
	exit 1
}
if (-not $def.areas -and -not $def.rows) {
	Write-Error "Required field 'areas' (block mode) or 'rows' (flat mode) is missing"
	exit 1
}

# Normalized row groups: block mode = one group per area, flat mode = single unnamed group
$flatMode = [bool]$def.rows
$rowGroups = @()
if ($flatMode) {
	$rowGroups += @{ Name = $null; Rows = $def.rows }
} else {
	foreach ($area in $def.areas) {
		$rowGroups += @{ Name = $area.name; Rows = $area.rows }
	}
}

$totalColumns = [int]$def.columns
# 0 is a meaningful value: "no default width, columns take the platform's own"
$defaultWidth = if ($null -ne $def.defaultWidth) { [int]$def.defaultWidth } else { 10 }

# Language plain-string cell texts are written under. `text` wins over `current`:
# a template can declare one current language and store its texts under another.
$textLang = "ru"
if ($def.languages) {
	if ($def.languages.text) { $textLang = "$($def.languages.text)" }
	elseif ($def.languages.current) { $textLang = "$($def.languages.current)" }
}

# Every language that appears anywhere in the document must end up declared in
# languageSettings, otherwise the platform drops the texts it cannot resolve
$usedLangs = [ordered]@{}
$usedLangs[$textLang] = $true

function Add-UsedLangs {
	param($value)
	if ($null -eq $value -or $value -is [string]) { return }
	foreach ($prop in $value.PSObject.Properties) { $script:usedLangs[$prop.Name] = $true }
}

foreach ($group in $rowGroups) {
	foreach ($row in $group.Rows) {
		foreach ($cell in $row.cells) {
			Add-UsedLangs $cell.text
			Add-UsedLangs $cell.template
		}
	}
}
if ($def.styles) {
	foreach ($prop in $def.styles.PSObject.Properties) { Add-UsedLangs $prop.Value.format }
}

# --- 2. Build font palette ---

$fontMap = [ordered]@{}   # name -> 0-based index
$fontEntries = @()        # array of hashtables

function Add-Font {
	param([string]$name, $fontDef)
	# An explicitly empty face means "inherit the default font" — keep it,
	# only a missing face falls back to Arial
	$face = if ($null -ne $fontDef.face) { "$($fontDef.face)" } else { "Arial" }
	# Font height can be fractional (8.3, 6.8) — do not round it to an integer
	$hasSize = $null -ne $fontDef.size
	$size = if ($hasSize) { [double]$fontDef.size } else { 10 }
	$bold = if ($fontDef.bold -eq $true) { "true" } else { "false" }
	$italic = if ($fontDef.italic -eq $true) { "true" } else { "false" }
	$underline = if ($fontDef.underline -eq $true) { "true" } else { "false" }
	$strikeout = if ($fontDef.strikeout -eq $true) { "true" } else { "false" }

	$idx = $script:fontEntries.Count
	$script:fontMap[$name] = $idx
	$script:fontEntries += @{
		Face      = $face
		Size      = $size
		HasSize   = $hasSize
		Bold      = $bold
		Italic    = $italic
		Underline = $underline
		Strikeout = $strikeout
		Ref       = if ($fontDef.ref) { "$($fontDef.ref)" } else { "" }
		Kind      = if ($fontDef.kind) { "$($fontDef.kind)" } else { "" }
		HasStyleAttrs = $null -ne $fontDef.bold
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

# Line palette: "<width>|<style>" -> 0-based index. Thin and thick solid keep
# their historical positions, everything else is appended in order of first use.
$linePalette = [ordered]@{}

function Register-Line {
	param([int]$width, [string]$style)
	$key = "$width|$style"
	if (-not $script:linePalette.Contains($key)) {
		$script:linePalette[$key] = $script:linePalette.Count
	}
	return $script:linePalette[$key]
}

$thinLineIndex = -1
$thickLineIndex = -1
if ($hasThinBorders) { $thinLineIndex = Register-Line -width 1 -style "Solid" }
if ($hasThickBorders) { $thickLineIndex = Register-Line -width 2 -style "Solid" }

# Per-side border specs may name any line style the platform knows
if ($def.styles) {
	foreach ($prop in $def.styles.PSObject.Properties) {
		$b = $prop.Value.borders
		if (-not $b) { continue }
		foreach ($side in $b.PSObject.Properties) {
			$spec = $side.Value
			if (-not $spec) { continue }
			$style = if ($spec.style) { "$($spec.style)" } else { "Solid" }
			$width = if ($null -ne $spec.width) { [int]$spec.width } else { 1 }
			Register-Line -width $width -style $style | Out-Null
		}
	}
}

$lineCount = $linePalette.Count

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
	$wrap = ""   # textPlacement: "", Wrap, Auto or Cut
	$textColor = ""; $borderColor = ""; $hidden = ""; $indent = -1
	$extra = $null; $order = $null
	$styleWidth = -1; $styleHeight = -1

	if ($styleName -and $def.styles) {
		$style = $def.styles.$styleName
		if ($style) {
			# Font. An empty name means "no <font> element at all", which the
			# platform writes for formats that inherit it.
			if ($style.font -and $fontMap.Contains($style.font)) {
				$fontIdx = $fontMap[$style.font]
			} elseif ($null -ne $style.font -and "$($style.font)" -eq "") {
				$fontIdx = -1
			}

			# Borders. `borders` describes each side on its own and wins over the
			# compact `border` + `borderWidth` pair.
			if ($style.borders) {
				foreach ($side in $style.borders.PSObject.Properties) {
					$spec = $side.Value
					if (-not $spec) { continue }
					$sStyle = if ($spec.style) { "$($spec.style)" } else { "Solid" }
					$sWidth = if ($null -ne $spec.width) { [int]$spec.width } else { 1 }
					$idx = Register-Line -width $sWidth -style $sStyle
					switch ($side.Name.ToLower()) {
						"left"   { $lb = $idx }
						"top"    { $tb = $idx }
						"right"  { $rb = $idx }
						"bottom" { $bb = $idx }
					}
				}
			} elseif ($style.border -and $style.border -ne "none") {
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
			# Common names are spelled out, anything else is passed through with
			# its first letter capitalised (Justify, Fill, ...)
			if ($style.align) {
				$v = "$($style.align)"
				$ha = switch ($v) {
					"left"   { "Left" }
					"center" { "Center" }
					"right"  { "Right" }
					default  { $v.Substring(0, 1).ToUpper() + $v.Substring(1) }
				}
			}
			if ($style.valign) {
				$v = "$($style.valign)"
				$va = switch ($v) {
					"top"    { "Top" }
					"center" { "Center" }
					"bottom" { "Bottom" }
					default  { $v.Substring(0, 1).ToUpper() + $v.Substring(1) }
				}
			}

			# Text placement
			if ($style.wrap -eq $true) { $wrap = "Wrap" }
			if ($style.textPlacement) {
				switch ("$($style.textPlacement)".ToLower()) {
					"wrap" { $wrap = "Wrap" }
					"auto" { $wrap = "Auto" }
					"cut"  { $wrap = "Cut" }
					default { Write-Warning "Unknown textPlacement '$($style.textPlacement)'; expected wrap, auto or cut" }
				}
			}

			# Number format
			if ($style.format) { $nf = $style.format }

			# Colors and misc
			if ($style.textColor) { $textColor = $style.textColor }
			if ($style.borderColor) { $borderColor = $style.borderColor }
			# false is meaningful: templates spell it out
			if ($null -ne $style.hidden) { $hidden = if ($style.hidden -eq $true) { "true" } else { "false" } }
			if ($null -ne $style.indent) { $indent = [int]$style.indent }
			# 0 is a real value, so absence is what -1 stands for
			if ($null -ne $style.width) { $styleWidth = [int]$style.width }
			if ($null -ne $style.height) { $styleHeight = [int]$style.height }

			# Properties the DSL does not model, plus the original element order
			if ($style.extra) { $extra = $style.extra }
			if ($style.order) { $order = $style.order }
		}
	}

	return @{
		FontIdx      = $fontIdx
		LB           = $lb; TB = $tb; RB = $rb; BB = $bb
		HA           = $ha; VA = $va
		Wrap         = $wrap
		FillType     = $fillType
		NumberFormat = $nf
		TextColor    = $textColor
		BorderColor  = $borderColor
		Hidden       = $hidden
		Indent       = $indent
		Extra        = $extra
		Order        = $order
		Width        = $styleWidth
		Height       = $styleHeight
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
		[string]$wrap = "",
		[string]$fillType = "",
		[string]$numberFormat = "",
		[int]$width = -1,
		[int]$height = -1,
		[string]$textColor = "", [string]$borderColor = "",
		[string]$hidden = "", [int]$indent = 0,
		[string]$controlType = "", [string]$valueType = "",
		[string]$extra = ""
	)
	$key = "f=$fontIdx|lb=$lb|tb=$tb|rb=$rb|bb=$bb|ha=$ha|va=$va|wr=$wrap|ft=$fillType|nf=$numberFormat|w=$width|h=$height"
	# Extra properties are appended only when used, so keys of plain cells stay unchanged
	if ($textColor -or $borderColor -or $hidden -or $indent -or $controlType -or $valueType -or $extra) {
		$key += "|tc=$textColor|bc=$borderColor|hd=$hidden|in=$indent|ct=$controlType|vt=$valueType|ex=$extra"
	}
	return $key
}

# Number format may be a plain string or one entry per language
function Get-NumberFormatKey {
	param($nf)
	if (-not $nf) { return "" }
	if ($nf -is [string]) { return $nf }
	$parts = @()
	foreach ($p in $nf.PSObject.Properties) { $parts += "$($p.Name)=$($p.Value)" }
	return ($parts -join ";")
}

# Cell control types: DSL name -> platform GUID
$controlTypeGuids = @{
	"field"    = "381ed624-9217-4e63-85db-c4c3cb87daae"
	"checkbox" = "35af3d93-d7c7-4a2e-a8eb-bac87a1a3f26"
}

# valueType: shorthand string or object -> normalized hashtable
function Resolve-ValueType {
	param($vt)
	if (-not $vt) { return $null }

	$spec = $vt
	if ($vt -is [string]) {
		# "number(10,0)", "string(50)", "date", "boolean"
		if ($vt -match '^number\((\d+)\s*,\s*(\d+)\)$') {
			$spec = @{ type = "number"; digits = [int]$Matches[1]; fractionDigits = [int]$Matches[2] }
		} elseif ($vt -match '^number\((\d+)\)$') {
			$spec = @{ type = "number"; digits = [int]$Matches[1]; fractionDigits = 0 }
		} elseif ($vt -match '^string\((\d+)\)$') {
			$spec = @{ type = "string"; length = [int]$Matches[1] }
		} elseif ($vt -eq "string") {
			$spec = @{ type = "string"; length = 0 }
		} elseif ($vt -eq "date" -or $vt -eq "boolean" -or $vt -eq "number") {
			$spec = @{ type = $vt }
		} else {
			Write-Warning "Unknown valueType '$vt'; expected number(N,M), string(N), date or boolean"
			return $null
		}
	}

	$type = "$($spec.type)"
	$out = @{ Type = $type }

	switch ($type) {
		"number" {
			$out.Digits = if ($null -ne $spec.digits) { [int]$spec.digits } else { 10 }
			$out.FractionDigits = if ($null -ne $spec.fractionDigits) { [int]$spec.fractionDigits } else { 0 }
			$out.AllowedSign = if ($spec.allowedSign) { "$($spec.allowedSign)" } else { "Any" }
		}
		"string" {
			$out.Length = if ($null -ne $spec.length) { [int]$spec.length } else { 0 }
			$out.AllowedLength = if ($spec.allowedLength) { "$($spec.allowedLength)" } else { "Variable" }
		}
		"date" {
			$out.XsType = if ($spec.xsType) { "$($spec.xsType)" } else { "xs:dateTime" }
			$out.DateFractions = if ($spec.dateFractions) { "$($spec.dateFractions)" } else { "Date" }
		}
		"boolean" { }
		default {
			Write-Warning "Unknown valueType type '$type'"
			return $null
		}
	}

	return $out
}

# Stable string form of a resolved valueType — used in the format key
function Get-ValueTypeKey {
	param($vt)
	if (-not $vt) { return "" }
	switch ($vt.Type) {
		"number"  { return "number($($vt.Digits),$($vt.FractionDigits),$($vt.AllowedSign))" }
		"string"  { return "string($($vt.Length),$($vt.AllowedLength))" }
		"date"    { return "date($($vt.XsType),$($vt.DateFractions))" }
		"boolean" { return "boolean" }
	}
	return ""
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

# 6a. Default format. Without a width it would come out empty, so it carries the
# default font instead — the same shape the platform writes.
if ($defaultWidth -gt 0) {
	$defaultFormatKey = Get-FormatKey -width $defaultWidth
	$defaultFormatIndex = Register-Format -key $defaultFormatKey -props @{ Width = $defaultWidth }
} else {
	$defaultFormatKey = Get-FormatKey -fontIdx $fontMap["default"]
	$defaultFormatIndex = Register-Format -key $defaultFormatKey -props @{ FontIdx = $fontMap["default"] }
}

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
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента: только & < > . Кавычки в тексте платформа НЕ экранирует —
	# пишет литерально (проверено: 92142 сырых кавычки на корпус, ни одной &quot;). &quot; платформа
	# принимает, но при выгрузке нормализует обратно в кавычку → лишний шум в роундтрипе.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# Helper: determine fillType from cell content
function Get-FillType {
	param($cell)
	# Explicit wins: a cell can carry a fill type without content
	if ($cell.fillType) { return "$($cell.fillType)" }
	if ($cell.param) { return "Parameter" }
	if ($cell.template) { return "Template" }
	if ($cell.text) { return "Text" }
	return ""
}

# Helper: register a cell format and return its index
function Register-CellFormat {
	param($styleName, [string]$fillType, $cell = $null)
	# Format index 0 is "no format"; nothing to register
	if ($null -ne $styleName -and "$styleName" -eq "" -and -not $fillType -and
		-not ($cell -and $cell.input)) {
		return 0
	}
	$resolved = Resolve-Style -styleName $styleName -fillType $fillType

	# Input cell properties live on the cell, not on the style
	$controlType = ""
	$valueType = $null
	if ($cell -and $cell.input) {
		$inputName = "$($cell.input)"
		$controlType = if ($controlTypeGuids.ContainsKey($inputName)) { $controlTypeGuids[$inputName] } else { $inputName }
		$valueType = Resolve-ValueType $cell.valueType
	}
	$vtKey = Get-ValueTypeKey $valueType
	$exKey = ""
	if ($resolved.Extra) { $exKey = (@($resolved.Extra | ForEach-Object { $_.xml }) -join "") }

	$key = Get-FormatKey -fontIdx $resolved.FontIdx `
		-lb $resolved.LB -tb $resolved.TB -rb $resolved.RB -bb $resolved.BB `
		-ha $resolved.HA -va $resolved.VA `
		-wrap $resolved.Wrap -fillType $resolved.FillType `
		-numberFormat (Get-NumberFormatKey $resolved.NumberFormat) `
		-width $resolved.Width -height $resolved.Height `
		-textColor $resolved.TextColor -borderColor $resolved.BorderColor `
		-hidden $resolved.Hidden -indent $resolved.Indent `
		-controlType $controlType -valueType $vtKey -extra $exKey
	$props = @{
		FontIdx      = $resolved.FontIdx
		LB           = $resolved.LB; TB = $resolved.TB
		RB           = $resolved.RB; BB = $resolved.BB
		HA           = $resolved.HA; VA = $resolved.VA
		Wrap         = $resolved.Wrap
		FillType     = $resolved.FillType
		NumberFormat = $resolved.NumberFormat
		TextColor    = $resolved.TextColor
		BorderColor  = $resolved.BorderColor
		Hidden       = $resolved.Hidden
		Indent       = $resolved.Indent
		ControlType  = $controlType
		ValueType    = $valueType
		Extra        = $resolved.Extra
		Order        = $resolved.Order
		Width        = $resolved.Width
		Height       = $resolved.Height
	}
	return Register-Format -key $key -props $props
}

# Pre-register all formats from rows
foreach ($group in $rowGroups) {
	foreach ($row in $group.Rows) {
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
				# An explicitly empty style means the cell names no format at all
				$cellStyle = if ($null -ne $cell.style) { "$($cell.style)" } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				Register-CellFormat -styleName $cellStyle -fillType $ft -cell $cell | Out-Null
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

# Cell children the DSL does not model (value, control, note, ...) — written back
# verbatim. `names` selects which ones; `rest` flips the selection.
function Write-CellExtra {
	param($extra, [string[]]$names, [bool]$rest = $false)
	if (-not $extra) { return }
	foreach ($e in $extra) {
		$isListed = $names -contains "$($e.name)"
		if ($rest -eq $isListed) { continue }
		X ("`t`t`t`t`t" + $e.xml)
	}
}

# Cell text: a plain string goes under the document language, an object writes
# one <v8:item> per language key ({ "uk": "...", "ru": "..." })
function Write-Tl {
	param($value)
	X "`t`t`t`t`t<tl>"
	if ($value -is [string]) {
		X "`t`t`t`t`t`t<v8:item>"
		X "`t`t`t`t`t`t`t<v8:lang>$textLang</v8:lang>"
		X "`t`t`t`t`t`t`t<v8:content>$(Esc-XmlText $value)</v8:content>"
		X "`t`t`t`t`t`t</v8:item>"
	} else {
		foreach ($prop in $value.PSObject.Properties) {
			X "`t`t`t`t`t`t<v8:item>"
			X "`t`t`t`t`t`t`t<v8:lang>$($prop.Name)</v8:lang>"
			X "`t`t`t`t`t`t`t<v8:content>$(Esc-XmlText "$($prop.Value)")</v8:content>"
			X "`t`t`t`t`t`t</v8:item>"
		}
	}
	X "`t`t`t`t`t</tl>"
}

# 7a. Header
$docNsDecl = 'xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
# 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (перед style):
# платформа держит объявления по алфавиту, дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$docNsDecl = $docNsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}
X '<?xml version="1.0" encoding="UTF-8"?>'
X "<document $docNsDecl>"

# 7b. Language settings
$curLang = $textLang
$defLang = $textLang
if ($def.languages) {
	if ($def.languages.current) { $curLang = "$($def.languages.current)" }
	if ($def.languages.default) { $defLang = "$($def.languages.default)" } else { $defLang = $curLang }
}
$usedLangs[$curLang] = $true
$usedLangs[$defLang] = $true

# Names for languages the definition does not describe itself
$knownLangNames = @{
	"ru" = @{ Code = "Русский";    Description = "Русский" }
	"uk" = @{ Code = "Украинский"; Description = "Українська" }
	"en" = @{ Code = "Английский"; Description = "English" }
}

$langInfos = [ordered]@{}
foreach ($li in $def.languages.list) {
	if (-not $li.id) { continue }
	$langInfos["$($li.id)"] = @{
		Code        = if ($li.code) { "$($li.code)" } else { "$($li.id)" }
		Description = if ($li.description) { "$($li.description)" } else { "$($li.id)" }
	}
}
foreach ($l in $usedLangs.Keys) {
	if ($langInfos.Contains($l)) { continue }
	if ($knownLangNames.ContainsKey($l)) { $langInfos[$l] = $knownLangNames[$l] }
	else { $langInfos[$l] = @{ Code = $l; Description = $l } }
}

X "`t<languageSettings>"
X "`t`t<currentLanguage>$curLang</currentLanguage>"
X "`t`t<defaultLanguage>$defLang</defaultLanguage>"
foreach ($id in $langInfos.Keys) {
	X "`t`t<languageInfo>"
	X "`t`t`t<id>$id</id>"
	X "`t`t`t<code>$(Esc-XmlText $langInfos[$id].Code)</code>"
	X "`t`t`t<description>$(Esc-XmlText $langInfos[$id].Description)</description>"
	X "`t`t</languageInfo>"
}
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

foreach ($group in $rowGroups) {
	$areaStartRow = $globalRow
	$areaName = $group.Name
	$activeRowspans = @()  # @{ColStart=1-based; ColEnd=1-based; EndLocalRow=int}
	$localRow = 0

	foreach ($row in $group.Rows) {
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
				# An explicitly empty style means the cell names no format at all
				$cellStyle = if ($null -ne $cell.style) { "$($cell.style)" } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				$fmtIdx = Register-CellFormat -styleName $cellStyle -fillType $ft -cell $cell

				$cellInfo = @{
					Col       = $colStart - 1  # 0-based
					FormatIdx = $fmtIdx
					Param     = $cell.param
					Detail    = $cell.detail
					Text      = $cell.text
					Template  = $cell.template
					Extra     = $cell.extra
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

				# Collect merge (horizontal, vertical, both, or an explicit 1x1 record)
				if ($colSpan -gt 1 -or $rowspan -gt 1 -or $cell.merge -eq $true) {
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
				}

				# Platform order inside a cell: f, parameter, v, detailParameter,
				# tl, control, everything else
				Write-CellExtra $cellInfo.Extra @("v")

				# A detail parameter can stand on its own, without a parameter
				if ($cellInfo.Detail) {
					X "`t`t`t`t`t<detailParameter>$($cellInfo.Detail)</detailParameter>"
				}

				if ($cellInfo.Text) { Write-Tl $cellInfo.Text }
				if ($cellInfo.Template) { Write-Tl $cellInfo.Template }

				Write-CellExtra $cellInfo.Extra @("v") $true

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
	if ($areaName) {
		$namedItems += @{
			Name     = $areaName
			Type     = "Rows"
			BeginRow = $areaStartRow
			EndRow   = $areaEndRow
			BeginCol = -1
			EndCol   = -1
		}
	}
}

# Explicit named areas (any type) — coordinates are 1-based in the DSL
foreach ($na in $def.namedAreas) {
	$type = if ($na.type) { "$($na.type)" } else { "Rectangle" }
	$item = @{
		Name     = $na.name
		Type     = $type
		BeginRow = -1; EndRow = -1
		BeginCol = -1; EndCol = -1
	}
	# Bounds are independent: a missing one stays -1, which the platform reads as
	# "open on that side" (it writes such areas itself)
	if ($null -ne $na.firstRow) { $item.BeginRow = [int]$na.firstRow - 1 }
	if ($null -ne $na.lastRow) { $item.EndRow = [int]$na.lastRow - 1 }
	elseif ($null -ne $na.firstRow) { $item.EndRow = $item.BeginRow }

	if ($null -ne $na.firstCol) { $item.BeginCol = [int]$na.firstCol - 1 }
	if ($null -ne $na.lastCol) { $item.EndCol = [int]$na.lastCol - 1 }
	elseif ($null -ne $na.firstCol) { $item.EndCol = $item.BeginCol }

	if ($type -ne "Columns" -and $item.BeginRow -lt 0 -and $item.EndRow -lt 0) {
		Write-Warning "Named area '$($na.name)' of type $type has no row range"
	}
	if ($type -ne "Rows" -and $item.BeginCol -lt 0 -and $item.EndCol -lt 0) {
		Write-Warning "Named area '$($na.name)' of type $type has no column range"
	}
	$namedItems += $item
}

$totalRowCount = $globalRow

# 7e. Scalar metadata
X "`t<templateMode>true</templateMode>"
X "`t<defaultFormatIndex>$defaultFormatIndex</defaultFormatIndex>"
# An explicit height keeps the declared geometry of templates that carry rows
# past their own height
$docHeightOut = if ($def.height) { [int]$def.height } else { $totalRowCount }
X "`t<height>$docHeightOut</height>"
X "`t<vgRows>$docHeightOut</vgRows>"

# 7f. Merges
foreach ($m in $merges) {
	X "`t<merge>"
	X "`t`t<r>$($m.R)</r>"
	X "`t`t<c>$($m.C)</c>"
	if ($m.H) { X "`t`t<h>$($m.H)</h>" }
	X "`t`t<w>$($m.W)</w>"
	X "`t</merge>"
}

# Merges that belong to no cell (-1 = all rows / all columns), written verbatim
foreach ($m in $def.extraMerges) {
	X "`t<merge>"
	X "`t`t<r>$([int]$m.r)</r>"
	X "`t`t<c>$([int]$m.c)</c>"
	if ($m.h) { X "`t`t<h>$([int]$m.h)</h>" }
	X "`t`t<w>$(if ($null -ne $m.w) { [int]$m.w } else { 0 })</w>"
	X "`t</merge>"
}

# 7g. Named items
foreach ($ni in $namedItems) {
	X "`t<namedItem xsi:type=`"NamedItemCells`">"
	X "`t`t<name>$($ni.Name)</name>"
	X "`t`t<area>"
	X "`t`t`t<type>$($ni.Type)</type>"
	X "`t`t`t<beginRow>$($ni.BeginRow)</beginRow>"
	X "`t`t`t<endRow>$($ni.EndRow)</endRow>"
	X "`t`t`t<beginColumn>$($ni.BeginCol)</beginColumn>"
	X "`t`t`t<endColumn>$($ni.EndCol)</endColumn>"
	X "`t`t</area>"
	X "`t</namedItem>"
}

# 7h. Line palette
foreach ($key in $linePalette.Keys) {
	$parts = $key -split '\|'
	X "`t<line width=`"$($parts[0])`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">$($parts[1])</v8ui:style>"
	X "`t</line>"
}

# 7i. Font palette
foreach ($fe in $fontEntries) {
	# Height is written with a dot regardless of the machine locale
	$fontHeight = [System.Convert]::ToString($fe.Size, [System.Globalization.CultureInfo]::InvariantCulture)

	if ($fe.Ref -or ($fe.Kind -and $fe.Kind -ne "Absolute")) {
		# System font: keep it minimal, the platform fills the rest from the OS
		$attrs = @()
		if ($fe.Ref) { $attrs += "ref=`"$($fe.Ref)`"" }
		$attrs += "faceName=`"$($fe.Face)`""
		if ($fe.HasSize) { $attrs += "height=`"$fontHeight`"" }
		# Written when the definition states them at all, false included
		if ($fe.HasStyleAttrs) {
			$attrs += "bold=`"$($fe.Bold)`""
			$attrs += "italic=`"$($fe.Italic)`""
			$attrs += "underline=`"$($fe.Underline)`""
			$attrs += "strikeout=`"$($fe.Strikeout)`""
		} else {
			if ($fe.Bold -eq "true") { $attrs += "bold=`"true`"" }
			if ($fe.Italic -eq "true") { $attrs += "italic=`"true`"" }
			if ($fe.Underline -eq "true") { $attrs += "underline=`"true`"" }
			if ($fe.Strikeout -eq "true") { $attrs += "strikeout=`"true`"" }
		}
		$attrs += "kind=`"$(if ($fe.Kind) { $fe.Kind } else { 'Absolute' })`""
		X ("`t<font " + ($attrs -join " ") + "/>")
	} else {
		X "`t<font faceName=`"$($fe.Face)`" height=`"$fontHeight`" bold=`"$($fe.Bold)`" italic=`"$($fe.Italic)`" underline=`"$($fe.Underline)`" strikeout=`"$($fe.Strikeout)`" kind=`"Absolute`" scale=`"100`"/>"
	}
}

# 7j. Format palette
# Every property is rendered into a name -> lines map first, so the element order
# can follow the one captured from the source template.
$defaultFormatOrder = @(
	"font", "leftBorder", "topBorder", "rightBorder", "bottomBorder", "border",
	"borderColor", "width", "height", "horizontalAlignment", "verticalAlignment",
	"textPlacement", "textColor", "hidden", "indent", "fillType", "format",
	"containsValue", "valueType", "controlType"
)

foreach ($key in $formatRegistry.Keys) {
	$fmt = $formatRegistry[$key]
	$out = [ordered]@{}

	if ($fmt.FontIdx -ne $null -and $fmt.FontIdx -ge 0) {
		$out["font"] = @("`t`t<font>$($fmt.FontIdx)</font>")
	}

	# All four sides on one line -> <border>, as the platform writes it. It never
	# spells out four equal per-side elements.
	$allSides = ($fmt.LB -ne $null -and $fmt.LB -ge 0 -and
		$fmt.LB -eq $fmt.TB -and $fmt.LB -eq $fmt.RB -and $fmt.LB -eq $fmt.BB)

	if ($allSides) {
		$out["border"] = @("`t`t<border>$($fmt.LB)</border>")
	} else {
		if ($fmt.LB -ne $null -and $fmt.LB -ge 0) { $out["leftBorder"] = @("`t`t<leftBorder>$($fmt.LB)</leftBorder>") }
		if ($fmt.TB -ne $null -and $fmt.TB -ge 0) { $out["topBorder"] = @("`t`t<topBorder>$($fmt.TB)</topBorder>") }
		if ($fmt.RB -ne $null -and $fmt.RB -ge 0) { $out["rightBorder"] = @("`t`t<rightBorder>$($fmt.RB)</rightBorder>") }
		if ($fmt.BB -ne $null -and $fmt.BB -ge 0) { $out["bottomBorder"] = @("`t`t<bottomBorder>$($fmt.BB)</bottomBorder>") }
	}

	if ($fmt.BorderColor) { $out["borderColor"] = @("`t`t<borderColor>$($fmt.BorderColor)</borderColor>") }
	if ($null -ne $fmt.Width -and $fmt.Width -ge 0) { $out["width"] = @("`t`t<width>$($fmt.Width)</width>") }
	if ($null -ne $fmt.Height -and $fmt.Height -ge 0) { $out["height"] = @("`t`t<height>$($fmt.Height)</height>") }
	if ($fmt.HA) { $out["horizontalAlignment"] = @("`t`t<horizontalAlignment>$($fmt.HA)</horizontalAlignment>") }
	if ($fmt.VA) { $out["verticalAlignment"] = @("`t`t<verticalAlignment>$($fmt.VA)</verticalAlignment>") }
	if ($fmt.Wrap) { $out["textPlacement"] = @("`t`t<textPlacement>$($fmt.Wrap)</textPlacement>") }
	if ($fmt.TextColor) { $out["textColor"] = @("`t`t<textColor>$($fmt.TextColor)</textColor>") }
	if ($fmt.Hidden) { $out["hidden"] = @("`t`t<hidden>$($fmt.Hidden)</hidden>") }
	if ($null -ne $fmt.Indent -and $fmt.Indent -ge 0) { $out["indent"] = @("`t`t<indent>$($fmt.Indent)</indent>") }
	if ($fmt.FillType) { $out["fillType"] = @("`t`t<fillType>$($fmt.FillType)</fillType>") }

	if ($fmt.NumberFormat) {
		$nfLines = @("`t`t<format>")
		if ($fmt.NumberFormat -is [string]) {
			$nfLines += "`t`t`t<v8:item>"
			$nfLines += "`t`t`t`t<v8:lang>$textLang</v8:lang>"
			$nfLines += "`t`t`t`t<v8:content>$(Esc-XmlText $fmt.NumberFormat)</v8:content>"
			$nfLines += "`t`t`t</v8:item>"
		} else {
			foreach ($p in $fmt.NumberFormat.PSObject.Properties) {
				$nfLines += "`t`t`t<v8:item>"
				$nfLines += "`t`t`t`t<v8:lang>$($p.Name)</v8:lang>"
				$nfLines += "`t`t`t`t<v8:content>$(Esc-XmlText "$($p.Value)")</v8:content>"
				$nfLines += "`t`t`t</v8:item>"
			}
		}
		$nfLines += "`t`t</format>"
		$out["format"] = $nfLines
	}

	# Input cell: containsValue -> valueType -> controlType
	if ($fmt.ControlType) {
		$out["containsValue"] = @("`t`t<containsValue>true</containsValue>")
		$vt = $fmt.ValueType
		if ($vt) {
			$vtLines = @("`t`t<valueType>")
			switch ($vt.Type) {
				"number" {
					$vtLines += "`t`t`t<v8:Type>xs:decimal</v8:Type>"
					$vtLines += "`t`t`t<v8:NumberQualifiers>"
					$vtLines += "`t`t`t`t<v8:Digits>$($vt.Digits)</v8:Digits>"
					$vtLines += "`t`t`t`t<v8:FractionDigits>$($vt.FractionDigits)</v8:FractionDigits>"
					$vtLines += "`t`t`t`t<v8:AllowedSign>$($vt.AllowedSign)</v8:AllowedSign>"
					$vtLines += "`t`t`t</v8:NumberQualifiers>"
				}
				"string" {
					$vtLines += "`t`t`t<v8:Type>xs:string</v8:Type>"
					$vtLines += "`t`t`t<v8:StringQualifiers>"
					$vtLines += "`t`t`t`t<v8:Length>$($vt.Length)</v8:Length>"
					$vtLines += "`t`t`t`t<v8:AllowedLength>$($vt.AllowedLength)</v8:AllowedLength>"
					$vtLines += "`t`t`t</v8:StringQualifiers>"
				}
				"date" {
					$vtLines += "`t`t`t<v8:Type>$($vt.XsType)</v8:Type>"
					$vtLines += "`t`t`t<v8:DateQualifiers>"
					$vtLines += "`t`t`t`t<v8:DateFractions>$($vt.DateFractions)</v8:DateFractions>"
					$vtLines += "`t`t`t</v8:DateQualifiers>"
				}
				"boolean" { $vtLines += "`t`t`t<v8:Type>xs:boolean</v8:Type>" }
			}
			$vtLines += "`t`t</valueType>"
			$out["valueType"] = $vtLines
		}
		$out["controlType"] = @("`t`t<controlType>$($fmt.ControlType)</controlType>")
	}

	# Properties the DSL does not model, carried over as they were
	if ($fmt.Extra) {
		foreach ($e in $fmt.Extra) { $out["$($e.name)"] = @("`t`t" + $e.xml) }
	}

	# Order: the one captured from the source, then anything it did not mention
	$order = @()
	if ($fmt.Order) { foreach ($nm in $fmt.Order) { if ($order -notcontains $nm) { $order += $nm } } }
	foreach ($nm in $defaultFormatOrder) { if ($order -notcontains $nm) { $order += $nm } }
	foreach ($nm in $out.Keys) { if ($order -notcontains $nm) { $order += $nm } }

	X "`t<format>"
	foreach ($nm in $order) {
		if (-not $out.Contains($nm)) { continue }
		foreach ($line in $out[$nm]) { X $line }
	}
	X "`t</format>"
}

# 7k. Close document
X '</document>'

# --- 8. Write output ---

$enc = New-Object System.Text.UTF8Encoding($true)
$resolvedPath = $script:outPathResolved
# Каталог назначения создаём сами: типовой путь — Templates/<Имя>/Ext/Template.xml,
# и его может ещё не быть. Так делают и form-compile, и skd-compile, и py-порт этого
# навыка; без этого PS-порт падал на «Could not find a part of the path».
$outDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Assert-EditAllowed $resolvedPath 'editable'
[System.IO.File]::WriteAllText($resolvedPath, $xml.ToString().TrimEnd("`r", "`n"), $enc)

# --- 9. Summary ---

Write-Host "[OK] Compiled: $OutputPath"
if ($def.page) {
	Write-Host "     Page: $pageName -> target $targetWidth, defaultWidth=$defaultWidth"
}
$mode = if ($flatMode) { "flat" } else { "blocks" }
$byType = @($namedItems | Group-Object { $_.Type } | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ", "
Write-Host "     Mode: $mode, Areas: $($namedItems.Count) ($byType), Rows: $totalRowCount, Columns: $totalColumns"
Write-Host "     Fonts: $($fontEntries.Count), Lines: $($linePalette.Count), Formats: $($formatRegistry.Count)"
$extraMergeCount = if ($def.extraMerges) { @($def.extraMerges).Count } else { 0 }
Write-Host "     Merges: $($merges.Count + $extraMergeCount)"
