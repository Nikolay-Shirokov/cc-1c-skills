# template-remove v1.8 — Remove template from 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias("ProcessorName")]
	[string]$ObjectName,

	[Parameter(Mandatory)]
	[string]$TemplateName,

	[string]$SrcDir = "src"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# --- Проверки ---

$rootXmlPath = Join-Path $SrcDir "$ObjectName.xml"
if (-not (Test-Path $rootXmlPath)) {
	Write-Error "Корневой файл обработки не найден: $rootXmlPath"
	exit 1
}

$processorDir = Join-Path $SrcDir $ObjectName
$templatesDir = Join-Path $processorDir "Templates"
$templateMetaPath = Join-Path $templatesDir "$TemplateName.xml"
$templateDir = Join-Path $templatesDir $TemplateName

if (-not (Test-Path $templateMetaPath)) {
	Write-Error "Метаданные макета не найдены: $templateMetaPath"
	exit 1
}

# --- Удаление файлов ---

if (Test-Path $templateDir) {
	Remove-Item -Path $templateDir -Recurse -Force
	Write-Host "[OK] Удалён каталог: $templateDir"
}

Remove-Item -Path $templateMetaPath -Force
Write-Host "[OK] Удалён файл: $templateMetaPath"

# --- Модификация корневого XML ---

$rootXmlFull = Resolve-Path $rootXmlPath
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($rootXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

# Удалить <Template>TemplateName</Template> из ChildObjects
$templateNodes = $xmlDoc.SelectNodes("//md:ChildObjects/md:Template", $nsMgr)
foreach ($node in $templateNodes) {
	if ($node.InnerText -eq $TemplateName) {
		$parent = $node.ParentNode
		# Удалить предшествующий whitespace
		$prev = $node.PreviousSibling
		if ($prev -and $prev.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
			$parent.RemoveChild($prev) | Out-Null
		}
		$parent.RemoveChild($node) | Out-Null
		# Опустевший контейнер: остаётся отступ-whitespace, и XmlWriter пишет пару
		# <ChildObjects>\n\t\t</ChildObjects>. Платформа пишет только <ChildObjects/>
		# (1394 самозакрывающихся на acc+erp, пустых пар ни в одной форме — 0).
		if ($parent.SelectNodes("*").Count -eq 0) { $parent.IsEmpty = $true }
		break
	}
}

# Очистить MainDataCompositionSchema если указывала на этот макет
$mainDCS = $xmlDoc.SelectSingleNode("//md:MainDataCompositionSchema", $nsMgr)
if ($mainDCS -and $mainDCS.InnerText -match "Template\.$([regex]::Escape($TemplateName))$") {
	$mainDCS.InnerText = ""
	Write-Host "[OK] Очищён MainDataCompositionSchema"
}

# Сохранить с BOM
$encBom = New-Object System.Text.UTF8Encoding($true)
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $encBom
$settings.Indent = $false
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

# Через MemoryStream, а не прямо в файл: нужен шаг пост-обработки строки.
$memStream = New-Object System.IO.MemoryStream
$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
$xmlDoc.Save($writer)
$writer.Flush(); $writer.Close()

$xmlText = [System.Text.Encoding]::UTF8.GetString($memStream.ToArray())
$memStream.Close()
if ($xmlText.Length -gt 0 -and $xmlText[0] -eq [char]0xFEFF) { $xmlText = $xmlText.Substring(1) }
$xmlText = $xmlText.Replace('encoding="utf-8"', 'encoding="UTF-8"')
# Пустой элемент: XmlWriter отдаёт `<a />`, Конфигуратор пишет `<a/>`. Внутри
# CDATA/комментария ` />` может быть содержимым (там `>` не экранируется),
# поэтому они идут первыми ветками альтернации и возвращаются как есть.
$xmlText = [regex]::Replace($xmlText, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
# Целевой перевод строки: стиль файла-назначения — правка наследует его (#44/#46/#47),
# новый файл получает канон выгрузки CRLF. Зеркало _detect_xml_style в py-порту.
$targetEol = if ((Test-Path -LiteralPath $rootXmlFull.Path) -and ([System.IO.File]::ReadAllText($rootXmlFull.Path) -notmatch "`r`n")) { "`n" } else { "`r`n" }
$xmlText = ($xmlText -replace "`r`n", "`n") -replace "`n", $targetEol
[System.IO.File]::WriteAllText($rootXmlFull.Path, $xmlText, $encBom)

Write-Host "[OK] Макет $TemplateName удалён из $rootXmlPath"
