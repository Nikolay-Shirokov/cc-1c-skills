# subsystem-compile v1.5 — Create 1C subsystem from JSON definition
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[string]$DefinitionFile,
	[string]$Value,
	[Parameter(Mandatory)][string]$OutputDir,
	[string]$Parent,
	[switch]$NoValidate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 1. Load JSON ---
if ($DefinitionFile -and $Value) {
	Write-Error "Cannot use both -DefinitionFile and -Value"
	exit 1
}
if (-not $DefinitionFile -and -not $Value) {
	Write-Error "Either -DefinitionFile or -Value is required"
	exit 1
}

if ($DefinitionFile) {
	if (-not [System.IO.Path]::IsPathRooted($DefinitionFile)) {
		$DefinitionFile = Join-Path (Get-Location).Path $DefinitionFile
	}
	if (-not (Test-Path $DefinitionFile)) {
		Write-Error "Definition file not found: $DefinitionFile"
		exit 1
	}
	$json = Get-Content -Raw -Encoding UTF8 $DefinitionFile
} else {
	$json = $Value
}

$def = $json | ConvertFrom-Json

if (-not $def.name) {
	Write-Error "JSON must have 'name' field"
	exit 1
}

$objName = "$($def.name)"

# Resolve OutputDir
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
	$OutputDir = Join-Path (Get-Location).Path $OutputDir
}

# --- 2. XML helpers ---
$script:xml = New-Object System.Text.StringBuilder 8192

function X([string]$text) {
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml([string]$s) {
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Split-CamelCase([string]$name) {
	if (-not $name) { return $name }
	$result = [regex]::Replace($name, '([a-z\u0430-\u044F\u0451])([A-Z\u0410-\u042F\u0401])', '$1 $2')
	if ($result.Length -gt 1) {
		$result = $result.Substring(0,1) + $result.Substring(1).ToLower()
	}
	return $result
}

function Emit-MLText([string]$indent, [string]$tag, [string]$text) {
	if (-not $text) {
		X "$indent<$tag/>"
		return
	}
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

function New-Guid-String {
	return [System.Guid]::NewGuid().ToString()
}

function Write-ChildSubsystemStub([string]$childPath, [string]$childName, [string]$formatVersion, [System.Text.Encoding]$utf8Bom) {
	$childUuid = New-Guid-String
	$sb = New-Object System.Text.StringBuilder 2048
	[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
	[void]$sb.AppendLine("<MetaDataObject xmlns=`"http://v8.1c.ru/8.3/MDClasses`" xmlns:app=`"http://v8.1c.ru/8.2/managed-application/core`" xmlns:cfg=`"http://v8.1c.ru/8.1/data/enterprise/current-config`" xmlns:cmi=`"http://v8.1c.ru/8.2/managed-application/cmi`" xmlns:ent=`"http://v8.1c.ru/8.1/data/enterprise`" xmlns:lf=`"http://v8.1c.ru/8.2/managed-application/logform`" xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`" xmlns:xen=`"http://v8.1c.ru/8.3/xcf/enums`" xmlns:xpr=`"http://v8.1c.ru/8.3/xcf/predef`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" version=`"$formatVersion`">")
	[void]$sb.AppendLine("`t<Subsystem uuid=`"$childUuid`">")
	[void]$sb.AppendLine("`t`t<Properties>")
	[void]$sb.AppendLine("`t`t`t<Name>$(Esc-Xml $childName)</Name>")
	[void]$sb.AppendLine("`t`t`t<Synonym/>")
	[void]$sb.AppendLine("`t`t`t<Comment/>")
	[void]$sb.AppendLine("`t`t`t<IncludeHelpInContents>true</IncludeHelpInContents>")
	[void]$sb.AppendLine("`t`t`t<IncludeInCommandInterface>true</IncludeInCommandInterface>")
	[void]$sb.AppendLine("`t`t`t<UseOneCommand>false</UseOneCommand>")
	[void]$sb.AppendLine("`t`t`t<Explanation/>")
	[void]$sb.AppendLine("`t`t`t<Picture/>")
	[void]$sb.AppendLine("`t`t`t<Content/>")
	[void]$sb.AppendLine("`t`t</Properties>")
	[void]$sb.AppendLine("`t`t<ChildObjects/>")
	[void]$sb.AppendLine("`t</Subsystem>")
	[void]$sb.AppendLine('</MetaDataObject>')
	[System.IO.File]::WriteAllText($childPath, $sb.ToString(), $utf8Bom)
}

# --- 3. Content type normalization (plural→singular, Russian→English) ---
$script:contentTypeMap = @{
	# Plural English → Singular
	"Catalogs"                     = "Catalog"
	"Documents"                    = "Document"
	"Enums"                        = "Enum"
	"Constants"                    = "Constant"
	"Reports"                      = "Report"
	"DataProcessors"               = "DataProcessor"
	"InformationRegisters"         = "InformationRegister"
	"AccumulationRegisters"        = "AccumulationRegister"
	"AccountingRegisters"          = "AccountingRegister"
	"CalculationRegisters"         = "CalculationRegister"
	"ChartsOfAccounts"             = "ChartOfAccounts"
	"ChartsOfCharacteristicTypes"  = "ChartOfCharacteristicTypes"
	"ChartsOfCalculationTypes"     = "ChartOfCalculationTypes"
	"BusinessProcesses"            = "BusinessProcess"
	"Tasks"                        = "Task"
	"ExchangePlans"                = "ExchangePlan"
	"DocumentJournals"             = "DocumentJournal"
	"CommonModules"                = "CommonModule"
	"CommonCommands"               = "CommonCommand"
	"CommonForms"                  = "CommonForm"
	"CommonPictures"               = "CommonPicture"
	"CommonTemplates"              = "CommonTemplate"
	"CommonAttributes"             = "CommonAttribute"
	"CommandGroups"                = "CommandGroup"
	"Roles"                        = "Role"
	"SessionParameters"            = "SessionParameter"
	"FilterCriteria"               = "FilterCriterion"
	"XDTOPackages"                 = "XDTOPackage"
	"WebServices"                  = "WebService"
	"HTTPServices"                 = "HTTPService"
	"WSReferences"                 = "WSReference"
	"EventSubscriptions"           = "EventSubscription"
	"ScheduledJobs"                = "ScheduledJob"
	"SettingsStorages"             = "SettingsStorage"
	"FunctionalOptions"            = "FunctionalOption"
	"FunctionalOptionsParameters"  = "FunctionalOptionsParameter"
	"DefinedTypes"                 = "DefinedType"
	"DocumentNumerators"           = "DocumentNumerator"
	"Sequences"                    = "Sequence"
	"Subsystems"                   = "Subsystem"
	"StyleItems"                   = "StyleItem"
	"IntegrationServices"          = "IntegrationService"
	# Russian singular → English
	"Справочник"                   = "Catalog"
	"Каталог"                      = "Catalog"
	"Документ"                     = "Document"
	"Перечисление"                 = "Enum"
	"Константа"                    = "Constant"
	"Отчёт"                        = "Report"
	"Отчет"                        = "Report"
	"Обработка"                    = "DataProcessor"
	"РегистрСведений"              = "InformationRegister"
	"РегистрНакопления"            = "AccumulationRegister"
	"РегистрБухгалтерии"           = "AccountingRegister"
	"РегистрРасчёта"               = "CalculationRegister"
	"РегистрРасчета"               = "CalculationRegister"
	"ПланСчетов"                   = "ChartOfAccounts"
	"ПланВидовХарактеристик"       = "ChartOfCharacteristicTypes"
	"ПланВидовРасчёта"             = "ChartOfCalculationTypes"
	"ПланВидовРасчета"             = "ChartOfCalculationTypes"
	"БизнесПроцесс"                = "BusinessProcess"
	"Задача"                       = "Task"
	"ПланОбмена"                   = "ExchangePlan"
	"ЖурналДокументов"             = "DocumentJournal"
	"ОбщийМодуль"                  = "CommonModule"
	"ОбщаяКоманда"                 = "CommonCommand"
	"ОбщаяФорма"                   = "CommonForm"
	"ОбщаяКартинка"                = "CommonPicture"
	"ОбщийМакет"                   = "CommonTemplate"
	"ОбщийРеквизит"                = "CommonAttribute"
	"ГруппаКоманд"                 = "CommandGroup"
	"Роль"                         = "Role"
	"ПараметрСеанса"               = "SessionParameter"
	"КритерийОтбора"               = "FilterCriterion"
	"ПакетXDTO"                    = "XDTOPackage"
	"ВебСервис"                    = "WebService"
	"HTTPСервис"                   = "HTTPService"
	"WSСсылка"                     = "WSReference"
	"ПодпискаНаСобытие"            = "EventSubscription"
	"РегламентноеЗадание"          = "ScheduledJob"
	"ХранилищеНастроек"            = "SettingsStorage"
	"ФункциональнаяОпция"          = "FunctionalOption"
	"ПараметрФункциональныхОпций"  = "FunctionalOptionsParameter"
	"ОпределяемыйТип"              = "DefinedType"
	"НумераторДокументов"          = "DocumentNumerator"
	"Последовательность"           = "Sequence"
	"Подсистема"                   = "Subsystem"
	"ЭлементСтиля"                 = "StyleItem"
	"СервисИнтеграции"             = "IntegrationService"
	# Russian plural → English
	"Справочники"                  = "Catalog"
	"Документы"                    = "Document"
	"Перечисления"                 = "Enum"
	"Константы"                    = "Constant"
	"Отчёты"                       = "Report"
	"Отчеты"                       = "Report"
	"Обработки"                    = "DataProcessor"
	"РегистрыСведений"             = "InformationRegister"
	"РегистрыНакопления"           = "AccumulationRegister"
	"РегистрыБухгалтерии"          = "AccountingRegister"
	"РегистрыРасчёта"              = "CalculationRegister"
	"РегистрыРасчета"              = "CalculationRegister"
	"ПланыСчетов"                  = "ChartOfAccounts"
	"ПланыВидовХарактеристик"      = "ChartOfCharacteristicTypes"
	"ПланыВидовРасчёта"            = "ChartOfCalculationTypes"
	"ПланыВидовРасчета"            = "ChartOfCalculationTypes"
	"БизнесПроцессы"               = "BusinessProcess"
	"Задачи"                       = "Task"
	"ПланыОбмена"                  = "ExchangePlan"
	"ЖурналыДокументов"            = "DocumentJournal"
	"ОбщиеМодули"                  = "CommonModule"
	"ОбщиеКоманды"                 = "CommonCommand"
	"ОбщиеФормы"                   = "CommonForm"
	"ОбщиеКартинки"                = "CommonPicture"
	"ОбщиеМакеты"                  = "CommonTemplate"
	"ОбщиеРеквизиты"               = "CommonAttribute"
	"ГруппыКоманд"                 = "CommandGroup"
	"Роли"                         = "Role"
	"ПараметрыСеанса"              = "SessionParameter"
	"КритерииОтбора"               = "FilterCriterion"
	"ПакетыXDTO"                   = "XDTOPackage"
	"ВебСервисы"                   = "WebService"
	"HTTPСервисы"                  = "HTTPService"
	"WSСсылки"                     = "WSReference"
	"ПодпискиНаСобытия"            = "EventSubscription"
	"РегламентныеЗадания"          = "ScheduledJob"
	"ХранилищаНастроек"            = "SettingsStorage"
	"ФункциональныеОпции"          = "FunctionalOption"
	"ОпределяемыеТипы"             = "DefinedType"
	"Подсистемы"                   = "Subsystem"
	"ЭлементыСтиля"                = "StyleItem"
	"СервисыИнтеграции"            = "IntegrationService"
}

function Normalize-ContentRef([string]$ref) {
	if (-not $ref -or -not $ref.Contains('.')) { return $ref }
	$dotIdx = $ref.IndexOf('.')
	$typePart = $ref.Substring(0, $dotIdx)
	$namePart = $ref.Substring($dotIdx + 1)
	if ($script:contentTypeMap.ContainsKey($typePart)) {
		$typePart = $script:contentTypeMap[$typePart]
	}
	return "$typePart.$namePart"
}

# --- 4. Resolve defaults ---
$synonym = if ($def.synonym) { "$($def.synonym)" } else { Split-CamelCase $objName }
$comment = if ($def.comment) { "$($def.comment)" } else { "" }
$includeHelpInContents = "true"
$includeInCI = if ($null -ne $def.includeInCommandInterface) { "$($def.includeInCommandInterface)".ToLower() } else { "true" }
$useOneCommand = if ($null -ne $def.useOneCommand) { "$($def.useOneCommand)".ToLower() } else { "false" }
$explanation = if ($def.explanation) { "$($def.explanation)" } else { "" }
$picture = if ($def.picture) { "$($def.picture)" } else { "" }

# Synonym: accept "objects" as alias for "content"
if (-not $def.content -and $def.objects) { $def | Add-Member -NotePropertyName content -NotePropertyValue $def.objects }

$contentItems = @()
$normalizedCount = 0
if ($def.content) {
	foreach ($c in $def.content) {
		$raw = "$c"
		$normalized = Normalize-ContentRef $raw
		if ($normalized -ne $raw) {
			Write-Host "[NORM] Content: $raw -> $normalized"
			$normalizedCount++
		}
		$contentItems += $normalized
	}
}
if ($normalizedCount -gt 0) {
	Write-Host "[INFO] Normalized $normalizedCount content reference(s) to singular English form"
}

$children = @()
if ($def.children) {
	foreach ($ch in $def.children) { $children += "$ch" }
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

$formatVersion = Detect-FormatVersion $OutputDir

# --- 4. Build XML ---
$uuid = New-Guid-String
$indent = "`t`t`t"

X '<?xml version="1.0" encoding="UTF-8"?>'
X "<MetaDataObject xmlns=`"http://v8.1c.ru/8.3/MDClasses`" xmlns:app=`"http://v8.1c.ru/8.2/managed-application/core`" xmlns:cfg=`"http://v8.1c.ru/8.1/data/enterprise/current-config`" xmlns:cmi=`"http://v8.1c.ru/8.2/managed-application/cmi`" xmlns:ent=`"http://v8.1c.ru/8.1/data/enterprise`" xmlns:lf=`"http://v8.1c.ru/8.2/managed-application/logform`" xmlns:style=`"http://v8.1c.ru/8.1/data/ui/style`" xmlns:sys=`"http://v8.1c.ru/8.1/data/ui/fonts/system`" xmlns:v8=`"http://v8.1c.ru/8.1/data/core`" xmlns:v8ui=`"http://v8.1c.ru/8.1/data/ui`" xmlns:web=`"http://v8.1c.ru/8.1/data/ui/colors/web`" xmlns:win=`"http://v8.1c.ru/8.1/data/ui/colors/windows`" xmlns:xen=`"http://v8.1c.ru/8.3/xcf/enums`" xmlns:xpr=`"http://v8.1c.ru/8.3/xcf/predef`" xmlns:xr=`"http://v8.1c.ru/8.3/xcf/readable`" xmlns:xs=`"http://www.w3.org/2001/XMLSchema`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`" version=`"$formatVersion`">"
X "`t<Subsystem uuid=`"$uuid`">"
X "`t`t<Properties>"

# Name
X "`t`t`t<Name>$(Esc-Xml $objName)</Name>"

# Synonym
Emit-MLText "`t`t`t" "Synonym" $synonym

# Comment
if ($comment) {
	X "`t`t`t<Comment>$(Esc-Xml $comment)</Comment>"
} else {
	X "`t`t`t<Comment/>"
}

# Boolean properties
X "`t`t`t<IncludeHelpInContents>$includeHelpInContents</IncludeHelpInContents>"
X "`t`t`t<IncludeInCommandInterface>$includeInCI</IncludeInCommandInterface>"
X "`t`t`t<UseOneCommand>$useOneCommand</UseOneCommand>"

# Explanation
Emit-MLText "`t`t`t" "Explanation" $explanation

# Picture
if ($picture) {
	X "`t`t`t<Picture>"
	X "`t`t`t`t<xr:Ref>$picture</xr:Ref>"
	X "`t`t`t`t<xr:LoadTransparent>false</xr:LoadTransparent>"
	X "`t`t`t</Picture>"
} else {
	X "`t`t`t<Picture/>"
}

# Content
if ($contentItems.Count -gt 0) {
	X "`t`t`t<Content>"
	foreach ($item in $contentItems) {
		X "`t`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">$(Esc-Xml $item)</xr:Item>"
	}
	X "`t`t`t</Content>"
} else {
	X "`t`t`t<Content/>"
}

X "`t`t</Properties>"

# ChildObjects
if ($children.Count -gt 0) {
	X "`t`t<ChildObjects>"
	foreach ($ch in $children) {
		X "`t`t`t<Subsystem>$(Esc-Xml $ch)</Subsystem>"
	}
	X "`t`t</ChildObjects>"
} else {
	X "`t`t<ChildObjects/>"
}

X "`t</Subsystem>"
X '</MetaDataObject>'

# --- 5. Write files ---

# Determine target directory
if ($Parent) {
	# Nested subsystem
	if (-not [System.IO.Path]::IsPathRooted($Parent)) {
		$Parent = Join-Path (Get-Location).Path $Parent
	}
	if (-not (Test-Path $Parent)) {
		Write-Error "Parent subsystem not found: $Parent"
		exit 1
	}
	$parentDir = [System.IO.Path]::GetDirectoryName($Parent)
	$parentBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Parent)
	$subsDir = Join-Path (Join-Path $parentDir $parentBaseName) "Subsystems"
} else {
	# Top-level subsystem
	$subsDir = Join-Path $OutputDir "Subsystems"
}

if (-not (Test-Path $subsDir)) {
	New-Item -ItemType Directory -Path $subsDir -Force | Out-Null
}

$targetXml = Join-Path $subsDir "$objName.xml"

# Write XML
$xmlContent = $script:xml.ToString()
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($targetXml, $xmlContent, $utf8Bom)
Write-Host "[OK] Created: $targetXml"

# Create subdirectory and stub files for children if they exist
if ($children.Count -gt 0) {
	$childSubsDir = Join-Path (Join-Path $subsDir $objName) "Subsystems"
	if (-not (Test-Path $childSubsDir)) {
		New-Item -ItemType Directory -Path $childSubsDir -Force | Out-Null
		Write-Host "[OK] Created directory: $childSubsDir"
	}
	$seen = @{}
	foreach ($ch in $children) {
		if ($seen.ContainsKey($ch)) { continue }
		$seen[$ch] = $true
		$childXml = Join-Path $childSubsDir "$ch.xml"
		if (-not (Test-Path $childXml)) {
			Write-ChildSubsystemStub $childXml $ch $formatVersion $utf8Bom
			Write-Host "[OK] Created stub: $childXml"
		}
	}
}

# --- 6. Register in parent ---
$parentXmlPath = $null
if ($Parent) {
	$parentXmlPath = $Parent
} else {
	$configXml = Join-Path $OutputDir "Configuration.xml"
	if (Test-Path $configXml) {
		$parentXmlPath = $configXml
	}
}

if ($parentXmlPath -and (Test-Path $parentXmlPath)) {
	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $true
	$doc.Load($parentXmlPath)

	$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	# Find ChildObjects
	$childObjects = $null
	if ($Parent) {
		$childObjects = $doc.SelectSingleNode("//md:Subsystem/md:ChildObjects", $ns)
	} else {
		$childObjects = $doc.SelectSingleNode("//md:Configuration/md:ChildObjects", $ns)
	}

	if ($childObjects) {
		# Check for self-closing tag
		$isSelfClosing = (-not $childObjects.HasChildNodes) -or ($childObjects.IsEmpty)

		# Check if already registered
		$alreadyExists = $false
		foreach ($child in $childObjects.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Subsystem" -and $child.InnerText -eq $objName) {
				$alreadyExists = $true
				break
			}
		}

		if (-not $alreadyExists) {
			$newEl = $doc.CreateElement("Subsystem", "http://v8.1c.ru/8.3/MDClasses")
			$newEl.InnerText = $objName

			if ($isSelfClosing) {
				# Expand self-closing tag
				$parentIndent = ""
				$prev = $childObjects.PreviousSibling
				if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
					if ($prev.Value -match '(\t+)$') { $parentIndent = $Matches[1] }
				}
				$childIndent = "$parentIndent`t"
				$ws1 = $doc.CreateWhitespace("`r`n$childIndent")
				$ws2 = $doc.CreateWhitespace("`r`n$parentIndent")
				$childObjects.AppendChild($ws1) | Out-Null
				$childObjects.AppendChild($newEl) | Out-Null
				$childObjects.AppendChild($ws2) | Out-Null
			} else {
				# Insert before trailing whitespace
				$childIndent = "`t`t`t"
				foreach ($child in $childObjects.ChildNodes) {
					if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
						if ($child.Value -match '^\r?\n(\t+)') { $childIndent = $Matches[1]; break }
					}
				}
				$trailing = $childObjects.LastChild
				$ws = $doc.CreateWhitespace("`r`n$childIndent")
				if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
					$childObjects.InsertBefore($ws, $trailing) | Out-Null
					$childObjects.InsertBefore($newEl, $trailing) | Out-Null
				} else {
					$childObjects.AppendChild($ws) | Out-Null
					$childObjects.AppendChild($newEl) | Out-Null
				}
			}

			# Save parent XML
			$settings = New-Object System.Xml.XmlWriterSettings
			$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
			$settings.Indent = $false
			$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

			$memStream = New-Object System.IO.MemoryStream
			$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
			$doc.Save($writer)
			$writer.Flush(); $writer.Close()

			$bytes = $memStream.ToArray()
			$memStream.Close()
			$text = [System.Text.Encoding]::UTF8.GetString($bytes)
			if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
			$text = $text.Replace('encoding="utf-8"', 'encoding="UTF-8"')
			[System.IO.File]::WriteAllText($parentXmlPath, $text, $utf8Bom)

			Write-Host "[OK] Registered in: $parentXmlPath"
		} else {
			Write-Host "[SKIP] Already registered in: $parentXmlPath"
		}
	} else {
		Write-Host "[WARN] ChildObjects not found in: $parentXmlPath"
	}
} else {
	Write-Host "[INFO] No parent XML to register in"
}

# --- 7. Auto-validate ---
if (-not $NoValidate) {
	$validateScript = Join-Path (Join-Path $PSScriptRoot "..\..\subsystem-validate") "scripts\subsystem-validate.ps1"
	$validateScript = [System.IO.Path]::GetFullPath($validateScript)
	if (Test-Path $validateScript) {
		Write-Host ""
		Write-Host "--- Running subsystem-validate ---"
		& powershell.exe -NoProfile -File $validateScript -SubsystemPath $targetXml
	}
}

Write-Host ""
Write-Host "=== subsystem-compile summary ==="
Write-Host "  Name:     $objName"
Write-Host "  UUID:     $uuid"
Write-Host "  Content:  $($contentItems.Count) objects"
Write-Host "  Children: $($children.Count)"
Write-Host "  File:     $targetXml"
exit 0
