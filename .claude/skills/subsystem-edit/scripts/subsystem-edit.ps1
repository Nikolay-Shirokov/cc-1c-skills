# subsystem-edit v1.0 — Edit existing 1C subsystem XML
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)][string]$SubsystemPath,
	[string]$DefinitionFile,
	[ValidateSet("add-content","remove-content","add-child","remove-child","set-property")]
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
if (-not [System.IO.Path]::IsPathRooted($SubsystemPath)) {
	$SubsystemPath = Join-Path (Get-Location).Path $SubsystemPath
}
if (Test-Path $SubsystemPath -PathType Container) {
	$dirName = Split-Path $SubsystemPath -Leaf
	$candidate = Join-Path $SubsystemPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $SubsystemPath) "$dirName.xml"
	if (Test-Path $candidate) { $SubsystemPath = $candidate }
	elseif (Test-Path $sibling) { $SubsystemPath = $sibling }
	else { Write-Error "No $dirName.xml found in directory or as sibling"; exit 1 }
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
if (-not (Test-Path $SubsystemPath)) { Write-Error "File not found: $SubsystemPath"; exit 1 }
$resolvedPath = (Resolve-Path $SubsystemPath).Path

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

$script:sub = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Subsystem") {
		$script:sub = $child; break
	}
}
if (-not $script:sub) { Write-Error "No <Subsystem> element found"; exit 1 }

$script:propsEl = $null
$script:childObjsEl = $null
foreach ($child in $script:sub.ChildNodes) {
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
Info "Subsystem: $($script:objName)"

# --- XML manipulation helpers (from meta-edit pattern) ---
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
	# If the element is self-closing (empty), add whitespace for children
	if (-not $container.HasChildNodes -or $container.IsEmpty) {
		$childIndent = "$parentIndent`t"
		# The element is self-closing; we need to add something to make it non-empty
		# Adding a whitespace node will force opening+closing tags
		$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
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

# --- Operations ---
function Do-AddContent([string[]]$items) {
	$contentEl = $null
	foreach ($child in $script:propsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Content") {
			$contentEl = $child; break
		}
	}
	if (-not $contentEl) { Write-Error "No <Content> element found"; exit 1 }

	# Get existing items for dedup
	$existing = @()
	foreach ($child in $contentEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Item") {
			$existing += $child.InnerText.Trim()
		}
	}

	# Determine indentation
	$propsIndent = Get-ChildIndent $script:propsEl
	$contentIndent = "$propsIndent`t"

	# Expand self-closing if needed
	if (-not $contentEl.HasChildNodes -or $contentEl.IsEmpty) {
		Expand-SelfClosingElement $contentEl $propsIndent
		$contentIndent = "$propsIndent`t"
	} else {
		$contentIndent = Get-ChildIndent $contentEl
	}

	foreach ($item in $items) {
		if ($item -in $existing) {
			Warn "Content already contains: $item"
			continue
		}
		$fragXml = "<xr:Item xsi:type=`"xr:MDObjectRef`">$item</xr:Item>"
		$nodes = Import-Fragment $fragXml
		if ($nodes.Count -gt 0) {
			Insert-BeforeElement $contentEl $nodes[0] $null $contentIndent
			$script:addCount++
			Info "Added content: $item"
		}
	}
}

function Do-RemoveContent([string[]]$items) {
	$contentEl = $null
	foreach ($child in $script:propsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Content") {
			$contentEl = $child; break
		}
	}
	if (-not $contentEl) { Write-Error "No <Content> element found"; exit 1 }

	foreach ($item in $items) {
		$found = $false
		foreach ($child in @($contentEl.ChildNodes)) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Item" -and $child.InnerText.Trim() -eq $item) {
				Remove-NodeWithWhitespace $child
				$script:removeCount++
				Info "Removed content: $item"
				$found = $true
				break
			}
		}
		if (-not $found) { Warn "Content item not found: $item" }
	}
}

function Do-AddChild([string]$childName) {
	if (-not $script:childObjsEl) { Write-Error "No <ChildObjects> element found"; exit 1 }

	# Dedup check
	foreach ($child in $script:childObjsEl.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Subsystem" -and $child.InnerText.Trim() -eq $childName) {
			Warn "ChildObjects already contains: $childName"
			return
		}
	}

	$subIndent = Get-ChildIndent $script:sub
	if (-not $script:childObjsEl.HasChildNodes -or $script:childObjsEl.IsEmpty) {
		Expand-SelfClosingElement $script:childObjsEl $subIndent
	}
	$childIndent = Get-ChildIndent $script:childObjsEl

	$newEl = $script:xmlDoc.CreateElement("Subsystem", $script:mdNs)
	$newEl.InnerText = $childName
	Insert-BeforeElement $script:childObjsEl $newEl $null $childIndent
	$script:addCount++
	Info "Added child subsystem: $childName"
}

function Do-RemoveChild([string]$childName) {
	if (-not $script:childObjsEl) { Write-Error "No <ChildObjects> element found"; exit 1 }

	$found = $false
	foreach ($child in @($script:childObjsEl.ChildNodes)) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Subsystem" -and $child.InnerText.Trim() -eq $childName) {
			Remove-NodeWithWhitespace $child
			$script:removeCount++
			Info "Removed child subsystem: $childName"
			$found = $true
			break
		}
	}
	if (-not $found) { Warn "Child subsystem not found: $childName" }
}

function Do-SetProperty([string]$jsonVal) {
	$propDef = $jsonVal | ConvertFrom-Json
	$propName = "$($propDef.name)"
	$propValue = "$($propDef.value)"

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

	$boolProps = @("IncludeInCommandInterface","UseOneCommand","IncludeHelpInContents")
	if ($propName -in $boolProps) {
		$propEl.InnerText = $propValue.ToLower()
		$script:modifyCount++
		Info "Set $propName = $propValue"
		return
	}

	$mlProps = @("Synonym","Explanation")
	if ($propName -in $mlProps) {
		if (-not $propValue) {
			# Clear - make self-closing
			$propEl.InnerXml = ""
			$script:modifyCount++
			Info "Cleared $propName"
		} else {
			$indent = Get-ChildIndent $script:propsEl
			$mlXml = "`r`n$indent`t<v8:item>`r`n$indent`t`t<v8:lang>ru</v8:lang>`r`n$indent`t`t<v8:content>$([System.Security.SecurityElement]::Escape($propValue))</v8:content>`r`n$indent`t</v8:item>`r`n$indent"
			$propEl.InnerXml = $mlXml
			$script:modifyCount++
			Info "Set $propName = `"$propValue`""
		}
		return
	}

	if ($propName -eq "Comment") {
		if (-not $propValue) { $propEl.InnerXml = "" }
		else { $propEl.InnerText = $propValue }
		$script:modifyCount++
		Info "Set Comment = `"$propValue`""
		return
	}

	if ($propName -eq "Picture") {
		if (-not $propValue) {
			$propEl.InnerXml = ""
		} else {
			$indent = Get-ChildIndent $script:propsEl
			$picXml = "`r`n$indent`t<xr:Ref>$propValue</xr:Ref>`r`n$indent`t<xr:LoadTransparent>false</xr:LoadTransparent>`r`n$indent"
			$propEl.InnerXml = $picXml
		}
		$script:modifyCount++
		Info "Set Picture = `"$propValue`""
		return
	}

	# Generic text property
	$propEl.InnerText = $propValue
	$script:modifyCount++
	Info "Set $propName = `"$propValue`""
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
	$opValue = if ($op.value) { "$($op.value)" } else { "$Value" }

	switch ($opName) {
		"add-content"    { Do-AddContent (Parse-ValueList $opValue) }
		"remove-content" { Do-RemoveContent (Parse-ValueList $opValue) }
		"add-child"      { Do-AddChild $opValue }
		"remove-child"   { Do-RemoveChild $opValue }
		"set-property"   { Do-SetProperty $opValue }
		default          { Write-Error "Unknown operation: $opName"; exit 1 }
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
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\subsystem-validate") "scripts\subsystem-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running subsystem-validate ---"
		& powershell.exe -NoProfile -File $validateScript -SubsystemPath $resolvedPath
	}
}

# --- Summary ---
Write-Host ""
Write-Host "=== subsystem-edit summary ==="
Write-Host "  Subsystem: $($script:objName)"
Write-Host "  Added:     $($script:addCount)"
Write-Host "  Removed:   $($script:removeCount)"
Write-Host "  Modified:  $($script:modifyCount)"
exit 0
