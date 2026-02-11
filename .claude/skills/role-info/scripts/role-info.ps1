# role-info v1.0 — Analyze 1C role rights
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)][string]$RightsPath,
	[switch]$ShowDenied,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Output helper (always collect, paginate at the end) ---
$script:lines = @()
function Out([string]$text) { $script:lines += $text }

# --- Resolve paths ---
if (-not [System.IO.Path]::IsPathRooted($RightsPath)) {
	$RightsPath = Join-Path (Get-Location).Path $RightsPath
}

if (-not (Test-Path $RightsPath)) {
	Write-Host "[ERROR] File not found: $RightsPath"
	exit 1
}

# --- Try to find metadata file for role name/synonym ---
$roleName = ""
$roleSynonym = ""
$extDir = Split-Path $RightsPath          # .../Ext
$roleDir = Split-Path $extDir             # .../RoleName
$rolesDir = Split-Path $roleDir           # .../Roles
$roleFolderName = Split-Path $roleDir -Leaf
$metaPath = Join-Path $rolesDir "$roleFolderName.xml"

if (Test-Path $metaPath) {
	try {
		[xml]$metaXml = Get-Content -Path $metaPath -Encoding UTF8
		$ns = New-Object System.Xml.XmlNamespaceManager($metaXml.NameTable)
		$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
		$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
		$nameNode = $metaXml.SelectSingleNode("//md:Role/md:Properties/md:Name", $ns)
		if ($nameNode) { $roleName = $nameNode.InnerText }
		$synNode = $metaXml.SelectSingleNode("//md:Role/md:Properties/md:Synonym/v8:item[v8:lang='ru']/v8:content", $ns)
		if ($synNode) { $roleSynonym = $synNode.InnerText }
	} catch {
		# Ignore metadata parsing errors
	}
}

if (-not $roleName) { $roleName = $roleFolderName }

# --- Parse Rights.xml ---
[xml]$xml = Get-Content -Path $RightsPath -Encoding UTF8
$root = $xml.DocumentElement
$rightsNs = "http://v8.1c.ru/8.2/roles"

# Global flags
$setForNew = $root.setForNewObjects
$setForAttrs = $root.setForAttributesByDefault
$independentChild = $root.independentRightsOfChildObjects

# --- Collect objects ---
# Structure: grouped by type prefix, then by object short name
$allowed = [ordered]@{}     # type -> [ordered]@{ shortName -> [list of rights] }
$denied = [ordered]@{}      # type -> [ordered]@{ shortName -> [list of rights] }
$rlsObjects = @()
$totalAllowed = 0
$totalDenied = 0

$objects = $root.GetElementsByTagName("object", $rightsNs)
foreach ($obj in $objects) {
	$objName = ""
	$rights = @()

	foreach ($child in $obj.ChildNodes) {
		if ($child.LocalName -eq "name" -and $child.NamespaceURI -eq $rightsNs) {
			$objName = $child.InnerText
		}
		if ($child.LocalName -eq "right" -and $child.NamespaceURI -eq $rightsNs) {
			$rName = ""
			$rValue = ""
			$hasRLS = $false
			foreach ($rc in $child.ChildNodes) {
				if ($rc.LocalName -eq "name") { $rName = $rc.InnerText }
				if ($rc.LocalName -eq "value") { $rValue = $rc.InnerText }
				if ($rc.LocalName -eq "restrictionByCondition") { $hasRLS = $true }
			}
			if ($rName -and $rValue) {
				$rights += @{ name = $rName; value = $rValue; rls = $hasRLS }
			}
		}
	}

	if (-not $objName -or $rights.Count -eq 0) { continue }

	# Split into type prefix and short name
	$dotIdx = $objName.IndexOf(".")
	if ($dotIdx -lt 0) { continue }
	$typePrefix = $objName.Substring(0, $dotIdx)
	$shortName = $objName.Substring($dotIdx + 1)

	foreach ($r in $rights) {
		if ($r.value -eq "true") {
			$totalAllowed++
			if (-not $allowed.Contains($typePrefix)) {
				$allowed[$typePrefix] = [ordered]@{}
			}
			if (-not $allowed[$typePrefix].Contains($shortName)) {
				$allowed[$typePrefix][$shortName] = @()
			}
			$suffix = $r.name
			if ($r.rls) {
				$suffix += " [RLS]"
				$rlsObjects += "$typePrefix.$shortName ($($r.name))"
			}
			$allowed[$typePrefix][$shortName] += $suffix
		}
		else {
			$totalDenied++
			if (-not $denied.Contains($typePrefix)) {
				$denied[$typePrefix] = [ordered]@{}
			}
			if (-not $denied[$typePrefix].Contains($shortName)) {
				$denied[$typePrefix][$shortName] = @()
			}
			$denied[$typePrefix][$shortName] += $r.name
		}
	}
}

# --- Restriction templates ---
$templates = @()
$tplNodes = $root.GetElementsByTagName("restrictionTemplate", $rightsNs)
foreach ($tpl in $tplNodes) {
	foreach ($child in $tpl.ChildNodes) {
		if ($child.LocalName -eq "name") {
			$tName = $child.InnerText
			# Extract just the name part before parentheses
			$parenIdx = $tName.IndexOf("(")
			if ($parenIdx -gt 0) { $tName = $tName.Substring(0, $parenIdx) }
			$templates += $tName
		}
	}
}

# --- Output ---
$header = "=== Role: $roleName"
if ($roleSynonym) { $header += " --- `"$roleSynonym`"" }
$header += " ==="
Out $header
Out ""

Out "Properties: setForNewObjects=$setForNew, setForAttributesByDefault=$setForAttrs, independentRightsOfChildObjects=$independentChild"
Out ""

# Helper: output group
function OutGroup($objMap, [string]$prefix, [switch]$isDenied) {
	foreach ($shortName in @($objMap.Keys)) {
		if ($isDenied) {
			$rightsList = ($objMap[$shortName] | ForEach-Object { "-$_" }) -join ", "
		} else {
			$rightsList = $objMap[$shortName] -join ", "
		}
		Out "    ${shortName}: $rightsList"
	}
}

# Allowed rights grouped by type
if ($allowed.Count -gt 0) {
	Out "Allowed rights:"
	Out ""
	foreach ($typePrefix in $allowed.Keys) {
		$objMap = $allowed[$typePrefix]
		Out "  $typePrefix ($($objMap.Count)):"
		OutGroup $objMap $typePrefix
		Out ""
	}
}
else {
	Out "(no allowed rights)"
	Out ""
}

# Denied rights
if ($ShowDenied -and $denied.Count -gt 0) {
	Out "Denied rights:"
	Out ""
	foreach ($typePrefix in $denied.Keys) {
		$objMap = $denied[$typePrefix]
		Out "  $typePrefix ($($objMap.Count)):"
		OutGroup $objMap $typePrefix -isDenied
		Out ""
	}
}
elseif ($totalDenied -gt 0) {
	Out "Denied: $totalDenied rights (use -ShowDenied to list)"
	Out ""
}

# RLS summary
if ($rlsObjects.Count -gt 0) {
	Out "RLS: $($rlsObjects.Count) restrictions"
}

# Templates
if ($templates.Count -gt 0) {
	Out "Templates: $($templates -join ', ')"
}

Out ""
Out "---"
Out "Total: $totalAllowed allowed, $totalDenied denied"

# --- Pagination and output ---
$totalLines = $script:lines.Count
$lines = $script:lines

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$lines = $lines[$Offset..($totalLines - 1)]
}

if ($Limit -gt 0 -and $lines.Count -gt $Limit) {
	$shown = $lines[0..($Limit - 1)]
	$remaining = $totalLines - $Offset - $Limit
	$shown += ""
	$shown += "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
	$lines = $shown
}

if ($OutFile) {
	if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
		$OutFile = Join-Path (Get-Location).Path $OutFile
	}
	$utf8 = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllLines($OutFile, $lines, $utf8)
	Write-Host "Output written to $OutFile"
} else {
	foreach ($l in $lines) { Write-Host $l }
}
