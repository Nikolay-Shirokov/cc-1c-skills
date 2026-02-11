# epf-add-help v1.0 — Add built-in help to 1C processor
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ProcessorName,

	[string]$Lang = "ru",

	[string]$SrcDir = "src"
)

$ErrorActionPreference = "Stop"

# --- Проверки ---

$processorDir = Join-Path $SrcDir $ProcessorName
$extDir = Join-Path $processorDir "Ext"

if (-not (Test-Path $extDir)) {
	Write-Error "Каталог обработки не найден: $extDir. Сначала выполните epf-init."
	exit 1
}

$helpXmlPath = Join-Path $extDir "Help.xml"
if (Test-Path $helpXmlPath) {
	Write-Error "Справка уже существует: $helpXmlPath"
	exit 1
}

# --- Кодировка ---

$encBom = New-Object System.Text.UTF8Encoding($true)

# --- 1. Help.xml ---

$helpXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Help xmlns="http://v8.1c.ru/8.3/xcf/extrnprops" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Page>$Lang</Page>
</Help>
"@

[System.IO.File]::WriteAllText($helpXmlPath, $helpXml, $encBom)

# --- 2. Help/<lang>.html ---

$helpDir = Join-Path $extDir "Help"
New-Item -ItemType Directory -Path $helpDir -Force | Out-Null

$helpHtmlPath = Join-Path $helpDir "$Lang.html"

$helpHtml = @"
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<html>
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
    <link rel="stylesheet" type="text/css" href="v8help://service_book/service_style"/>
</head>
<body>
    <h1>$ProcessorName</h1>
    <p>Описание обработки.</p>
</body>
</html>
"@

[System.IO.File]::WriteAllText($helpHtmlPath, $helpHtml, $encBom)

# --- 3. Проверка IncludeHelpInContents в метаданных форм ---

$formsDir = Join-Path $processorDir "Forms"
if (Test-Path $formsDir) {
	$formMetaFiles = Get-ChildItem -Path $formsDir -Filter "*.xml" -File
	foreach ($formMeta in $formMetaFiles) {
		$xmlDoc = New-Object System.Xml.XmlDocument
		$xmlDoc.PreserveWhitespace = $true
		$xmlDoc.Load($formMeta.FullName)

		$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
		$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

		$includeHelp = $xmlDoc.SelectSingleNode("//md:IncludeHelpInContents", $nsMgr)
		if (-not $includeHelp) {
			# Добавить после <FormType>
			$formType = $xmlDoc.SelectSingleNode("//md:FormType", $nsMgr)
			if ($formType) {
				$newElem = $xmlDoc.CreateElement("IncludeHelpInContents", "http://v8.1c.ru/8.3/MDClasses")
				$newElem.InnerText = "false"
				$parent = $formType.ParentNode
				$nextSibling = $formType.NextSibling
				# Вставить перенос + табуляцию + элемент
				$ws = $xmlDoc.CreateWhitespace("`n`t`t`t")
				if ($nextSibling) {
					$parent.InsertBefore($ws, $nextSibling) | Out-Null
					$parent.InsertBefore($newElem, $ws) | Out-Null
				} else {
					$parent.AppendChild($ws) | Out-Null
					$parent.AppendChild($newElem) | Out-Null
				}

				$settings = New-Object System.Xml.XmlWriterSettings
				$settings.Encoding = $encBom
				$settings.Indent = $false
				$stream = New-Object System.IO.FileStream($formMeta.FullName, [System.IO.FileMode]::Create)
				$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
				$xmlDoc.Save($writer)
				$writer.Close()
				$stream.Close()

				Write-Host "     IncludeHelpInContents добавлен: $($formMeta.Name)"
			}
		}
	}
}

Write-Host "[OK] Создана справка: $ProcessorName"
Write-Host "     Метаданные: $helpXmlPath"
Write-Host "     Страница:   $helpHtmlPath"
