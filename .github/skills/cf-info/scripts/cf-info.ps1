# cf-info v1.2 — Compact summary of 1C configuration root
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory=$true)][Alias('Path')][string]$ConfigPath,
	[ValidateSet("overview","brief","full")]
	[string]$Mode = "overview",
	[Alias('Name')]
	[ValidateSet("home-page")]
	[string]$Section,
	[int]$Limit = 150,
	[int]$Offset = 0,
	[string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Output helper (always collect, paginate at the end) ---
$script:lines = @()
function Out([string]$text) { $script:lines += $text }

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}

# Directory -> find Configuration.xml
if (Test-Path $ConfigPath -PathType Container) {
	$candidate = Join-Path $ConfigPath "Configuration.xml"
	if (Test-Path $candidate) {
		$ConfigPath = $candidate
	} else {
		Write-Host "[ERROR] No Configuration.xml found in directory: $ConfigPath"
		exit 1
	}
}

if (-not (Test-Path $ConfigPath)) {
	Write-Host "[ERROR] File not found: $ConfigPath"
	exit 1
}

# --- Load XML ---
[xml]$xmlDoc = Get-Content -Path $ConfigPath -Encoding UTF8
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("app", "http://v8.1c.ru/8.2/managed-application/core")

$mdRoot = $xmlDoc.SelectSingleNode("/md:MetaDataObject", $ns)
if (-not $mdRoot) {
	Write-Host "[ERROR] Not a valid 1C metadata XML file (no MetaDataObject root)"
	exit 1
}

$cfgNode = $mdRoot.SelectSingleNode("md:Configuration", $ns)
if (-not $cfgNode) {
	Write-Host "[ERROR] No <Configuration> element found"
	exit 1
}

$version = $mdRoot.GetAttribute("version")
$propsNode = $cfgNode.SelectSingleNode("md:Properties", $ns)
$childObjNode = $cfgNode.SelectSingleNode("md:ChildObjects", $ns)

# --- Helpers ---
function Get-MLText($node) {
	if (-not $node) { return "" }
	$item = $node.SelectSingleNode("v8:item/v8:content", $ns)
	if ($item -and $item.InnerText) { return $item.InnerText }
	return ""
}

function Get-PropText([string]$propName) {
	$n = $propsNode.SelectSingleNode("md:$propName", $ns)
	if ($n -and $n.InnerText) { return $n.InnerText }
	return ""
}

function Get-PropML([string]$propName) {
	$n = $propsNode.SelectSingleNode("md:$propName", $ns)
	return (Get-MLText $n)
}

# --- Type name maps (canonical order, 44 types) ---
$typeOrder = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","IntegrationService"
)

$typeRuNames = @{
	"Language"="Языки"; "Subsystem"="Подсистемы"; "StyleItem"="Элементы стиля"; "Style"="Стили"
	"CommonPicture"="Общие картинки"; "SessionParameter"="Параметры сеанса"; "Role"="Роли"
	"CommonTemplate"="Общие макеты"; "FilterCriterion"="Критерии отбора"; "CommonModule"="Общие модули"
	"CommonAttribute"="Общие реквизиты"; "ExchangePlan"="Планы обмена"; "XDTOPackage"="XDTO-пакеты"
	"WebService"="Веб-сервисы"; "HTTPService"="HTTP-сервисы"; "WSReference"="WS-ссылки"
	"EventSubscription"="Подписки на события"; "ScheduledJob"="Регламентные задания"
	"SettingsStorage"="Хранилища настроек"; "FunctionalOption"="Функциональные опции"
	"FunctionalOptionsParameter"="Параметры ФО"; "DefinedType"="Определяемые типы"
	"CommonCommand"="Общие команды"; "CommandGroup"="Группы команд"; "Constant"="Константы"
	"CommonForm"="Общие формы"; "Catalog"="Справочники"; "Document"="Документы"
	"DocumentNumerator"="Нумераторы"; "Sequence"="Последовательности"; "DocumentJournal"="Журналы документов"
	"Enum"="Перечисления"; "Report"="Отчёты"; "DataProcessor"="Обработки"
	"InformationRegister"="Регистры сведений"; "AccumulationRegister"="Регистры накопления"
	"ChartOfCharacteristicTypes"="ПВХ"; "ChartOfAccounts"="Планы счетов"
	"AccountingRegister"="Регистры бухгалтерии"; "ChartOfCalculationTypes"="ПВР"
	"CalculationRegister"="Регистры расчёта"; "BusinessProcess"="Бизнес-процессы"
	"Task"="Задачи"; "IntegrationService"="Сервисы интеграции"
}

# --- Read panel layout (Ext/ClientApplicationInterface.xml) ---
$script:panelNames = @{
	"cbab57f2-a0f3-4f0a-89ea-4cb19570ab75" = "Открытых"
	"b553047f-c9aa-4157-978d-448ecad24248" = "Разделов"
	"13322b22-3960-4d68-93a6-fe2dd7f28ca3" = "Избранного"
	"c933ac92-92cd-459d-81cc-e0c8a83ced99" = "История"
	"b2735bd3-d822-4430-ba59-c9e869693b24" = "Функций"
}

function Get-PanelsLayout {
	$configDir = [System.IO.Path]::GetDirectoryName($ConfigPath)
	$caiPath = Join-Path (Join-Path $configDir "Ext") "ClientApplicationInterface.xml"
	if (-not (Test-Path $caiPath)) { return $null }
	try { [xml]$caiDoc = Get-Content -Path $caiPath -Encoding UTF8 } catch { return $null }
	if (-not $caiDoc.DocumentElement) { return $null }
	$caiNs = New-Object System.Xml.XmlNamespaceManager($caiDoc.NameTable)
	$caiNs.AddNamespace("ca", "http://v8.1c.ru/8.2/managed-application/core")
	$layout = [ordered]@{ top=@(); left=@(); right=@(); bottom=@(); declared=@() }
	foreach ($side in @("top","left","right","bottom")) {
		foreach ($sideEl in $caiDoc.DocumentElement.SelectNodes("ca:$side", $caiNs)) {
			$slot = @()
			foreach ($u in $sideEl.SelectNodes(".//ca:panel/ca:uuid", $caiNs)) {
				$key = $u.InnerText.Trim()
				$nm = if ($script:panelNames.Contains($key)) { $script:panelNames[$key] } else { "?$key" }
				$slot += $nm
			}
			if ($slot.Count -gt 0) { $layout[$side] += ,$slot }
		}
	}
	foreach ($pd in $caiDoc.DocumentElement.SelectNodes("ca:panelDef", $caiNs)) {
		$key = $pd.GetAttribute("id")
		$nm = if ($script:panelNames.Contains($key)) { $script:panelNames[$key] } else { "?$key" }
		$layout.declared += $nm
	}
	return $layout
}

function Format-LayoutSlots($slots) {
	# slots is array of arrays (each inner array = one side-tag's panels, may be 1+)
	# Single inner array, single panel -> just name
	# Single inner array, multiple panels -> "Стек(a, b)"
	# Multiple inner arrays -> separate entries joined by " | "
	if (-not $slots -or $slots.Count -eq 0) { return "" }
	$parts = @()
	foreach ($slot in $slots) {
		if ($slot.Count -eq 1) { $parts += $slot[0] }
		else { $parts += ("Стек(" + ($slot -join ", ") + ")") }
	}
	return ($parts -join " | ")
}

$script:panelLayout = Get-PanelsLayout

# --- Read home page layout (Ext/HomePageWorkArea.xml) ---
function Get-HomePageLayout {
	$configDir = [System.IO.Path]::GetDirectoryName($ConfigPath)
	$hpPath = Join-Path (Join-Path $configDir "Ext") "HomePageWorkArea.xml"
	if (-not (Test-Path $hpPath)) { return $null }
	try { [xml]$hpDoc = Get-Content -Path $hpPath -Encoding UTF8 } catch { return $null }
	if (-not $hpDoc.DocumentElement) { return $null }
	$hpNs = New-Object System.Xml.XmlNamespaceManager($hpDoc.NameTable)
	$hpNs.AddNamespace("hp", "http://v8.1c.ru/8.3/xcf/extrnprops")
	$hpNs.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
	$result = [ordered]@{ template = ""; left = @(); right = @() }
	$tmplNode = $hpDoc.DocumentElement.SelectSingleNode("hp:WorkingAreaTemplate", $hpNs)
	if ($tmplNode) { $result.template = $tmplNode.InnerText.Trim() }
	foreach ($colName in @("LeftColumn","RightColumn")) {
		$colNode = $hpDoc.DocumentElement.SelectSingleNode("hp:$colName", $hpNs)
		if (-not $colNode) { continue }
		$items = @()
		foreach ($item in $colNode.SelectNodes("hp:Item", $hpNs)) {
			$f = $item.SelectSingleNode("hp:Form", $hpNs)
			$h = $item.SelectSingleNode("hp:Height", $hpNs)
			$visNode = $item.SelectSingleNode("hp:Visibility", $hpNs)
			$common = $true
			$roles = @()
			if ($visNode) {
				$cn = $visNode.SelectSingleNode("xr:Common", $hpNs)
				if ($cn) { $common = ($cn.InnerText.Trim() -eq "true") }
				foreach ($v in $visNode.SelectNodes("xr:Value", $hpNs)) {
					$roles += @{ name = $v.GetAttribute("name"); value = ($v.InnerText.Trim() -eq "true") }
				}
			}
			$items += [ordered]@{
				form = if ($f) { $f.InnerText.Trim() } else { "" }
				height = if ($h) { [int]$h.InnerText.Trim() } else { 10 }
				common = $common
				roles = $roles
			}
		}
		if ($colName -eq "LeftColumn") { $result.left = $items } else { $result.right = $items }
	}
	return $result
}

$script:homePage = Get-HomePageLayout

function Format-HomePageItem($it, [bool]$detailed) {
	$badges = @()
	$badges += "h=$($it.height)"
	if (-not $it.common) { $badges += "скрыта" }
	if ($it.roles.Count -gt 0) {
		if ($detailed) { $badges += "роли: $($it.roles.Count)" }
		else { $badges += "+$($it.roles.Count) ролей" }
	}
	$tail = if ($badges.Count -gt 0) { " (" + ($badges -join ", ") + ")" } else { "" }
	return "    $($it.form)$tail"
}

# --- Count objects in ChildObjects ---
$objectCounts = [ordered]@{}
$totalObjects = 0

if ($childObjNode) {
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		if (-not $objectCounts.Contains($typeName)) {
			$objectCounts[$typeName] = 0
		}
		$objectCounts[$typeName] = $objectCounts[$typeName] + 1
		$totalObjects++
	}
}

# --- Read key properties ---
$cfgName = Get-PropText "Name"
$cfgSynonym = Get-PropML "Synonym"
$cfgVersion = Get-PropText "Version"
$cfgVendor = Get-PropText "Vendor"
$cfgCompat = Get-PropText "CompatibilityMode"
$cfgExtCompat = Get-PropText "ConfigurationExtensionCompatibilityMode"
$cfgDefaultRun = Get-PropText "DefaultRunMode"
$cfgScript = Get-PropText "ScriptVariant"
$cfgDefaultLang = Get-PropText "DefaultLanguage"
$cfgDataLock = Get-PropText "DataLockControlMode"
$dash = [char]0x2014
$cfgModality = Get-PropText "ModalityUseMode"
$cfgIntfCompat = Get-PropText "InterfaceCompatibilityMode"
$cfgAutoNum = Get-PropText "ObjectAutonumerationMode"
$cfgSyncCalls = Get-PropText "SynchronousPlatformExtensionAndAddInCallUseMode"
$cfgDbSpaces = Get-PropText "DatabaseTablespacesUseMode"
$cfgWindowMode = Get-PropText "MainClientApplicationWindowMode"

# --- BRIEF mode ---
if ($Mode -eq "brief" -and -not $Section) {
	$synPart = if ($cfgSynonym) { " $dash `"$cfgSynonym`"" } else { "" }
	$verPart = if ($cfgVersion) { " v$cfgVersion" } else { "" }
	$compatPart = if ($cfgCompat) { " | $cfgCompat" } else { "" }
	Out "Конфигурация: ${cfgName}${synPart}${verPart} | $totalObjects объектов${compatPart}"
}

# --- OVERVIEW mode ---
if ($Mode -eq "overview" -and -not $Section) {
	$synPart = if ($cfgSynonym) { " $dash `"$cfgSynonym`"" } else { "" }
	$verPart = if ($cfgVersion) { " v$cfgVersion" } else { "" }
	Out "=== Конфигурация: ${cfgName}${synPart}${verPart} ==="
	Out ""

	# Key properties
	Out "Формат:         $version"
	if ($cfgVendor)     { Out "Поставщик:      $cfgVendor" }
	if ($cfgVersion)    { Out "Версия:         $cfgVersion" }
	Out "Совместимость:  $cfgCompat"
	Out "Режим запуска:  $cfgDefaultRun"
	Out "Язык скриптов:  $cfgScript"
	Out "Язык:           $cfgDefaultLang"
	Out "Блокировки:     $cfgDataLock"
	Out "Модальность:    $cfgModality"
	Out "Интерфейс:      $cfgIntfCompat"
	Out ""

	# Panel layout (if file exists)
	if ($script:panelLayout) {
		$hasPlaced = $false
		foreach ($s in @("top","left","right","bottom")) {
			if ($script:panelLayout[$s].Count -gt 0) { $hasPlaced = $true; break }
		}
		if ($hasPlaced) {
			Out "--- Раскладка панелей ---"
			foreach ($s in @("top","left","right","bottom")) {
				if ($script:panelLayout[$s].Count -gt 0) {
					Out "  $($s.PadRight(7)) $(Format-LayoutSlots $script:panelLayout[$s])"
				}
			}
			Out ""
		}
	}

	# Home page layout (brief summary)
	if ($script:homePage) {
		$ln = $script:homePage.left.Count
		$rn = $script:homePage.right.Count
		Out "--- Начальная страница ---"
		Out "  Шаблон: $($script:homePage.template)"
		Out "  LeftColumn: $ln, RightColumn: $rn  (детали: -Section home-page)"
		Out ""
	}

	# Object counts table
	Out "--- Состав ($totalObjects объектов) ---"
	Out ""
	$maxTypeLen = 0
	foreach ($typeName in $typeOrder) {
		if ($objectCounts.Contains($typeName)) {
			$ruName = $typeRuNames[$typeName]
			if ($ruName.Length -gt $maxTypeLen) { $maxTypeLen = $ruName.Length }
		}
	}
	if ($maxTypeLen -lt 10) { $maxTypeLen = 10 }

	foreach ($typeName in $typeOrder) {
		if ($objectCounts.Contains($typeName)) {
			$count = $objectCounts[$typeName]
			$ruName = $typeRuNames[$typeName]
			$padded = $ruName.PadRight($maxTypeLen)
			Out "  $padded  $count"
		}
	}
}

# --- Drill-down: -Section home-page ---
if ($Section -eq "home-page") {
	if (-not $script:homePage) {
		Out "Файл Ext/HomePageWorkArea.xml не найден"
	} else {
		Out "=== Начальная страница: $cfgName ==="
		Out ""
		Out "Шаблон: $($script:homePage.template)"
		Out ""
		foreach ($side in @(@("LeftColumn","left"), @("RightColumn","right"))) {
			$items = $script:homePage[$side[1]]
			$lbl = $side[0]
			if ($items.Count -eq 0) { Out "${lbl}: —"; Out ""; continue }
			Out "${lbl} ($($items.Count)):"
			foreach ($it in $items) {
				Out (Format-HomePageItem $it $true)
				foreach ($r in $it.roles) {
					$rval = if ($r.value) { "true" } else { "false" }
					Out "      $($r.name): $rval"
				}
			}
			Out ""
		}
	}
}

# --- FULL mode ---
if ($Mode -eq "full" -and -not $Section) {
	$synPart = if ($cfgSynonym) { " $dash `"$cfgSynonym`"" } else { "" }
	$verPart = if ($cfgVersion) { " v$cfgVersion" } else { "" }
	Out "=== Конфигурация: ${cfgName}${synPart}${verPart} ==="
	Out ""

	# --- Section: Identification ---
	Out "--- Идентификация ---"
	Out "UUID:           $($cfgNode.GetAttribute('uuid'))"
	Out "Имя:            $cfgName"
	if ($cfgSynonym)  { Out "Синоним:        $cfgSynonym" }
	$cfgComment = Get-PropText "Comment"
	if ($cfgComment)  { Out "Комментарий:    $cfgComment" }
	$cfgPrefix = Get-PropText "NamePrefix"
	if ($cfgPrefix)   { Out "Префикс:        $cfgPrefix" }
	if ($cfgVendor)   { Out "Поставщик:      $cfgVendor" }
	if ($cfgVersion)  { Out "Версия:         $cfgVersion" }
	$cfgUpdateAddr = Get-PropText "UpdateCatalogAddress"
	if ($cfgUpdateAddr) { Out "Каталог обн.:   $cfgUpdateAddr" }
	Out ""

	# --- Section: Modes ---
	Out "--- Режимы работы ---"
	Out "Формат:              $version"
	Out "Совместимость:       $cfgCompat"
	Out "Совм. расширений:    $cfgExtCompat"
	Out "Режим запуска:       $cfgDefaultRun"
	Out "Язык скриптов:       $cfgScript"
	Out "Блокировки:          $cfgDataLock"
	Out "Автонумерация:       $cfgAutoNum"
	Out "Модальность:         $cfgModality"
	Out "Синхр. вызовы:       $cfgSyncCalls"
	Out "Интерфейс:           $cfgIntfCompat"
	Out "Табл. пространства:  $cfgDbSpaces"
	Out "Режим окна:          $cfgWindowMode"
	Out ""

	# --- Section: Language, roles, purposes ---
	Out "--- Назначение ---"
	Out "Язык по умолч.:  $cfgDefaultLang"

	# UsePurposes
	$purposeNode = $propsNode.SelectSingleNode("md:UsePurposes", $ns)
	if ($purposeNode) {
		$purposes = @()
		foreach ($val in $purposeNode.SelectNodes("v8:Value", $ns)) {
			$purposes += $val.InnerText
		}
		if ($purposes.Count -gt 0) { Out "Назначения:      $($purposes -join ', ')" }
	}

	# DefaultRoles
	$rolesNode = $propsNode.SelectSingleNode("md:DefaultRoles", $ns)
	if ($rolesNode) {
		$roles = @()
		foreach ($item in $rolesNode.SelectNodes("xr:Item", $ns)) {
			$roles += $item.InnerText
		}
		if ($roles.Count -gt 0) {
			Out "Роли по умолч.:  $($roles.Count)"
			foreach ($r in $roles) { Out "  - $r" }
		}
	}

	# Booleans
	$useMF = Get-PropText "UseManagedFormInOrdinaryApplication"
	$useOF = Get-PropText "UseOrdinaryFormInManagedApplication"
	Out "Управл.формы в обычн.: $useMF"
	Out "Обычн.формы в управл.: $useOF"
	Out ""

	# --- Section: Panel layout ---
	if ($script:panelLayout) {
		Out "--- Раскладка панелей ---"
		foreach ($s in @("top","left","right","bottom")) {
			$slots = $script:panelLayout[$s]
			if ($slots.Count -gt 0) {
				Out "  $($s.PadRight(7)) $(Format-LayoutSlots $slots)"
			} else {
				Out "  $($s.PadRight(7)) —"
			}
		}
		if ($script:panelLayout.declared.Count -gt 0) {
			Out "  объявлено: $($script:panelLayout.declared -join ', ')"
		}
		Out ""
	}

	# --- Section: Home page (brief summary) ---
	if ($script:homePage) {
		$ln = $script:homePage.left.Count
		$rn = $script:homePage.right.Count
		Out "--- Начальная страница ---"
		Out "  Шаблон: $($script:homePage.template)"
		Out "  LeftColumn: $ln, RightColumn: $rn  (детали: -Section home-page)"
		Out ""
	}

	# --- Section: Storages & default forms ---
	Out "--- Хранилища и формы по умолчанию ---"
	$storageProps = @("CommonSettingsStorage","ReportsUserSettingsStorage","ReportsVariantsStorage","FormDataSettingsStorage","DynamicListsUserSettingsStorage","URLExternalDataStorage")
	foreach ($sp in $storageProps) {
		$val = Get-PropText $sp
		if ($val) { Out "  ${sp}: $val" }
	}
	$formProps = @("DefaultReportForm","DefaultReportVariantForm","DefaultReportSettingsForm","DefaultReportAppearanceTemplate","DefaultDynamicListSettingsForm","DefaultSearchForm","DefaultDataHistoryChangeHistoryForm","DefaultDataHistoryVersionDataForm","DefaultDataHistoryVersionDifferencesForm","DefaultCollaborationSystemUsersChoiceForm","DefaultConstantsForm","DefaultInterface","DefaultStyle")
	foreach ($fp in $formProps) {
		$val = Get-PropText $fp
		if ($val) { Out "  ${fp}: $val" }
	}
	Out ""

	# --- Section: Info ---
	$cfgBrief = Get-PropML "BriefInformation"
	$cfgDetail = Get-PropML "DetailedInformation"
	$cfgCopyright = Get-PropML "Copyright"
	$cfgVendorAddr = Get-PropML "VendorInformationAddress"
	$cfgInfoAddr = Get-PropML "ConfigurationInformationAddress"
	if ($cfgBrief -or $cfgDetail -or $cfgCopyright -or $cfgVendorAddr -or $cfgInfoAddr) {
		Out "--- Информация ---"
		if ($cfgBrief)      { Out "Краткая:         $cfgBrief" }
		if ($cfgDetail)     { Out "Подробная:       $cfgDetail" }
		if ($cfgCopyright)  { Out "Copyright:       $cfgCopyright" }
		if ($cfgVendorAddr) { Out "Сайт поставщика: $cfgVendorAddr" }
		if ($cfgInfoAddr)   { Out "Адрес информ.:   $cfgInfoAddr" }
		Out ""
	}

	# --- Section: Mobile functionalities ---
	$mobileFunc = $propsNode.SelectSingleNode("md:UsedMobileApplicationFunctionalities", $ns)
	if ($mobileFunc) {
		$enabledFuncs = @()
		$disabledFuncs = @()
		foreach ($func in $mobileFunc.SelectNodes("app:functionality", $ns)) {
			$fName = $func.SelectSingleNode("app:functionality", $ns)
			$fUse = $func.SelectSingleNode("app:use", $ns)
			if ($fName -and $fUse) {
				if ($fUse.InnerText -eq "true") {
					$enabledFuncs += $fName.InnerText
				} else {
					$disabledFuncs += $fName.InnerText
				}
			}
		}
		$totalFunc = $enabledFuncs.Count + $disabledFuncs.Count
		Out "--- Мобильные функциональности ($totalFunc, включено: $($enabledFuncs.Count)) ---"
		if ($enabledFuncs.Count -gt 0) {
			foreach ($f in $enabledFuncs) { Out "  [+] $f" }
		}
		foreach ($f in $disabledFuncs) { Out "  [-] $f" }
		Out ""
	}

	# --- Section: InternalInfo ---
	$internalInfo = $cfgNode.SelectSingleNode("md:InternalInfo", $ns)
	if ($internalInfo) {
		$contained = $internalInfo.SelectNodes("xr:ContainedObject", $ns)
		Out "--- InternalInfo ($($contained.Count) ContainedObject) ---"
		foreach ($co in $contained) {
			$classId = $co.SelectSingleNode("xr:ClassId", $ns).InnerText
			$objectId = $co.SelectSingleNode("xr:ObjectId", $ns).InnerText
			Out "  $classId -> $objectId"
		}
		Out ""
	}

	# --- Section: ChildObjects (full list) ---
	Out "--- Состав ($totalObjects объектов) ---"
	Out ""

	foreach ($typeName in $typeOrder) {
		if (-not $objectCounts.Contains($typeName)) { continue }
		$count = $objectCounts[$typeName]
		$ruName = $typeRuNames[$typeName]
		Out "  $ruName ($typeName): $count"

		# Collect names for this type
		$names = @()
		foreach ($child in $childObjNode.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq $typeName) {
				$names += $child.InnerText
			}
		}
		foreach ($n in $names) { Out "    $n" }
	}
}

# --- Pagination and output ---
$total = $script:lines.Count
if ($Offset -gt 0 -or $Limit -lt $total) {
	$start = [Math]::Min($Offset, $total)
	$end = [Math]::Min($start + $Limit, $total)
	$page = $script:lines[$start..($end - 1)]
	$result = ($page -join "`n")
	if ($end -lt $total) {
		$result += "`n`n... ($end of $total lines, use -Offset $end to continue)"
	}
} else {
	$result = ($script:lines -join "`n")
}

Write-Host $result

if ($OutFile) {
	$utf8Bom = New-Object System.Text.UTF8Encoding $true
	[System.IO.File]::WriteAllText($OutFile, $result, $utf8Bom)
	Write-Host "`nWritten to: $OutFile"
}
