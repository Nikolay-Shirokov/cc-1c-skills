param(
	[Parameter(Mandatory=$true)]
	[string]$TemplatePath,
	[ValidateSet("overview", "query", "fields", "params", "variant")]
	[string]$Mode = "overview",
	[string]$Name,
	[int]$Batch = 0,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---

if (-not $TemplatePath.EndsWith(".xml")) {
	$candidate = Join-Path (Join-Path $TemplatePath "Ext") "Template.xml"
	if (Test-Path $candidate) {
		$TemplatePath = $candidate
	}
}

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

$resolvedPath = (Resolve-Path $TemplatePath).Path

# --- Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load($resolvedPath)

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("s", "http://v8.1c.ru/8.1/data-composition-system/schema")
$ns.AddNamespace("dcscom", "http://v8.1c.ru/8.1/data-composition-system/common")
$ns.AddNamespace("dcscor", "http://v8.1c.ru/8.1/data-composition-system/core")
$ns.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

$root = $xmlDoc.DocumentElement

# --- Helpers ---

function Get-MLText($node) {
	if (-not $node) { return "" }
	$content = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($content) { return $content.InnerText }
	$text = $node.InnerText.Trim()
	if ($text) { return $text }
	return ""
}

function Unescape-Xml([string]$text) {
	if (-not $text) { return $text }
	$text = $text.Replace("&amp;", "&")
	$text = $text.Replace("&gt;", ">")
	$text = $text.Replace("&lt;", "<")
	$text = $text.Replace("&quot;", '"')
	$text = $text.Replace("&apos;", "'")
	return $text
}

function Get-CompactType($valueTypeNode) {
	if (-not $valueTypeNode) { return "" }
	$types = @()
	foreach ($t in $valueTypeNode.SelectNodes("v8:Type", $ns)) {
		$raw = $t.InnerText
		switch -Wildcard ($raw) {
			"xs:string"   { $types += "String" }
			"xs:decimal"  { $types += "Number" }
			"xs:boolean"  { $types += "Boolean" }
			"xs:dateTime" { $types += "DateTime" }
			"v8:StandardPeriod" { $types += "StandardPeriod" }
			"v8:StandardBeginningDate" { $types += "StandardBeginningDate" }
			"v8:AccountType" { $types += "AccountType" }
			"v8:Null"     { $types += "Null" }
			default {
				# Strip namespace prefixes like d4p1: cfg:
				$clean = $raw -replace '^[a-zA-Z0-9]+:', ''
				$types += $clean
			}
		}
	}
	if ($types.Count -eq 0) { return "" }
	return ($types -join " | ")
}

function Get-DataSetType($dsNode) {
	$xsiType = $dsNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsiType -like "*DataSetQuery*") { return "Query" }
	if ($xsiType -like "*DataSetObject*") { return "Object" }
	if ($xsiType -like "*DataSetUnion*") { return "Union" }
	return "Unknown"
}

function Get-FieldCount($dsNode) {
	return $dsNode.SelectNodes("s:field", $ns).Count
}

function Get-QueryLineCount($dsNode) {
	$queryNode = $dsNode.SelectSingleNode("s:query", $ns)
	if (-not $queryNode) { return 0 }
	$text = $queryNode.InnerText
	return ($text -split "`n").Count
}

function Get-StructureItemType($itemNode) {
	$xsiType = $itemNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if ($xsiType -like "*StructureItemGroup*") { return "Group" }
	if ($xsiType -like "*StructureItemTable*") { return "Table" }
	if ($xsiType -like "*StructureItemChart*") { return "Chart" }
	return "Unknown"
}

function Get-GroupFields($itemNode) {
	$fields = @()
	foreach ($gi in $itemNode.SelectNodes("dcsset:groupItems/dcsset:item", $ns)) {
		$fieldNode = $gi.SelectSingleNode("dcsset:field", $ns)
		$groupType = $gi.SelectSingleNode("dcsset:groupType", $ns)
		if ($fieldNode) {
			$f = $fieldNode.InnerText
			$gt = if ($groupType) { $groupType.InnerText } else { "" }
			if ($gt -and $gt -ne "Items") { $f += "($gt)" }
			$fields += $f
		}
	}
	return $fields
}

function Get-SelectionFields($itemNode) {
	$fields = @()
	foreach ($si in $itemNode.SelectNodes("dcsset:selection/dcsset:item", $ns)) {
		$xsiType = $si.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		if ($xsiType -like "*SelectedItemAuto*") {
			$fields += "Auto"
		} elseif ($xsiType -like "*SelectedItemField*") {
			$f = $si.SelectSingleNode("dcsset:field", $ns)
			if ($f) { $fields += $f.InnerText }
		} elseif ($xsiType -like "*SelectedItemFolder*") {
			$fields += "Folder"
		}
	}
	return $fields
}

function Get-FilterSummary($settingsNode) {
	$filters = @()
	foreach ($fi in $settingsNode.SelectNodes("dcsset:filter/dcsset:item", $ns)) {
		$xsiType = $fi.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")

		if ($xsiType -like "*FilterItemGroup*") {
			$groupType = $fi.SelectSingleNode("dcsset:groupType", $ns)
			$gt = if ($groupType) { $groupType.InnerText } else { "And" }
			$subCount = $fi.SelectNodes("dcsset:item", $ns).Count
			$filters += "[Group:$gt $subCount items]"
			continue
		}

		$use = $fi.SelectSingleNode("dcsset:use", $ns)
		$isActive = if ($use -and $use.InnerText -eq "false") { "[ ]" } else { "[x]" }

		$left = $fi.SelectSingleNode("dcsset:left", $ns)
		$comp = $fi.SelectSingleNode("dcsset:comparisonType", $ns)
		$right = $fi.SelectSingleNode("dcsset:right", $ns)
		$pres = $fi.SelectSingleNode("dcsset:presentation", $ns)
		$userSetting = $fi.SelectSingleNode("dcsset:userSettingID", $ns)

		$leftStr = if ($left) { $left.InnerText } else { "?" }
		$compStr = if ($comp) { $comp.InnerText } else { "?" }
		$rightStr = ""
		if ($right) {
			$rightStr = " $($right.InnerText)"
		}

		$presStr = ""
		if ($pres) {
			$pt = Get-MLText $pres
			if ($pt) { $presStr = "  `"$pt`"" }
		}

		$userStr = ""
		if ($userSetting) { $userStr = "  [user]" }

		$filters += "$isActive $leftStr $compStr$rightStr$presStr$userStr"
	}
	return $filters
}

function Build-StructureTree {
	param($itemNode, [string]$prefix, [bool]$isLast, [System.Collections.Generic.List[string]]$outLines)

	$itemType = Get-StructureItemType $itemNode
	$nameNode = $itemNode.SelectSingleNode("dcsset:name", $ns)
	$itemName = if ($nameNode) { $nameNode.InnerText } else { "" }

	$groupFields = Get-GroupFields $itemNode
	$groupStr = if ($groupFields.Count -gt 0) { "[" + ($groupFields -join ", ") + "]" } else { "(detail)" }

	$selFields = Get-SelectionFields $itemNode
	$selStr = if ($selFields.Count -gt 0) { "Selection: " + ($selFields -join ", ") } else { "" }

	$line = ""
	switch ($itemType) {
		"Group" {
			$line = "$itemType $groupStr"
			if ($itemName) { $line = "$itemType `"$itemName`" $groupStr" }
		}
		"Table" {
			$line = "Table"
			if ($itemName) { $line = "Table `"$itemName`"" }
		}
		"Chart" {
			$line = "Chart"
			if ($itemName) { $line = "Chart `"$itemName`"" }
		}
	}

	$outLines.Add("$prefix$line")
	if ($selStr -and $itemType -eq "Group") {
		$outLines.Add("$prefix      $selStr")
	}

	# For Table, show columns and rows
	if ($itemType -eq "Table") {
		$columns = $itemNode.SelectNodes("dcsset:column", $ns)
		$rows = $itemNode.SelectNodes("dcsset:row", $ns)

		foreach ($col in $columns) {
			$colGroup = Get-GroupFields $col
			$colGroupStr = if ($colGroup.Count -gt 0) { "[" + ($colGroup -join ", ") + "]" } else { "(detail)" }
			$colSel = Get-SelectionFields $col
			$colSelStr = if ($colSel.Count -gt 0) { "Selection: " + ($colSel -join ", ") } else { "" }
			$connC = if ($rows.Count -gt 0) { [string][char]0x251C + [string][char]0x2500 + [string][char]0x2500 } else { [string][char]0x2514 + [string][char]0x2500 + [string][char]0x2500 }
			$contC = if ($rows.Count -gt 0) { [string][char]0x2502 + "     " } else { "      " }
			$outLines.Add("$prefix$connC Columns: $colGroupStr")
			if ($colSelStr) { $outLines.Add("$prefix$contC $colSelStr") }
		}

		foreach ($row in $rows) {
			$rowGroup = Get-GroupFields $row
			$rowGroupStr = if ($rowGroup.Count -gt 0) { "[" + ($rowGroup -join ", ") + "]" } else { "(detail)" }
			$rowSel = Get-SelectionFields $row
			$rowSelStr = if ($rowSel.Count -gt 0) { "Selection: " + ($rowSel -join ", ") } else { "" }
			$outLines.Add("$prefix" + [string][char]0x2514 + [string][char]0x2500 + [string][char]0x2500 + " Rows: $rowGroupStr")
			if ($rowSelStr) { $outLines.Add("$prefix      $rowSelStr") }
		}
	}

	# Recurse into nested structure items (for Group)
	if ($itemType -eq "Group") {
		$children = $itemNode.SelectNodes("dcsset:item", $ns)
		for ($i = 0; $i -lt $children.Count; $i++) {
			$child = $children[$i]
			$childType = $child.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			if ($childType -like "*StructureItem*") {
				$last = ($i -eq $children.Count - 1)
				$connector = if ($last) { [string][char]0x2514 + [string][char]0x2500 + " " } else { [string][char]0x251C + [string][char]0x2500 + " " }
				$continuation = if ($last) { "    " } else { [string][char]0x2502 + "   " }
				Build-StructureTree -itemNode $child -prefix "$prefix$continuation" -isLast $last -outLines $outLines
			}
		}
	}
}

# --- Output collector ---

$lines = [System.Collections.Generic.List[string]]::new()

# Determine template name from path
$pathParts = $resolvedPath -split '[/\\]'
$templateName = $resolvedPath
for ($i = $pathParts.Count - 1; $i -ge 0; $i--) {
	if ($pathParts[$i] -eq "Ext" -and $i -ge 1) {
		$templateName = $pathParts[$i - 1]
		break
	}
}

$totalXmlLines = (Get-Content $resolvedPath).Count

# ============================================================
# MODE: overview
# ============================================================
if ($Mode -eq "overview") {

	$lines.Add("=== DCS: $templateName ($totalXmlLines lines) ===")
	$lines.Add("")

	# Sources
	$sources = @()
	foreach ($ds in $root.SelectNodes("s:dataSource", $ns)) {
		$dsName = $ds.SelectSingleNode("s:name", $ns).InnerText
		$dsType = $ds.SelectSingleNode("s:dataSourceType", $ns).InnerText
		$sources += "$dsName ($dsType)"
	}
	$lines.Add("Sources: " + ($sources -join ", "))
	$lines.Add("")

	# Datasets (recursive for Union)
	$lines.Add("Datasets:")
	foreach ($ds in $root.SelectNodes("s:dataSet", $ns)) {
		$dsType = Get-DataSetType $ds
		$dsName = $ds.SelectSingleNode("s:name", $ns).InnerText
		$fieldCount = Get-FieldCount $ds

		switch ($dsType) {
			"Query" {
				$queryLines = Get-QueryLineCount $ds
				$lines.Add("  [Query]  $dsName   $fieldCount fields, query $queryLines lines")
			}
			"Object" {
				$objName = $ds.SelectSingleNode("s:objectName", $ns)
				$objStr = if ($objName) { "  objectName=$($objName.InnerText)" } else { "" }
				$lines.Add("  [Object] $dsName$objStr  $fieldCount fields")
			}
			"Union" {
				$lines.Add("  [Union]  $dsName  $fieldCount fields")
				foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
					$subType = Get-DataSetType $subDs
					$subName = $subDs.SelectSingleNode("s:name", $ns)
					$subNameStr = if ($subName) { $subName.InnerText } else { "?" }
					$subFields = Get-FieldCount $subDs
					switch ($subType) {
						"Query" {
							$subQueryLines = Get-QueryLineCount $subDs
							$lines.Add("    " + [string][char]0x251C + [string][char]0x2500 + " [Query] $subNameStr   $subFields fields, query $subQueryLines lines")
						}
						"Object" {
							$subObjName = $subDs.SelectSingleNode("s:objectName", $ns)
							$subObjStr = if ($subObjName) { "  objectName=$($subObjName.InnerText)" } else { "" }
							$lines.Add("    " + [string][char]0x251C + [string][char]0x2500 + " [Object] $subNameStr$subObjStr  $subFields fields")
						}
						default {
							$lines.Add("    " + [string][char]0x251C + [string][char]0x2500 + " [$subType] $subNameStr  $subFields fields")
						}
					}
				}
			}
		}
	}

	# Links — only dataset pairs (not field-level)
	$links = $root.SelectNodes("s:dataSetLink", $ns)
	if ($links.Count -gt 0) {
		$linkPairs = [ordered]@{}
		foreach ($lnk in $links) {
			$srcDs = $lnk.SelectSingleNode("s:sourceDataSet", $ns).InnerText
			$dstDs = $lnk.SelectSingleNode("s:destinationDataSet", $ns).InnerText
			$key = "$srcDs -> $dstDs"
			if (-not $linkPairs.Contains($key)) { $linkPairs[$key] = 0 }
			$linkPairs[$key] = $linkPairs[$key] + 1
		}
		$linkStrs = @()
		foreach ($key in $linkPairs.Keys) {
			$cnt = $linkPairs[$key]
			if ($cnt -gt 1) { $linkStrs += "$key (${cnt} fields)" }
			else { $linkStrs += $key }
		}
		$lines.Add("Links: " + ($linkStrs -join ", "))
	}

	# Calculated fields — count only
	$calcFields = $root.SelectNodes("s:calculatedField", $ns)
	if ($calcFields.Count -gt 0) {
		$lines.Add("Calculated: $($calcFields.Count)")
	}

	# Totals — count + group flag
	$totalFields = $root.SelectNodes("s:totalField", $ns)
	if ($totalFields.Count -gt 0) {
		$hasGrouped = $false
		$uniquePaths = @{}
		foreach ($tf in $totalFields) {
			$tfPath = $tf.SelectSingleNode("s:dataPath", $ns).InnerText
			$uniquePaths[$tfPath] = $true
			if ($tf.SelectSingleNode("s:group", $ns)) { $hasGrouped = $true }
		}
		$groupNote = if ($hasGrouped) { ", with group formulas" } else { "" }
		if ($uniquePaths.Count -eq $totalFields.Count) {
			$lines.Add("Totals: $($totalFields.Count)$groupNote")
		} else {
			$lines.Add("Totals: $($totalFields.Count) ($($uniquePaths.Count) fields$groupNote)")
		}
	}

	# Templates — count only
	$templates = $root.SelectNodes("s:template", $ns)
	$groupTemplates = $root.SelectNodes("s:groupTemplate", $ns)
	if ($templates.Count -gt 0 -or $groupTemplates.Count -gt 0) {
		$parts = @()
		if ($templates.Count -gt 0) { $parts += "$($templates.Count) templates" }
		if ($groupTemplates.Count -gt 0) { $parts += "$($groupTemplates.Count) group bindings" }
		$lines.Add("Templates: " + ($parts -join ", "))
	}

	# Parameters — split visible/hidden
	$params = $root.SelectNodes("s:parameter", $ns)
	if ($params.Count -gt 0) {
		$visibleNames = @()
		$hiddenCount = 0
		foreach ($p in $params) {
			$pName = $p.SelectSingleNode("s:name", $ns).InnerText
			$useRestrict = $p.SelectSingleNode("s:useRestriction", $ns)
			$isHidden = ($useRestrict -and $useRestrict.InnerText -eq "true")
			if ($isHidden) { $hiddenCount++ } else { $visibleNames += $pName }
		}
		$paramLine = "Params: $($params.Count)"
		if ($hiddenCount -gt 0 -and $visibleNames.Count -gt 0) {
			$paramLine += " ($($visibleNames.Count) visible, $hiddenCount hidden)"
		} elseif ($hiddenCount -eq $params.Count) {
			$paramLine += " (all hidden)"
		}
		if ($visibleNames.Count -gt 0 -and $visibleNames.Count -le 8) {
			$paramLine += ": " + ($visibleNames -join ", ")
		}
		$lines.Add($paramLine)
	} else {
		$lines.Add("Params: (none)")
	}

	$lines.Add("")

	# Variants
	$variants = $root.SelectNodes("s:settingsVariant", $ns)
	if ($variants.Count -gt 0) {
		$lines.Add("Variants:")
		$varIdx = 0
		foreach ($v in $variants) {
			$varIdx++
			$vName = $v.SelectSingleNode("dcsset:name", $ns).InnerText
			$vPres = $v.SelectSingleNode("dcsset:presentation", $ns)
			$vPresStr = ""
			if ($vPres) {
				$pt = Get-MLText $vPres
				if ($pt) { $vPresStr = "  `"$pt`"" }
			}

			$settings = $v.SelectSingleNode("dcsset:settings", $ns)
			$structItems = @()
			if ($settings) {
				foreach ($si in $settings.SelectNodes("dcsset:item", $ns)) {
					$siType = Get-StructureItemType $si
					$groupFields = Get-GroupFields $si
					$groupStr = if ($groupFields.Count -gt 0) { "(" + ($groupFields -join ",") + ")" } else { "(detail)" }
					$structItems += "$siType$groupStr"
				}
			}
			# Compact: if many identical items, show count
			if ($structItems.Count -gt 3) {
				$grouped = $structItems | Group-Object | Sort-Object Count -Descending
				$compactParts = @()
				foreach ($g in $grouped) {
					if ($g.Count -gt 1) { $compactParts += "$($g.Count)x $($g.Name)" }
					else { $compactParts += $g.Name }
				}
				$structItems = $compactParts
			}
			$structStr = if ($structItems.Count -gt 0) { "  " + ($structItems -join ", ") } else { "" }

			$filterCount = 0
			if ($settings) {
				$filterCount = $settings.SelectNodes("dcsset:filter/dcsset:item", $ns).Count
			}
			$filterStr = if ($filterCount -gt 0) { "  $filterCount filters" } else { "" }

			$lines.Add("  [$varIdx] $vName$vPresStr$structStr$filterStr")
		}
	}

	# Hints — suggest next commands
	$lines.Add("")
	$hints = @()
	# Collect query dataset names for hint
	$queryDsNames = @()
	foreach ($ds in $root.SelectNodes("s:dataSet", $ns)) {
		$dsType = Get-DataSetType $ds
		if ($dsType -eq "Query") {
			$queryDsNames += $ds.SelectSingleNode("s:name", $ns).InnerText
		} elseif ($dsType -eq "Union") {
			foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
				if ((Get-DataSetType $subDs) -eq "Query") {
					$sn = $subDs.SelectSingleNode("s:name", $ns)
					if ($sn) { $queryDsNames += $sn.InnerText }
				}
			}
		}
	}
	if ($queryDsNames.Count -eq 1) {
		$hints += "-Mode query             query text"
	} elseif ($queryDsNames.Count -gt 1) {
		$hints += "-Mode query -Name <ds>  query text ($($queryDsNames -join ', '))"
	}
	$hints += "-Mode fields            field details + calculated + totals"
	if ($params.Count -gt 0) {
		$hints += "-Mode params            parameter details"
	}
	if ($variants.Count -eq 1) {
		$hints += "-Mode variant           variant structure"
	} elseif ($variants.Count -gt 1) {
		$hints += "-Mode variant -Name <N> variant structure (1..$($variants.Count))"
	}
	$lines.Add("Next:")
	foreach ($h in $hints) { $lines.Add("  $h") }
}

# ============================================================
# MODE: query
# ============================================================
elseif ($Mode -eq "query") {

	# Find dataset
	$dataSets = $root.SelectNodes("s:dataSet", $ns)
	$targetDs = $null

	if ($Name) {
		# Search by name: prefer nested Query items over parent Union
		# Pass 1: search nested items first
		foreach ($ds in $dataSets) {
			foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
				$subNameNode = $subDs.SelectSingleNode("s:name", $ns)
				if ($subNameNode -and $subNameNode.InnerText -eq $Name) { $targetDs = $subDs; break }
			}
			if ($targetDs) { break }
		}
		# Pass 2: search top-level
		if (-not $targetDs) {
			foreach ($ds in $dataSets) {
				$dsNameNode = $ds.SelectSingleNode("s:name", $ns)
				if ($dsNameNode -and $dsNameNode.InnerText -eq $Name) { $targetDs = $ds; break }
			}
		}
		if (-not $targetDs) {
			Write-Error "Dataset '$Name' not found"
			exit 1
		}
	} else {
		# Take first Query dataset
		foreach ($ds in $dataSets) {
			$dsType = Get-DataSetType $ds
			if ($dsType -eq "Query") { $targetDs = $ds; break }
			if ($dsType -eq "Union") {
				foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
					if ((Get-DataSetType $subDs) -eq "Query") { $targetDs = $subDs; break }
				}
				if ($targetDs) { break }
			}
		}
		if (-not $targetDs) {
			Write-Error "No Query dataset found"
			exit 1
		}
	}

	$queryNode = $targetDs.SelectSingleNode("s:query", $ns)
	if (-not $queryNode) {
		# If this is a Union, list nested query datasets
		$dsType = Get-DataSetType $targetDs
		if ($dsType -eq "Union") {
			$subNames = @()
			foreach ($subDs in $targetDs.SelectNodes("s:item", $ns)) {
				$sn = $subDs.SelectSingleNode("s:name", $ns)
				if ($sn) { $subNames += $sn.InnerText }
			}
			Write-Error "Dataset '$($targetDs.SelectSingleNode("s:name", $ns).InnerText)' is a Union. Specify nested: $($subNames -join ', ')"
		} else {
			Write-Error "Dataset has no query element"
		}
		exit 1
	}

	$rawQuery = Unescape-Xml $queryNode.InnerText
	$dsNameStr = $targetDs.SelectSingleNode("s:name", $ns).InnerText

	# Split into batches
	$batches = @()
	$batchTexts = $rawQuery -split ';\s*\r?\n\s*/{16,}\s*\r?\n'
	foreach ($bt in $batchTexts) {
		$trimmed = $bt.Trim()
		if ($trimmed) { $batches += $trimmed }
	}

	$totalQueryLines = ($rawQuery -split "`n").Count

	if ($batches.Count -le 1) {
		# Single query
		$lines.Add("=== Query: $dsNameStr ($totalQueryLines lines) ===")
		$lines.Add("")
		foreach ($ql in ($rawQuery.Trim() -split "`n")) {
			$lines.Add($ql.TrimEnd())
		}
	} else {
		$lines.Add("=== Query: $dsNameStr ($totalQueryLines lines, $($batches.Count) batches) ===")

		if ($Batch -eq 0) {
			# Show TOC
			$lineNum = 1
			for ($bi = 0; $bi -lt $batches.Count; $bi++) {
				$batchLines = ($batches[$bi] -split "`n")
				$endLine = $lineNum + $batchLines.Count - 1
				# Detect ПОМЕСТИТЬ target
				$target = ""
				foreach ($bl in $batchLines) {
					if ($bl -match '^\s*(?:ПОМЕСТИТЬ|INTO)\s+(\S+)') {
						$target = [char]0x2192 + " " + $Matches[1]
						break
					}
				}
				$lines.Add("  Batch $($bi + 1): lines $lineNum-$endLine  $target")
				$lineNum = $endLine + 3  # +separator
			}
			$lines.Add("")

			# Show all batches
			for ($bi = 0; $bi -lt $batches.Count; $bi++) {
				$lines.Add("--- Batch $($bi + 1) ---")
				foreach ($ql in ($batches[$bi] -split "`n")) {
					$lines.Add($ql.TrimEnd())
				}
				$lines.Add("")
			}
		} else {
			# Show specific batch
			if ($Batch -gt $batches.Count) {
				Write-Error "Batch $Batch not found (total: $($batches.Count))"
				exit 1
			}
			$lines.Add("")
			$lines.Add("--- Batch $Batch ---")
			foreach ($ql in ($batches[$Batch - 1] -split "`n")) {
				$lines.Add($ql.TrimEnd())
			}
		}
	}
}

# ============================================================
# MODE: fields
# ============================================================
elseif ($Mode -eq "fields") {

	$dataSets = $root.SelectNodes("s:dataSet", $ns)

	function Show-DataSetFields($dsNode) {
		$dsType = Get-DataSetType $dsNode
		$dsNameStr = $dsNode.SelectSingleNode("s:name", $ns).InnerText
		$fields = $dsNode.SelectNodes("s:field", $ns)

		$lines.Add("=== Fields: $dsNameStr [$dsType] ($($fields.Count)) ===")
		$lines.Add("  dataPath                          title                  role       restrict     format")

		foreach ($f in $fields) {
			$dp = $f.SelectSingleNode("s:dataPath", $ns)
			$dpStr = if ($dp) { $dp.InnerText } else { "-" }

			$titleNode = $f.SelectSingleNode("s:title", $ns)
			$titleStr = if ($titleNode) { Get-MLText $titleNode } else { "" }
			if (-not $titleStr) { $titleStr = "-" }

			# Role
			$role = $f.SelectSingleNode("s:role", $ns)
			$roleStr = "-"
			if ($role) {
				$roleParts = @()
				foreach ($child in $role.ChildNodes) {
					if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
						$roleParts += $child.LocalName
					}
				}
				if ($roleParts.Count -gt 0) { $roleStr = $roleParts -join "," }
			}

			# UseRestriction
			$restrict = $f.SelectSingleNode("s:useRestriction", $ns)
			$restrictStr = "-"
			if ($restrict) {
				$restrictParts = @()
				foreach ($child in $restrict.ChildNodes) {
					if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
						$restrictParts += $child.LocalName.Substring(0, [Math]::Min(4, $child.LocalName.Length))
					}
				}
				if ($restrictParts.Count -gt 0) { $restrictStr = $restrictParts -join "," }
			}

			# Appearance format
			$formatStr = "-"
			$appearance = $f.SelectSingleNode("s:appearance", $ns)
			if ($appearance) {
				foreach ($appItem in $appearance.SelectNodes("dcscor:item", $ns)) {
					$paramNode = $appItem.SelectSingleNode("dcscor:parameter", $ns)
					$valNode = $appItem.SelectSingleNode("dcscor:value", $ns)
					if ($paramNode -and ($paramNode.InnerText -eq "Формат" -or $paramNode.InnerText -eq "Format") -and $valNode) {
						$formatStr = $valNode.InnerText
					}
				}
			}

			# presentationExpression
			$presExpr = $f.SelectSingleNode("s:presentationExpression", $ns)
			$presStr = ""
			if ($presExpr) { $presStr = "  presExpr" }

			$dpPad = $dpStr.PadRight(35)
			$titlePad = $titleStr.PadRight(22)
			$rolePad = $roleStr.PadRight(10)
			$restrictPad = $restrictStr.PadRight(12)

			$lines.Add("  $dpPad $titlePad $rolePad $restrictPad $formatStr$presStr")
		}
	}

	if ($Name) {
		$found = $false
		foreach ($ds in $dataSets) {
			$dsNameNode = $ds.SelectSingleNode("s:name", $ns)
			if ($dsNameNode -and $dsNameNode.InnerText -eq $Name) {
				Show-DataSetFields $ds
				$found = $true
				break
			}
			foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
				$subNameNode = $subDs.SelectSingleNode("s:name", $ns)
				if ($subNameNode -and $subNameNode.InnerText -eq $Name) {
					Show-DataSetFields $subDs
					$found = $true
					break
				}
			}
			if ($found) { break }
		}
		if (-not $found) {
			Write-Error "Dataset '$Name' not found"
			exit 1
		}
	} else {
		# Show all datasets
		$first = $true
		foreach ($ds in $dataSets) {
			if (-not $first) { $lines.Add("") }
			$first = $false
			Show-DataSetFields $ds

			$dsType = Get-DataSetType $ds
			if ($dsType -eq "Union") {
				foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
					$lines.Add("")
					Show-DataSetFields $subDs
				}
			}
		}
	}

	# Calculated fields
	$calcFields = $root.SelectNodes("s:calculatedField", $ns)
	if ($calcFields.Count -gt 0) {
		$lines.Add("")
		$lines.Add("--- calculated ---")
		foreach ($cf in $calcFields) {
			$cfPath = $cf.SelectSingleNode("s:dataPath", $ns).InnerText
			$cfExpr = $cf.SelectSingleNode("s:expression", $ns).InnerText
			$cfRestrict = $cf.SelectSingleNode("s:useRestriction", $ns)
			$restrictStr = ""
			if ($cfRestrict) {
				$parts = @()
				foreach ($child in $cfRestrict.ChildNodes) {
					if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
						$parts += $child.LocalName.Substring(0, [Math]::Min(4, $child.LocalName.Length))
					}
				}
				if ($parts.Count -gt 0) { $restrictStr = "  restrict:" + ($parts -join ",") }
			}
			$lines.Add("  $cfPath = $cfExpr$restrictStr")
		}
	}

	# Total fields
	$totalFields = $root.SelectNodes("s:totalField", $ns)
	if ($totalFields.Count -gt 0) {
		$lines.Add("")
		$lines.Add("--- totals ---")
		foreach ($tf in $totalFields) {
			$tfPath = $tf.SelectSingleNode("s:dataPath", $ns).InnerText
			$tfExpr = $tf.SelectSingleNode("s:expression", $ns).InnerText
			$tfGroup = $tf.SelectSingleNode("s:group", $ns)
			$groupStr = ""
			if ($tfGroup) { $groupStr = " [group:$($tfGroup.InnerText)]" }
			$lines.Add("  $tfPath = $tfExpr$groupStr")
		}
	}
}

# ============================================================
# MODE: params
# ============================================================
elseif ($Mode -eq "params") {

	$params = $root.SelectNodes("s:parameter", $ns)
	$lines.Add("=== Parameters ($($params.Count)) ===")
	$lines.Add("  Name                            Type                   Default          Visible  Expression")

	foreach ($p in $params) {
		$pName = $p.SelectSingleNode("s:name", $ns).InnerText
		$pType = Get-CompactType $p.SelectSingleNode("s:valueType", $ns)
		if (-not $pType) { $pType = "-" }

		# Default value
		$valNode = $p.SelectSingleNode("s:value", $ns)
		$valStr = "-"
		if ($valNode) {
			$nilAttr = $valNode.GetAttribute("nil", "http://www.w3.org/2001/XMLSchema-instance")
			if ($nilAttr -eq "true") {
				$valStr = "null"
			} else {
				$raw = $valNode.InnerText.Trim()
				if ($raw -eq "0001-01-01T00:00:00") {
					$valStr = "-"
				} elseif ($raw) {
					# Check for StandardPeriod variant
					$variant = $valNode.SelectSingleNode("v8:variant", $ns)
					if ($variant) {
						$valStr = $variant.InnerText
					} else {
						$valStr = $raw
						if ($valStr.Length -gt 15) { $valStr = $valStr.Substring(0, 12) + "..." }
					}
				}
			}
		}

		# Visibility
		$useRestrict = $p.SelectSingleNode("s:useRestriction", $ns)
		$visStr = "yes"
		if ($useRestrict -and $useRestrict.InnerText -eq "true") { $visStr = "hidden" }
		if ($useRestrict -and $useRestrict.InnerText -eq "false") { $visStr = "yes" }

		# Expression
		$exprNode = $p.SelectSingleNode("s:expression", $ns)
		$exprStr = "-"
		if ($exprNode -and $exprNode.InnerText.Trim()) {
			$exprStr = Unescape-Xml $exprNode.InnerText.Trim()
		}

		# availableAsField
		$availField = $p.SelectSingleNode("s:availableAsField", $ns)
		$availStr = ""
		if ($availField -and $availField.InnerText -eq "false") { $availStr = " [noField]" }

		$namePad = $pName.PadRight(33)
		$typePad = $pType.PadRight(22)
		$valPad = $valStr.PadRight(16)
		$visPad = $visStr.PadRight(8)

		$lines.Add("  $namePad $typePad $valPad $visPad $exprStr$availStr")
	}
}

# ============================================================
# MODE: variant
# ============================================================
elseif ($Mode -eq "variant") {

	$variants = $root.SelectNodes("s:settingsVariant", $ns)

	$targetVariant = $null
	if ($Name) {
		# Try by name
		$varIdx = 0
		foreach ($v in $variants) {
			$varIdx++
			$vName = $v.SelectSingleNode("dcsset:name", $ns).InnerText
			if ($vName -eq $Name -or "$varIdx" -eq $Name) {
				$targetVariant = $v
				$matchIdx = $varIdx
				break
			}
		}
		if (-not $targetVariant) {
			Write-Error "Variant '$Name' not found"
			exit 1
		}
	} else {
		# Take first
		$targetVariant = $variants[0]
		$matchIdx = 1
		if (-not $targetVariant) {
			Write-Error "No variants found"
			exit 1
		}
	}

	$vName = $targetVariant.SelectSingleNode("dcsset:name", $ns).InnerText
	$vPres = $targetVariant.SelectSingleNode("dcsset:presentation", $ns)
	$vPresStr = ""
	if ($vPres) {
		$pt = Get-MLText $vPres
		if ($pt) { $vPresStr = " `"$pt`"" }
	}

	$lines.Add("=== Variant [$matchIdx]: $vName$vPresStr ===")

	$settings = $targetVariant.SelectSingleNode("dcsset:settings", $ns)
	if (-not $settings) {
		$lines.Add("  (empty settings)")
	} else {
		# Selection at settings level
		$topSel = Get-SelectionFields $settings
		if ($topSel.Count -gt 0) {
			$lines.Add("")
			$lines.Add("Selection: " + ($topSel -join ", "))
		}

		# Structure
		$structItems = $settings.SelectNodes("dcsset:item", $ns)
		$hasStruct = $false
		foreach ($si in $structItems) {
			$siXsiType = $si.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			if ($siXsiType -like "*StructureItem*") { $hasStruct = $true; break }
		}

		if ($hasStruct) {
			$lines.Add("")
			$lines.Add("Structure:")
			foreach ($si in $structItems) {
				$siXsiType = $si.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
				if ($siXsiType -like "*StructureItem*") {
					Build-StructureTree -itemNode $si -prefix "  " -isLast $false -outLines $lines
				}
			}
		}

		# Filter
		$filters = Get-FilterSummary $settings
		if ($filters.Count -gt 0) {
			$lines.Add("")
			$lines.Add("Filter:")
			foreach ($f in $filters) {
				$lines.Add("  $f")
			}
		}

		# Data parameters
		$dataParams = $settings.SelectNodes("dcsset:dataParameters/dcsset:item", $ns)
		if ($dataParams.Count -gt 0) {
			$dpStrs = @()
			foreach ($dp in $dataParams) {
				$dpParam = $dp.SelectSingleNode("dcscor:parameter", $ns)
				$dpVal = $dp.SelectSingleNode("dcscor:value", $ns)
				if ($dpParam -and $dpVal) {
					$dpStrs += "$($dpParam.InnerText)=`"$($dpVal.InnerText)`""
				}
			}
			if ($dpStrs.Count -gt 0) {
				$lines.Add("")
				$lines.Add("DataParams: " + ($dpStrs -join ", "))
			}
		}

		# Output parameters
		$outParams = $settings.SelectNodes("dcsset:outputParameters/dcscor:item", $ns)
		if ($outParams.Count -gt 0) {
			$opStrs = @()
			foreach ($op in $outParams) {
				$opParam = $op.SelectSingleNode("dcscor:parameter", $ns)
				$opVal = $op.SelectSingleNode("dcscor:value", $ns)
				if ($opParam -and $opVal) {
					$paramName = $opParam.InnerText
					$paramVal = $opVal.InnerText
					# Shorten known long names
					switch ($paramName) {
						"МакетОформления" { $opStrs += "style=$paramVal" }
						"РасположениеПолейГруппировки" { $opStrs += "groups=$paramVal" }
						"ГоризонтальноеРасположениеОбщихИтогов" { $opStrs += "totalsH=$paramVal" }
						"ВертикальноеРасположениеОбщихИтогов" { $opStrs += "totalsV=$paramVal" }
						"ВыводитьЗаголовок" { $opStrs += "header=$paramVal" }
						"ВыводитьОтбор" { $opStrs += "filter=$paramVal" }
						"ВыводитьПараметрыДанных" { $opStrs += "dataParams=$paramVal" }
						"РасположениеРеквизитов" { $opStrs += "attrs=$paramVal" }
						default { $opStrs += "$paramName=$paramVal" }
					}
				}
			}
			if ($opStrs.Count -gt 0) {
				$lines.Add("")
				$lines.Add("Output: " + ($opStrs -join "  "))
			}
		}
	}
}

# --- Output ---

$result = $lines.ToArray()
$totalLines = $result.Count

# OutFile
if ($OutFile) {
	$utf8Bom = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllLines((Join-Path (Get-Location) $OutFile), $result, $utf8Bom)
	Write-Host "Written $totalLines lines to $OutFile"
	exit 0
}

# Pagination
if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$result = $result[$Offset..($totalLines - 1)]
}

if ($result.Count -gt $Limit) {
	$shown = $result[0..($Limit - 1)]
	foreach ($l in $shown) { Write-Host $l }
	Write-Host ""
	Write-Host "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
} else {
	foreach ($l in $result) { Write-Host $l }
}
