# support-edit v1.0 — Toggle 1C configuration support state (Ext/ParentConfigurations.bin)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)][Alias('Path')][string]$TargetPath,
	[ValidateSet("editable","off-support","locked")]
	[string]$Set,
	[ValidateSet("on","off")]
	[string]$Capability
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ((-not $Set -and -not $Capability) -or ($Set -and $Capability)) {
	[Console]::Error.WriteLine("Укажите ровно одно: -Set editable|off-support|locked  ЛИБО  -Capability on|off")
	exit 1
}

# --- Resolve target uuid + config root + bin (walk-up, same as support-guard) ---
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

if (-not (Test-Path $TargetPath)) {
	[Console]::Error.WriteLine("Путь не найден: $TargetPath")
	exit 1
}
$rp = (Resolve-Path $TargetPath).Path
$elemUuid = Get-RootUuid $rp
$cfgDir = $null; $binPath = $null
$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
for ($i = 0; $i -lt 12 -and $d; $i++) {
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
if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }

if (-not $cfgDir) {
	[Console]::Error.WriteLine("Не найден корень конфигурации (Configuration.xml) над путём: $rp")
	exit 1
}
if (-not (Test-Path $binPath)) {
	Write-Host "Конфигурация не на поддержке (Ext/ParentConfigurations.bin отсутствует) — переключать нечего."
	exit 0
}

# --- Read bin (UTF-8 text with BOM) ---
$bytes = [System.IO.File]::ReadAllBytes($binPath)
if ($bytes.Length -le 32) {
	Write-Host "Поддержка снята полностью (пустой ParentConfigurations.bin) — переключать нечего."
	exit 0
}
$start = 0
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
if (-not $hm.Success) {
	[Console]::Error.WriteLine("Неизвестный формат ParentConfigurations.bin")
	exit 1
}
$G = [int]$hm.Groups[1].Value
$K = [int]$hm.Groups[2].Value

function Save-Bin([string]$txt) {
	[System.IO.File]::WriteAllText($binPath, $txt, (New-Object System.Text.UTF8Encoding($true)))
}

# === Capability (global G) ===
if ($Capability) {
	$target = if ($Capability -eq 'on') { '0' } else { '1' }
	if ($G -eq [int]$target) {
		$word = if ($Capability -eq 'on') { 'включена' } else { 'выключена' }
		Write-Host "Возможность изменения конфигурации уже $word — изменений нет."
		exit 0
	}
	# G + X (per block) + bulk f1
	$text = [regex]::Replace($text, '^(\{6,)\d+(,)', "`${1}$target`$2")
	$text = [regex]::Replace($text, '([0-9a-f-]{36}),\d+,([0-9a-f-]{36})', "`$1,$target,`$2")
	$text = [regex]::Replace($text, '[0-2],0,([0-9a-f-]{36})', "$target,0,`$1")
	Save-Bin $text
	if ($Capability -eq 'on') {
		Write-Host "Возможность изменения конфигурации ВКЛЮЧЕНА. Все объекты поставщика — на замке."
		Write-Host "Включайте редактирование точечно: support-edit -Path <объект> -Set editable"
	} else {
		Write-Host "Возможность изменения конфигурации ВЫКЛЮЧЕНА. Вся конфигурация стала read-only; пообъектные правила сброшены."
	}
	exit 0
}

# === Per-object -Set ===
if ($G -eq 1) {
	[Console]::Error.WriteLine("Возможность изменения конфигурации выключена — пообъектное переключение недоступно.`n  Сначала: support-edit -Path $TargetPath -Capability on")
	exit 1
}
if (-not $elemUuid) {
	[Console]::Error.WriteLine("Не удалось определить объект по пути: $rp")
	exit 1
}
$u = [regex]::Escape($elemUuid.ToLower())
$matches = [regex]::Matches($text, "([0-2]),0,$u")
if ($matches.Count -eq 0) {
	Write-Host "Объект (uuid $elemUuid) не на поддержке (своё добавление или не найден в bin) — переключать нечего."
	exit 0
}
$newF1 = switch ($Set) { 'editable' { '1' } 'off-support' { '2' } 'locked' { '0' } }
# Replacement string has no group refs — uuid is fixed, f1 is rewritten.
$text = [regex]::Replace($text, "([0-2]),0,$u", "$newF1,0,$($elemUuid.ToLower())")
Save-Bin $text
$state = switch ($Set) {
	'editable'    { "редактируется с сохранением поддержки (объект продолжит получать обновления вендора — возможны конфликты при обновлении)" }
	'off-support' { "снят с поддержки (обновления вендора по этому объекту прекращаются)" }
	'locked'      { "на замке (правка запрещена)" }
}
Write-Host "Объект uuid $elemUuid → $state."
Write-Host "Записей в bin изменено: $($matches.Count). Цель: $rp"
exit 0
