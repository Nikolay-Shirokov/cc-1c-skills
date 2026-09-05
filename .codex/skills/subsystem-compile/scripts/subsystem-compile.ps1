# subsystem-compile v1.32 — Create 1C subsystem from JSON definition
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[string]$DefinitionFile,
	[string]$Value,
	[Parameter(Mandatory)][string]$OutputDir,
	[string]$Parent,
	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"

# --- Разбор пользовательского JSON ---
# Одна строка в stderr вместо дампа исключения ConvertFrom-Json (issue #80): агент по стектрейсу
# идёт чинить скрипт, а не свой вызов. $source — файл или параметр. $expected заполняем только
# для полиморфного входа: у файла подсказка была бы наполнителем. -Inline печатает ещё и то,
# что доехало: у файла такого вопроса нет — путь назван, позицию дал парсер, файл на диске.
# Возврат через -NoEnumerate: без него одноэлементный
# JSON-массив разворачивался бы в скаляр вторым анруллингом.
function ConvertFrom-JsonInput([string]$text, [string]$source, [string]$expected, [switch]$Inline) {
	try {
		# PS 5.1 на пустой строке отдаёт $null, а не ошибку — навык уходил дальше с $null,
		# тогда как py-порт падал. Проверяем сами, чтобы порты вели себя одинаково.
		if ([string]::IsNullOrWhiteSpace($text)) { throw 'input is empty' }
		$parsed = $text | ConvertFrom-Json
	} catch {
		$what = if ($expected) { "$source expects $expected" } else { "Invalid JSON in $source" }
		if ($Inline) {
			$got = ($text -replace '\s+', ' ').Trim()
			$label = 'got'
			if (-not $got) { $got = '(empty)' }
			elseif ($got.Length -gt 60) { $label = 'got (first 60 chars)'; $got = $got.Substring(0, 60) }
			$what = "${what}, ${label}: ${got}"
		}
		[Console]::Error.WriteLine("[ERROR] ${what} ($($_.Exception.Message))")
		exit 1
	}
	Write-Output -NoEnumerate $parsed
}

# --- Чтение входного JSON-файла ---
# Кодировку берём из BOM — это объявление самого файла, а не догадка. Без BOM ждём строгий UTF-8:
# Get-Content -Encoding UTF8 на файле в cp1251 тихо меняет кириллицу на U+FFFD, JSON после этого
# разбирается успешно, и в конфигурацию уезжает имя из «замен». Кодовую страницу не подбираем:
# угаданное имя уйдёт в метаданные так же молча.
function Read-JsonInputFile([string]$path) {
	# Проверка здесь, а не по навыкам: часть навыков проверяла путь сама, часть — нет, и один и тот
	# же промах давал то внятную строку, то дамп MethodInvocationException. Навыки со своей
	# проверкой срабатывают раньше и сохраняют свой текст.
	if (-not (Test-Path -LiteralPath $path)) {
		[Console]::Error.WriteLine("[ERROR] File not found: $path")
		exit 1
	}
	if (Test-Path -LiteralPath $path -PathType Container) {
		[Console]::Error.WriteLine("[ERROR] Expected a JSON file, got a directory: $path")
		exit 1
	}
	$bytes = [System.IO.File]::ReadAllBytes($path)
	if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
		return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
		return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
		return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
	}
	try {
		return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
	} catch {
		$detail = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
		[Console]::Error.WriteLine("[ERROR] ${path} is not valid UTF-8: ${detail} - save the file as UTF-8, or add a BOM if it is UTF-16")
		exit 1
	}
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load JSON ---
if ($DefinitionFile -and $Value) {
	Write-Error "Cannot use both -DefinitionFile and -Value"
	exit 1
}
if (-not $DefinitionFile -and -not $Value) {
	Write-Error "Either -DefinitionFile or -Value is required"
	exit 1
}

if ($DefinitionFile) {
	if (-not [System.IO.Path]::IsPathRooted($DefinitionFile)) {
		$DefinitionFile = Join-Path (Get-Location).Path $DefinitionFile
	}
	if (-not (Test-Path $DefinitionFile)) {
		Write-Error "Definition file not found: $DefinitionFile"
		exit 1
	}
	$json = Read-JsonInputFile $DefinitionFile
	$jsonSource = $DefinitionFile
	$jsonInline = $false
} else {
	$json = $Value
	$jsonSource = "-Value"
	$jsonInline = $true
}

$def = ConvertFrom-JsonInput $json $jsonSource -Inline:$jsonInline

if (-not $def.name) {
	Write-Error "JSON must have 'name' field"
	exit 1
}

$objName = "$($def.name)"

# Resolve OutputDir
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
	$OutputDir = Join-Path (Get-Location).Path $OutputDir
}

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

Assert-EditAllowed $OutputDir 'editable'

# --- 2. XML helpers ---
$script:xml = New-Object System.Text.StringBuilder 8192

function X([string]$text) {
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	param([string]$s)
	# Эскейп ТЕКСТА элемента: только & < > — кавычку и апостроф платформа держит сырыми.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function Split-CamelCase([string]$name) {
	if (-not $name) { return $name }
	$result = [regex]::Replace($name, '([a-z\u0430-\u044F\u0451])([A-Z\u0410-\u042F\u0401])', '$1 $2')
	if ($result.Length -gt 1) {
		$result = $result.Substring(0,1) + $result.Substring(1).ToLower()
	}
	return $result
}

function Emit-MLText([string]$indent, [string]$tag, [string]$text) {
	if (-not $text) {
		X "$indent<$tag/>"
		return
	}
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-XmlText $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

function Write-ChildSubsystemStub([string]$childPath, [string]$childName, [string]$formatVersion, [System.Text.Encoding]$utf8Bom) {
	$childUuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder 2048
	[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
	[void]$sb.AppendLine("<MetaDataObject $($script:xmlnsDecl) version=`"$formatVersion`">")
	[void]$sb.AppendLine("`t<Subsystem uuid=`"$childUuid`">")
	[void]$sb.AppendLine("`t`t<Properties>")
	[void]$sb.AppendLine("`t`t`t<Name>$(Esc-XmlText $childName)</Name>")
	[void]$sb.AppendLine("`t`t`t<Synonym/>")
	[void]$sb.AppendLine("`t`t`t<Comment/>")
	[void]$sb.AppendLine("`t`t`t<IncludeHelpInContents>true</IncludeHelpInContents>")
	[void]$sb.AppendLine("`t`t`t<IncludeInCommandInterface>true</IncludeInCommandInterface>")
	[void]$sb.AppendLine("`t`t`t<UseOneCommand>false</UseOneCommand>")
	[void]$sb.AppendLine("`t`t`t<Explanation/>")
	[void]$sb.AppendLine("`t`t`t<Picture/>")
	[void]$sb.AppendLine("`t`t`t<Content/>")
	[void]$sb.AppendLine("`t`t</Properties>")
	[void]$sb.AppendLine("`t`t<ChildObjects/>")
	[void]$sb.AppendLine("`t</Subsystem>")
	[void]$sb.AppendLine('</MetaDataObject>')
	[System.IO.File]::WriteAllText($childPath, $sb.ToString().TrimEnd("`r", "`n"), $utf8Bom)
}

# --- 3. Content type normalization (plural→singular, Russian→English) ---
$script:contentTypeMap = @{
	# Plural English → Singular
	"Catalogs"                     = "Catalog"
	"Documents"                    = "Document"
	"Enums"                        = "Enum"
	"Constants"                    = "Constant"
	"Reports"                      = "Report"
	"DataProcessors"               = "DataProcessor"
	"InformationRegisters"         = "InformationRegister"
	"AccumulationRegisters"        = "AccumulationRegister"
	"AccountingRegisters"          = "AccountingRegister"
	"CalculationRegisters"         = "CalculationRegister"
	"ChartsOfAccounts"             = "ChartOfAccounts"
	"ChartsOfCharacteristicTypes"  = "ChartOfCharacteristicTypes"
	"ChartsOfCalculationTypes"     = "ChartOfCalculationTypes"
	"BusinessProcesses"            = "BusinessProcess"
	"Tasks"                        = "Task"
	"ExchangePlans"                = "ExchangePlan"
	"DocumentJournals"             = "DocumentJournal"
	"CommonModules"                = "CommonModule"
	"CommonCommands"               = "CommonCommand"
	"CommonForms"                  = "CommonForm"
	"CommonPictures"               = "CommonPicture"
	"CommonTemplates"              = "CommonTemplate"
	"CommonAttributes"             = "CommonAttribute"
	"CommandGroups"                = "CommandGroup"
	"Roles"                        = "Role"
	"SessionParameters"            = "SessionParameter"
	"FilterCriteria"               = "FilterCriterion"
	"XDTOPackages"                 = "XDTOPackage"
	"WebServices"                  = "WebService"
	"HTTPServices"                 = "HTTPService"
	"WSReferences"                 = "WSReference"
	"EventSubscriptions"           = "EventSubscription"
	"ScheduledJobs"                = "ScheduledJob"
	"SettingsStorages"             = "SettingsStorage"
	"FunctionalOptions"            = "FunctionalOption"
	"FunctionalOptionsParameters"  = "FunctionalOptionsParameter"
	"DefinedTypes"                 = "DefinedType"
	"DocumentNumerators"           = "DocumentNumerator"
	"Sequences"                    = "Sequence"
	"Subsystems"                   = "Subsystem"
	"StyleItems"                   = "StyleItem"
	"IntegrationServices"          = "IntegrationService"
	"Bots"                         = "Bot"
	"Bot"                          = "Bot"
	# Russian singular → English
	"Справочник"                   = "Catalog"
	"Каталог"                      = "Catalog"
	"Документ"                     = "Document"
	"Перечисление"                 = "Enum"
	"Константа"                    = "Constant"
	"Отчёт"                        = "Report"
	"Отчет"                        = "Report"
	"Обработка"                    = "DataProcessor"
	"РегистрСведений"              = "InformationRegister"
	"РегистрНакопления"            = "AccumulationRegister"
	"РегистрБухгалтерии"           = "AccountingRegister"
	"РегистрРасчёта"               = "CalculationRegister"
	"РегистрРасчета"               = "CalculationRegister"
	"ПланСчетов"                   = "ChartOfAccounts"
	"ПланВидовХарактеристик"       = "ChartOfCharacteristicTypes"
	"ПланВидовРасчёта"             = "ChartOfCalculationTypes"
	"ПланВидовРасчета"             = "ChartOfCalculationTypes"
	"БизнесПроцесс"                = "BusinessProcess"
	"Задача"                       = "Task"
	"ПланОбмена"                   = "ExchangePlan"
	"ЖурналДокументов"             = "DocumentJournal"
	"ОбщийМодуль"                  = "CommonModule"
	"ОбщаяКоманда"                 = "CommonCommand"
	"ОбщаяФорма"                   = "CommonForm"
	"ОбщаяКартинка"                = "CommonPicture"
	"ОбщийМакет"                   = "CommonTemplate"
	"ОбщийРеквизит"                = "CommonAttribute"
	"ГруппаКоманд"                 = "CommandGroup"
	"Роль"                         = "Role"
	"ПараметрСеанса"               = "SessionParameter"
	"КритерийОтбора"               = "FilterCriterion"
	"ПакетXDTO"                    = "XDTOPackage"
	"ВебСервис"                    = "WebService"
	"HTTPСервис"                   = "HTTPService"
	"WSСсылка"                     = "WSReference"
	"ПодпискаНаСобытие"            = "EventSubscription"
	"РегламентноеЗадание"          = "ScheduledJob"
	"ХранилищеНастроек"            = "SettingsStorage"
	"ФункциональнаяОпция"          = "FunctionalOption"
	"ПараметрФункциональныхОпций"  = "FunctionalOptionsParameter"
	"ОпределяемыйТип"              = "DefinedType"
	"НумераторДокументов"          = "DocumentNumerator"
	"Последовательность"           = "Sequence"
	"Подсистема"                   = "Subsystem"
	"ЭлементСтиля"                 = "StyleItem"
	"СервисИнтеграции"             = "IntegrationService"
	# Russian plural → English
	"Справочники"                  = "Catalog"
	"Документы"                    = "Document"
	"Перечисления"                 = "Enum"
	"Константы"                    = "Constant"
	"Отчёты"                       = "Report"
	"Отчеты"                       = "Report"
	"Обработки"                    = "DataProcessor"
	"РегистрыСведений"             = "InformationRegister"
	"РегистрыНакопления"           = "AccumulationRegister"
	"РегистрыБухгалтерии"          = "AccountingRegister"
	"РегистрыРасчёта"              = "CalculationRegister"
	"РегистрыРасчета"              = "CalculationRegister"
	"ПланыСчетов"                  = "ChartOfAccounts"
	"ПланыВидовХарактеристик"      = "ChartOfCharacteristicTypes"
	"ПланыВидовРасчёта"            = "ChartOfCalculationTypes"
	"ПланыВидовРасчета"            = "ChartOfCalculationTypes"
	"БизнесПроцессы"               = "BusinessProcess"
	"Задачи"                       = "Task"
	"ПланыОбмена"                  = "ExchangePlan"
	"ЖурналыДокументов"            = "DocumentJournal"
	"ОбщиеМодули"                  = "CommonModule"
	"ОбщиеКоманды"                 = "CommonCommand"
	"ОбщиеФормы"                   = "CommonForm"
	"ОбщиеКартинки"                = "CommonPicture"
	"ОбщиеМакеты"                  = "CommonTemplate"
	"ОбщиеРеквизиты"               = "CommonAttribute"
	"ГруппыКоманд"                 = "CommandGroup"
	"Роли"                         = "Role"
	"ПараметрыСеанса"              = "SessionParameter"
	"КритерииОтбора"               = "FilterCriterion"
	"ПакетыXDTO"                   = "XDTOPackage"
	"ВебСервисы"                   = "WebService"
	"HTTPСервисы"                  = "HTTPService"
	"WSСсылки"                     = "WSReference"
	"ПодпискиНаСобытия"            = "EventSubscription"
	"РегламентныеЗадания"          = "ScheduledJob"
	"ХранилищаНастроек"            = "SettingsStorage"
	"ФункциональныеОпции"          = "FunctionalOption"
	"ОпределяемыеТипы"             = "DefinedType"
	"Подсистемы"                   = "Subsystem"
	"ЭлементыСтиля"                = "StyleItem"
	"СервисыИнтеграции"            = "IntegrationService"
}

function Normalize-ContentRef([string]$ref) {
	if (-not $ref -or -not $ref.Contains('.')) { return $ref }
	$dotIdx = $ref.IndexOf('.')
	$typePart = $ref.Substring(0, $dotIdx)
	$namePart = $ref.Substring($dotIdx + 1)
	if ($script:contentTypeMap.ContainsKey($typePart)) {
		$typePart = $script:contentTypeMap[$typePart]
	}
	return "$typePart.$namePart"
}

# --- 4. Resolve defaults ---
$synonym = if ($def.synonym) { "$($def.synonym)" } else { Split-CamelCase $objName }
$comment = if ($def.comment) { "$($def.comment)" } else { "" }
$includeHelpInContents = "true"
$includeInCI = if ($null -ne $def.includeInCommandInterface) { "$($def.includeInCommandInterface)".ToLower() } else { "true" }
$useOneCommand = if ($null -ne $def.useOneCommand) { "$($def.useOneCommand)".ToLower() } else { "false" }
$explanation = if ($def.explanation) { "$($def.explanation)" } else { "" }
$picture = if ($def.picture) { "$($def.picture)" } else { "" }

# Synonym: accept "objects" as alias for "content"
if (-not $def.content -and $def.objects) { $def | Add-Member -NotePropertyName content -NotePropertyValue $def.objects }

$contentItems = @()
$normalizedCount = 0
if ($def.content) {
	foreach ($c in $def.content) {
		$raw = "$c"
		$normalized = Normalize-ContentRef $raw
		if ($normalized -ne $raw) {
			Write-Host "[NORM] Content: $raw -> $normalized"
			$normalizedCount++
		}
		$contentItems += $normalized
	}
}
if ($normalizedCount -gt 0) {
	Write-Host "[INFO] Normalized $normalizedCount content reference(s) to singular English form"
}

$children = @()
if ($def.children) {
	foreach ($ch in $def.children) { $children += "$ch" }
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

$formatVersion = Detect-FormatVersion $OutputDir

# Объявления пространств имён — одной переменной: места эмиссии её только интерполируют.
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
if ((Get-FormatRank $formatVersion) -ge 221) {
	$script:xmlnsDecl = $script:xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}

# --- 4. Build XML ---
$uuid = New-Guid-String
$indent = "`t`t`t"

X '<?xml version="1.0" encoding="UTF-8"?>'
X "<MetaDataObject $($script:xmlnsDecl) version=`"$formatVersion`">"
X "`t<Subsystem uuid=`"$uuid`">"
X "`t`t<Properties>"

# Name
X "`t`t`t<Name>$(Esc-XmlText $objName)</Name>"

# Synonym
Emit-MLText "`t`t`t" "Synonym" $synonym

# Comment
if ($comment) {
	X "`t`t`t<Comment>$(Esc-XmlText $comment)</Comment>"
} else {
	X "`t`t`t<Comment/>"
}

# Boolean properties
X "`t`t`t<IncludeHelpInContents>$includeHelpInContents</IncludeHelpInContents>"
X "`t`t`t<IncludeInCommandInterface>$includeInCI</IncludeInCommandInterface>"
X "`t`t`t<UseOneCommand>$useOneCommand</UseOneCommand>"

# Explanation
Emit-MLText "`t`t`t" "Explanation" $explanation

# Picture
if ($picture) {
	X "`t`t`t<Picture>"
	X "`t`t`t`t<xr:Ref>$picture</xr:Ref>"
	X "`t`t`t`t<xr:LoadTransparent>false</xr:LoadTransparent>"
	X "`t`t`t</Picture>"
} else {
	X "`t`t`t<Picture/>"
}

# Content
if ($contentItems.Count -gt 0) {
	X "`t`t`t<Content>"
	foreach ($item in $contentItems) {
		X "`t`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">$(Esc-XmlText $item)</xr:Item>"
	}
	X "`t`t`t</Content>"
} else {
	X "`t`t`t<Content/>"
}

X "`t`t</Properties>"

# ChildObjects
if ($children.Count -gt 0) {
	X "`t`t<ChildObjects>"
	foreach ($ch in $children) {
		X "`t`t`t<Subsystem>$(Esc-XmlText $ch)</Subsystem>"
	}
	X "`t`t</ChildObjects>"
} else {
	X "`t`t<ChildObjects/>"
}

X "`t</Subsystem>"
X '</MetaDataObject>'

# --- 5. Write files ---

# Determine target directory
if ($Parent) {
	# Nested subsystem
	if (-not [System.IO.Path]::IsPathRooted($Parent)) {
		$Parent = Join-Path (Get-Location).Path $Parent
	}
	if (-not (Test-Path $Parent)) {
		Write-Error "Parent subsystem not found: $Parent"
		exit 1
	}
	$parentDir = [System.IO.Path]::GetDirectoryName($Parent)
	$parentBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Parent)
	$subsDir = Join-Path (Join-Path $parentDir $parentBaseName) "Subsystems"
} else {
	# Top-level subsystem
	$subsDir = Join-Path $OutputDir "Subsystems"
}

if (-not (Test-Path $subsDir)) {
	New-Item -ItemType Directory -Path $subsDir -Force | Out-Null
}

$targetXml = Join-Path $subsDir "$objName.xml"

# Write XML
$xmlContent = $script:xml.ToString()
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($targetXml, $xmlContent.TrimEnd("`r", "`n"), $utf8Bom)
Write-Host "[OK] Created: $targetXml"

# Create subdirectory and stub files for children if they exist
if ($children.Count -gt 0) {
	$childSubsDir = Join-Path (Join-Path $subsDir $objName) "Subsystems"
	if (-not (Test-Path $childSubsDir)) {
		New-Item -ItemType Directory -Path $childSubsDir -Force | Out-Null
		Write-Host "[OK] Created directory: $childSubsDir"
	}
	$seen = @{}
	foreach ($ch in $children) {
		if ($seen.ContainsKey($ch)) { continue }
		$seen[$ch] = $true
		$childXml = Join-Path $childSubsDir "$ch.xml"
		if (-not (Test-Path $childXml)) {
			Write-ChildSubsystemStub $childXml $ch $formatVersion $utf8Bom
			Write-Host "[OK] Created stub: $childXml"
		}
	}
}

# --- 6. Register in parent ---

# Регистрация объекта в <ChildObjects> родительского XML. Вариант семьи: отступ берётся
# из самого документа, а запись дописывается в конец блока. Отличие от эталона
# (meta-compile) осознанное: родителем бывает вложенный Subsystem.xml произвольной
# глубины, где фиксированные три табуляции неверны, а группировать записи по типу
# внутри подсистемы нечего — потомок там всегда один и тот же.
# Реестр семьи: tests/skills/check-inline-drift.mjs.
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

	$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	$childObjects = $doc.SelectSingleNode("//md:$ParentTag/md:ChildObjects", $ns)
	if (-not $childObjects) { return "no-childobj" }

	foreach ($child in $childObjects.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $ChildTag -and $child.InnerText -eq $ChildName) {
			return "already"
		}
	}

	# Правка по сырому тексту, зеркально py-порту: сериализация DOM переписала бы файл целиком
	# (регистр encoding, `<a />` вместо `<a/>`), а текстовая вставка хранит его байт-в-байт.
	# Правим чужой файл, значит наследуем его стиль (#44/#46/#47). DOM выше — только на чтение.
	$rawText = [System.IO.File]::ReadAllText($ParentXmlPath, (New-Object System.Text.UTF8Encoding($false)))
	$eol = if ($rawText.Contains("`r`n")) { "`r`n" } else { "`n" }
	$entry = "<$ChildTag>$(Esc-XmlText $ChildName)</$ChildTag>"

	$empty = [regex]::Match($rawText, '<ChildObjects\s*/>')
	if ($empty.Success) {
		$replacement = "<ChildObjects>$eol`t`t`t$entry$eol`t`t</ChildObjects>"
		$rawText = $rawText.Substring(0, $empty.Index) + $replacement + $rawText.Substring($empty.Index + $empty.Length)
	} else {
		# В корне подсистема встаёт перед первой группой вида старше по $childObjectTypes:
		# так она попадает и в канонический порядок видов, и в конец своей группы, если та уже
		# есть. Дописать в конец блока нельзя вдвойне: платформа переставит новую группу при
		# первой же выгрузке, а существующую подсистема покинула бы, уехав за виды ниже.
		# Во вложенном Subsystem.xml порядок видов неприменим — потомок там всегда один.
		$anchor = $null
		if ($ParentTag -eq "Configuration") {
			$ownIdx = $childObjectTypes.IndexOf($ChildTag)
			if ($ownIdx -ge 0) {
				$typeRx = [regex]"(?m)^([ \t]*)<(\w+)>[^<]*</\2>"
				$tm = $typeRx.Match($rawText)
				while ($tm.Success) {
					$otherIdx = $childObjectTypes.IndexOf($tm.Groups[2].Value)
					if ($otherIdx -gt $ownIdx) { $anchor = $tm; break }
					$tm = $tm.NextMatch()
				}
			}
		}
		if ($anchor) {
			$rawText = $rawText.Substring(0, $anchor.Index) + $anchor.Groups[1].Value + $entry + $eol + $rawText.Substring($anchor.Index)
		} else {
			# Отступ вставки берём у закрывающего тега +1 уровень: подстановка по голому
			# '</ChildObjects>' удваивала бы уже присутствующий отступ строки.
			$cm = [regex]::Match($rawText, '([ 	]*)</ChildObjects>')
			if (-not $cm.Success) { return "no-childobj" }
			$rawText = $rawText.Substring(0, $cm.Index) + $cm.Groups[1].Value + "`t" + $entry + $eol + $cm.Groups[1].Value + "</ChildObjects>" + $rawText.Substring($cm.Index + $cm.Length)
		}
	}

	[System.IO.File]::WriteAllText($ParentXmlPath, $rawText, (New-Object System.Text.UTF8Encoding($true)))
	return "added"
}

$parentXmlPath = $null
$parentTag = "Configuration"
if ($Parent) {
	$parentXmlPath = $Parent
	$parentTag = "Subsystem"
} else {
	$configXml = Join-Path $OutputDir "Configuration.xml"
	if (Test-Path $configXml) {
		$parentXmlPath = $configXml
	}
}

if ($parentXmlPath) {
	switch (Register-InChildObjects $parentXmlPath $parentTag "Subsystem" $objName) {
		"added"       { Write-Host "[OK] Registered in: $parentXmlPath" }
		"already"     { Write-Host "[SKIP] Already registered in: $parentXmlPath" }
		"no-childobj" { Write-Host "[WARN] ChildObjects not found in: $parentXmlPath" }
		"no-config"   { Write-Host "[INFO] No parent XML to register in" }
	}
} else {
	Write-Host "[INFO] No parent XML to register in"
}

# --- 7. Auto-validate ---
if (-not $NoValidate) {
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\subsystem-validate") "scripts\subsystem-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running subsystem-validate ---"
		& powershell.exe -NoProfile -File $validateScript -SubsystemPath $targetXml
	}
}

Write-Host ""
Write-Host "=== subsystem-compile summary ==="
Write-Host "  Name:     $objName"
Write-Host "  UUID:     $uuid"
Write-Host "  Content:  $($contentItems.Count) objects"
Write-Host "  Children: $($children.Count)"
Write-Host "  File:     $targetXml"
exit 0
