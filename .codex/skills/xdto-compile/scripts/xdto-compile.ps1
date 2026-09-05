# xdto-compile v1.15 — Build a 1C XDTO package from an XML Schema (XSD) (+support-guard: общая реализация вместо урезанной)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory=$true, ParameterSetName='File')]
	[Alias('Path')]
	[string]$XsdPath,
	[Parameter(Mandatory=$true, ParameterSetName='Inline')]
	[string]$Xsd,
	[Parameter(Mandatory=$true)]
	[string]$OutputDir,
	[string]$Name,
	[object]$Synonym,
	[string]$Comment,
	[switch]$Force
)

$ErrorActionPreference = "Stop"

# Эти пространства имён предоставляет сама платформа — пакетов в конфигурации
# для них нет и быть не должно (выведено по корпусу: импортируются, но
# targetNamespace с таким значением ни у одного пакета нет)
$PLATFORM_NS = @(
		"http://v8.1c.ru/8.1/data/core",
		"http://v8.1c.ru/8.1/data/enterprise",
		"http://v8.1c.ru/8.1/data/enterprise/current-config",
		"http://v8.1c.ru/8.1/data-composition-system/settings",
		"http://v8.1c.ru/8.3/data/ext",
		"http://www.w3.org/2001/XMLSchema"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$XDTO_NS = "http://v8.1c.ru/8.1/xdto"
$XS_NS   = "http://www.w3.org/2001/XMLSchema"
$XSI_NS  = "http://www.w3.org/2001/XMLSchema-instance"
$MD_NS   = "http://v8.1c.ru/8.3/MDClasses"
$V8_NS   = "http://v8.1c.ru/8.1/data/core"

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

# --- Detect format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

# --- Load the schema ---

if ($PSCmdlet.ParameterSetName -eq 'Inline') {
	$xsdText = $Xsd
	$defaultName = "Package"
} else {
	if (-not (Test-Path $XsdPath -PathType Leaf)) { throw "Файл XSD не найден: $XsdPath" }
	$xsdText = [System.IO.File]::ReadAllText($XsdPath)
	$defaultName = [System.IO.Path]::GetFileNameWithoutExtension($XsdPath)
}

$xdoc = New-Object System.Xml.XmlDocument
$xdoc.PreserveWhitespace = $false
try { $xdoc.LoadXml($xsdText) } catch { throw "Не удалось разобрать XSD: $($_.Exception.Message)" }

$schema = $xdoc.DocumentElement
if ($schema.get_LocalName() -ne "schema" -or $schema.NamespaceURI -ne $XS_NS) {
	throw "Ожидался корневой <xs:schema> в пространстве имён $XS_NS"
}

$targetNs = $schema.GetAttribute("targetNamespace")

# --- Emit-tree primitives -----------------------------------------------------
# A node carries attributes in canonical order; QName values keep their namespace
# so prefixes can be assigned per depth at serialization time (the dNpN scheme).

function New-Node([string]$tag) {
	return [pscustomobject]@{ Tag = $tag; Attrs = (New-Object System.Collections.ArrayList); Children = (New-Object System.Collections.ArrayList); Text = $null; Prefix = $null; DeclareNs = $null }
}
function Add-Attr($node, [string]$name, $value) {
	# $value НЕ типизируем: [string]$null коэрсится в "" и атрибут ложно появляется
	if ($null -eq $value) { return }
	[void]$node.Attrs.Add([pscustomobject]@{ Name = $name; Value = [string]$value; Ns = $null; Local = $null })
}
function Add-QAttr($node, [string]$name, $ns, $local) {
	if ($null -eq $local) { return }
	[void]$node.Attrs.Add([pscustomobject]@{ Name = $name; Value = $null; Ns = [string]$ns; Local = [string]$local })
}
function Add-QListAttr($node, [string]$name, $pairs, [bool]$clark) {
	if (-not $pairs -or $pairs.Count -eq 0) { return }
	[void]$node.Attrs.Add([pscustomobject]@{ Name = $name; Value = $null; Ns = $null; Local = $null; List = $pairs; Clark = $clark })
}
function Add-Child($node, $child) { if ($child) { [void]$node.Children.Add($child) } }

# Canonical attribute order per element — derived by topological sort over the
# whole 8.3.24 corpus (acc + erp, 760 packages), see docs/1c-xdto-spec.md.
$ATTR_ORDER = @{
	"package"     = @("targetNamespace", "elementFormQualified", "attributeFormQualified")
	"import"      = @("namespace")
	"objectType"  = @("name", "base", "open", "abstract", "mixed", "ordered", "sequenced")
	"property"    = @("name", "ref", "type", "lowerBound", "upperBound", "nillable", "fixed", "default", "form", "localName", "qualified")
	"valueType"   = @("name", "base", "variety", "itemType", "length", "memberTypes", "minExclusive", "maxExclusive", "minInclusive", "maxInclusive", "minLength", "maxLength", "totalDigits", "fractionDigits", "whiteSpace")
	"typeDef"     = @("xsi:type", "base", "mixed", "open", "ordered", "sequenced", "variety", "itemType", "length", "memberTypes", "minExclusive", "maxExclusive", "minInclusive", "maxInclusive", "minLength", "maxLength", "totalDigits", "fractionDigits", "whiteSpace")
	"enumeration" = @("xsi:type")
}

function Sort-Attrs($node) {
	$order = $ATTR_ORDER[$node.Tag]
	if (-not $order) { return $node.Attrs }
	$sorted = New-Object System.Collections.ArrayList
	foreach ($n in $order) {
		foreach ($a in $node.Attrs) { if ($a.Name -eq $n) { [void]$sorted.Add($a) } }
	}
	foreach ($a in $node.Attrs) { if ($order -notcontains $a.Name) { [void]$sorted.Add($a) } }
	return $sorted
}

function Esc([string]$s) {
	if ($null -eq $s) { return "" }
	return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}
function EscText([string]$s) {
	if ($null -eq $s) { return "" }
	return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

# --- Serializer with the dNpN prefix scheme ---

$out = New-Object System.Text.StringBuilder

function Serialize-Node($node, [int]$depth, $inherited) {
	$indent = "`t" * ($depth - 1)
	$attrs = Sort-Attrs $node

	# Namespaces needing a NEW declaration here: те, что ещё не в области видимости.
	# Сериализатор платформы объявляет префикс на первом узле, где он нужен, а
	# потомки его переиспользуют — отсюда d2p1 у property внутри objectType.
	$localNs = New-Object System.Collections.ArrayList
	function Need-Prefix([string]$ns) {
		if (-not $ns -or $ns -eq $XS_NS -or $ns -eq $XSI_NS) { return }
		if ($inherited.ContainsKey($ns)) { return }
		if (-not $localNs.Contains($ns)) { [void]$localNs.Add($ns) }
	}
	foreach ($a in $attrs) {
		if ($a.PSObject.Properties.Name -contains 'List' -and $a.List) {
			# Нотация Кларка несёт ns в значении и префикса не требует; редкие
			# случаи, где платформа его всё же объявила, приходят зеркалом declareNs
			if (-not $a.Clark) { foreach ($p in $a.List) { Need-Prefix $p.Ns } }
		} elseif ($a.Ns) { Need-Prefix $a.Ns }
	}
	# Свойство с qualified платформа сериализует с явным префиксом пространства
	# имён XDTO — и в имени тега, и в имени самого атрибута
	$hasQualified = $false
	foreach ($a in $attrs) { if ($a.Name -eq "qualified") { $hasQualified = $true } }
	if ($hasQualified) { Need-Prefix $XDTO_NS }
	if ($node.DeclareNs) { Need-Prefix $node.DeclareNs }

	$prefixOf = @{}
	foreach ($k in $inherited.Keys) { $prefixOf[$k] = $inherited[$k] }
	$nsDecls = ""
	for ($i = 0; $i -lt $localNs.Count; $i++) {
		# Осмысленный префикс из исходника (зеркало xdto:prefix) имеет приоритет
		$px = if ($i -eq 0 -and $node.Prefix) { $node.Prefix } else { "d${depth}p$($i + 1)" }
		$prefixOf[$localNs[$i]] = $px
		$nsDecls += " xmlns:$px=`"$(Esc $localNs[$i])`""
	}
	function QVal([string]$ns, [string]$local) {
		if (-not $ns) { return $local }
		if ($ns -eq $XS_NS) { return "xs:$local" }
		if ($ns -eq $XSI_NS) { return "xsi:$local" }
		return "$($prefixOf[$ns]):$local"
	}

	$attrText = ""
	foreach ($a in $attrs) {
		if ($a.PSObject.Properties.Name -contains 'List' -and $a.List) {
			$vals = @()
			foreach ($p in $a.List) {
				if ($a.Clark) { $vals += $(if ($p.Ns) { "{$($p.Ns)}$($p.Local)" } else { $p.Local }) }
				else { $vals += (QVal $p.Ns $p.Local) }
			}
			$attrText += " $($a.Name)=`"$(Esc ($vals -join ' '))`""
		} elseif ($a.Ns -or $a.Local) {
			$attrText += " $($a.Name)=`"$(Esc (QVal $a.Ns $a.Local))`""
		} elseif ($a.Name -eq "qualified") {
			$attrText += " $($prefixOf[$XDTO_NS]):qualified=`"$(Esc $a.Value)`""
		} else {
			$attrText += " $($a.Name)=`"$(Esc $a.Value)`""
		}
	}

	$tagName = $node.Tag
	if ($hasQualified) { $tagName = "$($prefixOf[$XDTO_NS]):$($node.Tag)" }

	$hasChildren = $node.Children.Count -gt 0
	# Пустое значение пишется самозакрывающимся тегом: <enumeration/>, а не <enumeration></enumeration>
	$hasText = ($null -ne $node.Text -and $node.Text -ne "")

	if (-not $hasChildren -and -not $hasText) {
		[void]$out.Append("$indent<$tagName$nsDecls$attrText/>`r`n")
		return
	}
	if ($hasText -and -not $hasChildren) {
		[void]$out.Append("$indent<$tagName$nsDecls$attrText>$(EscText $node.Text)</$tagName>`r`n")
		return
	}
	[void]$out.Append("$indent<$tagName$nsDecls$attrText>`r`n")
	foreach ($c in $node.Children) { Serialize-Node $c ($depth + 1) $prefixOf }
	[void]$out.Append("$indent</$tagName>`r`n")
}

# --- XSD reading helpers ---

# Предупреждения о том, что XSD выражает, а модель XDTO — нет. Молча ронять
# такие конструкции нельзя: пакет соберётся, а половина свойств исчезнет.
$script:warnings = New-Object System.Collections.ArrayList
function Warn([string]$msg) {
	if (-not $script:warnings.Contains($msg)) { [void]$script:warnings.Add($msg) }
}

function XA([System.Xml.XmlElement]$el, [string]$name) {
	if ($el.HasAttribute($name)) { return $el.GetAttribute($name) }
	return $null
}
function MA([System.Xml.XmlElement]$el, [string]$name) {
	# xdto: mirror attribute — the literal value to write into Package.bin.
	# Префикс не фиксируем: ищем по namespace, а не по строке "xdto:".
	$a = $el.Attributes.GetNamedItem($name, $XDTO_NS)
	if ($null -eq $a) { return $null }
	return $a.Value
}
function XChildren([System.Xml.XmlElement]$el, [string]$local) {
	$res = New-Object System.Collections.ArrayList
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.NamespaceURI -eq $XS_NS -and $c.get_LocalName() -eq $local) { [void]$res.Add($c) }
	}
	# ArrayList, а не @(): PowerShell разворачивает массив из одного элемента при return
	return ,$res
}
function XFirst([System.Xml.XmlElement]$el, [string]$local) {
	$r = XChildren $el $local
	if ($r.Count -gt 0) { return $r[0] }
	return $null
}

# Split a QName from the XSD into (ns, local) using that element's prefix scope
function Split-QName([System.Xml.XmlElement]$el, [string]$qname) {
	if ($null -eq $qname -or $qname -eq "") { return $null }
	$parts = $qname.Split(":")
	if ($parts.Count -eq 2) {
		$ns = $el.GetNamespaceOfPrefix($parts[0])
		$local = $parts[1]
	} else {
		# Прощающий ввод: голое имя типа трактуем как тип целевого пространства
		$ns = $el.GetNamespaceOfPrefix("")
		if (-not $ns) { $ns = $targetNs }
		$local = $parts[0]
	}
	return [pscustomobject]@{ Ns = $ns; Local = $local }
}
function Split-QNameList([System.Xml.XmlElement]$el, [string]$list) {
	if (-not $list) { return @() }
	$res = @()
	foreach ($q in ($list -split "\s+")) { if ($q) { $res += (Split-QName $el $q) } }
	return $res
}

$FACETS = @("length", "minLength", "maxLength", "totalDigits", "fractionDigits",
            "minInclusive", "maxInclusive", "minExclusive", "maxExclusive", "whiteSpace")

# --- simpleType -> valueType / typeDef(ValueType) ---

function Fill-SimpleType($node, [System.Xml.XmlElement]$st) {
	$restriction = XFirst $st "restriction"
	$list        = XFirst $st "list"
	$union       = XFirst $st "union"

	if ($list) {
		$it = Split-QName $list (XA $list "itemType")
		$mv = MA $list "variety"
		Add-Attr $node "variety" $(if ($null -ne $mv) { $mv } else { "List" })
		if ($it) { Add-QAttr $node "itemType" $it.Ns $it.Local }
		return
	}
	if ($union) {
		$mv = MA $union "variety"
		Set-AttrValue $node "variety" $(if ($null -ne $mv) { $mv } else { "Union" })
		$members = @(Split-QNameList $union (XA $union "memberTypes"))
		# По умолчанию нотация Кларка — так записано 125 из 135 memberTypes корпуса
		$useClark = ((MA $union "memberTypesForm") -ne "prefixed")
		if ($members.Count -gt 0) { Add-QListAttr $node "memberTypes" $members $useClark }
		$node.DeclareNs = MA $union "declareNs"
		foreach ($anon in (XChildren $union "simpleType")) {
			# typeDef в контексте простого типа xsi:type не несёт (40 узлов корпуса)
			$td = New-Node "typeDef"
			Fill-SimpleType $td $anon
			Add-Child $node $td
		}
		return
	}
	if ($restriction) {
		$b = Split-QName $restriction (XA $restriction "base")
		if ($b) { Add-QAttr $node "base" $b.Ns $b.Local }
		$mv = MA $restriction "variety"
		if ($null -ne $mv) { Add-Attr $node "variety" $mv }
		# Анонимный базовый тип внутри xs:restriction — typeDef без xsi:type
		$anonBase = XFirst $restriction "simpleType"
		if ($anonBase) {
			$td = New-Node "typeDef"
			Fill-SimpleType $td $anonBase
			Add-Child $node $td
		}
		foreach ($f in $FACETS) {
			foreach ($fe in (XChildren $restriction $f)) { Add-Attr $node $f (XA $fe "value") }
		}
		foreach ($pe in (XChildren $restriction "pattern")) {
			$pn = New-Node "pattern"; $pn.Text = (XA $pe "value"); Add-Child $node $pn
		}
		foreach ($en in (XChildren $restriction "enumeration")) {
			$enode = New-Node "enumeration"
			$mt = MA $en "type"
			if ($null -ne $mt) {
				$q = Split-QName $en $mt
				Add-QAttr $enode "xsi:type" $q.Ns $q.Local
			}
			$enode.Text = (XA $en "value")
			Add-Child $node $enode
		}
	}
}

function Get-PropKey($p) {
	foreach ($a in $p.Attrs) { if ($a.Name -eq "name") { return $a.Value } }
	foreach ($a in $p.Attrs) { if ($a.Name -eq "ref") { return "@" + $a.Local } }
	return $null
}

# Восстановить исходный порядок свойств по зеркалу xdto:order
function Reorder-Properties($node, $names) {
	$props = @($node.Children | Where-Object { $_.Tag -eq "property" })
	if ($props.Count -lt 2) { return }
	$byKey = @{}
	foreach ($p in $props) {
		$k = Get-PropKey $p
		if ($null -ne $k -and -not $byKey.ContainsKey($k)) { $byKey[$k] = $p }
	}
	$ordered = New-Object System.Collections.ArrayList
	foreach ($n in $names) {
		if ($byKey.ContainsKey($n)) { [void]$ordered.Add($byKey[$n]); $byKey.Remove($n) }
	}
	foreach ($p in $props) { if ($ordered -notcontains $p) { [void]$ordered.Add($p) } }
	$others = @($node.Children | Where-Object { $_.Tag -ne "property" })
	$node.Children.Clear()
	foreach ($p in $ordered) { [void]$node.Children.Add($p) }
	foreach ($o in $others) { [void]$node.Children.Add($o) }
}

function Set-AttrValue($node, [string]$name, [string]$value) {
	foreach ($a in $node.Attrs) { if ($a.Name -eq $name) { $a.Value = $value; return } }
	Add-Attr $node $name $value
}

# --- element / attribute -> property ---

function Build-Property([System.Xml.XmlElement]$el, [bool]$isAttribute) {
	$p = New-Node "property"

	$xsdName = XA $el "name"
	$mirrorName = MA $el "name"
	if ($null -ne $mirrorName) {
		Add-Attr $p "name" $mirrorName
		$localName = $xsdName
	} else {
		Add-Attr $p "name" $xsdName
		$localName = $null
	}

	$refQ = Split-QName $el (XA $el "ref")
	if ($refQ) { Add-QAttr $p "ref" $refQ.Ns $refQ.Local }

	$typeQ = Split-QName $el (XA $el "type")
	if ($typeQ) { Add-QAttr $p "type" $typeQ.Ns $typeQ.Local }

	if ($isAttribute) {
		Add-Attr $p "lowerBound" (MA $el "lowerBound")
		Add-Attr $p "upperBound" (MA $el "upperBound")
		Add-Attr $p "nillable"   (MA $el "nillable")
	} else {
		Add-Attr $p "lowerBound" (XA $el "minOccurs")
		$maxOcc = XA $el "maxOccurs"
		if ($null -ne $maxOcc) { Add-Attr $p "upperBound" $(if ($maxOcc -eq "unbounded") { "-1" } else { $maxOcc }) }
		Add-Attr $p "nillable" (XA $el "nillable")
	}

	# XSD-шный fixed="V" несёт значение, в модели это fixed="true" + default="V".
	# Прощающий ввод: модельная форма через зеркало xdto:fixed тоже принимается.
	$mFixed = MA $el "fixed"
	if ($null -ne $mFixed) {
		Add-Attr $p "fixed" $mFixed
		Add-Attr $p "default" (XA $el "default")
		if ($mFixed -ceq "true" -and $null -eq (XA $el "default")) {
			Warn "Свойство `"$(XA $el 'name')`": xdto:fixed=`"true`" без default — платформа отвергнет пакет («Отсутствует фиксированное значение»). Значение задаётся атрибутом default, либо пишите XSD-форму fixed=`"значение`""
		}
	} elseif ($null -ne (XA $el "fixed")) {
		Add-Attr $p "fixed" "true"
		Add-Attr $p "default" (XA $el "fixed")
	} else {
		Add-Attr $p "default" (XA $el "default")
	}

	if ($isAttribute) {
		Add-Attr $p "form" "Attribute"
	} else {
		$mf = MA $el "form"
		if ($null -ne $mf) { Add-Attr $p "form" $mf }
	}
	Add-Attr $p "localName" $localName
	Add-Attr $p "qualified" (MA $el "qualified")
	$p.Prefix = MA $el "prefix"

	# Anonymous inline type
	$anonSimple  = XFirst $el "simpleType"
	$anonComplex = XFirst $el "complexType"
	if ($anonSimple) {
		$td = New-Node "typeDef"
		Add-Attr $td "xsi:type" "ValueType"
		Fill-SimpleType $td $anonSimple
		Add-Child $p $td
	} elseif ($anonComplex) {
		$td = New-Node "typeDef"
		Add-Attr $td "xsi:type" "ObjectType"
		Fill-ComplexType $td $anonComplex
		Add-Child $p $td
	}
	return $p
}

# --- complexType -> objectType / typeDef(ObjectType) ---

# Разрешение xs:group / xs:attributeGroup по ссылке
$script:GROUPS = @{}
$script:ATTR_GROUPS = @{}
function Resolve-Group([System.Xml.XmlElement]$el, [string]$kind) {
	$ref = XA $el "ref"
	if (-not $ref) { return $null }
	$q = Split-QName $el $ref
	if (-not $q) { return $null }
	$map = if ($kind -eq "group") { $script:GROUPS } else { $script:ATTR_GROUPS }
	if ($map.ContainsKey($q.Local)) { return $map[$q.Local] }
	return $null
}

# Модель XDTO знает только плоский список свойств: вложенные частицы уплощаются.
# Каждое уплощение — предупреждение, потому что меняется смысл схемы.
function Collect-Particle([System.Xml.XmlElement]$particle, $elemList, [ref]$isOpen, [string]$typeName, [int]$depth, [bool]$optionalize = $false) {
	if ($depth -gt 20) { return }
	foreach ($c in $particle.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.NamespaceURI -ne $XS_NS) { continue }
		switch ($c.get_LocalName()) {
			"element" {
				$prop = Build-Property $c $false
				# Ветка уплощённого xs:choice обязана стать необязательной: иначе
				# «одно из двух» превращается в «оба сразу», и тип нельзя заполнить
				if ($optionalize) { Set-AttrValue $prop "lowerBound" "0" }
				[void]$elemList.Add($prop)
			}
			"any"     { $isOpen.Value = $true }
			"sequence" {
				Warn "$typeName : вложенная xs:sequence уплощена — модель XDTO хранит плоский список свойств"
				Collect-Particle $c $elemList $isOpen $typeName ($depth + 1) $optionalize
			}
			"choice" {
				$branches = @()
				foreach ($b in $c.ChildNodes) {
					if ($b.NodeType -eq [System.Xml.XmlNodeType]::Element -and $b.NamespaceURI -eq $XS_NS -and $b.HasAttribute("name")) {
						$branches += $b.GetAttribute("name")
					}
				}
				$list = if ($branches.Count -gt 0) { " (" + ($branches -join ", ") + ")" } else { "" }
				Warn ("$typeName : вложенная xs:choice уплощена — ветки$list сделаны необязательными. " +
					"Выбор одного из вариантов не сохранён: модель не запретит заполнить сразу несколько или ни одного")
				Collect-Particle $c $elemList $isOpen $typeName ($depth + 1) $true
			}
			"all" {
				Warn "$typeName : xs:all трактуется как последовательность"
				Collect-Particle $c $elemList $isOpen $typeName ($depth + 1) $optionalize
			}
			"group" {
				$g = Resolve-Group $c "group"
				if ($g) {
					foreach ($gc in $g.ChildNodes) {
						if ($gc.NodeType -eq [System.Xml.XmlNodeType]::Element -and $gc.NamespaceURI -eq $XS_NS -and
						    @("sequence", "choice", "all") -contains $gc.get_LocalName()) {
							Collect-Particle $gc $elemList $isOpen $typeName ($depth + 1) $optionalize
						}
					}
				} else {
					Warn "$typeName : не найдена группа $(XA $c 'ref') — её свойства в пакет не попали"
				}
			}
		}
		# Кратность на самой частице модель выразить не может
		if (@("sequence", "choice", "all", "group") -contains $c.get_LocalName()) {
			if ((XA $c "maxOccurs") -or (XA $c "minOccurs")) {
				Warn "$typeName : кратность на вложенной частице (<xs:$($c.get_LocalName()) minOccurs/maxOccurs>) не выражается в модели XDTO"
			}
		}
	}
}

# open / ordered / sequenced / abstract / mixed: выводим где выводимо,
# остальное приходит зеркалом xdto:
function Set-TypeFlags($node, [System.Xml.XmlElement]$ct, $isOpen, $choice) {
	$mOpen = MA $ct "open"
	if ($null -ne $mOpen) { Add-Attr $node "open" $mOpen }
	elseif ($isOpen) { Add-Attr $node "open" "true" }

	$mOrdered = MA $ct "ordered"
	if ($null -ne $mOrdered) { Add-Attr $node "ordered" $mOrdered }
	elseif ($choice) { Add-Attr $node "ordered" "false" }

	$mSeq = MA $ct "sequenced"
	if ($null -ne $mSeq) { Add-Attr $node "sequenced" $mSeq }

	$mAbstract = MA $ct "abstract"
	if ($null -ne $mAbstract) { Add-Attr $node "abstract" $mAbstract }
	elseif ((XA $ct "abstract") -eq "true") { Add-Attr $node "abstract" "true" }

	$mMixed = MA $ct "mixed"
	if ($null -ne $mMixed) { Add-Attr $node "mixed" $mMixed }
	elseif ((XA $ct "mixed") -eq "true") { Add-Attr $node "mixed" "true" }
}

function Fill-ComplexType($node, [System.Xml.XmlElement]$ct) {
	# xs:complexContent/xs:extension carries the base type
	$content = XFirst $ct "complexContent"
	$body = $ct
	if ($content) {
		$ext = XFirst $content "extension"
		if ($ext) {
			$b = Split-QName $ext (XA $ext "base")
			if ($b) { Add-QAttr $node "base" $b.Ns $b.Local }
			$body = $ext
		}
	}

	# xs:simpleContent -> a "Text" property holding the element's own value
	$simple = XFirst $ct "simpleContent"
	if ($simple) {
		$ext = XFirst $simple "extension"
		if ($ext) {
			foreach ($a in (XChildren $ext "attribute")) { Add-Child $node (Build-Property $a $true) }
			$tp = New-Node "property"
			$tName = MA $ext "textName"
			Add-Attr $tp "name" $(if ($null -ne $tName) { $tName } else { "__content" })
			$b = Split-QName $ext (XA $ext "base")
			if ($b) { Add-QAttr $tp "type" $b.Ns $b.Local }
			Add-Attr $tp "lowerBound" (MA $ext "textlowerBound")
			Add-Attr $tp "upperBound" (MA $ext "textupperBound")
			Add-Attr $tp "nillable"   (MA $ext "textnillable")
			Add-Attr $tp "form" "Text"
			Add-Child $node $tp
			# xs:simpleContent не отменяет флаги самого xs:complexType
			Set-TypeFlags $node $ct $false $null
			return
		}
	}

	# Particle: xs:sequence (ordered) or xs:choice (ordered="false")
	$seq = XFirst $body "sequence"
	$cho = XFirst $body "choice"
	$all = XFirst $body "all"
	$grp = XFirst $body "group"
	$particle = if ($seq) { $seq } elseif ($cho) { $cho } elseif ($all) { $all } else { $grp }
	$isOpen = $false

	# Порядок в XDTO: сначала form="Attribute", потом остальные (верно для 96.5%
	# типов корпуса). Отклонения приходят зеркалом xdto:order.
	$elemProps = New-Object System.Collections.ArrayList
	$typeName = if ($ct.HasAttribute("name")) { $ct.GetAttribute("name") } else { "(анонимный тип)" }
	if ($particle) {
		$openRef = [ref]$isOpen
		if ($all) {
			Warn "$typeName : xs:all трактуется как последовательность"
		}
		if ($grp -and -not $seq -and -not $cho -and -not $all) {
			# Корневая частица задана ссылкой на группу — раскрываем её содержимое
			$g = Resolve-Group $grp "group"
			if ($g) {
				foreach ($gc in $g.ChildNodes) {
					if ($gc.NodeType -eq [System.Xml.XmlNodeType]::Element -and $gc.NamespaceURI -eq $XS_NS -and
					    @("sequence", "choice", "all") -contains $gc.get_LocalName()) {
						Collect-Particle $gc $elemProps $openRef $typeName 1
					}
				}
			} else {
				Warn "$typeName : не найдена группа $(XA $grp 'ref') — её свойства в пакет не попали"
			}
		} else {
			Collect-Particle $particle $elemProps $openRef $typeName 0
		}
		$isOpen = $openRef.Value
	}
	foreach ($a in (XChildren $body "attribute")) { Add-Child $node (Build-Property $a $true) }
	# xs:attributeGroup раскрываем по ссылке
	foreach ($ag in (XChildren $body "attributeGroup")) {
		$g = Resolve-Group $ag "attributeGroup"
		if ($g) {
			foreach ($a in (XChildren $g "attribute")) { Add-Child $node (Build-Property $a $true) }
		} else {
			Warn "Не найдена группа атрибутов $(XA $ag 'ref') — её атрибуты в пакет не попали"
		}
	}
	foreach ($e in $elemProps) { Add-Child $node $e }
	if ((XChildren $body "anyAttribute").Count -gt 0) { $isOpen = $true }

	$mOrder = MA $ct "order"
	if ($null -ne $mOrder) { Reorder-Properties $node ($mOrder -split "\|") }

	Set-TypeFlags $node $ct $isOpen $cho
}

# --- Build the package tree ---

$pkgNode = New-Node "package"
Add-Attr $pkgNode "targetNamespace" $targetNs

$efqMirror = MA $schema "elementFormQualified"
$afqMirror = MA $schema "attributeFormQualified"
$efd = XA $schema "elementFormDefault"
$afd = XA $schema "attributeFormDefault"
if ($null -ne $efqMirror) { Add-Attr $pkgNode "elementFormQualified" $efqMirror }
elseif ($null -ne $efd)   { Add-Attr $pkgNode "elementFormQualified" $(if ($efd -eq "qualified") { "true" } else { "false" }) }
if ($null -ne $afqMirror) { Add-Attr $pkgNode "attributeFormQualified" $afqMirror }
elseif ($null -ne $afd)   { Add-Attr $pkgNode "attributeFormQualified" $(if ($afd -eq "qualified") { "true" } else { "false" }) }

# Metadata properties from xs:annotation/xs:appinfo
$metaName = $null; $metaComment = $null; $metaSynonym = @()
$ann = XFirst $schema "annotation"
if ($ann) {
	$appinfo = XFirst $ann "appinfo"
	if ($appinfo) {
		foreach ($pk in $appinfo.ChildNodes) {
			if ($pk.NodeType -ne [System.Xml.XmlNodeType]::Element -or $pk.NamespaceURI -ne $XDTO_NS) { continue }
			foreach ($f in $pk.ChildNodes) {
				if ($f.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
				switch ($f.get_LocalName()) {
					"name"    { $metaName = $f.InnerText }
					"comment" { $metaComment = $f.InnerText }
					"synonym" { $metaSynonym += @{ Lang = $f.GetAttribute("lang"); Content = $f.InnerText } }
				}
			}
		}
	}
}

# Реестр глобальных групп — нужен до обхода, чтобы раскрывать ссылки
foreach ($node in $schema.ChildNodes) {
	if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element -or $node.NamespaceURI -ne $XS_NS) { continue }
	$nm = XA $node "name"
	if ($node.get_LocalName() -eq "group" -and $nm) { $script:GROUPS[$nm] = $node }
	if ($node.get_LocalName() -eq "attributeGroup" -and $nm) { $script:ATTR_GROUPS[$nm] = $node }
}

# Конструкции XSD, которым в модели XDTO нет соответствия
foreach ($sg in $schema.SelectNodes("//*[local-name()='element'][@substitutionGroup]")) {
	Warn "Подстановочные группы (substitutionGroup) не поддерживаются моделью XDTO — объявление $($sg.GetAttribute('name')) сохранено как обычное"
}
foreach ($idc in @("key", "keyref", "unique")) {
	if ($schema.SelectNodes("//*[local-name()='$idc']").Count -gt 0) {
		Warn "Ограничения целостности (xs:$idc) в модели XDTO не хранятся — отброшены"
	}
}
if ($schema.SelectNodes("//*[local-name()='redefine']").Count -gt 0) {
	Warn "xs:redefine не поддерживается — переопределения проигнорированы"
}
if ($schema.SelectNodes("//*[local-name()='include']").Count -gt 0) {
	Warn "xs:include проигнорирован: модель XDTO разрешает зависимости только по namespace. Соберите включаемую схему отдельным пакетом и добавьте <xs:import>"
}

foreach ($node in $schema.ChildNodes) {
	if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element -or $node.NamespaceURI -ne $XS_NS) { continue }
	switch ($node.get_LocalName()) {
		"annotation" { }
		"group" { }
		"attributeGroup" { }
		"notation" { }
		"import" {
			$n = New-Node "import"
			Add-Attr $n "namespace" (XA $node "namespace")
			Add-Child $pkgNode $n
		}
		"include" { }
		"element"   { Add-Child $pkgNode (Build-Property $node $false) }
		"attribute" { Add-Child $pkgNode (Build-Property $node $true) }
		"simpleType" {
			$n = New-Node "valueType"
			Add-Attr $n "name" (XA $node "name")
			Fill-SimpleType $n $node
			Add-Child $pkgNode $n
		}
		"complexType" {
			$n = New-Node "objectType"
			Add-Attr $n "name" (XA $node "name")
			Fill-ComplexType $n $node
			Add-Child $pkgNode $n
		}
	}
}

# --- Serialize Package.bin ---

# Модель XDTO требует строгой последовательности элементов верхнего уровня:
# import → property → valueType → objectType. Порядок объявлений в XSD произвольный,
# поэтому пересортировываем — иначе платформа отвергает пакет с «Ошибка преобразования
# данных XDTO». Все 760 пакетов корпуса этому порядку удовлетворяют, так что
# round-trip не затрагивается.
$TOP_ORDER = @("import", "property", "valueType", "objectType")
$sortedChildren = New-Object System.Collections.ArrayList
foreach ($t in $TOP_ORDER) {
	foreach ($c in $pkgNode.Children) { if ($c.Tag -eq $t) { [void]$sortedChildren.Add($c) } }
}
foreach ($c in $pkgNode.Children) { if ($TOP_ORDER -notcontains $c.Tag) { [void]$sortedChildren.Add($c) } }
$pkgNode.Children.Clear()
foreach ($c in $sortedChildren) { [void]$pkgNode.Children.Add($c) }

$attrsRoot = Sort-Attrs $pkgNode
$rootAttrText = ""
foreach ($a in $attrsRoot) { $rootAttrText += " $($a.Name)=`"$(Esc $a.Value)`"" }
[void]$out.Append("<package xmlns=`"$XDTO_NS`" xmlns:xs=`"$XS_NS`" xmlns:xsi=`"$XSI_NS`"$rootAttrText>`r`n")
foreach ($c in $pkgNode.Children) { Serialize-Node $c 2 @{} }
[void]$out.Append("</package>")

$binText = $out.ToString()

# --- Resolve the package name ---

if (-not $Name) {
	if ($metaName) { $Name = $metaName } else { $Name = $defaultName }
}
# Санация под идентификатор 1С
$Name = ($Name -replace '[^\wЀ-ӿ]', '_')
if ($Name -match '^\d') { $Name = "_$Name" }

Assert-EditAllowed $OutputDir "editable"

$script:formatVersion = Detect-FormatVersion $OutputDir

# Объявления пространств имён — одной переменной: место эмиссии её только интерполирует.
# Правки шапки (как xmlns:pal в формате 2.21) делаются здесь, в одном месте.
$script:xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

# 2.21 (8.5) добавила в шапку пространство палитры — ради <Color> у значений перечисления.
# Вставляем НА МЕСТО (после lf, перед style): платформа держит объявления по алфавиту,
# дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$script:xmlnsDecl = $script:xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}

$pkgRoot = Join-Path $OutputDir "XDTOPackages"
$pkgDir  = Join-Path $pkgRoot $Name
$extDir  = Join-Path $pkgDir "Ext"
$mdFile  = Join-Path $pkgRoot "$Name.xml"
$binFile = Join-Path $extDir "Package.bin"

if ((Test-Path $binFile) -and -not $Force) {
	throw "Пакет уже существует: $binFile. Используйте -Force для перезаписи."
}
New-Item -ItemType Directory -Path $extDir -Force | Out-Null

$encBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($binFile, $binText, $encBom)

# --- Metadata object file ---

if (-not $Synonym -and $metaSynonym.Count -gt 0) {
	$synItems = $metaSynonym
} elseif ($Synonym -is [System.Collections.IDictionary]) {
	$synItems = @()
	foreach ($k in $Synonym.Keys) { $synItems += @{ Lang = [string]$k; Content = [string]$Synonym[$k] } }
} elseif ($Synonym) {
	$synItems = @(@{ Lang = "ru"; Content = [string]$Synonym })
} else {
	$synItems = @(@{ Lang = "ru"; Content = $Name })
}
if (-not $Comment -and $metaComment) { $Comment = $metaComment }

$uuid = [guid]::NewGuid().ToString()
$md = New-Object System.Text.StringBuilder
function M([string]$s) { [void]$md.Append($s); [void]$md.Append("`r`n") }
M '<?xml version="1.0" encoding="UTF-8"?>'
M ("<MetaDataObject $($script:xmlnsDecl) version=`"$script:formatVersion`">")
M "`t<XDTOPackage uuid=`"$uuid`">"
M "`t`t<Properties>"
M "`t`t`t<Name>$(EscText $Name)</Name>"
M "`t`t`t<Synonym>"
foreach ($s in $synItems) {
	M "`t`t`t`t<v8:item>"
	M "`t`t`t`t`t<v8:lang>$(EscText $s.Lang)</v8:lang>"
	M "`t`t`t`t`t<v8:content>$(EscText $s.Content)</v8:content>"
	M "`t`t`t`t</v8:item>"
}
M "`t`t`t</Synonym>"
if ($Comment) { M "`t`t`t<Comment>$(EscText $Comment)</Comment>" } else { M "`t`t`t<Comment/>" }
M "`t`t`t<Namespace>$(EscText $targetNs)</Namespace>"
M "`t`t</Properties>"
M "`t</XDTOPackage>"
[void]$md.Append("</MetaDataObject>")

[System.IO.File]::WriteAllText($mdFile, $md.ToString(), $encBom)

# --- Register in Configuration.xml ---

# Ранняя диагностика: отказ платформы при db-update дешевле поймать на сборке
$xdtoRootDir = Join-Path $OutputDir "XDTOPackages"
$declaredImports = @()
foreach ($c in $pkgNode.Children) { if ($c.Tag -eq "import") { foreach ($a in $c.Attrs) { if ($a.Name -eq "namespace") { $declaredImports += $a.Value } } } }
if ($declaredImports.Count -gt 0 -and (Test-Path $xdtoRootDir)) {
	$knownNs = @{}
	foreach ($other in (Get-ChildItem $xdtoRootDir -Directory -ErrorAction SilentlyContinue)) {
		$ob = Join-Path (Join-Path $other.FullName "Ext") "Package.bin"
		if (-not (Test-Path $ob)) { continue }
		try {
			$od = New-Object System.Xml.XmlDocument
			$od.Load($ob)
			$knownNs[$od.DocumentElement.GetAttribute("targetNamespace")] = $true
		} catch {}
	}
	foreach ($imp in $declaredImports) {
		if (-not $knownNs.ContainsKey($imp) -and $PLATFORM_NS -notcontains $imp) {
			Warn "Импорт `"$imp`" не разрешается: пакета с таким namespace в конфигурации нет. Платформа отвергнет пакет при обновлении — соберите зависимость первой"
		}
	}
}

function Esc-XmlText {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# Куда навык ставит новую запись в <ChildObjects> — настройка newObjectPosition.
# databases[].newObjectPosition базы, чей configSrc охватывает каталог родительского XML,
# иначе корневое поле, иначе end. Значения: end — после последнего объекта того же вида
# (так дописывает Конфигуратор); byName — по имени среди объектов того же вида.
# Файл ищем от рабочего каталога вверх, каталог конфигурации — запасной путь: так же
# его ищут support-guard и группа db-*, а скрипт навыка зовут по абсолютному пути, и cwd
# остаётся рабочим каталогом проекта.
# configSrc считается от каталога .v8-project.json, как задокументировано в
# docs/v8-project-guide.md. Реестр семьи: tests/skills/check-inline-drift.mjs.
function Get-NewObjectPosition([string]$cfgDir) {
	try {
		if (-not $cfgDir) { $cfgDir = "." }
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project ([System.IO.Path]::GetFullPath($cfgDir)) }
		if (-not $pj) { return "end" }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$projDir = [System.IO.Path]::GetDirectoryName($pj)
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc -and $db.newObjectPosition) {
					$src = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($projDir, $db.configSrc)).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ("$($db.newObjectPosition)" -eq "byName") { return "byName" }
						return "end"
					}
				}
			}
		}
		if ("$($proj.newObjectPosition)" -eq "byName") { return "byName" }
		return "end"
	} catch { return "end" }
}

# Виды, у которых порядок в дереве несёт смысл: автоматически их не упорядочиваем.
# CommonAttribute — исключение самого стандарта (#std467): у общих реквизитов-разделителей
# порядок в дереве задаёт порядок установки параметров сеанса. Subsystem и CommandGroup:
# пока они не перечислены в <SubsystemsOrder> / <GroupsOrder> файла Ext/CommandInterface.xml,
# порядок дерева задаёт порядок в интерфейсе, а платформа эти списки сама не заводит
# (в выгрузке ACC вне GroupsOrder 15 живых групп из 39). Language исключён из осторожности,
# без замера: языков обычно один-два, и в типовых их порядок не алфавитный.
# Явно названный вид сортируется в любом случае.
# Реестр семьи: tests/skills/check-inline-drift.mjs.
function Test-OrderSensitiveType([string]$typeName) {
	return @("CommonAttribute", "Subsystem", "CommandGroup", "Language") -ccontains $typeName
}

# Порядок имён объектов метаданных, как в дереве Конфигуратора.
# Ключ — пары «ранг+символ»: регистр не учитывается, подчёркивание раньше цифр, цифры раньше
# букв, буквы по кодам (латиница раньше кириллицы), ё на месте е. Культурные таблицы не
# используются — они разные на разных ОС и в разных рантаймах, а так оба порта сравнивают
# одинаково везде. Равные ключи разводит ordinal-сравнение исходных строк.
# Возвращает -1 | 0 | 1. Реестр семьи: tests/skills/check-inline-drift.mjs.
function Compare-MetadataNames([string]$a, [string]$b) {
	$keys = @("", "")
	$names = @($a, $b)
	for ($i = 0; $i -lt 2; $i++) {
		$sb = New-Object System.Text.StringBuilder
		foreach ($ch in $names[$i].ToLowerInvariant().ToCharArray()) {
			if ($ch -eq [char]0x0451) { $ch = [char]0x0435 }
			if ([char]::IsDigit($ch)) { [void]$sb.Append('1') }
			elseif ([char]::IsLetter($ch)) { [void]$sb.Append('2') }
			else { [void]$sb.Append('0') }
			[void]$sb.Append($ch)
		}
		$keys[$i] = $sb.ToString()
	}
	$r = [string]::CompareOrdinal($keys[0], $keys[1])
	if ($r -eq 0) { $r = [string]::CompareOrdinal($a, $b) }
	if ($r -lt 0) { return -1 }
	if ($r -gt 0) { return 1 }
	return 0
}

# Регистрация объекта в <ChildObjects> родительского XML. Общая реализация: эталон —
# meta-compile, копии — role-compile, xdto-compile. Реестр семьи: tests/skills/check-inline-drift.mjs.
# Возвращает исход: added | already | no-childobj | no-config.
# Канонический порядок видов в <ChildObjects> — эталон в docs/1c-configuration-spec.md,
# таблица «Порядок типов в ChildObjects». Нужен, чтобы новая группа вида вставала на своё
# место: иначе платформа переставит её при первой же выгрузке и даст диф на ровном месте.
# Реестр карт: tests/skills/check-type-maps.mjs.
$childObjectTypes = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","Bot","PaletteColor","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","IntegrationService"
)

function Register-InChildObjects([string]$ParentXmlPath, [string]$ParentTag, [string]$ChildTag, [string]$ChildName) {
	if (-not (Test-Path $ParentXmlPath)) { return "no-config" }

	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	$doc.Load($ParentXmlPath)

	$nsMgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	$childObjects = $doc.SelectSingleNode("//md:$ParentTag/md:ChildObjects", $nsMgr)
	if (-not $childObjects) { return "no-childobj" }

	$existing = $childObjects.SelectNodes("md:$ChildTag", $nsMgr)
	foreach ($e in $existing) {
		if ($e.InnerText -eq $ChildName) { return "already" }
	}

	# Правка по сырому тексту, зеркально py-порту: сериализация DOM переписала бы файл целиком
	# (регистр encoding, `<a />` вместо `<a/>`), а текстовая вставка хранит его байт-в-байт —
	# дельта ровно в одну строку. Правим чужой файл, значит наследуем его стиль (#44/#46/#47).
	# DOM выше — только на чтение: найти ChildObjects и отсечь дубликат.
	$configContent = [System.IO.File]::ReadAllText($ParentXmlPath, (New-Object System.Text.UTF8Encoding($false)))
	$eol = if ($configContent.Contains("`r`n")) { "`r`n" } else { "`n" }
	$entry = "<$ChildTag>$(Esc-XmlText $ChildName)</$ChildTag>"
	$enc = New-Object System.Text.UTF8Encoding($true)

	$block = [regex]::Match($configContent, '(?s)<ChildObjects\s*>.*?</ChildObjects>')
	if (-not $block.Success) {
		# Самозакрытый <ChildObjects/> раскрываем первой записью
		$empty = [regex]::Match($configContent, '<ChildObjects\s*/>')
		if (-not $empty.Success) { return "no-childobj" }
		$replacement = "<ChildObjects>$eol`t`t`t$entry$eol`t`t</ChildObjects>"
		$newContent = $configContent.Substring(0, $empty.Index) + $replacement + $configContent.Substring($empty.Index + $empty.Length)
		[System.IO.File]::WriteAllText($ParentXmlPath, $newContent, $enc)
		return "added"
	}

	# byName: перед первым объектом того же вида, чьё имя больше нового.
	# Виды с осмысленным порядком в дереве пропускаем — см. Test-OrderSensitiveType.
	if (-not (Test-OrderSensitiveType $ChildTag) -and (Get-NewObjectPosition ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ParentXmlPath)))) -eq "byName") {
		$lineRx = [regex]"(?m)^([ \t]*)<$ChildTag>([^<]*)</$ChildTag>"
		$m = $lineRx.Match($configContent, $block.Index, $block.Length)
		while ($m.Success) {
			if ((Compare-MetadataNames $m.Groups[2].Value $ChildName) -gt 0) {
				$newContent = $configContent.Substring(0, $m.Index) + $m.Groups[1].Value + $entry + $eol + $configContent.Substring($m.Index)
				[System.IO.File]::WriteAllText($ParentXmlPath, $newContent, $enc)
				return "added"
			}
			$m = $m.NextMatch()
		}
	}

	$closeSame = "</$ChildTag>"
	$blockEnd = $block.Index + $block.Length
	$lastSame = $configContent.LastIndexOf($closeSame, $blockEnd - 1, $block.Length, [System.StringComparison]::Ordinal)
	if ($lastSame -ge 0) {
		# После последнего объекта того же вида (группы по видам сохраняются)
		$insertAt = $lastSame + $closeSame.Length
		$newContent = $configContent.Substring(0, $insertAt) + "$eol`t`t`t$entry" + $configContent.Substring($insertAt)
	} else {
		# Группы своего вида ещё нет: ставим её в канонический порядок видов — перед первой
		# группой вида старше по $childObjectTypes. Дописать в конец блока нельзя: платформа
		# переставит группу при первой же выгрузке и даст диф на ровном месте.
		$ownIdx = $childObjectTypes.IndexOf($ChildTag)
		$anchor = $null
		if ($ownIdx -ge 0) {
			$typeRx = [regex]"(?m)^([ \t]*)<(\w+)>[^<]*</\2>"
			$tm = $typeRx.Match($configContent, $block.Index, $block.Length)
			while ($tm.Success) {
				$otherIdx = $childObjectTypes.IndexOf($tm.Groups[2].Value)
				if ($otherIdx -gt $ownIdx) { $anchor = $tm; break }
				$tm = $tm.NextMatch()
			}
		}
		if ($anchor) {
			$newContent = $configContent.Substring(0, $anchor.Index) + $anchor.Groups[1].Value + $entry + $eol + $configContent.Substring($anchor.Index)
		} else {
			# Видов старше в файле нет — новая строка перед </ChildObjects>,
			# отступ закрывающего тега переиспользуется
			$closeAt = $configContent.LastIndexOf("</ChildObjects>", $blockEnd - 1, $block.Length, [System.StringComparison]::Ordinal)
			$newContent = $configContent.Substring(0, $closeAt) + "`t$entry$eol`t`t" + $configContent.Substring($closeAt)
		}
	}
	[System.IO.File]::WriteAllText($ParentXmlPath, $newContent, $enc)
	return "added"
}

$configXmlPath = Join-Path $OutputDir "Configuration.xml"
$regResult = Register-InChildObjects $configXmlPath "Configuration" "XDTOPackage" $Name

# --- Report ---

$typeCount = 0
foreach ($c in $pkgNode.Children) { if ($c.Tag -eq "objectType" -or $c.Tag -eq "valueType") { $typeCount++ } }

Write-Host "✓ Пакет XDTO собран: $Name"
Write-Host "  Namespace: $targetNs"
Write-Host "  Типов: $typeCount"
Write-Host "  Файлы: XDTOPackages/$Name.xml, XDTOPackages/$Name/Ext/Package.bin"
if ($script:warnings.Count -gt 0) {
	Write-Host ""
	Write-Host "Предупреждения ($($script:warnings.Count)) — конструкции XSD без точного соответствия в модели XDTO:"
	foreach ($w in $script:warnings) { Write-Host "  ! $w" }
	Write-Host ""
}
switch ($regResult) {
	"added"     { Write-Host "  Configuration.xml: <XDTOPackage>$Name</XDTOPackage> добавлен в ChildObjects" }
	"already"   { Write-Host "  Configuration.xml: <XDTOPackage>$Name</XDTOPackage> уже зарегистрирован" }
	"no-childobj" { [Console]::Error.WriteLine("ПРЕДУПРЕЖДЕНИЕ: Configuration.xml найден, но <ChildObjects> не найден") }
	"no-config" { Write-Host "  Configuration.xml не найден — регистрация пропущена" }
}
