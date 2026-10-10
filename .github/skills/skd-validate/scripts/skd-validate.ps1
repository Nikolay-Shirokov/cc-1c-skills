# skd-validate v1.7 — Validate 1C DCS structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)]
	[Alias('Path')]
	[string]$TemplatePath,

	[switch]$Detailed,

	[int]$MaxErrors = 20,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---

if (-not [System.IO.Path]::IsPathRooted($TemplatePath)) {
	$TemplatePath = Join-Path (Get-Location).Path $TemplatePath
}
# A: Directory → Ext/Template.xml
if (Test-Path $TemplatePath -PathType Container) {
	$TemplatePath = Join-Path (Join-Path $TemplatePath "Ext") "Template.xml"
}
# B1: Missing Ext/ (e.g. Templates/СКД/Template.xml → Templates/СКД/Ext/Template.xml)
if (-not (Test-Path $TemplatePath)) {
	$fn = [System.IO.Path]::GetFileName($TemplatePath)
	if ($fn -eq "Template.xml") {
		$c = Join-Path (Join-Path (Split-Path $TemplatePath) "Ext") $fn
		if (Test-Path $c) { $TemplatePath = $c }
	}
}
# B2: Descriptor (Templates/СКД.xml → Templates/СКД/Ext/Template.xml)
if (-not (Test-Path $TemplatePath) -and $TemplatePath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::GetFileNameWithoutExtension($TemplatePath)
	$dir = Split-Path $TemplatePath
	$c = Join-Path (Join-Path (Join-Path $dir $stem) "Ext") "Template.xml"
	if (Test-Path $c) { $TemplatePath = $c }
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
$script:okCount = 0
$script:stopped = $false
# Проверка, которая не выполнялась, — в итоговую строку: без этого «Validation OK» читается как
# «проверено всё» (модель так и докладывала пользователю при нарушенном порядке)
$script:xsdNote = $null
$script:output = New-Object System.Text.StringBuilder 4096

function Out-Line {
	param([string]$msg)
	$script:output.AppendLine($msg) | Out-Null
}

function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Out-Line "[OK]    $msg" }
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
	$checks = $script:okCount + $script:errors + $script:warnings
	if ($script:errors -eq 0 -and $script:warnings -eq 0 -and -not $Detailed) {
		$note = if ($script:xsdNote) { "; $($script:xsdNote)" } else { "" }
		$result = "=== Validation OK: $fileName ($checks checks$note) ==="
	} else {
		Out-Line ""
		$note = if ($script:xsdNote) { "; $($script:xsdNote)" } else { "" }
		Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ($checks checks$note) ==="
		$result = $script:output.ToString()
	}
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

# Регистр значим: -ne его не различает, и корень со строчной пропускался молча. Строчную
# (dataCompositionSchema — имя из XSD, так пишет сериализатор XDTO) платформа загружает, но
# конфигуратор всегда пишет DataCompositionSchema — это предупреждение, не ошибка.
if ($root.LocalName -ceq "DataCompositionSchema") {
	Report-OK "Root element: DataCompositionSchema"
} elseif ($root.LocalName -eq "DataCompositionSchema") {
	Report-Warn "Root element is '$($root.LocalName)' — the platform loads it, but the Designer writes 'DataCompositionSchema'"
} else {
	Report-Error "Root element is '$($root.LocalName)', expected 'DataCompositionSchema'"
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
	# Collect totalField dataPaths — an empty calculatedField is legitimate if a
	# totalField with the same dataPath provides the expression (real-world
	# pattern in vendor ERP/БП reports for fields visible only in totals).
	$tfPaths = @{}
	foreach ($tf in $totalFieldNodes) {
		$tfDp = $tf.SelectSingleNode("s:dataPath", $ns)
		if ($tfDp -and $tfDp.InnerText) {
			$tfPaths[$tfDp.InnerText] = $true
		}
	}

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
			# Empty expression is legitimate in several vendor patterns:
			#   - totalField with same dataPath provides the calculation
			#   - groupTemplate uses the field as group name (declarative only)
			#   - field is referenced only by settingsVariants for grouping
			# Surface as warning, not error, to avoid false positives on real
			# ERP/БП reports while still flagging the unusual shape.
			if (-not $tfPaths.ContainsKey($path)) {
				Report-Warn "CalculatedField '$path' has empty expression (declarative-only?)"
			}
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
			# Vendor configs (ERP/БП) ship templates with repeating names — the
			# platform identifies them by position/context, not by <name>. Demote
			# to warning so the check still surfaces the collision without failing.
			Report-Warn "Duplicate template name: $tName (allowed by platform but ambiguous)"
		} else {
			$tplSeen[$tName] = $true
		}
	}
	if ($tplOk) {
		Report-OK "$($templateNodes.Count) template(s) found"
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
	"InList","NotInList","InHierarchy","NotInHierarchy",
	"InListByHierarchy","NotInListByHierarchy",
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

# --- 16. valueType structural checks ---
# Catches broken XDTO that XML/structural checks miss (decimal without xs:,
# missing qualifiers, mismatched qualifier blocks, unknown sign/length tokens).

$validTypeQualifier = @{
	'xs:decimal'        = 'v8:NumberQualifiers'
	'xs:string'         = 'v8:StringQualifiers'
	'xs:dateTime'       = 'v8:DateQualifiers'
	'xs:boolean'        = ''
	'v8:StandardPeriod' = ''
	'v8:UUID'           = ''
	'v8:Null'           = ''
	'v8:Type'           = ''
	'v8:ValueStorage'   = ''
}
$validSign       = @('Any', 'Nonnegative', 'Negative')
$validLength     = @('Variable', 'Fixed')
$validFractions  = @('Date', 'DateTime', 'Time')

# DCS supports composite types: multiple <v8:Type> blocks may share a single
# trailing qualifier block (e.g. xs:string + CatalogRef.X + StringQualifiers).
# So we collect all types and qualifiers per valueType, then check consistency.
$qualifierProducers = @{
	'v8:NumberQualifiers' = 'xs:decimal'
	'v8:StringQualifiers' = 'xs:string'
	'v8:DateQualifiers'   = 'xs:dateTime'
}

$valueTypeNodes = $root.SelectNodes("//s:valueType", $ns)
$vtChecked = 0
$vtOk = $true
foreach ($vt in $valueTypeNodes) {
	$vtChecked++
	$types = @()       # list of short type strings; '' marks a ref type
	$qualifiers = @()  # list of @{ name = 'v8:XQualifiers'; node = $child }

	foreach ($child in $vt.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		if ($child.NamespaceURI -ne 'http://v8.1c.ru/8.1/data/core') { continue }
		$localName = $child.LocalName

		if ($localName -eq 'Type') {
			$t = "$($child.InnerText)".Trim()
			if (-not $t) {
				Report-Error "valueType: <v8:Type> is empty"
				$vtOk = $false
				continue
			}
			if ($t -match '^([A-Za-z][A-Za-z0-9]*):(.+)$') {
				$prefix = $Matches[1]
				$localT = $Matches[2]
				if ($prefix -eq 'xs' -or $prefix -eq 'v8') {
					if (-not $validTypeQualifier.ContainsKey($t)) {
						Report-Error "valueType: unknown type '$t' (allowed: xs:decimal/xs:string/xs:dateTime/xs:boolean/v8:StandardPeriod or <prefix>:*Ref.X)"
						$vtOk = $false
					} else {
						$types += $t
					}
				} else {
					$prefixNs = $child.GetNamespaceOfPrefix($prefix)
					if ($prefixNs -eq 'http://v8.1c.ru/8.1/data/enterprise/current-config') {
						if (-not ($localT -match '^[A-Za-z]+(Ref)?\.')) {
							Report-Error "valueType: ref type '$t' must look like '<prefix>:<Kind>.<Name>' (e.g. d5p1:CatalogRef.X)"
							$vtOk = $false
						} else {
							$types += ''   # ref — no qualifier needed
						}
					} elseif ($prefixNs -eq 'http://v8.1c.ru/8.1/data/enterprise') {
						# System types: AccumulationRecordType etc. — no qualifiers
						if (-not ($localT -match '^[A-Za-z][A-Za-z0-9]*$')) {
							Report-Error "valueType: system type '$t' has unexpected local-name shape"
							$vtOk = $false
						} else {
							$types += ''
						}
					} else {
						Report-Error "valueType: type '$t' uses prefix '$prefix' bound to unexpected namespace '$prefixNs'"
						$vtOk = $false
					}
				}
			} else {
				Report-Error "valueType: type '$t' has no namespace prefix (expected xs:/v8:/d5p1: — e.g. xs:decimal not decimal)"
				$vtOk = $false
			}
		} elseif ($localName -match 'Qualifiers$') {
			$qName = "v8:$localName"
			$qualifiers += @{ name = $qName; node = $child }
			# Validate qualifier internals
			if ($qName -eq 'v8:NumberQualifiers') {
				$digits = $child.SelectSingleNode("v8:Digits", $ns)
				$frac   = $child.SelectSingleNode("v8:FractionDigits", $ns)
				$sign   = $child.SelectSingleNode("v8:AllowedSign", $ns)
				if (-not $digits -or -not ($digits.InnerText -match '^\d+$')) {
					Report-Error "v8:NumberQualifiers: <v8:Digits> missing or not a non-negative integer"
					$vtOk = $false
				}
				if (-not $frac -or -not ($frac.InnerText -match '^\d+$')) {
					Report-Error "v8:NumberQualifiers: <v8:FractionDigits> missing or not a non-negative integer"
					$vtOk = $false
				}
				if ($sign -and $sign.InnerText -and $sign.InnerText -notin $validSign) {
					Report-Error "v8:NumberQualifiers: <v8:AllowedSign>$($sign.InnerText)</v8:AllowedSign> — must be one of: $($validSign -join ', ')"
					$vtOk = $false
				}
			} elseif ($qName -eq 'v8:StringQualifiers') {
				$len = $child.SelectSingleNode("v8:Length", $ns)
				$al  = $child.SelectSingleNode("v8:AllowedLength", $ns)
				if (-not $len -or -not ($len.InnerText -match '^\d+$')) {
					Report-Error "v8:StringQualifiers: <v8:Length> missing or not a non-negative integer"
					$vtOk = $false
				}
				if ($al -and $al.InnerText -and $al.InnerText -notin $validLength) {
					Report-Error "v8:StringQualifiers: <v8:AllowedLength>$($al.InnerText)</v8:AllowedLength> — must be one of: $($validLength -join ', ')"
					$vtOk = $false
				}
			} elseif ($qName -eq 'v8:DateQualifiers') {
				$df = $child.SelectSingleNode("v8:DateFractions", $ns)
				if ($df -and $df.InnerText -and $df.InnerText -notin $validFractions) {
					Report-Error "v8:DateQualifiers: <v8:DateFractions>$($df.InnerText)</v8:DateFractions> — must be one of: $($validFractions -join ', ')"
					$vtOk = $false
				}
			}
		}
	}

	# Cross-check: every qualifier must have a matching scalar type in this valueType
	foreach ($q in $qualifiers) {
		$producer = $qualifierProducers[$q.name]
		if (-not $producer) { continue }
		if ($types -notcontains $producer) {
			Report-Error "valueType: <$($q.name)> has no matching <v8:Type>$producer</v8:Type> in this valueType"
			$vtOk = $false
		}
	}
}
if ($vtChecked -gt 0 -and $vtOk) {
	Report-OK "$vtChecked valueType block(s): structure and qualifiers OK"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 17. value content checks ---
# Catches literal placeholders ("_") and empty strings in DesignTimeValue refs
# that XDTO would reject at db-load-xml.

$valueNodes = @()
$valueNodes += @($root.SelectNodes("//s:value[@xsi:type]", $ns))
$valueNodes += @($root.SelectNodes("//dcscor:value[@xsi:type]", $ns))
$vChecked = 0
$vOk = $true
foreach ($vn in $valueNodes) {
	if (-not $vn) { continue }
	$vChecked++
	$xsiType = $vn.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	$text = $vn.InnerText
	if ($xsiType -eq 'dcscor:DesignTimeValue') {
		if (-not $text -or $text.Trim() -eq '' -or $text.Trim() -eq '_') {
			Report-Error "<value xsi:type=`"dcscor:DesignTimeValue`">$text</value> — DesignTimeValue must be a reference path (e.g. Перечисление.X.Y), not '$text'"
			$vOk = $false
		} elseif (-not ($text -match '^[A-Za-zА-Яа-яЁё]+\.[A-Za-zА-Яа-яЁё0-9_]+')) {
			Report-Warn "<value xsi:type=`"dcscor:DesignTimeValue`">$text</value> — doesn't look like a typical ref path"
		}
	} elseif ($xsiType -ceq 'xs:boolean' -and @('true', 'false', '1', '0') -cnotcontains $text.Trim()) {
		# Платформа прощает True/False, чтение по схеме (XDTO) — нет
		Report-Error "<value xsi:type=`"xs:boolean`">$text</value> — boolean must be true or false (lowercase)"
		$vOk = $false
	}
}
if ($vChecked -gt 0 -and $vOk) {
	Report-OK "$vChecked <value> element(s) with xsi:type: content OK"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- 18. XSD (schemas of the platform, /v8-xsd-fetch) ---
# Порядок элементов, типы и значения — по XSD платформы, если они есть в проекте. Нет схем —
# нет проверки. Схемы XDTO совпадают с выгрузкой конфигуратора только в СКД, и то кроме
# нескольких мест, которые платформа пишет иначе, — они отсекаются ниже (Test-XsdPlatformNoise).

# Копия общего эталона (семья find_v8project, авторитет — cf-edit).
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

# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Именно корневого: в Form.xml
# расширения ниже стоит <BaseForm version=…>. Читается только заголовок, без разбора файла.
function Get-RootVersion([string]$xmlPath) {
	if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { return $null }
	$buf = New-Object byte[] 4096
	$fs = [System.IO.File]::OpenRead($xmlPath)
	try { $len = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
	$head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
	$m = [regex]::Match($head, '<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>')
	if (-not $m.Success) { return $null }
	$v = [regex]::Match($m.Groups[1].Value, '(?:^|\s)version="([^"]*)"')
	if ($v.Success) { return $v.Groups[1].Value }
	return $null
}

# Корень автономной внешней обработки/отчёта. Копия общего эталона (семья is_external_root,
# авторитет — cf-edit).
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

# Якорь выгрузки, в чьём дереве лежит файл: корень автономной EPF/ERF либо Configuration.xml,
# ближайший вверх. Корень обработки проверяется первым — иначе обработка, лежащая в дереве
# конфигурации, сверялась бы с конфигурацией. Нет якоря — сверять не с чем.
function Find-DumpAnchor([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 15 -and $d; $i++) {
		if (Test-ExternalObjectRoot "$d.xml") { return "$d.xml" }
		$cfg = Join-Path $d "Configuration.xml"
		if (Test-Path $cfg) { return $cfg }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if (-not $parent -or $parent -eq $d) { break }
		$d = $parent
	}
	return $null
}

function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

$xsdDcsNs = "http://v8.1c.ru/8.1/data-composition-system/schema"

# targetNamespace схемы — из заголовка файла, без разбора
function Get-XsdTargetNs([string]$path) {
	$buf = New-Object byte[] 4096
	$fs = [System.IO.File]::OpenRead($path)
	try { $len = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
	$m = [regex]::Match([System.Text.Encoding]::UTF8.GetString($buf, 0, $len), 'targetNamespace="([^"]*)"')
	if ($m.Success) { return $m.Groups[1].Value }
	return $null
}

# Каталог версии годится, если в нём есть схема СКД (в 2.10–2.11 её нет)
function Test-XsdVersionDir([string]$dir) {
	foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.xsd -File -ErrorAction SilentlyContinue) {
		if ((Get-XsdTargetNs $f.FullName) -ceq $xsdDcsNs) { return $true }
	}
	return $false
}

# Каталог схем: .v8-project.json — сначала от шаблона (проект, которому он принадлежит), потом
# от текущего каталога; xsdPath из него, иначе .v8-xsd рядом с ним. Нет проекта — нет схем.
function Resolve-XsdRoot([string]$templateDir) {
	$pj = Find-V8Project $templateDir
	if (-not $pj) { $pj = Find-V8Project (Get-Location).Path }
	if (-not $pj) { return $null }
	$pjDir = [System.IO.Path]::GetDirectoryName($pj)
	$rel = ".v8-xsd"
	try {
		$cfg = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
		if ($cfg.xsdPath) { $rel = "$($cfg.xsdPath)" }
	} catch {}
	$dir = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $pjDir $rel }
	if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
	return $null
}

# Места, которые платформа пишет не так, как описывает XSD, — сверено на всех схемах компоновки
# выгрузок БП и УНФ. Правило — по месту (элемент, родитель, xsi:type), не по тексту: текст
# зависит от движка и языка.
function Test-XsdPlatformNoise($info) {
	$e = $info.elem; $p = $info.parent
	if (($p -ceq 'groupTemplate' -or $p -ceq 'groupHeaderTemplate') -and ($e -ceq 'templateType' -or $e -ceq 'groupName')) { return $true }
	if ($p -ceq 'right' -and $e -ceq 'lastId') { return $true }
	if ($p -ceq 'nestedSchema' -and $e -ceq 'schema') { return $true }
	if ($info.xsiNs -ceq 'http://v8.1c.ru/8.2/data/chart') { return $true }
	# Пустое выражение параметра макета платформа не пишет, схема требует
	if ($e -ceq 'parameter' -and $info.xsiLocal -ceq 'ExpressionAreaTemplateParameter') { return $true }
	return $false
}

# --- Подсказка по схеме: что именно исправить ---
# Текст валидатора про порядок («недопустимый дочерний X, ожидается A, B») читается как «добавь A»,
# а означает «X стоит слишком поздно». Поэтому для нарушений порядка строим свою подсказку: тип
# родителя и порядок его детей берём из XSD, сравниваем с соседями нарушителя в документе. Обход
# схемы — свой, по XSD-документам (не PSVI .NET): так подсказки портов совпадают.

function Get-XsdModel([string]$dir) {
	$m = @{
		types = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
		elems = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
		orders = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
	}
	foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.xsd -File) {
		$doc = New-Object System.Xml.XmlDocument
		$doc.Load($f.FullName)
		$tns = $doc.DocumentElement.GetAttribute("targetNamespace")
		foreach ($n in $doc.DocumentElement.ChildNodes) {
			if ($n.NodeType -ne 'Element' -or $n.NamespaceURI -cne 'http://www.w3.org/2001/XMLSchema') { continue }
			$name = $n.GetAttribute("name")
			if (-not $name) { continue }
			if ($n.get_LocalName() -ceq 'complexType' -and -not $m.types.ContainsKey("$tns|$name")) { $m.types["$tns|$name"] = $n }
			elseif ($n.get_LocalName() -ceq 'element' -and -not $m.elems.ContainsKey("$tns|$name")) { $m.elems["$tns|$name"] = $n }
		}
	}
	return $m
}

# QName из атрибута схемы → "ns|имя" по пространствам имён узла XSD
function Resolve-XsdQName($node, [string]$qn) {
	if (-not $qn) { return $null }
	$pp = $qn.Split(':')
	$prefix = if ($pp.Count -gt 1) { $pp[0] } else { '' }
	return "$($node.GetNamespaceOfPrefix($prefix))|$($pp[-1])"
}

# Дети типа по порядку: @{ name; type; maxOne }. База расширения — первой. Порядок не определён
# (choice, all, any, group) или тип неизвестен — $null.
function Get-XsdChildOrder($model, [string]$typeKey) {
	if (-not $typeKey) { return $null }
	# Список отдаём через «,»: иначе PS развернёт его — пустой станет $null, одиночный — самим элементом
	if ($model.orders.ContainsKey($typeKey)) { $v = $model.orders[$typeKey]; if ($null -eq $v) { return $null }; return ,$v }
	$model.orders[$typeKey] = $null   # защита от циклов
	$ct = if ($model.types.ContainsKey($typeKey)) { $model.types[$typeKey] } else { $null }
	if (-not $ct) { return $null }
	$list = New-Object System.Collections.ArrayList
	$holder = $ct
	foreach ($c in $ct.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if ($c.get_LocalName() -ceq 'simpleContent') { $model.orders[$typeKey] = $list; return ,$list }
		if ($c.get_LocalName() -ceq 'complexContent') {
			$ext = $null
			foreach ($x in $c.ChildNodes) { if ($x.NodeType -eq 'Element' -and $x.get_LocalName() -ceq 'extension') { $ext = $x } }
			if (-not $ext) { return $null }
			$baseKey = Resolve-XsdQName $ext $ext.GetAttribute("base")
			$base = Get-XsdChildOrder $model $baseKey
			# База известна, но порядок у неё не определён — не определён и здесь
			if ($null -eq $base -and $model.types.ContainsKey($baseKey)) { return $null }
			if ($base) { foreach ($b in $base) { [void]$list.Add($b) } }
			$holder = $ext
		}
	}
	foreach ($c in $holder.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		$ln = $c.get_LocalName()
		if ($ln -ceq 'sequence') { if (-not (Add-XsdSequence $model $c $list)) { return $null } }
		elseif ($ln -ceq 'choice' -or $ln -ceq 'all' -or $ln -ceq 'group' -or $ln -ceq 'any') { return $null }
	}
	$model.orders[$typeKey] = $list
	return ,$list
}

function Add-XsdSequence($model, $seq, $list) {
	foreach ($c in $seq.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		$ln = $c.get_LocalName()
		if ($ln -ceq 'element') {
			$ref = $c.GetAttribute("ref")
			if ($ref) {
				$rk = Resolve-XsdQName $c $ref
				$ge = if ($model.elems.ContainsKey($rk)) { $model.elems[$rk] } else { $null }
				$name = $rk.Split('|')[-1]
				$type = if ($ge -and $ge.GetAttribute("type")) { Resolve-XsdQName $ge $ge.GetAttribute("type") } else { $null }
			} else {
				$name = $c.GetAttribute("name")
				$type = if ($c.GetAttribute("type")) { Resolve-XsdQName $c $c.GetAttribute("type") } else { $null }
			}
			$mx = $c.GetAttribute("maxOccurs")
			[void]$list.Add(@{ name = $name; type = $type; maxOne = (-not $mx -or $mx -ceq '1') })
		} elseif ($ln -ceq 'sequence') {
			if (-not (Add-XsdSequence $model $c $list)) { return $false }
		} elseif ($ln -ceq 'annotation') {
			continue
		} else {
			return $false
		}
	}
	return $true
}

# Тип родителя нарушителя: спуск от корня по цепочке предков (@{ name; ns; xsiKey })
function Resolve-XsdParentType($model, $ancestors) {
	if ($ancestors.Count -eq 0) { return $null }
	$root = $ancestors[0]
	$rk = "$($root.ns)|$($root.name)"
	if ($root.xsiKey) { $type = $root.xsiKey }
	elseif ($model.elems.ContainsKey($rk) -and $model.elems[$rk].GetAttribute("type")) { $type = Resolve-XsdQName $model.elems[$rk] $model.elems[$rk].GetAttribute("type") }
	elseif ($model.types.ContainsKey($rk)) { $type = $rk }
	else { return $null }
	for ($i = 1; $i -lt $ancestors.Count; $i++) {
		$a = $ancestors[$i]
		if ($a.xsiKey) { $type = $a.xsiKey; continue }
		$order = Get-XsdChildOrder $model $type
		if ($null -eq $order) { return $null }
		$hit = $null
		foreach ($o in $order) { if ($o.name -ceq $a.name) { $hit = $o; break } }
		if (-not $hit -or -not $hit.type) { return $null }
		$type = $hit.type
	}
	return $type
}

function Get-XsdOrderHint($model, $ancestors, [string]$name, $preceding) {
	$pt = Resolve-XsdParentType $model $ancestors
	$order = Get-XsdChildOrder $model $pt
	if ($null -eq $order) { return $null }
	$names = [string[]]@($order | ForEach-Object { $_.name })
	$idx = [array]::IndexOf($names, $name)
	if ($idx -lt 0) { return "not allowed in <$($ancestors[$ancestors.Count - 1].name)>" }
	if ($order[$idx].maxOne -and ([string[]]@($preceding) -ccontains $name)) { return "duplicate — only one <$name> allowed" }
	foreach ($sib in $preceding) {
		if ([array]::IndexOf($names, [string]$sib) -gt $idx) { return "must come before <$sib>" }
	}
	return $null
}

# Текст валидатора без пространств имён: остаются имена и значения
function Compress-XsdMessage([string]$m) {
	$m = $m -replace '[\r\n]+', ' '
	$m = $m -replace '\s(в пространстве имен|in namespace)\s"[^"]*"', ''
	$m = $m -replace "\s(в пространстве имен|in namespace)\s'[^']*'", ''
	$m = $m -replace '\{[^}]*\}', ''
	$m = $m -replace '(["''])https?://[^"'']*:', '$1'
	return $m.Trim()
}

function Invoke-XsdCheck {
	$xsdRoot = Resolve-XsdRoot ([System.IO.Path]::GetDirectoryName($resolvedPath))
	if (-not $xsdRoot) { $script:xsdNote = "XSD not checked: no schemas (/v8-xsd-fetch)"; return }
	$anchor = Find-DumpAnchor ([System.IO.Path]::GetDirectoryName($resolvedPath))
	$ver = if ($anchor) { Get-RootVersion $anchor } else { $null }
	if (-not $ver -or (Get-FormatRank $ver) -eq 0) { $script:xsdNote = "XSD not checked: template outside a dump"; return }

	# Точная версия — ошибки; ближайшая более новая — предупреждения; только старше — пропуск
	$cands = @(Get-ChildItem -LiteralPath $xsdRoot -Directory |
		Where-Object { $_.Name -match '^\d+\.\d+$' -and (Get-FormatRank $_.Name) -ge (Get-FormatRank $ver) } |
		Sort-Object { Get-FormatRank $_.Name } |
		Where-Object { Test-XsdVersionDir $_.FullName })
	if ($cands.Count -eq 0) { Report-Warn "XSD: no schemas for format $ver in '$xsdRoot' — not checked"; return }
	$useDir = $cands[0].FullName
	$useVer = $cands[0].Name
	$exact = ($useVer -eq $ver)

	# Набор схем. У import нет schemaLocation — связь по namespace, поэтому в набор кладём все.
	# Корень DataCompositionSchema в схеме объявлен как dataCompositionSchema (строчная) —
	# дописываем элемент в саму схему СКД: вторую схему того же namespace без SourceUri
	# XmlSchemaSet молча отбрасывает.
	$schemas = @()
	# Битый .xsd (например, недокачанный) — предупреждение, а не падение навыка
	try {
		foreach ($f in Get-ChildItem -LiteralPath $useDir -Filter *.xsd -File) {
			$fs = [System.IO.File]::OpenRead($f.FullName)
			try { $schemas += [System.Xml.Schema.XmlSchema]::Read($fs, $null) } finally { $fs.Dispose() }
		}
	} catch { Report-Warn "XSD: schemas in '$useDir' do not compile — not checked: $($_.Exception.Message)"; return }
	$dcs = $schemas | Where-Object { $_.TargetNamespace -ceq $xsdDcsNs } | Select-Object -First 1
	$hasRoot = $false
	foreach ($it in $dcs.Items) {
		if ($it -is [System.Xml.Schema.XmlSchemaElement] -and $it.Name -ceq 'DataCompositionSchema') { $hasRoot = $true }
	}
	if (-not $hasRoot) {
		$el = New-Object System.Xml.Schema.XmlSchemaElement
		$el.Name = 'DataCompositionSchema'
		$el.SchemaTypeName = New-Object System.Xml.XmlQualifiedName('DataCompositionSchema', $xsdDcsNs)
		[void]$dcs.Items.Add($el)
	}
	$set = New-Object System.Xml.Schema.XmlSchemaSet
	$set.XmlResolver = $null
	foreach ($sc in $schemas) { [void]$set.Add($sc) }
	try { $set.Compile() } catch { Report-Warn "XSD: schemas in '$useDir' do not compile — not checked: $($_.Exception.Message)"; return }
	$script:xsdModel = Get-XsdModel $useDir

	# Своя цепочка открытых элементов: в обработчике нужен родитель нарушителя
	$script:xsdStack = New-Object System.Collections.ArrayList
	$script:xsdFound = 0
	# Ошибку атрибута .NET сообщает, стоя на атрибуте: имени элемента-владельца в этот момент нет.
	# Откладываем и выводим после Read(), когда читатель уже на элементе.
	$script:xsdPending = New-Object System.Collections.ArrayList
	$script:xsdTag = if ($exact) { "XSD $useVer" } else { "XSD $useVer (no schemas for $ver)" }
	$script:xsdExact = $exact
	$handler = {
		param($sender, $e)
		if ($script:stopped) { return }
		$st = $script:xsdStack
		if ($sender.NodeType -eq 'Attribute') {
			[void]$script:xsdPending.Add(@{ line = $e.Exception.LineNumber; text = (Compress-XsdMessage $e.Message) })
			return
		}
		if ($sender.NodeType -eq 'Element') {
			$xt = $sender.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
			$info = @{ elem = $sender.LocalName; parent = $(if ($st.Count -gt 0) { $st[$st.Count - 1].name } else { '' }); xsiNs = ''; xsiLocal = '' }
			if ($xt) {
				$pp = $xt.Split(':')
				$info.xsiLocal = $pp[-1]
				if ($pp.Count -gt 1) { $info.xsiNs = "$($sender.LookupNamespace($pp[0]))" }
			}
		} else {
			$top = if ($st.Count -gt 0) { $st[$st.Count - 1] } else { @{ name = ''; xsiNs = ''; xsiLocal = '' } }
			$info = @{ elem = $top.name; parent = $(if ($st.Count -gt 1) { $st[$st.Count - 2].name } else { '' }); xsiNs = $top.xsiNs; xsiLocal = $top.xsiLocal }
		}
		if (Test-XsdPlatformNoise $info) { return }
		# Недопустимое булево значение уже сообщила собственная проверка значений (раздел 17)
		if ($info.elem -ceq 'value' -and $info.xsiNs -ceq 'http://www.w3.org/2001/XMLSchema' -and $info.xsiLocal -ceq 'boolean') { return }
		$script:xsdFound++
		$hint = $null
		if ($sender.NodeType -eq 'Element') {
			$prec = if ($st.Count -gt 0) { $st[$st.Count - 1].children } else { @() }
			$hint = Get-XsdOrderHint $script:xsdModel $st $sender.LocalName $prec
		}
		$text = if ($hint) { $hint } else { Compress-XsdMessage $e.Message }
		$msg = "$($script:xsdTag), line $($e.Exception.LineNumber): $($info.parent)/$($info.elem): $text"
		if ($script:xsdExact) { Report-Error $msg } else { Report-Warn $msg }
	}
	$rs = New-Object System.Xml.XmlReaderSettings
	$rs.ValidationType = 'Schema'
	$rs.Schemas = $set
	$rs.DtdProcessing = 'Prohibit'
	$rs.add_ValidationEventHandler($handler)
	$r = [System.Xml.XmlReader]::Create($resolvedPath, $rs)
	try {
		while ($r.Read()) {
			if ($r.NodeType -eq 'Element') {
				# Имя — в дети родителя (и у пустого элемента: он тоже сосед для подсказки)
				if ($script:xsdStack.Count -gt 0) { [void]$script:xsdStack[$script:xsdStack.Count - 1].children.Add($r.LocalName) }
				foreach ($pa in $script:xsdPending) {
					if ($script:stopped) { break }
					$xt = $r.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
					$info = @{ elem = $r.LocalName; parent = $(if ($script:xsdStack.Count -gt 0) { $script:xsdStack[$script:xsdStack.Count - 1].name } else { '' }); xsiNs = ''; xsiLocal = '' }
					if ($xt) {
						$pp = $xt.Split(':')
						$info.xsiLocal = $pp[-1]
						if ($pp.Count -gt 1) { $info.xsiNs = "$($r.LookupNamespace($pp[0]))" }
					}
					if (Test-XsdPlatformNoise $info) { continue }
					$script:xsdFound++
					$msg = "$($script:xsdTag), line $($pa.line): $($info.parent)/$($info.elem): $($pa.text)"
					if ($script:xsdExact) { Report-Error $msg } else { Report-Warn $msg }
				}
				$script:xsdPending.Clear()
				if ($script:stopped) { break }
				if ($r.IsEmptyElement) { continue }
				$xt = $r.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
				$entry = @{ name = $r.LocalName; ns = $r.NamespaceURI; xsiNs = ''; xsiLocal = ''; xsiKey = $null; children = New-Object System.Collections.ArrayList }
				if ($xt) {
					$pp = $xt.Split(':')
					$entry.xsiLocal = $pp[-1]
					$entry.xsiNs = if ($pp.Count -gt 1) { "$($r.LookupNamespace($pp[0]))" } else { "$($r.LookupNamespace(''))" }
					$entry.xsiKey = "$($entry.xsiNs)|$($entry.xsiLocal)"
				}
				[void]$script:xsdStack.Add($entry)
			} elseif ($r.NodeType -eq 'EndElement' -and $script:xsdStack.Count -gt 0) {
				$script:xsdStack.RemoveAt($script:xsdStack.Count - 1)
			}
			if ($script:stopped) { break }
		}
	} finally { $r.Dispose() }
	if ($script:xsdFound -eq 0) { Report-OK "$($script:xsdTag): order, types and values OK" }
}

Invoke-XsdCheck

if ($script:stopped) { & $finalize; exit 1 }

# --- Final output ---

& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
