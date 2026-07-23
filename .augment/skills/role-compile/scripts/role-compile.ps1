# role-compile v1.8 — Compile 1C role from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputDir
)

$ErrorActionPreference = "Stop"
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

$json = Get-Content -Raw -Encoding UTF8 $JsonPath
$def = $json | ConvertFrom-Json

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
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

# --- 3. Russian synonyms → canonical English names ---

$script:typeAliases = @{
	"Справочник" = "Catalog"
	"Документ" = "Document"
	"РегистрСведений" = "InformationRegister"
	"РегистрНакопления" = "AccumulationRegister"
	"РегистрБухгалтерии" = "AccountingRegister"
	"РегистрРасчета" = "CalculationRegister"
	"Константа" = "Constant"
	"ПланСчетов" = "ChartOfAccounts"
	"ПланВидовХарактеристик" = "ChartOfCharacteristicTypes"
	"ПланВидовРасчета" = "ChartOfCalculationTypes"
	"ПланОбмена" = "ExchangePlan"
	"БизнесПроцесс" = "BusinessProcess"
	"Задача" = "Task"
	"Обработка" = "DataProcessor"
	"Отчет" = "Report"
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
	"Перечисление" = "Enum"
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
}

# Nested objects: Attribute, StandardAttribute, TabularSection, Dimension, Resource, AddressingAttribute
$script:nestedRights = @("View","Edit")
$script:commandRights = @("View")

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

	if (Is-NestedObject $objectName) {
		if ($objectName -match '\.Command\.') {
			if ($rightName -notin $script:commandRights) {
				Write-Warning "${objectName}: '$rightName' not valid for commands (only: View)"
				return $false
			}
		} else {
			if ($rightName -notin $script:nestedRights) {
				Write-Warning "${objectName}: '$rightName' not valid for nested objects (only: View, Edit)"
				return $false
			}
		}
		return $true
	}

	if (-not $script:knownRights.ContainsKey($objectType)) {
		Write-Warning "${objectName}: unknown object type '$objectType'"
		return $true
	}

	$validRights = $script:knownRights[$objectType]
	if ($rightName -notin $validRights) {
		$suggestions = @($validRights | Where-Object {
			$_ -like "*$rightName*" -or $rightName -like "*$_*"
		})
		$sugStr = if ($suggestions.Count -gt 0) { " Did you mean: $($suggestions -join ', ')?" } else { "" }
		Write-Warning "${objectName}: unknown right '$rightName'.$sugStr"
		return $false
	}

	return $true
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

$parsedObjects = @()
if ($def.objects) {
	foreach ($entry in $def.objects) {
		$parsed = Parse-ObjectEntry -entry $entry
		if ($parsed) {
			$parsedObjects += ,$parsed
		}
	}
}

# --- Detect format version ---

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$head = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8).Substring(0, [Math]::Min(2000, (Get-Item $cfgPath).Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

$resolvedOutputDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path (Get-Location) $OutputDir }
Assert-EditAllowed $resolvedOutputDir 'editable'
$formatVersion = Detect-FormatVersion $resolvedOutputDir

# --- 8. Generate UUID ---

$uuid = [guid]::NewGuid().ToString()

# --- 9. Emit metadata XML (Roles/Name.xml) ---

$script:xmlBuf = New-Object System.Text.StringBuilder 4096

X '<?xml version="1.0" encoding="UTF-8"?>'
X '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"'
X '        xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
X '        xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
X '        xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi"'
X '        xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
X '        xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
X '        xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
X '        xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
X '        xmlns:v8="http://v8.1c.ru/8.1/data/core"'
X '        xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
X '        xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
X '        xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
X '        xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"'
X '        xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef"'
X '        xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
X '        xmlns:xs="http://www.w3.org/2001/XMLSchema"'
X '        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
X "        version=`"$formatVersion`">"
X "    <Role uuid=`"$uuid`">"
X '        <Properties>'
X "            <Name>$roleName</Name>"
X '            <Synonym>'
X '                <v8:item>'
X '                    <v8:lang>ru</v8:lang>'
X "                    <v8:content>$(Esc-Xml $synonym)</v8:content>"
X '                </v8:item>'
X '            </Synonym>'
if ($comment) {
	X "            <Comment>$(Esc-Xml $comment)</Comment>"
} else {
	X '            <Comment/>'
}
X '        </Properties>'
X '    </Role>'
X '</MetaDataObject>'

$metadataXml = $script:xmlBuf.ToString()

# --- 10. Emit Rights XML (Roles/Name/Ext/Rights.xml) ---

$script:xmlBuf = New-Object System.Text.StringBuilder 8192

X '<?xml version="1.0" encoding="UTF-8"?>'
X '<Rights xmlns="http://v8.1c.ru/8.2/roles"'
X '        xmlns:xs="http://www.w3.org/2001/XMLSchema"'
X '        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
X "        xsi:type=`"Rights`" version=`"$formatVersion`">"

# Global flags (defaults match typical 1C roles)
$sfno = if ($null -ne $def.setForNewObjects) { "$($def.setForNewObjects)".ToLower() } else { "false" }
$sfab = if ($null -ne $def.setForAttributesByDefault) { "$($def.setForAttributesByDefault)".ToLower() } else { "true" }
$irco = if ($null -ne $def.independentRightsOfChildObjects) { "$($def.independentRightsOfChildObjects)".ToLower() } else { "false" }

X "    <setForNewObjects>$sfno</setForNewObjects>"
X "    <setForAttributesByDefault>$sfab</setForAttributesByDefault>"
X "    <independentRightsOfChildObjects>$irco</independentRightsOfChildObjects>"

# Object blocks
$totalRights = 0
foreach ($obj in $parsedObjects) {
	X '    <object>'
	X "        <name>$($obj.Name)</name>"
	foreach ($right in $obj.Rights) {
		X '        <right>'
		X "            <name>$($right.Name)</name>"
		X "            <value>$($right.Value)</value>"
		if ($right.Condition) {
			X '            <restrictionByCondition>'
			X "                <condition>$(Esc-Xml $right.Condition)</condition>"
			X '            </restrictionByCondition>'
		}
		X '        </right>'
		$totalRights++
	}
	X '    </object>'
}

# RLS restriction templates
$templateCount = 0
if ($def.templates) {
	foreach ($tpl in $def.templates) {
		X '    <restrictionTemplate>'
		X "        <name>$(Esc-Xml "$($tpl.name)")</name>"
		X "        <condition>$(Esc-Xml "$($tpl.condition)")</condition>"
		X '    </restrictionTemplate>'
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
[System.IO.File]::WriteAllText($metadataPath, $metadataXml, $enc)
[System.IO.File]::WriteAllText($rightsPath, $rightsXml, $enc)

# --- 12. Register in Configuration.xml ---

$configXmlPath = Join-Path $configDir "Configuration.xml"
$regResult = $null

if (Test-Path $configXmlPath) {
	$configDoc = New-Object System.Xml.XmlDocument
	$configDoc.PreserveWhitespace = $true
	$configDoc.Load($configXmlPath)

	$nsMgr = New-Object System.Xml.XmlNamespaceManager($configDoc.NameTable)
	$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	$childObjects = $configDoc.SelectSingleNode("//md:Configuration/md:ChildObjects", $nsMgr)
	if ($childObjects) {
		$existing = $childObjects.SelectNodes("md:Role", $nsMgr)
		$alreadyExists = $false
		foreach ($r in $existing) {
			if ($r.InnerText -eq $roleName) {
				$alreadyExists = $true
				break
			}
		}

		if ($alreadyExists) {
			$regResult = "already"
		} else {
			$roleElem = $configDoc.CreateElement("Role", "http://v8.1c.ru/8.3/MDClasses")
			$roleElem.InnerText = $roleName

			if ($existing.Count -gt 0) {
				# Insert after last existing <Role>
				$lastRole = $existing[$existing.Count - 1]
				$newWs = $configDoc.CreateWhitespace("`n`t`t`t")
				$childObjects.InsertAfter($newWs, $lastRole) | Out-Null
				$childObjects.InsertAfter($roleElem, $newWs) | Out-Null
			} else {
				# No existing roles — insert before closing whitespace
				$lastChild = $childObjects.LastChild
				if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
					$newWs = $configDoc.CreateWhitespace("`n`t`t`t")
					$childObjects.InsertBefore($newWs, $lastChild) | Out-Null
					$childObjects.InsertBefore($roleElem, $lastChild) | Out-Null
				} else {
					$childObjects.AppendChild($configDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
					$childObjects.AppendChild($roleElem) | Out-Null
					$childObjects.AppendChild($configDoc.CreateWhitespace("`n`t`t")) | Out-Null
				}
			}

			# Save
			$cfgSettings = New-Object System.Xml.XmlWriterSettings
			$cfgSettings.Encoding = New-Object System.Text.UTF8Encoding($true)
			$cfgSettings.Indent = $false
			$stream = New-Object System.IO.FileStream($configXmlPath, [System.IO.FileMode]::Create)
			$writer = [System.Xml.XmlWriter]::Create($stream, $cfgSettings)
			$configDoc.Save($writer)
			$writer.Close()
			$stream.Close()

			$regResult = "added"
		}
	} else {
		$regResult = "no-childobj"
	}
} else {
	$regResult = "no-config"
}

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
