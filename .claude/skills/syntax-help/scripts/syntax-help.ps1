# syntax-help v1.0 — Search and read the 1C platform syntax helper (.hbk)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: *nix-раскладку платформы (/opt/1cv8/<ver>/1cv8, без .exe) знает только .py-порт — PS на *nix не исполняется.
[CmdletBinding(PositionalBinding=$false)]
param(
	[string]$Search,
	[string]$Page,
	[switch]$InText,
	[string]$Book = "shlang,shcntx,shquery",
	[string]$Language = "ru",
	[string]$V8Path,
	[string]$CacheDir,
	[int]$Limit = 150,
	[int]$Offset = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.IO.Compression

# --- Output helper (always collect, paginate at the end) ---
$script:lines = New-Object System.Collections.Generic.List[string]
function Out([string]$text) { $script:lines.Add($text) }

$hasSearch = -not [string]::IsNullOrWhiteSpace($Search)
$hasPage = -not [string]::IsNullOrWhiteSpace($Page)
if ($hasSearch -eq $hasPage) {
	Write-Host "[ERROR] Specify exactly one of -Search or -Page"
	exit 1
}
if ($hasPage -and $Page -notmatch '^[A-Za-z0-9_]+:.+$') {
	Write-Host "[ERROR] -Page expects <book>:<path> from the search output, got: $Page"
	exit 1
}

# --- Platform: -V8Path, then .v8-project.json, then the newest installed version ---
function Find-ProjectV8Path {
    $dir = (Get-Location).Path
    while ($dir) {
        $pf = Join-Path $dir ".v8-project.json"
        if (Test-Path $pf) {
            try {
                $j = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.v8path) { return [string]$j.v8path }
            } catch {}
            return $null
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

if (-not $V8Path) {
	$V8Path = Find-ProjectV8Path
}
if (-not $V8Path) {
	$found = Get-ChildItem @("C:\Program Files\1cv8\*\bin\1cv8.exe", "C:\Program Files (x86)\1cv8\*\bin\1cv8.exe") -ErrorAction SilentlyContinue |
		Sort-Object { try { [version]$_.Directory.Parent.Name } catch { [version]"0.0" } } -Descending |
		Select-Object -First 1
	if ($found) {
		$V8Path = $found.FullName
		Write-Host "Auto-selected platform $($found.Directory.Parent.Name): $V8Path"
	} else {
		Write-Host "[ERROR] 1C platform not found. Specify -V8Path"
		exit 1
	}
}
# Книги лежат рядом с исполняемым файлом: принимаем и каталог bin, и путь к 1cv8.exe/ibcmd.exe.
if (Test-Path -LiteralPath $V8Path -PathType Leaf) {
	$binDir = Split-Path -Parent $V8Path
} elseif (Test-Path -LiteralPath $V8Path -PathType Container) {
	$binDir = $V8Path
} else {
	Write-Host "[ERROR] Platform path not found: $V8Path"
	exit 1
}
$binDir = (Resolve-Path -LiteralPath $binDir).Path
$platformName = Split-Path $binDir -Leaf
if ($platformName -ieq 'bin') { $platformName = Split-Path (Split-Path $binDir -Parent) -Leaf }

# --- 1C container (.hbk) ---
# Документ контейнера хранится цепочкой блоков. Заголовок блока — 31 байт текста: CRLF, длина
# документа, длина блока, адрес следующего блока (8 hex-цифр через пробел), пробел, CRLF.
# Длину документа несёт первый блок; конец цепочки — адрес 7fffffff.
function Read-ContainerDocument([byte[]]$Data, [long]$Address) {
	$ascii = [System.Text.Encoding]::ASCII
	$stream = New-Object System.IO.MemoryStream
	$docLength = -1
	$visited = New-Object 'System.Collections.Generic.HashSet[long]'
	while ($true) {
		if ($Address -lt 0 -or $Address + 31 -gt $Data.Length -or -not $visited.Add($Address)) {
			throw "broken block chain at offset $Address"
		}
		$header = $ascii.GetString($Data, [int]$Address, 31)
		if ($header.Substring(0, 2) -ne "`r`n" -or $header.Substring(29, 2) -ne "`r`n") {
			throw "no block header at offset $Address"
		}
		if ($docLength -lt 0) { $docLength = [Convert]::ToInt64($header.Substring(2, 8), 16) }
		$blockLength = [Convert]::ToInt64($header.Substring(11, 8), 16)
		$next = [Convert]::ToInt64($header.Substring(20, 8), 16)
		$take = [Math]::Min($blockLength, $docLength - $stream.Length)
		if ($Address + 31 + $take -gt $Data.Length) { throw "block at offset $Address runs past the end of file" }
		$stream.Write($Data, [int]($Address + 31), [int]$take)
		if ($stream.Length -ge $docLength -or $next -eq 0x7FFFFFFF) { break }
		$Address = $next
	}
	return ,$stream.ToArray()
}

# Оглавление — первый документ после 16 байт заголовка файла: тройки uint32 (адрес заголовка
# элемента, адрес данных, резерв). Имя элемента — UTF-16LE после 20 байт дат и резерва.
function Get-ContainerItems([byte[]]$Data) {
	$toc = Read-ContainerDocument $Data 16
	$items = @{}
	for ($i = 0; $i + 12 -le $toc.Length; $i += 12) {
		$headerAddress = [BitConverter]::ToUInt32($toc, $i)
		$dataAddress = [BitConverter]::ToUInt32($toc, $i + 4)
		if ($headerAddress -eq 0 -and $dataAddress -eq 0) { continue }
		$itemHeader = Read-ContainerDocument $Data $headerAddress
		$name = [System.Text.Encoding]::Unicode.GetString($itemHeader, 20, $itemHeader.Length - 20).Split([char]0)[0]
		$items[$name] = [long]$dataAddress
	}
	return $items
}

# Страницы книги — zip в элементе FileStorage.
function Open-HelpBook([string]$BookName) {
	$path = Join-Path $binDir ("{0}_{1}.hbk" -f $BookName, $Language)
	if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
		Write-Host "[ERROR] Help book not found: $path"
		exit 1
	}
	try {
		$data = [System.IO.File]::ReadAllBytes($path)
		$items = Get-ContainerItems $data
		if (-not $items.ContainsKey('FileStorage')) { throw "no FileStorage item" }
		$zipBytes = Read-ContainerDocument $data $items['FileStorage']
		$archive = New-Object System.IO.Compression.ZipArchive((New-Object System.IO.MemoryStream(,$zipBytes)), [System.IO.Compression.ZipArchiveMode]::Read)
	} catch {
		Write-Host "[ERROR] Cannot read help book ${path}: $($_.Exception.Message)"
		exit 1
	}
	return [pscustomobject]@{ Name = $BookName; Path = $path; File = (Get-Item -LiteralPath $path); Archive = $archive }
}

function Read-HelpEntry($Entry) {
	$reader = New-Object System.IO.StreamReader($Entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
	try { return $reader.ReadToEnd().TrimStart([char]0xFEFF) } finally { $reader.Dispose() }
}

# --- HTML -> text ---
function Get-HelpTitle([string]$Html) {
	$m = [regex]::Match($Html, '(?is)<h1\b[^>]*>(.*?)</h1>')
	if (-not $m.Success) { return $null }
	$title = [System.Net.WebUtility]::HtmlDecode(($m.Groups[1].Value -replace '<[^>]+>', ''))
	return ($title -replace '\s+', ' ').Trim()
}

function ConvertFrom-HelpHtml([string]$Html) {
	$text = $Html -replace '(?is)<head\b.*?</head>', ''
	$text = $text -replace '(?i)<li\b[^>]*>', "`n- "
	$text = $text -replace '(?i)</t[dh]>', ' | '
	$text = $text -replace '(?i)<br\s*/?>|</?(p|div|h[1-6]|tr|table|ul|ol|pre|dl|dt|dd)\b[^>]*>', "`n"
	$text = $text -replace '<[^>]+>', ''
	$text = [System.Net.WebUtility]::HtmlDecode($text)
	$result = New-Object System.Collections.Generic.List[string]
	foreach ($raw in ($text -split "\r?\n")) {
		$line = ($raw -replace '[ \t\u00A0]+', ' ').Trim().TrimEnd('|').Trim()
		# пункты списка идут подряд, без пустой строки между ними
		if ($line.StartsWith('- ') -and $result.Count -gt 1 -and $result[$result.Count - 1] -eq '' -and $result[$result.Count - 2].StartsWith('- ')) {
			$result.RemoveAt($result.Count - 1)
		}
		if ($line -ne '' -or ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '')) { $result.Add($line) }
	}
	while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') { $result.RemoveAt($result.Count - 1) }
	return ,$result
}

# --- Title index ---
# Заголовок страницы — это её <h1>, и чтобы найти страницу по заголовку, надо распаковать все
# страницы книги. Поэтому список «путь — заголовок» кэшируется: ключ — платформа, книга, размер
# и время изменения файла, так что обновление платформы строит индекс заново.
function Get-HelpIndex($HelpBook) {
	$root = $CacheDir
	if (-not $root) { $root = Join-Path ([System.IO.Path]::GetTempPath()) '1c-syntax-help' }
	$mtime = [DateTimeOffset]::new($HelpBook.File.LastWriteTimeUtc).ToUnixTimeSeconds()
	$indexPath = Join-Path $root ('{0}-{1}_{2}-{3}-{4}.tsv' -f $platformName, $HelpBook.Name, $Language, $HelpBook.File.Length, $mtime)
	if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
		$rows = New-Object System.Collections.Generic.List[object]
		foreach ($row in [System.IO.File]::ReadAllLines($indexPath, [System.Text.Encoding]::UTF8)) {
			$parts = $row.Split("`t", 2)
			if ($parts.Count -eq 2) { $rows.Add([pscustomobject]@{ Path = $parts[0]; Title = $parts[1] }) }
		}
		return ,$rows
	}
	$rows = New-Object System.Collections.Generic.List[object]
	foreach ($entry in $HelpBook.Archive.Entries) {
		if ($entry.FullName.EndsWith('.st') -or $entry.FullName.EndsWith('__categories__')) { continue }
		$title = Get-HelpTitle (Read-HelpEntry $entry)
		if ($title) { $rows.Add([pscustomobject]@{ Path = $entry.FullName; Title = $title }) }
	}
	# Не удалось записать кэш — не ошибка: индекс просто построится и в следующий раз.
	try {
		[void][System.IO.Directory]::CreateDirectory($root)
		$tmp = "$indexPath.$PID.tmp"
		$content = [string[]]@($rows | ForEach-Object { "$($_.Path)`t$($_.Title)" })
		[System.IO.File]::WriteAllLines($tmp, $content, (New-Object System.Text.UTF8Encoding($false)))
		Move-Item -LiteralPath $tmp -Destination $indexPath -Force
	} catch {}
	return ,$rows
}

# --- Page mode ---
if ($hasPage) {
	$sep = $Page.IndexOf(':')
	$helpBook = Open-HelpBook $Page.Substring(0, $sep)
	$entryPath = $Page.Substring($sep + 1)
	$entry = $helpBook.Archive.GetEntry($entryPath)
	if (-not $entry) {
		Write-Host "[ERROR] Page not found: $Page ($($helpBook.Path))"
		exit 1
	}
	Out "[$platformName] $Page"
	foreach ($l in (ConvertFrom-HelpHtml (Read-HelpEntry $entry))) { Out $l }
} else {
	# --- Search mode ---
	# Все слова запроса должны встретиться в заголовке (или в тексте при -InText). Порядок:
	# точное совпадение заголовка, заголовок начинается с запроса, запрос целиком внутри,
	# слова по отдельности, совпадение только в тексте; внутри группы — короткие заголовки выше.
	$query = ($Search -replace '\s+', ' ').Trim()
	$words = @($query.Split(' '))
	$hits = New-Object System.Collections.Generic.List[string]
	foreach ($bookName in @($Book.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
		$helpBook = Open-HelpBook $bookName
		foreach ($row in (Get-HelpIndex $helpBook)) {
			$title = $row.Title
			$rank = -1
			if ($title.Equals($query, [StringComparison]::OrdinalIgnoreCase)) { $rank = 0 }
			elseif ($title.StartsWith($query, [StringComparison]::OrdinalIgnoreCase)) { $rank = 1 }
			elseif ($title.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $rank = 2 }
			elseif (@($words | Where-Object { $title.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }).Count -eq 0) { $rank = 3 }
			elseif ($InText) {
				$text = (ConvertFrom-HelpHtml (Read-HelpEntry ($helpBook.Archive.GetEntry($row.Path)))) -join "`n"
				if (@($words | Where-Object { $text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }).Count -eq 0) { $rank = 4 }
			}
			if ($rank -ge 0) {
				# Ключ сортировки несёт и саму строку вывода: так порядок не зависит от культуры
				# и совпадает с py-портом (порядковое сравнение).
				$hits.Add(('{0}|{1:D6}|{2}:{3} | {4}' -f $rank, $title.Length, $bookName, $row.Path, $title))
			}
		}
	}
	if ($hits.Count -eq 0) {
		Write-Host "[INFO] Nothing found: $query"
		exit 0
	}
	$keys = $hits.ToArray()
	[Array]::Sort($keys, [StringComparer]::Ordinal)
	Out "[$platformName] Found: $($keys.Count)"
	foreach ($k in $keys) { Out $k.Split([char[]]'|', 3)[2] }
}

# --- Pagination ---
$totalLines = $script:lines.Count
$outLines = $script:lines.ToArray()
if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$outLines = $outLines[$Offset..($totalLines - 1)]
}
if ($Limit -gt 0 -and $outLines.Count -gt $Limit) {
	$shown = $outLines[0..($Limit - 1)]
	$shown += ""
	$shown += "[ОБРЕЗАНО] Показано $Limit из $totalLines строк. Используйте -Offset $($Offset + $Limit) для продолжения."
	$outLines = $shown
}
foreach ($l in $outLines) { Write-Host $l }
exit 0
