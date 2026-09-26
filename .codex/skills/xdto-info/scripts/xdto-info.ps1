# xdto-info v1.2 — Analyze 1C XDTO package structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory=$true, Position=0)]
	[Alias('Path')]
	[string]$PackagePath,
	[string]$Package,
	[string]$Namespace,
	[string]$Name,
	[ValidateSet("auto", "used-by")]
	[string]$Mode = "auto",
	[int]$Depth = 1,
	[switch]$RequiredOnly,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$XS_NS  = "http://www.w3.org/2001/XMLSchema"
$XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
$MD_NS  = "http://v8.1c.ru/8.3/MDClasses"

# --- Output ---

$sb = New-Object System.Text.StringBuilder
function O([string]$line = "") { [void]$sb.AppendLine($line) }

function Fail([string]$msg) {
	# Отрицательный результат поиска — не исключение: печатаем сообщение
	# и выходим с кодом 1, без стектрейса PowerShell
	Write-Host $msg
	exit 1
}

function Flush-Output {
	$text = $sb.ToString().TrimEnd()
	if ($OutFile) {
		$dir = [System.IO.Path]::GetDirectoryName($OutFile)
		if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
		[System.IO.File]::WriteAllText($OutFile, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
		Write-Host "✓ Записано: $OutFile"
	} else {
		Write-Host $text
	}
}

# --- Path resolution -----------------------------------------------------------
# Путь может указывать на корень конфигурации (тогда работаем со всеми пакетами)
# либо на конкретный пакет.

if (-not [System.IO.Path]::IsPathRooted($PackagePath)) {
	$PackagePath = Join-Path (Get-Location).Path $PackagePath
}
if (-not (Test-Path $PackagePath)) { Fail "Путь не найден: $PackagePath" }

$configRoot = $null
$directPkgDir = $null

if (Test-Path (Join-Path $PackagePath "Configuration.xml")) {
	$configRoot = $PackagePath
} elseif ((Split-Path $PackagePath -Leaf) -eq "XDTOPackages") {
	$configRoot = Split-Path $PackagePath -Parent
} elseif (Test-Path (Join-Path (Join-Path $PackagePath "Ext") "Package.bin")) {
	$directPkgDir = $PackagePath
	$pkgRoot = Split-Path $PackagePath -Parent
	$configRoot = Split-Path $pkgRoot -Parent
} elseif ((Test-Path $PackagePath -PathType Leaf) -and ([System.IO.Path]::GetFileName($PackagePath) -eq "Package.bin")) {
	$directPkgDir = Split-Path (Split-Path $PackagePath -Parent) -Parent
	$configRoot = Split-Path (Split-Path $directPkgDir -Parent) -Parent
} elseif ($PackagePath.EndsWith(".xml")) {
	$stem = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PackagePath),
	                                  [System.IO.Path]::GetFileNameWithoutExtension($PackagePath))
	if (Test-Path (Join-Path (Join-Path $stem "Ext") "Package.bin")) {
		$directPkgDir = $stem
		$configRoot = Split-Path (Split-Path $stem -Parent) -Parent
	}
}
if (-not $configRoot -and -not $directPkgDir) { Fail "Не удалось определить пакет или конфигурацию по пути: $PackagePath" }

# Sort-Object в PowerShell сортирует по культуре, sorted() в Python — по кодам.
# Для паритета портов сортируем ординально в обоих.
function Sort-Ordinal($items) {
	$arr = [string[]]@($items)
	[array]::Sort($arr, [StringComparer]::Ordinal)
	return ,$arr
}

# --- Package index -------------------------------------------------------------

function Read-Package([string]$pkgDir) {
	$bin = Join-Path (Join-Path $pkgDir "Ext") "Package.bin"
	if (-not (Test-Path $bin)) { return $null }
	try {
		$doc = New-Object System.Xml.XmlDocument
		$doc.PreserveWhitespace = $false
		$doc.Load($bin)
	} catch { return $null }
	$root = $doc.DocumentElement
	if ($root.get_LocalName() -ne "package") { return $null }

	$info = [pscustomobject]@{
		Name       = [System.IO.Path]::GetFileName($pkgDir)
		Dir        = $pkgDir
		Namespace  = $root.GetAttribute("targetNamespace")
		Root       = $root
		Imports    = (New-Object System.Collections.ArrayList)
		Types      = @{}
		GlobalProps= (New-Object System.Collections.ArrayList)
	}
	foreach ($n in $root.ChildNodes) {
		if ($n.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		switch ($n.get_LocalName()) {
			"import"     { [void]$info.Imports.Add($n.GetAttribute("namespace")) }
			"objectType" { $info.Types[$n.GetAttribute("name")] = $n }
			"valueType"  { $info.Types[$n.GetAttribute("name")] = $n }
			"property"   { [void]$info.GlobalProps.Add($n) }
		}
	}
	return $info
}

$packages = New-Object System.Collections.ArrayList
$byNamespace = @{}

if ($configRoot -and (Test-Path (Join-Path $configRoot "XDTOPackages"))) {
	foreach ($dn in (Sort-Ordinal ((Get-ChildItem (Join-Path $configRoot "XDTOPackages") -Directory -ErrorAction SilentlyContinue).Name))) {
		$p = Read-Package (Join-Path (Join-Path $configRoot "XDTOPackages") $dn)
		if ($p) {
			[void]$packages.Add($p)
			if (-not $byNamespace.ContainsKey($p.Namespace)) { $byNamespace[$p.Namespace] = $p }
		}
	}
}
if ($directPkgDir -and $packages.Count -eq 0) {
	$p = Read-Package $directPkgDir
	if ($p) { [void]$packages.Add($p); $byNamespace[$p.Namespace] = $p }
}
if ($packages.Count -eq 0) { Fail "Пакеты XDTO не найдены: $PackagePath" }

# --- Type notation: XSD -> 1С ---------------------------------------------------

$XS_TO_1C = @{
	"string" = "Строка"; "normalizedString" = "Строка"; "token" = "Строка"; "NCName" = "Строка"
	"Name" = "Строка"; "QName" = "Строка"; "anyURI" = "Строка"; "language" = "Строка"
	"ID" = "Строка"; "IDREF" = "Строка"; "NMTOKEN" = "Строка"
	"decimal" = "Число"; "integer" = "Число"; "int" = "Число"; "long" = "Число"; "short" = "Число"
	"byte" = "Число"; "float" = "Число"; "double" = "Число"
	"nonNegativeInteger" = "Число"; "positiveInteger" = "Число"; "nonPositiveInteger" = "Число"
	"negativeInteger" = "Число"; "unsignedInt" = "Число"; "unsignedLong" = "Число"
	"unsignedShort" = "Число"; "unsignedByte" = "Число"
	"date" = "Дата"; "dateTime" = "Дата"; "time" = "Дата"
	"boolean" = "Булево"
	"base64Binary" = "ДвоичныеДанные"; "hexBinary" = "ДвоичныеДанные"
	"anyType" = "произвольный"; "anySimpleType" = "произвольный"
}

function Split-Ref([System.Xml.XmlElement]$el, [string]$raw) {
	if (-not $raw) { return $null }
	if ($raw.StartsWith("{")) {
		$close = $raw.IndexOf("}")
		if ($close -lt 0) { return $null }
		return [pscustomobject]@{ Ns = $raw.Substring(1, $close - 1); Local = $raw.Substring($close + 1) }
	}
	$parts = $raw.Split(":")
	if ($parts.Count -eq 2) {
		return [pscustomobject]@{ Ns = $el.GetNamespaceOfPrefix($parts[0]); Local = $parts[1] }
	}
	return [pscustomobject]@{ Ns = $null; Local = $parts[0] }
}

function Get-Facets([System.Xml.XmlElement]$t) {
	$res = @{}
	foreach ($f in @("length", "minLength", "maxLength", "totalDigits", "fractionDigits",
	                 "minInclusive", "maxInclusive", "minExclusive", "maxExclusive")) {
		$v = $t.GetAttribute($f)
		if ($v) { $res[$f] = $v }
	}
	$pat = $null
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "pattern") { $pat = $c.InnerText; break }
	}
	if ($pat) { $res["pattern"] = $pat }
	return $res
}

function Get-Enumerations([System.Xml.XmlElement]$t) {
	$vals = @()
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "enumeration") { $vals += $c.InnerText }
	}
	return $vals
}

# Разворачивает цепочку псевдонимов до примитива, собирая фасеты по пути.
# Возвращает @{ Base1C; Facets; Alias; Enum; Kind }
function Resolve-Scalar([System.Xml.XmlElement]$t, $pkg, [int]$guard = 0) {
	$acc = @{ Base1C = $null; Facets = @{}; Alias = $null; Enum = @(); Kind = "scalar" }
	if ($guard -gt 10 -or -not $t) { return $acc }

	$variety = $t.GetAttribute("variety")
	if ($variety -eq "List") {
		$it = Split-Ref $t $t.GetAttribute("itemType")
		$acc.Kind = "list"
		$acc.Base1C = "список " + $(if ($it) { Format-RefName $it $pkg } else { "значений" })
		return $acc
	}
	if ($variety -eq "Union" -or $t.GetAttribute("memberTypes")) {
		$members = @()
		foreach ($m in (($t.GetAttribute("memberTypes") -split "\s+") | Where-Object { $_ })) {
			$q = Split-Ref $t $m
			if ($q) { $members += (Format-RefName $q $pkg) }
		}
		foreach ($c in $t.ChildNodes) {
			if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") {
				$inner = Resolve-Scalar $c $pkg ($guard + 1)
				$members += $inner.Base1C
			}
		}
		$acc.Kind = "union"
		$acc.Base1C = "одно из (" + (($members | Where-Object { $_ }) -join " | ") + ")"
		return $acc
	}

	$acc.Facets = Get-Facets $t
	$acc.Enum = Get-Enumerations $t

	# базовый тип: атрибут base или вложенный анонимный typeDef
	$baseQ = Split-Ref $t $t.GetAttribute("base")
	$anonBase = $null
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $anonBase = $c; break }
	}
	if (-not $baseQ -and $anonBase) {
		$inner = Resolve-Scalar $anonBase $pkg ($guard + 1)
		$acc.Base1C = $inner.Base1C
		foreach ($k in $inner.Facets.Keys) { if (-not $acc.Facets.ContainsKey($k)) { $acc.Facets[$k] = $inner.Facets[$k] } }
		if ($inner.Enum.Count -gt 0 -and $acc.Enum.Count -eq 0) { $acc.Enum = $inner.Enum }
		return $acc
	}
	if (-not $baseQ) { $acc.Base1C = "произвольный"; return $acc }

	if ($baseQ.Ns -eq $XS_NS) {
		$acc.Base1C = $(if ($XS_TO_1C.ContainsKey($baseQ.Local)) { $XS_TO_1C[$baseQ.Local] } else { "xs:$($baseQ.Local)" })
		return $acc
	}

	# база — именованный тип значения: разворачиваем дальше
	$target = Find-Type $baseQ $pkg
	if ($target -and $target.Element.get_LocalName() -eq "valueType") {
		$inner = Resolve-Scalar $target.Element $target.Package ($guard + 1)
		$acc.Base1C = $inner.Base1C
		foreach ($k in $inner.Facets.Keys) { if (-not $acc.Facets.ContainsKey($k)) { $acc.Facets[$k] = $inner.Facets[$k] } }
		if ($inner.Enum.Count -gt 0 -and $acc.Enum.Count -eq 0) { $acc.Enum = $inner.Enum }
		if (-not $acc.Alias) { $acc.Alias = $baseQ.Local }
		return $acc
	}
	$acc.Base1C = $baseQ.Local
	return $acc
}

function Find-Type($q, $pkg) {
	if (-not $q) { return $null }
	$targetPkg = $null
	if (-not $q.Ns -or ($pkg -and $q.Ns -eq $pkg.Namespace)) { $targetPkg = $pkg }
	elseif ($byNamespace.ContainsKey($q.Ns)) { $targetPkg = $byNamespace[$q.Ns] }
	if (-not $targetPkg) { return $null }
	if (-not $targetPkg.Types.ContainsKey($q.Local)) { return $null }
	return [pscustomobject]@{ Element = $targetPkg.Types[$q.Local]; Package = $targetPkg }
}

function Format-RefName($q, $pkg) {
	if (-not $q) { return "" }
	if ($q.Ns -eq $XS_NS) {
		return $(if ($XS_TO_1C.ContainsKey($q.Local)) { $XS_TO_1C[$q.Local] } else { "xs:$($q.Local)" })
	}
	return $q.Local
}

function Format-Scalar($res) {
	$t = $res.Base1C
	$f = $res.Facets
	if ($t -eq "Строка") {
		if ($f.ContainsKey("length")) { $t = "Строка($($f['length']))" }
		elseif ($f.ContainsKey("maxLength")) { $t = "Строка($($f['maxLength']))" }
	} elseif ($t -eq "Число") {
		if ($f.ContainsKey("totalDigits")) {
			$frac = $(if ($f.ContainsKey("fractionDigits")) { $f["fractionDigits"] } else { "0" })
			$t = "Число($($f['totalDigits']),$frac)"
		}
	}
	return $t
}

function Format-Notes($res) {
	$notes = @()
	if ($res.Alias) { $notes += "← $($res.Alias)" }
	if ($res.Facets.ContainsKey("pattern")) {
		$p = $res.Facets["pattern"]
		if ($p.Length -gt 40) { $p = $p.Substring(0, 40) + "…" }
		$notes += "шаблон $p"
	}
	foreach ($k in @("minInclusive", "maxInclusive", "minExclusive", "maxExclusive")) {
		if ($res.Facets.ContainsKey($k)) { $notes += "$k $($res.Facets[$k])" }
	}
	return $notes
}

# --- Property rendering ---------------------------------------------------------

function Get-PropRows([System.Xml.XmlElement]$type, $pkg, [int]$depth, [int]$indent, $seen) {
	$rows = New-Object System.Collections.ArrayList
	foreach ($p in $type.ChildNodes) {
		if ($p.NodeType -ne [System.Xml.XmlNodeType]::Element -or $p.get_LocalName() -ne "property") { continue }

		$pname = $p.GetAttribute("name")
		if (-not $pname) {
			$refQ = Split-Ref $p $p.GetAttribute("ref")
			$pname = $(if ($refQ) { $refQ.Local } else { "(без имени)" })
		}
		$lower = $p.GetAttribute("lowerBound")
		$upper = $p.GetAttribute("upperBound")
		$flags = @()
		# В модели умолчание lowerBound = 1; помечаем обязательные, как в meta-info
		if ($lower -ne "0") { $flags += "обязательный" }
		if ($upper -eq "-1") { $flags += "список" }
		elseif ($upper -and $upper -ne "1") { $flags += "до $upper" }
		if ($p.GetAttribute("form") -eq "Text") { $flags += "значение элемента" }

		$notes = @()
		$typeText = ""
		$children = $null
		$childPkg = $pkg
		# Именованный вложенный тип берётся так же, как корневой; окольный путь
		# через свойство владельца нужен только анонимному — имени у него нет
		$objName = $null
		$objNs = $null

		$anon = $null
		foreach ($c in $p.ChildNodes) {
			if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "typeDef") { $anon = $c; break }
		}

		if ($anon) {
			if ($anon.GetAttribute("type", $XSI_NS) -eq "ObjectType") {
				$typeText = "объект (анонимный)"
				$objName = "(анонимный)"
				$children = $anon   # анонимные раскрываем всегда: смотреть отдельно негде
			} else {
				$res = Resolve-Scalar $anon $pkg
				$typeText = Format-Scalar $res
				$notes += (Format-Notes $res)
				if ($res.Enum.Count -gt 0) { $notes += "значения: " + (($res.Enum | Select-Object -First 8) -join ", ") }
			}
		} else {
			$q = Split-Ref $p $p.GetAttribute("type")
			if (-not $q) {
				$typeText = "произвольный"
			} elseif ($q.Ns -eq $XS_NS) {
				$typeText = $(if ($XS_TO_1C.ContainsKey($q.Local)) { $XS_TO_1C[$q.Local] } else { "xs:$($q.Local)" })
			} else {
				$target = Find-Type $q $pkg
				if (-not $target) {
					$typeText = "объект $($q.Local)"
					$notes += "(пакет не найден: $($q.Ns))"
				} elseif ($target.Element.get_LocalName() -eq "objectType") {
					$typeText = "объект $($q.Local)"
					if ($target.Package.Namespace -ne $pkg.Namespace) { $typeText += " · $($target.Package.Name)" }
					$objName = $q.Local
					$objNs = $target.Package.Namespace
					$children = $target.Element
					$childPkg = $target.Package
				} else {
					$res = Resolve-Scalar $target.Element $target.Package
					$typeText = Format-Scalar $res
					$notes += "← $($q.Local)"
					$n2 = Format-Notes $res | Where-Object { -not $_.StartsWith("←") }
					$notes += $n2
					if ($res.Enum.Count -gt 0) { $notes += "значения: " + (($res.Enum | Select-Object -First 8) -join ", ") }
				}
			}
		}

		[void]$rows.Add([pscustomobject]@{
			Indent = $indent; Name = $pname; Type = $typeText
			Flags = $flags; Notes = ($notes | Where-Object { $_ })
			ObjName = $objName; ObjNs = $objNs
		})

		if ($children) {
			$key = "$($childPkg.Namespace)#$($children.GetAttribute('name'))"
			$isAnon = -not $children.GetAttribute("name")
			if (-not $isAnon -and $seen.Contains($key)) {
				[void]$rows.Add([pscustomobject]@{ Indent = $indent + 1; Name = "(раскрыт выше)"; Type = ""; Flags = @(); Notes = @() })
			} elseif ($isAnon -or $depth -gt 1) {
				$nextSeen = New-Object System.Collections.Generic.HashSet[string] (,[string[]]$seen)
				if (-not $isAnon) { [void]$nextSeen.Add($key) }
				$nextDepth = $(if ($isAnon) { $depth } else { $depth - 1 })
				foreach ($r in (Get-PropRows $children $childPkg $nextDepth ($indent + 1) $nextSeen)) { [void]$rows.Add($r) }
			}
		}
	}
	return ,$rows
}

# Оставить только обязательные свойства. Ребёнок необязательного объекта тоже
# уходит: он лежит под необязательной веткой и заполнять его не обязательно.
function Select-Required($rows) {
	$res = New-Object System.Collections.ArrayList
	$cutFrom = -1
	foreach ($r in $rows) {
		if ($cutFrom -ge 0 -and $r.Indent -gt $cutFrom) { continue }
		$cutFrom = -1
		if ($r.Flags -notcontains "обязательный") { $cutFrom = $r.Indent; continue }
		[void]$res.Add($r)
	}
	return ,$res
}

function Write-Rows($rows) {
	if ($rows.Count -eq 0) { O "  (нет свойств)"; return }
	$shown = $rows
	if ($Offset -gt 0 -or $rows.Count -gt $Limit) {
		$end = [Math]::Min($Offset + $Limit, $rows.Count) - 1
		if ($Offset -le $end) { $shown = $rows[$Offset..$end] } else { $shown = @() }
	}
	$wName = 0; $wType = 0
	foreach ($r in $shown) {
		$n = ("  " * $r.Indent) + $r.Name
		if ($n.Length -gt $wName) { $wName = $n.Length }
		if ($r.Type.Length -gt $wType) { $wType = $r.Type.Length }
	}
	foreach ($r in $shown) {
		$n = ("  " * $r.Indent) + $r.Name
		$line = "  " + $n.PadRight($wName + 2) + $r.Type.PadRight($wType + 2)
		if ($r.Flags.Count -gt 0) { $line += "[" + ($r.Flags -join ", ") + "]  " }
		if ($r.Notes.Count -gt 0) { $line += ($r.Notes -join ", ") }
		O $line.TrimEnd()
	}
	if ($rows.Count -gt $shown.Count) {
		O "  … показано $($shown.Count) из $($rows.Count); листать через -Offset/-Limit"
	}
}

# --- Modes ----------------------------------------------------------------------

function Show-PackageList {
	O "=== Пакеты XDTO: $($packages.Count) ==="
	O ""
	$shown = $packages
	if ($Offset -gt 0 -or $packages.Count -gt $Limit) {
		$end = [Math]::Min($Offset + $Limit, $packages.Count) - 1
		if ($Offset -le $end) { $shown = $packages[$Offset..$end] } else { $shown = @() }
	}
	$wn = 0
	foreach ($p in $shown) { if ($p.Name.Length -gt $wn) { $wn = $p.Name.Length } }
	foreach ($p in $shown) {
		$cnt = $p.Types.Count
		O ("  " + $p.Name.PadRight($wn + 2) + "$cnt".PadLeft(4) + "  " + $p.Namespace)
	}
	if ($packages.Count -gt $shown.Count) {
		O ""
		O "  … показано $($shown.Count) из $($packages.Count); листать через -Offset/-Limit"
	}
	O ""
	O "Колонки: имя пакета, число типов, namespace."
	O "Следующий шаг: -Package <имя> или -Namespace <URI> — состав пакета; -Name <Тип> — поиск типа по всем пакетам"
}

function Show-PackageOverview($pkg) {
	O "=== Пакет XDTO: $($pkg.Name) ==="
	O "Namespace: $($pkg.Namespace)"
	if ($pkg.Imports.Count -gt 0) {
		O ""
		O "Импорты ($($pkg.Imports.Count)):"
		foreach ($i in $pkg.Imports) {
			$dep = $(if ($byNamespace.ContainsKey($i)) { $byNamespace[$i].Name } else { "(пакет не найден)" })
			O "  $i  →  $dep"
		}
	}
	if ($pkg.GlobalProps.Count -eq 0) {
		O ""
		O "Точки входа: нет — пакет не объявляет корневых элементов документа"
	} else {
		O ""
		O "Точки входа ($($pkg.GlobalProps.Count)) — корневые элементы документа:"
		foreach ($gp in $pkg.GlobalProps) {
			$q = Split-Ref $gp $gp.GetAttribute("type")
			$tn = $(if ($q) { Format-RefName $q $pkg } else { "произвольный" })
			$form = $(if ($gp.GetAttribute("form") -eq "Attribute") { "  (атрибут)" } else { "" })
			O ("  <" + $gp.GetAttribute("name") + ">  →  " + $tn + $form)
		}
	}
	$objs = @(); $vals = @()
	foreach ($k in (Sort-Ordinal $pkg.Types.Keys)) {
		if ($pkg.Types[$k].get_LocalName() -eq "objectType") { $objs += $k } else { $vals += $k }
	}
	if ($objs.Count -gt 0) {
		O ""
		O "Объектные типы ($($objs.Count)):"
		foreach ($n in $objs) {
			$cnt = 0
			foreach ($c in $pkg.Types[$n].ChildNodes) {
				if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.get_LocalName() -eq "property") { $cnt++ }
			}
			$base = Split-Ref $pkg.Types[$n] $pkg.Types[$n].GetAttribute("base")
			$suffix = $(if ($base) { "  ← $($base.Local)" } else { "" })
			O ("  " + $n.PadRight(40) + "свойств: $cnt" + $suffix)
		}
	}
	if ($vals.Count -gt 0) {
		O ""
		O "Типы значений ($($vals.Count)):"
		foreach ($n in $vals) {
			$res = Resolve-Scalar $pkg.Types[$n] $pkg
			$line = "  " + $n.PadRight(40) + (Format-Scalar $res)
			if ($res.Enum.Count -gt 0) { $line += "  значения: " + (($res.Enum | Select-Object -First 6) -join ", ") }
			O $line
		}
	}
	O ""
	O "Следующий шаг: -Name <Тип> — структура типа для заполнения"
}

# Легенда едет вместе с выводом, а не живёт в инструкции: показываем только те
# обозначения, которые реально встретились, иначе она сама становится шумом.
function Write-Legend($rows) {
	$text = ($rows | ForEach-Object { $_.Type + " " + ($_.Flags -join ",") + " " + ($_.Notes -join ",") }) -join " "
	$items = @()
	if ($text -match "объект ")            { $items += "объект X — присвоить вложенный объект XDTO, состав раскрывает -Depth" }
	if ($text -match "←")                  { $items += "← Имя — исходный тип из схемы, слева от стрелки развёрнутое значение" }
	if ($text -match "список")             { $items += "список — коллекция, заполняется через .Добавить()" }
	if ($text -match "до \d")              { $items += "до N — коллекция с ограничением сверху" }
	if ($text -match "значение элемента")  { $items += "значение элемента — собственное значение узла XML" }
	if ($text -match "·")                  { $items += "· Пакет — тип объявлен в другом пакете" }
	if ($items.Count -eq 0) { return }
	O ""
	O "Обозначения:"
	foreach ($i in $items) { O "  $i" }
}

function Show-Type($pkg, [string]$typeName) {
	$el = $pkg.Types[$typeName]
	$kind = $el.get_LocalName()
	if ($kind -eq "valueType") {
		$res = Resolve-Scalar $el $pkg
		O "=== Тип значения XDTO: $typeName ==="
		O "Пакет: $($pkg.Name) · $($pkg.Namespace)"
		O ""
		O "Значение: $(Format-Scalar $res)"
		foreach ($n in (Format-Notes $res)) { O "  $n" }
		if ($res.Enum.Count -gt 0) {
			O ""
			O "Допустимые значения ($($res.Enum.Count)):"
			foreach ($v in $res.Enum) { O "  $v" }
		}
		O ""
		O "Создание:"
		# Создать(<Тип>, <Значение>) принимает именно ТипЗначенияXDTO —
		# для объектного типа эта форма неприменима
		O "  Значение = ФабрикаXDTO.Создать(ФабрикаXDTO.Тип(`"$($pkg.Namespace)`", `"$typeName`"), Значение);"
		return
	}

	$hdr = "=== Тип XDTO: $typeName ==="
	if ($Depth -gt 1) { $hdr += "  (глубина $Depth)" }
	O $hdr
	O "Пакет: $($pkg.Name) · $($pkg.Namespace)"
	$base = Split-Ref $el $el.GetAttribute("base")
	if ($base) { O "Наследует: $($base.Local)" }
	if ($el.GetAttribute("abstract") -eq "true") { O "Абстрактный — создаётся только тип-наследник" }
	if ($el.GetAttribute("open") -eq "true") { O "Открытый — допускает произвольные элементы и атрибуты" }
	O ""

	$seen = New-Object System.Collections.Generic.HashSet[string]
	[void]$seen.Add("$($pkg.Namespace)#$typeName")
	$rows = Get-PropRows $el $pkg $Depth 0 $seen
	$own = @($rows | Where-Object { $_.Indent -eq 0 })
	if ($RequiredOnly) {
		$all = $rows.Count
		$rows = Select-Required $rows
		$ownReq = @($rows | Where-Object { $_.Indent -eq 0 })
		# Фильтр обязан сообщать о себе: иначе список читается как полный
		O "Свойства: обязательных $($ownReq.Count) из $($own.Count) (-RequiredOnly; скрыто строк: $($all - $rows.Count))"
	} else {
		O "Свойства ($($own.Count)):"
	}
	Write-Rows $rows
	Write-Legend $rows
	O ""
	O "Создание:"
	O "  Тип = ФабрикаXDTO.Тип(`"$($pkg.Namespace)`", `"$typeName`");"
	O "  Объект = ФабрикаXDTO.Создать(Тип);"
	# Рецепты для вложенных и анонимных типов: имени у анонимного нет, через
	# ФабрикаXDTO.Тип(ns, имя) его не получить — только от свойства владельца
	$named = @($rows | Where-Object { $_.ObjName -and $_.ObjName -ne "(анонимный)" } | Select-Object -First 1)
	if ($named.Count -gt 0) {
		O "  // вложенный именованный тип — так же, как корневой:"
		O "  $($named[0].Name) = ФабрикаXDTO.Создать(ФабрикаXDTO.Тип(`"$($named[0].ObjNs)`", `"$($named[0].ObjName)`"));"
	}
	$anonRow = @($rows | Where-Object { $_.ObjName -eq "(анонимный)" } | Select-Object -First 1)
	if ($anonRow.Count -gt 0) {
		O "  // у анонимного типа нет имени — только через свойство владельца:"
		O "  $($anonRow[0].Name) = ФабрикаXDTO.Создать(Тип.Свойства.Получить(`"$($anonRow[0].Name)`").Тип);"
	}
	$textRow = @($rows | Where-Object { $_.Flags -contains "значение элемента" } | Select-Object -First 1)
	if ($textRow.Count -gt 0) {
		O "  // собственное значение узла лежит в свойстве $($textRow[0].Name)"
	}
}

function Show-UsedBy([string]$typeName, $ownerPkg) {
	O "=== Ссылки на тип: $typeName ==="
	if ($ownerPkg) { O "Объявлен в: $($ownerPkg.Name) · $($ownerPkg.Namespace)" }
	O ""
	$hits = New-Object System.Collections.ArrayList
	foreach ($p in $packages) {
		foreach ($node in $p.Root.SelectNodes("//*")) {
			if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
			foreach ($a in @("type", "base", "itemType", "memberTypes")) {
				$raw = $node.GetAttribute($a)
				if (-not $raw) { continue }
				foreach ($one in ($raw -split "\s+")) {
					$q = Split-Ref $node $one
					if (-not $q -or $q.Local -ne $typeName) { continue }
					if ($ownerPkg -and $q.Ns -and $q.Ns -ne $ownerPkg.Namespace) { continue }
					$owner = $node
					while ($owner -and @("objectType", "valueType") -notcontains $owner.get_LocalName()) { $owner = $owner.ParentNode }
					$where = $(if ($owner -and $owner.GetAttribute("name")) { $owner.GetAttribute("name") } else { "(верхний уровень)" })
					$what = $(if ($node.GetAttribute("name")) { $node.GetAttribute("name") } else { $node.get_LocalName() })
					[void]$hits.Add("  $($p.Name).$where.$what  ($a)")
				}
			}
		}
	}
	if ($hits.Count -eq 0) { O "  Ссылок не найдено"; return }
	O "Найдено ($($hits.Count)):"
	foreach ($h in (Sort-Ordinal ($hits | Select-Object -Unique))) { O $h }
}

# --- Dispatch -------------------------------------------------------------------

# Выбор пакета: явный путь, затем -Namespace / -Package, затем поиск типа по всем
$selected = $null
if ($directPkgDir) {
	$leaf = [System.IO.Path]::GetFileName($directPkgDir)
	$selected = $packages | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
}
if (-not $selected -and $Namespace) {
	$selected = $packages | Where-Object { $_.Namespace -eq $Namespace } | Select-Object -First 1
	if (-not $selected) { Fail "Пакет с namespace `"$Namespace`" не найден. Список: -PackagePath <корень> без параметров" }
}
if (-not $selected -and $Package) {
	$selected = $packages | Where-Object { $_.Name -eq $Package } | Select-Object -First 1
	if (-not $selected) { Fail "Пакет `"$Package`" не найден. Список: -PackagePath <корень> без параметров" }
}

if ($Mode -eq "used-by") {
	if (-not $Name) { Fail "Режим used-by требует -Name <Тип>" }
	$ownerPkg = $selected
	if (-not $ownerPkg) { $ownerPkg = ($packages | Where-Object { $_.Types.ContainsKey($Name) } | Select-Object -First 1) }
	Show-UsedBy $Name $ownerPkg
	Flush-Output
	exit 0
}

if ($Name) {
	if (-not $selected) {
		# Тип известен, пакет — нет: ищем по всей конфигурации
		$found = @($packages | Where-Object { $_.Types.ContainsKey($Name) })
		if ($found.Count -eq 0) { Fail "Тип `"$Name`" не найден ни в одном пакете конфигурации" }
		if ($found.Count -gt 1) {
			O "=== Тип `"$Name`" найден в нескольких пакетах ($($found.Count)) ==="
			O "Уточните через -Namespace или -Package:"
			O ""
			foreach ($f in $found) { O "  $($f.Name)  ·  $($f.Namespace)" }
			Flush-Output
			exit 0
		}
		$selected = $found[0]
	}
	if (-not $selected.Types.ContainsKey($Name)) {
		Fail "В пакете $($selected.Name) нет типа `"$Name`". Список типов: тот же вызов без -Name"
	}
	Show-Type $selected $Name
	Flush-Output
	exit 0
}

if ($selected) { Show-PackageOverview $selected } else { Show-PackageList }
Flush-Output
exit 0
