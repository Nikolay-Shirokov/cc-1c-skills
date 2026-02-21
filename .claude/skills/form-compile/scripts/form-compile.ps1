# form-compile v1.0 — Compile 1C managed form from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$json = Get-Content -Raw -Encoding UTF8 $JsonPath
$def = $json | ConvertFrom-Json

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

function Emit-Type {
	param($typeStr, [string]$indent)

	if (-not $typeStr) {
		X "$indent<Type/>"
		return
	}

	$typeString = "$typeStr"

	# Composite type: "Type1 | Type2"
	$parts = $typeString -split '\s*\|\s*'

	X "$indent<Type>"
	foreach ($part in $parts) {
		$part = $part.Trim()
		Emit-SingleType -typeStr $part -indent "$indent`t"
	}
	X "$indent</Type>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

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
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|InformationRegisterRecordSet|AccumulationRegisterRecordSet|DataProcessorObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
		return
	}

	# Fallback: emit as-is with cfg: prefix if contains dot, otherwise v8:
	if ($typeStr.Contains('.')) {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"
	} else {
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
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1
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

	# Companions
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
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

# --- 12. Main compilation ---

# Title
if ($def.title) {
	Emit-MLText -tag "Title" -text "$($def.title)" -indent "`t"
}

# Header
X '<?xml version="1.0" encoding="UTF-8"?>'
X '<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">'

# Oops — Title was emitted before header. Need to fix the order.
# Actually, let me restructure: build the body into a separate buffer, then assemble

# Reset and rebuild properly
$script:xml = New-Object System.Text.StringBuilder 8192
$script:nextId = 1

X '<?xml version="1.0" encoding="UTF-8"?>'
X '<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">'

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
X "`t<AutoCommandBar name=`"ФормаКоманднаяПанель`" id=`"-1`">"
X "`t`t<HorizontalAlign>Right</HorizontalAlign>"
X "`t`t<Autofill>false</Autofill>"
X "`t</AutoCommandBar>"

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
