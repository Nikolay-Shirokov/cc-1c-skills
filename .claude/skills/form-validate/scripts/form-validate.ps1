# form-validate v1.4 — Validate 1C managed form
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$FormPath,

	[switch]$Detailed,

	[int]$MaxErrors = 30
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---
# A: Directory → Ext/Form.xml
if (Test-Path $FormPath -PathType Container) {
	$FormPath = Join-Path (Join-Path $FormPath "Ext") "Form.xml"
}
# B1: Missing Ext/ (e.g. Forms/Форма/Form.xml → Forms/Форма/Ext/Form.xml)
if (-not (Test-Path $FormPath)) {
	$fn = [System.IO.Path]::GetFileName($FormPath)
	if ($fn -eq "Form.xml") {
		$c = Join-Path (Join-Path (Split-Path $FormPath) "Ext") $fn
		if (Test-Path $c) { $FormPath = $c }
	}
}
# B2: Descriptor (Forms/Форма.xml → Forms/Форма/Ext/Form.xml)
if (-not (Test-Path $FormPath) -and $FormPath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
	$dir = Split-Path $FormPath
	$c = Join-Path (Join-Path (Join-Path $dir $stem) "Ext") "Form.xml"
	if (Test-Path $c) { $FormPath = $c }
}

# --- Load XML ---

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
try {
	$xmlDoc.Load((Resolve-Path $FormPath).Path)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	Write-Host ""
	Write-Host "---"
	Write-Host "Errors: 1, Warnings: 0"
	exit 1
}

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

$root = $xmlDoc.DocumentElement

# --- Detect context: config vs EPF/ERF ---
# Walk up from FormPath looking for Configuration.xml → config context
# No Configuration.xml → external data processor / report (EPF/ERF)
$script:isConfigContext = $false
$walkDir = Split-Path (Resolve-Path $FormPath) -Parent
for ($i = 0; $i -lt 15; $i++) {
	if (-not $walkDir -or $walkDir -eq (Split-Path $walkDir)) { break }
	if (Test-Path (Join-Path $walkDir "Configuration.xml")) {
		$script:isConfigContext = $true
		break
	}
	$walkDir = Split-Path $walkDir
}

# --- Counters ---

$errors = 0
$warnings = 0
$stopped = $false
$script:okCount = 0

function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Write-Host "[OK]    $msg" }
}

function Report-Error {
	param([string]$msg)
	$script:errors++
	Write-Host "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}

function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Write-Host "[WARN]  $msg"
}

# --- Form name from path ---

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($FormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

if ($Detailed) {
	Write-Host "=== Validation: $formName ==="
	Write-Host ""
}

# Early BaseForm detection (used in Check 5 to skip base element DataPath validation)
$hasBaseForm = ($root.SelectSingleNode("f:BaseForm", $nsMgr) -ne $null)

# --- Check 1: Root element and version ---

if ($root.LocalName -ne "Form") {
	Report-Error "Root element is '$($root.LocalName)', expected 'Form'"
} else {
	$version = $root.GetAttribute("version")
	if ($version -eq "2.17" -or $version -eq "2.20") {
		Report-OK "Root element: Form version=$version"
	} elseif ($version) {
		Report-Warn "Form version='$version' (expected 2.17 or 2.20)"
	} else {
		Report-Warn "Form version attribute missing"
	}
}

# --- Check 2: AutoCommandBar ---

if (-not $stopped) {
	$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
	if ($acb) {
		$acbName = $acb.GetAttribute("name")
		$acbId = $acb.GetAttribute("id")
		if ($acbId -eq "-1") {
			Report-OK "AutoCommandBar: name='$acbName', id=$acbId"
		} else {
			Report-Error "AutoCommandBar id='$acbId', expected '-1'"
		}
	} else {
		Report-Error "AutoCommandBar element missing"
	}
}

# --- Collect all elements with IDs ---

$elementIds = @{}  # id -> name (element ID pool)
$allElements = @() # @{Name; Tag; Id; ParentName; Node}

function Collect-Elements {
	param($node, [string]$parentName)

	foreach ($child in $node.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }

		$name = $child.GetAttribute("name")
		$id = $child.GetAttribute("id")

		if ($name -and $id) {
			$tag = $child.LocalName

			$script:allElements += @{
				Name       = $name
				Tag        = $tag
				Id         = $id
				ParentName = $parentName
				Node       = $child
			}

			# Track element IDs (skip AutoCommandBar which has -1)
			if ($id -ne "-1") {
				if ($elementIds.ContainsKey($id)) {
					Report-Error "Duplicate element id=${id}: '$name' and '$($elementIds[$id])'"
				} else {
					$elementIds[$id] = $name
				}
			}

			# Recurse into ChildItems
			$childItems = $child.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($childItems) {
				Collect-Elements -node $childItems -parentName $name
			}
		}
	}
}

# Collect from ChildItems
$childItemsRoot = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($childItemsRoot) {
	Collect-Elements -node $childItemsRoot -parentName "(root)"
}

# Also collect from AutoCommandBar's ChildItems
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	$acbChildren = $acb.SelectSingleNode("f:ChildItems", $nsMgr)
	if ($acbChildren) {
		Collect-Elements -node $acbChildren -parentName "ФормаКоманднаяПанель"
	}
}

# --- Check 3: Unique element IDs ---

if (-not $stopped) {
	$dupCount = ($allElements | Group-Object { $_.Id } | Where-Object { $_.Count -gt 1 -and $_.Name -ne "-1" }).Count
	if ($dupCount -eq 0) {
		Report-OK "Unique element IDs: $($elementIds.Count) elements"
	}
}

# --- Collect attributes (separate ID pool) ---

$attrMap = @{}    # name -> node
$attrIds = @{}    # id -> name
$attrNodes = $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)
foreach ($attr in $attrNodes) {
	$attrName = $attr.GetAttribute("name")
	$attrId = $attr.GetAttribute("id")
	if ($attrName) {
		$attrMap[$attrName] = $attr
	}
	if ($attrId -and $attrId -ne "") {
		if ($attrIds.ContainsKey($attrId)) {
			Report-Error "Duplicate attribute id=${attrId}: '$attrName' and '$($attrIds[$attrId])'"
		} else {
			$attrIds[$attrId] = $attrName
		}
	}

	# Column IDs are a separate sub-pool per attribute — check uniqueness within parent
	$colIds = @{}
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		$colName = $col.GetAttribute("name")
		if ($colId -and $colId -ne "") {
			if ($colIds.ContainsKey($colId)) {
				Report-Error "Duplicate column id=${colId} in '$attrName': '$colName' and '$($colIds[$colId])'"
			} else {
				$colIds[$colId] = $colName
			}
		}
	}
}

if (-not $stopped) {
	$attrDupCount = ($attrIds.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }).Count
	if ($attrDupCount -eq 0 -and $attrIds.Count -gt 0) {
		Report-OK "Unique attribute IDs: $($attrIds.Count) entries"
	}
}

# --- Collect commands (separate ID pool) ---

$cmdMap = @{}   # name -> node
$cmdIds = @{}   # id -> name
$cmdNodes = $root.SelectNodes("f:Commands/f:Command", $nsMgr)
foreach ($cmd in $cmdNodes) {
	$cmdName = $cmd.GetAttribute("name")
	$cmdId = $cmd.GetAttribute("id")
	if ($cmdName) {
		$cmdMap[$cmdName] = $cmd
	}
	if ($cmdId -and $cmdId -ne "") {
		if ($cmdIds.ContainsKey($cmdId)) {
			Report-Error "Duplicate command id=${cmdId}: '$cmdName' and '$($cmdIds[$cmdId])'"
		} else {
			$cmdIds[$cmdId] = $cmdName
		}
	}
}

if (-not $stopped) {
	if ($cmdIds.Count -gt 0) {
		$cmdDupCount = ($cmdIds.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }).Count
		if ($cmdDupCount -eq 0) {
			Report-OK "Unique command IDs: $($cmdIds.Count) entries"
		}
	}
}

# --- Check 4: Companion elements ---

# Define required companions per element type
$companionRules = @{
	"InputField"        = @("ContextMenu", "ExtendedTooltip")
	"CheckBoxField"     = @("ContextMenu", "ExtendedTooltip")
	"LabelDecoration"   = @("ContextMenu", "ExtendedTooltip")
	"LabelField"        = @("ContextMenu", "ExtendedTooltip")
	"PictureDecoration" = @("ContextMenu", "ExtendedTooltip")
	"PictureField"      = @("ContextMenu", "ExtendedTooltip")
	"CalendarField"     = @("ContextMenu", "ExtendedTooltip")
	"UsualGroup"        = @("ExtendedTooltip")
	"Pages"             = @("ExtendedTooltip")
	"Page"              = @("ExtendedTooltip")
	"Button"            = @("ExtendedTooltip")
	"Table"             = @("ContextMenu", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition")
}

if (-not $stopped) {
	$companionErrors = 0
	$companionChecked = 0

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		if (-not $companionRules.ContainsKey($tag)) { continue }

		$required = $companionRules[$tag]
		$companionChecked++

		foreach ($compTag in $required) {
			$compNode = $node.SelectSingleNode("f:$compTag", $nsMgr)
			if (-not $compNode) {
				Report-Error "[$tag] '$elName': missing companion <$compTag>"
				$companionErrors++
			}
		}
	}

	if ($companionErrors -eq 0 -and $companionChecked -gt 0) {
		Report-OK "Companion elements: $companionChecked elements checked"
	}
}

# --- Check 5: DataPath -> Attribute references ---

if (-not $stopped) {
	$pathErrors = 0
	$pathChecked = 0
	$pathBaseSkipped = 0

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		# Skip companion elements
		if ($tag -in @("ContextMenu", "ExtendedTooltip", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition")) {
			continue
		}

		# In borrowed forms, skip DataPath check for base elements (id < 1000000)
		if ($hasBaseForm -and $el.Id) {
			try { if ([int]$el.Id -lt 1000000) { $pathBaseSkipped++; continue } } catch {}
		}

		$dpNode = $node.SelectSingleNode("f:DataPath", $nsMgr)
		if (-not $dpNode) { continue }

		$dataPath = $dpNode.InnerText.Trim()
		if (-not $dataPath) { continue }

		$pathChecked++

		# Extract root segment of path, strip array indices like [0]
		$cleanPath = $dataPath -replace '\[\d+\]', ''
		$segments = $cleanPath -split '\.'
		$rootAttr = $segments[0]

		if (-not $attrMap.ContainsKey($rootAttr)) {
			Report-Error "[$tag] '$elName': DataPath='$dataPath' — attribute '$rootAttr' not found"
			$pathErrors++
		}
	}

	$pathMsg = ""
	if ($pathChecked -gt 0) { $pathMsg = "$pathChecked paths checked" }
	if ($pathBaseSkipped -gt 0) {
		$skipNote = "$pathBaseSkipped base skipped"
		$pathMsg = if ($pathMsg) { "$pathMsg, $skipNote" } else { $skipNote }
	}
	if ($pathErrors -eq 0 -and $pathMsg) {
		Report-OK "DataPath references: $pathMsg"
	} elseif ($pathErrors -eq 0) {
		Report-OK "DataPath references: none"
	}
}

# --- Check 6: Button command references ---

if (-not $stopped) {
	$cmdErrors = 0
	$cmdChecked = 0

	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		if ($tag -ne "Button") { continue }

		$cmdNode = $node.SelectSingleNode("f:CommandName", $nsMgr)
		if (-not $cmdNode) { continue }

		$cmdRef = $cmdNode.InnerText.Trim()
		if (-not $cmdRef) { continue }

		# Form.Command.XXX -> check command XXX exists
		if ($cmdRef -match '^Form\.Command\.(.+)$') {
			$cmdName = $Matches[1]
			$cmdChecked++
			if (-not $cmdMap.ContainsKey($cmdName)) {
				Report-Error "[Button] '$elName': CommandName='$cmdRef' — command '$cmdName' not found in Commands"
				$cmdErrors++
			}
		}
		# Form.StandardCommand.XXX — skip, standard commands always exist
	}

	if ($cmdErrors -eq 0 -and $cmdChecked -gt 0) {
		Report-OK "Command references: $cmdChecked buttons checked"
	} elseif ($cmdChecked -eq 0) {
		Report-OK "Command references: none"
	}
}

# --- Check 7: Events have handler names ---

if (-not $stopped) {
	$eventErrors = 0
	$eventChecked = 0

	# Form-level events
	$formEvents = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($formEvents) {
		foreach ($evt in $formEvents.SelectNodes("f:Event", $nsMgr)) {
			$evtName = $evt.GetAttribute("name")
			$handler = $evt.InnerText.Trim()
			$eventChecked++
			if (-not $handler) {
				Report-Error "Form event '$evtName': empty handler name"
				$eventErrors++
			}
		}
	}

	# Element-level events
	foreach ($el in $allElements) {
		if ($stopped) { break }
		$tag = $el.Tag
		$elName = $el.Name
		$node = $el.Node

		$eventsNode = $node.SelectSingleNode("f:Events", $nsMgr)
		if (-not $eventsNode) { continue }

		foreach ($evt in $eventsNode.SelectNodes("f:Event", $nsMgr)) {
			$evtName = $evt.GetAttribute("name")
			$handler = $evt.InnerText.Trim()
			$eventChecked++
			if (-not $handler) {
				Report-Error "[$tag] '$elName' event '$evtName': empty handler name"
				$eventErrors++
			}
		}
	}

	if ($eventErrors -eq 0 -and $eventChecked -gt 0) {
		Report-OK "Event handlers: $eventChecked events checked"
	} elseif ($eventChecked -eq 0) {
		Report-OK "Event handlers: none"
	}
}

# --- Check 8: Command actions ---

if (-not $stopped) {
	$actionErrors = 0
	$actionChecked = 0

	foreach ($cmd in $cmdNodes) {
		if ($stopped) { break }
		$cmdName = $cmd.GetAttribute("name")
		$actionNode = $cmd.SelectSingleNode("f:Action", $nsMgr)
		$actionChecked++
		if (-not $actionNode -or -not $actionNode.InnerText.Trim()) {
			Report-Error "Command '$cmdName': missing or empty Action"
			$actionErrors++
		}
	}

	if ($actionErrors -eq 0 -and $actionChecked -gt 0) {
		Report-OK "Command actions: $actionChecked commands checked"
	} elseif ($actionChecked -eq 0) {
		Report-OK "Command actions: none"
	}
}

# --- Check 9: MainAttribute count ---

if (-not $stopped) {
	$mainCount = 0
	foreach ($attr in $attrNodes) {
		$mainNode = $attr.SelectSingleNode("f:MainAttribute", $nsMgr)
		if ($mainNode -and $mainNode.InnerText -eq "true") {
			$mainCount++
		}
	}

	if ($mainCount -le 1) {
		$mainInfo = if ($mainCount -eq 1) { "1 main attribute" } else { "no main attribute" }
		Report-OK "MainAttribute: $mainInfo"
	} else {
		Report-Error "Multiple MainAttribute=true ($mainCount found, expected 0 or 1)"
	}
}

# --- Check 10: Title must be multilingual XML (not plain text) ---

if (-not $stopped) {
	$titleNode = $root.SelectSingleNode("f:Title", $nsMgr)
	if ($titleNode) {
		$v8items = $titleNode.SelectNodes("v8:item", $nsMgr)
		if ($v8items.Count -eq 0 -and $titleNode.InnerText.Trim() -ne "") {
			Report-Error "Form Title is plain text ('$($titleNode.InnerText.Trim())') — must be multilingual XML (<v8:item>). Use top-level 'title' key in form-compile DSL."
		} else {
			Report-OK "Title: multilingual XML"
		}
	}
}

# --- Check 11: Extension-specific validations ---

$baseFormNode = $root.SelectSingleNode("f:BaseForm", $nsMgr)
$isExtension = ($baseFormNode -ne $null)

if (-not $stopped -and $isExtension) {
	# 11a. BaseForm version
	$bfVersion = $baseFormNode.GetAttribute("version")
	if ($bfVersion) {
		Report-OK "BaseForm: version=$bfVersion"
	} else {
		Report-Warn "BaseForm: version attribute missing"
	}

	# 11b. callType values validation (Before, After, Override)
	$validCallTypes = @("Before", "After", "Override")
	$ctErrors = 0
	$ctChecked = 0

	# Check form-level events
	$formEventsNode = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($formEventsNode) {
		foreach ($evt in $formEventsNode.SelectNodes("f:Event", $nsMgr)) {
			$ct = $evt.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "Form event '$($evt.GetAttribute('name'))': invalid callType='$ct' (expected: Before, After, Override)"
					$ctErrors++
				}
			}
		}
	}

	# Check element-level events
	foreach ($el in $allElements) {
		if ($stopped) { break }
		$eventsNode = $el.Node.SelectSingleNode("f:Events", $nsMgr)
		if (-not $eventsNode) { continue }
		foreach ($evt in $eventsNode.SelectNodes("f:Event", $nsMgr)) {
			$ct = $evt.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "[$($el.Tag)] '$($el.Name)' event '$($evt.GetAttribute('name'))': invalid callType='$ct'"
					$ctErrors++
				}
			}
		}
	}

	# Check command actions
	foreach ($cmd in $cmdNodes) {
		if ($stopped) { break }
		$cmdName = $cmd.GetAttribute("name")
		foreach ($action in $cmd.SelectNodes("f:Action", $nsMgr)) {
			$ct = $action.GetAttribute("callType")
			if ($ct) {
				$ctChecked++
				if ($validCallTypes -notcontains $ct) {
					Report-Error "Command '$cmdName' Action: invalid callType='$ct'"
					$ctErrors++
				}
			}
		}
	}

	if (-not $stopped -and $ctErrors -eq 0 -and $ctChecked -gt 0) {
		Report-OK "callType values: $ctChecked checked"
	}

	# 11c. Extension ID ranges — warn if extension-added attrs/commands have id < 1000000
	# Collect BaseForm attribute names to distinguish added ones
	$baseAttrNames = @{}
	$baseCmdNames = @{}
	$bfNs = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
	$bfNs.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")
	foreach ($bAttr in $baseFormNode.SelectNodes("f:Attributes/f:Attribute", $bfNs)) {
		$baName = $bAttr.GetAttribute("name")
		if ($baName) { $baseAttrNames[$baName] = $true }
	}
	foreach ($bCmd in $baseFormNode.SelectNodes("f:Commands/f:Command", $bfNs)) {
		$bcName = $bCmd.GetAttribute("name")
		if ($bcName) { $baseCmdNames[$bcName] = $true }
	}

	$idWarnCount = 0
	foreach ($attr in $attrNodes) {
		$aName = $attr.GetAttribute("name")
		$aId = $attr.GetAttribute("id")
		if ($aName -and -not $baseAttrNames.ContainsKey($aName) -and $aId) {
			try {
				$intId = [int]$aId
				if ($intId -lt 1000000) {
					Report-Warn "Attribute '$aName' (id=$aId): extension-added attribute has id < 1000000"
					$idWarnCount++
				}
			} catch {}
		}
	}

	foreach ($cmd in $cmdNodes) {
		$cName = $cmd.GetAttribute("name")
		$cId = $cmd.GetAttribute("id")
		if ($cName -and -not $baseCmdNames.ContainsKey($cName) -and $cId) {
			try {
				$intId = [int]$cId
				if ($intId -lt 1000000) {
					Report-Warn "Command '$cName' (id=$cId): extension-added command has id < 1000000"
					$idWarnCount++
				}
			} catch {}
		}
	}

	if (-not $stopped -and $idWarnCount -eq 0) {
		$extAttrCount = ($attrNodes | Where-Object { -not $baseAttrNames.ContainsKey($_.GetAttribute("name")) }).Count
		$extCmdCount = ($cmdNodes | Where-Object { -not $baseCmdNames.ContainsKey($_.GetAttribute("name")) }).Count
		if (($extAttrCount + $extCmdCount) -gt 0) {
			Report-OK "Extension ID ranges: $extAttrCount attr(s), $extCmdCount cmd(s) — all >= 1000000"
		}
	}
}

# Check callType without BaseForm (structural warning)
if (-not $stopped -and -not $isExtension) {
	$callTypeWithoutBase = $false
	$feNode = $root.SelectSingleNode("f:Events", $nsMgr)
	if ($feNode) {
		foreach ($evt in $feNode.SelectNodes("f:Event", $nsMgr)) {
			if ($evt.GetAttribute("callType")) { $callTypeWithoutBase = $true; break }
		}
	}
	if (-not $callTypeWithoutBase) {
		foreach ($cmd in $cmdNodes) {
			foreach ($action in $cmd.SelectNodes("f:Action", $nsMgr)) {
				if ($action.GetAttribute("callType")) { $callTypeWithoutBase = $true; break }
			}
			if ($callTypeWithoutBase) { break }
		}
	}
	if ($callTypeWithoutBase) {
		Report-Warn "callType attributes found but no BaseForm — possible incorrect structure"
	}
}

# --- Check 12: Type values validation ---

$knownInvalidTypes = @(
	"FormDataStructure","FormDataCollection","FormDataTree","FormDataTreeItem","FormDataCollectionItem"
	"FormGroup","FormField","FormButton","FormDecoration","FormTable"
)
$validClosedTypes = @(
	"xs:boolean","xs:string","xs:decimal","xs:dateTime","xs:binary"
	"v8:FillChecking","v8:Null","v8:StandardPeriod","v8:StandardBeginningDate","v8:Type"
	"v8:TypeDescription","v8:UUID","v8:ValueListType","v8:ValueTable","v8:ValueTree"
	"v8:Universal","v8:FixedArray","v8:FixedStructure"
	"v8ui:Color","v8ui:Font","v8ui:FormattedString","v8ui:HorizontalAlign"
	"v8ui:Picture","v8ui:SizeChangeMode","v8ui:VerticalAlign"
	"dcsset:DataCompositionComparisonType","dcsset:DataCompositionFieldPlacement"
	"dcsset:Filter","dcsset:SettingsComposer","dcsset:DataCompositionSettings"
	"dcssch:DataCompositionSchema"
	"dcscor:DataCompositionComparisonType","dcscor:DataCompositionGroupType"
	"dcscor:DataCompositionPeriodAdditionType","dcscor:DataCompositionSortDirection","dcscor:Field"
	"ent:AccountType","ent:AccumulationRecordType","ent:AccountingRecordType"
)
$validCfgPrefixes = @(
	"AccountingRegisterRecordSet","AccumulationRegisterRecordSet"
	"BusinessProcessObject","BusinessProcessRef"
	"CatalogObject","CatalogRef"
	"ChartOfAccountsObject","ChartOfAccountsRef"
	"ChartOfCalculationTypesObject","ChartOfCalculationTypesRef"
	"ChartOfCharacteristicTypesObject","ChartOfCharacteristicTypesRef"
	"ConstantsSet","DataProcessorObject","DocumentObject","DocumentRef"
	"DynamicList","EnumRef","ExchangePlanObject","ExchangePlanRef"
	"ExternalDataProcessorObject","ExternalReportObject"
	"InformationRegisterRecordManager","InformationRegisterRecordSet"
	"ReportObject","TaskObject","TaskRef"
)

if (-not $stopped) {
	$typeNodes = $root.SelectNodes("//v8:Type", $nsMgr)
	$typeOk = $true
	$typeChecked = 0
	$typeInvalid = 0
	foreach ($tn in $typeNodes) {
		$tv = $tn.InnerText.Trim()
		if (-not $tv) { continue }
		$typeChecked++
		if ($tv -in $knownInvalidTypes) {
			Report-Error "12. Type '$tv': invalid runtime/UI type (not valid in XDTO schema)"
			$typeOk = $false; $typeInvalid++
			continue
		}
		if ($tv -in $validClosedTypes) { continue }
		if ($tv -match '^cfg:(.+)$') {
			$cfgVal = $Matches[1]
			if ($cfgVal -eq "DynamicList") { continue }
			if ($cfgVal -match '^([^.]+)\.') {
				$pfx = $Matches[1]
				if ($pfx -in $validCfgPrefixes) {
					# ExternalDataProcessorObject/ExternalReportObject valid only for EPF/ERF, not config
					if ($script:isConfigContext -and ($pfx -eq "ExternalDataProcessorObject" -or $pfx -eq "ExternalReportObject")) {
						Report-Error "12. Type '$tv': External* type in configuration context (use DataProcessorObject/ReportObject instead)"
						$typeOk = $false; $typeInvalid++
					}
					continue
				}
			}
			Report-Warn "12. Type '$tv': unrecognized cfg prefix"
			$typeOk = $false
			continue
		}
		if ($tv -match ':') { continue }
		Report-Warn "12. Type '$tv': bare type without namespace prefix"
		$typeOk = $false
	}
	if ($typeChecked -eq 0) {
		Report-OK "12. Types: no type values to check"
	} elseif ($typeOk) {
		Report-OK "12. Types: $typeChecked values, all valid"
	}
}

# --- Summary ---

$checks = $script:okCount + $errors + $warnings

if ($errors -eq 0 -and $warnings -eq 0 -and -not $Detailed) {
	Write-Host "=== Validation OK: Form.$formName ($checks checks) ==="
} else {
	Write-Host ""
	if ($Detailed) {
		Write-Host "---"
		Write-Host "Total: $($allElements.Count) elements, $($attrNodes.Count) attributes, $($cmdNodes.Count) commands"
	}

	if ($stopped) {
		Write-Host "Stopped after $MaxErrors errors. Fix and re-run."
	}

	Write-Host "=== Result: $errors errors, $warnings warnings ($checks checks) ==="
}

if ($errors -gt 0) {
	exit 1
} else {
	exit 0
}
