# xdto-validate v1.4 — Validate a 1C XDTO package
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
	Write-Host "[ERROR] Не найден Ext/Package.bin для пути: $PackagePath"
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
	Report-Error "Package.bin не является корректным XML: $($_.Exception.Message)"
	& $finalize
	exit 1
}
$pkg = $doc.DocumentElement
if ($pkg.get_LocalName() -ne "package") {
	Report-Error "Ожидался корневой <package>, найден <$($pkg.get_LocalName())>"
	& $finalize
	exit 1
}
Report-OK "Package.bin: корректный XML, корень <package>"

$targetNs = $pkg.GetAttribute("targetNamespace")
if (-not $targetNs) {
	Report-Error "У <package> не задан targetNamespace"
} else {
	Report-OK "targetNamespace: $targetNs"
}

# --- 2. Encoding / EOL ---

$bytes = [System.IO.File]::ReadAllBytes($binPath)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
	Report-Warn "Package.bin без BOM UTF-8 — платформа пишет файл с BOM"
} else {
	Report-OK "Кодировка: UTF-8 с BOM"
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
		Report-Error "Нарушен порядок элементов верхнего уровня: <$t> после <$($TOP_ORDER[$prevRank])>. Модель требует import -> property -> valueType -> objectType; платформа отвергнет пакет при обновлении конфигурации"
		$orderOk = $false
		break
	}
	$prevRank = $rank
}
if ($orderOk) { Report-OK "Порядок элементов верхнего уровня корректен" }

# --- 4. Duplicate type names ---

$seen = @{}
foreach ($n in $pkg.ChildNodes) {
	if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
	if ($n.get_LocalName() -ne "objectType" -and $n.get_LocalName() -ne "valueType") { continue }
	$nm = $n.GetAttribute("name")
	if (-not $nm) { Report-Error "<$($n.get_LocalName())> без атрибута name"; continue }
	if ($seen.ContainsKey($nm)) {
		Report-Error "Дублирующееся имя типа: $nm"
	} else {
		$seen[$nm] = $true
	}
}
if ($localTypes.Count -gt 0) { Report-OK "$($localTypes.Count) тип(ов), имена уникальны" }

# --- 5. Type references resolve ---

$usedNamespaces = New-Object System.Collections.Generic.HashSet[string]
$anyTypeProps = New-Object System.Collections.ArrayList
$refAttrs = @("type", "base", "ref", "itemType")

function Resolve-Ref([System.Xml.XmlElement]$el, [string]$attr, [string]$raw) {
	if (-not $raw) { return }
	# Нотация Кларка {ns}local
	if ($raw.StartsWith("{")) {
		$close = $raw.IndexOf("}")
		if ($close -lt 0) { Report-Error "Некорректная нотация Кларка в $attr=`"$raw`""; return }
		$ns = $raw.Substring(1, $close - 1)
		$local = $raw.Substring($close + 1)
	} else {
		$parts = $raw.Split(":")
		if ($parts.Count -eq 2) {
			$ns = $el.GetNamespaceOfPrefix($parts[0])
			$local = $parts[1]
			if (-not $ns) {
				Report-Error "Префикс `"$($parts[0])`" не объявлен: $attr=`"$raw`" (тип $($el.get_LocalName()))"
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
				Report-Error "ref=`"$raw`" не разрешается: в пакете нет глобального свойства `"$local`""
			}
		} elseif (-not $localTypes.Contains($local)) {
			Report-Error "$attr=`"$raw`" не разрешается: в пакете нет типа `"$local`""
		}
		return
	}
	if ($ns) {
		[void]$usedNamespaces.Add($ns)
		if (-not $imports.Contains($ns)) {
			Report-Error "$attr=`"$raw`" ссылается на `"$ns`", но <import namespace=`"$ns`"/> не объявлен"
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
if (-not $script:stopped) { Report-OK "$nodeCount узлов: ссылки на типы разрешаются" }

if ($script:stopped) { & $finalize; exit 1 }

# --- 6. Silent degradation to xs:anyType ---
# Платформа при импорте XML-схемы молча подменяет неразрешённый чужой тип на anyType.

if ($anyTypeProps.Count -gt 0 -and $imports.Count -gt 0) {
	$names = @()
	foreach ($p in $anyTypeProps) { if ($p.HasAttribute("name")) { $names += $p.GetAttribute("name") } }
	$shown = ($names | Select-Object -First 5) -join ", "
	Report-Warn "Свойств с type=`"xs:anyType`": $($anyTypeProps.Count) при объявленных импортах ($shown). Тип не разрешён — заполнить структурно такое свойство нельзя. Обычно это след импорта XML-схемы: платформа заменяет неразрешённый чужой тип на anyType без ошибки"
}

# --- 7. Unused imports ---

# Сам по себе неиспользуемый импорт безвреден и встречается в четверти пакетов
# типовых конфигураций. Сигналом он становится только вместе с anyType — тогда это
# почти наверняка неразрешённая зависимость.
$unused = @()
foreach ($imp in $imports) { if (-not $usedNamespaces.Contains($imp)) { $unused += $imp } }
if ($unused.Count -gt 0 -and $anyTypeProps.Count -gt 0) {
	Report-Warn "Импорт(ы) без единого использованного типа: $($unused -join ', ') — вместе с anyType это признак неразрешённой зависимости"
}
if ($imports.Count -gt 0 -and $unused.Count -eq 0) { Report-OK "$($imports.Count) импорт(ов) — все используются" }

# --- 8. nillable on attribute-form properties ---

$nillAttrs = @()
foreach ($p in $pkg.SelectNodes("//*[local-name()='property']")) {
	if ($p.GetAttribute("form") -eq "Attribute" -and $p.GetAttribute("nillable") -eq "true") {
		$nillAttrs += $p.GetAttribute("name")
	}
}
if ($nillAttrs.Count -gt 0) {
	Report-Warn "Свойств с nillable=`"true`" и form=`"Attribute`": $($nillAttrs.Count) ($(($nillAttrs | Select-Object -First 5) -join ', ')). Спецификация XSD не допускает nillable у атрибутов — экспорт XML-схемы в Конфигураторе их потеряет"
}

# --- 9. Facet consistency ---

$FACET_NUM = @("totalDigits", "fractionDigits")
$facetChecked = 0
foreach ($t in $pkg.SelectNodes("//*[local-name()='valueType' or local-name()='typeDef']")) {
	if ($t.get_LocalName() -eq "typeDef" -and $t.GetAttribute("type", $XSI_NS) -eq "ObjectType") { continue }
	$facetChecked++
	$nm = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(анонимный тип)" }

	$len = $t.GetAttribute("length")
	if ($len -and ($t.HasAttribute("minLength") -or $t.HasAttribute("maxLength"))) {
		# Спецификация XSD это запрещает, но платформа такие типы хранит — предупреждение, не ошибка
		Report-Warn "$nm : length задан вместе с minLength/maxLength — спецификация XSD считает их взаимоисключающими"
	}
	$minL = $t.GetAttribute("minLength"); $maxL = $t.GetAttribute("maxLength")
	if ($minL -and $maxL -and ([int]$minL -gt [int]$maxL)) {
		Report-Error "$nm : minLength ($minL) больше maxLength ($maxL)"
	}
	$td = $t.GetAttribute("totalDigits"); $fd = $t.GetAttribute("fractionDigits")
	if ($td -and $fd -and ([int]$fd -gt [int]$td)) {
		Report-Error "$nm : fractionDigits ($fd) больше totalDigits ($td)"
	}
	$ws = $t.GetAttribute("whiteSpace")
	if ($ws -and @("preserve", "replace", "collapse") -notcontains $ws) {
		Report-Error "$nm : недопустимое whiteSpace=`"$ws`""
	}
	$var = $t.GetAttribute("variety")
	if ($var -and @("Atomic", "List", "Union") -notcontains $var) {
		Report-Error "$nm : недопустимое variety=`"$var`""
	}
	if ($var -eq "List" -and -not $t.HasAttribute("itemType")) {
		Report-Warn "$nm : variety=`"List`" без itemType"
	}
	if ($script:stopped) { break }
}
if ($facetChecked -gt 0 -and -not $script:stopped) { Report-OK "$facetChecked простых тип(ов): фасеты согласованы" }

if ($script:stopped) { & $finalize; exit 1 }

# --- 10. property form / bounds ---

foreach ($p in $pkg.SelectNodes("//*[local-name()='property']")) {
	$form = $p.GetAttribute("form")
	if ($form -and @("Element", "Attribute", "Text") -notcontains $form) {
		Report-Error "Свойство `"$($p.GetAttribute('name'))`": недопустимое form=`"$form`""
	}
	$ub = $p.GetAttribute("upperBound")
	if ($ub -and $ub -ne "-1" -and ([int]$ub -lt 1)) {
		Report-Error "Свойство `"$($p.GetAttribute('name'))`": upperBound=`"$ub`" (допустимы -1 или число ≥ 1)"
	}
	$lb = $p.GetAttribute("lowerBound")
	if ($lb -and $ub -and $ub -ne "-1" -and ([int]$lb -gt [int]$ub)) {
		Report-Error "Свойство `"$($p.GetAttribute('name'))`": lowerBound ($lb) больше upperBound ($ub)"
	}
	if (-not $p.HasAttribute("name") -and -not $p.HasAttribute("ref")) {
		Report-Error "Свойство без name и без ref"
	}
	# В модели XDTO fixed — булев признак, само значение лежит в default.
	# В XML-схеме наоборот: fixed="V" совмещает признак и значение.
	if ($p.HasAttribute("fixed")) {
		$fx = $p.GetAttribute("fixed")
		$pName = if ($p.HasAttribute("name")) { $p.GetAttribute("name") } else { $p.GetAttribute("ref") }
		if (@("true", "false") -cnotcontains $fx) {
			Report-Error "Свойство `"$pName`": fixed=`"$fx`" — в модели это булев признак, значение задаётся в default (в XML-схеме признак и значение совмещены в fixed)"
		} elseif ($fx -ceq "true" -and -not $p.HasAttribute("default")) {
			Report-Error "Отсутствует фиксированное значение свойства '$pName': есть fixed=`"true`", нет default"
		}
	}
	if ($script:stopped) { break }
}
if (-not $script:stopped) { Report-OK "Свойства: form, кратности и фиксированные значения корректны" }

# --- 10b. Structural consistency ---

$structOk = $true
foreach ($t in $pkg.SelectNodes("//*[local-name()='objectType' or local-name()='typeDef']")) {
	if ($t.get_LocalName() -eq "typeDef" -and $t.GetAttribute("type", $XSI_NS) -ne "ObjectType") { continue }
	$tn = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(анонимный тип)" }
	$propNames = @{}
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.get_LocalName() -ne "property") { continue }
		$pn = $c.GetAttribute("name")
		if ($pn) {
			if ($propNames.ContainsKey($pn)) {
				Report-Error "$tn : дублирующееся имя свойства `"$pn`""
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
		Report-Error "Свойство `"$pn`": заданы одновременно name и ref — допустимо только одно"
		$structOk = $false
	}
	$inlineTypeDef = $null
	foreach ($c in $p.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $inlineTypeDef = $c; break }
	}
	if ($inlineTypeDef -and $p.HasAttribute("type")) {
		Report-Error "Свойство `"$pn`": заданы одновременно type и вложенный <typeDef> — допустимо только одно"
		$structOk = $false
	}
	if ($inlineTypeDef -and -not $inlineTypeDef.HasAttribute("type", $XSI_NS)) {
		Report-Error "Свойство `"$pn`": у вложенного <typeDef> не задан xsi:type (ValueType или ObjectType)"
		$structOk = $false
	}
	if ($script:stopped) { break }
}

# Анонимный тип внутри valueType задаёт базовый тип и xsi:type не несёт
foreach ($vt in $pkg.SelectNodes("//*[local-name()='valueType']")) {
	foreach ($c in $vt.ChildNodes) {
		if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.get_LocalName() -ne "typeDef") { continue }
		if ($c.HasAttribute("type", $XSI_NS)) {
			Report-Warn "$($vt.GetAttribute('name')) : у <typeDef> внутри <valueType> задан xsi:type — платформа его здесь не пишет"
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
		Report-Error "$($t.GetAttribute('name')) : base=`"$b`" ссылается на valueType, а objectType может наследоваться только от objectType"
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
		Report-Error "$($t.GetAttribute('name')) : base=`"$b`" ссылается на objectType, а valueType может строиться только на простом типе"
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
		$tn = if ($t.HasAttribute("name")) { $t.GetAttribute("name") } else { "(анонимный тип)" }
		Report-Warn "$tn : variety=`"Union`" без memberTypes и без вложенных типов — состав объединения пуст"
	}
}

if ($structOk -and -not $script:stopped) { Report-OK "Структура типов и свойств согласована" }

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
		Report-Error "В объекте метаданных не задано <Name>"
	} elseif ($mdName.InnerText -ne $fileName) {
		Report-Error "<Name>$($mdName.InnerText)</Name> не совпадает с именем каталога `"$fileName`""
	} else {
		Report-OK "Объект метаданных: Name = $($mdName.InnerText)"
	}
	if ($mdNs -and $mdNs.InnerText -ne $targetNs) {
		Report-Error "<Namespace>$($mdNs.InnerText)</Namespace> не совпадает с targetNamespace пакета ($targetNs)"
	} elseif ($mdNs) {
		Report-OK "Namespace объекта метаданных совпадает с targetNamespace"
	}
} else {
	Report-Warn "Файл объекта метаданных <Имя>.xml не найден рядом с каталогом пакета"
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
		Report-OK "Зарегистрирован в Configuration.xml"
	} else {
		Report-Error "<XDTOPackage>$fileName</XDTOPackage> отсутствует в ChildObjects файла Configuration.xml — платформа пакет не увидит"
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
			Report-Error ("Импортируемые пакеты не определены в конфигурации: " + ($missing -join ", ") +
			              ". Платформа отвергнет пакет при обновлении конфигурации — соберите зависимости первыми")
		} elseif ($imports.Count -gt 0) {
			Report-OK "Все импорты разрешаются в пакеты конфигурации"
		}

		if ($clash.Count -gt 0) {
			Report-Warn "targetNamespace `"$targetNs`" объявлен также в пакет(ах): $($clash -join ', '). Платформа это допускает, но <import> на это пространство имён становится неоднозначным"
		} else {
			Report-OK "targetNamespace уникален в конфигурации"
		}
	}
} else {
	Report-Warn "Configuration.xml не найден ($ConfigDir) — проверки регистрации и уникальности namespace пропущены"
}

# --- Final ---

& $finalize
if ($script:errors -gt 0) { exit 1 }
exit 0
