# erf-init v1.8 — Init 1C external report scaffold (+write_xml_file/write_utf8_bom: общий эталон записи)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$Name,

	[string]$Synonym = $Name,

	[string]$SrcDir = "src",

	[switch]$WithSKD,

	# Версия формата выгрузки. Своей конфигурации у автономного отчёта нет, наследовать
	# версию неоткуда — поэтому её задают явно. Формы, макеты и справку внутри отчёта
	# навыки берут уже отсюда: их детектор читает version из корня этого файла.
	[string]$FormatVersion = "2.17"
)

$ErrorActionPreference = "Stop"

# --- Format version ---
# Проверенный диапазон: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница — docs/1c-configuration-spec.md,
# «Лестница версий». Версии ниже 2.17 (платформы 8.3.23 и старше) реальны, поэтому запретом их не
# закрываем: за пределами диапазона — ПРЕДУПРЕЖДЕНИЕ, скаффолд всё равно выпускается. Ошибка — только
# на нечисловое значение: это опечатка, а не версия.
$formatVerifiedMin = "2.17"
$formatVerifiedMax = "2.21"
# Версия формата как число: "2.20" → 220. Строковое сравнение неверно ("2.9" > "2.17").
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}
$formatRank = Get-FormatRank $FormatVersion

function Esc-XmlText {
	param([string]$s)
	# Эскейп ТЕКСТА элемента: только & < > — кавычку и апостроф платформа держит сырыми.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Проверка версии — ПОСЛЕ настройки кодировки консоли: иначе em-dash в сообщении уедет в вопросы.
# Пишем прямо в stderr, а не Write-Warning: в PS 5.1 предупреждение уходит в stdout, получает
# локализованный префикс и переносится по 80 символов — подстрока в тесте перестаёт находиться.
if ($formatRank -eq 0) {
	[Console]::Error.WriteLine("Malformed -FormatVersion '$FormatVersion' (expected N.N, e.g. 2.17)")
	exit 1
}
if ($formatRank -lt (Get-FormatRank $formatVerifiedMin) -or $formatRank -gt (Get-FormatRank $formatVerifiedMax)) {
	[Console]::Error.WriteLine("WARNING: Format version '$FormatVersion' is outside the tested range $formatVerifiedMin-$formatVerifiedMax — the scaffold is emitted as requested but was not verified on that platform")
}

$uuid1 = [guid]::NewGuid().ToString()
$uuid2 = [guid]::NewGuid().ToString()
$uuid3 = [guid]::NewGuid().ToString()
$uuid4 = [guid]::NewGuid().ToString()

# Объявления пространств имён — одной переменной: места эмиссии её только интерполируют.
$xmlnsDecl = 'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
# 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (после lf, перед style):
# платформа держит объявления по алфавиту, дописать в конец нельзя.
if ($formatRank -ge 221) {
	$xmlnsDecl = $xmlnsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}

# --- Формируем Properties ---

$mainDCSValue = ""
$childObjectsContent = ""

if ($WithSKD) {
	$mainDCSValue = "ExternalReport.$Name.Template.ОсновнаяСхемаКомпоновкиДанных"
	$childObjectsContent = @"

			<Template>ОсновнаяСхемаКомпоновкиДанных</Template>

"@
}

$mainDCSElement = if ($mainDCSValue) {
	"<MainDataCompositionSchema>$mainDCSValue</MainDataCompositionSchema>"
} else {
	"<MainDataCompositionSchema/>"
}

$childObjectsXml = if ($childObjectsContent) {
	"<ChildObjects>$childObjectsContent</ChildObjects>"
} else {
	"<ChildObjects/>"
}

$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $xmlnsDecl version="$FormatVersion">
	<ExternalReport uuid="$uuid1">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>e41aff26-25cf-4bb6-b6c1-3f478a75f374</xr:ClassId>
				<xr:ObjectId>$uuid2</xr:ObjectId>
			</xr:ContainedObject>
			<xr:GeneratedType name="ExternalReportObject.$Name" category="Object">
				<xr:TypeId>$uuid3</xr:TypeId>
				<xr:ValueId>$uuid4</xr:ValueId>
			</xr:GeneratedType>
		</InternalInfo>
		<Properties>
			<Name>$(Esc-XmlText $Name)</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$(Esc-XmlText $Synonym)</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<DefaultForm/>
			<AuxiliaryForm/>
			$mainDCSElement
			<DefaultSettingsForm/>
			<AuxiliarySettingsForm/>
			<DefaultVariantForm/>
			<VariantsStorage/>
			<SettingsStorage/>
		</Properties>
		$childObjectsXml
	</ExternalReport>
</MetaDataObject>
"@

$rootFile = Join-Path $SrcDir "$Name.xml"
$reportDir = Join-Path $SrcDir $Name

if (Test-Path $rootFile) {
	Write-Error "Файл уже существует: $rootFile"
	exit 1
}

if (-not (Test-Path $SrcDir)) {
	New-Item -ItemType Directory -Path $SrcDir -Force | Out-Null
}
$extDir = Join-Path $reportDir "Ext"
New-Item -ItemType Directory -Path $extDir -Force | Out-Null

$enc = New-Object System.Text.UTF8Encoding($true)
# XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.
#
# Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
# копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
function Write-XmlFile([string]$path, [string]$text, $encoding) {
	$t = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($path, $t.TrimEnd("`r", "`n"), $encoding)
}

Write-XmlFile (Resolve-Path $SrcDir | Join-Path -ChildPath "$Name.xml") $xml $enc

# --- Модуль объекта ---

$moduleBsl = @"
#Область ОписаниеПеременных

#КонецОбласти

#Область ПрограммныйИнтерфейс

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти
"@

$modulePath = Join-Path $extDir "ObjectModule.bsl"
# Модуль пишем в каноне платформы: CRLF в разделителях строк (корпус: 2643 CRLF,
# чисто-LF 0 из 3001). Хвостовой перевод НЕ навязываем — у платформы он
# неканоничен (1235 модулей с ним, 766 без). Шаблон берёт переводы строк из
# самого скрипта, а он в репозитории хранится с LF.
$moduleBsl = ($moduleBsl -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllText($modulePath, $moduleBsl, $enc)

Write-Host "[OK] Создан отчёт: $rootFile"
Write-Host "     Каталог: $reportDir"
Write-Host "     Модуль:  $modulePath"

# --- СКД-макет (если --WithSKD) ---

if ($WithSKD) {
	$templatesDir = Join-Path $reportDir "Templates"
	$skdName = "ОсновнаяСхемаКомпоновкиДанных"
	$skdMetaPath = Join-Path $templatesDir "$skdName.xml"
	$skdExtDir = Join-Path (Join-Path $templatesDir $skdName) "Ext"
	New-Item -ItemType Directory -Path $skdExtDir -Force | Out-Null

	$skdUuid = [guid]::NewGuid().ToString()

	$skdMetaXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject $xmlnsDecl version="$FormatVersion">
	<Template uuid="$skdUuid">
		<Properties>
			<Name>$skdName</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>Основная схема компоновки данных</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<TemplateType>DataCompositionSchema</TemplateType>
		</Properties>
	</Template>
</MetaDataObject>
"@

	Write-XmlFile $skdMetaPath $skdMetaXml $enc

	$skdContent = @"
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

	$skdFilePath = Join-Path $skdExtDir "Template.xml"
	Write-XmlFile $skdFilePath $skdContent $enc

	Write-Host "     СКД:     $skdMetaPath"
	Write-Host "     Тело:    $skdFilePath"
}
