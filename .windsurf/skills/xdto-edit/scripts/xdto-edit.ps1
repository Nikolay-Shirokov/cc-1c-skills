# xdto-edit v1.7 — Point edits of a 1C XDTO package (+support-guard: общая реализация вместо урезанной)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory=$true)]
	[Alias('Path')]
	[string]$PackagePath,
	[Parameter(Mandatory=$true)]
	[ValidateSet("add-property", "replace-property", "remove-property",
	             "add-type", "remove-type", "add-enum", "add-import",
	             "rename", "set-synonym", "set-comment", "set-namespace")]
	[string]$Operation,
	[string]$Target,
	[string]$Value,
	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$XDTO_NS = "http://v8.1c.ru/8.1/xdto"
$XS_NS   = "http://www.w3.org/2001/XMLSchema"
$MD_NS   = "http://v8.1c.ru/8.3/MDClasses"
$V8_NS   = "http://v8.1c.ru/8.1/data/core"

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

# --- Resolve package ------------------------------------------------------------

if (-not [System.IO.Path]::IsPathRooted($PackagePath)) {
	$PackagePath = Join-Path (Get-Location).Path $PackagePath
}

$pkgDir = $null
if (Test-Path $PackagePath -PathType Container) {
	if (Test-Path (Join-Path (Join-Path $PackagePath "Ext") "Package.bin")) { $pkgDir = $PackagePath }
} elseif ((Test-Path $PackagePath -PathType Leaf) -and ([System.IO.Path]::GetFileName($PackagePath) -eq "Package.bin")) {
	$pkgDir = Split-Path (Split-Path $PackagePath -Parent) -Parent
} elseif ($PackagePath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PackagePath),
	                                  [System.IO.Path]::GetFileNameWithoutExtension($PackagePath))
	if (Test-Path (Join-Path (Join-Path $stem "Ext") "Package.bin")) { $pkgDir = $stem }
}
if (-not $pkgDir) { throw "Не найден пакет XDTO по пути: $PackagePath" }

$pkgName    = [System.IO.Path]::GetFileName($pkgDir)
$xdtoRoot   = Split-Path $pkgDir -Parent
$configRoot = Split-Path $xdtoRoot -Parent
$binFile    = Join-Path (Join-Path $pkgDir "Ext") "Package.bin"
$mdFile     = Join-Path $xdtoRoot "$pkgName.xml"
$configXml  = Join-Path $configRoot "Configuration.xml"

# -Value "@путь" — содержимое берётся из файла. Передавать XSD-фрагмент инлайном
# через powershell.exe -File ненадёжно: вложенные кавычки схлопываются на границе
# процессов, и вместо понятной ошибки получается сырой сбой разбора XML.
if ($Value -and $Value.StartsWith("@")) {
	$valueFile = $Value.Substring(1)
	if (-not [System.IO.Path]::IsPathRooted($valueFile)) {
		$valueFile = Join-Path (Get-Location).Path $valueFile
	}
	if (-not (Test-Path $valueFile -PathType Leaf)) { throw "Файл значения не найден: $valueFile" }
	$Value = [System.IO.File]::ReadAllText($valueFile).Trim()
}

Assert-EditAllowed $pkgDir "editable"

$encBom = New-Object System.Text.UTF8Encoding($true)

# --- Sibling skills -------------------------------------------------------------
# Правка идёт через уже проверенный round-trip: пакет выгружается в XSD, операция
# применяется к схеме, пакет собирается обратно. Второго эмиттера не заводим —
# байт-точность для всего нетронутого достаётся от компилятора.

$decompileScript = Join-Path (Join-Path $PSScriptRoot "..\..\xdto-decompile") "scripts\xdto-decompile.ps1"
$compileScript   = Join-Path (Join-Path $PSScriptRoot "..\..\xdto-compile") "scripts\xdto-compile.ps1"
$validateScript  = Join-Path (Join-Path $PSScriptRoot "..\..\xdto-validate") "scripts\xdto-validate.ps1"

# Исключение из автономности навыков, сделанное осознанно: конвертер XSD ↔ модель
# нельзя скопировать буквально (xdto-compile — скрипт со сквозным потоком, не библиотека),
# а вторая его реализация разошлась бы с первой. Обещание «правка не меняет ни байта
# в нетронутом» держится именно на том, что код тот же самый.
# Проверяем комплектность заранее, чтобы не падать на середине правки.
function Assert-SiblingsPresent([string]$operation) {
	$needed = @{}
	if (@("rename", "set-synonym", "set-comment") -notcontains $operation) {
		$needed["xdto-decompile"] = $decompileScript
		$needed["xdto-compile"]   = $compileScript
	}
	$missing = @()
	foreach ($k in $needed.Keys) { if (-not (Test-Path $needed[$k])) { $missing += $k } }
	if ($missing.Count -gt 0) {
		$skillsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
		throw ("Навык неработоспособен: рядом нет " + ($missing -join ", ") + ".`n" +
		       "Операция `"$operation`" выполняется через " +
		       $(if ($missing.Count -gt 1) { "них" } else { "него" }) + ".`n" +
		       "Ожидаются в каталоге навыков: $skillsRoot")
	}
}

function Invoke-Sibling([string]$script, [string[]]$argList, [string]$what) {
	if (-not (Test-Path $script)) { throw "Не найден навык $what по пути: $script" }
	$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @argList 2>&1
	if ($LASTEXITCODE -ne 0) { throw "$what завершился с ошибкой:`n$($out -join "`n")" }
	return $out
}

# --- Metadata object edits ------------------------------------------------------

function Edit-Metadata([string]$field, [string]$newValue) {
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	$doc.Load($mdFile)
	$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$nsm.AddNamespace("md", $MD_NS)
	$nsm.AddNamespace("v8", $V8_NS)
	$props = $doc.SelectSingleNode("//md:XDTOPackage/md:Properties", $nsm)
	if (-not $props) { throw "В объекте метаданных не найден блок <Properties>" }

	switch ($field) {
		"Name" {
			$n = $props.SelectSingleNode("md:Name", $nsm)
			if (-not $n) { throw "В объекте метаданных нет <Name>" }
			$n.InnerText = $newValue
		}
		"Comment" {
			$c = $props.SelectSingleNode("md:Comment", $nsm)
			if (-not $c) {
				$c = $doc.CreateElement("Comment", $MD_NS)
				$props.AppendChild($c) | Out-Null
			}
			$c.InnerText = $newValue
		}
		"Namespace" {
			$ns = $props.SelectSingleNode("md:Namespace", $nsm)
			if (-not $ns) { throw "В объекте метаданных нет <Namespace>" }
			$ns.InnerText = $newValue
		}
		"Synonym" {
			$syn = $props.SelectSingleNode("md:Synonym", $nsm)
			if (-not $syn) {
				$syn = $doc.CreateElement("Synonym", $MD_NS)
				$props.AppendChild($syn) | Out-Null
			}
			$item = $syn.SelectSingleNode("v8:item[v8:lang='ru']", $nsm)
			if (-not $item) {
				$item = $doc.CreateElement("v8", "item", $V8_NS)
				$lang = $doc.CreateElement("v8", "lang", $V8_NS); $lang.InnerText = "ru"
				$cont = $doc.CreateElement("v8", "content", $V8_NS)
				$item.AppendChild($lang) | Out-Null
				$item.AppendChild($cont) | Out-Null
				$syn.AppendChild($item) | Out-Null
			}
			$item.SelectSingleNode("v8:content", $nsm).InnerText = $newValue
		}
	}

	$settings = New-Object System.Xml.XmlWriterSettings
	$settings.Encoding = $encBom
	$settings.Indent = $false
	$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
	# Через MemoryStream, а не прямо в файл: нужен шаг пост-обработки строки.
	$memStream = New-Object System.IO.MemoryStream
	$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
	$doc.Save($writer)
	$writer.Flush(); $writer.Close()

	$mdText = [System.Text.Encoding]::UTF8.GetString($memStream.ToArray())
	$memStream.Close()
	if ($mdText.Length -gt 0 -and $mdText[0] -eq [char]0xFEFF) { $mdText = $mdText.Substring(1) }
	$mdText = $mdText.Replace('encoding="utf-8"', 'encoding="UTF-8"')
	# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
	# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
	# поэтому они идут первыми ветками альтернации и возвращаются как есть.
	$mdText = [regex]::Replace($mdText, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
	# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
	# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
	$targetEol = if ((Test-Path -LiteralPath $mdFile) -and ([System.IO.File]::ReadAllText($mdFile) -notmatch "`r`n")) { "`n" } else { "`r`n" }
	$mdText = ($mdText -replace "`r`n", "`n") -replace "`n", $targetEol
	[System.IO.File]::WriteAllText($mdFile, $mdText, $encBom)
}

function Rename-Package([string]$newName) {
	if ($newName -notmatch '^[\wЀ-ӿ]+$' -or $newName -match '^\d') {
		throw "`"$newName`" не является допустимым идентификатором 1С"
	}
	$newMd  = Join-Path $xdtoRoot "$newName.xml"
	$newDir = Join-Path $xdtoRoot $newName
	if ((Test-Path $newMd) -or (Test-Path $newDir)) { throw "Имя `"$newName`" уже занято другим пакетом" }

	Edit-Metadata "Name" $newName
	Move-Item $mdFile $newMd
	Move-Item $pkgDir $newDir

	if (Test-Path $configXml) {
		$cfg = New-Object System.Xml.XmlDocument
		$cfg.PreserveWhitespace = $true
		$cfg.Load($configXml)
		$nsm = New-Object System.Xml.XmlNamespaceManager($cfg.NameTable)
		$nsm.AddNamespace("md", $MD_NS)
		$found = $false
		foreach ($e in $cfg.SelectNodes("//md:Configuration/md:ChildObjects/md:XDTOPackage", $nsm)) {
			if ($e.InnerText -eq $pkgName) { $e.InnerText = $newName; $found = $true; break }
		}
		if ($found) {
			$s = New-Object System.Xml.XmlWriterSettings
			$s.Encoding = $encBom; $s.Indent = $false
			$s.NewLineHandling = [System.Xml.NewLineHandling]::None
			# Через MemoryStream, а не прямо в файл: нужен шаг пост-обработки строки.
			$mem = New-Object System.IO.MemoryStream
			$w = [System.Xml.XmlWriter]::Create($mem, $s)
			$cfg.Save($w); $w.Flush(); $w.Close()
			$cfgText = [System.Text.Encoding]::UTF8.GetString($mem.ToArray())
			$mem.Close()
			if ($cfgText.Length -gt 0 -and $cfgText[0] -eq [char]0xFEFF) { $cfgText = $cfgText.Substring(1) }
			$cfgText = $cfgText.Replace('encoding="utf-8"', 'encoding="UTF-8"')
			# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
			# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
			# поэтому они идут первыми ветками альтернации и возвращаются как есть.
			$cfgText = [regex]::Replace($cfgText, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
			# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
			# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
			$targetEol = if ((Test-Path -LiteralPath $configXml) -and ([System.IO.File]::ReadAllText($configXml) -notmatch "`r`n")) { "`n" } else { "`r`n" }
			$cfgText = ($cfgText -replace "`r`n", "`n") -replace "`n", $targetEol
			[System.IO.File]::WriteAllText($configXml, $cfgText, $encBom)
			Write-Host "  Configuration.xml: <XDTOPackage> переименован в $newName"
		} else {
			Write-Warning "В Configuration.xml не найдена запись <XDTOPackage>$pkgName</XDTOPackage> — зарегистрируйте пакет вручную"
		}
	}
	Write-Host "✓ Пакет переименован: $pkgName → $newName"
	Write-Host "  Перемещены: $newName.xml, $newName/"
}

# --- Model edits through the XSD round-trip -------------------------------------

$XSD_DECL = @{ "add-property" = "element"; "replace-property" = "element"; "remove-property" = "element" }

function Get-SchemaChildren([System.Xml.XmlElement]$el, [string]$local) {
	$res = New-Object System.Collections.ArrayList
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.NamespaceURI -eq $XS_NS -and $c.get_LocalName() -eq $local) { [void]$res.Add($c) }
	}
	return ,$res
}
function Get-SchemaFirst([System.Xml.XmlElement]$el, [string]$local) {
	$r = Get-SchemaChildren $el $local
	if ($r.Count -gt 0) { return $r[0] }
	return $null
}

function Find-TypeElement($schema, [string]$typeName) {
	foreach ($kind in @("complexType", "simpleType")) {
		foreach ($t in (Get-SchemaChildren $schema $kind)) {
			if ($t.GetAttribute("name") -eq $typeName) { return $t }
		}
	}
	throw "В пакете нет типа `"$typeName`""
}

# Тело типа: внутрь xs:complexContent/xs:extension, если тип наследуется
function Get-TypeBody([System.Xml.XmlElement]$ct) {
	$content = Get-SchemaFirst $ct "complexContent"
	if ($content) {
		$ext = Get-SchemaFirst $content "extension"
		if ($ext) { return $ext }
	}
	return $ct
}

function Find-Declaration([System.Xml.XmlElement]$body, [string]$propName) {
	foreach ($node in $body.SelectNodes(".//*")) {
		if ($node.NamespaceURI -ne $XS_NS) { continue }
		if (@("element", "attribute") -notcontains $node.get_LocalName()) { continue }
		if ($node.GetAttribute("name") -eq $propName) { return $node }
	}
	return $null
}

# Путь Тип.Свойство[.Вложенное...] — точка безопасна: имена в модели XDTO
# являются идентификаторами 1С и точку содержать не могут
function Resolve-Path($schema, [string]$path) {
	$segments = $path.Split(".")
	$typeEl = Find-TypeElement $schema $segments[0]
	if ($segments.Count -eq 1) { return [pscustomobject]@{ Type = $typeEl; Decl = $null } }

	$body = Get-TypeBody $typeEl
	$decl = $null
	for ($i = 1; $i -lt $segments.Count; $i++) {
		$decl = Find-Declaration $body $segments[$i]
		if (-not $decl) { throw "По пути `"$path`" не найдено свойство `"$($segments[$i])`"" }
		if ($i -lt $segments.Count - 1) {
			$inner = Get-SchemaFirst $decl "complexType"
			if (-not $inner) { throw "Свойство `"$($segments[$i])`" не содержит вложенного типа — путь дальше не идёт" }
			$body = Get-TypeBody $inner
		}
	}
	return [pscustomobject]@{ Type = $typeEl; Decl = $decl }
}

function Import-Fragment($schema, [string]$xml) {
	$tmp = New-Object System.Xml.XmlDocument
	$nsAttrs = " xmlns:xs=`"$XS_NS`" xmlns:xdto=`"$XDTO_NS`""
	$tns = $schema.GetAttribute("targetNamespace")
	if ($tns) { $nsAttrs += " xmlns:tns=`"$tns`"" }
	foreach ($a in $schema.Attributes) {
		if ($a.Prefix -eq "xmlns" -and $a.get_LocalName() -notin @("xs", "xdto", "tns")) {
			$nsAttrs += " xmlns:$($a.get_LocalName())=`"$($a.Value)`""
		}
	}
	try { $tmp.LoadXml("<wrap$nsAttrs>$xml</wrap>") }
	catch {
		throw ("Не удалось разобрать -Value как фрагмент XML-схемы: " + $_.Exception.InnerException.Message + "`n" +
			"Получено: " + $xml + "`n" +
			"Если фрагмент передан инлайном, кавычки могли схлопнуться на границе процессов — " +
			"положите его в файл и укажите -Value `"@путь`".")
	}
	$res = New-Object System.Collections.ArrayList
	foreach ($c in $tmp.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) {
			[void]$res.Add($schema.OwnerDocument.ImportNode($c, $true))
		}
	}
	if ($res.Count -eq 0) { throw "Во фрагменте нет ни одного элемента: $xml" }
	return ,$res
}

function Apply-ModelOperation($schema) {
	switch ($Operation) {

		"add-property" {
			if (-not $Target) { throw "add-property требует -Target <Тип>" }
			$loc = Resolve-Path $schema $Target
			$body = Get-TypeBody $(if ($loc.Decl) { Get-SchemaFirst $loc.Decl "complexType" } else { $loc.Type })
			foreach ($frag in (Import-Fragment $schema $Value)) {
				$kind = $frag.get_LocalName()
				if ($kind -eq "attribute") {
					$body.AppendChild($frag) | Out-Null
				} elseif ($kind -eq "element") {
					$particle = Get-SchemaFirst $body "sequence"
					if (-not $particle) { $particle = Get-SchemaFirst $body "choice" }
					if (-not $particle) { $particle = Get-SchemaFirst $body "all" }
					if (-not $particle) {
						$particle = $schema.OwnerDocument.CreateElement("xs", "sequence", $XS_NS)
						$firstAttr = Get-SchemaFirst $body "attribute"
						if ($firstAttr) { $body.InsertBefore($particle, $firstAttr) | Out-Null }
						else { $body.AppendChild($particle) | Out-Null }
					}
					$particle.AppendChild($frag) | Out-Null
				} else {
					throw "add-property ожидает <xs:element> или <xs:attribute>, получен <xs:$kind>"
				}
				Write-Host "  + $($frag.GetAttribute('name'))  в тип $Target"
			}
		}

		"replace-property" {
			if (-not $Target) { throw "replace-property требует -Target `"Тип.Свойство`"" }
			$loc = Resolve-Path $schema $Target
			if (-not $loc.Decl) { throw "replace-property требует путь вида `"Тип.Свойство`"" }
			$frags = Import-Fragment $schema $Value
			if ($frags.Count -ne 1) { throw "replace-property ожидает ровно одно объявление" }
			$loc.Decl.ParentNode.ReplaceChild($frags[0], $loc.Decl) | Out-Null
			Write-Host "  ~ $Target заменено"
		}

		"remove-property" {
			if (-not $Target) { throw "remove-property требует путь `"Тип.Свойство`"" }
			foreach ($one in ($Target -split "\s*;;\s*")) {
				if (-not $one) { continue }
				$loc = Resolve-Path $schema $one
				if (-not $loc.Decl) { throw "remove-property требует путь вида `"Тип.Свойство`", получено `"$one`"" }
				$loc.Decl.ParentNode.RemoveChild($loc.Decl) | Out-Null
				Write-Host "  − $one удалено"
			}
		}

		"add-type" {
			foreach ($frag in (Import-Fragment $schema $Value)) {
				if (@("complexType", "simpleType") -notcontains $frag.get_LocalName()) {
					throw "add-type ожидает <xs:complexType> или <xs:simpleType>, получен <xs:$($frag.get_LocalName())>"
				}
				$schema.AppendChild($frag) | Out-Null
				Write-Host "  + тип $($frag.GetAttribute('name'))"
			}
		}

		"remove-type" {
			if (-not $Target) { throw "remove-type требует -Target <Тип>" }
			foreach ($one in ($Target -split "\s*;;\s*")) {
				if (-not $one) { continue }
				$t = Find-TypeElement $schema $one
				$t.ParentNode.RemoveChild($t) | Out-Null
				Write-Host "  − тип $one удалён"
			}
		}

		"add-enum" {
			if (-not $Target) { throw "add-enum требует -Target <ТипЗначения>" }
			$t = Find-TypeElement $schema $Target
			$restriction = Get-SchemaFirst $t "restriction"
			if (-not $restriction) { throw "Тип `"$Target`" не является ограничением простого типа" }
			foreach ($lit in ($Value -split "\s*;;\s*")) {
				if (-not $lit) { continue }
				$e = $schema.OwnerDocument.CreateElement("xs", "enumeration", $XS_NS)
				$e.SetAttribute("value", $lit)
				$restriction.AppendChild($e) | Out-Null
				Write-Host "  + значение `"$lit`" в тип $Target"
			}
		}

		"add-import" {
			foreach ($uri in ($Value -split "\s*;;\s*")) {
				if (-not $uri) { continue }
				$exists = $false
				foreach ($i in (Get-SchemaChildren $schema "import")) {
					if ($i.GetAttribute("namespace") -eq $uri) { $exists = $true; break }
				}
				if ($exists) { Write-Host "  = импорт $uri уже объявлен"; continue }
				$imp = $schema.OwnerDocument.CreateElement("xs", "import", $XS_NS)
				$imp.SetAttribute("namespace", $uri)
				$firstOther = $null
				foreach ($c in $schema.ChildNodes) {
					if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -notin @("annotation", "import")) { $firstOther = $c; break }
				}
				if ($firstOther) { $schema.InsertBefore($imp, $firstOther) | Out-Null } else { $schema.AppendChild($imp) | Out-Null }
				Write-Host "  + импорт $uri"
			}
		}

		"set-namespace" {
			if (-not $Value) { throw "set-namespace требует -Value <URI>" }
			$old = $schema.GetAttribute("targetNamespace")
			# Установка того же значения не отбрасывается: пакет пересобирается вхолостую,
			# и это заодно проба точности пути «выгрузить → собрать» на любом пакете
			if ($old -eq $Value) { Write-Host "  = namespace уже $Value, пакет пересобран без изменений" }
			# Меняем и targetNamespace, и объявление префикса, который на него указывал:
			# иначе ссылки на собственные типы станут ссылками в чужое пространство имён
			$schema.SetAttribute("targetNamespace", $Value)
			foreach ($a in @($schema.Attributes)) {
				if ($a.Prefix -eq "xmlns" -and $a.Value -eq $old) {
					$schema.SetAttribute("xmlns:$($a.get_LocalName())", $Value)
				}
			}
			Write-Host "  ~ namespace: $old → $Value"
		}
	}
}

# --- Dispatch -------------------------------------------------------------------

$metaOps = @("rename", "set-synonym", "set-comment")
$touchesModel = ($metaOps -notcontains $Operation)

Assert-SiblingsPresent $Operation

Write-Host "Пакет: $pkgName"

if ($Operation -eq "rename") {
	if (-not $Value) { throw "rename требует -Value <НовоеИмя>" }
	Rename-Package $Value
	$pkgName = $Value
	$pkgDir  = Join-Path $xdtoRoot $Value
} elseif ($Operation -eq "set-synonym") {
	if (-not $Value) { throw "set-synonym требует -Value <текст>" }
	Edit-Metadata "Synonym" $Value
	Write-Host "✓ Синоним: $Value"
} elseif ($Operation -eq "set-comment") {
	Edit-Metadata "Comment" $Value
	Write-Host "✓ Комментарий обновлён"
} else {
	$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdto-edit_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
	New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
	try {
		$xsdPath = Join-Path $tmpDir "schema.xsd"
		Invoke-Sibling $decompileScript @("-PackagePath", $binFile, "-OutFile", $xsdPath) "xdto-decompile" | Out-Null

		$doc = New-Object System.Xml.XmlDocument
		$doc.PreserveWhitespace = $false
		$doc.Load($xsdPath)
		$schema = $doc.DocumentElement

		$oldNamespace = $schema.GetAttribute("targetNamespace")
		Apply-ModelOperation $schema

		$doc.Save($xsdPath)
		Invoke-Sibling $compileScript @("-XsdPath", $xsdPath, "-OutputDir", $configRoot, "-Name", $pkgName, "-Force") "xdto-compile" | Out-Null

		if ($Operation -eq "set-namespace") {
			Edit-Metadata "Namespace" $Value
			# Зависящие пакеты не трогаем: при версионировании они обязаны продолжать
			# смотреть на прежний namespace. Но молчать о них нельзя.
			$dependents = @()
			foreach ($d in (Get-ChildItem $xdtoRoot -Directory -ErrorAction SilentlyContinue)) {
				if ($d.Name -eq $pkgName) { continue }
				$ob = Join-Path (Join-Path $d.FullName "Ext") "Package.bin"
				if (-not (Test-Path $ob)) { continue }
				try {
					$od = New-Object System.Xml.XmlDocument
					$od.Load($ob)
					foreach ($imp in $od.DocumentElement.ChildNodes) {
						if ($imp.NodeType -eq [System.Xml.XmlNodeType]::Element -and $imp.get_LocalName() -eq "import" -and
						    $imp.GetAttribute("namespace") -eq $oldNamespace) { $dependents += $d.Name; break }
					}
				} catch {}
			}
			if ($dependents.Count -gt 0) {
				Write-Host ""
				Write-Warning ("Старый namespace импортируют пакеты ($($dependents.Count)): " + ($dependents -join ", ") +
				               ". Они не изменены — при версионировании это верно; если нет, поправьте их импорты.")
			}
		}
		Write-Host "✓ Пакет пересобран: XDTOPackages/$pkgName/Ext/Package.bin"
	} finally {
		Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
	}
}

# --- Validate -------------------------------------------------------------------

if (-not $NoValidate) {
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- xdto-validate ---"
		& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validateScript -PackagePath (Join-Path $xdtoRoot $pkgName)
	} else {
		Write-Host "[SKIP] xdto-validate не найден: $validateScript"
	}
}
exit 0
