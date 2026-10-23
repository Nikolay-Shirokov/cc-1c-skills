# xdto-validate v1.5 — Validate a 1C XDTO package
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)]
	[Alias('Path')]
	[string]$PackagePath,

	[string]$ConfigDir,

	[switch]$Detailed,

	[int]$MaxErrors = 20,

	[string]$OutFile
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

$XS_NS  = "http://www.w3.org/2001/XMLSchema"
$XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
$MD_NS  = "http://v8.1c.ru/8.3/MDClasses"

# --- Reporting ---

$script:errors = 0
$script:warnings = 0
$script:okCount = 0
$script:stopped = $false
$script:output = New-Object System.Text.StringBuilder

function Out-Line([string]$s) { [void]$script:output.AppendLine($s) }
function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Out-Line "[OK]    $msg" }
}
function Report-Error {
	param([string]$msg)
	$script:errors++
	Out-Line "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}
function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Out-Line "[WARN]  $msg"
}

# --- Resolve paths ---

if (-not [System.IO.Path]::IsPathRooted($PackagePath)) {
	$PackagePath = Join-Path (Get-Location).Path $PackagePath
}

$binPath = $null
$mdPath = $null
if (Test-Path $PackagePath -PathType Leaf) {
	if ([System.IO.Path]::GetFileName($PackagePath) -eq "Package.bin") {
		$binPath = $PackagePath
		$pkgDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($PackagePath))
		if (Test-Path "$pkgDir.xml") { $mdPath = "$pkgDir.xml" }
	} elseif ($PackagePath.EndsWith(".xml")) {
		$mdPath = $PackagePath
		$stem = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PackagePath), [System.IO.Path]::GetFileNameWithoutExtension($PackagePath))
		$c = Join-Path (Join-Path $stem "Ext") "Package.bin"
		if (Test-Path $c) { $binPath = $c }
	}
} elseif (Test-Path $PackagePath -PathType Container) {
	$c = Join-Path (Join-Path $PackagePath "Ext") "Package.bin"
	if (Test-Path $c) {
		$binPath = $c
		$m = "$($PackagePath.TrimEnd('\','/')).xml"
		if (Test-Path $m) { $mdPath = $m }
	}
}

$fileName = if ($binPath) { [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($binPath))) } else { $PackagePath }

if (-not $binPath) {
	Write-Host "[ERROR] Ext/Package.bin not found for path: $PackagePath"
	exit 1
}

# Каталог конфигурации — для проверок регистрации и зависимостей
if (-not $ConfigDir) {
	$d = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($binPath)))
	# .../XDTOPackages/<Имя>/Ext/Package.bin -> .../XDTOPackages -> корень
	$ConfigDir = [System.IO.Path]::GetDirectoryName($d)
}

$finalize = {
	$checks = $script:okCount + $script:errors + $script:warnings
	if ($script:errors -eq 0 -and $script:warnings -eq 0 -and -not $Detailed) {
		$result = "=== Validation OK: $fileName ($checks checks) ==="
	} else {
		Out-Line ""
		Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ($checks checks) ==="
		$result = $script:output.ToString()
	}
	Write-Host $result
	if ($OutFile) {
		$utf8Bom = New-Object System.Text.UTF8Encoding $true
		[System.IO.File]::WriteAllText($OutFile, $script:output.ToString(), $utf8Bom)
	}
}

# --- 1. Well-formedness ---

$doc = New-Object System.Xml.XmlDocument
try {
	$doc.Load($binPath)
} catch {
	Report-Error "Package.bin is not well-formed XML: $($_.Exception.Message)"
	& $finalize
	exit 1
}
$pkg = $doc.DocumentElement
if ($pkg.get_LocalName() -ne "package") {
	Report-Error "Expected root <package>, found <$($pkg.get_LocalName())>"
	& $finalize
	exit 1
}
Report-OK "Package.bin: well-formed XML, root <package>"

$targetNs = $pkg.GetAttribute("targetNamespace")
if (-not $targetNs) {
	Report-Error "<package> has no targetNamespace"
} else {
	Report-OK "targetNamespace: $targetNs"
}

# --- 2. Encoding / EOL ---

$bytes = [System.IO.File]::ReadAllBytes($binPath)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
	Report-Warn "Package.bin has no UTF-8 BOM — the platform writes the file with a BOM"
} else {
	Report-OK "Encoding: UTF-8 with BOM"
}

# --- 3. Collect declarations ---

$imports = New-Object System.Collections.ArrayList
$localTypes = New-Object System.Collections.Generic.HashSet[string]
$objectTypeNames = New-Object System.Collections.Generic.HashSet[string]
$valueTypeNames = New-Object System.Collections.Generic.HashSet[string]
$globalProps = New-Object System.Collections.Generic.HashSet[string]
$topSequence = New-Object System.Collections.ArrayList

foreach ($n in $pkg.ChildNodes) {
	if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
	[void]$topSequence.Add($n.get_LocalName())
	switch ($n.get_LocalName()) {
		"import"     { [void]$imports.Add($n.GetAttribute("namespace")) }
		"objectType" { [void]$localTypes.Add($n.GetAttribute("name")); [void]$objectTypeNames.Add($n.GetAttribute("name")) }
		"valueType"  { [void]$localTypes.Add($n.GetAttribute("name")); [void]$valueTypeNames.Add($n.GetAttribute("name")) }
		"property"   { if ($n.HasAttribute("name")) { [void]$globalProps.Add($n.GetAttribute("name")) } }
	}
}

# --- Порядок элементов верхнего уровня ---
# Модель требует import -> property -> valueType -> objectType. Нарушение платформа
# не прощает: db-update падает с «Ошибка преобразования данных XDTO».
$TOP_ORDER = @("import", "property", "valueType", "objectType")
$prevRank = -1
$orderOk = $true
foreach ($t in $topSequence) {
	$rank = [array]::IndexOf($TOP_ORDER, $t)
	if ($rank -lt 0) { continue }
	if ($rank -lt $prevRank) {
		Report-Error "Top-level element order violated: <$t> after <$($TOP_ORDER[$prevRank])>. The model requires import -> property -> valueType -> objectType; the platform rejects the package on configuration update"
		$orderOk = $false
		break
	}
	$prevRank = $rank
}
if ($orderOk) { Report-OK "Top-level element order is correct" }

# --- 4. Duplicate type names ---

$seen = @{}
foreach ($n in $pkg.ChildNodes) {
	if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
	if ($n.get_LocalName() -ne "objectType" -and $n.get_LocalName() -ne "valueType") { continue }
	$nm = $n.GetAttribute("name")
	if (-not $nm) { Report-Error "<$($n.get_LocalName())> has no name attribute"; continue }
	if ($seen.ContainsKey($nm)) {
		Report-Error "Duplicate type name: $nm"
	} else {
		$seen[$nm] = $true
	}
}
if ($localTypes.Count -gt 0) { Report-OK "$($localTypes.Count) type(s), names are unique" }

# --- 5. Type references resolve ---

$usedNamespaces = New-Object System.Collections.Generic.HashSet[string]
$anyTypeProps = New-Object System.Collections.ArrayList
$refAttrs = @("type", "base", "ref", "itemType")

function Resolve-Ref([System.Xml.XmlElement]$el, [string]$attr, [string]$raw) {
	if (-not $raw) { return }
	# Нотация Кларка {ns}local
	if ($raw.StartsWith("{")) {
		$close = $raw.IndexOf("}")
		if ($close -lt 0) { Report-Error "Invalid Clark notation in $attr=`"$raw`""; return }
		$ns = $raw.Substring(1, $close - 1)
		$local = $raw.Substring($close + 1)
	} else {
		$parts = $raw.Split(":")
		if ($parts.Count -eq 2) {
			$ns = $el.GetNamespaceOfPrefix($parts[0])
			$local = $parts[1]
			if (-not $ns) {
				Report-Error "Prefix `"$($parts[0])`" is not declared: $attr=`"$raw`" (element $($el.get_LocalName()))"
				return
			}
		} else {
			$ns = $null
			$local = $parts[0]
		}
	}

	if ($ns -eq $XS_NS -or $ns -eq $XSI_NS) {
		if ($local -eq "anyType") { [void]$anyTypeProps.Add($el) }
		return
	}
	if ($ns -eq $targetNs) {
		if ($attr -eq "ref") {
			if (-not $globalProps.Contains($local)) {
				Report-Error "ref=`"$raw`" does not resolve: the package has no global property `"$local`""
			}
		} elseif (-not $localTypes.Contains($local)) {
			Report-Error "$attr=`"$raw`" does not resolve: the package has no type `"$local`""
		}
		return
	}
	if ($ns) {
		[void]$usedNamespaces.Add($ns)
		if (-not $imports.Contains($ns)) {
			Report-Error "$attr=`"$raw`" refers to `"$ns`", but <import namespace=`"$ns`"/> is not declared"
		}
	}
}

$nodeCount = 0
foreach ($el in $pkg.SelectNodes("//*")) {
	if ($el.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
	$nodeCount++
	foreach ($a in $refAttrs) {
		if ($el.HasAttribute($a)) { Resolve-Ref $el $a $el.GetAttribute($a) }
	}
	if ($el.HasAttribute("memberTypes")) {
		foreach ($m in ($el.GetAttribute("memberTypes") -split "\s+")) {
			if ($m) { Resolve-Ref $el "memberTypes" $m }
		}
	}
	if ($script:stopped) { break }
}
if (-not $script:stopped) { Report-OK "$nodeCount nodes: type references resolve" }

if ($script:stopped) { & $finalize; exit 1 }

# --- 6. Silent degradation to xs:anyType ---
# Платформа при импорте XML-схемы молча подменяет неразрешённый чужой тип на anyType.

if ($anyTypeProps.Count -gt 0 -and $imports.Count -gt 0) {
	$names = @()
	foreach ($p in $anyTypeProps) { if ($p.HasAttribute("name")) { $names += $p.GetAttribute("name") } }
	$shown = ($names | Select-Object -First 5) -join ", "
	Report-Warn "Properties with type=`"xs:anyType`": $($anyTypeProps.Count) despite declared imports ($shown). The type is unresolved — such a property cannot be filled structurally. Usually a trace of an XML Schema import: the platform silently replaces an unresolved foreign type with anyType"
}

# --- 7. Unused imports ---

# Сам по себе неиспользуемый импорт безвреден и встречается в четверти пакетов
# типовых конфигураций. Сигналом он становится только вместе с anyType — тогда это
# почти наверняка неразрешённая зависимость.
$unused = @()
foreach ($imp in $imports) { if (-not $usedNamespaces.Contains($imp)) { $unused += $imp } }
if ($unused.Count -gt 0 -and $anyTypeProps.Count -gt 0) {
	Report-Warn "Import(s) with no type used: $($unused -join ', ') — together with anyType this indicates an unresolved dependency"
}
if ($imports.Count -gt 0 -and $unused.Count -eq 0) { Report-OK "$($imports.Count) import(s) — all used" }

# --- 8. nillable on attribute-form properties ---

$nillAttrs = @()
foreach ($p in $pkg.SelectNodes("//*[local-name()='property']")) {
	if ($p.GetAttribute("form") -eq "Attribute" -and $p.GetAttribute("nillable") -eq "true") {
		$nillAttrs += $p.GetAttribute("name")
	}
}
if ($nillAttrs.Count -gt 0) {
	Report-Warn "Properties with nillable=`"true`" and form=`"Attribute`": $($nillAttrs.Count) ($(($nillAttrs | Select-Object -First 5) -join ', ')). The XSD specification does not allow nillable on attributes — XML Schema export in Designer will lose them"
}

# --- 9. Facet consistency ---

$FACET_NUM = @("totalDigits", "fractionDigits")
$facetChecked = 0
foreach ($t in $pkg.SelectNodes("//*[local-name()='valueType' or local-name()='typeDef']")) {
	if ($t.get_LocalName() -eq "typeDef" -and $t.GetAttribute("type", $XSI_NS) -eq "ObjectType") { continue }
	$facetChecked++
	$nm = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(anonymous type)" }

	$len = $t.GetAttribute("length")
	if ($len -and ($t.HasAttribute("minLength") -or $t.HasAttribute("maxLength"))) {
		# Спецификация XSD это запрещает, но платформа такие типы хранит — предупреждение, не ошибка
		Report-Warn "$nm : length is set together with minLength/maxLength — the XSD specification treats them as mutually exclusive"
	}
	$minL = $t.GetAttribute("minLength"); $maxL = $t.GetAttribute("maxLength")
	if ($minL -and $maxL -and ([int]$minL -gt [int]$maxL)) {
		Report-Error "$nm : minLength ($minL) is greater than maxLength ($maxL)"
	}
	$td = $t.GetAttribute("totalDigits"); $fd = $t.GetAttribute("fractionDigits")
	if ($td -and $fd -and ([int]$fd -gt [int]$td)) {
		Report-Error "$nm : fractionDigits ($fd) is greater than totalDigits ($td)"
	}
	$ws = $t.GetAttribute("whiteSpace")
	if ($ws -and @("preserve", "replace", "collapse") -notcontains $ws) {
		Report-Error "$nm : invalid whiteSpace=`"$ws`""
	}
	$var = $t.GetAttribute("variety")
	if ($var -and @("Atomic", "List", "Union") -notcontains $var) {
		Report-Error "$nm : invalid variety=`"$var`""
	}
	if ($var -eq "List" -and -not $t.HasAttribute("itemType")) {
		Report-Warn "$nm : variety=`"List`" without itemType"
	}
	if ($script:stopped) { break }
}
if ($facetChecked -gt 0 -and -not $script:stopped) { Report-OK "$facetChecked simple type(s): facets are consistent" }

if ($script:stopped) { & $finalize; exit 1 }

# --- 10. property form / bounds ---

foreach ($p in $pkg.SelectNodes("//*[local-name()='property']")) {
	$form = $p.GetAttribute("form")
	if ($form -and @("Element", "Attribute", "Text") -notcontains $form) {
		Report-Error "Property `"$($p.GetAttribute('name'))`": invalid form=`"$form`""
	}
	$ub = $p.GetAttribute("upperBound")
	if ($ub -and $ub -ne "-1" -and ([int]$ub -lt 1)) {
		Report-Error "Property `"$($p.GetAttribute('name'))`": upperBound=`"$ub`" (allowed: -1 or a number ≥ 1)"
	}
	$lb = $p.GetAttribute("lowerBound")
	if ($lb -and $ub -and $ub -ne "-1" -and ([int]$lb -gt [int]$ub)) {
		Report-Error "Property `"$($p.GetAttribute('name'))`": lowerBound ($lb) is greater than upperBound ($ub)"
	}
	if (-not $p.HasAttribute("name") -and -not $p.HasAttribute("ref")) {
		Report-Error "Property without name or ref"
	}
	# В модели XDTO fixed — булев признак, само значение лежит в default.
	# В XML-схеме наоборот: fixed="V" совмещает признак и значение.
	if ($p.HasAttribute("fixed")) {
		$fx = $p.GetAttribute("fixed")
		$pName = if ($p.HasAttribute("name")) { $p.GetAttribute("name") } else { $p.GetAttribute("ref") }
		if (@("true", "false") -cnotcontains $fx) {
			Report-Error "Property `"$pName`": fixed=`"$fx`" — in the model this is a boolean flag; the value goes in default (XML Schema combines flag and value in fixed)"
		} elseif ($fx -ceq "true" -and -not $p.HasAttribute("default")) {
			Report-Error "Property `"$pName`": fixed=`"true`" without default — the platform rejects the package («Отсутствует фиксированное значение свойства '$pName'»)"
		}
	}
	if ($script:stopped) { break }
}
if (-not $script:stopped) { Report-OK "Properties: form, cardinalities and fixed values are correct" }

# --- 10b. Structural consistency ---

$structOk = $true
foreach ($t in $pkg.SelectNodes("//*[local-name()='objectType' or local-name()='typeDef']")) {
	if ($t.get_LocalName() -eq "typeDef" -and $t.GetAttribute("type", $XSI_NS) -ne "ObjectType") { continue }
	$tn = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(anonymous type)" }
	$propNames = @{}
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.get_LocalName() -ne "property") { continue }
		$pn = $c.GetAttribute("name")
		if ($pn) {
			if ($propNames.ContainsKey($pn)) {
				Report-Error "$tn : duplicate property name `"$pn`""
				$structOk = $false
			}
			$propNames[$pn] = $true
		}
	}
	if ($script:stopped) { break }
}

foreach ($p in $pkg.SelectNodes("//*[local-name()='property']")) {
	$pn = if ($p.HasAttribute("name")) { $p.GetAttribute("name") } else { $p.GetAttribute("ref") }
	if ($p.HasAttribute("name") -and $p.HasAttribute("ref")) {
		Report-Error "Property `"$pn`": both name and ref are set — only one is allowed"
		$structOk = $false
	}
	$inlineTypeDef = $null
	foreach ($c in $p.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $inlineTypeDef = $c; break }
	}
	if ($inlineTypeDef -and $p.HasAttribute("type")) {
		Report-Error "Property `"$pn`": both type and a nested <typeDef> are set — only one is allowed"
		$structOk = $false
	}
	if ($inlineTypeDef -and -not $inlineTypeDef.HasAttribute("type", $XSI_NS)) {
		Report-Error "Property `"$pn`": nested <typeDef> has no xsi:type (ValueType or ObjectType)"
		$structOk = $false
	}
	if ($script:stopped) { break }
}

# Анонимный тип внутри valueType задаёт базовый тип и xsi:type не несёт
foreach ($vt in $pkg.SelectNodes("//*[local-name()='valueType']")) {
	foreach ($c in $vt.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.get_LocalName() -ne "typeDef") { continue }
		if ($c.HasAttribute("type", $XSI_NS)) {
			Report-Warn "$($vt.GetAttribute('name')) : <typeDef> inside <valueType> has xsi:type — the platform does not write it here"
		}
	}
}

# Род базового типа должен совпадать
foreach ($t in $pkg.SelectNodes("//*[local-name()='objectType'][@base]")) {
	$b = $t.GetAttribute("base")
	$parts = $b.Split(":")
	if ($parts.Count -ne 2) { continue }
	$bns = $t.GetNamespaceOfPrefix($parts[0])
	if ($bns -ne $targetNs) { continue }
	if ($valueTypeNames.Contains($parts[1])) {
		Report-Error "$($t.GetAttribute('name')) : base=`"$b`" refers to a valueType, but an objectType can only inherit from an objectType"
		$structOk = $false
	}
}
foreach ($t in $pkg.SelectNodes("//*[local-name()='valueType'][@base]")) {
	$b = $t.GetAttribute("base")
	$parts = $b.Split(":")
	if ($parts.Count -ne 2) { continue }
	$bns = $t.GetNamespaceOfPrefix($parts[0])
	if ($bns -ne $targetNs) { continue }
	if ($objectTypeNames.Contains($parts[1])) {
		Report-Error "$($t.GetAttribute('name')) : base=`"$b`" refers to an objectType, but a valueType can only be built on a simple type"
		$structOk = $false
	}
}

# Union без состава
foreach ($t in $pkg.SelectNodes("//*[local-name()='valueType' or local-name()='typeDef'][@variety='Union']")) {
	if ($t.HasAttribute("memberTypes")) { continue }
	$hasMember = $false
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $hasMember = $true; break }
	}
	if (-not $hasMember) {
		$tn = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(anonymous type)" }
		Report-Warn "$tn : variety=`"Union`" without memberTypes or nested types — the union is empty"
	}
}

if ($structOk -and -not $script:stopped) { Report-OK "Type and property structure is consistent" }

if ($script:stopped) { & $finalize; exit 1 }

# --- 11. Metadata object ---

if ($mdPath) {
	$md = New-Object System.Xml.XmlDocument
	$md.Load($mdPath)
	$nsm = New-Object System.Xml.XmlNamespaceManager($md.NameTable)
	$nsm.AddNamespace("md", $MD_NS)
	$mdName = $md.SelectSingleNode("//md:XDTOPackage/md:Properties/md:Name", $nsm)
	$mdNs = $md.SelectSingleNode("//md:XDTOPackage/md:Properties/md:Namespace", $nsm)
	if (-not $mdName) {
		Report-Error "The metadata object has no <Name>"
	} elseif ($mdName.InnerText -ne $fileName) {
		Report-Error "<Name>$($mdName.InnerText)</Name> does not match the directory name `"$fileName`""
	} else {
		Report-OK "Metadata object: Name = $($mdName.InnerText)"
	}
	if ($mdNs -and $mdNs.InnerText -ne $targetNs) {
		Report-Error "<Namespace>$($mdNs.InnerText)</Namespace> does not match the package targetNamespace ($targetNs)"
	} elseif ($mdNs) {
		Report-OK "Metadata object Namespace matches targetNamespace"
	}
} else {
	Report-Warn "Metadata object file <Name>.xml not found next to the package directory"
}

# --- 12. Registration in Configuration.xml + namespace uniqueness ---

$configXml = Join-Path $ConfigDir "Configuration.xml"
if (Test-Path $configXml) {
	$cfg = New-Object System.Xml.XmlDocument
	$cfg.Load($configXml)
	$nsm2 = New-Object System.Xml.XmlNamespaceManager($cfg.NameTable)
	$nsm2.AddNamespace("md", $MD_NS)
	$registered = $false
	foreach ($e in $cfg.SelectNodes("//md:Configuration/md:ChildObjects/md:XDTOPackage", $nsm2)) {
		if ($e.InnerText -eq $fileName) { $registered = $true; break }
	}
	if ($registered) {
		Report-OK "Registered in Configuration.xml"
	} else {
		Report-Error "<XDTOPackage>$fileName</XDTOPackage> is missing from ChildObjects in Configuration.xml — the platform will not see the package"
	}

	# Уникальность targetNamespace среди пакетов конфигурации
	$pkgRoot = Join-Path $ConfigDir "XDTOPackages"
	if (Test-Path $pkgRoot) {
		$clash = @()
		foreach ($other in (Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue)) {
			if ($other.Name -eq $fileName) { continue }
			$ob = Join-Path (Join-Path $other.FullName "Ext") "Package.bin"
			if (-not (Test-Path $ob)) { continue }
			try {
				$od = New-Object System.Xml.XmlDocument
				$od.Load($ob)
				if ($od.DocumentElement.GetAttribute("targetNamespace") -eq $targetNs) { $clash += $other.Name }
			} catch {}
		}
		# Платформа отвергает пакет, если импортируемого namespace нет в конфигурации:
		# «Ошибка проверки модели XDTO: xdto-package-3.3 … не определен»
		$knownNs = @{}
		foreach ($other in (Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue)) {
			$ob = Join-Path (Join-Path $other.FullName "Ext") "Package.bin"
			if (-not (Test-Path $ob)) { continue }
			try {
				$od = New-Object System.Xml.XmlDocument
				$od.Load($ob)
				$knownNs[$od.DocumentElement.GetAttribute("targetNamespace")] = $other.Name
			} catch {}
		}
		$missing = @()
		foreach ($imp in $imports) { if (-not $knownNs.ContainsKey($imp) -and $PLATFORM_NS -notcontains $imp) { $missing += $imp } }
		if ($missing.Count -gt 0) {
			Report-Error ("Imported packages are not defined in the configuration: " + ($missing -join ", ") +
			              ". The platform rejects the package on configuration update — build the dependencies first")
		} elseif ($imports.Count -gt 0) {
			Report-OK "All imports resolve to configuration packages"
		}

		if ($clash.Count -gt 0) {
			Report-Warn "targetNamespace `"$targetNs`" is also declared in package(s): $($clash -join ', '). The platform allows this, but an <import> of this namespace becomes ambiguous"
		} else {
			Report-OK "targetNamespace is unique in the configuration"
		}
	}
} else {
	Report-Warn "Configuration.xml not found ($ConfigDir) — registration and namespace uniqueness checks skipped"
}

# --- Final ---

& $finalize
if ($script:errors -gt 0) { exit 1 }
exit 0
