# cf-edit v1.2 — Edit 1C configuration root (Configuration.xml)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][Alias('Path')][string]$ConfigPath,
	[string]$DefinitionFile,
	[ValidateSet("modify-property","add-childObject","remove-childObject","add-defaultRole","remove-defaultRole","set-defaultRoles","set-panels")]
	[string]$Operation,
	[string]$Value,
	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Mode validation ---
if ($DefinitionFile -and $Operation) { Write-Error "Cannot use both -DefinitionFile and -Operation"; exit 1 }
if (-not $DefinitionFile -and -not $Operation) { Write-Error "Either -DefinitionFile or -Operation is required"; exit 1 }

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}
if (Test-Path $ConfigPath -PathType Container) {
	$candidate = Join-Path $ConfigPath "Configuration.xml"
	if (Test-Path $candidate) { $ConfigPath = $candidate }
	else { Write-Error "No Configuration.xml in directory"; exit 1 }
}
if (-not (Test-Path $ConfigPath)) { Write-Error "File not found: $ConfigPath"; exit 1 }
$resolvedPath = (Resolve-Path $ConfigPath).Path
$script:configDir = [System.IO.Path]::GetDirectoryName($resolvedPath)

# --- Load XML with PreserveWhitespace ---
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
$script:mdNs = "http://v8.1c.ru/8.3/MDClasses"
$script:xrNs = "http://v8.1c.ru/8.3/xcf/readable"
$script:xsiNs = "http://www.w3.org/2001/XMLSchema-instance"
$script:v8Ns = "http://v8.1c.ru/8.1/data/core"

$script:cfgEl = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Configuration") {
		$script:cfgEl = $child; break
	}
}
if (-not $script:cfgEl) { Write-Error "No <Configuration> element found"; exit 1 }

$script:propsEl = $null
$script:childObjsEl = $null
foreach ($child in $script:cfgEl.ChildNodes) {
	if ($child.NodeType -ne 'Element') { continue }
	if ($child.LocalName -eq "Properties") { $script:propsEl = $child }
	if ($child.LocalName -eq "ChildObjects") { $script:childObjsEl = $child }
}

$script:objName = ""
foreach ($child in $script:propsEl.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Name") {
		$script:objName = $child.InnerText.Trim(); break
	}
}
Info "Configuration: $($script:objName)"

# --- Canonical type order for ChildObjects (44 types) ---
$script:typeOrder = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","IntegrationService"
)

# --- Type → on-disk directory name (plural) ---
$script:typeToDir = @{
	"Language"="Languages"; "Subsystem"="Subsystems"; "StyleItem"="StyleItems"; "Style"="Styles"
	"CommonPicture"="CommonPictures"; "SessionParameter"="SessionParameters"; "Role"="Roles"; "CommonTemplate"="CommonTemplates"
	"FilterCriterion"="FilterCriteria"; "CommonModule"="CommonModules"; "CommonAttribute"="CommonAttributes"; "ExchangePlan"="ExchangePlans"
	"XDTOPackage"="XDTOPackages"; "WebService"="WebServices"; "HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"; "SettingsStorage"="SettingsStorages"; "FunctionalOption"="FunctionalOptions"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"; "DefinedType"="DefinedTypes"; "CommonCommand"="CommonCommands"; "CommandGroup"="CommandGroups"
	"Constant"="Constants"; "CommonForm"="CommonForms"; "Catalog"="Catalogs"; "Document"="Documents"
	"DocumentNumerator"="DocumentNumerators"; "Sequence"="Sequences"; "DocumentJournal"="DocumentJournals"; "Enum"="Enums"
	"Report"="Reports"; "DataProcessor"="DataProcessors"; "InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"; "ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"; "CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"; "IntegrationService"="IntegrationServices"
}

# --- XML manipulation helpers (from subsystem-edit pattern) ---
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

function Expand-SelfClosingElement($container, $parentIndent) {
	if (-not $container.HasChildNodes -or $container.IsEmpty) {
		$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

function Import-Fragment([string]$xmlString) {
	$wrapper = "<_W xmlns=`"$($script:mdNs)`" xmlns:xsi=`"$($script:xsiNs)`" xmlns:v8=`"$($script:v8Ns)`" xmlns:xr=`"$($script:xrNs)`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`">$xmlString</_W>"
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

# --- Parse batch value (split by ;;) ---
function Parse-BatchValue([string]$val) {
	$items = @()
	foreach ($part in $val.Split(";;")) {
		$trimmed = $part.Trim()
		if ($trimmed) { $items += $trimmed }
	}
	return ,$items
}

# --- LocalString properties ---
$mlProps = @("Synonym","BriefInformation","DetailedInformation","Copyright","VendorInformationAddress","ConfigurationInformationAddress")
# Scalar properties
$scalarProps = @("Name","Version","Vendor","Comment","NamePrefix","UpdateCatalogAddress")
# Ref properties
$refProps = @("DefaultLanguage")

# --- Operation: modify-property ---
function Do-ModifyProperty([string]$batchVal) {
	$items = Parse-BatchValue $batchVal
	foreach ($item in $items) {
		$eqIdx = $item.IndexOf("=")
		if ($eqIdx -lt 1) {
			Write-Error "Invalid property format '$item', expected 'Key=Value'"
			exit 1
		}
		$propName = $item.Substring(0, $eqIdx).Trim()
		$propValue = $item.Substring($eqIdx + 1).Trim()

		# Find property element
		$propEl = $null
		foreach ($child in $script:propsEl.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $propName) {
				$propEl = $child; break
			}
		}
		if (-not $propEl) {
			Write-Error "Property '$propName' not found in Properties"
			exit 1
		}

		if ($mlProps -contains $propName) {
			# LocalString
			if (-not $propValue) {
				$propEl.InnerXml = ""
			} else {
				$indent = Get-ChildIndent $script:propsEl
				$escaped = [System.Security.SecurityElement]::Escape($propValue)
				$mlXml = "`r`n$indent`t<v8:item>`r`n$indent`t`t<v8:lang>ru</v8:lang>`r`n$indent`t`t<v8:content>$escaped</v8:content>`r`n$indent`t</v8:item>`r`n$indent"
				$propEl.InnerXml = $mlXml
			}
		} elseif ($scalarProps -contains $propName -or $refProps -contains $propName) {
			# Simple text
			if (-not $propValue) { $propEl.InnerXml = "" }
			else { $propEl.InnerText = $propValue }
		} else {
			# Enum or other — just set text
			$propEl.InnerText = $propValue
		}

		$script:modifyCount++
		Info "Set $propName = `"$propValue`""
	}
}

# --- Operation: add-childObject ---
function Do-AddChildObject([string]$batchVal) {
	if (-not $script:childObjsEl) { Write-Error "No <ChildObjects> element found"; exit 1 }

	$items = Parse-BatchValue $batchVal
	$cfgIndent = Get-ChildIndent $script:cfgEl

	# Expand self-closing if needed
	if (-not $script:childObjsEl.HasChildNodes -or $script:childObjsEl.IsEmpty) {
		Expand-SelfClosingElement $script:childObjsEl $cfgIndent
	}
	$childIndent = Get-ChildIndent $script:childObjsEl

	foreach ($item in $items) {
		$dotIdx = $item.IndexOf(".")
		if ($dotIdx -lt 1) {
			Write-Error "Invalid format '$item', expected 'Type.Name'"
			exit 1
		}
		$typeName = $item.Substring(0, $dotIdx)
		$objNameVal = $item.Substring($dotIdx + 1)

		# Check type is valid
		$typeIdx = $script:typeOrder.IndexOf($typeName)
		if ($typeIdx -lt 0) {
			Write-Error "Unknown type '$typeName'"
			exit 1
		}

		# Check that the referenced object actually exists on disk.
		# cf-edit add-childObject is a low-level operation for rare scenarios
		# (e.g. restoring a rolled-back Configuration.xml when object files are intact).
		# For creating NEW objects, meta-compile/role-compile/subsystem-compile already
		# auto-register in Configuration.xml — calling cf-edit add-childObject there is
		# unnecessary and error-prone.
		$typeDir = $script:typeToDir[$typeName]
		$objFile = Join-Path (Join-Path $script:configDir $typeDir) "$objNameVal.xml"
		if (-not (Test-Path $objFile)) {
			$hintSkill = switch ($typeName) {
				"Subsystem" { "subsystem-compile" }
				"Role"      { "role-compile" }
				default     { "meta-compile" }
			}
			Write-Error @"
Object file not found: $typeDir/$objNameVal.xml
cf-edit add-childObject only references objects that already exist on disk.
To create a new $typeName, use $hintSkill (auto-registers in Configuration.xml):
  /$hintSkill with {"type":"$typeName","name":"$objNameVal"}
"@
			exit 1
		}

		# Dedup check
		$existing = $false
		foreach ($child in $script:childObjsEl.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $typeName -and $child.InnerText -eq $objNameVal) {
				$existing = $true; break
			}
		}
		if ($existing) {
			Warn "Already exists: $typeName.$objNameVal"
			continue
		}

		# Find insertion point: after last element of same type, or after last element of preceding type
		$insertBefore = $null
		$lastSameType = $null
		$lastPrecedingType = $null
		$currentTypeIdx = -1

		foreach ($child in $script:childObjsEl.ChildNodes) {
			if ($child.NodeType -ne 'Element') { continue }
			$childTypeIdx = $script:typeOrder.IndexOf($child.LocalName)
			if ($childTypeIdx -lt 0) { continue }

			if ($child.LocalName -eq $typeName) {
				# Same type — check alphabetical order
				if ($child.InnerText -gt $objNameVal -and -not $insertBefore) {
					# Insert before this element (alphabetical)
					$insertBefore = $child
				}
				$lastSameType = $child
			} elseif ($childTypeIdx -lt $typeIdx) {
				$lastPrecedingType = $child
			} elseif ($childTypeIdx -gt $typeIdx -and -not $insertBefore) {
				# First element of a later type — insert before it
				$insertBefore = $child
			}
		}

		# Create element
		$newEl = $script:xmlDoc.CreateElement($typeName, $script:mdNs)
		$newEl.InnerText = $objNameVal

		if ($insertBefore) {
			Insert-BeforeElement $script:childObjsEl $newEl $insertBefore $childIndent
		} else {
			# Append at end (or after last same/preceding type)
			Insert-BeforeElement $script:childObjsEl $newEl $null $childIndent
		}

		$script:addCount++
		Info "Added: $typeName.$objNameVal"
	}
}

# --- Operation: remove-childObject ---
function Do-RemoveChildObject([string]$batchVal) {
	if (-not $script:childObjsEl) { Write-Error "No <ChildObjects> element found"; exit 1 }

	$items = Parse-BatchValue $batchVal
	foreach ($item in $items) {
		$dotIdx = $item.IndexOf(".")
		if ($dotIdx -lt 1) {
			Write-Error "Invalid format '$item', expected 'Type.Name'"
			exit 1
		}
		$typeName = $item.Substring(0, $dotIdx)
		$objNameVal = $item.Substring($dotIdx + 1)

		$found = $false
		foreach ($child in @($script:childObjsEl.ChildNodes)) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $typeName -and $child.InnerText -eq $objNameVal) {
				Remove-NodeWithWhitespace $child
				$script:removeCount++
				Info "Removed: $typeName.$objNameVal"
				$found = $true
				break
			}
		}
		if (-not $found) { Warn "Not found: $typeName.$objNameVal" }
	}
}

# --- Operation: add-defaultRole ---
function Do-AddDefaultRole([string]$batchVal) {
	$items = Parse-BatchValue $batchVal

	# Find DefaultRoles element
	$rolesEl = $null
	foreach ($child in $script:propsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "DefaultRoles") {
			$rolesEl = $child; break
		}
	}
	if (-not $rolesEl) { Write-Error "No <DefaultRoles> element found in Properties"; exit 1 }

	$propsIndent = Get-ChildIndent $script:propsEl
	if (-not $rolesEl.HasChildNodes -or $rolesEl.IsEmpty) {
		Expand-SelfClosingElement $rolesEl $propsIndent
	}
	$roleIndent = Get-ChildIndent $rolesEl

	foreach ($item in $items) {
		$roleName = $item
		if (-not $roleName.StartsWith("Role.")) { $roleName = "Role.$roleName" }

		# Dedup
		$existing = $false
		foreach ($child in $rolesEl.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.InnerText.Trim() -eq $roleName) {
				$existing = $true; break
			}
		}
		if ($existing) {
			Warn "DefaultRole already exists: $roleName"
			continue
		}

		$fragXml = "<xr:Item xsi:type=`"xr:MDObjectRef`">$roleName</xr:Item>"
		$nodes = Import-Fragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $rolesEl $nodes[0] $null $roleIndent
			$script:addCount++
			Info "Added DefaultRole: $roleName"
		}
	}
}

# --- Operation: remove-defaultRole ---
function Do-RemoveDefaultRole([string]$batchVal) {
	$items = Parse-BatchValue $batchVal

	$rolesEl = $null
	foreach ($child in $script:propsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "DefaultRoles") {
			$rolesEl = $child; break
		}
	}
	if (-not $rolesEl) { Write-Error "No <DefaultRoles> element found"; exit 1 }

	foreach ($item in $items) {
		$roleName = $item
		if (-not $roleName.StartsWith("Role.")) { $roleName = "Role.$roleName" }

		$found = $false
		foreach ($child in @($rolesEl.ChildNodes)) {
			if ($child.NodeType -eq 'Element' -and $child.InnerText.Trim() -eq $roleName) {
				Remove-NodeWithWhitespace $child
				$script:removeCount++
				Info "Removed DefaultRole: $roleName"
				$found = $true
				break
			}
		}
		if (-not $found) { Warn "DefaultRole not found: $roleName" }
	}
}

# --- Operation: set-panels ---
$script:panelUuids = @{
	"sections"  = "b553047f-c9aa-4157-978d-448ecad24248"
	"open"      = "cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"
	"favorites" = "13322b22-3960-4d68-93a6-fe2dd7f28ca3"
	"history"   = "c933ac92-92cd-459d-81cc-e0c8a83ced99"
	"functions" = "b2735bd3-d822-4430-ba59-c9e869693b24"
}

function Build-PanelEntryXml($entry, [string]$indent) {
	# String alias -> <panel><uuid>...</uuid></panel>
	if ($entry -is [string]) {
		if (-not $script:panelUuids.ContainsKey($entry)) {
			Write-Error "Unknown panel alias '$entry'. Allowed: $(($script:panelUuids.Keys | Sort-Object) -join ', ')"
			exit 1
		}
		$u = $script:panelUuids[$entry]
		$instId = [guid]::NewGuid().ToString()
		return "$indent<panel id=`"$instId`">`r`n$indent`t<uuid>$u</uuid>`r`n$indent</panel>"
	}
	# Object {group: [...]} -> <group id=""><group><panel/></group>...</group> (stack)
	if ($entry.PSObject.Properties['group']) {
		$children = $entry.group
		if (-not $children -or $children.Count -eq 0) {
			Write-Error "group must contain at least one entry"
			exit 1
		}
		$gid = [guid]::NewGuid().ToString()
		$inner = ""
		foreach ($child in $children) {
			$childXml = Build-PanelEntryXml $child "$indent`t`t"
			$inner += "$indent`t<group>`r`n$childXml`r`n$indent`t</group>`r`n"
		}
		return "$indent<group id=`"$gid`">`r`n$inner$indent</group>"
	}
	Write-Error "Panel entry must be a string alias or object {group:[...]}, got: $($entry | ConvertTo-Json -Compress)"
	exit 1
}

function Do-SetPanels($valArg) {
	# Accept string (JSON), PSCustomObject, or hashtable
	$layout = $valArg
	if ($layout -is [string]) {
		try { $layout = $layout | ConvertFrom-Json } catch {
			Write-Error "set-panels value must be valid JSON object, got: $valArg"
			exit 1
		}
	}
	if (-not $layout) {
		Write-Error "set-panels value is empty"
		exit 1
	}

	$sides = @("top","left","right","bottom")
	$bodyParts = @()
	foreach ($side in $sides) {
		$entries = $null
		if ($layout.PSObject.Properties[$side]) { $entries = $layout.$side }
		if ($null -eq $entries) { continue }
		# Normalize to array
		if ($entries -isnot [System.Array] -and $entries -isnot [System.Collections.IList]) {
			$entries = @($entries)
		}
		foreach ($entry in $entries) {
			$entryXml = Build-PanelEntryXml $entry "`t`t"
			$bodyParts += "`t<$side>`r`n$entryXml`r`n`t</$side>"
		}
	}

	# Reject unknown side keys (catches typos like "Top" vs "top")
	foreach ($prop in $layout.PSObject.Properties) {
		if ($sides -notcontains $prop.Name) {
			Write-Error "Unknown side '$($prop.Name)'. Allowed: $($sides -join ', ')"
			exit 1
		}
	}

	$body = $bodyParts -join "`r`n"
	$declarations = @"
	<panelDef id="b553047f-c9aa-4157-978d-448ecad24248"/>
	<panelDef id="13322b22-3960-4d68-93a6-fe2dd7f28ca3"/>
	<panelDef id="c933ac92-92cd-459d-81cc-e0c8a83ced99"/>
	<panelDef id="cbab57f2-a0f3-4f0a-89ea-4cb19570ab75"/>
	<panelDef id="b2735bd3-d822-4430-ba59-c9e869693b24"/>
"@
	$bodyBlock = if ($body) { "$body`r`n" } else { "" }
	$caiXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<ClientApplicationInterface xmlns="http://v8.1c.ru/8.2/managed-application/core" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="InterfaceLayouter">
$bodyBlock$declarations
</ClientApplicationInterface>
"@

	$extDir = Join-Path $script:configDir "Ext"
	if (-not (Test-Path $extDir)) { New-Item -ItemType Directory -Path $extDir -Force | Out-Null }
	$caiPath = Join-Path $extDir "ClientApplicationInterface.xml"
	$utf8Bom = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($caiPath, $caiXml, $utf8Bom)
	$script:modifyCount++
	Info "Wrote panel layout: $caiPath"
}

# --- Operation: set-defaultRoles ---
function Do-SetDefaultRoles([string]$batchVal) {
	$items = Parse-BatchValue $batchVal

	$rolesEl = $null
	foreach ($child in $script:propsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "DefaultRoles") {
			$rolesEl = $child; break
		}
	}
	if (-not $rolesEl) { Write-Error "No <DefaultRoles> element found"; exit 1 }

	# Clear all existing children
	while ($rolesEl.HasChildNodes) {
		$rolesEl.RemoveChild($rolesEl.FirstChild) | Out-Null
	}

	if ($items.Count -eq 0) {
		$script:modifyCount++
		Info "Cleared DefaultRoles"
		return
	}

	$propsIndent = Get-ChildIndent $script:propsEl
	$roleIndent = "$propsIndent`t"

	# Add closing whitespace
	$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$propsIndent")
	$rolesEl.AppendChild($closeWs) | Out-Null

	foreach ($item in $items) {
		$roleName = $item
		if (-not $roleName.StartsWith("Role.")) { $roleName = "Role.$roleName" }

		$fragXml = "<xr:Item xsi:type=`"xr:MDObjectRef`">$roleName</xr:Item>"
		$nodes = Import-Fragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $rolesEl $nodes[0] $null $roleIndent
		}
	}

	$script:modifyCount++
	Info "Set DefaultRoles: $($items.Count) roles"
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
	# Pass value through as-is (object or string); set-panels needs object form
	$opValue = if ($null -ne $op.value) { $op.value } else { $Value }
	$opValueStr = if ($opValue -is [string]) { $opValue } else { "$opValue" }

	switch ($opName) {
		"modify-property"    { Do-ModifyProperty $opValueStr }
		"add-childObject"    { Do-AddChildObject $opValueStr }
		"remove-childObject" { Do-RemoveChildObject $opValueStr }
		"add-defaultRole"    { Do-AddDefaultRole $opValueStr }
		"remove-defaultRole" { Do-RemoveDefaultRole $opValueStr }
		"set-defaultRoles"   { Do-SetDefaultRoles $opValueStr }
		"set-panels"         { Do-SetPanels $opValue }
		default              { Write-Error "Unknown operation: $opName"; exit 1 }
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
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\cf-validate") "scripts\cf-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running cf-validate ---"
		& powershell.exe -NoProfile -File $validateScript -ConfigPath $resolvedPath
	}
}

# --- Summary ---
Write-Host ""
Write-Host "=== cf-edit summary ==="
Write-Host "  Configuration: $($script:objName)"
Write-Host "  Added:         $($script:addCount)"
Write-Host "  Removed:       $($script:removeCount)"
Write-Host "  Modified:      $($script:modifyCount)"
exit 0
