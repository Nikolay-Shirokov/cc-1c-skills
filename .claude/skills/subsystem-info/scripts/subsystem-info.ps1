# subsystem-info v1.0 — Compact summary of 1C subsystem structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)][string]$SubsystemPath,
	[ValidateSet("overview","content","ci","tree","full")]
	[string]$Mode = "overview",
	[string]$Name,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Output helper ---
$script:lines = @()
function Out([string]$text) { $script:lines += $text }

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($SubsystemPath)) {
	$SubsystemPath = Join-Path (Get-Location).Path $SubsystemPath
}

# --- Helper: get LocalString text ---
function Get-MLText($node) {
	if (-not $node -or -not $node.HasChildNodes) { return "" }
	foreach ($item in $node.ChildNodes) {
		if ($item.NodeType -ne 'Element') { continue }
		$lang = ""; $content = ""
		foreach ($c in $item.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ($c.LocalName -eq "lang") { $lang = $c.InnerText }
			if ($c.LocalName -eq "content") { $content = $c.InnerText }
		}
		if ($lang -eq "ru" -and $content) { return $content }
	}
	# fallback: first item
	foreach ($item in $node.ChildNodes) {
		if ($item.NodeType -ne 'Element') { continue }
		foreach ($c in $item.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ($c.LocalName -eq "content" -and $c.InnerText) { return $c.InnerText }
		}
	}
	return ""
}

# --- Helper: load subsystem XML ---
function Load-SubsystemXml([string]$xmlPath) {
	[xml]$doc = Get-Content -Path $xmlPath -Encoding UTF8
	$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
	$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
	$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
	$sub = $doc.SelectSingleNode("/md:MetaDataObject/md:Subsystem", $ns)
	if (-not $sub) {
		Write-Host "[ERROR] Not a valid subsystem XML: $xmlPath"
		exit 1
	}
	return @{ Doc=$doc; Ns=$ns; Sub=$sub }
}

# --- Helper: get content items ---
function Get-ContentItems($props, $ns) {
	$items = @()
	$contentNode = $props.SelectSingleNode("md:Content", $ns)
	if (-not $contentNode -or -not $contentNode.HasChildNodes) { return $items }
	foreach ($item in $contentNode.SelectNodes("xr:Item", $ns)) {
		$items += $item.InnerText
	}
	return $items
}

# --- Helper: get child subsystem names ---
function Get-ChildNames($sub, $ns) {
	$names = @()
	$co = $sub.SelectSingleNode("md:ChildObjects", $ns)
	if (-not $co -or -not $co.HasChildNodes) { return $names }
	foreach ($child in $co.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Subsystem") {
			$names += $child.InnerText
		}
	}
	return $names
}

# --- Helper: group content by type ---
function Group-ContentByType($items) {
	$groups = [ordered]@{}
	foreach ($item in $items) {
		if ($item -match '^([^.]+)\.(.+)$') {
			$type = $Matches[1]
			$name = $Matches[2]
		} elseif ($item -match '^[0-9a-fA-F]{8}-') {
			$type = "[UUID]"
			$name = $item
		} else {
			$type = "[Other]"
			$name = $item
		}
		if (-not $groups.Contains($type)) { $groups[$type] = @() }
		$groups[$type] += $name
	}
	return $groups
}

# --- Helper: find subsystem dir from XML path ---
function Get-SubsystemDir([string]$xmlPath) {
	$dir = [System.IO.Path]::GetDirectoryName($xmlPath)
	$baseName = [System.IO.Path]::GetFileNameWithoutExtension($xmlPath)
	return Join-Path $dir $baseName
}

# --- Show functions for full mode ---
function Show-Overview {
	Out "Подсистема: $subName"
	if ($synonym -and $synonym -ne $subName) { Out "Синоним: $synonym" }
	if ($commentText) { Out "Комментарий: $commentText" }
	Out "ВключатьВКомандныйИнтерфейс: $inclCI"
	Out "ИспользоватьОднуКоманду: $useOneCmd"
	if ($explanation) { Out "Пояснение: $explanation" }
	if ($picText) { Out "Картинка: $picText" }
	if ($contentItems.Count -gt 0) {
		$parts = @()
		foreach ($type in $groups.Keys) {
			$parts += "$type`: $($groups[$type].Count)"
		}
		Out "Состав: $($contentItems.Count) объектов ($($parts -join ', '))"
	} else {
		Out "Состав: пусто"
	}
	if ($childNames.Count -gt 0) {
		Out "Дочерние подсистемы ($($childNames.Count)): $($childNames -join ', ')"
	}
	if ($hasCI) {
		Out "Командный интерфейс: есть"
	}
}

function Show-Content {
	Out "Состав подсистемы $subName ($($contentItems.Count) объектов):"
	Out ""
	if ($Name) {
		if ($groups.Contains($Name)) {
			$filtered = $groups[$Name]
			Out "$Name ($($filtered.Count)):"
			foreach ($n in $filtered) { Out "  $n" }
		} else {
			Out "[INFO] Тип '$Name' не найден в составе."
			Out "Доступные типы: $($groups.Keys -join ', ')"
		}
	} else {
		foreach ($type in $groups.Keys) {
			Out "$type ($($groups[$type].Count)):"
			foreach ($n in $groups[$type]) { Out "  $n" }
			Out ""
		}
	}
}

function Show-CI {
	$localSubDir = Get-SubsystemDir $SubsystemPath
	$localCiPath = Join-Path (Join-Path $localSubDir "Ext") "CommandInterface.xml"

	if (-not (Test-Path $localCiPath)) {
		Out "Командный интерфейс: $subName"
		Out ""
		Out "Файл CommandInterface.xml не найден."
		Out "Путь: $localCiPath"
	} else {
		[xml]$ciDoc = Get-Content -Path $localCiPath -Encoding UTF8
		$ciNs = New-Object System.Xml.XmlNamespaceManager($ciDoc.NameTable)
		$ciNs.AddNamespace("ci", "http://v8.1c.ru/8.3/xcf/extrnprops")
		$ciNs.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")

		$ciRoot = $ciDoc.DocumentElement

		Out "Командный интерфейс: $subName"
		Out ""

		# --- CommandsVisibility ---
		$visSection = $ciRoot.SelectSingleNode("ci:CommandsVisibility", $ciNs)
		if ($visSection) {
			$hidden = @(); $shown = @()
			foreach ($cmd in $visSection.SelectNodes("ci:Command", $ciNs)) {
				$cmdName = $cmd.GetAttribute("name")
				$vis = $cmd.SelectSingleNode("ci:Visibility/xr:Common", $ciNs)
				if ($vis -and $vis.InnerText -eq "false") { $hidden += $cmdName }
				else { $shown += $cmdName }
			}
			$total = $hidden.Count + $shown.Count
			if (-not $Name -or $Name -eq "visibility") {
				Out "Видимость ($total):"
				if ($hidden.Count -gt 0) {
					Out "  СКРЫТО ($($hidden.Count)):"
					foreach ($h in $hidden) { Out "    $h" }
				}
				if ($shown.Count -gt 0) {
					Out "  ПОКАЗАНО ($($shown.Count)):"
					foreach ($s in $shown) { Out "    $s" }
				}
				Out ""
			}
		}

		# --- CommandsPlacement ---
		$placeSection = $ciRoot.SelectSingleNode("ci:CommandsPlacement", $ciNs)
		if ($placeSection) {
			$placements = @()
			foreach ($cmd in $placeSection.SelectNodes("ci:Command", $ciNs)) {
				$cmdName = $cmd.GetAttribute("name")
				$grp = $cmd.SelectSingleNode("ci:CommandGroup", $ciNs)
				$pl = $cmd.SelectSingleNode("ci:Placement", $ciNs)
				$grpText = if ($grp) { $grp.InnerText } else { "?" }
				$plText = if ($pl) { $pl.InnerText } else { "?" }
				$placements += @{ Name=$cmdName; Group=$grpText; Placement=$plText }
			}
			if ((-not $Name -or $Name -eq "placement") -and $placements.Count -gt 0) {
				Out "Размещение ($($placements.Count)):"
				$arrow = [char]0x2192
				foreach ($p in $placements) {
					Out "  $($p.Name) $arrow $($p.Group) ($($p.Placement))"
				}
				Out ""
			}
		}

		# --- CommandsOrder ---
		$orderSection = $ciRoot.SelectSingleNode("ci:CommandsOrder", $ciNs)
		if ($orderSection) {
			$orderGroups = [ordered]@{}
			foreach ($cmd in $orderSection.SelectNodes("ci:Command", $ciNs)) {
				$cmdName = $cmd.GetAttribute("name")
				$grp = $cmd.SelectSingleNode("ci:CommandGroup", $ciNs)
				$grpText = if ($grp) { $grp.InnerText } else { "?" }
				if (-not $orderGroups.Contains($grpText)) { $orderGroups[$grpText] = @() }
				$orderGroups[$grpText] += $cmdName
			}
			$totalOrder = 0
			foreach ($k in $orderGroups.Keys) { $totalOrder += $orderGroups[$k].Count }
			if ((-not $Name -or $Name -eq "order") -and $totalOrder -gt 0) {
				Out "Порядок команд ($totalOrder):"
				foreach ($grpName in $orderGroups.Keys) {
					Out "  [$grpName]:"
					foreach ($c in $orderGroups[$grpName]) { Out "    $c" }
				}
				Out ""
			}
		}

		# --- SubsystemsOrder ---
		$subOrderSection = $ciRoot.SelectSingleNode("ci:SubsystemsOrder", $ciNs)
		if ($subOrderSection) {
			$subOrder = @()
			foreach ($s in $subOrderSection.SelectNodes("ci:Subsystem", $ciNs)) {
				$subOrder += $s.InnerText
			}
			if ((-not $Name -or $Name -eq "subsystems") -and $subOrder.Count -gt 0) {
				Out "Порядок подсистем ($($subOrder.Count)):"
				for ($i = 0; $i -lt $subOrder.Count; $i++) {
					Out "  $($i+1). $($subOrder[$i])"
				}
				Out ""
			}
		}

		# --- GroupsOrder ---
		$grpOrderSection = $ciRoot.SelectSingleNode("ci:GroupsOrder", $ciNs)
		if ($grpOrderSection) {
			$grpOrder = @()
			foreach ($g in $grpOrderSection.SelectNodes("ci:Group", $ciNs)) {
				$grpOrder += $g.InnerText
			}
			if ((-not $Name -or $Name -eq "groups") -and $grpOrder.Count -gt 0) {
				Out "Порядок групп ($($grpOrder.Count)):"
				foreach ($g in $grpOrder) { Out "  $g" }
			}
		}
	}
}

# ============================================================
# Mode: tree
# ============================================================
if ($Mode -eq "tree") {
	$isDir = Test-Path $SubsystemPath -PathType Container
	$rootDir = $null
	$rootXml = $null

	if ($isDir) {
		# Subsystems/ directory — show all top-level subsystems
		$rootDir = $SubsystemPath
	} else {
		# Specific subsystem XML — show tree from this subsystem
		if (-not (Test-Path $SubsystemPath)) {
			Write-Host "[ERROR] File not found: $SubsystemPath"
			exit 1
		}
		$rootXml = $SubsystemPath
	}

	# Box-drawing chars (PS 5.1 compatible)
	$script:T_BRANCH = [char]0x251C + [char]0x2500 + [char]0x2500 + " "  # ├──
	$script:T_LAST   = [char]0x2514 + [char]0x2500 + [char]0x2500 + " "  # └──
	$script:T_PIPE   = [char]0x2502 + "   "                               # │
	$script:T_ARROW  = [char]0x2192                                        # →

	function Get-TreeLine([string]$xmlPath) {
		$parsed = Load-SubsystemXml $xmlPath
		$sub = $parsed.Sub; $ns = $parsed.Ns
		$props = $sub.SelectSingleNode("md:Properties", $ns)
		$name = $props.SelectSingleNode("md:Name", $ns).InnerText

		$markers = @()
		$subDir = Get-SubsystemDir $xmlPath
		$ciPath = Join-Path (Join-Path $subDir "Ext") "CommandInterface.xml"
		if (Test-Path $ciPath) { $markers += "CI" }
		$useOne = $props.SelectSingleNode("md:UseOneCommand", $ns)
		if ($useOne -and $useOne.InnerText -eq "true") { $markers += "OneCmd" }
		$inclCI = $props.SelectSingleNode("md:IncludeInCommandInterface", $ns)
		if ($inclCI -and $inclCI.InnerText -eq "false") { $markers += "Скрыт" }
		$markerStr = if ($markers.Count -gt 0) { " [$($markers -join ', ')]" } else { "" }

		$contentItems = @(Get-ContentItems $props $ns)
		$childNames = @(Get-ChildNames $sub $ns)
		$childStr = if ($childNames.Count -gt 0) { ", $($childNames.Count) дочерних" } else { "" }

		return @{
			Label = "$name$markerStr ($($contentItems.Count) объектов$childStr)"
			SubDir = $subDir
			ChildNames = $childNames
		}
	}

	function Build-TreeEntry([string]$xmlPath, [string]$prefix, [bool]$isLast, [bool]$isRoot) {
		$info = Get-TreeLine $xmlPath

		$connector = if ($isRoot) { "" } elseif ($isLast) { $script:T_LAST } else { $script:T_BRANCH }
		Out "$prefix$connector$($info.Label)"

		if ($info.ChildNames.Count -gt 0) {
			$childPrefix = if ($isRoot) { "" } elseif ($isLast) { "$prefix    " } else { "$prefix$($script:T_PIPE)" }
			$subsDir = Join-Path $info.SubDir "Subsystems"
			for ($i = 0; $i -lt $info.ChildNames.Count; $i++) {
				$childXml = Join-Path $subsDir "$($info.ChildNames[$i]).xml"
				$childIsLast = ($i -eq $info.ChildNames.Count - 1)
				if (Test-Path $childXml) {
					Build-TreeEntry $childXml $childPrefix $childIsLast $false
				} else {
					$conn2 = if ($childIsLast) { $script:T_LAST } else { $script:T_BRANCH }
					Out "$childPrefix$conn2$($info.ChildNames[$i]) [NOT FOUND]"
				}
			}
		}
	}

	if ($rootDir) {
		$label = Split-Path $rootDir -Leaf
		Out "Дерево подсистем от: $label/"
		Out ""
		$xmlFiles = @(Get-ChildItem $rootDir -Filter "*.xml" -File | Sort-Object Name)
		if ($Name) {
			$xmlFiles = @($xmlFiles | Where-Object { $_.BaseName -eq $Name })
			if ($xmlFiles.Count -eq 0) {
				Write-Host "[ERROR] Subsystem '$Name' not found in $rootDir"
				exit 1
			}
		}
		for ($i = 0; $i -lt $xmlFiles.Count; $i++) {
			Build-TreeEntry $xmlFiles[$i].FullName "" ($i -eq $xmlFiles.Count - 1) $true
		}
	} else {
		Build-TreeEntry $rootXml "" $true $true
	}

} elseif ($Mode -eq "ci") {
# ============================================================
# Mode: ci — CommandInterface.xml
# ============================================================
	if (Test-Path $SubsystemPath -PathType Container) {
		Write-Host "[ERROR] ci mode requires a subsystem .xml file, not a directory"
		exit 1
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

	$parsed = Load-SubsystemXml $SubsystemPath
	$sub = $parsed.Sub; $ns = $parsed.Ns
	$props = $sub.SelectSingleNode("md:Properties", $ns)
	$subName = $props.SelectSingleNode("md:Name", $ns).InnerText

	Show-CI

} else {
# ============================================================
# Mode: overview / content — requires a subsystem XML file
# ============================================================
	if (Test-Path $SubsystemPath -PathType Container) {
		$dirName = Split-Path $SubsystemPath -Leaf
		$candidate = Join-Path $SubsystemPath "$dirName.xml"
		$sibling = Join-Path (Split-Path $SubsystemPath) "$dirName.xml"
		if (Test-Path $candidate) {
			$SubsystemPath = $candidate
		} elseif (Test-Path $sibling) {
			$SubsystemPath = $sibling
		} else {
			Write-Host "[ERROR] No $dirName.xml found in directory. Use -Mode tree for directory listing."
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

	$parsed = Load-SubsystemXml $SubsystemPath
	$sub = $parsed.Sub; $ns = $parsed.Ns
	$props = $sub.SelectSingleNode("md:Properties", $ns)

	$subName = $props.SelectSingleNode("md:Name", $ns).InnerText
	$synonym = Get-MLText $props.SelectSingleNode("md:Synonym", $ns)
	$comment = $props.SelectSingleNode("md:Comment", $ns)
	$commentText = if ($comment -and $comment.InnerText) { $comment.InnerText } else { "" }
	$inclHelp = $props.SelectSingleNode("md:IncludeHelpInContents", $ns).InnerText
	$inclCI = $props.SelectSingleNode("md:IncludeInCommandInterface", $ns).InnerText
	$useOneCmd = $props.SelectSingleNode("md:UseOneCommand", $ns).InnerText
	$explanation = Get-MLText $props.SelectSingleNode("md:Explanation", $ns)

	# Picture
	$picNode = $props.SelectSingleNode("md:Picture", $ns)
	$picText = ""
	if ($picNode -and $picNode.HasChildNodes) {
		$picRef = $picNode.SelectSingleNode("xr:Ref", $ns)
		if ($picRef -and $picRef.InnerText) { $picText = $picRef.InnerText }
	}

	# Content
	$contentItems = @(Get-ContentItems $props $ns)
	$groups = Group-ContentByType $contentItems

	# Children
	$childNames = @(Get-ChildNames $sub $ns)

	# CI presence
	$subDir = Get-SubsystemDir $SubsystemPath
	$ciPath = Join-Path (Join-Path $subDir "Ext") "CommandInterface.xml"
	$hasCI = Test-Path $ciPath

	if ($Mode -eq "overview") {
		Show-Overview
	} elseif ($Mode -eq "content") {
		Show-Content
	} elseif ($Mode -eq "full") {
		Show-Overview
		Out ""; Out "--- content ---"; Out ""
		Show-Content
		Out ""; Out "--- ci ---"; Out ""
		Show-CI
	}
}

# --- Pagination and output ---
$totalLines = $script:lines.Count
$outLines = $script:lines

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$outLines = $outLines[$Offset..($totalLines - 1)]
}

if ($Limit -gt 0 -and $outLines.Count -gt $Limit) {
	$shown = $outLines[0..($Limit - 1)]
	$remaining = $totalLines - $Offset - $Limit
	$shown += ""
	$shown += "[ОБРЕЗАНО] Показано $Limit из $totalLines строк. Используйте -Offset $($Offset + $Limit) для продолжения."
	$outLines = $shown
}

if ($OutFile) {
	if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
		$OutFile = Join-Path (Get-Location).Path $OutFile
	}
	$utf8 = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllLines($OutFile, $outLines, $utf8)
	Write-Host "Output written to $OutFile"
} else {
	foreach ($l in $outLines) { Write-Host $l }
}
