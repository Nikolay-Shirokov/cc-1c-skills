# skd-info v1.0 — Analyze 1C DCS structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)]
	[string]$TemplatePath,
	[ValidateSet("overview", "query", "fields", "links", "calculated", "resources", "params", "variant", "trace", "templates")]
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
$ns.AddNamespace("dcsat", "http://v8.1c.ru/8.1/data-composition-system/area-template")

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
			$lines.Add("Resources: $($totalFields.Count)$groupNote")
		} else {
			$lines.Add("Resources: $($totalFields.Count) ($($uniquePaths.Count) fields$groupNote)")
		}
	}

	# Templates — count with binding types
	$tplDefs = $root.SelectNodes("s:template", $ns)
	$fieldTpls = $root.SelectNodes("s:fieldTemplate", $ns)
	$groupTpls = $root.SelectNodes("s:groupTemplate", $ns)
	$groupHeaderTpls = $root.SelectNodes("s:groupHeaderTemplate", $ns)
	$groupFooterTpls = $root.SelectNodes("s:groupFooterTemplate", $ns)
	$totalBindings = $fieldTpls.Count + $groupTpls.Count + $groupHeaderTpls.Count + $groupFooterTpls.Count
	if ($tplDefs.Count -gt 0) {
		$parts = @()
		if ($fieldTpls.Count -gt 0) { $parts += "$($fieldTpls.Count) field" }
		$grpCount = $groupTpls.Count + $groupHeaderTpls.Count + $groupFooterTpls.Count
		if ($grpCount -gt 0) { $parts += "$grpCount group" }
		$lines.Add("Templates: $($tplDefs.Count) defined ($($parts -join ', ') bindings)")
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
	$hints += "-Mode fields            field tables by dataset"
	$linkCount = $root.SelectNodes("s:dataSetLink", $ns).Count
	if ($linkCount -gt 0) {
		$hints += "-Mode links             dataset connections ($linkCount)"
	}
	$calcCount = $root.SelectNodes("s:calculatedField", $ns).Count
	$totalCount = $root.SelectNodes("s:totalField", $ns).Count
	if ($calcCount -gt 0) {
		$hints += "-Mode calculated        calculated field expressions ($calcCount)"
	}
	if ($totalCount -gt 0) {
		$hints += "-Mode resources         resource aggregation ($totalCount)"
	}
	if ($params.Count -gt 0) {
		$hints += "-Mode params            parameter details"
	}
	if ($variants.Count -eq 1) {
		$hints += "-Mode variant           variant structure"
	} elseif ($variants.Count -gt 1) {
		$hints += "-Mode variant -Name <N> variant structure (1..$($variants.Count))"
	}
	if ($tplDefs.Count -gt 0) {
		$hints += "-Mode templates         template bindings and expressions"
	}
	$hints += "-Mode trace -Name <f>   trace field origin (by name or title)"
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
		# Detail for specific field by dataPath — search all datasets
		$found = $false
		$matchedIn = @()

		function Collect-FieldInfo($dsNode) {
			$dsType = Get-DataSetType $dsNode
			$dsNameStr = $dsNode.SelectSingleNode("s:name", $ns).InnerText
			foreach ($f in $dsNode.SelectNodes("s:field", $ns)) {
				$dp = $f.SelectSingleNode("s:dataPath", $ns)
				if (-not $dp -or $dp.InnerText -ne $Name) { continue }

				$info = @{ dataset = "$dsNameStr [$dsType]" }

				$titleNode = $f.SelectSingleNode("s:title", $ns)
				$info.title = if ($titleNode) { Get-MLText $titleNode } else { "" }

				# ValueType
				$vt = $f.SelectSingleNode("s:valueType", $ns)
				$info.type = if ($vt) { Get-CompactType $vt } else { "" }

				# Role
				$role = $f.SelectSingleNode("s:role", $ns)
				$roleParts = @()
				if ($role) {
					foreach ($child in $role.ChildNodes) {
						if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
							$roleParts += $child.LocalName
						}
					}
				}
				$info.role = $roleParts -join ", "

				# UseRestriction
				$restrict = $f.SelectSingleNode("s:useRestriction", $ns)
				$restrictParts = @()
				if ($restrict) {
					foreach ($child in $restrict.ChildNodes) {
						if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
							$restrictParts += $child.LocalName
						}
					}
				}
				$info.restrict = $restrictParts -join ", "

				# Format
				$formatStr = ""
				$appearance = $f.SelectSingleNode("s:appearance", $ns)
				if ($appearance) {
					foreach ($appItem in $appearance.SelectNodes("dcscor:item", $ns)) {
						$pn = $appItem.SelectSingleNode("dcscor:parameter", $ns)
						$vn = $appItem.SelectSingleNode("dcscor:value", $ns)
						if ($pn -and ($pn.InnerText -eq "Формат" -or $pn.InnerText -eq "Format") -and $vn) {
							$formatStr = $vn.InnerText
						}
					}
				}
				$info.format = $formatStr

				# PresentationExpression
				$presExpr = $f.SelectSingleNode("s:presentationExpression", $ns)
				$info.presExpr = if ($presExpr) { $presExpr.InnerText } else { "" }

				return $info
			}
			return $null
		}

		# Search all datasets and nested items
		$fieldInfos = @()
		foreach ($ds in $dataSets) {
			$info = Collect-FieldInfo $ds
			if ($info) { $fieldInfos += $info }
			$dsType = Get-DataSetType $ds
			if ($dsType -eq "Union") {
				foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
					$info = Collect-FieldInfo $subDs
					if ($info) { $fieldInfos += $info }
				}
			}
		}

		if ($fieldInfos.Count -eq 0) {
			Write-Error "Field '$Name' not found in any dataset"
			exit 1
		}

		# Use first match for detail (they usually share the same properties)
		$first = $fieldInfos[0]
		$titleStr = if ($first.title) { " `"$($first.title)`"" } else { "" }
		$lines.Add("=== Field: $Name$titleStr ===")
		$lines.Add("")

		# Datasets
		$dsList = ($fieldInfos | ForEach-Object { $_.dataset }) -join ", "
		$lines.Add("Dataset: $dsList")

		if ($first.type) { $lines.Add("Type: $($first.type)") }
		if ($first.role) { $lines.Add("Role: $($first.role)") }
		if ($first.restrict) { $lines.Add("Restrict: $($first.restrict)") }
		if ($first.format) { $lines.Add("Format: $($first.format)") }
		if ($first.presExpr) {
			$lines.Add("PresentationExpression:")
			foreach ($el in ($first.presExpr -split "`n")) { $lines.Add("  $($el.TrimEnd())") }
		}
	} else {
		# Compact map: field names per dataset
		$lines.Add("=== Fields map ===")

		function Show-DataSetFieldMap($dsNode, $indent) {
			$dsType = Get-DataSetType $dsNode
			$dsNameStr = $dsNode.SelectSingleNode("s:name", $ns).InnerText
			$fields = $dsNode.SelectNodes("s:field", $ns)
			$fieldNames = @()
			foreach ($f in $fields) {
				$dp = $f.SelectSingleNode("s:dataPath", $ns)
				if ($dp) { $fieldNames += $dp.InnerText }
			}
			$nameList = $fieldNames -join ", "
			if ($nameList.Length -gt 100) {
				$nameList = $nameList.Substring(0, 97) + "..."
			}
			$lines.Add("$indent$dsNameStr [$dsType] ($($fields.Count)): $nameList")
		}

		foreach ($ds in $dataSets) {
			Show-DataSetFieldMap $ds ""
			$dsType = Get-DataSetType $ds
			if ($dsType -eq "Union") {
				foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
					Show-DataSetFieldMap $subDs "  "
				}
			}
		}

		$lines.Add("")
		$lines.Add("Use -Name <field> for details.")
	}
}

# ============================================================
# MODE: links
# ============================================================
elseif ($Mode -eq "links") {

	$links = $root.SelectNodes("s:dataSetLink", $ns)
	if ($links.Count -eq 0) {
		$lines.Add("(no links)")
	} else {
		$lines.Add("=== Links ($($links.Count)) ===")
		$lines.Add("")
		# Group by source->dest pair
		$currentPair = ""
		foreach ($lnk in $links) {
			$srcDs = $lnk.SelectSingleNode("s:sourceDataSet", $ns).InnerText
			$dstDs = $lnk.SelectSingleNode("s:destinationDataSet", $ns).InnerText
			$srcExpr = $lnk.SelectSingleNode("s:sourceExpression", $ns).InnerText
			$dstExpr = $lnk.SelectSingleNode("s:destinationExpression", $ns).InnerText
			$paramNode = $lnk.SelectSingleNode("s:parameter", $ns)
			$paramListNode = $lnk.SelectSingleNode("s:parameterListAllowed", $ns)

			$pair = "$srcDs -> $dstDs"
			if ($pair -ne $currentPair) {
				if ($currentPair) { $lines.Add("") }
				$lines.Add("$pair :")
				$currentPair = $pair
			}

			$paramStr = ""
			if ($paramNode) { $paramStr = "  param=$($paramNode.InnerText)" }

			$lines.Add("  $srcExpr -> $dstExpr$paramStr")
		}
	}
}

# ============================================================
# MODE: calculated
# ============================================================
elseif ($Mode -eq "calculated") {

	$calcFields = $root.SelectNodes("s:calculatedField", $ns)
	if ($calcFields.Count -eq 0) {
		$lines.Add("(no calculated fields)")
	} elseif ($Name) {
		$found = $false
		foreach ($cf in $calcFields) {
			$cfPath = $cf.SelectSingleNode("s:dataPath", $ns).InnerText
			if ($cfPath -eq $Name) {
				$lines.Add("=== Calculated: $cfPath ===")
				$lines.Add("")

				$cfExpr = $cf.SelectSingleNode("s:expression", $ns).InnerText
				$lines.Add("Expression:")
				foreach ($el in ($cfExpr -split "`n")) { $lines.Add("  $($el.TrimEnd())") }

				$cfTitle = $cf.SelectSingleNode("s:title", $ns)
				if ($cfTitle) {
					$t = Get-MLText $cfTitle
					if ($t) { $lines.Add("Title: $t") }
				}

				$cfRestrict = $cf.SelectSingleNode("s:useRestriction", $ns)
				if ($cfRestrict) {
					$parts = @()
					foreach ($child in $cfRestrict.ChildNodes) {
						if ($child.NodeType -eq "Element" -and $child.InnerText -eq "true") {
							$parts += $child.LocalName
						}
					}
					if ($parts.Count -gt 0) { $lines.Add("Restrict: $($parts -join ', ')") }
				}

				$found = $true
				break
			}
		}
		if (-not $found) {
			Write-Error "Calculated field '$Name' not found"
			exit 1
		}
	} else {
		# Map
		$lines.Add("=== Calculated fields ($($calcFields.Count)) ===")
		foreach ($cf in $calcFields) {
			$cfPath = $cf.SelectSingleNode("s:dataPath", $ns).InnerText
			$cfTitle = $cf.SelectSingleNode("s:title", $ns)
			$titleStr = ""
			if ($cfTitle) {
				$t = Get-MLText $cfTitle
				if ($t -and $t -ne $cfPath) { $titleStr = "  `"$t`"" }
			}
			$lines.Add("  $cfPath$titleStr")
		}
		$lines.Add("")
		$lines.Add("Use -Name <field> for full expression.")
	}
}

# ============================================================
# MODE: resources
# ============================================================
elseif ($Mode -eq "resources") {

	$totalFields = $root.SelectNodes("s:totalField", $ns)
	if ($totalFields.Count -eq 0) {
		$lines.Add("(no resources)")
	} elseif ($Name) {
		$matched = @()
		foreach ($tf in $totalFields) {
			$tfPath = $tf.SelectSingleNode("s:dataPath", $ns).InnerText
			if ($tfPath -eq $Name) { $matched += $tf }
		}
		if ($matched.Count -eq 0) {
			Write-Error "Resource '$Name' not found"
			exit 1
		}
		$lines.Add("=== Resource: $Name ===")
		$lines.Add("")
		foreach ($tf in $matched) {
			$tfExpr = $tf.SelectSingleNode("s:expression", $ns).InnerText
			$tfGroup = $tf.SelectSingleNode("s:group", $ns)
			$groupStr = "(overall)"
			if ($tfGroup) { $groupStr = $tfGroup.InnerText }
			$lines.Add("  [$groupStr] $tfExpr")
		}
	} else {
		# Map
		$lines.Add("=== Resources ($($totalFields.Count)) ===")
		$resMap = [ordered]@{}
		foreach ($tf in $totalFields) {
			$tfPath = $tf.SelectSingleNode("s:dataPath", $ns).InnerText
			$tfGroup = $tf.SelectSingleNode("s:group", $ns)
			if (-not $resMap.Contains($tfPath)) {
				$resMap[$tfPath] = @{ hasGroup = $false }
			}
			if ($tfGroup) { $resMap[$tfPath].hasGroup = $true }
		}
		foreach ($key in $resMap.Keys) {
			$groupMark = if ($resMap[$key].hasGroup) { " *" } else { "" }
			$lines.Add("  $key$groupMark")
		}
		$lines.Add("")
		$lines.Add("  * = has group-level formulas")
		$lines.Add("")
		$lines.Add("Use -Name <field> for full formula.")
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

	if (-not $Name) {
		# --- Variant list (map) ---
		if ($variants.Count -eq 0) {
			$lines.Add("=== Variants: (none) ===")
		} else {
			$lines.Add("=== Variants ($($variants.Count)) ===")
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

				# Selection fields
				$selFields = @()
				if ($settings) { $selFields = Get-SelectionFields $settings }
				$selStr = if ($selFields.Count -gt 0) { "  sel: " + ($selFields -join ", ") } else { "" }

				$lines.Add("  [$varIdx] $vName$vPresStr$structStr$filterStr")
				if ($selStr) { $lines.Add("        $selStr") }
			}
		}
	} else {
		# --- Variant detail ---

	$targetVariant = $null
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
		Write-Error "Variant '$Name' not found. Use -Mode variant without -Name to see list."
		exit 1
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
	} # end else (variant detail)
}

# ============================================================
# MODE: trace
# ============================================================
elseif ($Mode -eq "trace") {

	if (-not $Name) {
		Write-Error "Trace mode requires -Name <field_name_or_title>"
		exit 1
	}

	# --- Build field index ---

	$dsFields = @{}     # dataPath -> @{ datasets=@(); title="" }
	$calcFields = @{}   # dataPath -> @{ expression=""; title="" }
	$resFields = @{}    # dataPath -> @(@{ expression=""; group="" })
	$titleMap = @{}     # title -> dataPath

	# Scan dataset fields (including nested Union items)
	$dataSets = $root.SelectNodes("s:dataSet", $ns)
	foreach ($ds in $dataSets) {
		$dsName = $ds.SelectSingleNode("s:name", $ns).InnerText
		$dsType = Get-DataSetType $ds

		foreach ($f in $ds.SelectNodes("s:field", $ns)) {
			$dp = $f.SelectSingleNode("s:dataPath", $ns)
			if (-not $dp) { continue }
			$dpStr = $dp.InnerText
			if (-not $dsFields.ContainsKey($dpStr)) {
				$dsFields[$dpStr] = @{ datasets = @(); title = "" }
			}
			$dsFields[$dpStr].datasets += "$dsName [$dsType]"
			$titleNode = $f.SelectSingleNode("s:title", $ns)
			if ($titleNode) {
				$t = Get-MLText $titleNode
				if ($t) {
					if (-not $dsFields[$dpStr].title) { $dsFields[$dpStr].title = $t }
					if (-not $titleMap.ContainsKey($t)) { $titleMap[$t] = $dpStr }
				}
			}
		}

		if ($dsType -eq "Union") {
			foreach ($subDs in $ds.SelectNodes("s:item", $ns)) {
				$subName = $subDs.SelectSingleNode("s:name", $ns).InnerText
				$subType = Get-DataSetType $subDs
				foreach ($f in $subDs.SelectNodes("s:field", $ns)) {
					$dp = $f.SelectSingleNode("s:dataPath", $ns)
					if (-not $dp) { continue }
					$dpStr = $dp.InnerText
					if (-not $dsFields.ContainsKey($dpStr)) {
						$dsFields[$dpStr] = @{ datasets = @(); title = "" }
					}
					$dsFields[$dpStr].datasets += "$subName [$subType]"
					$titleNode = $f.SelectSingleNode("s:title", $ns)
					if ($titleNode) {
						$t = Get-MLText $titleNode
						if ($t) {
							if (-not $dsFields[$dpStr].title) { $dsFields[$dpStr].title = $t }
							if (-not $titleMap.ContainsKey($t)) { $titleMap[$t] = $dpStr }
						}
					}
				}
			}
		}
	}

	# Scan calculated fields
	foreach ($cf in $root.SelectNodes("s:calculatedField", $ns)) {
		$dpStr = $cf.SelectSingleNode("s:dataPath", $ns).InnerText
		$expr = $cf.SelectSingleNode("s:expression", $ns).InnerText
		$cfTitle = $cf.SelectSingleNode("s:title", $ns)
		$t = ""
		if ($cfTitle) { $t = Get-MLText $cfTitle }
		$calcFields[$dpStr] = @{ expression = $expr; title = $t }
		if ($t -and -not $titleMap.ContainsKey($t)) { $titleMap[$t] = $dpStr }
	}

	# Scan resources
	foreach ($tf in $root.SelectNodes("s:totalField", $ns)) {
		$dpStr = $tf.SelectSingleNode("s:dataPath", $ns).InnerText
		$expr = $tf.SelectSingleNode("s:expression", $ns).InnerText
		$grp = $tf.SelectSingleNode("s:group", $ns)
		$groupStr = "(overall)"
		if ($grp) { $groupStr = $grp.InnerText }
		if (-not $resFields.ContainsKey($dpStr)) { $resFields[$dpStr] = @() }
		$resFields[$dpStr] += @{ expression = $expr; group = $groupStr }
	}

	# --- Resolve name: try dataPath, then exact title, then substring title ---
	$targetPath = $Name
	$knownPaths = @()
	$knownPaths += $dsFields.Keys
	$knownPaths += $calcFields.Keys
	$knownPaths += $resFields.Keys
	$isKnown = $knownPaths -contains $Name

	if (-not $isKnown) {
		if ($titleMap.ContainsKey($Name)) {
			$targetPath = $titleMap[$Name]
		} else {
			# Substring match in titles
			$matchedTitle = $null
			foreach ($key in $titleMap.Keys) {
				if ($key -like "*$Name*") {
					$matchedTitle = $key
					break
				}
			}
			if ($matchedTitle) {
				$targetPath = $titleMap[$matchedTitle]
			} else {
				Write-Error "Field '$Name' not found by dataPath or title"
				exit 1
			}
		}
	}

	# --- Build output ---
	$title = ""
	if ($calcFields.ContainsKey($targetPath) -and $calcFields[$targetPath].title) {
		$title = $calcFields[$targetPath].title
	} elseif ($dsFields.ContainsKey($targetPath) -and $dsFields[$targetPath].title) {
		$title = $dsFields[$targetPath].title
	}
	$titleStr = if ($title) { " `"$title`"" } else { "" }

	$lines.Add("=== Trace: $targetPath$titleStr ===")
	$lines.Add("")

	# Dataset origin
	if ($dsFields.ContainsKey($targetPath)) {
		$uniqueDs = $dsFields[$targetPath].datasets | Select-Object -Unique
		$lines.Add("Dataset: $($uniqueDs -join ', ')")
	} else {
		$lines.Add("Dataset: (schema-level only, not in dataset fields)")
	}

	# Calculated field
	if ($calcFields.ContainsKey($targetPath)) {
		$cf = $calcFields[$targetPath]
		$lines.Add("")
		$lines.Add("Calculated:")
		foreach ($el in ($cf.expression -split "`n")) { $lines.Add("  $($el.TrimEnd())") }

		# Extract operands: find known field names in expression
		$operands = @()
		$allKnown = @()
		$allKnown += $dsFields.Keys
		$allKnown += $calcFields.Keys
		$allKnown = $allKnown | Select-Object -Unique | Where-Object { $_ -ne $targetPath }
		# Sort by length descending to match longer names first
		$allKnown = $allKnown | Sort-Object -Property Length -Descending

		foreach ($fieldName in $allKnown) {
			$escaped = [regex]::Escape($fieldName)
			if ($cf.expression -match "(?<![а-яА-ЯёЁa-zA-Z0-9_.])$escaped(?![а-яА-ЯёЁa-zA-Z0-9_.])") {
				$operands += $fieldName
			}
		}

		if ($operands.Count -gt 0) {
			$lines.Add("  Operands:")
			foreach ($op in $operands) {
				if ($calcFields.ContainsKey($op)) {
					$lines.Add("    $op -> calculated")
				} elseif ($dsFields.ContainsKey($op)) {
					$opDs = ($dsFields[$op].datasets | Select-Object -Unique) -join ", "
					$lines.Add("    $op -> $opDs")
				} else {
					$lines.Add("    $op")
				}
			}
		}
	}

	# Resource
	if ($resFields.ContainsKey($targetPath)) {
		$lines.Add("")
		$lines.Add("Resource:")
		foreach ($r in $resFields[$targetPath]) {
			$lines.Add("  [$($r.group)] $($r.expression)")
		}
	}

	# Simple dataset field, no calc/resource
	if (-not $calcFields.ContainsKey($targetPath) -and -not $resFields.ContainsKey($targetPath)) {
		if ($dsFields.ContainsKey($targetPath)) {
			$lines.Add("")
			$lines.Add("(direct dataset field, no calculated expression or resource)")
		}
	}
}

# ============================================================
# MODE: templates
# ============================================================
elseif ($Mode -eq "templates") {

	# --- Helper: check if expression is trivial ---
	function Is-TrivialExpr([string]$paramName, [string]$expr) {
		$e = $expr.Trim()
		$n = $paramName.Trim()
		if ($e -eq $n) { return $true }
		if ($e -eq "Представление($n)") { return $true }
		return $false
	}

	# --- Helper: parse template content (rows/cells) ---
	function Get-TemplateContent([System.Xml.XmlNode]$tplNode) {
		$innerT = $tplNode.SelectSingleNode("s:template", $ns)
		if (-not $innerT) { return @{ rows = 0; cells = @(); params = @(); nonTrivial = @() } }

		$rows = $innerT.SelectNodes("dcsat:item", $ns)
		$rowCount = $rows.Count
		$cellData = [System.Collections.ArrayList]::new()
		$rowIdx = 0
		foreach ($row in $rows) {
			$rowIdx++
			$rowCells = [System.Collections.ArrayList]::new()
			foreach ($cell in $row.SelectNodes("dcsat:tableCell", $ns)) {
				$field = $cell.SelectSingleNode("dcsat:item", $ns)
				if (-not $field) {
					[void]$rowCells.Add("(empty)")
					continue
				}
				$val = $field.SelectSingleNode("dcsat:value", $ns)
				if (-not $val) {
					[void]$rowCells.Add("(empty)")
					continue
				}
				$xsiType = $val.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
				if ($xsiType -like "*LocalStringType*") {
					$text = Get-MLText $val
					if ($text) { [void]$rowCells.Add("`"$text`"") }
					else { [void]$rowCells.Add("(empty)") }
				} elseif ($xsiType -like "*Parameter*") {
					[void]$rowCells.Add("{$($val.InnerText)}")
				} else {
					[void]$rowCells.Add("(?)")
				}
			}
			[void]$cellData.Add(@{ row = $rowIdx; cells = $rowCells.ToArray() })
		}

		# Parameters
		$paramNodes = $tplNode.SelectNodes("s:parameter", $ns)
		$paramList = [System.Collections.ArrayList]::new()
		$nonTrivialList = [System.Collections.ArrayList]::new()
		foreach ($p in $paramNodes) {
			$pn = $p.SelectSingleNode("dcsat:name", $ns)
			$pe = $p.SelectSingleNode("dcsat:expression", $ns)
			if ($pn -and $pe) {
				$pName = $pn.InnerText
				$pExpr = $pe.InnerText
				[void]$paramList.Add(@{ name = $pName; expression = $pExpr })
				if (-not (Is-TrivialExpr $pName $pExpr)) {
					[void]$nonTrivialList.Add(@{ name = $pName; expression = $pExpr })
				}
			}
		}

		return @{
			rows = $rowCount
			cells = $cellData.ToArray()
			params = $paramList.ToArray()
			nonTrivial = $nonTrivialList.ToArray()
		}
	}

	# --- Build template name -> node index ---
	$tplIndex = @{}
	foreach ($t in $root.SelectNodes("s:template", $ns)) {
		$tn = $t.SelectSingleNode("s:name", $ns)
		if ($tn) { $tplIndex[$tn.InnerText] = $t }
	}

	# --- Parse bindings ---
	# Group bindings: groupTemplate + groupHeaderTemplate
	$groupBindings = [ordered]@{}  # groupName -> @{ bindings = @(@{type; tplName; tplNode}) }

	foreach ($gt in $root.SelectNodes("s:groupTemplate", $ns)) {
		$gn = $gt.SelectSingleNode("s:groupName", $ns)
		$gf = $gt.SelectSingleNode("s:groupField", $ns)
		$gnStr = if ($gn) { $gn.InnerText } elseif ($gf) { $gf.InnerText } else { "(default)" }
		$tt = $gt.SelectSingleNode("s:templateType", $ns)
		$tn = $gt.SelectSingleNode("s:template", $ns)
		$ttStr = if ($tt) { $tt.InnerText } else { "-" }
		$tnStr = if ($tn) { $tn.InnerText } else { "-" }

		if (-not $groupBindings.Contains($gnStr)) {
			$groupBindings[$gnStr] = [System.Collections.ArrayList]::new()
		}
		[void]$groupBindings[$gnStr].Add(@{ type = $ttStr; tplName = $tnStr })
	}

	foreach ($ght in $root.SelectNodes("s:groupHeaderTemplate", $ns)) {
		$gn = $ght.SelectSingleNode("s:groupName", $ns)
		$gf = $ght.SelectSingleNode("s:groupField", $ns)
		$gnStr = if ($gn) { $gn.InnerText } elseif ($gf) { $gf.InnerText } else { "(default)" }
		$tt = $ght.SelectSingleNode("s:templateType", $ns)
		$tn = $ght.SelectSingleNode("s:template", $ns)
		$ttStr = if ($tt) { "GroupHeader" } else { "GroupHeader" }
		$tnStr = if ($tn) { $tn.InnerText } else { "-" }

		if (-not $groupBindings.Contains($gnStr)) {
			$groupBindings[$gnStr] = [System.Collections.ArrayList]::new()
		}
		[void]$groupBindings[$gnStr].Add(@{ type = $ttStr; tplName = $tnStr })
	}

	foreach ($gft in $root.SelectNodes("s:groupFooterTemplate", $ns)) {
		$gn = $gft.SelectSingleNode("s:groupName", $ns)
		$gf = $gft.SelectSingleNode("s:groupField", $ns)
		$gnStr = if ($gn) { $gn.InnerText } elseif ($gf) { $gf.InnerText } else { "(default)" }
		$tn = $gft.SelectSingleNode("s:template", $ns)
		$tnStr = if ($tn) { $tn.InnerText } else { "-" }

		if (-not $groupBindings.Contains($gnStr)) {
			$groupBindings[$gnStr] = [System.Collections.ArrayList]::new()
		}
		[void]$groupBindings[$gnStr].Add(@{ type = "GroupFooter"; tplName = $tnStr })
	}

	# Field bindings: fieldTemplate
	$fieldBindings = [ordered]@{}  # fieldName -> tplName
	$fieldNonTrivial = [System.Collections.ArrayList]::new()

	foreach ($ft in $root.SelectNodes("s:fieldTemplate", $ns)) {
		$fn = $ft.SelectSingleNode("s:field", $ns)
		$tn = $ft.SelectSingleNode("s:template", $ns)
		if ($fn -and $tn) {
			$fName = $fn.InnerText
			$tName = $tn.InnerText
			$fieldBindings[$fName] = $tName
			# Check params for non-trivial expressions
			if ($tplIndex.ContainsKey($tName)) {
				$content = Get-TemplateContent $tplIndex[$tName]
				foreach ($nt in $content.nonTrivial) {
					[void]$fieldNonTrivial.Add(@{ field = $fName; template = $tName; name = $nt.name; expression = $nt.expression })
				}
			}
		}
	}

	$totalTpl = $tplIndex.Count
	$fieldCount = $fieldBindings.Count
	$groupBindCount = 0
	foreach ($k in $groupBindings.Keys) { $groupBindCount += $groupBindings[$k].Count }

	if (-not $Name) {
		# --- MAP mode ---
		$lines.Add("=== Templates ($totalTpl defined: $fieldCount field, $groupBindCount group) ===")

		# Field bindings
		if ($fieldBindings.Count -gt 0) {
			$lines.Add("")
			if ($fieldNonTrivial.Count -eq 0) {
				$fieldNames = @($fieldBindings.Keys)
				if ($fieldNames.Count -le 8) {
					$lines.Add("Field bindings ($fieldCount): $($fieldNames -join ', ')  (all trivial)")
				} else {
					$lines.Add("Field bindings ($fieldCount): (all trivial)")
					$lines.Add("  $($fieldNames[0..7] -join ', '), ...")
				}
			} else {
				$trivialCount = $fieldBindings.Count - ($fieldNonTrivial | Select-Object -ExpandProperty field -Unique).Count
				$lines.Add("Field bindings ($fieldCount, $trivialCount trivial):")
				foreach ($nt in $fieldNonTrivial) {
					$lines.Add("  $($nt.field): $($nt.name) = $($nt.expression)")
				}
			}
		}

		# Group bindings
		if ($groupBindings.Count -gt 0) {
			$lines.Add("")
			$lines.Add("Group bindings ($groupBindCount):")
			foreach ($gName in $groupBindings.Keys) {
				$bindings = $groupBindings[$gName]
				$parts = @()
				foreach ($b in $bindings) {
					$info = "$($b.type) -> $($b.tplName)"
					if ($tplIndex.ContainsKey($b.tplName)) {
						$content = Get-TemplateContent $tplIndex[$b.tplName]
						# Check if any cell has content
						$hasContent = $false
						foreach ($r in $content.cells) {
							foreach ($c in $r.cells) {
								if ($c -ne "(empty)") { $hasContent = $true; break }
							}
							if ($hasContent) { break }
						}
						$info += " ($($content.rows) rows"
						if ($content.params.Count -gt 0) { $info += ", $($content.params.Count) params" }
						$info += ")"
						if (-not $hasContent -and $content.params.Count -eq 0) {
							$info += " spacer"
						}
						if ($content.nonTrivial.Count -gt 0) {
							$ntNames = ($content.nonTrivial | ForEach-Object { $_.name }) -join ', '
							$info += " *$ntNames"
						}
					}
					$parts += $info
				}
				$lines.Add("  $gName")
				foreach ($p in $parts) {
					$lines.Add("    $p")
				}
			}
		}

		if ($fieldBindings.Count -gt 0 -or $groupBindings.Count -gt 0) {
			$lines.Add("")
			$lines.Add("Use -Name <group|field> for template details.")
		}
	} else {
		# --- DETAIL mode ---
		$found = $false

		# Check group bindings first
		if ($groupBindings.Contains($Name)) {
			$found = $true
			$bindings = $groupBindings[$Name]
			$lines.Add("=== Templates: $Name ===")
			foreach ($b in $bindings) {
				$lines.Add("")
				$tName = $b.tplName
				if (-not $tplIndex.ContainsKey($tName)) {
					$lines.Add("$($b.type) -> $tName  (template not found)")
					continue
				}
				$content = Get-TemplateContent $tplIndex[$tName]
				$cellCount = 0
				foreach ($r in $content.cells) { $cellCount += $r.cells.Count }
				$lines.Add("$($b.type) -> $tName [$($content.rows) rows, $cellCount cells]:")

				foreach ($r in $content.cells) {
					$cellStr = $r.cells -join " | "
					$lines.Add("  Row $($r.row): $cellStr")
				}

				if ($content.nonTrivial.Count -gt 0) {
					$lines.Add("  Params:")
					foreach ($nt in $content.nonTrivial) {
						$lines.Add("    $($nt.name) = $($nt.expression)")
					}
				}
			}
		}

		# Check field bindings
		if ($fieldBindings.Contains($Name)) {
			if ($found) { $lines.Add("") }
			$found = $true
			$tName = $fieldBindings[$Name]
			$lines.Add("=== Field template: $Name -> $tName ===")
			if ($tplIndex.ContainsKey($tName)) {
				$content = Get-TemplateContent $tplIndex[$tName]
				$cellCount = 0
				foreach ($r in $content.cells) { $cellCount += $r.cells.Count }
				$lines.Add("[$($content.rows) rows, $cellCount cells]")

				foreach ($r in $content.cells) {
					$cellStr = $r.cells -join " | "
					$lines.Add("  Row $($r.row): $cellStr")
				}

				if ($content.nonTrivial.Count -gt 0) {
					$lines.Add("  Non-trivial params:")
					foreach ($nt in $content.nonTrivial) {
						$lines.Add("    $($nt.name) = $($nt.expression)")
					}
				} else {
					$lines.Add("  (all params trivial)")
				}
			}
		}

		if (-not $found) {
			Write-Error "Group or field '$Name' not found in template bindings"
			exit 1
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
