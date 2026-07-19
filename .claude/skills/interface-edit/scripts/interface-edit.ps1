# interface-edit v1.8 — Edit 1C CommandInterface.xml
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][Alias('Path')][string]$CIPath,
	[string]$DefinitionFile,
	[ValidateSet("hide","show","place","order","subsystem-order","group-order")]
	[string]$Operation,
	[string]$Value,
	[switch]$CreateIfMissing,
	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Mode validation ---
if ($DefinitionFile -and $Operation) { Write-Error "Cannot use both -DefinitionFile and -Operation"; exit 1 }
if (-not $DefinitionFile -and -not $Operation) { Write-Error "Either -DefinitionFile or -Operation is required"; exit 1 }

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($CIPath)) {
	$CIPath = Join-Path (Get-Location).Path $CIPath
}
$resolvedPath = $CIPath

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow. Walk-up from Subsystems/X/Ext/
# CommandInterface.xml reaches Subsystems/X.xml (owning subsystem uuid).
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

Assert-EditAllowed $CIPath 'editable'

# --- Detect format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$head = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8).Substring(0, [Math]::Min(2000, (Get-Item $cfgPath).Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

$formatVersion = Detect-FormatVersion ([System.IO.Path]::GetDirectoryName($CIPath))

# --- Namespaces ---
$script:ciNs = "http://v8.1c.ru/8.3/xcf/extrnprops"
$script:xrNs = "http://v8.1c.ru/8.3/xcf/readable"
$script:xsiNs = "http://www.w3.org/2001/XMLSchema-instance"
$script:xsNs = "http://www.w3.org/2001/XMLSchema"

# --- Create if missing ---
if (-not (Test-Path $CIPath)) {
	if ($CreateIfMissing) {
		$parentDir = [System.IO.Path]::GetDirectoryName($CIPath)
		if (-not (Test-Path $parentDir)) {
			New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
		}
		$emptyCI = @"
<?xml version="1.0" encoding="UTF-8"?>
<CommandInterface xmlns="$($script:ciNs)"
	xmlns:xr="$($script:xrNs)"
	xmlns:xs="$($script:xsNs)"
	xmlns:xsi="$($script:xsiNs)"
	version="$formatVersion">
</CommandInterface>
"@
		$utf8Bom = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($CIPath, $emptyCI, $utf8Bom)
		Write-Host "[INFO] Created new CommandInterface.xml: $CIPath"
	} else {
		Write-Error "File not found: $CIPath (use -CreateIfMissing to create)"
		exit 1
	}
}
$resolvedPath = (Resolve-Path $CIPath).Path

# --- Load XML ---
$script:xmlDoc = New-Object System.Xml.XmlDocument
$script:xmlDoc.PreserveWhitespace = $true
$script:xmlDoc.Load($resolvedPath)

$script:addCount = 0
$script:removeCount = 0
$script:modifyCount = 0

function Info([string]$msg) { Write-Host "[INFO] $msg" }
function Warn([string]$msg) { Write-Host "[WARN] $msg" }

# --- Detect structure ---
$root = $script:xmlDoc.DocumentElement
if ($root.LocalName -ne "CommandInterface") {
	Write-Error "Expected <CommandInterface> root element, got <$($root.LocalName)>"
	exit 1
}

# Section canonical order
$script:sectionOrder = @("CommandsVisibility","CommandsPlacement","CommandsOrder","SubsystemsOrder","GroupsOrder")

# --- XML manipulation helpers ---
function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			if ($child.Value -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($child.Value -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	$depth = 0; $current = $container
	while ($current -and $current -ne $script:xmlDoc.DocumentElement) { $depth++; $current = $current.ParentNode }
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	$ws = $script:xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $ws) | Out-Null
	} else {
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$container.InsertBefore($ws, $trailing) | Out-Null
			$container.InsertBefore($newNode, $trailing) | Out-Null
		} else {
			$container.AppendChild($ws) | Out-Null
			$container.AppendChild($newNode) | Out-Null
			$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
			$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Remove-NodeWithWhitespace($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	$next = $node.NextSibling
	if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($prev) | Out-Null
	} elseif ($next -and ($next.NodeType -eq 'Whitespace' -or $next.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($next) | Out-Null
	}
	$parent.RemoveChild($node) | Out-Null
}

function Import-CIFragment([string]$xmlString) {
	$wrapper = "<_W xmlns=`"$($script:ciNs)`" xmlns:xr=`"$($script:xrNs)`" xmlns:xsi=`"$($script:xsiNs)`" xmlns:xs=`"$($script:xsNs)`">$xmlString</_W>"
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$nodes = @()
	foreach ($child in $frag.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $script:xmlDoc.ImportNode($child, $true)
		}
	}
	return ,$nodes
}

# --- Ensure section exists, creating it in correct order if needed ---
function Ensure-Section([string]$sectionName) {
	# Find existing
	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $sectionName) {
			return $child
		}
	}

	# Create new section
	$newSection = $script:xmlDoc.CreateElement($sectionName, $script:ciNs)

	# Find the correct insertion point: before the first section that comes AFTER us in canonical order
	$myIdx = [array]::IndexOf($script:sectionOrder, $sectionName)
	$refNode = $null
	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childIdx = [array]::IndexOf($script:sectionOrder, $child.LocalName)
		if ($childIdx -gt $myIdx) {
			# Find the whitespace before this element to insert before it
			$prev = $child.PreviousSibling
			if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
				$refNode = $prev
			} else {
				$refNode = $child
			}
			break
		}
	}

	$rootIndent = Get-ChildIndent $root
	# Add closing whitespace inside the new section
	$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$rootIndent")
	$newSection.AppendChild($closeWs) | Out-Null

	if ($refNode) {
		$ws = $script:xmlDoc.CreateWhitespace("`r`n$rootIndent")
		$root.InsertBefore($ws, $refNode) | Out-Null
		$root.InsertBefore($newSection, $ws) | Out-Null
	} else {
		Insert-BeforeElement $root $newSection $null $rootIndent
	}
	return $newSection
}

# --- Parse value: string or JSON array ---
function Parse-ValueList([string]$val) {
	$val = $val.Trim()
	if ($val.StartsWith("[")) {
		$arr = $val | ConvertFrom-Json
		$result = @(); foreach ($item in $arr) { $result += "$item" }
		return ,$result
	}
	return @($val)
}

# --- Find Command element by name in a section ---
function Find-CommandByName($section, [string]$cmdName) {
	foreach ($child in $section.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Command") {
			if ($child.GetAttribute("name") -eq $cmdName) { return $child }
		}
	}
	return $null
}

# --- Command name normalization (plural/Russian type prefix → singular English) ---
$script:typeNormMap = @{
	"Catalogs"="Catalog"; "Documents"="Document"; "Enums"="Enum"; "Constants"="Constant"
	"Reports"="Report"; "DataProcessors"="DataProcessor"
	"InformationRegisters"="InformationRegister"; "AccumulationRegisters"="AccumulationRegister"
	"AccountingRegisters"="AccountingRegister"; "CalculationRegisters"="CalculationRegister"
	"ChartsOfAccounts"="ChartOfAccounts"; "ChartsOfCharacteristicTypes"="ChartOfCharacteristicTypes"
	"ChartsOfCalculationTypes"="ChartOfCalculationTypes"
	"BusinessProcesses"="BusinessProcess"; "Tasks"="Task"
	"ExchangePlans"="ExchangePlan"; "DocumentJournals"="DocumentJournal"
	"CommonModules"="CommonModule"; "CommonCommands"="CommonCommand"
	"CommonForms"="CommonForm"; "CommonPictures"="CommonPicture"
	"CommonTemplates"="CommonTemplate"; "CommonAttributes"="CommonAttribute"
	"CommandGroups"="CommandGroup"; "Roles"="Role"
	"Subsystems"="Subsystem"; "StyleItems"="StyleItem"
	# Russian singular
	"Справочник"="Catalog"; "Документ"="Document"; "Перечисление"="Enum"
	"Константа"="Constant"; "Отчёт"="Report"; "Отчет"="Report"; "Обработка"="DataProcessor"
	"РегистрСведений"="InformationRegister"; "РегистрНакопления"="AccumulationRegister"
	"РегистрБухгалтерии"="AccountingRegister"
	"ПланСчетов"="ChartOfAccounts"; "ПланВидовХарактеристик"="ChartOfCharacteristicTypes"
	"БизнесПроцесс"="BusinessProcess"; "Задача"="Task"
	"ПланОбмена"="ExchangePlan"; "ЖурналДокументов"="DocumentJournal"
	"ОбщийМодуль"="CommonModule"; "ОбщаяКоманда"="CommonCommand"
	"ОбщаяФорма"="CommonForm"; "Подсистема"="Subsystem"
	# Russian plural
	"Справочники"="Catalog"; "Документы"="Document"; "Перечисления"="Enum"
	"Константы"="Constant"; "Отчёты"="Report"; "Отчеты"="Report"; "Обработки"="DataProcessor"
	"РегистрыСведений"="InformationRegister"; "РегистрыНакопления"="AccumulationRegister"
	"РегистрыБухгалтерии"="AccountingRegister"
	"ПланыСчетов"="ChartOfAccounts"; "ПланыВидовХарактеристик"="ChartOfCharacteristicTypes"
	"БизнесПроцессы"="BusinessProcess"; "Задачи"="Task"
	"ПланыОбмена"="ExchangePlan"; "ЖурналыДокументов"="DocumentJournal"
	"Подсистемы"="Subsystem"
}

function Normalize-CmdName([string]$name) {
	if (-not $name -or -not $name.Contains('.')) { return $name }
	$dotIdx = $name.IndexOf('.')
	$first = $name.Substring(0, $dotIdx)
	$rest = $name.Substring($dotIdx)
	if ($script:typeNormMap.ContainsKey($first)) {
		$normalized = "$($script:typeNormMap[$first])$rest"
		if ($normalized -ne $name) { Write-Host "[NORM] Command: $name -> $normalized" }
		return $normalized
	}
	return $name
}

# --- Operations ---

function Do-Hide([string[]]$commands) {
	$commands = @($commands | ForEach-Object { Normalize-CmdName $_ })
	$section = Ensure-Section "CommandsVisibility"
	$sectionIndent = Get-ChildIndent $section

	foreach ($cmd in $commands) {
		$existing = Find-CommandByName $section $cmd
		if ($existing) {
			# Check if already false
			$commonEl = $null
			foreach ($vis in $existing.ChildNodes) {
				if ($vis.NodeType -eq 'Element' -and $vis.LocalName -eq "Visibility") {
					foreach ($c in $vis.ChildNodes) {
						if ($c.NodeType -eq 'Element' -and $c.LocalName -eq "Common") { $commonEl = $c; break }
					}
				}
			}
			if ($commonEl -and $commonEl.InnerText.Trim() -eq "false") {
				Warn "Already hidden: $cmd"
				continue
			}
			# Change true -> false
			if ($commonEl) {
				$commonEl.InnerText = "false"
				$script:modifyCount++
				Info "Changed to hidden: $cmd"
				continue
			}
		}
		# Add new entry
		$fragXml = "<Command name=`"$cmd`"><Visibility><xr:Common>false</xr:Common></Visibility></Command>"
		$nodes = Import-CIFragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $section $nodes[0] $null $sectionIndent
			$script:addCount++
			Info "Hidden: $cmd"
		}
	}
}

function Do-Show([string[]]$commands) {
	$commands = @($commands | ForEach-Object { Normalize-CmdName $_ })
	$section = $null
	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "CommandsVisibility") {
			$section = $child; break
		}
	}

	foreach ($cmd in $commands) {
		if (-not $section) {
			# No CommandsVisibility section — showing means adding with true
			$section = Ensure-Section "CommandsVisibility"
		}
		$existing = Find-CommandByName $section $cmd
		if ($existing) {
			$commonEl = $null
			foreach ($vis in $existing.ChildNodes) {
				if ($vis.NodeType -eq 'Element' -and $vis.LocalName -eq "Visibility") {
					foreach ($c in $vis.ChildNodes) {
						if ($c.NodeType -eq 'Element' -and $c.LocalName -eq "Common") { $commonEl = $c; break }
					}
				}
			}
			if ($commonEl -and $commonEl.InnerText.Trim() -eq "true") {
				Warn "Already shown: $cmd"
				continue
			}
			if ($commonEl -and $commonEl.InnerText.Trim() -eq "false") {
				# Change false -> true
				$commonEl.InnerText = "true"
				$script:modifyCount++
				Info "Changed to shown: $cmd"
				continue
			}
		}
		# Add new entry with true
		$sectionIndent = Get-ChildIndent $section
		$fragXml = "<Command name=`"$cmd`"><Visibility><xr:Common>true</xr:Common></Visibility></Command>"
		$nodes = Import-CIFragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $section $nodes[0] $null $sectionIndent
			$script:addCount++
			Info "Shown: $cmd"
		}
	}
}

function Do-Place([string]$jsonVal) {
	$def = $jsonVal | ConvertFrom-Json
	$cmdName = Normalize-CmdName "$($def.command)"
	$groupName = "$($def.group)"
	if (-not $cmdName -or -not $groupName) { Write-Error "place requires {command, group}"; exit 1 }

	$section = Ensure-Section "CommandsPlacement"
	$sectionIndent = Get-ChildIndent $section

	# Check existing
	$existing = Find-CommandByName $section $cmdName
	if ($existing) {
		# Update group
		foreach ($child in $existing.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "CommandGroup") {
				$child.InnerText = $groupName
				$script:modifyCount++
				Info "Updated placement: $cmdName -> $groupName"
				return
			}
		}
	}

	# Add new
	$fragXml = "<Command name=`"$cmdName`"><CommandGroup>$groupName</CommandGroup><Placement>Auto</Placement></Command>"
	$nodes = Import-CIFragment $fragXml
	if ($nodes.Count -gt 0) {
		Insert-BeforeElement $section $nodes[0] $null $sectionIndent
		$script:addCount++
		Info "Placed: $cmdName -> $groupName"
	}
}

function Do-Order([string]$jsonVal) {
	$def = $jsonVal | ConvertFrom-Json
	$groupName = "$($def.group)"
	$commands = @($def.commands | ForEach-Object { Normalize-CmdName "$_" })
	if (-not $groupName -or $commands.Count -eq 0) { Write-Error "order requires {group, commands:[...]}"; exit 1 }

	$section = Ensure-Section "CommandsOrder"
	$sectionIndent = Get-ChildIndent $section

	# Remove existing entries for this group
	$toRemove = @()
	foreach ($child in $section.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -ne "Command") { continue }
		foreach ($gc in $child.ChildNodes) {
			if ($gc.NodeType -eq 'Element' -and $gc.LocalName -eq "CommandGroup" -and $gc.InnerText.Trim() -eq $groupName) {
				$toRemove += $child
				break
			}
		}
	}
	foreach ($node in $toRemove) {
		Remove-NodeWithWhitespace $node
		$script:removeCount++
	}

	# Add new entries in order
	foreach ($cmdName in $commands) {
		$fragXml = "<Command name=`"$cmdName`"><CommandGroup>$groupName</CommandGroup></Command>"
		$nodes = Import-CIFragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $section $nodes[0] $null $sectionIndent
			$script:addCount++
		}
	}
	Info "Set order for $groupName : $($commands.Count) commands"
}

function Do-SubsystemOrder([string]$jsonVal) {
	$parsed = $jsonVal | ConvertFrom-Json
	$subsystems = @(); foreach ($s in $parsed) { $subsystems += "$s" }
	if ($subsystems.Count -eq 0) { Write-Error "subsystem-order requires array of subsystem paths"; exit 1 }

	$section = Ensure-Section "SubsystemsOrder"
	$sectionIndent = Get-ChildIndent $section

	# Clear existing
	$toRemove = @()
	foreach ($child in @($section.ChildNodes)) {
		if ($child.NodeType -eq 'Element') { $toRemove += $child }
	}
	foreach ($node in $toRemove) {
		Remove-NodeWithWhitespace $node
		$script:removeCount++
	}

	# Add new entries
	foreach ($sub in $subsystems) {
		$newEl = $script:xmlDoc.CreateElement("Subsystem", $script:ciNs)
		$newEl.InnerText = $sub
		Insert-BeforeElement $section $newEl $null $sectionIndent
		$script:addCount++
	}
	Info "Set subsystem order: $($subsystems.Count) entries"
}

function Do-GroupOrder([string]$jsonVal) {
	$parsed = $jsonVal | ConvertFrom-Json
	$groups = @(); foreach ($g in $parsed) { $groups += "$g" }
	if ($groups.Count -eq 0) { Write-Error "group-order requires array of group names"; exit 1 }

	$section = Ensure-Section "GroupsOrder"
	$sectionIndent = Get-ChildIndent $section

	# Clear existing
	$toRemove = @()
	foreach ($child in @($section.ChildNodes)) {
		if ($child.NodeType -eq 'Element') { $toRemove += $child }
	}
	foreach ($node in $toRemove) {
		Remove-NodeWithWhitespace $node
		$script:removeCount++
	}

	# Add new entries
	foreach ($grp in $groups) {
		$newEl = $script:xmlDoc.CreateElement("Group", $script:ciNs)
		$newEl.InnerText = $grp
		Insert-BeforeElement $section $newEl $null $sectionIndent
		$script:addCount++
	}
	Info "Set group order: $($groups.Count) entries"
}

# --- Execute operations ---
$operations = @()
if ($DefinitionFile) {
	if (-not [System.IO.Path]::IsPathRooted($DefinitionFile)) {
		$DefinitionFile = Join-Path (Get-Location).Path $DefinitionFile
	}
	$jsonText = Get-Content -Raw -Encoding UTF8 $DefinitionFile
	$ops = $jsonText | ConvertFrom-Json
	if ($ops -is [System.Array]) {
		foreach ($op in $ops) { $operations += $op }
	} else {
		$operations += $ops
	}
} else {
	$operations += @{ operation = $Operation; value = $Value }
}

foreach ($op in $operations) {
	$opName = if ($op.operation) { "$($op.operation)" } else { "$Operation" }
	$opValueRaw = if ($op.value) { $op.value } else { "$Value" }
	# For operations expecting JSON (place, order, etc.): accept object or string
	$opValue = if ($opValueRaw -is [string]) { $opValueRaw } else { $opValueRaw | ConvertTo-Json -Compress }

	switch ($opName) {
		"hide"            { Do-Hide (Parse-ValueList $opValue) }
		"show"            { Do-Show (Parse-ValueList $opValue) }
		"place"           { Do-Place $opValue }
		"order"           { Do-Order $opValue }
		"subsystem-order" { Do-SubsystemOrder $opValue }
		"group-order"     { Do-GroupOrder $opValue }
		default           { Write-Error "Unknown operation: $opName"; exit 1 }
	}
}

# --- Save ---
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
$settings.Indent = $false
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$script:xmlDoc.Save($writer)
$writer.Flush(); $writer.Close()

$bytes = $memStream.ToArray()
$memStream.Close()
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
$text = $text.Replace('encoding="utf-8"', 'encoding="UTF-8"')

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedPath, $text, $utf8Bom)
Info "Saved: $resolvedPath"

# --- Auto-validate ---
if (-not $NoValidate) {
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\interface-validate") "scripts\interface-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running interface-validate ---"
		& powershell.exe -NoProfile -File $validateScript -CIPath $resolvedPath
	}
}

# --- Summary ---
Write-Host ""
Write-Host "=== interface-edit summary ==="
Write-Host "  Added:    $($script:addCount)"
Write-Host "  Removed:  $($script:removeCount)"
Write-Host "  Modified: $($script:modifyCount)"
exit 0
