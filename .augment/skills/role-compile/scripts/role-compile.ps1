# role-compile v1.35 — Compile 1C role from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputDir
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

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$json = Read-JsonInputFile $JsonPath
$def = ConvertFrom-JsonInput $json $JsonPath

if (-not $def.name) {
	Write-Error "JSON must have 'name' field (role programmatic name)"
	exit 1
}

$roleName = "$($def.name)"
$synonym = if ($def.synonym) { "$($def.synonym)" } else { $roleName }
$comment = if ($def.comment) { "$($def.comment)" } else { "" }

# --- 2. XML helpers ---

$script:xmlBuf = $null

function X {
	param([string]$text)
	$script:xmlBuf.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента: только & < > . Кавычки в тексте платформа НЕ экранирует —
	# пишет литерально (проверено: 92142 сырых кавычки на корпус, ни одной &quot;). &quot; платформа
	# принимает, но при выгрузке нормализует обратно в кавычку → лишний шум в роундтрипе.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# --- 3. Russian synonyms → canonical English names ---

$script:typeAliases = @{
	"Справочник" = "Catalog"
	"Документ" = "Document"
	"РегистрСведений" = "InformationRegister"
	"РегистрНакопления" = "AccumulationRegister"
	"РегистрБухгалтерии" = "AccountingRegister"
	"РегистрРасчета" = "CalculationRegister"
	"РегистрРасчёта" = "CalculationRegister"
	"Константа" = "Constant"
	"ПланСчетов" = "ChartOfAccounts"
	"ПланВидовХарактеристик" = "ChartOfCharacteristicTypes"
	"ПланВидовРасчета" = "ChartOfCalculationTypes"
	"ПланВидовРасчёта" = "ChartOfCalculationTypes"
	"ПланОбмена" = "ExchangePlan"
	"БизнесПроцесс" = "BusinessProcess"
	"Задача" = "Task"
	"Обработка" = "DataProcessor"
	"Отчет" = "Report"
	"Отчёт" = "Report"
	"ОбщаяФорма" = "CommonForm"
	"ОбщаяКоманда" = "CommonCommand"
	"Подсистема" = "Subsystem"
	"КритерийОтбора" = "FilterCriterion"
	"ЖурналДокументов" = "DocumentJournal"
	"Последовательность" = "Sequence"
	"ВебСервис" = "WebService"
	"HTTPСервис" = "HTTPService"
	"СервисИнтеграции" = "IntegrationService"
	"ПараметрСеанса" = "SessionParameter"
	"ОбщийРеквизит" = "CommonAttribute"
	"Конфигурация" = "Configuration"
	"ВнешнийИсточникДанных" = "ExternalDataSource"
	# Типы без прав в ролях: алиасы нужны не ради генерации, а ради отказа по делу —
	# иначе на русскую запись навык ответит «неизвестный тип 'ОбщийМодуль'».
	"Перечисление" = "Enum"
	"ОбщийМодуль" = "CommonModule"
	"ОпределяемыйТип" = "DefinedType"
	"ОбщаяКартинка" = "CommonPicture"
	"ОбщийМакет" = "CommonTemplate"
	"Язык" = "Language"
	"ФункциональнаяОпция" = "FunctionalOption"
	"ПараметрФункциональныхОпций" = "FunctionalOptionsParameter"
	"ПодпискаНаСобытие" = "EventSubscription"
	"РегламентноеЗадание" = "ScheduledJob"
	"ЭлементСтиля" = "StyleItem"
	"ХранилищеНастроек" = "SettingsStorage"
	"ПакетXDTO" = "XDTOPackage"
	"WSСсылка" = "WSReference"
	"Нумератор" = "DocumentNumerator"
	# Nested
	"Реквизит" = "Attribute"
	"СтандартныйРеквизит" = "StandardAttribute"
	"ТабличнаяЧасть" = "TabularSection"
	"Измерение" = "Dimension"
	"Ресурс" = "Resource"
	"Команда" = "Command"
	"РеквизитАдресации" = "AddressingAttribute"
}

$script:rightAliases = @{
	"Чтение" = "Read"
	"Добавление" = "Insert"
	"Изменение" = "Update"
	"Удаление" = "Delete"
	"Просмотр" = "View"
	"Редактирование" = "Edit"
	"ВводПоСтроке" = "InputByString"
	"Проведение" = "Posting"
	"ОтменаПроведения" = "UndoPosting"
	"ИнтерактивноеДобавление" = "InteractiveInsert"
	"ИнтерактивнаяПометкаУдаления" = "InteractiveSetDeletionMark"
	"ИнтерактивноеСнятиеПометкиУдаления" = "InteractiveClearDeletionMark"
	"ИнтерактивноеУдаление" = "InteractiveDelete"
	"ИнтерактивноеУдалениеПомеченных" = "InteractiveDeleteMarked"
	"ИнтерактивноеПроведение" = "InteractivePosting"
	"ИнтерактивноеПроведениеНеоперативное" = "InteractivePostingRegular"
	"ИнтерактивнаяОтменаПроведения" = "InteractiveUndoPosting"
	"ИнтерактивноеИзменениеПроведенных" = "InteractiveChangeOfPosted"
	"Использование" = "Use"
	"Получение" = "Get"
	"Установка" = "Set"
	"Старт" = "Start"
	"ИнтерактивныйСтарт" = "InteractiveStart"
	"ИнтерактивнаяАктивация" = "InteractiveActivate"
	"Выполнение" = "Execute"
	"ИнтерактивноеВыполнение" = "InteractiveExecute"
	"УправлениеИтогами" = "TotalsControl"
	"Администрирование" = "Administration"
	"АдминистрированиеДанных" = "DataAdministration"
	"ТонкийКлиент" = "ThinClient"
	"ВебКлиент" = "WebClient"
	"ТолстыйКлиент" = "ThickClient"
	"ВнешнееСоединение" = "ExternalConnection"
	"Вывод" = "Output"
	"СохранениеДанныхПользователя" = "SaveUserData"
	"МобильныйКлиент" = "MobileClient"
}

# Translate Russian object name to English (e.g. "Справочник.Контрагенты" → "Catalog.Контрагенты")
function Translate-ObjectName {
	param([string]$name)
	$parts = $name.Split(".")
	$result = @()
	foreach ($p in $parts) {
		if ($script:typeAliases.ContainsKey($p)) {
			$result += $script:typeAliases[$p]
		} else {
			$result += $p
		}
	}
	return $result -join "."
}

# Translate Russian right name to English (e.g. "Чтение" → "Read")
function Translate-RightName {
	param([string]$name)
	if ($script:rightAliases.ContainsKey($name)) {
		return $script:rightAliases[$name]
	}
	return $name
}

# --- 4. Known rights per object type (source: docs/1c-role-spec.md) ---

$script:knownRights = @{
	"Configuration" = @(
		"Administration","DataAdministration","UpdateDataBaseConfiguration",
		"ConfigurationExtensionsAdministration","ActiveUsers","EventLog","ExclusiveMode",
		"ThinClient","ThickClient","WebClient","MobileClient","ExternalConnection",
		"Automation","Output","SaveUserData","TechnicalSpecialistMode",
		"InteractiveOpenExtDataProcessors","InteractiveOpenExtReports",
		"AnalyticsSystemClient","CollaborationSystemInfoBaseRegistration",
		"MainWindowModeNormal","MainWindowModeWorkplace",
		"MainWindowModeEmbeddedWorkplace","MainWindowModeFullscreenWorkplace","MainWindowModeKiosk"
	)
	"Catalog" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"Document" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Posting","UndoPosting",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractivePosting","InteractivePostingRegular","InteractiveUndoPosting",
		"InteractiveChangeOfPosted",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"InformationRegister" = @(
		"Read","Update","View","Edit","TotalsControl",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","ReadDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"AccumulationRegister" = @("Read","Update","View","Edit","TotalsControl")
	"AccountingRegister" = @("Read","Update","View","Edit","TotalsControl")
	"CalculationRegister" = @("Read","View")
	"Constant" = @(
		"Read","Update","View","Edit",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"ChartOfAccounts" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData",
		"UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment"
	)
	"ChartOfCharacteristicTypes" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"ChartOfCalculationTypes" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData",
		"InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData"
	)
	"ExchangePlan" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveDeleteMarked",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"BusinessProcess" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Start","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveActivate","InteractiveStart"
	)
	"Task" = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"Execute","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDelete","InteractiveActivate","InteractiveExecute"
	)
	"DataProcessor" = @("Use","View")
	"Report" = @("Use","View")
	"CommonForm" = @("View")
	"CommonCommand" = @("View")
	"Subsystem" = @("View")
	"FilterCriterion" = @("View")
	"DocumentJournal" = @("Read","View")
	"Sequence" = @("Read","Update")
	"WebService" = @("Use")
	"HTTPService" = @("Use")
	"IntegrationService" = @("Use")
	"SessionParameter" = @("Get","Set")
	"CommonAttribute" = @("View","Edit")
	"ExternalDataSource" = @(
		"Use","Administration","StandardAuthenticationChange",
		"SessionStandardAuthenticationChange","SessionOSAuthenticationChange"
	)
}

# Виды вложенности (предпоследний сегмент пути) → допустимые права. Списки сняты с корпуса
# типовых конфигураций и с выгрузки роли, где права проставлены по всему дереву редактора:
# догадкам тут не место — закрытый список превращает промах в ложный отказ.
$script:nestedKindRights = @{
	"Attribute"                  = @("View","Edit")
	"StandardAttribute"          = @("View","Edit")
	"TabularSection"             = @("View","Edit")
	"StandardTabularSection"     = @("View","Edit")
	"Dimension"                  = @("View","Edit")
	"Resource"                   = @("View","Edit")
	"AccountingFlag"             = @("View","Edit")
	"ExtDimensionAccountingFlag" = @("View","Edit")
	"AddressingAttribute"        = @("View","Edit")
	"Field"                      = @("View","Edit")
	"Command"                    = @("View")
	"Subsystem"                  = @("View")
	"Operation"                  = @("Use")
	"Method"                     = @("Use")
	"IntegrationServiceChannel"  = @("Use")
	"Recalculation"              = @("Read","Update")
	"Cube"                       = @("Read","View")
	"DimensionTable"             = @("Read","View")
	"Function"                   = @("Use","View")
	"Table"                      = @(
		"Read","Insert","Update","Delete","View","Edit","InputByString",
		"InteractiveInsert","InteractiveDelete"
	)
}

# Виды, существующие только у одного типа-родителя: без этой привязки
# `Catalog.Товары.Field.Цена` прошёл бы как валидный вложенный объект.
$script:kindOwners = @{
	"Table"                     = "ExternalDataSource"
	"Cube"                      = "ExternalDataSource"
	"Function"                  = "ExternalDataSource"
	"Field"                     = "ExternalDataSource"
	"DimensionTable"            = "ExternalDataSource"
	"Recalculation"             = "CalculationRegister"
	"Operation"                 = "WebService"
	"Method"                    = "HTTPService"
	"IntegrationServiceChannel" = "IntegrationService"
}

# Право на сервис живёт на ЛИСТЕ — методе шаблона URL, операции, канале, — а не на самом
# сервисе: корневого узла нет ни в одной типовой роли (907 записей корпуса — ноль), в
# Конфигураторе галки на корне нет вовсе. Короткая запись `HTTPService.X: Use` выражает
# намерение «открой сервис целиком» и раскрывается в листья по метаданным сервиса.
$script:serviceLeaves = @{
	"WebService"         = @{ Dir = "WebServices";         Kinds = @("Operation") }
	"HTTPService"        = @{ Dir = "HTTPServices";        Kinds = @("URLTemplate", "Method") }
	"IntegrationService" = @{ Dir = "IntegrationServices"; Kinds = @("IntegrationServiceChannel") }
}

# Один и тот же вид под разными родителями имеет разный набор: измерение регистра —
# View + Edit, измерение куба внешнего источника — только View. Объединять нельзя,
# объединение молча разрешило бы Edit там, где платформа его не даёт.
$script:nestedKindRightsByType = @{
	"ExternalDataSource" = @{
		"Dimension" = @("View")
		"Resource"  = @("View")
	}
}

# Типы без прав в ролях (в дереве редактора ролей их нет). Таблица НЕ управляет поведением —
# отказ даёт отсутствие типа в $knownRights; здесь только причина для сообщения.
$script:noRightsTypes = @(
	"Enum","CommonModule","DefinedType","CommonPicture","CommonTemplate","Language",
	"FunctionalOption","FunctionalOptionsParameter","EventSubscription","ScheduledJob",
	"StyleItem","Style","SettingsStorage","XDTOPackage","WSReference","DocumentNumerator"
)

# --- 4. Presets (@view, @edit) ---

$script:presets = @{
	"view" = @{
		"Catalog" = @("Read","View","InputByString")
		"ExchangePlan" = @("Read","View","InputByString")
		"Document" = @("Read","View","InputByString")
		"ChartOfAccounts" = @("Read","View","InputByString")
		"ChartOfCharacteristicTypes" = @("Read","View","InputByString")
		"ChartOfCalculationTypes" = @("Read","View","InputByString")
		"BusinessProcess" = @("Read","View","InputByString")
		"Task" = @("Read","View","InputByString")
		"InformationRegister" = @("Read","View")
		"AccumulationRegister" = @("Read","View")
		"AccountingRegister" = @("Read","View")
		"CalculationRegister" = @("Read","View")
		"Constant" = @("Read","View")
		"DocumentJournal" = @("Read","View")
		"Sequence" = @("Read")
		"CommonForm" = @("View")
		"CommonCommand" = @("View")
		"Subsystem" = @("View")
		"FilterCriterion" = @("View")
		"SessionParameter" = @("Get")
		"CommonAttribute" = @("View")
		"DataProcessor" = @("Use","View")
		"Report" = @("Use","View")
		"Configuration" = @("ThinClient","WebClient","Output","SaveUserData","MainWindowModeNormal")
	}
	"edit" = @{
		"Catalog" = @("Read","Insert","Update","Delete","View","Edit","InputByString","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark")
		"ExchangePlan" = @("Read","Insert","Update","Delete","View","Edit","InputByString","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark")
		"Document" = @("Read","Insert","Update","Delete","View","Edit","InputByString","Posting","UndoPosting","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractivePosting","InteractivePostingRegular","InteractiveUndoPosting","InteractiveChangeOfPosted")
		"ChartOfAccounts" = @("Read","Insert","Update","Delete","View","Edit","InputByString","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark")
		"ChartOfCharacteristicTypes" = @("Read","Insert","Update","Delete","View","Edit","InputByString","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark")
		"ChartOfCalculationTypes" = @("Read","Insert","Update","Delete","View","Edit","InputByString","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark")
		"BusinessProcess" = @("Read","Insert","Update","Delete","View","Edit","InputByString","Start","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveActivate","InteractiveStart")
		"Task" = @("Read","Insert","Update","Delete","View","Edit","InputByString","Execute","InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveActivate","InteractiveExecute")
		"InformationRegister" = @("Read","Update","View","Edit")
		"AccumulationRegister" = @("Read","Update","View","Edit")
		"AccountingRegister" = @("Read","Update","View","Edit")
		"Constant" = @("Read","Update","View","Edit")
		"DocumentJournal" = @("Read","View")
		"Sequence" = @("Read","Update")
		"SessionParameter" = @("Get","Set")
		"CommonAttribute" = @("View","Edit")
	}
}

# --- 5. Helpers ---

function Get-ObjectType {
	param([string]$objectName)
	$dotIdx = $objectName.IndexOf(".")
	if ($dotIdx -lt 0) { return $objectName }
	return $objectName.Substring(0, $dotIdx)
}

function Is-NestedObject {
	param([string]$objectName)
	return ($objectName.Split(".").Count -ge 3)
}

# Вид вложенности — предпоследний сегмент: путь бывает и восьмисегментным
# (ExternalDataSource.И.Cube.К.DimensionTable.Т.Field.П), считать от конца.
function Get-NestedKind {
	param([string]$objectName)
	$parts = $objectName.Split(".")
	if ($parts.Count -lt 3) { return $null }
	return $parts[$parts.Count - 2]
}

function Get-NestedRights {
	param([string]$objectType, [string]$kind)
	if ($script:nestedKindRightsByType.ContainsKey($objectType) -and
		$script:nestedKindRightsByType[$objectType].ContainsKey($kind)) {
		return @($script:nestedKindRightsByType[$objectType][$kind])
	}
	if ($script:nestedKindRights.ContainsKey($kind)) { return @($script:nestedKindRights[$kind]) }
	return $null
}

# Отказ копится, а не печатается сразу: роль пишется целиком, поэтому единственный
# безопасный момент отказа — до первой записи, и показать надо все причины сразу.
$script:validationErrors = @()

function Add-ValidationError {
	param([string]$message)
	$script:validationErrors += $message
}

# Проверка имени объекта: тип по белому списку (всегда, включая вложенные пути) и вид
# вложенности. Запрещённый и незнакомый тип — разные диагнозы.
function Validate-ObjectName {
	param([string]$objectName)

	$objectType = Get-ObjectType $objectName
	if (-not $script:knownRights.ContainsKey($objectType)) {
		if ($script:noRightsTypes -contains $objectType) {
			Add-ValidationError "${objectName}: тип '$objectType' не имеет прав в роли — уберите объект из списка"
		} else {
			$similar = @($script:knownRights.Keys | Where-Object { $_ -like "*$objectType*" -or $objectType -like "*$_*" })
			$sug = if ($similar.Count -gt 0) { " Возможно: $(($similar | Select-Object -First 3) -join ', ')?" } else { "" }
			Add-ValidationError "${objectName}: неизвестный тип объекта '$objectType'.$sug"
		}
		return $false
	}

	if (Is-NestedObject $objectName) {
		$kind = Get-NestedKind $objectName
		if ($script:kindOwners.ContainsKey($kind) -and $objectType -ne $script:kindOwners[$kind]) {
			Add-ValidationError "${objectName}: вид '$kind' бывает только у $($script:kindOwners[$kind])"
			return $false
		}
		if ($null -eq (Get-NestedRights $objectType $kind)) {
			Add-ValidationError "${objectName}: неизвестный вид вложенности '$kind'"
			return $false
		}
	}

	return $true
}

function Resolve-Preset {
	param([string]$objectType, [string]$presetName)

	$preset = $presetName.TrimStart('@')

	if (-not $script:presets.ContainsKey($preset)) {
		Write-Warning "Unknown preset '@$preset'. Known: @view, @edit"
		return @()
	}

	$typeMap = $script:presets[$preset]
	if (-not $typeMap.ContainsKey($objectType)) {
		$available = @()
		foreach ($k in $script:presets.Keys) {
			if ($script:presets[$k].ContainsKey($objectType)) {
				$available += "@$k"
			}
		}
		$availStr = if ($available.Count -gt 0) { $available -join ", " } else { "none" }
		Write-Warning "Preset '@$preset' not defined for type '$objectType'. Available: $availStr"
		return @()
	}

	return @($typeMap[$objectType])
}

function Validate-RightName {
	param([string]$objectName, [string]$rightName)

	$objectType = Get-ObjectType $objectName

	# Тип уже проверен Validate-ObjectName — здесь только права, иначе про один
	# запрещённый тип напечатается столько строк, сколько у него перечислено прав.
	if (-not $script:knownRights.ContainsKey($objectType)) { return $false }

	if (Is-NestedObject $objectName) {
		$kind = Get-NestedKind $objectName
		$validNested = Get-NestedRights $objectType $kind
		if ($null -eq $validNested) { return $false }
		if ($rightName -notin $validNested) {
			Add-ValidationError "${objectName}: право '$rightName' недопустимо для вида '$kind' (допустимо: $($validNested -join ', '))"
			return $false
		}
		return $true
	}

	$validRights = $script:knownRights[$objectType]
	if ($rightName -notin $validRights) {
		$suggestions = @($validRights | Where-Object {
			$_ -like "*$rightName*" -or $rightName -like "*$_*"
		})
		$sugStr = if ($suggestions.Count -gt 0) { " Возможно: $(($suggestions | Select-Object -First 3) -join ', ')?" } else { "" }
		Add-ValidationError "${objectName}: право '$rightName' не существует у типа '$objectType'.$sugStr"
		return $false
	}

	return $true
}

# --- 5a. Service roots: expand to leaves ---

# Метаданные сервиса читаются один раз на имя: раскрытие и проверка заимствования
# спрашивают один и тот же файл.
$script:serviceMetaCache = @{}

function Get-ServiceMeta {
	param([string]$objectType, [string]$serviceName, [string]$configRoot)

	$key = "$objectType.$serviceName"
	if ($script:serviceMetaCache.ContainsKey($key)) { return $script:serviceMetaCache[$key] }

	$spec = $script:serviceLeaves[$objectType]
	$xmlPath = Join-Path (Join-Path $configRoot $spec.Dir) "$serviceName.xml"
	$result = @{ Path = $xmlPath; Found = $false; Adopted = $false; Leaves = @() }

	if (Test-Path $xmlPath) {
		try {
			$doc = New-Object System.Xml.XmlDocument
			$doc.PreserveWhitespace = $true
			$doc.Load($xmlPath)
			$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
			$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
			$root = $doc.SelectSingleNode("/md:MetaDataObject/md:$objectType", $ns)
			if ($root) {
				$result.Found = $true
				# ObjectBelonging=Adopted — сервис заимствован в расширение.
				$ob = $root.SelectSingleNode("md:Properties/md:ObjectBelonging", $ns)
				if ($ob -and $ob.InnerText -eq "Adopted") { $result.Adopted = $true }

				# Спуск по видам: у HTTP-сервиса лист лежит на два уровня ниже
				# (URLTemplate → Method), у остальных — на один.
				$level = @(@{ Node = $root; Name = "$objectType.$serviceName" })
				foreach ($kind in $spec.Kinds) {
					$next = @()
					foreach ($item in $level) {
						foreach ($child in $item.Node.SelectNodes("md:ChildObjects/md:$kind", $ns)) {
							# Имя берём SelectSingleNode: XML-адаптер PowerShell перекрывает
							# .NET-члены атрибутами, $child.Name отдал бы не то и молча.
							$nameNode = $child.SelectSingleNode("md:Properties/md:Name", $ns)
							if (-not $nameNode) { continue }
							$next += ,@{ Node = $child; Name = "$($item.Name).$kind.$($nameNode.InnerText)" }
						}
					}
					$level = $next
				}
				$result.Leaves = @($level | ForEach-Object { $_.Name })
			}
		} catch {
			# Битый XML — не наша забота: раскрывать нечего, дальше отработает отказ
			# «метаданные не найдены» с тем же путём в подсказке.
		}
	}

	$script:serviceMetaCache[$key] = $result
	return $result
}

# Подсказка формата: единственное, что отличается у трёх видов сервисов, — путь до листа.
function Get-ServiceLeafHint {
	param([string]$objectType, [string]$serviceName)
	switch ($objectType) {
		"HTTPService"        { return "$objectType.$serviceName.URLTemplate.<Шаблон>.Method.<Метод>: Use" }
		"WebService"         { return "$objectType.$serviceName.Operation.<Операция>: Use" }
		default              { return "$objectType.$serviceName.IntegrationServiceChannel.<Канал>: Use" }
	}
}

# Роль расширения, включённая в <DefaultRoles>, прав на заимствованные объекты давать не
# может — платформа отвечает «Назначение прав доступа на заимствованные объекты основными
# ролями в расширениях недопустимо». Считаем один раз: имя роли за прогон не меняется.
$script:isDefaultRole = $null

function Test-DefaultRole {
	param([string]$configRoot, [string]$name)

	if ($null -ne $script:isDefaultRole) { return $script:isDefaultRole }
	$script:isDefaultRole = $false

	$cfgPath = Join-Path $configRoot "Configuration.xml"
	if (Test-Path $cfgPath) {
		$text = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
		# Только расширение: у обычной конфигурации DefaultRoles значит другое и запрета нет.
		if ($text -match '<ConfigurationExtensionPurpose>' -and $text -match '(?s)<DefaultRoles>(.*?)</DefaultRoles>') {
			# -cmatch, а не -match: -match регистронезависим и «Расш1_Роль1» совпал бы
			# с «расш1_роль1», молча приняв роль за основную.
			$script:isDefaultRole = ($Matches[1] -cmatch ([regex]::Escape("Role.$name") + '\s*<'))
		}
	}
	return $script:isDefaultRole
}

# Возвращает список записей на замену исходной: сервисный корень раскрывается в листья,
# всё остальное проходит как есть.
function Expand-ServiceEntry {
	param($parsed, [string]$configRoot, [string]$name)

	$objName = $parsed.Name
	$objectType = Get-ObjectType $objName
	if (-not $script:serviceLeaves.ContainsKey($objectType)) { return @($parsed) }

	$parts = $objName.Split(".")
	if ($parts.Count -lt 2) { return @($parsed) }
	$serviceName = $parts[1]
	$meta = Get-ServiceMeta -objectType $objectType -serviceName $serviceName -configRoot $configRoot

	if ($meta.Adopted -and (Test-DefaultRole -configRoot $configRoot -name $name)) {
		Add-ValidationError ("${objName}: '$name' — основная роль расширения (входит в DefaultRoles), " +
			"а $objectType.$serviceName заимствован; назначать права на заимствованные объекты " +
			"основными ролями расширения платформа запрещает. Заведите отдельную роль и не включайте её в основные.")
		return @()
	}

	# Полный путь пользователь задал сам — раскрывать нечего.
	if ($parts.Count -gt 2) { return @($parsed) }

	$hint = Get-ServiceLeafHint -objectType $objectType -serviceName $serviceName
	if (-not $meta.Found) {
		Add-ValidationError ("${objName}: метаданные сервиса не найдены ($($meta.Path)); " +
			"право на сервис целиком платформа игнорирует — укажите листья явно: $hint")
		return @()
	}
	if ($meta.Leaves.Count -eq 0) {
		Add-ValidationError ("${objName}: у сервиса нет ни одного вложенного объекта, раскрывать нечего; " +
			"право на сервис целиком платформа игнорирует. Для заимствованного сервиса заимствуйте нужные методы, затем: $hint")
		return @()
	}

	$expanded = @()
	foreach ($leaf in $meta.Leaves) {
		$expanded += ,@{ Name = $leaf; Rights = $parsed.Rights }
	}
	Write-Host "     $objName -> раскрыт (вложенных объектов: $($expanded.Count))"
	return $expanded
}

# --- 6. Parse object entries ---

function Parse-ObjectEntry {
	param($entry)

	# --- String shorthand ---
	if ($entry -is [string]) {
		$colonIdx = $entry.IndexOf(':')
		if ($colonIdx -lt 0) {
			Write-Warning "Invalid string '$entry' -- expected 'Object.Name: @preset' or 'Object.Name: Right1, Right2'"
			return $null
		}
		$objName = Translate-ObjectName ($entry.Substring(0, $colonIdx).Trim())
		$rightsStr = $entry.Substring($colonIdx + 1).Trim()
		# Объект с непроходным именем дальше не разбираем: пресет для несуществующего типа
		# добавил бы к отказу ещё и бессмысленное предупреждение.
		if (-not (Validate-ObjectName $objName)) { return $null }
		$objectType = Get-ObjectType $objName

		if ($rightsStr.StartsWith('@')) {
			$rightNames = @(Resolve-Preset -objectType $objectType -presetName $rightsStr)
		} else {
			$rightNames = @($rightsStr -split ',\s*' | ForEach-Object { Translate-RightName $_.Trim() } | Where-Object { $_ })
			foreach ($r in $rightNames) {
				Validate-RightName -objectName $objName -rightName $r | Out-Null
			}
		}

		$rights = @()
		foreach ($r in $rightNames) {
			$rights += ,@{Name=$r; Value="true"; Condition=$null}
		}
		return @{ Name = $objName; Rights = $rights }
	}

	# --- Object form ---
	$objName = Translate-ObjectName "$($entry.name)"
	if (-not $objName) {
		Write-Warning "Object entry missing 'name' field"
		return $null
	}

	if (-not (Validate-ObjectName $objName)) { return $null }

	$objectType = Get-ObjectType $objName
	$rightsMap = [ordered]@{}

	# 1) Start with preset
	if ($entry.preset) {
		$presetRights = @(Resolve-Preset -objectType $objectType -presetName "$($entry.preset)")
		foreach ($r in $presetRights) {
			$rightsMap[$r] = @{Value="true"; Condition=$null}
		}
	}

	# 2) Apply explicit rights
	if ($entry.rights) {
		if ($entry.rights -is [array]) {
			foreach ($r in $entry.rights) {
				$rName = Translate-RightName "$r"
				Validate-RightName -objectName $objName -rightName $rName | Out-Null
				$rightsMap[$rName] = @{Value="true"; Condition=$null}
			}
		} else {
			foreach ($p in $entry.rights.PSObject.Properties) {
				$rName = Translate-RightName $p.Name
				Validate-RightName -objectName $objName -rightName $rName | Out-Null
				$boolVal = $p.Value
				if ($boolVal -eq $true -or "$boolVal" -eq "True") {
					$rightsMap[$rName] = @{Value="true"; Condition=$null}
				} else {
					$rightsMap[$rName] = @{Value="false"; Condition=$null}
				}
			}
		}
	}

	# 3) Apply RLS conditions
	if ($entry.rls) {
		foreach ($p in $entry.rls.PSObject.Properties) {
			$rlsRight = Translate-RightName $p.Name
			if ($rightsMap.Contains($rlsRight)) {
				$rightsMap[$rlsRight].Condition = "$($p.Value)"
			} else {
				Write-Warning "${objName}: RLS for '$rlsRight' but this right is not in the rights list"
			}
		}
	}

	# Convert to array
	$rights = @()
	foreach ($k in $rightsMap.Keys) {
		$rights += ,@{
			Name = $k
			Value = $rightsMap[$k].Value
			Condition = $rightsMap[$k].Condition
		}
	}

	return @{ Name = $objName; Rights = $rights }
}

# --- 7. Parse all object entries ---

# Synonym: accept "rights" as alias for "objects"
if (-not $def.objects -and $def.rights) { $def | Add-Member -NotePropertyName objects -NotePropertyValue $def.rights }

# Путь нужен уже здесь: раскрытие сервисного корня читает метаданные сервиса рядом с ролью.
$resolvedOutputDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path (Get-Location) $OutputDir }

$parsedObjects = @()
$seenObjectNames = @{}
if ($def.objects) {
	foreach ($entry in $def.objects) {
		$parsed = Parse-ObjectEntry -entry $entry
		if (-not $parsed) { continue }
		foreach ($p in (Expand-ServiceEntry -parsed $parsed -configRoot $resolvedOutputDir -name $roleName)) {
			# Дубль возникает штатно: раскрытый лист совпал с явно заданным. Права на листе
			# одни и те же (Use), так что вторая запись — шум, а не конфликт.
			if ($seenObjectNames.ContainsKey($p.Name)) {
				Write-Warning "$($p.Name): объект указан дважды, вторая запись пропущена"
				continue
			}
			$seenObjectNames[$p.Name] = $true
			$parsedObjects += ,$p
		}
	}
}

# Отказ ДО записи: роль пишется тремя файлами (метаданные, права, регистрация в
# Configuration.xml), и частично записанная роль хуже отсутствующей. Печатаем все причины
# разом — иначе пользователь чинит их по одной. Console.Error, а не Write-Error: под
# ErrorActionPreference=Stop последний бросает исключение (см. комментарий в support-guard).
if ($script:validationErrors.Count -gt 0) {
	[Console]::Error.WriteLine("[role-compile] Роль не создана: $($script:validationErrors.Count) ошибок в описании прав.")
	foreach ($e in $script:validationErrors) { [Console]::Error.WriteLine("  ERROR: $e") }
	exit 1
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

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

Assert-EditAllowed $resolvedOutputDir 'editable'
$formatVersion = Detect-FormatVersion $resolvedOutputDir

# --- 8. Generate UUID ---

$uuid = [guid]::NewGuid().ToString()

# --- 9. Emit metadata XML (Roles/Name.xml) ---

$script:xmlBuf = New-Object System.Text.StringBuilder 4096

X '<?xml version="1.0" encoding="UTF-8"?>'
# Объявления пространств имён — одной переменной и одной строкой, как пишет платформа.
$xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
# 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (после lf, перед style):
# платформа держит объявления по алфавиту. В Rights.xml палитра НЕ идёт (проверено по выгрузке 8.5).
if ((Get-FormatRank $formatVersion) -ge 221) {
	$xmlnsDecl = $xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}
X "<MetaDataObject $xmlnsDecl version=`"$formatVersion`">"
X "`t<Role uuid=`"$uuid`">"
X "`t`t<Properties>"
X "`t`t`t<Name>$roleName</Name>"
X "`t`t`t<Synonym>"
X "`t`t`t`t<v8:item>"
X "`t`t`t`t`t<v8:lang>ru</v8:lang>"
X "`t`t`t`t`t<v8:content>$(Esc-XmlText $synonym)</v8:content>"
X "`t`t`t`t</v8:item>"
X "`t`t`t</Synonym>"
if ($comment) {
	X "`t`t`t<Comment>$(Esc-XmlText $comment)</Comment>"
} else {
	X "`t`t`t<Comment/>"
}
X "`t`t</Properties>"
X "`t</Role>"
X '</MetaDataObject>'

$metadataXml = $script:xmlBuf.ToString()

# --- 10. Emit Rights XML (Roles/Name/Ext/Rights.xml) ---

$script:xmlBuf = New-Object System.Text.StringBuilder 8192

X '<?xml version="1.0" encoding="UTF-8"?>'
X "<Rights xmlns=`"http://v8.1c.ru/8.2/roles`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" xsi:type=`"Rights`" version=`"$formatVersion`">"

# Global flags (defaults match typical 1C roles)
$sfno = if ($null -ne $def.setForNewObjects) { "$($def.setForNewObjects)".ToLower() } else { "false" }
$sfab = if ($null -ne $def.setForAttributesByDefault) { "$($def.setForAttributesByDefault)".ToLower() } else { "true" }
$irco = if ($null -ne $def.independentRightsOfChildObjects) { "$($def.independentRightsOfChildObjects)".ToLower() } else { "false" }

X "`t<setForNewObjects>$sfno</setForNewObjects>"
X "`t<setForAttributesByDefault>$sfab</setForAttributesByDefault>"
X "`t<independentRightsOfChildObjects>$irco</independentRightsOfChildObjects>"

# Object blocks
$totalRights = 0
foreach ($obj in $parsedObjects) {
	X "`t<object>"
	X "`t`t<name>$($obj.Name)</name>"
	foreach ($right in $obj.Rights) {
		X "`t`t<right>"
		X "`t`t`t<name>$($right.Name)</name>"
		X "`t`t`t<value>$($right.Value)</value>"
		if ($right.Condition) {
			X "`t`t`t<restrictionByCondition>"
			X "`t`t`t`t<condition>$(Esc-XmlText $right.Condition)</condition>"
			X "`t`t`t</restrictionByCondition>"
		}
		X "`t`t</right>"
		$totalRights++
	}
	X "`t</object>"
}

# RLS restriction templates
$templateCount = 0
if ($def.templates) {
	foreach ($tpl in $def.templates) {
		X "`t<restrictionTemplate>"
		X "`t`t<name>$(Esc-XmlText "$($tpl.name)")</name>"
		X "`t`t<condition>$(Esc-XmlText "$($tpl.condition)")</condition>"
		X "`t</restrictionTemplate>"
		$templateCount++
	}
}

X '</Rights>'

$rightsXml = $script:xmlBuf.ToString()

# --- 11. Write output files ---

$outDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
	$OutputDir
} else {
	Join-Path (Get-Location) $OutputDir
}

# Determine Roles dir and config root
# Back-compat: if OutputDir leaf is "Roles", use as-is; otherwise treat as config root
$leaf = Split-Path $outDir -Leaf
if ($leaf -eq "Roles") {
	$rolesDir = $outDir
	$configDir = Split-Path $outDir -Parent
} else {
	$rolesDir = Join-Path $outDir "Roles"
	$configDir = $outDir
}

# Metadata: Roles/RoleName.xml
$metadataPath = Join-Path $rolesDir "$roleName.xml"
if (-not (Test-Path $rolesDir)) {
	New-Item -ItemType Directory -Path $rolesDir -Force | Out-Null
}

# Rights: Roles/RoleName/Ext/Rights.xml
$roleSubDir = Join-Path $rolesDir $roleName
$extDir = Join-Path $roleSubDir "Ext"
$rightsPath = Join-Path $extDir "Rights.xml"
if (-not (Test-Path $extDir)) {
	New-Item -ItemType Directory -Path $extDir -Force | Out-Null
}

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($metadataPath, $metadataXml.TrimEnd("`r", "`n"), $enc)
[System.IO.File]::WriteAllText($rightsPath, $rightsXml.TrimEnd("`r", "`n"), $enc)

# --- 12. Register in Configuration.xml ---

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

$configXmlPath = Join-Path $configDir "Configuration.xml"
$regResult = Register-InChildObjects $configXmlPath "Configuration" "Role" $roleName

# --- 13. Summary ---

Write-Host "[OK] Role '$roleName' compiled"
Write-Host "     UUID: $uuid"
Write-Host "     Metadata: $metadataPath"
Write-Host "     Rights:   $rightsPath"
Write-Host "     Objects: $($parsedObjects.Count), Rights: $totalRights, Templates: $templateCount"
switch ($regResult) {
	"added"       { Write-Host "     Configuration.xml: <Role>$roleName</Role> added to ChildObjects" }
	"already"     { Write-Host "     Configuration.xml: <Role>$roleName</Role> already registered" }
	"no-childobj" { Write-Warning "Configuration.xml found but <ChildObjects> not found" }
	"no-config"   { Write-Warning "Configuration.xml not found at $configXmlPath — register manually" }
}
