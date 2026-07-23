# form-remove v1.4 — Remove form from 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias("ProcessorName")]
	[string]$ObjectName,

	[Parameter(Mandatory)]
	[string]$FormName,

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
$formsDir = Join-Path $processorDir "Forms"
$formMetaPath = Join-Path $formsDir "$FormName.xml"
$formDir = Join-Path $formsDir $FormName

if (-not (Test-Path $formMetaPath)) {
	Write-Error "Метаданные формы не найдены: $formMetaPath"
	exit 1
}

# --- Удаление файлов ---

if (Test-Path $formDir) {
	Remove-Item -Path $formDir -Recurse -Force
	Write-Host "[OK] Удалён каталог: $formDir"
}

Remove-Item -Path $formMetaPath -Force
Write-Host "[OK] Удалён файл: $formMetaPath"

# --- Модификация корневого XML ---

$rootXmlFull = Resolve-Path $rootXmlPath
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($rootXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

# Удалить <Form>FormName</Form> из ChildObjects
$formNodes = $xmlDoc.SelectNodes("//md:ChildObjects/md:Form", $nsMgr)
foreach ($node in $formNodes) {
	if ($node.InnerText -eq $FormName) {
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

# Очистить любые Default*/Auxiliary* form-слоты, указывавшие на удалённую форму
# (form-add пишет свойство по назначению: DefaultObjectForm/DefaultListForm/
#  DefaultChoiceForm/DefaultRecordForm/DefaultForm — не только generic DefaultForm).
$formRefRe = "Form\.$([regex]::Escape($FormName))$"
foreach ($node in $xmlDoc.SelectNodes("//md:*", $nsMgr)) {
	if ($node.LocalName -like "*Form" -and $node.InnerText -and $node.InnerText -match $formRefRe) {
		$node.InnerText = ""
	}
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

Write-Host "[OK] Форма $FormName удалена из $rootXmlPath"
