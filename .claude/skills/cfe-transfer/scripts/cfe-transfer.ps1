# cfe-transfer v1.20 — Transfer of 1C configuration extension (CFE) changes into the main configuration: check and transfer
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[string]$ExtensionPath,

	[Parameter(Mandatory)]
	[string]$ConfigPath,

	[string]$Mode = "check",

	[string]$Name,

	[int]$Limit = 150,

	[int]$Offset = 0,

	[string]$Expand,

	[string]$Tag,

	[string]$OutFile
)

$ErrorActionPreference = "Stop"
trap { [Console]::Error.WriteLine("TRAP line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"); [Console]::Error.WriteLine($_.ScriptStackTrace); exit 1 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Mode ---
$Mode = $Mode.Trim().ToLower()
if (@('check', 'transfer') -notcontains $Mode) {
	Write-Error "Invalid -Mode '$Mode'. Expected: check, transfer"
	exit 1
}

# Detail budget: below it the whole report (summaries + details) is printed in one go;
# above it only summaries, and -Name opens the details of chosen objects.
$DetailBudget = 80

# Block closers and bare jumps: they match anywhere, so they neither score a heuristic match nor
# serve as a neighbour that places an insert
$script:trivialRe = '(?i)^(?:КонецЕсли|Иначе|КонецЦикла|КонецПопытки|Исключение|Возврат|Продолжить|Прервать|EndIf|Else|EndDo|EndTry|Except|Return|Continue|Break)\s*;?$'

# --- Resolve paths ---
function Resolve-InputPath([string]$p) {
	$p = $p.Trim()
	if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).ProviderPath $p }
	if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent }
	return $p
}

$mdNsUri = "http://v8.1c.ru/8.3/MDClasses"
$v8NsUri = "http://v8.1c.ru/8.1/data/core"
$xsiNsUri = "http://www.w3.org/2001/XMLSchema-instance"

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
# Two extensions may change one method: the order they go in is a person's decision
if ($Mode -eq 'transfer' -and $extDirs.Count -gt 1) { Write-Error "-Mode transfer takes one extension, got $($extDirs.Count): $($extDirs -join ', ')"; exit 1 }

$ConfigPath = Resolve-InputPath $ConfigPath
$cfgInfo = Read-ConfigurationProps $ConfigPath
if (-not $cfgInfo) { Write-Error "Config Configuration.xml not found: $(Join-Path $ConfigPath 'Configuration.xml')"; exit 1 }
if ($cfgInfo.IsExtension) { Write-Error "-ConfigPath is an extension, expected the main configuration: $ConfigPath"; exit 1 }

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

# Spelling language of a recognized keyword. English is the discriminator: a Russian keyword
# never equals an English one, so anything else is 'ru'.
function Get-BslLang {
	param([string]$word)
	$w = $word.Trim().ToLower()
	foreach ($k in @("Async", "Proc", "EndProc", "Func", "EndFunc", "Region", "If", "Insert", "Delete", "Before", "After", "Around", "Control")) {
		if ($script:bslKw.en[$k].ToLower() -eq $w) { return "en" }
	}
	return "ru"
}

# Edit marker kind at the start of a line: Insert/Delete/EndInsert/EndDelete, $null if none.
# The marker owns the start of the line only — a trailing comment does not bother the platform
# and must not bother us either.
function Get-BslMarkerKind {
	param([string]$line)
	$kw = $script:bslKw
	foreach ($k in @("EndInsert", "EndDelete", "Insert", "Delete")) {
		if ($line -match ('^\s*#(?:' + $kw.ru[$k] + '|' + $kw.en[$k] + ')\b')) { return $k }
	}
	return $null
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
	$alt = ($script:bslKw.ru.Directives + $script:bslKw.en.Directives) -join '|'
	return $trimmed -match ('^&(' + $alt + ')\s*$')
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
	param($frame, [string]$lang)
	$kwNot = $script:bslKw[$lang].Not
	$kwAnd = $script:bslKw[$lang].And
	$conds = $frame.Conds
	$n = $conds.Count
	if ($frame.InElse) {
		$parts = @()
		foreach ($c in $conds) { $parts += "$kwNot ($c)" }
		return ($parts -join " $kwAnd ")
	}
	if ($n -eq 1) { return $conds[0] }
	$parts = @()
	for ($j = 0; $j -lt ($n - 1); $j++) { $parts += "$kwNot ($($conds[$j]))" }
	$parts += $conds[$n - 1]
	return ($parts -join " $kwAnd ")
}

# Extract the enclosing wrapper chain (regions + preprocessor) at a target line.
# Returns array outer->inner of @{ Kind='region'|'if'; Name=..; Cond=.. }
function Get-EnclosingChain {
	param($lines, [int]$targetIdx, [string]$lang)
	$reRegion = '^#' + (Get-KwAlt 'Region') + '\s+(\S+)'
	$reEndRegion = '^#' + (Get-KwAlt 'EndRegion')
	$reIf = '^#' + (Get-KwAlt 'If') + '\s+(.+?)\s+' + (Get-KwAlt 'Then')
	$reElsIf = '^#' + (Get-KwAlt 'ElsIf') + '\s+(.+?)\s+' + (Get-KwAlt 'Then')
	$reElse = '^#' + (Get-KwAlt 'Else') + '(\s|$)'
	$reEndIf = '^#' + (Get-KwAlt 'EndIf')
	$stack = New-Object System.Collections.ArrayList
	for ($i = 0; $i -lt $targetIdx; $i++) {
		$t = $lines[$i].Trim()
		if ($t -match $reRegion) {
			[void]$stack.Add(@{ Kind = 'region'; Name = $Matches[1] })
		} elseif ($t -match $reEndRegion) {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'region') { $stack.RemoveAt($k); break } }
		} elseif ($t -match $reIf) {
			[void]$stack.Add(@{ Kind = 'if'; Conds = @($Matches[1].Trim()); InElse = $false })
		} elseif ($t -match $reElsIf) {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack[$k].Conds += $Matches[1].Trim(); $stack[$k].InElse = $false; break } }
		} elseif ($t -match $reElse) {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack[$k].InElse = $true; break } }
		} elseif ($t -match $reEndIf) {
			for ($k = $stack.Count - 1; $k -ge 0; $k--) { if ($stack[$k].Kind -eq 'if') { $stack.RemoveAt($k); break } }
		}
	}
	$chain = @()
	foreach ($f in $stack) {
		if ($f.Kind -eq 'region') { $chain += @{ Kind = 'region'; Name = $f.Name } }
		else { $chain += @{ Kind = 'if'; Cond = (Get-EffectiveCondition $f $lang) } }
	}
	return ,$chain
}

# Extract a method from source .bsl lines. Returns $null if not found.
function Extract-Method {
	param($lines, [string]$methodName)
	$declRe = '^\s*(' + (Get-KwAlt 'Async') + '\s+)?(' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+(' + [regex]::Escape($methodName) + ')\s*\('
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i] -imatch $declRe) {
			$isAsync = [bool]$Matches[1]
			$keyword = $Matches[2]
			$canonical = $Matches[3]
			$lang = Get-BslLang $keyword
			$isFunction = ($keyword -ieq $script:bslKw.ru.Func -or $keyword -ieq $script:bslKw.en.Func)

			$sig = Read-Signature $lines $i
			if (-not $sig) { throw "Не удалось разобрать сигнатуру метода '$methodName'" }
			$sigEnd = $sig.EndLineIdx
			$paramsText = $sig.ParamsText

			# Parameter names (for ПродолжитьВызов)
			$paramNames = @()
			if ($paramsText.Trim().Length -gt 0) {
				foreach ($seg in (Split-TopLevel $paramsText)) {
					$s = $seg.Trim() -replace ('^' + (Get-KwAlt 'Val') + '\s+'), ''
					if ($s -match '^([\w]+)') { $paramNames += $Matches[1] }
				}
			}

			# Body: from sigEnd+1 to matching Конец*
			$endRe = if ($isFunction) { '^\s*' + (Get-KwAlt 'EndFunc') + '\b' } else { '^\s*' + (Get-KwAlt 'EndProc') + '\b' }
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
			$chain = Get-EnclosingChain $lines $i $lang

			return @{
				Canonical   = $canonical
				Lang        = $lang
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

# Parse declared procedure/function names in a module
function Get-ProcNames {
	param($lines)
	$re = '^\s*(?:' + (Get-KwAlt 'Async') + '\s+)?(?:' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+([\w]+)\s*\('
	$names = @()
	foreach ($line in $lines) {
		if ($line -imatch $re) { $names += $Matches[1] }
	}
	return $names
}

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
		$kind = Get-BslMarkerKind $bodyLines[$i]
		if ($kind -eq 'Insert') {
			# Marker lines are kept verbatim: they carry the author's spelling, indent and — since
			# a tail comment is legal — the note explaining the edit. Re-emitting a bare keyword
			# would silently drop that note on -Actualize.
			$open = $bodyLines[$i]
			$ins = @()
			$i++
			while ($i -lt $bodyLines.Count -and (Get-BslMarkerKind $bodyLines[$i]) -ne 'EndInsert') { $ins += $bodyLines[$i]; $i++ }
			$close = if ($i -lt $bodyLines.Count) { $bodyLines[$i] } else { $null }
			$i++  # skip #КонецВставки
			$ops += @{ Kind = 'insert'; After = ($v1.Count - 1); Lines = $ins; Open = $open; Close = $close }
		} elseif ($kind -eq 'Delete') {
			$open = $bodyLines[$i]
			$startIdx = $v1.Count
			$i++
			$del = @()
			while ($i -lt $bodyLines.Count -and (Get-BslMarkerKind $bodyLines[$i]) -ne 'EndDelete') { $del += $bodyLines[$i]; $v1 += $bodyLines[$i]; $i++ }
			$close = if ($i -lt $bodyLines.Count) { $bodyLines[$i] } else { $null }
			$i++  # skip #КонецУдаления
			$ops += @{ Kind = 'delete'; Start = $startIdx; End = ($v1.Count - 1); Lines = $del; Open = $open; Close = $close }
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
		if ($v2norm[$k] -ceq $key) {
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
			if ($v2norm[$k + $m] -cne $keys[$m]) { $match = $false; break }
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
	for ($m = 0; $m -lt $keys.Count; $m++) { if ($hay[$at + $m] -cne $keys[$m]) { return $false } }
	return $true
}

# True if a deletion is already applied in v2: its before/after context lines now enclose exactly
# `mid` (nothing for a plain deletion, the inserted code for a replacement), or the missing side sits
# at a body boundary. $null = boundary side.
function Test-DeleteAbsorbed {
	param($v2norm, $beforeCtx, $afterCtx, $mid = @())
	$mid = @($mid)
	$n = $mid.Count
	for ($i = 0; $i -le ($v2norm.Count - $n); $i++) {
		if ($null -ne $beforeCtx) { if ($i -eq 0 -or $v2norm[$i - 1] -cne $beforeCtx) { continue } }
		elseif ($i -ne 0) { break }
		$ok = $true
		for ($m = 0; $m -lt $n; $m++) { if ($v2norm[$i + $m] -cne $mid[$m]) { $ok = $false; break } }
		if (-not $ok) { continue }
		$e = $i + $n
		if ($null -ne $afterCtx) { if ($e -lt $v2norm.Count -and $v2norm[$e] -ceq $afterCtx) { return $true } }
		elseif ($e -eq $v2norm.Count) { return $true }
	}
	return $false
}

# Edits already carried into the main configuration in place: v2 holds "line before + inserted code
# + line after" (significant lines). A deletion together with the insertions right next to it (only
# blanks/comments between) is one replacement: its context lines are no longer adjacent and the
# insert's own anchor was the deleted text, so neither edit is recognised alone. A plain insert is
# checked the same way, because the payload sitting at its spot splits its anchor and the anchor
# search may then land on a look-alike elsewhere. Returns a hashtable of op indices absorbed.
# $payloads: op index -> significant normalized lines of that insert.
function Get-AbsorbedInPlace {
	param($ops, $v1norm, $v2norm, $v2sig, $payloads)
	$ops = @($ops)
	$hit = @{}
	for ($d = 0; $d -lt $ops.Count; $d++) {
		$op = $ops[$d]
		if ($op.Kind -ne 'delete') { continue }
		# No check that the deleted lines are gone from the whole method: the new code may well
		# repeat them (a call wrapped into a condition). The contiguous run below settles it.
		$bIdx = -1; for ($z = $op.Start - 1; $z -ge 0; $z--) { if (Test-Significant $v1norm[$z]) { $bIdx = $z; break } }
		$aIdx = $v1norm.Count; for ($z = $op.End + 1; $z -lt $v1norm.Count; $z++) { if (Test-Significant $v1norm[$z]) { $aIdx = $z; break } }
		$group = @(); $mid = @()
		for ($i = 0; $i -lt $ops.Count; $i++) {
			if ($ops[$i].Kind -eq 'insert' -and $ops[$i].After -ge $bIdx -and $ops[$i].After -lt $aIdx) { $group += $i; $mid += @($payloads[$i]) }
		}
		if ($mid.Count -eq 0) { continue }
		$bCtx = if ($bIdx -ge 0) { $v1norm[$bIdx] } else { $null }
		$aCtx = if ($aIdx -lt $v1norm.Count) { $v1norm[$aIdx] } else { $null }
		if (Test-DeleteAbsorbed $v2sig $bCtx $aCtx $mid) { $hit[$d] = $true; foreach ($i in $group) { $hit[$i] = $true } }
	}
	for ($i = 0; $i -lt $ops.Count; $i++) {
		$op = $ops[$i]
		if ($op.Kind -ne 'insert' -or $hit.ContainsKey($i)) { continue }
		$mid = @($payloads[$i])
		if ($mid.Count -eq 0) { continue }
		$bCtx = $null; for ($z = $op.After; $z -ge 0; $z--) { if (Test-Significant $v1norm[$z]) { $bCtx = $v1norm[$z]; break } }
		$aCtx = $null; for ($z = $op.After + 1; $z -lt $v1norm.Count; $z++) { if (Test-Significant $v1norm[$z]) { $aCtx = $v1norm[$z]; break } }
		if (Test-DeleteAbsorbed $v2sig $bCtx $aCtx $mid) { $hit[$i] = $true }
	}
	return $hit
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
			if ($v2norm[$k] -ceq $beforeLines[$nb - 1] -and $v2norm[$k + 1] -ceq $afterLines[0]) { $cands += $k }
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
						if (($k - ($w - 1)) -lt 0 -or $v2norm[$k - ($w - 1)] -cne $beforeLines[$nb - $w]) { $ok = $false }
					}
					if ($ok -and $w -le $na) {
						if (($k + $w) -ge $v2norm.Count -or $v2norm[$k + $w] -cne $afterLines[$w - 1]) { $ok = $false }
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

# Name lookup: the exact name first, then the name without the extension prefix
function Find-NameIn($names, [string]$name, [string]$prefix) {
	foreach ($c in $names) { if ($c -ieq $name) { return $c } }
	$s = Get-NameKey $name $prefix
	foreach ($c in $names) { if ((Get-NameKey $c $prefix) -ieq $s) { return $c } }
	return $null
}

# All names that may stand for $name: the same name first, then those equal without the prefixes
function Find-NamesIn($names, [string]$name, [string]$prefix) {
	$res = @()
	foreach ($c in $names) { if ($c -ieq $name) { $res += $c } }
	$s = Get-NameKey $name $prefix
	foreach ($c in $names) { if ($c -ine $name -and (Get-NameKey $c $prefix) -ieq $s) { $res += $c } }
	return $res
}

# A name compared without the extension prefix and, when the project has them, without the
# development prefixes: the transfer may give an own name either way (see Get-TargetName)
function Get-NameKey([string]$name, [string]$prefix) {
	$t = Remove-ExtPrefix $name $prefix
	if ($script:devRe) { $t = $script:devRe.Replace($t, '') }
	return $t
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

# A configuration file by its relative path: one spelling for every map and edit pool keyed by it, whatever
# the spelling the caller's Join-Path produced
function Get-CfgPath([string]$rel) { return [System.IO.Path]::GetFullPath((Join-Path $ConfigPath $rel)) }

function Read-BslLines([string]$path) {
	if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
	return ,([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8))
}

function Get-MethodSafe($lines, [string]$methodName) {
	if ($null -eq $lines -or [string]::IsNullOrEmpty($methodName)) { return $null }
	try { return (Extract-Method $lines $methodName) } catch { return $null }
}

# Lexical spans cover the original text, including multiline literals and doubled quotes.
# Offsets are used for edits; formatting never comes from comparison keys.
$script:bslLiteralRe = '"(?:""|[^"\r\n])*(?:\r?\n[\t ]*(?:\|(?:""|[^"\r\n])*|//[^\r\n]*|(?=\r?\n|$)))*(?:"|(?=\r?\n|$))'
function Get-BslTokens($lines) {
	$text = @($lines) -join "`n"
	$rx = '//[^\r\n]*|' + $script:bslLiteralRe + '|\w+|\s+|[^\w\s]'
	foreach ($m in [regex]::Matches($text, $rx)) {
		$v = $m.Value
		$kind = if ($v.StartsWith('//')) { 'comment' } elseif ($v.StartsWith('"') -and $v.Length -ge 2 -and $v.EndsWith('"')) { 'string' } elseif ($v.StartsWith('"')) { 'fragment' } elseif ($v -match '^\w+$') { 'word' } else { 'punct' }
		@{ Kind = $kind; Value = $v; Start = $m.Index; Length = $m.Length }
	}
}

function Get-CodeKey([string]$line, [string]$prefix) {
	return [string](@(Get-CodeKeys @($line) $prefix)[0])
}

# Encode literals before the legacy case-insensitive matchers see them. Hex is invariant under
# case folding and whitespace normalization, so differing literal bytes cannot compare equal.
function Get-CodeKeys($lines, [string]$prefix, [switch]$Significant, $params = $null) {
	if ($params.Count -gt 0) { $lines = Protect-BslParameterMembers $lines $params }
	$src = @($lines) -join "`n"
	$sb = New-Object System.Text.StringBuilder; $pos2 = 0; $line2 = 0; $comments2 = @{}
	foreach ($m2 in [regex]::Matches($src, ('//[^\r\n]*|' + $script:bslLiteralRe))) {
		$segment2 = $src.Substring($pos2, $m2.Index - $pos2)
		$line2 += ([regex]::Matches($segment2, "`n")).Count
		$code2 = Remove-ExtPrefix $segment2 $prefix
		if ($script:devRe) { $code2 = $script:devRe.Replace($code2, '') }
		[void]$sb.Append($code2)
		if ($m2.Value.StartsWith('//')) {
			$lineStart2 = $src.LastIndexOf("`n", $m2.Index) + 1
			if ($src.Substring($lineStart2, $m2.Index - $lineStart2).Trim() -eq '') { $comments2[$line2] = $m2.Value.Substring(2) }
			$code2 = Remove-ExtPrefix $m2.Value $prefix
			if ($script:devRe) { $code2 = $script:devRe.Replace($code2, '') }
			[void]$sb.Append($code2)
		} else {
			[void]$sb.Append('"'); $first2 = $true
			foreach ($part2 in ($m2.Value -split "`n", 0, 'SimpleMatch')) {
				if (-not $first2) {
					[void]$sb.Append("`n")
					# Between |continuations, a // line is a BSL source comment, not string data.
					if ($part2.TrimStart().StartsWith('//')) {
						$arch2 = $part2.TrimStart().Substring(2).TrimStart()
						if ($arch2.StartsWith('|')) {
							$ak2 = @(Get-CodeKeys @('"', $arch2, '|"') $prefix)
							[void]$sb.Append('//' + $ak2[1])
						} else { [void]$sb.Append($part2.Trim()) }
						continue
					}
					if ($part2.Trim() -eq '') { continue }
					$part2 = $part2 -replace '^[\t ]+(?=\|)', ''
				}
				$hex2 = [BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($part2)).Replace('-', '')
				[void]$sb.Append('~'); [void]$sb.Append($hex2); $first2 = $false
			}
			[void]$sb.Append('"')
		}
		$pos2 = $m2.Index + $m2.Length
		$line2 += ([regex]::Matches($m2.Value, "`n")).Count
	}
	$code2 = Remove-ExtPrefix $src.Substring($pos2) $prefix
	if ($script:devRe) { $code2 = $script:devRe.Replace($code2, '') }
	[void]$sb.Append($code2)
	$keys2 = @($sb.ToString() -split "`n", 0, 'SimpleMatch')
	# A removed block may remain as //code. Its literals need the same keys as live code;
	# lex a whole comment run so a multiline removed literal keeps its state as well.
	for ($i2 = 0; $i2 -lt $keys2.Count; $i2++) {
		if (-not $comments2.ContainsKey($i2)) { continue }
		$start2 = $i2; $archive2 = @()
		while ($i2 -lt $keys2.Count -and $comments2.ContainsKey($i2)) { $archive2 += $comments2[$i2]; $i2++ }
		$archiveKeys2 = @(Get-CodeKeys $archive2 $prefix -params $params)
		for ($j2 = $start2; $j2 -lt $i2; $j2++) { $keys2[$j2] = '//' + $archiveKeys2[$j2 - $start2] }
		$i2--
	}
	$r = New-Object 'System.Collections.Generic.List[string]'
	foreach ($l in $keys2) {
		$v = ($l -replace '\s+', ' ').Trim().ToLowerInvariant()
		if ($Significant -and -not (Test-Significant $v)) { continue }
		$r.Add($v)
	}
	return $r.ToArray()
}

# Significant lines of a body as code keys
function Get-SigLines($lines, [string]$prefix) {
	return ,@(Get-CodeKeys $lines $prefix -Significant)
}

# Only scopes dependency protection to newly exposed literal mismatches. This historical
# folding is never used to accept code as transferred; the actual comparison uses Get-SigLines.
function Test-PreviouslyFoldedBody($left, $right, [string]$prefix) {
	$signatures = @()
	foreach ($ls in @(@{ Lines = $left }, @{ Lines = $right })) {
		$keys = @()
		foreach ($l in $ls.Lines) {
			$t = Remove-ExtPrefix ([string]$l) $prefix
			if ($script:devRe) { $t = $script:devRe.Replace($t, '') }
			$t = (Get-Normalized $t).ToLowerInvariant()
			if (Test-Significant $t) { $keys += $t }
		}
		$signatures += ($keys -join "`n")
	}
	return $signatures[0] -ceq $signatures[1]
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
# Transfer of method changes
# ============================================================

# Developer's mark "not for transfer" (a workaround for an extension limitation, a one-off fix):
# a comment whose text starts with «Временно» or «Не переносить» (case and spaces ignored), the
# reason may follow. Returns the reason ('' when none) or $null when the line is not such a mark.
function Get-TempMark([string]$line) {
	$i = $line.IndexOf('//')
	if ($i -lt 0) { return $null }
	$t = $line.Substring($i).TrimStart('/').Trim()
	# The form's own mark (Get-FormTempMarks) names form items, not the method below it
	if ($t -match '^(?i)не\s*переносить\s+элементы\s+формы') { return $null }
	if ($t -match '^(?i)(?:не\s*переносить|временно)(?![\p{L}\p{Nd}_])\s*[:\-–—]?\s*(.*)$') { return $Matches[1].Trim() }
	return $null
}

# Form items kept out of the transfer: "// Не переносить элементы формы: Имя1, Имя2 — причина" among the
# comment lines the form module starts with, before its variables and methods. Lower-case name -> reason.
function Get-FormTempMarks($lines) {
	$res = @{}
	foreach ($l in @($lines)) {
		$t = ([string]$l).Trim()
		if ($t -eq '' -or $t.StartsWith('#')) { continue }
		if (-not $t.StartsWith('//')) { break }
		if ($t -match '^//+\s*(?i:не\s*переносить\s+элементы\s+формы)\s*:\s*(.+)$') {
			$body = $Matches[1]; $why = ''
			$sep = [regex]::Match($body, '\s+[—–-]\s+')
			if ($sep.Success) { $why = $body.Substring($sep.Index + $sep.Length).Trim(); $body = $body.Substring(0, $sep.Index) }
			foreach ($n in $body.Split(',')) { $n = $n.Trim(); if ($n) { $res[$n.ToLower()] = $why } }
		}
	}
	return $res
}

# Mark of a whole method: in the comment lines right above it (annotations and directives skipped)
# or in the comment lines the body starts with. -AboveOnly for &ИзменениеИКонтроль: its body is a
# copy of the original, so a comment there is the configuration's, not the developer's mark.
function Get-MethodTempMark($lines, $method, [switch]$AboveOnly) {
	for ($z = $method.DeclIdx - 1; $z -ge 0; $z--) {
		$t = $lines[$z].Trim()
		if ($t.StartsWith('&')) { continue }
		if (-not $t.StartsWith('//')) { break }
		$m = Get-TempMark $t
		if ($null -ne $m) { return $m }
	}
	if ($AboveOnly) { return $null }
	foreach ($l in $method.BodyLines) {
		$t = $l.Trim()
		if ($t -eq '') { continue }
		if (-not $t.StartsWith('//')) { break }
		$m = Get-TempMark $t
		if ($null -ne $m) { return $m }
	}
	return $null
}

# Mark of one #Вставка/#Удаление block: a tail comment on its opening marker or the comment lines
# an insert starts with (the lines of a deletion are the configuration's code, not the developer's).
function Get-BlockTempMark($op) {
	if ($op.Open) { $m = Get-TempMark $op.Open; if ($null -ne $m) { return $m } }
	if ($op.Kind -ne 'insert') { return $null }
	foreach ($l in $op.Lines) {
		$t = $l.Trim()
		if ($t -eq '') { continue }
		if (-not $t.StartsWith('//')) { break }
		$m = Get-TempMark $t
		if ($null -ne $m) { return $m }
	}
	return $null
}

function Format-TempWhy([string]$mark) { if ($mark) { return " — $mark" } else { return '' } }

# A method marked "not for transfer": still carried over -> stays TRANSFERRED with a note (a
# workaround moved into the configuration is worth a look); otherwise -> TEMPORARY.
function Set-TempMark($item, $mark, [string]$label) {
	if ($null -eq $mark -or -not $item) { return $item }
	if ($item.Status -eq 'TRANSFERRED') { $item.Text += ' (marked temporary)'; $item.Marked = $true; return $item }
	$t = New-Item2 'TEMPORARY' "$label$(Format-TempWhy $mark)" $item.Loc $item.Group
	# The plan stays: code that calls a temporary method must know it is not coming
	if ($item.Plan) { $t.Plan = $item.Plan }
	return $t
}

# Insert payload sitting right after its line before, or right before its line after, anywhere in v2
# (significant lines; $null side is not checked). Looser than the in-place check: one neighbour is
# enough and the spot need not be unique. For an insert not found at its anchor: the anchor may be
# lost (a payload repeated in the method leaves the search nothing to go on) or resolved to a
# look-alike elsewhere. Only a neighbour with content counts (see $trivialRe).
function Test-PayloadBeside($v2sig, $mid, $beforeCtx, $afterCtx) {
	# A block closer or a bare jump stands next to anything: as a neighbour it proves nothing
	if ($null -ne $beforeCtx -and $beforeCtx -match $script:trivialRe) { $beforeCtx = $null }
	if ($null -ne $afterCtx -and $afterCtx -match $script:trivialRe) { $afterCtx = $null }
	if ($null -eq $beforeCtx -and $null -eq $afterCtx) { return $false }
	$n = $mid.Count
	for ($i = 0; $i -le ($v2sig.Count - $n); $i++) {
		$ok = $true
		for ($m = 0; $m -lt $n; $m++) { if ($v2sig[$i + $m] -cne $mid[$m]) { $ok = $false; break } }
		if (-not $ok) { continue }
		if ($null -ne $beforeCtx -and $i -gt 0 -and $v2sig[$i - 1] -ceq $beforeCtx) { return $true }
		if ($null -ne $afterCtx -and ($i + $n) -lt $v2sig.Count -and $v2sig[$i + $n] -ceq $afterCtx) { return $true }
	}
	return $false
}

# How many times the run `keys` occurs in `hay` (contiguous, overlapping counted)
function Get-RunCount($hay, $keys) {
	$n = $keys.Count; $c = 0
	if ($n -eq 0) { return 0 }
	for ($i = 0; $i -le ($hay.Count - $n); $i++) {
		$ok = $true
		for ($m = 0; $m -lt $n; $m++) { if ($hay[$i + $m] -cne $keys[$m]) { $ok = $false; break } }
		if ($ok) { $c++ }
	}
	return $c
}

# Why an edit is disputed, with the line to look at: the insert's neighbour (and whether the
# configuration keeps it commented out) or the first deleted line.
function Get-DisputeReason($kind, [string]$line, [string]$key, [string]$side, $v2norm) {
	$txt = Get-Short $line 60
	if ($kind -eq 'delete') { return "deleted lines changed in config: $txt" }
	if (-not $key) { return 'insert anchor changed in config' }
	$commented = $false
	foreach ($l in $v2norm) { if ($l.StartsWith('//') -and (($l -replace '^/+\s*', '') -ceq $key)) { $commented = $true; break } }
	$how = if ($commented) { 'commented out' } else { 'changed' }
	return "line $side insert $how in config: $txt"
}

# &ИзменениеИКонтроль: each #Вставка/#Удаление is classified the way cfe-patch-method -Check does
# (absorbed = already in the main configuration, pending = still to carry over, disputed = the
# anchor or the deleted lines changed). $null when the method has no edits with code.
# A deletion carried over by commenting the lines out, at its own place: its significant lines stand in
# $v2norm as a run of // comments (blank lines and other comments — the frame, //-blank lines — between
# them allowed, code not), with the deleted block's line before right above the run or its line after
# right below it ($null: a body boundary). One neighbour is enough: the replacing code may follow the
# run. Returns the index of the run's last line in $v2norm, -1 when there is none.
function Find-CommentedRun($v2norm, $keys, $beforeCtx, $afterCtx) {
	$keys = @($keys); $v2norm = @($v2norm)
	if ($keys.Count -eq 0) { return -1 }
	$run = New-Object System.Collections.ArrayList
	$check = {
		for ($s = 0; $s -le $run.Count - $keys.Count; $s++) {
			$ok = $true
			for ($m = 0; $m -lt $keys.Count; $m++) { if ($run[$s + $m].C -cne $keys[$m]) { $ok = $false; break } }
			if (-not $ok) { continue }
			$first = $run[$s].I; $last = $run[$s + $keys.Count - 1].I
			$b = $null; for ($z = $first - 1; $z -ge 0; $z--) { if (Test-Significant $v2norm[$z]) { $b = $v2norm[$z]; break } }
			$a = $null; for ($z = $last + 1; $z -lt $v2norm.Count; $z++) { if (Test-Significant $v2norm[$z]) { $a = $v2norm[$z]; break } }
			if ($b -ceq $beforeCtx -or $a -ceq $afterCtx) { return $last }
		}
		return -1
	}
	for ($i = 0; $i -lt $v2norm.Count; $i++) {
		$l = $v2norm[$i]
		if ($l -eq '') { continue }
		if ($l.StartsWith('//')) {
			$c = ($l.Substring(2) -replace '\s+', ' ').Trim()
			if (Test-Significant $c) { [void]$run.Add(@{ C = $c; I = $i }) }
			continue
		}
		$r = & $check
		if ($r -ge 0) { return $r }
		$run.Clear()
	}
	return (& $check)
}

# Where deleted lines that occur more than once stand between the same neighbours as in the original:
# the index in $v2norm when exactly one occurrence does, else -1
function Find-RunInContext($v2norm, $v2proj, $keys, $sigKeys, $beforeCtx, $afterCtx) {
	$sig = @($v2proj.Sig); $n = @($sigKeys).Count
	if ($n -eq 0) { return -1 }
	$lead = 0; while ($lead -lt $keys.Count -and -not (Test-Significant $keys[$lead])) { $lead++ }
	$found = -1
	for ($i = 0; $i -le $sig.Count - $n; $i++) {
		if (-not (Test-RunAt $sig $sigKeys $i)) { continue }
		if ($null -ne $beforeCtx) { if ($i -eq 0 -or $sig[$i - 1] -cne $beforeCtx) { continue } } elseif ($i -ne 0) { continue }
		$e = $i + $n
		if ($null -ne $afterCtx) { if ($e -ge $sig.Count -or $sig[$e] -cne $afterCtx) { continue } } elseif ($e -ne $sig.Count) { continue }
		$at = $v2proj.Map[$i] - $lead
		if (-not (Test-RunAt $v2norm $keys $at)) { continue }
		if ($found -ge 0) { return -1 }
		$found = $at
	}
	return $found
}

function Compare-CodeSequence($left, $right) {
	if ($left.Count -ne $right.Count) { return $false }
	for ($i = 0; $i -lt $left.Count; $i++) {
		if ($left[$i] -cne $right[$i]) { return $false }
	}
	return $true
}

# Can one occurrence be removed to reproduce the shorter sequence exactly?
function Test-SequenceWithoutRun($longer, $shorter, $keys) {
	if ($keys.Count -eq 0 -or $longer.Count -ne $shorter.Count + $keys.Count) { return $false }
	$first = $shorter.Count
	while ($first -gt 0 -and $longer[$first + $keys.Count - 1] -ceq $shorter[$first - 1]) { $first-- }
	for ($i = 0; $i -le $shorter.Count; $i++) {
		if ($i -ge $first -and (Test-RunAt $longer $keys $i)) { return $true }
		if ($i -lt $shorter.Count -and $longer[$i] -cne $shorter[$i]) { break }
	}
	return $false
}

# Expected live code with just this operation undone. Keep the positions from the
# projected body so equal occurrences elsewhere do not change which run is undone.
function Get-ExpectedWithoutEdit($projection, [int]$index, $restoredKeys) {
	$range = $projection.Ranges[$index]
	$result = New-Object 'System.Collections.Generic.List[string]'
	for ($i = 0; $i -lt $range.Start; $i++) {
		if (Test-Significant $projection.Keys[$i]) { $result.Add($projection.Keys[$i]) }
	}
	foreach ($key in $restoredKeys) { $result.Add($key) }
	for ($i = $range.End; $i -lt $projection.Keys.Count; $i++) {
		if (Test-Significant $projection.Keys[$i]) { $result.Add($projection.Keys[$i]) }
	}
	return ,$result.ToArray()
}

function Get-ControlTransfer($extMethod, $cfgMethod, [string]$prefix) {
	$parsed = Parse-MarkedBody $extMethod.BodyLines
	$projection = Get-ControlProjection $extMethod.BodyLines @{} $prefix $extMethod.ParamNames
	$ops = @($parsed.Ops)
	$v1norm = @(Get-CodeKeys (Convert-BslCode $parsed.V1 @{} $extMethod.ParamNames) $prefix -params $extMethod.ParamNames)
	$v2norm = @(Get-CodeKeys $cfgMethod.BodyLines $prefix -params $cfgMethod.ParamNames)
	$v2proj = Get-SignificantProjection $v2norm
	$v1sig = @((Get-SignificantProjection $v1norm).Sig)
	$absorbed = 0; $pending = 0; $disputed = @(); $temp = 0; $tempWhy = $null; $markedDone = 0
	# Per edit, for -Mode transfer: the result and where it goes in the configuration's body
	$plan = New-Object System.Collections.ArrayList
	$payloads = @{}
	for ($oi = 0; $oi -lt $ops.Count; $oi++) {
		$ops[$oi].SourceIndex = $oi
		if ($ops[$oi].Kind -eq 'insert') { $payloads[$oi] = @($projection.PayloadKeys[$oi] | Where-Object { Test-Significant $_ }) }
	}
	$desiredSig = @($projection.Keys | Where-Object { Test-Significant $_ })
	$hasTempEdits = @($ops | Where-Object { $null -ne (Get-BlockTempMark $_) } | Select-Object -First 1).Count -gt 0
	# Whole-body agreement identifies repeated lines by their position in the sequence.
	$hasBodyChange = -not (Compare-CodeSequence $v1sig $desiredSig)
	$atOriginal = $hasBodyChange -and (Compare-CodeSequence $v1norm $v2norm)
	$atDesired = $hasBodyChange -and (Compare-CodeSequence $desiredSig $v2proj.Sig)
	$replaced = if ($atOriginal -or $atDesired) { @{} } else { Get-AbsorbedInPlace $ops $v1norm $v2norm $v2proj.Sig $payloads }
	$deleted = @{}
	foreach ($op in $ops) { if ($op.Kind -eq 'delete') { for ($m = $op.Start; $m -le $op.End; $m++) { $deleted[$m] = $true } } }
	# Lines of deletions found carried over (an insert anchored to them cannot be pending elsewhere)
	$deletedDone = @{}
	$oi = -1
	foreach ($op in $ops) {
		$oi++
		# $res: 'absorbed', 'pending' or the reason the edit is disputed
		if ($op.Kind -eq 'insert') {
			$payloadSig = @($payloads[$oi])
			# A comment-only insert carries nothing to transfer
			if ($payloadSig.Count -eq 0) { continue }
			$k = $null
			if ($atDesired) { $res = 'absorbed' }
			elseif ($atOriginal) { $k = $op.After; $res = 'pending' }
			else {
				$baseRuns = Get-RunCount $v1sig $payloadSig
				$currentRuns = Get-RunCount $v2proj.Sig $payloadSig
				$desiredRuns = if ($baseRuns -gt 0) { Get-RunCount $desiredSig $payloadSig } else { 0 }
				# An optional insertion must not raise the required count of a permanent insertion.
				if ($hasTempEdits) { $desiredRuns = [Math]::Min($desiredRuns, $baseRuns + 1) }
				$missingRepeat = $baseRuns -gt 0 -and $desiredRuns -gt $baseRuns -and $currentRuns -lt $desiredRuns
				$beforeLines = @()
				if ($op.After -ge 0) { $bs = [Math]::Max(0, $op.After - 2); for ($m = $bs; $m -le $op.After; $m++) { $beforeLines += $v1norm[$m] } }
				$afterLines = @()
				$ae = [Math]::Min($v1norm.Count - 1, $op.After + 3)
				for ($m = $op.After + 1; $m -le $ae; $m++) { $afterLines += $v1norm[$m] }
				$k = Resolve-InsertionPoint $v2norm $beforeLines $afterLines
				# The looser checks below accept the payload only as new code: the configuration has it
				# more times than the original method (an insert repeating a line next to it otherwise
				# finds that very line)
				$isNew = $currentRuns -gt $baseRuns
				if ($null -eq $k) { $isAbsorbed = $isNew -and (Find-UniqueRun $v2proj.Sig $payloadSig) -ge 0 }
				else { $sigStart = @($v2proj.Map | Where-Object { $_ -le $k }).Count; $isAbsorbed = Test-RunAt $v2proj.Sig $payloadSig $sigStart }
				# Neighbours of the insert in the edited method: deleted lines are not there
				$bIdx = -1; for ($z = $op.After; $z -ge 0; $z--) { if (-not $deleted.ContainsKey($z) -and (Test-Significant $v1norm[$z])) { $bIdx = $z; break } }
				$aIdx = -1; for ($z = $op.After + 1; $z -lt $v1norm.Count; $z++) { if (-not $deleted.ContainsKey($z) -and (Test-Significant $v1norm[$z])) { $aIdx = $z; break } }
				$bCtx = if ($bIdx -ge 0) { $v1norm[$bIdx] } else { $null }
				$aCtx = if ($aIdx -ge 0) { $v1norm[$aIdx] } else { $null }
				# Not at the anchor: the anchor found by its line after leaves the carried-over code right
				# before the spot; otherwise the payload next to a neighbour with content, anywhere
				if (-not $isAbsorbed -and $isNew -and $null -ne $k) { $isAbsorbed = Test-RunAt $v2proj.Sig $payloadSig ($sigStart - $payloadSig.Count) }
				if (-not $isAbsorbed -and $isNew) { $isAbsorbed = Test-PayloadBeside $v2proj.Sig $payloadSig $bCtx $aCtx }
				# Anchored to deleted lines whose deletion is carried over already: the spot is right after the
				# commented-out lines, with nothing but comments up to it and the insert's line after next.
				# Anywhere else the anchor is a look-alike, and code at the spot means the insert went over
				# differently.
				$freeSpot = $false
				if ($null -ne $k -and $deletedDone.ContainsKey($op.After) -and $deletedDone[$op.After] -ge 0 -and $k -ge $deletedDone[$op.After]) {
					$freeSpot = $true
					for ($z = $deletedDone[$op.After] + 1; $z -le $k; $z++) { if (Test-Significant $v2norm[$z]) { $freeSpot = $false; break } }
					$nx = $null; for ($z = $k + 1; $z -lt $v2norm.Count; $z++) { if (Test-Significant $v2norm[$z]) { $nx = $v2norm[$z]; break } }
					if ($nx -cne $aCtx) { $freeSpot = $false }
				}
				# Lines that stand anywhere (КонецЕсли;, Возврат;) prove nothing by being elsewhere
				$plain = @($payloadSig | Where-Object { $_ -notmatch $script:trivialRe }).Count -eq 0
				$wrongPosition = $false
				if ($hasBodyChange -and $baseRuns -gt 0 -and $v2proj.Sig.Count -eq $desiredSig.Count) {
					if ($ops.Count -eq 1) {
						$wrongPosition = Test-SequenceWithoutRun $v2proj.Sig $v1sig $payloadSig
					} elseif ($desiredRuns -gt $baseRuns) {
						$withoutEdit = Get-ExpectedWithoutEdit $projection $oi @()
						$wrongPosition = Test-SequenceWithoutRun $v2proj.Sig $withoutEdit $payloadSig
					}
				}
				if ($wrongPosition) {
					$res = 'repeated insertion is at a different position in config'
				}
				elseif ($isAbsorbed -or $replaced.ContainsKey($oi)) {
					$res = if ($missingRepeat) { 'repeated insertion is ambiguous in config' } else { 'absorbed' }
				}
				elseif ($null -ne $k -and $deletedDone.ContainsKey($op.After) -and -not $freeSpot) { $res = 'inserted code next to the carried-over deletion differs in config' }
				# Not at the anchor, yet the configuration has the code more times than the original: carried
				# over to another spot (other code may have come in between). Writing it would make a copy.
				elseif ($null -ne $k -and $isNew -and -not $plain) { $res = 'inserted code is in config already, elsewhere in the method' }
				elseif ($null -ne $k) { $res = 'pending' }
				elseif ($bIdx -ge 0) { $res = Get-DisputeReason 'insert' $parsed.V1[$bIdx] $bCtx 'before' $v2norm }
				elseif ($aIdx -ge 0) { $res = Get-DisputeReason 'insert' $parsed.V1[$aIdx] $aCtx 'after' $v2norm }
				else { $res = Get-DisputeReason 'insert' '' '' '' $v2norm }
			}
		} else {
			$p = -1; $cAt = -1
			$keys = @(); for ($m = $op.Start; $m -le $op.End; $m++) { $keys += $v1norm[$m] }
			$sigKeys = @($keys | Where-Object { Test-Significant $_ })
			if ($atDesired) {
				$res = 'absorbed'
				if ($sigKeys.Count -eq 0 -and $keys.Count -gt 0) {
					# The live lines agree. Look for the explicitly deleted comments only
					# between the live lines that surround their projected position.
					$liveBefore = 0
					for ($m = 0; $m -lt $projection.Ranges[$oi].Start; $m++) {
						if (Test-Significant $projection.Keys[$m]) { $liveBefore++ }
					}
					$firstGap = if ($liveBefore -gt 0) { $v2proj.Map[$liveBefore - 1] + 1 } else { 0 }
					$endGap = if ($liveBefore -lt $v2proj.Map.Count) { $v2proj.Map[$liveBefore] } else { $v2norm.Count }
					$gapKeys = @(for ($m = $firstGap; $m -lt $endGap; $m++) { $v2norm[$m] })
					$offset = Find-UniqueRun $gapKeys $keys
					if ($offset -ge 0) { $p = $firstGap + $offset; $res = 'pending' }
					elseif ((Get-RunCount $gapKeys $keys) -gt 1) { $res = 'comment-only deletion has multiple matches in config' }
				}
			}
			elseif ($atOriginal) { $p = $op.Start; $res = 'pending' }
			else {
				$delBeforeCtx = $null; for ($z = $op.Start - 1; $z -ge 0; $z--) { if (Test-Significant $v1norm[$z]) { $delBeforeCtx = $v1norm[$z]; break } }
				$delAfterCtx = $null; for ($z = $op.End + 1; $z -lt $v1norm.Count; $z++) { if (Test-Significant $v1norm[$z]) { $delAfterCtx = $v1norm[$z]; break } }
				# Deleted text that stays in the method elsewhere — moved into an insert of the method, or one
				# of its repeats — is found by the search below even once the deletion is done. Then the
				# closed-up neighbours decide, provided the configuration holds the text as many times as
				# the original would after the edits: one less, plus the inserts that carry it.
				$insRuns = 0; foreach ($pk in @($payloads.Keys)) { $insRuns += Get-RunCount @($payloads[$pk]) $sigKeys }
				$v1Runs = Get-RunCount $v1sig $sigKeys
				$currentRuns = Get-RunCount $v2proj.Sig $sigKeys
				$desiredRuns = if ($v1Runs -gt 1) { Get-RunCount $desiredSig $sigKeys } else { $v1Runs }
				if ($hasTempEdits) { $desiredRuns = [Math]::Max($desiredRuns, $v1Runs - 1) }
				$missingDeletion = $v1Runs -gt 1 -and $desiredRuns -lt $v1Runs -and $currentRuns -gt $desiredRuns
				$liveLeft = $sigKeys.Count -gt 0 -and $currentRuns -eq ($v1Runs - 1 + $insRuns)
				$stays = $liveLeft -and ($insRuns -gt 0 -or $v1Runs -gt 1)
				# Commented out at its own place, and the code left as often as after the edit: carried over.
				# Looked at first — a line the edit moves into its own insert is there as code too, and
				# deleting it would break the carried-over insert. An old comment elsewhere does not count.
				$cAt = if ($liveLeft) { Find-CommentedRun $v2norm $sigKeys $delBeforeCtx $delAfterCtx } else { -1 }
				$wrongPosition = $false
				if ($hasBodyChange -and $v1Runs -gt 1 -and $v2proj.Sig.Count -eq $desiredSig.Count) {
					if ($ops.Count -eq 1) {
						$wrongPosition = Test-SequenceWithoutRun $v1sig $v2proj.Sig $sigKeys
					} elseif ($desiredRuns -lt $v1Runs) {
						$withoutEdit = Get-ExpectedWithoutEdit $projection $oi $sigKeys
						$wrongPosition = Test-SequenceWithoutRun $withoutEdit $v2proj.Sig $sigKeys
					}
				}
				if ($wrongPosition) {
					$res = 'repeated deletion is at a different position in config'
				}
				elseif ($replaced.ContainsKey($oi) -and -not $missingDeletion) { $res = 'absorbed'; $cAt = -1 }
				elseif ($cAt -ge 0 -and -not $missingDeletion) { $res = 'absorbed' }
				elseif (-not $missingDeletion -and $stays -and (Test-DeleteAbsorbed $v2proj.Sig $delBeforeCtx $delAfterCtx)) { $res = 'absorbed' }
				elseif (($p = Find-UniqueRun $v2norm $keys) -ge 0) { $res = 'pending' }
				elseif ($v1Runs -gt 1 -and ($p = Find-RunInContext $v2norm $v2proj $keys $sigKeys $delBeforeCtx $delAfterCtx) -ge 0) { $res = 'pending' }
				else {
					$p = -1
					if (-not $missingDeletion -and (Test-DeleteAbsorbed $v2proj.Sig $delBeforeCtx $delAfterCtx)) { $res = 'absorbed' }
					else {
						$first = @($op.Lines | Where-Object { Test-Significant (Get-Normalized $_) } | Select-Object -First 1)
						$line = if ($first.Count -gt 0) { $first[0] } else { '' }
						$res = Get-DisputeReason 'delete' $line '' '' $v2norm
					}
				}
			}
		}
		# Where the carried-over deletion stands in the configuration: the last commented line, -1 unknown
		if ($op.Kind -eq 'delete' -and $res -eq 'absorbed') {
			$at = if ($replaced.ContainsKey($oi)) { -1 } else { $cAt }
			for ($m = $op.Start; $m -le $op.End; $m++) { $deletedDone[$m] = $at }
		}
		# A block marked "not for transfer" counts as temporary only while it is not in the configuration
		$mark = Get-BlockTempMark $op
		$pk = if ($op.Kind -eq 'insert') { $k } else { $p }
		if ($null -ne $mark -and $res -ne 'absorbed') {
			[void]$plan.Add(@{ Op = $op; Res = 'temp'; At = $pk })
			$temp++; if ($null -eq $tempWhy) { $tempWhy = $mark }; continue
		}
		[void]$plan.Add(@{ Op = $op; Res = $res; At = $pk })
		if ($res -eq 'absorbed') { $absorbed++; if ($null -ne $mark) { $markedDone++ } }
		elseif ($res -eq 'pending') { $pending++ }
		else { $disputed += $res }
	}
	$n = $absorbed + $pending + $disputed.Count
	if ($n -eq 0) {
		if ($temp -gt 0) { return @{ Status = 'TEMPORARY'; Count = (Get-Plural $temp 'edit'); Note = $tempWhy; Plan = $plan } }
		return $null
	}
	$count = "$absorbed/$n edits"
	if ($temp -gt 0) { $count += ", $temp temporary" }
	if ($disputed.Count -gt 0) {
		$more = if ($disputed.Count -gt 1) { " (+$($disputed.Count - 1) more)" } else { '' }
		return @{ Status = 'DIVERGED'; Count = $count; Note = "$($disputed[0])$more"; Plan = $plan }
	}
	$st = if ($absorbed -eq $n) { 'TRANSFERRED' } elseif ($absorbed -eq 0) { 'NOT_TRANSFERRED' } else { 'PARTIAL' }
	$note = if ($markedDone -gt 0) { "$markedDone marked temporary" } else { '' }
	return @{ Status = $st; Count = $count; Note = $note; Marked = ($markedDone -gt 0); Plan = $plan }
}

# &Перед/&После/&Вместо and form event interceptors: there is no marked original to compare with,
# so the interceptor's code lines are looked up, in order, in the body of the target method.
# Plumbing (ПродолжитьВызов and the return of its result) is not part of the fix and is skipped;
# the interceptor's parameters are renamed to the original's by position.
function Get-HeuristicTransfer($extMethod, $cfgMethod, [string]$prefix) {
	$proceedRe = '(?i)' + (Get-KwAlt 'Proceed') + '\s*\('
	$ep = @($extMethod.ParamNames); $cp = @($cfgMethod.ParamNames)
	# Parameters renamed in code only: a literal or a comment that mentions one stays as written, the
	# way the transfer writes it. One pass for all names: renaming one by one would rename again a
	# name already renamed when the two lists overlap (Источник, Отказ -> Отказ, Режим)
	$renames = @{}
	for ($i = 0; $i -lt [Math]::Min($ep.Count, $cp.Count); $i++) {
		if ($ep[$i] -ine $cp[$i]) { $renames[$ep[$i].ToLowerInvariant()] = $cp[$i] }
	}
	$resultVars = @()
	$lines = @()
	foreach ($n in @(Get-CodeKeys (Protect-BslParameterMembers (Rename-CodeWords (Convert-BslCode $extMethod.BodyLines @{} $ep) $renames) $cp) $prefix)) {
		if (-not (Test-Significant $n)) { continue }
		if ($n -match $proceedRe) {
			if ($n -match '^([\w]+)\s*=') { $resultVars += $Matches[1] }
			continue
		}
		$lines += $n
	}
	if ($resultVars.Count -gt 0) {
		$retRe = '(?i)^' + (Get-KwAlt 'Return') + '\s+(?:' + (($resultVars | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*;?$'
		$lines = @($lines | Where-Object { $_ -notmatch $retRe })
	}
	# Block closers and bare jumps match anywhere — they would only inflate the score
	$meaningful = @($lines | Where-Object { $_ -notmatch $script:trivialRe })
	if ($meaningful.Count -gt 0) { $lines = $meaningful }
	if ($lines.Count -eq 0) { return $null }
	$hay = Get-SigLines (Protect-BslParameterMembers $cfgMethod.BodyLines $cfgMethod.ParamNames) $prefix
	$found = 0; $j = 0
	foreach ($l in $lines) {
		for ($k = $j; $k -lt $hay.Count; $k++) {
			if ($hay[$k] -ieq $l) { $found++; $j = $k + 1; break }
		}
	}
	return @{ Found = $found; Total = $lines.Count }
}

function Get-HeuristicStatus($h) {
	if ($h.Found -eq $h.Total) { return 'TRANSFERRED' }
	if ($h.Found -eq 0) { return 'NOT_TRANSFERRED' }
	return 'PARTIAL'
}

function New-Item2([string]$status, [string]$text, [string]$loc = '', [string]$group = '') {
	return @{ Status = $status; Text = $text; Loc = $loc; Group = $group }
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

# Comparable type of an attribute: the set of its types without namespace and extension prefixes
function Get-MdTypeKey($node, $mns, [string]$prefix) {
	$t = $node.SelectSingleNode("md:Properties/md:Type", $mns)
	if (-not $t) { return '' }
	$parts = @()
	foreach ($c in $t.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if ($c.LocalName -ne 'Type' -and $c.LocalName -ne 'TypeSet') { continue }
		$parts += (Remove-ExtPrefix ($c.InnerText.Trim() -replace '^[\w]+:', '') $prefix)
	}
	$arr = [string[]]@($parts)
	[Array]::Sort($arr, [StringComparer]::Ordinal)
	return ($arr -join ' | ')
}

function Get-KindWord([string]$localName) {
	return ([regex]::Replace($localName, '(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ')).ToLower()
}

# --- Property overrides of adopted elements (xr:PropertyState) ---

# --- Copy from meta-compile (kept identical by check-inline-drift): the format version as a number,
# "2.20" -> 220, "2.9" -> 209; a string comparison would be wrong ---
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

# --- Copy from cfe-borrow (kept identical by check-cfe-prop-lists): how a declared property of an
# adopted element is treated. The extension's mode decides; these lists tell the exceptions ---
$script:controlledProps = @('Type', 'Owners', 'Global', 'ClientManagedApplication', 'Server', 'ExternalConnection',
	'ClientOrdinaryApplication', 'ServerCall', 'Hierarchical', 'CodeLength', 'DescriptionLength', 'CodeType',
	'CodeAllowedLength', 'NumberType', 'NumberLength', 'NumberAllowedLength', 'InformationRegisterPeriodicity',
	'WriteMode', 'LanguageCode', 'RegisteredDocuments', 'ExtDimensionTypes', 'MaxExtDimensionCount')
$script:additiveProps = @('RegisterRecords', 'Content')
$script:noOverrideProps = @('Hierarchical', 'InformationRegisterPeriodicity', 'WriteMode', 'Global',
	'ClientManagedApplication', 'Server', 'ExternalConnection', 'ClientOrdinaryApplication', 'ServerCall', 'CodeAllowedLength', 'LanguageCode')

# Properties the other stages bring: modules and forms are transfered as code, not as a property value
$script:mdModuleProps = @('Module', 'ObjectModule', 'ManagerModule', 'RecordSetModule', 'ValueManagerModule', 'CommandModule', 'Form')
$script:mdServiceProps = @('ObjectBelonging', 'Name', 'Comment', 'ExtendedConfigurationObject')

# Qualifier element a type needs; the order the platform writes them in
$script:mdQualKindByType = @{ 'string' = 'StringQualifiers'; 'decimal' = 'NumberQualifiers'; 'dateTime' = 'DateQualifiers'; 'base64Binary' = 'BinaryDataQualifiers' }
$script:mdQualOrder = @('NumberQualifiers', 'StringQualifiers', 'DateQualifiers', 'BinaryDataQualifiers')

# Type kinds that name a metadata object of the configuration; a *Ref kind looks up its base kind
function Get-MdTypeRefBase([string]$kind) {
	if ($kind.EndsWith('Ref') -and $kind.Length -gt 3) { return $kind.Substring(0, $kind.Length - 3) }
	return $kind
}

# Modes of one element: property -> Notify / MultiState / Extended, from InternalInfo/PropertyState
function Get-MdPropertyStates($el) {
	$states = @{}
	if (-not $el) { return $states }
	$ii = $null
	foreach ($c in $el.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'InternalInfo') { $ii = $c; break } }
	if (-not $ii) { return $states }
	foreach ($ps in $ii.ChildNodes) {
		if ($ps.NodeType -ne 'Element' -or $ps.LocalName -ne 'PropertyState') { continue }
		$p = ''; $s = ''
		foreach ($x in $ps.ChildNodes) {
			if ($x.NodeType -ne 'Element') { continue }
			if ($x.LocalName -eq 'Property') { $p = $x.InnerText.Trim() }
			elseif ($x.LocalName -eq 'State') { $s = $x.InnerText.Trim() }
		}
		if ($p -and $s -and -not $states.ContainsKey($p)) { $states[$p] = $s }
	}
	return $states
}

# Comparable key of one type entry: kind|value, without the namespace prefix, an object name without
# the extension prefix — the configuration has the name the transfer gives it
function Get-MdTypeEntryKey([string]$local, [string]$value, [string]$prefix) {
	$v = $value.Trim() -replace '^[\w]+:', ''
	$i = $v.IndexOf('.')
	if ($i -ge 0) { $v = $v.Substring(0, $i + 1) + (Get-NameKey $v.Substring($i + 1) $prefix) }
	return (($local + '|' + $v).ToLower())
}

# Composition of a <Type>: type entries with their keys and the qualifier elements by kind
function Get-MdTypeModel($typeEl, [string]$prefix) {
	$types = @(); $quals = @{}
	if ($typeEl) {
		foreach ($c in $typeEl.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ($c.LocalName -eq 'Type' -or $c.LocalName -eq 'TypeSet' -or $c.LocalName -eq 'TypeId') {
				$types += @{ Local = $c.LocalName; Value = $c.InnerText.Trim(); Key = (Get-MdTypeEntryKey $c.LocalName $c.InnerText $prefix) }
			} elseif ($c.LocalName.EndsWith('Qualifiers')) { $quals[$c.LocalName] = $c }
		}
	}
	return @{ Types = $types; Quals = $quals }
}

# Qualifier element a type entry of the model needs, '' when the type has none
function Get-MdTypeQualKind($t) {
	$v = $t.Value -replace '^[\w]+:', ''
	if ($v.Contains('.')) { return '' }
	if ($script:mdQualKindByType.ContainsKey($v)) { return $script:mdQualKindByType[$v] }
	return ''
}

function Get-MdQualValue($q, [string]$local) {
	if (-not $q) { return '' }
	foreach ($c in $q.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $local) { return $c.InnerText.Trim() } }
	return ''
}

# Short type composition for the report: String(20), Number(10,2), CatalogRef.X
function Format-MdTypeModel($model) {
	$parts = @()
	foreach ($t in $model.Types) {
		$v = $t.Value -replace '^[\w]+:', ''
		$q = if ($t.Local -eq 'Type') { $model.Quals[(Get-MdTypeQualKind $t)] } else { $null }
		switch -CaseSensitive ($v) {
			'string' { $v = if ($q) { "String($(Get-MdQualValue $q 'Length'))" } else { 'String' } }
			'decimal' { $v = if ($q) { "Number($(Get-MdQualValue $q 'Digits'),$(Get-MdQualValue $q 'FractionDigits'))" } else { 'Number' } }
			'boolean' { $v = 'Boolean' }
			'dateTime' { $v = 'Date' }
		}
		$parts += $v
	}
	return ($parts -join ', ')
}

# Same composition of a type: the same entries (their order is not a value) and qualifiers
function Test-MdTypeModelEqual($a, $b) {
	if ($a.Types.Count -ne $b.Types.Count) { return $false }
	foreach ($t in $a.Types) { if (@($b.Types | Where-Object { $_.Key -ceq $t.Key }).Count -eq 0) { return $false } }
	$keys = @(@($a.Quals.Keys) + @($b.Quals.Keys) | Select-Object -Unique)
	foreach ($k in $keys) {
		if (-not $a.Quals.ContainsKey($k) -or -not $b.Quals.ContainsKey($k)) { return $false }
		if ((Get-NodeCanon $a.Quals[$k]) -cne (Get-NodeCanon $b.Quals[$k])) { return $false }
	}
	return $true
}

# Every type of the part is in the configuration with the qualifiers the part declares for it
function Test-MdTypeModelIncludes($cfg, $ext) {
	foreach ($t in $ext.Types) {
		$ct = @($cfg.Types | Where-Object { $_.Key -ceq $t.Key })[0]
		if (-not $ct) { return $false }
		$k = Get-MdTypeQualKind $t
		if (-not $k -or -not $ext.Quals.ContainsKey($k)) { continue }
		if (-not $cfg.Quals.ContainsKey($k)) { return $false }
		if ((Get-NodeCanon $ext.Quals[$k]) -cne (Get-NodeCanon $cfg.Quals[$k])) { return $false }
	}
	return $true
}

# Types of the part the configuration does not have yet, as a short text
function Get-MdMissingTypeText($cfg, $ext) {
	$parts = @()
	foreach ($t in $ext.Types) {
		if (@($cfg.Types | Where-Object { $_.Key -ceq $t.Key }).Count -gt 0) { continue }
		$one = @{ Types = @($t); Quals = $ext.Quals }
		$parts += (Format-MdTypeModel $one)
	}
	return ($parts -join ', ')
}

# Why the part cannot be merged into the configuration, '' when it can
function Get-MdTypeMergeConflict($cfg, $ext) {
	foreach ($t in $ext.Types) {
		if ($t.Local -eq 'TypeId') { return 'a generated type identifier cannot be transferred' }
		$v = $t.Value -replace '^[\w]+:', ''
		$k = Get-MdTypeQualKind $t
		if (-not $k) { continue }
		$has = $ext.Quals.ContainsKey($k); $cfgHas = $cfg.Quals.ContainsKey($k)
		$ct = @($cfg.Types | Where-Object { $_.Key -ceq $t.Key })[0]
		$extOne = Format-MdTypeModel @{ Types = @($t); Quals = $ext.Quals }
		if ($ct) {
			if ($has -ne $cfgHas) { return "the qualifiers differ ($extOne)" }
			if ($has -and ((Get-NodeCanon $ext.Quals[$k]) -cne (Get-NodeCanon $cfg.Quals[$k]))) {
				return "the configuration already has $(Format-MdTypeModel @{ Types = @($ct); Quals = $cfg.Quals }), the extension declares $extOne"
			}
		} elseif ($cfgHas) {
			# The kind belongs to another type already: adding this one would change that type too
			if (-not $has -or ((Get-NodeCanon $ext.Quals[$k]) -cne (Get-NodeCanon $cfg.Quals[$k]))) { return "the configuration already has $k for another type, the extension declares $extOne" }
		}
	}
	return ''
}

# A property value the transfer can write: no element children, only xsi:type / xsi:nil attributes
function Test-MdScalarProp($p) {
	foreach ($c in $p.ChildNodes) { if ($c.NodeType -eq 'Element') { return $false } }
	foreach ($a in $p.Attributes) {
		if ($a.Prefix -ne 'xsi') { return $false }
		if ($a.LocalName -ne 'type' -and $a.LocalName -ne 'nil') { return $false }
	}
	return $true
}

# Short value of a property for the report
function Format-MdPropValue($p) {
	if (-not $p) { return '—' }
	if (Test-HasElementChild $p) { return '{…}' }
	$t = $p.InnerText.Trim()
	if (-not $t) {
		foreach ($a in $p.Attributes) { if ($a.LocalName -eq 'nil') { return 'nil' } }
		return '—'
	}
	return (Get-Short $t 30)
}

# The <Properties> of an element, null when there is none
function Get-MdPropsElement($el) {
	if (-not $el) { return $null }
	foreach ($c in $el.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'Properties') { return $c } }
	return $null
}

# A named property of <Properties>, null when the element has no such property
function Get-MdPropNode($props, [string]$prop) {
	if (-not $props) { return $null }
	foreach ($c in $props.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -ceq $prop) { return $c } }
	return $null
}

# Items of the property overrides one adopted element declares: Extended scalars are transfered (the
# config's own element gets the value, its uuid and name stay), a type extension is merged into the
# config's <Type>; Notify and a difference without a mode are shown but never written
function Get-MdPropItems($extEl, $cfgEl, [string]$prefix, [int]$rank, [string]$rel, [string]$objType, [string]$tag, [string]$name, [string]$parent, [string]$subject, [bool]$isObject) {
	$items = @()
	if (-not $extEl) { return $items }
	$extProps = Get-MdPropsElement $extEl
	if (-not $extProps) { return $items }
	$states = if ($rank -ge 219) { Get-MdPropertyStates $extEl } else { @{} }
	$cfgProps = Get-MdPropsElement $cfgEl
	$elemMissing = (-not $cfgEl)
	$newPlan = {
		param($mode, $why, $next)
		$pl = @{ Kind = 'md-prop'; Rel = $rel; ObjType = $objType; Tag = $tag; Name = $name; Parent = $parent; Prop = ''; Mode = $mode }
		if ($why) { $pl.Conflict = $why }
		if ($next) { $pl.Next = $next }
		return $pl
	}
	foreach ($p in $extProps.ChildNodes) {
		if ($p.NodeType -ne 'Element') { continue }
		$prop = $p.LocalName
		if ($script:mdServiceProps -contains $prop -or $script:mdModuleProps -contains $prop -or $script:additiveProps -contains $prop) { continue }
		$state = if ($states.ContainsKey($prop)) { $states[$prop] } else { '' }
		$at = if ($isObject) { "$subject property $prop" } else { "$subject.$prop" }

		# Type extension: the extension declares parts; the configuration gets the missing types
		if ($rank -ge 219 -and $prop -eq 'Type') {
			$isXp = $false
			foreach ($a in $p.Attributes) { if ($a.LocalName -eq 'type' -and $a.Value -match 'ExtendedProperty') { $isXp = $true } }
			if ($state -eq 'MultiState' -or $isXp) {
				$parts = @()
				foreach ($c in $p.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'ExtendValue') { $parts += $c } }
				if ($parts.Count -eq 0) { continue }
				$ex = @{ Types = @(); Quals = @{} }
				foreach ($pt in $parts) {
					$m = Get-MdTypeModel $pt $prefix
					$ex.Types += $m.Types
					foreach ($k in $m.Quals.Keys) { if (-not $ex.Quals.ContainsKey($k)) { $ex.Quals[$k] = $m.Quals[$k] } }
				}
				$cfgType = Get-MdPropNode $cfgProps 'Type'
				$why = ''
				if ($elemMissing) { $why = 'the element is not in the configuration' }
				elseif (-not $cfgType) { $why = "the element has no type in the configuration" }
				else { $why = Get-MdTypeMergeConflict (Get-MdTypeModel $cfgType '') $ex }
				if ($why) {
					$ni = New-Item2 'DIVERGED' "$at — $why"
					$pl = & $newPlan 'TypeExtend' $why 'next: compare the types and merge by hand, then re-run -Mode check'
					$pl.Prop = 'Type'
					$ni.Plan = $pl
					$items += $ni
					continue
				}
				if (Test-MdTypeModelIncludes (Get-MdTypeModel $cfgType '') $ex) { $items += (New-Item2 'TRANSFERRED' $at); continue }
				$ni = New-Item2 'NOT_TRANSFERRED' "${at}: + $(Get-MdMissingTypeText (Get-MdTypeModel $cfgType '') $ex)"
				$pl = & $newPlan 'TypeExtend' '' ''
				$pl.Prop = 'Type'; $pl.Node = $p; $pl.Path = Get-NodePath $p; $pl.Parts = $parts; $pl.ExtModel = $ex
				$ni.Plan = $pl
				$items += $ni
				continue
			}
			if ($state -eq 'Extended') {
				$ni = New-Item2 'MANUAL' "$at (mode: Extended) — the platform does not apply a single override of the type; compare by hand"
				$ni.Manual = $true
				$items += $ni
				continue
			}
		}

		$cfgP = Get-MdPropNode $cfgProps $prop
		# An empty element in the shell declares no value: nothing to compare and nothing to report
		$declared = ($p.InnerText.Trim() -ne '') -or (Test-HasElementChild $p) -or ($p.Attributes.Count -gt 0)
		if (-not $declared -and $state -ne 'Extended') { continue }
		$differs = $true
		if ($cfgP) {
			if ($prop -eq 'Type') {
				# The order of the type entries is not a value: the same set is the same type
				$differs = -not (Test-MdTypeModelEqual (Get-MdTypeModel $p $prefix) (Get-MdTypeModel $cfgP ''))
			} else {
				$differs = ((Get-CmpKey $p $prefix) -cne (Get-CmpKey $cfgP ''))
			}
		}

		if ($state -eq 'Extended') {
			if ($script:noOverrideProps -contains $prop) {
				$ni = New-Item2 'MANUAL' "$at (mode: Extended) — override mode is not supported for this property"
				$ni.Manual = $true
				$items += $ni
				continue
			}
			if (-not (Test-MdScalarProp $p)) {
				$ni = New-Item2 'MANUAL' "$at (mode: Extended) — not a scalar; not transferred by this stage"
				$ni.Manual = $true
				$items += $ni
				continue
			}
			if (-not $cfgP) {
				$why = if ($elemMissing) { 'the element is not in the configuration' } else { 'the property is not in the configuration' }
				$ni = New-Item2 'DIVERGED' "$at — $why"
				$pl = & $newPlan 'Scalar' $why 'next: add it by hand if it belongs in the configuration, then re-run -Mode check'
				$pl.Prop = $prop
				$ni.Plan = $pl
				$items += $ni
				continue
			}
			if (-not $differs) { $items += (New-Item2 'TRANSFERRED' $at); continue }
			$ni = New-Item2 'NOT_TRANSFERRED' "${at}: $(Format-MdPropValue $p) vs $(Format-MdPropValue $cfgP) in config"
			$pl = & $newPlan 'Scalar' '' ''
			$pl.Prop = $prop; $pl.Node = $p; $pl.Value = $p.InnerText
			foreach ($a in $p.Attributes) {
				if ($a.Prefix -ne 'xsi') { continue }
				if ($a.LocalName -eq 'type') { $pl.XmlType = $a.Value }
				elseif ($a.LocalName -eq 'nil') { $pl.Nil = ($a.Value -eq 'true') }
			}
			$ni.Plan = $pl
			$items += $ni
			continue
		}

		if ($state -eq 'Notify') {
			if (-not $cfgP) {
				$ni = New-Item2 'MANUAL' "$at (mode: Notify) — $(if ($elemMissing) { 'the element is not in the configuration' } else { 'the property is not in the configuration' })"
				$ni.Manual = $true
				$items += $ni
				continue
			}
			if (-not $differs) { continue }
			$ni = New-Item2 'MANUAL' "$at (mode: Notify): $(Format-MdPropValue $p) vs $(Format-MdPropValue $cfgP) in config — the platform only warns, the extension is not applied; the configuration keeps its value"
			$ni.Manual = $true
			$items += $ni
			continue
		}

		# No mode: with no override declared this is a stale snapshot, not a change to move
		if (-not $cfgP) {
			$ni = New-Item2 'MANUAL' "$at — $(if ($elemMissing) { 'the element is not in the configuration' } else { 'the property is not in the configuration' })"
			$ni.Manual = $true
			$items += $ni
			continue
		}
		if (-not $differs) { continue }
		if ($rank -ge 219) {
			$ni = New-Item2 'MANUAL' "$at — no override mode: the platform will not apply it — align the extension or change the configuration by hand"
		} else {
			$ni = New-Item2 'MANUAL' "$at — the value differs (this format has no override modes); compare by hand"
		}
		$ni.Manual = $true
		$items += $ni
	}
	return $items
}

# --- Copies from meta-edit (kept identical by check-inline-drift): the canonical place of a child
# in <ChildObjects> by the object's kind, in the order MDClasses XSD gives it ---
function Get-ObjectChildOrder {
	return @{
		"Catalog"                    = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"Document"                   = @("Attribute", "Form", "TabularSection", "Template", "Command")
		"ExchangePlan"               = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"ChartOfCharacteristicTypes" = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"ChartOfAccounts"            = @("Attribute", "TabularSection", "AccountingFlag", "ExtDimensionAccountingFlag", "Form", "Template", "Command")
		"ChartOfCalculationTypes"    = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"BusinessProcess"            = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"Task"                       = @("Attribute", "TabularSection", "Form", "Template", "AddressingAttribute", "Command")
		"DataProcessor"              = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"Report"                     = @("Attribute", "TabularSection", "Form", "Template", "Command")
		"ExternalDataProcessor"      = @("Attribute", "TabularSection", "Form", "Template")
		"ExternalReport"             = @("Attribute", "TabularSection", "Form", "Template")
		"Enum"                       = @("EnumValue", "Form", "Template", "Command")
		"InformationRegister"        = @("Resource", "Attribute", "Dimension", "Form", "Template", "Command")
		"AccumulationRegister"       = @("Resource", "Attribute", "Dimension", "Form", "Template", "Command")
		"AccountingRegister"         = @("Dimension", "Resource", "Attribute", "Form", "Template", "Command")
		"CalculationRegister"        = @("Resource", "Attribute", "Dimension", "Recalculation", "Form", "Template", "Command")
		"DocumentJournal"            = @("Column", "Form", "Template", "Command")
		"Table"                      = @("Field", "Form", "Command", "Template")
		"ExternalDataSource"         = @("Table", "Cube", "Function")
		"Cube"                       = @("DimensionTable", "Dimension", "Resource", "Form", "Command", "Template")
		"DimensionTable"             = @("Field", "Form", "Command", "Template")
		"FilterCriterion"            = @("Form", "Command")
		"SettingsStorage"            = @("Form", "Template")
		"TabularSection"             = @("Attribute")
	}
}

# Элемент <ChildObjects>, ПЕРЕД которым встаёт новый <tag>; $null — дописать в конец.
# Сразу за последним элементом своего тега, иначе перед первым элементом группы, идущей
# по канону вида позже. Вид или тег вне канона — $null, как раньше.
function Find-ChildAnchor($container, [string]$tag, [string]$objType) {
	$children = New-Object System.Collections.Generic.List[object]
	foreach ($c in $container.ChildNodes) { if ($c.NodeType -eq 'Element') { $children.Add($c) } }
	$lastIdx = -1
	for ($i = 0; $i -lt $children.Count; $i++) {
		if ($children[$i].LocalName -ceq $tag) { $lastIdx = $i }
	}
	if ($lastIdx -ge 0) {
		if ($lastIdx + 1 -lt $children.Count) { return $children[$lastIdx + 1] }
		return $null
	}
	$order = (Get-ObjectChildOrder)[$objType]
	if (-not $order) { return $null }
	$tagIdx = [array]::IndexOf([string[]]$order, $tag)
	if ($tagIdx -lt 0) { return $null }
	$later = @($order | Select-Object -Skip ($tagIdx + 1))
	foreach ($c in $children) {
		if ($later -ccontains $c.LocalName) { return $c }
	}
	return $null
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

# Nearest preceding sibling of a record that the other side knows (names compared without the prefix)
function Get-PrevKnown($rec, $otherNames, [string]$prefix) {
	for ($i = $rec.Pos - 1; $i -ge 0; $i--) {
		$hit = Find-NameIn $otherNames $rec.Siblings[$i] $prefix
		if ($hit) { return $hit }
	}
	return ''
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


# Transfer check of a form diff against the form of the main configuration
# One property change of the extension against the configuration: 'ok' (the extension's value),
# 'pending' (still the BaseForm value) or 'differs' (changed in the configuration some other way).
function Get-PropTransfer($cpm, $p, [string]$prefix) {
	$cv = if ($cpm.Contains($p.Key)) { Get-RefCmpKey $cpm[$p.Key] $prefix } else { $null }
	$nv = Get-RefCmpKey $p.New $prefix
	$ov = Get-RefCmpKey $p.Old $prefix
	if ($cv -ieq $nv) { return 'ok' }
	# A property the configuration never had: the extension's own, still to be added
	if ($null -eq $p.Old -and -not $cv) { return 'pending' }
	if ($cv -ieq $ov) { return 'pending' }
	return 'differs'
}

function Get-FormTransferItems($diff, $form, [string]$cfgFormXml, [string]$cfgModulePath, [string]$extDir, [string]$prefix) {
	$items = @()
	$group = $form.Label
	$cfgDoc = Read-FormDoc $cfgFormXml
	if (-not $cfgDoc) {
		$items += New-Item2 'MISSING_IN_CONFIG' "form not found in config ($($diff.Total) changes)" '' $group
		return $items
	}
	$cr = $cfgDoc.DocumentElement
	$ci = Get-FormElementIndex $cr
	$cNames = @($ci.Keys)
	$asText = { param($found, $orig) if ($found -and $found -ine $orig) { " (found as $found)" } else { '' } }
	# Items the form module marks "not for transfer", with everything inside them
	$extMod = Read-BslLines $form.Module
	$tmarks = Get-FormTempMarks $extMod
	$marked = {
		param($it, $names)
		if (-not $it -or $tmarks.Count -eq 0) { return $it }
		foreach ($n in @($names)) { if ($n -and $tmarks.ContainsKey(([string]$n).ToLower())) { return (Set-TempMark $it $tmarks[([string]$n).ToLower()] $it.Text) } }
		return $it
	}

	foreach ($ch in $diff.Elements) {
		$rec = $ch.Rec
		$tag = Get-ElementTag $rec.Node
		$hit = Find-NameIn $cNames $rec.Name $prefix
		$own = @($rec.Name) + @($rec.Ancestors)
		if ($ch.Kind -eq 'added') {
			$in = if ($rec.Parent) { " (in: $($rec.Parent))" } else { '' }
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$ni = & $marked (New-Item2 $st "+ $tag $($rec.Name)$in$(& $asText $hit $rec.Name)" '' $group) $own
			if (-not $hit) { $ni.Plan = @{ Kind = 'element'; Rec = $rec }; $ni.PlanKey = "+ $tag $($rec.Name)" }
			$items += $ni
			continue
		}
		if ($ch.Props.Count -gt 0) {
			$keys = @($ch.Props | ForEach-Object { $_.Key })
			if (-not $hit) {
				$items += & $marked (New-Item2 'NOT_TRANSFERRED' "~ $tag $($rec.Name): $($keys -join ', ') (element not in config)" '' $group) $own
			} else {
				$cpm = Get-PropMap $ci[$hit].Node
				$ok = 0; $differs = @()
				foreach ($p in $ch.Props) {
					$r = Get-PropTransfer $cpm $p $prefix
					if ($r -eq 'ok') { $ok++ } elseif ($r -eq 'differs') { $differs += $p.Key }
				}
				$n = $ch.Props.Count
				$st = if ($differs.Count -gt 0) { 'DIVERGED' } elseif ($ok -eq $n) { 'TRANSFERRED' } elseif ($ok -eq 0) { 'NOT_TRANSFERRED' } else { 'PARTIAL' }
				$cnt = if ($st -eq 'DIVERGED' -and $differs.Count -eq $n) { ' (config value differs)' } elseif ($st -eq 'DIVERGED') { " (config value differs: $($differs -join ', '))" } elseif ($st -eq 'PARTIAL') { " ($ok/$n props)" } else { '' }
				$ni = & $marked (New-Item2 $st "~ $tag $($rec.Name): $($keys -join ', ')$cnt" '' $group) $own
				# Only the properties still at their BaseForm value: a value changed in the configuration some
				# other way stays as it is and is left to a person
				$pend = @($ch.Props | Where-Object { (Get-PropTransfer $cpm $_ $prefix) -eq 'pending' })
				if ($pend.Count -gt 0) {
					$ni.Plan = @{ Kind = 'prop'; Rec = $rec; Props = $pend }
					$ni.PlanKey = "~ $tag $($rec.Name): $($keys -join ', ')"
				}
				$items += $ni
			}
		}
		if ($ch.Moved) {
			$st = 'NOT_TRANSFERRED'
			if ($hit) {
				$crec = $ci[$hit]
				$sameParent = ((Remove-ExtPrefix $crec.Parent $prefix) -ieq (Remove-ExtPrefix $rec.Parent $prefix))
				$want = Get-PrevKnown $rec $cNames $prefix
				$have = Get-PrevKnown $crec @($diff.MainIndex.Keys) $prefix
				$haveMapped = if ($have) { Find-NameIn $cNames $have $prefix } else { '' }
				if ($sameParent -and ($want -ieq $haveMapped)) { $st = 'TRANSFERRED' }
			}
			$ni = & $marked (New-Item2 $st "> $tag $($rec.Name): $(Get-MoveText $ch)" '' $group) $own
			if ($st -ne 'TRANSFERRED') { $ni.Plan = @{ Kind = 'move'; Rec = $rec }; $ni.PlanKey = "> $tag $($rec.Name)" }
			$items += $ni
		}
	}

	# Interceptor of a handler: the extension's handler code looked up in the configuration's one
	$cfgMod = Read-BslLines $cfgModulePath
	$modRel = if ($form.Module -and (Test-Path -LiteralPath $form.Module)) { Get-RelPath $extDir $form.Module } else { '' }
	$checkHandler = {
		param([string]$label, [string]$extHandler, [string]$cfgHandler, [string]$missing)
		$extM = Get-MethodSafe $extMod $extHandler
		$loc = if ($extM -and $modRel) { "${modRel}:$($extM.DeclIdx + 1)" } else { '' }
		$mark = if ($extM) { Get-MethodTempMark $extMod $extM } else { $null }
		if (-not $cfgHandler) { return (Set-TempMark (New-Item2 'NOT_TRANSFERRED' "$label ($missing)" $loc $group) $mark $label) }
		$cfgM = Get-MethodSafe $cfgMod $cfgHandler
		if (-not $extM) { return (New-Item2 'NOT_TRANSFERRED' "$label (handler not found in extension module)" $loc $group) }
		if (-not $cfgM) { return (Set-TempMark (New-Item2 'NOT_TRANSFERRED' "$label (config handler $cfgHandler not found in module)" $loc $group) $mark $label) }
		$h = Get-HeuristicTransfer $extM $cfgM $prefix
		if (-not $h) { return $null }
		return (Set-TempMark (New-Item2 (Get-HeuristicStatus $h) "$label (heuristic: $($h.Found)/$($h.Total) lines)" $loc $group) $mark $label)
	}

	foreach ($sec in @(@('Attributes', 'Attribute', 'attribute'), @('Commands', 'Command', 'command'), @('Parameters', 'Parameter', 'parameter'))) {
		if ($diff[$sec[0]].Count -eq 0) { continue }
		$cm = Get-SectionMap $cr $sec[0] $sec[1]
		$cn = @($cm.Keys)
		foreach ($x in $diff[$sec[0]]) {
			# A configuration command the extension intercepts (its action carries callType): kept in
			# BaseForm (Changed) or not, so "absent from BaseForm" alone does not make it the extension's own
			$ctActs = @($x.Actions | Where-Object { $_.CallType })
			if ($sec[1] -eq 'Command' -and $ctActs.Count -gt 0 -and ($cm.Contains($x.Name) -or $x.Changed)) {
				$cfgAct = if ($cm.Contains($x.Name)) { $cm[$x.Name].SelectSingleNode("d:Action", $ns) } else { $null }
				$cfgHandler = if ($cfgAct) { $cfgAct.InnerText.Trim() } else { '' }
				foreach ($a in $ctActs) {
					$label = "command $($x.Name)[$($a.CallType)] -> $($a.Handler)"
					$it = & $checkHandler $label $a.Handler $cfgHandler "no action of $($x.Name) in config"
					$kind = Get-CallTypeKind $a.CallType
					$extM = if ($a.Handler) { Get-MethodSafe $extMod $a.Handler } else { $null }
					$cfgM = if ($cfgHandler) { Get-MethodSafe $cfgMod $cfgHandler } else { $null }
					if ($it -and $kind -and $extM -and $cfgM -and $it.Status -ne 'TRANSFERRED') {
						$it.Plan = @{ Kind = 'intercept'; Type = $kind; ExtM = $extM; CfgM = $cfgM; Rel = $modRel; Label = $label }
						$it.PlanKey = $label
					}
					if ($it) { $items += & $marked $it @($x.Name) }
				}
				continue
			}
			$hit = Find-NameIn $cn $x.Name $prefix
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$ni = & $marked (New-Item2 $st "+ $($sec[2]) $($x.Name)$($x.Info)$(& $asText $hit $x.Name)" '' $group) @($x.Name)
			# A command whose action intercepts a method is a transfer of its own kind: events and command
			# interceptors go with the handlers. A command the configuration lacks is the extension's own even
			# when its action carries callType — there is no handler to intercept: it goes as a command, with
			# its handler as an own method and the callType dropped on the write
			$ctActions = @($x.Actions | Where-Object { $_.CallType })
			if (-not $hit) {
				$cmdOwn = @()
				if ($sec[2] -eq 'command' -and $ctActions.Count -gt 0) {
					foreach ($a in $ctActions) {
						$m = if ($a.Handler) { Get-MethodSafe $extMod $a.Handler } else { $null }
						if ($m) { $cmdOwn += @{ Handler = $a.Handler; ExtM = $m } }
					}
				}
				if ($cmdOwn.Count -gt 0) {
					$ni.Plan = @{ Kind = 'command-bind'; Node = $x.Node; Name = $x.Name; Handlers = $cmdOwn; ExtLines = $extMod; Rel = $modRel }
					$ni.PlanKey = "+ $($sec[2]) $($x.Name)"
				} elseif ($ctActions.Count -eq 0) {
					$ni.Plan = @{ Kind = $(switch ($sec[2]) { 'attribute' { 'attribute' } 'command' { 'command' } default { 'parameter' } }); Node = $x.Node; Name = $x.Name }
					$ni.PlanKey = "+ $($sec[2]) $($x.Name)"
				}
			}
			$items += $ni
		}
	}

	# Columns the extension adds to an attribute of the configuration
	if ($diff.Columns.Count -gt 0) {
		$am = Get-SectionMap $cr 'Attributes' 'Attribute'
		$an = @($am.Keys)
		foreach ($c in $diff.Columns) {
			$label = "+ column $($c.Attr).$($c.Name)$($c.Info)"
			$ah = Find-NameIn $an $c.Attr $prefix
			if (-not $ah) { $items += & $marked (New-Item2 'NOT_TRANSFERRED' "$label (attribute not in config)" '' $group) @($c.Attr, "$($c.Attr).$($c.Name)"); continue }
			$cols = @(); foreach ($x in $am[$ah].SelectNodes("d:Columns/d:Column", $ns)) { $cols += $x.GetAttribute('name') }
			$hit = Find-NameIn $cols $c.Name $prefix
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$ni = & $marked (New-Item2 $st "$label$(& $asText $hit $c.Name)" '' $group) @($c.Attr, "$($c.Attr).$($c.Name)")
			if (-not $hit) { $ni.Plan = @{ Kind = 'column'; Node = $c.Node; Attr = $c.Attr }; $ni.PlanKey = $label }
			$items += $ni
		}
	}

	if ($diff.FormProps.Count -gt 0) {
		$cpm = Get-PropMap $cr -Root
		foreach ($p in $diff.FormProps) {
			$r = Get-PropTransfer $cpm $p $prefix
			$st = if ($r -eq 'ok') { 'TRANSFERRED' } elseif ($r -eq 'pending') { 'NOT_TRANSFERRED' } else { 'DIVERGED' }
			$why = if ($r -eq 'differs') { ' (config value differs)' } else { '' }
			$ni = New-Item2 $st "~ form $(Get-PropChangeText $p)$why" '' $group
			if ($r -eq 'pending') { $ni.Plan = @{ Kind = 'formprop'; Props = @($p); ExtRoot = $diff.Root }; $ni.PlanKey = "~ form $($p.Key)" }
			$items += $ni
		}
	}
	# Conditional appearance rules: an added one must be among the configuration's rules, a removed one not
	if ($diff.Appearance.Count -gt 0) {
		$have = New-Object System.Collections.ArrayList
		foreach ($x in $cr.SelectNodes("d:Attributes/d:ConditionalAppearance/dcsset:item", $ns)) { [void]$have.Add((Get-CmpKey $x $prefix)) }
		foreach ($a in $diff.Appearance) {
			$in = $have.Contains((Get-CmpKey $a.Node $prefix))
			$done = if ($a.Kind -eq 'added') { $in } else { -not $in }
			$mk = if ($a.Kind -eq 'added') { '+' } else { '-' }
			$st = if ($done) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$ni = New-Item2 $st "$mk conditional appearance rule $(Get-AppearanceText $a.Node)" '' $group
			if (-not $done) { $ni.Plan = @{ Kind = 'appearance'; Rule = $a.Node; Add = ($a.Kind -eq 'added') }; $ni.PlanKey = "$mk conditional appearance rule $(Get-AppearanceText $a.Node)" }
			$items += $ni
		}
	}
	foreach ($b in $diff.Blocks) {
		$cnode = $cr.SelectSingleNode($b.XPath, $ns)
		$st = if ((Get-CmpKey $cnode $prefix) -ieq (Get-CmpKey $b.Node $prefix)) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
		$items += New-Item2 $st "~ $($b.Name)" '' $group
	}

	foreach ($e in $diff.Events) {
		$target = $null
		if ($e.Scope) {
			$hit = Find-NameIn $cNames $e.Scope $prefix
			if ($hit) { $target = $ci[$hit].Node }
		} else { $target = $cr }
		$cfgHandler = ''
		if ($target) { foreach ($ce in (Get-EventList $target)) { if ($ce.Name -ieq $e.Name) { $cfgHandler = $ce.Handler; break } } }
		$it = & $checkHandler "event $(Get-EventText $e)" $e.Handler $cfgHandler "no $($e.Name) handler in config"
		$kind = Get-CallTypeKind $e.CallType
		$extM = if ($e.Handler) { Get-MethodSafe $extMod $e.Handler } else { $null }
		$cfgM = if ($cfgHandler) { Get-MethodSafe $cfgMod $cfgHandler } else { $null }
		if ($it -and $kind -and $extM -and $cfgM -and $it.Status -ne 'TRANSFERRED') {
			$it.Plan = @{ Kind = 'intercept'; Type = $kind; ExtM = $extM; CfgM = $cfgM; Rel = $modRel; Label = "event $(Get-EventText $e)" }
			$it.PlanKey = "event $(Get-EventText $e)"
		}
		# An event the configuration has no handler for — whatever its callType: there is nothing to intercept,
		# the event is the extension's own. It goes into the configuration's form and its handler as own method
		if ($it -and $extM -and -not $cfgHandler -and $it.Status -ne 'TRANSFERRED') {
			$it.Plan = @{ Kind = 'event-bind'; ExtM = $extM; ExtLines = $extMod; Rel = $modRel; Scope = $e.Scope; Name = $e.Name; Handler = $e.Handler }
			$it.PlanKey = "event $(if ($e.Scope) { "$($e.Scope)." } else { '' })$($e.Name)"
		}
		if ($it) { $items += & $marked $it @($e.Scope) }
	}
	# An element of BaseForm the main part lacks: the extension cannot drop a borrowed element, so the
	# configuration's form has changed since the borrowing
	foreach ($nm in $diff.Removed) {
		$items += New-Item2 'DIVERGED' "! $nm (in BaseForm, not in the extension's form: the configuration's form changed since the borrowing)" '' $group
	}
	return $items
}

# A form event or command action with callType intercepts the configuration's handler: same kinds as the
# module annotations
function Get-CallTypeKind([string]$callType) {
	switch -Regex ($callType) {
		'^(?i)before$' { return 'Перед' }
		'^(?i)after$' { return 'После' }
		'^(?i)override$' { return 'Вместо' }
	}
	return $null
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
# Transfer check of one object
# ============================================================

# Compare the call contract of an own method. Interceptors use the base declaration.
function Get-OwnMethodParameters([string]$text) {
	$clean = ((Get-CodeOnly ($text -split '\r?\n') -KeepStrings) -join [char]10).Trim()
	if (-not $clean) { return ,@() }
	$pattern = '(?is)^\s*(?:(?<val>' + (Get-KwAlt 'Val') + ')\s+)?\w+\s*(?:=\s*(?<default>.+))?$'
	$result = foreach ($part in (Split-TopLevel $clean)) {
		if ($part -notmatch $pattern) { return $null }
		$byValue = $Matches.ContainsKey('val')
		$default = $null
		if ($Matches.ContainsKey('default')) {
			$value = $Matches['default'].Trim()
			$default = switch ($value.ToLowerInvariant()) {
				'истина' { 'true' }
				'ложь' { 'false' }
				'неопределено' { 'undefined' }
				default { if ($value.StartsWith('"')) { $value } else { ($value -replace '\s+', '').ToLowerInvariant() } }
			}
		}
		@{ ByValue = $byValue; Default = $default }
	}
	return ,@($result)
}

function Get-OwnMethodContext($method) {
	$context = $method.Context.TrimStart('&')
	for ($i = 0; $i -lt $script:bslKw.en.Directives.Count; $i++) {
		if ($context -ieq $script:bslKw.ru.Directives[$i] -or $context -ieq $script:bslKw.en.Directives[$i]) { return $script:bslKw.en.Directives[$i] }
	}
	return $context
}

function Get-OwnDeclarationDifference($extLines, $extMethod, $cfgLines, $cfgMethod) {
	if ($extMethod.IsFunction -ne $cfgMethod.IsFunction) { return 'procedure/function differs' }
	if ($extMethod.IsAsync -ne $cfgMethod.IsAsync) { return 'Async modifier differs' }
	if ((Test-IsExport $extLines $extMethod) -ne (Test-IsExport $cfgLines $cfgMethod)) { return 'Export modifier differs' }
	if ((Get-OwnMethodContext $extMethod) -ine (Get-OwnMethodContext $cfgMethod)) { return 'execution context differs' }
	$left = Get-OwnMethodParameters $extMethod.ParamsText
	$right = Get-OwnMethodParameters $cfgMethod.ParamsText
	if ($null -eq $left -or $null -eq $right) { return 'cannot compare parameter declarations' }
	if ($left.Count -ne $right.Count) { return 'parameter count differs' }
	for ($i = 0; $i -lt $left.Count; $i++) {
		if ($left[$i].ByValue -ne $right[$i].ByValue) { return "parameter $($i + 1) has a different Val modifier" }
		if (-not [string]::Equals($left[$i].Default, $right[$i].Default, [StringComparison]::Ordinal)) {
			return "parameter $($i + 1) has a different default value"
		}
	}
	return $null
}

function Get-ModuleTransferItems([string]$bsl, [string]$extDir, [string]$prefix, $skipHandlers) {
	$items = @()
	$extLines = Read-BslLines $bsl
	if ($null -eq $extLines) { return $items }
	$rel = Get-RelPath $extDir $bsl
	Set-BslContext $rel
	$cfgLines = Read-BslLines (Join-Path $ConfigPath $rel)
	$mc = Get-ModuleChanges $extLines $skipHandlers
	foreach ($x in $mc.Interceptors) {
		$ic = $x.Ic; $decl = $x.Decl
		$label = "&$($ic.Raw)(`"$($ic.Method)`")"
		$loc = "${rel}:$($ic.Line + 1)"
		$extM = if ($decl) { Get-MethodSafe $extLines $decl.Name } else { $null }
		$mark = if ($extM) { Get-MethodTempMark $extLines $extM -AboveOnly:($ic.Type -eq 'ИзменениеИКонтроль') } else { $null }
		$cfgM = Get-MethodSafe $cfgLines $ic.Method
		$it = $null
		$plan = @{ Kind = 'missing'; Rel = $rel; ExtM = $extM; CfgM = $cfgM; Label = $label }
		if (-not $cfgM) {
			$why = if ($null -eq $cfgLines) { 'module not found in config' } else { 'method not found in config' }
			$it = New-Item2 'MISSING_IN_CONFIG' "$label ($why)" $loc
			$plan.Why = $why
		} elseif (-not $extM) {
			$it = New-Item2 'DIVERGED' "$label (cannot parse the interceptor)" $loc
			$plan.Why = 'cannot parse the interceptor'
		} elseif ($ic.Type -eq 'ИзменениеИКонтроль') {
			$r = Get-ControlTransfer $extM $cfgM $prefix
			if ($r) {
				$note = if ($r.Note) { " ($($r.Note))" } else { '' }
				$it = New-Item2 $r.Status "$label — $($r.Count)$note" $loc
				if ($r.Marked -and $r.Status -eq 'TRANSFERRED') { $it.Marked = $true }
				$plan.Kind = 'control'; $plan.Ops = $r.Plan
			}
		} else {
			$h = Get-HeuristicTransfer $extM $cfgM $prefix
			if ($h) { $it = New-Item2 (Get-HeuristicStatus $h) "$label (heuristic: $($h.Found)/$($h.Total) lines)" $loc }
			$plan.Kind = 'intercept'; $plan.Type = $ic.Type
		}
		if ($it) { $it.Plan = $plan }
		if ($it) { $items += (Set-TempMark $it $mark $label) }
	}
	$cfgNames = if ($null -ne $cfgLines) { @(Get-ProcNames $cfgLines) } else { @() }
	foreach ($od in $mc.Own) {
		$pn = $od.Name
		$extM = Get-MethodSafe $extLines $pn
		if (-not $extM) { continue }
		$loc = "${rel}:$($extM.DeclIdx + 1)"
		$mark = Get-MethodTempMark $extLines $extM
		# Every method of the module the name may stand for; the one with the same declaration and body wins (a name
		# given with the development prefix next to a vendor method of the plain name)
		$hits = @(Find-NamesIn $cfgNames $pn $prefix)
		$hit = $null; $cfgM = $null; $literalMismatch = $false; $declarationMismatch = $null
		if ($hits.Count -eq 0) { $it = New-Item2 'NOT_TRANSFERRED' "method $pn" $loc }
		else {
			$extSig = (Get-SigLines (Protect-BslParameterMembers (Convert-BslCode $extM.BodyLines @{} $extM.ParamNames) $extM.ParamNames) $prefix) -join "`n"
			$same = $false
			foreach ($h in $hits) {
				$m = Get-MethodSafe $cfgLines $h
				if (-not $m) { continue }
				if (((Get-SigLines (Protect-BslParameterMembers $m.BodyLines $m.ParamNames) $prefix) -join [char]10) -ieq $extSig) {
					$why = Get-OwnDeclarationDifference $extLines $extM $cfgLines $m
					if (-not $why) { $hit = $h; $cfgM = $m; $same = $true; break }
					if (-not $declarationMismatch) { $hit = $h; $cfgM = $m; $declarationMismatch = $why }
				} elseif (Test-PreviouslyFoldedBody $extM.BodyLines $m.BodyLines $prefix) { $literalMismatch = $true }
			}
			if (-not $hit) { $hit = $hits[0]; $cfgM = Get-MethodSafe $cfgLines $hit }
			$as = if ($hit -ine $pn) { " (found as $hit)" } else { '' }
			$it = if ($same) { New-Item2 'TRANSFERRED' "method $pn$as" $loc } else {
				$reason = if ($declarationMismatch) { "declaration differs: $declarationMismatch" } else { 'body differs' }
				New-Item2 'DIVERGED' "method $pn$as ($reason)" $loc
			}
		}
		$it.Plan = @{ Kind = 'own'; Rel = $rel; ExtM = $extM; ExtLines = $extLines; CfgM = $cfgM; Name = $pn; Hit = $hit; CfgMissing = ($null -eq $cfgLines); LiteralMismatch = $literalMismatch; DeclarationMismatch = $declarationMismatch }
		$items += (Set-TempMark $it $mark "method $pn")
	}
	# Code outside methods (module variables, statements of the module body): its lines looked up among
	# the configuration module's code outside methods, prefixes left out; order is not compared
	if ($mc.TopCode -ge 0) {
		# A line counts once: a variable declared twice in the extension is declared once in the configuration
		$extTop = [ordered]@{}; foreach ($key in (Get-TopCodeKeys $extLines $prefix -Extension).Values) { $extTop[$key] = $true }
		$have = @{}
		if ($null -ne $cfgLines) { foreach ($key in (Get-TopCodeKeys $cfgLines $prefix).Values) { $have[$key] = $true } }
		$found = @($extTop.Keys | Where-Object { $have.ContainsKey($_) }).Count
		$st = Get-HeuristicStatus @{ Found = $found; Total = $extTop.Count }
		$it = New-Item2 $st "module code outside methods (heuristic: $found/$($extTop.Count) lines)" "${rel}:$($mc.TopCode + 1)"
		$it.Plan = @{ Kind = 'topcode'; Rel = $rel; Line = $mc.TopCode; ExtLines = $extLines }
		$items += $it
	}
	return $items
}

# Layout of a module's code outside methods, in one walk: each Перем line with the directive and comment
# lines right above it (Vars: Start, Idx, Names, Depth — of #Если nesting), the other code lines
# (Statements: indexes), the last Перем before the methods at the methods' #Если depth, the first method
# with the directive and comment lines above it, the line after the last method
function Get-ModuleLayout($lines) {
	$declRe = '^\s*(?:' + (Get-KwAlt 'Async') + '\s+)?(?:' + (Get-KwAlt 'Proc') + '|' + (Get-KwAlt 'Func') + ')\s+[\w]+\s*\('
	$endRe = '^\s*(?:' + (Get-KwAlt 'EndProc') + '|' + (Get-KwAlt 'EndFunc') + ')\b'
	$lines = @($lines)
	$lead = { param([int]$i) $s = $i; while ($s -gt 0 -and (([string]$lines[$s - 1]).Trim() -match '^(//|&)')) { $s-- }; $s }
	$vars = @(); $stmts = @(); $firstMethod = -1; $methodDepth = 0; $afterMethods = 0
	$inProc = $false; $depth = 0
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = ([string]$lines[$i]).Trim()
		if ($inProc) { if ($t -imatch $endRe) { $inProc = $false; $afterMethods = $i + 1 }; continue }
		if ($t -imatch $declRe) {
			$inProc = $true
			if ($firstMethod -lt 0) { $firstMethod = & $lead $i; $methodDepth = $depth }
			continue
		}
		if ($t -match '^#(Если|If)(?!\w)') { $depth++; continue }
		if ($t -match '^#(КонецЕсли|EndIf)(?!\w)') { if ($depth -gt 0) { $depth-- }; continue }
		if ($t -eq '' -or $t.StartsWith('//') -or $t.StartsWith('&') -or $t.StartsWith('#')) { continue }
		if ($t -match $script:icVarRe) {
			$names = @()
			if ($t -match ($script:icVarRe + '\s+([^;]*)')) { foreach ($v in $Matches[1].Split(',')) { $n = ($v.Trim() -split '\s+')[0]; if ($n) { $names += $n } } }
			$vars += @{ Start = (& $lead $i); Idx = $i; Names = $names; Depth = $depth; BeforeMethods = ($firstMethod -lt 0) }
		} else { $stmts += $i }
	}
	# New variables go after the last one declared where the methods are: one in a #Если block of its
	# own (#Если Клиент …) would carry them into that block
	$lastVar = -1
	foreach ($v in $vars) { if ($v.BeforeMethods -and ($firstMethod -lt 0 -or $v.Depth -eq $methodDepth)) { $lastVar = $v.Idx } }
	return @{ Vars = $vars; Statements = $stmts; LastVar = $lastVar; FirstMethod = $firstMethod; AfterMethods = $afterMethods }
}

# Code lines of a module outside its methods (not blank, not comments, annotations or preprocessor lines),
# trimmed
function Get-TopCodeKeys($lines, [string]$prefix, [switch]$Extension) {
	$src = if ($Extension) { Convert-BslCode $lines @{} } else { $lines }
	$keys = @(Get-CodeKeys (Get-CodeOnly $src -KeepStrings) $prefix)
	$lay = Get-ModuleLayout $lines
	$res = [ordered]@{}
	foreach ($i in @(@($lay.Vars | ForEach-Object { $_.Idx }) + @($lay.Statements) | Sort-Object)) { $res[[string]$i] = $keys[$i] }
	return $res
}

# Own sub-objects of a borrowed object (attributes, tabular sections, commands, forms, templates, …)
function Get-OwnChildItems($ctx, $cfgMd, [string]$prefix, [string]$rel, [int]$rank) {
	$items = @()
	if (-not $ctx.Md -or -not $ctx.Md.Children) { return $items }
	$mns = $ctx.Md.Ns
	$cfgKids = @()
	if ($cfgMd -and $cfgMd.Children) { foreach ($c in $cfgMd.Children.ChildNodes) { if ($c.NodeType -eq 'Element') { $cfgKids += $c } } }
	# Kinds kept in files of their own: a form, a template, a command module. The metadata transfer
	# carries XML-only children; these stay for a person
	$fileKinds = @('Form', 'Template', 'Command')
	$check = {
		param($node, [string]$label, $cfgPool, [string]$path)
		$nm = Get-MdChildName $node $mns
		$cands = @($cfgPool | Where-Object { $_.LocalName -eq $node.LocalName })
		$hit = Find-NameIn @($cands | ForEach-Object { Get-MdChildName $_ $cfgMd.Ns }) $nm $prefix
		$full = if ($path) { "$path.$nm" } else { $nm }
		$plan = @{ Kind = 'md'; Rel = $rel; ObjType = $ctx.Type; Tag = $node.LocalName; Name = $nm; Parent = $path; Node = $node; TypeKey = '' }
		if ($node.LocalName -eq 'TabularSection') {
			$plan.ChildNames = @()
			$sk = $node.SelectSingleNode("md:ChildObjects", $mns)
			if ($sk) { foreach ($x in $sk.ChildNodes) { if ($x.NodeType -eq 'Element') { $plan.ChildNames += (Get-MdChildName $x $mns) } } }
		}
		if (-not $hit) {
			$ni = New-Item2 'NOT_TRANSFERRED' "$label $full"
			$ni.Plan = if ($fileKinds -contains $node.LocalName) {
				@{ Kind = 'md-skip'; Rel = $rel; Reason = "own $($node.LocalName.ToLower()) is kept in files and is not transferred by this stage; copy it by hand" }
			} else { $plan }
			return $ni
		}
		$as = if ($hit -ine $nm) { " (found as $hit)" } else { '' }
		if ($node.SelectSingleNode("md:Properties/md:Type", $mns)) {
			$cnode = @($cands | Where-Object { (Get-MdChildName $_ $cfgMd.Ns) -ieq $hit })[0]
			$a = Get-MdTypeKey $node $mns $prefix; $b = Get-MdTypeKey $cnode $cfgMd.Ns $prefix
			if ($a -ine $b) {
				$ni = New-Item2 'DIVERGED' "$label $full$as (type: $a vs $b in config)"
				$plan.TypeKey = $a; $plan.Conflict = 'the type differs'
				$ni.Plan = $plan
				return $ni
			}
		}
		return (New-Item2 'TRANSFERRED' "$label $full$as")
	}
	foreach ($c in $ctx.Md.Children.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		if (-not (Test-HasElementChild $c)) {
			# <Form>Имя</Form>, <Template>Имя</Template>: ownership is in the sub-object descriptor
			$nm = $c.InnerText.Trim()
			$desc = Read-MdObject (Join-Path (Join-Path $ctx.ObjDir "$($c.LocalName)s") "$nm.xml")
			if ($desc -and (Test-AdoptedNode $desc.Props $desc.Ns)) { continue }
			$hit = Find-NameIn @($cfgKids | Where-Object { $_.LocalName -eq $c.LocalName } | ForEach-Object { $_.InnerText.Trim() }) $nm $prefix
			$as = if ($hit -and $hit -ine $nm) { " (found as $hit)" } else { '' }
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$ni = New-Item2 $st "$(Get-KindWord $c.LocalName) $nm$as"
			if (-not $hit) {
				$ni.Plan = @{ Kind = 'md-skip'; Rel = $rel; Reason = "own $($c.LocalName.ToLower()) is kept in files and is not transferred by this stage; copy it by hand" }
			}
			$items += $ni
			continue
		}
		if (-not (Test-AdoptedNode $c $mns)) {
			$items += (& $check $c (Get-KindWord $c.LocalName) $cfgKids '')
			continue
		}
		# Adopted element: overrides of its own properties; a borrowed tabular section is also walked
		# for its own children — adopted ones carry overrides, the rest are the extension's new columns
		$nm = Get-MdChildName $c $mns
		$hit = Find-NameIn @($cfgKids | Where-Object { $_.LocalName -eq $c.LocalName } | ForEach-Object { Get-MdChildName $_ $cfgMd.Ns }) $nm $prefix
		$cnode = if ($hit) { @($cfgKids | Where-Object { $_.LocalName -eq $c.LocalName -and (Get-MdChildName $_ $cfgMd.Ns) -ieq $hit })[0] } else { $null }
		$cname = if ($hit) { $hit } else { $nm }
		$items += @(Get-MdPropItems $c $cnode $prefix $rank $rel $ctx.Type $c.LocalName $cname '' "$(Get-KindWord $c.LocalName) $nm" $false)
		$sub = $c.SelectSingleNode("md:ChildObjects", $mns)
		if (-not $sub) { continue }
		$tsName = $nm
		$cfgTs = $cnode
		$cfgSub = @()
		if ($cfgTs) { $cs = $cfgTs.SelectSingleNode("md:ChildObjects", $cfgMd.Ns); if ($cs) { foreach ($x in $cs.ChildNodes) { if ($x.NodeType -eq 'Element') { $cfgSub += $x } } } }
		foreach ($sc in $sub.ChildNodes) {
			if ($sc.NodeType -ne 'Element') { continue }
			$scName = Get-MdChildName $sc $mns
			if (-not (Test-AdoptedNode $sc $mns)) {
				$items += (& $check $sc (Get-KindWord $sc.LocalName) $cfgSub $tsName)
				continue
			}
			$sHit = Find-NameIn @($cfgSub | ForEach-Object { Get-MdChildName $_ $cfgMd.Ns }) $scName $prefix
			$scNode = if ($sHit) { @($cfgSub | Where-Object { (Get-MdChildName $_ $cfgMd.Ns) -ieq $sHit })[0] } else { $null }
			$scTarget = if ($sHit) { $sHit } else { $scName }
			$tsTarget = if ($cfgTs) { Get-MdChildName $cfgTs $cfgMd.Ns } else { $tsName }
			$items += @(Get-MdPropItems $sc $scNode $prefix $rank $rel $ctx.Type $sc.LocalName $scTarget $tsTarget "$(Get-KindWord $sc.LocalName) $tsName.$scName" $false)
		}
	}
	return $items
}

function Get-TransferObject($ext, $obj) {
	$ctx = Get-ObjContext $ext.Dir $obj.Type $obj.Name
	$rec = @{ Id = "$($obj.Type).$($obj.Name)"; Items = @() }
	if (-not $ctx.Known -or -not $ctx.Exists) { return $rec }
	$prefix = $ext.Prefix
	if (-not $ctx.Borrowed) {
		$pool = @()
		if ($cfgInfo.ChildObjects) { foreach ($c in $cfgInfo.ChildObjects.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $obj.Type) { $pool += $c.InnerText.Trim() } } }
		$hit = Find-NameIn $pool $obj.Name $prefix
		$as = if ($hit -and $hit -ine $obj.Name) { " (found as $hit)" } else { '' }
		$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
		$rec.Items += New-Item2 $st "own object$as"
		return $rec
	}
	$cfgFile = Join-Path (Join-Path $ConfigPath $ctx.Dir) "$($obj.Name).xml"
	$cfgMd = Read-MdObject $cfgFile
	$forms = @(Get-ObjForms $ctx)
	$diffs = @{}
	$formItems = @()
	foreach ($f in $forms) {
		if ($f.Own) { continue }
		$d = Get-FormDiff $f.Xml
		if (-not $d -or -not $d.IsBorrowed) { continue }
		$diffs[[IO.Path]::GetFullPath($f.Module)] = $d
		if ($d.Total -eq 0) { continue }
		$rel = Get-RelPath $ext.Dir $f.Xml
		$cfgForm = Join-Path $ConfigPath $rel
		$cfgModule = Join-Path $ConfigPath (Get-RelPath $ext.Dir $f.Module)
		Set-BslContext (Get-RelPath $ext.Dir $f.Module)
		# Dialog changes have no line of their own: their file is the form's Form.xml
		foreach ($fi in @(Get-FormTransferItems $d $f $cfgForm $cfgModule $ext.Dir $prefix)) {
			if (-not $fi.Loc) { $fi.Section = $rel }
			$formItems += $fi
		}
	}
	foreach ($bsl in @(Get-ObjModules $ctx $forms)) {
		$skip = @{}
		$key = [IO.Path]::GetFullPath($bsl)
		if ($diffs.ContainsKey($key)) { $skip = Get-CallTypeHandlers $diffs[$key] }
		$rec.Items += @(Get-ModuleTransferItems $bsl $ext.Dir $prefix $skip)
	}
	# Section = the file the change lives in (a module line, the form's Form.xml, the object's own
	# XML for its sub-objects); the item then keeps only its line number
	$objRel = Get-RelPath $ext.Dir $ctx.File
	# Overrides of the borrowed object's own properties; a missing config object is MISSING_IN_CONFIG anyway
	$rank = if ($ctx.Md -and $ctx.Md.El) { Get-FormatRank $ctx.Md.El.OwnerDocument.DocumentElement.GetAttribute('version') } else { 0 }
	if ($cfgMd) { $rec.Items += @(Get-MdPropItems $ctx.Md.El $cfgMd.El $prefix $rank $objRel $ctx.Type '' '' '' 'object' $true) }
	$rec.Items += @(Get-OwnChildItems $ctx $cfgMd $prefix $objRel $rank)
	if ($obj.Type -eq 'Subsystem') { $rec.Items += @(Get-SubsystemContentItems $ctx.Md $cfgMd $prefix $objRel) }
	$rec.Items += $formItems
	foreach ($it in $rec.Items) {
		$pl2 = $it.Plan
		if ($pl2.Rel -and $it.Status -notin @('TRANSFERRED', 'TEMPORARY')) {
			Set-BslContext $pl2.Rel
			$problem = Get-BslPlanIssue $pl2
			if ($problem) {
				$it.Status = 'MANUAL'; $it.Text += " — $($problem.Issue.Why)"
				$it.Sub = Get-BslManualDetails $pl2 $problem
			}
		}
		if ($it.Loc -match '^(.+):(\d+)$') { $it.Section = $Matches[1]; $it.Loc = ":$($Matches[2])" }
		elseif (-not $it.Section) { $it.Section = $objRel }
	}
	if (-not $cfgMd -and $rec.Items.Count -gt 0) {
		# Temporary changes stay apart: they are not for transfer, missing object or not
		$temp = @($rec.Items | Where-Object { $_.Status -eq 'TEMPORARY' })
		$rest = $rec.Items.Count - $temp.Count
		$rec.Items = @()
		if ($rest -gt 0) { $rec.Items += New-Item2 'MISSING_IN_CONFIG' "object not found in config ($(Get-Plural $rest 'change'))" }
		$rec.Items += $temp
	}
	return $rec
}

# ============================================================
# Module declarations and subsystem content
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

# Transfer of a borrowed subsystem's content: each object the extension adds must be in the content
# of the configuration's subsystem (own names compared with and without the prefix)
function Get-SubsystemContentItems($md, $cfgMd, [string]$prefix, [string]$rel) {
	$items = @()
	$cfg = @(Get-SubsystemContent $cfgMd)
	foreach ($ref in @(Get-SubsystemContent $md)) {
		$i = $ref.IndexOf('.')
		$typ = if ($i -ge 0) { $ref.Substring(0, $i) } else { $ref }
		$nm = if ($i -ge 0) { $ref.Substring($i + 1) } else { '' }
		$pool = @($cfg | Where-Object { $_.StartsWith("$typ.") } | ForEach-Object { $_.Substring($typ.Length + 1) })
		$hit = Find-NameIn $pool $nm $prefix
		$as = if ($hit -and $hit -ine $nm) { " (found as $typ.$hit)" } else { '' }
		$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
		$ni = New-Item2 $st "content $ref$as"
		if (-not $hit) {
			# The referenced object must be in the configuration: the subsystem cannot name a missing one
			$missing = $false
			if ($cfgPools -and $cfgPools.ContainsKey($typ)) { $missing = -not (Find-NameIn @($cfgPools[$typ]) $nm $prefix) }
			$ni.Plan = @{ Kind = 'md-content'; Rel = $rel; Ref = $ref; Type = $typ; Name = $nm; Missing = $missing }
		}
		$items += $ni
	}
	return $items
}


# ============================================================
# Form writing: nodes of the extension's Form.xml copied into the configuration's one
# ============================================================

function Test-IsWs($n) {
	return ($null -ne $n -and ($n.NodeType -eq 'Whitespace' -or $n.NodeType -eq 'SignificantWhitespace'))
}

# A form document for writing: the text is kept as is (whitespace significant), BOM and line breaks remembered
function Read-FormWrite([string]$path) {
	$bytes = [System.IO.File]::ReadAllBytes($path)
	$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
	$off = if ($bom) { 3 } else { 0 }
	$text = [System.Text.Encoding]::UTF8.GetString($bytes, $off, $bytes.Length - $off)
	$eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	$doc.LoadXml($text)
	return @{ Path = $path; Doc = $doc; Bom = $bom; Eol = $eol }
}

# The same file parsed keeping whitespace: the nodes copied into the configuration come from here, so the
# copy carries the platform's line breaks and indents of the extension
function Read-FormDocKeep([string]$path) {
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	try { $doc.Load($path) } catch { return $null }
	return $doc
}

# Where a node sits among element children, from the root: indexes of element siblings
function Get-NodePath($node) {
	$path = New-Object System.Collections.ArrayList
	$cur = $node
	while ($cur -and $cur.NodeType -eq 'Element') {
		$i = 0
		$sib = $cur.PreviousSibling
		while ($sib) { if ($sib.NodeType -eq 'Element') { $i++ }; $sib = $sib.PreviousSibling }
		[void]$path.Insert(0, $i)
		$cur = $cur.ParentNode
	}
	return ,$path.ToArray()
}

function Get-NodeByPath($doc, $path) {
	$cur = $doc.DocumentElement
	for ($k = 1; $k -lt $path.Count; $k++) {
		$want = $path[$k]; $i = 0; $next = $null
		foreach ($c in $cur.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ($i -eq $want) { $next = $c; break }
			$i++
		}
		if (-not $next) { return $null }
		$cur = $next
	}
	return $cur
}

# The document written the way the platform dumps it: UTF-8, <a/> without a space, the file's line breaks and BOM
function Save-FormWrite($fw, [string]$path) {
	if (-not $path) { $path = $fw.Path }
	$settings = New-Object System.Xml.XmlWriterSettings
	$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
	$settings.Indent = $false
	$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
	$settings.OmitXmlDeclaration = $false
	$ms = New-Object System.IO.MemoryStream
	$w = [System.Xml.XmlWriter]::Create($ms, $settings)
	$fw.Doc.Save($w)
	$w.Flush(); $w.Close()
	$text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
	# Ordinal: a culture-sensitive comparison treats the BOM as ignorable and matches anything
	if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
	$text = $text -replace 'encoding="utf-8"', 'encoding="UTF-8"'
	$text = [regex]::Replace($text, '(?<=\S) />', '/>')
	if ($fw.Eol -eq "`r`n") { $text = $text -replace "`r?`n", "`r`n" } else { $text = $text -replace "`r`n", "`n" }
	[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($fw.Bom)))
}

# Free ids of the configuration's form: elements (with companions), attributes, commands, columns per attribute
function Get-FormIdPools($root) {
	$res = @{ Elem = 0; Attr = 0; Cmd = 0; Col = @{} }
	foreach ($n in $root.SelectNodes(".//*[@id]", $ns)) {
		$v = 0
		if (-not [int]::TryParse($n.GetAttribute('id'), [ref]$v)) { continue }
		switch ($n.LocalName) {
			'Attribute' { if ($v -gt $res.Attr) { $res.Attr = $v } }
			'Command' { if ($v -gt $res.Cmd) { $res.Cmd = $v } }
			'Column' {
				$at = $n.ParentNode
				while ($at -and $at.LocalName -ne 'Attribute') { $at = $at.ParentNode }
				$k = if ($at) { $at.GetAttribute('name').ToLower() } else { '' }
				if (-not $res.Col.ContainsKey($k) -or $v -gt $res.Col[$k]) { $res.Col[$k] = $v }
			}
			default { if ($v -gt $res.Elem) { $res.Elem = $v } }
		}
	}
	return $res
}

# Indent of the container's children, from the whitespace of its first child
function Get-FormChildIndent($container, [string]$eol) {
	foreach ($c in $container.ChildNodes) {
		if (-not (Test-IsWs $c)) { continue }
		if ($c.Value -match '^\r?\n(\t+)$') { return $Matches[1] }
		if ($c.Value -match '^\r?\n(\t+)') { return $Matches[1] }
	}
	$depth = 0
	$cur = $container
	while ($cur -and $cur.NodeType -eq 'Element' -and $cur.ParentNode -and $cur.ParentNode.NodeType -eq 'Element') { $depth++; $cur = $cur.ParentNode }
	return ("`t" * ($depth + 1))
}

# Whitespace of a subtree rewritten for a new depth: children on the next level, the closing tag at the node's own
function Set-FormSubtreeIndent($node, [string]$eol, [int]$depth) {
	$kids = @($node.ChildNodes)
	for ($i = 0; $i -lt $kids.Count; $i++) {
		$c = $kids[$i]
		if (Test-IsWs $c) {
			$nv = if ($i -eq $kids.Count - 1) { "$eol$("`t" * $depth)" } else { "$eol$("`t" * ($depth + 1))" }
			$c.Value = $nv
		} elseif ($c.NodeType -eq 'Element') {
			$hasElems = $false
			foreach ($x in $c.ChildNodes) { if ($x.NodeType -eq 'Element') { $hasElems = $true; break } }
			if ($hasElems) { Set-FormSubtreeIndent $c $eol ($depth + 1) }
		}
	}
}

function Get-FormDepth($node) {
	$d = 0
	$cur = $node
	while ($cur -and $cur.ParentNode -and $cur.ParentNode.NodeType -eq 'Element') { $d++; $cur = $cur.ParentNode }
	return $d
}

# Two whitespace nodes side by side make a blank line the platform never writes: one goes
function Remove-DuplicateWhitespace($node) {
	$kids = @($node.ChildNodes)
	for ($i = 1; $i -lt $kids.Count; $i++) {
		if ((Test-IsWs $kids[$i]) -and (Test-IsWs $kids[$i - 1])) { [void]$node.RemoveChild($kids[$i - 1]) }
	}
	foreach ($c in @($node.ChildNodes)) { if ($c.NodeType -eq 'Element') { Remove-DuplicateWhitespace $c } }
}

# A node put among the container's children: before $ref when given, else after the last child. Whitespace of
# the container is kept: one line per node.
function Insert-FormNodeAt($container, $node, $ref, [string]$eol) {
	$ind = Get-FormChildIndent $container $eol
	if ($null -ne $ref) {
		# A line of its own before the reference and one after: the reference keeps the line break that
		# used to stand before it
		[void]$container.InsertBefore($container.OwnerDocument.CreateWhitespace("$eol$ind"), $ref)
		[void]$container.InsertBefore($node, $ref)
		[void]$container.InsertBefore($container.OwnerDocument.CreateWhitespace("$eol$ind"), $ref)
		return
	}
	$trailing = $container.LastChild
	if (Test-IsWs $trailing) {
		[void]$container.InsertBefore($container.OwnerDocument.CreateWhitespace("$eol$ind"), $trailing)
		[void]$container.InsertBefore($node, $trailing)
	} else {
		[void]$container.AppendChild($container.OwnerDocument.CreateWhitespace("$eol$ind"))
		[void]$container.AppendChild($node)
		$parentIndent = if ($ind.Length -gt 0) { $ind.Substring(0, $ind.Length - 1) } else { '' }
		[void]$container.AppendChild($container.OwnerDocument.CreateWhitespace("$eol$parentIndent"))
	}
}

function Remove-FormNode($node) {
	$parent = $node.ParentNode
	if ($parent -and (Test-IsWs $node.PreviousSibling)) { [void]$parent.RemoveChild($node.PreviousSibling) }
	[void]$parent.RemoveChild($node)
}

# ChildItems of a form or an element; created where the platform writes it — after AutoCommandBar/Events of the
# form, at the end of an element's own children
function Get-FormChildItems($container, $root) {
	$ci = $container.SelectSingleNode("d:ChildItems", $ns)
	if ($ci) { return $ci }
	$doc = $container.OwnerDocument
	$ci = $doc.CreateElement('ChildItems', $ns.LookupNamespace('d'))
	if ($container -eq $root) {
		$after = $container.SelectSingleNode("d:Events", $ns)
		if (-not $after) { $after = $container.SelectSingleNode("d:AutoCommandBar", $ns) }
		if ($after -and -not (Test-IsWs $after.NextSibling)) { Remove-FormNode $after; Insert-FormNodeAt $container $after $null $script:formEol; $after = $after.PreviousSibling.PreviousSibling }
	}
	Insert-FormNodeAt $container $ci $null $script:formEol
	return $ci
}

# Name of the property node as Get-PropMap keys it: the tag, a repeat gets #2, #3…
function Get-FormPropKeys($node) {
	$res = @{}
	$seen = @{}
	foreach ($c in $node.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		$k = $c.LocalName
		if ($seen.ContainsKey($k)) { $seen[$k]++; $k = "$k#$($seen[$k])" } else { $seen[$k] = 1 }
		$res[$k] = $c
	}
	return $res
}

# A property node of the target put where the extension's layout has it: after the previous property both sides
# have, else before the next one, else first
function Insert-FormProp($target, $extNode, [string]$key, $newNode, [string]$eol) {
	# The extension's own document order: a hashtable's keys have none
	$extKeys = @(); $seen = @{}
	foreach ($c in $extNode.ChildNodes) {
		if ($c.NodeType -ne 'Element') { continue }
		$k = $c.LocalName
		if ($seen.ContainsKey($k)) { $seen[$k]++; $k = "$k#$($seen[$k])" } else { $seen[$k] = 1 }
		$extKeys += $k
	}
	$pos = [Array]::IndexOf($extKeys, $key)
	$prevKey = $null; $nextKey = $null
	if ($pos -gt 0) { $prevKey = $extKeys[$pos - 1] }
	if ($pos -ge 0 -and $pos -lt $extKeys.Count - 1) { $nextKey = $extKeys[$pos + 1] }
	$tgt = Get-FormPropKeys $target
	$ref = $null
	if ($prevKey -and $tgt.ContainsKey($prevKey)) {
		$ref = $tgt[$prevKey].NextSibling
		while ($ref -and (Test-IsWs $ref) -and $null -eq $ref.NextSibling) { $ref = $null }
	} elseif ($prevKey) {
		# the previous one is missing in the configuration: go further back
		for ($i = $pos - 2; $i -ge 0; $i--) { if ($tgt.ContainsKey($extKeys[$i])) { $ref = $tgt[$extKeys[$i]].NextSibling; break } }
	}
	if (-not $ref -and $nextKey -and $tgt.ContainsKey($nextKey)) { $ref = $tgt[$nextKey] }
	if (-not $ref) { $ref = $target.LastChild; if (Test-IsWs $ref) { $ref = $null } }
	Insert-FormNodeAt $target $newNode $ref $eol
}

# Names of the configuration as a pool: lower-case name -> true
function Get-FormNameSet($root) {
	$s = @{}
	foreach ($n in $root.SelectNodes(".//*[@name]", $ns)) { $s[$n.GetAttribute('name').ToLower()] = $true }
	return $s
}

# Names of the extension's main part -> names in the configuration: the extension prefix goes, a taken name
# gets the project's development prefix (Get-TargetName), a taken one as well stays as it is
function Get-FormNameMap($extRoot, $cfgRoot, [string]$prefix) {
	$taken = Get-FormNameSet $cfgRoot
	$map = @{}
	foreach ($n in $extRoot.SelectNodes(".//*[@name]", $ns)) {
		$nm = $n.GetAttribute('name')
		if (-not $nm) { continue }
		$k = $nm.ToLower()
		if ($map.ContainsKey($k)) { continue }
		if ($prefix -and $nm.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
			$tn = Get-TargetName $nm $prefix $taken $false
			if (-not $tn.Taken) { $taken[$tn.Name.ToLower()] = $true }
			$map[$k] = $tn.Name
		}
	}
	return $map
}

# Objects of the configuration by uuid, for the extension's "0:<uuid>" references: the style items and
# common pictures name themselves in their own source files — StyleItems/<Name>.xml, CommonPictures/<Name>.xml
function Get-ConfigRefMap([string]$cfgDir) {
	$res = @{}
	foreach ($pair in @(@('StyleItems', 'style:'), @('CommonPictures', 'CommonPicture.'))) {
		$dir = Join-Path $cfgDir $pair[0]
		if (-not (Test-Path -LiteralPath $dir)) { continue }
		foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.xml' -File)) {
			try { $doc = New-Object System.Xml.XmlDocument; $doc.Load($f.FullName) } catch { continue }
			$obj = $null
			foreach ($c in $doc.DocumentElement.ChildNodes) { if ($c.NodeType -eq 'Element') { $obj = $c; break } }
			if (-not $obj) { continue }
			$u = $obj.GetAttribute('uuid')
			$nm = $obj.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
			if ($u -and $nm -and $nm.InnerText.Trim()) { $res[$u.ToLower()] = $pair[1] + $nm.InnerText.Trim() }
		}
	}
	return $res
}

# A compared value that is a reference to a style item or a picture: the extension has "0:<uuid>", the
# configuration's dump has "style:<Name>"/"CommonPicture.<Name>", so the extension's side is read the same
function Get-RefCmpKey($node, [string]$prefix) {
	$k = Get-CmpKey $node $prefix
	if (-not $k -or $k.IndexOf('0:') -lt 0 -or -not $script:configRefMap) { return $k }
	# The value of a leaf inside the canonical form: <tag>0:<uuid></>
	return [regex]::Replace($k, '(?<=>)0:([0-9a-fA-F-]{36})(?=<)', {
		param($m)
		$u = $m.Groups[1].Value.ToLower()
		if ($script:configRefMap.ContainsKey($u)) { return $script:configRefMap[$u] }
		return $m.Value
	})
}

$script:formPathTags = '(?:DataPath|TitleDataPath|FooterDataPath|HeaderDataPath|MultipleValue\w*DataPath)$'

# Text of a leaf rewritten: names renamed, "0:<uuid>" references resolved, handler names renamed. Returns the
# unresolved references found.
function Convert-FormLeaf($node, $nameMap, $refMap, $handlerMap, $bad) {
	$tag = $node.LocalName
	if ($tag -eq 'Action' -or $tag -eq 'Event') {
		$v = $node.InnerText.Trim()
		if ($handlerMap -and $handlerMap.ContainsKey($v.ToLower())) { $node.InnerText = $handlerMap[$v.ToLower()] }
		return
	}
	$v = $node.InnerText
	if ($v -match '^\s*0:([0-9a-fA-F-]{36})\s*$') {
		$u = $Matches[1].ToLower()
		if ($refMap.ContainsKey($u)) { $node.InnerText = $refMap[$u] }
		else { [void]$bad.Add("$tag 0:$u") }
		return
	}
	if ($tag -eq 'CommandName' -and $v.Trim().StartsWith('Form.Command.')) {
		$cn = $v.Trim().Substring('Form.Command.'.Length)
		if ($nameMap.ContainsKey($cn.ToLower())) { $node.InnerText = 'Form.Command.' + $nameMap[$cn.ToLower()] }
		return
	}
	if ($tag -match $script:formPathTags -and $nameMap.Count -gt 0) {
		$alt = (@($nameMap.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
		$re = New-Object System.Text.RegularExpressions.Regex ('(?<![\w.])(' + $alt + ')(?!\w)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		$node.InnerText = $re.Replace($v, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $nameMap[$m.Value.ToLower()] })
	}
}

# A copy of the extension's node for the configuration: ids from its pools, names and references converted,
# whitespace at the new depth. $colOwner — the attribute whose columns are copied.
function Copy-FormNode($node, $dstDoc, $pools, $nameMap, $refMap, $handlerMap, $bad, [string]$colOwner) {
	$copy = $dstDoc.ImportNode($node, $true)
	# Document order: the node itself before its descendants, as the py port walks it
	$all = @($copy) + @($copy.SelectNodes(".//*[@id]"))
	foreach ($n in $all) {
		if ($n.NodeType -ne 'Element' -or -not $n.HasAttribute('id')) { continue }
		switch ($n.LocalName) {
			'Attribute' { $pools.Attr++; $n.SetAttribute('id', [string]$pools.Attr) }
			'Command' { $pools.Cmd++; $n.SetAttribute('id', [string]$pools.Cmd) }
			'Column' {
				$owner = $colOwner.ToLower()
				if (-not $pools.Col.ContainsKey($owner)) { $pools.Col[$owner] = 0 }
				$pools.Col[$owner]++
				$n.SetAttribute('id', [string]$pools.Col[$owner])
			}
			default { $pools.Elem++; $n.SetAttribute('id', [string]$pools.Elem) }
		}
	}
	foreach ($n in @($copy.SelectNodes(".//*[@name]")) + @($copy)) {
		if ($n.NodeType -ne 'Element' -or -not $n.HasAttribute('name')) { continue }
		$nm = $n.GetAttribute('name')
		if ($nameMap.ContainsKey($nm.ToLower())) { $n.SetAttribute('name', $nameMap[$nm.ToLower()]) }
	}
	# The node itself too: a copied property is a leaf on its own
	foreach ($n in @($copy) + @($copy.SelectNodes(".//*"))) {
		if ($n.NodeType -ne 'Element') { continue }
		$hasKids = $false
		foreach ($c in $n.ChildNodes) { if ($c.NodeType -eq 'Element') { $hasKids = $true; break } }
		if (-not $hasKids) { Convert-FormLeaf $n $nameMap $refMap $handlerMap $bad }
	}
	return $copy
}

# Attributes section of the form, created at its canonical place
function Get-FormSection($root, [string]$name) {
	$s = $root.SelectSingleNode("d:$name", $ns)
	if ($s) { return $s }
	$doc = $root.OwnerDocument
	$s = $doc.CreateElement($name, $ns.LookupNamespace('d'))
	Insert-FormNodeAt $root $s $null $script:formEol
	return $s
}

# Where a new attribute goes: before ConditionalAppearance (it is the last child of Attributes), else at the end
function Insert-FormAttribute($attrs, $node) {
	$ca = $attrs.SelectSingleNode("d:ConditionalAppearance", $ns)
	if ($ca) { Insert-FormNodeAt $attrs $node $ca $script:formEol } else { Insert-FormNodeAt $attrs $node $null $script:formEol }
}

# An element put among its parent's children: after the nearest previous sibling of the extension that the
# configuration has, else first
function Insert-FormElement($rec, $root, $nameMap, [string]$eol) {
	$parentName = $rec.Parent
	$container = $root
	if ($parentName) {
		$target = Find-FormTarget $root $nameMap $parentName
		if (-not $target) { return $null }
		$container = $target
	}
	$ci = Get-FormChildItems $container $root
	$ref = $null; $foundAny = $false
	for ($i = $rec.Pos - 1; $i -ge 0; $i--) {
		$sib = $rec.Siblings[$i]
		$mn = if ($nameMap.ContainsKey($sib.ToLower())) { $nameMap[$sib.ToLower()] } else { $sib }
		$found = $ci.SelectSingleNode("d:*[@name='" + $mn.Replace("'", "&apos;") + "']", $ns)
		if ($found) { $foundAny = $true; $ref = $found.NextSibling; break }
	}
	if ($ref -and $ref.NodeType -ne 'Element' -and $ref.NextSibling) { $ref = $ref.NextSibling }
	if ($ref -and $ref.NodeType -ne 'Element') { $ref = $null }
	# None of the previous siblings is there: the element stands first, as the check reads it back
	if (-not $foundAny) { foreach ($c in $ci.ChildNodes) { if ($c.NodeType -eq 'Element') { $ref = $c; break } } }
	return @{ Ci = $ci; Ref = $ref }
}

# --- the plan of one form item and applying it ---

function New-FormEdit([string]$path, [string]$extForm, [string]$extModule, [string]$cfgModule, [string]$extDir, [string]$prefix, [string]$label) {
	# The full path as the key: two spellings of one file must not make two documents
	$k = [System.IO.Path]::GetFullPath($path).ToLower()
	if (-not $script:formEdits.Contains($k)) {
		$fw = Read-FormWrite $path
		$script:formEdits[$k] = @{
			Path = $path; Fw = $fw; SrcDoc = (Read-FormDocKeep $extForm); Pools = (Get-FormIdPools $fw.Doc.DocumentElement)
			ExtForm = $extForm; ExtModule = $extModule; CfgModule = $cfgModule; ExtDir = $extDir; Prefix = $prefix; Label = $label
			FormInfo = @{ Xml = $extForm; Module = $extModule; Label = $label }
			Ops = (New-Object System.Collections.ArrayList); Failed = 0
		}
	}
	# Insertion helpers of this form write its line breaks
	$script:formEol = $script:formEdits[$k].Fw.Eol
	return $script:formEdits[$k]
}

# The element of the configuration by its name in the extension: the name map applied. Attributes, commands
# and parameters may share a name with an element — only the form's own elements are looked up here
function Find-FormTarget($root, $nameMap, [string]$name) {
	$mn = if ($nameMap.ContainsKey($name.ToLower())) { $nameMap[$name.ToLower()] } else { $name }
	$idx = Get-FormElementIndex $root
	$hit = Find-NameIn @($idx.Keys) $mn ''
	if ($hit) { return $idx[$hit].Node }
	return $null
}
# The attribute of the configuration by its name: a form element may share it, the element stands first
function Find-FormAttr($root, [string]$name) {
	foreach ($a in @($root.SelectNodes("d:Attributes/d:Attribute", $ns))) { if ($a.GetAttribute('name') -ieq $name) { return $a } }
	return $null
}

function Apply-FormOp($fe, $op, $ctx) {
	$root = $fe.Fw.Doc.DocumentElement
	$eol = $fe.Fw.Eol
	$pools = $fe.Pools
	$copy = {
		param($node, [string]$colOwner)
		$src = if ($fe.SrcDoc) { Get-NodeByPath $fe.SrcDoc (Get-NodePath $node) } else { $null }
		if (-not $src) { $src = $node }
		Copy-FormNode $src $fe.Fw.Doc $pools $ctx.NameMap $ctx.RefMap $ctx.HandlerMap $ctx.Bad $colOwner
	}
	switch ($op.Kind) {
		'attribute' {
			$attrs = Get-FormSection $root 'Attributes'
			$node = & $copy $op.Node $op.Name
			Set-FormSubtreeIndent $node $eol ((Get-FormDepth $attrs) + 1)
			Insert-FormAttribute $attrs $node
		}
		'column' {
			$anm = if ($ctx.NameMap.ContainsKey($op.Attr.ToLower())) { $ctx.NameMap[$op.Attr.ToLower()] } else { $op.Attr }
			$at = Find-FormAttr $root $anm
			if (-not $at) { throw "SKIP: attribute $($op.Attr) is not in the configuration" }
			$cols = $at.SelectSingleNode("d:Columns", $ns)
			if (-not $cols) {
				$doc = $root.OwnerDocument
				$cols = $doc.CreateElement('Columns', $ns.LookupNamespace('d'))
				Insert-FormNodeAt $at $cols $null $eol
			}
			$owner = $at.GetAttribute('name')
			$node = & $copy $op.Node $owner
			Set-FormSubtreeIndent $node $eol ((Get-FormDepth $cols) + 1)
			Insert-FormNodeAt $cols $node $null $eol
		}
		'command' {
			$cmds = Get-FormSection $root 'Commands'
			$node = & $copy $op.Node $null
			# A command of the extension's own: callType has no handler of the configuration to intercept
			if ($op.StripCallType) { foreach ($a in @($node.SelectNodes("d:Action", $ns))) { $a.RemoveAttribute('callType') } }
			Set-FormSubtreeIndent $node $eol ((Get-FormDepth $cmds) + 1)
			Insert-FormNodeAt $cmds $node $null $eol
		}
		'element' {
			# Only the form's own elements count: an attribute may share a name with an element
			$elNames = @((Get-FormElementIndex $root).Keys)
			# What a copied ancestor brought into this run is not added a second time
			$mn = if ($ctx.NameMap.ContainsKey($op.Rec.Name.ToLower())) { $ctx.NameMap[$op.Rec.Name.ToLower()] } else { $op.Rec.Name }
			if (Find-NameIn $elNames $mn '') { return }
			$where = Insert-FormElement $op.Rec $root $ctx.NameMap $eol
			if (-not $where) { throw "SKIP: parent $($op.Rec.Parent) is not in the configuration" }
			$node = & $copy $op.Rec.Node $null
			# Descendants the configuration already has come with their own items: a property, a move — the
			# copy of the new element must not bring a second one
			foreach ($d in @($node.SelectNodes(".//*[@name]", $ns))) {
				$dn = $d.GetAttribute('name')
				if ($dn -and (Find-NameIn $elNames $dn '')) { [void]$d.ParentNode.RemoveChild($d) }
			}
			# A button carries its command with it: a command the configuration does not have leaves
			# the form broken
			$cmds0 = Get-SectionMap $root 'Commands' 'Command'
			foreach ($cn in @($node.SelectNodes(".//d:CommandName", $ns))) {
				$v = $cn.InnerText.Trim()
				if (-not $v.StartsWith('Form.Command.')) { continue }
				$v = $v.Substring('Form.Command.'.Length)
				if (-not $cmds0.Contains($v)) { throw "SKIP: command $v is not in the configuration" }
			}
			Set-FormSubtreeIndent $node $eol ((Get-FormDepth $where.Ci) + 1)
			Insert-FormNodeAt $where.Ci $node $where.Ref $eol
		}
		'event' {
			$target = if ($op.Scope) { Find-FormTarget $root $ctx.NameMap $op.Scope } else { $root }
			if (-not $target) { throw "SKIP: element $($op.Scope) is not in the configuration" }
			$evs = $target.SelectSingleNode("d:Events", $ns)
			if (-not $evs) {
				$evs = $fe.Fw.Doc.CreateElement('Events', $ns.LookupNamespace('d'))
				Insert-FormNodeAt $target $evs $null $eol
			}
			$node = $fe.Fw.Doc.CreateElement('Event', $ns.LookupNamespace('d'))
			$node.SetAttribute('name', $op.Name)
			$node.InnerText = $op.Handler
			Insert-FormNodeAt $evs $node $null $eol
		}
		'prop' {
			$target = Find-FormTarget $root $ctx.NameMap $op.Rec.Name
			if (-not $target) { throw "SKIP: element $($op.Rec.Name) is not in the configuration" }
			foreach ($p in $op.Props) {
				$keys = Get-FormPropKeys $target
				if ($null -eq $p.New) {
					if ($keys.ContainsKey($p.Key)) { Remove-FormNode $keys[$p.Key] }
					continue
				}
				$node = & $copy $p.New $null
				if ($keys.ContainsKey($p.Key)) { [void]$target.ReplaceChild($node, $keys[$p.Key]) }
				else { Insert-FormProp $target $op.Rec.Node $p.Key $node $eol }
			}
		}
		'formprop' {
			foreach ($p in $op.Props) {
				$keys = Get-FormPropKeys $root
				if ($null -eq $p.New) {
					if ($keys.ContainsKey($p.Key)) { Remove-FormNode $keys[$p.Key] }
					continue
				}
				$node = & $copy $p.New $null
				if ($keys.ContainsKey($p.Key)) { [void]$root.ReplaceChild($node, $keys[$p.Key]) }
				else { Insert-FormProp $root $op.ExtRoot $p.Key $node $eol }
			}
		}
		'move' {
			$target = Find-FormTarget $root $ctx.NameMap $op.Rec.Name
			if (-not $target) { throw "SKIP: element $($op.Rec.Name) is not in the configuration" }
			# The element must not leave the document only to have nowhere to go
			if ($op.Rec.Parent -and -not (Find-FormTarget $root $ctx.NameMap $op.Rec.Parent)) { throw "SKIP: parent $($op.Rec.Parent) is not in the configuration" }
			$node = $target.CloneNode($true)
			Remove-FormNode $target
			# The spot is looked up after the element has left: its neighbours have changed
			$where = Insert-FormElement $op.Rec $root $ctx.NameMap $eol
			if (-not $where) { throw "SKIP: parent $($op.Rec.Parent) is not in the configuration" }
			$ci = $where.Ci
			$ref = $null
			if ($where.Ref -and $where.Ref.ParentNode -eq $ci) { $ref = $where.Ref }
			Insert-FormNodeAt $ci $node $ref $eol
		}
		'appearance' {
			$attrs = Get-FormSection $root 'Attributes'
			$ca = $attrs.SelectSingleNode("d:ConditionalAppearance", $ns)
			if ($op.Add) {
				if (-not $ca) {
					$doc = $root.OwnerDocument
					$ca = $doc.CreateElement('ConditionalAppearance', $ns.LookupNamespace('d'))
					Insert-FormNodeAt $attrs $ca $null $eol
				}
				$node = & $copy $op.Rule $null
				Set-FormSubtreeIndent $node $eol ((Get-FormDepth $ca) + 1)
				Insert-FormNodeAt $ca $node $null $eol
			} elseif ($ca) {
				$key = Get-CmpKey $op.Rule $script:transferPrefix
				foreach ($it in @($ca.SelectNodes("dcsset:item", $ns))) {
					if ((Get-CmpKey $it $script:transferPrefix) -ieq $key) { Remove-FormNode $it; break }
				}
			}
		}
		default { throw "unknown form operation $($op.Kind)" }
	}
}

# The form written and read back the same way the check reads it: every planned item must come out in place —
# a property by its value, the rest by the line the check would print for it
# Errors of the form validator (form-validate) for a form file: what the write must not add
function Get-FormValidateErrors([string]$path) {
	$vs = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '../../form-validate') 'scripts/form-validate.ps1'))
	if (-not (Test-Path -LiteralPath $vs)) {
		# The skill may be installed on its own: say so rather than skip the check silently
		$script:formValidateMissing = $true
		return @()
	}
	$out = & powershell.exe -NoProfile -File $vs -FormPath $path 2>&1
	$errs = @()
	foreach ($l in @($out)) { $t = [string]$l; if ($t -match '\[ERROR\]') { $errs += ($t.Substring($t.IndexOf('[ERROR]') + 7) -replace '\s+', ' ').Trim() } }
	return , $errs
}

function Test-FormWrite($fe) {
	$tmp = [System.IO.Path]::GetTempFileName()
	try {
		Remove-DuplicateWhitespace $fe.Fw.Doc.DocumentElement
		Save-FormWrite $fe.Fw $tmp
		# The validator must not see errors the configuration's form did not have before the write
		$before = Get-FormValidateErrors $fe.Path
		$after = Get-FormValidateErrors $tmp
		$added = @($after | Where-Object { $before -notcontains $_ })
		# The comma keeps a one-item array an array: a bare string would unroll to characters
		if ($added.Count -gt 0) { return , @("form-validate: $($added[0])") }
		$miss = @()
		$diff = Get-FormDiff $fe.ExtForm
		$items = Get-FormTransferItems $diff $fe.FormInfo $tmp $fe.CfgModule $fe.ExtDir $fe.Prefix
		$ok = @()
		foreach ($it in $items) { if ($it.Status -eq 'TRANSFERRED') { $ok += $it.Text } }
		$doc = Read-FormDoc $tmp
		$names = if ($doc) { @(Get-FormElementIndex $doc.DocumentElement).Keys } else { @() }
		$checkProps = {
			param($target, $props)
			$bad = @()
			if (-not $target) { return @('target not found') }
			$cpm = Get-PropMap $target
			foreach ($p in $props) { if ((Get-PropTransfer $cpm $p $fe.Prefix) -ne 'ok') { $bad += $p.Key } }
			return $bad
		}
		foreach ($op in $fe.Ops) {
			if ($op.Kind -eq 'prop') {
				$hit = Find-NameIn $names $op.Rec.Name $fe.Prefix
				$target = if ($hit -and $doc) { (Get-FormElementIndex $doc.DocumentElement)[$hit].Node } else { $null }
				foreach ($k in (& $checkProps $target $op.Props)) { $miss += "$($op.Rec.Name).$k" }
				continue
			}
			if ($op.Kind -eq 'formprop') {
				foreach ($k in (& $checkProps $doc.DocumentElement $op.Props)) { $miss += "form.$k" }
				continue
			}
			$hit = $false
			foreach ($t in $ok) { if ($t.StartsWith($op.Key)) { $hit = $true; break } }
			# A command of the extension's own is read back by the check as an interception of itself:
			# its item goes by the command and the callType of the extension's action
			if (-not $hit -and $op.Key.StartsWith('+ command ')) {
				$cre = '^command ' + [regex]::Escape($op.Key.Substring('+ command '.Length)) + '\['
				foreach ($t in $ok) { if ($t -match $cre) { $hit = $true; break } }
			}
			if (-not $hit) { $miss += $op.Key }
		}
		# The comma keeps a one-item array an array: a bare string would unroll to characters
		return , $miss
	} finally {
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
	}
}

# ============================================================
# Metadata writing: nodes of the extension's object XML copied into the configuration's one
# ============================================================

function New-MdNt($doc) {
	$m = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$m.AddNamespace('md', $mdNsUri)
	$m.AddNamespace('xr', 'http://v8.1c.ru/8.3/xcf/readable')
	$m.AddNamespace('v8', 'http://v8.1c.ru/8.1/data/core')
	# A namespace manager is enumerable: the comma keeps it one object
	return , $m
}

# Edits of one configuration's object XML, collected over the run and written once
function Get-MdEdits([string]$path, [string]$objType) {
	$k = [System.IO.Path]::GetFullPath($path).ToLower()
	if (-not $script:mdEdits.Contains($k)) {
		$script:mdEdits[$k] = @{ Path = $path; ObjType = $objType; Fw = (Read-FormWrite $path); Ops = (New-Object System.Collections.ArrayList); Failed = 0 }
	}
	return $script:mdEdits[$k]
}

# The object element of a configuration's object XML
function Get-MdObjectElement($doc) {
	foreach ($c in $doc.DocumentElement.ChildNodes) { if ($c.NodeType -eq 'Element') { return $c } }
	return $null
}

# The <ChildObjects> of the object or of its tabular section $parent, created where it belongs
function Get-MdContainer($me, [string]$parent, [string]$tag) {
	$doc = $me.Fw.Doc; $eol = $me.Fw.Eol
	$m = New-MdNt $doc
	$objEl = Get-MdObjectElement $doc
	if (-not $objEl) { return $null }
	$owner = $objEl
	if ($parent) {
		$owner = $null
		$kids = $objEl.SelectSingleNode("md:ChildObjects", $m)
		if ($kids) {
			foreach ($c in $kids.ChildNodes) {
				if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'TabularSection' -and (Get-MdChildName $c $m) -ieq $parent) { $owner = $c; break }
			}
		}
		if (-not $owner) { return $null }
	}
	$co = $owner.SelectSingleNode("md:ChildObjects", $m)
	if (-not $co) {
		$co = $doc.CreateElement('ChildObjects', $doc.DocumentElement.GetNamespaceOfPrefix('md'))
		Insert-FormNodeAt $owner $co $null $eol
	}
	return $co
}

# The extension's node by the plan: a whitespace-keeping copy of the source document, so the copied
# subtree carries the platform's line breaks and indents
function Get-MdSourceNode($plan, [string]$extDir) {
	$src = Read-FormDocKeep (Join-Path $extDir $plan.Rel)
	if (-not $src) { return $null }
	return (Get-NodeByPath $src (Get-NodePath $plan.Node))
}

function Apply-MdOp($me, $plan, [string]$extDir) {
	$doc = $me.Fw.Doc; $eol = $me.Fw.Eol
	$m = New-MdNt $doc
	$objEl = Get-MdObjectElement $doc
	if (-not $objEl) { throw "SKIP: the object is not in the configuration" }
	if ($plan.Kind -eq 'md-prop') {
		Apply-MdPropOp $me $plan $extDir
		return
	}
	if ($plan.Kind -eq 'md-content') {
		$props = $objEl.SelectSingleNode("md:Properties", $m)
		if (-not $props) { throw "SKIP: the subsystem has no Properties" }
		$content = $props.SelectSingleNode("md:Content", $m)
		if (-not $content) {
			$content = $doc.CreateElement('Content', $doc.DocumentElement.GetNamespaceOfPrefix('md'))
			Insert-FormNodeAt $props $content $null $eol
		}
		$item = $doc.CreateElement('xr:Item', $doc.DocumentElement.GetNamespaceOfPrefix('xr'))
		[void]$item.SetAttribute('type', $doc.DocumentElement.GetNamespaceOfPrefix('xsi'), 'xr:MDObjectRef')
		$item.InnerText = $plan.Ref
		Insert-FormNodeAt $content $item $null $eol
		return
	}
	$container = Get-MdContainer $me $plan.Parent $plan.Tag
	if (-not $container) {
		$why = if ($plan.Parent) { "tabular section $($plan.Parent) is not in the configuration" } else { 'ChildObjects is not in the configuration' }
		throw "SKIP: $why"
	}
	$src = Get-MdSourceNode $plan $extDir
	if (-not $src) { throw "SKIP: the node is not found in the extension" }
	$node = $doc.ImportNode($src, $true)
	# Identifiers are new: a configuration's object must not share them with the extension's own one
	foreach ($n in @($node) + @($node.SelectNodes(".//*", $m))) {
		if ($n.NodeType -ne 'Element') { continue }
		if ($n.HasAttribute('uuid')) { $n.SetAttribute('uuid', [guid]::NewGuid().ToString()) }
	}
	# A new tabular section: its generated types are new and named after it
	foreach ($g in @($node.SelectNodes(".//xr:GeneratedType", $m))) {
		foreach ($x in @($g.SelectNodes("xr:TypeId|xr:ValueId", $m))) { $x.InnerText = [guid]::NewGuid().ToString() }
		$gn = $g.GetAttribute('name')
		if ($gn) { $g.SetAttribute('name', [regex]::Replace($gn, '[^.]+$', $plan.Target.Name)) }
	}
	$nmNode = $node.SelectSingleNode("md:Properties/md:Name", $m)
	if ($nmNode) { $nmNode.InnerText = $plan.Target.Name }
	# Inner names of a copied subtree: a tabular section's own attributes lose the prefix too
	foreach ($x in @($node.SelectNodes(".//md:Properties/md:Name", $m))) {
		if ($x -eq $nmNode) { continue }
		$conv = Convert-ExtCode @($x.InnerText) @{}
		$x.InnerText = [string]$conv[0]
	}
	# The node is the configuration's own: the extension's belongings have no place here
	foreach ($x in @($node.SelectNodes("md:Properties/md:ObjectBelonging|md:Properties/md:ExtendedConfigurationObject", $m))) { [void]$x.ParentNode.RemoveChild($x) }
	# Reference types name the objects the configuration has
	foreach ($t in @($node.SelectNodes(".//v8:Type|.//v8:TypeSet", $m))) {
		$conv = Convert-ExtCode @($t.InnerText) @{}
		$t.InnerText = [string]$conv[0]
	}
	$ref = Find-ChildAnchor $container $plan.Tag $plan.ObjType
	Insert-FormNodeAt $container $node $ref $eol
}

# The config's element a property override belongs to: the object itself or a named child (inside the
# named tabular section when Parent is given), null when the configuration has no such element
function Get-MdTargetElement($objEl, $plan, $m) {
	if (-not $plan.Tag) { return $objEl }
	$kids = $objEl.SelectSingleNode("md:ChildObjects", $m)
	if (-not $kids) { return $null }
	if ($plan.Parent) {
		$ts = $null
		foreach ($c in $kids.ChildNodes) {
			if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'TabularSection' -and (Get-MdChildName $c $m) -ieq $plan.Parent) { $ts = $c; break }
		}
		if (-not $ts) { return $null }
		$kids = $ts.SelectSingleNode("md:ChildObjects", $m)
		if (-not $kids) { return $null }
	}
	foreach ($c in $kids.ChildNodes) {
		if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $plan.Tag -and (Get-MdChildName $c $m) -ieq $plan.Name) { return $c }
	}
	return $null
}

# The extension's node by the path recorded at the check, with the platform's whitespace kept
function Get-MdSourcePropNode($plan, [string]$extDir) {
	$src = Read-FormDocKeep (Join-Path $extDir $plan.Rel)
	if (-not $src) { return $null }
	return (Get-NodeByPath $src $plan.Path)
}

# One scalar property of the configuration's existing element takes the extension's value
function Set-MdScalarProp($p, $plan) {
	foreach ($a in @($p.Attributes)) {
		if ($a.Prefix -eq 'xsi' -and ($a.LocalName -eq 'type' -or $a.LocalName -eq 'nil')) { [void]$p.Attributes.Remove($a) }
	}
	$xsi = $p.OwnerDocument.DocumentElement.GetNamespaceOfPrefix('xsi')
	if ($plan.Nil) { [void]$p.SetAttribute('nil', $xsi, 'true') }
	elseif ($plan.XmlType) { [void]$p.SetAttribute('type', $xsi, $plan.XmlType) }
	$conv = [string](Convert-ExtCode @([string]$plan.Value) @{})[0]
	$p.InnerText = $conv
	$plan.ExpectedKey = Get-CmpKey $p ''
}

# Missing types of the extension's ExtendValue parts merged into the configuration's <Type>: the type
# entries keep their order, the qualifiers follow by kind; the element itself stays a plain <Type>
function Add-MdTypeExtends($props, $plan, [string]$extDir, [string]$eol) {
	$type = Get-MdPropNode $props 'Type'
	if (-not $type) { throw "SKIP: the element has no Type in the configuration" }
	$srcType = Get-MdSourcePropNode $plan $extDir
	if (-not $srcType) { throw "SKIP: the type is not found in the extension" }
	# Declared parts converted to the configuration's names
	$ex = @{ Types = @(); Quals = @{} }
	foreach ($part in $srcType.ChildNodes) {
		if ($part.NodeType -ne 'Element' -or $part.LocalName -ne 'ExtendValue') { continue }
		foreach ($c in $part.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			if ($c.LocalName -eq 'Type' -or $c.LocalName -eq 'TypeSet') {
				$val = [string](Convert-ExtCode @($c.InnerText.Trim()) @{})[0]
				$ex.Types += @{ Local = $c.LocalName; Value = $val; Key = (Get-MdTypeEntryKey $c.LocalName $val ''); Node = $c }
			} elseif ($c.LocalName.EndsWith('Qualifiers')) {
				if (-not $ex.Quals.ContainsKey($c.LocalName)) { $ex.Quals[$c.LocalName] = $c }
			}
		}
	}
	if ($ex.Types.Count -eq 0) { return }
	$cfgModel = Get-MdTypeModel $type ''
	$why = Get-MdTypeMergeConflict $cfgModel $ex
	if ($why) { throw "SKIP: $why" }
	# A type naming a metadata object the configuration lacks would dangle
	foreach ($t in $ex.Types) {
		$v = $t.Value -replace '^[\w]+:', ''
		$j = $v.IndexOf('.')
		if ($j -lt 0) { continue }
		$base = Get-MdTypeRefBase $v.Substring(0, $j)
		$obj = $v.Substring($j + 1)
		if ($cfgPools -and $cfgPools.ContainsKey($base) -and -not (Find-NameIn @($cfgPools[$base]) $obj '')) { throw "SKIP: $v is not in the configuration" }
	}
	$doc = $props.OwnerDocument
	$new = $doc.CreateElement('Type', $mdNsUri)
	[void]$type.ParentNode.ReplaceChild($new, $type)
	$existing = @(); $existingQuals = @{}
	foreach ($c in @($type.ChildNodes)) {
		if ($c.NodeType -ne 'Element') { continue }
		if ($c.LocalName -eq 'Type' -or $c.LocalName -eq 'TypeSet' -or $c.LocalName -eq 'TypeId') { $existing += $c }
		elseif ($c.LocalName.EndsWith('Qualifiers')) { $existingQuals[$c.LocalName] = $c }
	}
	$have = @{}
	foreach ($c in $existing) {
		Insert-FormNodeAt $new $c $null $eol
		$have[(Get-MdTypeEntryKey $c.LocalName $c.InnerText '')] = $true
	}
	$needKinds = @()
	foreach ($t in $ex.Types) {
		if ($have.ContainsKey($t.Key)) { continue }
		$n = $doc.ImportNode($t.Node, $true)
		$n.InnerText = $t.Value
		Insert-FormNodeAt $new $n $null $eol
		$have[$t.Key] = $true
		$k = Get-MdTypeQualKind $t
		if ($k -and $needKinds -cnotcontains $k) { $needKinds += $k }
	}
	foreach ($k in $script:mdQualOrder) {
		if ($existingQuals.ContainsKey($k)) { Insert-FormNodeAt $new $existingQuals[$k] $null $eol; continue }
		if ($needKinds -ccontains $k -and $ex.Quals.ContainsKey($k)) {
			$q = $doc.ImportNode($ex.Quals[$k], $true)
			Insert-FormNodeAt $new $q $null $eol
			# The source qualifier sat deeper (inside ExtendValue): its children are re-indented for <Type>
			Set-FormSubtreeIndent $q $eol (Get-FormDepth $q)
		}
	}
	foreach ($k in $existingQuals.Keys) {
		if ($script:mdQualOrder -cnotcontains $k) { Insert-FormNodeAt $new $existingQuals[$k] $null $eol }
	}
	$plan.ExpectedModel = $ex
}

# An override of one property of the configuration's existing element: the element keeps its uuid and
# name, only the declared value (or the missing type entries) is written
function Apply-MdPropOp($me, $plan, [string]$extDir) {
	$doc = $me.Fw.Doc; $eol = $me.Fw.Eol
	$m = New-MdNt $doc
	$objEl = Get-MdObjectElement $doc
	if (-not $objEl) { throw "SKIP: the object is not in the configuration" }
	$target = Get-MdTargetElement $objEl $plan $m
	if (-not $target) {
		$why = if ($plan.Tag) { "the element $($plan.Tag) $($plan.Name) is not in the configuration" } else { 'the object is not in the configuration' }
		throw "SKIP: $why"
	}
	$props = Get-MdPropsElement $target
	if (-not $props) { throw "SKIP: the element has no Properties in the configuration" }
	if ($plan.Mode -eq 'TypeExtend') { Add-MdTypeExtends $props $plan $extDir $eol; return }
	$p = Get-MdPropNode $props $plan.Prop
	if (-not $p) { throw "SKIP: property $($plan.Prop) is not in the configuration" }
	Set-MdScalarProp $p $plan
}

# Errors of the metadata validator (meta-validate for an object, subsystem-validate for a subsystem)
function Get-MdValidateErrors([string]$path, [string]$objType) {
	$rel = if ($objType -eq 'Subsystem') { '../../subsystem-validate/scripts/subsystem-validate.ps1' } else { '../../meta-validate/scripts/meta-validate.ps1' }
	$vs = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $rel))
	if (-not (Test-Path -LiteralPath $vs)) {
		$script:mdValidateMissing = $true
		return , @()
	}
	$param = if ($objType -eq 'Subsystem') { '-SubsystemPath' } else { '-ObjectPath' }
	$out = & powershell.exe -NoProfile -File $vs $param $path 2>&1
	$errs = @()
	foreach ($l in @($out)) { $t = [string]$l; if ($t -match '\[ERROR\]') { $errs += ($t.Substring($t.IndexOf('[ERROR]') + 7) -replace '\s+', ' ').Trim() } }
	return , $errs
}

# The written file read back the same way the check reads it: every planned node is in place with the
# type the extension has, and the validator sees no error the configuration's file did not have
function Test-MdWrite($me) {
	$dir = [System.IO.Path]::GetDirectoryName($me.Path)
	# Next to the original: meta-validate looks for Configuration.xml upward, a temp dir would lose it
	$tmp = Join-Path $dir ('.cfe-md-' + [guid]::NewGuid().ToString() + '.xml')
	try {
		Remove-DuplicateWhitespace $me.Fw.Doc.DocumentElement
		Save-FormWrite $me.Fw $tmp
		$before = Get-MdValidateErrors $me.Path $me.ObjType
		$after = Get-MdValidateErrors $tmp $me.ObjType
		$added = @($after | Where-Object { $before -notcontains $_ })
		if ($added.Count -gt 0) { return , @("validator: $($added[0])") }
		$doc = Read-FormDoc $tmp
		$m = New-MdNt $doc
		$objEl = Get-MdObjectElement $doc
		$miss = @()
		foreach ($op in $me.Ops) {
			$pl = $op.Plan
			if ($pl.Kind -eq 'md-content') {
				$content = if ($objEl) { $objEl.SelectSingleNode("md:Properties/md:Content", $m) } else { $null }
				$found = $false
				if ($content) { foreach ($i in @($content.SelectNodes("*[local-name()='Item']", $m))) { if ($i.InnerText.Trim() -ieq $pl.Ref) { $found = $true; break } } }
				if (-not $found) { $miss += "$($op.Item.Text)" }
				continue
			}
			if ($pl.Kind -eq 'md-prop') {
				$target = if ($objEl) { Get-MdTargetElement $objEl $pl $m } else { $null }
				$props = Get-MdPropsElement $target
				$bad = -not $target
				if (-not $bad) {
					if ($pl.Mode -eq 'TypeExtend') {
						$type = Get-MdPropNode $props 'Type'
						$bad = (-not $type) -or (-not (Test-MdTypeModelIncludes (Get-MdTypeModel $type '') $pl.ExpectedModel))
					} else {
						$p = Get-MdPropNode $props $pl.Prop
						$bad = (-not $p) -or ((Get-CmpKey $p '') -cne $pl.ExpectedKey)
					}
				}
				if ($bad) { $miss += "$($op.Item.Text)" }
				continue
			}
			$container = $null; $node = $null
			if ($objEl) {
				if ($pl.Parent) {
					$kids = $objEl.SelectSingleNode("md:ChildObjects", $m)
					if ($kids) {
						foreach ($c in $kids.ChildNodes) {
							if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'TabularSection' -and (Get-MdChildName $c $m) -ieq $pl.Parent) { $container = $c.SelectSingleNode("md:ChildObjects", $m); break }
						}
					}
				} else { $container = $objEl.SelectSingleNode("md:ChildObjects", $m) }
			}
			if ($container) {
				foreach ($c in $container.ChildNodes) {
					if ($c.NodeType -eq 'Element' -and $c.LocalName -eq $pl.Tag -and (Get-MdChildName $c $m) -ieq $pl.Target.Name) { $node = $c; break }
				}
			}
			$bad = -not $node
			if (-not $bad -and $pl.TypeKey) { $bad = ((Get-MdTypeKey $node $m $script:transferPrefix) -ine $pl.TypeKey) }
			if (-not $bad -and $pl.Tag -eq 'TabularSection' -and $pl.ChildNames) {
				$sub = $node.SelectSingleNode("md:ChildObjects", $m)
				$have = @()
				if ($sub) { foreach ($x in $sub.ChildNodes) { if ($x.NodeType -eq 'Element') { $have += (Get-MdChildName $x $m) } } }
				foreach ($n in @($pl.ChildNames)) { if (-not (Find-NameIn $have $n $script:transferPrefix)) { $bad = $true; break } }
			}
			if ($bad) { $miss += "$($op.Item.Text)" }
		}
		return , $miss
	} finally {
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
	}
}
# ============================================================
# Transfer: writing into the configuration (-Mode transfer)
# ============================================================

# --- support-guard copies (verbatim from cf-edit, kept identical by check-inline-drift) ---
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
		$pj = Find-V8Project (Get-Location).ProviderPath
		if (-not $pj) { $pj = Find-V8Project ([System.IO.Path]::GetFullPath($cfgDir)) }
		if (-not $pj) { return 'deny' }
		# UTF-8 явно: PS 5.1 читает файл без BOM как ANSI, и configSrc с кириллицей не совпал бы
		$proj = Get-Content -Raw -Encoding UTF8 $pj | ConvertFrom-Json
		# configSrc — от каталога .v8-project.json, а не от рабочего каталога: иначе из подкаталога
		# проекта база не сопоставляется и берётся правило проекта.
		$projDir = [System.IO.Path]::GetDirectoryName($pj)
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($projDir, $db.configSrc)).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}

# ConvertFrom-Json gives PSCustomObject: plain hashtables and arrays are easier to merge and test
function ConvertTo-Plain($v) {
	if ($null -eq $v) { return $null }
	if ($v -is [System.Management.Automation.PSCustomObject]) {
		$h = @{}
		foreach ($p in $v.PSObject.Properties) { $h[$p.Name] = ConvertTo-Plain $p.Value }
		return $h
	}
	if ($v -is [System.Array]) { return ,@($v | ForEach-Object { ConvertTo-Plain $_ }) }
	return $v
}

# Role of an own method -> region, by the module structure standard; a project overrides any of them
# in cfeTransfer.regions with a name or a list of names (the first one the module has wins)
$script:regionDefaults = [ordered]@{
	formEvents       = 'ОбработчикиСобытийФормы'
	headerItemEvents = 'ОбработчикиСобытийЭлементовШапкиФормы'
	tableItemEvents  = 'ОбработчикиСобытийЭлементовТаблицыФормы{table}'
	commands         = 'ОбработчикиКомандФормы'
	notifications    = @('ОбработчикиОповещений', 'СлужебныеПроцедурыИФункции')
	objectEvents     = 'ОбработчикиСобытий'
	api              = 'ПрограммныйИнтерфейс'
	service          = 'СлужебныеПроцедурыИФункции'
}

# Events of object, manager and record set modules (both spellings): their handlers go to objectEvents
$script:objectEventNames = @(
	'ПередЗаписью', 'ПриЗаписи', 'ОбработкаЗаполнения', 'ОбработкаПроверкиЗаполнения', 'ПриКопировании',
	'ПередУдалением', 'ОбработкаПроведения', 'ОбработкаУдаленияПроведения', 'ПриУстановкеНовогоКода',
	'ПриУстановкеНовогоНомера', 'ОбработкаПолученияДанныхВыбора', 'ОбработкаПолученияФормы',
	'ОбработкаПолученияПредставления', 'ОбработкаПолученияПолейПредставления', 'ПриКомпоновкеРезультата',
	'BeforeWrite', 'OnWrite', 'Filling', 'FillCheckProcessing', 'OnCopy', 'BeforeDelete', 'Posting',
	'UndoPosting', 'OnSetNewCode', 'OnSetNewNumber', 'ChoiceDataGetProcessing', 'FormGetProcessing',
	'PresentationGetProcessing', 'PresentationFieldsGetProcessing', 'OnComposeResult')

# Project settings: the database record whose configSrc holds the configuration, else the project
# level. devPrefix — the project's development prefixes; cfeTransfer — keys on its top level apply to
# both kinds of objects, its vendor/own sections refine them.
function Get-TransferSettings([string]$cfgDir) {
	$proj = $null; $db = $null
	$pj = Find-V8Project (Get-Location).ProviderPath
	if (-not $pj) { $pj = Find-V8Project ([System.IO.Path]::GetFullPath($cfgDir)) }
	if ($pj) {
		try { $proj = ConvertTo-Plain (Get-Content -Raw -Encoding UTF8 $pj | ConvertFrom-Json) }
		catch { Write-Error "Cannot read ${pj}: $($_.Exception.Message)"; exit 1 }
		$projDir = [System.IO.Path]::GetDirectoryName($pj)
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		foreach ($d in @($proj['databases'])) {
			if ($d -isnot [hashtable] -or -not $d['configSrc']) { continue }
			$src = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($projDir, $d['configSrc'])).TrimEnd('\', '/')
			if ($cfgFull -ieq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { $db = $d; break }
		}
	}
	$pick = { param($key) if ($db -and $db.ContainsKey($key)) { $db[$key] } elseif ($proj -is [hashtable] -and $proj.ContainsKey($key)) { $proj[$key] } else { $null } }
	$devPrefix = @(@(& $pick 'devPrefix') | Where-Object { $_ } | ForEach-Object { [string]$_ })
	$ct = & $pick 'cfeTransfer'
	if ($ct -isnot [hashtable]) { $ct = @{} }
	$res = @{ DevPrefix = $devPrefix }
	foreach ($kind in @('vendor', 'own')) {
		$e = @{ InsertComment = $null; Deletion = 'comment'; CreateRegions = ($kind -eq 'own'); Regions = @{}; AddDevObjects = $true; AddDevMethods = $false }
		foreach ($k in $script:regionDefaults.Keys) { $e.Regions[$k] = @($script:regionDefaults[$k]) }
		foreach ($src in @($ct, $ct[$kind])) {
			if ($src -isnot [hashtable]) { continue }
			if ($src.ContainsKey('insertComment')) { $e.InsertComment = $src['insertComment'] }
			if ($src.ContainsKey('deletion')) { $e.Deletion = ([string]$src['deletion']).ToLower() }
			if ($src.ContainsKey('createRegions')) { $e.CreateRegions = [bool]$src['createRegions'] }
			if ($src['regions'] -is [hashtable]) { foreach ($k in @($src['regions'].Keys)) { $e.Regions[$k] = @(@($src['regions'][$k]) | ForEach-Object { [string]$_ }) } }
			if ($src['addDevPrefix'] -is [hashtable]) {
				if ($src['addDevPrefix'].ContainsKey('objects')) { $e.AddDevObjects = [bool]$src['addDevPrefix']['objects'] }
				if ($src['addDevPrefix'].ContainsKey('methods')) { $e.AddDevMethods = [bool]$src['addDevPrefix']['methods'] }
			}
		}
		if (@('comment', 'remove') -notcontains $e.Deletion) { Write-Error "cfeTransfer.deletion: expected comment or remove, got '$($e.Deletion)'"; exit 1 }
		$res[$kind] = $e
	}
	return $res
}

# Values for the comment template, from the extension's properties
function Get-TemplateVars($cp, [string]$tag) {
	$props = $cp.Doc.SelectSingleNode("//md:Configuration/md:Properties", $cp.Ns)
	$txt = { param($n) $x = if ($props) { $props.SelectSingleNode("md:$n", $cp.Ns) } else { $null }; if ($x) { $x.InnerText.Trim() } else { '' } }
	$syn = ''
	if ($props) {
		foreach ($it in $props.SelectNodes("md:Synonym/*[local-name()='item']", $cp.Ns)) {
			$lang = $it.SelectSingleNode("*[local-name()='lang']"); $content = $it.SelectSingleNode("*[local-name()='content']")
			if (-not $content) { continue }
			if (-not $syn) { $syn = $content.InnerText.Trim() }
			if ($lang -and $lang.InnerText.Trim() -eq 'ru') { $syn = $content.InnerText.Trim(); break }
		}
	}
	$prefix = [string]$cp.Prefix
	return @{ name = [string]$cp.Name; synonym = $syn; version = (& $txt 'Version'); vendor = (& $txt 'Vendor'); prefix = $prefix; prefixBare = $prefix.TrimEnd('_'); tag = $tag }
}

# A comment line from a template: {name} {synonym} {version} {vendor} {prefix} {prefixBare} {tag},
# {date} or {date:<.NET format>}; a template that is not a comment yet becomes one
function Expand-Template([string]$tpl, $vars) {
	$ev = [System.Text.RegularExpressions.MatchEvaluator] {
		param($m)
		$k = $m.Groups[1].Value
		if ($k -eq 'date') {
			$f = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { 'dd.MM.yyyy' }
			return (Get-Date).ToString($f, [System.Globalization.CultureInfo]::InvariantCulture)
		}
		if ($vars.ContainsKey($k)) { return [string]$vars[$k] }
		return $m.Value
	}
	$out = [regex]::Replace($tpl, '\{(\w+)(?::([^}]*))?\}', $ev)
	if (-not $out.TrimStart().StartsWith('//')) { $out = "// $out" }
	return $out
}

# Begin/end comment lines of a kind of object ($null when the project frames nothing)
function Get-Frame($set, $vars) {
	$ic = $set.InsertComment
	$b = $null; $e = $null
	if ($ic -is [hashtable]) {
		if ($ic['begin']) { $b = Expand-Template ([string]$ic['begin']) $vars }
		if ($ic['end']) { $e = Expand-Template ([string]$ic['end']) $vars }
	}
	return @{ Begin = $b; End = $e }
}

# Support settings of the configuration, read once: capability (G), objects on support (K), the
# support state per object uuid (0 locked, 1 editable with support, 2 taken off support)
function Get-SupportInfo([string]$cfgDir) {
	$info = @{ G = 0; K = 0; Map = @{}; Mode = (Get-EditMode $cfgDir) }
	$bin = Join-Path (Join-Path $cfgDir 'Ext') 'ParentConfigurations.bin'
	if (-not (Test-Path -LiteralPath $bin)) { return $info }
	$bytes = [System.IO.File]::ReadAllBytes($bin)
	if ($bytes.Length -le 32) { return $info }
	$start = 0
	if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
	$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
	$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
	if (-not $hm.Success) { return $info }
	$info.G = [int]$hm.Groups[1].Value
	$info.K = [int]$hm.Groups[2].Value
	foreach ($m in [regex]::Matches($text, '([0-2]),0,([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')) {
		$u = $m.Groups[2].Value.ToLower(); $f = [int]$m.Groups[1].Value
		if (-not $info.Map.ContainsKey($u) -or $f -lt $info.Map[$u]) { $info.Map[$u] = $f }
	}
	return $info
}

# Support state of a configuration object: locked (the support settings forbid editing it), vendor
# (on support) or own (taken off support, created in the configuration, no support at all).
# editingAllowedCheck lifts the lock, as for the editing skills: warn — the object is 'warn' (on
# support, edited with a note in the report), off — plain 'vendor'.
function Get-ObjectSupport([string]$xmlPath) {
	$si = $script:supportInfo
	if ($si.K -eq 0) { return 'own' }
	$lock = { if ($si.Mode -eq 'off') { 'vendor' } elseif ($si.Mode -eq 'warn') { 'warn' } else { 'locked' } }
	if ($si.G -eq 1) { return (& $lock) }
	$u = Get-RootUuid $xmlPath
	$f = if ($u -and $si.Map.ContainsKey($u.ToLower())) { $si.Map[$u.ToLower()] } else { $null }
	if ($null -eq $f -or $f -eq 2) { return 'own' }
	if ($f -eq 0) { return (& $lock) }
	return 'vendor'
}

function Test-HasDevPrefix([string]$name) {
	foreach ($p in $script:settings.DevPrefix) { if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
	return $false
}

# Own or vendor: by the development prefix in the object's name when the project has one, else by support
function Get-ObjectKind([string]$objName, [string]$support) {
	if ($script:settings.DevPrefix.Count -gt 0) { if (Test-HasDevPrefix (Remove-ExtPrefix $objName $script:transferPrefix)) { return 'own' } else { return 'vendor' } }
	if ($support -eq 'own') { return 'own' }
	return 'vendor'
}

# Name in the configuration for an own name of the extension: without the extension prefix; taken ->
# with the development prefix; taken too -> as it is. $addDev puts the development prefix first.
# $taken — lower-case names of the target (module or object) plus those given in this run.
function Get-TargetName([string]$name, [string]$prefix, $taken, [bool]$addDev) {
	$bare = if ($prefix) { Remove-ExtPrefix $name $prefix } else { $name }
	$dp = $script:settings.DevPrefix
	$withDev = if ($dp.Count -gt 0 -and -not (Test-HasDevPrefix $bare)) { "$($dp[0])$bare" } else { $null }
	$cands = @()
	if ($addDev -and $withDev) { $cands += $withDev } else { $cands += $bare; if ($withDev) { $cands += $withDev } }
	for ($i = 0; $i -lt $cands.Count; $i++) {
		$c = $cands[$i]
		if ($taken.Contains($c.ToLower())) { continue }
		$note = ''
		if ($i -gt 0) { $note = "as ${c}: $($cands[0]) exists" }
		elseif ($c -cne $name) { $note = "as $c" }
		return @{ Name = $c; Note = $note }
	}
	$verb = if ($cands.Count -gt 1) { 'exist' } else { 'exists' }
	if ($taken.Contains($name.ToLower())) { return @{ Name = $name; Taken = $true; Note = "$($cands -join ', ') $verb" } }
	return @{ Name = $name; Note = "kept prefix: $($cands -join ', ') $verb" }
}

# Names called as functions (not methods of an object: no dot before them), lower case, without
# those in $skip (the extension's own methods: calling them is not a global name)
function Get-CalledNames($lines, $skip) {
	$sk = @{}
	foreach ($n in @($skip)) { if ($n) { $sk[$n.ToLower()] = $true } }
	$res = @{}
	foreach ($t in (Get-CodeOnly $lines)) {
		foreach ($m in [regex]::Matches($t, '(?<![\w.])([\w]+)\s*\(')) { $k = $m.Groups[1].Value.ToLower(); if (-not $sk.ContainsKey($k)) { $res[$k] = $true } }
	}
	return @($res.Keys)
}

# Per-extension symbol catalog. Methods and attributes never share a global short-name map.
function Initialize-BslCatalog([string]$extDir, [string]$prefix) {
	$script:bslCatalog = @{}; $script:bslCommon = @{}; $script:bslGlobals = @{}; $script:bslGlobalOwners = @()
	$script:transferPrefix = $prefix
	foreach ($f in @(Get-ChildItem -LiteralPath $extDir -Filter '*.bsl' -Recurse)) {
		$rel = Get-RelPath $extDir $f.FullName
		$cfg = Get-CfgPath $rel
		$el = Read-BslLines $f.FullName; $cl = Read-BslLines $cfg
		$kind = Get-ModuleKind $rel
		$ctx = @{ Rel = $rel; Ext = $el; Cfg = $cl; Kind = $kind; Methods = @{}; Attrs = @{}; DataAttrs = @{}; FormNames = @{}; Names = @{} }
		$script:bslCatalog[$rel.ToLower()] = $ctx
		$cn = @(Get-ProcNames $cl)
		$taken = New-Object 'System.Collections.Generic.HashSet[string]'
		foreach ($n in $cn) { [void]$taken.Add($n.ToLower()) }
		$en = @(Get-ProcNames $el)
		foreach ($n in @(Get-CalledNames (@($cl) + @($el)) $en)) { [void]$taken.Add($n) }
		$interceptNames2 = @{}
		foreach ($ic2 in @(Get-Interceptors $el)) { $dd2 = Find-DeclAfter $el $ic2.Line; if ($dd2) { $interceptNames2[$dd2.Name.ToLower()] = $true } }
		foreach ($d in @(Get-ProcDecls $el)) {
			$n = $d.Name
			# An interceptor is not a separately callable own method.
			if ($interceptNames2.ContainsKey($n.ToLower())) { continue }
			$hits = @(Find-NamesIn $cn $n $prefix)
			$hit = $null
			$em = Get-MethodSafe $el $n
			foreach ($h in $hits) {
				$cm = Get-MethodSafe $cl $h
				if ($cm -and $em -and -not (Get-OwnDeclarationDifference $el $em $cl $cm) -and ((Get-SigLines $cm.BodyLines $prefix) -join "`n") -ceq ((Get-SigLines $em.BodyLines $prefix) -join "`n")) { $hit = $h; break }
			}
			if (-not $hit -and $hits.Count) { $hit = $hits[0] }
			if ($hit) { $target = $hit } else { $target = (Get-TargetName $n $prefix $taken $false).Name }
			$ctx.Methods[$n.ToLower()] = $target; $ctx.Names[$n.ToLower()] = $n
			[void]$taken.Add($target.ToLower())
		}
		if ($kind -eq 'common' -and $rel -match '^CommonModules[/\\]([^/\\]+)') { $script:bslCommon[$Matches[1].ToLower()] = $ctx }
		# Module variables are real identifiers too; arbitrary prefixed words are not names.
		foreach ($v in (Get-ModuleLayout $el).Vars) { foreach ($n in $v.Names) { $ctx.Attrs[$n.ToLower()] = Remove-ExtPrefix $n $prefix; $ctx.Names[$n.ToLower()] = $n } }
		if ($kind -eq 'form') {
			$ef = ($f.FullName -replace '[/\\]Form[/\\]Module\.bsl$', '/Form.xml')
			$cf = ($cfg -replace '[/\\]Form[/\\]Module\.bsl$', '/Form.xml')
			$ed = Read-FormDoc $ef; $cd = Read-FormDoc $cf
			if ($ed -and $cd) {
				$fm = Get-FormNameMap $ed.DocumentElement $cd.DocumentElement $prefix
				$cfgNames2 = @($cd.SelectNodes('//*[@name]') | ForEach-Object { $_.GetAttribute('name') })
				foreach ($k2 in @($fm.Keys)) { $hit2 = Find-NameIn $cfgNames2 $k2 $prefix; if ($hit2) { $fm[$k2] = $hit2 } }
				$ctx.FormNames = $fm
				foreach ($x in $ed.SelectNodes("/*/*[local-name()='Attributes']/*[local-name()='Attribute']")) {
					$n = $x.GetAttribute('name'); if (-not $n) { continue }
					$ctx.Attrs[$n.ToLower()] = if ($fm.ContainsKey($n.ToLower())) { $fm[$n.ToLower()] } else { Remove-ExtPrefix $n $prefix }
					$ctx.Names[$n.ToLower()] = $n
				}
			}
		}
		# Object metadata belongs to the object, including its form's data attribute Object.
		if ($rel -match '^([^/\\]+)[/\\]([^/\\]+)[/\\]') {
			$mdRel = "$($Matches[1])/$($Matches[2]).xml"
			$ed = Read-MdObject (Join-Path $extDir $mdRel); $cd = Read-MdObject (Get-CfgPath $mdRel)
			if ($ed -and $ed.Children) {
				$cfgNames = @(); if ($cd -and $cd.Children) { foreach ($x in $cd.Children.ChildNodes) { if ($x.NodeType -eq 'Element') { $cfgNames += (Get-MdChildName $x $cd.Ns) } } }
				foreach ($x in $ed.Children.ChildNodes) {
					if ($x.LocalName -notin @('Attribute', 'TabularSection')) { continue }
					$n = Get-MdChildName $x $ed.Ns; if (-not $n) { continue }
					$hit = Find-NameIn $cfgNames $n $prefix
					$target = if ($hit) { $hit } else { Remove-ExtPrefix $n $prefix }
					$ctx.DataAttrs[$n.ToLower()] = $target; $ctx.Names[$n.ToLower()] = $n
					if ($kind -ne 'form') { $ctx.Attrs[$n.ToLower()] = $target }
				}
			}
		}
	}
	# Actual metadata object names, for qualified code references only.
	$cp = Read-ConfigurationProps $extDir
	if ($cp.ChildObjects) { foreach ($x in $cp.ChildObjects.ChildNodes) {
		if ($x.NodeType -ne 'Element') { continue }; $n = $x.InnerText.Trim()
		$pool2 = @(); if ($cfgInfo.ChildObjects) { foreach ($c2 in $cfgInfo.ChildObjects.ChildNodes) { if ($c2.NodeType -eq 'Element' -and $c2.LocalName -eq $x.LocalName) { $pool2 += $c2.InnerText.Trim() } } }
		$hit2 = Find-NameIn $pool2 $n $prefix
		$script:bslGlobals[$n.ToLower()] = if ($hit2) { $hit2 } else { Remove-ExtPrefix $n $prefix }
	} }
	# The global idle-handler API can only see application/global common-module exports.
	# Include configuration-only modules too: extension-only coincidences are not an exhaustive set.
	$globalPaths = @{}
	foreach ($root2 in @($ConfigPath, $extDir)) {
		$dir2 = Join-Path $root2 'CommonModules'
		if (-not (Test-Path -LiteralPath $dir2)) { continue }
		foreach ($md2 in @(Get-ChildItem -LiteralPath $dir2 -Filter '*.xml')) {
			$md3 = Read-MdObject $md2.FullName
			if (-not $md3 -or -not $md3.Props) { continue }
			$g = $md3.Props.SelectSingleNode('md:Global', $md3.Ns)
			if ($g -and $g.InnerText -ieq 'true') { $globalPaths["CommonModules/$($md2.BaseName)/Ext/Module.bsl".ToLower()] = "CommonModules/$($md2.BaseName)/Ext/Module.bsl" }
		}
	}
	foreach ($rel2 in $globalPaths.Values) {
		$gc = $script:bslCatalog[$rel2.ToLower()]
		if (-not $gc) { $gc = @{ Rel = $rel2; Kind = 'common'; Methods = @{}; Ext = @(); Cfg = (Read-BslLines (Get-CfgPath $rel2)) } }
		$script:bslGlobalOwners += $gc
	}
	foreach ($rel2 in @('Ext/ManagedApplicationModule.bsl', 'Ext/OrdinaryApplicationModule.bsl')) {
		$ac = $script:bslCatalog[$rel2.ToLower()]; $acl = Read-BslLines (Get-CfgPath $rel2)
		if ($ac -or $null -ne $acl) {
			$script:bslGlobalOwners += @{ Rel = $rel2; Kind = 'application'; Methods = $(if ($ac) { $ac.Methods } else { @{} }); Ext = $(if ($ac) { $ac.Ext } else { @() }); Cfg = $acl }
		}
	}
	# A carried-over callback contains the target name inside a literal. Resolve candidate
	# bodies with that candidate's map, including self-references and cross-module cycles.
	for ($pass2 = 0; $pass2 -le $script:bslCatalog.Count; $pass2++) {
		$changed2 = $false
		foreach ($ctx2 in $script:bslCatalog.Values) {
			$script:bslContext = $ctx2
			foreach ($k2 in @($ctx2.Methods.Keys)) {
				$n2 = $ctx2.Names[$k2]; $em2 = Get-MethodSafe $ctx2.Ext $n2
				if (-not $em2 -or (@($em2.BodyLines) -join "`n") -notmatch '(?i)(ОписаниеОповещения|CallbackDescription|NotifyDescription|ОбработчикОжидания|IdleHandler|УстановитьДействие|SetAction|РеквизитФормыВЗначение|FormAttributeToValue)\s*\(') { continue }
				$old2 = $ctx2.Methods[$k2]; $found2 = $null
				foreach ($hit2 in @(Find-NamesIn @(Get-ProcNames $ctx2.Cfg) $n2 $prefix)) {
					$ctx2.Methods[$k2] = $hit2
					$cm2 = Get-MethodSafe $ctx2.Cfg $hit2
					if ($cm2 -and -not (Get-OwnDeclarationDifference $ctx2.Ext $em2 $ctx2.Cfg $cm2) -and ((Get-SigLines (Protect-BslParameterMembers (Convert-BslCode $em2.BodyLines @{} $em2.ParamNames) $em2.ParamNames) $prefix) -join "`n") -ceq ((Get-SigLines (Protect-BslParameterMembers $cm2.BodyLines $cm2.ParamNames) $prefix) -join "`n")) { $found2 = $hit2; break }
				}
				$ctx2.Methods[$k2] = if ($found2) { $found2 } else { $old2 }
				if ($found2 -and $found2 -cne $old2) { $changed2 = $true }
			}
		}
		if (-not $changed2) { break }
	}
	$script:bslContext = $null
}

function Get-BslGlobalReferences([string]$name) {
	$res = @(); $k = $name.ToLower()
	foreach ($gc in $script:bslGlobalOwners) {
		$em = Get-MethodSafe $gc.Ext $name
		if ($em -and (Test-IsExport $gc.Ext $em) -and $gc.Methods.ContainsKey($k)) {
			$target2 = $gc.Methods[$k]
			# Application-module transfer is outside this stage: only an existing target is a rename.
			if ($gc.Kind -eq 'application' -and -not (Get-MethodSafe $gc.Cfg $target2)) { $target2 = $name }
			$res += @{ Target = $target2; Context = $gc }
		}
		$cm = Get-MethodSafe $gc.Cfg $name
		if ($cm -and (Test-IsExport $gc.Cfg $cm)) { $res += @{ Target = $name; Context = $gc } }
	}
	return ,$res
}

function Set-BslContext([string]$rel) {
	$script:bslContext = $script:bslCatalog[$rel.ToLower()]
}

# Resolve only an explicit, supported owner. Unknown variables are not aliases of ThisObject.
function Get-BslOwner([string]$owner, $ctx) {
	$k = $owner.Trim().ToLowerInvariant()
	if ($k.Length -ge 2 -and $k.StartsWith('"') -and $k.EndsWith('"')) { $k = $k.Substring(1, $k.Length - 2) }
	else { $k = $k -replace '\s+', '' }
	if ($k -eq '') { return $ctx }
	if ($k -in @('этаформа', 'thisform') -and $ctx.Kind -eq 'form') { return $ctx }
	if ($k -in @('этотобъект', 'thisobject') -and $ctx.Kind -in @('form', 'object')) { return $ctx }
	if ($script:bslCommon.ContainsKey($k)) { return $script:bslCommon[$k] }
	return $null
}

# Token indexes of call arguments; commas nested in calls/arrays/strings are not separators.
function Get-BslArguments($tokens, [int]$open) {
	$args2 = New-Object System.Collections.ArrayList; $part = New-Object System.Collections.ArrayList; $depth = 0
	for ($j = $open + 1; $j -lt $tokens.Count; $j++) {
		$v = $tokens[$j].Value
		if ($tokens[$j].Kind -eq 'punct') {
			if ($v -in @('(', '[')) { $depth++ }
			elseif ($v -in @(')', ']')) { if ($depth -eq 0) { [void]$args2.Add(@($part)); break }; $depth-- }
			elseif ($v -eq ',' -and $depth -eq 0) { [void]$args2.Add(@($part)); $part.Clear(); continue }
		}
		[void]$part.Add($j)
	}
	return ,$args2.ToArray()
}

# Result includes diagnostics; callers decide whether a complete transfer unit must stay manual.
function Get-BslConversion($lines, $fileMap, $ctx, $params = $null, [switch]$Comparison) {
	$all = @(Get-BslTokens $lines)
	$ts = @($all | Where-Object { $_.Kind -ne 'comment' -and $_.Value -notmatch '^\s+$' })
	$edits = @{}; $handled = @{}; $issues = @(); $warnings = @(); $references = @()
	$methods = @{}; $attrs = @{}
	if ($ctx) { foreach ($k in $ctx.Methods.Keys) { $methods[$k] = $ctx.Methods[$k] }; $attrs = $ctx.Attrs }
	foreach ($k in $fileMap.Keys) { $methods[$k] = $fileMap[$k] }
	for ($i = 0; $i -lt $ts.Count; $i++) {
		$t = $ts[$i]; if ($t.Kind -ne 'word') { continue }; $k = $t.Value.ToLowerInvariant()
		$owner = ''; $qualified = $i -gt 0 -and $ts[$i - 1].Value -eq '.'
		if ($qualified) {
			$a = $i - 2
			while ($a -gt 1 -and $ts[$a - 1].Value -eq '.' -and $ts[$a - 2].Kind -eq 'word') { $a -= 2 }
			$owner = (@($ts[$a..($i - 2)] | ForEach-Object { $_.Value }) -join '')
		}
		if ($qualified -and $params -contains ($owner -split '\.', 2)[0]) {
			if ($Comparison -and $script:bslCommon.ContainsKey((($owner -split '\.', 2)[0]).ToLowerInvariant())) {
				$edits[$t.Start] = '~' + [BitConverter]::ToString([text.encoding]::Unicode.GetBytes($k)).Replace('-', '') + '~'
			}
			continue
		}
		$oc = if (-not $Comparison) { Get-BslOwner $owner $ctx } else { $null }
		$om = if ($oc -and $oc -eq $ctx) { $methods } elseif ($oc) { $oc.Methods } else { @{} }
		$isCall = $i + 1 -lt $ts.Count -and $ts[$i + 1].Value -eq '('
		$isCtor = $i -gt 0 -and $ts[$i - 1].Value -in @('Новый', 'New')
		if ($Comparison -or (-not $qualified -and -not $isCall -and $params -contains $k)) { continue }
		if (-not $isCtor) {
			if ($om.ContainsKey($k) -and ($isCall -or -not $qualified)) { $edits[$t.Start] = $om[$k] }
			elseif (-not $qualified -and $attrs.ContainsKey($k)) { $edits[$t.Start] = $attrs[$k] }
			elseif ($qualified -and -not $isCall -and $oc.Attrs -and $oc.Attrs.ContainsKey($k)) { $edits[$t.Start] = $oc.Attrs[$k] }
			elseif (-not $qualified -and $i + 1 -lt $ts.Count -and $ts[$i + 1].Value -eq '.' -and $script:bslGlobals.ContainsKey($k)) { $edits[$t.Start] = $script:bslGlobals[$k] }
			elseif ($qualified -and $ctx -and $owner.ToLower() -in @('элементы', 'items', 'команды', 'commands') -and $ctx.FormNames.ContainsKey($k)) { $edits[$t.Start] = $ctx.FormNames[$k] }
			elseif ($qualified -and $ctx -and $owner.ToLower() -in @('объект', 'object') -and $ctx.Kind -eq 'form' -and $ctx.DataAttrs.ContainsKey($k)) { $edits[$t.Start] = $ctx.DataAttrs[$k] }
			elseif ($qualified -and -not $isCall -and $script:bslGlobals.ContainsKey($k)) { $edits[$t.Start] = $script:bslGlobals[$k] }
		}
		if (-not $isCall) { continue }
		if (-not $isCtor -and ($om.ContainsKey($k) -or ($qualified -and $oc.Kind -eq 'common'))) { continue }
		$specs = @()
		if ($k -in @('описаниеоповещения', 'notifydescription', 'callbackdescription')) {
			if ($i -eq 0 -or $ts[$i - 1].Value -notin @('Новый', 'New')) { continue }
			$specs = @(@{ Arg = 0; Owner = 1; Kind = 'method' }, @{ Arg = 3; Owner = 4; Kind = 'method' })
		} elseif ($k -in @('подключитьобработчикожидания', 'attachidlehandler', 'отключитьобработчикожидания', 'detachidlehandler')) {
			$specs = @(@{ Arg = 0; Owner = -1; Kind = 'method' })
		} elseif ($k -in @('установитьдействие', 'setaction')) {
			$specs = @(@{ Arg = 1; Owner = -1; Kind = 'method' })
		} elseif ($k -in @('реквизитформывзначение', 'formattributetovalue')) {
			$specs = @(@{ Arg = 0; Owner = -1; Kind = 'attribute' })
		}
		if (-not $specs.Count) { continue }
		$args2 = Get-BslArguments $ts ($i + 1)
		# SetAction's event name is explicitly not a method reference.
		if ($k -in @('setaction', 'установитьдействие') -and $args2.Count -gt 0 -and @($args2[0]).Count -eq 1) { $handled[$ts[$args2[0][0]].Start] = $true }
		foreach ($sp in $specs) {
			if ($args2.Count -le $sp.Arg -or @($args2[$sp.Arg]).Count -ne 1) { continue }
			$st = $ts[$args2[$sp.Arg][0]]; if ($st.Kind -ne 'string') { continue }
			$value = $st.Value.Substring(1, $st.Value.Length - 2).Replace('""', '"'); $sk = $value.ToLowerInvariant()
			$refOwner = $owner
			if ($sp.Owner -ge 0) {
				$refOwner = '?'
				if ($args2.Count -gt $sp.Owner) { $refOwner = (@($args2[$sp.Owner] | ForEach-Object { $ts[$_].Value }) -join '') }
			}
			$rc = if ($params -notcontains $refOwner) { Get-BslOwner $refOwner $ctx }
			if ($sp.Owner -ge 0 -and $rc -and $args2.Count -gt $sp.Owner -and @($args2[$sp.Owner]).Count -eq 1) {
				$mt = $ts[$args2[$sp.Owner][0]]
				if ($mt.Kind -eq 'string') {
					$mk = $mt.Value.Substring(1, $mt.Value.Length - 2).ToLower()
					$handled[$mt.Start] = $true
					if ($script:bslGlobals.ContainsKey($mk)) { $edits[$mt.Start] = '"' + $script:bslGlobals[$mk] + '"' }
				}
			}
			if ($k -in @('setaction', 'установитьдействие') -and $ctx.Kind -eq 'form' -and $refOwner -match '^(Элементы|Items)\.') { $rc = $ctx }
			if ($k -in @('attachidlehandler', 'detachidlehandler', 'подключитьобработчикожидания', 'отключитьобработчикожидания') -and -not $qualified -and $ctx.Kind -ne 'form') {
				$gs = @(Get-BslGlobalReferences $value)
				$targets2 = @($gs | ForEach-Object { $_.Target } | Sort-Object -Unique)
				$handled[$st.Start] = $true
				if ($targets2.Count -eq 1) {
					$edits[$st.Start] = '"' + $targets2[0] + '"'
					foreach ($gr in $gs) { $references += @{ Name = $value; Context = $gr.Context; Kind = 'method'; Token = $st } }
				} elseif ($targets2.Count -gt 1) {
					$issues += @{ Token = $st; Rename = "$value -> $($targets2 -join ', ')"; Why = 'global handler resolves to different target names' }
				}
				continue
			}
			$rm = if ($sp.Kind -eq 'attribute') { if ($rc -and $rc.Kind -eq 'form') { $rc.Attrs } else { @{} } } elseif ($rc -eq $ctx -and $rc) { $methods } elseif ($rc) { $rc.Methods } else { @{} }
			$handled[$st.Start] = $true
			if ($rm.ContainsKey($sk)) {
				$edits[$st.Start] = '"' + $rm[$sk].Replace('"', '""') + '"'
				$references += @{ Name = $value; Context = $rc; Kind = $sp.Kind; Token = $st }
			}
			elseif (-not $rc) {
				$matches = @()
				foreach ($c in $script:bslCatalog.Values) { $mm = if ($sp.Kind -eq 'attribute') { $c.Attrs } else { $c.Methods }; if ($mm.ContainsKey($sk) -and $mm[$sk] -ine $value) { $matches += "$value -> $($mm[$sk])" } }
				if ($matches.Count) { $issues += @{ Token = $st; Rename = (@($matches | Sort-Object -Unique) -join ', '); Why = 'handler owner is unknown; the current module map cannot be used' } }
			}
		}
	}
	foreach ($t in $ts) {
		if ($t.Kind -ne 'string' -or $handled.ContainsKey($t.Start)) { continue }
		$v = $t.Value.Substring(1, $t.Value.Length - 2).Replace('""', '"'); $k = $v.ToLowerInvariant()
		foreach ($pair in @(@{ Map = $methods; Kind = 'method' }, @{ Map = $attrs; Kind = 'attribute' })) {
			$renames2 = @{}
			$maps2 = @($pair.Map)
			foreach ($c2 in $script:bslCatalog.Values) { $maps2 += if ($pair.Kind -eq 'method') { $c2.Methods } else { $c2.Attrs } }
			foreach ($map2 in $maps2) { if ($map2.ContainsKey($k) -and $map2[$k] -ine $v) { $renames2[$map2[$k]] = "$v -> $($map2[$k])" } }
			if ($renames2.Count) { $warnings += @{ Token = $t; Kind = $pair.Kind; Rename = (@($renames2.Values | Sort-Object) -join ', ') } }
		}
	}
	$sb = New-Object System.Text.StringBuilder
	foreach ($t in $all) { if ($edits.ContainsKey($t.Start)) { [void]$sb.Append($edits[$t.Start]) } else { [void]$sb.Append($t.Value) } }
	return @{ Lines = @($sb.ToString() -split "`n", 0, 'SimpleMatch'); Issues = $issues; Warnings = $warnings; References = $references }
}

function Convert-BslCode($lines, $fileMap, $params = $null) {
	return ,@((Get-BslConversion $lines $fileMap $script:bslContext $params).Lines)
}

# Protect member names of shadowing parameters only in comparison keys.
function Protect-BslParameterMembers($lines, $params) {
	foreach ($name in $params) {
		if ($script:bslCommon.ContainsKey($name.ToLowerInvariant())) {
			return ,@((Get-BslConversion $lines @{} $null $params -Comparison).Lines)
		}
	}
	return ,@($lines)
}

# Project the effective method before lexing it: a payload may begin or end inside a literal.
# Ranges keep each raw edit's identity while strings and call arguments see the complete body.
function Get-ControlProjection($body, $fileMap, [string]$prefix, $params = $null) {
	$desired = @(); $source = @(); $ranges = @{}; $opIndex = -1; $i = 0
	while ($i -lt $body.Count) {
		$kind2 = Get-BslMarkerKind $body[$i]
		if ($kind2 -in @('Insert', 'Delete')) {
			$opIndex++; $i++; $start2 = $desired.Count
			$endKind = if ($kind2 -eq 'Insert') { 'EndInsert' } else { 'EndDelete' }
			while ($i -lt $body.Count -and (Get-BslMarkerKind $body[$i]) -ne $endKind) {
				if ($kind2 -eq 'Insert') { $desired += $body[$i]; $source += $i }; $i++
			}
			$ranges[$opIndex] = @{ Start = $start2; End = $desired.Count }; $i++
		} else { $desired += $body[$i]; $source += $i; $i++ }
	}
	$converted2 = Convert-BslCode $desired $fileMap $params
	$keys2 = @(Get-CodeKeys $converted2 $prefix -params $params)
	$payloads2 = @{}; $payloadKeys2 = @{}
	foreach ($k2 in $ranges.Keys) {
		$r2 = $ranges[$k2]; $ls2 = @(); $ks2 = @()
		for ($j2 = $r2.Start; $j2 -lt $r2.End; $j2++) { $ls2 += $converted2[$j2]; $ks2 += $keys2[$j2] }
		$payloads2[$k2] = $ls2; $payloadKeys2[$k2] = $ks2
	}
	return @{ Desired = $desired; Source = $source; Ranges = $ranges; Payloads = $payloads2; PayloadKeys = $payloadKeys2; Keys = $keys2 }
}

function Get-BslPlanIssue($plan) {
	$methods2 = @(); if ($plan.ExtM) { $methods2 += $plan.ExtM }
	foreach ($h2 in @($plan.Handlers)) { if ($h2.ExtM) { $methods2 += $h2.ExtM } }
	$allowed = $null
	if ($plan.Kind -eq 'topcode') {
		$methods2 += @{ BodyLines = $plan.ExtLines; SigEndIdx = -1 }
		$allowed = Get-TopCodeKeys $plan.ExtLines $script:transferPrefix
	}
	foreach ($m2 in $methods2) {
		$ls2 = $m2.BodyLines; $sourceMap = $null
		if ($plan.Kind -eq 'control') { $projection2 = Get-ControlProjection $ls2 @{} $script:transferPrefix $m2.ParamNames; $ls2 = $projection2.Desired; $sourceMap = $projection2.Source }
		$r2 = Get-BslConversion $ls2 @{} $script:bslContext $m2.ParamNames
		foreach ($issue2 in $r2.Issues) {
			$offset2 = ([regex]::Matches((@($ls2) -join "`n").Substring(0, $issue2.Token.Start), "`n")).Count
			if ($null -ne $allowed -and -not $allowed.Contains([string]$offset2)) { continue }
			if ($null -ne $sourceMap) { $offset2 = $sourceMap[$offset2] }
			return @{ Method = $m2; Issue = $issue2; Offset = $offset2 }
		}
	}
	return $null
}

function Get-BslManualDetails($plan, $problem) {
	$m2 = $problem.Method; $issue = $problem.Issue
	$offset2 = $problem.Offset
	return @("from: extension $($plan.Rel):$($m2.SigEndIdx + 2 + $offset2)",
		"code: $(([string]$m2.BodyLines[$offset2]).Trim())", "rename: $($issue.Rename)",
		'next: resolve the handler context in the extension, or copy the complete method and verify its handler by hand; then re-run -Mode transfer')
}

function Get-BslBlockedDependencies($plan, $byFile, $common) {
	$missing2 = @{}
	foreach ($map2 in @($byFile[(Get-CfgPath $plan.Rel).ToLower()], $common)) {
		if ($map2) { foreach ($k2 in $map2.Keys) { $missing2[$k2] = $map2[$k2] } }
	}
	$methods2 = @($plan.ExtM) + @(foreach ($h2 in @($plan.Handlers)) { $h2.ExtM })
	$deps2 = @(foreach ($m2 in $methods2) { if ($m2) { Get-UsedMissing $m2.BodyLines $missing2 $null $m2.ParamNames } })
	$deps2 = [string[]]@($deps2 | Select-Object -Unique)
	[Array]::Sort($deps2, [StringComparer]::OrdinalIgnoreCase)
	return $deps2
}

# Scan the final method by its owner and declaration, never by a potentially repeated text line.
# Diagnostics live in the footer so folding and pagination cannot hide them.
function Get-BslWarningReport($records, [string]$extDir) {
	$result = @(); $seen = @{}
	if ($Mode -eq 'transfer') {
		foreach ($ctx2 in $script:bslCatalog.Values) {
			$fk2 = (Get-CfgPath $ctx2.Rel).ToLower()
			if ($fileMaps.ContainsKey($fk2)) { foreach ($k2 in $fileMaps[$fk2].Keys) { $ctx2.Methods[$k2] = $fileMaps[$fk2][$k2] } }
		}
	}
	foreach ($rec in $records) {
		$units = @($rec.Items)
		foreach ($it2 in $rec.Items) { foreach ($h2 in @($it2.Plan.Handlers)) {
			if ($h2.ExtM) { $units += @{ Status = $it2.Status; Plan = @{ Kind = 'own'; Rel = $it2.Plan.Rel; ExtM = $h2.ExtM; Name = $h2.Handler } } }
		} }
		foreach ($it in $units) {
		$pl = $it.Plan
		if (-not $pl -or (-not $pl.ExtM -and $pl.Kind -ne 'topcode') -or -not $pl.Rel) { continue }
		$ctx = $script:bslCatalog[$pl.Rel.ToLower()]; if (-not $ctx) { continue }
		$key = "$($pl.Rel)|$($pl.ExtM.DeclIdx)"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
		$side = 'extension'; $m = $pl.ExtM
		$allowed = $null
		if ($pl.Kind -eq 'topcode') {
			$src2 = $pl.ExtLines
			if ($it.Status -eq 'TRANSFERRED') { $src2 = Read-BslLines (Get-CfgPath $pl.Rel); $side = 'config' }
			$m = @{ BodyLines = $src2; SigEndIdx = -1 }; $allowed = Get-TopCodeKeys $src2 $script:transferPrefix
		}
		if ($it.Status -eq 'TRANSFERRED' -and $pl.Kind -ne 'topcode') {
			$name = if ($pl.Kind -eq 'own') { $ctx.Methods[$pl.Name.ToLower()] } elseif ($pl.CfgM) { $pl.CfgM.Canonical } elseif ($pl.Handler) { $ctx.Methods[$pl.Handler.ToLower()] } else { '' }
			$cm = Get-MethodSafe (Read-BslLines (Get-CfgPath $pl.Rel)) $name
			if ($cm) { $m = $cm; $side = 'config' }
		}
		$bc = Get-BslConversion $m.BodyLines @{} $ctx $m.ParamNames
		$text = @($m.BodyLines) -join "`n"
		foreach ($w in $bc.Warnings) {
			$line = $m.SigEndIdx + 2 + ([regex]::Matches($text.Substring(0, $w.Token.Start), "`n")).Count
			if ($null -ne $allowed -and -not $allowed.Contains([string]($line - 1))) { continue }
			$snippet = @($m.BodyLines)[$line - $m.SigEndIdx - 2].Trim()
			$result += "[WARNING] string matches a renamed $($w.Kind); left unchanged"
			$result += "  to:   $side $($pl.Rel):$line"
			$result += "  code: $snippet"
			$result += "  rename: $($w.Rename)"
			$result += "  next: check whether the string refers to this $($w.Kind)"
		}
	} }
	if ($result.Count) { return ,(@("Warnings: $($result.Count / 5)") + $result) }
	return ,@()
}


# Legacy XML value conversion. BSL uses Convert-BslCode and its owner-scoped symbol catalog.
function Convert-ExtCode($lines, $fileMap) {
	$prefix = $script:transferPrefix
	$keys = @()
	foreach ($m in @($fileMap, $script:nameMap)) { foreach ($k in $m.Keys) { if (-not $prefix -or -not $k.StartsWith($prefix.ToLower())) { $keys += [regex]::Escape($k) } } }
	$alts = @($keys | Sort-Object -Property Length -Descending -Unique)
	if ($prefix) { $alts += ([regex]::Escape($prefix) + '\w+') }
	if ($alts.Count -eq 0) { return ,@($lines) }
	$re = New-Object System.Text.RegularExpressions.Regex ('(?<!\w)(?:' + ($alts -join '|') + ')(?!\w)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	$ev = [System.Text.RegularExpressions.MatchEvaluator] {
		param($m)
		$k = $m.Value.ToLower()
		if ($fileMap.ContainsKey($k)) { return $fileMap[$k] }
		if ($script:nameMap.ContainsKey($k)) { return $script:nameMap[$k] }
		if ($prefix -and $k.StartsWith($prefix.ToLower())) { return $m.Value.Substring($prefix.Length) }
		return $m.Value
	}
	$out = @()
	foreach ($l in $lines) { $out += $re.Replace([string]$l, $ev) }
	return ,$out
}

# Regions of a module, nested ones included: @{ Name; Start; End } (line indexes of the markers)
function Get-Regions($lines) {
	$reRegion = '^\s*#' + (Get-KwAlt 'Region') + '\s+(\S+)'
	$reEnd = '^\s*#' + (Get-KwAlt 'EndRegion') + '(?![\w])'
	$stack = New-Object System.Collections.ArrayList
	$res = @()
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$t = $lines[$i]
		if ($t -imatch $reRegion) { [void]$stack.Add(@{ Name = $Matches[1]; Start = $i; End = -1 }) }
		elseif ($t -imatch $reEnd -and $stack.Count -gt 0) { $r = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1); $r.End = $i; $res += $r }
	}
	return ,$res
}

function Get-ModuleKind([string]$rel) {
	$r = $rel -replace '\\', '/'
	if ($r -match '/Ext/Form/Module\.bsl$') { return 'form' }
	if ($r -match '^CommonModules/') { return 'common' }
	if ($r -match '/Ext/(?:ObjectModule|ManagerModule|RecordSetModule|ValueManagerModule)\.bsl$') { return 'object' }
	return 'other'
}

# Handlers a form binds (its own part, BaseForm left out): lower-case name -> @{ Role; Table }
function Get-FormBindings([string]$formXml) {
	$res = @{}
	if (-not $formXml -or -not (Test-Path -LiteralPath $formXml)) { return $res }
	$doc = New-Object System.Xml.XmlDocument
	try { $doc.Load($formXml) } catch { return $res }
	$root = $doc.DocumentElement
	$order = @($script:regionDefaults.Keys)
	$put = { param([string]$h, [string]$role, [string]$table)
		if (-not $h) { return }
		$k = $h.Trim().ToLower()
		if ($res.ContainsKey($k) -and $order.IndexOf($res[$k].Role) -le $order.IndexOf($role)) { return }
		$res[$k] = @{ Role = $role; Table = $table }
	}
	foreach ($ev in $root.SelectNodes("//*[local-name()='Event']")) {
		$owner = $ev.ParentNode.ParentNode
		$inBase = $false; $table = ''
		for ($n = $owner; $n -and $n -ne $root; $n = $n.ParentNode) {
			if ($n.LocalName -eq 'BaseForm') { $inBase = $true; break }
			if (-not $table -and $n.LocalName -eq 'Table') { $table = $n.GetAttribute('name') }
		}
		if ($inBase) { continue }
		$role = if ($owner -eq $root) { 'formEvents' } elseif ($table) { 'tableItemEvents' } else { 'headerItemEvents' }
		& $put $ev.InnerText $role $table
	}
	foreach ($a in $root.SelectNodes("//*[local-name()='Command']/*[local-name()='Action']")) {
		$inBase = $false
		for ($n = $a; $n -and $n -ne $root; $n = $n.ParentNode) { if ($n.LocalName -eq 'BaseForm') { $inBase = $true; break } }
		if (-not $inBase) { & $put $a.InnerText 'commands' '' }
	}
	return $res
}

# Procedures a module names in Новый ОписаниеОповещения("Имя", ...)
function Get-NotifyNames($lines) {
	$res = @{}
	$re = '(?i)(?:Новый|New)\s+(?:ОписаниеОповещения|NotifyDescription|CallbackDescription)\s*\(\s*"([\w]+)"'
	foreach ($l in @($lines)) { foreach ($m in [regex]::Matches([string]$l, $re)) { $res[$m.Groups[1].Value.ToLower()] = $true } }
	return $res
}

function Test-IsExport($lines, $m) {
	$t = (Get-CodeOnly @($lines[$m.SigEndIdx]) -KeepStrings)[0]
	$i = $t.LastIndexOf(')')
	return ($i -ge 0 -and $t.Substring($i + 1) -imatch '^\s*(?:Экспорт|Export)(?![\w])')
}

# Role of an own method: the first one by the order of the regions table
function Get-MethodRole([string]$name, [string]$kind, $bind, $notify, [bool]$export) {
	$k = $name.ToLower()
	if ($kind -eq 'form' -and $bind.ContainsKey($k)) { return @{ Role = $bind[$k].Role; Table = $bind[$k].Table } }
	if ($kind -eq 'form' -and $notify.ContainsKey($k)) { return @{ Role = 'notifications'; Table = '' } }
	if ($kind -eq 'object' -and ($script:objectEventNames -icontains $name)) { return @{ Role = 'objectEvents'; Table = '' } }
	if ($export -and $kind -ne 'form') { return @{ Role = 'api'; Table = '' } }
	return @{ Role = 'service'; Table = '' }
}

# Where an own method goes in the configuration's module. First the region it sits in, in the
# extension, if the module has it — unless that is the service region and the method has a role of
# its own (a service region often collects everything); then the region of the role; then a new one
# (createRegions), the service region, the end of the module.
function Get-MethodPlace($cfgLines, $regions, $extM, $role, $set, $created) {
	# {table}: the table's name as the configuration gets it
	$table = if ($role.Table) { [string](Convert-ExtCode @($role.Table) @{})[0] } else { '' }
	$names = { param([string]$r) @($set.Regions[$r] | ForEach-Object { ([string]$_).Replace('{table}', $table) }) }
	$find = { param([string]$n) @($regions | Where-Object { $_.Name -ieq $n })[0] }
	$service = @(& $names 'service')
	$chain = @($extM.Chain | Where-Object { $_.Kind -eq 'region' })
	for ($i = $chain.Count - 1; $i -ge 0; $i--) {
		$r = & $find $chain[$i].Name
		if (-not $r) { continue }
		if ($role.Role -ne 'service' -and ($service -icontains $r.Name)) { break }
		return @{ At = $r.End; Region = $r.Name }
	}
	$roleNames = @(& $names $role.Role)
	foreach ($n in $roleNames) { $r = & $find $n; if ($r) { return @{ At = $r.End; Region = $r.Name } } }
	foreach ($n in $roleNames) { if ($created.Contains($n.ToLower())) { return @{ Create = $n } } }
	if ($set.CreateRegions -and $roleNames.Count -gt 0) { return @{ Create = $roleNames[0] } }
	foreach ($n in $service) { $r = & $find $n; if ($r) { return @{ At = $r.End; Region = $r.Name } } }
	return @{ At = (Get-ModuleEnd $cfgLines); Region = '' }
}

# Where methods appended to a module go: before the statements of the module body after the last method
# (a method after them would not compile), else the module's tail (Get-ModuleTail)
function Get-ModuleEnd($lines) {
	$tail = Get-ModuleTail $lines
	$lay = Get-ModuleLayout $lines
	$body = @($lay.Statements | Where-Object { $_ -ge $lay.AfterMethods -and $_ -lt $tail })
	if ($body.Count -eq 0) { return $tail }
	$s = $body[0]
	while ($s -gt 0 -and (([string]$lines[$s - 1]).Trim() -match '^(//|&)')) { $s-- }
	return $s
}

# The tail of a module, where statements of the module body are added after the existing ones: its end,
# or — in a module wrapped whole in #Если Сервер ... Тогда ... [#Иначе ВызватьИсключение ...] #КонецЕсли —
# before the wrapper's #Иначе (#КонецЕсли when it has none): after the wrapper the code would not compile
function Get-ModuleTail($lines) {
	$n = @($lines).Count
	$skip = { param([string]$t) $t = $t.Trim(); ($t -eq '' -or $t.StartsWith('//')) }
	$i = $n - 1
	while ($i -ge 0 -and (& $skip $lines[$i])) { $i-- }
	if ($i -lt 0 -or $lines[$i] -notmatch '^\s*#(КонецЕсли|EndIf)(?!\w)') { return $n }
	$depth = 0; $else = -1
	for ($j = $i; $j -ge 0; $j--) {
		$t = $lines[$j]
		if ($t -match '^\s*#(КонецЕсли|EndIf)(?!\w)') { $depth++ }
		elseif ($t -match '^\s*#(Если|If)(?!\w)') {
			$depth--
			if ($depth -gt 0) { continue }
			# A wrapper only when nothing but comments stands above it
			for ($k = 0; $k -lt $j; $k++) { if (-not (& $skip $lines[$k])) { return $n } }
			if ($else -ge 0) { return $else } else { return $i }
		}
		elseif ($depth -eq 1 -and $t -match '^\s*#(Иначе|ИначеЕсли|Else|ElsIf)(?!\w)') { $else = $j }
	}
	return $n
}

# Language of a module's keywords: the first region or method declaration decides (Russian without any)
function Get-ModuleLang($lines) {
	foreach ($l in @($lines)) {
		if ($l -match '^\s*(#Область|Процедура|Функция)(?!\w)') { return 'ru' }
		if ($l -match '^\s*(#Region|Procedure|Function)(?!\w)') { return 'en' }
	}
	return 'ru'
}

# A .bsl file read for writing back as it was: BOM, line breaks, final line break
function Read-BslFile([string]$path) {
	$bytes = [System.IO.File]::ReadAllBytes($path)
	$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
	$off = if ($bom) { 3 } else { 0 }
	$text = [System.Text.Encoding]::UTF8.GetString($bytes, $off, $bytes.Length - $off)
	$eol = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { "`r`n" }
	$final = ($text.EndsWith("`n") -or $text.EndsWith("`r"))
	$lines = if ($text -eq '') { @() } else { @($text -split "`r`n|`n|`r") }
	if ($final -and $lines.Count -gt 0) { $lines = @($lines[0..($lines.Count - 2)]) }
	return @{ Path = $path; Lines = $lines; Bom = $bom; Eol = $eol; Final = $final }
}

function Write-BslFile($f, $lines) {
	$text = ($lines -join $f.Eol)
	if ($f.Final) { $text += $f.Eol }
	$enc = New-Object System.Text.UTF8Encoding($f.Bom)
	[System.IO.File]::WriteAllText($f.Path, $text, $enc)
}

function Get-Indent([string]$line) { if ($line -match '^(\s*)') { return $Matches[1] } else { return '' } }

# The pending edits of an &ИзменениеИКонтроль method laid onto the configuration's body: inserts
# after their anchor, deletions removed or commented out, each framed by the project's comments
function Get-ControlBody($cfgM, $plan, $frame, [string]$deletion, $fileMap, $extM) {
	$projection2 = Get-ControlProjection $extM.BodyLines $fileMap $script:transferPrefix $extM.ParamNames
	$v2 = @($cfgM.BodyLines)
	$insAfter = @{}; $delAt = @{}
	foreach ($e in $plan) {
		if ($e.Res -ne 'pending') { continue }
		if ($e.Op.Kind -eq 'insert') { $k = [int]$e.At; if (-not $insAfter.ContainsKey($k)) { $insAfter[$k] = @() }; $insAfter[$k] += $e.Op }
		else { $delAt[[int]$e.At] = ($e.Op.End - $e.Op.Start + 1) }
	}
	$out = New-Object System.Collections.Generic.List[string]
	$emitIns = {
		param($op)
		$lines = @($projection2.Payloads[$op.SourceIndex])
		$first = @($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
		$ind = if ($first.Count -gt 0) { Get-Indent $first[0] } else { Get-Indent ([string]$op.Open) }
		if ($frame.Begin) { $out.Add("$ind$($frame.Begin)") }
		# A note on the opening marker (#Вставка // why) stays with the code
		if ($op.Open) { $ci = $op.Open.IndexOf('//'); if ($ci -ge 0) { $out.Add("$ind$($op.Open.Substring($ci).Trim())") } }
		foreach ($l in $lines) { $out.Add($l) }
		if ($frame.End) { $out.Add("$ind$($frame.End)") }
	}
	if ($insAfter.ContainsKey(-1)) { foreach ($op in $insAfter[-1]) { & $emitIns $op } }
	$i = 0
	while ($i -lt $v2.Count) {
		if ($delAt.ContainsKey($i)) {
			$len = $delAt[$i]
			if ($deletion -eq 'comment') {
				$first = @($v2[$i..($i + $len - 1)] | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
				$ind = if ($first.Count -gt 0) { Get-Indent $first[0] } else { '' }
				if ($frame.Begin) { $out.Add("$ind$($frame.Begin)") }
				for ($j = $i; $j -lt $i + $len; $j++) { $out.Add("//$($v2[$j])") }
				if ($frame.End) { $out.Add("$ind$($frame.End)") }
			}
			for ($j = $i; $j -lt $i + $len; $j++) { if ($insAfter.ContainsKey($j)) { foreach ($op in $insAfter[$j]) { & $emitIns $op } } }
			$i += $len
			continue
		}
		$out.Add($v2[$i])
		if ($insAfter.ContainsKey($i)) { foreach ($op in $insAfter[$i]) { & $emitIns $op } }
		$i++
	}
	return ,$out.ToArray()
}

# ============================================================
# &Перед / &После / &Вместо: the handler's code put into the original's body
# ============================================================

# Each line's code without comments; string literals are kept (-KeepStrings) or left as "" — a
# literal that runs on over lines (the | continuation) is followed from line to line
function Get-CodeOnly($lines, [switch]$KeepStrings) {
	if (@($lines).Count -eq 0) { return ,@() }
	$src = @($lines) -join "`n"
	$sb = New-Object System.Text.StringBuilder; $pos2 = 0
	foreach ($m2 in [regex]::Matches($src, ('//[^\r\n]*|' + $script:bslLiteralRe))) {
		[void]$sb.Append($src.Substring($pos2, $m2.Index - $pos2))
		if (-not $m2.Value.StartsWith('//')) {
			if ($KeepStrings) { [void]$sb.Append($m2.Value) }
			else {
				[void]$sb.Append('"')
				[void]$sb.Append(("`n" * ([regex]::Matches($m2.Value, "`n")).Count))
				if ($m2.Value.Length -ge 2 -and $m2.Value.EndsWith('"')) { [void]$sb.Append('"') }
			}
		}
		$pos2 = $m2.Index + $m2.Length
	}
	[void]$sb.Append($src.Substring($pos2))
	return ,@($sb.ToString() -split "`n", 0, 'SimpleMatch')
}

# Parameter substitutions share the BSL lexer: member names, literals and comments retain identity.
function Rename-CodeWords($lines, $map) {
	if ($map.Count -eq 0 -or @($lines).Count -eq 0) { return ,@($lines) }
	$sb = New-Object System.Text.StringBuilder; $previous = ''
	foreach ($t in @(Get-BslTokens $lines)) {
		$k = $t.Value.ToLowerInvariant()
		if ($t.Kind -eq 'word' -and $previous -notin @('.', 'Новый', 'New') -and $map.ContainsKey($k)) { [void]$sb.Append($map[$k]) }
		else { [void]$sb.Append($t.Value) }
		if ($t.Kind -ne 'comment' -and $t.Value -notmatch '^\s+$') { $previous = $t.Value }
	}
	return ,@($sb.ToString() -split "`n", 0, 'SimpleMatch')
}

$script:icOpenRe = '(?i)(?<![\w.])(?:Если|If|Для|For|Пока|While|Попытка|Try)(?!\w)'
$script:icCloseRe = '(?i)(?<![\w.])(?:КонецЕсли|EndIf|КонецЦикла|EndDo|КонецПопытки|EndTry)(?!\w)'
$script:icRetRe = '(?i)(?<![\w.])(?:Возврат|Return)(?!\w)'
$script:icProceedRe = '(?i)(?<![\w.])(?:ПродолжитьВызов|ProceedWithCall)\s*\('
$script:icVarRe = '(?i)^\s*(?:Перем|Var)(?!\w)'
$script:icBareRetRe = '(?i)^(?:Возврат|Return)\s*;?$'
# Where one statement ends and the next may start within a line
$script:icStmtRe = '(?i);|(?<![\w.])(?:Тогда|Иначе|Цикл|Попытка|Исключение|Then|Else|Do|Try|Except)(?!\w)'

# Is line $i the terminal Возврат of a body, and a bare one (without a value)?
function Test-BareTerm($shape, $code, [int]$i) {
	return ($i -eq $shape.Term -and ([string]$code[$i]).Trim() -match $script:icBareRetRe)
}

# Shape of a body from its code lines: block depth before each line, blocks opened on it, Возврат on
# it (inside a block when the line opens one too); the last line with code and whether it is a
# lone Возврат at the top level (the terminal one)
function Get-BodyShape($code) {
	$n = @($code).Count
	$depth = New-Object int[] $n; $ret = New-Object bool[] $n; $inBlock = New-Object bool[] $n
	$d = 0; $last = -1
	for ($i = 0; $i -lt $n; $i++) {
		$t = [string]$code[$i]
		$depth[$i] = $d
		$o = [regex]::Matches($t, $script:icOpenRe).Count
		$c = [regex]::Matches($t, $script:icCloseRe).Count
		if ($t -match $script:icRetRe) { $ret[$i] = $true; $inBlock[$i] = ($d -gt 0 -or $o -gt 0) }
		$d += $o - $c; if ($d -lt 0) { $d = 0 }
		$tt = $t.Trim()
		if ($tt -ne '' -and -not $tt.StartsWith('#')) { $last = $i }
	}
	$term = -1
	if ($last -ge 0 -and $ret[$last] -and -not $inBlock[$last] -and ([string]$code[$last]).Trim() -match '(?i)^(?:Возврат|Return)(?!\w)[^;]*;?$') { $term = $last }
	return @{ Ret = $ret; InBlock = $inBlock; Depth = $depth; Last = $last; Term = $term }
}

# Local variables of a body (assigned, loop variables, Перем), parameters left out: lower -> name.
# A line may hold several statements (Если … Тогда Х = 1; КонецЕсли;): each is looked at.
function Get-LocalNames($code, $params) {
	$skip = @{}; foreach ($p in @($params)) { $skip[$p.ToLower()] = $true }
	$res = [ordered]@{}
	$add = { param($n) if ($n -and -not $skip.ContainsKey($n.ToLower()) -and -not $res.Contains($n.ToLower())) { $res[$n.ToLower()] = $n } }
	foreach ($l in @($code)) {
		foreach ($t in [regex]::Split([string]$l, $script:icStmtRe)) {
			if ($t -match '^\s*([\w]+)\s*=') { & $add $Matches[1] }
			if ($t -match '(?i)^\s*(?:Для\s+Каждого|For\s+Each)\s+([\w]+)') { & $add $Matches[1] }
			elseif ($t -match '(?i)^\s*(?:Для|For)\s+([\w]+)\s*=') { & $add $Matches[1] }
		}
		if ([string]$l -match ($script:icVarRe + '\s+([^;]*)')) { foreach ($v in $Matches[1].Split(',')) { & $add (($v.Trim() -split '\s+')[0]) } }
	}
	return $res
}

# Names a body assigns to (any statement of a line), lower case
function Get-AssignedNames($code) {
	$set = New-Object 'System.Collections.Generic.HashSet[string]'
	foreach ($l in @($code)) {
		foreach ($t in [regex]::Split([string]$l, $script:icStmtRe)) {
			if ($t -match '^\s*([\w]+)\s*=') { [void]$set.Add($Matches[1].ToLower()) }
			# A loop variable is assigned too
			if ($t -match '(?i)^\s*(?:Для\s+Каждого|For\s+Each)\s+([\w]+)') { [void]$set.Add($Matches[1].ToLower()) }
			elseif ($t -match '(?i)^\s*(?:Для|For)\s+([\w]+)\s*=') { [void]$set.Add($Matches[1].ToLower()) }
		}
	}
	return ,$set
}

# Знач of each parameter, by position
function Get-ValFlags([string]$paramsText) {
	if ($paramsText.Trim() -eq '') { return ,@() }
	return ,@(Split-TopLevel $paramsText | ForEach-Object { $_ -match ('(?i)^\s*' + (Get-KwAlt 'Val') + '\s') })
}

function Get-WordSet($code) {
	$set = New-Object 'System.Collections.Generic.HashSet[string]'
	foreach ($l in @($code)) { foreach ($m in [regex]::Matches([string]$l, '[\w]+')) { [void]$set.Add($m.Value.ToLower()) } }
	return ,$set
}

# Lines framed by the project's comments, at the indent of their first code line
function Get-Framed($lines, $frame) {
	$lines = @($lines)
	$first = @($lines | Where-Object { ([string]$_).Trim() -ne '' } | Select-Object -First 1)
	$ind = if ($first.Count -gt 0) { Get-Indent $first[0] } else { '' }
	$out = @()
	if ($frame.Begin) { $out += "$ind$($frame.Begin)" }
	$out += $lines
	if ($frame.End) { $out += "$ind$($frame.End)" }
	return ,$out
}

# Original lines that leave: commented out and framed, or gone (deletion = remove)
function Get-Removed($lines, $frame, [string]$deletion) {
	if ($deletion -ne 'comment') { return ,@() }
	return ,(Get-Framed @(@($lines) | ForEach-Object { "//$_" }) $frame)
}

# Blank lines off both ends
function Get-Trimmed($lines) {
	$a = @($lines)
	$s = 0; $e = $a.Count - 1
	while ($s -le $e -and ([string]$a[$s]).Trim() -eq '') { $s++ }
	while ($e -ge $s -and ([string]$a[$e]).Trim() -eq '') { $e-- }
	if ($s -gt $e) { return ,@() }
	return ,@($a[$s..$e])
}

# Index of the last Перем line in the leading run of Перем, blank and comment lines (-1: none)
function Get-VarEnd($lines, $code) {
	$end = -1
	for ($i = 0; $i -lt @($lines).Count; $i++) {
		$t = ([string]$code[$i]).Trim()
		if ($t -eq '') { continue }
		if ($t -match $script:icVarRe) { $end = $i; continue }
		break
	}
	return $end
}

# Edits that put an interceptor's code into the original's body, as insertions after an index of the
# original's body (-1: at the top) and replacements of a range of it; or the reason it cannot be done
function Get-InterceptOps($extM, $cfgM, [string]$type, $frame, [string]$deletion, $fileMap) {
	if ([bool]$extM.IsAsync -ne [bool]$cfgM.IsAsync) { return @{ Why = 'Асинх differs between the handler and the original' } }
	$ep = @($extM.ParamNames); $cp = @($cfgM.ParamNames)
	if ($ep.Count -ne $cp.Count) { return @{ Why = "parameters differ from the original's" } }
	# The platform does not apply an interceptor whose Знач differs from the original's: its code never ran
	$ev = Get-ValFlags $extM.ParamsText; $cv = Get-ValFlags $cfgM.ParamsText
	if (($ev -join ',') -ne ($cv -join ',')) { return @{ Why = "the interceptor never applied: Знач differs from the original's"; Next = 'fix the signature in the extension or drop the interceptor, then re-run -Mode check' } }
	$valNames = @(for ($i = 0; $i -lt $cp.Count; $i++) { if ($cv[$i]) { $cp[$i].ToLower() } })
	$map = @{}
	for ($i = 0; $i -lt $ep.Count; $i++) { if ($ep[$i] -cne $cp[$i]) { $map[$ep[$i].ToLowerInvariant()] = $cp[$i] } }
	$h = Convert-BslCode (Rename-CodeWords $extM.BodyLines $map) $fileMap $cp
	$o = @($cfgM.BodyLines)
	$hc = Get-CodeOnly $h; $oc = Get-CodeOnly $o
	$hs = Get-BodyShape $hc; $os = Get-BodyShape $oc
	$oVar = Get-VarEnd $o $oc
	# A local of the handler the original also names, or the other way round, becomes one variable
	$clash = {
		$hl = Get-LocalNames $hc $cp; $ol = Get-LocalNames $oc $cp
		$hw = Get-WordSet $hc; $ow = Get-WordSet $oc
		$names = @(@($hl.Keys | Where-Object { $ow.Contains($_) } | ForEach-Object { $hl[$_] }) + @($ol.Keys | Where-Object { $hw.Contains($_) } | ForEach-Object { $ol[$_] }) | Select-Object -Unique)
		if ($names.Count -gt 0) { return "variable $($names -join ', ') is in both the handler and the original" }
		return $null
	}
	# The original's Возврат lines other than a bare terminal one: code put after its body would be skipped
	$oEarly = { for ($i = 0; $i -lt $o.Count; $i++) { if ($os.Ret[$i] -and -not (Test-BareTerm $os $oc $i)) { return $true } }; return $false }
	# Where code goes after the original's body: before its bare terminal Возврат, else after its last line
	$oTail = {
		$end = if ($os.Term -ge 0 -and (Test-BareTerm $os $oc $os.Term)) { $os.Term } else { $o.Count }
		for ($i = $end - 1; $i -ge 0; $i--) { if ($o[$i].Trim() -ne '') { return $i } }
		return $oVar
	}
	# A handler part: its Перем lines go up to the original's, the rest stays in place
	$split = {
		param([int]$from, [int]$to, [bool]$dropTerm)
		$vars = @(); $rest = @()
		for ($i = $from; $i -le $to; $i++) {
			if ($dropTerm -and (Test-BareTerm $hs $hc $i)) { continue }
			if ($hc[$i] -match $script:icVarRe) { $vars += $h[$i] } else { $rest += $h[$i] }
		}
		return @{ Vars = $vars; Code = (Get-Trimmed $rest) }
	}
	$ops = New-Object System.Collections.ArrayList
	# Rank orders edits at one spot, whatever interceptor they come from: Перем, then code that runs
	# before the original, then code that runs after it
	$put = {
		param([int]$after, $part, [int]$rank)
		if ($part.Vars.Count -gt 0) { [void]$ops.Add(@{ Kind = 'insert'; After = $oVar; Lines = (Get-Framed $part.Vars $frame); Rank = 0 }) }
		if ($part.Code.Count -gt 0) { [void]$ops.Add(@{ Kind = 'insert'; After = $after; Lines = (Get-Framed $part.Code $frame); Rank = $rank }) }
	}
	# What the handler's code names: another interceptor of the method must not share its locals
	$done = { param($where) @{ Ops = $ops; Where = $where; Locals = (Get-LocalNames $hc $cp); Words = (Get-WordSet $hc) } }
	$last = $h.Count - 1
	# Знач parameters: the handler and the original each had a copy. What one of them changed the other
	# did not see; in one body it would.
	$valCheck = {
		param([string]$side, [int]$from)
		$names = @()
		if ($side -eq 'handler') {
			$as = Get-AssignedNames $hc
			$names = @($valNames | Where-Object { $as.Contains($_) })
			if ($names.Count -gt 0) { return "the handler changes Знач parameter $(($names | ForEach-Object { $n = $_; @($cp | Where-Object { $_ -ieq $n })[0] }) -join ', '): the original did not see it" }
		} else {
			$as = Get-AssignedNames $oc
			$ws = Get-WordSet @(if ($from -le $last) { $hc[$from..$last] })
			$names = @($valNames | Where-Object { $as.Contains($_) -and $ws.Contains($_) })
			if ($names.Count -gt 0) { return "the original changes Знач parameter $(($names | ForEach-Object { $n = $_; @($cp | Where-Object { $_ -ieq $n })[0] }) -join ', '): the handler did not see it" }
		}
		return $null
	}
	if ($type -eq 'Перед' -or $type -eq 'После') {
		if ($cfgM.IsFunction) { return @{ Why = 'a function cannot have &Перед/&После' } }
		$why = & $clash; if ($why) { return @{ Why = $why } }
		if ($type -eq 'Перед') {
			for ($i = 0; $i -le $last; $i++) {
				if ($hs.Ret[$i] -and -not (Test-BareTerm $hs $hc $i)) { return @{ Why = 'Возврат in the handler would skip the original' } }
			}
			$why = & $valCheck 'handler' 0; if ($why) { return @{ Why = $why } }
			& $put $oVar (& $split 0 $last $true) 1
			return (& $done 'before the original')
		}
		if (& $oEarly) { return @{ Why = 'the original returns early: the code after it would be skipped' } }
		$why = & $valCheck 'original' 0; if ($why) { return @{ Why = $why } }
		& $put (& $oTail) (& $split 0 $last $true) 2
		return (& $done 'after the original')
	}
	# &Вместо
	$calls = @(for ($i = 0; $i -le $last; $i++) { if ($hc[$i] -match $script:icProceedRe) { $i } })
	if ($calls.Count -eq 0) {
		$new = Get-Framed (Get-Trimmed $h) $frame
		$rm = Get-Removed $o $frame $deletion
		if ($o.Count -gt 0) { [void]$ops.Add(@{ Kind = 'replace'; Start = 0; End = $o.Count - 1; Lines = @(@($rm) + @($new)); Rank = 1 }) }
		else { [void]$ops.Add(@{ Kind = 'insert'; After = -1; Lines = $new; Rank = 1 }) }
		return (& $done 'in place of the original')
	}
	if ($calls.Count -gt 1) { return @{ Why = 'ПродолжитьВызов is called more than once' } }
	$c = $calls[0]
	if ($hs.Depth[$c] -gt 0 -or [regex]::Matches($hc[$c], $script:icOpenRe).Count -gt 0) { return @{ Why = 'ПродолжитьВызов sits inside a block' } }
	$ct = $hc[$c].Trim()
	$var = $null
	if ($ct -match '(?i)^(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$') { $kind = 'call'; $argText = $Matches[1] }
	elseif ($ct -match '(?i)^([\w]+)\s*=\s*(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$') { $kind = 'assign'; $var = $Matches[1]; $argText = $Matches[2] }
	elseif ($ct -match '(?i)^(?:Возврат|Return)\s+(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$') { $kind = 'return'; $argText = $Matches[1] }
	else { return @{ Why = 'ПродолжитьВызов is part of an expression' } }
	$given = @(if ($argText.Trim() -ne '') { Split-TopLevel $argText | ForEach-Object { $_.Trim().ToLower() } })
	if (($given -join ',') -cne ((@($cp) | ForEach-Object { $_.ToLower() }) -join ',')) { return @{ Why = 'ПродолжитьВызов gets other arguments than the parameters' } }
	$why = & $clash; if ($why) { return @{ Why = $why } }
	$why = & $valCheck 'original' ($c + 1); if ($why) { return @{ Why = $why } }
	$before = & $split 0 ($c - 1) $false
	$after = & $split ($c + 1) $last ($kind -eq 'call')
	if ($kind -eq 'call') {
		if ($cfgM.IsFunction) { return @{ Why = 'the result of ПродолжитьВызов is not used' } }
		if ($after.Code.Count -gt 0 -and (& $oEarly)) { return @{ Why = 'the original returns early: the code after it would be skipped' } }
		& $put $oVar $before 1
		& $put (& $oTail) $after 2
		return (& $done 'around the original')
	}
	if (-not $cfgM.IsFunction) { return @{ Why = 'ПродолжитьВызов of a procedure gives no value' } }
	if ($kind -eq 'return') {
		if ($after.Code.Count -gt 0) { return @{ Why = 'the code after Возврат ПродолжитьВызов is never reached' } }
		& $put $oVar $before 1
		& $put $oVar @{ Vars = $after.Vars; Code = @() } 0
		return (& $done 'around the original')
	}
	# Р = ПродолжитьВызов(…): the original's one Возврат, at its end, gives Р its value
	$rets = @(for ($i = 0; $i -lt $o.Count; $i++) { if ($os.Ret[$i]) { $i } })
	$r = $os.Term
	$raw = if ($r -ge 0) { (Get-CodeOnly @($o[$r]) -KeepStrings)[0].Trim() } else { '' }
	if ($rets.Count -ne 1 -or $r -lt 0 -or $raw -notmatch '(?i)^(?:Возврат|Return)\s+(.+?)\s*;?$') { return @{ Why = 'the original returns other than by one Возврат at its end' } }
	$expr = $Matches[1]
	& $put $oVar $before 1
	& $put $oVar @{ Vars = $after.Vars; Code = @() } 0
	$setLines = Get-Framed (@("$(Get-Indent $o[$r])$var = $expr;") + @($after.Code)) $frame
	$rm = Get-Removed @($o[$r]) $frame $deletion
	[void]$ops.Add(@{ Kind = 'replace'; Start = $r; End = $r; Lines = @(@($rm) + @($setLines)); Rank = 2 })
	return (& $done 'around the original')
}

# The original's body with interceptor edits laid on it
function Get-InterceptBody($body, $ops) {
	$body = @($body)
	$ins = @{}; $rep = @{}
	# At one spot: by rank, then in the order they came (a stable sort, the same in both ports)
	$n = 0
	$sorted = @(@($ops) | ForEach-Object { @{ Op = $_; Key = ([int]$_.Rank * 100000 + $n) }; $n++ } | Sort-Object -Property @{ Expression = { $_.Key } } | ForEach-Object { $_.Op })
	foreach ($op in $sorted) {
		if ($op.Kind -eq 'insert') { $k = [int]$op.After; if (-not $ins.ContainsKey($k)) { $ins[$k] = New-Object System.Collections.ArrayList }; [void]$ins[$k].Add($op) }
		else { $rep[[int]$op.Start] = $op }
	}
	$out = New-Object System.Collections.Generic.List[string]
	if ($ins.ContainsKey(-1)) { foreach ($op in $ins[-1]) { foreach ($l in $op.Lines) { $out.Add($l) } } }
	$i = 0
	while ($i -lt $body.Count) {
		if ($rep.ContainsKey($i)) {
			$op = $rep[$i]
			foreach ($l in $op.Lines) { $out.Add($l) }
			for ($j = $op.Start; $j -le $op.End; $j++) { if ($ins.ContainsKey($j)) { foreach ($x in $ins[$j]) { foreach ($l in $x.Lines) { $out.Add($l) } } } }
			$i = $op.End + 1; continue
		}
		$out.Add($body[$i])
		if ($ins.ContainsKey($i)) { foreach ($x in $ins[$i]) { foreach ($l in $x.Lines) { $out.Add($l) } } }
		$i++
	}
	return ,$out.ToArray()
}

# Names the extension declares and the configuration does not have yet, under any prefix (lower-case
# name -> name): code that uses them waits until those objects, sub-objects or form items are there
function Get-MissingNames($extNames, $cfgNames) {
	$have = @{}
	foreach ($n in @($cfgNames)) { if ($n) { $have[(Get-NameKey $n $script:transferPrefix).ToLower()] = $true } }
	$res = @{}
	foreach ($n in @($extNames)) {
		if (-not $n) { continue }
		if (-not $have.ContainsKey((Get-NameKey $n $script:transferPrefix).ToLower())) { $res[$n.ToLower()] = $n }
	}
	return $res
}

# Named items of a form (elements, attributes, commands, parameters), its BaseForm left out
function Get-FormItemNames([string]$formXml) {
	$res = @()
	if (-not $formXml -or -not (Test-Path -LiteralPath $formXml)) { return $res }
	$doc = New-Object System.Xml.XmlDocument
	try { $doc.Load($formXml) } catch { return $res }
	foreach ($n in $doc.DocumentElement.SelectNodes("//*[@name][not(ancestor::*[local-name()='BaseForm'])]")) { $res += $n.GetAttribute('name') }
	return $res
}

# A method that is not coming, for the code that calls it: by its name in its own module; a common
# module's method also as Модуль.Метод for the other modules (a bare name there is someone else's).
# Returns $true when it is new.
function Add-OutName($byFile, $common, [string]$cfgFile, [string]$rel, [string]$name) {
	$fk = $cfgFile.ToLower()
	if (-not $byFile.ContainsKey($fk)) { $byFile[$fk] = @{} }
	$new = -not $byFile[$fk].ContainsKey($name.ToLower())
	$byFile[$fk][$name.ToLower()] = $name
	if ((Get-ModuleKind $rel) -eq 'common') {
		$mod = ($rel -replace '\\', '/').Split('/')[1]
		$common["$mod.$name".ToLower()] = "$mod.$name"
	}
	return $new
}

# Missing names the code uses (comments left out): the sorted original names. The extension's code
# names its own things as the extension does, so a word matches by the very name: a plain Товары is
# not the extension's Расш_Товары.
function Get-UsedMissing($lines, $missing, $selected = $null, $params = $null) {
	$hit = @{}
	if ($missing.Count -eq 0) { return @() }
	$only = Get-CodeOnly $lines
	for ($lineIdx = 0; $lineIdx -lt $only.Count; $lineIdx++) {
		if ($null -ne $selected -and -not $selected.ContainsKey($lineIdx)) { continue }
		$t = $only[$lineIdx]
		foreach ($m in [regex]::Matches($t, '[\w]+')) {
			$k = $m.Value.ToLower()
			if ($script:bslContext.Methods.ContainsKey($k)) {
				$before2 = $t.Substring(0, $m.Index)
				if ($before2 -match '([\w]+)\s*\.\s*$') {
					if ($params -contains $Matches[1]) { continue }
					$owner2 = Get-BslOwner $Matches[1] $script:bslContext
					if (-not $owner2 -or $owner2 -ne $script:bslContext) { continue }
				}
			}
			if ($missing.ContainsKey($k)) { $hit[$missing[$k]] = $true }
		}
		# A common module's method called from another module: Модуль.Метод
		foreach ($m in [regex]::Matches($t, '([\w]+)\s*\.\s*([\w]+)')) {
			if ($params -contains $m.Groups[1].Value) { continue }
			$k = ($m.Groups[1].Value + '.' + $m.Groups[2].Value).ToLower()
			if ($missing.ContainsKey($k)) { $hit[$missing[$k]] = $true }
		}
	}
	# Only explicit API references carry dependencies through strings. Ordinary data may warn,
	# but never waits merely because its text is also the name of a blocked method.
	$bc = Get-BslConversion $lines @{} $script:bslContext $params
	foreach ($ref in $bc.References) {
		$refLine = ([regex]::Matches((@($lines) -join "`n").Substring(0, $ref.Token.Start), "`n")).Count
		if ($null -ne $selected -and -not $selected.ContainsKey($refLine)) { continue }
		$k = $ref.Name.ToLower()
		if ($ref.Context -and $ref.Context -ne $script:bslContext -and $ref.Context.Kind -eq 'common') {
			$mod = ($ref.Context.Rel -replace '\\', '/').Split('/')[1]; $k = "$mod.$($ref.Name)".ToLower()
		}
		if ($ref.Context -and $ref.Context -ne $script:bslContext -and $ref.Context.Kind -eq 'application') { continue }
		if ($missing.ContainsKey($k)) { $hit[$missing[$k]] = $true }
	}
	# Ordinal, case-insensitive: the same order in both ports, whatever the culture
	$arr = [string[]]@($hit.Keys)
	if ($arr.Count -gt 1) { [Array]::Sort($arr, [StringComparer]::OrdinalIgnoreCase) }
	return $arr
}

# The new body of an &ИзменениеИКонтроль method, compared again: every edit must come out absorbed,
# the way the check sees it after the write — the ones laid now and the ones already there (lines an
# edit moves within the method reappear in its insert, and a deletion then looks undone again).
# Returns the number of edits the check would still see as not transferred.
function Get-ControlResultGap($plan, $body) {
	$m2 = @{ BodyLines = @($body); ParamNames = $plan.CfgM.ParamNames }
	$r2 = Get-ControlTransfer $plan.ExtM $m2 $script:transferPrefix
	$before = @($plan.Ops)
	if (-not $r2) { return $before.Count }
	$after = @($r2.Plan)
	if ($after.Count -ne $before.Count) { return $before.Count }
	$gap = 0
	for ($i = 0; $i -lt $before.Count; $i++) {
		if (@('pending', 'absorbed') -contains $before[$i].Res -and $after[$i].Res -ne 'absorbed') { $gap++ }
	}
	return $gap
}

# An own method after the transfer, seen by the check: found by its name, with the same body
function Test-OwnResult($plan, $fe, $fileMap) {
	$names = @(Get-ProcNames $fe.File.Lines) + @($fe.Given)
	if (@(Find-NamesIn $names $plan.Name $script:transferPrefix | Where-Object { $_ -ieq $plan.Target.Name }).Count -eq 0) { return $false }
	$conv = Convert-BslCode $plan.ExtM.BodyLines $fileMap $plan.ExtM.ParamNames
	return (((Get-SigLines (Convert-BslCode $plan.ExtM.BodyLines $fileMap $plan.ExtM.ParamNames) $script:transferPrefix) -join "`n") -ieq ((Get-SigLines $conv $script:transferPrefix) -join "`n"))
}

# An own method as the configuration gets it: the description comments above it, the directive, the
# declaration through Конец*; names converted; begin comment on top, end comment on the Конец* line
function Get-OwnMethodBlock($extLines, $extM, $frame, $fileMap) {
	$start = $extM.DeclIdx
	if ($start -ge 1 -and (Test-ContextDirective $extLines[$start - 1].Trim())) { $start-- }
	while ($start -ge 1 -and $extLines[$start - 1].Trim().StartsWith('//')) { $start-- }
	$src = @(); for ($j = $start; $j -le $extM.BodyEndIdx; $j++) { $src += $extLines[$j] }
	$conv = Convert-BslCode $src $fileMap $extM.ParamNames
	$out = New-Object System.Collections.Generic.List[string]
	if ($frame.Begin) { $out.Add($frame.Begin) }
	foreach ($l in $conv) { $out.Add($l) }
	if ($frame.End) { $out[$out.Count - 1] = "$($out[$out.Count - 1]) $($frame.End)" }
	return ,$out.ToArray()
}

# Edits of one configuration file, collected over the run and written once
function Get-FileEdits([string]$path) {
	# One pool per file, however the path was spelled
	$path = [System.IO.Path]::GetFullPath($path)
	$key = $path.ToLower()
	if (-not $script:fileEdits.Contains($key)) {
		$f = Read-BslFile $path
		$script:fileEdits[$key] = @{ File = $f; Repl = (New-Object System.Collections.ArrayList); Create = [ordered]@{}; OwnAt = @{}; Tail = (New-Object System.Collections.ArrayList); Regions = (Get-Regions $f.Lines); Layout = (Get-ModuleLayout $f.Lines); Given = (New-Object 'System.Collections.Generic.HashSet[string]') }
	}
	return $script:fileEdits[$key]
}

# All collected edits written: replacements from the bottom up (indexes stay valid; inserts at one
# spot keep the order they came in), own methods put at one spot as one block, then regions created
# at the end of the module
function Write-FileEdits {
	$changed = @()
	foreach ($fe in $script:fileEdits.Values) {
		if ($fe.Repl.Count -eq 0 -and $fe.Create.Count -eq 0 -and $fe.OwnAt.Count -eq 0 -and $fe.Tail.Count -eq 0) { continue }
		$lines = New-Object System.Collections.Generic.List[string]
		foreach ($l in $fe.File.Lines) { $lines.Add($l) }
		$repl = @($fe.Repl)
		foreach ($at in @($fe.OwnAt.Keys)) {
			$o = $fe.OwnAt[$at]
			$blk = @()
			foreach ($b in $o.Blocks) { if ($blk.Count -gt 0) { $blk += '' }; $blk += $b }
			$repl += @{ Start = [int]$at; End = [int]$at; Lines = (Get-SpacedBlock $fe.File.Lines ([int]$at) $blk); Seq = $o.Seq }
		}
		$sorted = @($repl | Sort-Object -Property @{ Expression = { $_.Start }; Descending = $true }, @{ Expression = { $_.Seq }; Descending = $true })
		foreach ($r in $sorted) {
			if ($r.End -gt $r.Start) { $lines.RemoveRange($r.Start, $r.End - $r.Start) }
			$lines.InsertRange($r.Start, [string[]]@($r.Lines))
		}
		if ($fe.Create.Count -gt 0) {
			$lang = Get-ModuleLang $fe.File.Lines
			$endAt = Get-ModuleEnd $lines.ToArray()
			$prev = if ($endAt -gt 0) { $lines[$endAt - 1] } else { '' }
			$add = New-Object System.Collections.Generic.List[string]
			foreach ($name in $fe.Create.Keys) {
				if ($add.Count -gt 0 -or $prev.Trim() -ne '') { $add.Add('') }
				$add.Add("#$($script:bslKw[$lang].Region) $name")
				foreach ($blk in $fe.Create[$name]) { $add.Add(''); foreach ($l in $blk) { $add.Add($l) } }
				$add.Add('')
				$add.Add("#$($script:bslKw[$lang].EndRegion)")
			}
			if ($endAt -lt $lines.Count -and $lines[$endAt].Trim() -ne '') { $add.Add('') }
			$lines.InsertRange($endAt, $add)
		}
		# Statements of the module body: after the configuration's own, at the tail
		foreach ($blk in $fe.Tail) {
			$at = Get-ModuleTail $lines.ToArray()
			$sb = Get-SpacedBlock $lines.ToArray() $at $blk
			$lines.InsertRange($at, [string[]]$sb)
		}
		Write-BslFile $fe.File $lines.ToArray()
		$changed += $fe.File.Path
	}
	return ,$changed
}

# Lines around the spot: one blank line between the block and its neighbours
function Get-SpacedBlock($lines, [int]$at, $block) {
	$res = @()
	if ($at -gt 0 -and ([string]$lines[$at - 1]).Trim() -ne '') { $res += '' }
	$res += $block
	if ($at -lt $lines.Count -and ([string]$lines[$at]).Trim() -ne '') { $res += '' }
	return ,$res
}

function New-TItem([string]$status, [string]$text, [string]$loc, [string]$section) {
	return @{ Status = $status; Text = $text; Loc = $loc; Section = $section; Group = ''; Sub = @() }
}

# from/to/next lines of a change the skill leaves to a person
function Get-WhereLines($plan, [string]$next) {
	$sub = @()
	if ($plan -and $plan.ExtM) { $sub += "from: extension $($plan.Rel):$($plan.ExtM.DeclIdx + 1)-$($plan.ExtM.BodyEndIdx + 1)" }
	if ($plan -and $plan.CfgM) {
		$kw = if ($plan.CfgM.IsFunction) { $script:bslKw[$plan.CfgM.Lang].Func } else { $script:bslKw[$plan.CfgM.Lang].Proc }
		$sub += "to:   config $($plan.Rel):$($plan.CfgM.DeclIdx + 1) ($kw $($plan.CfgM.Canonical))"
	}
	if ($next) { $sub += "next: $next" }
	return $sub
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

# -Expand: a section is opened by its object (Type.Name), a path from the section headers (prefix,
# so a form folder opens its Form.xml and Module.bsl) or * for all. A logical name as other skills
# take it (Type.Name.Form.F, Type.Name.ObjectModule) is turned into that path.
function Get-ExpandPrefix([string]$token) {
	$t = $token.Trim()
	if ($t -match '[\\/]') { return (($t -replace '\\', '/').TrimEnd('/').ToLower()) }
	$parts = $t.Split('.')
	if ($parts.Count -lt 3 -or -not $childTypeDirMap.ContainsKey($parts[0])) { return $null }
	$base = "$($childTypeDirMap[$parts[0]])/$($parts[1])"
	if ($parts[2] -ieq 'Form') {
		if ($parts.Count -ge 4) { return "$base/Forms/$($parts[3])".ToLower() }
		return $base.ToLower()
	}
	if ($parts[2] -ieq 'Command') {
		if ($parts.Count -ge 4) { return "$base/Commands/$($parts[3])".ToLower() }
		return $base.ToLower()
	}
	return "$base/Ext/$($parts[2]).bsl".ToLower()
}

function Test-Expanded($ext, [string]$objId, [string]$section) {
	foreach ($t in $expandList) {
		if ($t -eq '*' -or $t -ieq $objId) { return $true }
		$p = Get-ExpandPrefix $t
		if (-not $p -or -not $section) { continue }
		$s = $section.ToLower()
		$full = ((Join-Path $ext.Dir $section) -replace '\\', '/').ToLower()
		foreach ($c in @($s, $full)) { if ($c -eq $p -or $c.StartsWith("$p/")) { return $true } }
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

# Details of an object in transfer, grouped by the file each change lives in. A plain transferred
# change folds into "… N transferred" unless its section is expanded (one marked temporary stays
# in sight); a section with nothing else left is one line, and so is a form whose files all are.
function Get-TransferDetails($ext, $rec, [string]$foldWord = 'transferred') {
	$lines = New-Object System.Collections.Generic.List[string]
	$folded = 0
	$order = New-Object System.Collections.Generic.List[string]
	$bySec = @{}
	foreach ($it in $rec.Items) {
		$s = [string]$it.Section
		if (-not $bySec.ContainsKey($s)) { $bySec[$s] = New-Object System.Collections.ArrayList; $order.Add($s) }
		[void]$bySec[$s].Add($it)
	}
	# Shown items and the folded count of a section
	$view = @{}
	$anyOpen = $false
	foreach ($s in $order) {
		$open = Test-Expanded $ext $rec.Id $s
		if ($open) { $anyOpen = $true }
		$shown = @($bySec[$s] | Where-Object { $open -or $_.Status -ne 'TRANSFERRED' -or $_.Marked -or $_.Now })
		$view[$s] = @{ Shown = $shown; Hidden = ($bySec[$s].Count - $shown.Count) }
	}
	$emit = {
		param([string]$s)
		$v = $view[$s]
		$pad = if ($s) { '      ' } else { '    ' }
		if ($s) {
			if ($v.Shown.Count -eq 0) { $lines.Add("    ${s}: $($v.Hidden) $foldWord"); return }
			$lines.Add("    ${s}:")
		}
		foreach ($it in $v.Shown) {
			$loc = if ($it.Loc) { "  $($it.Loc)" } else { '' }
			$lines.Add("$pad$(Format-Status $it.Status)$($it.Text)$loc")
			foreach ($sl in @($it.Sub)) { if ($sl) { $lines.Add("$pad    $sl") } }
		}
		if ($v.Hidden -gt 0) { $lines.Add("$pad… $($v.Hidden) $foldWord") }
	}
	$lay = Get-SectionLayout $order
	foreach ($s in $lay.Plain) { & $emit $s; $folded += $view[$s].Hidden }
	foreach ($f in $lay.Forms) {
		$fd = $f.Dir; $secs = $f.Secs
		$hidden = 0; $shown = 0
		foreach ($s in $secs) { $hidden += $view[$s].Hidden; $shown += $view[$s].Shown.Count }
		$folded += $hidden
		if ($shown -eq 0) { $lines.Add("    ${fd}: $hidden $foldWord"); continue }
		foreach ($s in $secs) { & $emit $s }
	}
	return @{ Lines = $lines.ToArray(); Folded = $folded; Open = $anyOpen }
}

$statusOrder = @('TRANSFERRED', 'NOT_TRANSFERRED', 'PARTIAL', 'DIVERGED', 'MISSING_IN_CONFIG', 'TEMPORARY', 'MANUAL')
function Format-Status([string]$st) { return ("[$st]").PadRight(21) }

# Order of a form's changes in the transfer: what the others rely on goes first (a column needs its
# attribute, an element may name a command or carry a property and an event), a form change left to a
# person or applied in place goes last; anything not of a form keeps its place
function Get-FormItemRank($it) {
	if (-not $it.Group) { return 100 }
	$k = if ($it.Plan) { $it.Plan.Kind } else { '' }
	switch ($k) {
		'attribute' { return 0 }
		'command' { return 1 }
		'command-bind' { return 1 }
		'column' { return 2 }
		'element' { return 3 }
		'prop' { return 4 }
		'move' { return 4 }
		'event-bind' { return 5 }
		'appearance' { return 6 }
		'formprop' { return 6 }
		'intercept' { return 9 }
	}
	return 8
}

# Project settings (.v8-project.json): development prefixes for both modes, the rest for transfer
$script:settings = Get-TransferSettings $ConfigPath
$script:configRefMap = Get-ConfigRefMap $ConfigPath
$script:devRe = $null
if ($script:settings.DevPrefix.Count -gt 0) {
	$alt = (@($script:settings.DevPrefix | Sort-Object -Property Length -Descending) | ForEach-Object { [regex]::Escape($_) }) -join '|'
	$script:devRe = New-Object System.Text.RegularExpressions.Regex ('(?<!\w)(?:' + $alt + ')(?=\w)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

if ($Mode -eq 'transfer') {
	$extDir0 = $extDirs[0]
	$cp0 = Read-ConfigurationProps $extDir0
	$prefix = [string]$cp0.Prefix
	$script:transferPrefix = $prefix
	$vars = Get-TemplateVars $cp0 $Tag
	foreach ($kind in @('vendor', 'own')) {
		$ic = $script:settings[$kind].InsertComment
		if ($ic -is [hashtable] -and -not $Tag) {
			foreach ($k in @('begin', 'end')) { if ([string]$ic[$k] -match '\{tag(?::[^}]*)?\}') { Write-Error "The project's comment template (cfeTransfer.insertComment.$k in .v8-project.json) uses {tag}: ask the user for the value (e.g. the task number) and pass -Tag <value>. Nothing was written."; exit 1 } }
		}
	}
	$script:supportInfo = Get-SupportInfo $ConfigPath
	$script:fileEdits = [ordered]@{}
	$script:nameMap = @{}
	$script:seq = 0
	$ext = @{ Dir = $extDir0; Name = $cp0.Name; Prefix = $prefix; Purpose = $cp0.Purpose }
	$matchedIds = @{}
	$roles = 0

	Initialize-BslCatalog $extDir0 $prefix
	# --- Pass 1: what the check sees, object by object ---
	$work = @()
	$cfgPools = @{}
	if ($cfgInfo.ChildObjects) { foreach ($c in $cfgInfo.ChildObjects.ChildNodes) { if ($c.NodeType -eq 'Element') { if (-not $cfgPools.ContainsKey($c.LocalName)) { $cfgPools[$c.LocalName] = @() }; $cfgPools[$c.LocalName] += $c.InnerText.Trim() } } }
	$allObjs = @()
	if ($cp0.ChildObjects) { foreach ($c in $cp0.ChildObjects.ChildNodes) { if ($c.NodeType -eq 'Element' -and $c.LocalName -ne 'Language') { $allObjs += @{ Type = $c.LocalName; Name = $c.InnerText.Trim() } } } }
	foreach ($obj in $allObjs) {
		$id = "$($obj.Type).$($obj.Name)"
		if (-not (Test-NameMatch $id)) { continue }
		$matchedIds[$id.ToLower()] = $true
		if ($obj.Type -eq 'Role') { $roles++; continue }
		$rec = Get-TransferObject $ext $obj
		if ($rec.Items.Count -eq 0) { continue }
		$ctx = Get-ObjContext $extDir0 $obj.Type $obj.Name
		$sup = 'own'
		if ($ctx.Known) {
			$cfgXml = Join-Path (Join-Path $ConfigPath $ctx.Dir) "$($obj.Name).xml"
			if (Test-Path -LiteralPath $cfgXml) { $sup = Get-ObjectSupport $cfgXml }
		}
		$work += @{ Id = $id; Obj = $obj; Rec = $rec; Ctx = $ctx; Support = $sup; Kind = (Get-ObjectKind $obj.Name $sup) }
	}

	# --- Pass 2: names the configuration gets ---
	# Own objects and own sub-objects of borrowed ones: the names code refers to. Only a name that
	# differs from the plain one (prefix dropped) goes to the map: found under another name, or with
	# the development prefix.
	$missingGlobal = @{}
	$missingByObj = @{}
	foreach ($obj in $allObjs) {
		if ($obj.Type -eq 'Role') { continue }
		$ctx = Get-ObjContext $extDir0 $obj.Type $obj.Name
		if (-not $ctx.Known -or -not $ctx.Exists) { continue }
		if (-not $ctx.Borrowed) {
			$pool = @($cfgPools[$obj.Type])
			$hit = Find-NameIn $pool $obj.Name $prefix
			if (-not $hit) { $missingGlobal[$obj.Name.ToLower()] = $obj.Name }
			$t = if ($hit) { $hit } else {
				$taken = New-Object 'System.Collections.Generic.HashSet[string]'
				foreach ($n in $pool) { [void]$taken.Add($n.ToLower()) }
				(Get-TargetName $obj.Name $prefix $taken $script:settings.vendor.AddDevObjects).Name
			}
			if ($t -cne (Remove-ExtPrefix $obj.Name $prefix)) { $script:nameMap[$obj.Name.ToLower()] = $t }
			continue
		}
		if (-not $ctx.Md -or -not $ctx.Md.Children) { continue }
		$cfgXml = Join-Path (Join-Path $ConfigPath $ctx.Dir) "$($obj.Name).xml"
		$cfgMd = Read-MdObject $cfgXml
		$sup = if (Test-Path -LiteralPath $cfgXml) { Get-ObjectSupport $cfgXml } else { 'own' }
		$addDev = $script:settings[(Get-ObjectKind $obj.Name $sup)].AddDevObjects
		$cfgNames = @()
		if ($cfgMd -and $cfgMd.Children) {
			foreach ($c in $cfgMd.Children.ChildNodes) {
				if ($c.NodeType -ne 'Element') { continue }
				$cfgNames += if (Test-HasElementChild $c) { Get-MdChildName $c $cfgMd.Ns } else { $c.InnerText.Trim() }
			}
		}
		$taken = New-Object 'System.Collections.Generic.HashSet[string]'
		foreach ($n in $cfgNames) { [void]$taken.Add($n.ToLower()) }
		# Names code may refer to: attributes of the configuration's tabular sections too — a method waiting
		# for one must stop waiting once the metadata transfer has put it into the configuration
		$cfgKnown = @($cfgNames)
		if ($cfgMd -and $cfgMd.Children) {
			foreach ($c in $cfgMd.Children.ChildNodes) {
				if ($c.NodeType -ne 'Element') { continue }
				$csub = $c.SelectSingleNode("md:ChildObjects", $cfgMd.Ns)
				if ($csub) { foreach ($x in $csub.ChildNodes) { if ($x.NodeType -eq 'Element') { $cfgKnown += (Get-MdChildName $x $cfgMd.Ns) } } }
			}
		}
		$mns = $ctx.Md.Ns
		foreach ($c in $ctx.Md.Children.ChildNodes) {
			if ($c.NodeType -ne 'Element') { continue }
			$own = @()
			if (-not (Test-HasElementChild $c)) {
				$nm = $c.InnerText.Trim()
				$desc = Read-MdObject (Join-Path (Join-Path $ctx.ObjDir "$($c.LocalName)s") "$nm.xml")
				if (-not ($desc -and (Test-AdoptedNode $desc.Props $desc.Ns))) { $own += $nm }
			} elseif (-not (Test-AdoptedNode $c $mns)) { $own += (Get-MdChildName $c $mns) }
			else {
				$sub = $c.SelectSingleNode("md:ChildObjects", $mns)
				if ($sub) { foreach ($sc in $sub.ChildNodes) { if ($sc.NodeType -eq 'Element' -and -not (Test-AdoptedNode $sc $mns)) { $own += (Get-MdChildName $sc $mns) } } }
			}
			foreach ($nm in $own) {
				if (-not $nm) { continue }
				$hit = Find-NameIn $cfgKnown $nm $prefix
				if (-not $hit) {
					if (-not $missingByObj.ContainsKey("$($obj.Type).$($obj.Name)")) { $missingByObj["$($obj.Type).$($obj.Name)"] = @{} }
					$missingByObj["$($obj.Type).$($obj.Name)"][$nm.ToLower()] = $nm
				}
				if ($script:nameMap.ContainsKey($nm.ToLower())) { continue }
				$t = if ($hit) { $hit } else { (Get-TargetName $nm $prefix $taken $addDev).Name }
				if ($t -cne (Remove-ExtPrefix $nm $prefix)) { $script:nameMap[$nm.ToLower()] = $t }
			}
		}
	}
	# Own methods: the target name in their module (taken: the module's methods and those given in
	# this run); a common module's method is called from other modules too, so it goes to the run map
	$fileMaps = @{}
	foreach ($w in $work) {
		foreach ($it in $w.Rec.Items) {
			$pl = $it.Plan
			if (-not $pl -or $pl.Kind -ne 'own') { continue }
			$cfgFile = Get-CfgPath $pl.Rel
			$fk = $cfgFile.ToLower()
			if (-not $fileMaps.ContainsKey($fk)) { $fileMaps[$fk] = @{} }
			if ($pl.Hit) { if ($pl.Hit -cne $pl.Name) { $fileMaps[$fk][$pl.Name.ToLower()] = $pl.Hit }; continue }
			if ($it.Status -notin @('NOT_TRANSFERRED', 'MANUAL') -or $pl.CfgMissing -or $w.Support -eq 'locked') { continue }
			$fe = Get-FileEdits $cfgFile
			$taken = New-Object 'System.Collections.Generic.HashSet[string]'
			foreach ($n in @(Get-ProcNames $fe.File.Lines)) { [void]$taken.Add($n.ToLower()) }
			foreach ($n in $fe.Given) { [void]$taken.Add($n) }
			# A module method shadows a global function of the same name for every call in the module:
			# a name called as a function there (or in the extension's module) is taken too
			foreach ($n in @(Get-CalledNames (@($fe.File.Lines) + @($pl.ExtLines)) @(Get-ProcNames $pl.ExtLines))) { [void]$taken.Add($n) }
			$set = $script:settings[$w.Kind]
			$tn = Get-TargetName $pl.Name $prefix $taken ($set.AddDevMethods -and $w.Kind -eq 'vendor')
			$pl.Target = $tn
			if ($tn.Taken) { continue }
			[void]$fe.Given.Add($tn.Name.ToLower())
			$fileMaps[$fk][$pl.Name.ToLower()] = $tn.Name
			# Preserve the XML converter's map; BSL never resolves methods through this flat map.
			if ((Get-ModuleKind $pl.Rel) -eq 'common' -and $tn.Name -cne (Remove-ExtPrefix $pl.Name $prefix)) { $script:nameMap[$pl.Name.ToLower()] = $tn.Name }

		}
	}

	foreach ($ctx2 in $script:bslCatalog.Values) {
		$fk2 = (Get-CfgPath $ctx2.Rel).ToLower()
		if ($fileMaps.ContainsKey($fk2)) { foreach ($k2 in $fileMaps[$fk2].Keys) { $ctx2.Methods[$k2] = $fileMaps[$fk2][$k2] } }
	}

	# --- Pass 3: each change -> transferred now, waiting, left to a person (manual) or in conflict ---
	# An own method that stays out of the configuration in this run is one more missing name: code
	# calling it waits too. Nothing is written before pass 4, so the pass runs again until no new
	# method stays out. A method of a common module is called from other modules, the rest from
	# their own module only.
	$formMissing = @{}
	$formTemp = @{}
	$outByFile = @{}
	$outCommon = @{}
	# Own methods marked "not for transfer" and not in the configuration: never coming, so code that
	# calls them is left to a person (drop the call or the mark) rather than waiting
	$tempByFile = @{}
	$tempCommon = @{}
	foreach ($w in $work) {
		foreach ($it in $w.Rec.Items) {
			$pl = $it.Plan
			if ($it.Status -ne 'TEMPORARY' -or -not $pl -or $pl.Kind -ne 'own' -or $pl.Hit) { continue }
			[void](Add-OutName $tempByFile $tempCommon (Get-CfgPath $pl.Rel) $pl.Rel $pl.Name)
		}
	}
	do {
		$again = $false
		foreach ($fe in $script:fileEdits.Values) { $fe.Repl.Clear(); $fe.Create.Clear(); $fe.OwnAt.Clear(); $fe.Tail.Clear() }
		# Ordered: the written forms are listed for review in the order they were touched
		$script:formEdits = [ordered]@{}
		$script:mdEdits = [ordered]@{}
		$mdGiven = @{}
		$mdWarn = @()
		$script:seq = 0
		$tempCount = 0
		$recs = @()
		$ownItems = @()
		$icPending = @()
		$topItems = @()
		$ctlKeys = @{}
		foreach ($w in $work) {
			$titems = @()
			$set = $script:settings[$w.Kind]
			$frame = Get-Frame $set $vars
			# Changes of one form go in the order they depend on each other — a column needs its attribute, an
			# element may name a command added in this run — the report keeps the order the items came in
			$order = @()
			for ($oi = 0; $oi -lt $w.Rec.Items.Count; $oi++) { $order += @{ I = $oi; R = (Get-FormItemRank $w.Rec.Items[$oi]) } }
			$order = @($order | Sort-Object -Property @{ Expression = { $_.R } }, @{ Expression = { $_.I } })
			foreach ($o in $order) {
				$it = $w.Rec.Items[$o.I]
				$pl = $it.Plan
				if ($pl.Rel) { Set-BslContext $pl.Rel }
				$t = New-TItem $it.Status $it.Text $it.Loc $it.Section
				$t.Plan = $pl
				$t.Group = $it.Group; $t.Marked = $it.Marked; $t.Seq = $o.I
				if ($pl -and $pl.Kind -eq 'own' -and ($it.Status -in @('NOT_TRANSFERRED', 'MANUAL') -or ($it.Status -eq 'DIVERGED' -and ($pl.LiteralMismatch -or $pl.DeclarationMismatch)))) { $ownItems += @{ Plan = $pl; T = $t } }
				# A method with an &ИзменениеИКонтроль edit not in the configuration yet: an interceptor of it
				# would move the lines the edit is anchored to
				if ($pl -and $pl.Kind -eq 'control' -and $pl.CfgM -and @('TRANSFERRED', 'TEMPORARY') -notcontains $it.Status) {
					$ctlKeys["$((Get-CfgPath $pl.Rel).ToLower())|$($pl.CfgM.DeclIdx)"] = $true
				}
				if ($it.Status -eq 'TEMPORARY') { $tempCount++; continue }
				if ($it.Status -eq 'TRANSFERRED') { $titems += $t; continue }
				$problem = Get-BslPlanIssue $pl
				if ($problem) {
					$t.Status = 'MANUAL'
					if ($it.Status -ne 'MANUAL') { $t.Text += " — $($problem.Issue.Why)" }
					$t.Sub = Get-BslManualDetails $pl $problem
					# New refusals of event/command handlers must also protect their callers.
					$blockedNames2 = @()
					if ($pl.Kind -eq 'event-bind') { $blockedNames2 += $pl.Handler }
					if ($pl.Kind -eq 'command-bind') { $blockedNames2 += @($pl.Handlers | ForEach-Object { $_.Handler }) }
					foreach ($n2 in $blockedNames2) { if (Add-OutName $outByFile $outCommon (Get-CfgPath $pl.Rel) $pl.Rel $n2) { $again = $true } }
					$titems += $t; continue
				}
				if ($it.Group -and $w.Support -eq 'locked') {
					$t.Status = 'MANUAL'
					$t.Text = "$($it.Text) — object is locked by vendor support"
					$t.Sub = @('next: allow editing with /support-edit, then re-run -Mode transfer')
					$titems += $t; continue
				}
				if ($it.Group -and $it.Plan -and $it.Plan.Kind -eq 'intercept') {
					$cfgFile = Get-CfgPath $it.Plan.Rel
					$fm = if ($fileMaps.ContainsKey($cfgFile.ToLower())) { $fileMaps[$cfgFile.ToLower()] } else { @{} }
					$r = Get-InterceptOps $it.Plan.ExtM $it.Plan.CfgM $it.Plan.Type $frame $set.Deletion $fm
					if ($r.Why) {
						$t.Text = "$($it.Plan.Label) — $($r.Why)"
						$t.Sub = @('next: apply by hand, then re-run -Mode check')
						$titems += $t
						continue
					}
					$blocked2 = @(Get-BslBlockedDependencies $pl $outByFile $outCommon)
					if ($blocked2.Count) { $t.Status = 'WAITING'; $t.Text = "$($it.Text) - waits for: $($blocked2 -join ', ')"; $titems += $t; continue }
					$icPending += @{ T = $t; Pl = $it.Plan; Fe = (Get-FileEdits $cfgFile); Ops = $r.Ops; Where = $r.Where; Label = $it.Plan.Label; Warn = ''; Locals = $r.Locals; Words = $r.Words }
					$titems += $t
					continue
				}
				if ($pl.Kind -in @('event-bind', 'command-bind')) {
					$blocked2 = @(Get-BslBlockedDependencies $pl $outByFile $outCommon)
					if ($blocked2.Count) { $t.Status = 'WAITING'; $t.Text = "$($it.Text) - waits for: $($blocked2 -join ', ')"; $titems += $t; continue }
				}
				if ($it.Group -and $it.Plan) {
					$pl = $it.Plan
					$relForm = [string]$it.Section
					# A new event or a new command's handler lives in the form's module, the change itself in Form.xml
					if ($pl.Kind -eq 'event-bind' -or $pl.Kind -eq 'command-bind') { $relForm = $pl.Rel -replace '[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml' }
					$cfgForm = Join-Path $ConfigPath $relForm
					$extForm = Join-Path $extDir0 $relForm
					# Join-Path turns the forward slashes of a relative path into backslashes: both are matched;
					# the module path is normalized so that it keys the same map as a module path built from Rel
					$cfgFormMod = [IO.Path]::GetFullPath(($cfgForm -replace '[\\/]Ext[\\/]Form\.xml$', '/Ext/Form/Module.bsl'))
					$extFormMod = [IO.Path]::GetFullPath(($extForm -replace '[\\/]Ext[\\/]Form\.xml$', '/Ext/Form/Module.bsl'))
					$fe = New-FormEdit $cfgForm $extForm $extFormMod $cfgFormMod $extDir0 $prefix $it.Group
					if (-not $fe.Ctx) {
						# The same map the handlers of this module are registered in: a node copied later (a command's
						# Action, an element's Event) finds the names given in this run
						$fk = $cfgFormMod.ToLower()
						if (-not $fileMaps.ContainsKey($fk)) { $fileMaps[$fk] = @{} }
						$fe.Ctx = @{ NameMap = (Get-FormNameMap (Read-FormDoc $extForm).DocumentElement $fe.Fw.Doc.DocumentElement $prefix); RefMap = $script:configRefMap; HandlerMap = $fileMaps[$fk]; Bad = (New-Object System.Collections.ArrayList) }
					}
					# A binding of the extension's own (an event, a new command's actions): its handlers go into
					# the module by the role the form gives them, the item into Form.xml; nothing is committed
					# until the item itself has been applied
					$op = $pl
					$modAdds = @()
					$mapRef = $null
					$mapAdded = @()
					if ($pl.Kind -eq 'event-bind' -or $pl.Kind -eq 'command-bind') {
						$cfgModFile = Get-CfgPath $pl.Rel
						$fw = Get-FileEdits $cfgModFile
						$fk = $cfgModFile.ToLower()
						if (-not $fileMaps.ContainsKey($fk)) { $fileMaps[$fk] = @{} }
						# The names go into the shared map before the item is copied: a command's Action text is
						# renamed by the copy; on a refusal they are taken back
						$mapRef = $fileMaps[$fk]
						$hs = if ($pl.Kind -eq 'event-bind') { @(@{ Handler = $pl.Handler; ExtM = $pl.ExtM }) } else { @($pl.Handlers) }
						$bind = Get-FormBindings $extForm
						$notify = Get-NotifyNames (@($pl.ExtLines) + @($fw.File.Lines))
						$conflict = $null
						foreach ($h in $hs) {
							$hk = $h.Handler.ToLower()
							$tn = if ($mapRef.ContainsKey($hk)) { @{ Name = $mapRef[$hk]; Note = '' } } else { $null }
							if (-not $tn) {
								$taken = New-Object 'System.Collections.Generic.HashSet[string]'
								foreach ($n in @(Get-ProcNames $fw.File.Lines)) { [void]$taken.Add($n.ToLower()) }
								foreach ($n in $fw.Given) { [void]$taken.Add($n) }
								foreach ($n in @(Get-CalledNames (@($fw.File.Lines) + @($pl.ExtLines)) @(Get-ProcNames $pl.ExtLines))) { [void]$taken.Add($n) }
								$tn = Get-TargetName $h.Handler $prefix $taken ($set.AddDevMethods -and $w.Kind -eq 'vendor')
							}
							if ($tn.Taken) { $conflict = "name taken in config ($($tn.Note))"; break }
							$mapRef[$hk] = $tn.Name; $mapAdded += $hk
							$conv = Convert-BslCode $h.ExtM.BodyLines $mapRef $h.ExtM.ParamNames
							if (((Get-SigLines (Convert-BslCode $h.ExtM.BodyLines $mapRef $h.ExtM.ParamNames) $prefix) -join "`n") -ine ((Get-SigLines $conv $prefix) -join "`n")) {
								$conflict = "after the transfer the check would not find the handler's code"; break
							}
							$role = Get-MethodRole $h.Handler 'form' $bind $notify (Test-IsExport $pl.ExtLines $h.ExtM)
							$created = @($fw.Create.Keys | ForEach-Object { $_.ToLower() })
							$place = Get-MethodPlace $fw.File.Lines $fw.Regions $h.ExtM $role $set $created
							$modAdds += @{ Name = $tn.Name; Note = $tn.Note; Fw = $fw; Place = $place
								Block = (Get-OwnMethodBlock $pl.ExtLines $h.ExtM $frame $mapRef); Where = '' }
						}
						if ($conflict) {
							foreach ($k in $mapAdded) { [void]$mapRef.Remove($k) }
							$t.Status = 'CONFLICT'
							$t.Text = "$($it.Text) — $conflict; form not changed"
							$t.Sub = @('next: rename the handler in the extension or merge by hand, then re-run -Mode transfer')
							$titems += $t; continue
						}
						if ($pl.Kind -eq 'event-bind') { $op = @{ Kind = 'event'; Scope = $pl.Scope; Name = $pl.Name; Handler = $modAdds[0].Name } }
						else { $op = @{ Kind = 'command'; Node = $pl.Node; Name = $pl.Name; StripCallType = $true } }
					}
					try {
						Apply-FormOp $fe $op $fe.Ctx
						if ($fe.Ctx.Bad.Count -gt 0) { throw "reference $($fe.Ctx.Bad[0]) is not in the configuration" }
						foreach ($ma in $modAdds) {
							$mf = $ma.Fw; $mp = $ma.Place
							if ($mp.Create) {
								$key = @($mf.Create.Keys | Where-Object { $_ -ieq $mp.Create })[0]
								if (-not $key) { $key = $mp.Create; $mf.Create[$key] = New-Object System.Collections.ArrayList }
								[void]$mf.Create[$key].Add($ma.Block)
								$ma.Where = "new region $key"
							} else {
								$at = [int]$mp.At
								if (-not $mf.OwnAt.ContainsKey($at)) { $mf.OwnAt[$at] = @{ Blocks = (New-Object System.Collections.ArrayList); Seq = $script:seq++ } }
								[void]$mf.OwnAt[$at].Blocks.Add($ma.Block)
								$ma.Where = if ($mp.Region) { "region $($mp.Region)" } else { 'end of module' }
							}
						}
						if ($pl.Kind -eq 'prop') { [void]$fe.Ops.Add(@{ Kind = 'prop'; Rec = $pl.Rec; Props = $pl.Props; Item = $t }) }
						elseif ($pl.Kind -eq 'formprop') { [void]$fe.Ops.Add(@{ Kind = 'formprop'; Props = $pl.Props; Item = $t }) }
						else { [void]$fe.Ops.Add(@{ Kind = 'text'; Key = $it.PlanKey; Item = $t }) }
						# A property changed in the configuration some other way stays as it is: the item keeps
						# its divergence, what was pending has gone over
						if ($it.Status -eq 'DIVERGED') { $t.Status = 'DIVERGED'; $t.Now = $false; $t.Text = "$($it.Text) — the rest transferred" }
						else {
							$t.Status = 'TRANSFERRED'; $t.Now = $true
							if ($modAdds.Count -gt 0) {
								$names = @($modAdds | ForEach-Object { "$($_.Name)$(if ($_.Note) { " ($($_.Note))" })" }) -join ', '
								$where = @($modAdds | ForEach-Object { $_.Where } | Select-Object -Unique) -join ', '
								if ($pl.Kind -eq 'event-bind') {
									$t.Text = "event $(if ($pl.Scope) { "$($pl.Scope)." } else { '' })$($pl.Name) -> $names — method in $where"
								} else { $t.Text = "$($it.Text) — method $names -> $where" }
							} else { $t.Text = ($it.Text -replace ' \(\d+/\d+ props\)$', '') }
						}
						$titems += $t
					} catch {
						# A change that was refused before touching the document leaves the rest of the form
						# transferable
						foreach ($k in $mapAdded) { [void]$mapRef.Remove($k) }
						$msg = $_.Exception.Message
						# A refused change leaves the rest of the form transferable; a failure of the write itself
						# keeps the whole form as it is
						$skip = $msg.StartsWith('SKIP: ')
						if ($skip) { $msg = $msg.Substring(6) } else { $fe.Failed++ }
						$t.Status = 'CONFLICT'
						$t.Text = "$($it.Text) — $msg; $(if ($skip) { 'change not applied' } else { 'form not changed' })"
						$t.Sub = @('next: apply by hand, then re-run -Mode check')
						$titems += $t
					}
					continue
				}
				$t.Status = 'MANUAL'
				if ($it.Group) { $t.Text = "$($it.Text) — the configuration's form changed since the borrowing; not applied"; $titems += $t; continue }
				# A metadata property left to a person: the check side already said why, nothing to add
				if ($it.Manual -and -not $pl) { $t.Text = $it.Text; $titems += $t; continue }
				if (-not $pl) { $t.Text = "$($it.Text) — metadata is not transferred yet"; $titems += $t; continue }
				if ($pl.Kind -eq 'md' -or $pl.Kind -like 'md-*') {
					if ($pl.Kind -eq 'md-skip') { $t.Text = "$($it.Text) — $($pl.Reason)"; $titems += $t; continue }
					if ($w.Support -eq 'locked') {
						$t.Text = "$($it.Text) — object is locked by vendor support"
						$t.Sub = @('next: allow editing with /support-edit, then re-run -Mode transfer')
						$titems += $t; continue
					}
					if ($pl.Kind -eq 'md-prop') {
						if ($pl.Conflict) {
							$t.Status = 'CONFLICT'
							# The check's line already names the reason (the type qualifiers, the missing property)
							$t.Text = "$($it.Text); property not changed"
							$next = if ($pl.Next) { $pl.Next } else { 'next: compare and merge by hand, then re-run -Mode check' }
							$t.Sub = @("from: extension $($pl.Rel)", "to:   config $($pl.Rel)", $next)
							$titems += $t; continue
						}
						$me = Get-MdEdits (Get-CfgPath $pl.Rel) $pl.ObjType
						try {
							Apply-MdOp $me $pl $extDir0
							[void]$me.Ops.Add(@{ Plan = $pl; Item = $t })
							$t.Status = 'TRANSFERRED'; $t.Now = $true
							$t.Text = "$($it.Text) — applied"
							$titems += $t
						} catch {
							$msg = $_.Exception.Message
							$skip = $msg.StartsWith('SKIP: ')
							if ($skip) { $msg = $msg.Substring(6) } else { $me.Failed++ }
							$t.Status = 'CONFLICT'
							$t.Text = "$($it.Text) — $msg; $(if ($skip) { 'property not changed' } else { 'object not changed' })"
							$t.Sub = @('next: apply by hand, then re-run -Mode check')
							$titems += $t
						}
						continue
					}
					if ($pl.Kind -eq 'md-content') {
						if ($pl.Missing) {
							$t.Text = "$($it.Text) — the object is not in the configuration"
							$t.Sub = @('next: add the object to the configuration first, then re-run -Mode transfer')
							$titems += $t; continue
						}
						$me = Get-MdEdits (Get-CfgPath $pl.Rel) 'Subsystem'
						try {
							Apply-MdOp $me $pl $extDir0
							[void]$me.Ops.Add(@{ Plan = $pl; Item = $t })
							$t.Status = 'TRANSFERRED'; $t.Now = $true
							$titems += $t
						} catch {
							$msg = $_.Exception.Message
							$skip = $msg.StartsWith('SKIP: ')
							if ($skip) { $msg = $msg.Substring(6) } else { $me.Failed++ }
							$t.Status = 'CONFLICT'
							$t.Text = "$($it.Text) — $msg; $(if ($skip) { 'change not applied' } else { 'object not changed' })"
							$t.Sub = @('next: apply by hand, then re-run -Mode check')
							$titems += $t
						}
						continue
					}
					if ($pl.Conflict) {
						$t.Status = 'CONFLICT'
						$t.Text = "$($it.Text) — $($pl.Conflict); object not changed"
						$next = if ($pl.Next) { $pl.Next } else { 'next: compare the types and merge by hand, then re-run -Mode check' }
						$t.Sub = @("from: extension $($pl.Rel)", "to:   config $($pl.Rel)", $next)
						$titems += $t; continue
					}
					$me = Get-MdEdits (Get-CfgPath $pl.Rel) $pl.ObjType
					# The name is the one pass 2 gave the code, else the container's pool decides
					$tn = if ($script:nameMap.ContainsKey($pl.Name.ToLower())) { @{ Name = $script:nameMap[$pl.Name.ToLower()]; Note = '' } } else { $null }
					if (-not $tn) {
						$m = New-MdNt $me.Fw.Doc
						$co = Get-MdContainer $me $pl.Parent $pl.Tag
						$taken = New-Object 'System.Collections.Generic.HashSet[string]'
						if ($co) { foreach ($x in $co.ChildNodes) { if ($x.NodeType -eq 'Element') { [void]$taken.Add((Get-MdChildName $x $m).ToLower()) } } }
						$gk = "$($pl.Rel)|$($pl.Parent)|$($pl.Tag)"
						if ($mdGiven.ContainsKey($gk)) { foreach ($n in $mdGiven[$gk]) { [void]$taken.Add($n) } }
						$tn = Get-TargetName $pl.Name $prefix $taken $set.AddDevObjects
					}
					if ($tn.Taken) {
						$t.Status = 'CONFLICT'
						$t.Text = "$($it.Text) — name taken in config ($($tn.Note)); object not changed"
						$t.Sub = @('next: rename it in the extension or merge by hand, then re-run -Mode transfer')
						$titems += $t; continue
					}
					$pl.Target = $tn
					$gk = "$($pl.Rel)|$($pl.Parent)|$($pl.Tag)"
					if (-not $mdGiven.ContainsKey($gk)) { $mdGiven[$gk] = @() }
					$mdGiven[$gk] += $tn.Name.ToLower()
					try {
						Apply-MdOp $me $pl $extDir0
						[void]$me.Ops.Add(@{ Plan = $pl; Item = $t })
						$note = if ($tn.Name -ine $pl.Name) { " (as $($tn.Name))" } else { '' }
						$t.Status = 'TRANSFERRED'; $t.Now = $true
						$t.Text = "$($it.Text)$note — structure only, stored values are not migrated"
						$mdWarn += "$($pl.Rel): $($it.Text)$note"
						$titems += $t
					} catch {
						$msg = $_.Exception.Message
						$skip = $msg.StartsWith('SKIP: ')
						if ($skip) { $msg = $msg.Substring(6) } else { $me.Failed++ }
						$t.Status = 'CONFLICT'
						$t.Text = "$($it.Text) — $msg; $(if ($skip) { 'change not applied' } else { 'object not changed' })"
						$t.Sub = @('next: apply by hand, then re-run -Mode check')
						$titems += $t
					}
					continue
				}
				if ($pl.Kind -eq 'missing') {
					$next = if ($pl.CfgM) { "the interceptor does not parse: fix it in the extension, then re-run -Mode transfer" } else { 'the target is not in the configuration: add it there first, then re-run -Mode transfer' }
					$t.Sub = Get-WhereLines $pl $next
					$titems += $t; continue
				}
				$cfgFile = Get-CfgPath $pl.Rel
				$fileMap = if ($fileMaps.ContainsKey($cfgFile.ToLower())) { $fileMaps[$cfgFile.ToLower()] } else { @{} }
				$label = if ($pl.Kind -eq 'own') { "method $($pl.Name)" } elseif ($pl.Kind -eq 'topcode') { 'module code outside methods' } else { $pl.Label }
				if ($w.Support -eq 'locked') {
					$t.Text = "$label — object is locked by vendor support"
					$t.Sub = Get-WhereLines $pl 'allow editing with /support-edit, then re-run -Mode transfer'
					$titems += $t; continue
				}
				$warnNote = if ($w.Support -eq 'warn') { ' (object locked by vendor support, written: editingAllowedCheck = warn)' } else { '' }
				# Code outside methods: module variables go after the configuration's (or before its first
				# method), statements of the module body after the configuration's own, at the module's tail —
				# the extension's body runs after the configuration's, so the order stays
				if ($pl.Kind -eq 'topcode') {
					$label = 'module code outside methods'
					$whereSub = @("from: extension $($pl.Rel):$($pl.Line + 1)")
					if (-not (Test-Path -LiteralPath $cfgFile)) {
						$t.Text = "$label — module not found in config"
						$t.Sub = $whereSub + @('next: add the module to the configuration first, then re-run -Mode transfer')
						$titems += $t; continue
					}
					$fe = Get-FileEdits $cfgFile
					if (-not $pl.Layout) { $pl.Layout = Get-ModuleLayout $pl.ExtLines }
					if (-not $fe.TopKeys) { $fe.TopKeys = @{}; foreach ($key in (Get-TopCodeKeys $fe.File.Lines $prefix).Values) { $fe.TopKeys[$key] = $true } }
					$el = $pl.Layout; $cl = $fe.Layout; $have = $fe.TopKeys
					$extKeys = Get-TopCodeKeys $pl.ExtLines $prefix -Extension
					$taken = @{}
					foreach ($v in $cl.Vars) { foreach ($n in $v.Names) { $taken[$n.ToLower()] = $true } }
					foreach ($n in @(Get-ProcNames $fe.File.Lines)) { $taken[$n.ToLower()] = $true }
					# Each line once: a variable declared twice in the extension is declared once in the configuration
					$seen = @{}
					$stmts = @(); $stmtsHave = 0
					foreach ($i in $el.Statements) {
						$key = $extKeys[[string]$i]
						if ($have.ContainsKey($key)) { $stmtsHave++; continue }
						if ($seen.ContainsKey($key)) { continue }
						$seen[$key] = $true; $stmts += $i
					}
					$todo = @(); $clash = @()
					foreach ($v in $el.Vars) {
						$key = $extKeys[[string]$v.Idx]
						if ($have.ContainsKey($key) -or $seen.ContainsKey($key)) { continue }
						$seen[$key] = $true
						foreach ($n in $v.Names) { $tn = [string](Convert-BslCode @($n) $fileMap)[0]; if ($taken.ContainsKey($tn.ToLower())) { $clash += $tn } }
						$todo += $v
					}
					# Variables that stay out make the code using them wait, like a method that stays out
					$t.OutNames = @(foreach ($v in $todo) { $v.Names }); $t.OutFile = $cfgFile
					$topItems += $t
					# The platform drops a manager module with variables or statements, its methods included
					if ($pl.Rel -match '[\\/]Ext[\\/]ManagerModule\.bsl$') {
						$t.Text = "$label — a manager module with variables or statements is not applied by the platform: this code never ran"
						$t.Sub = $whereSub + @('next: remove the code outside methods from the extension''s manager module (none of its methods run either), then re-run -Mode check')
						$titems += $t; continue
					}
					if ($clash.Count -gt 0) {
						$t.Status = 'CONFLICT'
						$t.Text = "$label — variable $($clash -join ', ') is declared in config already; not changed"
						$t.Sub = $whereSub + @('next: rename or merge by hand, then re-run -Mode check')
						$titems += $t; continue
					}
					$body = $null
					if ($stmts.Count -gt 0) {
						$s0 = $stmts[0]; while ($s0 -gt 0 -and (([string]$pl.ExtLines[$s0 - 1]).Trim() -match '^(//|&)')) { $s0-- }
						$s1 = $stmts[-1]
						$range = @($pl.ExtLines[$s0..$s1])
						$why = $null
						if ($stmtsHave -gt 0) { $why = 'statements of the module body are partly in config' }
						elseif (@($range | Where-Object { ([string]$_).Trim().StartsWith('#') }).Count -gt 0) { $why = 'statements of the module body stand under preprocessor instructions' }
						if ($why) {
							$t.Text = "$label — $why"
							$t.Sub = @("from: extension $($pl.Rel):$($s0 + 1)-$($s1 + 1)", 'next: add them at the end of the configuration module by hand, then re-run -Mode check')
							$titems += $t; continue
						}
						$blockedMethods = @{}
						foreach ($methodMap in @($outByFile[$cfgFile.ToLower()], $outCommon)) {
							if ($methodMap) { foreach ($name in $methodMap.Keys) { $blockedMethods[$name] = $methodMap[$name] } }
						}
						$deps = @(Get-UsedMissing $range $blockedMethods)
						if ($deps.Count -gt 0) {
							$t.Status = 'WAITING'
							$t.Text = "$label — waits for: $($deps -join ', ')"
							$t.Sub = @("from: extension $($pl.Rel):$($s0 + 1)-$($s1 + 1)", 'next: transfer the required methods, then re-run -Mode transfer')
							$titems += $t; continue
						}
						$body = Convert-BslCode $range $fileMap
					}
					$parts = @()
					if ($todo.Count -gt 0) {
						$block = @()
						foreach ($v in $todo) { $cv = Convert-BslCode @($pl.ExtLines[$v.Start..$v.Idx]) $fileMap; $block += $cv }
						$block = Get-Framed $block $frame
						if ($cl.LastVar -ge 0) { [void]$fe.Repl.Add(@{ Start = $cl.LastVar + 1; End = $cl.LastVar + 1; Lines = $block; Seq = $script:seq++ }); $where = 'after the module variables' }
						else {
							$at = if ($cl.FirstMethod -ge 0) { $cl.FirstMethod } else { Get-ModuleEnd $fe.File.Lines }
							[void]$fe.Repl.Add(@{ Start = $at; End = $at; Lines = (Get-SpacedBlock $fe.File.Lines $at $block); Seq = $script:seq++ })
							$where = if ($cl.FirstMethod -ge 0) { 'before the first method' } else { 'end of module' }
						}
						$parts += "$(Get-Plural $todo.Count 'variable declaration') -> $where"
					}
					if ($null -ne $body) {
						[void]$fe.Tail.Add((Get-Framed $body $frame))
						$parts += "statements of the module body -> end of module"
					}
					if ($parts.Count -eq 0) { $t.Status = 'TRANSFERRED'; $titems += $t; continue }
					$t.Status = 'TRANSFERRED'; $t.Now = $true
					$t.Text = "$label — $($parts -join '; ')$warnNote"
					$titems += $t; continue
				}
				# Code that uses names the configuration does not have yet waits for them
				$missing = @{}
				foreach ($m in @($missingGlobal, $missingByObj[$w.Id])) { if ($m) { foreach ($k in $m.Keys) { $missing[$k] = $m[$k] } } }
				if ((Get-ModuleKind $pl.Rel) -eq 'form') {
					$fk = $pl.Rel.ToLower()
					if (-not $formMissing.ContainsKey($fk)) {
						$fx = { param($root) ((Join-Path $root $pl.Rel) -replace '[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml') }
						$formMissing[$fk] = Get-MissingNames (Get-FormItemNames (& $fx $extDir0)) (Get-FormItemNames (& $fx $ConfigPath))
					}
					foreach ($k in $formMissing[$fk].Keys) { $missing[$k] = $formMissing[$fk][$k] }
					# Form items the form module marks "not for transfer" are never coming
					if (-not $formTemp.ContainsKey($fk)) {
						$fm = Get-FormTempMarks (Read-BslLines (Join-Path $extDir0 $pl.Rel))
						$formTemp[$fk] = @{}
						foreach ($k in $fm.Keys) { $formTemp[$fk][$k] = $(if ($formMissing[$fk].ContainsKey($k)) { $formMissing[$fk][$k] } else { $k }) }
					}
					foreach ($k in $formTemp[$fk].Keys) { $missing.Remove($k) }
				}
				foreach ($m in @($outByFile[$cfgFile.ToLower()], $outCommon)) { if ($m) { foreach ($k in $m.Keys) { $missing[$k] = $m[$k] } } }
				# A method calling itself does not wait for itself
				if ($pl.Kind -eq 'own') { $missing.Remove($pl.Name.ToLower()) }
				$selected2 = $null
				if ($pl.Kind -eq 'control') {
					$cp2 = Get-ControlProjection $pl.ExtM.BodyLines $fileMap $prefix $pl.ExtM.ParamNames
					$code = $cp2.Desired; $selected2 = @{}
					foreach ($op2 in @($pl.Ops | Where-Object { $_.Res -eq 'pending' -and $_.Op.Kind -eq 'insert' })) {
						$range2 = $cp2.Ranges[$op2.Op.SourceIndex]
						for ($j2 = $range2.Start; $j2 -lt $range2.End; $j2++) { $selected2[$j2] = $true }
					}
				} else { $code = @($pl.ExtM.BodyLines) }
				$deps = @(Get-UsedMissing $code $missing $selected2 $pl.ExtM.ParamNames)
				# A conflict or a missing module shows first: waiting would hide it
				$blocked = ($pl.Kind -eq 'control' -and @($pl.Ops | Where-Object { @('pending', 'absorbed', 'temp') -notcontains $_.Res }).Count -gt 0) -or
					($pl.Kind -eq 'own' -and ($it.Status -eq 'DIVERGED' -or $pl.CfgMissing -or ($pl.Target -and $pl.Target.Taken))) -or
					($pl.Kind -eq 'intercept' -and $it.Status -eq 'PARTIAL')
				$tempMap = @{}
				foreach ($m in @($tempByFile[$cfgFile.ToLower()], $tempCommon)) { if ($m) { foreach ($k in $m.Keys) { $tempMap[$k] = $m[$k] } } }
				$tempDeps = @(Get-UsedMissing $code $tempMap $selected2 $pl.ExtM.ParamNames)
				if ($tempDeps.Count -gt 0 -and -not $blocked) {
					$t.Text = "$label — calls $($tempDeps -join ', '), marked as not for transfer"
					$t.Sub = Get-WhereLines $pl 'drop the call before the transfer or remove the mark from the method, then re-run -Mode transfer'
					$titems += $t; continue
				}
				$formTempDeps = if ((Get-ModuleKind $pl.Rel) -eq 'form') { @(Get-UsedMissing $code $formTemp[$pl.Rel.ToLower()] $selected2 $pl.ExtM.ParamNames) } else { @() }
				if ($formTempDeps.Count -gt 0 -and -not $blocked) {
					$t.Text = "$label — uses form items $($formTempDeps -join ', '), marked as not for transfer"
					$t.Sub = Get-WhereLines $pl 'drop the use before the transfer or remove the mark from the form module, then re-run -Mode transfer'
					$titems += $t; continue
				}
				if ($deps.Count -gt 0 -and -not $blocked) {
					$shownDeps = @($deps | Select-Object -First 5)
					$more = if ($deps.Count -gt 5) { ", …+$($deps.Count - 5)" } else { '' }
					$t.Status = 'WAITING'
					$t.Text = "$label — waits for: $($shownDeps -join ', ')$more"
					$titems += $t; continue
				}
				if ($pl.Kind -eq 'intercept') {
					if ($it.Status -eq 'PARTIAL') {
						$t.Status = 'CONFLICT'
						$t.Text = "$($it.Text) — partly in the configuration already; method not changed"
						$t.Sub = Get-WhereLines $pl 'compare with the original and finish by hand, then re-run -Mode check'
						$titems += $t; continue
					}
					$r = Get-InterceptOps $pl.ExtM $pl.CfgM $pl.Type $frame $set.Deletion $fileMap
					if ($r.Why) {
						$t.Text = "$label — $($r.Why)"
						$t.Sub = Get-WhereLines $pl $(if ($r.Next) { $r.Next } else { 'apply by hand, then re-run -Mode check' })
						$titems += $t; continue
					}
					# Laid once every interceptor of the module is known: two of one method go together
					$icPending += @{ T = $t; Pl = $pl; Fe = (Get-FileEdits $cfgFile); Ops = $r.Ops; Where = $r.Where; Label = $label; Warn = $warnNote; Locals = $r.Locals; Words = $r.Words }
					$titems += $t; continue
				}
				if ($pl.Kind -eq 'control') {
					$fit = @($pl.Ops | Where-Object { $_.Res -eq 'pending' -or $_.Res -eq 'absorbed' }).Count
					$pend = @($pl.Ops | Where-Object { $_.Res -eq 'pending' }).Count
					$div = @($pl.Ops | Where-Object { @('pending', 'absorbed', 'temp') -notcontains $_.Res })
					if ($div.Count -gt 0) {
						$t.Status = 'CONFLICT'
						$t.Text = "$label — $fit of $($fit + $div.Count) edits fit, $($div.Count) diverged; method not changed"
						$t.Sub = @($div | ForEach-Object { "diverged: $($_.Res)" }) + @(Get-WhereLines $pl 'original changed in config -> /cfe-patch-method -Actualize, then re-run -Mode transfer; otherwise apply by hand')
						$titems += $t; continue
					}
					$fe = Get-FileEdits $cfgFile
					$body = Get-ControlBody $pl.CfgM $pl.Ops $frame $set.Deletion $fileMap $pl.ExtM
					# The check must see the result as transferred, or a re-run would carry it over again:
					# the new body goes through the same comparison before anything is written
					$gap = Get-ControlResultGap $pl $body
					if ($gap -gt 0) {
						$t.Status = 'CONFLICT'
						$t.Text = "$label — after the transfer the check would still see $(Get-Plural $gap 'edit') as not transferred; method not changed"
						$t.Sub = Get-WhereLines $pl 'lines moved within the method or already partly carried over: transfer by hand, then re-run -Mode check'
						$titems += $t; continue
					}
					[void]$fe.Repl.Add(@{ Start = $pl.CfgM.SigEndIdx + 1; End = $pl.CfgM.BodyEndIdx; Lines = $body; Seq = $script:seq++ })
					$t.Status = 'TRANSFERRED'; $t.Now = $true
					$already = $fit - $pend
					$t.Text = "$label — $(Get-Plural $pend 'edit')$(if ($already) { ", $already already there" })$warnNote"
					$titems += $t; continue
				}
				# own method
				if ($it.Status -eq 'DIVERGED') {
					$t.Status = 'CONFLICT'
					$t.Text = "$($it.Text); not changed"
					$t.Sub = Get-WhereLines $pl 'compare the bodies and merge by hand'
					$titems += $t; continue
				}
				if ($pl.CfgMissing) {
					$t.Text = "$label — module not found in config"
					$t.Sub = Get-WhereLines $pl 'add the module to the configuration first, then re-run -Mode transfer'
					$titems += $t; continue
				}
				if ($pl.Target.Taken) {
					$t.Status = 'CONFLICT'
					$t.Text = "$label — name taken in config ($($pl.Target.Note)); not changed"
					$t.Sub = Get-WhereLines $pl 'rename the method or merge by hand'
					$titems += $t; continue
				}
				$fe = Get-FileEdits $cfgFile
				$kindMod = Get-ModuleKind $pl.Rel
				$bind = @{}
				if ($kindMod -eq 'form') { $bind = Get-FormBindings ((Join-Path $extDir0 $pl.Rel) -replace '[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml') }
				$notify = Get-NotifyNames (@($pl.ExtLines) + @($fe.File.Lines))
				$role = Get-MethodRole $pl.Name $kindMod $bind $notify (Test-IsExport $pl.ExtLines $pl.ExtM)
				$created = @($fe.Create.Keys | ForEach-Object { $_.ToLower() })
				$place = Get-MethodPlace $fe.File.Lines $fe.Regions $pl.ExtM $role $set $created
				$block = Get-OwnMethodBlock $pl.ExtLines $pl.ExtM $frame $fileMap
				if (-not (Test-OwnResult $pl $fe $fileMap)) {
					$t.Status = 'CONFLICT'
					$t.Text = "$label — after the transfer the check would not find it under $($pl.Target.Name); not changed"
					$t.Sub = Get-WhereLines $pl 'transfer by hand'
					$titems += $t; continue
				}
				if ($place.Create) {
					$key = @($fe.Create.Keys | Where-Object { $_ -ieq $place.Create })[0]
					if (-not $key) { $key = $place.Create; $fe.Create[$key] = New-Object System.Collections.ArrayList }
					[void]$fe.Create[$key].Add($block)
					$where = "new region $key"
				} else {
					$at = [int]$place.At
					if (-not $fe.OwnAt.ContainsKey($at)) { $fe.OwnAt[$at] = @{ Blocks = (New-Object System.Collections.ArrayList); Seq = $script:seq++ } }
					[void]$fe.OwnAt[$at].Blocks.Add($block)
					$where = if ($place.Region) { "region $($place.Region)" } else { 'end of module' }
				}
				$t.Status = 'TRANSFERRED'; $t.Now = $true
				$note = if ($pl.Target.Note) { " ($($pl.Target.Note))" } else { '' }
				$t.Text = "$label$note -> $where$warnNote"
				$titems += $t
			}
			if ($titems.Count -eq 0) { continue }
			# A hashtable's keys are not what Sort-Object orders by: the index is taken by expression
			$titems = @($titems | Sort-Object -Property @{ Expression = { [int]$_.Seq } })
			$recs += @{ Id = $w.Id; Items = $titems }
		}
		# Interceptors, by the method they intercept: &Перед and &После of one method go into one body;
		# &Вместо next to another interceptor, or any next to &ИзменениеИКонтроль, is left to a person
		$icGroups = [ordered]@{}
		foreach ($p in $icPending) {
			$key = "$($p.Fe.File.Path.ToLower())|$($p.Pl.CfgM.DeclIdx)"
			if (-not $icGroups.Contains($key)) { $icGroups[$key] = @() }
			$icGroups[$key] += $p
		}
		foreach ($key in @($icGroups.Keys)) {
			$g = @($icGroups[$key])
			$fe = $g[0].Fe; $cfgM = $g[0].Pl.CfgM
			Set-BslContext $g[0].Pl.Rel
			$manual = $null
			if ($ctlKeys.ContainsKey($key)) { $manual = 'the method has &ИзменениеИКонтроль too' }
			elseif ($g.Count -gt 1 -and @($g | Where-Object { $_.Pl.Type -eq 'Вместо' }).Count -gt 0) { $manual = 'the method has other interceptors too' }
			elseif ($g.Count -gt 1) {
				# Two handlers in one body: a local of one that the other names becomes one variable
				$shared = @()
				for ($a = 0; $a -lt $g.Count; $a++) {
					for ($b = 0; $b -lt $g.Count; $b++) {
						if ($a -eq $b) { continue }
						foreach ($k in $g[$a].Locals.Keys) { if ($g[$b].Words.Contains($k)) { $shared += $g[$a].Locals[$k] } }
					}
				}
				$shared = @($shared | Select-Object -Unique)
				if ($shared.Count -gt 0) { $manual = "variable $($shared -join ', ') is in more than one interceptor of the method" }
			}
			if ($manual) {
				foreach ($p in $g) { $p.T.Text = "$($p.Label) — $manual"; $p.T.Sub = Get-WhereLines $p.Pl 'apply by hand, then re-run -Mode check' }
				continue
			}
			$ops = @(); foreach ($p in $g) { $ops += @($p.Ops) }
			$body = Get-InterceptBody $cfgM.BodyLines $ops
			# The check must find every handler's code in the new body, or a re-run would put it in again
			$m2 = @{ BodyLines = $body; ParamNames = $cfgM.ParamNames }
			$bad = @($g | Where-Object { $h2 = Get-HeuristicTransfer $_.Pl.ExtM $m2 $prefix; $h2 -and $h2.Found -ne $h2.Total })
			if ($bad.Count -gt 0) {
				foreach ($p in $g) { $p.T.Status = 'CONFLICT'; $p.T.Text = "$($p.Label) — after the transfer the check would not find the handler's code; method not changed"; $p.T.Sub = Get-WhereLines $p.Pl 'apply by hand, then re-run -Mode check' }
				continue
			}
			[void]$fe.Repl.Add(@{ Start = $cfgM.SigEndIdx + 1; End = $cfgM.BodyEndIdx; Lines = $body; Seq = $script:seq++ })
			foreach ($p in $g) { $p.T.Status = 'TRANSFERRED'; $p.T.Now = $true; $p.T.Text = "$($p.Label) — $($p.Where)$($p.Warn)" }
		}
		# Module variables that stay out, the same way
		foreach ($o in $topItems) {
			if ($o.Status -eq 'TRANSFERRED') { continue }
			$fk = $o.OutFile.ToLower()
			if (-not $outByFile.ContainsKey($fk)) { $outByFile[$fk] = @{} }
			foreach ($nm in $o.OutNames) { if (-not $outByFile[$fk].ContainsKey($nm.ToLower())) { $outByFile[$fk][$nm.ToLower()] = $nm; $again = $true } }
		}
		# Own methods that stay out: new ones make the pass run again
		foreach ($o in $ownItems) {
			if ($o.T.Status -eq 'TRANSFERRED') { continue }
			if (Add-OutName $outByFile $outCommon (Get-CfgPath $o.Plan.Rel) $o.Plan.Rel $o.Plan.Name) { $again = $true }
		}
	} while ($again)

	# --- Pass 4: write ---
	$changed = Write-FileEdits
	foreach ($fe in @($script:formEdits.Values)) {
		if ($fe.Ops.Count -eq 0 -and $fe.Failed -eq 0) { continue }
		$why = if ($fe.Failed -gt 0) { 'another change of the same form could not be applied' } else { $null }
		if (-not $why) {
			$miss = Test-FormWrite $fe
			if ($miss.Count -gt 0) { $why = "after the transfer the check would not find it: $($miss[0])" }
		}
		if ($why) {
			foreach ($op in $fe.Ops) {
				$op.Item.Status = 'CONFLICT'; $op.Item.Now = $false
				$op.Item.Text = "$($op.Item.Text) — $why; form not changed"
				$op.Item.Sub = @('next: apply by hand, then re-run -Mode check')
			}
			continue
		}
		Save-FormWrite $fe.Fw
		$changed += $fe.Path
	}
	# Metadata: written only after the same comparison and the validator see it in place
	foreach ($me in @($script:mdEdits.Values)) {
		if ($me.Ops.Count -eq 0) { continue }
		$why = if ($me.Failed -gt 0) { 'another change of the same file could not be applied' } else { $null }
		if (-not $why) {
			$miss = Test-MdWrite $me
			if ($miss.Count -gt 0) { $why = "after the transfer the check would not find it: $($miss[0])" }
		}
		if ($why) {
			foreach ($op in $me.Ops) {
				$op.Item.Status = 'CONFLICT'; $op.Item.Now = $false
				$op.Item.Text = "$($op.Item.Text) — $why; object not changed"
				$op.Item.Sub = @('next: apply by hand, then re-run -Mode check')
			}
			continue
		}
		Save-FormWrite $me.Fw
		$changed += $me.Path
	}

	# --- Report ---
	$cNow = 0; $cAlready = 0; $cWait = 0; $cManual = 0; $cConflict = 0
	$body = @()
	$anyFolded = $false
	$body += "=== cfe-transfer transfer: $($ext.Name) ($($ext.Purpose)) -> $($cfgInfo.Name) ==="
	if ($ext.Prefix) { $body += "NamePrefix: $($ext.Prefix)" }
	$body += ""
	$shown = 0
	foreach ($r in $recs) {
		$now = @($r.Items | Where-Object { $_.Now }).Count
		$already = @($r.Items | Where-Object { $_.Status -eq 'TRANSFERRED' -and -not $_.Now }).Count
		$wait = @($r.Items | Where-Object { $_.Status -eq 'WAITING' }).Count
		$man = @($r.Items | Where-Object { $_.Status -eq 'MANUAL' }).Count
		$con = @($r.Items | Where-Object { $_.Status -eq 'CONFLICT' }).Count
		$cNow += $now; $cAlready += $already; $cWait += $wait; $cManual += $man; $cConflict += $con
		if (($now + $wait + $man + $con) -eq 0) { continue }
		$st = if ($con) { 'CONFLICT' } elseif ($man) { 'MANUAL' } elseif ($wait) { 'WAITING' } else { 'TRANSFERRED' }
		$parts = @()
		if ($now) { $parts += "$now transferred now" }
		if ($wait) { $parts += "$wait waiting" }
		if ($man) { $parts += "$man manual" }
		if ($con) { $parts += "$con conflict" }
		if ($already) { $parts += "$already already transferred" }
		$body += "$(Format-Status $st)$($r.Id) — $($parts -join ', ')"
		$dv = Get-TransferDetails $ext $r 'already transferred'
		$body += $dv.Lines
		if ($dv.Folded) { $anyFolded = $true }
		$shown++
	}
	if ($shown -eq 0) { $body += if ($recs.Count -gt 0) { "All changes already transferred." } else { "No changes to transfer." } }
	$body += ""

	$footer = @()
	$parts = @("$cNow transferred now")
	if ($cWait) { $parts += "$cWait waiting" }
	if ($cManual) { $parts += "$cManual manual" }
	if ($cConflict) { $parts += "$cConflict conflict" }
	$tail = @()
	if ($cAlready) { $tail += "$cAlready already transferred" }
	if ($tempCount) { $tail += "$tempCount temporary skipped" }
	if ($roles) { $tail += "$(Get-Plural $roles 'role'), not transferred" }
	$tailText = if ($tail.Count) { " · $($tail -join ' · ')" } else { '' }
	$footer += "=== Summary $($ext.Name): $($parts -join ', ')$tailText ==="
	# The values the extension wrote into its own attributes do not come along: loud and never cut by
	# the detail budget, so it goes into the footer with the summary
	if ($mdWarn.Count -gt 0) {
		$footer += "!!! Stored data is NOT migrated:"
		foreach ($l in @($mdWarn | Select-Object -Unique)) { $footer += "    $l" }
		$footer += "    The metadata is transferred as structure only, with new identifiers. Values the extension"
		$footer += "    wrote into its own attributes stay in the extension's columns and are LOST when it is"
		$footer += "    disabled or removed. Copy them into the configuration's attributes BEFORE that."
	}
	if ($changed.Count -gt 0) {
		$footer += "Changed files:"
		foreach ($c in $changed) { $footer += "    $(Get-RelPath $ConfigPath $c)" }
		$footer += "Hint: validate the changed modules, then re-run -Mode check"
	}
	if ($cConflict) { $footer += "Hint: resolve each conflict (see next:), then re-run -Mode transfer" }
	if ($script:formValidateMissing) { $footer += "Hint: /form-validate is not installed — the written forms were not checked; run /form-validate by hand" }
	if ($script:mdValidateMissing) { $footer += "Hint: /meta-validate (or /subsystem-validate) is not installed — the written metadata was not checked; run it by hand" }
	if ($cWait) { $footer += "Hint: waiting changes go over by themselves on a re-run of -Mode transfer once what they wait for is in the configuration: own methods of this run (see their lines), objects, sub-objects and form items (by hand for now)" }
	$footer += Get-BslWarningReport $recs $extDir0
	$failed = ($cWait + $cManual + $cConflict) -gt 0
	$showDetails = $true
} else {
	$exts = @()
	$matchedIds = @{}
	foreach ($dir in $extDirs) {
		$cp = Read-ConfigurationProps $dir
		Initialize-BslCatalog $dir ([string]$cp.Prefix)
		$ext = @{ Dir = $dir; Name = $cp.Name; Prefix = $cp.Prefix; Purpose = $cp.Purpose; Objects = @(); Roles = 0; Matched = 0 }
		if ($cp.ChildObjects) {
			foreach ($child in $cp.ChildObjects.ChildNodes) {
				if ($child.NodeType -ne 'Element' -or $child.LocalName -eq 'Language') { continue }
				$obj = @{ Type = $child.LocalName; Name = $child.InnerText.Trim() }
				$id = "$($obj.Type).$($obj.Name)"
				if (-not (Test-NameMatch $id)) { continue }
				$matchedIds[$id.ToLower()] = $true
				$ext.Matched++
				if ($obj.Type -eq 'Role') { $ext.Roles++; continue }
				$rec = Get-TransferObject $ext $obj
				if ($rec.Items.Count -eq 0) { continue }
				# Temporary changes are not for transfer: they neither leave the object incomplete nor set its status
				$sts = @($rec.Items | Where-Object { $_.Status -ne 'TEMPORARY' } | ForEach-Object { $_.Status } | Select-Object -Unique)
				# A mix shows its most alarming status: a conflict must not hide behind PARTIAL
				$rec.Status = if ($sts.Count -eq 0) { 'TEMPORARY' } elseif ($sts.Count -eq 1) { $sts[0] } elseif ($sts -contains 'DIVERGED') { 'DIVERGED' } elseif ($sts -contains 'MISSING_IN_CONFIG') { 'MISSING_IN_CONFIG' } else { 'PARTIAL' }
				$done = @($rec.Items | Where-Object { $_.Status -eq 'TRANSFERRED' }).Count
				$temp = @($rec.Items | Where-Object { $_.Status -eq 'TEMPORARY' }).Count
				$rec.Complete = (($done + $temp) -eq $rec.Items.Count)
				$tempNote = if ($temp -gt 0) { ", $temp temporary" } else { '' }
				$tail = if ($rec.Complete) { "$(Get-Plural $rec.Items.Count 'change')$(if ($temp) { " ($temp temporary)" })" } else { "$(Get-Plural $rec.Items.Count 'change'): $done transferred, $($rec.Items.Count - $done - $temp) remaining$tempNote" }
				$rec.Summary = "$(Format-Status $rec.Status)$($rec.Id) — $tail"
				$dv = Get-TransferDetails $ext $rec
				$rec.Details = $dv.Lines
				$rec.Folded = $dv.Folded
				# Asked for by name or opened with -Expand (the object or one of its sections): details even when all is transferred
				$rec.Asked = ($nameFilter.Count -gt 0) -or $dv.Open
				$ext.Objects += $rec
			}
		}
		$ext.StringWarnings = Get-BslWarningReport $ext.Objects $dir
		# -Name narrows the report: an extension without a matching object stays out of it
		if ($nameFilter.Count -gt 0 -and $ext.Matched -eq 0) { continue }
		$exts += $ext
	}

	# --- Detail decision ---
	$fullCount = 0
	foreach ($ext in $exts) {
		$fullCount += 3
		foreach ($o in $ext.Objects) {
			$fullCount += 1
			if (-not $o.Complete -or $o.Asked) { $fullCount += $o.Details.Count }
		}
	}
	$showDetails = ($nameFilter.Count -gt 0) -or ($expandList.Count -gt 0) -or ($fullCount -le $DetailBudget)

	# --- Body ---
	$body = @()
	$anyFolded = $false
	foreach ($ext in $exts) {
		$body += "=== cfe-transfer check: $($ext.Name) ($($ext.Purpose)) -> $($cfgInfo.Name) ==="
		if ($ext.Prefix) { $body += "NamePrefix: $($ext.Prefix)" }
		$body += ""
		$shown = 0
		foreach ($o in $ext.Objects) {
			if ($o.Complete -and -not $showDetails) { continue }
			$body += $o.Summary
			$shown++
			if ($showDetails -and (-not $o.Complete -or $o.Asked)) {
				$body += $o.Details
				if ($o.Folded) { $anyFolded = $true }
			}
		}
		if ($shown -eq 0) {
			if ($ext.Objects.Count -gt 0) { $body += "All changes transferred." }
			else { $body += "No changes to transfer." }
		}
		$body += ""
	}

	# --- Footer: always printed, after the body (output is often read from its tail) ---
	$footer = @()
	$failed = $false
	$extDone = 0; $extLeft = 0; $leftTotal = 0
	foreach ($ext in $exts) {
		$footer += $ext.StringWarnings
		$all = @($ext.Objects | ForEach-Object { $_.Items } | ForEach-Object { $_ })
		$rolesNote = if ($ext.Roles) { " · $(Get-Plural $ext.Roles 'role'), not checked" } else { '' }
		if ($all.Count -eq 0) {
			$footer += "=== Summary $($ext.Name): no changes to transfer$rolesNote ==="
			$extDone++
			continue
		}
		$cnt = @{}
		foreach ($s in $statusOrder) { $cnt[$s] = @($all | Where-Object { $_.Status -eq $s }).Count }
		# A workaround carried over although marked "not for transfer" is worth a look: counted apart
		$marked = @($all | Where-Object { $_.Marked }).Count
		$markedNote = if ($marked -gt 0) { " ($marked marked temporary)" } else { '' }
		$parts = @("$($cnt['TRANSFERRED']) transferred$markedNote")
		foreach ($s in $statusOrder[1..($statusOrder.Count - 1)]) { if ($cnt[$s]) { $parts += "$($cnt[$s]) $($s.ToLower().Replace('_', ' '))" } }
		$footer += "=== Summary $($ext.Name): $(Get-Plural $all.Count 'change') — $($parts -join ', ')$rolesNote ==="
		$left = $all.Count - $cnt['TRANSFERRED'] - $cnt['TEMPORARY']
		if ($left -gt 0) {
			$failed = $true; $extLeft++; $leftTotal += $left
			$ids = @($ext.Objects | Where-Object { -not $_.Complete } | ForEach-Object { $_.Id })
			$shown = @($ids | Select-Object -First 10)
			$more = if ($ids.Count -gt 10) { ", …+$($ids.Count - 10)" } else { '' }
			$footer += "Remaining: $($shown -join ', ')$more"
		} else { $extDone++ }
	}
	if ($exts.Count -gt 1) {
		$tail = if ($extLeft) { ", $extLeft with $leftTotal remaining" } else { '' }
		$footer += "=== Total: $($exts.Count) extensions — $extDone complete$tail ==="
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
if ($anyFolded) {
	$what = if ($Mode -eq 'transfer') { 'already transferred' } else { 'transferred' }
	$footer += "Hint: use -Expand <Type.Name> or a section path to list $what changes, -Expand * for all"
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

if ($failed) { exit 1 }
exit 0
