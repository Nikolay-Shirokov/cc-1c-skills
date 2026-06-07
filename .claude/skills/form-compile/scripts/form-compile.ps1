# form-compile v1.58 — Compile 1C managed form from JSON or object metadata
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath,

	[switch]$FromObject,
	[string]$ObjectPath,
	[string]$Purpose,
	[string]$Preset = "erp-standard",
	[string]$EmitDsl
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ═══════════════════════════════════════════════════════════════════════════
# FROM-OBJECT MODE: functions for metadata parsing, presets, DSL generation
# ═══════════════════════════════════════════════════════════════════════════

function Parse-ObjectMeta([string]$ObjectPath) {
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	$doc.Load($ObjectPath)

	$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
	$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

	# Detect object type from root child
	$metaRoot = $doc.SelectSingleNode("md:MetaDataObject", $ns)
	if (-not $metaRoot) { Write-Error "Not a 1C metadata XML: $ObjectPath"; exit 1 }
	$typeNode = $metaRoot.FirstChild
	$objType = $typeNode.LocalName  # "Document", "Catalog", etc.

	$propsNode = $typeNode.SelectSingleNode("md:Properties", $ns)
	$childObjs = $typeNode.SelectSingleNode("md:ChildObjects", $ns)

	# Name
	$objName = $propsNode.SelectSingleNode("md:Name", $ns).InnerText

	# Synonym (Russian)
	$synonym = $objName
	$synNode = $propsNode.SelectSingleNode("md:Synonym/v8:item[v8:lang='ru']/v8:content", $ns)
	if ($synNode) { $synonym = $synNode.InnerText }

	# Helper: extract type string from md:Type
	$extractType = {
		param($typeParent)
		if (-not $typeParent) { return "string" }
		$types = @()
		foreach ($t in $typeParent.SelectNodes("v8:Type", $ns)) {
			$types += $t.InnerText
		}
		if ($types.Count -eq 0) { return "string" }
		return ($types -join " | ")
	}

	# Helper: check if type is a reference
	$isRefType = {
		param([string]$t)
		return ($t -match 'Ref\.' -or $t -match 'ссылка\.')
	}

	# Helper: extract field list from ChildObjects by tag name (Attribute, Dimension, Resource, AccountingFlag, ExtDimensionAccountingFlag)
	$extractFields = {
		param($parentNode, [string]$tagName)
		$result = @()
		if (-not $parentNode) { return $result }
		foreach ($fieldNode in $parentNode.SelectNodes("md:$tagName", $ns)) {
			$fp = $fieldNode.SelectSingleNode("md:Properties", $ns)
			$fName = $fp.SelectSingleNode("md:Name", $ns).InnerText
			$fSynNode = $fp.SelectSingleNode("md:Synonym/v8:item[v8:lang='ru']/v8:content", $ns)
			$fSyn = if ($fSynNode) { $fSynNode.InnerText } else { $fName }
			$fTypeNode = $fp.SelectSingleNode("md:Type", $ns)
			$fType = & $extractType $fTypeNode
			$result += @{
				Name = $fName
				Synonym = $fSyn
				Type = $fType
				IsRef = (& $isRefType $fType)
			}
		}
		return $result
	}

	# Attributes
	$attributes = @(& $extractFields $childObjs "Attribute")

	# Tabular sections
	$tabularSections = @()
	if ($childObjs) {
		foreach ($tsNode in $childObjs.SelectNodes("md:TabularSection", $ns)) {
			$tsp = $tsNode.SelectSingleNode("md:Properties", $ns)
			$tsName = $tsp.SelectSingleNode("md:Name", $ns).InnerText
			$tsSynNode = $tsp.SelectSingleNode("md:Synonym/v8:item[v8:lang='ru']/v8:content", $ns)
			$tsSyn = if ($tsSynNode) { $tsSynNode.InnerText } else { $tsName }
			$tsCo = $tsNode.SelectSingleNode("md:ChildObjects", $ns)
			$tsCols = @(& $extractFields $tsCo "Attribute")
			$tabularSections += @{
				Name = $tsName
				Synonym = $tsSyn
				Columns = $tsCols
			}
		}
	}

	$meta = @{
		Type = $objType
		Name = $objName
		Synonym = $synonym
		Attributes = $attributes
		TabularSections = $tabularSections
	}

	# Type-specific properties
	switch ($objType) {
		"Document" {
			$ntNode = $propsNode.SelectSingleNode("md:NumberType", $ns)
			$meta.NumberType = if ($ntNode) { $ntNode.InnerText } else { "String" }
		}
		"Catalog" {
			$clNode = $propsNode.SelectSingleNode("md:CodeLength", $ns)
			$meta.CodeLength = if ($clNode) { [int]$clNode.InnerText } else { 0 }
			$dlNode = $propsNode.SelectSingleNode("md:DescriptionLength", $ns)
			$meta.DescriptionLength = if ($dlNode) { [int]$dlNode.InnerText } else { 0 }
			$hiNode = $propsNode.SelectSingleNode("md:Hierarchical", $ns)
			$meta.Hierarchical = ($hiNode -and $hiNode.InnerText -eq "true")
			$htNode = $propsNode.SelectSingleNode("md:HierarchyType", $ns)
			$meta.HierarchyType = if ($htNode) { $htNode.InnerText } else { "HierarchyFoldersAndItems" }
			# Owners
			$owners = @()
			foreach ($ow in $propsNode.SelectNodes("md:Owners/xr:Item", $ns)) {
				$owners += $ow.InnerText
			}
			$meta.Owners = $owners
		}
		"InformationRegister" {
			$meta.Dimensions = @(& $extractFields $childObjs "Dimension")
			$meta.Resources  = @(& $extractFields $childObjs "Resource")
			$prdNode = $propsNode.SelectSingleNode("md:InformationRegisterPeriodicity", $ns)
			$meta.Periodicity = if ($prdNode) { $prdNode.InnerText } else { "Nonperiodical" }
			$wmNode = $propsNode.SelectSingleNode("md:WriteMode", $ns)
			$meta.WriteMode = if ($wmNode) { $wmNode.InnerText } else { "Independent" }
		}
		"AccumulationRegister" {
			$meta.Dimensions = @(& $extractFields $childObjs "Dimension")
			$meta.Resources  = @(& $extractFields $childObjs "Resource")
			$rtNode = $propsNode.SelectSingleNode("md:RegisterType", $ns)
			$meta.RegisterType = if ($rtNode) { $rtNode.InnerText } else { "Balances" }
		}
		"ChartOfCharacteristicTypes" {
			$clNode = $propsNode.SelectSingleNode("md:CodeLength", $ns)
			$meta.CodeLength = if ($clNode) { [int]$clNode.InnerText } else { 0 }
			$dlNode = $propsNode.SelectSingleNode("md:DescriptionLength", $ns)
			$meta.DescriptionLength = if ($dlNode) { [int]$dlNode.InnerText } else { 0 }
			$hiNode = $propsNode.SelectSingleNode("md:Hierarchical", $ns)
			$meta.Hierarchical = ($hiNode -and $hiNode.InnerText -eq "true")
			$htNode = $propsNode.SelectSingleNode("md:HierarchyType", $ns)
			$meta.HierarchyType = if ($htNode) { $htNode.InnerText } else { "HierarchyFoldersAndItems" }
			$owners = @()
			foreach ($ow in $propsNode.SelectNodes("md:Owners/xr:Item", $ns)) {
				$owners += $ow.InnerText
			}
			$meta.Owners = $owners
			$meta.HasValueType = $true
		}
		"ExchangePlan" {
			$clNode = $propsNode.SelectSingleNode("md:CodeLength", $ns)
			$meta.CodeLength = if ($clNode) { [int]$clNode.InnerText } else { 0 }
			$dlNode = $propsNode.SelectSingleNode("md:DescriptionLength", $ns)
			$meta.DescriptionLength = if ($dlNode) { [int]$dlNode.InnerText } else { 0 }
			$meta.Hierarchical = $false
			$meta.HierarchyType = $null
			$meta.Owners = @()
		}
		"ChartOfAccounts" {
			$clNode = $propsNode.SelectSingleNode("md:CodeLength", $ns)
			$meta.CodeLength = if ($clNode) { [int]$clNode.InnerText } else { 0 }
			$dlNode = $propsNode.SelectSingleNode("md:DescriptionLength", $ns)
			$meta.DescriptionLength = if ($dlNode) { [int]$dlNode.InnerText } else { 0 }
			$meta.Hierarchical = $true
			$htNode = $propsNode.SelectSingleNode("md:HierarchyType", $ns)
			$meta.HierarchyType = if ($htNode) { $htNode.InnerText } else { "HierarchyFoldersAndItems" }
			$meta.Owners = @()
			$maxEdNode = $propsNode.SelectSingleNode("md:MaxExtDimensionCount", $ns)
			$meta.MaxExtDimensionCount = if ($maxEdNode) { [int]$maxEdNode.InnerText } else { 0 }
			$meta.AccountingFlags = @(& $extractFields $childObjs "AccountingFlag")
			$meta.ExtDimensionAccountingFlags = @(& $extractFields $childObjs "ExtDimensionAccountingFlag")
		}
	}

	return $meta
}

function Load-Preset([string]$PresetName, [string]$ScriptDir) {
	# Hardcoded defaults (ERP-oriented)
	$defaults = @{
		"document.item" = @{
			header = @{ position = "insidePage"; layout = "2col"; distribute = "even"; dateTitle = "от" }
			footer = @{ fields = @("Комментарий"); position = "insidePage" }
			tabularSections = @{ container = "pages"; exclude = @("ДополнительныеРеквизиты"); lineNumber = $true }
			additional = @{ position = "page"; layout = "2col"; bspGroup = $true }
			fieldDefaults = @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } }
			commandBar = "auto"
			properties = @{ autoTitle = $false }
		}
		"document.list" = @{
			columns = "all"; columnType = "labelField"; hiddenRef = $true
			tableCommandBar = "none"; commandBar = "auto"
			properties = @{}
		}
		"document.choice" = @{
			basedOn = "document.list"
			properties = @{ windowOpeningMode = "LockOwnerWindow" }
		}
		"catalog.item" = @{
			header = @{ layout = "1col"; distribute = "left" }
			codeDescription = @{ layout = "horizontal"; order = "descriptionFirst" }
			parent = @{ title = "Входит в группу"; position = "afterCodeDescription" }
			owner = @{ readOnly = $true; position = "first" }
			tabularSections = @{ container = "inline"; exclude = @("ДополнительныеРеквизиты","Представления"); lineNumber = $true }
			footer = @{ fields = @(); position = "none" }
			additional = @{ position = "none"; bspGroup = $true }
			fieldDefaults = @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } }
			commandBar = "auto"
			properties = @{}
		}
		"catalog.folder" = @{
			parent = @{ title = "Входит в группу" }
			properties = @{ windowOpeningMode = "LockOwnerWindow" }
		}
		"catalog.list" = @{
			columns = "all"; columnType = "labelField"; hiddenRef = $true
			tableCommandBar = "none"; commandBar = "auto"
			properties = @{}
		}
		"catalog.choice" = @{
			basedOn = "catalog.list"; choiceMode = $true
			properties = @{ windowOpeningMode = "LockOwnerWindow" }
		}
		# ─── Register defaults ───
		"informationRegister.record" = @{
			fieldDefaults = @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } }
			properties = @{ windowOpeningMode = "LockOwnerWindow" }
		}
		"informationRegister.list" = @{
			columns = "all"; columnType = "labelField"
			tableCommandBar = "none"; commandBar = "auto"
			properties = @{}
		}
		"accumulationRegister.list" = @{
			columns = "all"; columnType = "labelField"
			tableCommandBar = "none"; commandBar = "auto"
			properties = @{}
		}
		# ─── Catalog-like type defaults ───
		"chartOfCharacteristicTypes.item"   = @{ basedOn = "catalog.item" }
		"chartOfCharacteristicTypes.folder" = @{ basedOn = "catalog.folder" }
		"chartOfCharacteristicTypes.list"   = @{ basedOn = "catalog.list" }
		"chartOfCharacteristicTypes.choice" = @{ basedOn = "catalog.choice" }
		"exchangePlan.item"   = @{ basedOn = "catalog.item" }
		"exchangePlan.list"   = @{ basedOn = "catalog.list" }
		"exchangePlan.choice" = @{ basedOn = "catalog.choice" }
		# ─── ChartOfAccounts defaults ───
		"chartOfAccounts.item" = @{
			parent = @{ title = "Подчинен счету" }
			fieldDefaults = @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } }
			properties = @{}
		}
		"chartOfAccounts.folder" = @{
			parent = @{ title = "Подчинен счету" }
			properties = @{ windowOpeningMode = "LockOwnerWindow" }
		}
		"chartOfAccounts.list"   = @{ basedOn = "catalog.list" }
		"chartOfAccounts.choice" = @{ basedOn = "catalog.choice" }
	}

	# Deep merge helper
	$deepMerge = {
		param($base, $overlay)
		if (-not $overlay) { return $base }
		if (-not $base) { return $overlay }
		$result = @{}
		foreach ($k in $base.Keys) { $result[$k] = $base[$k] }
		foreach ($k in $overlay.Keys) {
			if ($result.ContainsKey($k) -and $result[$k] -is [hashtable] -and $overlay[$k] -is [hashtable]) {
				$result[$k] = & $deepMerge $result[$k] $overlay[$k]
			} else {
				$result[$k] = $overlay[$k]
			}
		}
		return $result
	}

	# Try built-in preset
	$presetDir = Join-Path (Split-Path $ScriptDir -Parent) "presets"
	$builtInPath = Join-Path $presetDir "$PresetName.json"
	if (Test-Path $builtInPath) {
		$presetJson = Get-Content -Raw -Encoding UTF8 $builtInPath | ConvertFrom-Json
		# Convert PSCustomObject to hashtable recursively
		$toHash = {
			param($obj)
			if ($obj -is [System.Management.Automation.PSCustomObject]) {
				$h = @{}
				foreach ($p in $obj.PSObject.Properties) {
					$h[$p.Name] = & $toHash $p.Value
				}
				return $h
			}
			if ($obj -is [System.Object[]]) {
				return @($obj | ForEach-Object { & $toHash $_ })
			}
			return $obj
		}
		$presetHash = & $toHash $presetJson
		foreach ($k in @($presetHash.Keys)) {
			$defaults[$k] = & $deepMerge $defaults[$k] $presetHash[$k]
		}
	}

	# Try project-level preset (scan up from output path)
	$scanDir = [System.IO.Path]::GetDirectoryName($script:outPathResolved)
	while ($scanDir) {
		$projPreset = Join-Path (Join-Path (Join-Path (Join-Path $scanDir "presets") "skills") "form") "$PresetName.json"
		if (Test-Path $projPreset) {
			$projJson = Get-Content -Raw -Encoding UTF8 $projPreset | ConvertFrom-Json
			$projHash = & $toHash $projJson
			foreach ($k in @($projHash.Keys)) {
				$defaults[$k] = & $deepMerge $defaults[$k] $projHash[$k]
			}
			break
		}
		$parentDir = Split-Path $scanDir -Parent
		if ($parentDir -eq $scanDir) { break }
		$scanDir = $parentDir
	}

	# Resolve basedOn references
	foreach ($k in @($defaults.Keys)) {
		$sect = $defaults[$k]
		if ($sect -is [hashtable] -and $sect.ContainsKey("basedOn")) {
			$baseName = $sect["basedOn"]
			if ($defaults.ContainsKey($baseName)) {
				$merged = & $deepMerge $defaults[$baseName] $sect
				$merged.Remove("basedOn")
				$defaults[$k] = $merged
			}
		}
	}

	return $defaults
}

# --- Helper: build a field element DSL entry ---
# Non-displayable types — cannot be bound to form elements
$script:nonDisplayableTypes = @('v8:ValueStorage', 'ValueStorage', 'ХранилищеЗначения')

function Test-DisplayableType([string]$typeStr) {
	foreach ($nd in $script:nonDisplayableTypes) {
		if ($typeStr -match [regex]::Escape($nd)) { return $false }
	}
	return $true
}

function New-FieldElement {
	param([string]$attrName, [string]$dataPath, [string]$attrType, [hashtable]$fieldDefaults, [hashtable]$extraProps)

	$isRef = ($attrType -match 'Ref\.')
	$isBool = ($attrType -match '^\s*xs:boolean\s*$' -or $attrType -eq 'boolean' -or $attrType -match 'Boolean')

	# Determine element type
	$elType = "input"
	if ($isBool -and $fieldDefaults -and $fieldDefaults.boolean -and $fieldDefaults.boolean.element -eq "check") {
		$elType = "check"
	}

	$el = [ordered]@{ $elType = $attrName; path = $dataPath }

	# Apply ref defaults
	if ($isRef -and $fieldDefaults -and $fieldDefaults.ref) {
		if ($fieldDefaults.ref.choiceButton -eq $true) { $el["choiceButton"] = $true }
	}

	# Extra props
	if ($extraProps) {
		foreach ($k in $extraProps.Keys) { $el[$k] = $extraProps[$k] }
	}

	return $el
}

# --- Catalog DSL generators ---
function Generate-CatalogDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)

	$purposeKey = "catalog.$($purpose.ToLower())"
	$p = if ($presetData.ContainsKey($purposeKey)) { $presetData[$purposeKey] } else { @{} }
	$fd = if ($p.ContainsKey("fieldDefaults")) { $p.fieldDefaults } else { @{} }

	switch ($purpose) {
		"Folder" { return Generate-CatalogFolderDSL $meta $p }
		"List"   { return Generate-CatalogListDSL $meta $p }
		"Choice" { return Generate-CatalogChoiceDSL $meta $p $presetData }
		"Item"   { return Generate-CatalogItemDSL $meta $p $fd }
	}
}

function Generate-CatalogFolderDSL($meta, [hashtable]$p) {
	$elements = @()
	# Code (if CodeLength > 0)
	if ($meta.CodeLength -gt 0) {
		$elements += [ordered]@{ input = "Код"; path = "Объект.Code" }
	}
	# Description
	$elements += [ordered]@{ input = "Наименование"; path = "Объект.Description" }
	# Parent
	$parentTitle = if ($p.parent -and $p.parent.title) { $p.parent.title } else { $null }
	$parentEl = [ordered]@{ input = "Родитель"; path = "Объект.Parent" }
	if ($parentTitle) { $parentEl["title"] = $parentTitle }
	$elements += $parentEl

	$props = [ordered]@{ windowOpeningMode = "LockOwnerWindow" }
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	$formProps = [ordered]@{ useForFoldersAndItems = "Folders" }
	foreach ($k in $props.Keys) { $formProps[$k] = $props[$k] }

	return [ordered]@{
		title = $meta.Synonym
		properties = $formProps
		elements = $elements
		attributes = @(
			[ordered]@{ name = "Объект"; type = "CatalogObject.$($meta.Name)"; main = $true }
		)
	}
}

function Generate-CatalogListDSL($meta, [hashtable]$p) {
	# Columns
	$columns = @()
	# Description always first
	$columns += [ordered]@{ labelField = "Наименование"; path = "Список.Description" }
	# Code if present
	if ($meta.CodeLength -gt 0) {
		$columns += [ordered]@{ labelField = "Код"; path = "Список.Code" }
	}
	# Custom attributes
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$columns += [ordered]@{ labelField = $attr.Name; path = "Список.$($attr.Name)" }
	}
	# Hidden ref
	if (-not $p.ContainsKey("hiddenRef") -or $p.hiddenRef -eq $true) {
		$columns += [ordered]@{ labelField = "Ссылка"; path = "Список.Ref"; userVisible = $false }
	}

	$tableEl = [ordered]@{
		table = "Список"; path = "Список"
		rowPictureDataPath = "Список.DefaultPicture"
		commandBarLocation = "None"
		tableAutofill = $false
		columns = $columns
	}
	# Hierarchical properties
	if ($meta.Hierarchical) {
		$tableEl["initialTreeView"] = "ExpandTopLevel"
		$tableEl["enableStartDrag"] = $true
		$tableEl["enableDrag"] = $true
	}

	$formProps = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $formProps[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $formProps
		elements = @($tableEl)
		attributes = @(
			[ordered]@{
				name = "Список"; type = "DynamicList"; main = $true
				settings = [ordered]@{ mainTable = "Catalog.$($meta.Name)"; dynamicDataRead = $true }
			}
		)
	}
}

function Generate-CatalogChoiceDSL($meta, [hashtable]$p, [hashtable]$presetData) {
	# Start from list
	$listKey = "catalog.list"
	$lp = if ($presetData.ContainsKey($listKey)) { $presetData[$listKey] } else { @{} }
	$dsl = Generate-CatalogListDSL $meta $lp

	# Add choice-specific properties
	$dsl.properties["windowOpeningMode"] = "LockOwnerWindow"
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $dsl.properties[$k] = $p.properties[$k] } }

	# Set ChoiceMode on table
	$dsl.elements[0]["choiceMode"] = $true

	return $dsl
}

function Generate-CatalogItemDSL($meta, [hashtable]$p, [hashtable]$fd) {
	$headerChildren = @()

	# Owner (if subordinate)
	if ($meta.Owners -and $meta.Owners.Count -gt 0) {
		$ownerEl = [ordered]@{ input = "Владелец"; path = "Объект.Owner"; readOnly = $true }
		$headerChildren += $ownerEl
	}

	# Code + Description
	$cdLayout = if ($p.codeDescription -and $p.codeDescription.layout) { $p.codeDescription.layout } else { "horizontal" }
	$cdOrder = if ($p.codeDescription -and $p.codeDescription.order) { $p.codeDescription.order } else { "descriptionFirst" }
	$hasCode = ($meta.CodeLength -gt 0)

	if ($cdLayout -eq "horizontal" -and $hasCode) {
		$cdChildren = @()
		$descEl = [ordered]@{ input = "Наименование"; path = "Объект.Description" }
		$codeEl = [ordered]@{ input = "Код"; path = "Объект.Code" }
		if ($cdOrder -eq "descriptionFirst") {
			$cdChildren = @($descEl, $codeEl)
		} else {
			$cdChildren = @($codeEl, $descEl)
		}
		$headerChildren += [ordered]@{
			group = "horizontal"; name = "ГруппаКодНаименование"; showTitle = $false
			representation = "none"; children = $cdChildren
		}
	} else {
		# Vertical or no code
		$headerChildren += [ordered]@{ input = "Наименование"; path = "Объект.Description" }
		if ($hasCode) {
			$headerChildren += [ordered]@{ input = "Код"; path = "Объект.Code" }
		}
	}

	# Parent (for hierarchical catalogs)
	$parentPos = if ($p.parent -and $p.parent.position) { $p.parent.position } else { "afterCodeDescription" }
	$parentTitle = if ($p.parent -and $p.parent.title) { $p.parent.title } else { $null }
	if ($meta.Hierarchical) {
		$parentEl = [ordered]@{ input = "Родитель"; path = "Объект.Parent" }
		if ($parentTitle) { $parentEl["title"] = $parentTitle }
		if ($parentPos -eq "beforeCodeDescription") {
			# Insert before Code/Description (after Owner if present)
			$insertIdx = if ($meta.Owners -and $meta.Owners.Count -gt 0) { 1 } else { 0 }
			$newChildren = @()
			for ($i = 0; $i -lt $headerChildren.Count; $i++) {
				if ($i -eq $insertIdx) { $newChildren += $parentEl }
				$newChildren += $headerChildren[$i]
			}
			$headerChildren = $newChildren
		} else {
			# afterCodeDescription (default)
			$headerChildren += $parentEl
		}
	}

	# Custom attributes → header
	$footerFieldNames = @()
	if ($p.footer -and $p.footer.fields) { $footerFieldNames = @($p.footer.fields) }

	foreach ($attr in $meta.Attributes) {
		if ($footerFieldNames -contains $attr.Name) { continue }
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$headerChildren += (New-FieldElement -attrName $attr.Name -dataPath "Объект.$($attr.Name)" -attrType $attr.Type -fieldDefaults $fd -extraProps @{})
	}

	# Build root elements
	$rootElements = @()

	# ГруппаШапка
	$rootElements += [ordered]@{
		group = "vertical"; name = "ГруппаШапка"; showTitle = $false
		representation = "none"; children = $headerChildren
	}

	# Tabular sections
	$tsExclude = @("ДополнительныеРеквизиты", "Представления")
	if ($p.tabularSections -and $p.tabularSections.exclude) { $tsExclude = @($p.tabularSections.exclude) }
	$tsLineNumber = if ($p.tabularSections -and $null -ne $p.tabularSections.lineNumber) { $p.tabularSections.lineNumber } else { $true }
	$tsContainer = if ($p.tabularSections -and $p.tabularSections.container) { $p.tabularSections.container } else { "inline" }

	$visibleTS = @()
	foreach ($ts in $meta.TabularSections) {
		if ($tsExclude -contains $ts.Name) { continue }
		$visibleTS += $ts
	}

	foreach ($ts in $visibleTS) {
		$tsCols = @()
		if ($tsLineNumber) {
			$tsCols += [ordered]@{ labelField = "$($ts.Name)НомерСтроки"; path = "Объект.$($ts.Name).LineNumber" }
		}
		foreach ($col in $ts.Columns) {
			$colEl = New-FieldElement -attrName "$($ts.Name)$($col.Name)" -dataPath "Объект.$($ts.Name).$($col.Name)" -attrType $col.Type -fieldDefaults $fd -extraProps @{}
			$tsCols += $colEl
		}
		$tableEl = [ordered]@{ table = $ts.Name; path = "Объект.$($ts.Name)"; columns = $tsCols }
		$rootElements += $tableEl
	}

	# Footer fields
	foreach ($fn in $footerFieldNames) {
		$fAttr = $meta.Attributes | Where-Object { $_.Name -eq $fn }
		if ($fAttr) {
			$rootElements += (New-FieldElement -attrName $fAttr.Name -dataPath "Объект.$($fAttr.Name)" -attrType $fAttr.Type -fieldDefaults $fd -extraProps @{})
		}
	}

	# BSP group
	$bspGroup = if ($p.additional -and $null -ne $p.additional.bspGroup) { $p.additional.bspGroup } else { $true }
	if ($bspGroup) {
		$rootElements += [ordered]@{ group = "vertical"; name = "ГруппаДополнительныеРеквизиты" }
	}

	# Properties
	$formProps = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $formProps[$k] = $p.properties[$k] } }
	# UseForFoldersAndItems
	if ($meta.Hierarchical -and $meta.HierarchyType -eq "HierarchyFoldersAndItems") {
		$formProps["useForFoldersAndItems"] = "Items"
	}

	return [ordered]@{
		title = $meta.Synonym
		properties = $formProps
		elements = $rootElements
		attributes = @(
			[ordered]@{ name = "Объект"; type = "CatalogObject.$($meta.Name)"; main = $true }
		)
	}
}

# --- Document DSL generators ---
function Generate-DocumentDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)

	$purposeKey = "document.$($purpose.ToLower())"
	$p = if ($presetData.ContainsKey($purposeKey)) { $presetData[$purposeKey] } else { @{} }
	$fd = if ($p.ContainsKey("fieldDefaults")) { $p.fieldDefaults } else { @{} }

	switch ($purpose) {
		"List"   { return Generate-DocumentListDSL $meta $p }
		"Choice" { return Generate-DocumentChoiceDSL $meta $p $presetData }
		"Item"   { return Generate-DocumentItemDSL $meta $p $fd }
	}
}

function Generate-DocumentListDSL($meta, [hashtable]$p) {
	$columns = @()
	# Standard columns: Number + Date
	$columns += [ordered]@{ labelField = "Номер"; path = "Список.Number" }
	$columns += [ordered]@{ labelField = "Дата"; path = "Список.Date" }
	# All custom attributes as labelField
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$columns += [ordered]@{ labelField = $attr.Name; path = "Список.$($attr.Name)" }
	}
	# Hidden ref
	if (-not $p.ContainsKey("hiddenRef") -or $p.hiddenRef -eq $true) {
		$columns += [ordered]@{ labelField = "Ссылка"; path = "Список.Ref"; userVisible = $false }
	}

	$tableEl = [ordered]@{
		table = "Список"; path = "Список"
		rowPictureDataPath = "Список.DefaultPicture"
		commandBarLocation = "None"
		tableAutofill = $false
		columns = $columns
	}

	$formProps = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $formProps[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $formProps
		elements = @($tableEl)
		attributes = @(
			[ordered]@{
				name = "Список"; type = "DynamicList"; main = $true
				settings = [ordered]@{ mainTable = "Document.$($meta.Name)"; dynamicDataRead = $true }
			}
		)
	}
}

function Generate-DocumentChoiceDSL($meta, [hashtable]$p, [hashtable]$presetData) {
	$listKey = "document.list"
	$lp = if ($presetData.ContainsKey($listKey)) { $presetData[$listKey] } else { @{} }
	$dsl = Generate-DocumentListDSL $meta $lp

	$dsl.properties["windowOpeningMode"] = "LockOwnerWindow"
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $dsl.properties[$k] = $p.properties[$k] } }

	return $dsl
}

function Generate-DocumentItemDSL($meta, [hashtable]$p, [hashtable]$fd) {
	$headerPos = if ($p.header -and $p.header.position) { $p.header.position } else { "insidePage" }
	$headerLayout = if ($p.header -and $p.header.layout) { $p.header.layout } else { "2col" }
	$headerDistribute = if ($p.header -and $p.header.distribute) { $p.header.distribute } else { "even" }
	$dateTitle = if ($p.header -and $p.header.dateTitle) { $p.header.dateTitle } else { "от" }

	$footerFields = @()
	if ($p.footer -and $p.footer.fields) { $footerFields = @($p.footer.fields) }
	$footerPos = if ($p.footer -and $p.footer.position) { $p.footer.position } else { "insidePage" }

	$addPos = if ($p.additional -and $p.additional.position) { $p.additional.position } else { "page" }
	$addLayout = if ($p.additional -and $p.additional.layout) { $p.additional.layout } else { "2col" }
	$addBspGroup = if ($p.additional -and $null -ne $p.additional.bspGroup) { $p.additional.bspGroup } else { $true }
	$addLeft = @(); $addRight = @()
	if ($p.additional -and $p.additional.left) { $addLeft = @($p.additional.left) }
	if ($p.additional -and $p.additional.right) { $addRight = @($p.additional.right) }

	$headerRight = @()
	if ($p.header -and $p.header.right) { $headerRight = @($p.header.right) }

	$tsExclude = @("ДополнительныеРеквизиты")
	if ($p.tabularSections -and $p.tabularSections.exclude) { $tsExclude = @($p.tabularSections.exclude) }
	$tsLineNumber = if ($p.tabularSections -and $null -ne $p.tabularSections.lineNumber) { $p.tabularSections.lineNumber } else { $true }

	# Classify attributes
	$claimed = @{}
	foreach ($fn in $footerFields) { $claimed[$fn] = "footer" }
	foreach ($fn in $headerRight) { $claimed[$fn] = "header.right" }
	foreach ($fn in $addLeft) { $claimed[$fn] = "additional.left" }
	foreach ($fn in $addRight) { $claimed[$fn] = "additional.right" }

	$unclaimed = @()
	foreach ($attr in $meta.Attributes) {
		if (-not $claimed.ContainsKey($attr.Name) -and (Test-DisplayableType $attr.Type)) { $unclaimed += $attr }
	}

	# Distribute unclaimed
	$leftAttrs = @(); $rightExtraAttrs = @()
	switch ($headerDistribute) {
		"left"  { $leftAttrs = $unclaimed }
		"right" { $rightExtraAttrs = $unclaimed }
		default { # "even"
			$half = [Math]::Ceiling($unclaimed.Count / 2)
			for ($i = 0; $i -lt $unclaimed.Count; $i++) {
				if ($i -lt $half) { $leftAttrs += $unclaimed[$i] }
				else { $rightExtraAttrs += $unclaimed[$i] }
			}
		}
	}

	# Build ГруппаНомерДата
	$numDateChildren = @(
		[ordered]@{ input = "Номер"; path = "Объект.Number"; autoMaxWidth = $false; width = 9 }
		[ordered]@{ input = "Дата"; path = "Объект.Date"; title = $dateTitle }
	)
	$numDateGroup = [ordered]@{
		group = "horizontal"; name = "ГруппаНомерДата"; showTitle = $false; children = $numDateChildren
	}

	# Build left column
	$leftChildren = @($numDateGroup)
	foreach ($attr in $leftAttrs) {
		$leftChildren += (New-FieldElement -attrName $attr.Name -dataPath "Объект.$($attr.Name)" -attrType $attr.Type -fieldDefaults $fd -extraProps @{})
	}

	# Build right column
	$rightChildren = @()
	foreach ($rn in $headerRight) {
		$rAttr = $meta.Attributes | Where-Object { $_.Name -eq $rn }
		if ($rAttr) {
			$rightChildren += (New-FieldElement -attrName $rAttr.Name -dataPath "Объект.$($rAttr.Name)" -attrType $rAttr.Type -fieldDefaults $fd -extraProps @{})
		}
	}
	foreach ($attr in $rightExtraAttrs) {
		$rightChildren += (New-FieldElement -attrName $attr.Name -dataPath "Объект.$($attr.Name)" -attrType $attr.Type -fieldDefaults $fd -extraProps @{})
	}

	# Header group
	$headerGroup = $null
	if ($headerLayout -eq "2col" -and $rightChildren.Count -gt 0) {
		$headerGroup = [ordered]@{
			group = "horizontal"; name = "ГруппаШапка"; showTitle = $false; representation = "none"
			children = @(
				[ordered]@{ group = "vertical"; name = "ГруппаШапкаЛево"; showTitle = $false; children = $leftChildren }
				[ordered]@{ group = "vertical"; name = "ГруппаШапкаПраво"; showTitle = $false; children = $rightChildren }
			)
		}
	} else {
		# 1col or no right items
		$allHeaderFields = $leftChildren + $rightChildren
		$headerGroup = [ordered]@{
			group = "horizontal"; name = "ГруппаШапка"; showTitle = $false; representation = "none"
			children = @(
				[ordered]@{ group = "vertical"; name = "ГруппаШапкаЛево"; showTitle = $false; children = $allHeaderFields }
			)
		}
	}

	# Footer elements
	$footerElements = @()
	foreach ($fn in $footerFields) {
		$fAttr = $meta.Attributes | Where-Object { $_.Name -eq $fn }
		if ($fAttr -and (Test-DisplayableType $fAttr.Type)) {
			$footerElements += (New-FieldElement -attrName $fAttr.Name -dataPath "Объект.$($fAttr.Name)" -attrType $fAttr.Type -fieldDefaults $fd -extraProps @{})
		}
	}

	# Visible tabular sections
	$visibleTS = @()
	foreach ($ts in $meta.TabularSections) {
		if ($tsExclude -contains $ts.Name) { continue }
		$visibleTS += $ts
	}

	# Additional page content
	$additionalPage = $null
	if ($addPos -eq "page") {
		$addLeftEls = @(); $addRightEls = @()
		foreach ($aln in $addLeft) {
			$alAttr = $meta.Attributes | Where-Object { $_.Name -eq $aln }
			if ($alAttr) {
				$addLeftEls += (New-FieldElement -attrName $alAttr.Name -dataPath "Объект.$($alAttr.Name)" -attrType $alAttr.Type -fieldDefaults $fd -extraProps @{})
			}
		}
		foreach ($arn in $addRight) {
			$arAttr = $meta.Attributes | Where-Object { $_.Name -eq $arn }
			if ($arAttr) {
				$addRightEls += (New-FieldElement -attrName $arAttr.Name -dataPath "Объект.$($arAttr.Name)" -attrType $arAttr.Type -fieldDefaults $fd -extraProps @{})
			}
		}
		$addPageChildren = @()
		if ($addLayout -eq "2col") {
			$addPageChildren += [ordered]@{
				group = "horizontal"; name = "ГруппаПараметры"; showTitle = $false
				children = @(
					[ordered]@{ group = "vertical"; name = "ГруппаПараметрыЛево"; showTitle = $false; children = $addLeftEls }
					[ordered]@{ group = "vertical"; name = "ГруппаПараметрыПраво"; showTitle = $false; children = $addRightEls }
				)
			}
		} else {
			$addPageChildren += @($addLeftEls + $addRightEls)
		}
		if ($addBspGroup) {
			$addPageChildren += [ordered]@{ group = "vertical"; name = "ГруппаДополнительныеРеквизиты" }
		}
		$additionalPage = [ordered]@{ page = "ГруппаДополнительно"; title = "Дополнительно"; children = $addPageChildren }
	}

	# Build TS page elements
	$tsPages = @()
	foreach ($ts in $visibleTS) {
		$tsCols = @()
		if ($tsLineNumber) {
			$tsCols += [ordered]@{ labelField = "$($ts.Name)НомерСтроки"; path = "Объект.$($ts.Name).LineNumber" }
		}
		foreach ($col in $ts.Columns) {
			$tsCols += (New-FieldElement -attrName "$($ts.Name)$($col.Name)" -dataPath "Объект.$($ts.Name).$($col.Name)" -attrType $col.Type -fieldDefaults $fd -extraProps @{})
		}
		$tsPages += [ordered]@{
			page = "Группа$($ts.Name)"; title = $ts.Synonym
			children = @(
				[ordered]@{ table = $ts.Name; path = "Объект.$($ts.Name)"; columns = $tsCols }
			)
		}
	}

	# Assemble root elements
	$rootElements = @()

	if ($visibleTS.Count -eq 0) {
		# Simple form — no Pages
		$rootElements += $headerGroup
		if ($footerElements.Count -gt 0) { $rootElements += $footerElements }
		if ($addBspGroup -and $addPos -ne "none") {
			$rootElements += [ordered]@{ group = "vertical"; name = "ГруппаДополнительныеРеквизиты" }
		}
	} else {
		# Pages form
		if ($headerPos -eq "abovePages") {
			$rootElements += $headerGroup
			$pagesChildren = @()
			$pagesChildren += $tsPages
			if ($additionalPage) { $pagesChildren += $additionalPage }
			$rootElements += [ordered]@{ pages = "ГруппаСтраницы"; children = $pagesChildren }
		} else {
			# insidePage (default)
			$osnovnoeChildren = @($headerGroup)
			if ($footerPos -eq "insidePage" -and $footerElements.Count -gt 0) {
				$osnovnoeChildren += $footerElements
			}
			$pagesChildren = @()
			$pagesChildren += [ordered]@{ page = "ГруппаОсновное"; title = "Основное"; children = $osnovnoeChildren }
			$pagesChildren += $tsPages
			if ($additionalPage) { $pagesChildren += $additionalPage }
			$rootElements += [ordered]@{ pages = "ГруппаСтраницы"; children = $pagesChildren }
		}

		# Footer below pages
		if ($footerPos -eq "belowPages" -and $footerElements.Count -gt 0) {
			$rootElements += $footerElements
		}
	}

	# Properties
	$formProps = [ordered]@{ autoTitle = $false }
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $formProps[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $formProps
		elements = $rootElements
		attributes = @(
			[ordered]@{ name = "Объект"; type = "DocumentObject.$($meta.Name)"; main = $true }
		)
	}
}

# ─── InformationRegister ──────────────────────────────────────────────────

function Generate-InformationRegisterDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)
	$pKey = "informationRegister.$($purpose.ToLower())"
	$p = if ($presetData.ContainsKey($pKey)) { $presetData[$pKey] } else { @{} }
	$fd = if ($p.fieldDefaults) { $p.fieldDefaults } else { @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } } }
	switch ($purpose) {
		"Record" { return Generate-InformationRegisterRecordDSL $meta $p $fd }
		"List"   { return Generate-InformationRegisterListDSL $meta $p }
	}
}

function Generate-InformationRegisterRecordDSL($meta, [hashtable]$p, [hashtable]$fd) {
	$elements = @()
	$isPeriodic = $meta.Periodicity -and $meta.Periodicity -ne "Nonperiodical"

	# Period first (if periodic)
	if ($isPeriodic) {
		$elements += [ordered]@{ input = "Период"; path = "Запись.Period" }
	}
	# Dimensions
	foreach ($dim in $meta.Dimensions) {
		if (-not (Test-DisplayableType $dim.Type)) { continue }
		$elements += (New-FieldElement -attrName $dim.Name -dataPath "Запись.$($dim.Name)" -attrType $dim.Type -fieldDefaults $fd)
	}
	# Resources
	foreach ($res in $meta.Resources) {
		if (-not (Test-DisplayableType $res.Type)) { continue }
		$elements += (New-FieldElement -attrName $res.Name -dataPath "Запись.$($res.Name)" -attrType $res.Type -fieldDefaults $fd)
	}
	# Attributes
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$elements += (New-FieldElement -attrName $attr.Name -dataPath "Запись.$($attr.Name)" -attrType $attr.Type -fieldDefaults $fd)
	}

	$props = [ordered]@{ windowOpeningMode = "LockOwnerWindow" }
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $props
		elements = $elements
		attributes = @(
			@{ name = "Запись"; type = "InformationRegisterRecordManager.$($meta.Name)"; main = $true; savedData = $true }
		)
	}
}

function Generate-InformationRegisterListDSL($meta, [hashtable]$p) {
	$isPeriodic = $meta.Periodicity -and $meta.Periodicity -ne "Nonperiodical"
	$isRecorderSubordinate = $meta.WriteMode -eq "RecorderSubordinate"

	$columns = @()
	# Period
	if ($isPeriodic) {
		$columns += [ordered]@{ labelField = "Период"; path = "Список.Period" }
	}
	# Recorder/LineNumber for subordinate registers
	if ($isRecorderSubordinate) {
		$columns += [ordered]@{ labelField = "Регистратор"; path = "Список.Recorder" }
		$columns += [ordered]@{ labelField = "НомерСтроки"; path = "Список.LineNumber" }
	}
	# Dimensions
	foreach ($dim in $meta.Dimensions) {
		if (-not (Test-DisplayableType $dim.Type)) { continue }
		$columns += [ordered]@{ labelField = $dim.Name; path = "Список.$($dim.Name)" }
	}
	# Resources
	foreach ($res in $meta.Resources) {
		if (-not (Test-DisplayableType $res.Type)) { continue }
		$elKey = "labelField"
		if ($res.Type -match '^xs:boolean$|^Boolean$') { $elKey = "check" }
		$columns += [ordered]@{ $elKey = $res.Name; path = "Список.$($res.Name)" }
	}
	# Attributes
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$elKey = "labelField"
		if ($attr.Type -match '^xs:boolean$|^Boolean$') { $elKey = "check" }
		$columns += [ordered]@{ $elKey = $attr.Name; path = "Список.$($attr.Name)" }
	}

	$tableEl = [ordered]@{
		table = "Список"; path = "Список"
		rowPictureDataPath = "Список.DefaultPicture"
		commandBarLocation = "None"
		tableAutofill = $false
		columns = $columns
	}

	$props = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $props
		elements = @($tableEl)
		attributes = @(
			@{ name = "Список"; type = "DynamicList"; main = $true; settings = @{ mainTable = "InformationRegister.$($meta.Name)"; dynamicDataRead = $true } }
		)
	}
}

# ─── AccumulationRegister ─────────────────────────────────────────────────

function Generate-AccumulationRegisterDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)
	$pKey = "accumulationRegister.$($purpose.ToLower())"
	$p = if ($presetData.ContainsKey($pKey)) { $presetData[$pKey] } else { @{} }
	switch ($purpose) {
		"List" { return Generate-AccumulationRegisterListDSL $meta $p }
	}
}

function Generate-AccumulationRegisterListDSL($meta, [hashtable]$p) {
	$columns = @()
	# AccumulationRegisters always have Period, Recorder, LineNumber
	$columns += [ordered]@{ labelField = "Период"; path = "Список.Period" }
	$columns += [ordered]@{ labelField = "Регистратор"; path = "Список.Recorder" }
	$columns += [ordered]@{ labelField = "НомерСтроки"; path = "Список.LineNumber" }
	# Dimensions
	foreach ($dim in $meta.Dimensions) {
		if (-not (Test-DisplayableType $dim.Type)) { continue }
		$columns += [ordered]@{ labelField = $dim.Name; path = "Список.$($dim.Name)" }
	}
	# Resources
	foreach ($res in $meta.Resources) {
		if (-not (Test-DisplayableType $res.Type)) { continue }
		$elKey = "labelField"
		if ($res.Type -match '^xs:boolean$|^Boolean$') { $elKey = "check" }
		$columns += [ordered]@{ $elKey = $res.Name; path = "Список.$($res.Name)" }
	}
	# Attributes
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$elKey = "labelField"
		if ($attr.Type -match '^xs:boolean$|^Boolean$') { $elKey = "check" }
		$columns += [ordered]@{ $elKey = $attr.Name; path = "Список.$($attr.Name)" }
	}

	$tableEl = [ordered]@{
		table = "Список"; path = "Список"
		rowPictureDataPath = "Список.DefaultPicture"
		commandBarLocation = "None"
		tableAutofill = $false
		columns = $columns
	}

	$props = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $props
		elements = @($tableEl)
		attributes = @(
			@{ name = "Список"; type = "DynamicList"; main = $true; settings = @{ mainTable = "AccumulationRegister.$($meta.Name)"; dynamicDataRead = $true } }
		)
	}
}

# ─── ChartOfCharacteristicTypes (delegates to Catalog) ────────────────────

function Generate-ChartOfCharacteristicTypesDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)
	# Delegate to Catalog generators — meta already has CodeLength, DescriptionLength, etc.
	$dsl = Generate-CatalogDSL -meta $meta -presetData $presetData -purpose $purpose

	# Post-patch: replace Catalog types with ChartOfCharacteristicTypes types
	$catObjType = "CatalogObject.$($meta.Name)"
	$ccoctObjType = "ChartOfCharacteristicTypesObject.$($meta.Name)"
	$catListType = "Catalog.$($meta.Name)"
	$ccoctListType = "ChartOfCharacteristicTypes.$($meta.Name)"

	foreach ($a in $dsl.attributes) {
		if ($a.type -eq $catObjType) { $a.type = $ccoctObjType }
		if ($a.type -eq "DynamicList" -and $a.settings -and $a.settings.mainTable -eq $catListType) {
			$a.settings.mainTable = $ccoctListType
		}
	}

	# For Item forms: inject ValueType field after Code/Description
	if ($purpose -eq "Item" -and $dsl.elements) {
		$vtEl = [ordered]@{ input = "ТипЗначения"; path = "Объект.ValueType" }
		$newElements = @()
		$inserted = $false
		foreach ($el in $dsl.elements) {
			$newElements += $el
			if (-not $inserted) {
				$elName = if ($el.input) { $el.input } elseif ($el.name) { $el.name } elseif ($el.group) { $el.group } else { "" }
				if ($elName -eq "Наименование" -or $elName -eq "ГруппаКодНаименование") {
					$newElements += $vtEl
					$inserted = $true
				}
			}
		}
		if (-not $inserted) { $newElements += $vtEl }
		$dsl.elements = $newElements
	}

	return $dsl
}

# ─── ExchangePlan (delegates to Catalog) ──────────────────────────────────

function Generate-ExchangePlanDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)
	# ExchangePlans are not hierarchical and have no Folder form
	$dsl = Generate-CatalogDSL -meta $meta -presetData $presetData -purpose $purpose

	# Post-patch: replace Catalog types with ExchangePlan types
	$catObjType = "CatalogObject.$($meta.Name)"
	$epObjType = "ExchangePlanObject.$($meta.Name)"
	$catListType = "Catalog.$($meta.Name)"
	$epListType = "ExchangePlan.$($meta.Name)"

	foreach ($a in $dsl.attributes) {
		if ($a.type -eq $catObjType) { $a.type = $epObjType }
		if ($a.type -eq "DynamicList" -and $a.settings -and $a.settings.mainTable -eq $catListType) {
			$a.settings.mainTable = $epListType
		}
	}

	# For Item forms: inject SentNo, ReceivedNo after Code/Description
	if ($purpose -eq "Item" -and $dsl.elements) {
		$sentEl = [ordered]@{ input = "НомерОтправленного"; path = "Объект.SentNo"; readOnly = $true }
		$recvEl = [ordered]@{ input = "НомерПринятого"; path = "Объект.ReceivedNo"; readOnly = $true }
		$newElements = @()
		$inserted = $false
		foreach ($el in $dsl.elements) {
			$newElements += $el
			if (-not $inserted) {
				$elName = if ($el.input) { $el.input } elseif ($el.name) { $el.name } elseif ($el.group) { $el.group } else { "" }
				if ($elName -eq "Наименование" -or $elName -eq "ГруппаКодНаименование") {
					$newElements += $sentEl
					$newElements += $recvEl
					$inserted = $true
				}
			}
		}
		if (-not $inserted) { $newElements += $sentEl; $newElements += $recvEl }
		$dsl.elements = $newElements
	}

	return $dsl
}

# ─── ChartOfAccounts ──────────────────────────────────────────────────────

function Generate-ChartOfAccountsDSL {
	param($meta, [hashtable]$presetData, [string]$purpose)
	$pKey = "chartOfAccounts.$($purpose.ToLower())"
	$p = if ($presetData.ContainsKey($pKey)) { $presetData[$pKey] } else { @{} }
	$fd = if ($p.fieldDefaults) { $p.fieldDefaults } else { @{ ref = @{ choiceButton = $true }; boolean = @{ element = "check" } } }
	switch ($purpose) {
		"Item"   { return Generate-ChartOfAccountsItemDSL $meta $p $fd $presetData }
		"Folder" { return Generate-ChartOfAccountsFolderDSL $meta $p }
		"List"   { return Generate-ChartOfAccountsListDSL $meta $presetData }
		"Choice" { return Generate-ChartOfAccountsChoiceDSL $meta $presetData }
	}
}

function Generate-ChartOfAccountsItemDSL($meta, [hashtable]$p, [hashtable]$fd, [hashtable]$presetData) {
	$elements = @()

	# Header: Code + Parent
	$headerLeftChildren = @()
	if ($meta.CodeLength -gt 0) {
		$headerLeftChildren += [ordered]@{ input = "Код"; path = "Объект.Code" }
	}
	$headerRightChildren = @()
	if ($meta.Hierarchical) {
		$parentTitle = if ($p.parent -and $p.parent.title) { $p.parent.title } else { "Подчинен счету" }
		$headerRightChildren += [ordered]@{ input = "Родитель"; path = "Объект.Parent"; title = $parentTitle }
	}

	if ($headerRightChildren.Count -gt 0) {
		$elements += [ordered]@{
			group = "horizontal"; name = "ГруппаШапка"; showTitle = $false; representation = "none"
			children = @(
				[ordered]@{ group = "vertical"; name = "ГруппаШапкаЛево"; showTitle = $false; children = $headerLeftChildren }
				[ordered]@{ group = "vertical"; name = "ГруппаШапкаПраво"; showTitle = $false; children = $headerRightChildren }
			)
		}
	} elseif ($headerLeftChildren.Count -gt 0) {
		$elements += $headerLeftChildren
	}

	# Description
	if ($meta.DescriptionLength -gt 0) {
		$elements += [ordered]@{ input = "Наименование"; path = "Объект.Description" }
	}

	# OffBalance
	$elements += [ordered]@{ check = "Забалансовый"; path = "Объект.OffBalance" }

	# AccountingFlags as checkboxes
	if ($meta.AccountingFlags -and $meta.AccountingFlags.Count -gt 0) {
		$flagChildren = @()
		foreach ($flag in $meta.AccountingFlags) {
			$flagChildren += [ordered]@{ check = $flag.Name; path = "Объект.$($flag.Name)" }
		}
		$elements += [ordered]@{
			group = "vertical"; name = "ГруппаПризнакиУчета"; title = "Признаки учета"
			children = $flagChildren
		}
	}

	# ExtDimensionTypes table
	if ($meta.MaxExtDimensionCount -gt 0) {
		$edCols = @()
		$edCols += [ordered]@{ input = "ВидСубконто"; path = "Объект.ExtDimensionTypes.ExtDimensionType" }
		$edCols += [ordered]@{ check = "ТолькоОбороты"; path = "Объект.ExtDimensionTypes.TurnoversOnly" }
		if ($meta.ExtDimensionAccountingFlags) {
			foreach ($edFlag in $meta.ExtDimensionAccountingFlags) {
				$edCols += [ordered]@{ check = $edFlag.Name; path = "Объект.ExtDimensionTypes.$($edFlag.Name)" }
			}
		}
		$elements += [ordered]@{
			table = "ВидыСубконто"
			path = "Объект.ExtDimensionTypes"
			columns = $edCols
		}
	}

	# Custom attributes
	foreach ($attr in $meta.Attributes) {
		if (-not (Test-DisplayableType $attr.Type)) { continue }
		$elements += (New-FieldElement -attrName $attr.Name -dataPath "Объект.$($attr.Name)" -attrType $attr.Type -fieldDefaults $fd)
	}

	# Tabular sections
	$tsExclude = @("ДополнительныеРеквизиты","Представления")
	foreach ($ts in $meta.TabularSections) {
		if ($tsExclude -contains $ts.Name) { continue }
		$tsCols = @()
		foreach ($col in $ts.Columns) {
			if (-not (Test-DisplayableType $col.Type)) { continue }
			$tsCols += (New-FieldElement -attrName "$($ts.Name)$($col.Name)" -dataPath "Объект.$($ts.Name).$($col.Name)" -attrType $col.Type -fieldDefaults $fd)
		}
		$elements += [ordered]@{ table = $ts.Name; path = "Объект.$($ts.Name)"; columns = $tsCols }
	}

	$props = [ordered]@{}
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		properties = $props
		elements = $elements
		attributes = @(
			@{ name = "Объект"; type = "ChartOfAccountsObject.$($meta.Name)"; main = $true; savedData = $true }
		)
	}
}

function Generate-ChartOfAccountsFolderDSL($meta, [hashtable]$p) {
	$elements = @()
	if ($meta.CodeLength -gt 0) {
		$elements += [ordered]@{ input = "Код"; path = "Объект.Code" }
	}
	if ($meta.DescriptionLength -gt 0) {
		$elements += [ordered]@{ input = "Наименование"; path = "Объект.Description" }
	}
	if ($meta.Hierarchical) {
		$parentTitle = if ($p.parent -and $p.parent.title) { $p.parent.title } else { "Подчинен счету" }
		$elements += [ordered]@{ input = "Родитель"; path = "Объект.Parent"; title = $parentTitle }
	}

	$props = [ordered]@{ windowOpeningMode = "LockOwnerWindow" }
	if ($p.properties) { foreach ($k in $p.properties.Keys) { $props[$k] = $p.properties[$k] } }

	return [ordered]@{
		title = $meta.Synonym
		useForFoldersAndItems = "Folders"
		properties = $props
		elements = $elements
		attributes = @(
			@{ name = "Объект"; type = "ChartOfAccountsObject.$($meta.Name)"; main = $true; savedData = $true }
		)
	}
}

function Generate-ChartOfAccountsListDSL($meta, [hashtable]$presetData) {
	# Delegate to Catalog List and patch types
	$dsl = Generate-CatalogDSL -meta $meta -presetData $presetData -purpose "List"
	foreach ($a in $dsl.attributes) {
		if ($a.type -eq "DynamicList" -and $a.settings -and $a.settings.mainTable -eq "Catalog.$($meta.Name)") {
			$a.settings.mainTable = "ChartOfAccounts.$($meta.Name)"
		}
	}
	return $dsl
}

function Generate-ChartOfAccountsChoiceDSL($meta, [hashtable]$presetData) {
	$dsl = Generate-CatalogDSL -meta $meta -presetData $presetData -purpose "Choice"
	foreach ($a in $dsl.attributes) {
		if ($a.type -eq "DynamicList" -and $a.settings -and $a.settings.mainTable -eq "Catalog.$($meta.Name)") {
			$a.settings.mainTable = "ChartOfAccounts.$($meta.Name)"
		}
	}
	return $dsl
}

# ═══════════════════════════════════════════════════════════════════════════
# END OF FROM-OBJECT MODE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# --- Detect XML format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$head = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8).Substring(0, [Math]::Min(2000, (Get-Item $cfgPath).Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

$script:outPathResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
$script:formatVersion = Detect-FormatVersion ([System.IO.Path]::GetDirectoryName($script:outPathResolved))

# --- 0. Path normalization and mode dispatch ---

# Form name → purpose mapping
$script:formNameToPurpose = @{
	"ФормаДокумента"  = "Item"
	"ФормаЭлемента"   = "Item"
	"ФормаСписка"     = "List"
	"ФормаВыбора"     = "Choice"
	"ФормаГруппы"     = "Folder"
	"ФормаЗаписи"     = "Record"
	"ФормаСчета"      = "Item"
	"ФормаУзла"       = "Item"
}

if ($FromObject -and $JsonPath) {
	Write-Error "Cannot use both -JsonPath and -FromObject. Choose one mode."
	exit 1
}
if (-not $FromObject -and -not $JsonPath) {
	Write-Error "Either -JsonPath or -FromObject is required."
	exit 1
}

if ($FromObject) {
	# Normalize OutputPath: append /Ext/Form.xml if missing
	$outNorm = $OutputPath -replace '[\\/]$', ''
	if ($outNorm -notmatch '[/\\]Ext[/\\]Form\.xml$') {
		if ($outNorm -match '[/\\]Ext$') {
			$OutputPath = "$outNorm/Form.xml"
		} else {
			$OutputPath = "$outNorm/Ext/Form.xml"
		}
		Write-Host "[resolved] OutputPath -> $OutputPath"
	}

	# Resolve object path and purpose from OutputPath convention:
	# .../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml
	$outAbs = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
	$pathParts = $outAbs -split '[/\\]'
	# Find "Forms" segment
	$formsIdx = -1
	for ($i = $pathParts.Count - 1; $i -ge 0; $i--) {
		if ($pathParts[$i] -eq "Forms") { $formsIdx = $i; break }
	}

	$resolvedObjectPath = $null
	$resolvedPurpose = $null

	if ($formsIdx -ge 2) {
		$formName = $pathParts[$formsIdx + 1]
		$objectName = $pathParts[$formsIdx - 1]
		$typePluralAndAbove = $pathParts[0..($formsIdx - 2)] -join [IO.Path]::DirectorySeparatorChar

		# Derive purpose from form name
		if ($script:formNameToPurpose.ContainsKey($formName)) {
			$resolvedPurpose = $script:formNameToPurpose[$formName]
		}

		# Derive object XML path
		$candidateObjPath = Join-Path $typePluralAndAbove "$objectName.xml"
		if (Test-Path $candidateObjPath) {
			$resolvedObjectPath = $candidateObjPath
		}
	}

	# Apply: explicit -ObjectPath / -Purpose override resolved values
	$fromObjPath = $null
	if ($ObjectPath) {
		$fromObjPath = if ([System.IO.Path]::IsPathRooted($ObjectPath)) { $ObjectPath } else { Join-Path (Get-Location) $ObjectPath }
		# Append .xml if missing
		if (-not $fromObjPath.EndsWith(".xml")) { $fromObjPath = "$fromObjPath.xml" }
	} elseif ($resolvedObjectPath) {
		$fromObjPath = $resolvedObjectPath
		Write-Host "[resolved] ObjectPath -> $fromObjPath"
	} else {
		Write-Error "Cannot derive object path from OutputPath. Use -ObjectPath explicitly."
		exit 1
	}

	if (-not (Test-Path $fromObjPath)) {
		Write-Error "Object file not found: $fromObjPath"
		exit 1
	}

	$effectivePurpose = if ($Purpose) { $Purpose } elseif ($resolvedPurpose) { $resolvedPurpose } else { "Item" }
	if ($resolvedPurpose -and -not $Purpose) {
		Write-Host "[resolved] Purpose -> $effectivePurpose"
	}

	$meta = Parse-ObjectMeta $fromObjPath
	Write-Host "[from-object] Type=$($meta.Type), Name=$($meta.Name), Attrs=$($meta.Attributes.Count), TS=$($meta.TabularSections.Count)"

	$presetData = Load-Preset -PresetName $Preset -ScriptDir $PSScriptRoot

	$supportedPurposes = switch ($meta.Type) {
		"Document"                    { @("Item","List","Choice") }
		"Catalog"                     { @("Item","Folder","List","Choice") }
		"InformationRegister"         { @("Record","List") }
		"AccumulationRegister"        { @("List") }
		"ChartOfCharacteristicTypes"  { @("Item","Folder","List","Choice") }
		"ExchangePlan"                { @("Item","List","Choice") }
		"ChartOfAccounts"             { @("Item","Folder","List","Choice") }
		default                       { @() }
	}
	if ($supportedPurposes.Count -eq 0) {
		Write-Error "Object type '$($meta.Type)' is not yet supported by --from-object. Supported: Document, Catalog, InformationRegister, AccumulationRegister, ChartOfCharacteristicTypes, ExchangePlan, ChartOfAccounts."
		exit 1
	}
	if ($supportedPurposes -notcontains $effectivePurpose) {
		Write-Error "Purpose '$effectivePurpose' is not valid for $($meta.Type). Valid: $($supportedPurposes -join ', ')"
		exit 1
	}

	# Generate DSL
	$dsl = switch ($meta.Type) {
		"Document"                    { Generate-DocumentDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"Catalog"                     { Generate-CatalogDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"InformationRegister"         { Generate-InformationRegisterDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"AccumulationRegister"        { Generate-AccumulationRegisterDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"ChartOfCharacteristicTypes"  { Generate-ChartOfCharacteristicTypesDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"ExchangePlan"                { Generate-ExchangePlanDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
		"ChartOfAccounts"             { Generate-ChartOfAccountsDSL -meta $meta -presetData $presetData -purpose $effectivePurpose }
	}

	# Emit DSL if requested
	if ($EmitDsl) {
		$dslJson = $dsl | ConvertTo-Json -Depth 20
		$dslPath = if ([System.IO.Path]::IsPathRooted($EmitDsl)) { $EmitDsl } else { Join-Path (Get-Location) $EmitDsl }
		$enc = New-Object System.Text.UTF8Encoding($true)
		[System.IO.File]::WriteAllText($dslPath, $dslJson, $enc)
		Write-Host "[from-object] DSL saved: $dslPath"
	}

	# Feed DSL into existing compiler
	$dslJson = $dsl | ConvertTo-Json -Depth 20
	$def = $dslJson | ConvertFrom-Json
} else {
	# --- 1. Load and validate JSON (original mode) ---

	if (-not (Test-Path $JsonPath)) {
		Write-Error "File not found: $JsonPath"
		exit 1
	}

	$json = Get-Content -Raw -Encoding UTF8 $JsonPath
	$def = $json | ConvertFrom-Json
}

# Базовая директория для @file-ссылок в query динсписка (зеркало skd-compile)
$script:queryBaseDir = if ($JsonPath) { [System.IO.Path]::GetDirectoryName((Resolve-Path $JsonPath).Path) } else { (Get-Location).Path }
function Resolve-QueryValue {
	param([string]$val, [string]$baseDir)
	if (-not $val.StartsWith("@")) { return $val }
	$filePath = $val.Substring(1)
	if ([System.IO.Path]::IsPathRooted($filePath)) {
		$candidates = @($filePath)
	} else {
		$candidates = @((Join-Path $baseDir $filePath), (Join-Path (Get-Location).Path $filePath))
	}
	foreach ($c in $candidates) { if (Test-Path $c) { return (Get-Content -Raw -Encoding UTF8 $c).TrimEnd() } }
	Write-Error "Query file not found: $filePath (searched: $($candidates -join ', '))"
	exit 1
}

# --- 2. ID allocator ---

$script:nextId = 1
function New-Id {
	$id = $script:nextId
	$script:nextId++
	return $id
}

# --- 3. XML helper ---

$script:xml = New-Object System.Text.StringBuilder 8192

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	# Экранирование ТЕКСТА элемента (<v8:content>, <Value>): только & < > .
	# Кавычки/апострофы в тексте экранировать НЕ нужно (1С их не экранирует — пишет литерально);
	# &quot; ломал бы раундтрип. Кавычки спецсимвольны лишь в значениях атрибутов.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# --- 4. Multilang helper ---

# Эмитит <v8:item> для значения: строка → один ru-элемент; объект {lang:text} → по элементу на язык.
function Emit-MLItems {
	param($val, [string]$indent)
	if ($val -is [System.Collections.IDictionary]) {
		foreach ($k in $val.Keys) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$k</v8:lang>"; X "$indent`t<v8:content>$(Esc-Xml "$($val[$k])")</v8:content>"; X "$indent</v8:item>"
		}
	} elseif ($val -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $val.PSObject.Properties) {
			X "$indent<v8:item>"; X "$indent`t<v8:lang>$($p.Name)</v8:lang>"; X "$indent`t<v8:content>$(Esc-Xml "$($p.Value)")</v8:content>"; X "$indent</v8:item>"
		}
	} else {
		X "$indent<v8:item>"; X "$indent`t<v8:lang>ru</v8:lang>"; X "$indent`t<v8:content>$(Esc-Xml "$val")</v8:content>"; X "$indent</v8:item>"
	}
}

function Emit-MLText {
	param([string]$tag, $text, [string]$indent)
	X "$indent<$tag>"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

# Детектор «настоящей» inline-разметки форматированного текста (1С: <link>/<b>/<color>/…
# и закрывающий </>). Плейсхолдеры вида <не заполнен> НЕ срабатывают (нет известного тега/</>).
# ВАЖНО: regex должен быть идентичен в form-decompile (иначе гибрид-раундтрип поедет).
$script:fmtMarkupRe = '</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)'
function Test-HasRealMarkup {
	param($text)
	if ($null -eq $text) { return $false }
	$vals = if ($text -is [System.Collections.IDictionary]) { @($text.Values) }
		elseif ($text -is [System.Management.Automation.PSCustomObject]) { @($text.PSObject.Properties.Value) }
		else { @("$text") }
	foreach ($v in $vals) { if ("$v" -match $script:fmtMarkupRe) { return $true } }
	return $false
}
# DSL-значение ML-поля → @{ text; formatted }. Форма {text, formatted} = явный override;
# строка/мапа → авто-детект formatted по разметке.
function Resolve-MLFormatted {
	param($val)
	$hasText = $false
	if ($val -is [System.Management.Automation.PSCustomObject]) { $hasText = [bool]$val.PSObject.Properties['text'] }
	elseif ($val -is [System.Collections.IDictionary]) { $hasText = $val.Contains('text') }
	if ($hasText) {
		$t = if ($val -is [System.Collections.IDictionary]) { $val['text'] } else { $val.text }
		$f = if ($val -is [System.Collections.IDictionary]) { $val['formatted'] } else { $val.formatted }
		return @{ text = $t; formatted = [bool]$f }
	}
	return @{ text = $val; formatted = (Test-HasRealMarkup $val) }
}

# Каноничные GUID пустых контейнеров ListSettings (умолчание платформы, ~90% форм).
# Декомпилятор опускает пустые настройки → компилятор регенерит этот скелет → раундтрип
# (harness нормализует GUID для хвоста с иными идентификаторами).
$script:CANON_FILTER_ID = 'dfcece9d-5077-440b-b6b3-45a5cb4538eb'
$script:CANON_ORDER_ID  = '88619765-ccb3-46c6-ac52-38e9c992ebd4'
$script:CANON_CA_ID     = 'b75fecce-942b-4aed-abc9-e6a02e460fb3'
$script:CANON_ITEMS_ID  = '911b6018-f537-43e8-a417-da56b22f9aec'

# ─────────────────────────────────────────────────────────────────────────────
# Настройки компоновщика ListSettings: filter/order/conditionalAppearance.
# Грамматика DSL и эмиссия dcsset скопированы из skd-compile (навыки автономны).
# ─────────────────────────────────────────────────────────────────────────────
function New-Guid-String { return [System.Guid]::NewGuid().ToString() }

$script:comparisonTypes = @{
	"=" = "Equal"; "<>" = "NotEqual"
	">" = "Greater"; ">=" = "GreaterOrEqual"
	"<" = "Less"; "<=" = "LessOrEqual"
	"in" = "InList"; "notIn" = "NotInList"
	"inHierarchy" = "InHierarchy"; "inListByHierarchy" = "InListByHierarchy"
	"contains" = "Contains"; "notContains" = "NotContains"
	"beginsWith" = "BeginsWith"; "notBeginsWith" = "NotBeginsWith"
	"filled" = "Filled"; "notFilled" = "NotFilled"
}

function Parse-FilterShorthand {
	param([string]$s)
	$result = @{ field = ""; op = "Equal"; value = $null; use = $true; userSettingID = $null; viewMode = $null; presentation = $null }
	if ($s -match '@user') { $result.userSettingID = "auto"; $s = $s -replace '\s*@user', '' }
	if ($s -match '@off') { $result.use = $false; $s = $s -replace '\s*@off', '' }
	if ($s -match '@quickAccess') { $result.viewMode = "QuickAccess"; $s = $s -replace '\s*@quickAccess', '' }
	if ($s -match '@normal') { $result.viewMode = "Normal"; $s = $s -replace '\s*@normal', '' }
	if ($s -match '@inaccessible') { $result.viewMode = "Inaccessible"; $s = $s -replace '\s*@inaccessible', '' }
	$s = $s.Trim()
	$opPatterns = @('<>', '>=', '<=', '=', '>', '<',
		'notIn\b', 'in\b', 'inHierarchy\b', 'inListByHierarchy\b',
		'notContains\b', 'contains\b', 'notBeginsWith\b', 'beginsWith\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'
	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$result.op = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }
		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") { $result.value = [bool]($valPart -eq "true"); $result["valueType"] = "xs:boolean" }
			elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') { $result.value = $valPart; $result["valueType"] = "xs:dateTime" }
			elseif ($valPart -match '^\d+(\.\d+)?$') { $result.value = $valPart; $result["valueType"] = "xs:decimal" }
			elseif ($valPart -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') { $result.value = $valPart; $result["valueType"] = "dcscor:DesignTimeValue" }
			else { $result.value = $valPart; $result["valueType"] = "xs:string" }
		}
	} else { $result.field = $s }
	return $result
}

function Emit-FilterItem {
	param($item, [string]$indent)
	if ($item.group) {
		$groupType = switch ("$($item.group)") { "And" { "AndGroup" } "Or" { "OrGroup" } "Not" { "NotGroup" } default { "$($item.group)Group" } }
		X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
		X "$indent`t<dcsset:groupType>$groupType</dcsset:groupType>"
		if ($item.items) {
			foreach ($sub in $item.items) {
				if ($sub -is [string]) {
					$parsed = Parse-FilterShorthand $sub
					$obj = @{ field = $parsed.field; op = $parsed.op }
					if ($parsed.use -eq $false) { $obj.use = $false }
					if ($null -ne $parsed.value) { $obj.value = $parsed.value }
					if ($parsed["valueType"]) { $obj.valueType = $parsed["valueType"] }
					if ($parsed.userSettingID) { $obj.userSettingID = $parsed.userSettingID }
					if ($parsed.viewMode) { $obj.viewMode = $parsed.viewMode }
					$sub = [pscustomobject]$obj
				}
				Emit-FilterItem -item $sub -indent "$indent`t"
			}
		}
		if ($item.presentation) { Emit-MLText -tag "dcsset:presentation" -text $item.presentation -indent "$indent`t" }
		if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>" }
		if ($item.userSettingID) {
			$guid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $guid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) { Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t" }
		X "$indent</dcsset:item>"
		return
	}
	X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemComparison`">"
	if ($item.use -eq $false) { X "$indent`t<dcsset:use>false</dcsset:use>" }
	X "$indent`t<dcsset:left xsi:type=`"dcscor:Field`">$(Esc-Xml "$($item.field)")</dcsset:left>"
	$compType = $script:comparisonTypes["$($item.op)"]
	if (-not $compType) { $compType = "$($item.op)" }
	X "$indent`t<dcsset:comparisonType>$(Esc-Xml $compType)</dcsset:comparisonType>"
	$valIsArray = ($item.value -is [array]) -or ($item.value -is [System.Collections.IList] -and $item.value -isnot [string])
	if ($valIsArray) {
		if (@($item.value).Count -eq 0) {
			X "$indent`t<dcsset:right xsi:type=`"v8:ValueListType`">"
			X "$indent`t`t<v8:valueType/>"
			X "$indent`t`t<v8:lastId xsi:type=`"xs:decimal`">-1</v8:lastId>"
			X "$indent`t</dcsset:right>"
		} else {
			foreach ($v in $item.value) {
				$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
				if (-not $vt) {
					if ($v -is [bool]) { $vt = 'xs:boolean' }
					elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vt = 'xs:decimal' }
					elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') { $vt = 'xs:dateTime' }
					elseif ("$v" -match '^-?\d+(\.\d+)?$') { $vt = 'xs:decimal' }
					elseif ("$v" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { $vt = 'dcscor:DesignTimeValue' }
					else { $vt = 'xs:string' }
				}
				$vStr = if ($v -is [bool]) { "$v".ToLower() } else { Esc-Xml "$v" }
				X "$indent`t<dcsset:right xsi:type=`"$vt`">$vStr</dcsset:right>"
			}
		}
	} elseif ($null -ne $item.value) {
		$vt = if ($item.valueType) { "$($item.valueType)" } else { "" }
		if (-not $vt) {
			$v = $item.value
			if ($v -is [bool]) { $vt = "xs:boolean" }
			elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vt = "xs:decimal" }
			elseif ("$v" -match '^\d{4}-\d{2}-\d{2}T') { $vt = "xs:dateTime" }
			elseif ("$v" -match '^-?\d+(\.\d+)?$') { $vt = "xs:decimal" }
			elseif ("$v" -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена|Catalog|Enum|Document|ChartOfAccounts|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { $vt = "dcscor:DesignTimeValue" }
			else { $vt = "xs:string" }
		}
		$vStr = if ($item.value -is [bool]) { "$($item.value)".ToLower() } else { Esc-Xml "$($item.value)" }
		X "$indent`t<dcsset:right xsi:type=`"$vt`">$vStr</dcsset:right>"
	}
	if ($item.presentation) { Emit-MLText -tag "dcsset:presentation" -text $item.presentation -indent "$indent`t" }
	if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>" }
	if ($item.userSettingID) {
		$uid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	if ($item.userSettingPresentation) { Emit-MLText -tag "dcsset:userSettingPresentation" -text $item.userSettingPresentation -indent "$indent`t" }
	X "$indent</dcsset:item>"
}

function Emit-Filter {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<dcsset:filter>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			$parsed = Parse-FilterShorthand $item
			$obj = @{ field = $parsed.field; op = $parsed.op }
			if ($parsed.use -eq $false) { $obj.use = $false }
			if ($null -ne $parsed.value) { $obj.value = $parsed.value }
			if ($parsed["valueType"]) { $obj.valueType = $parsed["valueType"] }
			if ($parsed.userSettingID) { $obj.userSettingID = $parsed.userSettingID }
			if ($parsed.viewMode) { $obj.viewMode = $parsed.viewMode }
			Emit-FilterItem -item ([pscustomobject]$obj) -indent "$indent`t"
		} else { Emit-FilterItem -item $item -indent "$indent`t" }
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:filter>"
}

function Emit-Order {
	param($items, [string]$indent, [switch]$skipAuto, $blockViewMode = $null, $blockUserSettingID = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<dcsset:order>"
	foreach ($item in $items) {
		if ($item -is [string]) {
			if ($item -eq "Auto") { if (-not $skipAuto) { X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>" } }
			else {
				$parts = $item -split '\s+'
				$field = $parts[0]
				$dir = "Asc"
				if ($parts.Count -gt 1 -and $parts[1] -match '^(?i)(desc|убыв)') { $dir = "Desc" }
				elseif ($parts.Count -gt 1 -and $parts[1] -match '^(?i)(asc|возр)') { $dir = "Asc" }
				X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
				X "$indent`t`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
				X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
				X "$indent`t</dcsset:item>"
			}
		} else {
			if ($item.field -eq "Auto" -or $item.type -eq "auto") { if (-not $skipAuto) { X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemAuto`"/>" }; continue }
			$dir = if ($item.direction) { "$($item.direction)" } else { "Asc" }
			if ($dir -match '^(?i)(desc|убыв)') { $dir = "Desc" } elseif ($dir -match '^(?i)(asc|возр)') { $dir = "Asc" }
			X "$indent`t<dcsset:item xsi:type=`"dcsset:OrderItemField`">"
			if ($item.use -eq $false) { X "$indent`t`t<dcsset:use>false</dcsset:use>" }
			X "$indent`t`t<dcsset:field>$(Esc-Xml "$($item.field)")</dcsset:field>"
			X "$indent`t`t<dcsset:orderType>$dir</dcsset:orderType>"
			if ($item.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>" }
			X "$indent`t</dcsset:item>"
		}
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:order>"
}

function Emit-AppearanceValue {
	param([string]$key, $val, [string]$indent)
	X "$indent<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
	function _HasKey { param($o, [string]$k)
		if ($o -is [PSCustomObject]) { return [bool]$o.PSObject.Properties[$k] }
		if ($o -is [System.Collections.IDictionary]) { return $o.Contains($k) }
		return $false
	}
	function _Get { param($o, [string]$k)
		if ($o -is [PSCustomObject]) { return $o.$k }
		if ($o -is [System.Collections.IDictionary]) { return $o[$k] }
		return $null
	}
	$isTopLevelLine = (_HasKey $val '@type') -and ("$(_Get $val '@type')" -eq 'Line')
	$useWrapper = $false
	$innerVal = $val
	$nestedItems = $null
	if ($isTopLevelLine) {
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	} elseif ((_HasKey $val 'value') -and (($val -is [PSCustomObject]) -or ($val -is [System.Collections.IDictionary]))) {
		$innerVal = (_Get $val 'value')
		if ((_HasKey $val 'use') -and ((_Get $val 'use') -eq $false)) { $useWrapper = $true }
		if (_HasKey $val 'items') { $nestedItems = (_Get $val 'items') }
	}
	if ($useWrapper) { X "$indent`t<dcscor:use>false</dcscor:use>" }
	X "$indent`t<dcscor:parameter>$(Esc-Xml $key)</dcscor:parameter>"
	$isFontDict = $false
	if ($innerVal -is [PSCustomObject]) {
		$tProp = $innerVal.PSObject.Properties['@type']
		if ($tProp -and "$($tProp.Value)" -eq 'Font') { $isFontDict = $true }
	} elseif ($innerVal -is [System.Collections.IDictionary]) {
		if ($innerVal.Contains('@type') -and "$($innerVal['@type'])" -eq 'Font') { $isFontDict = $true }
	}
	$isLineDict = $false
	if (_HasKey $innerVal '@type') { $isLineDict = ("$(_Get $innerVal '@type')" -eq 'Line') }
	$isDict = ($innerVal -is [hashtable]) -or ($innerVal -is [System.Collections.IDictionary]) -or ($innerVal -is [PSCustomObject])
	if ($isLineDict) {
		$lw = if (_HasKey $innerVal 'width') { _Get $innerVal 'width' } else { 0 }
		$lg = if (_HasKey $innerVal 'gap') { if ((_Get $innerVal 'gap')) { 'true' } else { 'false' } } else { 'false' }
		$ls = if (_HasKey $innerVal 'style') { "$(_Get $innerVal 'style')" } else { 'None' }
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Line`" width=`"$lw`" gap=`"$lg`">"
		X "$indent`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">$(Esc-Xml $ls)</v8ui:style>"
		X "$indent`t</dcscor:value>"
	} elseif ($isFontDict) {
		$attrParts = @()
		foreach ($attrName in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
			$av = $null
			if ($innerVal -is [PSCustomObject]) { $ap = $innerVal.PSObject.Properties[$attrName]; if ($ap) { $av = $ap.Value } }
			else { if ($innerVal.Contains($attrName)) { $av = $innerVal[$attrName] } }
			if ($null -ne $av) { $attrParts += "$attrName=`"$(Esc-Xml "$av")`"" }
		}
		X "$indent`t<dcscor:value xsi:type=`"v8ui:Font`" $($attrParts -join ' ')/>"
	} elseif ($isDict) {
		Emit-MLText -tag "dcscor:value" -text $innerVal -indent "$indent`t"
	} else {
		$actualVal = "$innerVal"
		$keyTypeMap = @{
			'Размещение'           = 'dcscor:DataCompositionTextPlacementType'
			'ГоризонтальноеПоложение' = 'v8ui:HorizontalAlign'
			'ВертикальноеПоложение' = 'v8ui:VerticalAlign'
			'ОриентацияТекста'     = 'xs:decimal'
			'РасположениеИтогов'   = 'dcscor:DataCompositionTotalPlacement'
			'ТипМакета'            = 'dcsset:DataCompositionGroupTemplateType'
		}
		$keyType = $keyTypeMap[$key]
		if ($keyType) { X "$indent`t<dcscor:value xsi:type=`"$keyType`">$(Esc-Xml $actualVal)</dcscor:value>" }
		elseif ($actualVal -match '^(style|web|win):') { X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $actualVal)</dcscor:value>" }
		elseif ($actualVal -eq "true" -or $actualVal -eq "false") { X "$indent`t<dcscor:value xsi:type=`"xs:boolean`">$actualVal</dcscor:value>" }
		elseif ($key -eq "Текст" -or $key -eq "Заголовок" -or $key -eq "Формат") { Emit-MLText -tag "dcscor:value" -text $actualVal -indent "$indent`t" }
		elseif ($actualVal -match '^-?\d+(\.\d+)?$') { X "$indent`t<dcscor:value xsi:type=`"xs:decimal`">$actualVal</dcscor:value>" }
		elseif ($key -eq 'ЦветТекста' -or $key -eq 'ЦветФона' -or $key -eq 'ЦветГраницы') { X "$indent`t<dcscor:value xsi:type=`"v8ui:Color`">$(Esc-Xml $actualVal)</dcscor:value>" }
		else { X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $actualVal)</dcscor:value>" }
	}
	if ($nestedItems) {
		$niProps = if ($nestedItems -is [PSCustomObject]) { $nestedItems.PSObject.Properties } else { $null }
		if ($niProps) { foreach ($np in $niProps) { Emit-AppearanceValue -key $np.Name -val $np.Value -indent "$indent`t" } }
		elseif ($nestedItems -is [System.Collections.IDictionary]) { foreach ($nk in $nestedItems.Keys) { Emit-AppearanceValue -key $nk -val $nestedItems[$nk] -indent "$indent`t" } }
	}
	X "$indent</dcscor:item>"
}

function Emit-ConditionalAppearance {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<dcsset:conditionalAppearance>"
	foreach ($ca in $items) {
		X "$indent`t<dcsset:item>"
		if ($ca.use -eq $false) { X "$indent`t`t<dcsset:use>false</dcsset:use>" }
		if ($ca.selection -and $ca.selection.Count -gt 0) {
			X "$indent`t`t<dcsset:selection>"
			foreach ($sel in $ca.selection) {
				X "$indent`t`t`t<dcsset:item>"
				X "$indent`t`t`t`t<dcsset:field>$(Esc-Xml "$sel")</dcsset:field>"
				X "$indent`t`t`t</dcsset:item>"
			}
			X "$indent`t`t</dcsset:selection>"
		} else { X "$indent`t`t<dcsset:selection/>" }
		if ($ca.filter -and $ca.filter.Count -gt 0) { Emit-Filter -items $ca.filter -indent "$indent`t`t" }
		else { X "$indent`t`t<dcsset:filter/>" }
		if ($ca.appearance) {
			X "$indent`t`t<dcsset:appearance>"
			foreach ($prop in $ca.appearance.PSObject.Properties) { Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$indent`t`t`t" }
			X "$indent`t`t</dcsset:appearance>"
		}
		if ($ca.presentation) {
			if ($ca.presentation -is [hashtable] -or $ca.presentation -is [System.Collections.IDictionary] -or $ca.presentation -is [PSCustomObject]) { Emit-MLText -tag "dcsset:presentation" -text $ca.presentation -indent "$indent`t`t" }
			else { X "$indent`t`t<dcsset:presentation xsi:type=`"xs:string`">$(Esc-Xml "$($ca.presentation)")</dcsset:presentation>" }
		}
		if ($ca.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($ca.viewMode)")</dcsset:viewMode>" }
		if ($ca.userSettingID) {
			$uid = if ("$($ca.userSettingID)" -eq "auto") { New-Guid-String } else { "$($ca.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}
		if ($ca.userSettingPresentation) { Emit-MLText -tag "dcsset:userSettingPresentation" -text $ca.userSettingPresentation -indent "$indent`t`t" }
		if ($ca.useInDontUse -and $ca.useInDontUse.Count -gt 0) {
			$useInOrder = @('group','hierarchicalGroup','overall','fieldsHeader','header','parameters','filter','resourceFieldsHeader','overallHeader','overallResourceFieldsHeader')
			$set = @{}
			foreach ($n in $ca.useInDontUse) { $set["$n"] = $true }
			foreach ($n in $useInOrder) {
				if ($set.ContainsKey($n)) {
					$tag = "useIn" + ($n.Substring(0,1).ToUpper()) + ($n.Substring(1))
					X "$indent`t`t<dcsset:$tag>DontUse</dcsset:$tag>"
				}
			}
		}
		X "$indent`t</dcsset:item>"
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>" }
	if ($null -ne $blockUserSettingID) {
		$uid = if ("$blockUserSettingID" -eq 'auto') { New-Guid-String } else { "$blockUserSettingID" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	X "$indent</dcsset:conditionalAppearance>"
}

# --- 5. Type emitter ---

$script:formTypeSynonyms = New-Object System.Collections.Hashtable
$script:formTypeSynonyms["строка"]   = "string"
$script:formTypeSynonyms["число"]    = "decimal"
$script:formTypeSynonyms["булево"]   = "boolean"
$script:formTypeSynonyms["дата"]     = "date"
$script:formTypeSynonyms["датавремя"]= "dateTime"
$script:formTypeSynonyms["number"]   = "decimal"
$script:formTypeSynonyms["bool"]     = "boolean"
$script:formTypeSynonyms["справочникссылка"]            = "CatalogRef"
$script:formTypeSynonyms["справочникобъект"]            = "CatalogObject"
$script:formTypeSynonyms["документссылка"]              = "DocumentRef"
$script:formTypeSynonyms["документобъект"]              = "DocumentObject"
$script:formTypeSynonyms["перечислениессылка"]           = "EnumRef"
$script:formTypeSynonyms["плансчетовссылка"]             = "ChartOfAccountsRef"
$script:formTypeSynonyms["планвидовхарактеристикссылка"] = "ChartOfCharacteristicTypesRef"
$script:formTypeSynonyms["планвидоврасчётассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планвидоврасчетассылка"]        = "ChartOfCalculationTypesRef"
$script:formTypeSynonyms["планобменассылка"]              = "ExchangePlanRef"
$script:formTypeSynonyms["бизнеспроцессссылка"]           = "BusinessProcessRef"
$script:formTypeSynonyms["задачассылка"]                  = "TaskRef"
$script:formTypeSynonyms["определяемыйтип"]             = "DefinedType"
$script:formTypeSynonyms["характеристика"]             = "Characteristic"
$script:formTypeSynonyms["любаяссылка"]                = "AnyRef"
$script:formTypeSynonyms["любаяссылкаиб"]              = "AnyIBRef"

# Known invalid types (runtime/UI types that don't exist in XDTO schema)
$script:knownInvalidTypes = @{
	"FormDataStructure"     = "Runtime type. Use object type without cfg: prefix (e.g. CatalogObject.Контрагенты, DocumentObject.Приход)"
	"FormDataCollection"    = "Runtime type. Use ValueTable"
	"FormDataTree"          = "Runtime type. Use ValueTree"
	"FormDataTreeItem"      = "Runtime type, not valid in XML"
	"FormDataCollectionItem"= "Runtime type, not valid in XML"
	"FormGroup"             = "UI element type, not a data type"
	"FormField"             = "UI element type, not a data type"
	"FormButton"            = "UI element type, not a data type"
	"FormDecoration"        = "UI element type, not a data type"
	"FormTable"             = "UI element type, not a data type"
}

function Resolve-TypeStr {
	param([string]$typeStr)
	if (-not $typeStr) { return $typeStr }
	# Lenient: strip leading cfg: prefix if user passed it (canonical form is without prefix)
	if ($typeStr -match '^cfg:(.+)$') { $typeStr = $Matches[1] }
	if ($typeStr -match '^([^(]+)\((.+)\)$') {
		$base = $Matches[1].Trim(); $params = $Matches[2]
		$r = $script:formTypeSynonyms[$base.ToLower()]
		if ($r) { return "$r($params)" }
		return $typeStr
	}
	if ($typeStr.Contains('.')) {
		$i = $typeStr.IndexOf('.')
		$prefix = $typeStr.Substring(0, $i); $suffix = $typeStr.Substring($i)
		$r = $script:formTypeSynonyms[$prefix.ToLower()]
		if ($r) { return "$r$suffix" }
		return $typeStr
	}
	$r = $script:formTypeSynonyms[$typeStr.ToLower()]
	if ($r) { return $r }
	return $typeStr
}

function Emit-Type {
	param($typeStr, [string]$indent)

	if (-not $typeStr) {
		X "$indent<Type/>"
		return
	}

	$typeString = "$typeStr"

	# Composite type: "Type1 | Type2" or "Type1 + Type2"
	$parts = $typeString -split '\s*[|+]\s*'

	X "$indent<Type>"
	foreach ($part in $parts) {
		$part = $part.Trim()
		Emit-SingleType -typeStr $part -indent "$indent`t"
	}
	X "$indent</Type>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	$typeStr = Resolve-TypeStr $typeStr

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string or string(N)
	if ($typeStr -match '^string(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"
		return
	}

	# decimal(D,F) or decimal(D,F,nonneg)
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]
		$fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"
		return
	}

	# date / dateTime / time
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) {
			"date"     { "Date" }
			"dateTime" { "DateTime" }
			"time"     { "Time" }
		}
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"
		return
	}

	# ValueTable, ValueTree, ValueList, etc.
	$v8Types = @{
		"ValueTable"       = "v8:ValueTable"
		"ValueTree"        = "v8:ValueTree"
		"ValueList"        = "v8:ValueListType"
		"TypeDescription"  = "v8:TypeDescription"
		"Universal"        = "v8:Universal"
		"FixedArray"       = "v8:FixedArray"
		"FixedStructure"   = "v8:FixedStructure"
	}
	if ($v8Types.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($v8Types[$typeStr])</v8:Type>"
		return
	}

	# UI types
	$uiTypes = @{
		"FormattedString" = "v8ui:FormattedString"
		"Picture"         = "v8ui:Picture"
		"Color"           = "v8ui:Color"
		"Font"            = "v8ui:Font"
	}
	if ($uiTypes.ContainsKey($typeStr)) {
		X "$indent<v8:Type>$($uiTypes[$typeStr])</v8:Type>"
		return
	}

	# DCS types
	if ($typeStr -match '^DataComposition') {
		$dcsMap = @{
			"DataCompositionSettings"      = "dcsset:DataCompositionSettings"
			"DataCompositionSchema"        = "dcssch:DataCompositionSchema"
			"DataCompositionComparisonType" = "dcscor:DataCompositionComparisonType"
		}
		if ($dcsMap.ContainsKey($typeStr)) {
			X "$indent<v8:Type>$($dcsMap[$typeStr])</v8:Type>"
			return
		}
	}

	# DynamicList
	if ($typeStr -eq "DynamicList") {
		X "$indent<v8:Type>cfg:DynamicList</v8:Type>"
		return
	}

	# TypeSet (набор типов) → <v8:TypeSet>: определяемый тип / характеристика (именованные)
	# + «любая ссылка вида» (голый ref-вид без .Имя). Развязка с обычным типом — по наличию точки.
	if ($typeStr -match '^(DefinedType|Characteristic)\.') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}
	if ($typeStr -match '^(AnyRef|AnyIBRef|CatalogRef|DocumentRef|EnumRef|ExchangePlanRef|TaskRef|BusinessProcessRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef)$') {
		X "$indent<v8:TypeSet>cfg:$typeStr</v8:TypeSet>"
		return
	}

	# cfg: references (CatalogRef.XXX, DocumentObject.XXX, etc.)
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|InformationRegisterRecordSet|InformationRegisterRecordManager|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|ConstantsSet|DataProcessorObject|ReportObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# Fallback with validation
	if ($script:knownInvalidTypes.ContainsKey($typeStr)) {
		throw "Invalid form attribute type '$typeStr': $($script:knownInvalidTypes[$typeStr])"
	}
	# Платформенный тип с префиксом (v8:/v8ui:/xs:/dcs*:) — эмитим verbatim (напр. v8:UUID, v8:StandardPeriod).
	if ($typeStr -match '^(v8|v8ui|xs|ent|style|sys|web|win|dcs\w*):') {
		X "$indent<v8:Type>$typeStr</v8:Type>"
	} elseif ($typeStr.Contains('.')) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
	} else {
		Write-Warning "Unrecognized bare type '$typeStr' — will be emitted without namespace prefix"
		X "$indent<v8:Type>$typeStr</v8:Type>"
	}
}

# --- 6. Event handler name generator ---

$script:eventSuffixMap = @{
	"OnChange"             = "ПриИзменении"
	"StartChoice"          = "НачалоВыбора"
	"ChoiceProcessing"     = "ОбработкаВыбора"
	"AutoComplete"         = "АвтоПодбор"
	"Clearing"             = "Очистка"
	"Opening"              = "Открытие"
	"Click"                = "Нажатие"
	"OnActivateRow"        = "ПриАктивизацииСтроки"
	"BeforeAddRow"         = "ПередНачаломДобавления"
	"BeforeDeleteRow"      = "ПередУдалением"
	"BeforeRowChange"      = "ПередНачаломИзменения"
	"OnStartEdit"          = "ПриНачалеРедактирования"
	"OnEndEdit"            = "ПриОкончанииРедактирования"
	"Selection"            = "ВыборСтроки"
	"OnCurrentPageChange"  = "ПриСменеСтраницы"
	"TextEditEnd"          = "ОкончаниеВводаТекста"
	"URLProcessing"        = "ОбработкаНавигационнойСсылки"
	"DragStart"            = "НачалоПеретаскивания"
	"Drag"                 = "Перетаскивание"
	"DragCheck"            = "ПроверкаПеретаскивания"
	"Drop"                 = "Помещение"
	"AfterDeleteRow"       = "ПослеУдаления"
}

function Get-HandlerName {
	param([string]$elementName, [string]$eventName)
	$suffix = $script:eventSuffixMap[$eventName]
	if ($suffix) {
		return "$elementName$suffix"
	}
	return "$elementName$eventName"
}

# --- 7. Element emitters ---

function Get-ElementName {
	param($el, [string]$typeKey)
	if ($el.name) { return "$($el.name)" }
	return "$($el.$typeKey)"
}

$script:knownEvents = @{
	"input"     = @("OnChange","StartChoice","ChoiceProcessing","AutoComplete","TextEditEnd","Clearing","Creating","EditTextChange")
	"check"     = @("OnChange")
	"radio"     = @("OnChange")
	"label"     = @("Click","URLProcessing")
	"labelField"= @("OnChange","StartChoice","ChoiceProcessing","Click","URLProcessing","Clearing")
	"table"     = @("Selection","BeforeAddRow","AfterDeleteRow","BeforeDeleteRow","OnActivateRow","OnEditEnd","OnStartEdit","BeforeRowChange","BeforeEditEnd","ValueChoice","OnActivateCell","OnActivateField","Drag","DragStart","DragCheck","DragEnd","OnGetDataAtServer","BeforeLoadUserSettingsAtServer","OnUpdateUserSettingSetAtServer","OnChange")
	"pages"     = @("OnCurrentPageChange")
	"page"      = @("OnCurrentPageChange")
	"button"    = @("Click")
	"picField"  = @("OnChange","StartChoice","ChoiceProcessing","Click","Clearing")
	"calendar"  = @("OnChange","OnActivate")
	"picture"   = @("Click")
	"cmdBar"    = @()
	"popup"     = @()
	"group"     = @()
}
$script:knownFormEvents = @("OnCreateAtServer","OnOpen","BeforeClose","OnClose","NotificationProcessing","ChoiceProcessing","OnReadAtServer","AfterWriteAtServer","BeforeWriteAtServer","AfterWrite","BeforeWrite","OnWriteAtServer","FillCheckProcessingAtServer","OnLoadDataFromSettingsAtServer","BeforeLoadDataFromSettingsAtServer","OnSaveDataInSettingsAtServer","ExternalEvent","OnReopen","Opening")

# Собрать упорядоченный список событий элемента (имя, обработчик) из DSL.
# Основной формат: $el.events = { Событие: ИмяОбработчика } (null/"" → авто-имя по конвенции).
# Legacy (принимается ради совместимости): $el.on (массив) + $el.handlers (переопределение имён).
function Get-EventPairs {
	param($el, [string]$elementName)
	$pairs = New-Object System.Collections.ArrayList
	if ($el.events) {
		foreach ($p in $el.events.PSObject.Properties) {
			$h = "$($p.Value)"
			if ([string]::IsNullOrEmpty($h)) { $h = Get-HandlerName -elementName $elementName -eventName $p.Name }
			[void]$pairs.Add([pscustomobject]@{ name = $p.Name; handler = $h })
		}
	} elseif ($el.on) {
		foreach ($evt in $el.on) {
			$evtName = "$evt"
			$h = if ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" } else { Get-HandlerName -elementName $elementName -eventName $evtName }
			[void]$pairs.Add([pscustomobject]@{ name = $evtName; handler = $h })
		}
	}
	return $pairs
}

# Проверить, подключено ли событие к элементу (в любом из форматов).
function Test-ElementEvent {
	param($el, [string]$eventName)
	if ($el.events) {
		foreach ($p in $el.events.PSObject.Properties) { if ($p.Name -eq $eventName) { return $true } }
	}
	if ($el.on -contains $eventName) { return $true }
	return $false
}

function Emit-Events {
	param($el, [string]$elementName, [string]$indent, [string]$typeKey)

	$pairs = Get-EventPairs -el $el -elementName $elementName
	if ($pairs.Count -eq 0) { return }

	# Validate event names
	if ($typeKey -and $script:knownEvents.ContainsKey($typeKey)) {
		$allowed = $script:knownEvents[$typeKey]
		foreach ($pr in $pairs) {
			if ($allowed.Count -gt 0 -and $allowed -notcontains "$($pr.name)") {
				Write-Host "[WARN] Unknown event '$($pr.name)' for $typeKey '$elementName'. Known: $($allowed -join ', ')"
			}
		}
	}

	X "$indent<Events>"
	foreach ($pr in $pairs) {
		X "$indent`t<Event name=`"$($pr.name)`">$($pr.handler)</Event>"
	}
	X "$indent</Events>"
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent, $content = $null)
	$id = New-Id
	$hasContent = $null -ne $content -and -not ($content -is [string] -and "$content" -eq '')
	if (-not $hasContent) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	# Companion с контентом: <Title formatted="…"> (расширенная подсказка)
	X "$indent<$tag name=`"$name`" id=`"$id`">"
	$r = Resolve-MLFormatted $content
	$fmt = if ($r.formatted) { 'true' } else { 'false' }
	X "$indent`t<Title formatted=`"$fmt`">"
	Emit-MLItems -val $r.text -indent "$indent`t`t"
	X "$indent`t</Title>"
	X "$indent</$tag>"
}

# Companion-командная-панель (ContextMenu/AutoCommandBar) с контентом: { autofill?, children?[] }
# или массив = shorthand для { children }. Пусто/нет → self-closing companion (как Emit-Companion).
# Дети — обычная грамматика button/buttonGroup/popup (Emit-Element, inCmdBar).
function Emit-CompanionPanel {
	param([string]$tag, [string]$name, [string]$indent, $panel)
	$id = New-Id
	$autofill = $null
	$children = $null
	$halign = $null
	if ($panel -is [array]) {
		$children = $panel
	} elseif ($null -ne $panel) {
		if ($null -ne $panel.PSObject.Properties['autofill'] -and $null -ne $panel.autofill) { $autofill = [bool]$panel.autofill }
		if ($null -ne $panel.PSObject.Properties['horizontalAlign'] -and "$($panel.horizontalAlign)" -ne '') { $halign = "$($panel.horizontalAlign)" }
		$children = $panel.children
	}
	$hasChildren = $children -and @($children).Count -gt 0
	# Платформа пишет <Autofill> только при false; true = дефолт (тег опускается).
	$emitAfFalse = ($autofill -eq $false)
	if (-not $emitAfFalse -and -not $hasChildren -and -not $halign) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	X "$indent<$tag name=`"$name`" id=`"$id`">"
	if ($halign) { X "$indent`t<HorizontalAlign>$halign</HorizontalAlign>" }
	if ($emitAfFalse) { X "$indent`t<Autofill>false</Autofill>" }
	if ($hasChildren) {
		X "$indent`t<ChildItems>"
		foreach ($c in @($children)) { Emit-Element -el $c -indent "$indent`t`t" -inCmdBar $true }
		X "$indent`t</ChildItems>"
	}
	X "$indent</$tag>"
}

# Табличный addition (СтрокаПоиска/СостояниеПросмотра/УправлениеПоиском) с AdditionSource.
# Item = имя таблицы, Type фиксирован по виду; внутри — companion ContextMenu/ExtendedTooltip.
function Emit-TableAddition {
	param([string]$tag, [string]$tableName, [string]$nameSuffix, [string]$srcType, [string]$indent)
	$addName = "$tableName$nameSuffix"
	$id = New-Id
	X "$indent<$tag name=`"$addName`" id=`"$id`">"
	X "$indent`t<AdditionSource>"
	X "$indent`t`t<Item>$tableName</Item>"
	X "$indent`t`t<Type>$srcType</Type>"
	X "$indent`t</AdditionSource>"
	Emit-Companion -tag "ContextMenu" -name "${addName}КонтекстноеМеню" -indent "$indent`t"
	Emit-Companion -tag "ExtendedTooltip" -name "${addName}РасширеннаяПодсказка" -indent "$indent`t"
	X "$indent</$tag>"
}

function Emit-Element {
	param($el, [string]$indent, [bool]$inCmdBar = $false)

	# Companion-панели (объект/массив-значение) → commandBar/contextMenu, до тип-синонимов.
	Normalize-PanelSynonyms $el

	# Silent synonyms: model often writes XML name or Russian (ПолеПереключателя/RadioButtonField → radio).
	# Maps any synonym to canonical short DSL key.
	# commandBar/autoCommandBar/КоманднаяПанель → тип-элемент ТОЛЬКО при строковом значении (имя);
	# объект/массив уже отнесён к панель-свойству выше.
	$strOnlyKeys = @('commandBar','autoCommandBar','КоманднаяПанель')
	$synonyms = @{
		"commandBar"        = "cmdBar"
		"autoCommandBar"    = "autoCmdBar"
		"КоманднаяПанель"   = "cmdBar"
		"InputField"        = "input"
		"ПолеВвода"         = "input"
		"CheckBoxField"     = "check"
		"ПолеФлажка"        = "check"
		"RadioButtonField"  = "radio"
		"ПолеПереключателя" = "radio"
		"radioButton"       = "radio"
		"PictureField"      = "picField"
		"ПолеКартинки"      = "picField"
		"LabelField"        = "labelField"
		"ПолеНадписи"       = "labelField"
		"CalendarField"     = "calendar"
		"ПолеКалендаря"     = "calendar"
		"LabelDecoration"   = "label"
		"Надпись"           = "label"
		"PictureDecoration" = "picture"
		"Картинка"          = "picture"
		"UsualGroup"        = "group"
		"Группа"            = "group"
		"ОбычнаяГруппа"     = "group"
		"ColumnGroup"       = "columnGroup"
		"ГруппаКолонок"     = "columnGroup"
		"Pages"             = "pages"
		"ГруппаСтраниц"     = "pages"
		"Page"              = "page"
		"Страница"          = "page"
		"Table"             = "table"
		"Таблица"           = "table"
		"Button"            = "button"
		"Кнопка"            = "button"
		"Popup"             = "popup"
		"ВсплывающееМеню"   = "popup"
	}
	foreach ($pair in $synonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			if ($strOnlyKeys -contains $pair.Key -and -not ($el.($pair.Key) -is [string])) { continue }
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}

	# Determine element type from key
	$typeKey = $null
	$xmlTag = $null

	foreach ($key in @("columnGroup","buttonGroup","group","input","check","radio","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
		if ($el.$key -ne $null) {
			$typeKey = $key
			break
		}
	}

	if (-not $typeKey) {
		Write-Warning "Unknown element type, skipping"
		return
	}

	# Validate known keys — warn about typos and unknown properties
	$knownKeys = @{
		# type keys
		"group"=1;"columnGroup"=1;"buttonGroup"=1;"input"=1;"check"=1;"radio"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		# columnGroup-specific
		"showInHeader"=1
		# radio-specific
		"radioButtonType"=1;"choiceList"=1;"columnsCount"=1;"checkBoxType"=1;"editMode"=1
		# naming & binding
		"name"=1;"path"=1;"title"=1;"tooltip"=1;"tooltipRepresentation"=1;"extendedTooltip"=1
		# companion-панели (свойства): командная панель + контекстное меню
		"commandBar"=1;"contextMenu"=1
		# источник команд группы/панели (ButtonGroup/CommandBar)
		"commandSource"=1
		# visibility & state
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1;"userVisible"=1
		# events ("events" — основной формат; on/handlers — legacy, принимаются ради совместимости)
		"events"=1;"on"=1;"handlers"=1
		# layout
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		"maxWidth"=1;"maxHeight"=1
		"groupHorizontalAlign"=1;"groupVerticalAlign"=1;"horizontalAlign"=1
		# input-specific
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		"textEdit"=1
		"wrap"=1;"openButton"=1;"listChoiceMode"=1;"showInFooter"=1
		"extendedEditMultipleValues"=1;"chooseType"=1;"autoCellHeight"=1
		"choiceButtonRepresentation"=1;"footerHorizontalAlign"=1;"headerHorizontalAlign"=1
		# label/hyperlink
		"hyperlink"=1;"formatted"=1
		# group-specific
		"showTitle"=1;"united"=1;"collapsed"=1;"behavior"=1
		# hierarchy
		"children"=1;"columns"=1
		# table-specific
		"changeRowSet"=1;"changeRowOrder"=1;"autoInsertNewRow"=1;"rowFilter"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"viewStatusLocation"=1;"searchControlLocation"=1
		"excludedCommands"=1
		"choiceMode"=1;"initialTreeView"=1;"enableDrag"=1;"enableStartDrag"=1
		"rowPictureDataPath"=1;"tableAutofill"=1
		"rowSelectionMode"=1;"verticalLines"=1;"horizontalLines"=1
		# dynamic-list table block
		"defaultItem"=1;"useAlternationRowColor"=1;"fileDragMode"=1;"autoRefresh"=1
		"autoRefreshPeriod"=1;"choiceFoldersAndItems"=1;"restoreCurrentRow"=1;"showRoot"=1
		"allowRootChoice"=1;"updateOnDataChange"=1;"allowGettingCurrentRowURL"=1
		"userSettingsGroup"=1;"rowsPicture"=1
		# calendar-specific
		"selectionMode"=1;"showCurrentDate"=1;"widthInMonths"=1;"heightInMonths"=1;"showMonthsPanel"=1
		# pages-specific
		"pagesRepresentation"=1
		# button-specific
		"type"=1;"command"=1;"commandName"=1;"stdCommand"=1;"defaultButton"=1;"locationInCommandBar"=1
		# picture/decoration
		"src"=1;"valuesPicture"=1;"loadTransparent"=1
		# cmdBar-specific
		"autofill"=1
	}
	foreach ($p in $el.PSObject.Properties) {
		if ($p.Name -like '_*') { continue }  # внутренние маркеры (напр. _dynList)
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored. Check SKILL.md for valid keys."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	$id = New-Id

	switch ($typeKey) {
		"group"    { Emit-Group -el $el -name $name -id $id -indent $indent }
		"columnGroup" { Emit-ColumnGroup -el $el -name $name -id $id -indent $indent }
		"buttonGroup" { Emit-ButtonGroup -el $el -name $name -id $id -indent $indent }
		"input"    { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"    { Emit-Check -el $el -name $name -id $id -indent $indent }
		"radio"    { Emit-Radio -el $el -name $name -id $id -indent $indent }
		"label"    { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"    { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"    { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"     { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"   { Emit-Button -el $el -name $name -id $id -indent $indent -inCmdBar $inCmdBar }
		"picture"  { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"picField" { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar" { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"   { Emit-CommandBar -el $el -name $name -id $id -indent $indent }
		"popup"    { Emit-Popup -el $el -name $name -id $id -indent $indent }
	}
}

# Role-adjustable boolean (xr:Common + 0..N xr:Value name="Role.X").
# Единый механизм платформы: UserVisible (элементы), View/Edit (атрибуты), Use (команды/кнопки).
# Значение DSL: скаляр bool → только <xr:Common>; объект { common, roles:{ Имя: bool } } → +пер-ролевые исключения.
# Имя роли принимаем с/без префикса "Role." (forgiving); на выход всегда с префиксом.
function Emit-XrFlag {
	param([string]$tag, $val, [string]$indent)
	if ($null -eq $val) { return }
	if ($val -is [bool]) {
		X "$indent<$tag>"
		X "$indent`t<xr:Common>$(if ($val){'true'}else{'false'})</xr:Common>"
		X "$indent</$tag>"
		return
	}
	# объектная форма { common, roles }
	$common = if ($null -ne $val.common) { [bool]$val.common } else { $false }
	X "$indent<$tag>"
	X "$indent`t<xr:Common>$(if ($common){'true'}else{'false'})</xr:Common>"
	if ($val.roles) {
		foreach ($r in $val.roles.PSObject.Properties) {
			# Forgiving: принимаем имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role."
			$rname = "$($r.Name)" -replace '^(Role|Роль)\.', ''
			$rname = "Role.$rname"
			$rval = if ([bool]$r.Value) { 'true' } else { 'false' }
			X "$indent`t<xr:Value name=`"$rname`">$rval</xr:Value>"
		}
	}
	X "$indent</$tag>"
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($null -ne $el.userVisible) { Emit-XrFlag -tag 'UserVisible' -val $el.userVisible -indent $indent }
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

# Общие layout-свойства — применимы ко всем элементам. Порядок согласован с
# историческим выводом input/label, чтобы не сдвигать существующие снапшоты.
# -skipHeight: для Table (height → HeightInTableRows, эмитится в Emit-Table).
# -multiLineDefault: input без явного autoMaxWidth при multiLine → AutoMaxWidth=false.
# Общие свойства элемента (любой тип, включая Button/cmdBar): default/skip/drag.
function Emit-CommonElementProps {
	param($el, [string]$indent)
	if ($el.defaultItem -eq $true) { X "$indent<DefaultItem>true</DefaultItem>" }
	if ($el.PSObject.Properties['skipOnInput'] -and $null -ne $el.skipOnInput) {
		$siv = if ($el.skipOnInput -eq $true) { 'true' } else { 'false' }
		X "$indent<SkipOnInput>$siv</SkipOnInput>"
	}
	if ($el.enableStartDrag -eq $true) { X "$indent<EnableStartDrag>true</EnableStartDrag>" }
	if ($el.fileDragMode) { X "$indent<FileDragMode>$($el.fileDragMode)</FileDragMode>" }
	# Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
	foreach ($p in @(@('showInHeader','ShowInHeader'), @('showInFooter','ShowInFooter'), @('autoCellHeight','AutoCellHeight'))) {
		if ($null -ne $el.($p[0])) { X "$indent<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	if ($el.footerHorizontalAlign) { X "$indent<FooterHorizontalAlign>$($el.footerHorizontalAlign)</FooterHorizontalAlign>" }
	if ($el.headerHorizontalAlign) { X "$indent<HeaderHorizontalAlign>$($el.headerHorizontalAlign)</HeaderHorizontalAlign>" }
}

function Emit-Layout {
	param($el, [string]$indent, [switch]$skipHeight, [bool]$multiLineDefault = $false)
	Emit-CommonElementProps -el $el -indent $indent
	$amwExplicit = ($el.PSObject.Properties.Name -contains 'autoMaxWidth')
	if ($amwExplicit) {
		if ($el.autoMaxWidth -eq $false) { X "$indent<AutoMaxWidth>false</AutoMaxWidth>" }
	} elseif ($multiLineDefault) {
		X "$indent<AutoMaxWidth>false</AutoMaxWidth>"
	}
	if ($null -ne $el.maxWidth) { X "$indent<MaxWidth>$($el.maxWidth)</MaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$indent<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($null -ne $el.maxHeight) { X "$indent<MaxHeight>$($el.maxHeight)</MaxHeight>" }
	if ($el.width) { X "$indent<Width>$($el.width)</Width>" }
	if (-not $skipHeight -and $el.height) { X "$indent<Height>$($el.height)</Height>" }
	if ($null -ne $el.horizontalStretch) { X "$indent<HorizontalStretch>$(if ($el.horizontalStretch){'true'}else{'false'})</HorizontalStretch>" }
	if ($null -ne $el.verticalStretch) { X "$indent<VerticalStretch>$(if ($el.verticalStretch){'true'}else{'false'})</VerticalStretch>" }
	if ($el.groupHorizontalAlign) { X "$indent<GroupHorizontalAlign>$($el.groupHorizontalAlign)</GroupHorizontalAlign>" }
	if ($el.groupVerticalAlign) { X "$indent<GroupVerticalAlign>$($el.groupVerticalAlign)</GroupVerticalAlign>" }
	if ($el.horizontalAlign) { X "$indent<HorizontalAlign>$($el.horizontalAlign)</HorizontalAlign>" }
}

function Title-FromName {
	param([string]$name)
	if (-not $name) { return '' }
	$s = [regex]::Replace($name, '([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', '$1 $2')
	$s = [regex]::Replace($s, '([а-яa-z0-9])([А-ЯA-Z])', '$1 $2')
	$parts = $s -split ' '
	if ($parts.Count -eq 0) { return $s }
	$out = New-Object System.Collections.ArrayList
	[void]$out.Add($parts[0])
	for ($i = 1; $i -lt $parts.Count; $i++) {
		$p = $parts[$i]
		if ($p.Length -gt 1 -and $p -ceq $p.ToUpper()) {
			[void]$out.Add($p)
		} else {
			[void]$out.Add($p.ToLower())
		}
	}
	return ($out -join ' ')
}

function Emit-Title {
	# Нет ключа title → авто-вывод из имени (помощь модели).
	# Явный title: "" (или null) → подавить (заголовок не эмитим).
	# Явный непустой → эмитим как есть.
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	if ($hasKey) {
		if ($el.title) { Emit-MLText -tag "Title" -text $el.title -indent $indent }
	} elseif ($auto -and $name) {
		Emit-MLText -tag "Title" -text (Title-FromName -name $name) -indent $indent
	}
	# ToolTip элемента (всплывающая подсказка) — по схеме сразу после Title.
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	# ToolTipRepresentation — режим показа подсказки (None/Button/ShowBottom/…), после ToolTip.
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Map-TitleLoc {
	param([string]$v)
	switch ("$v".ToLower()) {
		"none"   { "None" }
		"left"   { "Left" }
		"right"  { "Right" }
		"top"    { "Top" }
		"bottom" { "Bottom" }
		"auto"   { "Auto" }
		default  { "$v" }
	}
}

# TitleLocation у check/radio: нет ключа → умный дефолт (Right/None), эмитится;
# "" → подавить (= дефолт платформы, она его сама не пишет); значение → эмитить (маппинг регистра).
function Emit-TitleLocation {
	param($el, [string]$indent, [string]$smartDefault)
	if ($null -ne $el.PSObject.Properties['titleLocation']) {
		if ($el.titleLocation) { X "$indent<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	} elseif ($smartDefault) {
		X "$indent<TitleLocation>$smartDefault</TitleLocation>"
	}
}

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<UsualGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
	$groupVal = "$($el.group)".ToLower()
	$orientation = switch ($groupVal) {
		"horizontal"       { "Horizontal" }
		"vertical"         { "Vertical" }
		"alwayshorizontal" { "AlwaysHorizontal" }
		"alwaysvertical"   { "AlwaysVertical" }
		"collapsible"      { "Vertical" }
		default            { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }

	# Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
	# Legacy: group:'collapsible' эквивалентно behavior:'collapsible'.
	$behaviorVal = if ($el.behavior) { "$($el.behavior)".ToLower() } elseif ($groupVal -eq "collapsible") { "collapsible" } else { $null }
	$bmap = @{ "usual"="Usual"; "collapsible"="Collapsible"; "popup"="PopUp" }
	if ($behaviorVal -and $bmap.ContainsKey($behaviorVal)) {
		X "$inner<Behavior>$($bmap[$behaviorVal])</Behavior>"
	}
	# Collapsed — у Collapsible и PopUp (не привязано к одному behavior)
	if ($el.collapsed -eq $true) { X "$inner<Collapsed>true</Collapsed>" }

	# Representation
	if ($el.representation) {
		$repr = switch ("$($el.representation)") {
			"none"             { "None" }
			"normal"           { "NormalSeparation" }
			"weak"             { "WeakSeparation" }
			"strong"           { "StrongSeparation" }
			default            { "$($el.representation)" }
		}
		X "$inner<Representation>$repr</Representation>"
	}

	# ShowTitle
	if ($el.showTitle -eq $false) { X "$inner<ShowTitle>false</ShowTitle>" }

	# United
	if ($el.united -eq $false) { X "$inner<United>false</United>" }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</UsualGroup>"
}

function Emit-ColumnGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ColumnGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (horizontal / vertical / inCell — последнее только здесь)
	$groupVal = "$($el.columnGroup)"
	$orientation = switch ($groupVal) {
		"horizontal" { "Horizontal" }
		"vertical"   { "Vertical" }
		"inCell"     { "InCell" }
		default      { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }

	if ($el.showTitle -eq $false) { X "$inner<ShowTitle>false</ShowTitle>" }
	# showInHeader эмитится общим Emit-CommonElementProps (через Emit-Layout)

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ColumnGroup>"
}

function Emit-Input {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<InputField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		$loc = switch ("$($el.titleLocation)") {
			"none"   { "None" }
			"left"   { "Left" }
			"right"  { "Right" }
			"top"    { "Top" }
			"bottom" { "Bottom" }
			default  { "$($el.titleLocation)" }
		}
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}

	if ($el.multiLine -eq $true) { X "$inner<MultiLine>true</MultiLine>" }
	if ($el.passwordMode -eq $true) { X "$inner<PasswordMode>true</PasswordMode>" }
	if ($el.choiceButton -eq $false) { X "$inner<ChoiceButton>false</ChoiceButton>" }
	elseif ($el.choiceButton -eq $true -and (Test-ElementEvent $el 'StartChoice')) { X "$inner<ChoiceButton>true</ChoiceButton>" }
	if ($el.clearButton -eq $true) { X "$inner<ClearButton>true</ClearButton>" }
	if ($el.spinButton -eq $true) { X "$inner<SpinButton>true</SpinButton>" }
	if ($el.dropListButton -eq $true) { X "$inner<DropListButton>true</DropListButton>" }
	if ($el.markIncomplete -eq $true) { X "$inner<AutoMarkIncomplete>true</AutoMarkIncomplete>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	if ($el.textEdit -eq $false) { X "$inner<TextEdit>false</TextEdit>" }
	# InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
	foreach ($p in @(
		@('wrap','Wrap'), @('openButton','OpenButton'), @('listChoiceMode','ListChoiceMode'),
		@('extendedEditMultipleValues','ExtendedEditMultipleValues'), @('chooseType','ChooseType')
	)) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	if ($el.choiceButtonRepresentation) { X "$inner<ChoiceButtonRepresentation>$($el.choiceButtonRepresentation)</ChoiceButtonRepresentation>" }
	Emit-Layout -el $el -indent $inner -multiLineDefault ([bool]($el.multiLine -eq $true))

	if ($el.inputHint) {
		Emit-MLText -tag "InputHint" -text $el.inputHint -indent $inner
	}

	Emit-ChoiceList -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"

	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CheckBoxField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	# CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
	if ($null -ne $el.PSObject.Properties['checkBoxType']) {
		if ($el.checkBoxType) {
			$cbt = switch ("$($el.checkBoxType)".ToLower()) { 'auto' {'Auto'} 'checkbox' {'CheckBox'} 'switcher' {'Switcher'} 'tumbler' {'Tumbler'} default {"$($el.checkBoxType)"} }
			X "$inner<CheckBoxType>$cbt</CheckBoxType>"
		}
	} else { X "$inner<CheckBoxType>Auto</CheckBoxType>" }

	Emit-TitleLocation -el $el -indent $inner -smartDefault "Right"

	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "check"

	X "$indent</CheckBoxField>"
}

# Maps Russian/English root of a typed reference path to canonical English root.
# Used to normalize ChoiceList values like "Перечисление.X.Y" → "Enum.X.EnumValue.Y".
$script:refRootSynonyms = @{
	"Перечисление"            = "Enum"
	"Справочник"              = "Catalog"
	"Документ"                = "Document"
	"ПланСчетов"              = "ChartOfAccounts"
	"ПланВидовХарактеристик"  = "ChartOfCharacteristicTypes"
	"ПланВидовРасчета"        = "ChartOfCalculationTypes"
	"ПланВидовРасчёта"        = "ChartOfCalculationTypes"
	"ПланОбмена"              = "ExchangePlan"
	"БизнесПроцесс"           = "BusinessProcess"
	"Задача"                  = "Task"
	"РегистрСведений"         = "InformationRegister"
	"РегистрНакопления"       = "AccumulationRegister"
	"РегистрБухгалтерии"      = "AccountingRegister"
	"РегистрРасчета"          = "CalculationRegister"
	"РегистрРасчёта"          = "CalculationRegister"
	"ЖурналДокументов"        = "DocumentJournal"
	"КритерийОтбора"          = "FilterCriterion"
}
$script:enumValueSynonyms = @("EnumValue","ЗначениеПеречисления")

# Нормализация типа таблицы динсписка: "Справочник.Контрагенты" → "Catalog.Контрагенты".
# Прощающий ввод: принимаем рус-имя метаданных, переводим в платформенное. Уже англ — без изменений.
function Normalize-MetaTypeRef {
	param([string]$ref)
	if ([string]::IsNullOrEmpty($ref)) { return $ref }
	$dot = $ref.IndexOf('.')
	if ($dot -lt 1) { return $ref }
	$root = $ref.Substring(0, $dot)
	if ($script:refRootSynonyms.ContainsKey($root)) {
		return $script:refRootSynonyms[$root] + $ref.Substring($dot)
	}
	return $ref
}

# Normalize a choiceList item value: returns @{ XsiType = "..."; Text = "..." }
function Normalize-ChoiceValue {
	param($value)

	# Booleans
	if ($value -is [bool]) {
		return @{ XsiType = "xs:boolean"; Text = if ($value) { "true" } else { "false" } }
	}
	# Numbers (int / decimal / double)
	if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
		return @{ XsiType = "xs:decimal"; Text = "$value" }
	}

	$s = "$value"
	if ([string]::IsNullOrEmpty($s)) {
		return @{ XsiType = "xs:string"; Text = "" }
	}

	# Try to detect typed reference path: "<Root>.<Type>[.<Member>.<Value>]"
	$parts = $s -split '\.'
	if ($parts.Count -ge 2) {
		$root = $parts[0]
		$canonRoot = $null
		if ($script:refRootSynonyms.ContainsKey($root)) { $canonRoot = $script:refRootSynonyms[$root] }
		elseif ($script:refRootSynonyms.Values -contains $root) { $canonRoot = $root }

		if ($canonRoot) {
			$typeName = $parts[1]
			$normalized = $null

			if ($canonRoot -eq "Enum") {
				if ($parts.Count -eq 2) {
					# "Enum.X" alone — not a value, treat as string
				} elseif ($parts.Count -eq 3) {
					# "Enum.X.Y" — insert .EnumValue.
					$normalized = "Enum.$typeName.EnumValue.$($parts[2])"
				} else {
					# "Enum.X.<member>.Y..."  — replace member with EnumValue (handles ЗначениеПеречисления too)
					$member = $parts[2]
					if ($script:enumValueSynonyms -contains $member) {
						$rest = $parts[3..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					} else {
						$rest = $parts[2..($parts.Count-1)] -join '.'
						$normalized = "Enum.$typeName.EnumValue.$rest"
					}
				}
			} else {
				# Other ref roots: just translate root, keep tail as-is
				if ($parts.Count -ge 3) {
					$tail = $parts[1..($parts.Count-1)] -join '.'
					$normalized = "$canonRoot.$tail"
				}
			}

			if ($normalized) {
				return @{ XsiType = "xr:DesignTimeRef"; Text = $normalized }
			}
		}
	}

	return @{ XsiType = "xs:string"; Text = $s }
}

# Emit Presentation block for a choiceList item.
# Accepts string (ru only), or hashtable/PSCustomObject {ru, en, ...}.
# Empty/null → emits empty <Presentation/>.
function Emit-ChoicePresentation {
	param($pres, [string]$indent)
	if ($null -eq $pres -or ($pres -is [string] -and [string]::IsNullOrEmpty($pres))) {
		X "$indent<Presentation/>"
		return
	}

	$pairs = @()
	if ($pres -is [string]) {
		$pairs += ,@("ru", $pres)
	} elseif ($pres -is [hashtable] -or $pres -is [System.Collections.IDictionary]) {
		foreach ($k in $pres.Keys) { $pairs += ,@("$k", "$($pres[$k])") }
	} elseif ($pres.PSObject -and $pres.PSObject.Properties) {
		foreach ($p in $pres.PSObject.Properties) { $pairs += ,@("$($p.Name)", "$($p.Value)") }
	} else {
		$pairs += ,@("ru", "$pres")
	}

	X "$indent<Presentation>"
	foreach ($pair in $pairs) {
		X "$indent`t<v8:item>"
		X "$indent`t`t<v8:lang>$($pair[0])</v8:lang>"
		X "$indent`t`t<v8:content>$(Esc-Xml $pair[1])</v8:content>"
		X "$indent`t</v8:item>"
	}
	X "$indent</Presentation>"
}

# Emit <ChoiceList> (список выбора) — у RadioButtonField и InputField.
# Элемент: { value, presentation?/title? } (+ рус. синонимы значение/представление).
function Emit-ChoiceList {
	param($el, [string]$indent)
	if (-not $el.choiceList -or $el.choiceList.Count -eq 0) { return }
	X "$indent<ChoiceList>"
	$itemIndent = "$indent`t"
	foreach ($item in $el.choiceList) {
		# value (+ рус. синоним "значение")
		$valRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("value")) { $valRaw = $item["value"] }
			elseif ($item.Contains("значение")) { $valRaw = $item["значение"] }
		} else {
			if ($item.PSObject.Properties["value"])    { $valRaw = $item.value }
			elseif ($item.PSObject.Properties["значение"]) { $valRaw = $item."значение" }
		}

		# presentation (presentation OR title синоним)
		$presRaw = $null
		$hasPres = $false
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("presentation")) { $presRaw = $item["presentation"]; $hasPres = $true }
			elseif ($item.Contains("представление")) { $presRaw = $item["представление"]; $hasPres = $true }
			elseif ($item.Contains("title")) { $presRaw = $item["title"]; $hasPres = $true }
		} else {
			if ($item.PSObject.Properties["presentation"]) { $presRaw = $item.presentation; $hasPres = $true }
			elseif ($item.PSObject.Properties["представление"]) { $presRaw = $item."представление"; $hasPres = $true }
			elseif ($item.PSObject.Properties["title"]) { $presRaw = $item.title; $hasPres = $true }
		}

		$norm = Normalize-ChoiceValue -value $valRaw

		# авто-вывод presentation, если не задан
		if (-not $hasPres) {
			if ($norm.XsiType -eq "xr:DesignTimeRef") {
				$tail = ($norm.Text -split '\.')[-1]
				$presRaw = Title-FromName -name $tail
			} else {
				$presRaw = $norm.Text
			}
		}

		X "$itemIndent<xr:Item>"
		$valIndent = "$itemIndent`t"
		X "$valIndent<xr:Presentation/>"
		X "$valIndent<xr:CheckState>0</xr:CheckState>"
		X "$valIndent<xr:Value xsi:type=`"FormChoiceListDesTimeValue`">"
		Emit-ChoicePresentation -pres $presRaw -indent "$valIndent`t"
		X "$valIndent`t<Value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</Value>"
		X "$valIndent</xr:Value>"
		X "$itemIndent</xr:Item>"
	}
	X "$indent</ChoiceList>"
}

function Emit-Radio {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<RadioButtonField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	Emit-TitleLocation -el $el -indent $inner -smartDefault "None"

	# RadioButtonType: Auto | RadioButtons | Tumbler. Accept synonyms.
	$rbtRaw = if ($el.radioButtonType) { "$($el.radioButtonType)".Trim() } else { "Auto" }
	$rbt = switch -Regex ($rbtRaw.ToLower()) {
		'^(auto|авто)$'                        { "Auto"; break }
		'^(radiobuttons?|переключатель|радио)$' { "RadioButtons"; break }
		'^(tumbler|тумблер)$'                  { "Tumbler"; break }
		default                                { $rbtRaw }
	}
	X "$inner<RadioButtonType>$rbt</RadioButtonType>"

	if ($null -ne $el.columnsCount) {
		X "$inner<ColumnsCount>$($el.columnsCount)</ColumnsCount>"
	}

	Emit-ChoiceList -el $el -indent $inner

	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "radio"

	X "$indent</RadioButtonField>"
}

# Заголовок декорации (Label/Picture): formatted-aware <Title> через единую ML-text форму
# (reuse Resolve-MLFormatted, как у extendedTooltip). Атрибут formatted эмитится ВСЕГДА
# (специфика декораций). Sibling-ключ `formatted` — back-compat override авто-детекта.
function Emit-DecorationTitle {
	param($el, [string]$name, [string]$indent, [switch]$auto)
	$hasKey = $null -ne $el.PSObject.Properties['title']
	$titleVal = if ($hasKey) { $el.title } elseif ($auto -and $name) { Title-FromName -name $name } else { $null }
	if ($titleVal) {
		$r = Resolve-MLFormatted $titleVal
		$fmt = if ($null -ne $el.PSObject.Properties['formatted']) { [bool]$el.formatted } else { $r.formatted }
		X "$indent<Title formatted=`"$(if ($fmt) { 'true' } else { 'false' })`">"
		Emit-MLItems -val $r.text -indent "$indent`t"
		X "$indent</Title>"
	}
	if ($el.tooltip) { Emit-MLText -tag "ToolTip" -text $el.tooltip -indent $indent }
	if ($el.tooltipRepresentation) { X "$indent<ToolTipRepresentation>$($el.tooltipRepresentation)</ToolTipRepresentation>" }
}

function Emit-Label {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-DecorationTitle -el $el -name $name -indent $inner -auto

	Emit-CommonFlags -el $el -indent $inner

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"

	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	# ВНИМАНИЕ: у LabelField платформенный тег именно <Hiperlink> (опечатка 1С), не <Hyperlink>.
	if ($el.hyperlink -eq $true) { X "$inner<Hiperlink>true</Hiperlink>" }
	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "labelField"

	X "$indent</LabelField>"
}

# Блок свойств таблицы, привязанной к динамическому списку (Group A defaults + B/C).
# Платформа всегда эмитит этот блок на дин-список-таблице; компилятор зеркалит дефолты,
# DSL-ключ переопределяет; декомпилятор инвертирует (опускает значения = дефолту).
function Emit-DynListTableBlock {
	param($el, [string]$indent)
	# (useAlternationRowColor — общее свойство таблицы, эмитится в Emit-Table)
	# Group A (гарант. блок, n=5079): дефолт + override
	$ar = if ($el.autoRefresh -eq $true) { "true" } else { "false" }
	X "$indent<AutoRefresh>$ar</AutoRefresh>"
	$arp = if ($el.PSObject.Properties["autoRefreshPeriod"] -and $null -ne $el.autoRefreshPeriod) { $el.autoRefreshPeriod } else { 60 }
	X "$indent<AutoRefreshPeriod>$arp</AutoRefreshPeriod>"
	X "$indent<Period>"
	X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
	X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
	X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
	X "$indent</Period>"
	$cfi = if ($el.choiceFoldersAndItems) { $el.choiceFoldersAndItems } else { "Items" }
	X "$indent<ChoiceFoldersAndItems>$cfi</ChoiceFoldersAndItems>"
	$rcr = if ($el.restoreCurrentRow -eq $true) { "true" } else { "false" }
	X "$indent<RestoreCurrentRow>$rcr</RestoreCurrentRow>"
	X "$indent<TopLevelParent xsi:nil=`"true`"/>"
	$sr = if ($el.showRoot -eq $false) { "false" } else { "true" }
	X "$indent<ShowRoot>$sr</ShowRoot>"
	$arc = if ($el.allowRootChoice -eq $true) { "true" } else { "false" }
	X "$indent<AllowRootChoice>$arc</AllowRootChoice>"
	$uodc = if ($el.updateOnDataChange) { $el.updateOnDataChange } else { "Auto" }
	X "$indent<UpdateOnDataChange>$uodc</UpdateOnDataChange>"
	if ($el.userSettingsGroup) { X "$indent<UserSettingsGroup>$($el.userSettingsGroup)</UserSettingsGroup>" }
	$agcru = if ($el.allowGettingCurrentRowURL -eq $false) { "false" } else { "true" }
	X "$indent<AllowGettingCurrentRowURL>$agcru</AllowGettingCurrentRowURL>"
}

function Emit-Table {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Table name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	# ChangeRowSet/Order — эмитим явное значение (в т.ч. false: платформа пишет его на ValueTable)
	if ($el.PSObject.Properties['changeRowSet'] -and $null -ne $el.changeRowSet) {
		X "$inner<ChangeRowSet>$(if ($el.changeRowSet -eq $true){'true'}else{'false'})</ChangeRowSet>"
	}
	if ($el.PSObject.Properties['changeRowOrder'] -and $null -ne $el.changeRowOrder) {
		X "$inner<ChangeRowOrder>$(if ($el.changeRowOrder -eq $true){'true'}else{'false'})</ChangeRowOrder>"
	}
	if ($el.autoInsertNewRow -eq $true) { X "$inner<AutoInsertNewRow>true</AutoInsertNewRow>" }
	# RowFilter — nil-плейсхолдер (всегда пустой); ключ присутствует → эмитим
	if ($el.PSObject.Properties['rowFilter']) { X "$inner<RowFilter xsi:nil=`"true`"/>" }
	if ($el.height) { X "$inner<HeightInTableRows>$($el.height)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }

	if ($el.commandBarLocation) {
		X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>"
	}
	if ($el.searchStringLocation) {
		X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>"
	}
	if ($el.choiceMode -eq $true) { X "$inner<ChoiceMode>true</ChoiceMode>" }
	if ($el.useAlternationRowColor -eq $true) { X "$inner<UseAlternationRowColor>true</UseAlternationRowColor>" }
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($el.rowSelectionMode) { X "$inner<RowSelectionMode>$($el.rowSelectionMode)</RowSelectionMode>" }
	if ($el.verticalLines -eq $false) { X "$inner<VerticalLines>false</VerticalLines>" }
	if ($el.horizontalLines -eq $false) { X "$inner<HorizontalLines>false</HorizontalLines>" }
	if ($el.initialTreeView) { X "$inner<InitialTreeView>$($el.initialTreeView)</InitialTreeView>" }
	if ($el.enableDrag -eq $true) { X "$inner<EnableDrag>true</EnableDrag>" }
	if ($el.rowPictureDataPath) { X "$inner<RowPictureDataPath>$($el.rowPictureDataPath)</RowPictureDataPath>" }
	if ($el.rowsPicture) {
		X "$inner<RowsPicture>"
		X "$inner`t<xr:Ref>$($el.rowsPicture)</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>false</xr:LoadTransparent>"
		X "$inner</RowsPicture>"
	}
	# Блок свойств дин-список-таблицы (помечена эвристикой 11b.4)
	if ($el.PSObject.Properties["_dynList"] -and $el._dynList) { Emit-DynListTableBlock -el $el -indent $inner }
	if ($el.viewStatusLocation) { X "$inner<ViewStatusLocation>$($el.viewStatusLocation)</ViewStatusLocation>" }
	if ($el.searchControlLocation) { X "$inner<SearchControlLocation>$($el.searchControlLocation)</SearchControlLocation>" }
	Emit-Layout -el $el -indent $inner -skipHeight

	if ($el.excludedCommands -and $el.excludedCommands.Count -gt 0) {
		X "$inner<CommandSet>"
		foreach ($cmd in $el.excludedCommands) { X "$inner`t<ExcludedCommand>$cmd</ExcludedCommand>" }
		X "$inner</CommandSet>"
	}

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	# AutoCommandBar: приоритет commandBar-свойства (контент); иначе tableAutofill-shorthand; иначе пусто.
	if ($null -ne $el.commandBar) {
		Emit-CompanionPanel -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner -panel $el.commandBar
	} elseif ($null -ne $el.tableAutofill) {
		$acbId = New-Id
		X "$inner<AutoCommandBar name=`"${name}КоманднаяПанель`" id=`"$acbId`">"
		$afVal = if ($el.tableAutofill) { "true" } else { "false" }
		X "$inner`t<Autofill>$afVal</Autofill>"
		X "$inner</AutoCommandBar>"
	} else {
		Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	}
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	Emit-TableAddition -tag "SearchStringAddition" -tableName $name -nameSuffix "СтрокаПоиска" -srcType "SearchStringRepresentation" -indent $inner
	Emit-TableAddition -tag "ViewStatusAddition" -tableName $name -nameSuffix "СостояниеПросмотра" -srcType "ViewStatusRepresentation" -indent $inner
	Emit-TableAddition -tag "SearchControlAddition" -tableName $name -nameSuffix "УправлениеПоиском" -srcType "SearchControl" -indent $inner

	# Columns
	if ($el.columns -and $el.columns.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($col in $el.columns) {
			Emit-Element -el $col -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "table"

	X "$indent</Table>"
}

function Emit-Pages {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Pages name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.pagesRepresentation) {
		X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>"
	}

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "pages"

	# Children (pages)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Pages>"
}

function Emit-Page {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Page name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.group) {
		$orientation = switch ("$($el.group)") {
			"horizontal"       { "Horizontal" }
			"vertical"         { "Vertical" }
			"alwaysHorizontal" { "AlwaysHorizontal" }
			"alwaysVertical"   { "AlwaysVertical" }
			default            { $null }
		}
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
	}
	Emit-Layout -el $el -indent $inner

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Page>"
}

function Emit-Button {
	param($el, [string]$name, [int]$id, [string]$indent, [bool]$inCmdBar = $false)

	X "$indent<Button name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	# (общие свойства — через Emit-Layout ниже; отдельный вызов был бы двойной эмиссией)

	# Type — context-aware:
	# Inside command bar (cmdBar/autoCmdBar/popup) only CommandBarButton/CommandBarHyperlink are valid.
	# UsualButton/Hyperlink would be silently ignored by 1C.
	$btnType = $null
	if ($el.type) {
		$rawType = "$($el.type)"
		if ($inCmdBar) {
			# Be forgiving: any "ordinary button" hint resolves to CommandBarButton,
			# any "hyperlink" hint resolves to CommandBarHyperlink. The model can pass
			# either DSL ("usual"/"hyperlink") or XML names — all map to the right kind.
			switch ($rawType) {
				"usual"                { $btnType = "CommandBarButton" }
				"UsualButton"          { $btnType = "CommandBarButton" }
				"commandBar"           { $btnType = "CommandBarButton" }
				"CommandBarButton"     { $btnType = "CommandBarButton" }
				"hyperlink"            { $btnType = "CommandBarHyperlink" }
				"Hyperlink"            { $btnType = "CommandBarHyperlink" }
				"CommandBarHyperlink"  { $btnType = "CommandBarHyperlink" }
				default                { $btnType = $rawType }
			}
		} else {
			# Symmetric: any "ordinary button" hint → UsualButton, any "hyperlink" → Hyperlink.
			switch ($rawType) {
				"usual"                { $btnType = "UsualButton" }
				"UsualButton"          { $btnType = "UsualButton" }
				"commandBar"           { $btnType = "UsualButton" }
				"CommandBarButton"     { $btnType = "UsualButton" }
				"hyperlink"            { $btnType = "Hyperlink" }
				"Hyperlink"            { $btnType = "Hyperlink" }
				"CommandBarHyperlink"  { $btnType = "Hyperlink" }
				default                { $btnType = $rawType }
			}
		}
	} elseif ($inCmdBar) {
		$btnType = "CommandBarButton"
	}
	if ($btnType) {
		X "$inner<Type>$btnType</Type>"
	}

	# CommandName
	if ($el.command) {
		X "$inner<CommandName>Form.Command.$($el.command)</CommandName>"
	}
	# commandName — глобальная команда «как есть» (CommonCommand.X, Catalog.X.Command.Y …), без обёртки Form.
	if ($el.commandName -and -not $el.command) {
		X "$inner<CommandName>$($el.commandName)</CommandName>"
	}
	if ($el.stdCommand) {
		$sc = "$($el.stdCommand)"
		if ($sc -match '^(.+)\.(.+)$') {
			X "$inner<CommandName>Form.Item.$($Matches[1]).StandardCommand.$($Matches[2])</CommandName>"
		} else {
			X "$inner<CommandName>Form.StandardCommand.$sc</CommandName>"
		}
	}

	$btnAuto = -not ($el.command -or $el.commandName -or $el.stdCommand)
	Emit-Title -el $el -name $name -indent $inner -auto:$btnAuto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.defaultButton -eq $true) { X "$inner<DefaultButton>true</DefaultButton>" }

	# Picture
	if ($el.picture) {
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
		X "$inner</Picture>"
	}

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	if ($el.locationInCommandBar) {
		X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>"
	}
	Emit-Layout -el $el -indent $inner

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"

	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-DecorationTitle -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.picture -or $el.src) {
		$ref = if ($el.src) { "$($el.src)" } else { "$($el.picture)" }
		$lt = if ($el.loadTransparent -eq $true) { "true" } else { "false" }
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$ref</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>$lt</xr:LoadTransparent>"
		X "$inner</Picture>"
	}

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picture"

	X "$indent</PictureDecoration>"
}

function Emit-PictureField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }

	# ValuesPicture — picture (collection) used to render the field's value.
	# Required for a Boolean-bound PictureField to actually show an icon.
	# loadTransparent emitted only when true (1С default is false).
	if ($el.valuesPicture) {
		X "$inner<ValuesPicture>"
		X "$inner`t<xr:Ref>$($el.valuesPicture)</xr:Ref>"
		if ($el.loadTransparent) { X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>" }
		X "$inner</ValuesPicture>"
	}

	Emit-Layout -el $el -indent $inner

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"

	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CalendarField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		$loc = switch ("$($el.titleLocation)") {
			"none"   { "None" }
			"left"   { "Left" }
			"right"  { "Right" }
			"top"    { "Top" }
			"bottom" { "Bottom" }
			"auto"   { "Auto" }
			default  { "$($el.titleLocation)" }
		}
		X "$inner<TitleLocation>$loc</TitleLocation>"
	}

	Emit-Layout -el $el -indent $inner

	# Календарно-специфичные свойства (порядок схемы: после layout, до companions)
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($null -ne $el.showCurrentDate) { $v = if ($el.showCurrentDate) { "true" } else { "false" }; X "$inner<ShowCurrentDate>$v</ShowCurrentDate>" }
	if ($null -ne $el.widthInMonths) { X "$inner<WidthInMonths>$($el.widthInMonths)</WidthInMonths>" }
	if ($null -ne $el.heightInMonths) { X "$inner<HeightInMonths>$($el.heightInMonths)</HeightInMonths>" }
	if ($null -ne $el.showMonthsPanel) { $v = if ($el.showMonthsPanel) { "true" } else { "false" }; X "$inner<ShowMonthsPanel>$v</ShowMonthsPanel>" }

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"

	X "$indent</CalendarField>"
}

function Emit-CommandBar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CommandBar name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</CommandBar>"
}

function Emit-ButtonGroup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<ButtonGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children (кнопки в контексте командной панели)
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</ButtonGroup>"
}

function Emit-Popup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Popup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.picture) {
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
		X "$inner</Picture>"
	}

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	Emit-Layout -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t" -inCmdBar $true
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Popup>"
}

# --- 8. Attribute emitter ---

# <FunctionalOptions><Item>FunctionalOption.X</Item>…</FunctionalOptions> — у Attribute/Command/Column.
# DSL: массив строк. Forgiving: "X" / "FunctionalOption.X" → FunctionalOption.X; GUID (расширение) — как есть.
function Emit-FunctionalOptions {
	param($fo, [string]$indent)
	if (-not $fo -or @($fo).Count -eq 0) { return }
	X "$indent<FunctionalOptions>"
	foreach ($opt in @($fo)) {
		$v = "$opt"
		if ($v -match '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$') { }          # GUID — как есть
		elseif ($v -match '^FunctionalOption\.') { }                     # уже с префиксом
		else { $v = "FunctionalOption.$v" }
		X "$indent`t<Item>$v</Item>"
	}
	X "$indent</FunctionalOptions>"
}

# Колонка реквизита (ValueTable/Tree или AdditionalColumns): name/Title/Type/FunctionalOptions.
function Emit-AttrColumn {
	param($col, [string]$indent)
	$colId = New-Id
	X "$indent<Column name=`"$($col.name)`" id=`"$colId`">"
	if ($col.title) { Emit-MLText -tag "Title" -text $col.title -indent "$indent`t" }
	Emit-Type -typeStr "$($col.type)" -indent "$indent`t"
	Emit-FunctionalOptions -fo $col.functionalOptions -indent "$indent`t"
	X "$indent</Column>"
}

function Emit-Attributes {
	param($attrs, [string]$indent)

	if (-not $attrs -or $attrs.Count -eq 0) { return }

	X "$indent<Attributes>"
	foreach ($attr in $attrs) {
		$attrId = New-Id
		$attrName = "$($attr.name)"

		X "$indent`t<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$indent`t`t"

		$attrTitle = if ($attr.title) { $attr.title } elseif ($attr.main -ne $true) { Title-FromName -name $attrName } else { '' }
		if ($attrTitle) {
			Emit-MLText -tag "Title" -text $attrTitle -indent $inner
		}

		# Type
		if ($attr.type) {
			Emit-Type -typeStr "$($attr.type)" -indent $inner
		} else {
			X "$inner<Type/>"
		}

		if ($attr.main -eq $true) {
			X "$inner<MainAttribute>true</MainAttribute>"
		}
		# Доступ по ролям: просмотр/редактирование (порядок схемы: View → Edit, после MainAttribute)
		if ($null -ne $attr.view) { Emit-XrFlag -tag 'View' -val $attr.view -indent $inner }
		if ($null -ne $attr.edit) { Emit-XrFlag -tag 'Edit' -val $attr.edit -indent $inner }
		$mainSaved = $false
		if ($attr.main -eq $true -and $attr.type) {
			$mainSaved = ("$($attr.type)") -match '^(CatalogObject|DocumentObject|ChartOfAccountsObject|ChartOfCalculationTypesObject|ChartOfCharacteristicTypesObject|ExchangePlanObject|BusinessProcessObject|TaskObject)\.' -or ("$($attr.type)") -match 'RecordManager\.'
		}
		if ($attr.savedData -eq $true -or $mainSaved) {
			X "$inner<SavedData>true</SavedData>"
		}
		if ($attr.fillChecking) {
			X "$inner<FillChecking>$($attr.fillChecking)</FillChecking>"
		}

		# UseAlways: поля, всегда читаемые (дин-список/таблица). Две формы DSL сливаются:
		#  attr.useAlways[] (короткие имена) + columns с useAlways:true → <Field>ИмяРеквизита.Поле</Field>.
		$uaFields = New-Object System.Collections.ArrayList
		if ($attr.useAlways) {
			foreach ($e in @($attr.useAlways)) {
				$fld = "$e"
				if ($fld -notmatch "^$([regex]::Escape($attrName))\.") { $fld = "$attrName.$fld" }
				if (-not $uaFields.Contains($fld)) { [void]$uaFields.Add($fld) }
			}
		}
		if ($attr.columns) {
			foreach ($col in $attr.columns) {
				if ($col.useAlways -eq $true) {
					$fld = "$attrName.$($col.name)"
					if (-not $uaFields.Contains($fld)) { [void]$uaFields.Add($fld) }
				}
			}
		}
		if ($uaFields.Count -gt 0) {
			X "$inner<UseAlways>"
			foreach ($f in $uaFields) { X "$inner`t<Field>$f</Field>" }
			X "$inner</UseAlways>"
		}

		Emit-FunctionalOptions -fo $attr.functionalOptions -indent $inner

		# Columns: прямые <Column> (ValueTable/Tree) + <AdditionalColumns table="X"> (доп. колонки
		# табличных частей объекта). Порядок схемы: прямые сначала, затем AdditionalColumns-группы.
		# Для дин-списка (есть settings) прямые колонки НЕ эмитим (служат лишь для UseAlways).
		$hasDirectCols = $attr.columns -and $attr.columns.Count -gt 0 -and -not $attr.settings
		$hasAddCols = $attr.additionalColumns -and @($attr.additionalColumns).Count -gt 0
		if ($hasDirectCols -or $hasAddCols) {
			X "$inner<Columns>"
			if ($hasDirectCols) {
				foreach ($col in $attr.columns) { Emit-AttrColumn -col $col -indent "$inner`t" }
			}
			if ($hasAddCols) {
				foreach ($ac in @($attr.additionalColumns)) {
					X "$inner`t<AdditionalColumns table=`"$($ac.table)`">"
					foreach ($col in @($ac.columns)) { Emit-AttrColumn -col $col -indent "$inner`t`t" }
					X "$inner`t</AdditionalColumns>"
				}
			}
			X "$inner</Columns>"
		}

		# Settings (динамический список)
		if ($attr.settings) {
			$st = $attr.settings
			X "$inner<Settings xsi:type=`"DynamicList`">"
			$si = "$inner`t"
			# Порядок платформы: ManualQuery, DynamicDataRead, QueryText, Field*, MainTable, ListSettings
			$hasQuery = $st.query -and "$($st.query)".Trim()
			$mq = if ($hasQuery -or $st.manualQuery -eq $true) { "true" } else { "false" }
			X "$si<ManualQuery>$mq</ManualQuery>"
			# DynamicDataRead: дефолт true; false только при явном отключении
			$ddr = if ($st.dynamicDataRead -eq $false) { "false" } else { "true" }
			X "$si<DynamicDataRead>$ddr</DynamicDataRead>"
			if ($hasQuery) {
				$qtext = Resolve-QueryValue "$($st.query)" $script:queryBaseDir
				X "$si<QueryText>$(Esc-Xml $qtext)</QueryText>"
			}
			# Явные поля набора (редко): override title/dataPath
			if ($st.fields) {
				foreach ($fld in $st.fields) {
					X "$si<Field xsi:type=`"dcssch:DataSetFieldField`">"
					$dp = if ($fld.dataPath) { $fld.dataPath } else { $fld.field }
					X "$si`t<dcssch:dataPath>$(Esc-Xml "$dp")</dcssch:dataPath>"
					X "$si`t<dcssch:field>$(Esc-Xml "$($fld.field)")</dcssch:field>"
					if ($fld.title) {
						X "$si`t<dcssch:title xsi:type=`"v8:LocalStringType`">"
						Emit-MLItems -val $fld.title -indent "$si`t`t"
						X "$si`t</dcssch:title>"
					}
					X "$si</Field>"
				}
			}
			if ($st.mainTable) { X "$si<MainTable>$(Normalize-MetaTypeRef "$($st.mainTable)")</MainTable>" }
			# ListSettings: filter/order/conditionalAppearance (skd-грамматика) + каноничные блок-GUID.
			# Нет items → контейнеры всё равно эмитятся (blockMeta) = каноничный пустой скелет платформы.
			$lsi = "$si`t"
			X "$si<ListSettings>"
			Emit-Filter -items $st.filter -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_FILTER_ID
			Emit-Order -items $st.order -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_ORDER_ID
			Emit-ConditionalAppearance -items $st.conditionalAppearance -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_CA_ID
			X "$lsi<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>"
			X "$lsi<dcsset:itemsUserSettingID>$($script:CANON_ITEMS_ID)</dcsset:itemsUserSettingID>"
			X "$si</ListSettings>"
			X "$inner</Settings>"
		}

		X "$indent`t</Attribute>"
	}
	X "$indent</Attributes>"
}

# --- 9. Parameter emitter ---

function Emit-Parameters {
	param($params, [string]$indent)

	if (-not $params -or $params.Count -eq 0) { return }

	X "$indent<Parameters>"
	foreach ($param in $params) {
		X "$indent`t<Parameter name=`"$($param.name)`">"
		$inner = "$indent`t`t"

		Emit-Type -typeStr "$($param.type)" -indent $inner

		if ($param.key -eq $true) {
			X "$inner<KeyParameter>true</KeyParameter>"
		}

		X "$indent`t</Parameter>"
	}
	X "$indent</Parameters>"
}

# --- 10. Command emitter ---

function Emit-Commands {
	param($cmds, [string]$indent)

	if (-not $cmds -or $cmds.Count -eq 0) { return }

	X "$indent<Commands>"
	foreach ($cmd in $cmds) {
		$cmdId = New-Id
		X "$indent`t<Command name=`"$($cmd.name)`" id=`"$cmdId`">"
		$inner = "$indent`t`t"

		$cmdTitle = if ($cmd.title) { $cmd.title } else { Title-FromName -name "$($cmd.name)" }
		if ($cmdTitle) {
			Emit-MLText -tag "Title" -text $cmdTitle -indent $inner
		}

		if ($cmd.tooltip) {
			Emit-MLText -tag "ToolTip" -text $cmd.tooltip -indent $inner
		}

		# Доступность команды по ролям (после ToolTip, до Action)
		if ($null -ne $cmd.use) { Emit-XrFlag -tag 'Use' -val $cmd.use -indent $inner }

		if ($cmd.action) {
			X "$inner<Action>$($cmd.action)</Action>"
		}

		Emit-FunctionalOptions -fo $cmd.functionalOptions -indent $inner

		if ($cmd.currentRowUse) {
			X "$inner<CurrentRowUse>$($cmd.currentRowUse)</CurrentRowUse>"
		}

		if ($cmd.shortcut) {
			X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>"
		}

		if ($cmd.picture) {
			X "$inner<Picture>"
			X "$inner`t<xr:Ref>$($cmd.picture)</xr:Ref>"
			X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
			X "$inner</Picture>"
		}

		if ($cmd.representation) {
			X "$inner<Representation>$($cmd.representation)</Representation>"
		}

		X "$indent`t</Command>"
	}
	X "$indent</Commands>"
}

# --- 11. Properties emitter ---

function Emit-Properties {
	param($props, [string]$indent)

	if (-not $props) { return }

	# camelCase -> PascalCase mapping for known properties
	$propMap = @{
		"autoTitle"              = "AutoTitle"
		"windowOpeningMode"      = "WindowOpeningMode"
		"commandBarLocation"     = "CommandBarLocation"
		"saveDataInSettings"     = "SaveDataInSettings"
		"autoSaveDataInSettings" = "AutoSaveDataInSettings"
		"autoTime"               = "AutoTime"
		"usePostingMode"         = "UsePostingMode"
		"repostOnWrite"          = "RepostOnWrite"
		"autoURL"                = "AutoURL"
		"autoFillCheck"          = "AutoFillCheck"
		"customizable"           = "Customizable"
		"enterKeyBehavior"       = "EnterKeyBehavior"
		"verticalScroll"         = "VerticalScroll"
		"scalingMode"            = "ScalingMode"
		"useForFoldersAndItems"  = "UseForFoldersAndItems"
		"reportResult"           = "ReportResult"
		"detailsData"            = "DetailsData"
		"reportFormType"         = "ReportFormType"
		"autoShowState"          = "AutoShowState"
		"width"                  = "Width"
		"height"                 = "Height"
		"group"                  = "Group"
	}

	foreach ($p in $props.PSObject.Properties) {
		$xmlName = if ($propMap.ContainsKey($p.Name)) { $propMap[$p.Name] } else {
			# Auto PascalCase: first letter uppercase
			$p.Name.Substring(0,1).ToUpper() + $p.Name.Substring(1)
		}
		# Convert boolean to lowercase string (PS renders as True/False)
		$val = $p.Value
		if ($val -is [bool]) {
			$val = if ($val) { "true" } else { "false" }
		}
		X "$indent<$xmlName>$val</$xmlName>"
	}
}

# --- 11b. Pre-pass: synonyms, main attribute inference, heuristics, autoCmdBar extraction ---

# Companion-панели как СВОЙСТВА элемента (значение объект/массив): любой знакомый
# синоним → каноника commandBar / contextMenu. Разводим с одноимёнными ТИПАМИ-элементами
# по типу значения: строка = элемент-тип (имя), объект/массив = панель-свойство.
function Normalize-PanelSynonyms {
	param($el)
	if ($null -eq $el) { return }
	$panelSyns = @{
		'commandBar' = @('commandBar','autoCommandBar','AutoCommandBar','autoCmdBar','cmdBar','КоманднаяПанель')
		'contextMenu' = @('contextMenu','ContextMenu','КонтекстноеМеню')
	}
	foreach ($canon in $panelSyns.Keys) {
		foreach ($syn in $panelSyns[$canon]) {
			$p = $el.PSObject.Properties[$syn]
			if ($null -ne $p -and ($p.Value -is [array] -or $p.Value -is [System.Management.Automation.PSCustomObject])) {
				if ($syn -ne $canon -and $null -eq $el.PSObject.Properties[$canon]) {
					$v = $p.Value
					$el.PSObject.Properties.Remove($syn) | Out-Null
					$el | Add-Member -NotePropertyName $canon -NotePropertyValue $v -Force
				}
				break
			}
		}
	}
}

function Normalize-ElementSynonyms {
	param($el)
	if ($null -eq $el) { return }
	Normalize-PanelSynonyms $el
	# Тип-синонимы (commandBar/autoCommandBar → элемент-тип) применяем ТОЛЬКО к строковому
	# значению (имя элемента); объект/массив уже отнесён к панель-свойству выше.
	$typeSyn = @{ "commandBar" = "cmdBar"; "autoCommandBar" = "autoCmdBar" }
	foreach ($pair in $typeSyn.GetEnumerator()) {
		$src = $el.PSObject.Properties[$pair.Key]
		if ($null -ne $src -and ($src.Value -is [string]) -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}
	if ($el.PSObject.Properties["extTooltip"] -and $null -eq $el.PSObject.Properties["extendedTooltip"]) {
		$val = $el.extTooltip
		$el.PSObject.Properties.Remove("extTooltip") | Out-Null
		$el | Add-Member -NotePropertyName "extendedTooltip" -NotePropertyValue $val -Force
	}
	# Рекурсия в детей панелей (commandBar/contextMenu) — нормализуем кнопки/группы внутри
	foreach ($pk in @('commandBar','contextMenu')) {
		$pp = $el.PSObject.Properties[$pk]
		if ($null -ne $pp) {
			$kids = if ($pp.Value -is [array]) { $pp.Value } elseif ($null -ne $pp.Value) { $pp.Value.children } else { $null }
			if ($kids) { foreach ($child in $kids) { Normalize-ElementSynonyms $child } }
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { Normalize-ElementSynonyms $child }
	}
	if ($el.PSObject.Properties["columns"] -and $el.columns) {
		foreach ($child in $el.columns) { Normalize-ElementSynonyms $child }
	}
}

function HasCmdBarRecursive {
	param($el)
	if ($null -eq $el) { return $false }
	if ($el.PSObject.Properties["cmdBar"] -and $null -ne $el.cmdBar) { return $true }
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { if (HasCmdBarRecursive $child) { return $true } }
	}
	if ($el.PSObject.Properties["columns"] -and $el.columns) {
		foreach ($child in $el.columns) { if (HasCmdBarRecursive $child) { return $true } }
	}
	return $false
}

function ApplyDynamicListTableHeuristic {
	param($el, [string]$listName, [bool]$hasMainTable)
	if ($null -eq $el) { return }
	if ($el.PSObject.Properties["table"] -and $null -ne $el.table -and "$($el.path)" -eq $listName) {
		# Маркер дин-список-таблицы → Emit-Table эмитит блок свойств (Group A defaults)
		$el | Add-Member -NotePropertyName "_dynList" -NotePropertyValue $true -Force
		if ($null -eq $el.PSObject.Properties["tableAutofill"]) {
			$el | Add-Member -NotePropertyName "tableAutofill" -NotePropertyValue $false -Force
		}
		if ($null -eq $el.PSObject.Properties["commandBarLocation"]) {
			$el | Add-Member -NotePropertyName "commandBarLocation" -NotePropertyValue "None" -Force
		}
		# RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ
		# и есть основная таблица. Пустая строка (suppress-маркер) НЕ перезатирается.
		if ($hasMainTable -and ($null -eq $el.PSObject.Properties["rowPictureDataPath"])) {
			$el | Add-Member -NotePropertyName "rowPictureDataPath" -NotePropertyValue "$listName.DefaultPicture" -Force
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { ApplyDynamicListTableHeuristic $child $listName $hasMainTable }
	}
}

function Test-IsObjectLikeType {
	param([string]$type)
	if ([string]::IsNullOrEmpty($type)) { return $false }
	if ($type -eq "DynamicList" -or $type -eq "ConstantsSet") { return $true }
	$objectSuffixes = @(
		"CatalogObject", "DocumentObject", "DataProcessorObject", "ReportObject",
		"ExternalDataProcessorObject", "ExternalReportObject", "BusinessProcessObject",
		"TaskObject", "ChartOfAccountsObject", "ChartOfCharacteristicTypesObject",
		"ChartOfCalculationTypesObject", "ExchangePlanObject"
	)
	$recordSetPrefixes = @(
		"InformationRegisterRecordSet", "AccumulationRegisterRecordSet",
		"AccountingRegisterRecordSet", "CalculationRegisterRecordSet",
		"InformationRegisterRecordManager"
	)
	foreach ($suffix in $objectSuffixes) {
		if ($type -like "$suffix.*") { return $true }
	}
	foreach ($prefix in $recordSetPrefixes) {
		if ($type -like "$prefix.*") { return $true }
	}
	return $false
}

# 11b.1: Normalize synonyms recursively
if ($def.elements) {
	foreach ($el in $def.elements) { Normalize-ElementSynonyms $el }
}

# 11b.2: Extract autoCmdBar element from def.elements
$script:mainAcbDef = $null
if ($def.elements) {
	$autoBars = @()
	$rest = @()
	foreach ($el in $def.elements) {
		if ($null -ne $el.PSObject.Properties["autoCmdBar"] -and $null -ne $el.autoCmdBar) {
			$autoBars += $el
		} else {
			$rest += $el
		}
	}
	if ($autoBars.Count -gt 1) {
		Write-Error "form-compile: more than one autoCmdBar in def.elements (found $($autoBars.Count)); only one allowed."
		exit 1
	}
	if ($autoBars.Count -eq 1) {
		$script:mainAcbDef = $autoBars[0]
		# Replace def.elements with the filtered list
		$def.PSObject.Properties.Remove("elements") | Out-Null
		$def | Add-Member -NotePropertyName "elements" -NotePropertyValue $rest -Force
	}
}

# 11b.3: Infer main attribute (only if no attribute has main:true)
if ($def.attributes) {
	$hasExplicitMain = $false
	foreach ($attr in $def.attributes) {
		if ($attr.main -eq $true) { $hasExplicitMain = $true; break }
	}
	if (-not $hasExplicitMain) {
		$candidates = @()
		foreach ($attr in $def.attributes) {
			# Skip if user explicitly opted out via main:false
			if ($null -ne $attr.PSObject.Properties["main"] -and $attr.main -eq $false) { continue }
			if (Test-IsObjectLikeType "$($attr.type)") {
				$candidates += $attr
			}
		}
		if ($candidates.Count -eq 1) {
			$candidates[0] | Add-Member -NotePropertyName "main" -NotePropertyValue $true -Force
			Write-Host "[INFO] Inferred main attribute: $($candidates[0].name) ($($candidates[0].type))"
		} elseif ($candidates.Count -gt 1) {
			$names = ($candidates | ForEach-Object { $_.name }) -join ", "
			Write-Host "[WARN] Multiple main-attribute candidates: $names; specify ""main"": true explicitly"
		}
	}
}

# 11b.4: DynamicList → table heuristic (для ВСЕХ DynamicList-реквизитов, не только main)
if ($def.attributes -and $def.elements) {
	foreach ($attr in $def.attributes) {
		if ("$($attr.type)" -ne "DynamicList") { continue }
		$mt = $null
		if ($attr.PSObject.Properties["settings"] -and $null -ne $attr.settings) {
			if ($attr.settings -is [hashtable]) {
				if ($attr.settings.ContainsKey("mainTable")) { $mt = $attr.settings["mainTable"] }
			} elseif ($attr.settings.PSObject.Properties["mainTable"]) {
				$mt = $attr.settings.mainTable
			}
		}
		$hasMt = -not [string]::IsNullOrEmpty("$mt")
		foreach ($el in $def.elements) {
			ApplyDynamicListTableHeuristic $el $attr.name $hasMt
		}
	}
}

# 11b.5: Compute main AutoCommandBar Autofill via heuristic B3
function Compute-MainAcbAutofill {
	if ($script:mainAcbDef) {
		if ($null -ne $script:mainAcbDef.PSObject.Properties["autofill"]) {
			return [bool]$script:mainAcbDef.autofill
		}
		return $true
	}
	if ($def.elements) {
		foreach ($el in $def.elements) {
			if (HasCmdBarRecursive $el) { return $false }
		}
	}
	return $true
}

# --- 12. Main compilation ---

# Title
if ($def.title) {
	Emit-MLText -tag "Title" -text $def.title -indent "`t"
}

# Header
X '<?xml version="1.0" encoding="UTF-8"?>'
X "<Form xmlns=`"http://v8.1c.ru/8.3/xcf/logform`" xmlns:app=`"http://v8.1c.ru/8.2/managed-application/core`" xmlns:cfg=`"http://v8.1c.ru/8.1/data/enterprise/current-config`" xmlns:dcscor=`"http://v8.1c.ru/8.1/data-composition-system/core`" xmlns:dcssch=`"http://v8.1c.ru/8.1/data-composition-system/schema`" xmlns:dcsset=`"http://v8.1c.ru/8.1/data-composition-system/settings`" xmlns:ent=`"http://v8.1c.ru/8.1/data/enterprise`" xmlns:lf=`"http://v8.1c.ru/8.2/managed-application/logform`" xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" version=`"$($script:formatVersion)`">"

# Oops — Title was emitted before header. Need to fix the order.
# Actually, let me restructure: build the body into a separate buffer, then assemble

# Reset and rebuild properly
$script:xml = New-Object System.Text.StringBuilder 8192
$script:nextId = 1

X '<?xml version="1.0" encoding="UTF-8"?>'
X "<Form xmlns=`"http://v8.1c.ru/8.3/xcf/logform`" xmlns:app=`"http://v8.1c.ru/8.2/managed-application/core`" xmlns:cfg=`"http://v8.1c.ru/8.1/data/enterprise/current-config`" xmlns:dcscor=`"http://v8.1c.ru/8.1/data-composition-system/core`" xmlns:dcssch=`"http://v8.1c.ru/8.1/data-composition-system/schema`" xmlns:dcsset=`"http://v8.1c.ru/8.1/data-composition-system/settings`" xmlns:ent=`"http://v8.1c.ru/8.1/data/enterprise`" xmlns:lf=`"http://v8.1c.ru/8.2/managed-application/logform`" xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" version=`"$($script:formatVersion)`">"

# 12a. Title (from def.title or properties.title — must be multilingual XML)
$formTitle = $def.title
if (-not $formTitle -and $def.properties -and $def.properties.title) {
	$formTitle = $def.properties.title
}
if ($formTitle) {
	Emit-MLText -tag "Title" -text $formTitle -indent "`t"
}

# 12b. Properties (skip 'title' — handled above as multilingual)
# When form-level Title is set, default autoTitle=false (≈95% of ERP forms do this;
# otherwise platform appends synonym → "Title: Synonym" double-titles).
$propsClone = New-Object PSObject
$hasAutoTitle = $false
if ($def.properties) {
	foreach ($p in $def.properties.PSObject.Properties) {
		if ($p.Name -eq "autoTitle") { $hasAutoTitle = $true }
	}
}
if ($formTitle -and -not $hasAutoTitle) {
	$propsClone | Add-Member -NotePropertyName "autoTitle" -NotePropertyValue $false
}
if ($def.properties) {
	foreach ($p in $def.properties.PSObject.Properties) {
		if ($p.Name -ne "title") {
			$propsClone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
		}
	}
}
Emit-Properties -props $propsClone -indent "`t"

# 12c. CommandSet (excluded commands)
if ($def.excludedCommands -and $def.excludedCommands.Count -gt 0) {
	X "`t<CommandSet>"
	foreach ($cmd in $def.excludedCommands) {
		X "`t`t<ExcludedCommand>$cmd</ExcludedCommand>"
	}
	X "`t</CommandSet>"
}

# 12d. AutoCommandBar (always present, id=-1)
$acbAutofill = Compute-MainAcbAutofill
$acbName = "ФормаКоманднаяПанель"
$acbHAlign = $null
if ($script:mainAcbDef) {
	if ($null -ne $script:mainAcbDef.PSObject.Properties["autoCmdBar"] -and "$($script:mainAcbDef.autoCmdBar)" -ne "") {
		$acbName = "$($script:mainAcbDef.autoCmdBar)"
	}
	if ($null -ne $script:mainAcbDef.PSObject.Properties["name"] -and "$($script:mainAcbDef.name)" -ne "") {
		$acbName = "$($script:mainAcbDef.name)"
	}
	if ($null -ne $script:mainAcbDef.PSObject.Properties["horizontalAlign"] -and "$($script:mainAcbDef.horizontalAlign)" -ne "") {
		$acbHAlign = "$($script:mainAcbDef.horizontalAlign)"
	}
}
$hasAcbChildren = ($script:mainAcbDef -and $script:mainAcbDef.children -and $script:mainAcbDef.children.Count -gt 0)
$acbHasInner = ($acbHAlign -or (-not $acbAutofill) -or $hasAcbChildren)
if ($acbHasInner) {
	X "`t<AutoCommandBar name=`"$acbName`" id=`"-1`">"
	if ($acbHAlign) { X "`t`t<HorizontalAlign>$acbHAlign</HorizontalAlign>" }
	if (-not $acbAutofill) { X "`t`t<Autofill>false</Autofill>" }
	if ($hasAcbChildren) {
		X "`t`t<ChildItems>"
		foreach ($child in $script:mainAcbDef.children) {
			Emit-Element -el $child -indent "`t`t`t" -inCmdBar $true
		}
		X "`t`t</ChildItems>"
	}
	X "`t</AutoCommandBar>"
} else {
	X "`t<AutoCommandBar name=`"$acbName`" id=`"-1`"/>"
}

# 12e. Events
if ($def.events) {
	foreach ($p in $def.events.PSObject.Properties) {
		if ($script:knownFormEvents -notcontains $p.Name) {
			Write-Host "[WARN] Unknown form event '$($p.Name)'. Known: $($script:knownFormEvents -join ', ')"
		}
	}
	X "`t<Events>"
	foreach ($p in $def.events.PSObject.Properties) {
		X "`t`t<Event name=`"$($p.Name)`">$($p.Value)</Event>"
	}
	X "`t</Events>"
}

# 12f. ChildItems (elements)
if ($def.elements -and $def.elements.Count -gt 0) {
	X "`t<ChildItems>"
	foreach ($el in $def.elements) {
		Emit-Element -el $el -indent "`t`t"
	}
	X "`t</ChildItems>"
}

# 12g. Attributes
Emit-Attributes -attrs $def.attributes -indent "`t"

# 12h. Parameters
Emit-Parameters -params $def.parameters -indent "`t"

# 12i. Commands
Emit-Commands -cmds $def.commands -indent "`t"

# 12j. Close
X '</Form>'

# --- 13. Write output ---

$outPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
$outDir = [System.IO.Path]::GetDirectoryName($outPath)
if (-not (Test-Path $outDir)) {
	New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($outPath, $xml.ToString(), $enc)

# --- 13b. Auto-register form in parent object XML ---

# Infer parent from OutputPath: .../TypePlural/ObjectName/Forms/FormName/Ext/Form.xml
$formXmlDir   = [System.IO.Path]::GetDirectoryName($outPath)
$formNameDir  = [System.IO.Path]::GetDirectoryName($formXmlDir)
$formsDir     = [System.IO.Path]::GetDirectoryName($formNameDir)
$objectDir    = [System.IO.Path]::GetDirectoryName($formsDir)
$typePluralDir = [System.IO.Path]::GetDirectoryName($objectDir)

$formName   = [System.IO.Path]::GetFileName($formNameDir)
$objectName = [System.IO.Path]::GetFileName($objectDir)
$formsLeaf  = [System.IO.Path]::GetFileName($formsDir)

if ($formsLeaf -eq 'Forms') {
	$objectXmlPath = Join-Path $typePluralDir "$objectName.xml"
	if (Test-Path $objectXmlPath) {
		$objDoc = New-Object System.Xml.XmlDocument
		$objDoc.PreserveWhitespace = $true
		$objDoc.Load($objectXmlPath)

		$nsMgr = New-Object System.Xml.XmlNamespaceManager($objDoc.NameTable)
		$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

		$childObjects = $objDoc.SelectSingleNode("//md:ChildObjects", $nsMgr)
		if ($childObjects) {
			$existing = $childObjects.SelectSingleNode("md:Form[text()='$formName']", $nsMgr)
			if (-not $existing) {
				$formElem = $objDoc.CreateElement("Form", "http://v8.1c.ru/8.3/MDClasses")
				$formElem.InnerText = $formName

				$insertBefore = $childObjects.SelectSingleNode("md:Template", $nsMgr)
				if (-not $insertBefore) { $insertBefore = $childObjects.SelectSingleNode("md:TabularSection", $nsMgr) }

				if ($insertBefore) {
					$childObjects.InsertBefore($formElem, $insertBefore) | Out-Null
					$ws = $objDoc.CreateWhitespace("`n`t`t`t")
					$childObjects.InsertBefore($ws, $insertBefore) | Out-Null
				} else {
					$lastChild = $childObjects.LastChild
					if ($lastChild -and $lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
						$childObjects.InsertBefore($objDoc.CreateWhitespace("`n`t`t`t"), $lastChild) | Out-Null
						$childObjects.InsertBefore($formElem, $lastChild) | Out-Null
					} else {
						$childObjects.AppendChild($objDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
						$childObjects.AppendChild($formElem) | Out-Null
						$childObjects.AppendChild($objDoc.CreateWhitespace("`n`t`t")) | Out-Null
					}
				}

				$regEnc = New-Object System.Text.UTF8Encoding($true)
				$regSettings = New-Object System.Xml.XmlWriterSettings
				$regSettings.Encoding = $regEnc
				$regSettings.Indent = $false
				$regStream = New-Object System.IO.FileStream($objectXmlPath, [System.IO.FileMode]::Create)
				$regWriter = [System.Xml.XmlWriter]::Create($regStream, $regSettings)
				$objDoc.Save($regWriter)
				$regWriter.Close()
				$regStream.Close()

				Write-Host "     Registered: <Form>$formName</Form> in $objectName.xml"
			}
		}
	}
}

# --- 14. Summary ---

$elCount = $script:nextId - 1
Write-Host "[OK] Compiled: $OutputPath"
Write-Host "     Elements+IDs: $elCount"
if ($def.attributes) { Write-Host "     Attributes: $($def.attributes.Count)" }
if ($def.commands)   { Write-Host "     Commands: $($def.commands.Count)" }
if ($def.parameters) { Write-Host "     Parameters: $($def.parameters.Count)" }
