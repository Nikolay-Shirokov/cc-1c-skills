# cfe-diff v2.2 — Analyze 1C configuration extension (CFE): borrowed objects, interceptors, own members, form changes
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)]
	[string]$ExtensionPath,

	[string]$ConfigPath,

	[string]$Mode = "overview",

	[string]$Name,

	[int]$Limit = 150,

	[int]$Offset = 0,

	[string]$Expand,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Mode ---
# The transfer check moved to its own skill: an old call gets pointed there instead of a bare error
$modeKey = $Mode.Trim().ToLower()
if (@('check-transfer', 'transfer', 'b') -contains $modeKey) {
	Write-Error "Transfer check moved: use /cfe-transfer -ExtensionPath <path> -ConfigPath <path>"
	exit 1
}
if (@('overview', 'a') -notcontains $modeKey) {
	Write-Error "Invalid -Mode '$Mode'. Expected: overview"
	exit 1
}

# Detail budget: below it the whole report (summaries + details) is printed in one go;
# above it only summaries, and -Name opens the details of chosen objects.
$DetailBudget = 80

# --- Resolve paths ---
function Resolve-InputPath([string]$p) {
	$p = $p.Trim()
	if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).ProviderPath $p }
	if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent }
	return $p
}

$mdNsUri = "http://v8.1c.ru/8.3/MDClasses"

function Read-ConfigurationProps([string]$dir) {
	$file = Join-Path $dir "Configuration.xml"
	if (-not (Test-Path -LiteralPath $file)) { return $null }
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	$doc.Load($file)
	$mns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$mns.AddNamespace("md", $mdNsUri)
	$props = $doc.SelectSingleNode("//md:Configuration/md:Properties", $mns)
	$get = { param($n) $x = if ($props) { $props.SelectSingleNode("md:$n", $mns) } else { $null }; if ($x) { $x.InnerText } else { "" } }
	return @{
		Dir = $dir
		Doc = $doc
		Ns = $mns
		Name = (& $get "Name")
		Prefix = (& $get "NamePrefix")
		Purpose = (& $get "ConfigurationExtensionPurpose")
		IsExtension = ($props -and $props.SelectSingleNode("md:ConfigurationExtensionPurpose", $mns))
		ChildObjects = $doc.SelectSingleNode("//md:Configuration/md:ChildObjects", $mns)
	}
}

# -ExtensionPath: an extension, a comma-separated list, or a folder whose subfolders are extensions.
# powershell.exe -File cannot bind an array parameter, hence the repo-wide comma convention.
$extDirs = @()
foreach ($raw in @($ExtensionPath -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
	$p = Resolve-InputPath $raw
	if (Test-Path -LiteralPath (Join-Path $p "Configuration.xml")) {
		$cp = Read-ConfigurationProps $p
		if (-not $cp.IsExtension) { Write-Error "Not an extension (no ConfigurationExtensionPurpose): $p"; exit 1 }
		$extDirs += $p
		continue
	}
	if (-not (Test-Path -LiteralPath $p -PathType Container)) { Write-Error "Extension not found: $p"; exit 1 }
	$found = @()
	$subs = [string[]]@(Get-ChildItem -LiteralPath $p -Directory | ForEach-Object { $_.Name })
	if ($subs.Count -gt 1) { [Array]::Sort($subs, [StringComparer]::Ordinal) }
	foreach ($sub in $subs) {
		$full = Join-Path $p $sub
		$cp = Read-ConfigurationProps $full
		if ($cp -and $cp.IsExtension) { $found += $full }
	}
	if ($found.Count -eq 0) { Write-Error "Extension Configuration.xml not found: $(Join-Path $p 'Configuration.xml') (and no extension subfolders)"; exit 1 }
	$extDirs += $found
}
if ($extDirs.Count -eq 0) { Write-Error "No extension given in -ExtensionPath"; exit 1 }

# -ConfigPath is kept so that a call written for the old transfer check reaches the hint above
# instead of failing on an unknown parameter; the overview does not use it

$nameFilter = @()
if ($Name) { $nameFilter = @($Name -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$expandList = @()
if ($Expand) { $expandList = @($Expand -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# --- Type -> directory mapping ---
$childTypeDirMap = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "Enum"="Enums"
	"CommonModule"="CommonModules"; "CommonPicture"="CommonPictures"
	"CommonCommand"="CommonCommands"; "CommonTemplate"="CommonTemplates"
	"ExchangePlan"="ExchangePlans"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"; "CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"Subsystem"="Subsystems"; "Role"="Roles"; "Constant"="Constants"
	"FunctionalOption"="FunctionalOptions"; "DefinedType"="DefinedTypes"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"
	"CommonForm"="CommonForms"; "DocumentJournal"="DocumentJournals"
	"SessionParameter"="SessionParameters"; "StyleItem"="StyleItems"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"
	"SettingsStorage"="SettingsStorages"; "FilterCriterion"="FilterCriteria"
	"CommandGroup"="CommandGroups"; "DocumentNumerator"="DocumentNumerators"
	"Sequence"="Sequences"; "ExternalDataSource"="ExternalDataSources"; "IntegrationService"="IntegrationServices"
	"CommonAttribute"="CommonAttributes"; "Style"="Styles"; "XDTOPackage"="XDTOPackages"
	"WebService"="WebServices"; "HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"Bot"="Bots"
	"PaletteColor"="PaletteColors"
}

# ============================================================
# BSL helpers — verbatim copies from cfe-patch-method (kept identical by check-inline-drift)
# ============================================================

# Built-in language keywords in both spellings. The platform accepts either one in any module
# (pairs taken from the platform string tables), so a module written in English is ordinary
# source, not a broken one: we must read both and emit the spelling we read.
function Get-BslKeywords {
	return @{
		ru = @{
			Async="Асинх"; Proc="Процедура"; EndProc="КонецПроцедуры"
			Func="Функция"; EndFunc="КонецФункции"; Val="Знач"
			Region="Область"; EndRegion="КонецОбласти"
			If="Если"; Then="Тогда"; ElsIf="ИначеЕсли"; Else="Иначе"; EndIf="КонецЕсли"
			# Platform spells the negation "Не"; we emit "НЕ" as this skill always has —
			# the language is case-insensitive, and the lower case would churn every snapshot.
			And="И"; Or="Или"; Not="НЕ"
			Insert="Вставка"; EndInsert="КонецВставки"; Delete="Удаление"; EndDelete="КонецУдаления"
			Before="Перед"; After="После"; Around="Вместо"; Control="ИзменениеИКонтроль"
			Proceed="ПродолжитьВызов"; Return="Возврат"
			# Not a keyword: name of the local the generated Instead-stub declares. Lives here so
			# that the language of emitted text is decided in exactly one place.
			ResultVar="Результат"
			Directives=@("НаКлиенте", "НаСервере", "НаСервереБезКонтекста", "НаКлиентеНаСервереБезКонтекста", "НаКлиентеНаСервере")
		}
		en = @{
			Async="Async"; Proc="Procedure"; EndProc="EndProcedure"
			Func="Function"; EndFunc="EndFunction"; Val="Val"
			Region="Region"; EndRegion="EndRegion"
			If="If"; Then="Then"; ElsIf="ElsIf"; Else="Else"; EndIf="EndIf"
			And="And"; Or="Or"; Not="Not"
			Insert="Insert"; EndInsert="EndInsert"; Delete="Delete"; EndDelete="EndDelete"
			Before="Before"; After="After"; Around="Around"; Control="ChangeAndValidate"
			Proceed="ProceedWithCall"; Return="Return"
			ResultVar="Result"
			Directives=@("AtClient", "AtServer", "AtServerNoContext", "AtClientAtServerNoContext", "AtClientAtServer")
		}
	}
}

$script:bslKw = Get-BslKeywords

# Regex alternation for a keyword in both spellings
function Get-KwAlt {
	param([string]$key)
	return '(?:' + $script:bslKw.ru[$key] + '|' + $script:bslKw.en[$key] + ')'
}


# Parse interceptor annotations present in a module. Type is normalized to the Russian spelling
# so everything downstream stays single-language; Raw keeps what the file actually says.
function Get-Interceptors {
	param($lines)
	$kw = $script:bslKw
	$keys = @("Before", "After", "Control", "Around")
	$alt = @()
	$norm = @{}
	foreach ($k in $keys) {
		$alt += $kw.ru[$k]; $alt += $kw.en[$k]
		$norm[$kw.ru[$k].ToLower()] = $kw.ru[$k]
		$norm[$kw.en[$k].ToLower()] = $kw.ru[$k]
	}
	$re = '^&(' + ($alt -join '|') + ')\("([^"]+)"\)'
	$result = @()
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = $lines[$i].Trim()
		if ($t -match $re) {
			$raw = $Matches[1]
			$result += @{ Type = $norm[$raw.ToLower()]; Raw = $raw; Method = $Matches[2]; Line = $i }
		}
	}
	return $result
}


# ============================================================
# Form notation — verbatim copies from form-info (kept identical by check-inline-drift)
# ============================================================

# --- Helper: format type compactly ---

function Format-Type($typeNode) {
	if (-not $typeNode -or -not $typeNode.HasChildNodes) { return "" }

	$typeSet = $typeNode.SelectSingleNode("v8:TypeSet", $ns)
	if ($typeSet) {
		$val = $typeSet.InnerText
		# Strip cfg:/d5p1: prefix for DefinedType, keep as-is
		$val = $val -replace '^(cfg|d\d+p\d+):', ''
		return $val
	}

	$types = $typeNode.SelectNodes("v8:Type", $ns)
	if ($types.Count -eq 0) { return "" }

	$parts = @()
	foreach ($t in $types) {
		$raw = $t.InnerText
		switch -Wildcard ($raw) {
			"xs:string" {
				$sq = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:Length", $ns)
				$al = $typeNode.SelectSingleNode("v8:StringQualifiers/v8:AllowedLength", $ns)
				$len = if ($sq) { [int]$sq.InnerText } else { 0 }
				if ($al -and $al.InnerText -eq 'Fixed') { $parts += "string($len,fixed)" }
				elseif ($len -gt 0) { $parts += "string($len)" } else { $parts += "string" }
			}
			"xs:decimal" {
				$nq = $typeNode.SelectSingleNode("v8:NumberQualifiers", $ns)
				if ($nq) {
					$d = $nq.SelectSingleNode("v8:Digits", $ns)
					$f = $nq.SelectSingleNode("v8:FractionDigits", $ns)
					$s = $nq.SelectSingleNode("v8:AllowedSign", $ns)
					$digits = if ($d) { $d.InnerText } else { "0" }
					$frac = if ($f) { $f.InnerText } else { "0" }
					if ($s -and $s.InnerText -eq 'Nonnegative') { $parts += "decimal($digits,$frac,nonneg)" }
					else { $parts += "decimal($digits,$frac)" }
				} else {
					# Без квалификаторов платформа читает число как 0,0; голое decimal значило бы 10,0
					$parts += "decimal(0,0)"
				}
			}
			"xs:boolean" { $parts += "boolean" }
			"xs:dateTime" {
				$dq = $typeNode.SelectSingleNode("v8:DateQualifiers/v8:DateFractions", $ns)
				if ($dq) {
					switch ($dq.InnerText) {
						"Date" { $parts += "date" }
						"Time" { $parts += "time" }
						default { $parts += "dateTime" }
					}
				} else {
					$parts += "dateTime"
				}
			}
			"xs:binary" { $parts += "binary" }
			{ $_ -like "cfg:*" -or $_ -match '^d\d+p\d+:' } { $parts += ($raw -replace '^(cfg|d\d+p\d+):', '') }
			"v8:ValueTable" { $parts += "ValueTable" }
			"v8:ValueTree" { $parts += "ValueTree" }
			"v8:ValueListType" { $parts += "ValueList" }
			"v8:TypeDescription" { $parts += "TypeDescription" }
			"v8:Universal" { $parts += "Universal" }
			"v8:FixedArray" { $parts += "FixedArray" }
			"v8:FixedStructure" { $parts += "FixedStructure" }
			"v8ui:FormattedString" { $parts += "FormattedString" }
			"v8ui:Picture" { $parts += "Picture" }
			"v8ui:Color" { $parts += "Color" }
			"v8ui:Font" { $parts += "Font" }
			"dcsset:*" { $parts += $raw.Replace("dcsset:", "DCS.") }
			"dcssch:*" { $parts += $raw.Replace("dcssch:", "DCS.") }
			"dcscor:*" { $parts += $raw.Replace("dcscor:", "DCS.") }
			default { $parts += $raw }
		}
	}

	return ($parts -join " | ")
}

# --- Element type abbreviations ---

$skipElements = @{
	"ExtendedTooltip" = $true
	"ContextMenu" = $true
	"AutoCommandBar" = $true
	"SearchStringAddition" = $true
	"ViewStatusAddition" = $true
	"SearchControlAddition" = $true
}

function Get-ElementTag($node) {
	$localName = $node.LocalName
	switch ($localName) {
		"UsualGroup" {
			$groupNode = $node.SelectSingleNode("d:Group", $ns)
			$orient = ""
			if ($groupNode) {
				switch ($groupNode.InnerText) {
					"Vertical" { $orient = ":V" }
					"Horizontal" { $orient = ":H" }
					"AlwaysHorizontal" { $orient = ":AH" }
					"AlwaysVertical" { $orient = ":AV" }
				}
			}
			$beh = $node.SelectSingleNode("d:Behavior", $ns)
			$collapse = ""
			if ($beh -and $beh.InnerText -eq "Collapsible") { $collapse = ",collapse" }
			return "[Group$orient$collapse]"
		}
		"InputField" { return "[Input]" }
		"CheckBoxField" { return "[Check]" }
		"LabelDecoration" { return "[Label]" }
		"LabelField" { return "[LabelField]" }
		"PictureDecoration" { return "[Picture]" }
		"PictureField" { return "[PicField]" }
		"CalendarField" { return "[Calendar]" }
		"Table" { return "[Table]" }
		"Button" { return "[Button]" }
		"CommandBar" { return "[CmdBar]" }
		"Pages" { return "[Pages]" }
		"Page" { return "[Page]" }
		"Popup" { return "[Popup]" }
		"ButtonGroup" { return "[BtnGroup]" }
		"ColumnGroup" { return "[ColGroup]" }
		"AutoCommandBar" { return "[CmdBar]" }
		"ContextMenu" { return "[ContextMenu]" }
		default { return "[$localName]" }
	}
}

# ============================================================
# Form namespaces: one name table for every form document, so the copied form-info helpers
# (they read $ns) work on the extension form, its BaseForm and the configuration form alike.
# ============================================================
$script:formNt = New-Object System.Xml.NameTable
$ns = New-Object System.Xml.XmlNamespaceManager($script:formNt)
$ns.AddNamespace("d", "http://v8.1c.ru/8.3/xcf/logform")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("cfg", "http://v8.1c.ru/8.1/data/enterprise/current-config")
$ns.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")
$ns.AddNamespace("dcscor", "http://v8.1c.ru/8.1/data-composition-system/core")

# ============================================================
# Common helpers
# ============================================================

# Drop the extension name prefix at the start of identifiers. Applied to BOTH sides of every
# comparison, so a change carried over with the prefix dropped and one carried over with the
# prefix kept compare equal alike.
function Remove-ExtPrefix([string]$text, [string]$prefix) {
	if ([string]::IsNullOrEmpty($prefix) -or [string]::IsNullOrEmpty($text)) { return $text }
	if ($script:prefixReFor -cne $prefix) {
		$script:prefixRe = New-Object System.Text.RegularExpressions.Regex ('(?<!\w)' + [regex]::Escape($prefix) + '(?=\w)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		$script:prefixReFor = $prefix
	}
	return $script:prefixRe.Replace($text, '')
}


function Get-Short([string]$s, [int]$n = 40) {
	$t = ($s -replace '\s+', ' ').Trim()
	if ($t.Length -gt $n) { return $t.Substring(0, $n) + "…" }
	return $t
}

function Get-Plural([int]$n, [string]$word) {
	if ($n -eq 1) { return "1 $word" }
	return "$n ${word}s"
}

function Get-RelPath([string]$root, [string]$full) {
	$r = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
	$f = [IO.Path]::GetFullPath($full)
	return ($f.Substring($r.Length).TrimStart('\', '/') -replace '\\', '/')
}

function Read-BslLines([string]$path) {
	if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
	return ,([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8))
}


# Declaration following an annotation (context directives and other annotations may sit between)
function Find-DeclAfter($lines, [int]$annIdx) {
	$declRe = '^\s*(?:' + (Get-KwAlt 'Async') + '\s+)?(?:' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+([\w]+)\s*\('
	$last = [Math]::Min($lines.Count - 1, $annIdx + 5)
	for ($j = $annIdx + 1; $j -le $last; $j++) {
		$t = $lines[$j].Trim()
		if ($t -imatch $declRe) { return @{ Name = $Matches[1]; Idx = $j } }
		if ($t -ne '' -and -not $t.StartsWith('&') -and -not $t.StartsWith('//')) { break }
	}
	return $null
}

# ============================================================
# Metadata objects
# ============================================================

function Read-MdObject([string]$file) {
	if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $null }
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	$doc.Load($file)
	$mns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$mns.AddNamespace("md", $mdNsUri)
	$mns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
	$el = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) { if ($c.NodeType -eq 'Element') { $el = $c; break } }
	if (-not $el) { return $null }
	return @{ El = $el; Ns = $mns; Props = $el.SelectSingleNode("md:Properties", $mns); Children = $el.SelectSingleNode("md:ChildObjects", $mns) }
}

function Test-AdoptedNode($node, $mns) {
	if (-not $node) { return $false }
	$props = if ($node.LocalName -eq 'Properties') { $node } else { $node.SelectSingleNode("md:Properties", $mns) }
	if (-not $props) { return $false }
	$ob = $props.SelectSingleNode("md:ObjectBelonging", $mns)
	return ($ob -and $ob.InnerText -eq 'Adopted')
}

function Get-MdChildName($node, $mns) {
	$n = $node.SelectSingleNode("md:Properties/md:Name", $mns)
	if ($n) { return $n.InnerText }
	return $node.InnerText.Trim()
}

function Test-HasElementChild($node) {
	foreach ($c in $node.ChildNodes) { if ($c.NodeType -eq 'Element') { return $true } }
	return $false
}


function Get-KindWord([string]$localName) {
	return ([regex]::Replace($localName, '(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ')).ToLower()
}

# Context of one object of the extension
function Get-ObjContext([string]$extDir, [string]$type, [string]$name) {
	if (-not $childTypeDirMap.ContainsKey($type)) { return @{ Known = $false } }
	$dir = $childTypeDirMap[$type]
	$file = Join-Path (Join-Path $extDir $dir) "$name.xml"
	$md = Read-MdObject $file
	return @{
		Known = $true; Type = $type; Name = $name; Id = "$type.$name"; Dir = $dir
		ObjDir = (Join-Path (Join-Path $extDir $dir) $name); File = $file
		Md = $md; Exists = [bool]$md
		Borrowed = ($md -and (Test-AdoptedNode $md.Props $md.Ns))
	}
}

# Forms of an object: borrowed ones carry <BaseForm>; a common form is a form itself
function Get-ObjForms($ctx) {
	$forms = @()
	if ($ctx.Type -eq 'CommonForm') {
		$forms += @{ Label = 'Form'; Name = $ctx.Name; Xml = (Join-Path $ctx.ObjDir "Ext/Form.xml"); Module = (Join-Path $ctx.ObjDir "Ext/Form/Module.bsl"); Own = (-not $ctx.Borrowed); Dir = $ctx.ObjDir }
		return $forms
	}
	if (-not $ctx.Md -or -not $ctx.Md.Children) { return $forms }
	foreach ($c in $ctx.Md.Children.ChildNodes) {
		if ($c.NodeType -ne 'Element' -or $c.LocalName -ne 'Form') { continue }
		$fn = $c.InnerText.Trim()
		$fdir = Join-Path (Join-Path $ctx.ObjDir "Forms") $fn
		$desc = Read-MdObject (Join-Path (Join-Path $ctx.ObjDir "Forms") "$fn.xml")
		$own = -not ($desc -and (Test-AdoptedNode $desc.Props $desc.Ns))
		$forms += @{ Label = "Form.$fn"; Name = $fn; Xml = (Join-Path $fdir "Ext/Form.xml"); Module = (Join-Path $fdir "Ext/Form/Module.bsl"); Own = $own; Dir = $fdir }
	}
	return $forms
}

# .bsl modules of a borrowed object, without those of its own forms and commands (they move as a whole)
function Get-ObjModules($ctx, $forms) {
	if (-not (Test-Path -LiteralPath $ctx.ObjDir -PathType Container)) { return @() }
	$skipDirs = @()
	foreach ($f in $forms) { if ($f.Own -and $ctx.Type -ne 'CommonForm') { $skipDirs += [IO.Path]::GetFullPath($f.Dir) } }
	if ($ctx.Md -and $ctx.Md.Children) {
		foreach ($c in $ctx.Md.Children.ChildNodes) {
			if ($c.NodeType -ne 'Element' -or $c.LocalName -ne 'Command') { continue }
			if (-not (Test-AdoptedNode $c $ctx.Md.Ns)) { $skipDirs += [IO.Path]::GetFullPath((Join-Path (Join-Path $ctx.ObjDir "Commands") (Get-MdChildName $c $ctx.Md.Ns))) }
		}
	}
	# Ordinal order of the relative paths: the same in both ports, whatever the culture
	$files = @(Get-ChildItem -LiteralPath $ctx.ObjDir -Recurse -Filter "*.bsl" -File | ForEach-Object { $_.FullName })
	$keys = [string[]]@($files | ForEach-Object { Get-RelPath $ctx.ObjDir $_ })
	$arr = [string[]]$files
	if ($arr.Count -gt 1) { [Array]::Sort($keys, $arr, [StringComparer]::Ordinal) }
	$res = @()
	foreach ($full in $arr) {
		$skip = $false
		foreach ($sd in $skipDirs) { if ($full.StartsWith($sd + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
		if (-not $skip) { $res += $full }
	}
	return $res
}

# ============================================================
# Form diff: main part of a borrowed form against its <BaseForm>
# ============================================================

function Read-FormDoc([string]$path) {
	if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
	$doc = New-Object System.Xml.XmlDocument($script:formNt)
	$doc.PreserveWhitespace = $false
	try { $doc.Load($path) } catch { return $null }
	return $doc
}

function Test-FormElement($n) {
	return ($n.NodeType -eq 'Element' -and $n.HasAttribute('name') -and $n.HasAttribute('id'))
}

# Named form elements of a part (form root or BaseForm), in document order. Elements nest through
# ChildItems and through named companions (context menu, tooltip, command bar of a table).
function Add-FormElements($node, [string]$parentName, $ancestors, $idx) {
	$kids = @()
	foreach ($c in $node.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if ($c.LocalName -eq 'ChildItems') { foreach ($cc in $c.ChildNodes) { if (Test-FormElement $cc) { $kids += $cc } } }
		elseif (Test-FormElement $c) { $kids += $c }
	}
	$names = @(foreach ($kk in $kids) { $kk.GetAttribute('name') })
	for ($i = 0; $i -lt $kids.Count; $i++) {
		$k = $kids[$i]
		$nm = $names[$i]
		if ($idx.Contains($nm)) { continue }
		$rec = @{ Name = $nm; Node = $k; Parent = $parentName; Ancestors = $ancestors; Siblings = $names; Pos = $i; HasKids = $false }
		$idx[$nm] = $rec
		Add-FormElements $k $nm (@($ancestors) + $nm) $idx
	}
	if ($parentName -and $idx.Contains($parentName) -and $kids.Count -gt 0) { $idx[$parentName].HasKids = $true }
}

function Get-FormElementIndex($part) {
	$idx = [ordered]@{}
	Add-FormElements $part '' @() $idx
	return ,$idx
}

# Elements of the longest common subsequence of two name orders (case-insensitive)
function Get-LcsSet($a, $b) {
	$n = $a.Count; $m = $b.Count
	$dp = New-Object 'System.Collections.Generic.List[int[]]'
	for ($i = 0; $i -le $n; $i++) { $dp.Add((New-Object 'int[]' ($m + 1))) }
	for ($i = $n - 1; $i -ge 0; $i--) {
		for ($j = $m - 1; $j -ge 0; $j--) {
			if ($a[$i] -ieq $b[$j]) { $dp[$i][$j] = $dp[$i + 1][$j + 1] + 1 }
			else { $dp[$i][$j] = [Math]::Max($dp[$i + 1][$j], $dp[$i][$j + 1]) }
		}
	}
	$set = @{}
	$i = 0; $j = 0
	while ($i -lt $n -and $j -lt $m) {
		if ($a[$i] -ieq $b[$j]) { $set[$a[$i].ToLower()] = $true; $i++; $j++ }
		elseif ($dp[$i + 1][$j] -ge $dp[$i][$j + 1]) { $i++ }
		else { $j++ }
	}
	return $set
}

# Elements the extension moved: a new parent, or out of the common order among the siblings
# (one element moved must not make its neighbours look moved too)
function Get-MovedSet($mi, $bi) {
	$moved = @{}
	$groups = [ordered]@{}
	foreach ($name in @($mi.Keys)) {
		if (-not $bi.Contains($name)) { continue }
		$pm = $mi[$name].Parent; $pb = $bi[$name].Parent
		if ($pm -ine $pb) { $moved[$name.ToLower()] = $true; continue }
		$g = "|$($pm.ToLower())"
		if (-not $groups.Contains($g)) { $groups[$g] = New-Object System.Collections.ArrayList }
		[void]$groups[$g].Add($name)
	}
	$baseKeys = @($bi.Keys)
	foreach ($g in @($groups.Keys)) {
		$mainOrder = @($groups[$g])
		if ($mainOrder.Count -lt 2) { continue }
		$inGroup = @{}
		foreach ($x in $mainOrder) { $inGroup[$x.ToLower()] = $true }
		$baseOrder = New-Object System.Collections.ArrayList
		foreach ($k in $baseKeys) { if ($inGroup.ContainsKey($k.ToLower())) { [void]$baseOrder.Add($k) } }
		$baseOrder = @($baseOrder)
		$keep = Get-LcsSet $mainOrder $baseOrder
		foreach ($x in $mainOrder) { if (-not $keep.ContainsKey($x.ToLower())) { $moved[$x.ToLower()] = $true } }
	}
	return $moved
}


$script:formStructural = @('ChildItems', 'Attributes', 'Commands', 'Parameters', 'Events', 'CommandInterface', 'BaseForm')

# Property tags of an element (or of the form root): child elements that are not elements themselves
function Get-PropMap($node, [switch]$Root) {
	$m = [ordered]@{}
	foreach ($c in $node.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if ($c.LocalName -eq 'ChildItems' -or $c.LocalName -eq 'Events') { continue }
		if ($Root -and $script:formStructural -contains $c.LocalName) { continue }
		if (Test-FormElement $c) { continue }
		$key = $c.LocalName; $i = 2
		while ($m.Contains($key)) { $key = "$($c.LocalName)#$i"; $i++ }
		$m[$key] = $c
	}
	return ,$m
}

# Canonical text of a node: whitespace, ids, xmlns and namespace-prefix spelling do not matter
function Get-NodeCanon($n) {
	if ($n.NodeType -eq 'Text' -or $n.NodeType -eq 'CDATA') { return (($n.Value -replace '\s+', ' ').Trim()) }
	if ($n.NodeType -ne 'Element') { return '' }
	$sb = New-Object System.Text.StringBuilder
	Add-NodeCanon $sb $n
	return $sb.ToString()
}

# Element in canonical form, appended to $sb: attributes sorted (xmlns and id dropped), text with
# whitespace collapsed. Only ever compared with another canonical form, never shown.
function Add-NodeCanon([System.Text.StringBuilder]$sb, $n) {
	$attrs = New-Object 'System.Collections.Generic.List[string]'
	foreach ($a in $n.Attributes) {
		if ($a.Prefix -eq 'xmlns' -or $a.LocalName -eq 'xmlns' -or $a.LocalName -eq 'id') { continue }
		$attrs.Add("$($a.LocalName)=$($a.Value)")
	}
	$attrs.Sort([StringComparer]::Ordinal)
	[void]$sb.Append('<').Append($n.LocalName)
	if ($attrs.Count -gt 0) { [void]$sb.Append(' ').Append(($attrs -join ' ')) }
	[void]$sb.Append('>')
	foreach ($c in $n.ChildNodes) {
		if ($c.NodeType -eq 'Element') { Add-NodeCanon $sb $c }
		elseif ($c.NodeType -eq 'Text' -or $c.NodeType -eq 'CDATA') { [void]$sb.Append((($c.Value -replace '\s+', ' ').Trim())) }
	}
	[void]$sb.Append('</>')
}

# Same property in both parts. Identical text (whitespace collapsed) settles it without building the
# canonical form; only a difference in the text is checked canonically.
function Test-SameProp($a, $b) {
	if (-not $a -or -not $b) { return (-not $a -and -not $b) }
	if ((($a.get_OuterXml()) -replace '\s+', ' ') -ceq (($b.get_OuterXml()) -replace '\s+', ' ')) { return $true }
	return ((Get-CmpKey $a '') -ceq (Get-CmpKey $b ''))
}

function Get-CmpKey($node, [string]$prefix) {
	if (-not $node) { return $null }
	$c = (Get-NodeCanon $node) -replace '(?<![\w])(?:cfg|d\d+p\d+):', ''
	return (Remove-ExtPrefix $c $prefix)
}

function Get-PropDisplay($node) {
	if (-not $node) { return '' }
	$content = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($content) { return '"' + (Get-Short $content.InnerText 40) + '"' }
	if (Test-HasElementChild $node) { return '{…}' }
	return (Get-Short $node.InnerText 40)
}

function Get-EventList($node) {
	$res = @()
	if (-not $node) { return $res }
	foreach ($e in $node.SelectNodes("d:Events/d:Event", $ns)) {
		$res += @{ Name = $e.GetAttribute('name'); CallType = $e.GetAttribute('callType'); Handler = $e.InnerText.Trim() }
	}
	return $res
}

function Get-EventKeySet($events) {
	$s = @{}
	foreach ($e in $events) { $s["$($e.Name)|$($e.CallType)".ToLower()] = $true }
	return $s
}

function Get-SectionMap($root, [string]$section, [string]$item) {
	$m = [ordered]@{}
	foreach ($x in $root.SelectNodes("d:$section/d:$item", $ns)) { $nm = $x.GetAttribute('name'); if ($nm -and -not $m.Contains($nm)) { $m[$nm] = $x } }
	return ,$m
}

function Get-FormDiff([string]$formXml) {
	$doc = Read-FormDoc $formXml
	if (-not $doc) { return $null }
	$root = $doc.DocumentElement
	$base = $root.SelectSingleNode("d:BaseForm", $ns)
	$r = @{
		IsBorrowed = [bool]$base; Root = $root
		Elements = @(); Removed = @(); Attributes = @(); Columns = @(); Commands = @(); Parameters = @()
		Events = @(); FormProps = @(); Blocks = @(); Appearance = @(); Total = 0; MainIndex = $null
	}
	if (-not $base) { return $r }
	$mi = Get-FormElementIndex $root
	$bi = Get-FormElementIndex $base
	$r.MainIndex = $mi
	$movedSet = Get-MovedSet $mi $bi
	foreach ($name in @($mi.Keys)) {
		$m = $mi[$name]
		if (-not $bi.Contains($name)) {
			# Context menu / tooltip that come with an added element carry nothing of their own
			if ($skipElements.ContainsKey($m.Node.LocalName) -and $m.Parent -and -not $bi.Contains($m.Parent) -and -not $m.HasKids) { continue }
			$r.Elements += @{ Kind = 'added'; Rec = $m; Props = @(); Moved = $false; OldParent = '' }
			continue
		}
		$b = $bi[$name]
		$pm = Get-PropMap $m.Node; $pb = Get-PropMap $b.Node
		$props = @()
		foreach ($k in @($pm.Keys)) {
			if (-not $pb.Contains($k)) { $props += @{ Key = $k; Old = $null; New = $pm[$k] } }
			elseif (-not (Test-SameProp $pm[$k] $pb[$k])) { $props += @{ Key = $k; Old = $pb[$k]; New = $pm[$k] } }
		}
		foreach ($k in @($pb.Keys)) { if (-not $pm.Contains($k)) { $props += @{ Key = $k; Old = $pb[$k]; New = $null } } }
		$moved = $movedSet.ContainsKey($name.ToLower())
		if ($props.Count -gt 0 -or $moved) {
			$kind = if ($props.Count -gt 0) { 'changed' } else { 'moved' }
			$r.Elements += @{ Kind = $kind; Rec = $m; Props = $props; Moved = $moved; OldParent = $b.Parent }
		}
		$baseEv = Get-EventKeySet (Get-EventList $b.Node)
		foreach ($e in (Get-EventList $m.Node)) {
			if (-not $baseEv.ContainsKey("$($e.Name)|$($e.CallType)".ToLower())) {
				$r.Events += @{ Scope = $name; Name = $e.Name; CallType = $e.CallType; Handler = $e.Handler }
			}
		}
	}
	foreach ($name in @($bi.Keys)) {
		if ($mi.Contains($name)) { continue }
		$b = $bi[$name]
		# A companion comes and goes with its element
		if ($skipElements.ContainsKey($b.Node.LocalName) -and $b.Parent -and -not $mi.Contains($b.Parent)) { continue }
		$r.Removed += $b.Name
	}

	# Form events
	$baseEv = Get-EventKeySet (Get-EventList $base)
	foreach ($e in (Get-EventList $root)) {
		if (-not $baseEv.ContainsKey("$($e.Name)|$($e.CallType)".ToLower())) {
			$r.Events += @{ Scope = ''; Name = $e.Name; CallType = $e.CallType; Handler = $e.Handler }
		}
	}

	# Attributes, commands, parameters added by the extension; a command present in both parts that
	# gained an action with callType is the configuration's command intercepted (Changed)
	foreach ($sec in @(@('Attributes', 'Attribute', 'Attributes'), @('Commands', 'Command', 'Commands'), @('Parameters', 'Parameter', 'Parameters'))) {
		$mm = Get-SectionMap $root $sec[0] $sec[1]
		$bm = Get-SectionMap $base $sec[0] $sec[1]
		foreach ($nm in @($mm.Keys)) {
			$x = $mm[$nm]
			$changed = $bm.Contains($nm)
			# An attribute of the configuration the extension adds columns to (a value table)
			if ($changed -and $sec[1] -eq 'Attribute') {
				$had = @{}
				foreach ($c in $bm[$nm].SelectNodes("d:Columns/d:Column", $ns)) { $had[$c.GetAttribute('name')] = $true }
				foreach ($c in $x.SelectNodes("d:Columns/d:Column", $ns)) {
					$cn = $c.GetAttribute('name')
					if (-not $cn -or $had.ContainsKey($cn)) { continue }
					$ft = Format-Type ($c.SelectSingleNode("d:Type", $ns))
					$r.Columns += @{ Attr = $nm; Name = $cn; Info = $(if ($ft) { ": $ft" } else { '' }); Node = $c }
				}
			}
			if ($changed -and $sec[1] -ne 'Command') { continue }
			$baseActs = @{}
			if ($changed) { foreach ($a in $bm[$nm].SelectNodes("d:Action", $ns)) { $baseActs["$($a.GetAttribute('callType'))|$($a.InnerText.Trim())".ToLower()] = $true } }
			$info = ''
			$actions = @()
			if ($sec[1] -eq 'Command') {
				$acts = @()
				foreach ($a in $x.SelectNodes("d:Action", $ns)) {
					$ct = $a.GetAttribute('callType')
					$h = $a.InnerText.Trim()
					if ($changed -and (-not $ct -or $baseActs.ContainsKey("$ct|$h".ToLower()))) { continue }
					$actions += @{ Handler = $h; CallType = $ct }
					$acts += $(if ($ct) { "$h[$ct]" } else { $h })
				}
				if ($changed -and $actions.Count -eq 0) { continue }
				if ($acts.Count -gt 0) { $info = " -> $($acts -join ', ')" }
			} else {
				$ft = Format-Type ($x.SelectSingleNode("d:Type", $ns))
				if ($ft) { $info = ": $ft" }
			}
			$r[$sec[2]] += @{ Name = $nm; Info = $info; Actions = $actions; Changed = $changed; Node = $x }
		}
	}

	# Conditional appearance, rule by rule: the main part holds the whole form's rules, BaseForm the
	# configuration's at the borrowing — a rule only in the main part is added, only in BaseForm removed
	$caRules = {
		param($part)
		$list = New-Object System.Collections.ArrayList
		foreach ($it in $part.SelectNodes("d:Attributes/d:ConditionalAppearance/dcsset:item", $ns)) { [void]$list.Add(@{ Key = (Get-CmpKey $it ''); Node = $it }) }
		return ,$list
	}
	$mr = & $caRules $root; $br = & $caRules $base
	$left = New-Object System.Collections.ArrayList; foreach ($x in $br) { [void]$left.Add($x.Key) }
	foreach ($x in $mr) { $j = $left.IndexOf($x.Key); if ($j -ge 0) { $left.RemoveAt($j) } else { $r.Appearance += @{ Kind = 'added'; Key = $x.Key; Node = $x.Node } } }
	$left = New-Object System.Collections.ArrayList; foreach ($x in $mr) { [void]$left.Add($x.Key) }
	foreach ($x in $br) { $j = $left.IndexOf($x.Key); if ($j -ge 0) { $left.RemoveAt($j) } else { $r.Appearance += @{ Kind = 'removed'; Key = $x.Key; Node = $x.Node } } }

	# Whole blocks: command interface
	foreach ($blk in @(, @('CommandInterface', 'd:CommandInterface'))) {
		$mn = $root.SelectSingleNode($blk[1], $ns)
		$bn = $base.SelectSingleNode($blk[1], $ns)
		if (-not (Test-SameProp $mn $bn)) { $r.Blocks += @{ Name = $blk[0]; XPath = $blk[1]; Node = $mn } }
	}

	# Form properties
	$pm = Get-PropMap $root -Root; $pb = Get-PropMap $base -Root
	foreach ($k in @($pm.Keys)) {
		if (-not $pb.Contains($k)) { $r.FormProps += @{ Key = $k; Old = $null; New = $pm[$k] } }
		elseif (-not (Test-SameProp $pm[$k] $pb[$k])) { $r.FormProps += @{ Key = $k; Old = $pb[$k]; New = $pm[$k] } }
	}
	foreach ($k in @($pb.Keys)) { if (-not $pm.Contains($k)) { $r.FormProps += @{ Key = $k; Old = $pb[$k]; New = $null } } }

	$r.Total = $r.Elements.Count + $r.Removed.Count + $r.Attributes.Count + $r.Columns.Count + $r.Commands.Count + $r.Parameters.Count + $r.Events.Count + $r.FormProps.Count + $r.Blocks.Count + $r.Appearance.Count
	return $r
}

function Get-PropChangeText($p) {
	$k = $p.Key
	if ($null -eq $p.Old) { return "+$k=$(Get-PropDisplay $p.New)" }
	if ($null -eq $p.New) { return "-$k" }
	return "${k}: $(Get-PropDisplay $p.Old)→$(Get-PropDisplay $p.New)"
}

function Get-ElementBinding($node) {
	$dp = $node.SelectSingleNode("d:DataPath", $ns)
	if ($dp -and $dp.InnerText.Trim()) { return " -> $($dp.InnerText.Trim())" }
	$cn = $node.SelectSingleNode("d:CommandName", $ns)
	if ($cn -and $cn.InnerText.Trim() -and $cn.InnerText.Trim() -ne '0') { return " -> $($cn.InnerText.Trim())" }
	return ''
}

function Get-EventsInline($node) {
	$evs = @(Get-EventList $node)
	if ($evs.Count -eq 0) { return '' }
	$parts = @($evs | ForEach-Object { if ($_.CallType) { "$($_.Name)[$($_.CallType)]" } else { $_.Name } })
	return " {$($parts -join ', ')}"
}

function Get-MoveText($ch) {
	$rec = $ch.Rec
	$after = if ($rec.Pos -gt 0) { $rec.Siblings[$rec.Pos - 1] } else { '' }
	$pos = if ($after) { "after: $after" } else { 'first' }
	if ($rec.Parent -ine $ch.OldParent) {
		$to = if ($rec.Parent) { $rec.Parent } else { '(form)' }
		return "moved to $to ($pos)"
	}
	return "moved ($pos)"
}

# One line per element change, in form-info notation
function Get-ElementChangeText($ch) {
	$rec = $ch.Rec
	$tag = Get-ElementTag $rec.Node
	if ($ch.Kind -eq 'added') {
		$after = if ($rec.Pos -gt 0) { " (after: $($rec.Siblings[$rec.Pos - 1]))" } else { " (first)" }
		return "+ $tag $($rec.Name)$(Get-ElementBinding $rec.Node)$after$(Get-EventsInline $rec.Node)"
	}
	$parts = @($ch.Props | ForEach-Object { Get-PropChangeText $_ })
	if ($ch.Moved) { $parts += (Get-MoveText $ch) }
	$mark = if ($ch.Kind -eq 'changed') { '~' } else { '>' }
	return "$mark $tag $($rec.Name): $($parts -join '; ')"
}

# A conditional appearance rule in short: the fields it colours and the parameters it sets
function Get-AppearanceText($rule) {
	$fields = @(); foreach ($f in $rule.SelectNodes("dcsset:selection/dcsset:item/dcsset:field", $ns)) { $fields += $f.InnerText.Trim() }
	$params = @(); foreach ($p in $rule.SelectNodes("dcsset:appearance/dcscor:item/dcscor:parameter", $ns)) { $params += $p.InnerText.Trim() }
	$f = if ($fields.Count) { $fields -join ', ' } else { '(form)' }
	return "${f}: $($params -join ', ')"
}
function Get-EventText($e) {
	$ct = if ($e.CallType) { "[$($e.CallType)]" } else { '' }
	$scope = if ($e.Scope) { "$($e.Scope)." } else { '' }
	return "$scope$($e.Name)$ct -> $($e.Handler)"
}

function Get-FormDiffHeadline($diff, [string]$label) {
	if ($diff.Total -eq 0) { return "$label (borrowed, unchanged)" }
	return "$label (borrowed): $(Get-FormDiffParts $diff)"
}

function Get-FormDiffParts($diff) {
	$added = @($diff.Elements | Where-Object { $_.Kind -eq 'added' }).Count
	$changed = $diff.Elements.Count - $added
	$parts = @()
	if ($added) { $parts += "+$(Get-Plural $added 'element')" }
	if ($changed) { $parts += "~$(Get-Plural $changed 'element')" }
	if ($diff.Attributes.Count) { $parts += "+$(Get-Plural $diff.Attributes.Count 'attribute')" }
	if ($diff.Columns.Count) { $parts += "+$(Get-Plural $diff.Columns.Count 'column')" }
	$cmdChanged = @($diff.Commands | Where-Object { $_.Changed }).Count
	$cmdAdded = $diff.Commands.Count - $cmdChanged
	if ($cmdAdded) { $parts += "+$(Get-Plural $cmdAdded 'command')" }
	if ($cmdChanged) { $parts += "~$(Get-Plural $cmdChanged 'command')" }
	if ($diff.Parameters.Count) { $parts += "+$(Get-Plural $diff.Parameters.Count 'parameter')" }
	if ($diff.Events.Count) { $parts += (Get-Plural $diff.Events.Count 'event') }
	if ($diff.FormProps.Count) { $parts += (Get-Plural $diff.FormProps.Count 'form property') -replace 'propertys$', 'properties' }
	foreach ($b in $diff.Blocks) { $parts += "~$($b.Name)" }
	$caAdded = @($diff.Appearance | Where-Object { $_.Kind -eq 'added' }).Count
	$caRemoved = $diff.Appearance.Count - $caAdded
	if ($caAdded) { $parts += "+$(Get-Plural $caAdded 'appearance rule')" }
	if ($caRemoved) { $parts += "-$(Get-Plural $caRemoved 'appearance rule')" }
	if ($diff.Removed.Count) { $parts += "!$($diff.Removed.Count) removed" }
	return ($parts -join ', ')
}

# Overview rendering: changed elements as a tree with their ancestors for context
function Format-FormDiff($diff, [string]$label, [string]$ind) {
	$lines = @()
	$lines += "$ind$(Get-FormDiffHeadline $diff $label)"
	if ($diff.Total -eq 0) { return $lines }
	if ($diff.Elements.Count -gt 0) {
		$lines += "$ind  Elements:"
		$printed = @()
		foreach ($ch in $diff.Elements) {
			$anc = @($ch.Rec.Ancestors)
			$common = 0
			while ($common -lt $anc.Count -and $common -lt $printed.Count -and $anc[$common] -ieq $printed[$common]) { $common++ }
			for ($d = $common; $d -lt $anc.Count; $d++) {
				$an = $diff.MainIndex[$anc[$d]].Node
				$lines += "$ind    $('  ' * $d)$(Get-ElementTag $an) $($anc[$d])"
			}
			$lines += "$ind    $('  ' * $anc.Count)$(Get-ElementChangeText $ch)"
			$printed = @($anc) + $ch.Rec.Name
		}
	}
	foreach ($sec in @(@('Attributes', 'Attributes'), @('Commands', 'Commands'), @('Parameters', 'Parameters'))) {
		if ($diff[$sec[0]].Count -eq 0) { continue }
		$lines += "$ind  $($sec[1]):"
		foreach ($x in $diff[$sec[0]]) { $mk = if ($x.Changed) { '~' } else { '+' }; $lines += "$ind    $mk $($x.Name)$($x.Info)" }
		if ($sec[0] -eq 'Attributes') { foreach ($c in $diff.Columns) { $lines += "$ind    + $($c.Attr).$($c.Name)$($c.Info)" } }
	}
	# Columns added to an attribute of the configuration, when the form adds no attribute of its own
	if ($diff.Attributes.Count -eq 0 -and $diff.Columns.Count -gt 0) {
		$lines += "$ind  Attributes:"
		foreach ($c in $diff.Columns) { $lines += "$ind    + $($c.Attr).$($c.Name)$($c.Info)" }
	}
	if ($diff.Appearance.Count -gt 0) {
		$lines += "$ind  Conditional appearance:"
		foreach ($a in $diff.Appearance) { $mk = if ($a.Kind -eq 'added') { '+' } else { '-' }; $lines += "$ind    $mk rule $(Get-AppearanceText $a.Node)" }
	}
	if ($diff.Events.Count -gt 0) {
		$lines += "$ind  Events:"
		foreach ($e in $diff.Events) { $lines += "$ind    $(Get-EventText $e)" }
	}
	if ($diff.FormProps.Count -gt 0 -or $diff.Blocks.Count -gt 0) {
		$lines += "$ind  Form:"
		foreach ($p in $diff.FormProps) { $lines += "$ind    ~ $(Get-PropChangeText $p)" }
		foreach ($b in $diff.Blocks) { $lines += "$ind    ~ $($b.Name) changed" }
	}
	if ($diff.Removed.Count -gt 0) { $lines += "$ind  ! removed (unexpected): $($diff.Removed -join ', ')" }
	return $lines
}


# Handlers bound with callType (events, command actions): they are interceptors, not own methods
function Get-CallTypeHandlers($diff) {
	$s = @{}
	if ($diff) {
		foreach ($e in $diff.Events) { if ($e.Handler) { $s[$e.Handler.ToLower()] = $true } }
		foreach ($c in $diff.Commands) { foreach ($a in $c.Actions) { if ($a.CallType -and $a.Handler) { $s[$a.Handler.ToLower()] = $true } } }
	}
	return $s
}

# ============================================================
# Overview of one object
# ============================================================

# Declarations of a module: name and line index of each procedure and function
function Get-ProcDecls($lines) {
	$re = '^\s*(?:' + (Get-KwAlt 'Async') + '\s+)?(?:' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+([\w]+)\s*\('
	$res = @()
	for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -imatch $re) { $res += @{ Name = $Matches[1]; Idx = $i } } }
	return $res
}

# First line of code outside the methods of a module (module variables, main program code), -1 if
# none: comments, directives (&...) and preprocessor lines (#...) do not count
function Get-TopCodeLine($lines) {
	$declRe = '^\s*(?:' + (Get-KwAlt 'Async') + '\s+)?(?:' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+[\w]+\s*\('
	$endRe = '^\s*(?:' + (Get-KwAlt 'EndProc') + '|' + (Get-KwAlt 'EndFunc') + ')\b'
	$inProc = $false
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = $lines[$i].Trim()
		if ($inProc) { if ($t -imatch $endRe) { $inProc = $false }; continue }
		if ($t -imatch $declRe) { $inProc = $true; continue }
		if ($t -eq '' -or $t.StartsWith('//') -or $t.StartsWith('&') -or $t.StartsWith('#')) { continue }
		return $i
	}
	return -1
}

# What a module of a borrowed object brings: interceptors (with the method each one declares) and
# own methods, that is neither interceptors nor handlers bound in Form.xml ($skipHandlers)
function Get-ModuleChanges($lines, $skipHandlers) {
	$ics = @(); $icProcs = @{}
	$top = Get-TopCodeLine $lines
	foreach ($ic in @(Get-Interceptors $lines)) {
		$decl = Find-DeclAfter $lines $ic.Line
		if ($decl) { $icProcs[$decl.Name.ToLower()] = $true }
		$ics += @{ Ic = $ic; Decl = $decl }
	}
	$own = @(@(Get-ProcDecls $lines) | Where-Object { -not $icProcs.ContainsKey($_.Name.ToLower()) -and -not $skipHandlers.ContainsKey($_.Name.ToLower()) })
	return @{ Interceptors = $ics; Own = $own; TopCode = $top }
}

# Own sub-objects of a borrowed object, named: kind, name, the type of an attribute. The own
# attributes of a borrowed tabular section come as Section.Attribute with In = the section; those of
# an own section come with In = '*' (a part of it, not counted apart).
function Get-OwnChildList($ctx) {
	$res = @()
	if (-not $ctx.Md -or -not $ctx.Md.Children) { return $res }
	$mns = $ctx.Md.Ns
	$fmt = {
		param($node, [string]$name, [string]$in)
		$w = Get-KindWord $node.LocalName
		$t = $node.SelectSingleNode("md:Properties/md:Type", $mns)
		$ft = if ($t) { Format-Type $t } else { '' }
		$tail = if ($ft) { ": $ft" } else { '' }
		return @{ Kind = $w; Text = "$w $name$tail"; In = $in }
	}
	foreach ($c in $ctx.Md.Children.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if (-not (Test-HasElementChild $c)) {
			# <Form>Имя</Form>, <Template>Имя</Template>: ownership is in the sub-object descriptor
			$nm = $c.InnerText.Trim()
			$desc = Read-MdObject (Join-Path (Join-Path $ctx.ObjDir "$($c.LocalName)s") "$nm.xml")
			if ($desc -and (Test-AdoptedNode $desc.Props $desc.Ns)) { continue }
			$w = Get-KindWord $c.LocalName
			$res += @{ Kind = $w; Text = "$w $nm"; In = '' }
			continue
		}
		$nm = Get-MdChildName $c $mns
		$own = -not (Test-AdoptedNode $c $mns)
		if ($own) { $res += (& $fmt $c $nm '') }
		$sub = $c.SelectSingleNode("md:ChildObjects", $mns)
		if (-not $sub) { continue }
		foreach ($sc in $sub.ChildNodes) {
			if ($sc.NodeType -ne 'Element') { continue }
			if (-not $own -and (Test-AdoptedNode $sc $mns)) { continue }
			$in = if ($own) { '*' } else { $nm }
			$res += (& $fmt $sc "$nm.$(Get-MdChildName $sc $mns)" $in)
		}
	}
	return $res
}

# Content of a borrowed subsystem: the objects the extension adds to it (Type.Name)
function Get-SubsystemContent($md) {
	$res = @()
	if (-not $md -or -not $md.Props) { return $res }
	foreach ($i in $md.Props.SelectNodes("md:Content/*[local-name()='Item']", $md.Ns)) {
		$t = $i.InnerText.Trim()
		if ($t) { $res += $t }
	}
	return $res
}


# Overview details, grouped by file like the cfe-transfer report: modules with their interceptors and own
# methods, the object's XML with its own sub-objects, Form.xml with the tree of changes vs BaseForm
function Format-OverviewDetails($items) {
	$lines = New-Object System.Collections.Generic.List[string]
	$order = New-Object System.Collections.Generic.List[string]
	$bySec = @{}
	foreach ($it in $items) {
		$s = [string]$it.Section
		if (-not $bySec.ContainsKey($s)) { $bySec[$s] = New-Object System.Collections.ArrayList; $order.Add($s) }
		[void]$bySec[$s].Add($it)
	}
	$lay = Get-SectionLayout $order
	$emit = {
		param([string]$s)
		$its = @($bySec[$s])
		$pad = if ($s) { '      ' } else { '    ' }
		if ($s) {
			$tree = @($its | Where-Object { $_.Head })
			$head = if ($tree.Count -gt 0) { ": $($tree[0].Head)" } else { ':' }
			$lines.Add("    $s$head")
		}
		foreach ($it in $its) {
			if ($it.Head) { foreach ($l in $it.Lines) { $lines.Add($l) }; continue }
			$loc = if ($it.Loc) { "  $($it.Loc)" } else { '' }
			$lines.Add("$pad$($it.Text)$loc")
		}
	}
	foreach ($s in $lay.Plain) { & $emit $s }
	foreach ($f in $lay.Forms) { foreach ($s in $f.Secs) { & $emit $s } }
	return $lines.ToArray()
}

function Get-OverviewObject($ext, $obj) {
	$id = "$($obj.Type).$($obj.Name)"
	$ctx = Get-ObjContext $ext.Dir $obj.Type $obj.Name
	if (-not $ctx.Known) { return @{ Id = $id; Kind = '?'; Summary = "[?]          $id — unknown type"; Details = @() } }
	if (-not $ctx.Exists) { return @{ Id = $id; Kind = '?'; Summary = "[?]          $id — file not found"; Details = @() } }
	if (-not $ctx.Borrowed) {
		$parts = @()
		if ($ctx.Md.Children) {
			$cnt = [ordered]@{}
			foreach ($c in $ctx.Md.Children.ChildNodes) {
				if ($c.NodeType -ne 'Element') { continue }
				$w = Get-KindWord $c.LocalName
				if ($cnt.Contains($w)) { $cnt[$w]++ } else { $cnt[$w] = 1 }
			}
			foreach ($w in @($cnt.Keys)) { $parts += (Get-Plural $cnt[$w] $w) }
		}
		$tail = if ($parts.Count) { " — $($parts -join ', ')" } else { '' }
		return @{ Id = $id; Kind = 'own'; Summary = "[OWN]        $id$tail"; Details = @() }
	}

	$items = @()
	$forms = @(Get-ObjForms $ctx)
	$diffs = @{}
	$changedForms = 0; $badForms = 0
	foreach ($f in $forms) {
		if ($f.Own) { continue }
		$d = Get-FormDiff $f.Xml
		if (-not $d -or -not $d.IsBorrowed) {
			# A borrowed form must carry its BaseForm: without it there is nothing to compare with
			$why = if (-not (Test-Path -LiteralPath $f.Xml -PathType Leaf)) { 'Form.xml not found' } elseif (-not $d) { 'Form.xml cannot be read' } else { 'no BaseForm — cannot compare' }
			$badForms++
			$items += @{ Section = (Get-RelPath $ext.Dir $f.Xml); Text = $why; Loc = '' }
			continue
		}
		$diffs[[IO.Path]::GetFullPath($f.Module)] = $d
		if ($d.Total -eq 0) { continue }
		$changedForms++
		# The headline of the tree goes to the section header, the rest under it
		$tree = @(Format-FormDiff $d $f.Label '    ')
		$items += @{ Section = (Get-RelPath $ext.Dir $f.Xml); Head = (Get-FormDiffParts $d); Lines = @($tree | Select-Object -Skip 1) }
	}
	$icCount = 0; $ownMethods = 0; $topCode = 0
	foreach ($bsl in @(Get-ObjModules $ctx $forms)) {
		$lines = Read-BslLines $bsl
		if ($null -eq $lines) { continue }
		$rel = Get-RelPath $ext.Dir $bsl
		$key = [IO.Path]::GetFullPath($bsl)
		$skip = if ($diffs.ContainsKey($key)) { Get-CallTypeHandlers $diffs[$key] } else { @{} }
		$mc = Get-ModuleChanges $lines $skip
		if ($mc.TopCode -ge 0) { $topCode++; $items += @{ Section = $rel; Text = 'module code outside methods'; Loc = ":$($mc.TopCode + 1)" } }
		foreach ($x in $mc.Interceptors) { $icCount++; $items += @{ Section = $rel; Text = "&$($x.Ic.Raw)(`"$($x.Ic.Method)`")"; Loc = ":$($x.Ic.Line + 1)" } }
		foreach ($o in $mc.Own) { $ownMethods++; $items += @{ Section = $rel; Text = "method $($o.Name)"; Loc = ":$($o.Idx + 1)" } }
	}
	$objRel = Get-RelPath $ext.Dir $ctx.File
	$kinds = [ordered]@{}
	foreach ($k in @(Get-OwnChildList $ctx)) {
		$items += @{ Section = $objRel; Text = $k.Text; Loc = '' }
		# Parts of an own sub-object go with it; additions to a borrowed one are counted per owner
		if ($k.In -eq '*') { continue }
		$kk = "$($k.Kind)|$($k.In)"
		if ($kinds.Contains($kk)) { $kinds[$kk]++ } else { $kinds[$kk] = 1 }
	}
	$content = 0
	if ($obj.Type -eq 'Subsystem') {
		foreach ($c in @(Get-SubsystemContent $ctx.Md)) { $items += @{ Section = $objRel; Text = "content $c"; Loc = '' }; $content++ }
	}

	$sp = @()
	if ($icCount) { $sp += (Get-Plural $icCount 'interceptor') }
	if ($ownMethods) { $sp += (Get-Plural $ownMethods 'own method') }
	if ($topCode) { $sp += 'module code' }
	foreach ($kk in @($kinds.Keys)) {
		$w, $in = $kk.Split('|')
		$where = if ($in) { " in $in" } else { '' }
		$sp += "own $(Get-Plural $kinds[$kk] $w)$where"
	}
	if ($content) { $sp += (Get-Plural $content 'content item') }
	if ($changedForms) { $sp += "$(Get-Plural $changedForms 'form') changed" }
	if ($badForms) { $sp += "$(Get-Plural $badForms 'form') not compared" }
	# Borrowed only as a dependency (a type, a picture, a style of the extension's own code)
	$unchanged = ($items.Count -eq 0)
	$tail = if ($unchanged) { ' — no changes' } else { " — $($sp -join ', ')" }
	return @{ Id = $id; Type = $obj.Type; Kind = 'borrowed'; Unchanged = $unchanged; Summary = "[BORROWED]   $id$tail"; Details = @(Format-OverviewDetails $items) }
}

# ============================================================
# Run
# ============================================================

function Test-NameMatch([string]$id) {
	if ($nameFilter.Count -eq 0) { return $true }
	foreach ($f in $nameFilter) {
		if ($id -ieq $f) { return $true }
		if ($f -notmatch '\.' -and $id.Substring($id.IndexOf('.') + 1) -ieq $f) { return $true }
	}
	return $false
}


# Order of detail sections: plain files first, then each form with its
# Form.xml before its Module.bsl. Returns @{ Plain = @(paths); Forms = @(@{ Dir; Secs = @(paths) }) }
function Get-SectionLayout($order) {
	$plain = @()
	$forms = New-Object System.Collections.Generic.List[string]
	$secsOf = @{}
	foreach ($s in $order) {
		$fd = if ($s -match '^(.*)/Ext/Form(?:\.xml|/Module\.bsl)$') { $Matches[1] } else { '' }
		if (-not $fd) { $plain += $s; continue }
		if (-not $secsOf.ContainsKey($fd)) { $secsOf[$fd] = @(); $forms.Add($fd) }
		$secsOf[$fd] += $s
	}
	$res = @()
	foreach ($fd in $forms) { $res += @{ Dir = $fd; Secs = @($secsOf[$fd] | Sort-Object { if ($_.EndsWith('.xml')) { 0 } else { 1 } }) } }
	return @{ Plain = $plain; Forms = $res }
}


$exts = @()
$matchedIds = @{}
foreach ($dir in $extDirs) {
	$cp = Read-ConfigurationProps $dir
	$ext = @{ Dir = $dir; Name = $cp.Name; Prefix = $cp.Prefix; Purpose = $cp.Purpose; Objects = @(); Borrowed = 0; Own = 0; Matched = 0 }
	if ($cp.ChildObjects) {
		foreach ($child in $cp.ChildObjects.ChildNodes) {
			if ($child.NodeType -ne 'Element' -or $child.LocalName -eq 'Language') { continue }
			$obj = @{ Type = $child.LocalName; Name = $child.InnerText.Trim() }
			$id = "$($obj.Type).$($obj.Name)"
			if (-not (Test-NameMatch $id)) { continue }
			$matchedIds[$id.ToLower()] = $true
			$ext.Matched++
			$rec = Get-OverviewObject $ext $obj
			if ($rec.Kind -eq 'borrowed') { $ext.Borrowed++ } elseif ($rec.Kind -eq 'own') { $ext.Own++ }
			# A borrowed object without changes is folded into the summary unless asked for
			# (-Expand * lists them in the summary instead)
			$rec.Asked = ($nameFilter.Count -gt 0) -or (@($expandList | Where-Object { $_ -ieq $rec.Id }).Count -gt 0)
			$ext.Objects += $rec
		}
	}
	# -Name narrows the report: an extension without a matching object stays out of it
	if ($nameFilter.Count -gt 0 -and $ext.Matched -eq 0) { continue }
	$exts += $ext
}

# --- Detail decision ---
$fullCount = 0
foreach ($ext in $exts) {
	$fullCount += 3
	foreach ($o in $ext.Objects) {
		if ($o.Unchanged -and -not $o.Asked) { continue }
		$fullCount += 1 + $o.Details.Count
	}
}
$showDetails = ($nameFilter.Count -gt 0) -or ($fullCount -le $DetailBudget)

# --- Body ---
$body = @()
foreach ($ext in $exts) {
	$body += "=== cfe-diff overview: $($ext.Name) ($($ext.Purpose)) ==="
	if ($ext.Prefix) { $body += "NamePrefix: $($ext.Prefix)" }
	$body += ""
	$shown = 0
	foreach ($o in $ext.Objects) {
		if ($o.Unchanged -and -not $o.Asked) { continue }
		$body += $o.Summary
		$shown++
		if ($showDetails) { $body += $o.Details }
	}
	if ($shown -eq 0) {
		if ($ext.Objects.Count -gt 0) { $body += "No changes in borrowed objects." }
		else { $body += "No objects (besides Language) in extension." }
	}
	$body += ""
}

# --- Footer: always printed, after the body (output is often read from its tail) ---
$footer = @()
$unchFolded = $false
foreach ($ext in $exts) {
	$unch = @($ext.Objects | Where-Object { $_.Unchanged })
	$bp = if ($unch.Count -gt 0) { " ($($ext.Borrowed - $unch.Count) changed, $($unch.Count) without changes)" } else { '' }
	$footer += "=== Summary $($ext.Name): $($ext.Borrowed) borrowed$bp, $($ext.Own) own objects ==="
	if ($unch.Count -gt 0) {
		$byType = [ordered]@{}
		# One shown in the body (asked for by -Name or -Expand Type.Name) is not folded
		foreach ($o in @($unch | Where-Object { -not $_.Asked })) { if (-not $byType.Contains($o.Type)) { $byType[$o.Type] = @() }; $byType[$o.Type] += $o.Id.Substring($o.Type.Length + 1) }
		if ($byType.Count -eq 0) { }
		elseif ($expandList -contains '*') {
			$footer += "Borrowed without changes:"
			foreach ($t in @($byType.Keys)) { $footer += "    ${t}: $($byType[$t] -join ', ')" }
		} else {
			$footer += "Borrowed without changes: $((@($byType.Keys) | ForEach-Object { "$_ $($byType[$_].Count)" }) -join ', ')"
			$unchFolded = $true
		}
	}
}
foreach ($f in $nameFilter) {
	$hit = $false
	foreach ($k in $matchedIds.Keys) { if ($k -eq $f.ToLower() -or ($f -notmatch '\.' -and $k.Substring($k.IndexOf('.') + 1) -eq $f.ToLower())) { $hit = $true; break } }
	if (-not $hit) { $footer += "[INFO] -Name: no object matches '$f'" }
}
if (-not $showDetails) {
	$footer += "Details omitted ($fullCount lines in full). Use -Name <Type.Name>[,<Type.Name>] for item details."
}
if ($unchFolded) {
	$footer += "Hint: use -Expand * to list borrowed objects without changes"
}

# --- Pagination of the body; the footer stays ---
$total = $body.Count
$out = @()
if ($Offset -gt 0 -and $Offset -ge $total) {
	$out += "[INFO] Offset $Offset exceeds total lines ($total)."
} else {
	$end = [Math]::Min($total, $Offset + $Limit)
	if ($end -gt $Offset) { $out += $body[$Offset..($end - 1)] }
	if ($end -lt $total) { $out += "[TRUNCATED] Shown $($end - $Offset) of $total lines. Use -Offset $end to continue."; $out += "" }
}
$out += $footer

if ($OutFile) {
	if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).ProviderPath $OutFile }
	[System.IO.File]::WriteAllLines($OutFile, [string[]]$out, (New-Object System.Text.UTF8Encoding($true)))
	Write-Host "Output written to $OutFile"
} else {
	foreach ($l in $out) { Write-Host $l }
}

exit 0
