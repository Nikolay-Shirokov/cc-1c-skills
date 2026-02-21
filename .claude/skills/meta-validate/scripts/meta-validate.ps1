# meta-validate v1.0 — Validate 1C metadata object structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
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

$validTypes = @(
	"Catalog","Document","Enum","Constant",
	"InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister",
	"ChartOfAccounts","ChartOfCharacteristicTypes","ChartOfCalculationTypes",
	"BusinessProcess","Task","ExchangePlan","DocumentJournal",
	"Report","DataProcessor",
	"CommonModule","ScheduledJob","EventSubscription",
	"HTTPService","WebService","DefinedType"
)

# GeneratedType categories by type
$generatedTypeCategories = @{
	"Catalog"                    = @("Object","Ref","Selection","List","Manager")
	"Document"                   = @("Object","Ref","Selection","List","Manager")
	"Enum"                       = @("Ref","Manager","List")
	"Constant"                   = @("Manager","ValueManager","ValueKey")
	"InformationRegister"        = @("Record","Manager","Selection","List","RecordSet","RecordKey","RecordManager")
	"AccumulationRegister"       = @("Record","Manager","Selection","List","RecordSet","RecordKey")
	"AccountingRegister"         = @("Record","Manager","Selection","List","RecordSet","RecordKey","ExtDimensions")
	"CalculationRegister"        = @("Record","Manager","Selection","List","RecordSet","RecordKey","Recalcs")
	"ChartOfAccounts"            = @("Object","Ref","Selection","List","Manager","ExtDimensionTypes","ExtDimensionTypesRow")
	"ChartOfCharacteristicTypes" = @("Object","Ref","Selection","List","Manager","Characteristic")
	"ChartOfCalculationTypes"    = @("Object","Ref","Selection","List","Manager","DisplacingCalculationTypes","DisplacingCalculationTypesRow","BaseCalculationTypes","BaseCalculationTypesRow","LeadingCalculationTypes","LeadingCalculationTypesRow")
	"BusinessProcess"            = @("Object","Ref","Selection","List","Manager","RoutePointRef")
	"Task"                       = @("Object","Ref","Selection","List","Manager")
	"ExchangePlan"               = @("Object","Ref","Selection","List","Manager")
	"DocumentJournal"            = @("Selection","List","Manager")
	"Report"                     = @("Object","Manager")
	"DataProcessor"              = @("Object","Manager")
	"DefinedType"                = @("DefinedType")
}

# Types that have NO InternalInfo / GeneratedType
$typesWithoutInternalInfo = @("CommonModule","ScheduledJob","EventSubscription")

# StandardAttributes by type
$standardAttributesByType = @{
	"Catalog"                    = @("PredefinedDataName","Predefined","Ref","DeletionMark","IsFolder","Owner","Parent","Description","Code")
	"Document"                   = @("Posted","Ref","DeletionMark","Date","Number")
	"Enum"                       = @("Order","Ref")
	"InformationRegister"        = @("Active","LineNumber","Recorder","Period")
	"AccumulationRegister"       = @("Active","LineNumber","Recorder","Period","RecordType")
	"AccountingRegister"         = @("Active","Period","Recorder","LineNumber","Account")
	"CalculationRegister"        = @("Active","Recorder","LineNumber","RegistrationPeriod","CalculationType","ReversingEntry","ActionPeriod","BegOfActionPeriod","EndOfActionPeriod","BegOfBasePeriod","EndOfBasePeriod")
	"ChartOfAccounts"            = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","Order","Type","OffBalance")
	"ChartOfCharacteristicTypes" = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","Parent","IsFolder","ValueType")
	"ChartOfCalculationTypes"    = @("PredefinedDataName","Predefined","Ref","DeletionMark","Description","Code","ActionPeriodIsBasic")
	"BusinessProcess"            = @("Ref","DeletionMark","Date","Number","Started","Completed","HeadTask")
	"Task"                       = @("Ref","DeletionMark","Date","Number","Executed","Description","RoutePoint","BusinessProcess")
	"ExchangePlan"               = @("Ref","DeletionMark","Code","Description","ThisNode","SentNo","ReceivedNo")
	"DocumentJournal"            = @("Type","Ref","Date","Posted","DeletionMark","Number")
}

# Types that have StandardAttributes block
$typesWithStdAttrs = @(
	"Catalog","Document","Enum",
	"InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister",
	"ChartOfAccounts","ChartOfCharacteristicTypes","ChartOfCalculationTypes",
	"BusinessProcess","Task","ExchangePlan","DocumentJournal"
)

# ChildObjects rules: what child element types are valid for each metadata type
$childObjectRules = @{
	"Catalog"                    = @("Attribute","TabularSection","Form","Template","Command")
	"Document"                   = @("Attribute","TabularSection","Form","Template","Command")
	"ExchangePlan"               = @("Attribute","TabularSection","Form","Template","Command")
	"ChartOfAccounts"            = @("Attribute","TabularSection","Form","Template","Command","AccountingFlag","ExtDimensionAccountingFlag")
	"ChartOfCharacteristicTypes" = @("Attribute","TabularSection","Form","Template","Command")
	"ChartOfCalculationTypes"    = @("Attribute","TabularSection","Form","Template","Command")
	"BusinessProcess"            = @("Attribute","TabularSection","Form","Template","Command")
	"Task"                       = @("Attribute","TabularSection","Form","Template","Command","AddressingAttribute")
	"Report"                     = @("Attribute","TabularSection","Form","Template","Command")
	"DataProcessor"              = @("Attribute","TabularSection","Form","Template","Command")
	"Enum"                       = @("EnumValue","Form","Template","Command")
	"InformationRegister"        = @("Dimension","Resource","Attribute","Form","Template","Command")
	"AccumulationRegister"       = @("Dimension","Resource","Attribute","Form","Template","Command")
	"AccountingRegister"         = @("Dimension","Resource","Attribute","Form","Template","Command")
	"CalculationRegister"        = @("Dimension","Resource","Attribute","Form","Template","Command","Recalculation")
	"DocumentJournal"            = @("Column","Form","Template","Command")
	"HTTPService"                = @("URLTemplate")
	"WebService"                 = @("Operation")
	"Constant"                   = @("Form")
	"DefinedType"                = @()
	"CommonModule"               = @()
	"ScheduledJob"               = @()
	"EventSubscription"          = @()
}

# Valid enum property values
$validPropertyValues = @{
	"CodeType"                       = @("String","Number")
	"CodeAllowedLength"              = @("Variable","Fixed")
	"NumberType"                     = @("String","Number")
	"NumberAllowedLength"            = @("Variable","Fixed")
	"Posting"                        = @("Allow","Deny")
	"RealTimePosting"                = @("Allow","Deny")
	"RegisterRecordsDeletion"        = @("AutoDelete","AutoDeleteOnUnpost","AutoDeleteOff")
	"RegisterRecordsWritingOnPost"   = @("WriteModified","WriteSelected","WriteAll")
	"DataLockControlMode"            = @("Automatic","Managed")
	"FullTextSearch"                 = @("Use","DontUse")
	"DefaultPresentation"            = @("AsDescription","AsCode")
	"HierarchyType"                  = @("HierarchyFoldersAndItems","HierarchyItemsOnly")
	"EditType"                       = @("InDialog","InList","BothWays")
	"WriteMode"                      = @("Independent","RecorderSubordinate")
	"InformationRegisterPeriodicity" = @("Nonperiodical","Second","Day","Month","Quarter","Year","RecorderPosition")
	"RegisterType"                   = @("Balance","Turnovers")
	"ReturnValuesReuse"              = @("DontUse","DuringRequest","DuringSession")
	"ReuseSessions"                  = @("DontUse","AutoUse")
	"FillChecking"                   = @("DontCheck","ShowError","ShowWarning")
	"Indexing"                       = @("DontIndex","Index","IndexWithAdditionalOrder")
	"DataHistory"                    = @("Use","DontUse")
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

# --- 2. Register namespaces ---

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("cfg", "http://v8.1c.ru/8.1/data/enterprise/current-config")

$root = $xmlDoc.DocumentElement

# --- Check 1: Root structure ---

$check1Ok = $true

# Root must be MetaDataObject
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

# Version attribute
$version = $root.GetAttribute("version")
if (-not $version) {
	Report-Warn "1. Missing version attribute on MetaDataObject"
} elseif ($version -ne "2.17" -and $version -ne "2.20") {
	Report-Warn "1. Unusual version '$version' (expected 2.17 or 2.20)"
}

# Detect type element — exactly one child element in md namespace
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

if ($validTypes -notcontains $mdType) {
	Report-Error "1. Unrecognized metadata type: $mdType"
	& $finalize
	exit 1
}

# UUID on type element
$typeUuid = $typeNode.GetAttribute("uuid")
if (-not $typeUuid) {
	Report-Error "1. Missing uuid on <$mdType> element"
	$check1Ok = $false
} elseif ($typeUuid -notmatch $guidPattern) {
	Report-Error "1. Invalid uuid '$typeUuid' on <$mdType>"
	$check1Ok = $false
}

# Get object name early for header
$propsNode = $typeNode.SelectSingleNode("md:Properties", $ns)
$nameNode = if ($propsNode) { $propsNode.SelectSingleNode("md:Name", $ns) } else { $null }
$objName = if ($nameNode -and $nameNode.InnerText) { $nameNode.InnerText } else { "(unknown)" }

# Now emit header
$script:output.Insert(0, "=== Validation: $mdType.$objName ===$([Environment]::NewLine)") | Out-Null

if ($check1Ok) {
	Report-OK "1. Root structure: MetaDataObject/$mdType, version $version"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 2: InternalInfo ---

$internalInfo = $typeNode.SelectSingleNode("md:InternalInfo", $ns)

if ($typesWithoutInternalInfo -contains $mdType) {
	# These types should NOT have InternalInfo with GeneratedType
	if ($internalInfo) {
		$genTypes = $internalInfo.SelectNodes("xr:GeneratedType", $ns)
		if ($genTypes.Count -gt 0) {
			Report-Warn "2. InternalInfo: $mdType should not have GeneratedType entries, found $($genTypes.Count)"
		} else {
			Report-OK "2. InternalInfo: absent or empty (correct for $mdType)"
		}
	} else {
		Report-OK "2. InternalInfo: absent (correct for $mdType)"
	}
} elseif ($generatedTypeCategories.ContainsKey($mdType)) {
	$expectedCategories = $generatedTypeCategories[$mdType]
	if (-not $internalInfo) {
		Report-Error "2. InternalInfo: missing (expected $($expectedCategories.Count) GeneratedType)"
	} else {
		$genTypes = $internalInfo.SelectNodes("xr:GeneratedType", $ns)
		$check2Ok = $true
		$foundCategories = @()

		foreach ($gt in $genTypes) {
			$gtName = $gt.GetAttribute("name")
			$gtCategory = $gt.GetAttribute("category")
			$foundCategories += $gtCategory

			# Validate name format: Prefix.ObjectName
			if ($gtName -and $objName -ne "(unknown)") {
				if (-not $gtName.EndsWith(".$objName")) {
					Report-Error "2. GeneratedType name '$gtName' does not end with '.$objName'"
					$check2Ok = $false
				}
			}

			# Validate category
			if ($expectedCategories -notcontains $gtCategory) {
				Report-Warn "2. Unexpected GeneratedType category '$gtCategory' for $mdType"
			}

			# Validate TypeId and ValueId UUIDs
			$typeId = $gt.SelectSingleNode("xr:TypeId", $ns)
			$valueId = $gt.SelectSingleNode("xr:ValueId", $ns)
			if ($typeId -and $typeId.InnerText -notmatch $guidPattern) {
				Report-Error "2. Invalid TypeId UUID in GeneratedType '$gtCategory'"
				$check2Ok = $false
			}
			if ($valueId -and $valueId.InnerText -notmatch $guidPattern) {
				Report-Error "2. Invalid ValueId UUID in GeneratedType '$gtCategory'"
				$check2Ok = $false
			}
		}

		# ExchangePlan: check for ThisNode
		if ($mdType -eq "ExchangePlan") {
			$thisNode = $internalInfo.SelectSingleNode("xr:ThisNode", $ns)
			if (-not $thisNode) {
				Report-Warn "2. ExchangePlan missing xr:ThisNode in InternalInfo"
			} elseif ($thisNode.InnerText -notmatch $guidPattern) {
				Report-Error "2. ExchangePlan xr:ThisNode has invalid UUID"
				$check2Ok = $false
			}
		}

		# Check count mismatch
		$missingCats = @($expectedCategories | Where-Object { $foundCategories -notcontains $_ })
		if ($missingCats.Count -gt 0) {
			Report-Warn "2. Missing GeneratedType categories: $($missingCats -join ', ')"
		}

		if ($check2Ok) {
			$catList = ($foundCategories | Sort-Object) -join ", "
			Report-OK "2. InternalInfo: $($genTypes.Count) GeneratedType ($catList)"
		}
	}
} else {
	Report-OK "2. InternalInfo: N/A for $mdType"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 3: Properties — Name, Synonym ---

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
			Report-Warn "3. Properties: Name '$nameVal' is longer than 80 characters ($($nameVal.Length))"
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

	if ($check3Ok) {
		$synInfo = if ($synPresent) { "Synonym present" } else { "no Synonym" }
		Report-OK "3. Properties: Name=`"$objName`", $synInfo"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 4: Property values — enum properties ---

if ($propsNode) {
	$enumChecked = 0
	$check4Ok = $true

	foreach ($propName in $validPropertyValues.Keys) {
		$propNode = $propsNode.SelectSingleNode("md:$propName", $ns)
		if ($propNode -and $propNode.InnerText) {
			$val = $propNode.InnerText
			$allowed = $validPropertyValues[$propName]
			if ($allowed -notcontains $val) {
				Report-Error "4. Property '$propName' has invalid value '$val' (allowed: $($allowed -join ', '))"
				$check4Ok = $false
			}
			$enumChecked++
		}
	}

	if ($check4Ok) {
		Report-OK "4. Property values: $enumChecked enum properties checked"
	}
} else {
	Report-Warn "4. No Properties block to check"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 5: StandardAttributes ---

if ($typesWithStdAttrs -contains $mdType) {
	$stdAttrNode = $propsNode.SelectSingleNode("md:StandardAttributes", $ns)
	if (-not $stdAttrNode) {
		# StandardAttributes block is optional for some types (e.g. Enum)
		Report-OK "5. StandardAttributes: absent (optional for $mdType)"
	} else {
		$stdAttrs = $stdAttrNode.SelectNodes("xr:StandardAttribute", $ns)
		$expectedStdAttrs = $standardAttributesByType[$mdType]
		$check5Ok = $true

		$foundNames = @()
		foreach ($sa in $stdAttrs) {
			$saName = $sa.GetAttribute("name")
			if ($saName) {
				$foundNames += $saName
				if ($expectedStdAttrs -notcontains $saName) {
					# AccountingRegister has dynamic ExtDimension{N}/ExtDimensionType{N} and optional PeriodAdjustment
					$isDynamic = ($mdType -eq "AccountingRegister" -and ($saName -match '^ExtDimension\d+$' -or $saName -match '^ExtDimensionType\d+$' -or $saName -eq "PeriodAdjustment"))
					# CalculationRegister has conditional period attrs
					$isCalcDynamic = ($mdType -eq "CalculationRegister" -and $saName -in @("ActionPeriod","BegOfActionPeriod","EndOfActionPeriod","BegOfBasePeriod","EndOfBasePeriod"))
					if (-not $isDynamic -and -not $isCalcDynamic) {
						Report-Warn "5. Unexpected StandardAttribute '$saName' for $mdType"
					}
				}
			} else {
				Report-Error "5. StandardAttribute without 'name' attribute"
				$check5Ok = $false
			}
		}

		if ($expectedStdAttrs) {
			$missingAttrs = @($expectedStdAttrs | Where-Object { $foundNames -notcontains $_ })
			if ($missingAttrs.Count -gt 0) {
				Report-Warn "5. Missing StandardAttributes: $($missingAttrs -join ', ')"
			}
		}

		if ($check5Ok) {
			Report-OK "5. StandardAttributes: $($stdAttrs.Count) entries"
		}
	}
} else {
	Report-OK "5. StandardAttributes: N/A for $mdType"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 6: ChildObjects — allowed element types ---

$childObjNode = $typeNode.SelectSingleNode("md:ChildObjects", $ns)
$allowedChildren = $childObjectRules[$mdType]

if ($childObjNode) {
	$check6Ok = $true
	$childCounts = @{}

	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childTag = $child.LocalName

		if ($allowedChildren -notcontains $childTag) {
			Report-Error "6. ChildObjects: disallowed element '$childTag' for $mdType"
			$check6Ok = $false
		}

		if (-not $childCounts.ContainsKey($childTag)) {
			$childCounts[$childTag] = 0
		}
		$childCounts[$childTag]++
	}

	if ($check6Ok) {
		$summary = ($childCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)($($_.Value))" }) -join ", "
		if ($summary) {
			Report-OK "6. ChildObjects types: $summary"
		} else {
			Report-OK "6. ChildObjects: empty (valid for $mdType)"
		}
	}
} elseif ($allowedChildren.Count -eq 0) {
	Report-OK "6. ChildObjects: absent (correct for $mdType)"
} else {
	# Some types may have no children — that's OK
	Report-OK "6. ChildObjects: absent"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 7: Attributes/Dimensions/Resources/EnumValues/Columns — UUID, Name, Type ---

function Check-ChildElement {
	param(
		[System.Xml.XmlNode]$node,
		[string]$kind,
		[bool]$requireType
	)

	$uuid = $node.GetAttribute("uuid")
	if (-not $uuid) {
		Report-Error "7. $kind missing uuid"
		return $false
	} elseif ($uuid -notmatch $guidPattern) {
		Report-Error "7. $kind has invalid uuid '$uuid'"
		return $false
	}

	$elProps = $node.SelectSingleNode("md:Properties", $ns)
	if (-not $elProps) {
		Report-Error "7. $kind (uuid=$uuid) missing Properties"
		return $false
	}

	$elName = $elProps.SelectSingleNode("md:Name", $ns)
	if (-not $elName -or -not $elName.InnerText) {
		Report-Error "7. $kind (uuid=$uuid) missing or empty Name"
		return $false
	}

	$nameVal = $elName.InnerText
	if ($nameVal -notmatch $identPattern) {
		Report-Error "7. $kind '$nameVal' has invalid identifier"
		return $false
	}

	if ($requireType) {
		$typeEl = $elProps.SelectSingleNode("md:Type", $ns)
		if (-not $typeEl) {
			Report-Error "7. $kind '$nameVal' missing Type block"
			return $false
		}
		$v8Types = $typeEl.SelectNodes("v8:Type", $ns)
		$v8TypeSets = $typeEl.SelectNodes("v8:TypeSet", $ns)
		if ($v8Types.Count -eq 0 -and $v8TypeSets.Count -eq 0) {
			Report-Error "7. $kind '$nameVal' Type block has no v8:Type or v8:TypeSet"
			return $false
		}
	}

	return $true
}

if ($childObjNode) {
	$check7Ok = $true
	$check7Count = 0
	$elementKinds = @("Attribute","Dimension","Resource","EnumValue","Column")

	foreach ($kind in $elementKinds) {
		$elements = $childObjNode.SelectNodes("md:$kind", $ns)
		$requireType = ($kind -ne "EnumValue" -and $kind -ne "Column")
		foreach ($el in $elements) {
			if ($script:stopped) { break }
			$ok = Check-ChildElement -node $el -kind $kind -requireType $requireType
			if (-not $ok) { $check7Ok = $false }
			$check7Count++
		}
	}

	if ($check7Ok -and $check7Count -gt 0) {
		Report-OK "7. Child elements: $check7Count items checked (UUID, Name, Type)"
	} elseif ($check7Count -eq 0) {
		Report-OK "7. Child elements: none to check"
	}
} else {
	Report-OK "7. Child elements: N/A (no ChildObjects)"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 8: Name uniqueness ---

function Check-Uniqueness {
	param(
		[System.Xml.XmlNodeList]$nodes,
		[string]$kind
	)

	$names = @{}
	$hasDupes = $false

	foreach ($node in $nodes) {
		$elProps = $node.SelectSingleNode("md:Properties", $ns)
		if (-not $elProps) { continue }
		$elName = $elProps.SelectSingleNode("md:Name", $ns)
		if (-not $elName -or -not $elName.InnerText) { continue }

		$nameVal = $elName.InnerText
		if ($names.ContainsKey($nameVal)) {
			Report-Error "8. Duplicate $kind name: '$nameVal'"
			$hasDupes = $true
		} else {
			$names[$nameVal] = $true
		}
	}

	return (-not $hasDupes)
}

if ($childObjNode) {
	$check8Ok = $true

	# Attributes
	$attrs = $childObjNode.SelectNodes("md:Attribute", $ns)
	if ($attrs.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $attrs -kind "Attribute")) { $check8Ok = $false }
	}

	# TabularSections
	$tss = $childObjNode.SelectNodes("md:TabularSection", $ns)
	if ($tss.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $tss -kind "TabularSection")) { $check8Ok = $false }
	}

	# Dimensions
	$dims = $childObjNode.SelectNodes("md:Dimension", $ns)
	if ($dims.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $dims -kind "Dimension")) { $check8Ok = $false }
	}

	# Resources
	$ress = $childObjNode.SelectNodes("md:Resource", $ns)
	if ($ress.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $ress -kind "Resource")) { $check8Ok = $false }
	}

	# EnumValues
	$evs = $childObjNode.SelectNodes("md:EnumValue", $ns)
	if ($evs.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $evs -kind "EnumValue")) { $check8Ok = $false }
	}

	# Columns (DocumentJournal)
	$cols = $childObjNode.SelectNodes("md:Column", $ns)
	if ($cols.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $cols -kind "Column")) { $check8Ok = $false }
	}

	# URLTemplates (HTTPService)
	$urlTs = $childObjNode.SelectNodes("md:URLTemplate", $ns)
	if ($urlTs.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $urlTs -kind "URLTemplate")) { $check8Ok = $false }
	}

	# Operations (WebService)
	$ops = $childObjNode.SelectNodes("md:Operation", $ns)
	if ($ops.Count -gt 0) {
		if (-not (Check-Uniqueness -nodes $ops -kind "Operation")) { $check8Ok = $false }
	}

	if ($check8Ok) {
		Report-OK "8. Name uniqueness: all names unique"
	}
} else {
	Report-OK "8. Name uniqueness: N/A"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 9: TabularSections — internal structure ---

if ($childObjNode) {
	$tsSections = $childObjNode.SelectNodes("md:TabularSection", $ns)
	if ($tsSections.Count -gt 0) {
		$check9Ok = $true
		$tsCount = 0

		foreach ($ts in $tsSections) {
			if ($script:stopped) { break }
			$tsCount++

			# UUID
			$tsUuid = $ts.GetAttribute("uuid")
			if (-not $tsUuid -or $tsUuid -notmatch $guidPattern) {
				Report-Error "9. TabularSection #${tsCount}: invalid or missing uuid"
				$check9Ok = $false
			}

			# Name
			$tsProps = $ts.SelectSingleNode("md:Properties", $ns)
			$tsNameNode = if ($tsProps) { $tsProps.SelectSingleNode("md:Name", $ns) } else { $null }
			$tsName = if ($tsNameNode) { $tsNameNode.InnerText } else { "(unnamed)" }

			if (-not $tsNameNode -or -not $tsNameNode.InnerText) {
				Report-Error "9. TabularSection #${tsCount}: missing or empty Name"
				$check9Ok = $false
			}

			# InternalInfo with 2 GeneratedType (TabularSection + TabularSectionRow)
			$tsIntInfo = $ts.SelectSingleNode("md:InternalInfo", $ns)
			if ($tsIntInfo) {
				$tsGens = $tsIntInfo.SelectNodes("xr:GeneratedType", $ns)
				if ($tsGens.Count -lt 2) {
					Report-Warn "9. TabularSection '$tsName': expected 2 GeneratedType, found $($tsGens.Count)"
				}
			}

			# Attributes inside TS
			$tsChildObj = $ts.SelectSingleNode("md:ChildObjects", $ns)
			if ($tsChildObj) {
				$tsAttrs = $tsChildObj.SelectNodes("md:Attribute", $ns)
				$tsAttrNames = @{}
				foreach ($ta in $tsAttrs) {
					$taOk = Check-ChildElement -node $ta -kind "TabularSection '$tsName'.Attribute" -requireType $true
					if (-not $taOk) { $check9Ok = $false }

					# Check name uniqueness within TS
					$taProps = $ta.SelectSingleNode("md:Properties", $ns)
					$taName = if ($taProps) { $taProps.SelectSingleNode("md:Name", $ns) } else { $null }
					if ($taName -and $taName.InnerText) {
						if ($tsAttrNames.ContainsKey($taName.InnerText)) {
							Report-Error "9. Duplicate attribute '$($taName.InnerText)' in TabularSection '$tsName'"
							$check9Ok = $false
						} else {
							$tsAttrNames[$taName.InnerText] = $true
						}
					}
				}

				# StandardAttributes of TS: expect LineNumber
				$tsStdAttr = $tsProps.SelectSingleNode("md:StandardAttributes", $ns)
				if ($tsStdAttr) {
					$tsStdAttrs = $tsStdAttr.SelectNodes("xr:StandardAttribute", $ns)
					$hasLineNumber = $false
					foreach ($tsa in $tsStdAttrs) {
						if ($tsa.GetAttribute("name") -eq "LineNumber") { $hasLineNumber = $true }
					}
					if (-not $hasLineNumber) {
						Report-Warn "9. TabularSection '$tsName': missing LineNumber StandardAttribute"
					}
				}
			}
		}

		if ($check9Ok) {
			Report-OK "9. TabularSections: $tsCount sections, structure valid"
		}
	} else {
		Report-OK "9. TabularSections: none present"
	}
} else {
	Report-OK "9. TabularSections: N/A"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 10: Cross-property consistency ---

$check10Ok = $true
$check10Issues = 0

if ($propsNode) {
	# HierarchyType set but Hierarchical = false
	$hierarchical = $propsNode.SelectSingleNode("md:Hierarchical", $ns)
	$hierarchyType = $propsNode.SelectSingleNode("md:HierarchyType", $ns)
	if ($hierarchical -and $hierarchyType -and $hierarchical.InnerText -eq "false" -and $hierarchyType.InnerText) {
		Report-Warn "10. HierarchyType='$($hierarchyType.InnerText)' but Hierarchical=false"
		$check10Issues++
	}

	# CommonModule: no context enabled
	if ($mdType -eq "CommonModule") {
		$contexts = @("Server","ClientManagedApplication","ClientOrdinaryApplication","ExternalConnection","ServerCall","Global")
		$anyEnabled = $false
		foreach ($ctx in $contexts) {
			$ctxNode = $propsNode.SelectSingleNode("md:$ctx", $ns)
			if ($ctxNode -and $ctxNode.InnerText -eq "true") {
				$anyEnabled = $true
				break
			}
		}
		if (-not $anyEnabled) {
			Report-Warn "10. CommonModule: no execution context enabled"
			$check10Issues++
		}
	}

	# EventSubscription: empty Handler
	if ($mdType -eq "EventSubscription") {
		$handler = $propsNode.SelectSingleNode("md:Handler", $ns)
		if (-not $handler -or -not $handler.InnerText.Trim()) {
			Report-Error "10. EventSubscription: empty Handler"
			$check10Ok = $false
			$check10Issues++
		}

		# Empty Source
		$source = $propsNode.SelectSingleNode("md:Source", $ns)
		$hasSource = $false
		if ($source) {
			$sourceTypes = $source.SelectNodes("v8:Type", $ns)
			if ($sourceTypes.Count -gt 0) { $hasSource = $true }
		}
		if (-not $hasSource) {
			Report-Warn "10. EventSubscription: no Source types specified"
			$check10Issues++
		}
	}

	# ScheduledJob: empty MethodName
	if ($mdType -eq "ScheduledJob") {
		$method = $propsNode.SelectSingleNode("md:MethodName", $ns)
		if (-not $method -or -not $method.InnerText.Trim()) {
			Report-Error "10. ScheduledJob: empty MethodName"
			$check10Ok = $false
			$check10Issues++
		}
	}
}

if ($check10Ok -and $check10Issues -eq 0) {
	Report-OK "10. Cross-property consistency"
} elseif ($check10Ok) {
	# Had warnings but no errors — already reported
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 11: HTTPService/WebService nested structure ---

if ($mdType -eq "HTTPService" -and $childObjNode) {
	$urlTemplates = $childObjNode.SelectNodes("md:URLTemplate", $ns)
	$check11Ok = $true
	$methodCount = 0

	$validHTTPMethods = @("GET","POST","PUT","DELETE","PATCH","HEAD","OPTIONS","MERGE","CONNECT")

	foreach ($ut in $urlTemplates) {
		if ($script:stopped) { break }

		$utProps = $ut.SelectSingleNode("md:Properties", $ns)
		$utNameNode = if ($utProps) { $utProps.SelectSingleNode("md:Name", $ns) } else { $null }
		$utName = if ($utNameNode) { $utNameNode.InnerText } else { "(unnamed)" }

		# Template property
		$tpl = if ($utProps) { $utProps.SelectSingleNode("md:Template", $ns) } else { $null }
		if (-not $tpl -or -not $tpl.InnerText.Trim()) {
			Report-Error "11. HTTPService URLTemplate '$utName': empty Template"
			$check11Ok = $false
		}

		# Methods inside URLTemplate
		$utChildObj = $ut.SelectSingleNode("md:ChildObjects", $ns)
		if ($utChildObj) {
			$methods = $utChildObj.SelectNodes("md:Method", $ns)
			foreach ($m in $methods) {
				$methodCount++
				$mProps = $m.SelectSingleNode("md:Properties", $ns)
				if ($mProps) {
					$httpMethod = $mProps.SelectSingleNode("md:HTTPMethod", $ns)
					if ($httpMethod -and $httpMethod.InnerText) {
						if ($validHTTPMethods -notcontains $httpMethod.InnerText) {
							Report-Error "11. HTTPService URLTemplate '$utName': invalid HTTPMethod '$($httpMethod.InnerText)'"
							$check11Ok = $false
						}
					} else {
						Report-Error "11. HTTPService URLTemplate '$utName': Method missing HTTPMethod"
						$check11Ok = $false
					}
				}
			}
		}
	}

	if ($check11Ok) {
		Report-OK "11. HTTPService: $($urlTemplates.Count) URLTemplate(s), $methodCount method(s)"
	}
} elseif ($mdType -eq "WebService" -and $childObjNode) {
	$operations = $childObjNode.SelectNodes("md:Operation", $ns)
	$check11Ok = $true
	$paramCount = 0

	$validDirections = @("In","Out","InOut")

	foreach ($op in $operations) {
		if ($script:stopped) { break }

		$opProps = $op.SelectSingleNode("md:Properties", $ns)
		$opNameNode = if ($opProps) { $opProps.SelectSingleNode("md:Name", $ns) } else { $null }
		$opName = if ($opNameNode) { $opNameNode.InnerText } else { "(unnamed)" }

		# ReturnType — XDTOReturningValueType
		$retType = if ($opProps) { $opProps.SelectSingleNode("md:XDTOReturningValueType", $ns) } else { $null }
		if (-not $retType -or -not $retType.InnerText.Trim()) {
			Report-Warn "11. WebService Operation '$opName': no XDTOReturningValueType"
		}

		# Parameters inside Operation
		$opChildObj = $op.SelectSingleNode("md:ChildObjects", $ns)
		if ($opChildObj) {
			$params = $opChildObj.SelectNodes("md:Parameter", $ns)
			foreach ($p in $params) {
				$paramCount++
				$pProps = $p.SelectSingleNode("md:Properties", $ns)
				if ($pProps) {
					$dir = $pProps.SelectSingleNode("md:TransferDirection", $ns)
					if ($dir -and $dir.InnerText -and $validDirections -notcontains $dir.InnerText) {
						Report-Error "11. WebService Operation '$opName': Parameter has invalid TransferDirection '$($dir.InnerText)'"
						$check11Ok = $false
					}
				}
			}
		}
	}

	if ($check11Ok) {
		Report-OK "11. WebService: $($operations.Count) operation(s), $paramCount parameter(s)"
	}
} else {
	Report-OK "11. HTTPService/WebService: N/A"
}

# --- Final output ---

& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
