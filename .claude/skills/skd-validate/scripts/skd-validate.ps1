# skd-validate v1.0 — Validate 1C DCS structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$TemplatePath,

	[int]$MaxErrors = 20,

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
$fileName = [System.IO.Path]::GetFileName($resolvedPath)

# --- Output infrastructure ---

$script:errors = 0
$script:warnings = 0
$script:stopped = $false
$script:output = New-Object System.Text.StringBuilder 4096

function Out-Line {
	param([string]$msg)
	$script:output.AppendLine($msg) | Out-Null
}

function Report-OK {
	param([string]$msg)
	Out-Line "[OK]    $msg"
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

$finalize = {
	Out-Line ""
	Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ==="

	$result = $script:output.ToString()
	Write-Host $result

	if ($OutFile) {
		$utf8Bom = New-Object System.Text.UTF8Encoding $true
		[System.IO.File]::WriteAllText($OutFile, $result, $utf8Bom)
		Write-Host "Written to: $OutFile"
	}
}

Out-Line "=== Validation: $fileName ==="
Out-Line ""

# --- 1. Parse XML ---

$xmlDoc = $null
try {
	$xmlDoc = New-Object System.Xml.XmlDocument
	$xmlDoc.PreserveWhitespace = $false
	$xmlDoc.Load($resolvedPath)
	Report-OK "XML parsed successfully"
} catch {
	Report-Error "XML parse failed: $($_.Exception.Message)"
	# Cannot continue
	$result = $script:output.ToString()
	Write-Host $result
	if ($OutFile) {
		$utf8Bom = New-Object System.Text.UTF8Encoding $true
		[System.IO.File]::WriteAllText($OutFile, $result, $utf8Bom)
	}
	exit 1
}

# --- 2. Register namespaces ---

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

# --- 3. Root element checks ---

if ($root.LocalName -ne "DataCompositionSchema") {
	Report-Error "Root element is '$($root.LocalName)', expected 'DataCompositionSchema'"
} else {
	Report-OK "Root element: DataCompositionSchema"
}

$expectedNs = "http://v8.1c.ru/8.1/data-composition-system/schema"
if ($root.NamespaceURI -ne $expectedNs) {
	Report-Error "Default namespace is '$($root.NamespaceURI)', expected '$expectedNs'"
} else {
	Report-OK "Default namespace correct"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 4. Collect inventories ---

# DataSources
$dataSourceNodes = $root.SelectNodes("s:dataSource", $ns)
$dataSourceNames = @{}
foreach ($dsn in $dataSourceNodes) {
	$name = $dsn.SelectSingleNode("s:name", $ns)
	if ($name) { $dataSourceNames[$name.InnerText] = $true }
}

# DataSets (recursive for unions)
$dataSetNodes = $root.SelectNodes("s:dataSet", $ns)
$dataSetNames = @{}
$allFieldPaths = @{}  # Global: dataPath → dataSet name

function Collect-DataSetFields {
	param($dsNode, [string]$dsName)

	$fields = $dsNode.SelectNodes("s:field", $ns)
	$localPaths = @{}
	foreach ($f in $fields) {
		$dp = $f.SelectSingleNode("s:dataPath", $ns)
		if ($dp) {
			$path = $dp.InnerText
			$localPaths[$path] = $true
			$allFieldPaths[$path] = $dsName
		}
	}

	# Union items
	$items = $dsNode.SelectNodes("s:item", $ns)
	foreach ($item in $items) {
		$itemName = $item.SelectSingleNode("s:name", $ns)
		if ($itemName) {
			Collect-DataSetFields -dsNode $item -dsName $itemName.InnerText
		}
	}

	return $localPaths
}

$dataSetFieldMap = @{}  # dsName → hashtable of dataPath
foreach ($ds in $dataSetNodes) {
	$nameNode = $ds.SelectSingleNode("s:name", $ns)
	if ($nameNode) {
		$dsName = $nameNode.InnerText
		$dataSetNames[$dsName] = $true
		$dataSetFieldMap[$dsName] = Collect-DataSetFields -dsNode $ds -dsName $dsName
	}
}

# CalculatedFields
$calcFieldNodes = $root.SelectNodes("s:calculatedField", $ns)
$calcFieldPaths = @{}
foreach ($cf in $calcFieldNodes) {
	$dp = $cf.SelectSingleNode("s:dataPath", $ns)
	if ($dp) { $calcFieldPaths[$dp.InnerText] = $true }
}

# TotalFields
$totalFieldNodes = $root.SelectNodes("s:totalField", $ns)

# Parameters
$paramNodes = $root.SelectNodes("s:parameter", $ns)
$paramNames = @{}
foreach ($p in $paramNodes) {
	$nameNode = $p.SelectSingleNode("s:name", $ns)
	if ($nameNode) { $paramNames[$nameNode.InnerText] = $true }
}

# Templates
$templateNodes = $root.SelectNodes("s:template", $ns)
$templateNames = @{}
foreach ($t in $templateNodes) {
	$nameNode = $t.SelectSingleNode("s:name", $ns)
	if ($nameNode) { $templateNames[$nameNode.InnerText] = $true }
}

# GroupTemplates
$groupTemplateNodes = $root.SelectNodes("s:groupTemplate", $ns)

# SettingsVariants
$variantNodes = $root.SelectNodes("s:settingsVariant", $ns)

# Known fields = dataset fields + calculated fields
$knownFields = @{}
foreach ($key in $allFieldPaths.Keys) { $knownFields[$key] = $true }
foreach ($key in $calcFieldPaths.Keys) { $knownFields[$key] = $true }

# --- 5. DataSource checks ---

if ($dataSourceNodes.Count -eq 0) {
	Report-Warn "No dataSource elements found (settings-only DCS?)"
} else {
	$dsNamesSeen = @{}
	$dsOk = $true
	foreach ($dsn in $dataSourceNodes) {
		$name = $dsn.SelectSingleNode("s:name", $ns)
		$type = $dsn.SelectSingleNode("s:dataSourceType", $ns)
		if (-not $name -or -not $name.InnerText) {
			Report-Error "DataSource has empty name"
			$dsOk = $false
		} elseif ($dsNamesSeen.ContainsKey($name.InnerText)) {
			Report-Error "Duplicate dataSource name: $($name.InnerText)"
			$dsOk = $false
		} else {
			$dsNamesSeen[$name.InnerText] = $true
		}
		if ($type) {
			$tv = $type.InnerText
			if ($tv -ne "Local" -and $tv -ne "External") {
				Report-Warn "DataSource '$($name.InnerText)' has unusual type: $tv"
			}
		}
	}
	if ($dsOk) {
		Report-OK "$($dataSourceNodes.Count) dataSource(s) found, names unique"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 6. DataSet checks ---

$validDsTypes = @("DataSetQuery", "DataSetObject", "DataSetUnion")

if ($dataSetNodes.Count -eq 0) {
	Report-Warn "No dataSet elements found (settings-only DCS?)"
} else {
	$dsNamesSeen = @{}
	$dsOk = $true
	foreach ($ds in $dataSetNodes) {
		$xsiType = $ds.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		$nameNode = $ds.SelectSingleNode("s:name", $ns)
		$dsName = if ($nameNode) { $nameNode.InnerText } else { "(unnamed)" }

		if (-not $nameNode -or -not $nameNode.InnerText) {
			Report-Error "DataSet has empty name"
			$dsOk = $false
		} elseif ($dsNamesSeen.ContainsKey($dsName)) {
			Report-Error "Duplicate dataSet name: $dsName"
			$dsOk = $false
		} else {
			$dsNamesSeen[$dsName] = $true
		}

		if (-not $xsiType) {
			Report-Error "DataSet '$dsName' missing xsi:type"
			$dsOk = $false
		} elseif ($validDsTypes -notcontains $xsiType) {
			Report-Warn "DataSet '$dsName' has unusual xsi:type: $xsiType"
		}

		# Check dataSource reference
		if ($xsiType -ne "DataSetUnion") {
			$srcNode = $ds.SelectSingleNode("s:dataSource", $ns)
			if ($srcNode -and $srcNode.InnerText) {
				if (-not $dataSourceNames.ContainsKey($srcNode.InnerText)) {
					Report-Error "DataSet '$dsName' references unknown dataSource: $($srcNode.InnerText)"
					$dsOk = $false
				}
			}
		}

		# Check query not empty for Query type
		if ($xsiType -eq "DataSetQuery") {
			$queryNode = $ds.SelectSingleNode("s:query", $ns)
			if (-not $queryNode -or -not $queryNode.InnerText.Trim()) {
				Report-Warn "DataSet '$dsName' (Query) has empty query"
			}
		}

		# Check objectName for Object type
		if ($xsiType -eq "DataSetObject") {
			$objNode = $ds.SelectSingleNode("s:objectName", $ns)
			if (-not $objNode -or -not $objNode.InnerText.Trim()) {
				Report-Error "DataSet '$dsName' (Object) has empty objectName"
				$dsOk = $false
			}
		}
	}

	if ($dsOk) {
		Report-OK "$($dataSetNodes.Count) dataSet(s) found, names unique"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 7. Field checks ---

function Check-DataSetFields {
	param($dsNode, [string]$dsName)

	$fields = $dsNode.SelectNodes("s:field", $ns)
	if ($fields.Count -eq 0) { return }

	$pathsSeen = @{}
	$fieldOk = $true

	foreach ($f in $fields) {
		$dp = $f.SelectSingleNode("s:dataPath", $ns)
		$fn = $f.SelectSingleNode("s:field", $ns)

		if (-not $dp -or -not $dp.InnerText) {
			Report-Error "DataSet '$dsName': field has empty dataPath"
			$fieldOk = $false
			continue
		}

		$path = $dp.InnerText
		if ($pathsSeen.ContainsKey($path)) {
			Report-Warn "DataSet '$dsName': duplicate dataPath '$path'"
		} else {
			$pathsSeen[$path] = $true
		}

		if (-not $fn -or -not $fn.InnerText) {
			Report-Warn "DataSet '$dsName': field '$path' has empty <field> element"
		}
	}

	if ($fieldOk) {
		Report-OK "DataSet `"$dsName`": $($fields.Count) fields, dataPath unique"
	}

	# Check union items recursively
	$items = $dsNode.SelectNodes("s:item", $ns)
	foreach ($item in $items) {
		$itemName = $item.SelectSingleNode("s:name", $ns)
		$iName = if ($itemName) { $itemName.InnerText } else { "(unnamed item)" }
		Check-DataSetFields -dsNode $item -dsName $iName
	}
}

foreach ($ds in $dataSetNodes) {
	$nameNode = $ds.SelectSingleNode("s:name", $ns)
	$dsName = if ($nameNode) { $nameNode.InnerText } else { "(unnamed)" }
	Check-DataSetFields -dsNode $ds -dsName $dsName
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 8. DataSetLink checks ---

$linkNodes = $root.SelectNodes("s:dataSetLink", $ns)
if ($linkNodes.Count -gt 0) {
	$linkOk = $true
	foreach ($link in $linkNodes) {
		$src = $link.SelectSingleNode("s:sourceDataSet", $ns)
		$dst = $link.SelectSingleNode("s:destinationDataSet", $ns)
		$srcExpr = $link.SelectSingleNode("s:sourceExpression", $ns)
		$dstExpr = $link.SelectSingleNode("s:destinationExpression", $ns)

		if ($src -and $src.InnerText -and -not $dataSetNames.ContainsKey($src.InnerText)) {
			Report-Error "DataSetLink: sourceDataSet '$($src.InnerText)' not found"
			$linkOk = $false
		}
		if ($dst -and $dst.InnerText -and -not $dataSetNames.ContainsKey($dst.InnerText)) {
			Report-Error "DataSetLink: destinationDataSet '$($dst.InnerText)' not found"
			$linkOk = $false
		}
		if (-not $srcExpr -or -not $srcExpr.InnerText.Trim()) {
			Report-Error "DataSetLink: empty sourceExpression"
			$linkOk = $false
		}
		if (-not $dstExpr -or -not $dstExpr.InnerText.Trim()) {
			Report-Error "DataSetLink: empty destinationExpression"
			$linkOk = $false
		}
	}
	if ($linkOk) {
		Report-OK "$($linkNodes.Count) dataSetLink(s): references valid"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 9. CalculatedField checks ---

if ($calcFieldNodes.Count -gt 0) {
	$cfOk = $true
	$cfSeen = @{}
	foreach ($cf in $calcFieldNodes) {
		$dp = $cf.SelectSingleNode("s:dataPath", $ns)
		$expr = $cf.SelectSingleNode("s:expression", $ns)

		if (-not $dp -or -not $dp.InnerText) {
			Report-Error "CalculatedField has empty dataPath"
			$cfOk = $false
			continue
		}

		$path = $dp.InnerText
		if ($cfSeen.ContainsKey($path)) {
			Report-Error "Duplicate calculatedField dataPath: $path"
			$cfOk = $false
		} else {
			$cfSeen[$path] = $true
		}

		if (-not $expr -or -not $expr.InnerText.Trim()) {
			Report-Error "CalculatedField '$path' has empty expression"
			$cfOk = $false
		}

		# Warn if collides with a dataset field
		if ($allFieldPaths.ContainsKey($path)) {
			Report-Warn "CalculatedField '$path' shadows dataSet field in '$($allFieldPaths[$path])'"
		}
	}

	if ($cfOk) {
		Report-OK "$($calcFieldNodes.Count) calculatedField(s): dataPath and expression valid"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 10. TotalField checks ---

if ($totalFieldNodes.Count -gt 0) {
	$tfOk = $true
	foreach ($tf in $totalFieldNodes) {
		$dp = $tf.SelectSingleNode("s:dataPath", $ns)
		$expr = $tf.SelectSingleNode("s:expression", $ns)

		if (-not $dp -or -not $dp.InnerText) {
			Report-Error "TotalField has empty dataPath"
			$tfOk = $false
			continue
		}

		if (-not $expr -or -not $expr.InnerText.Trim()) {
			Report-Error "TotalField '$($dp.InnerText)' has empty expression"
			$tfOk = $false
		}
	}

	if ($tfOk) {
		Report-OK "$($totalFieldNodes.Count) totalField(s): dataPath and expression present"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 11. Parameter checks ---

if ($paramNodes.Count -gt 0) {
	$paramOk = $true
	$paramSeen = @{}
	foreach ($p in $paramNodes) {
		$nameNode = $p.SelectSingleNode("s:name", $ns)
		if (-not $nameNode -or -not $nameNode.InnerText) {
			Report-Error "Parameter has empty name"
			$paramOk = $false
			continue
		}
		$pName = $nameNode.InnerText
		if ($paramSeen.ContainsKey($pName)) {
			Report-Error "Duplicate parameter name: $pName"
			$paramOk = $false
		} else {
			$paramSeen[$pName] = $true
		}
	}
	if ($paramOk) {
		Report-OK "$($paramNodes.Count) parameter(s): names unique"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 12. Template checks ---

if ($templateNodes.Count -gt 0) {
	$tplOk = $true
	$tplSeen = @{}
	foreach ($t in $templateNodes) {
		$nameNode = $t.SelectSingleNode("s:name", $ns)
		if (-not $nameNode -or -not $nameNode.InnerText) {
			Report-Error "Template has empty name"
			$tplOk = $false
			continue
		}
		$tName = $nameNode.InnerText
		if ($tplSeen.ContainsKey($tName)) {
			Report-Error "Duplicate template name: $tName"
			$tplOk = $false
		} else {
			$tplSeen[$tName] = $true
		}
	}
	if ($tplOk) {
		Report-OK "$($templateNodes.Count) template(s): names unique"
	}
}

# --- 13. GroupTemplate checks ---

if ($groupTemplateNodes.Count -gt 0) {
	$gtOk = $true
	$validTplTypes = @("Header", "Footer", "Overall", "OverallHeader", "OverallFooter")
	foreach ($gt in $groupTemplateNodes) {
		$tplRef = $gt.SelectSingleNode("s:template", $ns)
		$tplType = $gt.SelectSingleNode("s:templateType", $ns)

		if ($tplRef -and $tplRef.InnerText -and -not $templateNames.ContainsKey($tplRef.InnerText)) {
			Report-Error "GroupTemplate references unknown template: $($tplRef.InnerText)"
			$gtOk = $false
		}
		if ($tplType -and $validTplTypes -notcontains $tplType.InnerText) {
			Report-Warn "GroupTemplate has unusual templateType: $($tplType.InnerText)"
		}
	}
	if ($gtOk) {
		Report-OK "$($groupTemplateNodes.Count) groupTemplate(s): references valid"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 14. Settings helper functions ---

$validComparisonTypes = @(
	"Equal","NotEqual","Greater","GreaterOrEqual","Less","LessOrEqual",
	"InList","NotInList","InHierarchy","InListByHierarchy",
	"Contains","NotContains","BeginsWith","NotBeginsWith",
	"Filled","NotFilled"
)

$validStructureTypes = @(
	"dcsset:StructureItemGroup",
	"dcsset:StructureItemTable",
	"dcsset:StructureItemChart",
	"dcsset:StructureItemNestedObject"
)

function Check-FilterItems {
	param($parentNode, [string]$variantName)

	$filterItems = $parentNode.SelectNodes("dcsset:filter/dcsset:item", $ns)
	foreach ($fi in $filterItems) {
		if ($script:stopped) { return }
		$xsiType = $fi.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		if ($xsiType -eq "dcsset:FilterItemComparison") {
			$compType = $fi.SelectSingleNode("dcsset:comparisonType", $ns)
			if ($compType -and $validComparisonTypes -notcontains $compType.InnerText) {
				Report-Error "Variant '$variantName' filter: invalid comparisonType '$($compType.InnerText)'"
			}
		} elseif ($xsiType -eq "dcsset:FilterItemGroup") {
			$groupType = $fi.SelectSingleNode("dcsset:groupType", $ns)
			if ($groupType) {
				$validGroupTypes = @("AndGroup","OrGroup","NotGroup")
				if ($validGroupTypes -notcontains $groupType.InnerText) {
					Report-Warn "Variant '$variantName' filter group: unusual groupType '$($groupType.InnerText)'"
				}
			}
			# Recurse into nested items
			$nestedItems = $fi.SelectNodes("dcsset:item", $ns)
			foreach ($ni in $nestedItems) {
				$niType = $ni.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
				if ($niType -eq "dcsset:FilterItemComparison") {
					$compType = $ni.SelectSingleNode("dcsset:comparisonType", $ns)
					if ($compType -and $validComparisonTypes -notcontains $compType.InnerText) {
						Report-Error "Variant '$variantName' filter: invalid comparisonType '$($compType.InnerText)'"
					}
				}
			}
		}
	}
}

function Check-StructureItem {
	param($itemNode, [string]$variantName)

	if ($script:stopped) { return }

	$xsiType = $itemNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	if (-not $xsiType) {
		Report-Error "Variant '$variantName': structure item missing xsi:type"
		return
	}
	if ($validStructureTypes -notcontains $xsiType) {
		Report-Warn "Variant '$variantName': unusual structure item type '$xsiType'"
	}

	# Recurse into nested items (groups can contain groups)
	$nestedItems = $itemNode.SelectNodes("dcsset:item", $ns)
	foreach ($ni in $nestedItems) {
		Check-StructureItem -itemNode $ni -variantName $variantName
	}

	# Check column/row in tables
	if ($xsiType -eq "dcsset:StructureItemTable") {
		$columns = $itemNode.SelectNodes("dcsset:column", $ns)
		$rows = $itemNode.SelectNodes("dcsset:row", $ns)
		if ($columns.Count -eq 0) {
			Report-Warn "Variant '$variantName': table has no columns"
		}
		if ($rows.Count -eq 0) {
			Report-Warn "Variant '$variantName': table has no rows"
		}
	}
}

function Check-Settings {
	param($settingsNode, [string]$variantName)

	if ($script:stopped) { return }

	# Selection
	$selItems = $settingsNode.SelectNodes("dcsset:selection/dcsset:item", $ns)
	foreach ($si in $selItems) {
		$xsiType = $si.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		if ($xsiType -eq "dcsset:SelectedItemField") {
			$field = $si.SelectSingleNode("dcsset:field", $ns)
			if ($field -and $field.InnerText -and $field.InnerText -ne "SystemFields.Number") {
				$basePath = ($field.InnerText -split '\.')[0]
				if (-not $knownFields.ContainsKey($field.InnerText) -and -not $knownFields.ContainsKey($basePath)) {
					# Soft check — autoFillFields may add fields not listed explicitly
				}
			}
		}
	}

	# Filter
	Check-FilterItems -parentNode $settingsNode -variantName $variantName

	# Order
	$orderItems = $settingsNode.SelectNodes("dcsset:order/dcsset:item", $ns)
	foreach ($oi in $orderItems) {
		$xsiType = $oi.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
		if ($xsiType -eq "dcsset:OrderItemField") {
			$orderType = $oi.SelectSingleNode("dcsset:orderType", $ns)
			if ($orderType -and $orderType.InnerText -ne "Asc" -and $orderType.InnerText -ne "Desc") {
				Report-Warn "Variant '$variantName' order: invalid orderType '$($orderType.InnerText)'"
			}
		}
	}

	# Structure items
	$structItems = $settingsNode.SelectNodes("dcsset:item", $ns)
	foreach ($si in $structItems) {
		Check-StructureItem -itemNode $si -variantName $variantName
	}
}

# --- 15. SettingsVariant checks ---

if ($variantNodes.Count -eq 0) {
	Report-Warn "No settingsVariant elements found"
} else {
	$vOk = $true
	$vIdx = 0
	foreach ($v in $variantNodes) {
		$vIdx++
		$vName = $v.SelectSingleNode("dcsset:name", $ns)
		if (-not $vName -or -not $vName.InnerText) {
			Report-Error "SettingsVariant #$vIdx has empty name"
			$vOk = $false
		}

		$settings = $v.SelectSingleNode("dcsset:settings", $ns)
		if (-not $settings) {
			Report-Error "SettingsVariant '$($vName.InnerText)' has no settings element"
			$vOk = $false
			continue
		}

		# Check settings internals
		Check-Settings -settingsNode $settings -variantName "$($vName.InnerText)"
	}

	if ($vOk) {
		Report-OK "$($variantNodes.Count) settingsVariant(s) found"
	}
}

# --- Final output ---

& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
