# form-info v1.14 — Analyze 1C managed form structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory=$true, Position=0)]
	[Alias('Path')]
	[string]$FormPath,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$Expand,
	[switch]$Handlers
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve FormPath ---
if (-not [System.IO.Path]::IsPathRooted($FormPath)) {
	$FormPath = Join-Path (Get-Location).ProviderPath $FormPath
}
# A: Directory → Ext/Form.xml
if (Test-Path $FormPath -PathType Container) {
	$FormPath = Join-Path (Join-Path $FormPath "Ext") "Form.xml"
}
# B1: Missing Ext/ (Forms/Форма/Form.xml → Forms/Форма/Ext/Form.xml)
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

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}

# --- Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load((Resolve-Path $FormPath).ProviderPath)

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("d", "http://v8.1c.ru/8.3/xcf/logform")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui", "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("cfg", "http://v8.1c.ru/8.1/data/enterprise/current-config")
$ns.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")

$root = $xmlDoc.DocumentElement

# --- Detect extension (BaseForm) ---
$baseFormNode = $root.SelectSingleNode("d:BaseForm", $ns)
$isExtension = ($baseFormNode -ne $null)

# --- Обработчики: процедуры модуля формы (только с -Handlers) ---

# Текст модуля формы; $null — модуль не в UTF-8 (с заменой символов имена процедур не найти — лучше сказать прямо)
function Read-ModuleText([string]$path) {
	try { return (New-Object System.Text.UTF8Encoding($false, $true)).GetString([System.IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF) }
	catch { return $null }
}

# Сканер BSL: строковые литералы (с "" и многострочными продолжениями «|») и комментарии // отделяются
# от кода, номера строк сохраняются. Lines — строки текста; Code — они же без комментариев, литерал
# заменён на ""; Mask — строки той же длины, литералы и комментарии — пробелами (позиции в маске —
# позиции в тексте); Literals — @{ Line; Text; Prefix — код этой строки слева от литерала; Col — начало
# текста литерала в строке, -1 у многострочного }.
function Get-BslScan([string]$text) {
	$lines = $text -replace "`r", "" -split "`n"
	$code = New-Object System.Collections.ArrayList
	$mask = New-Object System.Collections.ArrayList
	$lits = New-Object System.Collections.ArrayList
	$inStr = $false; $cur = $null; $curLine = 0; $curPrefix = ""; $curCol = -1
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$line = $lines[$i]
		# строка без кавычек вне литерала — только отрезать комментарий (посимвольный разбор в PS медленный)
		if (-not $inStr -and $line.IndexOf('"') -lt 0) {
			$k = $line.IndexOf('//')
			[void]$code.Add($(if ($k -ge 0) { $line.Substring(0, $k) } else { $line }))
			[void]$mask.Add($(if ($k -ge 0) { $line.Substring(0, $k) + (' ' * ($line.Length - $k)) } else { $line }))
			continue
		}
		$sb = New-Object System.Text.StringBuilder
		$mk = $line.ToCharArray()
		$j = 0
		if ($inStr) {
			# продолжение многострочного литерала: пробелы, затем «|»
			while ($j -lt $line.Length -and ($line[$j] -eq ' ' -or $line[$j] -eq "`t")) { $j++ }
			# строка «//…» между строками литерала — комментарий, литерал продолжается на следующей
			if ($j + 1 -lt $line.Length -and $line[$j] -eq '/' -and $line[$j + 1] -eq '/') { [void]$code.Add(""); [void]$mask.Add(' ' * $line.Length); continue }
			if ($j -lt $line.Length -and $line[$j] -eq '|') { $mk[$j] = ' '; $j++ }
			$cur += "`n"
			$curCol = -1
		}
		while ($j -lt $line.Length) {
			$c = $line[$j]
			if ($inStr) {
				if ($c -eq '"') {
					if ($j + 1 -lt $line.Length -and $line[$j + 1] -eq '"') { $cur += '"'; $mk[$j] = ' '; $mk[$j + 1] = ' '; $j += 2; continue }
					$inStr = $false
					[void]$lits.Add(@{ Line = $curLine; Text = $cur; Prefix = $curPrefix; Col = $curCol })
					[void]$sb.Append('""')
					$j++
					continue
				}
				$cur += $c; $mk[$j] = ' '; $j++; continue
			}
			if ($c -eq '/' -and $j + 1 -lt $line.Length -and $line[$j + 1] -eq '/') { for ($q = $j; $q -lt $mk.Length; $q++) { $mk[$q] = ' ' }; break }
			if ($c -eq '"') { $inStr = $true; $cur = ""; $curLine = $i + 1; $curPrefix = $sb.ToString(); $curCol = $j + 1; $j++; continue }
			[void]$sb.Append($c); $j++
		}
		[void]$code.Add($sb.ToString())
		[void]$mask.Add([string]::new($mk))
	}
	return @{ Lines = $lines; Code = $code.ToArray(); Mask = $mask.ToArray(); Literals = $lits.ToArray() }
}

# Процедуры и функции модуля (имя, первая и последняя строка; первая — с аннотациями над заголовком)
# и области (имя, строки #Область и #КонецОбласти, вложенность). Строки нумеруются с 1.
# Заголовок — только в начале строки: продолжение литерала («|…») и комментарий заголовком не станут.
function Get-ModuleOutline([string[]]$lines) {
	$procs = New-Object System.Collections.ArrayList
	$regions = New-Object System.Collections.ArrayList
	$open = New-Object System.Collections.ArrayList
	$cur = $null
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$l = $lines[$i]
		if ($null -ne $cur) {
			# конец процедуры — в начале строки или после «;» (`Возврат Х;КонецФункции`)
			if ($l -match '(^|;)\s*(КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)(?![\w])') { $cur.end = $i + 1; [void]$procs.Add($cur); $cur = $null }
			continue
		}
		$m = [regex]::Match($l, '^\s*(?:(?:Асинх|Async)\s+)?(?:Процедура|Функция|Procedure|Function)\s+(\w+)\s*\(', 'IgnoreCase')
		if ($m.Success) {
			$s = $i
			while ($s -gt 0 -and $lines[$s - 1] -match '^\s*&') { $s-- }
			$cur = [pscustomobject]@{ name = $m.Groups[1].Value; start = $s + 1; end = $i + 1 }
			continue
		}
		$m = [regex]::Match($l, '^\s*#(?:Область|Region)\s+(\S+)', 'IgnoreCase')
		if ($m.Success) { [void]$open.Add([pscustomobject]@{ name = $m.Groups[1].Value; start = $i + 1; end = 0; depth = $open.Count }); continue }
		if ($l -match '^\s*#(КонецОбласти|EndRegion)(?![\w])' -and $open.Count -gt 0) {
			$r = $open[$open.Count - 1]; $open.RemoveAt($open.Count - 1)
			$r.end = $i + 1; [void]$regions.Add($r)
		}
	}
	return @{ procs = $procs; regions = $regions }
}

$script:modulePath = Join-Path (Split-Path (Resolve-Path $FormPath).ProviderPath -Parent) "Form\Module.bsl"
$script:moduleProcs = $null
$script:moduleNotUtf8 = $false
if ($Handlers -and (Test-Path -LiteralPath $script:modulePath)) {
	$moduleText = Read-ModuleText $script:modulePath
	$script:moduleNotUtf8 = ($null -eq $moduleText)
}
if ($Handlers -and (Test-Path -LiteralPath $script:modulePath) -and -not $script:moduleNotUtf8) {
	$bsl = Get-BslScan $moduleText
	# @{} регистронезависим — как имена в BSL
	$script:moduleProcs = @{}
	foreach ($p in (Get-ModuleOutline $bsl.Code).procs) { if (-not $script:moduleProcs.ContainsKey($p.name)) { $script:moduleProcs[$p.name] = $p } }
}

# Где процедура обработчика: " (lines a-b)", " (not in module)" или "" — без -Handlers, без модуля,
# у привязки формы расширения без callType (процедура исходной формы — в модуле конфигурации)
# и у события с GUID-именем без процедуры (платформа такой обработчик не вызывает).
function Get-HandlerSuffix([string]$handler, [string]$callType, [string]$eventName) {
	if ($null -eq $script:moduleProcs -or -not $handler) { return "" }
	if ($isExtension -and -not $callType) { return "" }
	$p = $script:moduleProcs[$handler.Trim()]
	if ($p) { return " (lines $($p.start)-$($p.end))" }
	if ($eventName -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return "" }
	return " (not in module)"
}

# --- Helper: extract multilang text ---

function Get-MLText($node) {
	if (-not $node) { return "" }
	$content = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($content) { return $content.InnerText }
	$text = $node.InnerText.Trim()
	if ($text) { return $text }
	return ""
}

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
				$len = if ($sq) { [int]$sq.InnerText } else { 0 }
				if ($len -gt 0) { $parts += "string($len)" } else { $parts += "string" }
			}
			"xs:decimal" {
				$nq = $typeNode.SelectSingleNode("v8:NumberQualifiers", $ns)
				if ($nq) {
					$d = $nq.SelectSingleNode("v8:Digits", $ns)
					$f = $nq.SelectSingleNode("v8:FractionDigits", $ns)
					$digits = if ($d) { $d.InnerText } else { "0" }
					$frac = if ($f) { $f.InnerText } else { "0" }
					$parts += "decimal($digits,$frac)"
				} else {
					$parts += "decimal"
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

# --- Helper: check if title differs from name ---

function Test-TitleDiffers($node, [string]$name) {
	$titleNode = $node.SelectSingleNode("d:Title", $ns)
	if (-not $titleNode) { return $null }
	$titleText = Get-MLText $titleNode
	if (-not $titleText) { return $null }
	# Normalize: remove spaces, lowercase
	$normTitle = ($titleText -replace '\s', '').ToLower()
	$normName = $name.ToLower()
	if ($normTitle -eq $normName) { return $null }
	return $titleText
}

# --- Helper: get events as compact string ---

function Get-EventsStr($node) {
	$eventsNode = $node.SelectSingleNode("d:Events", $ns)
	if (-not $eventsNode) { return "" }
	$evts = @()
	foreach ($e in $eventsNode.SelectNodes("d:Event", $ns)) {
		$eName = $e.GetAttribute("name")
		$ct = $e.GetAttribute("callType")
		$label = if ($ct) { "$eName[$ct]" } else { $eName }
		if ($Handlers) { $label += ": $($e.InnerText.Trim())$(Get-HandlerSuffix $e.InnerText $ct $eName)" }
		$evts += $label
	}
	if ($evts.Count -eq 0) { return "" }
	return " {$($evts -join ', ')}"
}

# --- Helper: get flags ---

function Get-Flags($node) {
	$flags = @()
	$vis = $node.SelectSingleNode("d:Visible", $ns)
	if ($vis -and $vis.InnerText -eq "false") { $flags += "visible:false" }
	$en = $node.SelectSingleNode("d:Enabled", $ns)
	if ($en -and $en.InnerText -eq "false") { $flags += "enabled:false" }
	$ro = $node.SelectSingleNode("d:ReadOnly", $ns)
	if ($ro -and $ro.InnerText -eq "true") { $flags += "ro" }
	if ($flags.Count -eq 0) { return "" }
	return " [$($flags -join ',')]"
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

# --- Count significant children (for Page summary) ---

function Count-SignificantChildren($childItemsNode) {
	if (-not $childItemsNode) { return 0 }
	$count = 0
	foreach ($child in $childItemsNode.ChildNodes) {
		if ($child.NodeType -ne "Element") { continue }
		if ($skipElements.ContainsKey($child.LocalName)) { continue }
		$count++
	}
	return $count
}

# --- Build element tree recursively ---

$treeLines = [System.Collections.Generic.List[string]]::new()
$script:hasCollapsed = $false

# Командная панель и контекстное меню элемента — в дереве, только если в них есть своё:
# кнопки, подменю или отключённое автозаполнение. Стандартные пустые не шумят.
function Get-OwnPanels($node) {
	$out = @()
	foreach ($c in $node.ChildNodes) {
		if ($c.NodeType -ne "Element" -or ($c.LocalName -ne "ContextMenu" -and $c.LocalName -ne "AutoCommandBar")) { continue }
		$ci = $c.SelectSingleNode("d:ChildItems", $ns)
		$af = $c.SelectSingleNode("d:Autofill", $ns)
		if (((Count-SignificantChildren $ci) -gt 0) -or ($af -and $af.InnerText -eq "false")) { $out += $c }
	}
	return $out
}

function Get-SignificantChildren($childItemsNode) {
	$out = @()
	if (-not $childItemsNode) { return $out }
	foreach ($child in $childItemsNode.ChildNodes) {
		if ($child.NodeType -ne "Element") { continue }
		if ($skipElements.ContainsKey($child.LocalName)) { continue }
		$out += $child
	}
	return $out
}

function Build-Tree($childItemsNode, [string]$prefix, [bool]$isLast) {
	if (-not $childItemsNode) { return }
	Build-TreeNodes @(Get-SignificantChildren $childItemsNode) $prefix
}

function Build-TreeNodes($children, [string]$prefix) {
	$children = @($children)
	for ($i = 0; $i -lt $children.Count; $i++) {
		$child = $children[$i]
		$last = ($i -eq $children.Count - 1)
		$connector = if ($last) { [char]0x2514 + [string][char]0x2500 } else { [char]0x251C + [string][char]0x2500 }
		$continuation = if ($last) { "  " } else { [string][char]0x2502 + " " }

		$tag = Get-ElementTag $child
		$name = $child.GetAttribute("name")
		$flags = Get-Flags $child
		$events = Get-EventsStr $child
		$localName = $child.LocalName
		if ($localName -eq "AutoCommandBar" -or $localName -eq "ContextMenu") {
			$af = $child.SelectSingleNode("d:Autofill", $ns)
			if ($af -and $af.InnerText -eq "false") { $flags += " [autofill:false]" }
		}

		# DataPath or CommandName
		$binding = ""
		$dp = $child.SelectSingleNode("d:DataPath", $ns)
		if ($dp) {
			$binding = " -> $($dp.InnerText)"
		} else {
			$cn = $child.SelectSingleNode("d:CommandName", $ns)
			if ($cn) {
				$cnVal = $cn.InnerText
				if ($cnVal -match '^Form\.StandardCommand\.(.+)$') {
					$binding = " -> $($Matches[1]) [std]"
				} elseif ($cnVal -match '^Form\.Item\.(.+)\.StandardCommand\.(.+)$') {
					$binding = " -> $($Matches[1]).$($Matches[2]) [std]"
				} elseif ($cnVal -match '^Form\.Command\.(.+)$') {
					$binding = " -> $($Matches[1]) [cmd]"
				} else {
					$binding = " -> $cnVal"
				}
			}
		}

		# Title differs?
		$titleStr = ""
		$diffTitle = Test-TitleDiffers $child $name
		if ($diffTitle) { $titleStr = " [title:$diffTitle]" }

		$panels = @(Get-OwnPanels $child)
		# Панель таблицы с нестандартным именем — имя в строке таблицы (нужно для правки формы)
		$panelStr = ""
		if ($localName -eq "Table") {
			$acb = $child.SelectSingleNode("d:AutoCommandBar", $ns)
			if ($acb -and $acb.GetAttribute("name") -ne "${name}КоманднаяПанель" -and -not ($panels | Where-Object { $_.LocalName -eq "AutoCommandBar" })) {
				$panelStr = " [cmdBar:$($acb.GetAttribute('name'))]"
			}
		}

		$line = "$prefix$connector $tag $name$binding$flags$titleStr$panelStr$events"
		$treeLines.Add($line)

		# Recurse into containers (but not Page — show summary unless expanded)
		if ($localName -eq "Page") {
			$ci = $child.SelectSingleNode("d:ChildItems", $ns)
			$pageName = $child.GetAttribute("name")
			$pageTitle = Test-TitleDiffers $child $pageName
			$shouldExpand = ($Expand -eq "*") -or ($Expand -eq $pageName) -or ($pageTitle -and $Expand -eq $pageTitle)
			if ($shouldExpand -and $ci) {
				Build-Tree $ci "$prefix$continuation" $last
			} else {
				$cnt = Count-SignificantChildren $ci
				$idx = $treeLines.Count - 1
				# с -Handlers — сколько привязок внутри свёрнутой страницы: без счётчика их не заметить
				$hc = if ($Handlers -and $ci) { $ci.SelectNodes(".//d:Event", $ns).Count } else { 0 }
				$hcStr = if ($hc -gt 0) { ", $hc handlers" } else { "" }
				$treeLines[$idx] = $treeLines[$idx] + " ($cnt items$hcStr)"
				$script:hasCollapsed = $true
			}
		} else {
			$sub = @($panels)
			if ($localName -in @("UsualGroup", "Pages", "Table", "CommandBar", "ButtonGroup", "Popup", "ColumnGroup", "AutoCommandBar", "ContextMenu")) {
				$sub += @(Get-SignificantChildren ($child.SelectSingleNode("d:ChildItems", $ns)))
			}
			if ($sub.Count -gt 0) { Build-TreeNodes $sub "$prefix$continuation" }
		}
	}
}

# --- Determine form name and object from path ---

$resolvedPath = (Resolve-Path $FormPath).ProviderPath
$parts = $resolvedPath -split '[/\\]'

$formName = ""
$objectContext = ""

# Look for /Forms/<FormName>/Ext/Form.xml pattern
$formsIdx = -1
for ($i = $parts.Count - 1; $i -ge 0; $i--) {
	if ($parts[$i] -eq "Forms") { $formsIdx = $i; break }
}

if ($formsIdx -ge 0 -and ($formsIdx + 1) -lt $parts.Count) {
	$formName = $parts[$formsIdx + 1]
	# Object is 2 levels up: .../<ObjectType>/<ObjectName>/Forms/...
	if ($formsIdx -ge 2) {
		$objType = $parts[$formsIdx - 2]
		$objName = $parts[$formsIdx - 1]
		$objectContext = "$objType.$objName"
	}
} else {
	# CommonForms pattern: .../<ObjectType>/<FormName>/Ext/Form.xml
	$extIdx = -1
	for ($i = $parts.Count - 1; $i -ge 0; $i--) {
		if ($parts[$i] -eq "Ext") { $extIdx = $i; break }
	}
	if ($extIdx -ge 2) {
		$formName = $parts[$extIdx - 1]
		$objType = $parts[$extIdx - 2]
		$objectContext = $objType
	} else {
		$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
	}
}

# --- Support status (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Walks up from the target path, taking the
# uuid of the nearest element meta-xml (form/template/etc.) and the config root
# bin. Never throws — degrades to "не на поддержке".
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
function Get-SupportStatusForPath([string]$targetPath) {
	try {
		$rp = (Resolve-Path $targetPath).ProviderPath
		$elemUuid = $null
		$binPath = $null
		# Reads the uuid of the first metadata element in an .xml file (or $null).
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
		# The target file itself may be the element meta-xml (e.g. Subsystems/X.xml).
		$elemUuid = Get-RootUuid $rp
		if (Test-ExternalObjectRoot $rp) { return $null }
		$d = [System.IO.Path]::GetDirectoryName($rp)
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return $null }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $binPath) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $binPath = $cand }
			}
			if ($elemUuid -and $binPath) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		if (-not $binPath -or -not (Test-Path $binPath)) { return "не на поддержке" }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return "снято с поддержки (правки свободны)" }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$h = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $h.Success) { return "не на поддержке" }
		$G = [int]$h.Groups[1].Value
		$K = [int]$h.Groups[2].Value
		if ($K -eq 0) { return "снято с поддержки (правки свободны)" }
		if ($G -eq 1) { return "конфигурация read-only (возможность изменения выключена) — правки невозможны без включения" }
		if (-not $elemUuid) { return "не на поддержке" }
		$u = [regex]::Escape($elemUuid.ToLower())
		$best = $null
		foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
			$f1 = [int]$m.Groups[1].Value
			if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
		}
		if ($null -eq $best) { return "не на поддержке" }
		switch ($best) {
			0 { return "на замке — прямая правка сломает обновления; дорабатывай через cfe-* либо включи редактирование объекта" }
			1 { return "редактируется с сохранением поддержки" }
			2 { return "снято с поддержки (правки свободны)" }
		}
		return "не на поддержке"
	} catch { return "не на поддержке" }
}

# --- Collect output ---

$lines = @()

# Header — include Title if present
$titleNode = $root.SelectSingleNode("d:Title", $ns)
$formTitle = $null
if ($titleNode) {
	$formTitle = Get-MLText $titleNode
	if (-not $formTitle) { $formTitle = $titleNode.InnerText }
}
$extMarker = if ($isExtension) { " [EXTENSION]" } else { "" }
$header = "=== Form: $formName$extMarker"
if ($formTitle) { $header += " — `"$formTitle`"" }
if ($objectContext) { $header += " ($objectContext)" }
$header += " ==="
$lines += $header
$support = Get-SupportStatusForPath $FormPath
if ($null -ne $support) { $lines += "Поддержка: $support" }
if ($Handlers) { $lines += "Module: $(if (Test-Path -LiteralPath $script:modulePath) { $script:modulePath } else { 'none' })$(if ($script:moduleNotUtf8) { ' (not UTF-8 — line ranges unavailable)' })" }

# --- Form properties (Title excluded — shown in header) ---

$propNames = @(
	"Width", "Height", "Group",
	"WindowOpeningMode", "EnterKeyBehavior", "AutoTitle", "AutoURL",
	"AutoFillCheck", "Customizable", "CommandBarLocation",
	"SaveDataInSettings", "AutoSaveDataInSettings",
	"AutoTime", "UsePostingMode", "RepostOnWrite",
	"UseForFoldersAndItems",
	"ReportResult", "DetailsData", "ReportFormType",
	"VerticalScroll", "ScalingMode"
)

$props = @()
foreach ($pn in $propNames) {
	$pNode = $root.SelectSingleNode("d:$pn", $ns)
	if ($pNode) {
		$val = Get-MLText $pNode
		if (-not $val) { $val = $pNode.InnerText }
		$props += "$pn=$val"
	}
}

if ($props.Count -gt 0) {
	$lines += ""
	$lines += "Properties: $($props -join ', ')"
}

# --- Excluded commands ---

$excludedCmds = @()
foreach ($ec in $root.SelectNodes("d:CommandSet/d:ExcludedCommand", $ns)) {
	$excludedCmds += $ec.InnerText
}

# --- Form events ---

$formEvents = $root.SelectSingleNode("d:Events", $ns)
if ($formEvents -and $formEvents.HasChildNodes) {
	$lines += ""
	$lines += "Events:"
	foreach ($e in $formEvents.SelectNodes("d:Event", $ns)) {
		$eName = $e.GetAttribute("name")
		$eHandler = $e.InnerText
		$ct = $e.GetAttribute("callType")
		$ctStr = if ($ct) { "[$ct]" } else { "" }
		$lines += "  $eName${ctStr} -> $eHandler$(Get-HandlerSuffix $eHandler $ct $eName)"
	}
}

# --- Main AutoCommandBar (form's id=-1 panel) ---

function Format-MainAcb($acbNode) {
	if (-not $acbNode) { return @() }
	$result = @()
	$autofillNode = $acbNode.SelectSingleNode("d:Autofill", $ns)
	$autofill = $true
	if ($autofillNode -and $autofillNode.InnerText -eq "false") { $autofill = $false }
	$halignNode = $acbNode.SelectSingleNode("d:HorizontalAlign", $ns)
	$flags = @()
	$flags += if ($autofill) { "autofill" } else { "no-autofill" }
	if ($halignNode) { $flags += "align=$($halignNode.InnerText)" }
	$acbName = $acbNode.GetAttribute("name")
	$header = "AutoCommandBar $acbName [$($flags -join ', ')]"
	$childItemsNode = $acbNode.SelectSingleNode("d:ChildItems", $ns)
	$buttons = @()
	if ($childItemsNode) {
		foreach ($btn in $childItemsNode.ChildNodes) {
			if ($btn.NodeType -ne "Element") { continue }
			if ($skipElements.ContainsKey($btn.LocalName)) { continue }
			$bName = $btn.GetAttribute("name")
			$cmdNode = $btn.SelectSingleNode("d:CommandName", $ns)
			$cmdRef = if ($cmdNode) { $cmdNode.InnerText } else { "" }
			$locNode = $btn.SelectSingleNode("d:LocationInCommandBar", $ns)
			$locStr = if ($locNode) { " [$($locNode.InnerText)]" } else { "" }
			$tag = Get-ElementTag $btn
			if ($cmdRef) {
				$buttons += "  $tag $bName -> $cmdRef$locStr"
			} else {
				$buttons += "  $tag $bName$locStr"
			}
		}
	}
	if ($buttons.Count -eq 0 -and $autofill -and -not $halignNode) {
		# Default empty panel — terse one-liner
		return @("AutoCommandBar $acbName [autofill]")
	}
	$result += $header
	$result += $buttons
	return $result
}

# Determine position from CommandBarLocation form property
$cbLocNode = $root.SelectSingleNode("d:CommandBarLocation", $ns)
$cbLoc = if ($cbLocNode) { $cbLocNode.InnerText } else { "Auto" }
$mainAcbNode = $root.SelectSingleNode("d:AutoCommandBar", $ns)
$acbLines = @()
if ($cbLoc -ne "None" -and $mainAcbNode) {
	$acbLines = Format-MainAcb $mainAcbNode
}

# AutoCommandBar above Elements (Auto/Top)
if ($acbLines.Count -gt 0 -and ($cbLoc -eq "Auto" -or $cbLoc -eq "Top")) {
	$lines += ""
	$lines += $acbLines
}

# --- Element tree ---

$childItems = $root.SelectSingleNode("d:ChildItems", $ns)
if ($childItems) {
	$lines += ""
	$lines += "Elements:"
	Build-Tree $childItems "  " $false
	$lines += $treeLines.ToArray()
}

# AutoCommandBar below Elements (Bottom)
if ($acbLines.Count -gt 0 -and $cbLoc -eq "Bottom") {
	$lines += ""
	$lines += $acbLines
}

# --- Attributes ---

$attrsNode = $root.SelectSingleNode("d:Attributes", $ns)
if ($attrsNode) {
	$attrLines = @()
	foreach ($attr in $attrsNode.SelectNodes("d:Attribute", $ns)) {
		$aName = $attr.GetAttribute("name")
		$typeNode = $attr.SelectSingleNode("d:Type", $ns)
		$typeStr = Format-Type $typeNode

		$mainAttr = $attr.SelectSingleNode("d:MainAttribute", $ns)
		$isMain = ($mainAttr -and $mainAttr.InnerText -eq "true")

		$prefix = if ($isMain) { "*" } else { " " }
		$mainSuffix = if ($isMain) { " (main)" } else { "" }

		# DynamicList: show MainTable
		$settings = $attr.SelectSingleNode("d:Settings", $ns)
		$dynTable = ""
		if ($settings -and $typeStr -eq "DynamicList") {
			$mt = $settings.SelectSingleNode("d:MainTable", $ns)
			if ($mt) { $dynTable = " -> $($mt.InnerText)" }
		}

		# ValueTable/ValueTree columns
		$colStr = ""
		$columns = $attr.SelectSingleNode("d:Columns", $ns)
		if ($columns -and ($typeStr -eq "ValueTable" -or $typeStr -eq "ValueTree")) {
			$cols = @()
			foreach ($col in $columns.SelectNodes("d:Column", $ns)) {
				$cName = $col.GetAttribute("name")
				$cTypeNode = $col.SelectSingleNode("d:Type", $ns)
				$cType = Format-Type $cTypeNode
				if ($cType) { $cols += "$cName`: $cType" } else { $cols += $cName }
			}
			if ($cols.Count -gt 0) {
				$colStr = " [$($cols -join ', ')]"
			}
		}

		$line = "  $prefix$aName`: $typeStr$colStr$dynTable$mainSuffix"
		if (-not $typeStr -and -not $colStr -and -not $dynTable) {
			$line = "  $prefix$aName$mainSuffix"
		}
		$attrLines += $line
	}
	if ($attrLines.Count -gt 0) {
		$lines += ""
		$lines += "Attributes:"
		$lines += $attrLines
	}
}

# --- Parameters ---

$paramsNode = $root.SelectSingleNode("d:Parameters", $ns)
if ($paramsNode) {
	$paramLines = @()
	foreach ($param in $paramsNode.SelectNodes("d:Parameter", $ns)) {
		$pName = $param.GetAttribute("name")
		$typeNode = $param.SelectSingleNode("d:Type", $ns)
		$typeStr = Format-Type $typeNode

		$keyParam = $param.SelectSingleNode("d:KeyParameter", $ns)
		$isKey = ($keyParam -and $keyParam.InnerText -eq "true")
		$keySuffix = if ($isKey) { " (key)" } else { "" }

		if ($typeStr) {
			$paramLines += "  $pName`: $typeStr$keySuffix"
		} else {
			$paramLines += "  $pName$keySuffix"
		}
	}
	if ($paramLines.Count -gt 0) {
		$lines += ""
		$lines += "Parameters:"
		$lines += $paramLines
	}
}

# --- Commands ---

$cmdsNode = $root.SelectSingleNode("d:Commands", $ns)
if ($cmdsNode) {
	$cmdLines = @()
	foreach ($cmd in $cmdsNode.SelectNodes("d:Command", $ns)) {
		$cName = $cmd.GetAttribute("name")
		$shortcut = $cmd.SelectSingleNode("d:Shortcut", $ns)
		$scStr = if ($shortcut) { " [$($shortcut.InnerText)]" } else { "" }

		# Collect all Action elements (may have multiple with callType)
		$actions = $cmd.SelectNodes("d:Action", $ns)
		if ($actions.Count -gt 1) {
			$actParts = @()
			foreach ($a in $actions) {
				$ct = $a.GetAttribute("callType")
				$ctStr = if ($ct) { "[$ct]" } else { "" }
				$actParts += "$($a.InnerText)$ctStr$(Get-HandlerSuffix $a.InnerText $ct 'Action')"
			}
			$actionStr = " -> $($actParts -join ', ')"
		} elseif ($actions.Count -eq 1) {
			$ct = $actions[0].GetAttribute("callType")
			$ctStr = if ($ct) { "[$ct]" } else { "" }
			$actionStr = " -> $($actions[0].InnerText)$ctStr$(Get-HandlerSuffix $actions[0].InnerText $ct 'Action')"
		} else {
			$actionStr = ""
		}

		$cmdLines += "  $cName$actionStr$scStr"
	}
	if ($cmdLines.Count -gt 0) {
		$lines += ""
		$lines += "Commands:"
		$lines += $cmdLines
	}
}

# --- BaseForm footer ---

if ($isExtension) {
	$bfVersion = $baseFormNode.GetAttribute("version")
	$bfStr = if ($bfVersion) { "present (version $bfVersion)" } else { "present" }
	$lines += ""
	$lines += "BaseForm: $bfStr"
}

# --- Hints ---

$hints = @()
if ($script:hasCollapsed) { $hints += "Hint: use -Expand <name> to expand a collapsed section, -Expand * for all" }
if (-not $Handlers -and $null -ne $root.SelectSingleNode(".//d:Events/d:Event | d:Commands/d:Command/d:Action", $ns)) {
	$hints += "Hint: use -Handlers to show handler names with their line ranges in Form/Module.bsl"
}
if ($hints.Count -gt 0) {
	$lines += ""
	$lines += $hints
}

# --- Truncation protection ---

$totalLines = $lines.Count

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$lines = $lines[$Offset..($totalLines - 1)]
}

if ($lines.Count -gt $Limit) {
	$shown = $lines[0..($Limit - 1)]
	foreach ($l in $shown) { Write-Host $l }
	$remaining = $totalLines - $Offset - $Limit
	Write-Host ""
	Write-Host "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
	# Подсказки стоят в конце вывода — при обрезке повторяем их здесь
	foreach ($h in $hints) { Write-Host $h }
} else {
	foreach ($l in $lines) { Write-Host $l }
}
