# v8-xsd-fetch v1.0 — Download 1C platform XSD schemas (dump format) into .v8-xsd
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Загрузка XSD-схем формата выгрузки 1С по версиям формата

.DESCRIPTION
    Скачивает schemas/designer/<версия>/*.xsd из репозитория yellow-hammer/namespace-forest
    в каталог схем проекта: -OutPath, иначе xsdPath из .v8-project.json, иначе .v8-xsd
    рядом с .v8-project.json (нет его — в текущем каталоге).

.EXAMPLE
    .\v8-xsd-fetch.ps1 -Versions "2.20,2.21"

.EXAMPLE
    .\v8-xsd-fetch.ps1 -List
#>

[CmdletBinding(PositionalBinding=$false)]
param(
	# Списком одной строкой: powershell -File не связывает массивы
	[Parameter(Mandatory=$false)]
	[string]$Versions,

	[Parameter(Mandatory=$false)]
	[string]$OutPath,

	[Parameter(Mandatory=$false)]
	[string]$Ref = "main",

	[Parameter(Mandatory=$false)]
	[switch]$Force,

	[Parameter(Mandatory=$false)]
	[switch]$List
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repo = "yellow-hammer/namespace-forest"
$repoUrl = "https://github.com/$repo"

# Текст README — в templates/ навыка, одна копия на оба порта
$readmeTemplate = Join-Path $PSScriptRoot "../templates/README.md"

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

function Fail([string]$msg) {
	Write-Host "Error: $msg" -ForegroundColor Red
	exit 1
}

# --- Версии: проверяем до сети ---
$wanted = @()
if ($Versions) {
	foreach ($v in ($Versions -split '[,;\s]+')) {
		if (-not $v) { continue }
		if ($v -notmatch '^\d+\.\d+$') { Fail "неверная версия формата '$v' (ожидается вида 2.20)" }
		if ($wanted -notcontains $v) { $wanted += $v }
	}
}

# --- Каталог схем ---
$cwd = (Get-Location).Path
$pj = Find-V8Project $cwd
$target = $null
if ($OutPath) {
	$target = if ([System.IO.Path]::IsPathRooted($OutPath)) { $OutPath } else { Join-Path $cwd $OutPath }
} elseif ($pj) {
	$pjDir = [System.IO.Path]::GetDirectoryName($pj)
	try { $cfg = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
	if ($cfg -and $cfg.xsdPath) {
		$target = if ([System.IO.Path]::IsPathRooted($cfg.xsdPath)) { $cfg.xsdPath } else { Join-Path $pjDir $cfg.xsdPath }
	} else {
		$target = Join-Path $pjDir ".v8-xsd"
	}
} else {
	$target = Join-Path $cwd ".v8-xsd"
}
$target = [System.IO.Path]::GetFullPath($target)
if (Test-Path -LiteralPath $target -PathType Leaf) { Fail "каталог схем '$target' — это файл" }

# --- Состав репозитория ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("User-Agent", "v8-xsd-fetch")
$wc.Encoding = [System.Text.Encoding]::UTF8
try {
	$tree = $wc.DownloadString("https://api.github.com/repos/$repo/git/trees/$([uri]::EscapeDataString($Ref))?recursive=1") | ConvertFrom-Json
} catch {
	Fail "не удалось получить состав $repo@${Ref}: $($_.Exception.Message)`nСкачайте вручную каталоги schemas/designer/<версия> из $repoUrl в '$target'"
}
$commit = $tree.sha

$byVersion = @{}
foreach ($node in $tree.tree) {
	if ($node.type -ne 'blob') { continue }
	$m = [regex]::Match($node.path, '^schemas/designer/(\d+\.\d+)/([^/]+\.xsd)$')
	if (-not $m.Success) { continue }
	$v = $m.Groups[1].Value
	if (-not $byVersion.ContainsKey($v)) { $byVersion[$v] = New-Object System.Collections.ArrayList }
	[void]$byVersion[$v].Add(@{ path = $node.path; name = $m.Groups[2].Value })
}
$available = @($byVersion.Keys | Sort-Object { [version]$_ })
if ($available.Count -eq 0) { Fail "в $repo@$Ref нет каталогов schemas/designer/<версия>" }

if ($List) {
	Write-Host "Версии формата в $repo@${Ref}:"
	foreach ($v in $available) {
		$mark = if (Test-Path -LiteralPath (Join-Path $target $v) -PathType Container) { "  (есть локально)" } else { "" }
		Write-Host "  $v — $($byVersion[$v].Count) схем$mark"
	}
	Write-Host "Каталог схем: $target"
	exit 0
}

if ($wanted.Count -eq 0) { $wanted = $available }
$missing = @($wanted | Where-Object { $available -notcontains $_ })
if ($missing.Count -gt 0) {
	Fail "версии $($missing -join ', ') нет в $repo@$Ref (есть: $($available -join ', '))"
}

# --- Загрузка ---
if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
$fetched = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Происхождение — по версиям: уже лежащие файлы без -Force не перекачиваются, поэтому коммит
# версии обновляем, только когда её файлы действительно скачаны в этом запуске
$srcPath = Join-Path $target "source.json"
$srcVers = @{}
if (Test-Path -LiteralPath $srcPath) {
	try {
		$old = Get-Content -LiteralPath $srcPath -Raw -Encoding UTF8 | ConvertFrom-Json
		if ($old.versions -is [PSCustomObject]) {
			foreach ($pr in $old.versions.PSObject.Properties) {
				$srcVers[$pr.Name] = @{ ref = "$($pr.Value.ref)"; commit = "$($pr.Value.commit)"; fetched = "$($pr.Value.fetched)" }
			}
		}
	} catch { }
}

$totalNew = 0
foreach ($v in ($wanted | Sort-Object { [version]$_ })) {
	$dir = Join-Path $target $v
	if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
	$got = 0; $kept = 0
	foreach ($f in $byVersion[$v]) {
		$dest = Join-Path $dir $f.name
		if ((Test-Path -LiteralPath $dest) -and -not $Force) { $kept++; continue }
		# Файлы берём по коммиту, а не по ветке: весь набор — из одного состояния репозитория
		$url = "https://raw.githubusercontent.com/$repo/$commit/$($f.path)"
		try {
			$bytes = $wc.DownloadData($url)
		} catch {
			Fail "не удалось скачать $($f.path): $($_.Exception.Message)"
		}
		[System.IO.File]::WriteAllBytes($dest, $bytes)
		$got++
	}
	$totalNew += $got
	if ($got -gt 0) { $srcVers[$v] = @{ ref = $Ref; commit = $commit; fetched = $fetched } }
	$line = "  ${v}: скачано $got"
	if ($kept -gt 0) { $line += ", уже было $kept" }
	Write-Host $line
}

# --- README и source.json ---
$readmePath = Join-Path $target "README.md"
if (-not (Test-Path -LiteralPath $readmePath) -and (Test-Path -LiteralPath $readmeTemplate)) {
	Copy-Item -LiteralPath $readmeTemplate -Destination $readmePath
}
$localVersions = @(Get-ChildItem -LiteralPath $target -Directory |
	Where-Object { $_.Name -match '^\d+\.\d+$' } |
	ForEach-Object { $_.Name } | Sort-Object { [version]$_ })
# Руками, а не ConvertTo-Json: форматирование PS 5.1 не совпало бы с py-портом.
# Версия без записи о происхождении (скопирована вручную) — с пустыми полями.
function Esc-Json([string]$s) { return ($s -replace '\\', '\\' -replace '"', '\"') }
$verLines = @()
foreach ($v in $localVersions) {
	$e = if ($srcVers.ContainsKey($v)) { $srcVers[$v] } else { @{ ref = ''; commit = ''; fetched = '' } }
	$verLines += "    `"$v`": { `"ref`": `"$(Esc-Json $e.ref)`", `"commit`": `"$(Esc-Json $e.commit)`", `"fetched`": `"$(Esc-Json $e.fetched)`" }"
}
$verBlock = if ($verLines.Count -gt 0) { "{`n" + ($verLines -join ",`n") + "`n  }" } else { "{}" }
$srcJson = "{`n  `"repository`": `"$repoUrl`",`n  `"versions`": $verBlock`n}`n"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($srcPath, $srcJson, $enc)

Write-Host "Схемы: $target (скачано файлов: $totalNew)"
