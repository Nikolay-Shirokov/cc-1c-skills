# cfe-patch-method v1.0 — Generate method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ExtensionPath,

	[Parameter(Mandatory)]
	[string]$ModulePath,

	[Parameter(Mandatory)]
	[string]$MethodName,

	[Parameter(Mandatory)]
	[ValidateSet("Before","After","ModificationAndControl")]
	[string]$InterceptorType,

	[string]$Context = "НаСервере",

	[switch]$IsFunction
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve extension path ---
if (-not [System.IO.Path]::IsPathRooted($ExtensionPath)) {
	$ExtensionPath = Join-Path (Get-Location).Path $ExtensionPath
}
if (Test-Path $ExtensionPath -PathType Leaf) {
	$ExtensionPath = Split-Path $ExtensionPath -Parent
}
$cfgFile = Join-Path $ExtensionPath "Configuration.xml"
if (-not (Test-Path $cfgFile)) {
	Write-Error "Configuration.xml not found in: $ExtensionPath"
	exit 1
}

# --- Read NamePrefix from Configuration.xml ---
$cfgDoc = New-Object System.Xml.XmlDocument
$cfgDoc.PreserveWhitespace = $false
$cfgDoc.Load($cfgFile)

$cfgNs = New-Object System.Xml.XmlNamespaceManager($cfgDoc.NameTable)
$cfgNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

$propsNode = $cfgDoc.SelectSingleNode("//md:Configuration/md:Properties", $cfgNs)
$prefixNode = if ($propsNode) { $propsNode.SelectSingleNode("md:NamePrefix", $cfgNs) } else { $null }
$namePrefix = if ($prefixNode -and $prefixNode.InnerText) { $prefixNode.InnerText } else { "Расш_" }

# --- Map ModulePath to file path ---
# ModulePath formats:
#   Catalog.X.ObjectModule       -> Catalogs/X/Ext/ObjectModule.bsl
#   Catalog.X.ManagerModule      -> Catalogs/X/Ext/ManagerModule.bsl
#   Catalog.X.Form.Y             -> Catalogs/X/Forms/Y/Ext/Form/Module.bsl
#   CommonModule.X               -> CommonModules/X/Ext/Module.bsl
#   Document.X.ObjectModule      -> Documents/X/Ext/ObjectModule.bsl
#   Document.X.ManagerModule     -> Documents/X/Ext/ManagerModule.bsl
#   Document.X.Form.Y            -> Documents/X/Forms/Y/Ext/Form/Module.bsl

$typeDirMap = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "Enum"="Enums"
	"CommonModule"="CommonModules"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"ExchangePlan"="ExchangePlans"; "ChartOfAccounts"="ChartsOfAccounts"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"AccountingRegister"="AccountingRegisters"; "CalculationRegister"="CalculationRegisters"
}

$parts = $ModulePath.Split(".")
if ($parts.Count -lt 2) {
	Write-Error "Invalid ModulePath format: $ModulePath. Expected: Type.Name.Module or CommonModule.Name"
	exit 1
}

$objType = $parts[0]
$objName = $parts[1]

if (-not $typeDirMap.ContainsKey($objType)) {
	Write-Error "Unknown object type: $objType"
	exit 1
}
$dirName = $typeDirMap[$objType]

$bslFile = $null
if ($objType -eq "CommonModule") {
	# CommonModule.X -> CommonModules/X/Ext/Module.bsl
	$bslFile = Join-Path (Join-Path (Join-Path (Join-Path $ExtensionPath $dirName) $objName) "Ext") "Module.bsl"
} elseif ($parts.Count -ge 4 -and $parts[2] -eq "Form") {
	# Type.X.Form.Y -> Types/X/Forms/Y/Ext/Form/Module.bsl
	$formName = $parts[3]
	$bslFile = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ExtensionPath $dirName) $objName) "Forms") $formName) "Ext") "Form") "Module.bsl"
} elseif ($parts.Count -ge 3) {
	# Type.X.ObjectModule -> Types/X/Ext/ObjectModule.bsl
	$moduleName = $parts[2]
	$moduleFileName = switch ($moduleName) {
		"ObjectModule"    { "ObjectModule.bsl" }
		"ManagerModule"   { "ManagerModule.bsl" }
		"RecordSetModule" { "RecordSetModule.bsl" }
		"CommandModule"   { "CommandModule.bsl" }
		default           { "$moduleName.bsl" }
	}
	$bslFile = Join-Path (Join-Path (Join-Path $ExtensionPath $dirName) $objName) (Join-Path "Ext" $moduleFileName)
} else {
	Write-Error "Invalid ModulePath format: $ModulePath. Expected: Type.Name.Module, Type.Name.Form.FormName, or CommonModule.Name"
	exit 1
}

# --- Map InterceptorType to decorator ---
$decorator = switch ($InterceptorType) {
	"Before"                  { "&Перед" }
	"After"                   { "&После" }
	"ModificationAndControl"  { "&ИзменениеИКонтроль" }
}

# --- Map Context to annotation ---
$contextAnnotation = switch ($Context) {
	"НаСервере"              { "&НаСервере" }
	"НаКлиенте"              { "&НаКлиенте" }
	"НаСервереБезКонтекста"  { "&НаСервереБезКонтекста" }
	default                  { "&$Context" }
}

# --- Procedure name ---
$procName = "${namePrefix}${MethodName}"

# --- Generate BSL code ---
$keyword = if ($IsFunction) { "Функция" } else { "Процедура" }
$endKeyword = if ($IsFunction) { "КонецФункции" } else { "КонецПроцедуры" }

$bodyLines = @()
switch ($InterceptorType) {
	"Before" {
		$bodyLines += "`t// TODO: код перед вызовом оригинального метода"
	}
	"After" {
		$bodyLines += "`t// TODO: код после вызова оригинального метода"
	}
	"ModificationAndControl" {
		$bodyLines += "`t// Скопируйте тело оригинального метода и внесите изменения,"
		$bodyLines += "`t// используя маркеры #Удаление / #КонецУдаления и #Вставка / #КонецВставки"
	}
}

if ($IsFunction) {
	$bodyLines += "`t"
	$bodyLines += "`tВозврат Неопределено; // TODO: заменить на реальное возвращаемое значение"
}

$bslCode = @()
$bslCode += "$contextAnnotation"
$bslCode += "${decorator}(`"$MethodName`")"
$bslCode += "$keyword ${procName}()"
$bslCode += $bodyLines
$bslCode += "$endKeyword"

$bslText = ($bslCode -join "`r`n") + "`r`n"

# --- Check form borrowing for .Form. paths ---
if ($parts.Count -ge 4 -and $parts[2] -eq "Form") {
	$formName = $parts[3]
	$dirName = $typeDirMap[$objType]
	$formMetaFile = Join-Path (Join-Path (Join-Path (Join-Path $ExtensionPath $dirName) $objName) "Forms") "${formName}.xml"
	$formXmlFile = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ExtensionPath $dirName) $objName) "Forms") $formName) "Ext/Form.xml"

	if (-not (Test-Path $formMetaFile) -or -not (Test-Path $formXmlFile)) {
		Write-Host "[WARN] Form '$formName' metadata or Form.xml not found in extension."
		Write-Host "       Run /cfe-borrow first:"
		Write-Host "       /cfe-borrow -ExtensionPath $ExtensionPath -ConfigPath <ConfigPath> -Object `"$objType.$objName.Form.$formName`""
		Write-Host ""
	}
}

# --- Check if file exists and append ---
$bslDir = Split-Path $bslFile -Parent
if (-not (Test-Path $bslDir)) {
	New-Item -ItemType Directory -Path $bslDir -Force | Out-Null
}

$enc = New-Object System.Text.UTF8Encoding($true)

if (Test-Path $bslFile) {
	# Append to existing file
	$existing = [System.IO.File]::ReadAllText($bslFile, $enc)
	$separator = "`r`n"
	if ($existing -and -not $existing.EndsWith("`n")) {
		$separator = "`r`n`r`n"
	}
	$newContent = $existing + $separator + $bslText
	[System.IO.File]::WriteAllText($bslFile, $newContent, $enc)
	Write-Host "[OK] Добавлен перехватчик в существующий файл"
} else {
	[System.IO.File]::WriteAllText($bslFile, $bslText, $enc)
	Write-Host "[OK] Создан файл модуля"
}

Write-Host "     Файл:         $bslFile"
Write-Host "     Декоратор:    $decorator(`"$MethodName`")"
Write-Host "     Процедура:    ${procName}()"
Write-Host "     Контекст:     $contextAnnotation"
