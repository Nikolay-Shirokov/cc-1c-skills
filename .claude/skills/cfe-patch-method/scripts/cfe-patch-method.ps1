# cfe-patch-method v2.0 — Source-aware method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ExtensionPath,

	[string]$ConfigPath,

	[Parameter(Mandatory)]
	[string]$ModulePath,

	[Parameter(Mandatory)]
	[string]$MethodName,

	[Parameter(Mandatory)]
	[ValidateSet("Before","After","Instead","ModificationAndControl")]
	[string]$InterceptorType
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================================
# Helpers
# ============================================================================

$script:typeDirMap = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "Enum"="Enums"
	"CommonModule"="CommonModules"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"ExchangePlan"="ExchangePlans"; "ChartOfAccounts"="ChartsOfAccounts"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"AccountingRegister"="AccountingRegisters"; "CalculationRegister"="CalculationRegisters"
	"Catalogs"="Catalogs"; "Documents"="Documents"; "Enums"="Enums"
	"CommonModules"="CommonModules"; "Reports"="Reports"; "DataProcessors"="DataProcessors"
	"ExchangePlans"="ExchangePlans"; "ChartsOfAccounts"="ChartsOfAccounts"
	"ChartsOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartsOfCalculationTypes"="ChartsOfCalculationTypes"
	"BusinessProcesses"="BusinessProcesses"; "Tasks"="Tasks"
	"InformationRegisters"="InformationRegisters"; "AccumulationRegisters"="AccumulationRegisters"
	"AccountingRegisters"="AccountingRegisters"; "CalculationRegisters"="CalculationRegisters"
}

# InterceptorType -> Russian decorator keyword
$script:decoratorMap = @{
	"Before"="Перед"; "After"="После"; "Instead"="Вместо"
	"ModificationAndControl"="ИзменениеИКонтроль"
}

# Compute relative .bsl path segments from ModulePath (used for both ext and src)
function Get-ModuleRelPath {
	param([string]$modulePath)
	$parts = $modulePath.Split(".")
	if ($parts.Count -lt 2) {
		throw "Invalid ModulePath format: $modulePath. Expected: Type.Name.Module, Type.Name.Form.FormName or CommonModule.Name"
	}
	$objType = $parts[0]
	$objName = $parts[1]
	if (-not $script:typeDirMap.ContainsKey($objType)) {
		throw "Unknown object type: $objType"
	}
	$dirName = $script:typeDirMap[$objType]

	if ($objType -eq "CommonModule") {
		return @($dirName, $objName, "Ext", "Module.bsl")
	} elseif ($parts.Count -ge 4 -and $parts[2] -eq "Form") {
		$formName = $parts[3]
		return @($dirName, $objName, "Forms", $formName, "Ext", "Form", "Module.bsl")
	} elseif ($parts.Count -ge 3) {
		$moduleName = $parts[2]
		$moduleFileName = switch ($moduleName) {
			"ObjectModule"    { "ObjectModule.bsl" }
			"ManagerModule"   { "ManagerModule.bsl" }
			"RecordSetModule" { "RecordSetModule.bsl" }
			"CommandModule"   { "CommandModule.bsl" }
			"ValueManagerModule" { "ValueManagerModule.bsl" }
			default           { "$moduleName.bsl" }
		}
		return @($dirName, $objName, "Ext", $moduleFileName)
	}
	throw "Invalid ModulePath format: $modulePath"
}

# Extract relative module path segments from a filesystem path to a .bsl,
# anchored on a known type directory (Catalogs/Documents/CommonModules/...).
function Get-RelPartsFromFilePath {
	param([string]$path)
	$segs = ($path -replace '\\', '/').Split('/') | Where-Object { $_ -ne '' }
	$anchors = $script:typeDirMap.Values | Select-Object -Unique
	for ($i = 0; $i -lt $segs.Count; $i++) {
		# case-sensitive: 1C type dirs are PascalCase (Catalogs/Documents/Tasks/…)
		if ($anchors -ccontains $segs[$i]) { return $segs[$i..($segs.Count - 1)] }
	}
	return $null
}

# Split text at top-level separator (respecting parens and string literals)
function Split-TopLevel {
	param([string]$text, [char]$sep = ',')
	$result = @()
	$depth = 0; $inStr = $false
	$sb = New-Object System.Text.StringBuilder
	for ($i = 0; $i -lt $text.Length; $i++) {
		$ch = $text[$i]
		if ($inStr) {
			[void]$sb.Append($ch)
			if ($ch -eq '"') { $inStr = $false }
			continue
		}
		if ($ch -eq '"') { $inStr = $true; [void]$sb.Append($ch); continue }
		if ($ch -eq '(') { $depth++; [void]$sb.Append($ch); continue }
		if ($ch -eq ')') { $depth--; [void]$sb.Append($ch); continue }
		if ($ch -eq $sep -and $depth -eq 0) { $result += $sb.ToString(); $sb = New-Object System.Text.StringBuilder; continue }
		[void]$sb.Append($ch)
	}
	$result += $sb.ToString()
	return $result
}

# Is a trimmed line a context-directive annotation?
function Test-ContextDirective {
	param([string]$trimmed)
	return $trimmed -match '^&(НаКлиенте|НаСервере|НаСервереБезКонтекста|НаКлиентеНаСервереБезКонтекста|НаКлиентеНаСервере)\s*$'
}

# Read a method signature starting at declaration line; returns @{ ParamsText; EndLineIdx }
function Read-Signature {
	param($lines, [int]$startIdx)
	$depth = 0; $inStr = $false; $openFound = $false
	$paramsSb = New-Object System.Text.StringBuilder
	for ($li = $startIdx; $li -lt $lines.Count; $li++) {
		$line = $lines[$li]
		for ($ci = 0; $ci -lt $line.Length; $ci++) {
			$ch = $line[$ci]
			if ($inStr) {
				if ($openFound) { [void]$paramsSb.Append($ch) }
				if ($ch -eq '"') { $inStr = $false }
				continue
			}
			if ($ch -eq '"') { $inStr = $true; if ($openFound) { [void]$paramsSb.Append($ch) }; continue }
			if ($ch -eq '(') {
				$depth++
				if (-not $openFound) { $openFound = $true } else { [void]$paramsSb.Append($ch) }
				continue
			}
			if ($ch -eq ')') {
				$depth--
				if ($depth -eq 0) { return @{ ParamsText = $paramsSb.ToString(); EndLineIdx = $li } }
				[void]$paramsSb.Append($ch)
				continue
			}
			if ($openFound) { [void]$paramsSb.Append($ch) }
		}
		if ($openFound -and $depth -ge 1) { [void]$paramsSb.Append("`r`n") }
	}
	return $null
}

# Compute effective condition of the current branch of an #Если frame
function Get-EffectiveCondition {
	param($frame)
	$conds = $frame.Conds
	$n = $conds.Count
	if ($frame.InElse) {
		$parts = @()
		foreach ($c in $conds) { $parts += "НЕ ($c)" }
		return ($parts -join " И ")
	}
	if ($n -eq 1) { return $conds[0] }
	$parts = @()
	for ($j = 0; $j -lt ($n - 1); $j++) { $parts += "НЕ ($($conds[$j]))" }
	$parts += $conds[$n - 1]
	return ($parts -join " И ")
}

# Extract the enclosing wrapper chain (regions + preprocessor) at a target line.
# Returns array outer->inner of @{ Kind='region'|'if'; Name=..; Cond=.. }
function Get-EnclosingChain {
	param($lines, [int]$targetIdx)
	$stack = New-Object System.Collections.ArrayList
	for ($i = 0; $i -lt $targetIdx; $i++) {
		$t = $lines[$i].Trim()
		if ($t -match '^#Область\s+(\S+)') {
			[void]$stack.Add(@{ Kind = 'region'; Name = $Matches[1] })
		} elseif ($t -match '^#КонецОбласти') {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'region') { $stack.RemoveAt($k); break } }
		} elseif ($t -match '^#Если\s+(.+?)\s+Тогда') {
			[void]$stack.Add(@{ Kind = 'if'; Conds = @($Matches[1].Trim()); InElse = $false })
		} elseif ($t -match '^#ИначеЕсли\s+(.+?)\s+Тогда') {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack[$k].Conds += $Matches[1].Trim(); $stack[$k].InElse = $false; break } }
		} elseif ($t -match '^#Иначе(\s|$)') {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack[$k].InElse = $true; break } }
		} elseif ($t -match '^#КонецЕсли') {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack.RemoveAt($k); break } }
		}
	}
	$chain = @()
	foreach ($f in $stack) {
		if ($f.Kind -eq 'region') { $chain += @{ Kind = 'region'; Name = $f.Name } }
		else { $chain += @{ Kind = 'if'; Cond = (Get-EffectiveCondition $f) } }
	}
	return ,$chain
}

# Extract a method from source .bsl lines. Returns $null if not found.
function Extract-Method {
	param($lines, [string]$methodName)
	$declRe = '^\s*(Асинх\s+)?(Процедура|Функция)\s+(' + [regex]::Escape($methodName) + ')\s*\('
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i] -imatch $declRe) {
			$isAsync = [bool]$Matches[1]
			$keyword = $Matches[2]
			$canonical = $Matches[3]
			$isFunction = ($keyword -ieq "Функция")

			$sig = Read-Signature $lines $i
			if (-not $sig) { throw "Не удалось разобрать сигнатуру метода '$methodName'" }
			$sigEnd = $sig.EndLineIdx
			$paramsText = $sig.ParamsText

			# Parameter names (for ПродолжитьВызов)
			$paramNames = @()
			if ($paramsText.Trim().Length -gt 0) {
				foreach ($seg in (Split-TopLevel $paramsText)) {
					$s = $seg.Trim() -replace '^Знач\s+', ''
					if ($s -match '^([\w]+)') { $paramNames += $Matches[1] }
				}
			}

			# Body: from sigEnd+1 to matching Конец*
			$endRe = if ($isFunction) { '^\s*КонецФункции\b' } else { '^\s*КонецПроцедуры\b' }
			$bodyStart = $sigEnd + 1
			$bodyEnd = -1
			for ($j = $bodyStart; $j -lt $lines.Count; $j++) {
				if ($lines[$j] -imatch $endRe) { $bodyEnd = $j; break }
			}
			if ($bodyEnd -lt 0) { throw "Не найден конец метода '$methodName'" }
			$bodyLines = @()
			for ($j = $bodyStart; $j -lt $bodyEnd; $j++) { $bodyLines += $lines[$j] }

			# Context directive (immediately above declaration)
			$context = ""
			if ($i -ge 1) {
				$prev = $lines[$i - 1].Trim()
				if (Test-ContextDirective $prev) { $context = $prev }
			}

			# Enclosing chain (regions + preprocessor)
			$chain = Get-EnclosingChain $lines $i

			return @{
				Canonical   = $canonical
				IsFunction  = $isFunction
				IsAsync     = $isAsync
				ParamsText  = $paramsText
				ParamNames  = $paramNames
				Context     = $context
				BodyLines   = $bodyLines
				Chain       = $chain
				DeclIdx     = $i
				SigEndIdx   = $sigEnd
				BodyEndIdx  = $bodyEnd
			}
		}
	}
	return $null
}

# Parse interceptors present in a module (type + method)
function Get-Interceptors {
	param($lines)
	$result = @()
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = $lines[$i].Trim()
		if ($t -match '^&(Перед|После|ИзменениеИКонтроль|Вместо)\("([^"]+)"\)') {
			$result += @{ Type = $Matches[1]; Method = $Matches[2]; Line = $i }
		}
	}
	return $result
}

# Parse declared procedure/function names in a module
function Get-ProcNames {
	param($lines)
	$names = @()
	foreach ($line in $lines) {
		if ($line -imatch '^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(') { $names += $Matches[1] }
	}
	return $names
}

# ============================================================================
# Build interceptor block (without enclosing wrappers)
# ============================================================================
function Build-InterceptorCore {
	param($method, [string]$interceptorType, [string]$interceptorName)

	$decoratorRu = $script:decoratorMap[$interceptorType]
	$asyncPrefix = if ($method.IsAsync) { "Асинх " } else { "" }
	$keyword = if ($method.IsFunction) { "Функция" } else { "Процедура" }
	$endKeyword = if ($method.IsFunction) { "КонецФункции" } else { "КонецПроцедуры" }

	$lines = @()
	if ($method.Context) { $lines += $method.Context }
	$lines += "&$decoratorRu(`"$($method.Canonical)`")"
	$lines += "$asyncPrefix$keyword $interceptorName($($method.ParamsText))"

	switch ($interceptorType) {
		"Before" {
			$lines += "`t// TODO: код перед вызовом оригинального метода"
		}
		"After" {
			$lines += "`t// TODO: код после вызова оригинального метода"
		}
		"Instead" {
			$namesJoined = ($method.ParamNames -join ", ")
			if ($method.IsFunction) {
				$lines += "`tРезультат = ПродолжитьВызов($namesJoined);"
				$lines += "`t// TODO: доработать поведение"
				$lines += "`tВозврат Результат;"
			} else {
				$lines += "`tПродолжитьВызов($namesJoined);"
				$lines += "`t// TODO: доработать поведение"
			}
		}
		"ModificationAndControl" {
			foreach ($bl in $method.BodyLines) { $lines += $bl }
		}
	}
	$lines += $endKeyword
	return $lines
}

# Wrap core with region/preprocessor lines, adding blank lines ("air") around
# each structural boundary. Empty chain -> core as-is.
function Build-WrappedBlock {
	param($chainArr, $core)
	$b = @()
	foreach ($w in $chainArr) {
		if ($w.Kind -eq 'region') { $b += "#Область $($w.Name)" } else { $b += "#Если $($w.Cond) Тогда" }
		$b += ""
	}
	$b += $core
	for ($c = $chainArr.Count - 1; $c -ge 0; $c--) {
		$b += ""
		if ($chainArr[$c].Kind -eq 'region') { $b += "#КонецОбласти" } else { $b += "#КонецЕсли" }
	}
	return $b
}

# ============================================================================
# Resync helpers (&ИзменениеИКонтроль)
# ============================================================================

function Get-Normalized {
	param([string]$line)
	return (($line -replace '\s+', ' ').Trim())
}

# Reconstruct v1 body and edit ops from a marked body
function Parse-MarkedBody {
	param($bodyLines)
	$v1 = @()          # reconstructed original lines
	$ops = @()         # edit operations
	$i = 0
	while ($i -lt $bodyLines.Count) {
		$t = $bodyLines[$i].Trim()
		if ($t -eq '#Вставка') {
			$ins = @()
			$i++
			while ($i -lt $bodyLines.Count -and $bodyLines[$i].Trim() -ne '#КонецВставки') { $ins += $bodyLines[$i]; $i++ }
			$i++  # skip #КонецВставки
			$ops += @{ Kind = 'insert'; After = ($v1.Count - 1); Lines = $ins }
		} elseif ($t -eq '#Удаление') {
			$startIdx = $v1.Count
			$i++
			$del = @()
			while ($i -lt $bodyLines.Count -and $bodyLines[$i].Trim() -ne '#КонецУдаления') { $del += $bodyLines[$i]; $v1 += $bodyLines[$i]; $i++ }
			$i++  # skip #КонецУдаления
			$ops += @{ Kind = 'delete'; Start = $startIdx; End = ($v1.Count - 1); Lines = $del }
		} else {
			$v1 += $bodyLines[$i]
			$i++
		}
	}
	return @{ V1 = $v1; Ops = $ops }
}

# Find unique normalized index of a line in v2; -1 if absent or ambiguous
function Find-UniqueIndex {
	param($v2norm, [string]$key)
	$found = -1
	for ($k = 0; $k -lt $v2norm.Count; $k++) {
		if ($v2norm[$k] -eq $key) {
			if ($found -ge 0) { return -1 }  # ambiguous
			$found = $k
		}
	}
	return $found
}

# Find unique contiguous run of normalized lines in v2; returns start index or -1
function Find-UniqueRun {
	param($v2norm, $keys)
	if ($keys.Count -eq 0) { return -1 }
	$found = -1
	for ($k = 0; $k -le ($v2norm.Count - $keys.Count); $k++) {
		$match = $true
		for ($m = 0; $m -lt $keys.Count; $m++) {
			if ($v2norm[$k + $m] -ne $keys[$m]) { $match = $false; break }
		}
		if ($match) {
			if ($found -ge 0) { return -1 }  # ambiguous
			$found = $k
		}
	}
	return $found
}

# ============================================================================
# Main
# ============================================================================

# --- Resolve extension path ---
if (-not [System.IO.Path]::IsPathRooted($ExtensionPath)) { $ExtensionPath = Join-Path (Get-Location).Path $ExtensionPath }
if (Test-Path $ExtensionPath -PathType Leaf) { $ExtensionPath = Split-Path $ExtensionPath -Parent }
$cfgFile = Join-Path $ExtensionPath "Configuration.xml"
if (-not (Test-Path $cfgFile)) { Write-Error "Configuration.xml не найден в расширении: $ExtensionPath"; exit 1 }

# --- Read NamePrefix ---
$cfgDoc = New-Object System.Xml.XmlDocument
$cfgDoc.PreserveWhitespace = $false
$cfgDoc.Load($cfgFile)
$cfgNs = New-Object System.Xml.XmlNamespaceManager($cfgDoc.NameTable)
$cfgNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$propsNode = $cfgDoc.SelectSingleNode("//md:Configuration/md:Properties", $cfgNs)
$prefixNode = if ($propsNode) { $propsNode.SelectSingleNode("md:NamePrefix", $cfgNs) } else { $null }
$namePrefix = if ($prefixNode -and $prefixNode.InnerText) { $prefixNode.InnerText } else { "Расш_" }

# --- Resolve module file paths (ModulePath = logical name OR path to a .bsl) ---
$hasConfigPath = -not [string]::IsNullOrEmpty($ConfigPath)
if ($hasConfigPath) {
	if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath = Join-Path (Get-Location).Path $ConfigPath }
	if (Test-Path $ConfigPath -PathType Leaf) { $ConfigPath = Split-Path $ConfigPath -Parent }
}

$isFilePath = ($ModulePath -match '[\\/]') -or ($ModulePath -match '\.bsl$')

if ($isFilePath) {
	# ModulePath is a filesystem path to the module .bsl
	$mpAbs = if ([System.IO.Path]::IsPathRooted($ModulePath)) { $ModulePath } else { Join-Path (Get-Location).Path $ModulePath }
	$relParts = Get-RelPartsFromFilePath $ModulePath
	if (-not $relParts) { Write-Error "Не удалось определить объект по пути модуля: $ModulePath`n(нет распознаваемой типовой папки — Catalogs/Documents/CommonModules/…)"; exit 1 }
	$extBsl = $ExtensionPath
	foreach ($p in $relParts) { $extBsl = Join-Path $extBsl $p }
	if ($hasConfigPath) {
		$srcBsl = $ConfigPath
		foreach ($p in $relParts) { $srcBsl = Join-Path $srcBsl $p }
	} else {
		# Guard: a path under the extension itself is not a valid source
		$extRootAbs = [System.IO.Path]::GetFullPath($ExtensionPath).TrimEnd('\','/')
		$mpFull = [System.IO.Path]::GetFullPath($mpAbs)
		if ($mpFull.StartsWith($extRootAbs, [System.StringComparison]::OrdinalIgnoreCase)) {
			Write-Error "Путь модуля указывает внутрь расширения, а не на источник. Укажите путь к модулю-источнику или -ConfigPath."; exit 1
		}
		$srcBsl = $mpAbs
	}
} else {
	# ModulePath is a logical name — ConfigPath required
	if (-not $hasConfigPath) { Write-Error "Не указан -ConfigPath. Укажите путь к исходникам конфигурации или передайте путь к файлу модуля в -ModulePath."; exit 1 }
	if (-not (Test-Path (Join-Path $ConfigPath "Configuration.xml"))) { Write-Error "Configuration.xml не найден в конфигурации-источнике: $ConfigPath"; exit 1 }
	$relParts = Get-ModuleRelPath $ModulePath
	$extBsl = $ExtensionPath
	foreach ($p in $relParts) { $extBsl = Join-Path $extBsl $p }
	$srcBsl = $ConfigPath
	foreach ($p in $relParts) { $srcBsl = Join-Path $srcBsl $p }
}

if (-not (Test-Path $srcBsl)) { Write-Error "Модуль-источник не найден: $srcBsl`n(проверьте ModulePath и ConfigPath)"; exit 1 }

# --- Extract original method ---
$srcLines = [System.IO.File]::ReadAllLines($srcBsl, [System.Text.Encoding]::UTF8)
$method = Extract-Method $srcLines $MethodName
if (-not $method) { Write-Error "Метод '$MethodName' не найден в модуле-источнике: $srcBsl"; exit 1 }

# --- Guard: functions cannot use Before/After ---
if ($method.IsFunction -and ($InterceptorType -eq "Before" -or $InterceptorType -eq "After")) {
	Write-Error "Метод '$MethodName' — функция. Для функций доступны только Instead и ModificationAndControl (перехват &Перед/&После к функциям неприменим)."
	exit 1
}

$decoratorRu = $script:decoratorMap[$InterceptorType]

# --- Read existing extension module (if any) ---
$extLines = @()
$extExists = Test-Path $extBsl
if ($extExists) { $extLines = @([System.IO.File]::ReadAllLines($extBsl, [System.Text.Encoding]::UTF8)) }

$existingInterceptors = if ($extExists) { Get-Interceptors $extLines } else { @() }
$existingProcNames = if ($extExists) { Get-ProcNames $extLines } else { @() }

# --- Does the same (method, type) already exist? ---
$dup = $existingInterceptors | Where-Object { $_.Type -eq $decoratorRu -and $_.Method -ieq $MethodName } | Select-Object -First 1

$enc = New-Object System.Text.UTF8Encoding($true)

if ($dup) {
	if ($InterceptorType -ne "ModificationAndControl") {
		Write-Host "[ПРОПУЩЕН] Перехватчик &$decoratorRu(`"$MethodName`") уже есть в модуле — дубль не создаётся."
		Write-Host "     Файл: $extBsl"
		exit 0
	}
	# ---- RESYNC (&ИзменениеИКонтроль) ----
	# Locate existing block: decorator line -> signature -> body -> Конец*
	$decLine = $dup.Line
	# Interceptor procedure name from existing signature (line after decorator, skipping possible async)
	$sigLineIdx = $decLine + 1
	if ($sigLineIdx -ge $extLines.Count -or $extLines[$sigLineIdx] -notmatch '^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(') {
		Write-Error "Не удалось найти сигнатуру существующего перехватчика &ИзменениеИКонтроль(`"$MethodName`")"; exit 1
	}
	$existingName = $Matches[1]
	$sig = Read-Signature $extLines $sigLineIdx
	if (-not $sig) { Write-Error "Не удалось разобрать сигнатуру существующего перехватчика"; exit 1 }
	$sigEnd = $sig.EndLineIdx
	$isFunc = ($extLines[$sigLineIdx] -imatch '^\s*(?:Асинх\s+)?Функция\b')
	$endRe = if ($isFunc) { '^\s*КонецФункции\b' } else { '^\s*КонецПроцедуры\b' }
	$blockEnd = -1
	for ($j = $sigEnd + 1; $j -lt $extLines.Count; $j++) { if ($extLines[$j] -imatch $endRe) { $blockEnd = $j; break } }
	if ($blockEnd -lt 0) { Write-Error "Не найден конец существующего перехватчика"; exit 1 }

	# marked body
	$markedBody = @()
	for ($j = $sigEnd + 1; $j -lt $blockEnd; $j++) { $markedBody += $extLines[$j] }

	# reconstruct v1, ops
	$parsed = Parse-MarkedBody $markedBody
	$v1 = $parsed.V1
	$ops = $parsed.Ops
	$v2 = $method.BodyLines

	$v1norm = @($v1 | ForEach-Object { Get-Normalized $_ })
	$v2norm = @($v2 | ForEach-Object { Get-Normalized $_ })

	# no drift?
	if (($v1norm -join "`n") -eq ($v2norm -join "`n")) {
		Write-Host "[АКТУАЛЕН] &ИзменениеИКонтроль(`"$MethodName`") — оригинал не менялся, изменений нет."
		Write-Host "     Файл: $extBsl"
		exit 0
	}

	# transfer ops onto v2
	$insertTop = @()
	$insertAfter = @{}   # v2 index -> list of blocks (each = @{Lines=..})
	$delStart = @{}      # v2 index -> $true
	$delEnd = @{}
	$disputed = @()

	foreach ($op in $ops) {
		if ($op.Kind -eq 'insert') {
			if ($op.After -lt 0) { $insertTop += ,$op.Lines; continue }
			$anchorKey = $v1norm[$op.After]
			$k = Find-UniqueIndex $v2norm $anchorKey
			if ($k -ge 0) {
				if (-not $insertAfter.ContainsKey($k)) { $insertAfter[$k] = @() }
				$insertAfter[$k] += ,$op.Lines
			} else {
				$disputed += @{ Kind = 'insert'; Lines = $op.Lines }
			}
		} else {
			$keys = @()
			for ($m = $op.Start; $m -le $op.End; $m++) { $keys += $v1norm[$m] }
			$p = Find-UniqueRun $v2norm $keys
			if ($p -ge 0) {
				$delStart[$p] = $true
				$delEnd[$p + $keys.Count - 1] = $true
			} else {
				$disputed += @{ Kind = 'delete'; Lines = $op.Lines }
			}
		}
	}

	# assemble new marked body
	$newBody = @()
	foreach ($blk in $insertTop) {
		$newBody += "#Вставка"; foreach ($l in $blk) { $newBody += $l }; $newBody += "#КонецВставки"
	}
	for ($k = 0; $k -lt $v2.Count; $k++) {
		if ($delStart.ContainsKey($k)) { $newBody += "#Удаление" }
		$newBody += $v2[$k]
		if ($delEnd.ContainsKey($k)) { $newBody += "#КонецУдаления" }
		if ($insertAfter.ContainsKey($k)) {
			foreach ($blk in $insertAfter[$k]) {
				$newBody += "#Вставка"; foreach ($l in $blk) { $newBody += $l }; $newBody += "#КонецВставки"
			}
		}
	}
	# disputed blocks appended with conflict markers (never lost)
	if ($disputed.Count -gt 0) {
		$newBody += "`t// [РЕСИНК-КОНФЛИКТ] перенесите блоки ниже вручную — исходный якорь изменился в новой версии оригинала."
		$newBody += "`t// Материалы для анализа см. в выводе команды (файлы v1/v2/current/diff)."
		foreach ($d in $disputed) {
			if ($d.Kind -eq 'insert') {
				$newBody += "#Вставка"; foreach ($l in $d.Lines) { $newBody += $l }; $newBody += "#КонецВставки"
			} else {
				$newBody += "`t// [РЕСИНК-КОНФЛИКТ] не удалось найти для удаления:"
				foreach ($l in $d.Lines) { $newBody += ("`t// " + $l.Trim()) }
			}
		}
	}

	# rebuild block: keep context (from v2), decorator, signature with existing name and v2 params
	$asyncPrefix = if ($method.IsAsync) { "Асинх " } else { "" }
	$keyword = if ($method.IsFunction) { "Функция" } else { "Процедура" }
	$endKeyword = if ($method.IsFunction) { "КонецФункции" } else { "КонецПроцедуры" }
	$newBlock = @()
	if ($method.Context) { $newBlock += $method.Context }
	$newBlock += "&ИзменениеИКонтроль(`"$($method.Canonical)`")"
	$newBlock += "$asyncPrefix$keyword $existingName($($method.ParamsText))"
	$newBlock += $newBody
	$newBlock += $endKeyword

	# block start includes preceding context directive line if present
	$blockStart = $decLine
	if ($decLine -ge 1 -and (Test-ContextDirective $extLines[$decLine - 1].Trim())) { $blockStart = $decLine - 1 }

	$out = @()
	for ($j = 0; $j -lt $blockStart; $j++) { $out += $extLines[$j] }
	foreach ($l in $newBlock) { $out += $l }
	for ($j = $blockEnd + 1; $j -lt $extLines.Count; $j++) { $out += $extLines[$j] }

	[System.IO.File]::WriteAllText($extBsl, (($out -join "`r`n") + "`r`n"), $enc)

	if ($disputed.Count -gt 0) {
		# write version files
		$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cfe-resync\" + ($ModulePath -replace '[\\/:*?"<>|]', '_') + "." + $MethodName)
		if (-not (Test-Path $tmpRoot)) { New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null }
		[System.IO.File]::WriteAllText((Join-Path $tmpRoot "v1.bsl"), (($v1 -join "`r`n") + "`r`n"), $enc)
		[System.IO.File]::WriteAllText((Join-Path $tmpRoot "v2.bsl"), (($v2 -join "`r`n") + "`r`n"), $enc)
		[System.IO.File]::WriteAllText((Join-Path $tmpRoot "current.bsl"), (($markedBody -join "`r`n") + "`r`n"), $enc)
		$diff = @()
		$diff += "--- v1 (что было скопировано) vs v2 (новый оригинал) ---"
		foreach ($l in $v1) { if ($v2norm -notcontains (Get-Normalized $l)) { $diff += "- $l" } }
		foreach ($l in $v2) { if ($v1norm -notcontains (Get-Normalized $l)) { $diff += "+ $l" } }
		[System.IO.File]::WriteAllText((Join-Path $tmpRoot "diff.txt"), (($diff -join "`r`n") + "`r`n"), $enc)

		Write-Host "[АКТУАЛИЗИРОВАН-ЧАСТИЧНО] &ИзменениеИКонтроль(`"$MethodName`")"
		Write-Host "     Перенесено автоматически, конфликтов: $($disputed.Count) (помечены // [РЕСИНК-КОНФЛИКТ])"
		Write-Host "     Файлы-версии для анализа:"
		Write-Host "       $tmpRoot"
		Write-Host "     Проверьте конфликтные блоки и разместите их вручную."
	} else {
		Write-Host "[АКТУАЛИЗИРОВАН] &ИзменениеИКонтроль(`"$MethodName`") — тело обновлено по новому оригиналу, правки перенесены."
	}
	Write-Host "     Файл: $extBsl"
	exit 0
}

# ============================================================================
# New interceptor: compute name, build block, place (region-aware)
# ============================================================================

# Procedure name with collision handling
$candidate = "${namePrefix}$($method.Canonical)"
$taken = @($existingProcNames | ForEach-Object { $_.ToLower() })
$interceptorName = $candidate
if ($taken -contains $candidate.ToLower()) {
	if ($InterceptorType -eq "ModificationAndControl") {
		$interceptorName = "${candidate}_ИзменениеИКонтроль"
	} else {
		$interceptorName = "${candidate}_$decoratorRu"
	}
}

$core = Build-InterceptorCore $method $InterceptorType $interceptorName

# --- Region-aware placement ---
# Find innermost region in the source chain that already exists in the extension module.
$chain = $method.Chain
$reuseRegionIdx = -1     # index in chain of the region to reuse
$reuseLineIdx = -1       # line in extLines of its #Область
if ($extExists) {
	for ($c = $chain.Count - 1; $c -ge 0; $c--) {
		if ($chain[$c].Kind -eq 'region') {
			$rname = $chain[$c].Name
			for ($li = 0; $li -lt $extLines.Count; $li++) {
				if ($extLines[$li].Trim() -match ('^#Область\s+' + [regex]::Escape($rname) + '\s*$')) {
					$reuseRegionIdx = $c; $reuseLineIdx = $li; break
				}
			}
		}
		if ($reuseRegionIdx -ge 0) { break }
	}
}

if ($reuseRegionIdx -ge 0) {
	# Insert inside the existing region, before its matching #КонецОбласти.
	# Wrappers inner to the reused region are emitted around the method; outer are inherited.
	$innerChain = @()
	for ($c = $reuseRegionIdx + 1; $c -lt $chain.Count; $c++) { $innerChain += $chain[$c] }

	$block = Build-WrappedBlock $innerChain $core

	# find matching #КонецОбласти for the reused region
	$depth = 0; $closeIdx = -1
	for ($li = $reuseLineIdx; $li -lt $extLines.Count; $li++) {
		$t = $extLines[$li].Trim()
		if ($t -match '^#Область\s') { $depth++ }
		elseif ($t -match '^#КонецОбласти') { $depth--; if ($depth -eq 0) { $closeIdx = $li; break } }
	}
	if ($closeIdx -lt 0) { Write-Error "Не найден #КонецОбласти для региона (переиспользование)"; exit 1 }

	# strip trailing blank lines of the region content, then insert with air
	$lastContent = $closeIdx - 1
	while ($lastContent -ge 0 -and $extLines[$lastContent].Trim() -eq "") { $lastContent-- }
	$out = @()
	for ($j = 0; $j -le $lastContent; $j++) { $out += $extLines[$j] }
	$out += ""
	foreach ($l in $block) { $out += $l }
	$out += ""
	for ($j = $closeIdx; $j -lt $extLines.Count; $j++) { $out += $extLines[$j] }
	[System.IO.File]::WriteAllText($extBsl, (($out -join "`r`n") + "`r`n"), $enc)
	$placement = "в существующий регион '$($chain[$reuseRegionIdx].Name)'"
} else {
	# Build full wrapper chain (source order) and append (or create file).
	$block = Build-WrappedBlock $chain $core
	$blockText = ($block -join "`r`n") + "`r`n"

	$bslDir = Split-Path $extBsl -Parent
	if (-not (Test-Path $bslDir)) { New-Item -ItemType Directory -Path $bslDir -Force | Out-Null }

	if ($extExists) {
		$existing = [System.IO.File]::ReadAllText($extBsl, $enc)
		if ([string]::IsNullOrWhiteSpace($existing)) {
			# Borrowed-but-empty module (e.g. cfe-borrow form module)
			[System.IO.File]::WriteAllText($extBsl, $blockText, $enc)
			$placement = "заполнен модуль"
		} else {
			$sep = if ($existing.EndsWith("`n")) { "`r`n" } else { "`r`n`r`n" }
			[System.IO.File]::WriteAllText($extBsl, ($existing + $sep + $blockText), $enc)
			$placement = "дописан в модуль"
		}
	} else {
		[System.IO.File]::WriteAllText($extBsl, $blockText, $enc)
		$placement = "создан модуль"
	}
}

Write-Host "[OK] Перехватчик &$decoratorRu(`"$MethodName`") — $placement"
Write-Host "     Файл:       $extBsl"
Write-Host "     Процедура:  $interceptorName($($method.ParamsText -replace '\s+', ' '))"
if ($method.Context) { Write-Host "     Контекст:   $($method.Context)" }
if ($chain.Count -gt 0) {
	$chainDesc = ($chain | ForEach-Object { if ($_.Kind -eq 'region') { "Область:$($_.Name)" } else { "Если:$($_.Cond)" } }) -join " > "
	Write-Host "     Обрамление: $chainDesc"
}
