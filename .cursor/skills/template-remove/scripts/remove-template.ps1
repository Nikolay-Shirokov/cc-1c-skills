# template-remove v1.2 — Remove template from 1C object
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

$stream = New-Object System.IO.FileStream($rootXmlFull.Path, [System.IO.FileMode]::Create)
$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
$xmlDoc.Save($writer)
$writer.Close()
$stream.Close()

Write-Host "[OK] Макет $TemplateName удалён из $rootXmlPath"
