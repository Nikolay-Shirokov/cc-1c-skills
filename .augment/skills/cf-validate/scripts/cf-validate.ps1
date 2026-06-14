# cf-validate v1.3 — Validate 1C configuration root structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$ConfigPath,

	[switch]$Detailed,

	[int]$MaxErrors = 30,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}

if (Test-Path $ConfigPath -PathType Container) {
	$candidate = Join-Path $ConfigPath "Configuration.xml"
	if (Test-Path $candidate) {
		$ConfigPath = $candidate
	} else {
		Write-Host "[ERROR] No Configuration.xml found in directory: $ConfigPath"
		exit 1
	}
}

if (-not (Test-Path $ConfigPath)) {
	Write-Host "[ERROR] File not found: $ConfigPath"
	exit 1
}

$resolvedPath = (Resolve-Path $ConfigPath).Path
$configDir = Split-Path $resolvedPath -Parent

# --- Output infrastructure ---
$script:errors = 0
$script:warnings = 0
$script:okCount = 0
$script:stopped = $false
$script:output = New-Object System.Text.StringBuilder 8192

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
		$result = "=== Validation OK: Configuration.$objName ($checks checks) ==="
	} else {
		Out-Line ""
		Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ($checks checks) ==="
		$result = $script:output.ToString()
	}
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

# 7 fixed ClassIds for Configuration
$validClassIds = @(
	"9cd510cd-abfc-11d4-9434-004095e12fc7",  # managed application module
	"9fcd25a0-4822-11d4-9414-008048da11f9",  # ordinary application module
	"e3687481-0a87-462c-a166-9f34594f9bba",  # session module
	"9de14907-ec23-4a07-96f0-85521cb6b53b",  # external connection module
	"51f2d5d8-ea4d-4064-8892-82951750031e",  # command interface
	"e68182ea-4237-4383-967f-90c1e3370bc7",  # main section command interface
	"fb282519-d103-4dd3-bc12-cb271d631dfc"   # home page / client app interface
)

# 44 types in canonical order
$childObjectTypes = @(
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

# Type -> directory mapping
$childTypeDirMap = @{
	"Language"="Languages"; "Subsystem"="Subsystems"; "StyleItem"="StyleItems"; "Style"="Styles"
	"CommonPicture"="CommonPictures"; "SessionParameter"="SessionParameters"; "Role"="Roles"
	"CommonTemplate"="CommonTemplates"; "FilterCriterion"="FilterCriteria"; "CommonModule"="CommonModules"
	"CommonAttribute"="CommonAttributes"; "ExchangePlan"="ExchangePlans"; "XDTOPackage"="XDTOPackages"
	"WebService"="WebServices"; "HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"
	"SettingsStorage"="SettingsStorages"; "FunctionalOption"="FunctionalOptions"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"; "DefinedType"="DefinedTypes"
	"CommonCommand"="CommonCommands"; "CommandGroup"="CommandGroups"; "Constant"="Constants"
	"CommonForm"="CommonForms"; "Catalog"="Catalogs"; "Document"="Documents"
	"DocumentNumerator"="DocumentNumerators"; "Sequence"="Sequences"
	"DocumentJournal"="DocumentJournals"; "Enum"="Enums"; "Report"="Reports"
	"DataProcessor"="DataProcessors"; "InformationRegister"="InformationRegisters"
	"AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"
	"CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"IntegrationService"="IntegrationServices"
}

# Valid enum values for Configuration properties
$validEnumValues = @{
	"ConfigurationExtensionCompatibilityMode" = @("DontUse","Version8_1","Version8_2_13","Version8_2_16","Version8_3_1","Version8_3_2","Version8_3_3","Version8_3_4","Version8_3_5","Version8_3_6","Version8_3_7","Version8_3_8","Version8_3_9","Version8_3_10","Version8_3_11","Version8_3_12","Version8_3_13","Version8_3_14","Version8_3_15","Version8_3_16","Version8_3_17","Version8_3_18","Version8_3_19","Version8_3_20","Version8_3_21","Version8_3_22","Version8_3_23","Version8_3_24","Version8_3_25","Version8_3_26","Version8_3_27","Version8_3_28","Version8_5_1")
	"DefaultRunMode" = @("ManagedApplication","OrdinaryApplication","Auto")
	"ScriptVariant" = @("Russian","English")
	"DataLockControlMode" = @("Automatic","Managed","AutomaticAndManaged")
	"ObjectAutonumerationMode" = @("NotAutoFree","AutoFree")
	"ModalityUseMode" = @("DontUse","Use","UseWithWarnings")
	"SynchronousPlatformExtensionAndAddInCallUseMode" = @("DontUse","Use","UseWithWarnings")
	"InterfaceCompatibilityMode" = @("Version8_2","Version8_2EnableTaxi","Taxi","TaxiEnableVersion8_2","TaxiEnableVersion8_5","Version8_5EnableTaxi","Version8_5")
	"DatabaseTablespacesUseMode" = @("DontUse","Use")
	"MainClientApplicationWindowMode" = @("Normal","Fullscreen","Kiosk")
	"CompatibilityMode" = @("DontUse","Version8_1","Version8_2_13","Version8_2_16","Version8_3_1","Version8_3_2","Version8_3_3","Version8_3_4","Version8_3_5","Version8_3_6","Version8_3_7","Version8_3_8","Version8_3_9","Version8_3_10","Version8_3_11","Version8_3_12","Version8_3_13","Version8_3_14","Version8_3_15","Version8_3_16","Version8_3_17","Version8_3_18","Version8_3_19","Version8_3_20","Version8_3_21","Version8_3_22","Version8_3_23","Version8_3_24","Version8_3_25","Version8_3_26","Version8_3_27","Version8_3_28","Version8_5_1")
}

# --- 1. Parse XML ---
Out-Line ""

$xmlDoc = $null
try {
	$xmlDoc = New-Object System.Xml.XmlDocument
	$xmlDoc.PreserveWhitespace = $false
	$xmlDoc.Load($resolvedPath)
} catch {
	Out-Line "=== Validation: Configuration (parse failed) ==="
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
$expectedNs = "http://v8.1c.ru/8.3/MDClasses"

if ($root.LocalName -ne "MetaDataObject") {
	Report-Error "1. Root element is '$($root.LocalName)', expected 'MetaDataObject'"
	& $finalize
	exit 1
}

if ($root.NamespaceURI -ne $expectedNs) {
	Report-Error "1. Root namespace is '$($root.NamespaceURI)', expected '$expectedNs'"
	$check1Ok = $false
}

$version = $root.GetAttribute("version")
if (-not $version) {
	Report-Warn "1. Missing version attribute on MetaDataObject"
} elseif ($version -ne "2.17" -and $version -ne "2.20" -and $version -ne "2.21") {
	Report-Warn "1. Unusual version '$version' (expected 2.17, 2.20 or 2.21)"
}

# Must have Configuration child
$cfgNode = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Configuration" -and $child.NamespaceURI -eq $expectedNs) {
		$cfgNode = $child; break
	}
}

if (-not $cfgNode) {
	Report-Error "1. No <Configuration> element found inside MetaDataObject"
	& $finalize
	exit 1
}

# UUID
$cfgUuid = $cfgNode.GetAttribute("uuid")
if (-not $cfgUuid) {
	Report-Error "1. Missing uuid on <Configuration>"
	$check1Ok = $false
} elseif ($cfgUuid -notmatch $guidPattern) {
	Report-Error "1. Invalid uuid '$cfgUuid' on <Configuration>"
	$check1Ok = $false
}

# Get name early for header
$propsNode = $cfgNode.SelectSingleNode("md:Properties", $ns)
$nameNode = if ($propsNode) { $propsNode.SelectSingleNode("md:Name", $ns) } else { $null }
$objName = if ($nameNode -and $nameNode.InnerText) { $nameNode.InnerText } else { "(unknown)" }

$script:output.Insert(0, "=== Validation: Configuration.$objName ===$([Environment]::NewLine)") | Out-Null

if ($check1Ok) {
	Report-OK "1. Root structure: MetaDataObject/Configuration, version $version"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 2: InternalInfo ---
$internalInfo = $cfgNode.SelectSingleNode("md:InternalInfo", $ns)
$check2Ok = $true

if (-not $internalInfo) {
	Report-Error "2. InternalInfo: missing"
} else {
	$contained = $internalInfo.SelectNodes("xr:ContainedObject", $ns)
	if ($contained.Count -ne 7) {
		Report-Warn "2. InternalInfo: expected 7 ContainedObject, found $($contained.Count)"
	}

	$foundClassIds = @{}
	foreach ($co in $contained) {
		$classId = $co.SelectSingleNode("xr:ClassId", $ns)
		$objectId = $co.SelectSingleNode("xr:ObjectId", $ns)

		if (-not $classId -or -not $classId.InnerText) {
			Report-Error "2. ContainedObject missing ClassId"
			$check2Ok = $false
			continue
		}

		$cid = $classId.InnerText
		if ($validClassIds -notcontains $cid) {
			Report-Error "2. Unknown ClassId: $cid"
			$check2Ok = $false
		}

		if ($foundClassIds.ContainsKey($cid)) {
			Report-Error "2. Duplicate ClassId: $cid"
			$check2Ok = $false
		}
		$foundClassIds[$cid] = $true

		if (-not $objectId -or -not $objectId.InnerText) {
			Report-Error "2. ContainedObject missing ObjectId for ClassId $cid"
			$check2Ok = $false
		} elseif ($objectId.InnerText -notmatch $guidPattern) {
			Report-Error "2. Invalid ObjectId '$($objectId.InnerText)' for ClassId $cid"
			$check2Ok = $false
		}
	}

	# Check missing ClassIds
	$missingIds = @($validClassIds | Where-Object { -not $foundClassIds.ContainsKey($_) })
	if ($missingIds.Count -gt 0) {
		Report-Warn "2. Missing ClassIds: $($missingIds.Count) of 7"
	}

	if ($check2Ok) {
		Report-OK "2. InternalInfo: $($contained.Count) ContainedObject, all ClassIds valid"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 3: Properties — Name, Synonym, DefaultLanguage, DefaultRunMode ---
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
	}

	# Synonym
	$synNode = $propsNode.SelectSingleNode("md:Synonym", $ns)
	$synPresent = $false
	if ($synNode) {
		$synItem = $synNode.SelectSingleNode("v8:item", $ns)
		if ($synItem) {
			$synContent = $synItem.SelectSingleNode("v8:content", $ns)
			if ($synContent -and $synContent.InnerText) { $synPresent = $true }
		}
	}

	# DefaultLanguage
	$defLangNode = $propsNode.SelectSingleNode("md:DefaultLanguage", $ns)
	$defLang = if ($defLangNode -and $defLangNode.InnerText) { $defLangNode.InnerText } else { "" }
	if (-not $defLang) {
		Report-Error "3. Properties: DefaultLanguage is missing or empty"
		$check3Ok = $false
	}

	# DefaultRunMode
	$defRunNode = $propsNode.SelectSingleNode("md:DefaultRunMode", $ns)
	if (-not $defRunNode -or -not $defRunNode.InnerText) {
		Report-Warn "3. Properties: DefaultRunMode is missing or empty"
	}

	if ($check3Ok) {
		$synInfo = if ($synPresent) { "Synonym present" } else { "no Synonym" }
		Report-OK "3. Properties: Name=`"$objName`", $synInfo, DefaultLanguage=$defLang"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 4: Property values — enum properties ---
if ($propsNode) {
	$enumChecked = 0
	$check4Ok = $true

	foreach ($propName in $validEnumValues.Keys) {
		$propNode = $propsNode.SelectSingleNode("md:$propName", $ns)
		if ($propNode -and $propNode.InnerText) {
			$val = $propNode.InnerText
			$allowed = $validEnumValues[$propName]
			if ($allowed -notcontains $val) {
				Report-Error "4. Property '$propName' has invalid value '$val'"
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

# --- Check 5: ChildObjects — valid types, no duplicates, order ---
$childObjNode = $cfgNode.SelectSingleNode("md:ChildObjects", $ns)

if (-not $childObjNode) {
	Report-Error "5. ChildObjects block missing"
} else {
	$check5Ok = $true
	$totalCount = 0
	$typeCounts = @{}
	$duplicates = @{}
	$typeFirstIndex = @{}    # type -> first position index
	$lastTypeOrder = -1
	$orderOk = $true
	$idx = 0

	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		$objNameVal = $child.InnerText

		# Valid type?
		$typeIdx = $childObjectTypes.IndexOf($typeName)
		if ($typeIdx -lt 0) {
			Report-Error "5. Unknown type '$typeName' in ChildObjects"
			$check5Ok = $false
		} else {
			# Check order
			if (-not $typeFirstIndex.ContainsKey($typeName)) {
				$typeFirstIndex[$typeName] = $typeIdx
				if ($typeIdx -lt $lastTypeOrder) {
					Report-Warn "5. Type '$typeName' is out of canonical order (after type at position $lastTypeOrder)"
					$orderOk = $false
				}
				$lastTypeOrder = $typeIdx
			}
		}

		# Count and dedup
		if (-not $typeCounts.ContainsKey($typeName)) { $typeCounts[$typeName] = @{} }
		if ($typeCounts[$typeName].ContainsKey($objNameVal)) {
			if (-not $duplicates.ContainsKey("$typeName.$objNameVal")) {
				Report-Error "5. Duplicate: $typeName.$objNameVal"
				$duplicates["$typeName.$objNameVal"] = $true
				$check5Ok = $false
			}
		} else {
			$typeCounts[$typeName][$objNameVal] = $true
		}

		$totalCount++
		$idx++
	}

	$typeCount = $typeCounts.Count
	if ($check5Ok) {
		$orderInfo = if ($orderOk) { ", order correct" } else { "" }
		Report-OK "5. ChildObjects: $typeCount types, $totalCount objects${orderInfo}"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 6: DefaultLanguage references existing Language in ChildObjects ---
if ($defLang -and $childObjNode) {
	# DefaultLanguage is like "Language.Русский"
	$langName = $defLang
	if ($langName.StartsWith("Language.")) {
		$langName = $langName.Substring(9)
	}

	$found = $false
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Language" -and $child.InnerText -eq $langName) {
			$found = $true; break
		}
	}

	if ($found) {
		Report-OK "6. DefaultLanguage `"$defLang`" found in ChildObjects"
	} else {
		Report-Error "6. DefaultLanguage `"$defLang`" not found in ChildObjects"
	}
} else {
	if (-not $defLang) {
		Report-Warn "6. Cannot check DefaultLanguage (empty)"
	} else {
		Report-Warn "6. Cannot check DefaultLanguage (no ChildObjects)"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 7: Language files exist ---
if ($childObjNode) {
	$langNames = @()
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Language") {
			$langNames += $child.InnerText
		}
	}

	if ($langNames.Count -gt 0) {
		$existCount = 0
		foreach ($ln in $langNames) {
			$langFile = Join-Path (Join-Path $configDir "Languages") "$ln.xml"
			if (Test-Path $langFile) {
				$existCount++
			} else {
				Report-Warn "7. Language file missing: Languages/$ln.xml"
			}
		}
		if ($existCount -eq $langNames.Count) {
			Report-OK "7. Language files: $existCount/$($langNames.Count) exist"
		}
	} else {
		Report-Warn "7. No Language entries in ChildObjects"
	}
} else {
	Report-Warn "7. Cannot check language files (no ChildObjects)"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 8: Object directories exist (spot-check) ---
if ($childObjNode) {
	$dirsToCheck = @{}
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		if ($typeName -eq "Language") { continue }  # Already checked
		if ($childTypeDirMap.ContainsKey($typeName)) {
			$dirName = $childTypeDirMap[$typeName]
			if (-not $dirsToCheck.ContainsKey($dirName)) {
				$dirsToCheck[$dirName] = 0
			}
			$dirsToCheck[$dirName] = $dirsToCheck[$dirName] + 1
		}
	}

	$missingDirs = @()
	foreach ($dir in $dirsToCheck.Keys) {
		$dirPath = Join-Path $configDir $dir
		if (-not (Test-Path $dirPath -PathType Container)) {
			$missingDirs += "$dir ($($dirsToCheck[$dir]) objects)"
		}
	}

	if ($missingDirs.Count -eq 0) {
		Report-OK "8. Object directories: $($dirsToCheck.Count) directories, all exist"
	} else {
		foreach ($md in $missingDirs) {
			Report-Warn "8. Missing directory: $md"
		}
	}
}

# --- Check 9: Form references (HomePageWorkArea + Properties) ---
function Test-FormRef([string]$ref) {
	if (-not $ref) { return $true }
	# UUID — cannot verify without scanning all forms; skip
	if ($ref -match $guidPattern) { return $true }
	$parts = $ref.Split(".")
	if ($parts.Count -eq 2 -and $parts[0] -eq "CommonForm") {
		$p = Join-Path (Join-Path (Join-Path $configDir "CommonForms") $parts[1]) "Form.xml"
		$pExt = Join-Path (Join-Path (Join-Path (Join-Path $configDir "CommonForms") $parts[1]) "Ext") "Form.xml"
		return (Test-Path $p) -or (Test-Path $pExt)
	}
	if ($parts.Count -eq 4 -and $parts[2] -eq "Form" -and $childTypeDirMap.ContainsKey($parts[0])) {
		$dir = $childTypeDirMap[$parts[0]]
		$p = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $configDir $dir) $parts[1]) "Forms") $parts[3]) "Form.xml"
		$pExt = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $configDir $dir) $parts[1]) "Forms") $parts[3]) "Ext") "Form.xml"
		return (Test-Path $p) -or (Test-Path $pExt)
	}
	return $false
}

$formRefsChecked = 0
$formRefErrors = @()

# HomePageWorkArea
$hpPath = Join-Path (Join-Path $configDir "Ext") "HomePageWorkArea.xml"
if (Test-Path $hpPath) {
	try {
		[xml]$hpDoc = Get-Content -Path $hpPath -Encoding UTF8
		$hpNs = New-Object System.Xml.XmlNamespaceManager($hpDoc.NameTable)
		$hpNs.AddNamespace("hp", "http://v8.1c.ru/8.3/xcf/extrnprops")
		foreach ($f in $hpDoc.DocumentElement.SelectNodes("//hp:Item/hp:Form", $hpNs)) {
			$ref = $f.InnerText.Trim()
			if (-not $ref) { continue }
			$formRefsChecked++
			if (-not (Test-FormRef $ref)) {
				$formRefErrors += "HomePageWorkArea.Form '$ref' — file not found"
			}
		}
	} catch {
		$formRefErrors += "HomePageWorkArea.xml: parse error — $($_.Exception.Message)"
	}
}

# Properties: DefaultXxxForm refs
if ($propsNode) {
	$formProps = @("DefaultReportForm","DefaultReportVariantForm","DefaultReportSettingsForm","DefaultDynamicListSettingsForm","DefaultSearchForm","DefaultDataHistoryChangeHistoryForm","DefaultDataHistoryVersionDataForm","DefaultDataHistoryVersionDifferencesForm","DefaultCollaborationSystemUsersChoiceForm","DefaultConstantsForm")
	foreach ($pn in $formProps) {
		$node = $propsNode.SelectSingleNode("md:$pn", $ns)
		if ($node -and $node.InnerText.Trim()) {
			$ref = $node.InnerText.Trim()
			$formRefsChecked++
			if (-not (Test-FormRef $ref)) {
				$formRefErrors += "Properties.$pn '$ref' — form not found"
			}
		}
	}
}

if ($formRefsChecked -eq 0) {
	Report-OK "9. Form references: none to check"
} elseif ($formRefErrors.Count -eq 0) {
	Report-OK "9. Form references: $formRefsChecked verified"
} else {
	foreach ($err in $formRefErrors) { Report-Error "9. $err" }
}

# --- Final output ---
& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
