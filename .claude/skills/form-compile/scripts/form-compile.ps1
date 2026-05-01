# form-compile v1.8 — Compile 1C managed form from JSON or object metadata
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
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

# --- 4. Multilang helper ---

function Emit-MLText {
	param([string]$tag, [string]$text, [string]$indent)
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
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

	# cfg: references (CatalogRef.XXX, DocumentObject.XXX, etc.)
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|InformationRegisterRecordSet|InformationRegisterRecordManager|AccumulationRegisterRecordSet|AccountingRegisterRecordSet|ConstantsSet|DataProcessorObject|ReportObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# Fallback with validation
	if ($script:knownInvalidTypes.ContainsKey($typeStr)) {
		throw "Invalid form attribute type '$typeStr': $($script:knownInvalidTypes[$typeStr])"
	}
	if ($typeStr.Contains('.')) {
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

function Emit-Events {
	param($el, [string]$elementName, [string]$indent, [string]$typeKey)

	if (-not $el.on) { return }

	# Validate event names
	if ($typeKey -and $script:knownEvents.ContainsKey($typeKey)) {
		$allowed = $script:knownEvents[$typeKey]
		foreach ($evt in $el.on) {
			if ($allowed.Count -gt 0 -and $allowed -notcontains "$evt") {
				Write-Host "[WARN] Unknown event '$evt' for $typeKey '$elementName'. Known: $($allowed -join ', ')"
			}
		}
	}

	X "$indent<Events>"
	foreach ($evt in $el.on) {
		$evtName = "$evt"
		$handler = if ($el.handlers -and $el.handlers.$evtName) {
			"$($el.handlers.$evtName)"
		} else {
			Get-HandlerName -elementName $elementName -eventName $evtName
		}
		X "$indent`t<Event name=`"$evtName`">$handler</Event>"
	}
	X "$indent</Events>"
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent)
	$id = New-Id
	X "$indent<$tag name=`"$name`" id=`"$id`"/>"
}

function Emit-Element {
	param($el, [string]$indent)

	# Silent synonyms: commandBar -> cmdBar, autoCommandBar -> autoCmdBar
	# (autoCmdBar inside def.elements is normally extracted in pre-pass; this is a safety net for nested cases)
	$synonyms = @{ "commandBar" = "cmdBar"; "autoCommandBar" = "autoCmdBar" }
	foreach ($pair in $synonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}

	# Determine element type from key
	$typeKey = $null
	$xmlTag = $null

	foreach ($key in @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
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
		"group"=1;"input"=1;"check"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		# naming & binding
		"name"=1;"path"=1;"title"=1
		# visibility & state
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1;"userVisible"=1
		# events
		"on"=1;"handlers"=1
		# layout
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		# input-specific
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		# label/hyperlink
		"hyperlink"=1
		# group-specific
		"showTitle"=1;"united"=1
		# hierarchy
		"children"=1;"columns"=1
		# table-specific
		"changeRowSet"=1;"changeRowOrder"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1
		"choiceMode"=1;"initialTreeView"=1;"enableDrag"=1;"enableStartDrag"=1
		"rowPictureDataPath"=1;"tableAutofill"=1
		# pages-specific
		"pagesRepresentation"=1
		# button-specific
		"type"=1;"command"=1;"stdCommand"=1;"defaultButton"=1;"locationInCommandBar"=1
		# picture/decoration
		"src"=1
		# cmdBar-specific
		"autofill"=1
	}
	foreach ($p in $el.PSObject.Properties) {
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored. Check SKILL.md for valid keys."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	$id = New-Id

	switch ($typeKey) {
		"group"    { Emit-Group -el $el -name $name -id $id -indent $indent }
		"input"    { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"    { Emit-Check -el $el -name $name -id $id -indent $indent }
		"label"    { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"    { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"    { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"     { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"   { Emit-Button -el $el -name $name -id $id -indent $indent }
		"picture"  { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"picField" { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar" { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"   { Emit-CommandBar -el $el -name $name -id $id -indent $indent }
		"popup"    { Emit-Popup -el $el -name $name -id $id -indent $indent }
	}
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($el.userVisible -eq $false) {
		X "$indent<UserVisible>"
		X "$indent`t<xr:Common>false</xr:Common>"
		X "$indent</UserVisible>"
	}
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

function Emit-Title {
	param($el, [string]$name, [string]$indent)
	if ($el.title) {
		Emit-MLText -tag "Title" -text "$($el.title)" -indent $indent
	}
}

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<UsualGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation
	$groupVal = "$($el.group)"
	$orientation = switch ($groupVal) {
		"horizontal"       { "Horizontal" }
		"vertical"         { "Vertical" }
		"alwaysHorizontal" { "AlwaysHorizontal" }
		"alwaysVertical"   { "AlwaysVertical" }
		default            { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }

	# Behavior
	if ($groupVal -eq "collapsible") {
		X "$inner<Group>Vertical</Group>"
		X "$inner<Behavior>Collapsible</Behavior>"
	}

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

	# Companion: ExtendedTooltip
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

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

function Emit-Input {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<InputField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
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
	if ($el.clearButton -eq $true) { X "$inner<ClearButton>true</ClearButton>" }
	if ($el.spinButton -eq $true) { X "$inner<SpinButton>true</SpinButton>" }
	if ($el.dropListButton -eq $true) { X "$inner<DropListButton>true</DropListButton>" }
	if ($el.markIncomplete -eq $true) { X "$inner<AutoMarkIncomplete>true</AutoMarkIncomplete>" }
	if ($el.skipOnInput -eq $true) { X "$inner<SkipOnInput>true</SkipOnInput>" }
	if ($el.autoMaxWidth -eq $false) { X "$inner<AutoMaxWidth>false</AutoMaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$inner<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
	if ($el.horizontalStretch -eq $true) { X "$inner<HorizontalStretch>true</HorizontalStretch>" }
	if ($el.verticalStretch -eq $true) { X "$inner<VerticalStretch>true</VerticalStretch>" }

	if ($el.inputHint) {
		Emit-MLText -tag "InputHint" -text "$($el.inputHint)" -indent $inner
	}

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"

	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CheckBoxField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) {
		X "$inner<TitleLocation>$($el.titleLocation)</TitleLocation>"
	}

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "check"

	X "$indent</CheckBoxField>"
}

function Emit-Label {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.title) {
		$formatted = if ($el.hyperlink -eq $true) { "true" } else { "false" }
		X "$inner<Title formatted=`"$formatted`">"
		X "$inner`t<v8:item>"
		X "$inner`t`t<v8:lang>ru</v8:lang>"
		X "$inner`t`t<v8:content>$(Esc-Xml "$($el.title)")</v8:content>"
		X "$inner`t</v8:item>"
		X "$inner</Title>"
	}

	Emit-CommonFlags -el $el -indent $inner

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	if ($el.autoMaxWidth -eq $false) { X "$inner<AutoMaxWidth>false</AutoMaxWidth>" }
	if ($el.autoMaxHeight -eq $false) { X "$inner<AutoMaxHeight>false</AutoMaxHeight>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"

	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "labelField"

	X "$indent</LabelField>"
}

function Emit-Table {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Table name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	if ($el.changeRowSet -eq $true) { X "$inner<ChangeRowSet>true</ChangeRowSet>" }
	if ($el.changeRowOrder -eq $true) { X "$inner<ChangeRowOrder>true</ChangeRowOrder>" }
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
	if ($el.initialTreeView) { X "$inner<InitialTreeView>$($el.initialTreeView)</InitialTreeView>" }
	if ($el.enableStartDrag -eq $true) { X "$inner<EnableStartDrag>true</EnableStartDrag>" }
	if ($el.enableDrag -eq $true) { X "$inner<EnableDrag>true</EnableDrag>" }
	if ($el.rowPictureDataPath) { X "$inner<RowPictureDataPath>$($el.rowPictureDataPath)</RowPictureDataPath>" }

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	# AutoCommandBar — with optional Autofill control
	if ($null -ne $el.tableAutofill) {
		$acbId = New-Id
		X "$inner<AutoCommandBar name=`"${name}КоманднаяПанель`" id=`"$acbId`">"
		$afVal = if ($el.tableAutofill) { "true" } else { "false" }
		X "$inner`t<Autofill>$afVal</Autofill>"
		X "$inner</AutoCommandBar>"
	} else {
		Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	}
	Emit-Companion -tag "SearchStringAddition" -name "${name}СтрокаПоиска" -indent $inner
	Emit-Companion -tag "ViewStatusAddition" -name "${name}СостояниеПросмотра" -indent $inner
	Emit-Companion -tag "SearchControlAddition" -name "${name}УправлениеПоиском" -indent $inner

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

	if ($el.pagesRepresentation) {
		X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>"
	}

	Emit-CommonFlags -el $el -indent $inner

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

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

	Emit-Title -el $el -name $name -indent $inner
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

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

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
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Button name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	# Type
	if ($el.type) {
		$btnType = switch ("$($el.type)") {
			"usual"      { "UsualButton" }
			"hyperlink"  { "Hyperlink" }
			"commandBar" { "CommandBarButton" }
			default      { "$($el.type)" }
		}
		X "$inner<Type>$btnType</Type>"
	}

	# CommandName
	if ($el.command) {
		X "$inner<CommandName>Form.Command.$($el.command)</CommandName>"
	}
	if ($el.stdCommand) {
		$sc = "$($el.stdCommand)"
		if ($sc -match '^(.+)\.(.+)$') {
			X "$inner<CommandName>Form.Item.$($Matches[1]).StandardCommand.$($Matches[2])</CommandName>"
		} else {
			X "$inner<CommandName>Form.StandardCommand.$sc</CommandName>"
		}
	}

	Emit-Title -el $el -name $name -indent $inner
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

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"

	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureDecoration name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.picture -or $el.src) {
		$ref = if ($el.src) { "$($el.src)" } else { "$($el.picture)" }
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$ref</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
		X "$inner</Picture>"
	}

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

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

	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"

	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CalendarField name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"

	X "$indent</CalendarField>"
}

function Emit-CommandBar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CommandBar name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }

	Emit-CommonFlags -el $el -indent $inner

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</CommandBar>"
}

function Emit-Popup {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<Popup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner
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

	# Children
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) {
			Emit-Element -el $child -indent "$inner`t"
		}
		X "$inner</ChildItems>"
	}

	X "$indent</Popup>"
}

# --- 8. Attribute emitter ---

function Emit-Attributes {
	param($attrs, [string]$indent)

	if (-not $attrs -or $attrs.Count -eq 0) { return }

	X "$indent<Attributes>"
	foreach ($attr in $attrs) {
		$attrId = New-Id
		$attrName = "$($attr.name)"

		X "$indent`t<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$indent`t`t"

		if ($attr.title) {
			Emit-MLText -tag "Title" -text "$($attr.title)" -indent $inner
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
		if ($attr.savedData -eq $true) {
			X "$inner<SavedData>true</SavedData>"
		}
		if ($attr.fillChecking) {
			X "$inner<FillChecking>$($attr.fillChecking)</FillChecking>"
		}

		# Columns (for ValueTable/ValueTree)
		if ($attr.columns -and $attr.columns.Count -gt 0) {
			X "$inner<Columns>"
			foreach ($col in $attr.columns) {
				$colId = New-Id
				X "$inner`t<Column name=`"$($col.name)`" id=`"$colId`">"
				if ($col.title) {
					Emit-MLText -tag "Title" -text "$($col.title)" -indent "$inner`t`t"
				}
				Emit-Type -typeStr "$($col.type)" -indent "$inner`t`t"
				X "$inner`t</Column>"
			}
			X "$inner</Columns>"
		}

		# Settings (for DynamicList)
		if ($attr.settings) {
			X "$inner<Settings xsi:type=`"DynamicList`">"
			$si = "$inner`t"
			if ($attr.settings.mainTable) { X "$si<MainTable>$($attr.settings.mainTable)</MainTable>" }
			$mq = if ($attr.settings.manualQuery -eq $true) { "true" } else { "false" }
			X "$si<ManualQuery>$mq</ManualQuery>"
			$ddr = if ($attr.settings.dynamicDataRead -eq $true) { "true" } else { "false" }
			X "$si<DynamicDataRead>$ddr</DynamicDataRead>"
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

		if ($cmd.title) {
			Emit-MLText -tag "Title" -text "$($cmd.title)" -indent $inner
		}

		if ($cmd.action) {
			X "$inner<Action>$($cmd.action)</Action>"
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

function Normalize-ElementSynonyms {
	param($el)
	if ($null -eq $el) { return }
	$synonyms = @{ "commandBar" = "cmdBar"; "autoCommandBar" = "autoCmdBar" }
	foreach ($pair in $synonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
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
	param($el, [string]$listName)
	if ($null -eq $el) { return }
	if ($el.PSObject.Properties["table"] -and $null -ne $el.table -and "$($el.path)" -eq $listName) {
		if ($null -eq $el.PSObject.Properties["tableAutofill"]) {
			$el | Add-Member -NotePropertyName "tableAutofill" -NotePropertyValue $false -Force
		}
		if ($null -eq $el.PSObject.Properties["commandBarLocation"]) {
			$el | Add-Member -NotePropertyName "commandBarLocation" -NotePropertyValue "None" -Force
		}
	}
	if ($el.PSObject.Properties["children"] -and $el.children) {
		foreach ($child in $el.children) { ApplyDynamicListTableHeuristic $child $listName }
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

# 11b.4: DynamicList → table heuristic
if ($def.attributes -and $def.elements) {
	$mainAttr = $null
	foreach ($attr in $def.attributes) {
		if ($attr.main -eq $true) { $mainAttr = $attr; break }
	}
	if ($mainAttr -and "$($mainAttr.type)" -eq "DynamicList") {
		foreach ($el in $def.elements) {
			ApplyDynamicListTableHeuristic $el $mainAttr.name
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
	Emit-MLText -tag "Title" -text "$($def.title)" -indent "`t"
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
	Emit-MLText -tag "Title" -text "$formTitle" -indent "`t"
}

# 12b. Properties (skip 'title' — handled above as multilingual)
if ($def.properties) {
	$propsClone = New-Object PSObject
	foreach ($p in $def.properties.PSObject.Properties) {
		if ($p.Name -ne "title") {
			$propsClone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
		}
	}
	Emit-Properties -props $propsClone -indent "`t"
} else {
	Emit-Properties -props $null -indent "`t"
}

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
$acbHAlign = "Right"
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
			Emit-Element -el $child -indent "`t`t`t"
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
