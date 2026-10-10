# xdto-decompile v1.3 — Convert 1C XDTO package to XML Schema (XSD)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory=$true)]
	[Alias('Path')]
	[string]$PackagePath,
	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$XDTO_NS = "http://v8.1c.ru/8.1/xdto"
$XS_NS   = "http://www.w3.org/2001/XMLSchema"
$XSI_NS  = "http://www.w3.org/2001/XMLSchema-instance"
$MD_NS   = "http://v8.1c.ru/8.3/MDClasses"
$V8_NS   = "http://v8.1c.ru/8.1/data/core"

# --- Resolve paths: accept package dir, Package.bin, or metadata .xml ---

function Resolve-PackagePaths([string]$p) {
	$binPath = $null
	$mdPath  = $null

	if (Test-Path $p -PathType Leaf) {
		if ([System.IO.Path]::GetFileName($p) -eq "Package.bin") {
			$binPath = $p
			# <Name>/Ext/Package.bin -> <Name>.xml
			$extDir = [System.IO.Path]::GetDirectoryName($p)
			$pkgDir = [System.IO.Path]::GetDirectoryName($extDir)
			$cand = "$pkgDir.xml"
			if (Test-Path $cand) { $mdPath = $cand }
		} elseif ($p.EndsWith(".xml")) {
			$mdPath = $p
			$pkgDir = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($p), [System.IO.Path]::GetFileNameWithoutExtension($p))
			$cand = Join-Path (Join-Path $pkgDir "Ext") "Package.bin"
			if (Test-Path $cand) { $binPath = $cand }
		}
	} elseif (Test-Path $p -PathType Container) {
		$cand = Join-Path (Join-Path $p "Ext") "Package.bin"
		if (Test-Path $cand) {
			$binPath = $cand
			$mdCand = "$($p.TrimEnd('\','/')).xml"
			if (Test-Path $mdCand) { $mdPath = $mdCand }
		}
	}

	if (-not $binPath) { throw "Не найден Ext/Package.bin для пути: $p" }
	return @{ Bin = $binPath; Md = $mdPath }
}

$paths = Resolve-PackagePaths $PackagePath

# --- Load package model ---

$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $false
$doc.Load($paths.Bin)
$pkg = $doc.DocumentElement
if ($pkg.get_LocalName() -ne "package") { throw "Ожидался корневой <package>, получен <$($pkg.get_LocalName())>" }

$targetNs = $pkg.GetAttribute("targetNamespace")

# --- Namespace -> prefix map for the emitted schema ---

$nsPrefix = @{}
$nsPrefix[$XS_NS] = "xs"
if ($targetNs) { $nsPrefix[$targetNs] = "tns" }

$imports = @()
foreach ($imp in $pkg.ChildNodes) {
	if ($imp.NodeType -ne [System.Xml.XmlNodeType]::Element -or $imp.get_LocalName() -ne "import") { continue }
	$ns = $imp.GetAttribute("namespace")
	$imports += $ns
	if (-not $nsPrefix.ContainsKey($ns)) { $nsPrefix[$ns] = "ns" + ($nsPrefix.Count) }
}

# Any foreign namespace referenced but not imported still needs a prefix
function Register-Ns([string]$ns) {
	if (-not $ns) { return }
	if (-not $nsPrefix.ContainsKey($ns)) { $nsPrefix[$ns] = "ns" + ($nsPrefix.Count) }
}

# --- Output buffer ---

$sb = New-Object System.Text.StringBuilder
function X([string]$line) { [void]$sb.Append($line); [void]$sb.Append("`r`n") }
function Esc([string]$s) {
	if ($null -eq $s) { return "" }
	return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}
function EscText([string]$s) {
	if ($null -eq $s) { return "" }
	return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

# --- QName conversion: bin prefix -> schema prefix ---

function Convert-QName([System.Xml.XmlElement]$el, [string]$qname) {
	if (-not $qname) { return $null }
	# Нотация Кларка {ns}local — так записаны почти все memberTypes
	if ($qname.StartsWith("{")) {
		$close = $qname.IndexOf("}")
		if ($close -gt 0) {
			$ns = $qname.Substring(1, $close - 1)
			$local = $qname.Substring($close + 1)
			if (-not $ns) { return $local }
			Register-Ns $ns
			return "$($nsPrefix[$ns]):$local"
		}
	}
	$parts = $qname.Split(":")
	if ($parts.Count -eq 2) {
		$ns = $el.GetNamespaceOfPrefix($parts[0])
		$local = $parts[1]
	} else {
		$ns = $el.GetNamespaceOfPrefix("")
		$local = $parts[0]
	}
	if (-not $ns) { return $qname }
	Register-Ns $ns
	return "$($nsPrefix[$ns]):$local"
}

function Convert-QNameList([System.Xml.XmlElement]$el, [string]$list) {
	if (-not $list) { return $null }
	$out = @()
	foreach ($q in ($list -split "\s+")) {
		if ($q) { $out += (Convert-QName $el $q) }
	}
	return ($out -join " ")
}

# --- Attribute helpers ---

function A([System.Xml.XmlElement]$el, [string]$name) {
	if ($el.HasAttribute($name)) { return $el.GetAttribute($name) }
	return $null
}

# Emits `key="value"` pairs, skipping nulls
function Attrs([object[]]$pairs) {
	$out = ""
	for ($i = 0; $i -lt $pairs.Count; $i += 2) {
		$v = $pairs[$i + 1]
		if ($null -ne $v) { $out += " $($pairs[$i])=`"$(Esc ([string]$v))`"" }
	}
	return $out
}

# --- xdto: mirror attributes ---
# Everything XSD cannot express literally rides as xdto:<same name as in Package.bin>.
# Mirrors are emitted only when the literal bin form is not recoverable from the XSD.

$usesXdtoNs = $false
function Mirror([string]$name, $value) {
	# $value НЕ типизируем: [string]$null коэрсится в "" и зеркало ложно появляется
	if ($null -eq $value) { return "" }
	$script:usesXdtoNs = $true
	return " xdto:$name=`"$(Esc ([string]$value))`""
}

# Обычно префиксы генерируются схемой dNpM, но изредка узел несёт осмысленный
# префикс (например dcsset) — его надо сохранить, иначе round-trip не сойдётся.
function Mirror-Prefix([System.Xml.XmlElement]$el) {
	foreach ($a in $el.Attributes) {
		if ($a.Prefix -ne "xmlns") { continue }
		if ($a.get_LocalName() -match '^d\d+p\d+$') { continue }
		return (Mirror "prefix" $a.get_LocalName())
	}
	return ""
}

# --- Facet emission (simple types) ---

$FACET_ATTRS = @("length", "minLength", "maxLength", "totalDigits", "fractionDigits",
                 "minInclusive", "maxInclusive", "minExclusive", "maxExclusive", "whiteSpace")

function Emit-Facets([System.Xml.XmlElement]$el, [string]$indent) {
	foreach ($f in $FACET_ATTRS) {
		$v = A $el $f
		if ($null -ne $v) { X "$indent<xs:$f value=`"$(Esc $v)`"/>" }
	}
	foreach ($child in $el.ChildNodes) {
		if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($child.get_LocalName() -eq "pattern") {
			X "$indent<xs:pattern value=`"$(Esc $child.InnerText)`"/>"
		} elseif ($child.get_LocalName() -eq "enumeration") {
			# xsi:type on enumeration has no XSD counterpart — mirror it
			$xsiType = $child.GetAttribute("type", $XSI_NS)
			$m = ""
			if ($xsiType) { $m = Mirror "type" (Convert-QName $child $xsiType) }
			X "$indent<xs:enumeration value=`"$(Esc $child.InnerText)`"$m/>"
		}
	}
}

function Has-SimpleContent([System.Xml.XmlElement]$el) {
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "pattern") { return $true }
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "enumeration") { return $true }
	}
	foreach ($f in $FACET_ATTRS) { if ($null -ne (A $el $f)) { return $true } }
	return $false
}

# --- Simple type body (valueType / typeDef xsi:type=ValueType) ---

function Emit-SimpleTypeBody([System.Xml.XmlElement]$el, [string]$indent) {
	$variety    = A $el "variety"
	$base       = Convert-QName $el (A $el "base")
	$itemType   = Convert-QName $el (A $el "itemType")
	$memberTypes= Convert-QNameList $el (A $el "memberTypes")

	# variety is mirrored: "Atomic" is written explicitly for only part of the corpus
	$mv = Mirror "variety" $variety

	# memberTypes почти всегда записаны нотацией Кларка; редкую префиксную форму зеркалим
	$rawMembers = A $el "memberTypes"
	if ($null -ne $rawMembers -and -not $rawMembers.StartsWith("{")) {
		$mv += Mirror "memberTypesForm" "prefixed"
	}
	# При нотации Кларка объявление xmlns:dNpM иногда присутствует, иногда нет —
	# из значения это не выводится (зависит от состояния сериализатора), зеркалим факт
	if ($null -ne $rawMembers -and $rawMembers.StartsWith("{")) {
		foreach ($a in $el.Attributes) {
			if ($a.Prefix -eq "xmlns" -and $a.get_LocalName() -match '^d\d+p\d+$') {
				$mv += Mirror "declareNs" $a.Value
				break
			}
		}
	}

	if ($variety -eq "List" -or $itemType) {
		X "$indent<xs:list$(Attrs @('itemType', $itemType))$mv/>"
		return
	}
	if ($variety -eq "Union" -or $memberTypes) {
		$anon = @()
		foreach ($c in $el.ChildNodes) {
			if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $anon += $c }
		}
		if ($anon.Count -eq 0) {
			X "$indent<xs:union$(Attrs @('memberTypes', $memberTypes))$mv/>"
		} else {
			X "$indent<xs:union$(Attrs @('memberTypes', $memberTypes))$mv>"
			foreach ($c in $anon) {
				X "$indent`t<xs:simpleType>"
				Emit-SimpleTypeBody $c "$indent`t`t"
				X "$indent`t</xs:simpleType>"
			}
			X "$indent</xs:union>"
		}
		return
	}

	# Базовый тип может быть задан не атрибутом base, а вложенным анонимным typeDef
	$anonBase = $null
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $anonBase = $c; break }
	}

	if ((Has-SimpleContent $el) -or $anonBase) {
		X "$indent<xs:restriction$(Attrs @('base', $base))$mv>"
		if ($anonBase) {
			X "$indent`t<xs:simpleType>"
			Emit-SimpleTypeBody $anonBase "$indent`t`t"
			X "$indent`t</xs:simpleType>"
		}
		Emit-Facets $el "$indent`t"
		X "$indent</xs:restriction>"
	} else {
		X "$indent<xs:restriction$(Attrs @('base', $base))$mv/>"
	}
}

# --- Property classification ---

function Get-PropForm([System.Xml.XmlElement]$p) {
	$f = A $p "form"
	if ($null -eq $f) { return "Element" }
	return $f
}

function Get-AnonTypeDef([System.Xml.XmlElement]$p) {
	foreach ($c in $p.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { return $c }
	}
	return $null
}

# --- Property emission ---

function Emit-Property([System.Xml.XmlElement]$p, [string]$indent, [bool]$isGlobal) {
	$form  = Get-PropForm $p
	$name  = A $p "name"
	$type  = Convert-QName $p (A $p "type")
	$ref   = Convert-QName $p (A $p "ref")
	$local = A $p "localName"
	$lower = A $p "lowerBound"
	$upper = A $p "upperBound"
	$nill  = A $p "nillable"
	$def   = A $p "default"
	$fix   = A $p "fixed"
	# В модели fixed — булев флаг, значение лежит в default; в XSD наоборот:
	# fixed="V" несёт само значение. Переводим, а не копируем.
	$defOut = $def
	$fixOut = $null
	$fixMirror = ""
	if ($fix -eq "true" -and $null -ne $def) { $fixOut = $def; $defOut = $null }
	elseif ($null -ne $fix) { $fixMirror = Mirror "fixed" $fix }
	$anon  = Get-AnonTypeDef $p
	# qualified записан как атрибут в пространстве имён XDTO
	$qual  = $p.GetAttribute("qualified", $XDTO_NS)
	if ($qual -eq "") { $qual = $null }

	# lowerBound/upperBound map 1:1 onto minOccurs/maxOccurs, including "written explicitly"
	$minOccurs = $lower
	$maxOccurs = $null
	if ($null -ne $upper) { $maxOccurs = if ($upper -eq "-1") { "unbounded" } else { $upper } }

	# localName carries the original XML name when it is not a valid 1C identifier
	$xmlName = if ($null -ne $local) { $local } else { $name }
	$mirrorName = if ($null -ne $local) { Mirror "name" $name } else { "" }

	$m = ""
	$isAttr = ($form -eq "Attribute")

	if ($isAttr) {
		# XSD forbids nillable on attributes, and has no minOccurs/maxOccurs
		if ($null -ne $qual)  { $m += Mirror "qualified" $qual }
		if ($null -ne $nill)  { $m += Mirror "nillable" $nill }
		if ($null -ne $lower) { $m += Mirror "lowerBound" $lower }
		if ($null -ne $upper) { $m += Mirror "upperBound" $upper }
		$m += $mirrorName
		$m += $fixMirror
		$body = Attrs @('name', $xmlName, 'ref', $ref, 'type', $type, 'default', $defOut, 'fixed', $fixOut)
		if ($anon) {
			X "$indent<xs:attribute$body$m>"
			X "$indent`t<xs:simpleType>"
			Emit-SimpleTypeBody $anon "$indent`t`t"
			X "$indent`t</xs:simpleType>"
			X "$indent</xs:attribute>"
		} else {
			X "$indent<xs:attribute$body$m/>"
		}
		return
	}

	if ($form -eq "Text") {
		# handled by the owning complexType (xs:simpleContent)
		return
	}

	# form="Element" written explicitly is indistinguishable in XSD from the default
	if ($null -ne (A $p "form")) { $m += Mirror "form" $form }
	if ($null -ne $qual) { $m += Mirror "qualified" $qual }
	$m += $mirrorName
	$m += (Mirror-Prefix $p)
	$m += $fixMirror

	$body = Attrs @('name', $xmlName, 'ref', $ref, 'type', $type,
	                'minOccurs', $minOccurs, 'maxOccurs', $maxOccurs,
	                'nillable', $nill, 'default', $defOut, 'fixed', $fixOut)

	if ($anon) {
		X "$indent<xs:element$body$m>"
		if ($anon.GetAttribute("type", $XSI_NS) -eq "ObjectType") {
			$anonBase = Convert-QName $anon (A $anon "base")
			if ($anonBase) {
				X "$indent`t<xs:complexType$(ComplexTypeAttrs $anon)>"
				X "$indent`t`t<xs:complexContent>"
				X "$indent`t`t`t<xs:extension$(Attrs @('base', $anonBase))>"
				Emit-ComplexTypeBody $anon "$indent`t`t`t`t"
				X "$indent`t`t`t</xs:extension>"
				X "$indent`t`t</xs:complexContent>"
				X "$indent`t</xs:complexType>"
			} else {
				X "$indent`t<xs:complexType$(ComplexTypeAttrs $anon)>"
				Emit-ComplexTypeBody $anon "$indent`t`t"
				X "$indent`t</xs:complexType>"
			}
		} else {
			X "$indent`t<xs:simpleType>"
			Emit-SimpleTypeBody $anon "$indent`t`t"
			X "$indent`t</xs:simpleType>"
		}
		X "$indent</xs:element>"
	} else {
		X "$indent<xs:element$body$m/>"
	}
}

# --- Complex type body (objectType / typeDef xsi:type=ObjectType) ---

function Emit-ComplexTypeBody([System.Xml.XmlElement]$el, [string]$indent) {
	$open      = A $el "open"
	$ordered   = A $el "ordered"
	$sequenced = A $el "sequenced"

	$props = @()
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "property") { $props += $c }
	}

	$elems = @(); $attrs = @(); $text = $null
	foreach ($p in $props) {
		switch (Get-PropForm $p) {
			"Attribute" { $attrs += $p }
			"Text"      { $text = $p }
			default     { $elems += $p }
		}
	}

	# simpleContent: a "Text" property holds the element's own value
	if ($null -ne $text) {
		$tType = Convert-QName $text (A $text "type")
		$tm = ""
		$tName = A $text "name"
		if ($tName -ne "__content") { $tm += Mirror "textName" $tName }
		foreach ($extra in @("lowerBound", "upperBound", "nillable")) {
			$v = A $text $extra
			if ($null -ne $v) { $tm += Mirror "text$extra" $v }
		}
		X "$indent<xs:simpleContent>"
		X "$indent`t<xs:extension$(Attrs @('base', $tType))$tm>"
		foreach ($a in $attrs) { Emit-Property $a "$indent`t`t" $false }
		X "$indent`t</xs:extension>"
		X "$indent</xs:simpleContent>"
		return
	}

	$particleTag = if ($ordered -eq "false") { "xs:choice" } else { "xs:sequence" }
	$needParticle = ($elems.Count -gt 0) -or ($open -eq "true")

	if ($needParticle) {
		X "$indent<$particleTag>"
		foreach ($e in $elems) { Emit-Property $e "$indent`t" $false }
		if ($open -eq "true") {
			X "$indent`t<xs:any namespace=`"##any`" processContents=`"lax`" minOccurs=`"0`" maxOccurs=`"unbounded`"/>"
		}
		X "$indent</$particleTag>"
	}

	foreach ($a in $attrs) { Emit-Property $a "$indent" $false }
	if ($open -eq "true") {
		X "$indent<xs:anyAttribute namespace=`"##any`" processContents=`"lax`"/>"
	}
}

# Attributes of a complexType tag itself (mirrors + XSD-native abstract/mixed)
function ComplexTypeAttrs([System.Xml.XmlElement]$el) {
	$open      = A $el "open"
	$ordered   = A $el "ordered"
	$sequenced = A $el "sequenced"
	$abstract  = A $el "abstract"
	$mixed     = A $el "mixed"

	$out = ""
	if ($abstract -eq "true") { $out += " abstract=`"true`"" } elseif ($null -ne $abstract) { $out += Mirror "abstract" $abstract }
	if ($mixed -eq "true")    { $out += " mixed=`"true`"" }    elseif ($null -ne $mixed)    { $out += Mirror "mixed" $mixed }

	# XSD требует объявлять атрибуты после частицы, поэтому исходный порядок свойств
	# восстановим как «сначала form=Attribute, потом остальные» — это верно для 96.5%
	# типов корпуса. Расхождения (768 типов) зеркалим списком имён.
	$order = @(); $kinds = @()
	foreach ($c in $el.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.get_LocalName() -ne "property") { continue }
		$nm = A $c "name"
		if ($null -eq $nm) { $nm = "@" + ((A $c "ref") -split ":")[-1] }
		$order += $nm
		$kinds += $(if ((Get-PropForm $c) -eq "Attribute") { 0 } else { 1 })
	}
	if ($order.Count -gt 1) {
		$natural = $true
		for ($i = 1; $i -lt $kinds.Count; $i++) { if ($kinds[$i] -lt $kinds[$i - 1]) { $natural = $false; break } }
		if (-not $natural) { $out += Mirror "order" ($order -join "|") }
	}

	# open="true" is rendered as xs:any + xs:anyAttribute; anything else is mirrored
	if ($null -ne $open -and $open -ne "true") { $out += Mirror "open" $open }
	# ordered="false" is rendered as xs:choice; "true" written explicitly is mirrored
	if ($null -ne $ordered -and $ordered -ne "false") { $out += Mirror "ordered" $ordered }
	# sequenced has no XSD counterpart at all
	if ($null -ne $sequenced) { $out += Mirror "sequenced" $sequenced }

	return $out
}

# --- Metadata properties (Name/Synonym/Comment) from the object's .xml ---

function Get-MetadataBlock() {
	if (-not $paths.Md -or -not (Test-Path $paths.Md)) { return $null }
	$md = New-Object System.Xml.XmlDocument
	$md.Load($paths.Md)
	$nsm = New-Object System.Xml.XmlNamespaceManager($md.NameTable)
	$nsm.AddNamespace("md", $MD_NS)
	$nsm.AddNamespace("v8", $V8_NS)
	$props = $md.SelectSingleNode("//md:XDTOPackage/md:Properties", $nsm)
	if (-not $props) { return $null }

	$res = @{ Name = $null; Comment = $null; Synonym = @() }
	$n = $props.SelectSingleNode("md:Name", $nsm); if ($n) { $res.Name = $n.InnerText }
	$c = $props.SelectSingleNode("md:Comment", $nsm); if ($c) { $res.Comment = $c.InnerText }
	foreach ($item in $props.SelectNodes("md:Synonym/v8:item", $nsm)) {
		$lang = $item.SelectSingleNode("v8:lang", $nsm)
		$cont = $item.SelectSingleNode("v8:content", $nsm)
		$res.Synonym += @{ Lang = $(if ($lang) { $lang.InnerText } else { "" }); Content = $(if ($cont) { $cont.InnerText } else { "" }) }
	}
	return $res
}

$meta = Get-MetadataBlock

# --- Emit ---
# Body first: emitting it registers every namespace actually referenced, so the
# schema element can declare a complete prefix map.

$bodyBuilder = New-Object System.Text.StringBuilder
$mainBuilder = $sb
$sb = $bodyBuilder

foreach ($node in $pkg.ChildNodes) {
	if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
	switch ($node.get_LocalName()) {
		"import" {
			X "`t<xs:import namespace=`"$(Esc $node.GetAttribute('namespace'))`"/>"
		}
		"property" {
			Emit-Property $node "`t" $true
		}
		"valueType" {
			$name = A $node "name"
			X "`t<xs:simpleType$(Attrs @('name', $name))>"
			Emit-SimpleTypeBody $node "`t`t"
			X "`t</xs:simpleType>"
		}
		"objectType" {
			$name = A $node "name"
			$base = Convert-QName $node (A $node "base")
			$cta  = ComplexTypeAttrs $node
			if ($base) {
				X "`t<xs:complexType$(Attrs @('name', $name))$cta>"
				X "`t`t<xs:complexContent>"
				X "`t`t`t<xs:extension$(Attrs @('base', $base))>"
				Emit-ComplexTypeBody $node "`t`t`t`t"
				X "`t`t`t</xs:extension>"
				X "`t`t</xs:complexContent>"
				X "`t</xs:complexType>"
			} else {
				$hasBody = $false
				foreach ($c in $node.ChildNodes) { if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) { $hasBody = $true; break } }
				if (-not $hasBody -and (A $node "open") -ne "true") {
					X "`t<xs:complexType$(Attrs @('name', $name))$cta/>"
				} else {
					X "`t<xs:complexType$(Attrs @('name', $name))$cta>"
					Emit-ComplexTypeBody $node "`t`t"
					X "`t</xs:complexType>"
				}
			}
		}
	}
}

$sb = $mainBuilder

# --- Schema element ---

$nsDecls = ""
foreach ($kv in ($nsPrefix.GetEnumerator() | Sort-Object { $_.Value })) {
	$nsDecls += " xmlns:$($kv.Value)=`"$(Esc $kv.Key)`""
}
if ($usesXdtoNs) { $nsDecls += " xmlns:xdto=`"$XDTO_NS`"" }

$schemaAttrs = ""
$efq = A $pkg "elementFormQualified"
$afq = A $pkg "attributeFormQualified"
if ($null -ne $efq) { $schemaAttrs += " elementFormDefault=`"$(if ($efq -eq 'true') { 'qualified' } else { 'unqualified' })`"" }
if ($null -ne $afq) { $schemaAttrs += " attributeFormDefault=`"$(if ($afq -eq 'true') { 'qualified' } else { 'unqualified' })`"" }

X "<xs:schema$nsDecls$(Attrs @('targetNamespace', $targetNs))$schemaAttrs>"

if ($meta) {
	X "`t<xs:annotation>"
	X "`t`t<xs:appinfo>"
	X "`t`t`t<xdto:package xmlns:xdto=`"$XDTO_NS`">"
	if ($null -ne $meta.Name)    { X "`t`t`t`t<xdto:name>$(EscText $meta.Name)</xdto:name>" }
	if ($null -ne $meta.Comment -and $meta.Comment -ne "") { X "`t`t`t`t<xdto:comment>$(EscText $meta.Comment)</xdto:comment>" }
	foreach ($s in $meta.Synonym) {
		X "`t`t`t`t<xdto:synonym lang=`"$(Esc $s.Lang)`">$(EscText $s.Content)</xdto:synonym>"
	}
	X "`t`t`t</xdto:package>"
	X "`t`t</xs:appinfo>"
	X "`t</xs:annotation>"
}

[void]$sb.Append($bodyBuilder.ToString())
X "</xs:schema>"

# --- Output (UTF-8 with BOM, CRLF — matches the Designer's own XSD export) ---

$text = $sb.ToString()
if ($OutFile) {
	$dir = [System.IO.Path]::GetDirectoryName($OutFile)
	if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
	$enc = New-Object System.Text.UTF8Encoding($true)
	[System.IO.File]::WriteAllText($OutFile, $text, $enc)
	Write-Host "✓ XSD записана: $OutFile"
	Write-Host "  targetNamespace: $targetNs"
} else {
	[Console]::Out.Write($text)
}
