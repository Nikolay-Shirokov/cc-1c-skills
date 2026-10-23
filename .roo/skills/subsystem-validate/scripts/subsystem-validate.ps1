# subsystem-validate v1.6 — Validate 1C subsystem XML structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)][Alias('Path')][string]$SubsystemPath,
	[switch]$Detailed,
	[int]$MaxErrors = 30,
	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Копия общего эталона (семья
# root_version, авторитет — meta-validate).
function Get-RootVersion([string]$xmlPath) {
	if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { return $null }
	$buf = New-Object byte[] 4096
	$fs = [System.IO.File]::OpenRead($xmlPath)
	try { $len = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
	$head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
	$m = [regex]::Match($head, '<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>')
	if (-not $m.Success) { return $null }
	$v = [regex]::Match($m.Groups[1].Value, '(?:^|\s)version="([^"]*)"')
	if ($v.Success) { return $v.Groups[1].Value }
	return $null
}

# Корень автономной внешней обработки/отчёта. Копия общего эталона (семья is_external_root,
# авторитет — cf-edit).
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

# Якорь выгрузки: корень автономной EPF/ERF либо Configuration.xml, ближайший вверх. Копия общего
# эталона (семья find_dump_anchor, авторитет — meta-validate).
function Find-DumpAnchor([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 15 -and $d; $i++) {
		if (Test-ExternalObjectRoot "$d.xml") { return "$d.xml" }
		$cfg = Join-Path $d "Configuration.xml"
		if (Test-Path $cfg) { return $cfg }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if (-not $parent -or $parent -eq $d) { break }
		$d = $parent
	}
	return $null
}

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($SubsystemPath)) {
	$SubsystemPath = Join-Path (Get-Location).Path $SubsystemPath
}
if (Test-Path $SubsystemPath -PathType Container) {
	$dirName = Split-Path $SubsystemPath -Leaf
	$candidate = Join-Path $SubsystemPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $SubsystemPath) "$dirName.xml"
	if (Test-Path $candidate) { $SubsystemPath = $candidate }
	elseif (Test-Path $sibling) { $SubsystemPath = $sibling }
	else {
		Write-Host "[ERROR] No $dirName.xml found in directory: $SubsystemPath"
		exit 1
	}
}
# File not found — check Dir/Name/Name.xml → Dir/Name.xml
if (-not (Test-Path $SubsystemPath)) {
	$fn = [System.IO.Path]::GetFileNameWithoutExtension($SubsystemPath)
	$pd = Split-Path $SubsystemPath
	if ($fn -eq (Split-Path $pd -Leaf)) {
		$c = Join-Path (Split-Path $pd) "$fn.xml"
		if (Test-Path $c) { $SubsystemPath = $c }
	}
}
if (-not (Test-Path $SubsystemPath)) {
	Write-Host "[ERROR] File not found: $SubsystemPath"
	exit 1
}
$resolvedPath = (Resolve-Path $SubsystemPath).Path

# --- Output infrastructure ---
$script:errors = 0
$script:warnings = 0
$script:stopped = $false
$script:okCount = 0
$script:output = New-Object System.Text.StringBuilder 8192

function Out-Line([string]$msg) { $script:output.AppendLine($msg) | Out-Null }
function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Out-Line "[OK]    $msg" }
}
function Report-Error {
	param([string]$msg)
	$script:errors++
	Out-Line "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}
function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Out-Line "[WARN]  $msg"
}

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$identPattern = '^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_][A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'

# Known plural forms that are NOT valid in subsystem Content (platform expects singular)
$knownPluralTypes = @(
	"Catalogs","Documents","Enums","Constants","Reports","DataProcessors"
	"InformationRegisters","AccumulationRegisters","AccountingRegisters","CalculationRegisters"
	"ChartsOfAccounts","ChartsOfCharacteristicTypes","ChartsOfCalculationTypes"
	"BusinessProcesses","Tasks","ExchangePlans","DocumentJournals"
	"CommonModules","CommonCommands","CommonForms","CommonPictures","CommonTemplates"
	"CommonAttributes","CommandGroups","Roles","SessionParameters","FilterCriteria"
	"XDTOPackages","WebServices","HTTPServices","WSReferences","EventSubscriptions"
	"ScheduledJobs","SettingsStorages","FunctionalOptions","FunctionalOptionsParameters"
	"DefinedTypes","DocumentNumerators","Sequences","Subsystems","StyleItems","IntegrationServices"
)

# --- 1. XML well-formedness + root structure ---
$xmlDoc = $null
try {
	[xml]$xmlDoc = Get-Content -Path $resolvedPath -Encoding UTF8
} catch {
	Report-Error "1. XML parse error: $($_.Exception.Message)"
	$script:stopped = $true
}

if (-not $script:stopped) {
	$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
	$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
	$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
	$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

	$root = $xmlDoc.DocumentElement
	$sub = $xmlDoc.SelectSingleNode("/md:MetaDataObject/md:Subsystem", $ns)
	$version = $root.GetAttribute("version")

	if (-not $sub) {
		Report-Error "1. Root structure: expected MetaDataObject/Subsystem, not found"
		$script:stopped = $true
	} else {
		$uuid = $sub.GetAttribute("uuid")
		if ($uuid -and $uuid -match $guidPattern) {
			Report-OK "1. Root structure: MetaDataObject/Subsystem, uuid=$uuid, version $version"
		} else {
			Report-Error "1. Root structure: invalid or missing uuid"
		}
	}
}

# --- Properties checks ---
if (-not $script:stopped) {
	$props = $sub.SelectSingleNode("md:Properties", $ns)
	if (-not $props) {
		Report-Error "2. Properties: <Properties> element not found"
		$script:stopped = $true
	}
}

$subName = ""
if (-not $script:stopped) {
	# --- 2. Required properties ---
	$requiredProps = @("Name","Synonym","Comment","IncludeHelpInContents","IncludeInCommandInterface","UseOneCommand","Explanation","Picture","Content")
	$missing = @()
	foreach ($p in $requiredProps) {
		$el = $props.SelectSingleNode("md:$p", $ns)
		if (-not $el) { $missing += $p }
	}
	if ($missing.Count -eq 0) {
		Report-OK "2. Properties: all 9 required properties present"
	} else {
		Report-Error "2. Properties: missing: $($missing -join ', ')"
	}

	# --- 3. Name ---
	$nameEl = $props.SelectSingleNode("md:Name", $ns)
	$subName = if ($nameEl) { $nameEl.InnerText.Trim() } else { "" }
	# Re-insert header at position 0
	$headerLine = "=== Validation: Subsystem.$subName ==="
	$script:output.Insert(0, "$headerLine`r`n`r`n") | Out-Null

	if ($subName -and $subName -match $identPattern) {
		Report-OK "3. Name: `"$subName`" - valid identifier"
	} elseif (-not $subName) {
		Report-Error "3. Name: empty"
	} else {
		Report-Error "3. Name: `"$subName`" - invalid identifier"
	}

	# --- 4. Synonym ---
	$synEl = $props.SelectSingleNode("md:Synonym", $ns)
	if ($synEl -and $synEl.HasChildNodes) {
		$items = $synEl.SelectNodes("v8:item", $ns)
		if ($items.Count -gt 0) {
			$firstContent = ""
			foreach ($item in $items) {
				$c = $item.SelectSingleNode("v8:content", $ns)
				if ($c -and $c.InnerText) { $firstContent = $c.InnerText; break }
			}
			Report-OK "4. Synonym: `"$firstContent`" ($($items.Count) lang(s))"
		} else {
			Report-Warn "4. Synonym: element exists but no v8:item children"
		}
	} else {
		Report-Warn "4. Synonym: empty or missing"
	}

	# --- 5. Boolean properties ---
	$boolProps = @("IncludeHelpInContents","IncludeInCommandInterface","UseOneCommand")
	$boolOk = $true
	$boolVals = @{}
	foreach ($bp in $boolProps) {
		$el = $props.SelectSingleNode("md:$bp", $ns)
		if ($el) {
			$val = $el.InnerText.Trim()
			$boolVals[$bp] = $val
			if ($val -ne "true" -and $val -ne "false") {
				Report-Error "5. Boolean property $bp = `"$val`" (expected true/false)"
				$boolOk = $false
			}
		}
	}
	if ($boolOk) { Report-OK "5. Boolean properties: valid" }

	# --- 6. Content items format ---
	$contentEl = $props.SelectSingleNode("md:Content", $ns)
	$contentItems = @()
	if ($contentEl -and $contentEl.HasChildNodes) {
		$xrItems = $contentEl.SelectNodes("xr:Item", $ns)
		$contentOk = $true
		foreach ($item in $xrItems) {
			$typeAttr = $item.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			$text = $item.InnerText.Trim()
			$contentItems += $text
			if ($typeAttr -ne "xr:MDObjectRef") {
				Report-Error "6. Content item `"$text`": xsi:type=`"$typeAttr`" (expected xr:MDObjectRef)"
				$contentOk = $false
			}
			if ($text -notmatch '^[A-Za-z]+\..+$' -and $text -notmatch $guidPattern) {
				Report-Error "6. Content item `"$text`": invalid format (expected Type.Name or UUID)"
				$contentOk = $false
			}
			if ($text -match '^([A-Za-z]+)\.') {
				$typePart = $Matches[1]
				if ($typePart -in $knownPluralTypes) {
					Report-Error "6. Content item `"$text`": uses plural form `"$typePart`" (platform requires singular, e.g. Catalog not Catalogs)"
					$contentOk = $false
				}
			}
		}
		if ($contentOk) { Report-OK "6. Content: $($xrItems.Count) items, all valid MDObjectRef format" }
	} else {
		Report-OK "6. Content: empty (no items)"
	}

	# --- 7. Content duplicates ---
	if ($contentItems.Count -gt 0) {
		$dupes = $contentItems | Group-Object | Where-Object { $_.Count -gt 1 }
		if ($dupes) {
			$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
			Report-Warn "7. Content: duplicates found: $dupeNames"
		} else {
			Report-OK "7. Content: no duplicates"
		}
	} else {
		Report-OK "7. Content: no duplicates (empty)"
	}

	# --- 8. ChildObjects entries non-empty ---
	$childObjs = $sub.SelectSingleNode("md:ChildObjects", $ns)
	$childNames = @()
	if ($childObjs -and $childObjs.HasChildNodes) {
		$childOk = $true
		foreach ($child in $childObjs.ChildNodes) {
			if ($child.NodeType -ne 'Element') { continue }
			if ($child.LocalName -ne "Subsystem") {
				Report-Error "8. ChildObjects: unexpected element <$($child.LocalName)>"
				$childOk = $false
			} elseif (-not $child.InnerText.Trim()) {
				Report-Error "8. ChildObjects: empty <Subsystem> element"
				$childOk = $false
			} else {
				$childNames += $child.InnerText.Trim()
			}
		}
		if ($childOk) { Report-OK "8. ChildObjects: $($childNames.Count) entries, all non-empty" }
	} else {
		Report-OK "8. ChildObjects: empty (leaf subsystem)"
	}

	# --- 9. ChildObjects duplicates ---
	if ($childNames.Count -gt 0) {
		$dupes = $childNames | Group-Object | Where-Object { $_.Count -gt 1 }
		if ($dupes) {
			$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
			Report-Error "9. ChildObjects: duplicates: $dupeNames"
		} else {
			Report-OK "9. ChildObjects: no duplicates"
		}
	} else {
		Report-OK "9. ChildObjects: no duplicates (empty)"
	}

	# --- 10. ChildObjects files exist ---
	if ($childNames.Count -gt 0) {
		$parentDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
		$baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
		$subsDir = Join-Path (Join-Path $parentDir $baseName) "Subsystems"
		$missingFiles = @()
		foreach ($cn in $childNames) {
			$childXml = Join-Path $subsDir "$cn.xml"
			if (-not (Test-Path $childXml)) { $missingFiles += $cn }
		}
		if ($missingFiles.Count -eq 0) {
			Report-OK "10. ChildObjects files: all $($childNames.Count) files exist"
		} else {
			Report-Warn "10. ChildObjects files: missing: $($missingFiles -join ', ')"
		}
	}

	# --- 11. CommandInterface.xml ---
	$parentDir2 = [System.IO.Path]::GetDirectoryName($resolvedPath)
	$baseName2 = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
	$ciPath = Join-Path (Join-Path (Join-Path $parentDir2 $baseName2) "Ext") "CommandInterface.xml"
	if (Test-Path $ciPath) {
		try {
			[xml]$ciDoc = Get-Content -Path $ciPath -Encoding UTF8
			Report-OK "11. CommandInterface: exists, well-formed"
		} catch {
			Report-Warn "11. CommandInterface: exists but NOT well-formed: $($_.Exception.Message)"
		}
	} else {
		Report-OK "11. CommandInterface: not present"
	}

	# --- 12. Picture format ---
	$picEl = $props.SelectSingleNode("md:Picture", $ns)
	if ($picEl -and $picEl.HasChildNodes) {
		$picRef = $picEl.SelectSingleNode("xr:Ref", $ns)
		if ($picRef -and $picRef.InnerText) {
			$refText = $picRef.InnerText
			if ($refText -match '^CommonPicture\.') {
				Report-OK "12. Picture: $refText"
			} else {
				Report-Warn "12. Picture: `"$refText`" (expected CommonPicture.XXX)"
			}
		} else {
			Report-Warn "12. Picture: has children but no xr:Ref content"
		}
	} else {
		Report-OK "12. Picture: empty (not set)"
	}

	# --- 13. UseOneCommand constraint ---
	$useOne = $boolVals["UseOneCommand"]
	if ($useOne -eq "true") {
		if ($contentItems.Count -eq 1) {
			Report-OK "13. UseOneCommand: true, Content has exactly 1 item"
		} else {
			Report-Warn "13. UseOneCommand: true but Content has $($contentItems.Count) items (expected 1)"
		}
	} else {
		Report-OK "13. UseOneCommand: false (no constraint)"
	}

	# --- 14. Format version: тела Ext/*.xml — как у дескриптора; сверка с выгрузкой ---
	# Дескриптор подсистемы и её штампованные тела (CommandInterface.xml, Help.xml) платформа загружает
	# только в одной версии формата: «Версия формата загружаемого файла … отличается от версии формата
	# ранее загруженных файлов». Вложенные подсистемы — отдельные объекты. С остальной выгрузкой
	# подсистема может расходиться — платформа такое грузит, это лишь неоднородность выгрузки (типично
	# после мержа веток, выгруженных разными платформами).
	if ($version) {
		$subExtDir = Join-Path (Join-Path $parentDir2 $baseName2) "Ext"
		$verBodiesOk = 0
		$verErrors = 0
		if (Test-Path $subExtDir -PathType Container) {
			$bodyNames = @(Get-ChildItem $subExtDir -Filter "*.xml" -File | ForEach-Object { $_.Name })
			[Array]::Sort($bodyNames, [StringComparer]::Ordinal)
			foreach ($bn in $bodyNames) {
				$bodyVer = Get-RootVersion (Join-Path $subExtDir $bn)
				if (-not $bodyVer) { continue }
				if ($bodyVer -eq $version) { $verBodiesOk++; continue }
				$verErrors++
				Report-Error "14. Format version: $baseName2/Ext/$bn is stamped $bodyVer, the descriptor $version — the platform refuses to load parts of one object in different formats"
			}
		}
		$dumpAnchor = Find-DumpAnchor $parentDir2
		$dumpVer = if ($dumpAnchor) { Get-RootVersion $dumpAnchor } else { $null }
		if ($dumpVer -and $version -ne $dumpVer) {
			Report-Warn "14. Format version $version differs from the dump ($dumpVer) — the platform loads it, but the dump is no longer uniform (typical after merging branches dumped by different platforms)"
		} elseif ($verErrors -eq 0 -and ($verBodiesOk -gt 0 -or $dumpVer)) {
			Report-OK "14. Format version: $version, matches the stamped parts and the dump"
		}
	}
}

# --- Finalize ---
$checks = $script:okCount + $script:errors + $script:warnings

if ($script:errors -eq 0 -and $script:warnings -eq 0 -and -not $Detailed) {
	$result = "=== Validation OK: Subsystem.$subName ($checks checks) ==="
} else {
	Out-Line ""
	Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ($checks checks) ==="
	$result = $script:output.ToString()
}

Write-Host $result

if ($OutFile) {
	if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
		$OutFile = Join-Path (Get-Location).Path $OutFile
	}
	$utf8Bom = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($OutFile, $result, $utf8Bom)
	Write-Host "Written to: $OutFile"
}

if ($script:errors -gt 0) { exit 1 } else { exit 0 }
