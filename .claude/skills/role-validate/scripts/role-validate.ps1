# role-validate v1.0 — Validate 1C role structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$RightsPath,

	[string]$MetadataPath,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Known rights per object type ---

$script:knownRights = @{
	"Configuration" = @(
		"Administration","DataAdministration","UpdateDataBaseConfiguration",
		"ConfigurationExtensionsAdministration","ActiveUsers","EventLog","ExclusiveMode",
		"ThinClient","ThickClient","WebClient","MobileClient","ExternalConnection",
		"Automation","Output","SaveUserData","TechnicalSpecialistMode",
		"InteractiveOpenExtDataProcessors","InteractiveOpenExtReports",
		"AnalyticsSystemClient","CollaborationSystemInfoBaseRegistration",
		"MainWindowModeNormal","MainWindowModeWorkplace",
		"MainWindowModeEmbeddedWorkplace","MainWindowModeFullscreenWorkplace","MainWindowModeKiosk"
	)
	"Catalog" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"Document" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Posting","UndoPosting",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractivePosting","InteractivePostingRegular","InteractiveUndoPosting",
		"InteractiveChangeOfPosted",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"InformationRegister" = @(
		"Read","Update","View","Edit","TotalsControl",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"AccumulationRegister" = @("Read","Update","View","Edit","TotalsControl")
	"AccountingRegister" = @("Read","Update","View","Edit","TotalsControl")
	"CalculationRegister" = @("Read","View")
	"Constant" = @(
		"Read","Update","View","Edit",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"ChartOfAccounts" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData",
		"UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment"
	)
	"ChartOfCharacteristicTypes" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"ChartOfCalculationTypes" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData"
	)
	"ExchangePlan" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"BusinessProcess" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Start","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveActivate","InteractiveStart"
	)
	"Task" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Execute","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveActivate","InteractiveExecute"
	)
	"DataProcessor" = @("Use","View")
	"Report" = @("Use","View")
	"CommonForm" = @("View")
	"CommonCommand" = @("View")
	"Subsystem" = @("View")
	"FilterCriterion" = @("View")
	"DocumentJournal" = @("Read","View")
	"Sequence" = @("Read","Update")
	"WebService" = @("Use")
	"HTTPService" = @("Use")
	"IntegrationService" = @("Use")
	"SessionParameter" = @("Get","Set")
	"CommonAttribute" = @("View","Edit")
}

$script:nestedRights = @("View","Edit")
$script:channelRights = @("Use")
$script:commandRights = @("View")

# --- 2. Output helpers ---

$script:lines = @()
$script:errors = 0
$script:warnings = 0

function Out-OK {
	param([string]$msg)
	$script:lines += "  OK  $msg"
}

function Out-WARN {
	param([string]$msg)
	$script:warnings++
	$script:lines += "  WARN  $msg"
}

function Out-ERR {
	param([string]$msg)
	$script:errors++
	$script:lines += "  ERR  $msg"
}

function Get-ObjectType {
	param([string]$name)
	$dotIdx = $name.IndexOf(".")
	if ($dotIdx -lt 0) { return $name }
	return $name.Substring(0, $dotIdx)
}

function Is-NestedObject {
	param([string]$name)
	return ($name.Split(".").Count -ge 3)
}

function Find-Similar {
	param([string]$needle, [string[]]$haystack)
	$result = @($haystack | Where-Object {
		$_ -like "*$needle*" -or $needle -like "*$_*"
	})
	if ($result.Count -gt 3) { $result = $result[0..2] }
	return $result
}

# --- 3. Validate Rights.xml ---

$script:lines += "Validating: $RightsPath"

if (-not (Test-Path $RightsPath)) {
	Out-ERR "File not found: $RightsPath"
	$script:lines += "---"
	$script:lines += "Result: $($script:errors) error(s), $($script:warnings) warning(s)"
	$output = $script:lines -join "`n"
	if ($OutFile) {
		$enc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($OutFile, $output, $enc)
	} else {
		Write-Host $output
	}
	exit 1
}

# 3a. Parse XML
try {
	[xml]$xml = Get-Content -Path $RightsPath -Encoding UTF8
	Out-OK "XML well-formed"
} catch {
	Out-ERR "XML parse error: $($_.Exception.Message)"
	$script:lines += "---"
	$script:lines += "Result: $($script:errors) error(s), $($script:warnings) warning(s)"
	$output = $script:lines -join "`n"
	if ($OutFile) {
		$enc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($OutFile, $output, $enc)
	} else {
		Write-Host $output
	}
	exit 1
}

$root = $xml.DocumentElement
$rightsNs = "http://v8.1c.ru/8.2/roles"

# 3b. Check root element
if ($root.LocalName -ne "Rights") {
	Out-ERR "Root element is '$($root.LocalName)', expected 'Rights'"
} elseif ($root.NamespaceURI -ne $rightsNs) {
	Out-WARN "Namespace is '$($root.NamespaceURI)', expected '$rightsNs'"
} else {
	Out-OK "Root element: <Rights> with correct namespace"
}

# 3c. Global flags
$flagNames = @("setForNewObjects","setForAttributesByDefault","independentRightsOfChildObjects")
$flagsFound = 0
foreach ($fn in $flagNames) {
	$node = $root.GetElementsByTagName($fn, $rightsNs)
	if ($node.Count -gt 0) {
		$val = $node[0].InnerText
		if ($val -ne "true" -and $val -ne "false") {
			Out-WARN "$fn = '$val' (expected 'true' or 'false')"
		}
		$flagsFound++
	} else {
		Out-WARN "Missing global flag: $fn"
	}
}
if ($flagsFound -eq 3) {
	Out-OK "3 global flags present"
}

# 3d. Objects
$objects = $root.GetElementsByTagName("object", $rightsNs)
$objCount = $objects.Count
$rightCount = 0
$rlsCount = 0

foreach ($obj in $objects) {
	$objName = ""
	foreach ($child in $obj.ChildNodes) {
		if ($child.LocalName -eq "name") {
			$objName = $child.InnerText
			break
		}
	}

	if (-not $objName) {
		Out-ERR "Object without <name>"
		continue
	}

	$objectType = Get-ObjectType $objName
	$isNested = Is-NestedObject $objName

	# Check object type is known
	if (-not $isNested -and -not $script:knownRights.ContainsKey($objectType)) {
		Out-WARN "${objName}: unknown object type '$objectType'"
	}

	# Check rights
	foreach ($child in $obj.ChildNodes) {
		if ($child.LocalName -ne "right") { continue }

		$rName = ""
		$rValue = ""
		$hasRLS = $false

		foreach ($rc in $child.ChildNodes) {
			if ($rc.LocalName -eq "name") { $rName = $rc.InnerText }
			if ($rc.LocalName -eq "value") { $rValue = $rc.InnerText }
			if ($rc.LocalName -eq "restrictionByCondition") {
				$hasRLS = $true
				$rlsCount++
				# Check condition not empty
				$condNode = $null
				foreach ($rcc in $rc.ChildNodes) {
					if ($rcc.LocalName -eq "condition") { $condNode = $rcc }
				}
				if (-not $condNode -or -not $condNode.InnerText) {
					Out-WARN "${objName}: RLS condition for '$rName' is empty"
				}
			}
		}

		if (-not $rName) {
			Out-ERR "${objName}: <right> without <name>"
			continue
		}

		if ($rValue -ne "true" -and $rValue -ne "false") {
			Out-ERR "${objName}: right '$rName' has invalid value '$rValue'"
			continue
		}

		$rightCount++

		# Validate right name
		if ($isNested) {
			if ($objName -match '\.Command\.') {
				if ($rName -notin $script:commandRights) {
					Out-WARN "${objName}: '$rName' not valid for commands (only: View)"
				}
			} elseif ($objName -match '\.IntegrationServiceChannel\.') {
				if ($rName -notin $script:channelRights) {
					Out-WARN "${objName}: '$rName' not valid for channels (only: Use)"
				}
			} else {
				if ($rName -notin $script:nestedRights) {
					Out-WARN "${objName}: '$rName' not valid for nested objects (only: View, Edit)"
				}
			}
		} elseif ($script:knownRights.ContainsKey($objectType)) {
			$validRights = $script:knownRights[$objectType]
			if ($rName -notin $validRights) {
				$similar = Find-Similar -needle $rName -haystack $validRights
				$sugStr = if ($similar.Count -gt 0) { " Did you mean: $($similar -join ', ')?" } else { "" }
				Out-WARN "${objName}: unknown right '$rName'.$sugStr"
			}
		}
	}
}

Out-OK "$objCount objects, $rightCount rights"
if ($rlsCount -gt 0) {
	Out-OK "$rlsCount RLS restrictions"
}

# 3e. Templates
$templates = $root.GetElementsByTagName("restrictionTemplate", $rightsNs)
if ($templates.Count -gt 0) {
	$tplNames = @()
	foreach ($tpl in $templates) {
		$tName = ""
		$tCond = ""
		foreach ($child in $tpl.ChildNodes) {
			if ($child.LocalName -eq "name") { $tName = $child.InnerText }
			if ($child.LocalName -eq "condition") { $tCond = $child.InnerText }
		}
		if (-not $tName) {
			Out-WARN "Restriction template without <name>"
		} else {
			$parenIdx = $tName.IndexOf("(")
			$shortName = if ($parenIdx -gt 0) { $tName.Substring(0, $parenIdx) } else { $tName }
			$tplNames += $shortName
		}
		if (-not $tCond) {
			Out-WARN "Template '$tName': empty <condition>"
		}
	}
	Out-OK "$($templates.Count) templates: $($tplNames -join ', ')"
}

# --- 4. Validate metadata (optional) ---

if ($MetadataPath) {
	$script:lines += ""

	if (-not (Test-Path $MetadataPath)) {
		Out-ERR "Metadata file not found: $MetadataPath"
	} else {
		try {
			[xml]$metaXml = Get-Content -Path $MetadataPath -Encoding UTF8
			$roleNode = $metaXml.DocumentElement.SelectSingleNode("//*[local-name()='Role']")
			if (-not $roleNode) {
				Out-ERR "Metadata: <Role> element not found"
			} else {
				$uuid = $roleNode.GetAttribute("uuid")
				if ($uuid -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
					Out-OK "Metadata: UUID valid ($uuid)"
				} else {
					Out-ERR "Metadata: invalid UUID format '$uuid'"
				}

				$nameNode = $roleNode.SelectSingleNode(".//*[local-name()='Name']")
				if ($nameNode -and $nameNode.InnerText) {
					Out-OK "Metadata: Name = $($nameNode.InnerText)"
				} else {
					Out-ERR "Metadata: <Name> is empty or missing"
				}

				$synNode = $roleNode.SelectSingleNode(".//*[local-name()='Synonym']")
				if ($synNode -and $synNode.InnerXml) {
					Out-OK "Metadata: Synonym present"
				} else {
					Out-WARN "Metadata: <Synonym> is empty"
				}
			}
		} catch {
			Out-ERR "Metadata XML parse error: $($_.Exception.Message)"
		}
	}
}

# --- 5. Check registration in Configuration.xml ---

# Infer paths: RightsPath = .../Roles/Name/Ext/Rights.xml
$extDir2 = Split-Path (Resolve-Path $RightsPath).Path -Parent
$roleDir2 = Split-Path $extDir2 -Parent
$rolesDir2 = Split-Path $roleDir2 -Parent
$configDir2 = Split-Path $rolesDir2 -Parent
$configXmlPath2 = Join-Path $configDir2 "Configuration.xml"
$inferredRoleName = Split-Path $roleDir2 -Leaf

# Use metadata name if available
if ($MetadataPath -and (Test-Path $MetadataPath)) {
	try {
		[xml]$metaXml2 = Get-Content -Path $MetadataPath -Encoding UTF8
		$nameNode2 = $metaXml2.DocumentElement.SelectSingleNode("//*[local-name()='Role']//*[local-name()='Name']")
		if ($nameNode2 -and $nameNode2.InnerText) {
			$inferredRoleName = $nameNode2.InnerText
		}
	} catch { }
}

if (Test-Path $configXmlPath2) {
	$script:lines += ""
	try {
		[xml]$cfgXml = Get-Content -Path $configXmlPath2 -Encoding UTF8
		$cfgNs = New-Object System.Xml.XmlNamespaceManager($cfgXml.NameTable)
		$cfgNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
		$childObj = $cfgXml.SelectSingleNode("//md:Configuration/md:ChildObjects", $cfgNs)
		if ($childObj) {
			$roleNodes = $childObj.SelectNodes("md:Role", $cfgNs)
			$found = $false
			foreach ($rn in $roleNodes) {
				if ($rn.InnerText -eq $inferredRoleName) {
					$found = $true
					break
				}
			}
			if ($found) {
				Out-OK "Configuration.xml: <Role>$inferredRoleName</Role> registered"
			} else {
				Out-WARN "Configuration.xml: <Role>$inferredRoleName</Role> NOT found in ChildObjects"
			}
		}
	} catch {
		Out-WARN "Configuration.xml: parse error — $($_.Exception.Message)"
	}
}

# --- 6. Summary ---

$script:lines += "---"
$script:lines += "Result: $($script:errors) error(s), $($script:warnings) warning(s)"

$output = $script:lines -join "`n"

if ($OutFile) {
	$outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location) $OutFile }
	$outDir = [System.IO.Path]::GetDirectoryName($outPath)
	if (-not (Test-Path $outDir)) {
		New-Item -ItemType Directory -Path $outDir -Force | Out-Null
	}
	$enc = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($outPath, $output, $enc)
	Write-Host "[OK] Validation result written to: $outPath"
} else {
	Write-Host $output
}

if ($script:errors -gt 0) { exit 1 } else { exit 0 }
