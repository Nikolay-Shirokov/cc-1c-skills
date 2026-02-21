# cfe-init v1.0 — Create 1C configuration extension scaffold (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$Name,
	[string]$Synonym = $Name,
	[string]$NamePrefix,
	[string]$OutputDir = "src",
	[ValidateSet("Patch","Customization","AddOn")]
	[string]$Purpose = "Customization",
	[string]$Version,
	[string]$Vendor,
	[string]$CompatibilityMode = "Version8_3_24",
	[string]$ConfigPath,
	[switch]$NoRole
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Default NamePrefix ---
if (-not $NamePrefix) {
	$NamePrefix = "${Name}_"
}

# --- Resolve output dir ---
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
	$OutputDir = Join-Path (Get-Location).Path $OutputDir
}

# --- Check existing ---
$cfgFile = Join-Path $OutputDir "Configuration.xml"
if (Test-Path $cfgFile) {
	Write-Error "Configuration.xml already exists: $cfgFile"
	exit 1
}

# --- Resolve ConfigPath ---
$baseLangUuid = "00000000-0000-0000-0000-000000000000"
if ($ConfigPath) {
	if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
		$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
	}
	if (Test-Path $ConfigPath -PathType Container) {
		$candidate = Join-Path $ConfigPath "Configuration.xml"
		if (Test-Path $candidate) { $ConfigPath = $candidate }
		else { Write-Error "No Configuration.xml in config directory: $ConfigPath"; exit 1 }
	}
	if (-not (Test-Path $ConfigPath)) { Write-Error "Config file not found: $ConfigPath"; exit 1 }
	$cfgDir = Split-Path (Resolve-Path $ConfigPath).Path -Parent

	# 3a. Read Language UUID from base config
	$baseLangFile = Join-Path (Join-Path $cfgDir "Languages") "Русский.xml"
	if (Test-Path $baseLangFile) {
		$baseLangDoc = New-Object System.Xml.XmlDocument
		$baseLangDoc.PreserveWhitespace = $false
		$baseLangDoc.Load($baseLangFile)
		$langEl = $null
		foreach ($c in $baseLangDoc.DocumentElement.ChildNodes) {
			if ($c.NodeType -eq 'Element' -and $c.LocalName -eq 'Language') { $langEl = $c; break }
		}
		if ($langEl) {
			$baseLangUuid = $langEl.GetAttribute("uuid")
			Write-Host "[INFO] Base config Language UUID: $baseLangUuid"
		} else {
			Write-Host "[WARN] No <Language> element in $baseLangFile"
		}
	} else {
		Write-Host "[WARN] Base config language not found: $baseLangFile"
	}

	# 3b. Read CompatibilityMode from base config
	$baseCfgDoc = New-Object System.Xml.XmlDocument
	$baseCfgDoc.PreserveWhitespace = $false
	$baseCfgDoc.Load((Resolve-Path $ConfigPath).Path)
	$baseCfgNs = New-Object System.Xml.XmlNamespaceManager($baseCfgDoc.NameTable)
	$baseCfgNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$compatNode = $baseCfgDoc.SelectSingleNode("//md:Configuration/md:Properties/md:CompatibilityMode", $baseCfgNs)
	if ($compatNode -and $compatNode.InnerText) {
		$CompatibilityMode = $compatNode.InnerText.Trim()
		Write-Host "[INFO] Base config CompatibilityMode: $CompatibilityMode"
	} else {
		Write-Host "[WARN] CompatibilityMode not found in base config, using default: $CompatibilityMode"
	}
} else {
	Write-Host "[WARN] Language ExtendedConfigurationObject set to zeros. Use -ConfigPath to auto-resolve from base config, or fix manually before loading."
}

# --- Generate UUIDs ---
$uuidCfg  = [guid]::NewGuid().ToString()
$uuidLang = [guid]::NewGuid().ToString()
$uuidRole = [guid]::NewGuid().ToString()

# 7 ContainedObject ObjectIds
$co1 = [guid]::NewGuid().ToString()
$co2 = [guid]::NewGuid().ToString()
$co3 = [guid]::NewGuid().ToString()
$co4 = [guid]::NewGuid().ToString()
$co5 = [guid]::NewGuid().ToString()
$co6 = [guid]::NewGuid().ToString()
$co7 = [guid]::NewGuid().ToString()

# --- Synonym XML ---
$synonymXml = ""
if ($Synonym) {
	$synonymXml = "`r`n`t`t`t`t<v8:item>`r`n`t`t`t`t`t<v8:lang>ru</v8:lang>`r`n`t`t`t`t`t<v8:content>$([System.Security.SecurityElement]::Escape($Synonym))</v8:content>`r`n`t`t`t`t</v8:item>`r`n`t`t`t"
}

# --- Optional properties ---
$vendorXml = if ($Vendor) { [System.Security.SecurityElement]::Escape($Vendor) } else { "" }
$versionXml = if ($Version) { [System.Security.SecurityElement]::Escape($Version) } else { "" }

# --- Role name ---
$roleName = "${NamePrefix}ОсновнаяРоль"

# --- DefaultRoles XML ---
$defaultRolesXml = ""
if (-not $NoRole) {
	$defaultRolesXml = "`r`n`t`t`t`t<xr:Item xsi:type=`"xr:MDObjectRef`">Role.$roleName</xr:Item>`r`n`t`t`t"
}

# --- ChildObjects ---
$childObjectsXml = "`r`n`t`t`t<Language>Русский</Language>"
if (-not $NoRole) {
	$childObjectsXml += "`r`n`t`t`t<Role>$roleName</Role>"
}
$childObjectsXml += "`r`n`t`t"

# --- Configuration.xml ---
$cfgXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Configuration uuid="$uuidCfg">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>9cd510cd-abfc-11d4-9434-004095e12fc7</xr:ClassId>
				<xr:ObjectId>$co1</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>9fcd25a0-4822-11d4-9414-008048da11f9</xr:ClassId>
				<xr:ObjectId>$co2</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>e3687481-0a87-462c-a166-9f34594f9bba</xr:ClassId>
				<xr:ObjectId>$co3</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>9de14907-ec23-4a07-96f0-85521cb6b53b</xr:ClassId>
				<xr:ObjectId>$co4</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>51f2d5d8-ea4d-4064-8892-82951750031e</xr:ClassId>
				<xr:ObjectId>$co5</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>e68182ea-4237-4383-967f-90c1e3370bc7</xr:ClassId>
				<xr:ObjectId>$co6</xr:ObjectId>
			</xr:ContainedObject>
			<xr:ContainedObject>
				<xr:ClassId>fb282519-d103-4dd3-bc12-cb271d631dfc</xr:ClassId>
				<xr:ObjectId>$co7</xr:ObjectId>
			</xr:ContainedObject>
		</InternalInfo>
		<Properties>
			<ObjectBelonging>Adopted</ObjectBelonging>
			<Name>$([System.Security.SecurityElement]::Escape($Name))</Name>
			<Synonym>$synonymXml</Synonym>
			<Comment/>
			<ConfigurationExtensionPurpose>$Purpose</ConfigurationExtensionPurpose>
			<KeepMappingToExtendedConfigurationObjectsByIDs>true</KeepMappingToExtendedConfigurationObjectsByIDs>
			<NamePrefix>$([System.Security.SecurityElement]::Escape($NamePrefix))</NamePrefix>
			<ConfigurationExtensionCompatibilityMode>$CompatibilityMode</ConfigurationExtensionCompatibilityMode>
			<DefaultRunMode>ManagedApplication</DefaultRunMode>
			<UsePurposes>
				<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
			</UsePurposes>
			<ScriptVariant>Russian</ScriptVariant>
			<DefaultRoles>$defaultRolesXml</DefaultRoles>
			<Vendor>$vendorXml</Vendor>
			<Version>$versionXml</Version>
			<DefaultLanguage>Language.Русский</DefaultLanguage>
			<BriefInformation/>
			<DetailedInformation/>
			<Copyright/>
			<VendorInformationAddress/>
			<ConfigurationInformationAddress/>
			<InterfaceCompatibilityMode>TaxiEnableVersion8_2</InterfaceCompatibilityMode>
		</Properties>
		<ChildObjects>$childObjectsXml</ChildObjects>
	</Configuration>
</MetaDataObject>
"@

# --- Languages/Русский.xml (adopted format) ---
$langXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Language uuid="$uuidLang">
		<InternalInfo/>
		<Properties>
			<ObjectBelonging>Adopted</ObjectBelonging>
			<Name>Русский</Name>
			<Comment/>
			<ExtendedConfigurationObject>$baseLangUuid</ExtendedConfigurationObject>
			<LanguageCode>ru</LanguageCode>
		</Properties>
	</Language>
</MetaDataObject>
"@

# --- Role XML ---
$roleXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<Role uuid="$uuidRole">
		<Properties>
			<Name>$([System.Security.SecurityElement]::Escape($roleName))</Name>
			<Synonym/>
			<Comment/>
		</Properties>
	</Role>
</MetaDataObject>
"@

# --- Create directories ---
if (-not (Test-Path $OutputDir)) {
	New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$langDir = Join-Path $OutputDir "Languages"
if (-not (Test-Path $langDir)) {
	New-Item -ItemType Directory -Path $langDir -Force | Out-Null
}

# --- Write files with UTF-8 BOM ---
$enc = New-Object System.Text.UTF8Encoding($true)

[System.IO.File]::WriteAllText($cfgFile, $cfgXml, $enc)
$langFile = Join-Path $langDir "Русский.xml"
[System.IO.File]::WriteAllText($langFile, $langXml, $enc)

# --- Role ---
if (-not $NoRole) {
	$roleDir = Join-Path $OutputDir "Roles"
	if (-not (Test-Path $roleDir)) {
		New-Item -ItemType Directory -Path $roleDir -Force | Out-Null
	}
	$roleFile = Join-Path $roleDir "$roleName.xml"
	[System.IO.File]::WriteAllText($roleFile, $roleXml, $enc)
}

# --- Output ---
Write-Host "[OK] Создано расширение: $Name"
Write-Host "     Каталог:            $OutputDir"
Write-Host "     Назначение:         $Purpose"
Write-Host "     Префикс:           $NamePrefix"
Write-Host "     Совместимость:     $CompatibilityMode"
Write-Host "     Configuration.xml:  $cfgFile"
Write-Host "     Languages:          $langFile"
if (-not $NoRole) {
	Write-Host "     Role:               $roleFile"
}
