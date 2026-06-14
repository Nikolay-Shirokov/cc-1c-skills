# interface-validate v1.1 — Validate 1C CommandInterface.xml structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][Alias('Path')][string]$CIPath,
	[switch]$Detailed,
	[int]$MaxErrors = 30,
	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($CIPath)) {
	$CIPath = Join-Path (Get-Location).Path $CIPath
}
# A: Directory → Ext/CommandInterface.xml
if (Test-Path $CIPath -PathType Container) {
	$CIPath = Join-Path (Join-Path $CIPath "Ext") "CommandInterface.xml"
}
# B1: Missing Ext/ (e.g. Subsystems/X/CommandInterface.xml → Subsystems/X/Ext/CommandInterface.xml)
if (-not (Test-Path $CIPath)) {
	$fn = [System.IO.Path]::GetFileName($CIPath)
	if ($fn -eq "CommandInterface.xml") {
		$c = Join-Path (Join-Path (Split-Path $CIPath) "Ext") $fn
		if (Test-Path $c) { $CIPath = $c }
	}
}
if (-not (Test-Path $CIPath)) {
	Write-Host "[ERROR] File not found: $CIPath"
	exit 1
}
$resolvedPath = (Resolve-Path $CIPath).Path

# --- Derive context name from path ---
$contextName = ""
$parentParts = $resolvedPath -split '[/\\]'
for ($i = 0; $i -lt $parentParts.Count; $i++) {
	if ($parentParts[$i] -eq "Subsystems" -and ($i + 1) -lt $parentParts.Count) {
		$contextName = $parentParts[$i + 1]
	}
}
if (-not $contextName) { $contextName = "Root" }

# --- Output infrastructure ---
$script:errors = 0
$script:warnings = 0
$script:stopped = $false
$script:okCount = 0
$script:output = New-Object System.Text.StringBuilder 8192
$script:allCommandNames = @()

function Out-Line([string]$msg) { $script:output.AppendLine($msg) | Out-Null }
function Report-OK([string]$msg) {
	$script:okCount++
	if ($Detailed) { Out-Line "[OK]    $msg" }
}
function Report-Error([string]$msg) {
	$script:errors++
	Out-Line "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) { $script:stopped = $true }
}
function Report-Warn([string]$msg) {
	$script:warnings++
	Out-Line "[WARN]  $msg"
}

Out-Line "=== Validation: CommandInterface ($contextName) ==="
Out-Line ""

# --- Valid section names and order ---
$validSections = @("CommandsVisibility","CommandsPlacement","CommandsOrder","SubsystemsOrder","GroupsOrder")

# Command reference patterns
$stdCmdPattern = '^[A-Za-z]+\.[^\s\.]+\.StandardCommand\.\w+$'
$customCmdPattern = '^[A-Za-z]+\.[^\s\.]+\.Command\.\w+$'
$commonCmdPattern = '^CommonCommand\.\w+$'
$uuidCmdPattern = '^0:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# --- 1. XML well-formedness + root structure ---
$xmlDoc = $null
try {
	[xml]$xmlDoc = Get-Content -Path $resolvedPath -Encoding UTF8
} catch {
	Report-Error "1. XML parse error: $($_.Exception.Message)"
	$script:stopped = $true
}

if (-not $script:stopped) {
	$root = $xmlDoc.DocumentElement

	if ($root.LocalName -ne "CommandInterface") {
		Report-Error "1. Root element: expected <CommandInterface>, got <$($root.LocalName)>"
		$script:stopped = $true
	} else {
		$nsUri = $root.NamespaceURI
		$version = $root.GetAttribute("version")
		$expectedNs = "http://v8.1c.ru/8.3/xcf/extrnprops"
		if ($nsUri -ne $expectedNs) {
			Report-Error "1. Root namespace: expected $expectedNs, got $nsUri"
		} elseif (-not $version) {
			Report-Warn "1. Root structure: CommandInterface, namespace valid, but no version attribute"
		} else {
			Report-OK "1. Root structure: CommandInterface, version $version, namespace valid"
		}
	}
}

# --- Setup namespace manager ---
$ns = $null
if (-not $script:stopped) {
	$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
	$ns.AddNamespace("ci", "http://v8.1c.ru/8.3/xcf/extrnprops")
	$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
	$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
	$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
}

# --- 2. Valid child elements ---
if (-not $script:stopped) {
	$root = $xmlDoc.DocumentElement
	$foundSections = @()
	$invalidElements = @()
	foreach ($child in $root.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.LocalName -in $validSections) {
			$foundSections += $child.LocalName
		} else {
			$invalidElements += $child.LocalName
		}
	}
	if ($invalidElements.Count -gt 0) {
		Report-Error "2. Invalid child elements: $($invalidElements -join ', ')"
	} else {
		Report-OK "2. Child elements: $($foundSections.Count) valid sections"
	}
}

# --- 3. Section order ---
if (-not $script:stopped) {
	$orderOk = $true
	$lastIdx = -1
	foreach ($sec in $foundSections) {
		$idx = [array]::IndexOf($validSections, $sec)
		if ($idx -lt $lastIdx) {
			Report-Error "3. Section order: '$sec' appears after a later section (expected: CommandsVisibility -> CommandsPlacement -> CommandsOrder -> SubsystemsOrder -> GroupsOrder)"
			$orderOk = $false
			break
		}
		$lastIdx = $idx
	}
	if ($orderOk) { Report-OK "3. Section order: correct" }
}

# --- 4. No duplicate sections ---
if (-not $script:stopped) {
	$dupes = $foundSections | Group-Object | Where-Object { $_.Count -gt 1 }
	if ($dupes) {
		$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
		Report-Error "4. Duplicate sections: $dupeNames"
	} else {
		Report-OK "4. No duplicate sections"
	}
}

# --- 5. CommandsVisibility ---
if (-not $script:stopped) {
	$visSection = $root.SelectSingleNode("ci:CommandsVisibility", $ns)
	if ($visSection) {
		$visOk = $true
		$visNames = @()
		$visCount = 0
		foreach ($cmd in $visSection.ChildNodes) {
			if ($cmd.NodeType -ne 'Element') { continue }
			$visCount++
			$cmdName = $cmd.GetAttribute("name")
			if (-not $cmdName) {
				Report-Error "5. CommandsVisibility: Command element without 'name' attribute"
				$visOk = $false; continue
			}
			$visNames += $cmdName
			$script:allCommandNames += $cmdName
			$visibility = $cmd.SelectSingleNode("ci:Visibility", $ns)
			if (-not $visibility) {
				Report-Error "5. CommandsVisibility[$cmdName]: missing <Visibility>"
				$visOk = $false; continue
			}
			$common = $visibility.SelectSingleNode("xr:Common", $ns)
			if (-not $common) {
				Report-Error "5. CommandsVisibility[$cmdName]: missing <xr:Common>"
				$visOk = $false; continue
			}
			$val = $common.InnerText.Trim()
			if ($val -ne "true" -and $val -ne "false") {
				Report-Error "5. CommandsVisibility[$cmdName]: xr:Common='$val' (expected true/false)"
				$visOk = $false
			}
		}
		if ($visOk) { Report-OK "5. CommandsVisibility: $visCount entries, all valid" }
	} else {
		Report-OK "5. CommandsVisibility: not present"
		$visNames = @()
	}
}

# --- 6. CommandsVisibility duplicates ---
if (-not $script:stopped) {
	if ($visNames.Count -gt 0) {
		$dupes = $visNames | Group-Object | Where-Object { $_.Count -gt 1 }
		if ($dupes) {
			$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
			Report-Warn "6. CommandsVisibility: duplicates: $dupeNames"
		} else {
			Report-OK "6. CommandsVisibility: no duplicates"
		}
	} else {
		Report-OK "6. CommandsVisibility: no duplicates (empty)"
	}
}

# --- 7. CommandsPlacement ---
if (-not $script:stopped) {
	$plcSection = $root.SelectSingleNode("ci:CommandsPlacement", $ns)
	if ($plcSection) {
		$plcOk = $true
		$plcCount = 0
		foreach ($cmd in $plcSection.ChildNodes) {
			if ($cmd.NodeType -ne 'Element') { continue }
			$plcCount++
			$cmdName = $cmd.GetAttribute("name")
			if (-not $cmdName) {
				Report-Error "7. CommandsPlacement: Command without 'name' attribute"
				$plcOk = $false; continue
			}
			$script:allCommandNames += $cmdName
			$grpEl = $cmd.SelectSingleNode("ci:CommandGroup", $ns)
			if (-not $grpEl -or -not $grpEl.InnerText.Trim()) {
				Report-Error "7. CommandsPlacement[$cmdName]: missing or empty <CommandGroup>"
				$plcOk = $false; continue
			}
			$placementEl = $cmd.SelectSingleNode("ci:Placement", $ns)
			if (-not $placementEl) {
				Report-Error "7. CommandsPlacement[$cmdName]: missing <Placement>"
				$plcOk = $false
			} elseif ($placementEl.InnerText.Trim() -ne "Auto") {
				Report-Warn "7. CommandsPlacement[$cmdName]: Placement='$($placementEl.InnerText.Trim())' (expected Auto)"
			}
		}
		if ($plcOk) { Report-OK "7. CommandsPlacement: $plcCount entries, all valid" }
	} else {
		Report-OK "7. CommandsPlacement: not present"
	}
}

# --- 8. CommandsOrder ---
if (-not $script:stopped) {
	$ordSection = $root.SelectSingleNode("ci:CommandsOrder", $ns)
	if ($ordSection) {
		$ordOk = $true
		$ordCount = 0
		foreach ($cmd in $ordSection.ChildNodes) {
			if ($cmd.NodeType -ne 'Element') { continue }
			$ordCount++
			$cmdName = $cmd.GetAttribute("name")
			if (-not $cmdName) {
				Report-Error "8. CommandsOrder: Command without 'name' attribute"
				$ordOk = $false; continue
			}
			$script:allCommandNames += $cmdName
			$grpEl = $cmd.SelectSingleNode("ci:CommandGroup", $ns)
			if (-not $grpEl -or -not $grpEl.InnerText.Trim()) {
				Report-Error "8. CommandsOrder[$cmdName]: missing or empty <CommandGroup>"
				$ordOk = $false
			}
		}
		if ($ordOk) { Report-OK "8. CommandsOrder: $ordCount entries, all valid" }
	} else {
		Report-OK "8. CommandsOrder: not present"
	}
}

# --- 9. SubsystemsOrder format ---
if (-not $script:stopped) {
	$subSection = $root.SelectSingleNode("ci:SubsystemsOrder", $ns)
	$subNames = @()
	if ($subSection) {
		$subOk = $true
		$subCount = 0
		foreach ($sub in $subSection.ChildNodes) {
			if ($sub.NodeType -ne 'Element') { continue }
			$subCount++
			$text = $sub.InnerText.Trim()
			$subNames += $text
			if (-not $text) {
				Report-Error "9. SubsystemsOrder: empty <Subsystem> element"
				$subOk = $false
			} elseif ($text -notmatch '^Subsystem\.') {
				Report-Error "9. SubsystemsOrder: '$text' - expected format Subsystem.X..."
				$subOk = $false
			}
		}
		if ($subOk) { Report-OK "9. SubsystemsOrder: $subCount entries, all valid format" }
	} else {
		Report-OK "9. SubsystemsOrder: not present"
	}
}

# --- 10. SubsystemsOrder duplicates ---
if (-not $script:stopped) {
	if ($subNames.Count -gt 0) {
		$dupes = $subNames | Group-Object | Where-Object { $_.Count -gt 1 }
		if ($dupes) {
			$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
			Report-Warn "10. SubsystemsOrder: duplicates: $dupeNames"
		} else {
			Report-OK "10. SubsystemsOrder: no duplicates"
		}
	} else {
		Report-OK "10. SubsystemsOrder: no duplicates (empty)"
	}
}

# --- 11. GroupsOrder entries ---
if (-not $script:stopped) {
	$grpSection = $root.SelectSingleNode("ci:GroupsOrder", $ns)
	$grpNames = @()
	if ($grpSection) {
		$grpOk = $true
		$grpCount = 0
		foreach ($grp in $grpSection.ChildNodes) {
			if ($grp.NodeType -ne 'Element') { continue }
			$grpCount++
			$text = $grp.InnerText.Trim()
			$grpNames += $text
			if (-not $text) {
				Report-Error "11. GroupsOrder: empty <Group> element"
				$grpOk = $false
			}
		}
		if ($grpOk) { Report-OK "11. GroupsOrder: $grpCount entries, all valid" }
	} else {
		Report-OK "11. GroupsOrder: not present"
	}
}

# --- 12. GroupsOrder duplicates ---
if (-not $script:stopped) {
	if ($grpNames.Count -gt 0) {
		$dupes = $grpNames | Group-Object | Where-Object { $_.Count -gt 1 }
		if ($dupes) {
			$dupeNames = ($dupes | ForEach-Object { $_.Name }) -join ", "
			Report-Warn "12. GroupsOrder: duplicates: $dupeNames"
		} else {
			Report-OK "12. GroupsOrder: no duplicates"
		}
	} else {
		Report-OK "12. GroupsOrder: no duplicates (empty)"
	}
}

# --- 13. Command reference format ---
if (-not $script:stopped) {
	if ($script:allCommandNames.Count -gt 0) {
		$badRefs = @()
		foreach ($ref in $script:allCommandNames) {
			if ($ref -match $stdCmdPattern) { continue }
			if ($ref -match $customCmdPattern) { continue }
			if ($ref -match $commonCmdPattern) { continue }
			if ($ref -match $uuidCmdPattern) { continue }
			$badRefs += $ref
		}
		if ($badRefs.Count -eq 0) {
			Report-OK "13. Command reference format: all $($script:allCommandNames.Count) valid"
		} else {
			$shown = $badRefs[0..([Math]::Min(4, $badRefs.Count - 1))]
			Report-Warn "13. Command reference format: $($badRefs.Count) unrecognized: $($shown -join ', ')$(if($badRefs.Count -gt 5){' ...'})"
		}
	}
}

# --- Finalize ---
$checks = $script:okCount + $script:errors + $script:warnings

if ($script:errors -eq 0 -and $script:warnings -eq 0 -and -not $Detailed) {
	$result = "=== Validation OK: CommandInterface ($contextName) ($checks checks) ==="
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
