# template-add v1.10 — Add template to 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias("ProcessorName")]
	[string]$ObjectName,

	[Parameter(Mandatory)]
	[string]$TemplateName,

	[Parameter(Mandatory)]
	[ValidateSet("HTML", "Text", "SpreadsheetDocument", "BinaryData", "DataCompositionSchema")]
	[string]$TemplateType,

	[string]$Synonym = $TemplateName,

	[string]$SrcDir = "src",

	[switch]$SetMainSKD
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

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

# --- Маппинг типов ---

$typeMap = @{
	"HTML"                = @{ TemplateType = "HTMLDocument";        Ext = ".html" }
	"Text"                = @{ TemplateType = "TextDocument";        Ext = ".txt" }
	"SpreadsheetDocument" = @{ TemplateType = "SpreadsheetDocument"; Ext = ".xml" }
	"BinaryData"          = @{ TemplateType = "BinaryData";          Ext = ".bin" }
	"DataCompositionSchema" = @{ TemplateType = "DataCompositionSchema"; Ext = ".xml" }
}

$tmpl = $typeMap[$TemplateType]

# --- Проверки ---

$objectTypeFolders = @(
	"Reports", "DataProcessors", "Documents", "Catalogs",
	"InformationRegisters", "AccumulationRegisters",
	"ChartsOfCharacteristicTypes", "ChartsOfAccounts", "ChartsOfCalculationTypes",
	"BusinessProcesses", "Tasks", "ExchangePlans"
)

$rootXmlPath = Join-Path $SrcDir "$ObjectName.xml"
if (-not (Test-Path $rootXmlPath)) {
	$candidates = @()
	foreach ($folder in $objectTypeFolders) {
		$probe = Join-Path (Join-Path $SrcDir $folder) "$ObjectName.xml"
		if (Test-Path $probe) { $candidates += (Join-Path $SrcDir $folder) }
	}
	if ($candidates.Count -eq 1) {
		$SrcDir = $candidates[0]
		$rootXmlPath = Join-Path $SrcDir "$ObjectName.xml"
		Write-Host "[INFO] SrcDir расширен до: $SrcDir"
	} elseif ($candidates.Count -gt 1) {
		Write-Error "Объект '$ObjectName' найден в нескольких подпапках: $($candidates -join ', ')`nУкажи SrcDir явно"
		exit 1
	} else {
		Write-Error "Корневой файл объекта не найден: $rootXmlPath`nОжидается: <SrcDir>/<ObjectName>.xml`nПодсказка: SrcDir должен указывать на папку типа объектов (например Reports), а не на корень конфигурации"
		exit 1
	}
}

$processorDir = Join-Path $SrcDir $ObjectName
$templatesDir = Join-Path $processorDir "Templates"
$templateMetaPath = Join-Path $templatesDir "$TemplateName.xml"

if (Test-Path $templateMetaPath) {
	Write-Error "Макет уже существует: $templateMetaPath"
	exit 1
}

Assert-EditAllowed $rootXmlPath 'editable'

# --- Создание каталогов ---

$templateExtDir = Join-Path (Join-Path $templatesDir $TemplateName) "Ext"
New-Item -ItemType Directory -Path $templateExtDir -Force | Out-Null

# --- Кодировка ---

$encBom = New-Object System.Text.UTF8Encoding($true)

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

$formatVersion = Detect-FormatVersion (Resolve-Path $SrcDir).Path

# --- 1. Метаданные макета (Templates/<TemplateName>.xml) ---

$templateUuid = [guid]::NewGuid().ToString()

$templateMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version=`"$formatVersion`">
	<Template uuid="$templateUuid">
		<Properties>
			<Name>$TemplateName</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$Synonym</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<TemplateType>$($tmpl.TemplateType)</TemplateType>
		</Properties>
	</Template>
</MetaDataObject>
"@

[System.IO.File]::WriteAllText($templateMetaPath, $templateMetaXml, $encBom)

# --- 2. Содержимое макета (Templates/<TemplateName>/Ext/Template.<ext>) ---

$templateFilePath = Join-Path $templateExtDir "Template$($tmpl.Ext)"

switch ($TemplateType) {
	"HTML" {
		$content = @"
<!DOCTYPE html>
<html>
<head>
	<meta charset="UTF-8">
	<title></title>
</head>
<body>
</body>
</html>
"@
		[System.IO.File]::WriteAllText($templateFilePath, $content, $encBom)
	}
	"Text" {
		[System.IO.File]::WriteAllText($templateFilePath, "", $encBom)
	}
	"SpreadsheetDocument" {
		$content = @"
<?xml version="1.0" encoding="UTF-8"?>
<SpreadsheetDocument xmlns="http://v8.1c.ru/spreadsheet/document" xmlns:ss="http://v8.1c.ru/spreadsheet/document" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xs="http://www.w3.org/2001/XMLSchema">
</SpreadsheetDocument>
"@
		[System.IO.File]::WriteAllText($templateFilePath, $content, $encBom)
	}
	"BinaryData" {
		[System.IO.File]::WriteAllBytes($templateFilePath, @())
	}
	"DataCompositionSchema" {
		$content = @"
<?xml version="1.0" encoding="UTF-8"?>
<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
		xmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
		xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
		xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
		xmlns:v8="http://v8.1c.ru/8.1/data/core"
		xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
		xmlns:xs="http://www.w3.org/2001/XMLSchema"
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
	<dataSource>
		<name>ИсточникДанных1</name>
		<dataSourceType>Local</dataSourceType>
	</dataSource>
</DataCompositionSchema>
"@
		[System.IO.File]::WriteAllText($templateFilePath, $content, $encBom)
	}
}

# --- 3. Модификация корневого XML ---

$rootXmlFull = Resolve-Path $rootXmlPath
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($rootXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

$childObjects = $xmlDoc.SelectSingleNode("//md:ChildObjects", $nsMgr)
if (-not $childObjects) {
	Write-Error "Не найден элемент ChildObjects в $rootXmlPath"
	exit 1
}

# Добавить <Template> в конец ChildObjects — идемпотентно (не дублировать уже зарегистрированный)
$alreadyRegistered = [bool]$childObjects.SelectSingleNode("md:Template[text()='$TemplateName']", $nsMgr)

if (-not $alreadyRegistered) {
$templateElem = $xmlDoc.CreateElement("Template", "http://v8.1c.ru/8.3/MDClasses")
$templateElem.InnerText = $TemplateName

if ($childObjects.ChildNodes.Count -eq 0) {
	$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
	$childObjects.AppendChild($templateElem) | Out-Null
	$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
} else {
	$lastChild = $childObjects.LastChild
	# Вставить перед закрывающим whitespace (если есть), или в конец
	if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
		$childObjects.InsertBefore($xmlDoc.CreateWhitespace("`n`t`t`t"), $lastChild) | Out-Null
		$childObjects.InsertBefore($templateElem, $lastChild) | Out-Null
	} else {
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
		$childObjects.AppendChild($templateElem) | Out-Null
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
	}
}
}

# --- 4. MainDataCompositionSchema (для ExternalReport / Report) ---

$mainDCSUpdated = $false
if ($TemplateType -eq "DataCompositionSchema") {
	# Определяем корневой элемент объекта
	$reportLikeTypes = @("ExternalReport", "Report")
	$objectTypeNode = $null
	$objectTypeName = $null
	foreach ($rt in $reportLikeTypes) {
		$node = $xmlDoc.SelectSingleNode("//md:$rt", $nsMgr)
		if ($node) {
			$objectTypeNode = $node
			$objectTypeName = $rt
			break
		}
	}

	if ($objectTypeNode) {
		$mainDCS = $xmlDoc.SelectSingleNode("//md:${objectTypeName}/md:Properties/md:MainDataCompositionSchema", $nsMgr)
		if ($mainDCS) {
			$isEmpty = [string]::IsNullOrWhiteSpace($mainDCS.InnerText)
			if ($isEmpty -or $SetMainSKD) {
				$objName = $xmlDoc.SelectSingleNode("//md:${objectTypeName}/md:Properties/md:Name", $nsMgr).InnerText
				$mainDCS.InnerText = "$objectTypeName.$objName.Template.$TemplateName"
				$mainDCSUpdated = $true
			}
		}
	}
}

# Сохранить с BOM
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $encBom
$settings.Indent = $false

$stream = New-Object System.IO.FileStream($rootXmlFull.Path, [System.IO.FileMode]::Create)
$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
$xmlDoc.Save($writer)
$writer.Close()
$stream.Close()

Write-Host "[OK] Создан макет: $TemplateName ($TemplateType)"
if ($alreadyRegistered) {
	Write-Host "     Already registered: <Template>$TemplateName</Template> in ChildObjects (skipped duplicate)"
}
Write-Host "     Метаданные: $templateMetaPath"
Write-Host "     Содержимое: $templateFilePath"
if ($mainDCSUpdated) {
	Write-Host "     MainDataCompositionSchema: $($mainDCS.InnerText)"
}
