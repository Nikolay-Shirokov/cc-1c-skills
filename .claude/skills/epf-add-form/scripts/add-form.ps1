# epf-add-form v1.0 — Add managed form to 1C processor
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ProcessorName,

	[Parameter(Mandatory)]
	[string]$FormName,

	[string]$Synonym = $FormName,

	[switch]$Main,

	[string]$SrcDir = "src"
)

$ErrorActionPreference = "Stop"

# --- Проверки ---

$rootXmlPath = Join-Path $SrcDir "$ProcessorName.xml"
if (-not (Test-Path $rootXmlPath)) {
	Write-Error "Корневой файл обработки не найден: $rootXmlPath. Сначала выполните epf-init."
	exit 1
}

$processorDir = Join-Path $SrcDir $ProcessorName
$formsDir = Join-Path $processorDir "Forms"
$formMetaPath = Join-Path $formsDir "$FormName.xml"

if (Test-Path $formMetaPath) {
	Write-Error "Форма уже существует: $formMetaPath"
	exit 1
}

# --- Создание каталогов ---

$formDir = Join-Path $formsDir $FormName
$formExtDir = Join-Path $formDir "Ext"
$formModuleDir = Join-Path $formExtDir "Form"

New-Item -ItemType Directory -Path $formModuleDir -Force | Out-Null

# --- Кодировка ---

$encBom = New-Object System.Text.UTF8Encoding($true)
$encNoBom = New-Object System.Text.UTF8Encoding($false)

# --- 1. Метаданные формы (Forms/<FormName>.xml) ---

$formUuid = [guid]::NewGuid().ToString()

$formMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Form uuid="$formUuid">
		<Properties>
			<Name>$FormName</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$Synonym</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<FormType>Managed</FormType>
			<IncludeHelpInContents>false</IncludeHelpInContents>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
				<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>
			</UsePurposes>
			<ExtendedPresentation/>
		</Properties>
	</Form>
</MetaDataObject>
"@

[System.IO.File]::WriteAllText($formMetaPath, $formMetaXml, $encBom)

# --- 2. Описание формы (Forms/<FormName>/Ext/Form.xml) ---

$formXmlPath = Join-Path $formExtDir "Form.xml"

$formXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Form xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<AutoCommandBar name="ФормаКоманднаяПанель" id="-1">
		<Autofill>true</Autofill>
	</AutoCommandBar>
	<ChildItems/>
	<Attributes>
		<Attribute name="Объект" id="1">
			<Type>
				<v8:Type>cfg:ExternalDataProcessorObject.$ProcessorName</v8:Type>
			</Type>
			<MainAttribute>true</MainAttribute>
		</Attribute>
	</Attributes>
</Form>
"@

[System.IO.File]::WriteAllText($formXmlPath, $formXml, $encBom)

# --- 3. BSL-модуль (Forms/<FormName>/Ext/Form/Module.bsl) ---

$modulePath = Join-Path $formModuleDir "Module.bsl"

$moduleBsl = @"
#Область ОбработчикиСобытийФормы

#КонецОбласти

#Область ОбработчикиСобытийЭлементовФормы

#КонецОбласти

#Область ОбработчикиКомандФормы

#КонецОбласти

#Область ОбработчикиОповещений

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти
"@

[System.IO.File]::WriteAllText($modulePath, $moduleBsl, $encBom)

# --- 4. Модификация корневого XML ---

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

# Добавить <Form> перед первым <Template>, или в конец
$formElem = $xmlDoc.CreateElement("Form", "http://v8.1c.ru/8.3/MDClasses")
$formElem.InnerText = $FormName

$firstTemplate = $childObjects.SelectSingleNode("md:Template", $nsMgr)
if ($firstTemplate) {
	# Вставить перед Template, добавив перенос строки + табуляцию
	$whitespace = $xmlDoc.CreateWhitespace("`n`t`t`t")
	$childObjects.InsertBefore($whitespace, $firstTemplate) | Out-Null
	$childObjects.InsertBefore($formElem, $whitespace) | Out-Null
} else {
	# Добавить в конец ChildObjects
	# Если ChildObjects пустой (самозакрывающийся), нужно добавить форматирование
	if ($childObjects.ChildNodes.Count -eq 0) {
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
		$childObjects.AppendChild($formElem) | Out-Null
		$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
	} else {
		$lastChild = $childObjects.LastChild
		# Вставить перед закрывающим whitespace (если есть), или в конец
		if ($lastChild.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
			$childObjects.InsertBefore($xmlDoc.CreateWhitespace("`n`t`t`t"), $lastChild) | Out-Null
			$childObjects.InsertBefore($formElem, $lastChild) | Out-Null
		} else {
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t`t")) | Out-Null
			$childObjects.AppendChild($formElem) | Out-Null
			$childObjects.AppendChild($xmlDoc.CreateWhitespace("`n`t`t")) | Out-Null
		}
	}
}

# Обновить DefaultForm: явно при -Main, или автоматически если это первая форма
$existingForms = $childObjects.SelectNodes("md:Form", $nsMgr)
$isFirstForm = ($existingForms.Count -eq 1)

if ($Main -or $isFirstForm) {
	$defaultForm = $xmlDoc.SelectSingleNode("//md:DefaultForm", $nsMgr)
	if ($defaultForm) {
		$defaultForm.InnerText = "ExternalDataProcessor.$ProcessorName.Form.$FormName"
	}
}

# Сохранить с BOM
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = $encBom
$settings.Indent = $false  # Preserve original whitespace

$stream = New-Object System.IO.FileStream($rootXmlFull.Path, [System.IO.FileMode]::Create)
$writer = [System.Xml.XmlWriter]::Create($stream, $settings)
$xmlDoc.Save($writer)
$writer.Close()
$stream.Close()

Write-Host "[OK] Создана форма: $FormName"
Write-Host "     Метаданные: $formMetaPath"
Write-Host "     Описание:   $formXmlPath"
Write-Host "     Модуль:     $modulePath"
if ($Main -or $isFirstForm) {
	Write-Host "     DefaultForm обновлён"
}
