param(
	[Parameter(Mandatory)]
	[string]$ProcessorName,

	[Parameter(Mandatory)]
	[string]$TemplateName,

	[Parameter(Mandatory)]
	[ValidateSet("HTML", "Text", "SpreadsheetDocument", "BinaryData", "DataCompositionSchema")]
	[string]$TemplateType,

	[string]$Synonym = $TemplateName,

	[string]$SrcDir = "src"
)

$ErrorActionPreference = "Stop"

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

$rootXmlPath = Join-Path $SrcDir "$ProcessorName.xml"
if (-not (Test-Path $rootXmlPath)) {
	Write-Error "Корневой файл обработки не найден: $rootXmlPath"
	exit 1
}

$processorDir = Join-Path $SrcDir $ProcessorName
$templatesDir = Join-Path $processorDir "Templates"
$templateMetaPath = Join-Path $templatesDir "$TemplateName.xml"

if (Test-Path $templateMetaPath) {
	Write-Error "Макет уже существует: $templateMetaPath"
	exit 1
}

# --- Создание каталогов ---

$templateExtDir = Join-Path (Join-Path $templatesDir $TemplateName) "Ext"
New-Item -ItemType Directory -Path $templateExtDir -Force | Out-Null

# --- Кодировка ---

$encBom = New-Object System.Text.UTF8Encoding($true)

# --- 1. Метаданные макета (Templates/<TemplateName>.xml) ---

$templateUuid = [guid]::NewGuid().ToString()

$templateMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
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

# Добавить <Template> в конец ChildObjects
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
Write-Host "     Метаданные: $templateMetaPath"
Write-Host "     Содержимое: $templateFilePath"
