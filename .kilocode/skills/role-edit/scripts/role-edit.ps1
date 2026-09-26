# role-edit v1.7 — Edit existing 1C role rights in place
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory)][Alias('Path','RightsPath')][string]$RolePath,
	[string]$DefinitionFile,
	[ValidateSet("add-rights","set-rights","remove-rights","deny-rights","set-rls","remove-rls",
		"add-template","set-template","remove-template","modify-property","set-synonym","set-comment")]
	[string]$Operation,
	[string]$Value,
	[switch]$NoValidate
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Разбор пользовательского JSON ---
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
	"CalculationRegister" = @(
		"Read","Update","View","Edit"
	)
	"Constant" = @(
		"Read","Update","View","Edit",
		"ReadDataHistory","ViewDataHistory","UpdateDataHistory",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"ChartOfAccounts" = @(
		"Read","Insert","Update","Delete"
		"View","Edit","InputByString","InteractiveInsert"
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDelete","InteractiveDeleteMarked"
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData"
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData"
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment"
		"SwitchToDataHistoryVersion"
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
		"Read","Insert","Update","Delete"
		"View","Edit","InputByString","InteractiveInsert"
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDelete","InteractiveDeleteMarked"
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData"
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData"
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment"
		"SwitchToDataHistoryVersion"
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
		"Read","Insert","Update","Delete"
		"View","Edit","InputByString","Start"
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDelete"
		"InteractiveDeleteMarked","InteractiveActivate","InteractiveStart","ReadDataHistory"
		"ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData","UpdateDataHistorySettings"
		"UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"Task" = @(
		"Read","Insert","Update","Delete"
		"View","Edit","InputByString","Execute"
		"InteractiveInsert","InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDelete"
		"InteractiveDeleteMarked","InteractiveActivate","InteractiveExecute","ReadDataHistory"
		"ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData","UpdateDataHistorySettings"
		"UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
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

# --- 4a. Канонический порядок прав и узлов (замерено на платформе) ---
# Платформа нормализует порядок <right> внутри <object> и порядок самих <object>:
# права идут в фиксированном для типа порядке, узлы — по uuid объекта метаданных.
# Пишем сразу так же, иначе первая же выгрузка из Конфигуратора даст диф на ровном месте.
$script:rightOrder = @{
	"AccountingRegister" = @("Read","Update","View","Edit","TotalsControl")
	"AccumulationRegister" = @("Read","Update","View","Edit","TotalsControl")
	"BusinessProcess" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveActivate","Start","InteractiveStart","ReadDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData","UpdateDataHistorySettings",
		"UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"CalculationRegister" = @("Read","Update","View","Edit")
	"Catalog" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment",
		"SwitchToDataHistoryVersion"
	)
	"ChartOfAccounts" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment",
		"SwitchToDataHistoryVersion"
	)
	"ChartOfCalculationTypes" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment",
		"SwitchToDataHistoryVersion"
	)
	"ChartOfCharacteristicTypes" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveDeletePredefinedData","InteractiveSetDeletionMarkPredefinedData","InteractiveClearDeletionMarkPredefinedData","InteractiveDeleteMarkedPredefinedData",
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment",
		"SwitchToDataHistoryVersion"
	)
	"CommonAttribute" = @("View","Edit")
	"CommonCommand" = @("View")
	"CommonForm" = @("View")
	"Configuration" = @(
		"Administration","DataAdministration","UpdateDataBaseConfiguration","ExclusiveMode",
		"ActiveUsers","EventLog","ThinClient","WebClient",
		"MobileClient","ThickClient","ExternalConnection","Automation",
		"TechnicalSpecialistMode","CollaborationSystemInfoBaseRegistration","MainWindowModeNormal","MainWindowModeWorkplace",
		"MainWindowModeEmbeddedWorkplace","MainWindowModeFullscreenWorkplace","MainWindowModeKiosk","AnalyticsSystemClient",
		"SaveUserData","ConfigurationExtensionsAdministration","InteractiveOpenExtDataProcessors","InteractiveOpenExtReports",
		"Output"
	)
	"Constant" = @(
		"Read","Update","View","Edit",
		"ReadDataHistory","UpdateDataHistory","UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"DataProcessor" = @("Use","View")
	"Document" = @(
		"Read","Insert","Update","Delete",
		"Posting","UndoPosting","View","InteractiveInsert",
		"Edit","InteractiveDelete","InteractiveSetDeletionMark","InteractiveClearDeletionMark",
		"InteractiveDeleteMarked","InteractivePosting","InteractivePostingRegular","InteractiveUndoPosting",
		"InteractiveChangeOfPosted","InputByString","ReadDataHistory","ReadDataHistoryOfMissingData",
		"UpdateDataHistory","UpdateDataHistoryOfMissingData","UpdateDataHistorySettings","UpdateDataHistoryVersionComment",
		"ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"DocumentJournal" = @("Read","View")
	"ExchangePlan" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData",
		"UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment",
		"SwitchToDataHistoryVersion"
	)
	"FilterCriterion" = @("View")
	"HTTPService" = @("Use")
	"InformationRegister" = @(
		"Read","Update","View","Edit",
		"TotalsControl","ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory",
		"UpdateDataHistoryOfMissingData","UpdateDataHistorySettings","UpdateDataHistoryVersionComment","ViewDataHistory",
		"EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"IntegrationService" = @("Use")
	"Report" = @("Use","View")
	"Sequence" = @("Read","Update")
	"SessionParameter" = @("Get","Set")
	"Subsystem" = @("View")
	"Task" = @(
		"Read","Insert","Update","Delete",
		"View","InteractiveInsert","Edit","InteractiveDelete",
		"InteractiveSetDeletionMark","InteractiveClearDeletionMark","InteractiveDeleteMarked","InputByString",
		"InteractiveActivate","Execute","InteractiveExecute","ReadDataHistory",
		"ReadDataHistoryOfMissingData","UpdateDataHistory","UpdateDataHistoryOfMissingData","UpdateDataHistorySettings",
		"UpdateDataHistoryVersionComment","ViewDataHistory","EditDataHistoryVersionComment","SwitchToDataHistoryVersion"
	)
	"WebService" = @("Use")
}

$script:nestedRightOrder = @{
	"AccountingFlag" = @("View","Edit")
	"AddressingAttribute" = @("View","Edit")
	"Attribute" = @("View","Edit")
	"Command" = @("View")
	"Dimension" = @("View","Edit")
	"ExtDimensionAccountingFlag" = @("View","Edit")
	"IntegrationServiceChannel" = @("Use")
	"Method" = @("Use")
	"Operation" = @("Use")
	"Recalculation" = @("Read","Update")
	"Resource" = @("View","Edit")
	"StandardAttribute" = @("View","Edit")
	"StandardTabularSection" = @("View","Edit")
	"Subsystem" = @("View")
	"TabularSection" = @("View","Edit")
}

# Каталоги объектов метаданных — нужны, чтобы прочитать uuid и расставить <object>.
$script:typeDirs = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "DocumentJournal"="DocumentJournals"
	"Sequence"="Sequences"; "Constant"="Constants"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"AccountingRegister"="AccountingRegisters"; "CalculationRegister"="CalculationRegisters"
	"ChartOfAccounts"="ChartsOfAccounts"; "ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"; "ExchangePlan"="ExchangePlans"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"; "Subsystem"="Subsystems"
	"CommonForm"="CommonForms"; "CommonCommand"="CommonCommands"; "CommonAttribute"="CommonAttributes"
	"FilterCriterion"="FilterCriteria"; "SessionParameter"="SessionParameters"
	"WebService"="WebServices"; "HTTPService"="HTTPServices"; "IntegrationService"="IntegrationServices"
	"ExternalDataSource"="ExternalDataSources"
}

# Порядок прав объекта: известные — по таблице, незнакомые — следом, в порядке ввода.
function Sort-RightsCanonical {
	param([string]$objName, $rights)
	$parts = $objName -split '\.'
	$order = if ($parts.Count -ge 3) { $script:nestedRightOrder[$parts[$parts.Count-2]] }
	         else { $script:rightOrder[$parts[0]] }
	if (-not $order) { return $rights }
	$byName = @{}
	foreach ($r in $rights) { if (-not $byName.ContainsKey($r.Name)) { $byName[$r.Name] = $r } }
	$sorted = @()
	foreach ($name in $order) { if ($byName.ContainsKey($name)) { $sorted += ,$byName[$name]; $byName.Remove($name) } }
	foreach ($r in $rights) { if ($byName.ContainsKey($r.Name)) { $sorted += ,$r; $byName.Remove($r.Name) } }
	return $sorted
}

# У стандартных реквизитов и стандартных табличных частей uuid в выгрузке нет: они системные.
# Отсутствие uuid для них — норма, а не потерянный объект.
function Test-StandardKind {
	param([string]$objName)
	$parts = $objName -split '\\.'
	if ($parts.Count -lt 3) { return $false }
	return $parts[$parts.Count-2].StartsWith("Standard")
}

# uuid объекта прав: у верхнего уровня — из файла объекта, у вложенного — спуском по дереву.
# Искать регуляркой по всему файлу нельзя: реквизит шапки и реквизит табличной части часто
# называются одинаково, и поиск нашёл бы первый попавшийся. Дочерние подсистемы лежат
# отдельными файлами, поэтому для них спуск идёт по каталогам.
# У стандартных реквизитов uuid в выгрузке нет вовсе — для них возвращаем $null молча.
function Get-RightsObjectUuid {
	param([string]$objName, [string]$configRoot)
	$parts = $objName -split '\.'
	if ($parts[0] -eq 'Configuration') {
		$cfgPath = Join-Path $configRoot "Configuration.xml"
		if (-not (Test-Path $cfgPath)) { return $null }
		$head = [System.IO.File]::ReadAllText($cfgPath)
		if ($head -match '<Configuration uuid="([0-9a-fA-F-]+)"') { return $Matches[1] }
		return $null
	}
	$dir = $script:typeDirs[$parts[0]]
	if (-not $dir -or $parts.Count -lt 2) { return $null }
	# Подсистемы вложены каталогами: Subsystems/Родитель/Subsystems/Ребёнок.xml
	$ownerPath = Join-Path (Join-Path $configRoot $dir) "$($parts[1]).xml"
	$i = 2
	while ($parts.Count -gt $i + 1 -and $parts[$i] -eq 'Subsystem') {
		$ownerDir = [System.IO.Path]::Combine($configRoot, $dir, ($parts[1..($i-1)] -join [System.IO.Path]::DirectorySeparatorChar + 'Subsystems' + [System.IO.Path]::DirectorySeparatorChar))
		$ownerPath = Join-Path (Join-Path ([System.IO.Path]::GetDirectoryName($ownerPath)) ([System.IO.Path]::GetFileNameWithoutExtension($ownerPath))) (Join-Path "Subsystems" "$($parts[$i+1]).xml")
		$i += 2
	}
	if (-not (Test-Path $ownerPath)) { return $null }
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	try { $doc.Load($ownerPath) } catch { return $null }
	$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$nsm.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$node = $doc.DocumentElement.FirstChild
	while ($node -and $node.NodeType -ne 'Element') { $node = $node.NextSibling }
	if (-not $node) { return $null }
	# Оставшиеся пары «вид, имя» ищем строго внутри текущего узла.
	while ($i + 1 -lt $parts.Count) {
		$kind = $parts[$i]
		$name = $parts[$i+1]
		$child = $node.SelectSingleNode("md:ChildObjects/md:$kind[md:Properties/md:Name='$name']", $nsm)
		if (-not $child) { return $null }
		$node = $child
		$i += 2
	}
	if ($node.HasAttribute("uuid")) { return $node.GetAttribute("uuid") }
	return $null
}

# Порядок узлов: по uuid объекта; неразрешённые — в конец, в порядке ввода.
function Sort-ObjectsByUuid {
	param($objects, [string]$configRoot)
	$known = @()
	$unknown = @()
	foreach ($o in $objects) {
		$uuid = Get-RightsObjectUuid -objName $o.Name -configRoot $configRoot
		if ($uuid) { $known += ,[pscustomobject]@{ Uuid = $uuid; Obj = $o } }
		else {
			[Console]::Error.WriteLine("[role-compile] $($o.Name): объект не найден в выгрузке, uuid неизвестен — узел записан в конец (платформа переставит его при первой выгрузке)")
			$unknown += ,$o
		}
	}
	# Сортировка строго ordinal: Sort-Object сравнивает по культуре и игнорирует дефис,
	# из-за чего порядок разошёлся бы и с платформой, и с py-портом.
	$arr = [object[]]$known
	if ($arr.Count -gt 1) {
		[Array]::Sort($arr, [System.Comparison[object]]{ param($x, $y) [string]::CompareOrdinal($x.Uuid, $y.Uuid) })
	}
	$result = @()
	foreach ($k in $arr) { $result += ,$k.Obj }
	foreach ($u in $unknown) { $result += ,$u }
	return $result
}

# --- 4b. Зависимости прав (замерено на платформе) ---
# Платформа при загрузке сама доводит набор до замыкания: выдал Edit — получил ещё
# Read, Update и View. Пишем замыкание сразу, иначе файл и база расходятся.
# Таблица общая для типов; исключения — там, где у типа своя механика (обработка и отчёт
# держатся на Use, план счетов не тянет Read под историю данных).
$script:rightDeps = @{
	"Delete" = @("Read")
	"Edit" = @("Read","Update","View")
	"EditDataHistoryVersionComment" = @("Read","ReadDataHistory","UpdateDataHistoryVersionComment","View")
	"Execute" = @("Read","Update")
	"InputByString" = @("Read","View")
	"Insert" = @("Read")
	"InteractiveActivate" = @("Read","Update")
	"InteractiveChangeOfPosted" = @("Edit","Read","Update","View")
	"InteractiveClearDeletionMark" = @("Edit","Read","Update","View")
	"InteractiveClearDeletionMarkPredefinedData" = @("Edit","InteractiveClearDeletionMark","Read","Update","View")
	"InteractiveDelete" = @("Delete","Edit","Read","Update","View")
	"InteractiveDeleteMarked" = @("Delete","Edit","Read","Update","View")
	"InteractiveDeleteMarkedPredefinedData" = @("Delete","Edit","InteractiveDeleteMarked","Read","Update","View")
	"InteractiveDeletePredefinedData" = @("Delete","Edit","InteractiveDelete","Read","Update","View")
	"InteractiveExecute" = @("Execute","Read","Update")
	"InteractiveInsert" = @("Edit","Insert","Read","Update","View")
	"InteractivePosting" = @("Edit","Posting","Read","Update","View")
	"InteractivePostingRegular" = @("Edit","InteractivePosting","Posting","Read","Update","View")
	"InteractiveSetDeletionMark" = @("Edit","Read","Update","View")
	"InteractiveSetDeletionMarkPredefinedData" = @("Edit","InteractiveSetDeletionMark","Read","Update","View")
	"InteractiveStart" = @("Read","Start","Update")
	"InteractiveUndoPosting" = @("Edit","Read","UndoPosting","Update","View")
	"Posting" = @("Read","Update")
	"ReadDataHistory" = @("Read")
	"ReadDataHistoryOfMissingData" = @("Read","ReadDataHistory")
	"Start" = @("Read","Update")
	"SwitchToDataHistoryVersion" = @("Read","View")
	"UndoPosting" = @("Read","Update")
	"Update" = @("Read")
	"UpdateDataHistory" = @("Read","ReadDataHistory")
	"UpdateDataHistoryOfMissingData" = @("Read","ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory")
	"UpdateDataHistoryVersionComment" = @("Read","ReadDataHistory")
	"View" = @("Read")
	"ViewDataHistory" = @("Read","ReadDataHistory","View")
}

$script:rightDepsByType = @{
	"ChartOfAccounts" = @{
		"ReadDataHistory" = @()
		"ReadDataHistoryOfMissingData" = @("ReadDataHistory")
		"UpdateDataHistory" = @("ReadDataHistory")
		"UpdateDataHistoryOfMissingData" = @("ReadDataHistory","ReadDataHistoryOfMissingData","UpdateDataHistory")
		"UpdateDataHistoryVersionComment" = @("ReadDataHistory")
	}
	"DataProcessor" = @{
		"View" = @("Use")
	}
	"InformationRegister" = @{
		"UpdateDataHistoryOfMissingData" = @("Read","ReadDataHistory","UpdateDataHistory")
	}
	"Report" = @{
		"View" = @("Use")
	}
}

$script:configurationLegacyDeps = @("AnalyticsSystemClient","MainWindowModeEmbeddedWorkplace","MainWindowModeFullscreenWorkplace","MainWindowModeKiosk","MainWindowModeNormal","MainWindowModeWorkplace")

# Права конфигурации: до формата 2.19 платформа взводила весь блок режимов окна вместе с
# любым правом, с 2.19 (8.3.26) перестала. Сами права допустимы и там, и там.
$script:configurationLegacyRank = 218

# Замыкание набора прав объекта. Возвращает @{ Rights = <итог>; Added = <что дописано> }.
# Платформа хранит только то, что ОТЛИЧАЕТСЯ от значения по умолчанию для роли: при
# setForNewObjects=false на верхнем уровне живут разрешения, при true — запреты; у реквизитных
# вложенных объектов ту же роль играет setForAttributesByDefault. Совпавшее с умолчанием
# платформа выбрасывает при первой же загрузке, поэтому не пишем его и сами.
$script:attributeKinds = @(
	"Attribute","StandardAttribute","TabularSection","StandardTabularSection",
	"Dimension","Resource","AccountingFlag","ExtDimensionAccountingFlag","AddressingAttribute"
)

function Get-DefaultRightValue {
	param([string]$objName, [string]$setForNewObjects, [string]$setForAttributesByDefault)
	$parts = $objName -split '\.'
	if ($parts.Count -lt 3) { return $setForNewObjects }
	# Внешние источники данных под это правило не проверялись — трогаем только то, что замерено.
	if ($parts[0] -eq 'ExternalDataSource') { return "false" }
	$kind = $parts[$parts.Count-2]
	if ($script:attributeKinds -contains $kind) { return $setForAttributesByDefault }
	# Команды, подсистемы, операции сервисов флагами роли не управляются — там живут разрешения.
	return "false"
}

function Close-RightsDependencies {
	param([string]$objName, $rights, [int]$formatRank)
	$parts = $objName -split '\.'
	$nested = $parts.Count -ge 3
	$objectType = $parts[0]
	$allowed = if ($nested) { Get-NestedRights -objectType $objectType -kind (Get-NestedKind $objName) }
	           else { $script:knownRights[$objectType] }
	if (-not $allowed) { return @{ Rights = $rights; Added = @() } }
	$have = [ordered]@{}
	foreach ($r in $rights) { if (-not $have.Contains($r.Name)) { $have[$r.Name] = $r } }
	$byType = $script:rightDepsByType[$objectType]
	$added = @()
	# Вперёд — только от РАЗРЕШЁННЫХ прав: платформа замыкает выданное, а не запрещённое.
	$queue = @($have.Keys | Where-Object { $have[$_].Value -eq "true" })
	while ($queue.Count -gt 0) {
		$name = $queue[0]
		$queue = @($queue | Select-Object -Skip 1)
		$need = if ($byType -and $byType.Contains($name)) { $byType[$name] } else { $script:rightDeps[$name] }
		if (-not $need) { continue }
		foreach ($dep in $need) {
			if ($allowed -notcontains $dep) { continue }
			if ($have.Contains($dep)) {
				# Разрешение перебивает запрет — так поступает и платформа при загрузке.
				if ($have[$dep].Value -ne "true") { $have[$dep].Value = "true"; $added += $dep; $queue += $dep }
				continue
			}
			$have[$dep] = @{ Name = $dep; Value = "true"; Condition = $null }
			$added += $dep
			$queue += $dep
		}
	}
	# Назад — от ЗАПРЕТОВ: право, которому запрещённое нужно, платформа запрещает следом.
	$denyQueue = @($have.Keys | Where-Object { $have[$_].Value -ne "true" })
	while ($denyQueue.Count -gt 0) {
		$name = $denyQueue[0]
		$denyQueue = @($denyQueue | Select-Object -Skip 1)
		foreach ($candidate in $allowed) {
			if ($candidate -eq $name) { continue }
			$need = if ($byType -and $byType.Contains($candidate)) { $byType[$candidate] } else { $script:rightDeps[$candidate] }
			if (-not $need -or $need -notcontains $name) { continue }
			if ($have.Contains($candidate)) { continue }
			$have[$candidate] = @{ Name = $candidate; Value = "false"; Condition = $null }
			$added += $candidate
			$denyQueue += $candidate
		}
	}
	if ($objectType -eq 'Configuration' -and $formatRank -le $script:configurationLegacyRank -and $have.Count -gt 0) {
		foreach ($dep in $script:configurationLegacyDeps) {
			if ($have.Contains($dep)) { continue }
			$have[$dep] = @{ Name = $dep; Value = "true"; Condition = $null }
			$added += $dep
		}
	}
	$result = @()
	foreach ($k in $have.Keys) { $result += ,$have[$k] }
	return @{ Rights = $result; Added = $added }
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

function Resolve-TextFromFile {
	param([string]$val, [string]$baseDir)
	if (-not $val.StartsWith("@")) { return $val }
	$filePath = $val.Substring(1)
	if ([System.IO.Path]::IsPathRooted($filePath)) {
		$candidates = @($filePath)
	} else {
		$candidates = @(
			(Join-Path $baseDir $filePath),
			(Join-Path (Get-Location).Path $filePath)
		)
	}
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			return (Get-Content -Raw -Encoding UTF8 $c).TrimEnd()
		}
	}
	Write-Error "Файл значения не найден: $filePath (искали: $($candidates -join ', '))"
	exit 1
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

# --- XML manipulation helpers (from meta-edit pattern) ---
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

function Import-Fragment([string]$xmlString) {
	$wrapper = "<_W xmlns=`"$($script:mdNs)`" xmlns:xsi=`"$($script:xsiNs)`" xmlns:v8=`"$($script:v8Ns)`" xmlns:xr=`"$($script:xrNs)`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`">$xmlString</_W>"
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$nodes = @()
	foreach ($child in $frag.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $script:xmlDoc.ImportNode($child, $true)
		}
	}
	return ,$nodes
}

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			if ($child.Value -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($child.Value -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	$depth = 0; $current = $container
	while ($current -and $current -ne $script:xmlDoc.DocumentElement) { $depth++; $current = $current.ParentNode }
	return "`t" * ($depth + 1)
}

function Insert-BeforeElement($container, $newNode, $refNode, $childIndent) {
	$ws = $script:xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $ws) | Out-Null
	} else {
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$container.InsertBefore($ws, $trailing) | Out-Null
			$container.InsertBefore($newNode, $trailing) | Out-Null
		} else {
			$container.AppendChild($ws) | Out-Null
			$container.AppendChild($newNode) | Out-Null
			$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
			$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
			$container.AppendChild($closeWs) | Out-Null
		}
	}
}

function Remove-NodeWithWhitespace($node) {
	$parent = $node.ParentNode
	$prev = $node.PreviousSibling
	$next = $node.NextSibling
	if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($prev) | Out-Null
	} elseif ($next -and ($next.NodeType -eq 'Whitespace' -or $next.NodeType -eq 'SignificantWhitespace')) {
		$parent.RemoveChild($next) | Out-Null
	}
	$parent.RemoveChild($node) | Out-Null
}

function Expand-SelfClosingElement($container, $parentIndent) {
	# If the element is self-closing (empty), add whitespace for children
	if (-not $container.HasChildNodes -or $container.IsEmpty) {
		$childIndent = "$parentIndent`t"
		# The element is self-closing; we need to add something to make it non-empty
		# Adding a whitespace node will force opening+closing tags
		$closeWs = $script:xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

function Detect-XmlStyle([string]$path) {
	if (-not (Test-Path -LiteralPath $path)) { return $null }
	$raw = [System.IO.File]::ReadAllBytes($path)
	$bom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
	$body = if ($bom) { [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3) } else { [System.Text.Encoding]::UTF8.GetString($raw) }
	$head = if ($body.Length -gt 200) { $body.Substring(0, 200) } else { $body }
	$m = [regex]::Match($head, 'encoding="([^"]+)"')
	return @{
		bom = $bom
		crlf = $body.Contains("`r`n")
		enc = $(if ($m.Success) { $m.Groups[1].Value } else { "utf-8" })
		finalNl = $body.EndsWith("`n")
	}
}

# Привести текст XmlWriter к стилю оригинала; для НОВОГО файла ($null) — к канону выгрузки
# Конфигуратора: encoding="UTF-8", CRLF, без перевода строки в конце.
# Реестр семьи: tests/skills/check-inline-drift.mjs.
function Finalize-XmlText([string]$text, $style) {
	if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
	$encDecl = $(if ($style) { $style.enc } else { "UTF-8" })
	$text = $text.Replace('encoding="utf-8"', 'encoding="' + $encDecl + '"')
	# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
	# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
	# поэтому они идут первыми ветками альтернации и возвращаются как есть.
	$text = [regex]::Replace($text, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
	$text = ($text -replace "`r`n", "`n").TrimEnd("`n")
	if ($style -and $style.finalNl) { $text += "`n" }
	if (-not $style -or $style.crlf) { $text = $text -replace "`n", "`r`n" }
	return $text
}

# --- Пространства имён (Import-Fragment собирает узлы в них) ---
$script:mdNs = "http://v8.1c.ru/8.2/roles"
$script:xsiNs = "http://www.w3.org/2001/XMLSchema-instance"
$script:v8Ns = "http://v8.1c.ru/8.1/data/core"
$script:xrNs = "http://v8.1c.ru/8.3/xcf/readable"
$script:mdObjectNs = "http://v8.1c.ru/8.3/MDClasses"

# --- Стандартные реквизиты в списке полей RLS платформа пишет по-английски ---
$script:fieldAliases = @{
	"Ссылка"="Ref"; "Код"="Code"; "Наименование"="Description"; "Родитель"="Parent"
	"Владелец"="Owner"; "Дата"="Date"; "Номер"="Number"; "ПометкаУдаления"="DeletionMark"
	"ЭтоГруппа"="IsFolder"; "Проведен"="Posted"; "Проведён"="Posted"; "ВерсияДанных"="DataVersion"
	"Предопределенный"="Predefined"; "Предопределённый"="Predefined"
}

function Translate-FieldName([string]$name) {
	foreach ($key in $script:fieldAliases.Keys) {
		if ([string]::Equals($key, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $script:fieldAliases[$key] }
	}
	return $name
}

# --- Резолв пути роли ---
# Принимаем всё, чем роль называют в обиходе: каталог роли, файл метаданных, сам Rights.xml.
function Resolve-RolePaths([string]$inputPath) {
	if (-not (Test-Path -LiteralPath $inputPath)) {
		[Console]::Error.WriteLine("[role-edit] Путь не найден: $inputPath")
		exit 1
	}
	$full = (Resolve-Path -LiteralPath $inputPath).Path
	$rightsPath = $null
	if (Test-Path -LiteralPath $full -PathType Leaf) {
		$leaf = [System.IO.Path]::GetFileName($full)
		if ($leaf -eq 'Rights.xml') { $rightsPath = $full }
		else {
			# Roles/Имя.xml — рядом лежит каталог Имя/Ext/Rights.xml
			$dir = [System.IO.Path]::GetDirectoryName($full)
			$name = [System.IO.Path]::GetFileNameWithoutExtension($full)
			$rightsPath = Join-Path (Join-Path (Join-Path $dir $name) "Ext") "Rights.xml"
		}
	} else {
		foreach ($candidate in @((Join-Path (Join-Path $full "Ext") "Rights.xml"), (Join-Path $full "Rights.xml"))) {
			if (Test-Path -LiteralPath $candidate) { $rightsPath = $candidate; break }
		}
	}
	if (-not $rightsPath -or -not (Test-Path -LiteralPath $rightsPath)) {
		[Console]::Error.WriteLine("[role-edit] Rights.xml не найден для пути: $inputPath")
		[Console]::Error.WriteLine("  Ожидается каталог роли, Roles/Имя.xml или Roles/Имя/Ext/Rights.xml.")
		exit 1
	}
	$rightsPath = (Resolve-Path -LiteralPath $rightsPath).Path
	# Rights.xml лежит в <Roles>/<Имя>/Ext/, метаданные — в <Roles>/<Имя>.xml
	$roleDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($rightsPath))
	$roleName = [System.IO.Path]::GetFileName($roleDir)
	$rolesDir = [System.IO.Path]::GetDirectoryName($roleDir)
	return @{
		RightsPath = $rightsPath
		RoleXmlPath = Join-Path $rolesDir "$roleName.xml"
		RoleName = $roleName
		ConfigRoot = [System.IO.Path]::GetDirectoryName($rolesDir)
	}
}

$script:paths = Resolve-RolePaths $RolePath
$script:rightsPath = $script:paths.RightsPath
$script:roleXmlPath = $script:paths.RoleXmlPath
$script:configRoot = $script:paths.ConfigRoot

if ($DefinitionFile -and $Operation) {
	[Console]::Error.WriteLine("[role-edit] Укажите либо -DefinitionFile, либо -Operation, но не оба сразу")
	exit 1
}
if (-not $DefinitionFile -and -not $Operation) {
	[Console]::Error.WriteLine("[role-edit] Укажите -Operation с -Value или -DefinitionFile")
	exit 1
}

# База относительного пути @файла: каталог списка операций, иначе каталог самой роли.
# Текущий каталог функция проверяет вторым кандидатом в любом случае.
$script:textBaseDir = if ($DefinitionFile) { [System.IO.Path]::GetDirectoryName((Resolve-Path $DefinitionFile).Path) }
                      else { [System.IO.Path]::GetDirectoryName($script:paths.RightsPath) }

$targetForGuard = if (Test-Path -LiteralPath $script:roleXmlPath) { $script:roleXmlPath } else { $script:rightsPath }
Assert-EditAllowed $targetForGuard 'editable'

# --- Загрузка XML ---
$script:xmlDoc = New-Object System.Xml.XmlDocument
$script:xmlDoc.PreserveWhitespace = $true
$script:xmlDoc.Load($script:rightsPath)
$script:root = $script:xmlDoc.DocumentElement
$script:ns = New-Object System.Xml.XmlNamespaceManager($script:xmlDoc.NameTable)
$script:ns.AddNamespace("rt", $script:mdNs)
$script:formatVersion = if ($script:root.HasAttribute("version")) { $script:root.GetAttribute("version") } else { "2.17" }
$script:formatRank = Get-FormatRank $script:formatVersion
# Умолчания роли решают, какие записи платформа хранит: совпавшее с умолчанием она выбрасывает.
$script:roleSfno = $script:root.SelectSingleNode("rt:setForNewObjects", $script:ns).InnerText
$script:roleSfab = $script:root.SelectSingleNode("rt:setForAttributesByDefault", $script:ns).InnerText
$script:droppedByDefault = @()

function Test-RightStored {
	param([string]$objName, [string]$rightName, [string]$value)
	$default = Get-DefaultRightValue $objName $script:roleSfno $script:roleSfab
	if ($value -ne $default) { return $true }
	$script:droppedByDefault += "$objName.$rightName"
	return $false
}

$script:addCount = 0
$script:removeCount = 0
$script:modifyCount = 0
$script:rightsDirty = $false
$script:metaDirty = $false
$script:notes = @()

function Add-Note([string]$text) { $script:notes += $text }

# --- Разбор значений операций ---

function Parse-BatchValue([string]$val) {
	# Делим ДО чтения файлов, поэтому ';;' внутри условия из файла разделителем не становится.
	return @($val -split ';;' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Адрес и значение разделяет первое ':' вне скобок: в адресе двоеточия не бывает,
# а в условии RLS встречается и оно, и '['.
function Split-AtTopLevelColon([string]$text, [char]$openChar, [char]$closeChar) {
	$depth = 0
	for ($i = 0; $i -lt $text.Length; $i++) {
		$ch = $text[$i]
		if ($ch -eq $openChar) { $depth++ }
		elseif ($ch -eq $closeChar) { if ($depth -gt 0) { $depth-- } }
		elseif ($ch -eq ':' -and $depth -eq 0) {
			return @{ Left = $text.Substring(0, $i).Trim(); Right = $text.Substring($i + 1).Trim(); Found = $true }
		}
	}
	return @{ Left = $text.Trim(); Right = ""; Found = $false }
}

# "Тип.Имя: Право1, Право2" или "Тип.Имя: @пресет"; без двоеточия — только имя объекта.
function Parse-RightsSpec([string]$text, [switch]$AllowNoRights) {
	$split = Split-AtTopLevelColon $text '[' ']'
	if (-not $split.Found) {
		if (-not $AllowNoRights) {
			Add-ValidationError "$text : ожидается 'Тип.Имя: Право1, Право2' или 'Тип.Имя: @пресет'"
			return $null
		}
		$objName = Translate-ObjectName $split.Left
		if (-not (Validate-ObjectName $objName)) { return $null }
		return @{ Name = $objName; Rights = @() }
	}
	$objName = Translate-ObjectName $split.Left
	if (-not (Validate-ObjectName $objName)) { return $null }
	$objectType = Get-ObjectType $objName
	$rightsStr = $split.Right
	$rightNames = @()
	if ($rightsStr.StartsWith('@')) {
		$rightNames = @(Resolve-Preset -objectType $objectType -presetName $rightsStr)
	} else {
		$rightNames = @($rightsStr -split ',\s*' | ForEach-Object { Translate-RightName $_.Trim() } | Where-Object { $_ })
	}
	$valid = @()
	foreach ($r in $rightNames) {
		if (Validate-RightName -objectName $objName -rightName $r) { $valid += $r }
	}
	return @{ Name = $objName; Rights = $valid }
}

# "Тип.Имя.Право[Поле1, Поле2]: условие" — поля необязательны, условие может быть пустым.
function Parse-RlsAddress([string]$text, [switch]$ConditionRequired) {
	$split = Split-AtTopLevelColon $text '[' ']'
	$address = $split.Left
	$condition = $split.Right
	if ($ConditionRequired -and -not $split.Found) {
		Add-ValidationError "$text : ожидается 'Тип.Имя.Право: условие' (условие может быть пустым)"
		return $null
	}
	$fields = @()
	if ($address.EndsWith(']')) {
		$open = $address.LastIndexOf('[')
		if ($open -lt 0) {
			Add-ValidationError "$text : не закрыта скобка списка полей"
			return $null
		}
		$fieldsPart = $address.Substring($open + 1, $address.Length - $open - 2)
		$address = $address.Substring(0, $open).Trim()
		$fields = @($fieldsPart -split ',' | ForEach-Object { Translate-FieldName $_.Trim() } | Where-Object { $_ })
		if ($fields.Count -eq 0) {
			Add-ValidationError "$text : пустой список полей — уберите скобки, если ограничение на все поля"
			return $null
		}
	}
	$lastDot = $address.LastIndexOf('.')
	if ($lastDot -lt 1) {
		Add-ValidationError "$text : ожидается 'Тип.Имя.Право', последний сегмент — имя права"
		return $null
	}
	$objName = Translate-ObjectName $address.Substring(0, $lastDot)
	$rightName = Translate-RightName $address.Substring($lastDot + 1)
	if (-not (Validate-ObjectName $objName)) { return $null }
	if (-not (Validate-RightName -objectName $objName -rightName $rightName)) {
		# Показываем разбор: иначе непонятно, что навык откусил не тот сегмент.
		Add-ValidationError "$text : разобрано как объект '$objName' и право '$rightName'"
		return $null
	}
	return @{ Object = $objName; Right = $rightName; Fields = $fields; Condition = (Resolve-TextFromFile $condition $script:textBaseDir) }
}

# "Имя(Пар1, Пар2): условие" — скобки принадлежат имени шаблона, разделитель ищем вне них.
function Parse-TemplateSpec([string]$text, [switch]$NameOnly) {
	$split = Split-AtTopLevelColon $text '(' ')'
	if ($NameOnly) { return @{ Name = $split.Left; Condition = $null } }
	if (-not $split.Found) {
		Add-ValidationError "$text : ожидается 'Имя(Параметры): условие'"
		return $null
	}
	return @{ Name = $split.Left; Condition = (Resolve-TextFromFile $split.Right $script:textBaseDir) }
}

# --- Доступ к дереву прав ---

function Get-ObjectNodes() { return @($script:root.SelectNodes("rt:object", $script:ns)) }

function Get-ObjectNodeName($objNode) {
	$nameNode = $objNode.SelectSingleNode("rt:name", $script:ns)
	if ($nameNode) { return $nameNode.InnerText } else { return "" }
}

function Find-ObjectNode([string]$name) {
	foreach ($node in Get-ObjectNodes) {
		if ([string]::Equals((Get-ObjectNodeName $node), $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $node }
	}
	return $null
}

function Get-RightNodes($objNode) { return @($objNode.SelectNodes("rt:right", $script:ns)) }

function Get-RightNodeName($rightNode) {
	$nameNode = $rightNode.SelectSingleNode("rt:name", $script:ns)
	if ($nameNode) { return $nameNode.InnerText } else { return "" }
}

function Get-RightNodeValue($rightNode) {
	$valueNode = $rightNode.SelectSingleNode("rt:value", $script:ns)
	if ($valueNode) { return $valueNode.InnerText } else { return "" }
}

function Find-RightNode($objNode, [string]$rightName) {
	foreach ($node in Get-RightNodes $objNode) {
		if ([string]::Equals((Get-RightNodeName $node), $rightName, [System.StringComparison]::OrdinalIgnoreCase)) { return $node }
	}
	return $null
}

function Get-TrueRightNames($objNode) {
	$names = @()
	foreach ($node in Get-RightNodes $objNode) {
		if ((Get-RightNodeValue $node) -eq 'true') { $names += (Get-RightNodeName $node) }
	}
	return $names
}

# Порядок прав внутри узла у платформы фиксирован для типа — новое право встаёт на своё место,
# соседей не трогаем.
function Insert-RightCanonical($objNode, $newNode, [string]$objName) {
	$parts = $objName -split '\.'
	$order = if ($parts.Count -ge 3) { $script:nestedRightOrder[$parts[$parts.Count-2]] } else { $script:rightOrder[$parts[0]] }
	$newName = Get-RightNodeName $newNode
	$refNode = $null
	if ($order) {
		$newIndex = [array]::IndexOf($order, $newName)
		if ($newIndex -ge 0) {
			foreach ($node in Get-RightNodes $objNode) {
				$idx = [array]::IndexOf($order, (Get-RightNodeName $node))
				if ($idx -gt $newIndex) { $refNode = $node; break }
			}
		}
	}
	$indent = Get-ChildIndent $objNode
	Insert-BeforeElement $objNode $newNode $refNode $indent
}

function New-RightNode([string]$name, [string]$value, [string]$indent) {
	$xml = "<right>`r`n$indent`t<name>$(Esc-XmlText $name)</name>`r`n$indent`t<value>$value</value>`r`n$indent</right>"
	$nodes = Import-Fragment $xml
	return $nodes[0]
}

# Узлы <object> платформа держит в порядке uuid объекта метаданных — вставляем на то же место.
function Insert-ObjectNode($newNode, [string]$objName) {
	$indent = Get-ChildIndent $script:root
	$uuid = Get-RightsObjectUuid -objName $objName -configRoot $script:configRoot
	$refNode = $null
	if ($uuid) {
		foreach ($node in Get-ObjectNodes) {
			$otherUuid = Get-RightsObjectUuid -objName (Get-ObjectNodeName $node) -configRoot $script:configRoot
			if ($otherUuid -and [string]::CompareOrdinal($otherUuid, $uuid) -gt 0) { $refNode = $node; break }
		}
	} elseif (-not (Test-StandardKind $objName)) {
		Add-Note "[WARN] ${objName}: объект не найден в выгрузке, uuid неизвестен — узел записан перед шаблонами (платформа переставит его при первой выгрузке)"
	}
	if (-not $refNode) {
		$templates = @($script:root.SelectNodes("rt:restrictionTemplate", $script:ns))
		if ($templates.Count -gt 0) { $refNode = $templates[0] }
	}
	Insert-BeforeElement $script:root $newNode $refNode $indent
}

function New-ObjectNode([string]$objName) {
	$indent = Get-ChildIndent $script:root
	$xml = "<object>`r`n$indent`t<name>$(Esc-XmlText $objName)</name>`r`n$indent</object>"
	$nodes = Import-Fragment $xml
	return $nodes[0]
}

# Пустых узлов платформа не производит. Узел с одними запретами — производит (так закрывают
# реквизит), поэтому смотрим на наличие прав вообще, а не только разрешающих.
function Remove-ObjectIfEmpty($objNode) {
	# @() на месте использования: return из функции разворачивает массив из одного элемента,
	# и .Count у него $null — узел с единственным правом считался бы пустым.
	if (@(Get-RightNodes $objNode).Count -gt 0) { return $false }
	$name = Get-ObjectNodeName $objNode
	Remove-NodeWithWhitespace $objNode
	Add-Note "     ${name}: прав не осталось — узел объекта удалён"
	return $true
}

# --- Зависимости: прямое замыкание для выдачи, обратное — для снятия и запрета ---

function Get-DirectDeps([string]$objectType, [string]$rightName) {
	$byType = $script:rightDepsByType[$objectType]
	if ($byType -and $byType.Contains($rightName)) { return $byType[$rightName] }
	$deps = $script:rightDeps[$rightName]
	if ($deps) { return $deps }
	return @()
}

function Get-AllowedRights([string]$objName) {
	$parts = $objName -split '\.'
	if ($parts.Count -ge 3) { return (Get-NestedRights -objectType $parts[0] -kind (Get-NestedKind $objName)) }
	return $script:knownRights[$parts[0]]
}

function Get-DependentRights([string]$objName, [string]$rightName) {
	# Кто требует это право: снимаем его — обязаны снять и их, иначе платформа вернёт снятое.
	# У вложенных объектов это работает и для запретов: View=false тянет Edit=false.
	$parts = $objName -split '\.'
	$objectType = $parts[0]
	$allowed = Get-AllowedRights $objName
	if (-not $allowed) { return @() }
	$result = @()
	$queue = @($rightName)
	while ($queue.Count -gt 0) {
		$current = $queue[0]
		$queue = @($queue | Select-Object -Skip 1)
		foreach ($candidate in $allowed) {
			if ($result -contains $candidate -or $candidate -eq $rightName) { continue }
			if ((Get-DirectDeps $objectType $candidate) -contains $current) {
				$result += $candidate
				$queue += $candidate
			}
		}
	}
	return $result
}

# --- Операции ---

function Do-AddRights([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RightsSpec $item
		if (-not $spec) { continue }
		foreach ($expanded in (Expand-ServiceEntry -parsed @{ Name = $spec.Name; Rights = @($spec.Rights | ForEach-Object { @{ Name = $_; Value = "true"; Condition = $null } }) } -configRoot $script:configRoot -name $script:paths.RoleName)) {
			$script:pending += ,@{ Kind = 'add-rights'; Spec = @{ Name = $expanded.Name; Rights = @($expanded.Rights | ForEach-Object { $_.Name }) } }
		}
	}
}

function Apply-AddRights($spec) {
	$objNode = Find-ObjectNode $spec.Name
	$created = $false
	if (-not $objNode) {
		$objNode = New-ObjectNode $spec.Name
		Insert-ObjectNode $objNode $spec.Name
		$created = $true
	}
	$existing = @()
	foreach ($node in Get-RightNodes $objNode) { $existing += (Get-RightNodeName $node) }
	$wanted = @($spec.Rights)
	# Платформа при загрузке всё равно доведёт набор до замыкания — пишем его сразу.
	$closure = Close-RightsDependencies -objName $spec.Name -rights @(($existing + $wanted | Select-Object -Unique) | ForEach-Object { @{ Name = $_; Value = "true"; Condition = $null } }) -formatRank $script:formatRank
	$final = @($closure.Rights | ForEach-Object { $_.Name })
	$added = @()
	$indent = Get-ChildIndent $objNode
	foreach ($rightName in $final) {
		if (-not (Test-RightStored $spec.Name $rightName 'true')) { continue }
		$node = Find-RightNode $objNode $rightName
		if ($node) {
			if ((Get-RightNodeValue $node) -ne 'true') {
				$node.SelectSingleNode("rt:value", $script:ns).InnerText = 'true'
				$added += $rightName
				$script:modifyCount++
				$script:rightsDirty = $true
			}
			continue
		}
		$new = New-RightNode $rightName 'true' $indent
		Insert-RightCanonical $objNode $new $spec.Name
		$added += $rightName
		$script:addCount++
		$script:rightsDirty = $true
	}
	if ($created -and $added.Count -eq 0) {
		Remove-NodeWithWhitespace $objNode
		return
	}
	if ($added.Count -gt 0) {
		$extra = @($added | Where-Object { $wanted -notcontains $_ })
		$note = "     $($spec.Name): добавлено — $($added -join ', ')"
		if ($extra.Count -gt 0) { $note += " (по зависимости: $($extra -join ', '))" }
		Add-Note $note
	} else {
		Add-Note "     $($spec.Name): права уже выданы, изменений нет"
	}
}

function Do-SetRights([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RightsSpec $item
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'set-rights'; Spec = $spec }
	}
}

function Apply-SetRights($spec) {
	$objNode = Find-ObjectNode $spec.Name
	if (-not $objNode) {
		Apply-AddRights $spec
		return
	}
	$droppedRls = 0
	foreach ($node in Get-RightNodes $objNode) {
		if ($node.SelectSingleNode("rt:restrictionByCondition", $script:ns)) { $droppedRls++ }
		Remove-NodeWithWhitespace $node
		$script:removeCount++
	}
	$closure = Close-RightsDependencies -objName $spec.Name -rights @($spec.Rights | ForEach-Object { @{ Name = $_; Value = "true"; Condition = $null } }) -formatRank $script:formatRank
	$indent = Get-ChildIndent $objNode
	foreach ($rightName in @($closure.Rights | ForEach-Object { $_.Name })) {
		if (-not (Test-RightStored $spec.Name $rightName 'true')) { continue }
		$new = New-RightNode $rightName 'true' $indent
		Insert-RightCanonical $objNode $new $spec.Name
		$script:addCount++
	}
	$script:rightsDirty = $true
	Add-Note "     $($spec.Name): набор прав заменён"
	if ($droppedRls -gt 0) { Add-Note "[WARN] $($spec.Name): снято ограничений RLS: $droppedRls" }
	Remove-ObjectIfEmpty $objNode | Out-Null
}

function Do-RemoveRights([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RightsSpec $item -AllowNoRights
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'remove-rights'; Spec = $spec }
	}
}

function Apply-RemoveRights($spec) {
	$objNode = Find-ObjectNode $spec.Name
	if (-not $objNode) {
		Add-Note "     $($spec.Name): объекта нет в роли, пропуск"
		return
	}
	if ($spec.Rights.Count -eq 0) {
		Remove-NodeWithWhitespace $objNode
		$script:removeCount++
		$script:rightsDirty = $true
		Add-Note "     $($spec.Name): узел объекта удалён"
		return
	}
	# Каскад: право, которое требует снимаемое, платформа вернула бы обратно.
	$toRemove = @()
	foreach ($rightName in $spec.Rights) {
		$toRemove += $rightName
		foreach ($dependent in (Get-DependentRights $spec.Name $rightName)) {
			if ($toRemove -notcontains $dependent) { $toRemove += $dependent }
		}
	}
	$removed = @()
	foreach ($rightName in $toRemove) {
		$node = Find-RightNode $objNode $rightName
		if (-not $node) { continue }
		Remove-NodeWithWhitespace $node
		$removed += $rightName
		$script:removeCount++
		$script:rightsDirty = $true
	}
	if ($removed.Count -eq 0) {
		Add-Note "     $($spec.Name): перечисленных прав нет, изменений нет"
		return
	}
	$cascade = @($removed | Where-Object { $spec.Rights -notcontains $_ })
	$note = "     $($spec.Name): снято — $($removed -join ', ')"
	if ($cascade.Count -gt 0) { $note += " (каскадом: $($cascade -join ', '))" }
	Add-Note $note
	Remove-ObjectIfEmpty $objNode | Out-Null
}

function Do-DenyRights([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RightsSpec $item
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'deny-rights'; Spec = $spec }
	}
}

function Apply-DenyRights($spec) {
	$objNode = Find-ObjectNode $spec.Name
	$created = $false
	if (-not $objNode) {
		$objNode = New-ObjectNode $spec.Name
		Insert-ObjectNode $objNode $spec.Name
		$created = $true
	}
	$toDeny = @()
	foreach ($rightName in $spec.Rights) {
		$toDeny += $rightName
		foreach ($dependent in (Get-DependentRights $spec.Name $rightName)) {
			if ($toDeny -notcontains $dependent) { $toDeny += $dependent }
		}
	}
	$denied = @()
	$indent = Get-ChildIndent $objNode
	foreach ($rightName in $toDeny) {
		if (-not (Test-RightStored $spec.Name $rightName 'false')) { continue }
		$node = Find-RightNode $objNode $rightName
		if ($node) {
			if ((Get-RightNodeValue $node) -eq 'false') { continue }
			$node.SelectSingleNode("rt:value", $script:ns).InnerText = 'false'
			$script:modifyCount++
		} else {
			$new = New-RightNode $rightName 'false' $indent
			Insert-RightCanonical $objNode $new $spec.Name
			$script:addCount++
		}
		$denied += $rightName
		$script:rightsDirty = $true
	}
	if ($denied.Count -eq 0) {
		if ($created) { Remove-NodeWithWhitespace $objNode }
		$reason = if (@($script:droppedByDefault | Where-Object { $_.StartsWith("$($spec.Name).") }).Count -gt 0) { "запрет совпадает с умолчанием роли и платформой не хранится" } else { "права уже запрещены" }
		Add-Note "     $($spec.Name): $reason, изменений нет"
		return
	}
	$cascade = @($denied | Where-Object { $spec.Rights -notcontains $_ })
	$note = "     $($spec.Name): запрещено — $($denied -join ', ')"
	if ($cascade.Count -gt 0) { $note += " (каскадом: $($cascade -join ', '))" }
	Add-Note $note
}

# --- RLS ---

function Get-RestrictionFields($restrictionNode) {
	$fields = @()
	foreach ($node in @($restrictionNode.SelectNodes("rt:field", $script:ns))) { $fields += $node.InnerText }
	return $fields
}

function Test-SameFieldSet($a, $b) {
	if ($a.Count -ne $b.Count) { return $false }
	$left = @($a | Sort-Object)
	$right = @($b | Sort-Object)
	for ($i = 0; $i -lt $left.Count; $i++) {
		if (-not [string]::Equals($left[$i], $right[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
	}
	return $true
}

function New-RestrictionNode([string]$indent, $fields, [string]$condition) {
	# Поля платформа держит отсортированными ordinal, условие без полей идёт первой строкой.
	$sorted = @($fields | Sort-Object -Property @{ Expression = { $_ } })
	if ($sorted.Count -gt 1) {
		$arr = [string[]]$sorted
		[Array]::Sort($arr, [System.StringComparer]::Ordinal)
		$sorted = $arr
	}
	$inner = ""
	foreach ($field in $sorted) { $inner += "$indent`t<field>$(Esc-XmlText $field)</field>`r`n" }
	if ($condition) { $inner += "$indent`t<condition>$(Esc-XmlText $condition)</condition>`r`n" }
	else { $inner += "$indent`t<condition/>`r`n" }
	$xml = "<restrictionByCondition>`r`n$inner$indent</restrictionByCondition>"
	$nodes = Import-Fragment $xml
	return $nodes[0]
}

function Do-SetRls([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RlsAddress $item -ConditionRequired
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'set-rls'; Spec = $spec }
	}
}

function Apply-SetRls($spec) {
	$objNode = Find-ObjectNode $spec.Object
	if (-not $objNode) {
		Add-ValidationError "$($spec.Object).$($spec.Right): право не выдано — сначала add-rights, ограничение без права платформа игнорирует"
		return
	}
	$rightNode = Find-RightNode $objNode $spec.Right
	if (-not $rightNode -or (Get-RightNodeValue $rightNode) -ne 'true') {
		Add-ValidationError "$($spec.Object).$($spec.Right): право не выдано — сначала add-rights, ограничение без права платформа игнорирует"
		return
	}
	$indent = (Get-ChildIndent $objNode) + "`t"
	$existing = @($rightNode.SelectNodes("rt:restrictionByCondition", $script:ns))
	$target = $null
	foreach ($node in $existing) {
		if (Test-SameFieldSet (Get-RestrictionFields $node) $spec.Fields) { $target = $node; break }
	}
	# Ссылка на шаблон, которого в роли нет, — тихая ошибка в рантайме 1С. Отказывать нельзя:
	# шаблон могут добавить следующей операцией или следующим вызовом.
	foreach ($m in [regex]::Matches("$($spec.Condition)", '#([A-Za-zА-Яа-яЁё0-9_]+)\s*\(')) {
		$templateName = $m.Groups[1].Value
		if ($templateName -in @('Если', 'Тогда', 'Иначе', 'КонецЕсли')) { continue }
		if (-not (Find-TemplateNode $templateName)) {
			[Console]::Error.WriteLine("[role-edit] $($spec.Object).$($spec.Right): условие ссылается на шаблон '$templateName', которого в роли нет")
		}
	}
	$new = New-RestrictionNode $indent $spec.Fields $spec.Condition
	if ($target) {
		$rightNode.ReplaceChild($new, $target) | Out-Null
		$script:modifyCount++
		Add-Note "     $($spec.Object).$($spec.Right): ограничение заменено"
	} else {
		# Строка без полей («прочие поля») идёт первой, строки с полями — после неё.
		$refNode = $null
		if ($spec.Fields.Count -eq 0) {
			foreach ($node in $existing) { if (@(Get-RestrictionFields $node).Count -gt 0) { $refNode = $node; break } }
		}
		Insert-BeforeElement $rightNode $new $refNode $indent
		$script:addCount++
		Add-Note "     $($spec.Object).$($spec.Right): ограничение добавлено"
	}
	$script:rightsDirty = $true
}

function Do-RemoveRls([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-RlsAddress $item
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'remove-rls'; Spec = $spec }
	}
}

function Apply-RemoveRls($spec) {
	$objNode = Find-ObjectNode $spec.Object
	if (-not $objNode) {
		Add-Note "     $($spec.Object): объекта нет в роли, пропуск"
		return
	}
	$rightNode = Find-RightNode $objNode $spec.Right
	if (-not $rightNode) {
		Add-Note "     $($spec.Object).$($spec.Right): права нет в роли, пропуск"
		return
	}
	$removed = 0
	foreach ($node in @($rightNode.SelectNodes("rt:restrictionByCondition", $script:ns))) {
		# Адрес без скобок снимает все ограничения права, со скобками — строку с этим набором полей.
		if (@($spec.Fields).Count -gt 0 -and -not (Test-SameFieldSet (Get-RestrictionFields $node) $spec.Fields)) { continue }
		Remove-NodeWithWhitespace $node
		$removed++
	}
	if ($removed -eq 0) {
		Add-Note "     $($spec.Object).$($spec.Right): ограничений нет, изменений нет"
		return
	}
	$script:removeCount += $removed
	$script:rightsDirty = $true
	Add-Note "     $($spec.Object).$($spec.Right): снято ограничений — $removed"
}

# --- Шаблоны RLS ---

function Get-TemplateNodes() { return @($script:root.SelectNodes("rt:restrictionTemplate", $script:ns)) }

function Get-TemplateIdentifier([string]$name) {
	$paren = $name.IndexOf('(')
	if ($paren -gt 0) { return $name.Substring(0, $paren).Trim() }
	return $name.Trim()
}

function Find-TemplateNode([string]$name) {
	$wanted = Get-TemplateIdentifier $name
	foreach ($node in Get-TemplateNodes) {
		$nameNode = $node.SelectSingleNode("rt:name", $script:ns)
		if (-not $nameNode) { continue }
		if ([string]::Equals((Get-TemplateIdentifier $nameNode.InnerText), $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $node }
	}
	return $null
}

function New-TemplateNode([string]$indent, [string]$name, [string]$condition) {
	$xml = "<restrictionTemplate>`r`n$indent`t<name>$(Esc-XmlText $name)</name>`r`n$indent`t<condition>$(Esc-XmlText $condition)</condition>`r`n$indent</restrictionTemplate>"
	$nodes = Import-Fragment $xml
	return $nodes[0]
}

function Do-AddTemplate([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-TemplateSpec $item
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'add-template'; Spec = $spec }
	}
}

function Apply-AddTemplate($spec, [switch]$AllowReplace) {
	$existing = Find-TemplateNode $spec.Name
	if ($existing -and -not $AllowReplace) {
		Add-ValidationError "$($spec.Name): шаблон с таким именем уже есть — используйте set-template"
		return
	}
	$indent = Get-ChildIndent $script:root
	$new = New-TemplateNode $indent $spec.Name $spec.Condition
	if ($existing) {
		$script:root.ReplaceChild($new, $existing) | Out-Null
		$script:modifyCount++
		Add-Note "     $($spec.Name): шаблон заменён"
	} else {
		Insert-BeforeElement $script:root $new $null $indent
		$script:addCount++
		Add-Note "     $($spec.Name): шаблон добавлен"
	}
	$script:rightsDirty = $true
}

function Do-SetTemplate([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-TemplateSpec $item
		if (-not $spec) { continue }
		$script:pending += ,@{ Kind = 'set-template'; Spec = $spec }
	}
}

function Do-RemoveTemplate([string]$batchVal) {
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$spec = Parse-TemplateSpec $item -NameOnly
		$script:pending += ,@{ Kind = 'remove-template'; Spec = $spec }
	}
}

function Apply-RemoveTemplate($spec) {
	$node = Find-TemplateNode $spec.Name
	if (-not $node) {
		Add-Note "     $($spec.Name): шаблона нет в роли, пропуск"
		return
	}
	# Ссылка на удалённый шаблон — тихая ошибка в рантайме, поэтому показываем, кто им пользуется.
	$identifier = Get-TemplateIdentifier $spec.Name
	$users = @()
	foreach ($objNode in Get-ObjectNodes) {
		foreach ($rightNode in Get-RightNodes $objNode) {
			foreach ($restriction in @($rightNode.SelectNodes("rt:restrictionByCondition", $script:ns))) {
				$conditionNode = $restriction.SelectSingleNode("rt:condition", $script:ns)
				if ($conditionNode -and $conditionNode.InnerText -match "#$([regex]::Escape($identifier))\s*\(") {
					$users += "$(Get-ObjectNodeName $objNode).$(Get-RightNodeName $rightNode)"
				}
			}
		}
	}
	Remove-NodeWithWhitespace $node
	$script:removeCount++
	$script:rightsDirty = $true
	Add-Note "     $($spec.Name): шаблон удалён"
	if ($users.Count -gt 0) {
		[Console]::Error.WriteLine("[role-edit] На шаблон '$identifier' ещё ссылаются: $($users -join ', ')")
	}
}

# --- Глобальные флаги ---

function Do-ModifyProperty([string]$batchVal) {
	$allowed = @("setForNewObjects", "setForAttributesByDefault", "independentRightsOfChildObjects")
	foreach ($item in (Parse-BatchValue $batchVal)) {
		$eq = $item.IndexOf('=')
		if ($eq -lt 1) {
			Add-ValidationError "$item : ожидается 'свойство=true' или 'свойство=false'"
			continue
		}
		$name = $item.Substring(0, $eq).Trim()
		$value = $item.Substring($eq + 1).Trim().ToLower()
		$canonical = $allowed | Where-Object { [string]::Equals($_, $name, [System.StringComparison]::OrdinalIgnoreCase) }
		if (-not $canonical) {
			Add-ValidationError "$name : неизвестное свойство роли, допустимы $($allowed -join ', ')"
			continue
		}
		if ($value -ne 'true' -and $value -ne 'false') {
			Add-ValidationError "$item : значение должно быть true или false"
			continue
		}
		$script:pending += ,@{ Kind = 'modify-property'; Spec = @{ Name = $canonical; Value = $value } }
	}
}

function Apply-ModifyProperty($spec) {
	$node = $script:root.SelectSingleNode("rt:$($spec.Name)", $script:ns)
	if (-not $node) {
		Add-Note "[WARN] $($spec.Name): свойства нет в файле роли, пропуск"
		return
	}
	if ($node.InnerText -eq $spec.Value) {
		Add-Note "     $($spec.Name): уже $($spec.Value), изменений нет"
		return
	}
	$node.InnerText = $spec.Value
	# Умолчания решают, какие записи вообще пишутся, — следующие операции должны видеть новое значение.
	if ($spec.Name -eq 'setForNewObjects') { $script:roleSfno = $spec.Value }
	if ($spec.Name -eq 'setForAttributesByDefault') { $script:roleSfab = $spec.Value }
	$script:modifyCount++
	$script:rightsDirty = $true
	Add-Note "     $($spec.Name) = $($spec.Value)"
	# Измерено: при setForNewObjects=true платформа перестаёт хранить права, совпадающие с
	# автоматически выдаваемыми, и переписывает файл роли целиком.
	if ($spec.Name -eq 'setForNewObjects' -and $spec.Value -eq 'true') {
		[Console]::Error.WriteLine("[role-edit] setForNewObjects=true: платформа пересчитает хранимые права роли при первой же загрузке — часть явных записей исчезнет")
	}
}

# --- Метаданные роли (Roles/Имя.xml) ---

function Edit-RoleMetadata([string]$field, [string]$text) {
	if (-not (Test-Path -LiteralPath $script:roleXmlPath)) {
		Add-ValidationError "Файл метаданных роли не найден: $($script:roleXmlPath)"
		return
	}
	$doc = $script:metaDoc
	if (-not $doc) {
		$doc = New-Object System.Xml.XmlDocument
		$doc.PreserveWhitespace = $true
		$doc.Load($script:roleXmlPath)
	}
	$nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$nsm.AddNamespace("md", $script:mdObjectNs)
	$nsm.AddNamespace("v8", $script:v8Ns)
	$props = $doc.SelectSingleNode("//md:Role/md:Properties", $nsm)
	if (-not $props) {
		Add-ValidationError "В метаданных роли нет блока <Properties>: $($script:roleXmlPath)"
		return
	}
	$node = $props.SelectSingleNode("md:$field", $nsm)
	$indent = Get-ChildIndent $props
	if ($field -eq 'Synonym') {
		$xml = if ($text) {
			"<Synonym>`r`n$indent`t<v8:item>`r`n$indent`t`t<v8:lang>ru</v8:lang>`r`n$indent`t`t<v8:content>$(Esc-XmlText $text)</v8:content>`r`n$indent`t</v8:item>`r`n$indent</Synonym>"
		} else { "<Synonym/>" }
	} else {
		$xml = if ($text) { "<Comment>$(Esc-XmlText $text)</Comment>" } else { "<Comment/>" }
	}
	$wrapper = "<_W xmlns=`"$($script:mdObjectNs)`" xmlns:v8=`"$($script:v8Ns)`" xmlns:xsi=`"$($script:xsiNs)`">$xml</_W>"
	$frag = New-Object System.Xml.XmlDocument
	$frag.PreserveWhitespace = $true
	$frag.LoadXml($wrapper)
	$new = $doc.ImportNode($frag.DocumentElement.FirstChild, $true)
	if ($node) { $props.ReplaceChild($new, $node) | Out-Null }
	else { Insert-BeforeElement $props $new $null $indent }
	$script:metaDoc = $doc
	$script:metaDirty = $true
	$script:modifyCount++
	Add-Note "     $field обновлён в метаданных роли"
}

# --- Сбор и выполнение операций ---

# Очередь одна: операции применяются в том порядке, в котором их перечислили.
$script:pending = @()

$operations = @()
if ($DefinitionFile) {
	$json = ConvertFrom-JsonInput (Read-JsonInputFile $DefinitionFile) "-DefinitionFile '$DefinitionFile'" "a JSON object or array of operations"
	$items = if ($json -is [array]) { $json } else { @($json) }
	foreach ($item in $items) {
		$opName = if ($item.operation) { "$($item.operation)" } else { "$($item.op)" }
		$opValue = if ($null -ne $item.value) { "$($item.value)" } else { "" }
		$operations += ,@{ Operation = $opName; Value = $opValue }
	}
} else {
	$operations += ,@{ Operation = $Operation; Value = $Value }
}

foreach ($op in $operations) {
	$opName = "$($op.Operation)".Trim()
	$opValue = "$($op.Value)"
	switch ($opName.ToLower()) {
		"add-rights"       { Do-AddRights $opValue }
		"set-rights"       { Do-SetRights $opValue }
		"remove-rights"    { Do-RemoveRights $opValue }
		"deny-rights"      { Do-DenyRights $opValue }
		"set-rls"          { Do-SetRls $opValue }
		"remove-rls"       { Do-RemoveRls $opValue }
		"add-template"     { Do-AddTemplate $opValue }
		"set-template"     { Do-SetTemplate $opValue }
		"remove-template"  { Do-RemoveTemplate $opValue }
		"modify-property"  { Do-ModifyProperty $opValue }
		"set-synonym"      { $script:pending += ,@{ Kind = 'set-meta'; Spec = @{ Field = 'Synonym'; Text = (Resolve-TextFromFile $opValue $script:textBaseDir) } } }
		"set-comment"      { $script:pending += ,@{ Kind = 'set-meta'; Spec = @{ Field = 'Comment'; Text = (Resolve-TextFromFile $opValue $script:textBaseDir) } } }
		default {
			Add-ValidationError "Неизвестная операция: $opName"
		}
	}
}

# Отказ до записи: правка роли — это несколько узлов сразу, и наполовину применённая правка
# хуже неприменённой. Печатаем все причины разом.
if ($script:validationErrors.Count -gt 0) {
	[Console]::Error.WriteLine("[role-edit] Правка не применена: $($script:validationErrors.Count) ошибок во входе.")
	foreach ($err in $script:validationErrors) { [Console]::Error.WriteLine("  ERROR: $err") }
	exit 1
}

foreach ($item in $script:pending) {
	switch ($item.Kind) {
		'add-rights'      { Apply-AddRights $item.Spec }
		'set-rights'      { Apply-SetRights $item.Spec }
		'deny-rights'     { Apply-DenyRights $item.Spec }
		'remove-rights'   { Apply-RemoveRights $item.Spec }
		'add-template'    { Apply-AddTemplate $item.Spec }
		'set-template'    { Apply-AddTemplate $item.Spec -AllowReplace }
		'remove-template' { Apply-RemoveTemplate $item.Spec }
		'set-rls'         { Apply-SetRls $item.Spec }
		'remove-rls'      { Apply-RemoveRls $item.Spec }
		'modify-property' { Apply-ModifyProperty $item.Spec }
		'set-meta'        { Edit-RoleMetadata $item.Spec.Field $item.Spec.Text }
	}
}

# Ошибка могла всплыть и на применении (RLS без права) — файл в этом случае не трогаем.
if ($script:validationErrors.Count -gt 0) {
	[Console]::Error.WriteLine("[role-edit] Правка не применена: $($script:validationErrors.Count) ошибок во входе.")
	foreach ($err in $script:validationErrors) { [Console]::Error.WriteLine("  ERROR: $err") }
	exit 1
}

# --- Запись ---

function Save-XmlPreservingStyle($doc, [string]$path) {
	$style = Detect-XmlStyle $path
	$settings = New-Object System.Xml.XmlWriterSettings
	$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
	$settings.Indent = $false
	$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
	$stream = New-Object System.IO.MemoryStream
	$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
	$doc.Save($writer)
	$writer.Flush()
	$writer.Close()
	$text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
	$stream.Dispose()
	$text = Finalize-XmlText $text $style
	$utf8Bom = New-Object System.Text.UTF8Encoding($style.bom)
	[System.IO.File]::WriteAllText($path, $text, $utf8Bom)
}

if ($script:rightsDirty) { Save-XmlPreservingStyle $script:xmlDoc $script:rightsPath }
if ($script:metaDirty) { Save-XmlPreservingStyle $script:metaDoc $script:roleXmlPath }

# --- Итог ---

Write-Host "[OK] Роль '$($script:paths.RoleName)' обновлена"
Write-Host "     Rights:   $($script:rightsPath)"
foreach ($note in $script:notes) { Write-Host $note }
Write-Host "     Added: $($script:addCount), Removed: $($script:removeCount), Modified: $($script:modifyCount)"
if ($script:droppedByDefault.Count -gt 0) {
	[Console]::Error.WriteLine("[role-edit] Не записаны права, совпадающие с умолчанием роли (платформа их не хранит): $($script:droppedByDefault -join ', ')")
	[Console]::Error.WriteLine("  Запрет хранится у реквизитов и табличных частей (они наследуют права объекта) либо в роли с setForNewObjects=true; выдача прав — наоборот.")
}

if (-not $NoValidate) {
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\role-validate") "scripts\role-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running role-validate ---"
		& powershell.exe -NoProfile -File $validateScript -RightsPath $script:rightsPath
	}
}
