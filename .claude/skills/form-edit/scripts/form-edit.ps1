# form-edit v1.0 — Edit 1C managed form elements
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$FormPath,

	[Parameter(Mandatory)]
	[string]$JsonPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# === 1. Load Form.xml ===

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}
if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$resolvedFormPath = (Resolve-Path $FormPath).Path
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
try {
	$xmlDoc.Load($resolvedFormPath)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	exit 1
}

$formNs = "http://v8.1c.ru/8.3/xcf/logform"
$v8Ns = "http://v8.1c.ru/8.1/data/core"
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", $formNs)
$nsMgr.AddNamespace("v8", $v8Ns)

$root = $xmlDoc.DocumentElement

# === 2. Load JSON ===

$def = Get-Content -Raw -Encoding UTF8 $JsonPath | ConvertFrom-Json

# === 3. Form name + header ===

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($resolvedFormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

Write-Host "=== form-edit: $formName ==="
Write-Host ""

# === 4. Scan max IDs per pool ===

$script:nextElemId = 0
$script:nextAttrId = 0
$script:nextCmdId = 0

# Scan ALL element IDs via XPath (includes companions like ExtendedTooltip, ContextMenu)
$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($rootCI) {
	foreach ($elem in $rootCI.SelectNodes(".//*[@id]")) {
		$id = $elem.GetAttribute("id")
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	$id = $acb.GetAttribute("id")
	if ($id -and $id -ne "-1") {
		try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
	}
}

# Scan attribute IDs (including column IDs — same pool)
foreach ($attr in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
	$id = $attr.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextAttrId) { $script:nextAttrId = $intId } } catch {}
	}
	# Column IDs are in the same pool as attribute IDs
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		if ($colId) {
			try { $intColId = [int]$colId; if ($intColId -gt $script:nextAttrId) { $script:nextAttrId = $intColId } } catch {}
		}
	}
}

# Scan command IDs
foreach ($cmd in $root.SelectNodes("f:Commands/f:Command", $nsMgr)) {
	$id = $cmd.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextCmdId) { $script:nextCmdId = $intId } } catch {}
	}
}

$script:nextElemId++
$script:nextAttrId++
$script:nextCmdId++

function New-ElemId { $id = $script:nextElemId; $script:nextElemId++; return $id }
function New-AttrId { $id = $script:nextAttrId; $script:nextAttrId++; return $id }
function New-CmdId { $id = $script:nextCmdId; $script:nextCmdId++; return $id }

# For element emitters, New-Id = New-ElemId
function New-Id { return New-ElemId }

# === 5. Fragment helpers (StringBuilder + Emit-* from form-compile) ===

$script:xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Emit-MLText {
	param([string]$tag, [string]$text, [string]$indent)
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

# --- Type emitter ---

function Emit-Type {
	param($typeStr, [string]$indent)
	if (-not $typeStr) { X "$indent<Type/>"; return }
	$typeString = "$typeStr"
	$parts = $typeString -split '\s*\|\s*'
	X "$indent<Type>"
	foreach ($part in $parts) {
		Emit-SingleType -typeStr $part.Trim() -indent "$indent`t"
	}
	X "$indent</Type>"
}

function Emit-SingleType {
	param([string]$typeStr, [string]$indent)

	if ($typeStr -eq "boolean") {
		X "$indent<v8:Type>xs:boolean</v8:Type>"; return
	}
	if ($typeStr -match '^string(\((\d+)\))?$') {
		$len = if ($Matches[2]) { $Matches[2] } else { "0" }
		X "$indent<v8:Type>xs:string</v8:Type>"
		X "$indent<v8:StringQualifiers>"
		X "$indent`t<v8:Length>$len</v8:Length>"
		X "$indent`t<v8:AllowedLength>Variable</v8:AllowedLength>"
		X "$indent</v8:StringQualifiers>"; return
	}
	if ($typeStr -match '^decimal\((\d+),(\d+)(,nonneg)?\)$') {
		$digits = $Matches[1]; $fraction = $Matches[2]
		$sign = if ($Matches[3]) { "Nonnegative" } else { "Any" }
		X "$indent<v8:Type>xs:decimal</v8:Type>"
		X "$indent<v8:NumberQualifiers>"
		X "$indent`t<v8:Digits>$digits</v8:Digits>"
		X "$indent`t<v8:FractionDigits>$fraction</v8:FractionDigits>"
		X "$indent`t<v8:AllowedSign>$sign</v8:AllowedSign>"
		X "$indent</v8:NumberQualifiers>"; return
	}
	if ($typeStr -match '^(date|dateTime|time)$') {
		$fractions = switch ($typeStr) { "date" { "Date" } "dateTime" { "DateTime" } "time" { "Time" } }
		X "$indent<v8:Type>xs:dateTime</v8:Type>"
		X "$indent<v8:DateQualifiers>"
		X "$indent`t<v8:DateFractions>$fractions</v8:DateFractions>"
		X "$indent</v8:DateQualifiers>"; return
	}
	$v8Types = @{
		"ValueTable" = "v8:ValueTable"; "ValueTree" = "v8:ValueTree"; "ValueList" = "v8:ValueListType"
		"TypeDescription" = "v8:TypeDescription"; "Universal" = "v8:Universal"
		"FixedArray" = "v8:FixedArray"; "FixedStructure" = "v8:FixedStructure"
	}
	if ($v8Types.ContainsKey($typeStr)) { X "$indent<v8:Type>$($v8Types[$typeStr])</v8:Type>"; return }
	$uiTypes = @{ "FormattedString" = "v8ui:FormattedString"; "Picture" = "v8ui:Picture"; "Color" = "v8ui:Color"; "Font" = "v8ui:Font" }
	if ($uiTypes.ContainsKey($typeStr)) { X "$indent<v8:Type>$($uiTypes[$typeStr])</v8:Type>"; return }
	if ($typeStr -eq "DynamicList") { X "$indent<v8:Type>cfg:DynamicList</v8:Type>"; return }
	if ($typeStr -match '^DataComposition') {
		$dcsMap = @{ "DataCompositionSettings" = "dcsset:DataCompositionSettings"; "DataCompositionSchema" = "dcssch:DataCompositionSchema"; "DataCompositionComparisonType" = "dcscor:DataCompositionComparisonType" }
		if ($dcsMap.ContainsKey($typeStr)) { X "$indent<v8:Type>$($dcsMap[$typeStr])</v8:Type>"; return }
	}
	if ($typeStr -match '^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef|ExchangePlanRef|BusinessProcessRef|TaskRef|InformationRegisterRecordSet|AccumulationRegisterRecordSet|DataProcessorObject)\.') {
		X "$indent<v8:Type>cfg:$typeStr</v8:Type>"; return
	}
	if ($typeStr.Contains('.')) { X "$indent<v8:Type>cfg:$typeStr</v8:Type>" }
	else { X "$indent<v8:Type>$typeStr</v8:Type>" }
}

# --- Event handler name generator ---

$script:eventSuffixMap = @{
	"OnChange" = "ПриИзменении"; "StartChoice" = "НачалоВыбора"; "ChoiceProcessing" = "ОбработкаВыбора"
	"AutoComplete" = "АвтоПодбор"; "Clearing" = "Очистка"; "Opening" = "Открытие"; "Click" = "Нажатие"
	"OnActivateRow" = "ПриАктивизацииСтроки"; "BeforeAddRow" = "ПередНачаломДобавления"
	"BeforeDeleteRow" = "ПередУдалением"; "BeforeRowChange" = "ПередНачаломИзменения"
	"OnStartEdit" = "ПриНачалеРедактирования"; "OnEndEdit" = "ПриОкончанииРедактирования"
	"Selection" = "ВыборСтроки"; "OnCurrentPageChange" = "ПриСменеСтраницы"
	"TextEditEnd" = "ОкончаниеВводаТекста"; "URLProcessing" = "ОбработкаНавигационнойСсылки"
	"DragStart" = "НачалоПеретаскивания"; "Drag" = "Перетаскивание"
	"DragCheck" = "ПроверкаПеретаскивания"; "Drop" = "Помещение"; "AfterDeleteRow" = "ПослеУдаления"
}

function Get-HandlerName {
	param([string]$elementName, [string]$eventName)
	$suffix = $script:eventSuffixMap[$eventName]
	if ($suffix) { return "$elementName$suffix" }
	return "$elementName$eventName"
}

# --- Element helpers ---

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
		$handler = if ($el.handlers -and $el.handlers.$evtName) { "$($el.handlers.$evtName)" }
		else { Get-HandlerName -elementName $elementName -eventName $evtName }
		X "$indent`t<Event name=`"$evtName`">$handler</Event>"
	}
	X "$indent</Events>"
}

function Emit-Companion {
	param([string]$tag, [string]$name, [string]$indent)
	$id = New-Id
	X "$indent<$tag name=`"$name`" id=`"$id`"/>"
}

function Emit-CommonFlags {
	param($el, [string]$indent)
	if ($el.visible -eq $false -or $el.hidden -eq $true) { X "$indent<Visible>false</Visible>" }
	if ($el.enabled -eq $false -or $el.disabled -eq $true) { X "$indent<Enabled>false</Enabled>" }
	if ($el.readOnly -eq $true) { X "$indent<ReadOnly>true</ReadOnly>" }
}

function Emit-Title {
	param($el, [string]$name, [string]$indent)
	if ($el.title) { Emit-MLText -tag "Title" -text "$($el.title)" -indent $indent }
}

# --- Element emitters ---

function Emit-Group {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<UsualGroup name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	Emit-Title -el $el -name $name -indent $inner
	$groupVal = "$($el.group)"
	$orientation = switch ($groupVal) {
		"horizontal" { "Horizontal" } "vertical" { "Vertical" }
		"alwaysHorizontal" { "AlwaysHorizontal" } "alwaysVertical" { "AlwaysVertical" }
		default { $null }
	}
	if ($orientation) { X "$inner<Group>$orientation</Group>" }
	if ($groupVal -eq "collapsible") { X "$inner<Group>Vertical</Group>"; X "$inner<Behavior>Collapsible</Behavior>" }
	if ($el.representation) {
		$repr = switch ("$($el.representation)") { "none" { "None" } "normal" { "NormalSeparation" } "weak" { "WeakSeparation" } "strong" { "StrongSeparation" } default { "$($el.representation)" } }
		X "$inner<Representation>$repr</Representation>"
	}
	if ($el.showTitle -eq $false) { X "$inner<ShowTitle>false</ShowTitle>" }
	if ($el.united -eq $false) { X "$inner<United>false</United>" }
	Emit-CommonFlags -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
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
		$loc = switch ("$($el.titleLocation)") { "none" { "None" } "left" { "Left" } "right" { "Right" } "top" { "Top" } "bottom" { "Bottom" } default { "$($el.titleLocation)" } }
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
	if ($el.inputHint) { Emit-MLText -tag "InputHint" -text "$($el.inputHint)" -indent $inner }
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
	if ($el.titleLocation) { X "$inner<TitleLocation>$($el.titleLocation)</TitleLocation>" }
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
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.changeRowSet -eq $true) { X "$inner<ChangeRowSet>true</ChangeRowSet>" }
	if ($el.changeRowOrder -eq $true) { X "$inner<ChangeRowOrder>true</ChangeRowOrder>" }
	if ($el.height) { X "$inner<HeightInTableRows>$($el.height)</HeightInTableRows>" }
	if ($el.header -eq $false) { X "$inner<Header>false</Header>" }
	if ($el.footer -eq $true) { X "$inner<Footer>true</Footer>" }
	if ($el.commandBarLocation) { X "$inner<CommandBarLocation>$($el.commandBarLocation)</CommandBarLocation>" }
	if ($el.searchStringLocation) { X "$inner<SearchStringLocation>$($el.searchStringLocation)</SearchStringLocation>" }
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "AutoCommandBar" -name "${name}КоманднаяПанель" -indent $inner
	Emit-Companion -tag "SearchStringAddition" -name "${name}СтрокаПоиска" -indent $inner
	Emit-Companion -tag "ViewStatusAddition" -name "${name}СостояниеПросмотра" -indent $inner
	Emit-Companion -tag "SearchControlAddition" -name "${name}УправлениеПоиском" -indent $inner
	if ($el.columns -and $el.columns.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($col in $el.columns) { Emit-Element -el $col -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "table"
	X "$indent</Table>"
}

function Emit-Pages {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Pages name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.pagesRepresentation) { X "$inner<PagesRepresentation>$($el.pagesRepresentation)</PagesRepresentation>" }
	Emit-CommonFlags -el $el -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "pages"
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
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
		$orientation = switch ("$($el.group)") { "horizontal" { "Horizontal" } "vertical" { "Vertical" } "alwaysHorizontal" { "AlwaysHorizontal" } "alwaysVertical" { "AlwaysVertical" } default { $null } }
		if ($orientation) { X "$inner<Group>$orientation</Group>" }
	}
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</Page>"
}

function Emit-Button {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<Button name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.type) {
		$btnType = switch ("$($el.type)") { "usual" { "UsualButton" } "hyperlink" { "Hyperlink" } "commandBar" { "CommandBarButton" } default { "$($el.type)" } }
		X "$inner<Type>$btnType</Type>"
	}
	if ($el.command) { X "$inner<CommandName>Form.Command.$($el.command)</CommandName>" }
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
	if ($el.picture) {
		X "$inner<Picture>"
		X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"
		X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
		X "$inner</Picture>"
	}
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.locationInCommandBar) { X "$inner<LocationInCommandBar>$($el.locationInCommandBar)</LocationInCommandBar>" }
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
		X "$inner<Picture>"; X "$inner`t<xr:Ref>$ref</xr:Ref>"; X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"; X "$inner</Picture>"
	}
	if ($el.hyperlink -eq $true) { X "$inner<Hyperlink>true</Hyperlink>" }
	if ($el.width) { X "$inner<Width>$($el.width)</Width>" }
	if ($el.height) { X "$inner<Height>$($el.height)</Height>" }
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
	Emit-Companion -tag "ContextMenu" -name "${name}КонтекстноеМеню" -indent $inner
	Emit-Companion -tag "ExtendedTooltip" -name "${name}РасширеннаяПодсказка" -indent $inner
	Emit-Events -el $el -elementName $name -indent $inner -typeKey "calendar"
	X "$indent</CalendarField>"
}

function Emit-CommandBarEl {
	param($el, [string]$name, [int]$id, [string]$indent)
	X "$indent<CommandBar name=`"$name`" id=`"$id`">"
	$inner = "$indent`t"
	if ($el.autofill -eq $true) { X "$inner<Autofill>true</Autofill>" }
	Emit-CommonFlags -el $el -indent $inner
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
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
		X "$inner<Picture>"; X "$inner`t<xr:Ref>$($el.picture)</xr:Ref>"; X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"; X "$inner</Picture>"
	}
	if ($el.representation) { X "$inner<Representation>$($el.representation)</Representation>" }
	if ($el.children -and $el.children.Count -gt 0) {
		X "$inner<ChildItems>"
		foreach ($child in $el.children) { Emit-Element -el $child -indent "$inner`t" }
		X "$inner</ChildItems>"
	}
	X "$indent</Popup>"
}

# --- Element dispatcher ---

function Emit-Element {
	param($el, [string]$indent)

	$typeKey = $null
	foreach ($key in @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
		if ($el.$key -ne $null) { $typeKey = $key; break }
	}
	if (-not $typeKey) { Write-Warning "Unknown element type, skipping"; return }

	# Validate known keys — warn about typos
	$knownKeys = @{
		"group"=1;"input"=1;"check"=1;"label"=1;"labelField"=1;"table"=1;"pages"=1;"page"=1
		"button"=1;"picture"=1;"picField"=1;"calendar"=1;"cmdBar"=1;"popup"=1
		"name"=1;"path"=1;"title"=1
		"visible"=1;"hidden"=1;"enabled"=1;"disabled"=1;"readOnly"=1
		"on"=1;"handlers"=1
		"titleLocation"=1;"representation"=1;"width"=1;"height"=1
		"horizontalStretch"=1;"verticalStretch"=1;"autoMaxWidth"=1;"autoMaxHeight"=1
		"multiLine"=1;"passwordMode"=1;"choiceButton"=1;"clearButton"=1
		"spinButton"=1;"dropListButton"=1;"markIncomplete"=1;"skipOnInput"=1;"inputHint"=1
		"hyperlink"=1;"showTitle"=1;"united"=1;"children"=1;"columns"=1
		"changeRowSet"=1;"changeRowOrder"=1;"header"=1;"footer"=1
		"commandBarLocation"=1;"searchStringLocation"=1;"pagesRepresentation"=1
		"type"=1;"command"=1;"stdCommand"=1;"defaultButton"=1;"locationInCommandBar"=1
		"src"=1;"autofill"=1
	}
	foreach ($p in $el.PSObject.Properties) {
		if (-not $knownKeys.ContainsKey($p.Name)) {
			Write-Warning "Element '$($el.$typeKey)': unknown key '$($p.Name)' — ignored."
		}
	}

	$name = Get-ElementName -el $el -typeKey $typeKey
	$id = New-Id

	switch ($typeKey) {
		"group"     { Emit-Group -el $el -name $name -id $id -indent $indent }
		"input"     { Emit-Input -el $el -name $name -id $id -indent $indent }
		"check"     { Emit-Check -el $el -name $name -id $id -indent $indent }
		"label"     { Emit-Label -el $el -name $name -id $id -indent $indent }
		"labelField" { Emit-LabelField -el $el -name $name -id $id -indent $indent }
		"table"     { Emit-Table -el $el -name $name -id $id -indent $indent }
		"pages"     { Emit-Pages -el $el -name $name -id $id -indent $indent }
		"page"      { Emit-Page -el $el -name $name -id $id -indent $indent }
		"button"    { Emit-Button -el $el -name $name -id $id -indent $indent }
		"picture"   { Emit-PictureDecoration -el $el -name $name -id $id -indent $indent }
		"picField"  { Emit-PictureField -el $el -name $name -id $id -indent $indent }
		"calendar"  { Emit-Calendar -el $el -name $name -id $id -indent $indent }
		"cmdBar"    { Emit-CommandBarEl -el $el -name $name -id $id -indent $indent }
		"popup"     { Emit-Popup -el $el -name $name -id $id -indent $indent }
	}
}

# === 6. Find element by name recursively ===

function Find-Element($startNode, [string]$targetName) {
	foreach ($child in $startNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childName = $child.GetAttribute("name")
		if ($childName -eq $targetName) { return $child }
		$ci = $child.SelectSingleNode("f:ChildItems", $nsMgr)
		if ($ci) {
			$found = Find-Element $ci $targetName
			if ($found) { return $found }
		}
	}
	return $null
}

# === 7. Detect indent level of a container's children ===

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	# Fallback: count depth from root
	$depth = 0
	$current = $container
	while ($current -and $current -ne $xmlDoc.DocumentElement) {
		$depth++
		$current = $current.ParentNode
	}
	return "`t" * ($depth + 1)
}

# === 8. Insert node into container ===

function Insert-IntoContainer($container, $newNode, $afterName, $childIndent) {
	$refNode = $null

	if ($afterName) {
		# Find the after-element, then insert after it
		$afterElem = $null
		foreach ($child in $container.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.GetAttribute("name") -eq $afterName) {
				$afterElem = $child
				break
			}
		}
		if ($afterElem) {
			$refNode = $afterElem.NextSibling
		} else {
			Write-Host "[WARN] after='$afterName' not found in target container, appending at end"
		}
	}

	if (-not $refNode) {
		# Append at end: insert before trailing whitespace
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$refNode = $trailing
		}
	}

	$ws = $xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $refNode) | Out-Null
	} else {
		# Container is empty (self-closing) — add framing whitespace
		$container.AppendChild($ws) | Out-Null
		$container.AppendChild($newNode) | Out-Null
		$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
		$closeWs = $xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

# === 9. Generate fragment, parse, import nodes ===

$allNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"'

function Parse-Fragment([string]$xmlText) {
	$fragDoc = New-Object System.Xml.XmlDocument
	$fragDoc.PreserveWhitespace = $true
	$fragDoc.LoadXml($xmlText)
	return $fragDoc
}

function Import-ElementNodes($fragDoc) {
	$nodes = @()
	foreach ($child in $fragDoc.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $xmlDoc.ImportNode($child, $true)
		}
	}
	return $nodes
}

# === 10. Add elements ===

$addedElems = @()
$companionCount = 0

if ($def.elements -and $def.elements.Count -gt 0) {
	# Resolve target container
	$targetCI = $null
	$intoName = if ($def.into) { "$($def.into)" } else { $null }
	$afterName = if ($def.after) { "$($def.after)" } else { $null }

	if ($intoName) {
		$targetGroup = Find-Element $rootCI $intoName
		if (-not $targetGroup) {
			Write-Host "[ERROR] Target group '$intoName' not found"
			exit 1
		}
		$targetCI = $targetGroup.SelectSingleNode("f:ChildItems", $nsMgr)
		if (-not $targetCI) {
			# Create ChildItems for the group
			$targetCI = $xmlDoc.CreateElement("ChildItems", $formNs)
			$targetGroup.AppendChild($targetCI) | Out-Null
		}
	} elseif ($afterName) {
		# Find the after element globally and use its parent as target
		$afterElem = Find-Element $rootCI $afterName
		if (-not $afterElem) {
			Write-Host "[ERROR] Element '$afterName' not found"
			exit 1
		}
		$targetCI = $afterElem.ParentNode
	} else {
		$targetCI = $rootCI
	}

	if (-not $targetCI) {
		# Create ChildItems section in form — insert after Events or AutoCommandBar
		$targetCI = $xmlDoc.CreateElement("ChildItems", $formNs)
		$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
		if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr) }
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($targetCI, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($targetCI) | Out-Null
		}
		# Also update $rootCI reference
		$rootCI = $targetCI
	}

	# Detect indent level
	$childIndent = Get-ChildIndent $targetCI

	# Check for duplicate element names
	foreach ($el in $def.elements) {
		$typeKey = $null
		foreach ($key in @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
			if ($el.$key -ne $null) { $typeKey = $key; break }
		}
		if ($typeKey) {
			$elName = Get-ElementName -el $el -typeKey $typeKey
			$existing = Find-Element $rootCI $elName
			if ($existing) {
				Write-Host "[WARN] Element '$elName' already exists in form (id=$($existing.GetAttribute('id')))"
			}
		}
	}

	# Remember starting element ID for companion counting
	$startElemId = $script:nextElemId

	# Generate fragment
	$script:xml = New-Object System.Text.StringBuilder 4096
	X "<_F $allNsDecl>"
	foreach ($el in $def.elements) {
		Emit-Element -el $el -indent $childIndent
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedNodes = Import-ElementNodes $fragDoc

	# Count actual elements (non-companion) for reporting
	foreach ($el in $def.elements) {
		$typeKey = $null
		foreach ($key in @("group","input","check","label","labelField","table","pages","page","button","picture","picField","calendar","cmdBar","popup")) {
			if ($el.$key -ne $null) { $typeKey = $key; break }
		}
		$name = Get-ElementName -el $el -typeKey $typeKey
		$tagMap = @{
			"group"="Group"; "input"="Input"; "check"="Check"; "label"="Label"; "labelField"="LabelField"
			"table"="Table"; "pages"="Pages"; "page"="Page"; "button"="Button"
			"picture"="Picture"; "picField"="PicField"; "calendar"="Calendar"; "cmdBar"="CmdBar"; "popup"="Popup"
		}
		$pathStr = if ($el.path) { " -> $($el.path)" } else { "" }
		$evtStr = if ($el.on) { " {$($el.on -join ', ')}" } else { "" }
		$addedElems += "  + [$($tagMap[$typeKey])] $name$pathStr$evtStr"
	}

	# Insert each imported node
	foreach ($node in $importedNodes) {
		Insert-IntoContainer -container $targetCI -newNode $node -afterName $afterName -childIndent $childIndent
		# Only use afterName for the first insertion; subsequent ones go after the previous
		$afterName = $node.GetAttribute("name")
	}

	$totalNewElemIds = $script:nextElemId - $startElemId
	$companionCount = $totalNewElemIds - $def.elements.Count
}

# === 11. Add attributes ===

$addedAttrs = @()

if ($def.attributes -and $def.attributes.Count -gt 0) {
	$attrsSection = $root.SelectSingleNode("f:Attributes", $nsMgr)
	if (-not $attrsSection) {
		# Create Attributes section — insert after ChildItems or after Events
		$attrsSection = $xmlDoc.CreateElement("Attributes", $formNs)
		# Find insertion point: after ChildItems or after the last pre-Attributes element
		$insertAfter = $rootCI
		if (-not $insertAfter) {
			$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
		}
		if (-not $insertAfter) {
			$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
		}
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($attrsSection, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($attrsSection) | Out-Null
		}
	}

	# Detect indent for attribute children
	$attrChildIndent = Get-ChildIndent $attrsSection
	if (-not $attrChildIndent -or $attrChildIndent -eq "") { $attrChildIndent = "`t`t" }

	# Generate attribute fragments
	$script:xml = New-Object System.Text.StringBuilder 2048
	X "<_F $allNsDecl>"
	foreach ($attr in $def.attributes) {
		$attrId = New-AttrId
		$attrName = "$($attr.name)"
		X "$attrChildIndent<Attribute name=`"$attrName`" id=`"$attrId`">"
		$inner = "$attrChildIndent`t"

		if ($attr.title) { Emit-MLText -tag "Title" -text "$($attr.title)" -indent $inner }
		if ($attr.type) { Emit-Type -typeStr "$($attr.type)" -indent $inner } else { X "$inner<Type/>" }
		if ($attr.main -eq $true) { X "$inner<MainAttribute>true</MainAttribute>" }
		if ($attr.savedData -eq $true) { X "$inner<SavedData>true</SavedData>" }
		if ($attr.fillChecking) { X "$inner<FillChecking>$($attr.fillChecking)</FillChecking>" }

		if ($attr.columns -and $attr.columns.Count -gt 0) {
			X "$inner<Columns>"
			$colId = 1
			foreach ($col in $attr.columns) {
				X "$inner`t<Column name=`"$($col.name)`" id=`"$colId`">"
				if ($col.title) { Emit-MLText -tag "Title" -text "$($col.title)" -indent "$inner`t`t" }
				Emit-Type -typeStr "$($col.type)" -indent "$inner`t`t"
				X "$inner`t</Column>"
				$colId++
			}
			X "$inner</Columns>"
		}

		X "$attrChildIndent</Attribute>"
		$typeStr = if ($attr.type) { "$($attr.type)" } else { "(no type)" }
		$addedAttrs += "  + ${attrName}: $typeStr (id=$attrId)"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedAttrs = Import-ElementNodes $fragDoc

	foreach ($node in $importedAttrs) {
		Insert-IntoContainer -container $attrsSection -newNode $node -afterName $null -childIndent $attrChildIndent
	}
}

# === 12. Add commands ===

$addedCmds = @()

if ($def.commands -and $def.commands.Count -gt 0) {
	$cmdsSection = $root.SelectSingleNode("f:Commands", $nsMgr)
	if (-not $cmdsSection) {
		# Create Commands section — insert after Parameters or Attributes
		$cmdsSection = $xmlDoc.CreateElement("Commands", $formNs)
		$insertAfter = $root.SelectSingleNode("f:Parameters", $nsMgr)
		if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:Attributes", $nsMgr) }
		if (-not $insertAfter) { $insertAfter = $rootCI }
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($cmdsSection, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($cmdsSection) | Out-Null
		}
	}

	$cmdChildIndent = Get-ChildIndent $cmdsSection
	if (-not $cmdChildIndent -or $cmdChildIndent -eq "") { $cmdChildIndent = "`t`t" }

	# Generate command fragments
	$script:xml = New-Object System.Text.StringBuilder 1024
	X "<_F $allNsDecl>"
	foreach ($cmd in $def.commands) {
		$cmdId = New-CmdId
		$cmdName = "$($cmd.name)"
		X "$cmdChildIndent<Command name=`"$cmdName`" id=`"$cmdId`">"
		$inner = "$cmdChildIndent`t"

		if ($cmd.title) { Emit-MLText -tag "Title" -text "$($cmd.title)" -indent $inner }
		if ($cmd.action) { X "$inner<Action>$($cmd.action)</Action>" }
		if ($cmd.shortcut) { X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>" }
		if ($cmd.picture) {
			X "$inner<Picture>"
			X "$inner`t<xr:Ref>$($cmd.picture)</xr:Ref>"
			X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
			X "$inner</Picture>"
		}
		if ($cmd.representation) { X "$inner<Representation>$($cmd.representation)</Representation>" }

		X "$cmdChildIndent</Command>"
		$actionStr = if ($cmd.action) { " -> $($cmd.action)" } else { "" }
		$addedCmds += "  + ${cmdName}${actionStr} (id=$cmdId)"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedCmds = Import-ElementNodes $fragDoc

	foreach ($node in $importedCmds) {
		Insert-IntoContainer -container $cmdsSection -newNode $node -afterName $null -childIndent $cmdChildIndent
	}
}

# === 13. Save ===

$content = $xmlDoc.OuterXml
# Ensure encoding declaration is uppercase UTF-8
$content = $content -replace '^<\?xml version="1.0" encoding="utf-8"\?>', '<?xml version="1.0" encoding="UTF-8"?>'

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedFormPath, $content, $enc)

# === 14. Summary ===

if ($addedElems.Count -gt 0) {
	$posStr = ""
	if ($def.into) { $posStr += "into $($def.into)" }
	if ($def.after) { if ($posStr) { $posStr += ", " }; $posStr += "after $($def.after)" }
	if ($posStr) { $posStr = " ($posStr)" }
	Write-Host "Added elements${posStr}:"
	foreach ($line in $addedElems) { Write-Host $line }
	Write-Host ""
}

if ($addedAttrs.Count -gt 0) {
	Write-Host "Added attributes:"
	foreach ($line in $addedAttrs) { Write-Host $line }
	Write-Host ""
}

if ($addedCmds.Count -gt 0) {
	Write-Host "Added commands:"
	foreach ($line in $addedCmds) { Write-Host $line }
	Write-Host ""
}

Write-Host "---"
$totalParts = @()
if ($addedElems.Count -gt 0) {
	$compStr = if ($companionCount -gt 0) { " (+$companionCount companions)" } else { "" }
	$totalParts += "$($addedElems.Count) element(s)$compStr"
}
if ($addedAttrs.Count -gt 0) { $totalParts += "$($addedAttrs.Count) attribute(s)" }
if ($addedCmds.Count -gt 0) { $totalParts += "$($addedCmds.Count) command(s)" }
Write-Host "Total: $($totalParts -join ', ')"
Write-Host "Run /form-validate to verify."
