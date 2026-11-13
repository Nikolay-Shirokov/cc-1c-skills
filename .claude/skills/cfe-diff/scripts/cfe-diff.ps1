# cfe-diff v2.0 — Analyze 1C configuration extension (CFE): overview and transfer check against the main configuration
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
# check-transfer is 'transfer' inside the script; the name says it checks, it does not carry over
$modeMap = @{ "overview" = "overview"; "check-transfer" = "transfer"; "a" = "overview"; "b" = "transfer" }
$modeKey = $Mode.Trim().ToLower()
if (-not $modeMap.ContainsKey($modeKey)) {
	Write-Error "Invalid -Mode '$Mode'. Expected: overview, check-transfer"
	exit 1
}
$Mode = $modeMap[$modeKey]

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

$cfgInfo = $null
if ($ConfigPath) {
	$ConfigPath = Resolve-InputPath $ConfigPath
	$cfgInfo = Read-ConfigurationProps $ConfigPath
	if (-not $cfgInfo) { Write-Error "Config Configuration.xml not found: $(Join-Path $ConfigPath 'Configuration.xml')"; exit 1 }
}
if ($Mode -eq "transfer" -and -not $cfgInfo) {
	Write-Error "-Mode check-transfer needs -ConfigPath (the main configuration to check against)"
	exit 1
}

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

# Control comparison key, as the platform compares a &ИзменениеИКонтроль copy with the original:
# each line trimmed, blank lines dropped, everything else byte-for-byte and case-sensitive
# (inner spaces, comments and letter case are significant). Measured on 8.3.24 and 8.3.27.
function Get-ControlKey {
	param($lines)
	return (@($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join "`n")
}

# Parameter count of a signature params text. The platform compares only the number of
# parameters of a &ИзменениеИКонтроль copy (names and default values it ignores).
function Get-ParamCount {
	param([string]$paramsText)
	if ([string]::IsNullOrWhiteSpace($paramsText)) { return 0 }
	return @(Split-TopLevel $paramsText | Where-Object { $_.Trim() -ne '' }).Count
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
	$s = Remove-ExtPrefix $name $prefix
	foreach ($c in $names) { if ((Remove-ExtPrefix $c $prefix) -ieq $s) { return $c } }
	return $null
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

function Get-MethodSafe($lines, [string]$methodName) {
	if ($null -eq $lines -or [string]::IsNullOrEmpty($methodName)) { return $null }
	try { return (Extract-Method $lines $methodName) } catch { return $null }
}

# Comparable form of a code line: normalized, without the extension prefix, lower case (the language
# ignores case; lowering here also keeps the copied matchers' -eq and Python's == in agreement)
function Get-CodeKey([string]$line, [string]$prefix) {
	return (Get-Normalized (Remove-ExtPrefix $line $prefix)).ToLowerInvariant()
}

# Get-CodeKey over a list of lines, inlined: a function call per line is what costs in PowerShell.
# -Significant keeps only lines that carry code (Test-Significant).
function Get-CodeKeys($lines, [string]$prefix, [switch]$Significant) {
	$re = $null
	if (-not [string]::IsNullOrEmpty($prefix)) { [void](Remove-ExtPrefix 'x' $prefix); $re = $script:prefixRe }
	$r = New-Object 'System.Collections.Generic.List[string]'
	foreach ($l in $lines) {
		$t = [string]$l
		if ($re -and $t.Length -gt 0) { $t = $re.Replace($t, '') }
		$t = ($t -replace '\s+', ' ').Trim().ToLowerInvariant()
		if ($Significant -and ($t -eq '' -or $t.StartsWith('//'))) { continue }
		$r.Add($t)
	}
	return $r.ToArray()
}

# Significant lines of a body as code keys
function Get-SigLines($lines, [string]$prefix) {
	return ,@(Get-CodeKeys $lines $prefix -Significant)
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
	if ($t -match '^(?i)(?:не\s*переносить|временно)(?![\p{L}\p{Nd}_])\s*[:\-–—]?\s*(.*)$') { return $Matches[1].Trim() }
	return $null
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
	return (New-Item2 'TEMPORARY' "$label$(Format-TempWhy $mark)" $item.Loc $item.Group)
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
function Get-ControlTransfer($extMethod, $cfgMethod, [string]$prefix) {
	$parsed = Parse-MarkedBody $extMethod.BodyLines
	$ops = @($parsed.Ops)
	$v1norm = @(Get-CodeKeys $parsed.V1 $prefix)
	$v2norm = @(Get-CodeKeys $cfgMethod.BodyLines $prefix)
	$v2proj = Get-SignificantProjection $v2norm
	$v1sig = @((Get-SignificantProjection $v1norm).Sig)
	$absorbed = 0; $pending = 0; $disputed = @(); $temp = 0; $tempWhy = $null; $markedDone = 0
	$payloads = @{}
	for ($oi = 0; $oi -lt $ops.Count; $oi++) {
		if ($ops[$oi].Kind -eq 'insert') { $payloads[$oi] = @(Get-CodeKeys $ops[$oi].Lines $prefix -Significant) }
	}
	$replaced = Get-AbsorbedInPlace $ops $v1norm $v2norm $v2proj.Sig $payloads
	$deleted = @{}
	foreach ($op in $ops) { if ($op.Kind -eq 'delete') { for ($m = $op.Start; $m -le $op.End; $m++) { $deleted[$m] = $true } } }
	$oi = -1
	foreach ($op in $ops) {
		$oi++
		# $res: 'absorbed', 'pending' or the reason the edit is disputed
		if ($op.Kind -eq 'insert') {
			$payloadSig = @($payloads[$oi])
			# A comment-only insert carries nothing to transfer
			if ($payloadSig.Count -eq 0) { continue }
			if ($replaced.ContainsKey($oi)) { $res = 'absorbed' }
			else {
				$beforeLines = @()
				if ($op.After -ge 0) { $bs = [Math]::Max(0, $op.After - 2); for ($m = $bs; $m -le $op.After; $m++) { $beforeLines += $v1norm[$m] } }
				$afterLines = @()
				$ae = [Math]::Min($v1norm.Count - 1, $op.After + 3)
				for ($m = $op.After + 1; $m -le $ae; $m++) { $afterLines += $v1norm[$m] }
				$k = Resolve-InsertionPoint $v2norm $beforeLines $afterLines
				# The looser checks below accept the payload only as new code: the configuration has it
				# more times than the original method (an insert repeating a line next to it otherwise
				# finds that very line)
				$isNew = (Get-RunCount $v2proj.Sig $payloadSig) -gt (Get-RunCount $v1sig $payloadSig)
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
				if ($isAbsorbed) { $res = 'absorbed' }
				elseif ($null -ne $k) { $res = 'pending' }
				elseif ($bIdx -ge 0) { $res = Get-DisputeReason 'insert' $parsed.V1[$bIdx] $bCtx 'before' $v2norm }
				elseif ($aIdx -ge 0) { $res = Get-DisputeReason 'insert' $parsed.V1[$aIdx] $aCtx 'after' $v2norm }
				else { $res = Get-DisputeReason 'insert' '' '' '' $v2norm }
			}
		} else {
			if ($replaced.ContainsKey($oi)) { $res = 'absorbed' }
			else {
				$keys = @(); for ($m = $op.Start; $m -le $op.End; $m++) { $keys += $v1norm[$m] }
				$p = Find-UniqueRun $v2norm $keys
				if ($p -ge 0) { $res = 'pending' }
				else {
					$delBeforeCtx = $null; for ($z = $op.Start - 1; $z -ge 0; $z--) { if (Test-Significant $v1norm[$z]) { $delBeforeCtx = $v1norm[$z]; break } }
					$delAfterCtx = $null; for ($z = $op.End + 1; $z -lt $v1norm.Count; $z++) { if (Test-Significant $v1norm[$z]) { $delAfterCtx = $v1norm[$z]; break } }
					if (Test-DeleteAbsorbed $v2proj.Sig $delBeforeCtx $delAfterCtx) { $res = 'absorbed' }
					else {
						$first = @($op.Lines | Where-Object { Test-Significant (Get-Normalized $_) } | Select-Object -First 1)
						$line = if ($first.Count -gt 0) { $first[0] } else { '' }
						$res = Get-DisputeReason 'delete' $line '' '' $v2norm
					}
				}
			}
		}
		# A block marked "not for transfer" counts as temporary only while it is not in the configuration
		$mark = Get-BlockTempMark $op
		if ($null -ne $mark -and $res -ne 'absorbed') { $temp++; if ($null -eq $tempWhy) { $tempWhy = $mark }; continue }
		if ($res -eq 'absorbed') { $absorbed++; if ($null -ne $mark) { $markedDone++ } }
		elseif ($res -eq 'pending') { $pending++ }
		else { $disputed += $res }
	}
	$n = $absorbed + $pending + $disputed.Count
	if ($n -eq 0) {
		if ($temp -gt 0) { return @{ Status = 'TEMPORARY'; Count = (Get-Plural $temp 'edit'); Note = $tempWhy } }
		return $null
	}
	$count = "$absorbed/$n edits"
	if ($temp -gt 0) { $count += ", $temp temporary" }
	if ($disputed.Count -gt 0) {
		$more = if ($disputed.Count -gt 1) { " (+$($disputed.Count - 1) more)" } else { '' }
		return @{ Status = 'DIVERGED'; Count = $count; Note = "$($disputed[0])$more" }
	}
	$st = if ($absorbed -eq $n) { 'TRANSFERRED' } elseif ($absorbed -eq 0) { 'NOT_TRANSFERRED' } else { 'PARTIAL' }
	$note = if ($markedDone -gt 0) { "$markedDone marked temporary" } else { '' }
	return @{ Status = $st; Count = $count; Note = $note; Marked = ($markedDone -gt 0) }
}

# &Перед/&После/&Вместо and form event interceptors: there is no marked original to compare with,
# so the interceptor's code lines are looked up, in order, in the body of the target method.
# Plumbing (ПродолжитьВызов and the return of its result) is not part of the fix and is skipped;
# the interceptor's parameters are renamed to the original's by position.
function Get-HeuristicTransfer($extMethod, $cfgMethod, [string]$prefix) {
	$proceedRe = '(?i)' + (Get-KwAlt 'Proceed') + '\s*\('
	$resultVars = @()
	$lines = @()
	foreach ($l in $extMethod.BodyLines) {
		$n = Get-CodeKey $l $prefix
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
	$ep = @($extMethod.ParamNames); $cp = @($cfgMethod.ParamNames)
	# One pass for all names: renaming one by one would rename again a name already renamed
	# when the two lists overlap (Источник, Отказ -> Отказ, Режим)
	$renames = @{}
	for ($i = 0; $i -lt [Math]::Min($ep.Count, $cp.Count); $i++) {
		if ($ep[$i] -ine $cp[$i]) { $renames[$ep[$i].ToLowerInvariant()] = $cp[$i].ToLowerInvariant() }
	}
	if ($renames.Count -gt 0) {
		$alt = (@($renames.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
		$re = New-Object System.Text.RegularExpressions.Regex ('(?<!\w)(?:' + $alt + ')(?!\w)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		$ev = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $renames[$m.Value.ToLowerInvariant()] }
		$lines = @($lines | ForEach-Object { $re.Replace($_, $ev) })
	}
	# Block closers and bare jumps match anywhere — they would only inflate the score
	$meaningful = @($lines | Where-Object { $_ -notmatch $script:trivialRe })
	if ($meaningful.Count -gt 0) { $lines = $meaningful }
	if ($lines.Count -eq 0) { return $null }
	$hay = Get-SigLines $cfgMethod.BodyLines $prefix
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
		Elements = @(); Removed = @(); Attributes = @(); Commands = @(); Parameters = @()
		Events = @(); FormProps = @(); Blocks = @(); Total = 0; MainIndex = $null
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
	foreach ($name in @($bi.Keys)) { if (-not $mi.Contains($name)) { $r.Removed += $name } }

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
			$r[$sec[2]] += @{ Name = $nm; Info = $info; Actions = $actions; Changed = $changed }
		}
	}

	# Whole blocks: conditional appearance, command interface
	foreach ($blk in @(@('ConditionalAppearance', 'd:Attributes/d:ConditionalAppearance'), @('CommandInterface', 'd:CommandInterface'))) {
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

	$r.Total = $r.Elements.Count + $r.Removed.Count + $r.Attributes.Count + $r.Commands.Count + $r.Parameters.Count + $r.Events.Count + $r.FormProps.Count + $r.Blocks.Count
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
	$cmdChanged = @($diff.Commands | Where-Object { $_.Changed }).Count
	$cmdAdded = $diff.Commands.Count - $cmdChanged
	if ($cmdAdded) { $parts += "+$(Get-Plural $cmdAdded 'command')" }
	if ($cmdChanged) { $parts += "~$(Get-Plural $cmdChanged 'command')" }
	if ($diff.Parameters.Count) { $parts += "+$(Get-Plural $diff.Parameters.Count 'parameter')" }
	if ($diff.Events.Count) { $parts += (Get-Plural $diff.Events.Count 'event') }
	if ($diff.FormProps.Count) { $parts += (Get-Plural $diff.FormProps.Count 'form property') -replace 'propertys$', 'properties' }
	foreach ($b in $diff.Blocks) { $parts += "~$($b.Name)" }
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

# Transfer check of a form diff against the form of the main configuration
# One property change of the extension against the configuration: 'ok' (the extension's value),
# 'pending' (still the BaseForm value) or 'differs' (changed in the configuration some other way).
function Get-PropTransfer($cpm, $p, [string]$prefix) {
	$cv = if ($cpm.Contains($p.Key)) { Get-CmpKey $cpm[$p.Key] $prefix } else { $null }
	$nv = Get-CmpKey $p.New $prefix
	$ov = Get-CmpKey $p.Old $prefix
	if ($cv -ieq $nv) { return 'ok' }
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

	foreach ($ch in $diff.Elements) {
		$rec = $ch.Rec
		$tag = Get-ElementTag $rec.Node
		$hit = Find-NameIn $cNames $rec.Name $prefix
		if ($ch.Kind -eq 'added') {
			$in = if ($rec.Parent) { " (in: $($rec.Parent))" } else { '' }
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$items += New-Item2 $st "+ $tag $($rec.Name)$in$(& $asText $hit $rec.Name)" '' $group
			continue
		}
		if ($ch.Props.Count -gt 0) {
			$keys = @($ch.Props | ForEach-Object { $_.Key })
			if (-not $hit) {
				$items += New-Item2 'NOT_TRANSFERRED' "~ $tag $($rec.Name): $($keys -join ', ') (element not in config)" '' $group
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
				$items += New-Item2 $st "~ $tag $($rec.Name): $($keys -join ', ')$cnt" '' $group
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
			$items += New-Item2 $st "> $tag $($rec.Name): $(Get-MoveText $ch)" '' $group
		}
	}

	# Interceptor of a handler: the extension's handler code looked up in the configuration's one
	$extMod = Read-BslLines $form.Module
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
					$it = & $checkHandler "command $($x.Name)[$($a.CallType)] -> $($a.Handler)" $a.Handler $cfgHandler "no action of $($x.Name) in config"
					if ($it) { $items += $it }
				}
				continue
			}
			$hit = Find-NameIn $cn $x.Name $prefix
			$st = if ($hit) { 'TRANSFERRED' } else { 'NOT_TRANSFERRED' }
			$items += New-Item2 $st "+ $($sec[2]) $($x.Name)$($x.Info)$(& $asText $hit $x.Name)" '' $group
		}
	}

	if ($diff.FormProps.Count -gt 0) {
		$cpm = Get-PropMap $cr -Root
		foreach ($p in $diff.FormProps) {
			$r = Get-PropTransfer $cpm $p $prefix
			$st = if ($r -eq 'ok') { 'TRANSFERRED' } elseif ($r -eq 'pending') { 'NOT_TRANSFERRED' } else { 'DIVERGED' }
			$why = if ($r -eq 'differs') { ' (config value differs)' } else { '' }
			$items += New-Item2 $st "~ form $(Get-PropChangeText $p)$why" '' $group
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
		if ($it) { $items += $it }
	}
	return $items
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

function Get-ModuleTransferItems([string]$bsl, [string]$extDir, [string]$prefix, $skipHandlers) {
	$items = @()
	$extLines = Read-BslLines $bsl
	if ($null -eq $extLines) { return $items }
	$rel = Get-RelPath $extDir $bsl
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
		if (-not $cfgM) {
			$why = if ($null -eq $cfgLines) { 'module not found in config' } else { 'method not found in config' }
			$it = New-Item2 'MISSING_IN_CONFIG' "$label ($why)" $loc
		} elseif (-not $extM) {
			$it = New-Item2 'DIVERGED' "$label (cannot parse the interceptor)" $loc
		} elseif ($ic.Type -eq 'ИзменениеИКонтроль') {
			$r = Get-ControlTransfer $extM $cfgM $prefix
			if ($r) {
				$note = if ($r.Note) { " ($($r.Note))" } else { '' }
				$it = New-Item2 $r.Status "$label — $($r.Count)$note" $loc
				if ($r.Marked -and $r.Status -eq 'TRANSFERRED') { $it.Marked = $true }
			}
		} else {
			$h = Get-HeuristicTransfer $extM $cfgM $prefix
			if ($h) { $it = New-Item2 (Get-HeuristicStatus $h) "$label (heuristic: $($h.Found)/$($h.Total) lines)" $loc }
		}
		if ($it) { $items += (Set-TempMark $it $mark $label) }
	}
	$cfgNames = if ($null -ne $cfgLines) { @(Get-ProcNames $cfgLines) } else { @() }
	foreach ($od in $mc.Own) {
		$pn = $od.Name
		$extM = Get-MethodSafe $extLines $pn
		if (-not $extM) { continue }
		$loc = "${rel}:$($extM.DeclIdx + 1)"
		$mark = Get-MethodTempMark $extLines $extM
		$hit = Find-NameIn $cfgNames $pn $prefix
		if (-not $hit) { $it = New-Item2 'NOT_TRANSFERRED' "method $pn" $loc }
		else {
			$as = if ($hit -ine $pn) { " (found as $hit)" } else { '' }
			$cfgM = Get-MethodSafe $cfgLines $hit
			$same = $cfgM -and (((Get-SigLines $extM.BodyLines $prefix) -join "`n") -ieq ((Get-SigLines $cfgM.BodyLines $prefix) -join "`n"))
			$it = if ($same) { New-Item2 'TRANSFERRED' "method $pn$as" $loc } else { New-Item2 'DIVERGED' "method $pn$as (body differs)" $loc }
		}
		$items += (Set-TempMark $it $mark "method $pn")
	}
	return $items
}

# Own sub-objects of a borrowed object (attributes, tabular sections, commands, forms, templates, …)
function Get-OwnChildItems($ctx, $cfgMd, [string]$prefix) {
	$items = @()
	if (-not $ctx.Md -or -not $ctx.Md.Children) { return $items }
	$mns = $ctx.Md.Ns
	$cfgKids = @()
	if ($cfgMd -and $cfgMd.Children) { foreach ($c in $cfgMd.Children.ChildNodes) { if ($c.NodeType -eq 'Element') { $cfgKids += $c } } }
	$check = {
		param($node, [string]$label, $cfgPool, [string]$path)
		$nm = Get-MdChildName $node $mns
		$cands = @($cfgPool | Where-Object { $_.LocalName -eq $node.LocalName })
		$hit = Find-NameIn @($cands | ForEach-Object { Get-MdChildName $_ $cfgMd.Ns }) $nm $prefix
		$full = if ($path) { "$path.$nm" } else { $nm }
		if (-not $hit) { return (New-Item2 'NOT_TRANSFERRED' "$label $full") }
		$as = if ($hit -ine $nm) { " (found as $hit)" } else { '' }
		if ($node.SelectSingleNode("md:Properties/md:Type", $mns)) {
			$cnode = @($cands | Where-Object { (Get-MdChildName $_ $cfgMd.Ns) -ieq $hit })[0]
			$a = Get-MdTypeKey $node $mns $prefix; $b = Get-MdTypeKey $cnode $cfgMd.Ns $prefix
			if ($a -ine $b) { return (New-Item2 'DIVERGED' "$label $full$as (type: $a vs $b in config)") }
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
			$items += New-Item2 $st "$(Get-KindWord $c.LocalName) $nm$as"
			continue
		}
		if (-not (Test-AdoptedNode $c $mns)) {
			$items += (& $check $c (Get-KindWord $c.LocalName) $cfgKids '')
			continue
		}
		# Borrowed tabular section: its own attributes
		$sub = $c.SelectSingleNode("md:ChildObjects", $mns)
		if (-not $sub) { continue }
		$tsName = Get-MdChildName $c $mns
		$cfgTs = @($cfgKids | Where-Object { $_.LocalName -eq $c.LocalName -and (Get-MdChildName $_ $cfgMd.Ns) -ieq $tsName })[0]
		$cfgSub = @()
		if ($cfgTs) { $cs = $cfgTs.SelectSingleNode("md:ChildObjects", $cfgMd.Ns); if ($cs) { foreach ($x in $cs.ChildNodes) { if ($x.NodeType -eq 'Element') { $cfgSub += $x } } } }
		foreach ($sc in $sub.ChildNodes) {
			if ($sc.NodeType -ne 'Element' -or (Test-AdoptedNode $sc $mns)) { continue }
			$items += (& $check $sc (Get-KindWord $sc.LocalName) $cfgSub $tsName)
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
	$rec.Items += @(Get-OwnChildItems $ctx $cfgMd $prefix)
	if ($obj.Type -eq 'Subsystem') { $rec.Items += @(Get-SubsystemContentItems $ctx.Md $cfgMd $prefix) }
	$rec.Items += $formItems
	# Section = the file the change lives in (a module line, the form's Form.xml, the object's own
	# XML for its sub-objects); the item then keeps only its line number
	$objRel = Get-RelPath $ext.Dir $ctx.File
	foreach ($it in $rec.Items) {
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

# Transfer of a borrowed subsystem's content: each object the extension adds must be in the content
# of the configuration's subsystem (own names compared with and without the prefix)
function Get-SubsystemContentItems($md, $cfgMd, [string]$prefix) {
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
		$items += New-Item2 $st "content $ref$as"
	}
	return $items
}

# Overview details, grouped by file like the transfer ones: modules with their interceptors and own
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

# Order of detail sections, the same in both modes: plain files first, then each form with its
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
function Get-TransferDetails($ext, $rec) {
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
	foreach ($s in $order) {
		$open = Test-Expanded $ext $rec.Id $s
		$shown = @($bySec[$s] | Where-Object { $open -or $_.Status -ne 'TRANSFERRED' -or $_.Marked })
		$view[$s] = @{ Shown = $shown; Hidden = ($bySec[$s].Count - $shown.Count) }
	}
	$emit = {
		param([string]$s)
		$v = $view[$s]
		$pad = if ($s) { '      ' } else { '    ' }
		if ($s) {
			if ($v.Shown.Count -eq 0) { $lines.Add("    ${s}: $($v.Hidden) transferred"); return }
			$lines.Add("    ${s}:")
		}
		foreach ($it in $v.Shown) {
			$loc = if ($it.Loc) { "  $($it.Loc)" } else { '' }
			$lines.Add("$pad$(Format-Status $it.Status)$($it.Text)$loc")
		}
		if ($v.Hidden -gt 0) { $lines.Add("$pad… $($v.Hidden) transferred") }
	}
	$lay = Get-SectionLayout $order
	foreach ($s in $lay.Plain) { & $emit $s; $folded += $view[$s].Hidden }
	foreach ($f in $lay.Forms) {
		$fd = $f.Dir; $secs = $f.Secs
		$hidden = 0; $shown = 0
		foreach ($s in $secs) { $hidden += $view[$s].Hidden; $shown += $view[$s].Shown.Count }
		$folded += $hidden
		if ($shown -eq 0) { $lines.Add("    ${fd}: $hidden transferred"); continue }
		foreach ($s in $secs) { & $emit $s }
	}
	return @{ Lines = $lines.ToArray(); Folded = $folded }
}

$statusOrder = @('TRANSFERRED', 'NOT_TRANSFERRED', 'PARTIAL', 'DIVERGED', 'MISSING_IN_CONFIG', 'TEMPORARY')
function Format-Status([string]$st) { return ("[$st]").PadRight(21) }

$exts = @()
$matchedIds = @{}
foreach ($dir in $extDirs) {
	$cp = Read-ConfigurationProps $dir
	$ext = @{ Dir = $dir; Name = $cp.Name; Prefix = $cp.Prefix; Purpose = $cp.Purpose; Objects = @(); Roles = 0; Borrowed = 0; Own = 0; Matched = 0 }
	if ($cp.ChildObjects) {
		foreach ($child in $cp.ChildObjects.ChildNodes) {
			if ($child.NodeType -ne 'Element' -or $child.LocalName -eq 'Language') { continue }
			$obj = @{ Type = $child.LocalName; Name = $child.InnerText.Trim() }
			$id = "$($obj.Type).$($obj.Name)"
			if (-not (Test-NameMatch $id)) { continue }
			$matchedIds[$id.ToLower()] = $true
			$ext.Matched++
			if ($Mode -eq 'transfer') {
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
				# Asked for by name or opened with -Expand: details even when all is transferred
				$rec.Asked = ($nameFilter.Count -gt 0) -or (Test-Expanded $ext $rec.Id '')
				$ext.Objects += $rec
			} else {
				$rec = Get-OverviewObject $ext $obj
				if ($rec.Kind -eq 'borrowed') { $ext.Borrowed++ } elseif ($rec.Kind -eq 'own') { $ext.Own++ }
				# A borrowed object without changes is folded into the summary unless asked for
				# (-Expand * lists them in the summary instead)
				$rec.Asked = ($nameFilter.Count -gt 0) -or (@($expandList | Where-Object { $_ -ieq $rec.Id }).Count -gt 0)
				$ext.Objects += $rec
			}
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
		if ($Mode -eq 'overview' -and $o.Unchanged -and -not $o.Asked) { continue }
		$fullCount += 1
		if ($Mode -eq 'overview' -or -not $o.Complete -or $o.Asked) { $fullCount += $o.Details.Count }
	}
}
$showDetails = ($nameFilter.Count -gt 0) -or ($fullCount -le $DetailBudget)

# --- Body ---
$body = @()
$anyFolded = $false
foreach ($ext in $exts) {
	$target = if ($Mode -eq 'transfer') { " -> $($cfgInfo.Name)" } else { '' }
	$modeName = if ($Mode -eq 'transfer') { 'check-transfer' } else { $Mode }
	$body += "=== cfe-diff ${modeName}: $($ext.Name) ($($ext.Purpose))$target ==="
	if ($ext.Prefix) { $body += "NamePrefix: $($ext.Prefix)" }
	$body += ""
	$shown = 0
	foreach ($o in $ext.Objects) {
		if ($Mode -eq 'transfer' -and $o.Complete -and -not $showDetails) { continue }
		if ($Mode -eq 'overview' -and $o.Unchanged -and -not $o.Asked) { continue }
		$body += $o.Summary
		$shown++
		if ($showDetails -and ($Mode -eq 'overview' -or -not $o.Complete -or $o.Asked)) {
			$body += $o.Details
			if ($o.Folded) { $anyFolded = $true }
		}
	}
	if ($shown -eq 0) {
		if ($Mode -eq 'overview' -and $ext.Objects.Count -gt 0) { $body += "No changes in borrowed objects." }
		elseif ($Mode -eq 'overview') { $body += "No objects (besides Language) in extension." }
		elseif ($ext.Objects.Count -gt 0) { $body += "All changes transferred." }
		else { $body += "No changes to transfer." }
	}
	$body += ""
}

# --- Footer: always printed, after the body (output is often read from its tail) ---
$footer = @()
$unchFolded = $false
$failed = $false
$extDone = 0; $extLeft = 0; $leftTotal = 0
foreach ($ext in $exts) {
	if ($Mode -eq 'transfer') {
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
		foreach ($s in $statusOrder[1..5]) { if ($cnt[$s]) { $parts += "$($cnt[$s]) $($s.ToLower().Replace('_', ' '))" } }
		$footer += "=== Summary $($ext.Name): $(Get-Plural $all.Count 'change') — $($parts -join ', ')$rolesNote ==="
		$left = $all.Count - $cnt['TRANSFERRED'] - $cnt['TEMPORARY']
		if ($left -gt 0) {
			$failed = $true; $extLeft++; $leftTotal += $left
			$ids = @($ext.Objects | Where-Object { -not $_.Complete } | ForEach-Object { $_.Id })
			$shown = @($ids | Select-Object -First 10)
			$more = if ($ids.Count -gt 10) { ", …+$($ids.Count - 10)" } else { '' }
			$footer += "Remaining: $($shown -join ', ')$more"
		} else { $extDone++ }
	} else {
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
}
if ($Mode -eq 'transfer' -and $exts.Count -gt 1) {
	$tail = if ($extLeft) { ", $extLeft with $leftTotal remaining" } else { '' }
	$footer += "=== Total: $($exts.Count) extensions — $extDone complete$tail ==="
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
if ($anyFolded) {
	$footer += "Hint: use -Expand <Type.Name> or a section path to list transferred changes, -Expand * for all"
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

if ($Mode -eq 'transfer' -and $failed) { exit 1 }
exit 0
