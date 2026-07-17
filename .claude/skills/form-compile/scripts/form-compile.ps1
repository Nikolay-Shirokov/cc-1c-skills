# form-compile v1.175 — Compile 1C managed form from JSON or object metadata
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

	# (ChoiceButton у ref-полей платформа выводит сама; компилятор эмитит true по StartChoice-эвристике.
	#  Явный choiceButton из декомпиляции эмитится verbatim. Дефолт-«true» здесь НЕ ставим, чтобы
	#  from-object вывод совпадал с сертифицированным и не плодил ChoiceButton на каждом ref-поле.)

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
		# Имена колонок табчасти префиксуются именем таблицы (как generic-путь и типовая 1С),
		# иначе флаг субконто (напр. "Валютный") столкнётся с одноимённым признаком учёта счёта.
		$edTable = "ВидыСубконто"
		$edCols = @()
		$edCols += [ordered]@{ input = "${edTable}ВидСубконто"; path = "Объект.ExtDimensionTypes.ExtDimensionType" }
		$edCols += [ordered]@{ check = "${edTable}ТолькоОбороты"; path = "Объект.ExtDimensionTypes.TurnoversOnly" }
		if ($meta.ExtDimensionAccountingFlags) {
			foreach ($edFlag in $meta.ExtDimensionAccountingFlags) {
				$edCols += [ordered]@{ check = "${edTable}$($edFlag.Name)"; path = "Объект.ExtDimensionTypes.$($edFlag.Name)" }
			}
		}
		$elements += [ordered]@{
			table = $edTable
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

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
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
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

$script:outPathResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
Assert-EditAllowed $script:outPathResolved 'editable'
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

# Уникальность имён внутри коллекции (1С: элементы/реквизиты/команды/параметры/колонки — каждое своё
# пространство имён). Дубль → битый XML, форма не открывается, поэтому fail-fast.
function Assert-UniqueName {
	param([string]$name, [hashtable]$seen, [string]$kind)
	if ($seen.ContainsKey($name)) {
		Write-Error "Duplicate $kind name '$name' — names must be unique within their collection in a 1C form (set a unique 'name')"
		exit 1
	}
	$seen[$name] = $true
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
	param([string]$tag, $text, [string]$indent, [string]$xsiType)
	$attr = if ($xsiType) { " xsi:type=`"$xsiType`"" } else { "" }
	X "$indent<$tag$attr>"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

# <dcsset:userSettingPresentation> и подобные DCS-подписи: платформа пишет плоскую строку как
# xsi:type="xs:string" (скаляр; корпус 26), мультиязычный текст — как xsi:type="v8:LocalStringType"
# (7). Декомпилятор различает (Get-PresText: строка ИЛИ объект {ru,en}).
function Emit-USPresentation {
	param($val, [string]$tag, [string]$indent)
	if ($null -eq $val) { return }
	if ($val -is [string]) {
		X "$indent<$tag xsi:type=`"xs:string`">$(Esc-Xml $val)</$tag>"
	} else {
		Emit-MLText -tag $tag -text $val -indent $indent -xsiType "v8:LocalStringType"
	}
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
	"like" = "Like"; "notLike" = "NotLike"
	"подобно" = "Like"; "неподобно" = "NotLike"   # рус. синоним (хэш регистронезависим: ПОДОБНО=подобно)
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
		'notLike\b', 'like\b', 'неподобно\b', 'подобно\b',
		'notFilled\b', 'filled\b')
	$opJoined = $opPatterns -join '|'
	if ($s -match "^(.+?)\s+($opJoined)\s*(.*)?$") {
		$result.field = $Matches[1].Trim()
		$result.op = $Matches[2].Trim()
		$valPart = if ($Matches[3]) { $Matches[3].Trim() } else { "" }
		if ($valPart -and $valPart -ne "_") {
			if ($valPart -eq "true" -or $valPart -eq "false") { $result.value = [bool]($valPart -eq "true"); $result["valueType"] = "xs:boolean" }
			elseif ($valPart -match '^\d{4}-\d{2}-\d{2}T') { $result.value = $valPart }  # дата без valueType → Emit-FilterItem выведет StandardBeginningDate Custom (дефолт даты в фильтре)
			elseif ($valPart -match '^\d+(\.\d+)?$') { $result.value = $valPart; $result["valueType"] = "xs:decimal" }
			elseif ($valPart -match '^(Перечисление|Справочник|ПланСчетов|Документ|ПланВидовХарактеристик|ПланВидовРасчета)\.') { $result.value = $valPart; $result["valueType"] = "dcscor:DesignTimeValue" }
			else { $result.value = $valPart; $result["valueType"] = "xs:string" }
		}
	} else { $result.field = $s }
	return $result
}

# Значение типа v8:Type (напр. тип «Неопределено» = <prefix>:Undefined) ссылается на тип
# платформы из namespace http://v8.1c.ru/8.2/data/types — платформа объявляет его ЛОКАЛЬНО
# на теге значения (префикс авто-назначаемый: d6p1/d8p1/dN…). Без объявления QName битый.
# Возвращает строку-атрибут ' xmlns:<pref>="…"' (перед xsi:type), либо "".
function Get-ValueTypeNsAttr {
	param([string]$valueType, [string]$value)
	if ($valueType -eq 'v8:Type' -and "$value" -match '^([A-Za-z]\w*):') {
		$pref = $Matches[1]
		if ($pref -notin @('xs','cfg','v8','v8ui','ent','dcscor','dcsset','dcssch')) {
			return " xmlns:$pref=`"http://v8.1c.ru/8.2/data/types`""
		}
	}
	return ""
}

function Emit-FilterItem {
	param($item, [string]$indent)
	if ($item.group) {
		$groupType = switch ("$($item.group)") { "And" { "AndGroup" } "Or" { "OrGroup" } "Not" { "NotGroup" } default { "$($item.group)Group" } }
		X "$indent<dcsset:item xsi:type=`"dcsset:FilterItemGroup`">"
		if ($item.use -eq $false) { X "$indent`t<dcsset:use>false</dcsset:use>" }   # группа отключена (перед groupType, порядок исходника)
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
		if ($item.presentation) { Emit-USPresentation -val $item.presentation -tag "dcsset:presentation" -indent "$indent`t" }
		if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>" }
		if ($item.userSettingID) {
			$guid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
			X "$indent`t<dcsset:userSettingID>$(Esc-Xml $guid)</dcsset:userSettingID>"
		}
		if ($item.userSettingPresentation) { Emit-USPresentation -val $item.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
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
				$nsAttr = Get-ValueTypeNsAttr -valueType $vt -value "$v"
				X "$indent`t<dcsset:right$nsAttr xsi:type=`"$vt`">$vStr</dcsset:right>"
			}
		}
	} elseif ($null -ne $item.value -and (
			"$($item.valueType)" -match 'Standard(Beginning|End)Date$' -or
			(-not $item.valueType -and "$($item.value)" -match '^\d{4}-\d{2}-\d{2}T'))) {
		# Стандартная дата начала/окончания. Формы значения:
		#   объект {variant, date?} — полная (Custom несёт <v8:date>);
		#   строка-вариант "BeginningOfThisDay" — именованный вариант без даты;
		#   голая ISO-дата без valueType — шорткат для Custom+date (дата в фильтре платформой
		#   почти всегда хранится как StandardBeginningDate Custom, корпус 268 vs 2 xs:dateTime;
		#   явный valueType="xs:dateTime" → плоская дата, ветка ниже).
		$sdType = if ($item.valueType) { "$($item.valueType)" -replace '^v8:','' } else { 'StandardBeginningDate' }
		$sv = $item.value
		if (($sv -is [PSCustomObject]) -or ($sv -is [System.Collections.IDictionary])) {
			$variant = if ($sv -is [PSCustomObject]) { "$($sv.variant)" } else { "$($sv['variant'])" }
			$hasDate = if ($sv -is [PSCustomObject]) { [bool]$sv.PSObject.Properties['date'] } else { $sv.Contains('date') }
			$dateV = if ($hasDate) { if ($sv -is [PSCustomObject]) { "$($sv.date)" } else { "$($sv['date'])" } } else { $null }
		} elseif ("$sv" -match '^\d{4}-\d{2}-\d{2}T') {
			$variant = 'Custom'; $hasDate = $true; $dateV = "$sv"
		} else {
			$variant = "$sv"; $hasDate = $false; $dateV = $null
		}
		X "$indent`t<dcsset:right xsi:type=`"v8:$sdType`">"
		X "$indent`t`t<v8:variant xsi:type=`"v8:${sdType}Variant`">$(Esc-Xml $variant)</v8:variant>"
		if ($hasDate) { X "$indent`t`t<v8:date>$(Esc-Xml $dateV)</v8:date>" }
		X "$indent`t</dcsset:right>"
	} elseif ("$($item.value)" -eq '_') {
		# "_" — маркер пустого значения: платформа эмитит пустой self-closing <dcsset:right>
		# (напр. <dcsset:right xsi:type="dcscor:Field"/> — сравнение с незаданным полем).
		$vt = if ($item.valueType) { "$($item.valueType)" } else { 'xs:string' }
		X "$indent`t<dcsset:right xsi:type=`"$vt`"/>"
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
		$nsAttr = Get-ValueTypeNsAttr -valueType $vt -value "$($item.value)"
		X "$indent`t<dcsset:right$nsAttr xsi:type=`"$vt`">$vStr</dcsset:right>"
	}
	if ($item.presentation) { Emit-USPresentation -val $item.presentation -tag "dcsset:presentation" -indent "$indent`t" }
	if ($item.viewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$($item.viewMode)")</dcsset:viewMode>" }
	if ($item.userSettingID) {
		$uid = if ("$($item.userSettingID)" -eq "auto") { New-Guid-String } else { "$($item.userSettingID)" }
		X "$indent`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
	}
	if ($item.userSettingPresentation) { Emit-USPresentation -val $item.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</dcsset:item>"
}

function Emit-Filter {
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null, $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
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
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</dcsset:filter>"
}

function Emit-Order {
	param($items, [string]$indent, [switch]$skipAuto, $blockViewMode = $null, $blockUserSettingID = $null, $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
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
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
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
	} elseif ($isDict -and (_HasKey $innerVal 'field')) {
		# Ссылка на поле (dcscor:Field) — значение параметра оформления = поле компоновки
		X "$indent`t<dcscor:value xsi:type=`"dcscor:Field`">$(Esc-Xml "$(_Get $innerVal 'field')")</dcscor:value>"
	} elseif ($isDict) {
		# Локализуемый текст параметра оформления: платформа объявляет xsi:type на dcscor:value
		Emit-MLText -tag "dcscor:value" -text $innerVal -indent "$indent`t" -xsiType "v8:LocalStringType"
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
		elseif ($key -eq "Текст" -or $key -eq "Заголовок" -or $key -eq "Формат") {
			# Текст/Заголовок/Формат: голая строка = плоский xs:string (так платформа хранит
			# нелокализованный литерал). Локализуемый текст → объект {ru,en} (ветка isDict выше).
			# Пустая строка → самозакрывающийся тег (как у платформы).
			if ($actualVal -eq '') { X "$indent`t<dcscor:value xsi:type=`"xs:string`"/>" }
			else { X "$indent`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $actualVal)</dcscor:value>" }
		}
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
	param($items, [string]$indent, $blockViewMode = $null, $blockUserSettingID = $null, [string]$wrapTag = 'dcsset:conditionalAppearance', $blockUserSettingPresentation = $null)
	$hasItems = $items -and $items.Count -gt 0
	$hasBlockMeta = ($null -ne $blockViewMode) -or ($null -ne $blockUserSettingID) -or ($null -ne $blockUserSettingPresentation)
	if (-not $hasItems -and -not $hasBlockMeta) { return }
	X "$indent<$wrapTag>"
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
			if ($ca.presentation -is [hashtable] -or $ca.presentation -is [System.Collections.IDictionary] -or $ca.presentation -is [PSCustomObject]) {
				# Мультиязык → LocalStringType (платформа объявляет тип у локализованного presentation)
				X "$indent`t`t<dcsset:presentation xsi:type=`"v8:LocalStringType`">"
				Emit-MLItems -val $ca.presentation -indent "$indent`t`t`t"
				X "$indent`t`t</dcsset:presentation>"
			}
			else { X "$indent`t`t<dcsset:presentation xsi:type=`"xs:string`">$(Esc-Xml "$($ca.presentation)")</dcsset:presentation>" }
		}
		if ($ca.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($ca.viewMode)")</dcsset:viewMode>" }
		if ($ca.userSettingID) {
			$uid = if ("$($ca.userSettingID)" -eq "auto") { New-Guid-String } else { "$($ca.userSettingID)" }
			X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>"
		}
		if ($ca.userSettingPresentation) { Emit-USPresentation -val $ca.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t`t" }
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
	if ($null -ne $blockUserSettingPresentation) { Emit-USPresentation -val $blockUserSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t" }
	X "$indent</$wrapTag>"
}

# === Группировка строк динамического списка (DCS-структура ListSettings) ===
# Линейная цепочка <dcsset:item StructureItemGroup> (каждый уровень = одно поле в groupItems;
# вложенность — через дочерний <dcsset:item>). Зеркало skd Emit-GroupItems/Emit-StructureItem,
# но плоская модель уровней (список всегда линеен, без selection/order/children).
function Get-ListGroupingValue {
	param($st)
	foreach ($k in 'grouping','structure','группировка') {
		if ($st.PSObject.Properties[$k] -and $st.$k) { return $st.$k }
	}
	return $null
}

function Parse-ListGrouping {
	param($grouping)
	# Шорткат "A > B > C" → массив имён; массив строк/объектов → как есть.
	# Unary comma: иначе PS разворачивает одноэлементный массив при return → строка → индексация даёт char.
	if (-not $grouping) { return ,@() }
	if ($grouping -is [string]) { return ,@($grouping -split '\s*>\s*' | Where-Object { "$_" -ne '' }) }
	return ,@($grouping)
}

function Emit-GroupItemField {
	param($level, [string]$indent)
	if ($level -is [string]) {
		$field = $level; $gt = 'Items'; $pat = 'None'; $pab = '0001-01-01T00:00:00'; $pae = '0001-01-01T00:00:00'
	} else {
		$field = "$($level.field)"
		$gt  = if ($level.groupType) { "$($level.groupType)" } else { 'Items' }
		$pat = if ($level.periodAdditionType) { "$($level.periodAdditionType)" } else { 'None' }
		$pab = if ($level.periodAdditionBegin) { "$($level.periodAdditionBegin)" } else { '0001-01-01T00:00:00' }
		$pae = if ($level.periodAdditionEnd)   { "$($level.periodAdditionEnd)"   } else { '0001-01-01T00:00:00' }
	}
	X "$indent<dcsset:item xsi:type=`"dcsset:GroupItemField`">"
	X "$indent`t<dcsset:field>$(Esc-Xml $field)</dcsset:field>"
	X "$indent`t<dcsset:groupType>$(Esc-Xml $gt)</dcsset:groupType>"
	X "$indent`t<dcsset:periodAdditionType>$(Esc-Xml $pat)</dcsset:periodAdditionType>"
	# Авто-детект: ISO-дата → xs:dateTime, иначе путь → dcscor:Field.
	$pabT = if ($pab -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
	$paeT = if ($pae -match '^\d{4}-\d{2}-\d{2}T') { 'xs:dateTime' } else { 'dcscor:Field' }
	X "$indent`t<dcsset:periodAdditionBegin xsi:type=`"$pabT`">$(Esc-Xml $pab)</dcsset:periodAdditionBegin>"
	X "$indent`t<dcsset:periodAdditionEnd xsi:type=`"$paeT`">$(Esc-Xml $pae)</dcsset:periodAdditionEnd>"
	X "$indent</dcsset:item>"
}

function Emit-ListGroupingLevels {
	param($levels, [int]$i, [string]$indent)
	X "$indent<dcsset:item xsi:type=`"dcsset:StructureItemGroup`">"
	X "$indent`t<dcsset:groupItems>"
	Emit-GroupItemField $levels[$i] "$indent`t`t"
	X "$indent`t</dcsset:groupItems>"
	if ($i -lt $levels.Count - 1) { Emit-ListGroupingLevels $levels ($i + 1) "$indent`t" }
	X "$indent</dcsset:item>"
}

function Emit-ListGrouping {
	param($grouping, [string]$indent)
	$levels = Parse-ListGrouping $grouping
	if ($levels.Count -eq 0) { return }
	Emit-ListGroupingLevels $levels 0 $indent
}

# === Вычисляемые поля DataSet динамического списка (<CalculatedField>) ===
# Зеркало skd: shorthand "Имя [Заголовок]: тип = Выражение #noField #noFilter #noGroup #noOrder"
# или объект. Форм-специфика: dcssch:-теги + presentationExpression/orderExpression (dcscommon ns).
$script:calcRestrictMap = @{ 'noField'='field'; 'noFilter'='condition'; 'noCondition'='condition'; 'noGroup'='group'; 'noOrder'='order' }
$script:dcsCommonNs = 'http://v8.1c.ru/8.1/data-composition-system/common'

function Parse-CalcShorthand {
	param([string]$s)
	$restrict = @()
	foreach ($m in [regex]::Matches($s, '#(noField|noFilter|noCondition|noGroup|noOrder)\b')) { $restrict += $m.Groups[1].Value }
	$s = [regex]::Replace($s, '\s*#(noField|noFilter|noCondition|noGroup|noOrder)\b', '')
	$eq = $s.IndexOf('=')
	if ($eq -gt 0) { $lhs = $s.Substring(0, $eq); $rhs = $s.Substring($eq + 1).Trim() } else { $lhs = $s; $rhs = '' }
	$title = ''
	if ($lhs -match '\[([^\]]+)\]') { $title = $Matches[1]; $lhs = $lhs -replace '\s*\[[^\]]+\]', '' }
	$lhs = $lhs.Trim()
	$type = ''; $dataPath = $lhs
	if ($lhs.Contains(':')) { $parts = $lhs -split ':', 2; $dataPath = $parts[0].Trim(); $type = Resolve-TypeStr ($parts[1].Trim()) }
	return @{ dataPath = $dataPath; expression = $rhs; type = $type; title = $title; restrict = $restrict }
}

function Emit-CalcFields {
	param($calcFields, [string]$indent)
	if (-not $calcFields) { return }
	foreach ($cf in $calcFields) {
		$pres = $null; $orderExpr = $null; $restrict = @()
		if ($cf -is [string]) {
			$p = Parse-CalcShorthand $cf
			$dataPath = "$($p.dataPath)"; $expression = "$($p.expression)"; $title = $p.title; $typeStr = "$($p.type)"
			foreach ($r in $p.restrict) { if ($script:calcRestrictMap[$r]) { $restrict += $script:calcRestrictMap[$r] } }
		} else {
			$dataPath = if ($cf.dataPath) { "$($cf.dataPath)" } elseif ($cf.field) { "$($cf.field)" } else { "$($cf.name)" }
			$expression = "$($cf.expression)"
			$title = $cf.title
			$typeStr = if ($cf.valueType) { "$($cf.valueType)" } elseif ($cf.type) { "$($cf.type)" } else { '' }
			$ur = if ($cf.useRestriction) { $cf.useRestriction } elseif ($cf.restrict) { $cf.restrict } else { $null }
			if ($ur -is [System.Management.Automation.PSCustomObject] -or $ur -is [hashtable]) {
				foreach ($k in 'field','condition','group','order') { if ($ur.$k -eq $true) { $restrict += $k } }
			} elseif ($ur -is [string]) {
				foreach ($tok in ($ur -split '\s+')) { $t = $tok.Trim().TrimStart('#'); if ($t) { $restrict += $(if ($script:calcRestrictMap[$t]) { $script:calcRestrictMap[$t] } else { $t }) } }
			} elseif ($ur) {
				foreach ($r in $ur) { $rr = "$r"; $restrict += $(if ($script:calcRestrictMap[$rr]) { $script:calcRestrictMap[$rr] } else { $rr }) }
			}
			$pres = $cf.presentationExpression
			$orderExpr = $cf.orderExpression
		}
		$ci = "$indent`t"
		X "$indent<CalculatedField>"
		X "$ci<dcssch:dataPath>$(Esc-Xml $dataPath)</dcssch:dataPath>"
		X "$ci<dcssch:expression>$(Esc-Xml $expression)</dcssch:expression>"
		if ($title) { Emit-MLText -tag 'dcssch:title' -text $title -indent $ci -xsiType 'v8:LocalStringType' }
		if ($restrict.Count -gt 0) {
			X "$ci<dcssch:useRestriction>"
			foreach ($r in @('field','condition','group','order')) { if ($restrict -contains $r) { X "$ci`t<dcssch:$r>true</dcssch:$r>" } }
			X "$ci</dcssch:useRestriction>"
		}
		if ($pres) { X "$ci<dcssch:presentationExpression>$(Esc-Xml "$pres")</dcssch:presentationExpression>" }
		if ($orderExpr) {
			$oeList = if ($orderExpr -is [System.Collections.IList]) { $orderExpr } else { @($orderExpr) }
			foreach ($oe in $oeList) {
				if ($oe -is [string]) { $exprV = $oe; $oType = 'Asc'; $auto = 'false' }
				else { $exprV = "$($oe.expression)"; $oType = if ($oe.orderType) { "$($oe.orderType)" } else { 'Asc' }; $auto = if ($oe.autoOrder) { 'true' } else { 'false' } }
				X "$ci<dcssch:orderExpression>"
				X "$ci`t<expression xmlns=`"$($script:dcsCommonNs)`">$(Esc-Xml $exprV)</expression>"
				X "$ci`t<orderType xmlns=`"$($script:dcsCommonNs)`">$oType</orderType>"
				X "$ci`t<autoOrder xmlns=`"$($script:dcsCommonNs)`">$auto</autoOrder>"
				X "$ci</dcssch:orderExpression>"
			}
		}
		if ($typeStr) { Emit-DLValueType -typeStr $typeStr -indent $ci }
		X "$indent</CalculatedField>"
	}
}

# Ограничения использования поля/вычисляемого поля (useRestriction / attributeUseRestriction).
# Значение: объект {field?,condition?,group?,order?} | флаг-строка "#noField #noFilter #noGroup #noOrder" | массив.
function Get-RestrictList {
	param($ur)
	$out = @()
	if (-not $ur) { return ,$out }
	if ($ur -is [System.Management.Automation.PSCustomObject] -or $ur -is [hashtable]) {
		foreach ($k in 'field','condition','group','order') { if ($ur.$k -eq $true) { $out += $k } }
	} elseif ($ur -is [string]) {
		foreach ($tok in ($ur -split '\s+')) { $t = $tok.Trim().TrimStart('#'); if ($t) { $out += $(if ($script:calcRestrictMap[$t]) { $script:calcRestrictMap[$t] } else { $t }) } }
	} else {
		foreach ($r in $ur) { $rr = "$r"; $out += $(if ($script:calcRestrictMap[$rr]) { $script:calcRestrictMap[$rr] } else { $rr }) }
	}
	return ,$out
}

function Emit-RestrictBlock {
	param([string]$tag, $ur, [string]$indent)
	$r = Get-RestrictList $ur
	if ($r.Count -eq 0) { return }
	X "$indent<dcssch:$tag>"
	foreach ($k in @('field','condition','group','order')) { if ($r -contains $k) { X "$indent`t<dcssch:$k>true</dcssch:$k>" } }
	X "$indent</dcssch:$tag>"
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
# Платформенные v8-типы (forgiving: англ. без префикса + рус.) → каноничный с префиксом v8: (эмитим verbatim)
$script:formTypeSynonyms["standardperiod"]            = "v8:StandardPeriod"
$script:formTypeSynonyms["стандартныйпериод"]          = "v8:StandardPeriod"
$script:formTypeSynonyms["standardbeginningdate"]     = "v8:StandardBeginningDate"
$script:formTypeSynonyms["стандартнаядатаначала"]      = "v8:StandardBeginningDate"
$script:formTypeSynonyms["uuid"]                      = "v8:UUID"
$script:formTypeSynonyms["уникальныйидентификатор"]    = "v8:UUID"
$script:formTypeSynonyms["списокзначений"]            = "ValueList"

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
	# $tag/$tagAttrs — обёртка (по умолчанию <Type>); для уточнения типа значений ValueList
	# вызывается с tag="Settings", tagAttrs=' xsi:type="v8:TypeDescription"'.
	param($typeStr, [string]$indent, [string]$tag = "Type", [string]$tagAttrs = "")

	if (-not $typeStr) {
		X "$indent<$tag$tagAttrs/>"
		return
	}

	$typeString = "$typeStr"

	# Composite type: "Type1 | Type2" or "Type1 + Type2"
	$parts = $typeString -split '\s*[|+]\s*'

	X "$indent<$tag$tagAttrs>"
	foreach ($part in $parts) {
		$part = $part.Trim()
		Emit-SingleType -typeStr $part -indent "$indent`t"
	}
	X "$indent</$tag>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	$typeStr = Resolve-TypeStr $typeStr

	# TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
	# сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID
	# глобально стабилен → эмитим verbatim (как роль-по-GUID). Маркер декомпилятора: 'typeid:GUID'.
	if ($typeStr -match '^typeid:([0-9a-fA-F-]{36})$') {
		X "$indent<v8:TypeId>$($Matches[1])</v8:TypeId>"
		return
	}

	# boolean
	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"
		return
	}

	# string or string(N) or string(N,fixed) (AllowedLength: Variable дефолт / Fixed)
	if ($typeStr -match '^string(\((\d+)(\s*,\s*(fixed|variable))?\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		$al = if ($Matches[4] -and $Matches[4].ToLower() -eq 'fixed') { 'Fixed' } else { 'Variable' }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>$al</v8:AllowedLength>"
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

	# Голые конфигурационные типы (cfg: без .Имя): дин-список, набор констант, общий объект отчёта.
	# Корпус (acc+erp 8.3.24): DynamicList 5205, ConstantsSet 103, ReportObject 10. (Дотированные формы
	# ConstantsSet.X / ReportObject.X ловит общий cfg:-regex ниже.)
	if ($typeStr -in @("DynamicList","ConstantsSet","ReportObject")) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
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

	# Спец-типы платформы с собственным namespace (объявляется ЛОКАЛЬНО на <v8:Type>).
	# Префикс d5p1 неоднозначен (5 разных URI), поэтому маппинг по полному значению типа.
	# К таким типам привязаны спец-поля: mxl→SpreadSheetDocumentField, fd→FormattedDocumentField,
	# d5p1:TextDocument→TextDocumentField, pdfdoc→PDF, pl→Planner, chart/geo/graphscheme/data-analysis.
	$specialTypeNs = @{
		"mxl:SpreadsheetDocument"               = "http://v8.1c.ru/8.2/data/spreadsheet"
		"fd:FormattedDocument"                  = "http://v8.1c.ru/8.2/data/formatted-document"
		"d5p1:TextDocument"                     = "http://v8.1c.ru/8.1/data/txtedt"
		"d5p1:Chart"                            = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:GanttChart"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:Dendrogram"                       = "http://v8.1c.ru/8.2/data/chart"
		"d5p1:FlowchartContextType"             = "http://v8.1c.ru/8.2/data/graphscheme"
		"d5p1:DataAnalysisTimeIntervalUnitType" = "http://v8.1c.ru/8.2/data/data-analysis"
		"d5p1:GeographicalSchema"               = "http://v8.1c.ru/8.2/data/geo"
		"pdfdoc:PDFDocument"                    = "http://v8.1c.ru/8.3/data/pdf"
		"pl:Planner"                            = "http://v8.1c.ru/8.3/data/planner"
	}
	if ($specialTypeNs.ContainsKey($typeStr)) {
		$pref = $typeStr.Substring(0, $typeStr.IndexOf(':'))
		X "$indent<v8:Type xmlns:$pref=`"$($specialTypeNs[$typeStr])`">$typeStr</v8:Type>"
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

# ExtendedTooltip — это LabelDecoration: может нести own-content (layout/оформление/флаги/hyperlink)
# вместо/вместе с текстом. Признак структурированной формы: объект с любым НЕ-текстовым ключом
# ({text,formatted} и языковые ключи {ru,en} → обычная текст-форма).
$script:companionStructKeys = @(
	'width','autoMaxWidth','maxWidth','height','autoMaxHeight','maxHeight','verticalAlign','titleHeight',
	'horizontalStretch','verticalStretch','horizontalAlign','groupHorizontalAlign','groupVerticalAlign',
	'visible','hidden','enabled','disabled','hyperlink','events','tooltip',
	'textColor','backColor','borderColor','font','border','цветтекста','цветфона','цветрамки','шрифт','рамка'
)
function Test-CompanionStructured {
	param($content)
	if (-not (($content -is [System.Collections.IDictionary]) -or ($content -is [System.Management.Automation.PSCustomObject]))) { return $false }
	foreach ($k in $script:companionStructKeys) {
		$present = if ($content -is [System.Collections.IDictionary]) { $content.Contains($k) } else { [bool]$content.PSObject.Properties[$k] }
		if ($present) { return $true }
	}
	return $false
}

function Emit-CompanionTitle {
	param($content, [string]$indent)
	$r = Resolve-MLFormatted $content
	$fmt = if ($r.formatted) { 'true' } else { 'false' }
	X "$indent<Title formatted=`"$fmt`">"
	Emit-MLItems -val $r.text -indent "$indent`t"
	X "$indent</Title>"
}

# DisplayImportance — атрибут открывающего тега элемента (адаптивная важность: VeryHigh/High/Usual/Low/VeryLow).
# Возвращает ` DisplayImportance="X"` или "" (для companion-эмиттеров без $el → "" молча).
function DI-Attr {
	param($el)
	if ($null -ne $el -and $el.displayImportance) { return " DisplayImportance=`"$(Esc-Xml "$($el.displayImportance)")`"" }
	return ""
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent, $content = $null)
	$id = New-Id
	$hasContent = $null -ne $content -and -not ($content -is [string] -and "$content" -eq '')
	if (-not $hasContent) {
		X "$indent<$tag name=`"$name`" id=`"$id`"/>"
		return
	}
	$inner = "$indent`t"
	# DI-Attr берём от СОБСТВЕННОГО объекта компаньона ($content), НЕ от ambient $el родителя
	# (PowerShell dynamic scope — иначе companion наследует DisplayImportance владельца: баг).
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $content)>"
	if (Test-CompanionStructured $content) {
		# структурированная форма (own-content). Порядок как у платформы: own-content (флаги/hyperlink/
		# layout/оформление) ПЕРЕД Title (в корпусе layout-first 582 vs 10).
		$txtPresent = if ($content -is [System.Collections.IDictionary]) { $content.Contains('text') } else { [bool]$content.PSObject.Properties['text'] }
		Emit-CommonFlags -el $content -indent $inner
		if ($content.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
		Emit-Layout -el $content -indent $inner
		Emit-Appearance -el $content -indent $inner -profile 'decoration'
		if ($txtPresent) { Emit-CompanionTitle -content $content -indent $inner }
		# ToolTip компаньона (подсказка самой расширенной подсказки) — после Title (порядок схемы LabelDecoration)
		if ($content.tooltip) { Emit-MLText -tag "ToolTip" -text $content.tooltip -indent $inner }
		# События компаньона (ExtendedTooltip = LabelDecoration: напр. URLProcessing у hyperlink-подсказки)
		Emit-Events -el $content -elementName $name -indent $inner -typeKey 'label'
	} else {
		Emit-CompanionTitle -content $content -indent $inner
	}
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
	X "$indent<$tag name=`"$name`" id=`"$id`"$(DI-Attr $panel)>"
	if ($halign) { X "$indent`t<HorizontalAlign>$halign</HorizontalAlign>" }
	if ($emitAfFalse) { X "$indent`t<Autofill>false</Autofill>" }
	if ($hasChildren) {
		X "$indent`t<ChildItems>"
		foreach ($c in @($children)) { Emit-Element -el $c -indent "$indent`t`t" -inCmdBar $true }
		X "$indent`t</ChildItems>"
	}
	X "$indent</$tag>"
}

# Дополнения командной панели таблицы: тип DSL → XML-тег + AdditionSource.Type.
$script:additionTypeMap = [ordered]@{
	'searchString'  = @{ Tag = 'SearchStringAddition';  Type = 'SearchStringRepresentation'; Suffix = 'СтрокаПоиска' }
	'viewStatus'    = @{ Tag = 'ViewStatusAddition';    Type = 'ViewStatusRepresentation';   Suffix = 'СостояниеПросмотра' }
	'searchControl' = @{ Tag = 'SearchControlAddition'; Type = 'SearchControl';               Suffix = 'УправлениеПоиском' }
}
# Синонимы типа дополнения (для override-карты additions и резолва тип-ключа).
$script:additionKeySynonyms = @{
	'searchString'  = @('SearchStringAddition','SearchStringRepresentation','строкаПоиска','отображениеСтрокиПоиска')
	'viewStatus'    = @('ViewStatusAddition','ViewStatusRepresentation','состояниеПросмотра')
	'searchControl' = @('SearchControlAddition','SearchControl','управлениеПоиском')
}

# HorizontalLocation: auto (дефолт, тег опускаем) / left / right; forgiving + рус.синонимы.
function Get-HLocation {
	param($el)
	$v = if ($el -and $el.PSObject.Properties['horizontalLocation']) { $el.horizontalLocation } else { $null }
	if (-not $v) { return $null }
	switch -Regex ("$v".ToLower()) {
		'^(auto|авто)$'          { return $null }    # дефолт — не эмитим
		'^(left|слева|лево)$'    { return 'Left' }
		'^(right|справа|право)$'  { return 'Right' }
		'^(center|центр|по центру)$' { return 'Center' }
		default                  { return "$v" }
	}
}

# Тело дополнения: AdditionSource + свойства (как у поля) + companions. $props может быть $null
# (стандартное дополнение без отклонений). Порядок 1С-толерантен (diff порядок-независим).
function Emit-AdditionBody {
	param($props, [string]$source, [string]$srcType, [string]$addName, [string]$indent)
	$inner = "$indent`t"
	X "$inner<AdditionSource>"
	X "$inner`t<Item>$source</Item>"
	X "$inner`t<Type>$srcType</Type>"
	X "$inner</AdditionSource>"
	if ($props) {
		if ($props.PSObject.Properties['title'] -and $props.title) { Emit-MLText -tag "Title" -text $props.title -indent $inner }
		Emit-CommonFlags -el $props -indent $inner
		if ($props.tooltip) { Emit-MLText -tag "ToolTip" -text $props.tooltip -indent $inner }
		if ($props.tooltipRepresentation) { X "$inner<ToolTipRepresentation>$($props.tooltipRepresentation)</ToolTipRepresentation>" }
		$hl = Get-HLocation $props; if ($hl) { X "$inner<HorizontalLocation>$hl</HorizontalLocation>" }
		Emit-Layout -el $props -indent $inner
		Emit-Appearance -el $props -indent $inner -profile 'field'
	}
	Emit-Companion -tag "ContextMenu" -name "${addName}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${addName}РасширеннаяПодсказка" -indent $inner
}

# Кастомное дополнение (тип-элемент в commandBar): source дефолтит в текущую таблицу.
function Emit-Addition {
	param($el, [string]$name, [int]$id, [string]$typeKey, [string]$indent)
	$map = $script:additionTypeMap[$typeKey]
	$source = if ($el.source) { "$($el.source)" } elseif ($script:currentTableName) { $script:currentTableName } else { '' }
	X "$indent<$($map.Tag) name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	Emit-AdditionBody -props $el -source $source -srcType $map.Type -addName $name -indent $indent
	X "$indent</$($map.Tag)>"
}

# Стандартное табличное дополнение (авто-генерация на уровне таблицы). $override — объект отклонений
# из per-table карты additions (или $null = чистый дефолт).
function Emit-TableAddition {
	param([string]$typeKey, [string]$tableName, [string]$indent, $override = $null)
	$map = $script:additionTypeMap[$typeKey]
	$addName = "$tableName$($map.Suffix)"
	$id = New-Id
	X "$indent<$($map.Tag) name=`"$addName`" id=`"$id`">"
	Emit-AdditionBody -props $override -source $tableName -srcType $map.Type -addName $addName -indent $indent
	X "$indent</$($map.Tag)>"
}

# Прочитать override-объект для типа дополнения из per-table карты additions (с синонимами).
function Get-AdditionOverride {
	param($additions, [string]$typeKey)
	if ($null -eq $additions) { return $null }
	foreach ($k in @($typeKey) + $script:additionKeySynonyms[$typeKey]) {
		$p = $additions.PSObject.Properties[$k]
		if ($p) { return $p.Value }
	}
	return $null
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
		# Дополнения командной панели таблицы (тип-как-ключ) — forgiving: XML-тег/Type/рус.имя → канон
		"SearchStringAddition"       = "searchString"
		"SearchStringRepresentation" = "searchString"
		"строкаПоиска"               = "searchString"
		"отображениеСтрокиПоиска"    = "searchString"
		"Отображение строки поиска"  = "searchString"
		"ViewStatusAddition"         = "viewStatus"
		"ViewStatusRepresentation"   = "viewStatus"
		"состояниеПросмотра"         = "viewStatus"
		"Состояние просмотра"        = "viewStatus"
		"SearchControlAddition"      = "searchControl"
		"SearchControl"              = "searchControl"
		"управлениеПоиском"          = "searchControl"
		"Управление поиском"         = "searchControl"
		# Спец-поля (документ/датчик) — XML-имя/рус. → канон
		"SpreadSheetDocumentField"   = "spreadsheet"
		"ПолеТабличногоДокумента"    = "spreadsheet"
		"HTMLDocumentField"          = "html"
		"ПолеHTMLДокумента"          = "html"
		"TextDocumentField"          = "textDoc"
		"ПолеТекстовогоДокумента"    = "textDoc"
		"FormattedDocumentField"     = "formattedDoc"
		"ПолеФорматированногоДокумента" = "formattedDoc"
		"ProgressBarField"           = "progressBar"
		"ПолеИндикатора"             = "progressBar"
		"TrackBarField"              = "trackBar"
		"ПолеПолосыРегулирования"    = "trackBar"
		"ChartField"                 = "chart"
		"ПолеДиаграммы"              = "chart"
		"GanttChartField"            = "ganttChart"
		"ПолеДиаграммыГанта"         = "ganttChart"
		"GraphicalSchemaField"       = "graphicalSchema"
		"ПолеГрафическойСхемы"       = "graphicalSchema"
		"PlannerField"               = "planner"
		"ПолеПланировщика"           = "planner"
		"PeriodField"                = "periodField"
		"ПолеПериода"                = "periodField"
		"DendrogramField"            = "dendrogram"
		"ПолеДендрограммы"           = "dendrogram"
	}
	foreach ($pair in $synonyms.GetEnumerator()) {
		if ($null -ne $el.PSObject.Properties[$pair.Key] -and $null -eq $el.PSObject.Properties[$pair.Value]) {
			if ($strOnlyKeys -contains $pair.Key -and -not ($el.($pair.Key) -is [string])) { continue }
			$val = $el.($pair.Key)
			$el.PSObject.Properties.Remove($pair.Key) | Out-Null
			$el | Add-Member -NotePropertyName $pair.Value -NotePropertyValue $val -Force
		}
	}

	# Синонимы ключей-свойств (русские имена 1С → канон. англ.). Case/space-insensitive.
	# Канон побеждает: если задан и русский, и англ. ключ — англ. остаётся, русский отбрасываем.
	foreach ($pn in @($el.PSObject.Properties.Name)) {
		$norm = ($pn -replace '\s','').ToLower()
		$canon = $script:propSynonyms[$norm]
		if ($canon -and $pn -ne $canon) {
			if ($null -eq $el.PSObject.Properties[$canon]) {
				$val = $el.($pn)
				$el | Add-Member -NotePropertyName $canon -NotePropertyValue $val -Force
			}
			$el.PSObject.Properties.Remove($pn) | Out-Null
		}
	}

	# Determine element type from key
	$typeKey = $null
	$xmlTag = $null

	# picture/picField — НИЗКИЙ приоритет: 'picture' это и тип (PictureDecoration), и свойство-иконка
	# у popup/button/cmdBar. Тип-ключ владельца (popup/button/…) должен выиграть.
	# pages/page ПЕРЕД group: у Page/Pages ключ 'group' — это направление раскладки детей
	# (<Group>Horizontal</Group>), а не тип UsualGroup. Реальная UsualGroup ключа page/pages не несёт.
	foreach ($key in @("columnGroup","buttonGroup","pages","page","group","input","check","radio","label","labelField","table","button","calendar","cmdBar","popup","searchString","viewStatus","searchControl","picField","picture","spreadsheet","html","textDoc","formattedDoc","progressBar","trackBar","chart","ganttChart","graphicalSchema","planner","periodField","dendrogram")) {
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
		# спец-поля (документ/датчик/диаграмма) — тип-ключи + типоспец. скаляры
		"spreadsheet"=1;"html"=1;"textDoc"=1;"formattedDoc"=1;"progressBar"=1;"trackBar"=1
		"chart"=1;"ganttChart"=1;"graphicalSchema"=1;"planner"=1;"periodField"=1;"dendrogram"=1;"ganttTable"=1
		"showPercent"=1;"largeStep"=1;"markingStep"=1;"step"=1
		"horizontalScrollBar"=1;"viewScalingMode"=1;"output"=1;"selectionShowMode"=1;"protection"=1
		"edit"=1;"showGrid"=1;"showGroups"=1;"showHeaders"=1;"showRowAndColumnNames"=1;"showCellNames"=1
		"pointerType"=1;"drawingSelectionShowMode"=1;"warningOnEditRepresentation"=1;"markingAppearance"=1
		# report-form контекст (generic-скаляры элементов)
		"horizontalSpacing"=1;"representationInContextMenu"=1;"settingsNamedItemDetailedRepresentation"=1
		# хвост: высота элемента списка / ширина выпадающего списка / картинка кнопки выбора / прозрачный пиксель
		"itemHeight"=1;"dropListWidth"=1;"choiceButtonPicture"=1;"transparentPixel"=1
		# хвост CI-форм: динамический заголовок / расширенное редактирование / высота таблицы
		"titleDataPath"=1;"extendedEdit"=1;"maxRowsCount"=1;"autoMaxRowsCount"=1;"heightControlVariant"=1
		"warningOnEdit"=1;"nonselectedPictureText"=1;"editTextUpdate"=1;"footerText"=1
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
		"headerDataPath"=1;"headerFormat"=1;"currentRowUse"=1
		"format"=1;"editFormat"=1;"choiceParameters"=1;"choiceParameterLinks"=1;"typeLink"=1
		# label/hyperlink
		"hyperlink"=1;"formatted"=1
		# group-specific
		"collapsedTitle"=1;"showTitle"=1;"united"=1;"collapsed"=1;"behavior"=1
		# hierarchy
		"children"=1;"columns"=1
		# table-specific
		"changeRowSet"=1;"changeRowOrder"=1;"autoInsertNewRow"=1;"rowFilter"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"viewStatusLocation"=1;"searchControlLocation"=1
		"excludedCommands"=1
		"choiceMode"=1;"initialTreeView"=1;"enableDrag"=1;"enableStartDrag"=1
		"rowPictureDataPath"=1;"tableAutofill"=1;"heightInTableRows"=1
		"multipleChoice"=1;"searchOnInput"=1;"shortcut"=1
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
		"type"=1;"command"=1;"commandName"=1;"stdCommand"=1;"parameter"=1;"defaultButton"=1;"locationInCommandBar"=1;"displayImportance"=1
		# picture/decoration
		"src"=1;"valuesPicture"=1;"loadTransparent"=1;"headerPicture"=1;"footerPicture"=1
		# cmdBar-specific
		"autofill"=1
		# AutoCommandBar-маркер (autofill heuristic) на элементе/таблице
		"autoCmdBar"=1
		# дополнения командной панели таблицы (тип-ключи + свойства)
		"searchString"=1;"viewStatus"=1;"searchControl"=1;"source"=1;"horizontalLocation"=1;"additions"=1
		# generic-скаляры (pass-through) + точечные
		"verticalAlign"=1;"throughAlign"=1;"enableContentChange"=1;"pictureSize"=1;"titleHeight"=1
		"childItemsWidth"=1;"showLeftMargin"=1;"cellHyperlink"=1;"viewMode"=1;"verticalScrollBar"=1
		"rowInputMode"=1;"mask"=1;"createButton"=1;"fixingInTable"=1;"verticalSpacing"=1
		# InputField choice-скаляры
		"choiceListButton"=1;"quickChoice"=1;"autoChoiceIncomplete"=1
		"choiceForm"=1;"choiceHistoryOnInput"=1;"footerDataPath"=1;"minValue"=1;"maxValue"=1
		# Button — пометка toggle-кнопки (ключ 'checked', не 'check' — во избежание конфликта с типом)
		"checked"=1
	}
	# Оформление (цвета/шрифты/граница) — авто-регистрация из самих структур, чтобы allowlist
	# не дрейфовал при добавлении новых ключей/синонимов. Канонические + forgiving-синонимы.
	foreach ($k in $script:appearanceSpec.Keys)     { $knownKeys[$k] = 1 }
	foreach ($k in $script:appearanceSynonyms.Keys) { $knownKeys[$k] = 1 }
	foreach ($k in $script:propSynonyms.Keys)       { $knownKeys[$k] = 1 }
	foreach ($p in $el.PSObject.Properties) {
		if ($p.Name -like '_*') { continue }  # внутренние маркеры (напр. _dynList)
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored. Check SKILL.md for valid keys."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	Assert-UniqueName -name $name -seen $script:seenElementNames -kind 'element'
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
		"searchString"  { Emit-Addition -el $el -name $name -typeKey "searchString"  -id $id -indent $indent }
		"viewStatus"    { Emit-Addition -el $el -name $name -typeKey "viewStatus"    -id $id -indent $indent }
		"searchControl" { Emit-Addition -el $el -name $name -typeKey "searchControl" -id $id -indent $indent }
		"picField" { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar" { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"   { Emit-CommandBar -el $el -name $name -id $id -indent $indent }
		"popup"    { Emit-Popup -el $el -name $name -id $id -indent $indent }
		"spreadsheet"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "SpreadSheetDocumentField" -typeKey "spreadsheet" }
		"html"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "HTMLDocumentField" -typeKey "html" }
		"textDoc"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TextDocumentField" -typeKey "textDoc" }
		"formattedDoc" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "FormattedDocumentField" -typeKey "formattedDoc" }
		"progressBar"  { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ProgressBarField" -typeKey "progressBar" }
		"trackBar"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "TrackBarField" -typeKey "trackBar" }
		"chart"           { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "ChartField" -typeKey "chart" }
		"graphicalSchema" { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "GraphicalSchemaField" -typeKey "graphicalSchema" }
		"planner"         { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PlannerField" -typeKey "planner" }
		"periodField"     { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "PeriodField" -typeKey "periodField" }
		"dendrogram"      { Emit-SimpleField -el $el -name $name -id $id -indent $indent -xmlTag "DendrogramField" -typeKey "dendrogram" }
		"ganttChart"      { Emit-GanttChart -el $el -name $name -id $id -indent $indent }
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
			# Forgiving: принимаем имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role.".
			# Роль по GUID (заимствованная/расширение — name="<guid>" без префикса) эмитим как есть.
			$rname = "$($r.Name)" -replace '^(Role|Роль)\.', ''
			if ($rname -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $rname = "Role.$rname" }
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
# -skipHeight: подавить <Height> (зарезервирован; Table теперь эмитит <Height> generic-ом + свой <HeightInTableRows>).
# -multiLineDefault: input без явного autoMaxWidth при multiLine → AutoMaxWidth=false.
# Общие свойства элемента (любой тип, включая Button/cmdBar): default/skip/drag.
function Emit-CommonElementProps {
	param($el, [string]$indent)
	if ($el.defaultItem -eq $true) { X "$indent<DefaultItem>true</DefaultItem>" }
	if ($el.PSObject.Properties['skipOnInput'] -and $null -ne $el.skipOnInput) {
		$siv = if ($el.skipOnInput -eq $true) { 'true' } else { 'false' }
		X "$indent<SkipOnInput>$siv</SkipOnInput>"
	}
	# EnableStartDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
	if ($null -ne $el.enableStartDrag) { X "$indent<EnableStartDrag>$(if ($el.enableStartDrag){'true'}else{'false'})</EnableStartDrag>" }
	if ($el.fileDragMode) { X "$indent<FileDragMode>$($el.fileDragMode)</FileDragMode>" }
	# Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
	foreach ($p in @(@('showInHeader','ShowInHeader'), @('showInFooter','ShowInFooter'), @('autoCellHeight','AutoCellHeight'))) {
		if ($null -ne $el.($p[0])) { X "$indent<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Динамический заголовок колонки-группы из данных (HeaderDataPath) — перед HeaderHorizontalAlign (порядок XSD)
	if ($el.headerDataPath) { X "$indent<HeaderDataPath>$(Esc-Xml "$($el.headerDataPath)")</HeaderDataPath>" }
	if ($el.footerHorizontalAlign) { X "$indent<FooterHorizontalAlign>$($el.footerHorizontalAlign)</FooterHorizontalAlign>" }
	if ($el.headerHorizontalAlign) { X "$indent<HeaderHorizontalAlign>$($el.headerHorizontalAlign)</HeaderHorizontalAlign>" }
	# Формат заголовка колонки-группы (ML-текст) — после HeaderHorizontalAlign (порядок XSD)
	if ($el.headerFormat) { Emit-MLText -tag "HeaderFormat" -text $el.headerFormat -indent $indent }
}

# Картинка-ссылка с прозрачностью (HeaderPicture/FooterPicture/ValuesPicture/Page Picture).
# Платформа ВСЕГДА эмитит <xr:LoadTransparent> → пишем всегда (false по умолчанию).
# Значение: скаляр (Ref) ИЛИ объект {src, loadTransparent, transparentPixel}.
# src с префиксом "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
function Emit-PictureRef {
	param($val, [string]$picTag, [string]$indent)
	if (-not $val) { return }
	$src = $null; $lt = $false; $tpx = $null
	if ($val -is [string]) { $src = $val }
	else { $src = $val.src; if ($val.loadTransparent -eq $true) { $lt = $true }; $tpx = $val.transparentPixel }
	if (-not $src) { return }
	$srcStr = "$src"
	X "$indent<$picTag>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-Xml $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-Xml $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt) { 'true' } else { 'false' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</$picTag>"
}

# Картинки заголовка/подвала колонки поля — по схеме сразу после <EditMode>,
# перед тип-специфичными элементами и layout (порядок XDTO строгий именно здесь).
function Emit-ColumnPics {
	param($el, [string]$indent)
	Emit-PictureRef -val $el.headerPicture -picTag 'HeaderPicture' -indent $indent
	Emit-PictureRef -val $el.footerPicture -picTag 'FooterPicture' -indent $indent
}

# <Picture> кнопки/попапа/команды. Дефолт LoadTransparent=true, отклонение false
# (обратная конвенция относительно header/values-картинок). Прощающий ввод:
# принимает скаляр (Ref) ИЛИ объект {src, loadTransparent} — на случай если модель
# опишет картинку объектно по аналогии с headerPicture. $elemLt — legacy
# элемент-уровневый ключ loadTransparent (используется, если в объекте флаг не задан).
function Emit-CommandPicture {
	param($pic, $elemLt, [string]$indent)
	if (-not $pic) { return }
	$src = $null; $lt = $null; $tpx = $null
	if ($pic -is [string]) { $src = $pic }
	else { $src = $pic.src; if ($null -ne $pic.loadTransparent) { $lt = [bool]$pic.loadTransparent }; $tpx = $pic.transparentPixel }
	if (-not $src) { return }
	if ($null -eq $lt -and $null -ne $elemLt) { $lt = [bool]$elemLt }
	$srcStr = "$src"
	X "$indent<Picture>"
	if ($srcStr -match '^abs:(.*)$') { X "$indent`t<xr:Abs>$(Esc-Xml $matches[1])</xr:Abs>" }
	else { X "$indent`t<xr:Ref>$(Esc-Xml $srcStr)</xr:Ref>" }
	X "$indent`t<xr:LoadTransparent>$(if ($lt -eq $false) { 'false' } else { 'true' })</xr:LoadTransparent>"
	if ($tpx) { X "$indent`t<xr:TransparentPixel x=`"$($tpx.x)`" y=`"$($tpx.y)`"/>" }
	X "$indent</Picture>"
}

# --- Оформление элемента: цвета / шрифты / граница ---
# Прямые свойства элемента (<TextColor>/<Font>/<Border> + header/footer-варианты у полей).
# Ключи DSL — англ. camelCase 1:1 с тегами; принимаем рус. синонимы (forgiving).
# Значения: цвет — verbatim-строка (style:/web:/sys:/win:/#RRGGBB); шрифт — строка-ref или
# объект-атрибуты; граница — строка-ref или объект {width,style|ref}. Порядок тегов — XSD (профиль).
$script:appearanceSpec = @{
	titleTextColor  = @{ tag='TitleTextColor';  kind='color' }
	titleBackColor  = @{ tag='TitleBackColor';  kind='color' }
	titleFont       = @{ tag='TitleFont';       kind='font'  }
	footerTextColor = @{ tag='FooterTextColor'; kind='color' }
	footerBackColor = @{ tag='FooterBackColor'; kind='color' }
	footerFont      = @{ tag='FooterFont';      kind='font'  }
	textColor       = @{ tag='TextColor';       kind='color' }
	backColor       = @{ tag='BackColor';       kind='color' }
	borderColor     = @{ tag='BorderColor';     kind='color' }
	border          = @{ tag='Border';          kind='border'}
	font            = @{ tag='Font';            kind='font'  }
}
# Рус. синоним (lower) → canonical key
$script:appearanceSynonyms = @{
	'цветтекста'='textColor'; 'цветфона'='backColor'; 'цветрамки'='borderColor'
	'цветтекстазаголовка'='titleTextColor'; 'цветфоназаголовка'='titleBackColor'; 'шрифтзаголовка'='titleFont'
	'цветтекстаподвала'='footerTextColor'; 'цветфонаподвала'='footerBackColor'; 'шрифтподвала'='footerFont'
	'шрифт'='font'; 'рамка'='border'
}
# Синонимы ключей-свойств: русские имена свойств 1С (как в Конфигураторе) → канон. англ. ключ.
# Ключи карты нормализованы (lowercase, без пробелов); сопоставление в Normalize-PropSynonyms тоже.
# Прощающий ввод: модель может писать свойство по-русски. Англ. ключ работает всегда (это доп. слой).
# Видимость/Доступность НЕ включаем — наш hidden/disabled инвертирован, был бы баг семантики.
$script:propSynonyms = @{
	'пометка'='checked'
	'кнопкавыбора'='choiceButton'; 'кнопкаочистки'='clearButton'; 'кнопкарегулирования'='spinButton'
	'кнопкавыпадающегосписка'='dropListButton'; 'кнопкасписковоговыбора'='choiceListButton'
	'кнопкаоткрытия'='openButton'; 'кнопкапоумолчанию'='defaultButton'
	'быстрыйвыбор'='quickChoice'; 'формавыбора'='choiceForm'; 'историявыборапривводе'='choiceHistoryOnInput'
	'выборгруппиэлементов'='choiceFoldersAndItems'; 'фиксациявтаблице'='fixingInTable'
	'путькданнымподвала'='footerDataPath'; 'автоотметканезаполненного'='markIncomplete'
	'многострочныйрежим'='multiLine'; 'режимпароля'='passwordMode'; 'переноспословам'='wrap'
	'расположениезаголовка'='titleLocation'; 'пропускатьпривводе'='skipOnInput'
	'заголовок'='title'; 'ширина'='width'; 'высота'='height'; 'подсказкаввода'='inputHint'
}
# Профили порядка тегов по базовым типам (XSD-последовательность)
$script:appOrderField      = @('titleTextColor','titleBackColor','titleFont','footerTextColor','footerBackColor','footerFont','textColor','backColor','borderColor','border','font')
$script:appOrderDecoration = @('textColor','font','backColor','borderColor','border')
$script:appOrderButton     = @('textColor','backColor','borderColor','font')

# Простые скаляры элемента (pass-through: captured/emitted «как есть»). Только НЕ-перекрывающиеся
# теги (не обрабатываемые специфично где-то ещё). kind: bool → true/false; value → строка verbatim.
$script:genericScalars = @(
	@{ Tag='VerticalAlign';       Key='verticalAlign';       Kind='value' }
	@{ Tag='ThroughAlign';        Key='throughAlign';        Kind='value' }
	@{ Tag='EnableContentChange'; Key='enableContentChange'; Kind='bool'  }
	@{ Tag='PictureSize';         Key='pictureSize';         Kind='value' }
	@{ Tag='TitleHeight';         Key='titleHeight';         Kind='value' }
	@{ Tag='ChildItemsWidth';     Key='childItemsWidth';     Kind='value' }
	@{ Tag='ShowLeftMargin';      Key='showLeftMargin';      Kind='bool'  }
	@{ Tag='CellHyperlink';       Key='cellHyperlink';       Kind='bool'  }
	@{ Tag='ViewMode';            Key='viewMode';            Kind='value' }
	@{ Tag='VerticalScrollBar';   Key='verticalScrollBar';   Kind='value' }
	@{ Tag='RowInputMode';        Key='rowInputMode';        Kind='value' }
	@{ Tag='Mask';                Key='mask';                Kind='value' }
	@{ Tag='CreateButton';        Key='createButton';        Kind='bool'  }
	@{ Tag='FixingInTable';       Key='fixingInTable';       Kind='value' }
	@{ Tag='VerticalSpacing';     Key='verticalSpacing';     Kind='value' }
	# Спец-поля (документ/датчик) — типоспец. enum/bool скаляры pass-through
	@{ Tag='HorizontalScrollBar'; Key='horizontalScrollBar'; Kind='value' }
	@{ Tag='ViewScalingMode';     Key='viewScalingMode';     Kind='value' }
	@{ Tag='Output';              Key='output';              Kind='value' }
	@{ Tag='SelectionShowMode';   Key='selectionShowMode';   Kind='value' }
	@{ Tag='PointerType';         Key='pointerType';         Kind='value' }
	@{ Tag='DrawingSelectionShowMode'; Key='drawingSelectionShowMode'; Kind='value' }
	@{ Tag='WarningOnEditRepresentation'; Key='warningOnEditRepresentation'; Kind='value' }
	@{ Tag='MarkingAppearance';   Key='markingAppearance';   Kind='value' }
	@{ Tag='Protection';          Key='protection';          Kind='bool'  }
	@{ Tag='Edit';                Key='edit';                Kind='bool'  }
	@{ Tag='ShowGrid';            Key='showGrid';            Kind='bool'  }
	@{ Tag='ShowGroups';          Key='showGroups';          Kind='bool'  }
	@{ Tag='ShowHeaders';         Key='showHeaders';         Kind='bool'  }
	@{ Tag='ShowRowAndColumnNames'; Key='showRowAndColumnNames'; Kind='bool' }
	@{ Tag='ShowCellNames';       Key='showCellNames';       Kind='bool'  }
	@{ Tag='ShowPercent';         Key='showPercent';         Kind='bool'  }
	# Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
	@{ Tag='HorizontalSpacing';   Key='horizontalSpacing';   Kind='value' }
	@{ Tag='RepresentationInContextMenu'; Key='representationInContextMenu'; Kind='value' }
	@{ Tag='SettingsNamedItemDetailedRepresentation'; Key='settingsNamedItemDetailedRepresentation'; Kind='bool' }
	# Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
	@{ Tag='ItemHeight';          Key='itemHeight';          Kind='value' }
	@{ Tag='DropListWidth';       Key='dropListWidth';       Kind='value' }
	# Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
	@{ Tag='TitleDataPath';       Key='titleDataPath';       Kind='value' }
	@{ Tag='ExtendedEdit';        Key='extendedEdit';        Kind='bool'  }
	@{ Tag='MaxRowsCount';        Key='maxRowsCount';        Kind='value' }
	@{ Tag='AutoMaxRowsCount';    Key='autoMaxRowsCount';    Kind='bool'  }
	@{ Tag='HeightControlVariant'; Key='heightControlVariant'; Kind='value' }
	@{ Tag='EditTextUpdate';      Key='editTextUpdate';      Kind='value' }
	# Корпусный хвост: представление управления свёрткой группы / форма кнопки-попапа /
	# авто-добавление незаполненной строки / выделение отрицательных / нач. позиция списка /
	# высота списка выбора / три состояния флажка / прокрутка страницы при сжатии
	@{ Tag='ControlRepresentation'; Key='controlRepresentation'; Kind='value' }
	@{ Tag='ShapeRepresentation';   Key='shapeRepresentation';   Kind='value' }
	@{ Tag='AutoAddIncomplete';     Key='autoAddIncomplete';     Kind='bool'  }
	@{ Tag='MarkNegatives';         Key='markNegatives';         Kind='bool'  }
	@{ Tag='InitialListView';       Key='initialListView';       Kind='value' }
	@{ Tag='ChoiceListHeight';      Key='choiceListHeight';      Kind='value' }
	@{ Tag='ThreeState';            Key='threeState';            Kind='bool'  }
	@{ Tag='ScrollOnCompress';      Key='scrollOnCompress';      Kind='bool'  }
	# Сочетание клавиш — общее свойство (input/group/radio/page/picField/label/table/check; команда — отд. путь, §7)
	@{ Tag='Shortcut';              Key='shortcut';              Kind='value' }
	# Батч простых скаляров (input/radio/group/picDecoration/button): режим выбора незаполненного,
	# равная ширина колонок, выравнивание детей, масштаб/зум картинки, форма/положение картинки кнопки.
	# (Table HeaderHeight/FooterHeight/CurrentRowUse — НЕ здесь, а в Emit-Table: pass-through,
	#  1С толерантна к порядку детей Table — в корпусе те же теги встречаются в разных позициях.)
	@{ Tag='IncompleteChoiceMode';  Key='incompleteChoiceMode';  Kind='value' }
	@{ Tag='EqualColumnsWidth';     Key='equalColumnsWidth';     Kind='bool'  }
	@{ Tag='ChildrenAlign';         Key='childrenAlign';         Kind='value' }
	@{ Tag='ImageScale';            Key='imageScale';            Kind='value' }
	@{ Tag='Zoomable';              Key='zoomable';              Kind='bool'  }
	@{ Tag='Shape';                 Key='shape';                 Kind='value' }
	@{ Tag='PictureLocation';       Key='pictureLocation';       Kind='value' }
	# Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
	@{ Tag='EqualItemsWidth';       Key='equalItemsWidth';       Kind='bool'  }
	@{ Tag='ItemTitleHeight';       Key='itemTitleHeight';       Kind='value' }
	# Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
	@{ Tag='SpecialTextInputMode';  Key='specialTextInputMode';  Kind='value' }
	# Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
	@{ Tag='ItemWidth';                    Key='itemWidth';                    Kind='value' }
	@{ Tag='ShowCheckBoxesInDropList';     Key='showCheckBoxesInDropList';     Kind='bool'  }
	@{ Tag='MultipleValueDataPath';        Key='multipleValueDataPath';        Kind='value' }
	@{ Tag='MultipleValuePresentDataPath'; Key='multipleValuePresentDataPath'; Kind='value' }
	# Режим авто-показа кнопок открытия/очистки (input, enum Auto/Always/FilledOnly/…)
	@{ Tag='AutoShowOpenButtonMode';       Key='autoShowOpenButtonMode';       Kind='value' }
	@{ Tag='AutoShowClearButtonMode';      Key='autoShowClearButtonMode';      Kind='value' }
	# Оформление/картинка множественного выбора (input, редко; цвета — текст-контент, не атрибуты)
	@{ Tag='MultipleValuesTextColor';      Key='multipleValuesTextColor';      Kind='value' }
	@{ Tag='MultipleValuesBackColor';      Key='multipleValuesBackColor';      Kind='value' }
	@{ Tag='MultipleValuePictureShape';    Key='multipleValuePictureShape';    Kind='value' }
	@{ Tag='MultipleValuePictureDataPath'; Key='multipleValuePictureDataPath'; Kind='value' }
	# Хвост листовых скаляров (по 1 в корпусе): автокоррекция ввода (input) / уникальность команды
	# (button) / допуск пустого множ. значения (input) / поведение при гориз. сжатии (table)
	@{ Tag='AutoCorrectionOnTextInput';    Key='autoCorrectionOnTextInput';    Kind='value' }
	@{ Tag='SpellCheckingOnTextInput';     Key='spellCheckingOnTextInput';     Kind='value' }
	@{ Tag='CommandUniqueness';            Key='commandUniqueness';            Kind='bool'  }
	@{ Tag='AllowInputEmptyMultipleValues';Key='allowInputEmptyMultipleValues';Kind='bool'  }
	@{ Tag='BehaviorOnHorizontalCompression'; Key='behaviorOnHorizontalCompression'; Kind='value' }
)

function Emit-GenericScalars {
	param($el, [string]$indent)
	if ($null -eq $el) { return }
	foreach ($s in $script:genericScalars) {
		$p = $el.PSObject.Properties[$s.Key]
		if (-not $p -or $null -eq $p.Value) { continue }
		if ($s.Kind -eq 'bool') {
			X "$indent<$($s.Tag)>$(if ($p.Value){'true'}else{'false'})</$($s.Tag)>"
		} else {
			$v = "$($p.Value)"; if ($v -eq '') { continue }
			X "$indent<$($s.Tag)>$(Esc-Xml $v)</$($s.Tag)>"
		}
	}
}

function Get-AppearanceValue {
	param($el, [string]$canonical)
	if ($null -eq $el) { return $null }
	$p = $el.PSObject.Properties[$canonical]
	if ($p) { return $p.Value }
	foreach ($syn in $script:appearanceSynonyms.Keys) {
		if ($script:appearanceSynonyms[$syn] -eq $canonical) {
			$pp = $el.PSObject.Properties[$syn]
			if ($pp) { return $pp.Value }
		}
	}
	return $null
}

# <Font|TitleFont|FooterFont …> — строка = ref на стиль (kind=StyleItem); объект = атрибуты.
function Emit-FontTag {
	param([string]$tag, $val, [string]$indent)
	if ($val -is [string]) {
		X "$indent<$tag ref=`"$(Esc-Xml $val)`" kind=`"StyleItem`"/>"
		return
	}
	$attrs = @()
	foreach ($a in @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')) {
		$pp = $val.PSObject.Properties[$a]
		if ($pp -and $null -ne $pp.Value) {
			$v = $pp.Value
			if ($v -is [bool]) { $v = if ($v) {'true'} else {'false'} }
			$attrs += "$a=`"$(Esc-Xml "$v")`""
		}
	}
	X "$indent<$tag $($attrs -join ' ')/>"
}

# <Border> — строка/{ref} = из стиля (<Border ref="style:X"/>); {width,style} = явная.
function Emit-BorderTag {
	param($val, [string]$indent)
	if ($val -is [string]) { X "$indent<Border ref=`"$(Esc-Xml $val)`"/>"; return }
	$refP = $val.PSObject.Properties['ref']
	if ($refP -and $refP.Value) { X "$indent<Border ref=`"$(Esc-Xml "$($refP.Value)")`"/>"; return }
	$width = if ($val.PSObject.Properties['width'] -and $null -ne $val.width) { $val.width } else { 1 }
	$style = if ($val.PSObject.Properties['style']) { "$($val.style)" } else { $null }
	X "$indent<Border width=`"$width`">"
	if ($style) { X "$indent`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-Xml $style)</v8ui:style>" }
	X "$indent</Border>"
}

# ─────────────────────────────────────────────────────────────────────────────
# Planner design-time <Settings xsi:type="pl:Planner"> — встроенный конфиг планировщика
# на реквизите planner-типа. Структурный DSL: items[] + appearance/поведение-скаляры +
# timeScale (уровни шкалы времени) + period. Каждое присутствующее поле → каноничный
# порядок; пропущенное → дефолт (планировщик всегда несёт полный блок). Декомпилятор
# делает полный захват → раундтрип бит-в-бит; ручной авторинг может быть кратким.
$script:PLANNER_NS = 'http://v8.1c.ru/8.3/data/planner'
$script:CHART_NS   = 'http://v8.1c.ru/8.2/data/chart'

function PL-Get {
	param($o, [string]$k, $def = $null)
	if ($null -ne $o -and $o.PSObject.Properties[$k] -and $null -ne $o.$k) { return $o.$k }
	return $def
}
function PL-Bool {
	param($v)
	if ($v -is [bool]) { if ($v) { 'true' } else { 'false' } }
	elseif ("$v" -eq 'True') { 'true' }
	elseif ("$v" -eq 'False') { 'false' }
	else { "$v" }
}
function Emit-PlannerColor {
	param([string]$tag, $o, [string]$key, [string]$ind)
	X "$ind<pl:$tag>$(Esc-Xml "$(PL-Get $o $key 'auto')")</pl:$tag>"
}
# <pl:text>/<pl:tooltip>… — пустое → самозакрывающийся тег (как в выгрузке платформы).
function Emit-PlannerText {
	param([string]$tag, $v, [string]$ind)
	if ([string]::IsNullOrEmpty("$v")) { X "$ind<pl:$tag/>" }
	else { X "$ind<pl:$tag>$(Esc-Xml "$v")</pl:$tag>" }
}
# Признак ссылочного значения (объект разреза/элемент-ссылка) → xsi:type="xr:DesignTimeRef";
# иначе xs:string. Покрывает англ. (Enum.X.EnumValue.Y) и рус. (Справочник.X) метатипы.
function Test-PlannerRef {
	param([string]$v)
	return ($v -match '^(Enum|Catalog|Document|ChartOfAccounts|ChartOfCalculationTypes|ChartOfCharacteristicTypes|ExchangePlan|BusinessProcess|Task)\.' -or `
		$v -match '\.EnumValue\.' -or $v -match 'EmptyRef$' -or `
		$v -match '^(Перечисление|Справочник|Документ|ПланСчетов|ПланВидовХарактеристик|ПланВидовРасчета|ПланОбмена|БизнесПроцесс|Задача)\.')
}
# <pl:value> — nil (нет значения) / xr:DesignTimeRef (ссылка) / xs:string (строка/прочее).
function Emit-PlannerValue {
	param($v, [string]$ind)
	if ($null -eq $v -or "$v" -eq '') { X "$ind<pl:value xsi:nil=`"true`"/>"; return }
	$t = if (Test-PlannerRef "$v") { 'xr:DesignTimeRef' } else { 'xs:string' }
	X "$ind<pl:value xsi:type=`"$t`">$(Esc-Xml "$v")</pl:value>"
}
function Emit-PlannerFont {
	param($o, [string]$ind)
	$f = PL-Get $o 'font' $null
	if ($null -eq $f) { X "$ind<pl:font kind=`"AutoFont`"/>"; return }
	Emit-FontTag -tag 'pl:font' -val $f -indent $ind
}
function Emit-PlannerBorder {
	param($o, [string]$ind, [string]$key = 'border')
	$b = PL-Get $o $key $null
	$bw = if ($b) { PL-Get $b 'width' 1 } else { 1 }
	$bs = if ($b) { PL-Get $b 'style' 'Single' } else { 'Single' }
	X "$ind<pl:border width=`"$bw`">"
	X "$ind`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-Xml "$bs")</v8ui:style>"
	X "$ind</pl:border>"
}
function Emit-PlannerLevel {
	param($lv, [string]$cns, [string]$ind)
	$li = "$ind`t"
	X "$ind<level xmlns=`"$cns`">"
	X "$li<measure>$(Esc-Xml "$(PL-Get $lv 'measure' 'Hour')")</measure>"
	X "$li<interval>$(PL-Get $lv 'interval' 1)</interval>"
	X "$li<show>$(PL-Bool (PL-Get $lv 'show' $true))</show>"
	$line = PL-Get $lv 'line' $null
	$lw  = if ($line) { PL-Get $line 'width' 1 } else { 1 }
	$lg  = if ($line) { PL-Get $line 'gap' $false } else { $false }
	$lst = if ($line) { PL-Get $line 'style' 'Solid' } else { 'Solid' }
	X "$li<line width=`"$lw`" gap=`"$(PL-Bool $lg)`">"
	X "$li`t<v8ui:style xsi:type=`"v8ui:ChartLineType`">$(Esc-Xml "$lst")</v8ui:style>"
	X "$li</line>"
	X "$li<scaleColor>$(Esc-Xml "$(PL-Get $lv 'scaleColor' 'auto')")</scaleColor>"
	X "$li<dayFormatRule>$(Esc-Xml "$(PL-Get $lv 'dayFormatRule' 'MonthDayWeekDay')")</dayFormatRule>"
	$fmt = PL-Get $lv 'format' $null
	if ($null -eq $fmt) { $fmt = [ordered]@{ '#' = 'DF="HH:mm"'; 'ru' = 'DF="HH:mm"' } }
	X "$li<format>"
	Emit-MLItems -val $fmt -indent "$li`t"
	X "$li</format>"
	$labels = PL-Get $lv 'labels' $null
	$ticks  = if ($labels) { PL-Get $labels 'ticks' 0 } else { 0 }
	X "$li<labels>"
	X "$li`t<ticks>$ticks</ticks>"
	X "$li</labels>"
	X "$li<backColor>$(Esc-Xml "$(PL-Get $lv 'backColor' 'auto')")</backColor>"
	X "$li<textColor>$(Esc-Xml "$(PL-Get $lv 'textColor' 'auto')")</textColor>"
	X "$li<showPereodicalLabels>$(PL-Bool (PL-Get $lv 'showPereodicalLabels' $true))</showPereodicalLabels>"
	X "$ind</level>"
}
function Emit-PlannerTimeScale {
	param($ts, [string]$ind)
	$cns = $script:CHART_NS
	$ci = "$ind`t"
	X "$ind<pl:timeScale>"
	X "$ci<placement xmlns=`"$cns`">$(Esc-Xml "$(if ($ts) { PL-Get $ts 'placement' 'Left' } else { 'Left' })")</placement>"
	$levels = if ($ts) { @(PL-Get $ts 'levels' @()) } else { @() }
	if (@($levels).Count -eq 0) { $levels = @($null) }   # один уровень-дефолт
	foreach ($lv in $levels) { Emit-PlannerLevel $lv $cns $ci }
	$transp = if ($ts) { PL-Get $ts 'transparent' $false } else { $false }
	X "$ci<transparent xmlns=`"$cns`">$(PL-Bool $transp)</transparent>"
	X "$ci<backColor xmlns=`"$cns`">$(Esc-Xml "$(if ($ts) { PL-Get $ts 'backColor' 'auto' } else { 'auto' })")</backColor>"
	X "$ci<textColor xmlns=`"$cns`">$(Esc-Xml "$(if ($ts) { PL-Get $ts 'textColor' 'auto' } else { 'auto' })")</textColor>"
	X "$ci<currentLevel xmlns=`"$cns`">$(if ($ts) { PL-Get $ts 'currentLevel' 0 } else { 0 })</currentLevel>"
	X "$ind</pl:timeScale>"
}
function Emit-PlannerItem {
	param($it, [string]$ind)
	X "$ind<pl:item>"
	$ii = "$ind`t"
	Emit-PlannerValue (PL-Get $it 'value' $null) $ii
	Emit-PlannerText 'text' (PL-Get $it 'text' '') $ii
	Emit-PlannerText 'tooltip' (PL-Get $it 'tooltip' '') $ii
	X "$ii<pl:begin>$(PL-Get $it 'begin' '0001-01-01T00:00:00')</pl:begin>"
	X "$ii<pl:end>$(PL-Get $it 'end' '0001-01-01T00:00:00')</pl:end>"
	Emit-PlannerColor 'borderColor' $it 'borderColor' $ii
	Emit-PlannerColor 'backColor'   $it 'backColor'   $ii
	Emit-PlannerColor 'textColor'   $it 'textColor'   $ii
	Emit-PlannerFont $it $ii
	X "$ii<pl:dimensionValues/>"
	X "$ii<pl:replacementDate>$(PL-Get $it 'replacementDate' '0001-01-01T00:00:00')</pl:replacementDate>"
	X "$ii<pl:deleted>$(PL-Bool (PL-Get $it 'deleted' $false))</pl:deleted>"
	$id = PL-Get $it 'id' $null
	if ($null -eq $id) { $id = [guid]::NewGuid().ToString() }
	X "$ii<pl:id>$id</pl:id>"
	X "$ii<pl:textFormatted>$(PL-Bool (PL-Get $it 'textFormatted' $false))</pl:textFormatted>"
	Emit-PlannerBorder $it $ii 'border'
	X "$ii<pl:editMode>$(Esc-Xml "$(PL-Get $it 'editMode' 'EnableEdit')")</pl:editMode>"
	X "$ind</pl:item>"
}
# Элемент измерения (<pl:item> внутри <pl:dimension>) — рекурсивен: может нести вложенные
# элементы (UI: колонка «Элементы» у элемента). Порядок: value, text, цвета, font,
# вложенные элементы, showOnlySubordinatesAreas, textFormatted.
function Emit-PlannerDimElement {
	param($el, [string]$ind)
	X "$ind<pl:item>"
	$ii = "$ind`t"
	Emit-PlannerValue (PL-Get $el 'value' $null) $ii
	Emit-PlannerText 'text' (PL-Get $el 'text' '') $ii
	Emit-PlannerColor 'borderColor' $el 'borderColor' $ii
	Emit-PlannerColor 'backColor'   $el 'backColor'   $ii
	Emit-PlannerColor 'textColor'   $el 'textColor'   $ii
	Emit-PlannerFont $el $ii
	foreach ($sub in @(PL-Get $el 'elements' @())) { Emit-PlannerDimElement $sub $ii }
	X "$ii<pl:showOnlySubordinatesAreas>$(PL-Bool (PL-Get $el 'showOnlySubordinatesAreas' $true))</pl:showOnlySubordinatesAreas>"
	X "$ii<pl:textFormatted>$(PL-Bool (PL-Get $el 'textFormatted' $false))</pl:textFormatted>"
	X "$ind</pl:item>"
}
# Измерение планировщика (<pl:dimension>) — объект разреза + его элементы.
function Emit-PlannerDimension {
	param($d, [string]$ind)
	X "$ind<pl:dimension>"
	$di = "$ind`t"
	Emit-PlannerValue (PL-Get $d 'value' $null) $di
	Emit-PlannerText 'text' (PL-Get $d 'text' '') $di
	Emit-PlannerColor 'borderColor' $d 'borderColor' $di
	Emit-PlannerColor 'backColor'   $d 'backColor'   $di
	Emit-PlannerColor 'textColor'   $d 'textColor'   $di
	Emit-PlannerFont $d $di
	foreach ($el in @(PL-Get $d 'elements' @())) { Emit-PlannerDimElement $el $di }
	X "$di<pl:textFormatted>$(PL-Bool (PL-Get $d 'textFormatted' $false))</pl:textFormatted>"
	X "$ind</pl:dimension>"
}
function Emit-PlannerSettings {
	param($pl, [string]$ind)
	X "$ind<Settings xmlns:pl=`"$($script:PLANNER_NS)`" xsi:type=`"pl:Planner`">"
	$si = "$ind`t"
	foreach ($it in @(PL-Get $pl 'items' @())) { Emit-PlannerItem $it $si }
	foreach ($d in @(PL-Get $pl 'dimensions' @())) { Emit-PlannerDimension $d $si }
	Emit-PlannerColor 'borderColor' $pl 'borderColor' $si
	Emit-PlannerColor 'backColor'   $pl 'backColor'   $si
	Emit-PlannerColor 'textColor'   $pl 'textColor'   $si
	Emit-PlannerColor 'lineColor'   $pl 'lineColor'   $si
	Emit-PlannerFont $pl $si
	X "$si<pl:beginOfRepresentationPeriod>$(PL-Get $pl 'beginOfRepresentationPeriod' '0001-01-01T00:00:00')</pl:beginOfRepresentationPeriod>"
	X "$si<pl:endOfRepresentationPeriod>$(PL-Get $pl 'endOfRepresentationPeriod' '0001-01-01T00:00:00')</pl:endOfRepresentationPeriod>"
	X "$si<pl:alignElementsOfTimeScale>$(PL-Bool (PL-Get $pl 'alignElementsOfTimeScale' $true))</pl:alignElementsOfTimeScale>"
	X "$si<pl:displayTimeScaleWrapHeaders>$(PL-Bool (PL-Get $pl 'displayTimeScaleWrapHeaders' $true))</pl:displayTimeScaleWrapHeaders>"
	X "$si<pl:displayWrapHeaders>$(PL-Bool (PL-Get $pl 'displayWrapHeaders' $true))</pl:displayWrapHeaders>"
	$wfmt = PL-Get $pl 'timeScaleWrapHeadersFormat' $null
	if ($null -eq $wfmt) { $wfmt = [ordered]@{ '#' = 'DLF="DD"'; 'ru' = 'DLF="DD"' } }
	Emit-MLText -tag 'pl:timeScaleWrapHeadersFormat' -text $wfmt -indent $si
	X "$si<pl:periodicVariantUnit>$(Esc-Xml "$(PL-Get $pl 'periodicVariantUnit' 'Day')")</pl:periodicVariantUnit>"
	X "$si<pl:periodicVariantRepetition>$(PL-Get $pl 'periodicVariantRepetition' 1)</pl:periodicVariantRepetition>"
	X "$si<pl:timeScaleWrapBeginIndent>$(PL-Get $pl 'timeScaleWrapBeginIndent' 0)</pl:timeScaleWrapBeginIndent>"
	X "$si<pl:timeScaleWrapEndIndent>$(PL-Get $pl 'timeScaleWrapEndIndent' 0)</pl:timeScaleWrapEndIndent>"
	Emit-PlannerTimeScale (PL-Get $pl 'timeScale' $null) $si
	$period = PL-Get $pl 'period' $null
	if ($period) {
		X "$si<pl:period>"
		X "$si`t<pl:begin>$(PL-Get $period 'begin' '0001-01-01T00:00:00')</pl:begin>"
		X "$si`t<pl:end>$(PL-Get $period 'end' '0001-01-01T00:00:00')</pl:end>"
		X "$si</pl:period>"
	}
	X "$si<pl:displayCurrentDate>$(PL-Bool (PL-Get $pl 'displayCurrentDate' $true))</pl:displayCurrentDate>"
	X "$si<pl:itemsTimeRepresentation>$(Esc-Xml "$(PL-Get $pl 'itemsTimeRepresentation' 'BeginTime')")</pl:itemsTimeRepresentation>"
	X "$si<pl:itemsBehaviorWhenSpaceInsufficient>$(Esc-Xml "$(PL-Get $pl 'itemsBehaviorWhenSpaceInsufficient' 'CollapseItems')")</pl:itemsBehaviorWhenSpaceInsufficient>"
	X "$si<pl:autoMinColumnWidth>$(PL-Bool (PL-Get $pl 'autoMinColumnWidth' $true))</pl:autoMinColumnWidth>"
	X "$si<pl:autoMinRowHeight>$(PL-Bool (PL-Get $pl 'autoMinRowHeight' $true))</pl:autoMinRowHeight>"
	X "$si<pl:minColumnWidth>$(PL-Get $pl 'minColumnWidth' 0)</pl:minColumnWidth>"
	X "$si<pl:minRowHeight>$(PL-Get $pl 'minRowHeight' 0)</pl:minRowHeight>"
	X "$si<pl:fixDimensionsHeader>$(Esc-Xml "$(PL-Get $pl 'fixDimensionsHeader' 'auto')")</pl:fixDimensionsHeader>"
	X "$si<pl:fixTimeScaleHeader>$(Esc-Xml "$(PL-Get $pl 'fixTimeScaleHeader' 'auto')")</pl:fixTimeScaleHeader>"
	Emit-PlannerBorder $pl $si 'border'
	X "$si<pl:newItemsTextType>$(Esc-Xml "$(PL-Get $pl 'newItemsTextType' 'String')")</pl:newItemsTextType>"
	X "$ind</Settings>"
}

# ─────────────────────────────────────────────────────────────────────────────
# Chart design-time <Settings xsi:type="d4p1:Chart"> — генерик-эмиттер (зеркало
# Build-ChartNode декомпилятора). Тип узла → форма XML: ML-поля (по имени), серии
# (массив, повтор тега), line/border/font (по ключам), attrs-узлы (gaugeQualityBands),
# иначе вложенный объект/скаляр. Порядок ключей = порядок эмиссии (раундтрип).
$script:CHART_ML_FIELDS = @{ 'title'=1;'lbFormat'=1;'lbpFormat'=1;'vsFormat'=1;'dtFormat'=1;'dataSourceDescription'=1;'labelFormat'=1;'text'=1 }
$script:CHART_ATTR_FIELDS = @{ 'gaugeQualityBands'=1 }
$script:CHART_FONT_KEYS = @('ref','faceName','height','bold','italic','underline','strikeout','kind','scale')
function Get-Keys { param($o) if ($o -is [System.Collections.IDictionary]) { return @($o.Keys) } else { return @($o.PSObject.Properties.Name) } }
function Get-Prop { param($o, [string]$k) if ($o -is [System.Collections.IDictionary]) { return $o[$k] } else { $p = $o.PSObject.Properties[$k]; if ($p) { return $p.Value } else { return $null } } }
function Emit-ChartNode {
	param([string]$name, $val, [string]$ind)
	if ($script:CHART_ML_FIELDS.Contains($name)) {
		if ($null -eq $val -or "$val" -eq '') { X "$ind<d4p1:$name/>"; return }
		X "$ind<d4p1:$name>"; Emit-MLItems -val $val -indent "$ind`t"; X "$ind</d4p1:$name>"; return
	}
	if (($val -is [System.Collections.IList]) -and ($val -isnot [string])) {
		foreach ($e in $val) { Emit-ChartNode $name $e $ind }
		return
	}
	if (($val -is [System.Management.Automation.PSCustomObject]) -or ($val -is [System.Collections.IDictionary])) {
		$keys = Get-Keys $val
		if ($script:CHART_ATTR_FIELDS.Contains($name)) {
			$attrs = @(); foreach ($k in $keys) { $v = Get-Prop $val $k; if ($v -is [bool]) { $v = PL-Bool $v }; $attrs += "$k=`"$(Esc-Xml "$v")`"" }
			X "$ind<d4p1:$name $($attrs -join ' ')/>"; return
		}
		if ($keys -contains 'gap') {
			$w = Get-Prop $val 'width'; $g = Get-Prop $val 'gap'; $st = Get-Prop $val 'style'
			X "$ind<d4p1:$name width=`"$w`" gap=`"$(PL-Bool $g)`">"
			X "$ind`t<v8ui:style xsi:type=`"v8ui:ChartLineType`">$(Esc-Xml "$st")</v8ui:style>"
			X "$ind</d4p1:$name>"; return
		}
		if (($keys -contains 'style') -and ($keys -contains 'width')) {
			$w = Get-Prop $val 'width'; $st = Get-Prop $val 'style'
			X "$ind<d4p1:$name width=`"$w`">"
			X "$ind`t<v8ui:style xsi:type=`"v8ui:ControlBorderType`">$(Esc-Xml "$st")</v8ui:style>"
			X "$ind</d4p1:$name>"; return
		}
		$isFont = $false; foreach ($fk in $script:CHART_FONT_KEYS) { if ($keys -contains $fk) { $isFont = $true; break } }
		if ($isFont) {
			$attrs = @(); foreach ($fk in $script:CHART_FONT_KEYS) { if ($keys -contains $fk) { $v = Get-Prop $val $fk; if ($v -is [bool]) { $v = PL-Bool $v }; $attrs += "$fk=`"$(Esc-Xml "$v")`"" } }
			X "$ind<d4p1:$name $($attrs -join ' ')/>"; return
		}
		if (@($keys).Count -eq 0) { X "$ind<d4p1:$name/>"; return }
		X "$ind<d4p1:$name>"
		foreach ($k in $keys) { Emit-ChartNode $k (Get-Prop $val $k) "$ind`t" }
		X "$ind</d4p1:$name>"
		return
	}
	if ($null -eq $val -or "$val" -eq '') { X "$ind<d4p1:$name/>"; return }
	if ($val -is [bool]) { X "$ind<d4p1:$name>$(PL-Bool $val)</d4p1:$name>"; return }
	X "$ind<d4p1:$name>$(Esc-Xml "$val")</d4p1:$name>"
}
function Emit-ChartSettings {
	param($chart, [string]$ind, [string]$ctype = 'd4p1:Chart')
	X "$ind<Settings xmlns:d4p1=`"$($script:CHART_NS)`" xsi:type=`"$ctype`">"
	foreach ($k in (Get-Keys $chart)) { Emit-ChartNode $k (Get-Prop $chart $k) "$ind`t" }
	X "$ind</Settings>"
}

function Emit-Appearance {
	param($el, [string]$indent, [string]$profile = 'field')
	if ($null -eq $el) { return }
	$order = switch ($profile) {
		'decoration' { $script:appOrderDecoration }
		'button'     { $script:appOrderButton }
		default      { $script:appOrderField }
	}
	foreach ($key in $order) {
		$val = Get-AppearanceValue -el $el -canonical $key
		if ($null -eq $val -or ($val -is [string] -and $val -eq '')) { continue }
		$spec = $script:appearanceSpec[$key]
		switch ($spec.kind) {
			'color'  { X "$indent<$($spec.tag)>$(Esc-Xml "$val")</$($spec.tag)>" }
			'font'   { Emit-FontTag -tag $spec.tag -val $val -indent $indent }
			'border' { Emit-BorderTag -val $val -indent $indent }
		}
	}
}

function Emit-Layout {
	param($el, [string]$indent, [switch]$skipHeight, [bool]$multiLineDefault = $false)
	# CommandSet (отключённые команды редактора) — общее свойство поля (input/label/check/
	# spreadsheet/html/formatted/picture); в схеме рано (после TitleLocation, перед скалярами).
	if ($el.excludedCommands -and @($el.excludedCommands).Count -gt 0) {
		X "$indent<CommandSet>"
		foreach ($cmd in $el.excludedCommands) { X "$indent`t<ExcludedCommand>$cmd</ExcludedCommand>" }
		X "$indent</CommandSet>"
	}
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
	Emit-GenericScalars -el $el -indent $indent
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

function Warn-Unrecognized {
	# drop-on-miss enum: значение не распознано → тег не эмитится. Громко, чтобы автор увидел потерю.
	param([string]$key, $raw, [string[]]$valid, [string]$owner)
	Write-Warning "Unrecognized $key '$raw' on '$owner'. Valid values: $($valid -join ', '). Value ignored."
}

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<UsualGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	# Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
	$groupVal = "$($el.group)".ToLower()
	$orientation = switch ($groupVal) {
		"horizontal"       { "Horizontal" }
		"vertical"         { "Vertical" }
		"alwayshorizontal" { "AlwaysHorizontal" }
		"alwaysvertical"   { "AlwaysVertical" }
		"horizontalifpossible" { "HorizontalIfPossible" }
		"collapsible"      { "Vertical" }
		default            { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	elseif ($groupVal) { Warn-Unrecognized 'group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }

	# Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
	# Legacy: group:'collapsible' эквивалентно behavior:'collapsible'.
	$behaviorVal = if ($el.behavior) { "$($el.behavior)".ToLower() } elseif ($groupVal -eq "collapsible") { "collapsible" } else { $null }
	$bmap = @{ "usual"="Usual"; "collapsible"="Collapsible"; "popup"="PopUp" }
	if ($behaviorVal -and $bmap.ContainsKey($behaviorVal)) {
		X "$inner<Behavior>$($bmap[$behaviorVal])</Behavior>"
	} elseif ($el.behavior -and -not $bmap.ContainsKey($behaviorVal)) {
		Warn-Unrecognized 'behavior' $el.behavior @('collapsible','popup') $name
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

	# Использование текущей строки группы (после Representation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	# ShowTitle
	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# Заголовок свёрнутого представления (collapsible/popup) — мультиязычный текст
	if ($el.collapsedTitle) { Emit-MLText -tag "CollapsedRepresentationTitle" -text $el.collapsedTitle -indent $inner }

	# United
	if ($el.united -eq $false) { X "$inner<United>false</United>" }

	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	X "$indent<ColumnGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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
	elseif ($groupVal) { Warn-Unrecognized 'columnGroup orientation' $el.columnGroup @('vertical','horizontal','inCell') $name }

	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# showInHeader эмитится общим Emit-CommonElementProps (через Emit-Layout)

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Картинка заголовка колонки-группы (после ShowInHeader/Layout, перед оформлением — порядок XSD)
	Emit-ColumnPics -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	X "$indent<InputField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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

	if ($null -ne $el.multiLine) { X "$inner<MultiLine>$(if ($el.multiLine){'true'}else{'false'})</MultiLine>" }
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	# ChoiceButton — захват «как есть» (платформа эмитит явное значение; ref-поля выводят сама,
	# декомпилятор фиксирует факт. значение). Нет ключа → не эмитим (не додумываем по событию).
	if ($null -ne $el.choiceButton) { X "$inner<ChoiceButton>$(if ($el.choiceButton){'true'}else{'false'})</ChoiceButton>" }
	# Кнопки поля ввода — захват «как есть» (платформа эмитит явное значение, в т.ч. false)
	if ($null -ne $el.clearButton)    { X "$inner<ClearButton>$(if ($el.clearButton){'true'}else{'false'})</ClearButton>" }
	if ($null -ne $el.spinButton)     { X "$inner<SpinButton>$(if ($el.spinButton){'true'}else{'false'})</SpinButton>" }
	if ($null -ne $el.dropListButton) { X "$inner<DropListButton>$(if ($el.dropListButton){'true'}else{'false'})</DropListButton>" }
	if ($null -ne $el.choiceListButton) { X "$inner<ChoiceListButton>$(if ($el.choiceListButton){'true'}else{'false'})</ChoiceListButton>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.textEdit -eq $false) { X "$inner<TextEdit>false</TextEdit>" }
	# InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
	foreach ($p in @(
		@('wrap','Wrap'), @('openButton','OpenButton'), @('listChoiceMode','ListChoiceMode'),
		@('extendedEditMultipleValues','ExtendedEditMultipleValues'), @('chooseType','ChooseType'),
		@('quickChoice','QuickChoice'), @('autoChoiceIncomplete','AutoChoiceIncomplete')
	)) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$(if ($el.($p[0])){'true'}else{'false'})</$($p[1])>" }
	}
	# Ограничение доступных типов (поле на составном типе): домен типов + явный набор.
	# availableTypes — формат типа реквизита (§type); Emit-Type сам разбирает мультитип "a | b".
	if ($null -ne $el.typeDomainEnabled) { X "$inner<TypeDomainEnabled>$(if ($el.typeDomainEnabled){'true'}else{'false'})</TypeDomainEnabled>" }
	if ($el.availableTypes) { Emit-Type -typeStr $el.availableTypes -indent $inner -tag 'AvailableTypes' }
	# InputField-специфичные value-скаляры
	foreach ($p in @(
		@('choiceForm','ChoiceForm'), @('choiceHistoryOnInput','ChoiceHistoryOnInput'),
		@('choiceFoldersAndItems','ChoiceFoldersAndItems'), @('footerDataPath','FooterDataPath')
	)) {
		if ($el.($p[0])) { X "$inner<$($p[1])>$(Esc-Xml "$($el.($p[0]))")</$($p[1])>" }
	}
	# MinValue/MaxValue — типизированное. JSON-число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'))) {
		if ($null -ne $el.($p[0])) {
			$mvt = if ($el.($p[0]) -is [string]) { 'xs:string' } else { 'xs:decimal' }
			X "$inner<$($p[1]) xsi:type=`"$mvt`">$(Esc-Xml "$($el.($p[0]))")</$($p[1])>"
		}
	}
	if ($el.choiceButtonRepresentation) { X "$inner<ChoiceButtonRepresentation>$($el.choiceButtonRepresentation)</ChoiceButtonRepresentation>" }
	Emit-PictureRef -val $el.choiceButtonPicture -picTag 'ChoiceButtonPicture' -indent $inner
	Emit-Layout -el $el -indent $inner -multiLineDefault ([bool]($el.multiLine -eq $true))

	if ($el.inputHint) {
		Emit-MLText -tag "InputHint" -text $el.inputHint -indent $inner
	}
	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	Emit-ChoiceList -el $el -indent $inner

	# Связи по типу / связи параметров выбора / параметры выбора
	Emit-TypeLink -el $el -indent $inner
	Emit-ChoiceParameterLinks -el $el -indent $inner
	Emit-ChoiceParameters -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "input"

	X "$indent</InputField>"
}

function Emit-Check {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CheckBoxField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
	if ($null -ne $el.PSObject.Properties['checkBoxType']) {
		if ($el.checkBoxType) {
			$cbt = switch ("$($el.checkBoxType)".ToLower()) { 'auto' {'Auto'} 'checkbox' {'CheckBox'} 'switcher' {'Switcher'} 'tumbler' {'Tumbler'} default {"$($el.checkBoxType)"} }
			X "$inner<CheckBoxType>$cbt</CheckBoxType>"
		}
	} else { X "$inner<CheckBoxType>Auto</CheckBoxType>" }

	Emit-TitleLocation -el $el -indent $inner -smartDefault "Right"

	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-Xml "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	# ISO datetime ("2020-01-01T00:00:00") → xs:dateTime
	if ($s -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') {
		return @{ XsiType = "xs:dateTime"; Text = $s }
	}

	# Raw-ссылка по GUID (метаданные.значение, оба GUID): "GUID.GUID" → xr:DesignTimeRef
	# (всегда ссылка, не строка; named-ссылки Enum.X.Y детектятся ниже).
	if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F]{8}-[0-9a-fA-F-]+$') {
		return @{ XsiType = "xr:DesignTimeRef"; Text = $s }
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
					# "Enum.X.Y" — insert .EnumValue. ("EmptyRef" — пустая ссылка, БЕЗ вставки)
					if ($parts[2] -eq 'EmptyRef') { $normalized = "Enum.$typeName.EmptyRef" }
					else { $normalized = "Enum.$typeName.EnumValue.$($parts[2])" }
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

# <Value> для choiceList/choiceParameters: пустой текст → самозакрывающийся тег (зеркало платформы).
function Get-ChoiceValueTag {
	param($norm)
	if ([string]::IsNullOrEmpty($norm.Text)) { return "<Value xsi:type=`"$($norm.XsiType)`"/>" }
	return "<Value xsi:type=`"$($norm.XsiType)`">$(Esc-Xml $norm.Text)</Value>"
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

		# valueType: явный xsi:type значения (системное перечисление ent:*, иной не-примитив) —
		# переопределяет авто-детект (Normalize-ChoiceValue вывела бы xs:string).
		$vtRaw = $null
		if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
			if ($item.Contains("valueType")) { $vtRaw = "$($item["valueType"])" }
		} elseif ($item.PSObject.Properties["valueType"]) { $vtRaw = "$($item.valueType)" }

		if ($vtRaw -eq 'nil') { $norm = @{ XsiType = $null; Text = $null; Nil = $true } }
		elseif ($vtRaw) { $norm = @{ XsiType = $vtRaw; Text = "$valRaw" } }
		else { $norm = Normalize-ChoiceValue -value $valRaw }

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
		X "$valIndent`t$(if ($norm.Nil) { '<Value xsi:nil="true"/>' } else { Get-ChoiceValueTag $norm })"
		X "$valIndent</xr:Value>"
		X "$itemIndent</xr:Item>"
	}
	X "$indent</ChoiceList>"
}

# Чтение свойства из hashtable/PSCustomObject по списку синонимов (первый найденный, иначе $null).
function Get-ElProp {
	param($obj, [string[]]$names)
	if ($null -eq $obj) { return $null }
	foreach ($n in $names) {
		if ($obj -is [System.Collections.IDictionary]) {
			if ($obj.Contains($n)) { return $obj[$n] }
		} elseif ($obj.PSObject -and $obj.PSObject.Properties[$n]) {
			return $obj.PSObject.Properties[$n].Value
		}
	}
	return $null
}

# Приведение строкового литерала shorthand к типу: true/false → bool, целое/дробное → число,
# иначе строка (ref-путь нормализует уже Normalize-ChoiceValue).
function ConvertTo-ScalarLiteral {
	param([string]$s)
	$t = "$s".Trim()
	if ($t -match '^(?i:true)$')  { return $true }
	if ($t -match '^(?i:false)$') { return $false }
	if ($t -match '^-?\d+$')       { return [int]$t }
	if ($t -match '^-?\d+\.\d+$')  { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) }
	return $t
}

# Shorthand параметра выбора: "name=value" либо "name=v1, v2, …" (запятые → массив). → {name, value}.
function ConvertFrom-ChoiceParamShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$name = $s.Substring(0, $eq).Trim()
	$rest = $s.Substring($eq + 1)
	if ($rest -match ',') {
		$vals = @()
		foreach ($part in ($rest -split ',')) { $vals += ,(ConvertTo-ScalarLiteral $part) }
		return @{ name = $name; value = $vals }
	}
	return @{ name = $name; value = (ConvertTo-ScalarLiteral $rest) }
}

# Shorthand связи параметров выбора: "name=dataPath" либо "name=dataPath:DontChange". → {name, dataPath, valueChange?}.
function ConvertFrom-ChoiceParamLinkShorthand {
	param([string]$s)
	$eq = $s.IndexOf('=')
	if ($eq -lt 0) { return @{ name = $s.Trim() } }
	$o = @{ name = $s.Substring(0, $eq).Trim() }
	$rest = $s.Substring($eq + 1).Trim()
	if ($rest -match '^(.*):(?i:(Clear|DontChange|очистить|неизменять))$') {
		$o['dataPath'] = $matches[1].Trim(); $o['valueChange'] = $matches[2]
	} else {
		$o['dataPath'] = $rest
	}
	return $o
}

# Shorthand связи по типу: "dataPath" либо "dataPath#linkItem". → {dataPath, linkItem}.
function ConvertFrom-TypeLinkShorthand {
	param([string]$s)
	if ($s -match '^(.*)#(\d+)$') { return @{ dataPath = $matches[1].Trim(); linkItem = [int]$matches[2] } }
	return @{ dataPath = "$s".Trim() }
}

# Внутреннее значение параметра выбора (FormChoiceListDesTimeValue): <Presentation/> + <Value>.
# Скаляр → один Value (через Normalize-ChoiceValue); массив → v8:FixedArray из вложенных FormChoiceListDesTimeValue.
function Emit-ChoiceParamValue {
	# $isArray передаётся ЯВНО из вызывающего кода: PowerShell разворачивает одноэлементный массив
	# при биндинге параметра ($value становится скаляром), поэтому определять массив тут — ненадёжно
	# (1-элементный список `["X"]` эмитился бы скаляром вместо FixedArray). foreach по скаляру = 1 итерация.
	param($value, [string]$indent, [bool]$isArray)
	X "$indent<Presentation/>"
	if ($isArray) {
		X "$indent<Value xsi:type=`"v8:FixedArray`">"
		foreach ($v in $value) {
			$norm = Normalize-ChoiceValue -value $v
			X "$indent`t<v8:Value xsi:type=`"FormChoiceListDesTimeValue`">"
			X "$indent`t`t<Presentation/>"
			X "$indent`t`t$(Get-ChoiceValueTag $norm)"
			X "$indent`t</v8:Value>"
		}
		X "$indent</Value>"
	} else {
		$norm = Normalize-ChoiceValue -value $value
		X "$indent$(Get-ChoiceValueTag $norm)"
	}
}

# <ChoiceParameters> (параметры выбора поля ввода) — [{name, value}]. value через Normalize-ChoiceValue;
# массив значений → FixedArray. Рус. синонимы имя/значение.
function Emit-ChoiceParameters {
	param($el, [string]$indent)
	$cp = $el.choiceParameters
	if (-not $cp -or @($cp).Count -eq 0) { return }
	X "$indent<ChoiceParameters>"
	foreach ($item in @($cp)) {
		if ($item -is [string]) { $item = ConvertFrom-ChoiceParamShorthand $item }
		$name = Get-ElProp $item @('name','имя')
		# Наличие ключа value (≠ значения) + ПРЯМОЙ доступ к значению (без Get-ElProp): его return
		# разворачивает 1-элементный массив (PS unwrap), теряя массив-ность → FixedArray не эмитится.
		# Индексер/member-доступ массив сохраняет; if-выражение/функция-return — нет.
		$hasVal = $false; $val = $null
		if ($item -is [System.Collections.IDictionary]) {
			if ($item.Contains('value')) { $hasVal = $true; $val = $item['value'] }
			elseif ($item.Contains('значение')) { $hasVal = $true; $val = $item['значение'] }
		} else {
			if ($item.PSObject.Properties['value']) { $hasVal = $true; $val = $item.PSObject.Properties['value'].Value }
			elseif ($item.PSObject.Properties['значение']) { $hasVal = $true; $val = $item.PSObject.Properties['значение'].Value }
		}
		$valIsArray = ($val -is [System.Array]) -or ($val -is [System.Collections.IList] -and $val -isnot [string])
		X "$indent`t<app:item name=`"$(Esc-Xml "$name")`">"
		# Параметр выбора без значения → <app:value xsi:nil="true"/> (платформа, 13 в корпусе);
		# со значением (в т.ч. пустой строкой) → FormChoiceListDesTimeValue.
		if (-not $hasVal) {
			X "$indent`t`t<app:value xsi:nil=`"true`"/>"
		} else {
			X "$indent`t`t<app:value xsi:type=`"FormChoiceListDesTimeValue`">"
			Emit-ChoiceParamValue -value $val -indent "$indent`t`t`t" -isArray $valIsArray
			X "$indent`t`t</app:value>"
		}
		X "$indent`t</app:item>"
	}
	X "$indent</ChoiceParameters>"
}

# <ChoiceParameterLinks> (связи параметров выбора) — [{name, dataPath, valueChange?}].
# valueChange всегда эмитится, дефолт Clear; forgiving Clear/DontChange + рус. синонимы.
function Emit-ChoiceParameterLinks {
	param($el, [string]$indent)
	$cpl = $el.choiceParameterLinks
	if (-not $cpl -or @($cpl).Count -eq 0) { return }
	X "$indent<ChoiceParameterLinks>"
	foreach ($lk in @($cpl)) {
		if ($lk -is [string]) { $lk = ConvertFrom-ChoiceParamLinkShorthand $lk }
		$name = Get-ElProp $lk @('name','имя')
		$dp = Get-ElProp $lk @('dataPath','path','путь')
		$vcRaw = Get-ElProp $lk @('valueChange','режимИзменения')
		$vc = "Clear"
		if ($vcRaw) {
			$vc = switch -Regex ("$vcRaw".ToLower()) {
				'^(clear|очистить|очистка)$'             { "Clear"; break }
				'^(dontchange|неизменять|неменять|нет)$' { "DontChange"; break }
				default                                  { "$vcRaw" }
			}
		}
		X "$indent`t<xr:Link>"
		X "$indent`t`t<xr:Name>$(Esc-Xml "$name")</xr:Name>"
		X "$indent`t`t<xr:DataPath xsi:type=`"xs:string`">$(Esc-Xml "$dp")</xr:DataPath>"
		X "$indent`t`t<xr:ValueChange>$vc</xr:ValueChange>"
		X "$indent`t</xr:Link>"
	}
	X "$indent</ChoiceParameterLinks>"
}

# <TypeLink> (связь по типу) — {dataPath, linkItem}. linkItem дефолт 0.
function Emit-TypeLink {
	param($el, [string]$indent)
	$tl = $el.typeLink
	if (-not $tl) { return }
	if ($tl -is [string]) { $tl = ConvertFrom-TypeLinkShorthand $tl }
	$dp = Get-ElProp $tl @('dataPath','path','путь')
	$li = Get-ElProp $tl @('linkItem','элементСвязи')
	if ($null -eq $li) { $li = 0 }
	X "$indent<TypeLink>"
	X "$indent`t<xr:DataPath>$(Esc-Xml "$dp")</xr:DataPath>"
	X "$indent`t<xr:LinkItem>$li</xr:LinkItem>"
	X "$indent</TypeLink>"
}

function Emit-Radio {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<RadioButtonField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
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

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	X "$indent<LabelDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	# Порядок как у платформы: own-content (флаги/hyperlink/layout/оформление) ПЕРЕД Title
	# (корпус layout-first 16970 vs 44 — заодно убирает шум атрибуции харнесса на многострочном Title).
	Emit-CommonFlags -el $el -indent $inner
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	Emit-DecorationTitle -el $el -name $name -indent $inner -auto

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "label"

	X "$indent</LabelDecoration>"
}

function Emit-LabelField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<LabelField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner

	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	# FooterDataPath — путь данных подвала колонки (общий cell-prop, как у input); после EditMode
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-Xml "$($el.footerDataPath)")</FooterDataPath>" }
	# PasswordMode на LabelField — платформа эмитит явный false (редко); факт. значение
	if ($null -ne $el.passwordMode) { X "$inner<PasswordMode>$(if ($el.passwordMode){'true'}else{'false'})</PasswordMode>" }
	Emit-ColumnPics -el $el -indent $inner
	# ВНИМАНИЕ: у LabelField платформенный тег именно <Hiperlink> (опечатка 1С), не <Hyperlink>.
	if ($el.hyperlink -eq $true) { X "$inner<Hiperlink>true</Hiperlink>" }
	Emit-Layout -el $el -indent $inner

	if ($null -ne $el.warningOnEdit) { Emit-MLText -tag "WarningOnEdit" -text $el.warningOnEdit -indent $inner }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# Формат / формат редактирования (LocalStringType — строка или {ru,en})
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }

	# Оформление (цвета/шрифты/граница + header/footer) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	$script:currentTableName = $name   # дефолт source для кастомных дополнений в commandBar
	X "$indent<Table name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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
	# Высота в строках таблицы (<HeightInTableRows>) — отдельное свойство от <Height> (высота элемента,
	# эмитится generic-ом Emit-Layout ниже). Таблица может нести оба (237 в корпусе).
	if ($el.heightInTableRows) { X "$inner<HeightInTableRows>$($el.heightInTableRows)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }

	if ($el.commandBarLocation) {
		X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>"
	}
	if ($el.searchStringLocation) {
		X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>"
	}
	if ($el.choiceMode -eq $true) { X "$inner<ChoiceMode>true</ChoiceMode>" }
	# Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill = tableAutofill).
	if ($null -ne $el.autofill) { X "$inner<Autofill>$(if ($el.autofill){'true'}else{'false'})</Autofill>" }
	if ($el.multipleChoice -eq $true) { X "$inner<MultipleChoice>true</MultipleChoice>" }
	if ($el.searchOnInput) { X "$inner<SearchOnInput>$($el.searchOnInput)</SearchOnInput>" }
	if ($null -ne $el.markIncomplete) { X "$inner<AutoMarkIncomplete>$(if ($el.markIncomplete){'true'}else{'false'})</AutoMarkIncomplete>" }
	# Высота шапки/подвала в строках (pass-through; 1С толерантна к порядку детей Table)
	if ($null -ne $el.headerHeight) { X "$inner<HeaderHeight>$($el.headerHeight)</HeaderHeight>" }
	if ($null -ne $el.footerHeight) { X "$inner<FooterHeight>$($el.footerHeight)</FooterHeight>" }
	if ($el.useAlternationRowColor -eq $true) { X "$inner<UseAlternationRowColor>true</UseAlternationRowColor>" }
	if ($el.selectionMode) { X "$inner<SelectionMode>$($el.selectionMode)</SelectionMode>" }
	if ($el.rowSelectionMode) { X "$inner<RowSelectionMode>$($el.rowSelectionMode)</RowSelectionMode>" }
	if ($el.verticalLines -eq $false) { X "$inner<VerticalLines>false</VerticalLines>" }
	if ($el.horizontalLines -eq $false) { X "$inner<HorizontalLines>false</HorizontalLines>" }
	if ($el.initialTreeView) { X "$inner<InitialTreeView>$($el.initialTreeView)</InitialTreeView>" }
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }
	if ($el.rowPictureDataPath) { X "$inner<RowPictureDataPath>$($el.rowPictureDataPath)</RowPictureDataPath>" }
	# RowsPicture — та же конвенция, что ValuesPicture (дефолт LoadTransparent=false; abs/TransparentPixel)
	Emit-PictureRef -val $el.rowsPicture -picTag 'RowsPicture' -indent $inner
	# Использование текущей строки таблицы (pass-through; в корпусе соседствует с блоком дин-списка)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }
	# Запрос обновления дин-списка (pass-through; в корпусе всегда PullFromTop)
	if ($el.refreshRequest) { X "$inner<RefreshRequest>$($el.refreshRequest)</RefreshRequest>" }
	# Блок свойств дин-список-таблицы (помечена эвристикой 11b.4)
	if ($el.PSObject.Properties["_dynList"] -and $el._dynList) { Emit-DynListTableBlock -el $el -indent $inner }
	if ($el.viewStatusLocation) { X "$inner<ViewStatusLocation>$($el.viewStatusLocation)</ViewStatusLocation>" }
	if ($el.searchControlLocation) { X "$inner<SearchControlLocation>$($el.searchControlLocation)</SearchControlLocation>" }
	Emit-Layout -el $el -indent $inner

	# CommandSet таблицы эмитится через Emit-Layout (общий механизм поля)

	# Оформление (цвета/граница таблицы) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

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
	$adds = $el.additions
	Emit-TableAddition -typeKey 'searchString'  -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchString')
	Emit-TableAddition -typeKey 'viewStatus'    -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'viewStatus')
	Emit-TableAddition -typeKey 'searchControl' -tableName $name -indent $inner -override (Get-AdditionOverride $adds 'searchControl')

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

	X "$indent<Pages name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.pagesRepresentation) {
		X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>"
	}
	# Использование текущей строки (после PagesRepresentation, порядок XSD)
	if ($el.currentRowUse) { X "$inner<CurrentRowUse>$($el.currentRowUse)</CurrentRowUse>" }

	Emit-CommonFlags -el $el -indent $inner
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифты/граница) заголовка группы страниц — TitleFont/TitleTextColor/… (как у Page)
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	X "$indent<Page name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Картинка страницы (иконка вкладки): после Title/флагов, перед Group (порядок XSD).
	# Конвенция как у ValuesPicture (дефолт LoadTransparent=false): скаляр-Ref/'abs:X' или объект.
	Emit-PictureRef -val $el.picture -picTag 'Picture' -indent $inner

	if ($el.group) {
		# Доступные значения страницы/обычной группы: Vertical / HorizontalIfPossible / AlwaysHorizontal
		# (InCell — только у columnGroup). Horizontal/AlwaysVertical оставлены forgiving (legacy).
		$orientation = switch ("$($el.group)") {
			"horizontal"          { "Horizontal" }
			"vertical"            { "Vertical" }
			"alwaysHorizontal"    { "AlwaysHorizontal" }
			"alwaysVertical"      { "AlwaysVertical" }
			"horizontalIfPossible" { "HorizontalIfPossible" }
			default               { $null }
		}
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
		else { Warn-Unrecognized 'page group orientation' $el.group @('vertical','horizontalIfPossible','alwaysHorizontal') $name }
	}
	if ($null -ne $el.showTitle) { X "$inner<ShowTitle>$(if ($el.showTitle){'true'}else{'false'})</ShowTitle>" }
	# Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
	if ($el.format)     { Emit-MLText -tag "Format" -text $el.format -indent $inner }
	if ($el.editFormat) { Emit-MLText -tag "EditFormat" -text $el.editFormat -indent $inner }
	Emit-Layout -el $el -indent $inner

	# Оформление страницы (BackColor / TitleTextColor / TitleFont) — после ShowTitle, перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

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

	X "$indent<Button name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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
	# Parameter команды (после CommandName): строка → xr:MDObjectRef (объект метаданных);
	# объект {type} → v8:TypeDescription (грамматика типа). Forgiving-синоним 'параметр'.
	$btnParam = if ($null -ne $el.PSObject.Properties['parameter']) { $el.parameter } elseif ($null -ne $el.PSObject.Properties['параметр']) { $el.параметр } else { $null }
	if ($null -ne $btnParam) {
		if (($btnParam -is [System.Management.Automation.PSCustomObject] -or $btnParam -is [hashtable]) -and $btnParam.type) {
			Emit-Type -typeStr "$($btnParam.type)" -indent $inner -tag "Parameter" -tagAttrs ' xsi:type="v8:TypeDescription"'
		} else {
			X "$inner<Parameter xsi:type=`"xr:MDObjectRef`">$(Esc-Xml "$btnParam")</Parameter>"
		}
	}
	# DataPath — привязка команды кнопки к контексту (Объект.Ref, Items.X.CurrentData.Поле)
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	$btnAuto = -not ($el.command -or $el.commandName -or $el.stdCommand)
	Emit-Title -el $el -name $name -indent $inner -auto:$btnAuto
	Emit-CommonFlags -el $el -indent $inner

	if ($el.defaultButton -eq $true) { X "$inner<DefaultButton>true</DefaultButton>" }
	# Check (пометка toggle-кнопки командной панели) — платформа эмитит только true.
	# Ключ 'checked' (не 'check': 'check' — тип-ключ CheckBoxField, был бы конфликт диспетчера типов)
	if ($el.checked -eq $true) { X "$inner<Check>true</Check>" }

	# Picture
	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}

	if ($el.locationInCommandBar) {
		X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление (цвета/шрифт/граница) — перед компаньоном (профиль кнопки)
	Emit-Appearance -el $el -indent $inner -profile 'button'

	# Companion
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "button"

	X "$indent</Button>"
}

function Emit-PictureDecoration {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureDecoration name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-DecorationTitle -el $el -name $name -indent $inner
	# Текст при невыбранной картинке (NonselectedPictureText) — после Title (порядок корпуса)
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }
	Emit-CommonFlags -el $el -indent $inner

	# Источник картинки — ТОЛЬКО $el.src (у PictureDecoration ключ 'picture' = тип/имя элемента, не источник).
	# Префикс "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
	if ($el.src) {
		$srcStr = "$($el.src)"
		$lt = if ($el.loadTransparent -eq $true) { "true" } else { "false" }
		X "$inner<Picture>"
		if ($srcStr -match '^abs:(.*)$') { X "$inner`t<xr:Abs>$(Esc-Xml $matches[1])</xr:Abs>" }
		else { X "$inner`t<xr:Ref>$(Esc-Xml $srcStr)</xr:Ref>" }
		X "$inner`t<xr:LoadTransparent>$lt</xr:LoadTransparent>"
		if ($el.transparentPixel) { X "$inner`t<xr:TransparentPixel x=`"$($el.transparentPixel.x)`" y=`"$($el.transparentPixel.y)`"/>" }
		X "$inner</Picture>"
	}

	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (декорация-картинка перетаскиваема; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Оформление (цвета/шрифт/граница) — профиль декорации (1С толерантна к порядку appearance)
	Emit-Appearance -el $el -indent $inner -profile 'decoration'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picture"

	X "$indent</PictureDecoration>"
}

function Emit-PictureField {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<PictureField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }

	Emit-Title -el $el -name $name -indent $inner
	Emit-CommonFlags -el $el -indent $inner

	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }
	Emit-ColumnPics -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }

	Emit-Layout -el $el -indent $inner
	# EnableDrag — фактическое значение (поле картинки перетаскиваемо; декомпилятор ловит generic-ом)
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
	if ($el.footerDataPath) { X "$inner<FooterDataPath>$(Esc-Xml "$($el.footerDataPath)")</FooterDataPath>" }
	if ($null -ne $el.footerText) { Emit-MLText -tag "FooterText" -text $el.footerText -indent $inner }

	# ValuesPicture — picture (collection) used to render the field's value.
	# Required for a Boolean-bound PictureField to actually show an icon.
	# Скаляр (Ref) или объект {src, loadTransparent}; LoadTransparent эмитится всегда.
	Emit-PictureRef -val $el.valuesPicture -picTag 'ValuesPicture' -indent $inner
	if ($null -ne $el.nonselectedPictureText) { Emit-MLText -tag "NonselectedPictureText" -text $el.nonselectedPictureText -indent $inner }

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "picField"

	X "$indent</PictureField>"
}

function Emit-Calendar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CalendarField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"

	X "$indent</CalendarField>"
}

# Спец-поля «документ/датчик» (SpreadSheet/HTML/Text/Formatted/ProgressBar/TrackBar):
# единый скелет поля (path/title/flags/titleLocation/editMode/layout/companions/events).
# Типоспец. enum/bool скаляры — через generic (Emit-Layout→Emit-GenericScalars);
# числовые скаляры датчиков (min/max/шаги) — без xsi:type (≠ типизированных InputField).
# enableDrag/enableStartDrag — общие (Emit-CommonElementProps), фактическое значение.
function Emit-SimpleField {
	param($el, [string]$name, [int]$id, [string]$indent, [string]$xmlTag, [string]$typeKey)

	X "$indent<$xmlTag name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	if ($el.editMode) { X "$inner<EditMode>$($el.editMode)</EditMode>" }

	Emit-Layout -el $el -indent $inner

	# EnableDrag — фактическое значение (SpreadSheet; платформа эмитит явный false). enableStartDrag — через Emit-Layout.
	if ($null -ne $el.enableDrag) { X "$inner<EnableDrag>$(if ($el.enableDrag){'true'}else{'false'})</EnableDrag>" }

	# Датчики (ProgressBar/TrackBar) — числовые скаляры (без xsi:type)
	foreach ($p in @(@('minValue','MinValue'), @('maxValue','MaxValue'), @('largeStep','LargeStep'), @('markingStep','MarkingStep'), @('step','Step'))) {
		if ($null -ne $el.($p[0])) { X "$inner<$($p[1])>$($el.($p[0]))</$($p[1])>" }
	}

	# Оформление (цвета/шрифты/граница) — перед компаньонами
	Emit-Appearance -el $el -indent $inner -profile 'field'

	# Companions
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip

	Emit-Events -el $el -elementName $name -indent $inner -typeKey $typeKey

	X "$indent</$xmlTag>"
}

# GanttChartField — скелет поля + вложенная <Table> (полноценная таблица, через Emit-Element).
# Порядок (по корпусу): path/title/flags/titleLocation/layout/appearance, companions, Table, events.
function Emit-GanttChart {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<GanttChartField name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"
	if ($el.path) { X "$inner<DataPath>$($el.path)</DataPath>" }
	Emit-Title -el $el -name $name -indent $inner -auto:(-not $el.path)
	Emit-CommonFlags -el $el -indent $inner
	if ($el.titleLocation) { X "$inner<TitleLocation>$(Map-TitleLoc "$($el.titleLocation)")</TitleLocation>" }
	Emit-Layout -el $el -indent $inner
	Emit-Appearance -el $el -indent $inner -profile 'field'
	Emit-CompanionPanel -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner -panel $el.contextMenu
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner -content $el.extendedTooltip
	# Вложенная таблица диаграммы Ганта (стандартный Table — переиспользуем Emit-Element)
	if ($el.ganttTable) { Emit-Element -el $el.ganttTable -indent $inner }
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "ganttChart"
	X "$indent</GanttChartField>"
}

function Emit-CommandBar {
	param($el, [string]$name, [int]$id, [string]$indent)

	X "$indent<CommandBar name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner

	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }

	# CommandBar хранит HorizontalLocation фактически (включая Auto — декомпилятор ловит только при наличии);
	# ≠ дополнениям, где Auto = умолчание-скип (Get-HLocation).
	if ($el.horizontalLocation) {
		$hlv = switch ("$($el.horizontalLocation)".ToLower()) { 'auto' {'Auto'} 'left' {'Left'} 'right' {'Right'} 'center' {'Center'} default {"$($el.horizontalLocation)"} }
		X "$inner<HorizontalLocation>$hlv</HorizontalLocation>"
	}
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

	X "$indent<ButtonGroup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
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

	X "$indent<Popup name=`"$name`" id=`"$id`"$(DI-Attr $el)>"
	$inner = "$indent`t"

	Emit-Title -el $el -name $name -indent $inner -auto
	Emit-CommonFlags -el $el -indent $inner

	# Источник команд попапа (после Title/ToolTip, перед компаньоном) — как у ButtonGroup/CommandBar
	if ($el.commandSource) { X "$inner<CommandSource>$($el.commandSource)</CommandSource>" }

	Emit-CommandPicture -pic $el.picture -elemLt $el.loadTransparent -indent $inner

	if ($el.representation) {
		X "$inner<Representation>$($el.representation)</Representation>"
	}
	Emit-Layout -el $el -indent $inner

	# Оформление попапа (TitleTextColor / TitleFont) — перед компаньоном
	Emit-Appearance -el $el -indent $inner -profile 'field'

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
	# Проверка заполнения колонки → <FillCheck> (как у реквизита; bool true→ShowError / строка verbatim)
	$cfcRaw = if ($null -ne $col.PSObject.Properties['fillCheck']) { $col.fillCheck } elseif ($null -ne $col.PSObject.Properties['fillChecking']) { $col.fillChecking } else { $null }
	if ($null -ne $cfcRaw) { $cfcv = if ($cfcRaw -is [bool]) { if ($cfcRaw) { 'ShowError' } else { $null } } else { "$cfcRaw" }; if ($cfcv) { X "$indent`t<FillCheck>$cfcv</FillCheck>" } }
	Emit-FunctionalOptions -fo $col.functionalOptions -indent "$indent`t"
	# Ролевой доступ колонки (View/Edit) — xr-флаг, как у самого реквизита
	if ($null -ne $col.view) { Emit-XrFlag -tag 'View' -val $col.view -indent "$indent`t" }
	if ($null -ne $col.edit) { Emit-XrFlag -tag 'Edit' -val $col.edit -indent "$indent`t" }
	X "$indent</Column>"
}

# --- Schema-параметры динамического списка (DataCompositionSchemaParameter) ---
# Та же сущность, что параметры СКД (см. skd-compile), но в форме: обёртка <Parameter>
# + дети с префиксом dcssch:. DSL переиспользует грамматику параметров СКД (shorthand +
# объект). Контекстные дефолты дин-списка (паттерн «умный дефолт у всегда-эмитируемого тега»):
#   useRestriction — эмитим ВСЕГДА, дефолт TRUE (в СКД дефолт false);
#   title — авто из имени (Title-FromName), если ключ не задан.
# Канон. порядок детей (по корпусу acc/erp 8.3.24): name, title, valueType, value,
#   useRestriction, expression, availableValue*, valueListAllowed, availableAsField,
#   inputParameters, denyIncompleteValues, use.

# Многоязычный текст в DCS-контексте — с xsi:type="v8:LocalStringType" (form-compile
# Emit-MLText его НЕ ставит, т.к. формовые <Title> голые; в dcssch:* — обязателен).
function Emit-DLMLText {
	param([string]$tag, $text, [string]$indent)
	X "$indent<$tag xsi:type=`"v8:LocalStringType`">"
	Emit-MLItems -val $text -indent "$indent`t"
	X "$indent</$tag>"
}

function Has-DLProp {
	param($obj, [string]$name)
	if ($null -eq $obj) { return $false }
	if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
	if ($obj.PSObject -and $obj.PSObject.Properties[$name]) { return $true }
	return $false
}

function Split-DLValueListCsv {
	param([string]$s)
	$result = @()
	if ($null -eq $s) { return ,$result }
	$items = @(); $buf = New-Object System.Text.StringBuilder; $inQuote = $null
	for ($i = 0; $i -lt $s.Length; $i++) {
		$ch = $s[$i]
		if ($inQuote) { [void]$buf.Append($ch); if ($ch -eq $inQuote) { $inQuote = $null } }
		elseif ($ch -eq "'" -or $ch -eq '"') { $inQuote = $ch; [void]$buf.Append($ch) }
		elseif ($ch -eq ',') { $items += $buf.ToString(); [void]$buf.Clear() }
		else { [void]$buf.Append($ch) }
	}
	if ($buf.Length -gt 0) { $items += $buf.ToString() }
	foreach ($raw in $items) {
		$t = $raw.Trim()
		if ($t.Length -ge 2 -and (($t[0] -eq "'" -and $t[-1] -eq "'") -or ($t[0] -eq '"' -and $t[-1] -eq '"'))) { $t = $t.Substring(1, $t.Length - 2) }
		if ($t -ne "") { $result += $t }
	}
	return ,$result
}

# Shorthand: "Имя [Заголовок]: Тип = Значение @valueList @hidden"
function Parse-DLParamShorthand {
	param([string]$s)
	$result = @{ name = ""; type = ""; value = $null; title = $null }
	if ($s -match '@valueList') { $result.valueListAllowed = $true; $s = $s -replace '\s*@valueList', '' }
	if ($s -match '@hidden')    { $result.hidden = $true; $s = $s -replace '\s*@hidden', '' }
	if ($s -match '\[([^\]]*)\]') { $result.title = $Matches[1].Trim(); $s = ($s -replace '\s*\[[^\]]*\]\s*', ' ').Trim() }
	# Тип может быть СОСТАВНЫМ (A | B | C — с пробелами); значение — после '=' (тип '=' не содержит).
	if ($s -match '^([^:]+):\s*([^=]+?)(\s*=\s*(.*))?$') {
		$result.name = $Matches[1].Trim()
		$typeRaw = $Matches[2].Trim()
		if ($typeRaw -match '[|+]') {
			$result.type = (($typeRaw -split '\s*[|+]\s*') | ForEach-Object { Resolve-TypeStr ($_.Trim()) }) -join ' | '
		} else {
			$result.type = Resolve-TypeStr $typeRaw
		}
		if ($Matches[4]) {
			$rhs = $Matches[4].Trim()
			$items = Split-DLValueListCsv $rhs
			if ($items.Count -ge 2) { $result.value = $items; $result.valueListAllowed = $true }
			elseif ($items.Count -eq 1) { $result.value = $items[0] }
			else { $result.value = $rhs }
		}
	} else { $result.name = $s.Trim() }
	return $result
}

function Test-DLEmptyValue {
	param($v)
	if ($null -eq $v) { return $true }
	$s = "$v".Trim()
	if ($s -eq "" -or $s -eq "_" -or $s.ToLowerInvariant() -eq "null") { return $true }
	return $false
}

# Эмиссия <dcssch:value> по типу/значению (xs:* или dcscor:DesignTimeValue для ссылок).
function Emit-DLValue {
	param([string]$type, $val, [string]$indent, [bool]$valueListAllowed = $false)
	if (Test-DLEmptyValue $val) {
		# Дин-список: пустое значение платформа ВСЕГДА пишет как xsi:nil, даже при известном
		# типе (в отличие от типизированного пустого в параметрах отчёта СКД).
		if ($valueListAllowed) { return }
		X "$indent<dcssch:value xsi:nil=`"true`"/>"
		return
	}
	$valStr = if ($val -is [bool]) { if ($val) { 'true' } else { 'false' } } else { "$val" }
	if ($type -match '^(date|dateTime|time)') { X "$indent<dcssch:value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</dcssch:value>" }
	elseif ($type -eq "boolean") { X "$indent<dcssch:value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</dcssch:value>" }
	elseif ($type -eq 'v8:Type') { $nsAttr = Get-ValueTypeNsAttr -valueType 'v8:Type' -value $valStr; X "$indent<dcssch:value$nsAttr xsi:type=`"v8:Type`">$(Esc-Xml $valStr)</dcssch:value>" }
	elseif ($type -match '^ent:') { X "$indent<dcssch:value xsi:type=`"$type`">$(Esc-Xml $valStr)</dcssch:value>" }   # системное перечисление (ent:X) — value несёт тот же xsi:type
	elseif ($type -match '^decimal') { X "$indent<dcssch:value xsi:type=`"xs:decimal`">$(Esc-Xml $valStr)</dcssch:value>" }
	elseif ($type -match '^string') { X "$indent<dcssch:value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</dcssch:value>" }
	elseif ($type -match '^(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|BusinessProcessRef|TaskRef|ExchangePlanRef)\.') { X "$indent<dcssch:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $valStr)</dcssch:value>" }
	else {
		if ($valStr -match '^\d{4}-\d{2}-\d{2}T') { X "$indent<dcssch:value xsi:type=`"xs:dateTime`">$(Esc-Xml $valStr)</dcssch:value>" }
		elseif ($valStr -eq "true" -or $valStr -eq "false") { X "$indent<dcssch:value xsi:type=`"xs:boolean`">$(Esc-Xml $valStr)</dcssch:value>" }
		elseif ($valStr -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or $valStr -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { X "$indent<dcssch:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $valStr)</dcssch:value>" }
		else { X "$indent<dcssch:value xsi:type=`"xs:string`">$(Esc-Xml $valStr)</dcssch:value>" }
	}
}

# <dcssch:valueType> — обёртка + тело через Emit-SingleType (ref-типы → cfg:, как в форме).
function Emit-DLValueType {
	param($typeStr, [string]$indent)
	if (-not $typeStr) { return }
	X "$indent<dcssch:valueType>"
	$parts = "$typeStr" -split '\s*[|+]\s*'
	foreach ($part in $parts) { Emit-SingleType -typeStr $part.Trim() -indent "$indent`t" }
	X "$indent</dcssch:valueType>"
}

function Emit-DLAvailableValue {
	param($av, [string]$type, [string]$indent)
	X "$indent<dcssch:availableValue>"
	$avVal = if (Has-DLProp $av 'value') { $av.value } else { $null }
	Emit-DLValue -type $type -val $avVal -indent "$indent`t" -valueListAllowed $false
	$pres = if ($av.presentation) { $av.presentation } elseif ($av.title) { $av.title } else { $null }
	if ($pres) { Emit-DLMLText -tag "dcssch:presentation" -text $pres -indent "$indent`t" }
	X "$indent</dcssch:availableValue>"
}

# <dcssch:inputParameters> — ChoiceParameters / ChoiceParameterLinks / простое значение (порт из skd).
function Emit-DLInputParameters {
	param($ip, [string]$indent)
	if ($null -eq $ip) { return }
	$items = @($ip)
	if ($items.Count -eq 0) { return }
	X "$indent<dcssch:inputParameters>"
	foreach ($item in $items) {
		X "$indent`t<dcscor:item>"
		if ((Has-DLProp $item 'use') -and $null -ne $item.use -and -not $item.use) { X "$indent`t`t<dcscor:use>false</dcscor:use>" }
		X "$indent`t`t<dcscor:parameter>$(Esc-Xml "$($item.parameter)")</dcscor:parameter>"
		if (Has-DLProp $item 'choiceParameters') {
			$cpItems = if ($null -ne $item.choiceParameters) { @($item.choiceParameters) } else { @() }
			if ($cpItems.Count -eq 0) { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`"/>" }
			else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameters`">"
				foreach ($cpItem in $cpItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-Xml "$($cpItem.name)")</dcscor:choiceParameter>"
					foreach ($v in @($cpItem.values)) {
						if ($v -is [bool]) { X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:boolean`">$(if ($v) { 'true' } else { 'false' })</dcscor:value>" }
						elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { X "$indent`t`t`t`t<dcscor:value xsi:type=`"xs:decimal`">$v</dcscor:value>" }
						else { X "$indent`t`t`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml "$v")</dcscor:value>" }
					}
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-DLProp $item 'choiceParameterLinks') {
			$cplItems = if ($null -ne $item.choiceParameterLinks) { @($item.choiceParameterLinks) } else { @() }
			if ($cplItems.Count -eq 0) { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`"/>" }
			else {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:ChoiceParameterLinks`">"
				foreach ($cplItem in $cplItems) {
					X "$indent`t`t`t<dcscor:item>"
					X "$indent`t`t`t`t<dcscor:choiceParameter>$(Esc-Xml "$($cplItem.name)")</dcscor:choiceParameter>"
					X "$indent`t`t`t`t<dcscor:value>$(Esc-Xml "$($cplItem.value)")</dcscor:value>"
					$mode = if ($cplItem.mode) { "$($cplItem.mode)" } else { 'Auto' }
					X "$indent`t`t`t`t<dcscor:mode xmlns:d8p1=`"http://v8.1c.ru/8.1/data/enterprise`" xsi:type=`"d8p1:LinkedValueChangeMode`">$mode</dcscor:mode>"
					X "$indent`t`t`t</dcscor:item>"
				}
				X "$indent`t`t</dcscor:value>"
			}
		} elseif (Has-DLProp $item 'typeLink') {
			# Связь по типу (dcscor:TypeLink) — field + linkItem (структурное значение параметра).
			$tl = $item.typeLink
			X "$indent`t`t<dcscor:value xsi:type=`"dcscor:TypeLink`">"
			$tlf = Get-Prop $tl 'field'; if ($null -ne $tlf) { X "$indent`t`t`t<dcscor:field>$(Esc-Xml "$tlf")</dcscor:field>" }
			$tli = Get-Prop $tl 'linkItem'; if ($null -ne $tli) { X "$indent`t`t`t<dcscor:linkItem>$(Esc-Xml "$tli")</dcscor:linkItem>" }
			X "$indent`t`t</dcscor:value>"
		} elseif (Has-DLProp $item 'value') {
			$val = $item.value
			if ($val -is [bool]) { X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(if ($val) { 'true' } else { 'false' })</dcscor:value>" }
			elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) { X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$val</dcscor:value>" }
			elseif ($val -is [hashtable] -or $val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject]) { Emit-DLMLText -tag "dcscor:value" -text $val -indent "$indent`t`t" }
			else { X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$val")</dcscor:value>" }
		}
		X "$indent`t</dcscor:item>"
	}
	X "$indent</dcssch:inputParameters>"
}

# ── dataParameters (значения параметров запроса в настройках компоновки) — порт из skd-compile ──
# Грамматика идентична СКД: shorthand "Имя = Значение @off @user" или объект
# {parameter, value?, valueType?, use?, nilValue?, viewMode?, userSettingID?, userSettingPresentation?}.
function Test-EmptyValue {
	param($v)
	if ($null -eq $v) { return $true }
	$s = "$v".Trim()
	if ($s -eq "") { return $true }
	if ($s -eq "_") { return $true }
	if ($s.ToLowerInvariant() -eq "null") { return $true }
	return $false
}
function Emit-EmptyValue {
	param([string]$type, [string]$indent, [string]$tagPrefix = "", [bool]$valueListAllowed = $false)
	if ($valueListAllowed) { return }
	$t = if ($null -eq $type) { "" } else { "$type" }
	$tBare = if ($t -match '^xs:(.+)$') { $matches[1] } else { $t }
	$pf = $tagPrefix
	if ($t -eq "") { X "$indent<${pf}value xsi:nil=`"true`"/>" }
	elseif ($t -eq "StandardPeriod") {
		X "$indent<${pf}value xsi:type=`"v8:StandardPeriod`">"
		X "$indent`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">Custom</v8:variant>"
		X "$indent`t<v8:startDate>0001-01-01T00:00:00</v8:startDate>"
		X "$indent`t<v8:endDate>0001-01-01T00:00:00</v8:endDate>"
		X "$indent</${pf}value>"
	}
	elseif ($tBare -match '^string') { X "$indent<${pf}value xsi:type=`"xs:string`"/>" }
	elseif ($tBare -match '^(date|time)') { X "$indent<${pf}value xsi:type=`"xs:dateTime`">0001-01-01T00:00:00</${pf}value>" }
	elseif ($tBare -match '^decimal') { X "$indent<${pf}value xsi:type=`"xs:decimal`">0</${pf}value>" }
	elseif ($tBare -eq "boolean") { X "$indent<${pf}value xsi:type=`"xs:boolean`">false</${pf}value>" }
	else { X "$indent<${pf}value xsi:nil=`"true`"/>" }
}
function Parse-DataParamShorthand {
	param([string]$s)
	$result = @{ parameter = ""; value = $null; use = $true; userSettingID = $null; viewMode = $null }
	if ($s -match '@user') { $result.userSettingID = "auto"; $s = $s -replace '\s*@user', '' }
	if ($s -match '@off') { $result.use = $false; $s = $s -replace '\s*@off', '' }
	if ($s -match '@quickAccess') { $result.viewMode = "QuickAccess"; $s = $s -replace '\s*@quickAccess', '' }
	if ($s -match '@normal') { $result.viewMode = "Normal"; $s = $s -replace '\s*@normal', '' }
	$s = $s.Trim()
	if ($s -match '^([^=]+)=\s*(.+)$') {
		$result.parameter = $Matches[1].Trim()
		$valStr = $Matches[2].Trim()
		$periodVariants = @("Custom","Today","ThisWeek","ThisTenDays","ThisMonth","ThisQuarter","ThisHalfYear","ThisYear","FromBeginningOfThisWeek","FromBeginningOfThisTenDays","FromBeginningOfThisMonth","FromBeginningOfThisQuarter","FromBeginningOfThisHalfYear","FromBeginningOfThisYear","LastWeek","LastTenDays","LastMonth","LastQuarter","LastHalfYear","LastYear","NextDay","NextWeek","NextTenDays","NextMonth","NextQuarter","NextHalfYear","NextYear","TillEndOfThisWeek","TillEndOfThisTenDays","TillEndOfThisMonth","TillEndOfThisQuarter","TillEndOfThisHalfYear","TillEndOfThisYear")
		if ($periodVariants -contains $valStr) { $result.value = @{ variant = $valStr } }
		elseif ($valStr -match '^\d{4}-\d{2}-\d{2}T') { $result.value = $valStr }
		elseif ($valStr -eq "true" -or $valStr -eq "false") { $result.value = [bool]($valStr -eq "true") }
		else { $result.value = $valStr }
	} else { $result.parameter = $s }
	return $result
}
function Emit-DataParameters {
	param($items, [string]$indent, $blockViewMode = $null)
	if (-not $items -or @($items).Count -eq 0) { return }
	X "$indent<dcsset:dataParameters>"
	foreach ($dp in @($items)) {
		if ($dp -is [string]) {
			$parsed = Parse-DataParamShorthand $dp
			$dpObj = New-Object PSObject
			$dpObj | Add-Member -NotePropertyName "parameter" -NotePropertyValue $parsed.parameter
			if ($null -ne $parsed.value) { $dpObj | Add-Member -NotePropertyName "value" -NotePropertyValue $parsed.value }
			if ($parsed.use -eq $false) { $dpObj | Add-Member -NotePropertyName "use" -NotePropertyValue $false }
			if ($parsed.userSettingID) { $dpObj | Add-Member -NotePropertyName "userSettingID" -NotePropertyValue $parsed.userSettingID }
			if ($parsed.viewMode) { $dpObj | Add-Member -NotePropertyName "viewMode" -NotePropertyValue $parsed.viewMode }
			$dp = $dpObj
		}
		X "$indent`t<dcscor:item xsi:type=`"dcsset:SettingsParameterValue`">"
		if ($dp.use -eq $false) { X "$indent`t`t<dcscor:use>false</dcscor:use>" }
		X "$indent`t`t<dcscor:parameter>$(Esc-Xml "$($dp.parameter)")</dcscor:parameter>"
		$dpValIsArr = ($dp.value -is [array]) -or ($dp.value -is [System.Collections.IList] -and $dp.value -isnot [string])
		if ($dpValIsArr) {
			# Список значений параметра (valueListAllowed) — отдельный <dcscor:value> на каждое.
			$avtype = "$($dp.valueType)"
			foreach ($v in @($dp.value)) {
				$vStr = if ($v -is [bool]) { "$v".ToLower() } else { "$v" }
				if ($avtype -match '^[a-zA-Z]+:') { X "$indent`t`t<dcscor:value xsi:type=`"$avtype`">$(Esc-Xml $vStr)</dcscor:value>" }
				elseif ("$vStr" -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or "$vStr" -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') { X "$indent`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml $vStr)</dcscor:value>" }
				else { X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml $vStr)</dcscor:value>" }
			}
		} elseif ($dp.nilValue -eq $true) {
			X "$indent`t`t<dcscor:value xsi:nil=`"true`"/>"
		} elseif ((Test-EmptyValue $dp.value) -and $dp.valueType) {
			# Явный типизированный пустой (xs:string-плейсхолдер и т.п.)
			Emit-EmptyValue -type "$($dp.valueType)" -indent "$indent`t`t" -tagPrefix "dcscor:" -valueListAllowed $false
		} elseif (Test-EmptyValue $dp.value) {
			# Нет значения и нет valueType → НЕ эмитим value-узел (form дин-список: use=false плейсхолдер).
			# (В отличие от skd-settings, где значение всегда присутствует.)
		} elseif ($null -ne $dp.value) {
			$vtype = "$($dp.valueType)"
			if (($dp.value -is [PSCustomObject] -or $dp.value -is [hashtable] -or $dp.value -is [System.Collections.IDictionary]) -and ($dp.value.variant)) {
				$_hasDate = $false; $_hasSD = $false
				if ($dp.value -is [PSCustomObject]) { $_hasDate = [bool]$dp.value.PSObject.Properties['date']; $_hasSD = [bool]$dp.value.PSObject.Properties['startDate'] }
				else { $_hasDate = $dp.value.Contains('date'); $_hasSD = $dp.value.Contains('startDate') }
				$_variantStr = "$($dp.value.variant)"
				$_isSBD = $_hasDate -or (-not $_hasSD -and $_variantStr -like 'BeginningOf*')
				if ($_isSBD) {
					$_d = $null
					if ($dp.value -is [PSCustomObject] -and $dp.value.PSObject.Properties['date']) { $_d = "$($dp.value.date)" }
					elseif (($dp.value -is [System.Collections.IDictionary]) -and $dp.value.Contains('date')) { $_d = "$($dp.value['date'])" }
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardBeginningDate`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardBeginningDateVariant`">$(Esc-Xml $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') { if (-not $_d) { $_d = '0001-01-01T00:00:00' }; X "$indent`t`t`t<v8:date>$(Esc-Xml $_d)</v8:date>" }
					X "$indent`t`t</dcscor:value>"
				} else {
					$_sd = $null; $_ed = $null
					if ($dp.value -is [PSCustomObject]) { if ($dp.value.PSObject.Properties['startDate']) { $_sd = "$($dp.value.startDate)" }; if ($dp.value.PSObject.Properties['endDate']) { $_ed = "$($dp.value.endDate)" } }
					else { if ($dp.value.Contains('startDate')) { $_sd = "$($dp.value['startDate'])" }; if ($dp.value.Contains('endDate')) { $_ed = "$($dp.value['endDate'])" } }
					X "$indent`t`t<dcscor:value xsi:type=`"v8:StandardPeriod`">"
					X "$indent`t`t`t<v8:variant xsi:type=`"v8:StandardPeriodVariant`">$(Esc-Xml $_variantStr)</v8:variant>"
					if ($_variantStr -eq 'Custom') { if (-not $_sd) { $_sd = '0001-01-01T00:00:00' }; if (-not $_ed) { $_ed = '0001-01-01T00:00:00' }; X "$indent`t`t`t<v8:startDate>$(Esc-Xml $_sd)</v8:startDate>"; X "$indent`t`t`t<v8:endDate>$(Esc-Xml $_ed)</v8:endDate>" }
					X "$indent`t`t</dcscor:value>"
				}
			} elseif ($vtype -match '^[a-zA-Z]+:') {
				$vStr = if ($dp.value -is [bool]) { "$($dp.value)".ToLower() } else { "$($dp.value)" }
				X "$indent`t`t<dcscor:value xsi:type=`"$vtype`">$(Esc-Xml $vStr)</dcscor:value>"
			} elseif ($vtype -eq 'boolean' -or $dp.value -is [bool]) {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:boolean`">$(Esc-Xml ("$($dp.value)".ToLower()))</dcscor:value>"
			} elseif ($vtype -match '^date' -or "$($dp.value)" -match '^\d{4}-\d{2}-\d{2}T') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:dateTime`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^decimal') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:decimal`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ($vtype -match '^string') {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} elseif ("$($dp.value)" -match '^(ПланСчетов|Справочник|Перечисление|Документ|ПланВидовХарактеристик|ПланВидовРасчета|БизнесПроцесс|Задача|РегистрСведений|ПланОбмена)\.' -or "$($dp.value)" -match '^(ChartOfAccounts|Catalog|Enum|Document|ChartOfCharacteristicTypes|ChartOfCalculationTypes|BusinessProcess|Task|InformationRegister|ExchangePlan)\.') {
				X "$indent`t`t<dcscor:value xsi:type=`"dcscor:DesignTimeValue`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			} else {
				X "$indent`t`t<dcscor:value xsi:type=`"xs:string`">$(Esc-Xml "$($dp.value)")</dcscor:value>"
			}
		}
		if ($dp.viewMode) { X "$indent`t`t<dcsset:viewMode>$(Esc-Xml "$($dp.viewMode)")</dcsset:viewMode>" }
		if ($dp.userSettingID) { $uid = if ("$($dp.userSettingID)" -eq "auto") { New-Guid-String } else { "$($dp.userSettingID)" }; X "$indent`t`t<dcsset:userSettingID>$(Esc-Xml $uid)</dcsset:userSettingID>" }
		if ($dp.userSettingPresentation) { Emit-USPresentation -val $dp.userSettingPresentation -tag "dcsset:userSettingPresentation" -indent "$indent`t`t" }
		X "$indent`t</dcscor:item>"
	}
	if ($null -ne $blockViewMode) { X "$indent`t<dcsset:viewMode>$(Esc-Xml "$blockViewMode")</dcsset:viewMode>" }
	X "$indent</dcsset:dataParameters>"
}

function Emit-DLParameter {
	param($p, $parsed, [string]$indent)
	X "$indent<Parameter>"
	$ci = "$indent`t"
	X "$ci<dcssch:name>$(Esc-Xml $parsed.name)</dcssch:name>"
	# Title: явный override (shorthand [..] / объект title/presentation) или авто из имени.
	$title = $null
	if ($parsed.title) { $title = $parsed.title }
	elseif ($p -isnot [string] -and (Has-DLProp $p 'title') -and $p.title) { $title = $p.title }
	elseif ($p -isnot [string] -and (Has-DLProp $p 'presentation') -and $p.presentation) { $title = $p.presentation }
	if ($null -eq $title -or ($title -is [string] -and $title -eq '')) { $title = Title-FromName -name $parsed.name }
	Emit-DLMLText -tag "dcssch:title" -text $title -indent $ci
	# valueType
	if ($parsed.type) { Emit-DLValueType -typeStr $parsed.type -indent $ci }
	# value (дефолт nil; при valueListAllowed пустое — опускаем)
	$vla = [bool]$parsed.valueListAllowed
	$valIsArray = ($parsed.value -is [array]) -or ($parsed.value -is [System.Collections.IList] -and $parsed.value -isnot [string])
	if ($valIsArray) {
		foreach ($v in @($parsed.value)) { Emit-DLValue -type $parsed.type -val $v -indent $ci -valueListAllowed $false }
	} elseif ($parsed.valueExplicit -and ($null -ne $parsed.value) -and ("$($parsed.value)" -eq '') -and (("$($parsed.type)" -eq '') -or ("$($parsed.type)" -match '^string'))) {
		# Явный пустой СТРОКОВЫЙ параметр (value:"" от декомпилятора) → типизированный пустой
		# <dcssch:value xsi:type="xs:string"/>, НЕ nil. Решается ФОРМОЙ value (""→typed-empty,
		# null/отсутствие→nil), независимо от valueListAllowed; декомпилятор различает ""/null
		# (Convert-TypedValue пустого xs:string → "", nil → value опущен/null). Корпус: 26 xs:string.
		X "$ci<dcssch:value xsi:type=`"xs:string`"/>"
	} elseif ($vla -and (Test-DLEmptyValue $parsed.value) -and $parsed.valueExplicit) {
		# valueListAllowed + явный пустой (value:null от декомпилятора) → платформа здесь пишет nil
		X "$ci<dcssch:value xsi:nil=`"true`"/>"
	} else {
		Emit-DLValue -type $parsed.type -val $parsed.value -indent $ci -valueListAllowed $vla
	}
	# useRestriction — ВСЕГДА; дефолт true; false только при явном useRestriction:false.
	$ur = $true
	if ($p -isnot [string] -and (Has-DLProp $p 'useRestriction')) { $ur = [bool]$p.useRestriction }
	X "$ci<dcssch:useRestriction>$(if ($ur) { 'true' } else { 'false' })</dcssch:useRestriction>"
	# expression
	$expr = $null
	if ($p -isnot [string] -and (Has-DLProp $p 'expression') -and $p.expression) { $expr = "$($p.expression)" }
	if ($expr) { X "$ci<dcssch:expression>$(Esc-Xml $expr)</dcssch:expression>" }
	# availableValues
	if ($p -isnot [string] -and (Has-DLProp $p 'availableValues') -and $p.availableValues) {
		foreach ($av in @($p.availableValues)) { Emit-DLAvailableValue -av $av -type $parsed.type -indent $ci }
	}
	# valueListAllowed
	if ($vla) { X "$ci<dcssch:valueListAllowed>true</dcssch:valueListAllowed>" }
	# availableAsField=false (hidden или явный)
	$aaf = $null
	if ($parsed.hidden -eq $true) { $aaf = $false }
	if ($p -isnot [string] -and (Has-DLProp $p 'availableAsField')) { $aaf = [bool]$p.availableAsField }
	if ($aaf -eq $false) { X "$ci<dcssch:availableAsField>false</dcssch:availableAsField>" }
	# inputParameters
	if ($p -isnot [string] -and (Has-DLProp $p 'inputParameters') -and $p.inputParameters) { Emit-DLInputParameters -ip $p.inputParameters -indent $ci }
	# denyIncompleteValues
	if ($p -isnot [string] -and (Has-DLProp $p 'denyIncompleteValues') -and $p.denyIncompleteValues -eq $true) { X "$ci<dcssch:denyIncompleteValues>true</dcssch:denyIncompleteValues>" }
	# use
	$useVal = $null
	if ($p -isnot [string] -and (Has-DLProp $p 'use') -and $p.use) { $useVal = "$($p.use)" }
	if ($useVal) { X "$ci<dcssch:use>$(Esc-Xml $useVal)</dcssch:use>" }
	X "$indent</Parameter>"
}

function Emit-DLParameters {
	param($params, [string]$indent)
	if (-not $params) { return }
	foreach ($p in @($params)) {
		if ($p -is [string]) {
			$parsed = Parse-DLParamShorthand $p
		} else {
			$resolvedType = ""
			if ((Has-DLProp $p 'type') -and $p.type) {
				if ($p.type -is [array] -or ($p.type -is [System.Collections.IList] -and $p.type -isnot [string])) {
					$resolvedType = (@($p.type | ForEach-Object { Resolve-TypeStr "$_" })) -join ' | '
				} else { $resolvedType = Resolve-TypeStr "$($p.type)" }
			} elseif ((Has-DLProp $p 'valueType') -and $p.valueType) {
				$resolvedType = Resolve-TypeStr "$($p.valueType)"
			}
			$parsed = @{ name = "$($p.name)"; type = $resolvedType; value = $(if (Has-DLProp $p 'value') { $p.value } else { $null }); valueExplicit = (Has-DLProp $p 'value'); title = $null }
			if ((Has-DLProp $p 'valueListAllowed') -and $p.valueListAllowed -eq $true) { $parsed.valueListAllowed = $true }
			if ((Has-DLProp $p 'hidden') -and $p.hidden -eq $true) { $parsed.hidden = $true }
		}
		Emit-DLParameter -p $p -parsed $parsed -indent $indent
	}
}

function Emit-Attributes {
	param($attrs, [string]$indent, $conditionalAppearance = $null)

	$hasCA = $conditionalAppearance -and @($conditionalAppearance).Count -gt 0
	# Платформа ВСЕГДА эмитит <Attributes> (100% корпуса; 162 формы — пустой <Attributes/>).
	if ((-not $attrs -or $attrs.Count -eq 0) -and -not $hasCA) { X "$indent<Attributes/>"; return }
	if (-not $attrs -or $attrs.Count -eq 0) {
		# Нет реквизитов, но есть условное оформление (последний child <Attributes>)
		X "$indent<Attributes>"
		Emit-ConditionalAppearance -items $conditionalAppearance -indent "$indent`t" -wrapTag 'ConditionalAppearance'
		X "$indent</Attributes>"
		return
	}

	X "$indent<Attributes>"
	$seenAttrs = @{}
	foreach ($attr in $attrs) {
		$attrId = New-Id
		$attrName = "$($attr.name)"
		Assert-UniqueName -name $attrName -seen $seenAttrs -kind 'attribute'

		X "$indent`t<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$indent`t`t"

		# Title атрибута (зеркало Emit-Title): нет ключа → авто-вывод из имени (кроме main);
		# title "" → подавить; непустой → эмитить как есть.
		$hasTitleKey = $null -ne $attr.PSObject.Properties['title']
		if ($hasTitleKey) {
			if ($attr.title) { Emit-MLText -tag "Title" -text $attr.title -indent $inner }
		} elseif ($attr.main -ne $true) {
			Emit-MLText -tag "Title" -text (Title-FromName -name $attrName) -indent $inner
		}

		# Type
		if ($attr.type) {
			Emit-Type -typeStr "$($attr.type)" -indent $inner
		} else {
			X "$inner<Type/>"
		}
		# valueType: уточнение типа значений ValueList → <Settings xsi:type="v8:TypeDescription">
		# (та же грамматика типа, что и Type, включая составной "A | B"). Forgiving-синонимы.
		# Три состояния: нет ключа → нет Settings; "" → пустой <Settings…/>; тип → с типом.
		$vtSpec = $null; $hasVt = $false
		foreach ($k in @('valueType','typeDescription','описаниеТипов','типЗначений')) {
			if ($attr.PSObject.Properties[$k]) { $vtSpec = $attr.$k; $hasVt = $true; break }
		}
		if ($hasVt) {
			Emit-Type -typeStr "$vtSpec" -indent $inner -tag "Settings" -tagAttrs ' xsi:type="v8:TypeDescription"'
		}
		# Planner design-time <Settings xsi:type="pl:Planner"> (встроенный конфиг планировщика).
		# Идёт сразу после <Type> (как valueType/DynamicList Settings — взаимоисключающи).
		if ($attr.PSObject.Properties['planner'] -and $null -ne $attr.planner) {
			Emit-PlannerSettings -pl $attr.planner -ind $inner
		}
		# Chart/GanttChart design-time <Settings xsi:type="d4p1:Chart"/"d4p1:GanttChart">.
		# Тип Settings выводится из типа реквизита (d5p1:GanttChart → d4p1:GanttChart).
		if ($attr.PSObject.Properties['chart'] -and $null -ne $attr.chart) {
			$ctype = if ("$($attr.type)" -match 'GanttChart') { 'd4p1:GanttChart' } else { 'd4p1:Chart' }
			Emit-ChartSettings -chart $attr.chart -ind $inner -ctype $ctype
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
		# Явный ключ savedData побеждает (в т.ч. false → суппресс авто-вывода $mainSaved); нет ключа → авто.
		$emitSaved = if ($null -ne $attr.PSObject.Properties['savedData']) { $attr.savedData -eq $true } else { $mainSaved }
		if ($emitSaved) {
			X "$inner<SavedData>true</SavedData>"
		}
		# Save: сохранение значения реквизита в пользовательских настройках. true → <Field>имя</Field>;
		# строка/массив → под-поля с авто-префиксом "имя." (путь с точкой / UUID / =имя — как есть).
		# Нет ключа или false → не эмитим.
		if ($null -ne $attr.PSObject.Properties['save'] -and $null -ne $attr.save) {
			$saveFields = New-Object System.Collections.ArrayList
			if ($attr.save -is [bool]) {
				if ($attr.save) { [void]$saveFields.Add($attrName) }
			} else {
				foreach ($e in @($attr.save)) {
					$fld = "$e"
					if ([string]::IsNullOrEmpty($fld)) { continue }
					if ($fld -ne $attrName -and $fld -notmatch '\.' -and $fld -notmatch '^\d+/\d+') { $fld = "$attrName.$fld" }
					if (-not $saveFields.Contains($fld)) { [void]$saveFields.Add($fld) }
				}
			}
			if ($saveFields.Count -gt 0) {
				X "$inner<Save>"
				foreach ($f in $saveFields) { X "$inner`t<Field>$(Esc-Xml $f)</Field>" }
				X "$inner</Save>"
			}
		}
		# Проверка заполнения реквизита → <FillCheck> (реальный тег; <FillChecking> в схеме нет).
		# bool true → ShowError (единственное значение в корпусе); строка → verbatim. Синоним fillChecking.
		$fcRaw = if ($null -ne $attr.PSObject.Properties['fillCheck']) { $attr.fillCheck } elseif ($null -ne $attr.PSObject.Properties['fillChecking']) { $attr.fillChecking } else { $null }
		if ($fcRaw) {
			$fcv = if ($fcRaw -is [bool]) { 'ShowError' } else { "$fcRaw" }
			X "$inner<FillCheck>$fcv</FillCheck>"
		}

		# UseAlways: поля, всегда читаемые (дин-список/таблица). Две формы DSL сливаются:
		#  attr.useAlways[] (короткие имена) + columns с useAlways:true → <Field>ИмяРеквизита.Поле</Field>.
		$uaFields = New-Object System.Collections.ArrayList
		if ($attr.useAlways) {
			foreach ($e in @($attr.useAlways)) {
				$fld = "$e"
				# Префикс "ИмяРеквизита." добавляем к коротким именам. Поля дин-списка с маркером "~"
				# (query-поля, ~13% корпуса) — префикс ставится ПОСЛЕ "~": ~Остановлен → ~Список.Остановлен.
				# Полная форма (~Список.Остановлен / Список.Остановлен) — verbatim (forgiving ввод).
				if ($fld.StartsWith('~')) {
					$bare = $fld.Substring(1)
					if ($bare -notmatch "^$([regex]::Escape($attrName))\.") { $bare = "$attrName.$bare" }
					$fld = "~$bare"
				} elseif ($fld -notmatch "^$([regex]::Escape($attrName))\." -and $fld -notmatch '^\d+/\d+') {
					# UUID-ссылка (1/0:GUID) — НЕ префиксуем (платформа хранит её без "имя.")
					$fld = "$attrName.$fld"
				}
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
				$seenCols = @{}  # колонки уникальны в пределах своего реквизита
				foreach ($col in $attr.columns) {
					Assert-UniqueName -name "$($col.name)" -seen $seenCols -kind "column of '$attrName'"
					Emit-AttrColumn -col $col -indent "$inner`t"
				}
			}
			if ($hasAddCols) {
				foreach ($ac in @($attr.additionalColumns)) {
					$acCols = @($ac.columns)
					if ($acCols.Count -eq 0) {
						# Пустая группа доп.колонок (table-ref без колонок) → self-closing (как платформа)
						X "$inner`t<AdditionalColumns table=`"$($ac.table)`"/>"
						continue
					}
					X "$inner`t<AdditionalColumns table=`"$($ac.table)`">"
					$seenAcCols = @{}  # уникальность в пределах группы AdditionalColumns
					foreach ($col in $acCols) {
						Assert-UniqueName -name "$($col.name)" -seen $seenAcCols -kind "column of '$attrName'"
						Emit-AttrColumn -col $col -indent "$inner`t`t"
					}
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
			# Порядок платформы: AutoFillAvailableFields, ManualQuery, DynamicDataRead, QueryText, Field*, MainTable, ListSettings
			# AutoFillAvailableFields — дефолт true; эмитим только при заданном ключе (отклонение).
			if ($null -ne $st.autoFillAvailableFields) { X "$si<AutoFillAvailableFields>$(if ($st.autoFillAvailableFields){'true'}else{'false'})</AutoFillAvailableFields>" }
			$hasQuery = $st.query -and "$($st.query)".Trim()
			# Явный ключ manualQuery (в т.ч. false) ПОБЕЖДАЕТ эвристику hasQuery (платформа изредка
			# хранит QueryText при ManualQuery=false — декомпилятор фиксирует это отклонение).
			$hasMQKey = ($st.PSObject.Properties['manualQuery']) -and ($null -ne $st.manualQuery)
			$mq = if ($hasMQKey) { if ($st.manualQuery) { "true" } else { "false" } } elseif ($hasQuery) { "true" } else { "false" }
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
					# Тип поля набора: DataSetFieldField (дефолт) vs DataSetFieldNestedDataSet
					# (поле-вложенный набор = реквизит табличной части; маркер nested).
					# folder = папка-группировка полей (DataSetFieldFolder, без <field>); nested = вложенный набор.
					$isFolder = [bool](Get-Prop $fld 'folder')
					$ftype = if ($fld.nested) { "DataSetFieldNestedDataSet" } elseif ($isFolder) { "DataSetFieldFolder" } else { "DataSetFieldField" }
					X "$si<Field xsi:type=`"dcssch:$ftype`">"
					# dataPath: явный (включая пустой "" → self-closing <dcssch:dataPath/>) побеждает; иначе fallback на field.
					if ($null -ne (Get-Prop $fld 'dataPath')) { $dp = "$($fld.dataPath)" }
					elseif ($isFolder) { $dp = "" }
					else { $dp = "$($fld.field)" }
					if ($dp -eq "") { X "$si`t<dcssch:dataPath/>" } else { X "$si`t<dcssch:dataPath>$(Esc-Xml "$dp")</dcssch:dataPath>" }
					if (-not $isFolder) { X "$si`t<dcssch:field>$(Esc-Xml "$($fld.field)")</dcssch:field>" }
					if ($fld.title) {
						X "$si`t<dcssch:title xsi:type=`"v8:LocalStringType`">"
						Emit-MLItems -val $fld.title -indent "$si`t`t"
						X "$si`t</dcssch:title>"
					}
					# Ограничения использования поля — после title, перед presentationExpression (порядок исходника)
					Emit-RestrictBlock 'useRestriction' $fld.useRestriction "$si`t"
					Emit-RestrictBlock 'attributeUseRestriction' $fld.attributeUseRestriction "$si`t"
					# presentationExpression поля — перед valueType (порядок исходника)
					if ($fld.presentationExpression) { X "$si`t<dcssch:presentationExpression>$(Esc-Xml "$($fld.presentationExpression)")</dcssch:presentationExpression>" }
					# valueType поля набора (тип значения; вычисляемые/кастомные поля)
					if ($fld.valueType) { Emit-DLValueType -typeStr "$($fld.valueType)" -indent "$si`t" }
					# appearance поля (формат/оформление) — после valueType (порядок исходника)
					if ($fld.appearance) {
						X "$si`t<dcssch:appearance>"
						foreach ($prop in $fld.appearance.PSObject.Properties) { Emit-AppearanceValue -key $prop.Name -val $prop.Value -indent "$si`t`t" }
						X "$si`t</dcssch:appearance>"
					}
					# inputParameters поля (связь по параметрам выбора) — в конце
					if ($fld.inputParameters) { Emit-DLInputParameters -ip $fld.inputParameters -indent "$si`t" }
					X "$si</Field>"
				}
			}
			# Вычисляемые поля DataSet (<CalculatedField>) — после Field*, до Parameter*.
			Emit-CalcFields -calcFields $st.calculatedFields -indent $si
			# Schema-параметры дин-списка (DataCompositionSchemaParameter) — после Field*, до MainTable.
			Emit-DLParameters -params $st.parameters -indent $si
			# Ключ набора (query-based список без MainTable): KeyType (RowNumber/FieldValue/RowKey)
			# + KeyField* — после Parameter*, до MainTable. Захват/эмит факт. значений.
			if ($st.keyType) { X "$si<KeyType>$(Esc-Xml "$($st.keyType)")</KeyType>" }
			if ($st.keyFields) { foreach ($kf in @($st.keyFields)) { X "$si<KeyField>$(Esc-Xml "$kf")</KeyField>" } }
			if ($st.mainTable) { X "$si<MainTable>$(Normalize-MetaTypeRef "$($st.mainTable)")</MainTable>" }
			# GetInvisibleFieldPresentations — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении false).
			if ($null -ne $st.getInvisibleFieldPresentations) { X "$si<GetInvisibleFieldPresentations>$(if ($st.getInvisibleFieldPresentations){'true'}else{'false'})</GetInvisibleFieldPresentations>" }
			# AutoSaveUserSettings — после MainTable (дефолт true; эмитим только при заданном ключе = отклонении).
			if ($null -ne $st.autoSaveUserSettings) { X "$si<AutoSaveUserSettings>$(if ($st.autoSaveUserSettings){'true'}else{'false'})</AutoSaveUserSettings>" }
			# ListSettings: filter/order/conditionalAppearance (skd-грамматика) + каноничные блок-GUID.
			# Нет items → контейнеры всё равно эмитятся (blockMeta) = каноничный пустой скелет платформы.
			$lsi = "$si`t"
			$lsOpenLen = $script:xml.Length
			X "$si<ListSettings>"
			$lsAfterOpenLen = $script:xml.Length  # для self-closing, если внутри ничего не эмитнётся
			if ($st.PSObject.Properties['listSettings'] -and $null -ne $st.listSettings) {
				# Частичная/минимальная форма скелета — эмитим ТОЛЬКО указанные части с их блок-метой.
				# meta: 'v'=viewMode, 'u'=userSettingID (контейнеры); itemsViewMode/itemsUserSettingID → present.
				foreach ($prop in $st.listSettings.PSObject.Properties) {
					$tag = $prop.Name; $pv = $prop.Value
					# Значение дескриптора: строка-код "vu" ИЛИ объект { meta:"vu", presentation:<текст/ML> }
					# (контейнер несёт собственный userSettingPresentation — кастомную подпись настройки).
					if (($pv -is [PSCustomObject]) -or ($pv -is [System.Collections.IDictionary])) {
						$meta = "$(Get-Prop $pv 'meta')"; $bpres = Get-Prop $pv 'presentation'
					} else { $meta = "$pv"; $bpres = $null }
					$bvm = if ($meta -match 'v') { 'Normal' } else { $null }
					switch ($tag) {
						'filter'                { $bus = if ($meta -match 'u') { $script:CANON_FILTER_ID } else { $null }; Emit-Filter -items $st.filter -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'order'                 { $bus = if ($meta -match 'u') { $script:CANON_ORDER_ID } else { $null }; Emit-Order -items $st.order -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'conditionalAppearance' { $bus = if ($meta -match 'u') { $script:CANON_CA_ID } else { $null }; Emit-ConditionalAppearance -items $st.conditionalAppearance -indent $lsi -blockViewMode $bvm -blockUserSettingID $bus -blockUserSettingPresentation $bpres }
						'itemsViewMode'         { X "$lsi<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>" }
						'itemsUserSettingID'    { X "$lsi<dcsset:itemsUserSettingID>$($script:CANON_ITEMS_ID)</dcsset:itemsUserSettingID>" }
						'itemsUserSettingPresentation' { Emit-USPresentation -val $pv -tag "dcsset:itemsUserSettingPresentation" -indent $lsi }
						'dataParameters'        { Emit-DataParameters -items $st.dataParameters -indent $lsi }
						'structure'             { Emit-ListGrouping (Get-ListGroupingValue $st) $lsi }
					}
				}
			} else {
				# Полный каноничный скелет (умолчание, ~93% форм) — без изменений.
				Emit-Filter -items $st.filter -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_FILTER_ID
				# dataParameters — после filter, до order (XSD-порядок ListSettings)
				if ($st.PSObject.Properties['dataParameters']) { Emit-DataParameters -items $st.dataParameters -indent $lsi }
				Emit-Order -items $st.order -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_ORDER_ID
				Emit-ConditionalAppearance -items $st.conditionalAppearance -indent $lsi -blockViewMode 'Normal' -blockUserSettingID $script:CANON_CA_ID
				# Группировка строк списка (авторинг без round-trip дескриптора) — после CA, до itemsViewMode
				Emit-ListGrouping (Get-ListGroupingValue $st) $lsi
				X "$lsi<dcsset:itemsViewMode>Normal</dcsset:itemsViewMode>"
				X "$lsi<dcsset:itemsUserSettingID>$($script:CANON_ITEMS_ID)</dcsset:itemsUserSettingID>"
			}
			if ($script:xml.Length -eq $lsAfterOpenLen) {
				# Пустой дескриптор listSettings:{} (оригинал = <ListSettings/>) → зеркалим self-closing.
				$script:xml.Length = $lsOpenLen
				X "$si<ListSettings/>"
			} else {
				X "$si</ListSettings>"
			}
			X "$inner</Settings>"
		}

		X "$indent`t</Attribute>"
	}
	# Условное оформление формы — последний child <Attributes> (та же DCS-грамматика, что settings CA)
	Emit-ConditionalAppearance -items $conditionalAppearance -indent "$indent`t" -wrapTag 'ConditionalAppearance'
	X "$indent</Attributes>"
}

# --- 9. Parameter emitter ---

function Emit-Parameters {
	param($params, [string]$indent)

	if (-not $params -or $params.Count -eq 0) { return }

	X "$indent<Parameters>"
	$seenParams = @{}
	foreach ($param in $params) {
		Assert-UniqueName -name "$($param.name)" -seen $seenParams -kind 'parameter'
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
	$seenCmds = @{}
	foreach ($cmd in $cmds) {
		$cmdId = New-Id
		Assert-UniqueName -name "$($cmd.name)" -seen $seenCmds -kind 'command'
		X "$indent`t<Command name=`"$($cmd.name)`" id=`"$cmdId`">"
		$inner = "$indent`t`t"

		# Заголовок команды (зеркало Emit-Title): ключ есть+непустой → эмитим; ключ есть+"" → суппресс
		# (в оригинале <Title> нет — не додумывать); ключ отсутствует → авто-вывод из имени (помощь модели).
		if ($null -ne $cmd.PSObject.Properties['title']) {
			if ($cmd.title) { Emit-MLText -tag "Title" -text $cmd.title -indent $inner }
		} else {
			$cmdTitle = Title-FromName -name "$($cmd.name)"
			if ($cmdTitle) { Emit-MLText -tag "Title" -text $cmdTitle -indent $inner }
		}

		if ($cmd.tooltip) {
			Emit-MLText -tag "ToolTip" -text $cmd.tooltip -indent $inner
		}

		# Доступность команды по ролям (после ToolTip, до Action)
		if ($null -ne $cmd.use) { Emit-XrFlag -tag 'Use' -val $cmd.use -indent $inner }

		if ($cmd.action) {
			X "$inner<Action>$($cmd.action)</Action>"
		}

		if ($cmd.modifiesSavedData -eq $true) { X "$inner<ModifiesSavedData>true</ModifiesSavedData>" }

		Emit-FunctionalOptions -fo $cmd.functionalOptions -indent $inner

		if ($cmd.currentRowUse) {
			X "$inner<CurrentRowUse>$($cmd.currentRowUse)</CurrentRowUse>"
		}

		# Используемая таблица — имя элемента-таблицы (xsi:type обязателен).
		# Forgiving-ключи: table / associatedTableElementId (XML-тег) / ИспользуемаяТаблица (рус., регистр-незав.)
		$cmdTable = $cmd.table
		if (-not $cmdTable) { $cmdTable = $cmd.associatedTableElementId }
		if (-not $cmdTable) { $cmdTable = $cmd.используемаяТаблица }
		if ($cmdTable) {
			X "$inner<AssociatedTableElementId xsi:type=`"xs:string`">$(Esc-Xml "$cmdTable")</AssociatedTableElementId>"
		}

		if ($cmd.shortcut) {
			X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>"
		}

		Emit-CommandPicture -pic $cmd.picture -elemLt $cmd.loadTransparent -indent $inner

		if ($cmd.representation) {
			X "$inner<Representation>$($cmd.representation)</Representation>"
		}

		X "$indent`t</Command>"
	}
	X "$indent</Commands>"
}

# Резолв ключа-группы древовидной формы → CommandGroup (зависит от панели). Дружелюбные
# алиасы стандартных form-групп; любой иной ключ (CommandGroup.X / GUID / "") — verbatim.
function Resolve-CommandGroupKey {
	param([string]$key, [string]$panelTag)
	$k = ($key -replace '\s','').ToLower()
	if ($panelTag -eq 'NavigationPanel') {
		switch ($k) {
			'important' { return 'FormNavigationPanelImportant' }
			'важное'    { return 'FormNavigationPanelImportant' }
			'goto'      { return 'FormNavigationPanelGoTo' }
			'перейти'   { return 'FormNavigationPanelGoTo' }
			'seealso'   { return 'FormNavigationPanelSeeAlso' }
			'смтакже'   { return 'FormNavigationPanelSeeAlso' }
		}
	} else {
		switch ($k) {
			'important'          { return 'FormCommandBarImportant' }
			'важное'             { return 'FormCommandBarImportant' }
			'createbasedon'      { return 'FormCommandBarCreateBasedOn' }
			'создатьнаосновании' { return 'FormCommandBarCreateBasedOn' }
		}
	}
	return $key  # verbatim
}

# Командный интерфейс формы (<CommandInterface>): панели CommandBar + NavigationPanel.
# Значение панели: МАССИВ (плоская форма; элемент может нести group) ИЛИ ОБЪЕКТ
# (древовидная форма: {группа: [команды]}, group берётся из ключа, элементы его не дублируют).
# Элемент: строка (голый command, Type=Auto) или объект. Порядок тегов:
# Command, Type(деф. Auto), Attribute, CommandGroup, Index, DefaultVisible, Visible(xr-flag).
function Emit-CommandInterface {
	param($ci, [string]$indent)
	if (-not $ci) { return }
	$inner = "$indent`t"
	$panels = @(
		@{ Tag='CommandBar';      Syns=@('commandBar','команднаяПанель','КоманднаяПанель') },
		@{ Tag='NavigationPanel'; Syns=@('navigationPanel','панельНавигации','ПанельНавигации') }
	)
	$present = @()
	foreach ($p in $panels) {
		$items = $null
		foreach ($syn in $p.Syns) { if ($null -ne $ci.PSObject.Properties[$syn]) { $items = $ci.($syn); break } }
		if ($null -ne $items) { $present += ,@{ Tag=$p.Tag; Items=$items } }
	}
	if ($present.Count -eq 0) { return }
	X "$indent<CommandInterface>"
	foreach ($p in $present) {
		X "$inner<$($p.Tag)>"
		# Нормализация: плоский список пар (элемент, group-из-дерева). Объект → дерево.
		$flat = New-Object System.Collections.ArrayList
		if ($p.Items -is [System.Management.Automation.PSCustomObject]) {
			foreach ($prop in $p.Items.PSObject.Properties) {
				$grpFromTree = Resolve-CommandGroupKey -key $prop.Name -panelTag $p.Tag
				foreach ($it in @($prop.Value)) { [void]$flat.Add(@{ item=$it; treeGroup=$grpFromTree }) }
			}
		} else {
			foreach ($it in @($p.Items)) { [void]$flat.Add(@{ item=$it; treeGroup=$null }) }
		}
		foreach ($fi in $flat) {
			$item = $fi.item; $treeGroup = $fi.treeGroup
			if ($item -is [string]) {
				$cmd = $item; $type = 'Auto'; $attr = $null; $grp = $null; $idx = $null; $dv = $null; $vis = $null
			} else {
				$cmd  = Get-ElProp $item @('command','команда')
				$type = Get-ElProp $item @('type','тип'); if (-not $type) { $type = 'Auto' }
				$attr = Get-ElProp $item @('attribute','реквизит')
				$grp  = Get-ElProp $item @('group','группа','группаКоманд')
				$idx  = Get-ElProp $item @('index','индекс')
				$dv   = Get-ElProp $item @('defaultVisible','видимость','видимостьПоУмолчанию')
				$vis  = Get-ElProp $item @('visible','видимостьПоРолям','настройкаВидимости')
			}
			# group из дерева побеждает (если задан и непустой); явный group элемента — фолбэк
			if ($treeGroup) { $grp = $treeGroup }
			X "$inner`t<Item>"
			X "$inner`t`t<Command>$(Esc-Xml "$cmd")</Command>"
			X "$inner`t`t<Type>$type</Type>"
			if ($attr) { X "$inner`t`t<Attribute>$(Esc-Xml "$attr")</Attribute>" }
			if ($grp)  { X "$inner`t`t<CommandGroup>$(Esc-Xml "$grp")</CommandGroup>" }
			if ($null -ne $idx) { X "$inner`t`t<Index>$idx</Index>" }
			if ($null -ne $dv)  { X "$inner`t`t<DefaultVisible>$(if ($dv){'true'}else{'false'})</DefaultVisible>" }
			if ($null -ne $vis) { Emit-XrFlag -tag 'Visible' -val $vis -indent "$inner`t`t" }
			X "$inner`t</Item>"
		}
		X "$inner</$($p.Tag)>"
	}
	X "$indent</CommandInterface>"
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
		# Пустая строка = суппресс-маркер (напр. autoTitle:"" — не эмитить и не додумывать)
		if ($val -is [string] -and $val -eq '') { continue }
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
		# RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ.
		# Декомпилятор опускает ключ при rpdp == smart-default (ждёт реинъекции); реальное отсутствие
		# фиксирует ""-маркером (НЕ перезатирается). Гейт hasMainTable снят: дин-список без mainTable
		# (напр. query-based) тоже несёт RowPictureDataPath.
		if ($null -eq $el.PSObject.Properties["rowPictureDataPath"]) {
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
$script:seenElementNames = @{}  # пул имён элементов (глобально по всей форме)

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

# 12c2. MobileDeviceCommandBarContent — форменный список имён командных панелей/кнопок
# (Presentation пустой, CheckState=0, тип xs:string — константы; варьируется только имя-Value).
# $null-проверка (не truthy): одноэлементный массив с пустой строкой @("") разворачивается
# в boolean-контексте в "" → falsy; 12 форм корпуса несут один пустой item (Value="").
if ($null -ne $def.mobileCommandBarContent -and @($def.mobileCommandBarContent).Count -gt 0) {
	X "`t<MobileDeviceCommandBarContent>"
	foreach ($nm in @($def.mobileCommandBarContent)) {
		X "`t`t<xr:Item>"
		X "`t`t`t<xr:Presentation/>"
		X "`t`t`t<xr:CheckState>0</xr:CheckState>"
		# пустое значение → самозакрывающийся тег (зеркало платформы)
		if ([string]::IsNullOrEmpty("$nm")) { X "`t`t`t<xr:Value xsi:type=`"xs:string`"/>" }
		else { X "`t`t`t<xr:Value xsi:type=`"xs:string`">$(Esc-Xml "$nm")</xr:Value>" }
		X "`t`t</xr:Item>"
	}
	X "`t</MobileDeviceCommandBarContent>"
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
$acbDIAttr = if ($script:mainAcbDef) { DI-Attr $script:mainAcbDef } else { "" }   # DisplayImportance форменной панели
$acbHasInner = ($acbHAlign -or (-not $acbAutofill) -or $hasAcbChildren)
if ($acbHasInner) {
	X "`t<AutoCommandBar name=`"$acbName`" id=`"-1`"$acbDIAttr>"
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
	X "`t<AutoCommandBar name=`"$acbName`" id=`"-1`"$acbDIAttr/>"
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
Emit-Attributes -attrs $def.attributes -indent "`t" -conditionalAppearance $def.conditionalAppearance

# 12h. Parameters
Emit-Parameters -params $def.parameters -indent "`t"

# 12i. Commands
Emit-Commands -cmds $def.commands -indent "`t"

# 12i2. CommandInterface (командный интерфейс формы — последний дочерний Form)
Emit-CommandInterface -ci $def.commandInterface -indent "`t"

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
