# form-remove v1.10 — Remove form from 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias("ProcessorName")]
	[string]$ObjectName,

	[Parameter(Mandatory)]
	[string]$FormName,

	[string]$SrcDir = "src",

	[switch]$Force
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

# --- Загрузка корневого XML: вид и имя объекта ---

$rootXmlFull = Resolve-Path $rootXmlPath
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($rootXmlFull.Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

$typeNode = $null
foreach ($c in $xmlDoc.DocumentElement.ChildNodes) {
	if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) { $typeNode = $c; break }
}
if (-not $typeNode) {
	Write-Error "Не удалось определить вид объекта в $rootXmlPath"
	exit 1
}
$mdType = $typeNode.LocalName
$nameNode = $typeNode.SelectSingleNode("md:Properties/md:Name", $nsMgr)
$objMetaName = if ($nameNode -and $nameNode.InnerText.Trim()) { $nameNode.InnerText.Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($rootXmlPath) }

# Полная ссылка на форму. Матч по ней целиком, а не по хвосту "Form.<Имя>": иначе при
# удалении своей ФормаСписка обнулялась бы и ссылка на DocumentJournal.Ж.Form.ФормаСписка.
$formRef = "$mdType.$objMetaName.Form.$FormName"

# --- Чистка ссылок и сохранение в стиле файла-источника ---

# Каноничное «не задано» зависит от файла: в корневом XML объекта и в Configuration.xml
# пустой слот штатен (164 508 пустых на корпус), а внутри Ext/Form.xml пустых <ChoiceForm/>
# и <SettingsStorage/> нет ни одного — там свойство просто отсутствует.
function Clear-FormRefs {
	param([System.Xml.XmlDocument]$doc, [string]$ref)

	$isFormFile = $doc.DocumentElement -and $doc.DocumentElement.LocalName -eq "Form"
	$touched = @()
	foreach ($node in @($doc.SelectNodes("//*"))) {
		if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
		if ($node.SelectNodes("*").Count -gt 0) { continue }   # только листья
		# Сравнение регистронезависимое — как у платформы (в py-порту .lower()).
		if ($node.InnerText.Trim() -ne $ref) { continue }

		$ln = $node.LocalName
		$parent = $node.ParentNode
		if ($ln -eq "Form" -and $parent -and $parent.LocalName -eq "Item") {
			$touched += "$($parent.LocalName)/$ln"
			Remove-NodeWithIndent $parent
		} elseif ($isFormFile) {
			$touched += $ln
			Remove-NodeWithIndent $node
		} else {
			# IsEmpty, а не InnerText="": пустая строка сериализуется парой <Tag></Tag>, а
			# Конфигуратор пустых пар не пишет (0 на 476 942 XML корпуса) — нужен <Tag/>.
			$touched += $ln
			$node.IsEmpty = $true
		}
	}
	return $touched
}

function Remove-NodeWithIndent {
	param([System.Xml.XmlNode]$node)
	$parent = $node.ParentNode
	if (-not $parent) { return }
	$prev = $node.PreviousSibling
	if ($prev -and $prev.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
		$parent.RemoveChild($prev) | Out-Null
	}
	$parent.RemoveChild($node) | Out-Null
	# Опустевший контейнер: остаётся отступ-whitespace, и XmlWriter пишет пару
	# <ChildObjects>\n\t\t</ChildObjects>. Платформа пишет только <ChildObjects/>
	# (1394 самозакрывающихся на acc+erp, пустых пар ни в одной форме — 0).
	if ($parent.SelectNodes("*").Count -eq 0) { $parent.IsEmpty = $true }
}

function Save-XmlPreservingStyle {
	param([System.Xml.XmlDocument]$doc, [string]$path)

	$encBom = New-Object System.Text.UTF8Encoding($true)
	$settings = New-Object System.Xml.XmlWriterSettings
	$settings.Encoding = $encBom
	$settings.Indent = $false
	$settings.NewLineHandling = [System.Xml.NewLineHandling]::None

	# Через MemoryStream, а не прямо в файл: нужен шаг пост-обработки строки.
	$memStream = New-Object System.IO.MemoryStream
	$writer = [System.Xml.XmlWriter]::Create($memStream, $settings)
	$doc.Save($writer)
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
	$targetEol = if ((Test-Path -LiteralPath $path) -and ([System.IO.File]::ReadAllText($path) -notmatch "`r`n")) { "`n" } else { "`r`n" }
	$xmlText = ($xmlText -replace "`r`n", "`n") -replace "`n", $targetEol
	[System.IO.File]::WriteAllText($path, $xmlText, $encBom)
}

# --- Поиск ссылок на форму по всей конфигурации ---

# Get-Item, а не Resolve-Path: последний оставляет короткое имя 8.3 (NSHIRO~1), а
# Get-ChildItem отдаёт длинное (nshirokov) — сравнение путей молча не совпадало.
function Get-LongPath {
	param([string]$path)
	if (-not (Test-Path -LiteralPath $path)) { return "" }
	return (Get-Item -LiteralPath $path -Force).FullName
}

# Корень конфигурации: обычно это сам SrcDir, но объект могут передать и из глубины.
$configDir = $null
$probe = Get-LongPath $SrcDir
for ($depth = 0; $depth -lt 4; $depth++) {
	if (-not $probe) { break }
	if (Test-Path (Join-Path $probe "Configuration.xml")) { $configDir = $probe; break }
	$probe = Split-Path $probe
}

$rootXmlLong = Get-LongPath $rootXmlFull.Path
$formMetaFull = Get-LongPath $formMetaPath
$formDirFull = Get-LongPath $formDir

$references = @()
if ($configDir) {
	# Полный обход, как в meta-remove: ссылки лежат и внутри Ext/Form.xml (ChoiceForm,
	# SettingsStorage), узкий скан по корневым XML их не видит.
	# EnumerateFiles, а не Get-ChildItem -Recurse: на ERP (73 904 XML) обход обёртками
	# занимает 180 с против 47 с — чтение файлов не узкое место, узкое место перечисление.
	$refPattern = '<([A-Za-z0-9_.]+)>' + [regex]::Escape($formRef) + '</'
	$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
	$scanned = 0
	foreach ($fp in [System.IO.Directory]::EnumerateFiles($configDir, "*.xml", [System.IO.SearchOption]::AllDirectories)) {
		if ($fp -eq $rootXmlLong) { continue }                          # свой файл чистится всегда
		if ($fp -eq $formMetaFull) { continue }                         # файлы удаляемой формы
		if ($formDirFull -and $fp.StartsWith($formDirFull)) { continue }
		$scanned++
		$content = [System.IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8)
		if (-not $content.Contains($formRef)) { continue }
		foreach ($m in [regex]::Matches($content, $refPattern)) {
			$references += @{ Path = $fp; Rel = $fp.Substring($configDir.Length + 1); Tag = $m.Groups[1].Value }
		}
	}
	$scanSw.Stop()
	if ($scanSw.Elapsed.TotalSeconds -ge 5) {
		Write-Host "[INFO] Проверено ссылок в $scanned файлах за $([math]::Round($scanSw.Elapsed.TotalSeconds, 1)) c"
	}
}

if ($references.Count -gt 0) {
	Write-Host "[WARN]  На форму $formRef ссылаются $($references.Count) раз(а):"
	foreach ($grp in ($references | Group-Object { "$($_.Rel)|$($_.Tag)" } | Sort-Object Name)) {
		$parts = $grp.Name.Split("|")
		$suffix = if ($grp.Count -gt 1) { " x$($grp.Count)" } else { "" }
		Write-Host "        $($parts[0]) — <$($parts[1])>$suffix"
	}
	Write-Host ""
	if (-not $Force) {
		Write-Host "[ERROR] Удаление остановлено: форма используется."
		Write-Host "        Решает пользователь: убрать ссылки, отказаться от удаления или"
		Write-Host "        повторить с -Force — тогда ссылки будут очищены."
		exit 1
	}
	Write-Host "[WARN]  -Force: ссылки будут очищены"
	Write-Host ""
} elseif (-not $configDir) {
	Write-Host "[WARN]  Корень конфигурации не найден — ссылки в других объектах не проверены"
}

# --- Удаление файлов ---

if (Test-Path $formDir) {
	Remove-Item -Path $formDir -Recurse -Force
	Write-Host "[OK] Удалён каталог: $formDir"
}

Remove-Item -Path $formMetaPath -Force
Write-Host "[OK] Удалён файл: $formMetaPath"

# --- Модификация корневого XML ---

# Удалить <Form>FormName</Form> из ChildObjects
$formNodes = $xmlDoc.SelectNodes("//md:ChildObjects/md:Form", $nsMgr)
foreach ($node in $formNodes) {
	if ($node.InnerText -eq $FormName) {
		Remove-NodeWithIndent $node
		break
	}
}

# Очистить слоты своего объекта, указывавшие на удалённую форму: Default*/Auxiliary*Form
# (form-add пишет свойство по назначению) и ChoiceForm у реквизитов.
Clear-FormRefs $xmlDoc $formRef | Out-Null

Save-XmlPreservingStyle $xmlDoc $rootXmlFull.Path

Write-Host "[OK] Форма $FormName удалена из $rootXmlPath"

# --- Чистка ссылок в других файлах (только с -Force) ---

if ($references.Count -gt 0) {
	foreach ($grp in ($references | Group-Object { $_.Path } | Sort-Object Name)) {
		$path = $grp.Name
		$doc = New-Object System.Xml.XmlDocument
		$doc.PreserveWhitespace = $true
		$doc.Load($path)
		$touched = @(Clear-FormRefs $doc $formRef)
		if ($touched.Count -eq 0) { continue }
		Save-XmlPreservingStyle $doc $path
		$rel = $path.Substring($configDir.Length + 1)
		Write-Host "[OK] Очищена ссылка в $rel — $(($touched | Sort-Object -Unique) -join ', ')"
	}
}
