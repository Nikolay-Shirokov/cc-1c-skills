# interface-edit v1.2 — Edit 1C CommandInterface.xml
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][string]$CIPath,
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
	version="2.17">
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
