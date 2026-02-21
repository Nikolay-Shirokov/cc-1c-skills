# epf-validate v1.0 — Validate 1C external data processor / report structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# Works for both EPF (ExternalDataProcessor) and ERF (ExternalReport) — auto-detects
param(
	[Parameter(Mandatory)]
	[string]$ObjectPath,

	[int]$MaxErrors = 30,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---

if (-not [System.IO.Path]::IsPathRooted($ObjectPath)) {
	$ObjectPath = Join-Path (Get-Location).Path $ObjectPath
}

if (Test-Path $ObjectPath -PathType Container) {
	$dirName = Split-Path $ObjectPath -Leaf
	$candidate = Join-Path $ObjectPath "$dirName.xml"
	$sibling = Join-Path (Split-Path $ObjectPath) "$dirName.xml"
	if (Test-Path $candidate) {
		$ObjectPath = $candidate
	} elseif (Test-Path $sibling) {
		$ObjectPath = $sibling
	} else {
		$xmlFiles = @(Get-ChildItem $ObjectPath -Filter "*.xml" -File | Select-Object -First 1)
		if ($xmlFiles.Count -gt 0) {
			$ObjectPath = $xmlFiles[0].FullName
		} else {
			Write-Host "[ERROR] No XML file found in directory: $ObjectPath"
			exit 1
		}
	}
}

# File not found — check Dir/Name/Name.xml → Dir/Name.xml
if (-not (Test-Path $ObjectPath)) {
	$fileName = [System.IO.Path]::GetFileNameWithoutExtension($ObjectPath)
	$parentDir = Split-Path $ObjectPath
	$parentDirName = Split-Path $parentDir -Leaf
	if ($fileName -eq $parentDirName) {
		$candidate = Join-Path (Split-Path $parentDir) "$fileName.xml"
		if (Test-Path $candidate) { $ObjectPath = $candidate }
	}
}
if (-not (Test-Path $ObjectPath)) {
	Write-Host "[ERROR] File not found: $ObjectPath"
	exit 1
}

$resolvedPath = (Resolve-Path $ObjectPath).Path
$srcDir = Split-Path $resolvedPath -Parent

# --- Output infrastructure ---

$script:errors = 0
$script:warnings = 0
$script:stopped = $false
$script:output = New-Object System.Text.StringBuilder 8192

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

# --- Reference tables ---

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$identPattern = '^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_][A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'

$classIds = @{
	"ExternalDataProcessor" = "c3831ec8-d8d5-4f93-8a22-f9bfae07327f"
	"ExternalReport"        = "e41aff26-25cf-4bb6-b6c1-3f478a75f374"
}

$allowedChildTypes = @("Attribute","TabularSection","Form","Template","Command")

# Expected order of child types in ChildObjects
$childTypeOrder = @{
	"Attribute"      = 0
	"TabularSection" = 1
	"Form"           = 2
	"Template"       = 3
	"Command"        = 4
}

$validPropertyValues = @{
	"FillChecking" = @("DontCheck","ShowError","ShowWarning")
	"Indexing"     = @("DontIndex","Index","IndexWithAdditionalOrder")
}

# --- 1. Parse XML ---

Out-Line ""

$xmlDoc = $null
try {
	$xmlDoc = New-Object System.Xml.XmlDocument
	$xmlDoc.PreserveWhitespace = $false
	$xmlDoc.Load($resolvedPath)
} catch {
	Out-Line "=== Validation: (parse failed) ==="
	Out-Line ""
	Report-Error "1. XML parse failed: $($_.Exception.Message)"
	& $finalize
	exit 1
}

# --- Register namespaces ---

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("app", "http://v8.1c.ru/8.2/managed-application/core")

$root = $xmlDoc.DocumentElement

# --- Check 1: Root structure ---

$check1Ok = $true

if ($root.LocalName -ne "MetaDataObject") {
	Report-Error "1. Root element is '$($root.LocalName)', expected 'MetaDataObject'"
	& $finalize
	exit 1
}

$expectedNs = "http://v8.1c.ru/8.3/MDClasses"
if ($root.NamespaceURI -ne $expectedNs) {
	Report-Error "1. Root namespace is '$($root.NamespaceURI)', expected '$expectedNs'"
	$check1Ok = $false
}

$version = $root.GetAttribute("version")
if (-not $version) {
	Report-Warn "1. Missing version attribute on MetaDataObject"
} elseif ($version -ne "2.17" -and $version -ne "2.20") {
	Report-Warn "1. Unusual version '$version' (expected 2.17 or 2.20)"
}

# Detect type: ExternalDataProcessor or ExternalReport
$typeNode = $null
$mdType = ""
$childElements = @()
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.NamespaceURI -eq $expectedNs) {
		$childElements += $child
	}
}

if ($childElements.Count -eq 0) {
	Report-Error "1. No metadata type element found inside MetaDataObject"
	& $finalize
	exit 1
} elseif ($childElements.Count -gt 1) {
	Report-Error "1. Multiple type elements found: $($childElements | ForEach-Object { $_.LocalName })"
	$check1Ok = $false
}

$typeNode = $childElements[0]
$mdType = $typeNode.LocalName

if ($mdType -ne "ExternalDataProcessor" -and $mdType -ne "ExternalReport") {
	Report-Error "1. Unexpected type '$mdType' (expected ExternalDataProcessor or ExternalReport)"
	& $finalize
	exit 1
}

$typeUuid = $typeNode.GetAttribute("uuid")
if (-not $typeUuid) {
	Report-Error "1. Missing uuid on <$mdType>"
	$check1Ok = $false
} elseif ($typeUuid -notmatch $guidPattern) {
	Report-Error "1. Invalid uuid '$typeUuid' on <$mdType>"
	$check1Ok = $false
}

# Get object name
$propsNode = $typeNode.SelectSingleNode("md:Properties", $ns)
$nameNode = if ($propsNode) { $propsNode.SelectSingleNode("md:Name", $ns) } else { $null }
$objName = if ($nameNode -and $nameNode.InnerText) { $nameNode.InnerText } else { "(unknown)" }

$shortType = if ($mdType -eq "ExternalDataProcessor") { "EPF" } else { "ERF" }
$script:output.Insert(0, "=== Validation: $shortType.$objName ===$([Environment]::NewLine)") | Out-Null

if ($check1Ok) {
	Report-OK "1. Root structure: MetaDataObject/$mdType, version $version"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 2: InternalInfo ---

$internalInfo = $typeNode.SelectSingleNode("md:InternalInfo", $ns)

if (-not $internalInfo) {
	Report-Error "2. InternalInfo block missing"
} else {
	$check2Ok = $true

	# ContainedObject / ClassId
	$containedObj = $internalInfo.SelectSingleNode("xr:ContainedObject", $ns)
	if (-not $containedObj) {
		Report-Error "2. InternalInfo: missing xr:ContainedObject"
		$check2Ok = $false
	} else {
		$classIdNode = $containedObj.SelectSingleNode("xr:ClassId", $ns)
		$objectIdNode = $containedObj.SelectSingleNode("xr:ObjectId", $ns)

		$expectedClassId = $classIds[$mdType]
		if (-not $classIdNode -or -not $classIdNode.InnerText) {
			Report-Error "2. Missing ClassId in ContainedObject"
			$check2Ok = $false
		} elseif ($classIdNode.InnerText -ne $expectedClassId) {
			Report-Error "2. ClassId is '$($classIdNode.InnerText)', expected '$expectedClassId' for $mdType"
			$check2Ok = $false
		}

		if ($objectIdNode -and $objectIdNode.InnerText -notmatch $guidPattern) {
			Report-Error "2. Invalid ObjectId UUID"
			$check2Ok = $false
		}
	}

	# GeneratedType — expect exactly 1 with category "Object"
	$genTypes = $internalInfo.SelectNodes("xr:GeneratedType", $ns)
	if ($genTypes.Count -eq 0) {
		Report-Error "2. No GeneratedType entries found"
		$check2Ok = $false
	} else {
		foreach ($gt in $genTypes) {
			$gtName = $gt.GetAttribute("name")
			$gtCategory = $gt.GetAttribute("category")

			if ($gtCategory -ne "Object") {
				Report-Warn "2. Unexpected GeneratedType category '$gtCategory' (expected 'Object')"
			}

			# Name format: ExternalDataProcessorObject.Name or ExternalReportObject.Name
			$expectedPrefix = "${mdType}Object."
			if ($gtName -and $objName -ne "(unknown)" -and -not $gtName.StartsWith($expectedPrefix)) {
				Report-Warn "2. GeneratedType name '$gtName' does not start with '$expectedPrefix'"
			}

			$typeId = $gt.SelectSingleNode("xr:TypeId", $ns)
			$valueId = $gt.SelectSingleNode("xr:ValueId", $ns)
			if ($typeId -and $typeId.InnerText -notmatch $guidPattern) {
				Report-Error "2. Invalid TypeId UUID in GeneratedType"
				$check2Ok = $false
			}
			if ($valueId -and $valueId.InnerText -notmatch $guidPattern) {
				Report-Error "2. Invalid ValueId UUID in GeneratedType"
				$check2Ok = $false
			}
		}
	}

	if ($check2Ok) {
		Report-OK "2. InternalInfo: ClassId correct, $($genTypes.Count) GeneratedType"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 3: Properties ---

if (-not $propsNode) {
	Report-Error "3. Properties block missing"
} else {
	$check3Ok = $true

	# Name
	if (-not $nameNode -or -not $nameNode.InnerText) {
		Report-Error "3. Properties: Name is missing or empty"
		$check3Ok = $false
	} else {
		$nameVal = $nameNode.InnerText
		if ($nameVal -notmatch $identPattern) {
			Report-Error "3. Properties: Name '$nameVal' is not a valid 1C identifier"
			$check3Ok = $false
		}
		if ($nameVal.Length -gt 80) {
			Report-Warn "3. Properties: Name '$nameVal' exceeds 80 characters ($($nameVal.Length))"
		}
	}

	# Synonym
	$synNode = $propsNode.SelectSingleNode("md:Synonym", $ns)
	$synPresent = $false
	if ($synNode) {
		$synItem = $synNode.SelectSingleNode("v8:item", $ns)
		if ($synItem) {
			$synContent = $synItem.SelectSingleNode("v8:content", $ns)
			if ($synContent -and $synContent.InnerText) {
				$synPresent = $true
			}
		}
	}

	# DefaultForm cross-reference (collected now, checked after ChildObjects)
	$defaultFormNode = $propsNode.SelectSingleNode("md:DefaultForm", $ns)
	$defaultFormVal = if ($defaultFormNode -and $defaultFormNode.InnerText.Trim()) { $defaultFormNode.InnerText.Trim() } else { "" }

	# AuxiliaryForm cross-reference
	$auxFormNode = $propsNode.SelectSingleNode("md:AuxiliaryForm", $ns)
	$auxFormVal = if ($auxFormNode -and $auxFormNode.InnerText.Trim()) { $auxFormNode.InnerText.Trim() } else { "" }

	# ERF-specific: MainDataCompositionSchema
	$mainDCSVal = ""
	if ($mdType -eq "ExternalReport") {
		$mainDCSNode = $propsNode.SelectSingleNode("md:MainDataCompositionSchema", $ns)
		$mainDCSVal = if ($mainDCSNode -and $mainDCSNode.InnerText.Trim()) { $mainDCSNode.InnerText.Trim() } else { "" }
	}

	if ($check3Ok) {
		$synInfo = if ($synPresent) { "Synonym present" } else { "no Synonym" }
		$extras = ""
		if ($defaultFormVal) { $extras += ", DefaultForm set" }
		if ($mainDCSVal) { $extras += ", MainDCS set" }
		Report-OK "3. Properties: Name=`"$objName`", $synInfo$extras"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 4: ChildObjects — allowed types and ordering ---

$childObjNode = $typeNode.SelectSingleNode("md:ChildObjects", $ns)
$formNames = @()
$templateNames = @()
$allChildNames = @{}

if ($childObjNode) {
	$check4Ok = $true
	$childCounts = @{}
	$lastOrder = -1
	$orderOk = $true

	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childTag = $child.LocalName

		if ($allowedChildTypes -notcontains $childTag) {
			Report-Error "4. ChildObjects: disallowed element '$childTag'"
			$check4Ok = $false
			continue
		}

		if (-not $childCounts.ContainsKey($childTag)) {
			$childCounts[$childTag] = 0
		}
		$childCounts[$childTag]++

		# Check ordering
		$thisOrder = $childTypeOrder[$childTag]
		if ($thisOrder -lt $lastOrder -and $orderOk) {
			Report-Warn "4. ChildObjects: '$childTag' appears after higher-order elements (expected: Attribute, TabularSection, Form, Template, Command)"
			$orderOk = $false
		}
		$lastOrder = $thisOrder

		# Collect Form and Template names (simple text content)
		if ($childTag -eq "Form") {
			$formNames += $child.InnerText.Trim()
		} elseif ($childTag -eq "Template") {
			$templateNames += $child.InnerText.Trim()
		}
	}

	if ($check4Ok) {
		$summary = ($childCounts.GetEnumerator() | Sort-Object { $childTypeOrder[$_.Name] } | ForEach-Object { "$($_.Name)($($_.Value))" }) -join ", "
		if ($summary) {
			Report-OK "4. ChildObjects: $summary"
		} else {
			Report-OK "4. ChildObjects: empty"
		}
	}
} else {
	Report-OK "4. ChildObjects: absent"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 5: DefaultForm / MainDCS cross-references ---

$check5Ok = $true

if ($defaultFormVal) {
	# Format: ExternalDataProcessor.Name.Form.FormName or ExternalReport.Name.Form.FormName
	$expectedPrefix = "$mdType.$objName.Form."
	if ($defaultFormVal.StartsWith($expectedPrefix)) {
		$refFormName = $defaultFormVal.Substring($expectedPrefix.Length)
		if ($formNames -notcontains $refFormName) {
			Report-Error "5. DefaultForm references '$refFormName', but no such Form in ChildObjects"
			$check5Ok = $false
		}
	} else {
		Report-Warn "5. DefaultForm value '$defaultFormVal' has unexpected prefix (expected '$expectedPrefix...')"
	}
}

if ($auxFormVal) {
	$expectedPrefix = "$mdType.$objName.Form."
	if ($auxFormVal.StartsWith($expectedPrefix)) {
		$refFormName = $auxFormVal.Substring($expectedPrefix.Length)
		if ($formNames -notcontains $refFormName) {
			Report-Error "5. AuxiliaryForm references '$refFormName', but no such Form in ChildObjects"
			$check5Ok = $false
		}
	}
}

if ($mainDCSVal -and $mdType -eq "ExternalReport") {
	$expectedPrefix = "ExternalReport.$objName.Template."
	if ($mainDCSVal.StartsWith($expectedPrefix)) {
		$refTplName = $mainDCSVal.Substring($expectedPrefix.Length)
		if ($templateNames -notcontains $refTplName) {
			Report-Error "5. MainDataCompositionSchema references '$refTplName', but no such Template in ChildObjects"
			$check5Ok = $false
		}
	} else {
		Report-Warn "5. MainDataCompositionSchema value '$mainDCSVal' has unexpected prefix"
	}
}

if ($check5Ok) {
	$refs = @()
	if ($defaultFormVal) { $refs += "DefaultForm" }
	if ($auxFormVal) { $refs += "AuxiliaryForm" }
	if ($mainDCSVal) { $refs += "MainDCS" }
	if ($refs.Count -gt 0) {
		Report-OK "5. Cross-references: $($refs -join ', ') valid"
	} else {
		Report-OK "5. Cross-references: none to check"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 6: Attributes — UUID, Name, Type ---

function Check-Attribute {
	param(
		[System.Xml.XmlNode]$node,
		[string]$context
	)

	$uuid = $node.GetAttribute("uuid")
	if (-not $uuid) {
		Report-Error "6. $context Attribute missing uuid"
		return $false
	} elseif ($uuid -notmatch $guidPattern) {
		Report-Error "6. $context Attribute has invalid uuid '$uuid'"
		return $false
	}

	$elProps = $node.SelectSingleNode("md:Properties", $ns)
	if (-not $elProps) {
		Report-Error "6. $context Attribute (uuid=$uuid) missing Properties"
		return $false
	}

	$elName = $elProps.SelectSingleNode("md:Name", $ns)
	if (-not $elName -or -not $elName.InnerText) {
		Report-Error "6. $context Attribute (uuid=$uuid) missing or empty Name"
		return $false
	}

	$nameVal = $elName.InnerText
	if ($nameVal -notmatch $identPattern) {
		Report-Error "6. $context Attribute '$nameVal' has invalid identifier"
		return $false
	}

	$typeEl = $elProps.SelectSingleNode("md:Type", $ns)
	if (-not $typeEl) {
		Report-Error "6. $context Attribute '$nameVal' missing Type block"
		return $false
	}
	$v8Types = $typeEl.SelectNodes("v8:Type", $ns)
	$v8TypeSets = $typeEl.SelectNodes("v8:TypeSet", $ns)
	if ($v8Types.Count -eq 0 -and $v8TypeSets.Count -eq 0) {
		Report-Error "6. $context Attribute '$nameVal' Type block has no v8:Type or v8:TypeSet"
		return $false
	}

	return $true
}

if ($childObjNode) {
	$attrs = $childObjNode.SelectNodes("md:Attribute", $ns)
	$check6Ok = $true
	$attrCount = 0

	foreach ($attr in $attrs) {
		if ($script:stopped) { break }
		$ok = Check-Attribute -node $attr -context ""
		if (-not $ok) { $check6Ok = $false }
		$attrCount++

		# Collect name for uniqueness
		$ap = $attr.SelectSingleNode("md:Properties/md:Name", $ns)
		if ($ap -and $ap.InnerText) {
			$allChildNames["Attr:$($ap.InnerText)"] = $ap.InnerText
		}
	}

	if ($attrCount -gt 0) {
		if ($check6Ok) {
			Report-OK "6. Attributes: $attrCount checked (UUID, Name, Type)"
		}
	} else {
		Report-OK "6. Attributes: none"
	}
} else {
	Report-OK "6. Attributes: N/A"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 7: TabularSections ---

if ($childObjNode) {
	$tsSections = $childObjNode.SelectNodes("md:TabularSection", $ns)
	if ($tsSections.Count -gt 0) {
		$check7Ok = $true
		$tsCount = 0
		$tsAttrTotal = 0

		foreach ($ts in $tsSections) {
			if ($script:stopped) { break }
			$tsCount++

			$tsUuid = $ts.GetAttribute("uuid")
			if (-not $tsUuid -or $tsUuid -notmatch $guidPattern) {
				Report-Error "7. TabularSection #${tsCount}: invalid or missing uuid"
				$check7Ok = $false
			}

			$tsProps = $ts.SelectSingleNode("md:Properties", $ns)
			$tsNameNode = if ($tsProps) { $tsProps.SelectSingleNode("md:Name", $ns) } else { $null }
			$tsName = if ($tsNameNode -and $tsNameNode.InnerText) { $tsNameNode.InnerText } else { "(unnamed)" }

			if (-not $tsNameNode -or -not $tsNameNode.InnerText) {
				Report-Error "7. TabularSection #${tsCount}: missing or empty Name"
				$check7Ok = $false
			} elseif ($tsName -notmatch $identPattern) {
				Report-Error "7. TabularSection '$tsName': invalid identifier"
				$check7Ok = $false
			}

			$allChildNames["TS:$tsName"] = $tsName

			# InternalInfo — expect 2 GeneratedType
			$tsIntInfo = $ts.SelectSingleNode("md:InternalInfo", $ns)
			if ($tsIntInfo) {
				$tsGens = $tsIntInfo.SelectNodes("xr:GeneratedType", $ns)
				if ($tsGens.Count -lt 2) {
					Report-Warn "7. TabularSection '$tsName': expected 2 GeneratedType, found $($tsGens.Count)"
				}
			}

			# Inner attributes
			$tsChildObj = $ts.SelectSingleNode("md:ChildObjects", $ns)
			if ($tsChildObj) {
				$tsAttrs = $tsChildObj.SelectNodes("md:Attribute", $ns)
				$tsAttrNames = @{}
				foreach ($ta in $tsAttrs) {
					$taOk = Check-Attribute -node $ta -context "TabularSection '$tsName'."
					if (-not $taOk) { $check7Ok = $false }
					$tsAttrTotal++

					$taProps = $ta.SelectSingleNode("md:Properties/md:Name", $ns)
					if ($taProps -and $taProps.InnerText) {
						if ($tsAttrNames.ContainsKey($taProps.InnerText)) {
							Report-Error "7. Duplicate attribute '$($taProps.InnerText)' in TabularSection '$tsName'"
							$check7Ok = $false
						} else {
							$tsAttrNames[$taProps.InnerText] = $true
						}
					}
				}
			}
		}

		if ($check7Ok) {
			Report-OK "7. TabularSections: $tsCount sections, $tsAttrTotal inner attributes"
		}
	} else {
		Report-OK "7. TabularSections: none"
	}
} else {
	Report-OK "7. TabularSections: N/A"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 8: Name uniqueness ---

$check8Ok = $true

# Collect all names: attributes + tabular sections + forms + templates + commands
$allNames = @{}

if ($childObjNode) {
	$nameKinds = @(
		@{ XPath = "md:Attribute"; Kind = "Attribute" },
		@{ XPath = "md:TabularSection"; Kind = "TabularSection" },
		@{ XPath = "md:Command"; Kind = "Command" }
	)

	foreach ($nk in $nameKinds) {
		$nodes = $childObjNode.SelectNodes($nk.XPath, $ns)
		foreach ($node in $nodes) {
			$np = $node.SelectSingleNode("md:Properties/md:Name", $ns)
			if ($np -and $np.InnerText) {
				$nameVal = $np.InnerText
				$key = "$($nk.Kind):$nameVal"
				if ($allNames.ContainsKey($nameVal)) {
					Report-Error "8. Duplicate name '$nameVal' ($($nk.Kind) conflicts with $($allNames[$nameVal]))"
					$check8Ok = $false
				} else {
					$allNames[$nameVal] = $nk.Kind
				}
			}
		}
	}

	# Forms and Templates are simple text nodes
	foreach ($fn in $formNames) {
		if ($allNames.ContainsKey($fn)) {
			Report-Error "8. Duplicate name '$fn' (Form conflicts with $($allNames[$fn]))"
			$check8Ok = $false
		} else {
			$allNames[$fn] = "Form"
		}
	}
	foreach ($tn in $templateNames) {
		if ($allNames.ContainsKey($tn)) {
			Report-Error "8. Duplicate name '$tn' (Template conflicts with $($allNames[$tn]))"
			$check8Ok = $false
		} else {
			$allNames[$tn] = "Template"
		}
	}
}

if ($check8Ok) {
	Report-OK "8. Name uniqueness: $($allNames.Count) names, all unique"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 9: File existence (forms and templates on disk) ---

$check9Ok = $true
$filesChecked = 0

# Object directory: same level as root XML, named after the object
$objDir = Join-Path $srcDir $objName

foreach ($fn in $formNames) {
	# FormName.xml — form descriptor
	$formMetaXml = Join-Path (Join-Path $objDir "Forms") "$fn.xml"
	if (-not (Test-Path $formMetaXml)) {
		Report-Error "9. Missing form descriptor: Forms/$fn.xml"
		$check9Ok = $false
	} else {
		$filesChecked++
	}

	# FormName/Ext/Form.xml — form layout
	$formXml = Join-Path (Join-Path (Join-Path (Join-Path $objDir "Forms") $fn) "Ext") "Form.xml"
	if (-not (Test-Path $formXml)) {
		Report-Error "9. Missing form layout: Forms/$fn/Ext/Form.xml"
		$check9Ok = $false
	} else {
		$filesChecked++
	}
}

foreach ($tn in $templateNames) {
	# TemplateName.xml — template descriptor
	$tplMetaXml = Join-Path (Join-Path $objDir "Templates") "$tn.xml"
	if (-not (Test-Path $tplMetaXml)) {
		Report-Error "9. Missing template descriptor: Templates/$tn.xml"
		$check9Ok = $false
	} else {
		$filesChecked++
	}

	# TemplateName/Ext/Template.* — template content (extension varies)
	$tplExtDir = Join-Path (Join-Path (Join-Path $objDir "Templates") $tn) "Ext"
	if (Test-Path $tplExtDir) {
		$tplFiles = @(Get-ChildItem $tplExtDir -Filter "Template.*" -File)
		if ($tplFiles.Count -eq 0) {
			Report-Error "9. Missing template content: Templates/$tn/Ext/Template.*"
			$check9Ok = $false
		} else {
			$filesChecked++
		}
	} else {
		Report-Error "9. Missing template Ext directory: Templates/$tn/Ext/"
		$check9Ok = $false
	}
}

# ObjectModule.bsl
$objModule = Join-Path (Join-Path $objDir "Ext") "ObjectModule.bsl"
if (Test-Path $objModule) {
	$filesChecked++
}

if ($check9Ok) {
	if ($filesChecked -gt 0) {
		Report-OK "9. File existence: $filesChecked files verified"
	} else {
		Report-OK "9. File existence: no forms/templates to check"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 10: Form descriptors structure ---

$check10Ok = $true
$formsChecked = 0

foreach ($fn in $formNames) {
	$formMetaXml = Join-Path (Join-Path $objDir "Forms") "$fn.xml"
	if (-not (Test-Path $formMetaXml)) { continue }

	try {
		$fDoc = New-Object System.Xml.XmlDocument
		$fDoc.PreserveWhitespace = $false
		$fDoc.Load($formMetaXml)
		$fRoot = $fDoc.DocumentElement

		if ($fRoot.LocalName -ne "MetaDataObject") {
			Report-Error "10. Form '$fn': root element is '$($fRoot.LocalName)', expected 'MetaDataObject'"
			$check10Ok = $false
			continue
		}

		$fTypeNode = $fRoot.SelectSingleNode("md:Form", $ns)
		if (-not $fTypeNode) {
			Report-Error "10. Form '$fn': missing <Form> element"
			$check10Ok = $false
			continue
		}

		$fUuid = $fTypeNode.GetAttribute("uuid")
		if (-not $fUuid -or $fUuid -notmatch $guidPattern) {
			Report-Error "10. Form '$fn': invalid or missing uuid"
			$check10Ok = $false
		}

		$fProps = $fTypeNode.SelectSingleNode("md:Properties", $ns)
		if ($fProps) {
			$fName = $fProps.SelectSingleNode("md:Name", $ns)
			if ($fName -and $fName.InnerText -ne $fn) {
				Report-Error "10. Form '$fn': Name in descriptor is '$($fName.InnerText)', expected '$fn'"
				$check10Ok = $false
			}

			# FormType should be Managed
			$fType = $fProps.SelectSingleNode("md:FormType", $ns)
			if ($fType -and $fType.InnerText -ne "Managed") {
				Report-Warn "10. Form '$fn': FormType is '$($fType.InnerText)' (expected 'Managed')"
			}
		}

		$formsChecked++
	} catch {
		Report-Error "10. Form '$fn': XML parse error: $($_.Exception.Message)"
		$check10Ok = $false
	}
}

if ($check10Ok) {
	if ($formsChecked -gt 0) {
		Report-OK "10. Form descriptors: $formsChecked checked"
	} else {
		Report-OK "10. Form descriptors: none to check"
	}
}

# --- Final output ---

& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
