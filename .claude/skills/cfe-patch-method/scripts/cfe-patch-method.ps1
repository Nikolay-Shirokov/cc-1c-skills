# cfe-patch-method v2.5 — Source-aware method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ExtensionPath,

	[string]$ConfigPath,

	# Generation: logical name or path to .bsl. Optional in -Check/-Actualize (scope narrowing).
	[string]$ModulePath,

	[string]$MethodName,

	[ValidateSet("", "Before", "After", "Instead", "ModificationAndControl")]
	[string]$InterceptorType,

	# Batch modes over &ИзменениеИКонтроль of the extension (no generation):
	[switch]$Check,      # report drift only, no writes
	[switch]$Actualize   # actualize drifted controlled methods
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

# A "significant" line carries code: non-empty and not a whole-line comment (//).
# Blank lines and comment-only lines are cosmetic — transparent to anchor/absorption matching.
function Test-Significant {
	param([string]$normLine)
	return ($normLine -ne '' -and -not $normLine.StartsWith('//'))
}

# Project normalized lines to significant-only. Returns @{ Sig = @(values); Map = @(orig indices) }.
function Get-SignificantProjection {
	param($norm)
	$sig = @(); $map = @()
	for ($i = 0; $i -lt $norm.Count; $i++) {
		if (Test-Significant $norm[$i]) { $sig += $norm[$i]; $map += $i }
	}
	return @{ Sig = $sig; Map = $map }
}

# True if the normalized run `keys` sits in `hay` starting exactly at index `at` (contiguous, in-bounds).
# Used to detect an insert whose payload the vendor already placed at the anchor (pereneseno v osnovnuyu).
function Test-RunAt {
	param($hay, $keys, [int]$at)
	if ($keys.Count -eq 0) { return $false }
	if ($at -lt 0 -or ($at + $keys.Count) -gt $hay.Count) { return $false }
	for ($m = 0; $m -lt $keys.Count; $m++) { if ($hay[$at + $m] -ne $keys[$m]) { return $false } }
	return $true
}

# True if a deletion is already applied in v2: its before/after context lines are now adjacent
# (nothing left between them), or the missing side sits at a body boundary. $null = boundary side.
function Test-DeleteAbsorbed {
	param($v2norm, $beforeCtx, $afterCtx)
	if ($null -ne $beforeCtx -and $null -ne $afterCtx) {
		for ($i = 0; $i -lt ($v2norm.Count - 1); $i++) {
			if ($v2norm[$i] -eq $beforeCtx -and $v2norm[$i + 1] -eq $afterCtx) { return $true }
		}
		return $false
	}
	if ($null -eq $beforeCtx -and $null -ne $afterCtx) { return ($v2norm.Count -gt 0 -and $v2norm[0] -eq $afterCtx) }
	if ($null -ne $beforeCtx -and $null -eq $afterCtx) { return ($v2norm.Count -gt 0 -and $v2norm[$v2norm.Count - 1] -eq $beforeCtx) }
	return $false
}

# Exact two-sided resolution over the given array.
# Returns index to "insert after" (-1 = top of body), or $null if ambiguous/conflict.
function Resolve-InsertionPointExact {
	param($v2norm, $beforeLines, $afterLines)
	$nb = $beforeLines.Count; $na = $afterLines.Count

	# Tier A: adjacent pair (before[-1] immediately followed by after[0] in v2), widening symmetrically
	if ($nb -ge 1 -and $na -ge 1) {
		$cands = @()
		for ($k = 0; $k -lt ($v2norm.Count - 1); $k++) {
			if ($v2norm[$k] -eq $beforeLines[$nb - 1] -and $v2norm[$k + 1] -eq $afterLines[0]) { $cands += $k }
		}
		if ($cands.Count -eq 1) { return $cands[0] }
		if ($cands.Count -gt 1) {
			$w = 1
			while ($cands.Count -gt 1 -and ($w -lt $nb -or $w -lt $na)) {
				$w++
				$filtered = @()
				foreach ($k in $cands) {
					$ok = $true
					if ($w -le $nb) {
						if (($k - ($w - 1)) -lt 0 -or $v2norm[$k - ($w - 1)] -ne $beforeLines[$nb - $w]) { $ok = $false }
					}
					if ($ok -and $w -le $na) {
						if (($k + $w) -ge $v2norm.Count -or $v2norm[$k + $w] -ne $afterLines[$w - 1]) { $ok = $false }
					}
					if ($ok) { $filtered += $k }
				}
				if ($filtered.Count -eq 0) { break }
				$cands = $filtered
			}
			if ($cands.Count -eq 1) { return $cands[0] }
			return $null
		}
	}

	# Tier B: one side changed -> single-side uniqueness
	if ($nb -ge 1) {
		$bk = Find-UniqueIndex $v2norm $beforeLines[$nb - 1]
		if ($bk -ge 0) { return $bk }
	}
	if ($na -ge 1) {
		$ak = Find-UniqueIndex $v2norm $afterLines[0]
		if ($ak -ge 0) { return ($ak - 1) }
	}
	return $null
}

# Resolve where an insertion lands in v2. Exact first (comments/blanks included — keeps the insert's
# position relative to a stable comment); on failure, retry on significant lines only (transparent to
# vendor-added blanks/comments) and map back to a full-v2 index. Returns "insert after" idx or $null.
function Resolve-InsertionPoint {
	param($v2norm, $beforeLines, $afterLines)
	$k = Resolve-InsertionPointExact $v2norm $beforeLines $afterLines
	if ($null -ne $k) { return $k }
	$proj = Get-SignificantProjection $v2norm
	$bs = @($beforeLines | Where-Object { Test-Significant $_ })
	$as = @($afterLines | Where-Object { Test-Significant $_ })
	$ksig = Resolve-InsertionPointExact $proj.Sig $bs $as
	if ($null -eq $ksig) { return $null }
	if ($ksig -lt 0) { return -1 }
	return $proj.Map[$ksig]
}

# Truncate a line for compact summary output
function Get-Truncated {
	param([string]$s, [int]$n = 60)
	$t = $s.Trim()
	if ($t.Length -gt $n) { return $t.Substring(0, $n) + "…" }
	return $t
}

# Reverse of typeDirMap (plural dir -> singular type) for logical id display
$script:dirToType = @{
	"Catalogs"="Catalog"; "Documents"="Document"; "Enums"="Enum"; "CommonModules"="CommonModule"
	"Reports"="Report"; "DataProcessors"="DataProcessor"; "ExchangePlans"="ExchangePlan"
	"ChartsOfAccounts"="ChartOfAccounts"; "ChartsOfCharacteristicTypes"="ChartOfCharacteristicTypes"
	"ChartsOfCalculationTypes"="ChartOfCalculationTypes"; "BusinessProcesses"="BusinessProcess"
	"Tasks"="Task"; "InformationRegisters"="InformationRegister"
	"AccumulationRegisters"="AccumulationRegister"; "AccountingRegisters"="AccountingRegister"
	"CalculationRegisters"="CalculationRegister"
}

# Rel-path segments (relative to ExtensionPath) -> logical ModulePath (Type.Name.Module / CommonModule.Name)
function Get-ModulePathFromRel {
	param($relParts)
	$dir0 = $relParts[0]; $name = $relParts[1]
	$typ = if ($script:dirToType.ContainsKey($dir0)) { $script:dirToType[$dir0] } else { $dir0 }
	if ($dir0 -eq "CommonModules") { return "CommonModule.$name" }
	if ($relParts.Count -ge 7 -and $relParts[2] -eq "Forms") { return "$typ.$name.Form.$($relParts[3])" }
	$mod = $relParts[$relParts.Count - 1]
	if ($mod.EndsWith(".bsl")) { $mod = $mod.Substring(0, $mod.Length - 4) }
	return "$typ.$name.$mod"
}

function Get-RelPartsUnder {
	param([string]$root, [string]$fullPath)
	$r = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
	$f = [IO.Path]::GetFullPath($fullPath)
	$rel = $f.Substring($r.Length).TrimStart('\', '/')
	return (($rel -replace '\\', '/').Split('/') | Where-Object { $_ -ne '' })
}

function Get-ResyncConflictReason {
	param($disputed)
	$kinds = @($disputed | ForEach-Object { $_.Kind } | Select-Object -Unique)
	$parts = @()
	if ($kinds -contains 'insert') { $parts += 'якорь вставки изменён' }
	if ($kinds -contains 'delete') { $parts += 'удаляемое исчезло' }
	return ($parts -join '; ')
}

# Write per-method conflict folder: conflict.md + base/local/remote
function Write-ConflictFolder {
	param($folder, $methodId, $extBsl, $existingName, $method, $v1, $markedBody, $v2, $v1norm, $v2norm, $disputed, $enc)
	if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
	[IO.File]::WriteAllText((Join-Path $folder 'base.bsl'), (($v1 -join "`r`n") + "`r`n"), $enc)
	[IO.File]::WriteAllText((Join-Path $folder 'local.bsl'), (($markedBody -join "`r`n") + "`r`n"), $enc)
	[IO.File]::WriteAllText((Join-Path $folder 'remote.bsl'), (($v2 -join "`r`n") + "`r`n"), $enc)
	$md = @()
	$md += "# $methodId"
	$md += "Править: $extBsl"
	$md += "Метод:   $existingName (&ИзменениеИКонтроль(`"$($method.Canonical)`"))"
	$md += "Причина: $(Get-ResyncConflictReason $disputed)"
	$md += ""
	$md += "## Не размещено — перенести вручную"
	$cn = 0
	foreach ($d in $disputed) {
		$cn++
		$md += ""
		if ($d.Kind -eq 'insert') {
			$md += "### Конфликт №$cn — вставка"
			$md += "Как блок стоял в вашей версии (local):"
			if ($d.Before -and $d.Before.Count -gt 0) { foreach ($l in $d.Before) { $md += $l } }
			$md += "#Вставка"; foreach ($l in $d.Lines) { $md += $l }; $md += "#КонецВставки"
			if ($d.After -and $d.After.Count -gt 0) { foreach ($l in $d.After) { $md += $l } }
			$md += ""
			$md += "Якорь (строки вокруг #Вставка) изменился/исчез в новом оригинале — блок не лёг автоматически (см. дифф base→remote ниже)."
			$md += "В модуле расширения блок припаркован в конце метода под меткой // [РЕСИНК-КОНФЛИКТ №$cn] — найди по ней."
			$md += "Куда переносить: если якорного кода в новом методе больше нет — он, вероятно, вынесен/отрефакторен (ищите в диффе новый вызов/процедуру). Размести адаптацию по смыслу: например пост-обработкой после нового вызова, либо в заимствованной процедуре, куда переехал код. При правке файла сохрани кодировку (UTF-8 с BOM)."
		} else {
			$md += "### Конфликт №$cn — удаление"
			$md += "Строки для удаления не найдены в новом оригинале (изменились/исчезли):"
			foreach ($l in $d.Lines) { $md += "  - $($l.Trim())" }
			$md += "В модуле расширения помечено меткой // [РЕСИНК-КОНФЛИКТ №$cn]."
		}
	}
	$md += ""
	$md += "## Дифф base→remote (что изменилось в оригинале)"
	foreach ($l in $v1) { if ($v2norm -notcontains (Get-Normalized $l)) { $md += "- $l" } }
	foreach ($l in $v2) { if ($v1norm -notcontains (Get-Normalized $l)) { $md += "+ $l" } }
	$md += ""
	$md += "Рядом: base.bsl / local.bsl / remote.bsl"
	[IO.File]::WriteAllText((Join-Path $folder 'conflict.md'), (($md -join "`r`n") + "`r`n"), $enc)
}

# Resync one &ИзменениеИКонтроль interceptor. Returns status hashtable.
# ReportOnly: classify without writing. Otherwise: apply to module (+ conflict folder on disputes).
function Invoke-Resync {
	param($extBsl, $extLines, $dup, $method, [string]$logicalModule, [string]$conflictFolder, [switch]$ReportOnly, $enc)

	$methodId = "$logicalModule.$($method.Canonical)"
	$decLine = $dup.Line
	$sigLineIdx = $decLine + 1
	if ($sigLineIdx -ge $extLines.Count -or $extLines[$sigLineIdx] -notmatch '^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(') {
		return @{ Id = $methodId; Status = 'ОШИБКА'; ExtBsl = $extBsl; Reason = 'не разобрать сигнатуру перехватчика' }
	}
	$existingName = $Matches[1]
	$sig = Read-Signature $extLines $sigLineIdx
	if (-not $sig) { return @{ Id = $methodId; Status = 'ОШИБКА'; ExtBsl = $extBsl; Reason = 'не разобрать сигнатуру' } }
	$sigEnd = $sig.EndLineIdx
	$isFunc = ($extLines[$sigLineIdx] -imatch '^\s*(?:Асинх\s+)?Функция\b')
	$endRe = if ($isFunc) { '^\s*КонецФункции\b' } else { '^\s*КонецПроцедуры\b' }
	$blockEnd = -1
	for ($j = $sigEnd + 1; $j -lt $extLines.Count; $j++) { if ($extLines[$j] -imatch $endRe) { $blockEnd = $j; break } }
	if ($blockEnd -lt 0) { return @{ Id = $methodId; Status = 'ОШИБКА'; ExtBsl = $extBsl; Reason = 'не найден конец перехватчика' } }

	$markedBody = @()
	for ($j = $sigEnd + 1; $j -lt $blockEnd; $j++) { $markedBody += $extLines[$j] }

	$parsed = Parse-MarkedBody $markedBody
	$v1 = $parsed.V1
	$ops = $parsed.Ops
	$v2 = $method.BodyLines
	$v1norm = @($v1 | ForEach-Object { Get-Normalized $_ })
	$v2norm = @($v2 | ForEach-Object { Get-Normalized $_ })

	if (($v1norm -join "`n") -eq ($v2norm -join "`n")) {
		return @{ Id = $methodId; Status = 'АКТУАЛЕН'; ExtBsl = $extBsl }
	}

	$insertTop = @(); $insertAfter = @{}; $delStart = @{}; $delEnd = @{}; $disputed = @(); $transferred = @(); $absorbed = @(); $absorbedNotes = @()
	$v2proj = Get-SignificantProjection $v2norm
	foreach ($op in $ops) {
		if ($op.Kind -eq 'insert') {
			$beforeLines = @()
			if ($op.After -ge 0) { $bs = [Math]::Max(0, $op.After - 2); for ($m = $bs; $m -le $op.After; $m++) { $beforeLines += $v1norm[$m] } }
			$afterLines = @()
			$ae = [Math]::Min($v1norm.Count - 1, $op.After + 3)
			for ($m = $op.After + 1; $m -le $ae; $m++) { $afterLines += $v1norm[$m] }
			$k = Resolve-InsertionPoint $v2norm $beforeLines $afterLines
			# Payload already in the new original -> change carried into the main config.
			# Match on significant lines only, so vendor-added blanks/comments don't hide it.
			$payloadSig = @(($op.Lines | ForEach-Object { Get-Normalized $_ }) | Where-Object { Test-Significant $_ })
			$isAbsorbed = $false
			if ($payloadSig.Count -gt 0) {
				if ($null -eq $k) { $isAbsorbed = (Find-UniqueRun $v2proj.Sig $payloadSig) -ge 0 }
				else { $sigStart = @($v2proj.Map | Where-Object { $_ -le $k }).Count; $isAbsorbed = Test-RunAt $v2proj.Sig $payloadSig $sigStart }
			}
			if ($isAbsorbed) {
				$absorbed += @{ Kind = 'insert' }
				foreach ($pl in $op.Lines) { if ((Get-Normalized $pl).StartsWith('//')) { $absorbedNotes += $pl.Trim() } }
			}
			elseif ($null -eq $k) {
				$dbefore = @(); if ($op.After -ge 0) { $bz = [Math]::Max(0, $op.After - 2); for ($z = $bz; $z -le $op.After; $z++) { $dbefore += $v1[$z] } }
				$dafter = @(); $az = [Math]::Min($v1.Count - 1, $op.After + 3); for ($z = $op.After + 1; $z -le $az; $z++) { $dafter += $v1[$z] }
				$disputed += @{ Kind = 'insert'; Lines = $op.Lines; Before = $dbefore; After = $dafter }
			}
			elseif ($k -lt 0) { $insertTop += ,$op.Lines; $transferred += @{ Kind = 'insert' } }
			else { if (-not $insertAfter.ContainsKey($k)) { $insertAfter[$k] = @() }; $insertAfter[$k] += ,$op.Lines; $transferred += @{ Kind = 'insert' } }
		} else {
			$keys = @(); for ($m = $op.Start; $m -le $op.End; $m++) { $keys += $v1norm[$m] }
			$p = Find-UniqueRun $v2norm $keys
			if ($p -ge 0) { $delStart[$p] = $true; $delEnd[$p + $keys.Count - 1] = $true; $transferred += @{ Kind = 'delete' } }
			else {
				# Nearest significant neighbours around the deleted block; adjacency in the significant
				# projection means the block is already cut (blanks/comments left behind don't matter).
				$delBeforeCtx = $null; for ($z = $op.Start - 1; $z -ge 0; $z--) { if (Test-Significant $v1norm[$z]) { $delBeforeCtx = $v1norm[$z]; break } }
				$delAfterCtx = $null; for ($z = $op.End + 1; $z -lt $v1norm.Count; $z++) { if (Test-Significant $v1norm[$z]) { $delAfterCtx = $v1norm[$z]; break } }
				if (Test-DeleteAbsorbed $v2proj.Sig $delBeforeCtx $delAfterCtx) { $absorbed += @{ Kind = 'delete' } }
				else { $disputed += @{ Kind = 'delete'; Lines = $op.Lines } }
			}
		}
	}

	if ($ReportOnly) {
		$st = if ($disputed.Count -gt 0) { 'КОНФЛИКТ' } elseif ($transferred.Count -eq 0 -and $absorbed.Count -gt 0) { 'ПЕРЕНЕСЕНО В ОСНОВНУЮ' } else { 'ДРЕЙФ' }
		$rsn = if ($disputed.Count -gt 0) { Get-ResyncConflictReason $disputed } elseif ($st -eq 'ПЕРЕНЕСЕНО В ОСНОВНУЮ') { 'все правки уже в основной конфигурации' } else { '' }
		return @{ Id = $methodId; Status = $st; ExtBsl = $extBsl; Transferred = $transferred.Count; Absorbed = $absorbed.Count; Disputed = $disputed.Count; Reason = $rsn; AbsorbedNotes = $absorbedNotes }
	}

	# assemble new marked body
	$newBody = @()
	foreach ($blk in $insertTop) { $newBody += "#Вставка"; foreach ($l in $blk) { $newBody += $l }; $newBody += "#КонецВставки" }
	for ($k = 0; $k -lt $v2.Count; $k++) {
		if ($delStart.ContainsKey($k)) { $newBody += "#Удаление" }
		$newBody += $v2[$k]
		if ($delEnd.ContainsKey($k)) { $newBody += "#КонецУдаления" }
		if ($insertAfter.ContainsKey($k)) { foreach ($blk in $insertAfter[$k]) { $newBody += "#Вставка"; foreach ($l in $blk) { $newBody += $l }; $newBody += "#КонецВставки" } }
	}
	if ($disputed.Count -gt 0) {
		$newBody += "`t// [РЕСИНК-КОНФЛИКТ] блоки ниже не легли автоматически — перенесите вручную (по № см. conflict.md / index.md в merge-воркспейсе, путь в выводе)."
		$cn = 0
		foreach ($d in $disputed) {
			$cn++
			if ($d.Kind -eq 'insert') {
				$newBody += "`t// [РЕСИНК-КОНФЛИКТ №$cn] вставка — исходный якорь изменён в новом оригинале."
				$newBody += "#Вставка"; foreach ($l in $d.Lines) { $newBody += $l }; $newBody += "#КонецВставки"
			}
			else {
				$newBody += "`t// [РЕСИНК-КОНФЛИКТ №$cn] удаление — строки не найдены в новом оригинале:"
				foreach ($l in $d.Lines) { $newBody += ("`t// " + $l.Trim()) }
			}
		}
	}
	$asyncPrefix = if ($method.IsAsync) { "Асинх " } else { "" }
	$keyword = if ($method.IsFunction) { "Функция" } else { "Процедура" }
	$endKeyword = if ($method.IsFunction) { "КонецФункции" } else { "КонецПроцедуры" }
	$newBlock = @()
	if ($method.Context) { $newBlock += $method.Context }
	$newBlock += "&ИзменениеИКонтроль(`"$($method.Canonical)`")"
	$newBlock += "$asyncPrefix$keyword $existingName($($method.ParamsText))"
	$newBlock += $newBody
	$newBlock += $endKeyword

	$blockStart = $decLine
	if ($decLine -ge 1 -and (Test-ContextDirective $extLines[$decLine - 1].Trim())) { $blockStart = $decLine - 1 }
	$out = @()
	for ($j = 0; $j -lt $blockStart; $j++) { $out += $extLines[$j] }
	foreach ($l in $newBlock) { $out += $l }
	for ($j = $blockEnd + 1; $j -lt $extLines.Count; $j++) { $out += $extLines[$j] }
	[IO.File]::WriteAllText($extBsl, (($out -join "`r`n") + "`r`n"), $enc)

	$conflictDir = $null
	if ($disputed.Count -gt 0) {
		$conflictDir = $conflictFolder
		Write-ConflictFolder $conflictFolder $methodId $extBsl $existingName $method $v1 $markedBody $v2 $v1norm $v2norm $disputed $enc
	}
	$status = if ($disputed.Count -gt 0) { 'ЧАСТИЧНО' } elseif ($transferred.Count -eq 0 -and $absorbed.Count -gt 0) { 'ПЕРЕНЕСЕНО В ОСНОВНУЮ' } else { 'АКТУАЛИЗИРОВАН' }
	$rsn = if ($disputed.Count -gt 0) { Get-ResyncConflictReason $disputed } elseif ($status -eq 'ПЕРЕНЕСЕНО В ОСНОВНУЮ') { 'все правки уже в основной конфигурации — перехватчик можно удалить' } else { '' }
	return @{ Id = $methodId; Status = $status; ExtBsl = $extBsl; Transferred = $transferred.Count; Absorbed = $absorbed.Count; Disputed = $disputed.Count; ConflictDir = $conflictDir; Reason = $rsn; AbsorbedNotes = $absorbedNotes }
}

# Write run-root index.md (only if there are conflicts). Returns run-root or $null.
function Write-ResyncIndex {
	param($runRoot, $results, [string]$extName, [string]$configPath, [string]$verb, $enc)
	$conflicts = @($results | Where-Object { $_.Status -eq 'ЧАСТИЧНО' })
	if ($conflicts.Count -eq 0) { return $null }
	if (-not (Test-Path $runRoot)) { New-Item -ItemType Directory -Path $runRoot -Force | Out-Null }
	$total = $results.Count
	$actual = @($results | Where-Object { $_.Status -eq 'АКТУАЛЕН' }).Count
	$upd = @($results | Where-Object { $_.Status -eq 'АКТУАЛИЗИРОВАН' }).Count
	$lines = @()
	$lines += "[$verb] $extName -> $configPath"
	$lines += "Итог: $actual/$total актуальны · актуализировано: $upd · конфликтов: $($conflicts.Count)"
	$lines += ""
	$lines += "Конфликты — править .bsl расширения:"
	foreach ($c in $conflicts) {
		$lines += "  ЧАСТИЧНО  $($c.Id)"
		$lines += "            -> $($c.ExtBsl)   ($($c.Reason))"
	}
	[IO.File]::WriteAllText((Join-Path $runRoot 'index.md'), (($lines -join "`r`n") + "`r`n"), $enc)
	return $runRoot
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
$extNameNode = if ($propsNode) { $propsNode.SelectSingleNode("md:Name", $cfgNs) } else { $null }
$extName = if ($extNameNode -and $extNameNode.InnerText) { $extNameNode.InnerText } else { "Расширение" }

# ============================================================================
# Batch modes: -Check / -Actualize over &ИзменениеИКонтроль of the extension
# ============================================================================
if ($Check -or $Actualize) {
	if ($Check -and $Actualize) { Write-Error "Укажите либо -Check, либо -Actualize, не оба."; exit 1 }
	if ([string]::IsNullOrEmpty($ConfigPath)) { Write-Error "Для -Check/-Actualize нужен -ConfigPath (сверка с исходником)."; exit 1 }
	if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath = Join-Path (Get-Location).Path $ConfigPath }
	if (Test-Path $ConfigPath -PathType Leaf) { $ConfigPath = Split-Path $ConfigPath -Parent }
	if (-not (Test-Path (Join-Path $ConfigPath "Configuration.xml"))) { Write-Error "Configuration.xml не найден в конфигурации-источнике: $ConfigPath"; exit 1 }

	$enc = New-Object System.Text.UTF8Encoding($true)
	$reportOnly = [bool]$Check
	$verb = if ($Check) { "КОНТРОЛЬ" } else { "АКТУАЛИЗАЦИЯ" }

	# target .bsl set: -ModulePath → один модуль; иначе — все .bsl расширения
	$targetBsls = @()
	if (-not [string]::IsNullOrEmpty($ModulePath)) {
		$relParts = Get-ModuleRelPath $ModulePath
		$mb = $ExtensionPath; foreach ($p in $relParts) { $mb = Join-Path $mb $p }
		if (Test-Path $mb) { $targetBsls += $mb }
	} else {
		$targetBsls = @(Get-ChildItem -Path $ExtensionPath -Recurse -Filter *.bsl -File | ForEach-Object { $_.FullName })
	}

	$runRoot = Join-Path ([IO.Path]::GetTempPath()) (Join-Path "cfe-resync" ($extName -replace '[\\/:*?"<>|]', '_'))
	if ($Actualize -and (Test-Path $runRoot)) { Remove-Item $runRoot -Recurse -Force -ErrorAction SilentlyContinue }

	$results = @()
	foreach ($tb in $targetBsls) {
		$scan = @([IO.File]::ReadAllLines($tb, [Text.Encoding]::UTF8))
		$mnames = @(Get-Interceptors $scan | Where-Object { $_.Type -eq 'ИзменениеИКонтроль' } | ForEach-Object { $_.Method })
		if (-not [string]::IsNullOrEmpty($MethodName)) { $mnames = @($mnames | Where-Object { $_ -ieq $MethodName }) }
		$mnames = @($mnames | Select-Object -Unique)
		if ($mnames.Count -eq 0) { continue }
		$rel = Get-RelPartsUnder $ExtensionPath $tb
		$logicalModule = Get-ModulePathFromRel $rel
		$srcBsl = $ConfigPath; foreach ($p in $rel) { $srcBsl = Join-Path $srcBsl $p }
		$relJoined = ($rel -join '\') -replace '\.bsl$', ''
		foreach ($mname in $mnames) {
			$mid = "$logicalModule.$mname"
			if (-not (Test-Path $srcBsl)) { $results += @{ Id = $mid; Status = 'ИСТОЧНИК-НЕ-НАЙДЕН'; ExtBsl = $tb }; continue }
			$srcL = [IO.File]::ReadAllLines($srcBsl, [Text.Encoding]::UTF8)
			$m = Extract-Method $srcL $mname
			if (-not $m) { $results += @{ Id = $mid; Status = 'МЕТОД-ИСЧЕЗ'; ExtBsl = $tb }; continue }
			# fresh read per method (writes shift line numbers)
			$tbLines = @([IO.File]::ReadAllLines($tb, [Text.Encoding]::UTF8))
			$ic = @(Get-Interceptors $tbLines | Where-Object { $_.Type -eq 'ИзменениеИКонтроль' -and $_.Method -ieq $mname })[0]
			if (-not $ic) { continue }
			$folder = Join-Path $runRoot (Join-Path $relJoined $m.Canonical)
			$results += (Invoke-Resync $tb $tbLines $ic $m $logicalModule $folder -ReportOnly:$reportOnly $enc)
		}
	}

	# --- report ---
	$total = $results.Count
	$actual = @($results | Where-Object { $_.Status -eq 'АКТУАЛЕН' }).Count
	Write-Host "[$verb] $extName -> $ConfigPath   (на контроле: $total)"
	$listed = @($results | Where-Object { $_.Status -ne 'АКТУАЛЕН' })
	foreach ($p in $listed) {
		$line = "  {0,-22} {1}" -f $p.Status, $p.Id
		if ($p.Reason) { $line += "   $($p.Reason)" }
		Write-Host $line
		if ($p.AbsorbedNotes) { foreach ($n in $p.AbsorbedNotes) { Write-Host "     ⚠ комментарий не перенесён (код в основной конфигурации): $n" } }
	}
	$transf = @($results | Where-Object { $_.Status -eq 'ПЕРЕНЕСЕНО В ОСНОВНУЮ' }).Count
	if ($Check) {
		$drift = @($results | Where-Object { $_.Status -eq 'ДРЕЙФ' }).Count
		$confl = @($results | Where-Object { $_.Status -eq 'КОНФЛИКТ' }).Count
		$gone = @($results | Where-Object { $_.Status -in @('МЕТОД-ИСЧЕЗ', 'ИСТОЧНИК-НЕ-НАЙДЕН') }).Count
		Write-Host "Итог: $actual/$total актуальны · дрейф: $drift · конфликтов: $confl · перенесено в основную: $transf · внимания: $gone"
		if (($drift + $confl + $gone) -gt 0) { Write-Host "Починить: /cfe-patch-method -Actualize -ExtensionPath $ExtensionPath -ConfigPath $ConfigPath"; exit 1 }
		elseif ($transf -gt 0) { Write-Host "Перенесённые в основную конфигурацию правки подчистит: /cfe-patch-method -Actualize -ExtensionPath $ExtensionPath -ConfigPath $ConfigPath"; exit 0 }
		else { exit 0 }
	} else {
		$upd = @($results | Where-Object { $_.Status -eq 'АКТУАЛИЗИРОВАН' }).Count
		$part = @($results | Where-Object { $_.Status -eq 'ЧАСТИЧНО' }).Count
		Write-Host "Итог: $actual/$total актуальны · актуализировано: $upd · частично: $part · перенесено в основную: $transf"
		$idx = Write-ResyncIndex $runRoot $results $extName $ConfigPath $verb $enc
		if ($idx) { Write-Host "Merge-воркспейс конфликтов (см. index.md): $idx" }
		exit 0
	}
}

# --- Generation mode: require ModulePath + MethodName + InterceptorType ---
if ([string]::IsNullOrEmpty($ModulePath) -or [string]::IsNullOrEmpty($MethodName) -or [string]::IsNullOrEmpty($InterceptorType)) {
	Write-Error "Нужны -ModulePath, -MethodName, -InterceptorType (генерация перехватчика). Для проверки/актуализации контролируемых методов используйте -Check или -Actualize."
	exit 1
}

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
	# ---- RESYNC (&ИзменениеИКонтроль) — via Invoke-Resync ----
	$rel = Get-RelPartsUnder $ExtensionPath $extBsl
	$logicalModule = Get-ModulePathFromRel $rel
	$relJoined = ($rel -join '') -replace '.bsl$', ''
	$runRoot = Join-Path ([IO.Path]::GetTempPath()) (Join-Path "cfe-resync" ($extName -replace '[\/:*?"<>|]', '_'))
	$folder = Join-Path $runRoot (Join-Path $relJoined $method.Canonical)
	$res = Invoke-Resync $extBsl $extLines $dup $method $logicalModule $folder $enc
	switch ($res.Status) {
		'АКТУАЛЕН' { Write-Host "[АКТУАЛЕН] &ИзменениеИКонтроль(`"$MethodName`") — оригинал не менялся, изменений нет." }
		'АКТУАЛИЗИРОВАН' {
			$msg = "[АКТУАЛИЗИРОВАН] &ИзменениеИКонтроль(`"$MethodName`") — тело обновлено, правок сохранено: $($res.Transferred)"
			if ($res.Absorbed -gt 0) { $msg += ", перенесено в основную конфигурацию: $($res.Absorbed)" }
			Write-Host $msg
		}
		'ПЕРЕНЕСЕНО В ОСНОВНУЮ' {
			Write-Host "[ПЕРЕНЕСЕНО В ОСНОВНУЮ] &ИзменениеИКонтроль(`"$MethodName`") — все правки ($($res.Absorbed)) уже в основной конфигурации, перехватчик можно удалить."
		}
		'ЧАСТИЧНО' {
			$idx = Write-ResyncIndex $runRoot @($res) $extName $ConfigPath "АКТУАЛИЗАЦИЯ" $enc
			$msg = "[АКТУАЛИЗИРОВАН-ЧАСТИЧНО] &ИзменениеИКонтроль(`"$MethodName`") — сохранено: $($res.Transferred), конфликтов: $($res.Disputed)"
			if ($res.Absorbed -gt 0) { $msg += ", перенесено в основную: $($res.Absorbed)" }
			Write-Host $msg
			Write-Host "     Конфликт помечен // [РЕСИНК-КОНФЛИКТ]. Папка метода: $($res.ConflictDir)"
			if ($idx) { Write-Host "     Индекс: $idx" }
		}
		default { Write-Host "[$($res.Status)] &ИзменениеИКонтроль(`"$MethodName`") — $($res.Reason)" }
	}
	if ($res.AbsorbedNotes) { foreach ($n in $res.AbsorbedNotes) { Write-Host "     ⚠ комментарий не перенесён (код в основной конфигурации): $n" } }
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
