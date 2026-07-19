# meta-remove v1.5 — Remove metadata object from 1C configuration dump
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ConfigDir,

	[Parameter(Mandatory)]
	[string]$Object,

	[switch]$DryRun,

	[switch]$KeepFiles,

	[switch]$Force
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Type → plural directory mapping ---

$typePluralMap = @{
	"Catalog"                    = "Catalogs"
	"Document"                   = "Documents"
	"Enum"                       = "Enums"
	"Constant"                   = "Constants"
	"InformationRegister"        = "InformationRegisters"
	"AccumulationRegister"       = "AccumulationRegisters"
	"AccountingRegister"         = "AccountingRegisters"
	"CalculationRegister"        = "CalculationRegisters"
	"ChartOfAccounts"            = "ChartsOfAccounts"
	"ChartOfCharacteristicTypes" = "ChartsOfCharacteristicTypes"
	"ChartOfCalculationTypes"    = "ChartsOfCalculationTypes"
	"BusinessProcess"            = "BusinessProcesses"
	"Task"                       = "Tasks"
	"ExchangePlan"               = "ExchangePlans"
	"DocumentJournal"            = "DocumentJournals"
	"Report"                     = "Reports"
	"DataProcessor"              = "DataProcessors"
	"CommonModule"               = "CommonModules"
	"ScheduledJob"               = "ScheduledJobs"
	"EventSubscription"          = "EventSubscriptions"
	"HTTPService"                = "HTTPServices"
	"WebService"                 = "WebServices"
	"DefinedType"                = "DefinedTypes"
	"Role"                       = "Roles"
	"Subsystem"                  = "Subsystems"
	"CommonForm"                 = "CommonForms"
	"CommonTemplate"             = "CommonTemplates"
	"CommonPicture"              = "CommonPictures"
	"CommonAttribute"            = "CommonAttributes"
	"SessionParameter"           = "SessionParameters"
	"FunctionalOption"           = "FunctionalOptions"
	"FunctionalOptionsParameter" = "FunctionalOptionsParameters"
	"Sequence"                   = "Sequences"
	"FilterCriterion"            = "FilterCriteria"
	"SettingsStorage"            = "SettingsStorages"
	"XDTOPackage"                = "XDTOPackages"
	"WSReference"                = "WSReferences"
	"StyleItem"                  = "StyleItems"
	"Language"                   = "Languages"
}

# --- Resolve paths ---

if (-not [System.IO.Path]::IsPathRooted($ConfigDir)) {
	$ConfigDir = Join-Path (Get-Location).Path $ConfigDir
}

if (-not (Test-Path $ConfigDir -PathType Container)) {
	Write-Host "[ERROR] Config directory not found: $ConfigDir"
	exit 1
}

$configXml = Join-Path $ConfigDir "Configuration.xml"
if (-not (Test-Path $configXml)) {
	Write-Host "[ERROR] Configuration.xml not found in: $ConfigDir"
	exit 1
}

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# --- Parse object spec ---

$parts = $Object -split "\.", 2
if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
	Write-Host "[ERROR] Invalid object format '$Object'. Expected: Type.Name (e.g. Catalog.Товары)"
	exit 1
}

$objType = $parts[0]
$objName = $parts[1]

if (-not $typePluralMap.ContainsKey($objType)) {
	Write-Host "[ERROR] Unknown type '$objType'. Supported: $($typePluralMap.Keys -join ', ')"
	exit 1
}

$typePlural = $typePluralMap[$objType]

Write-Host "=== meta-remove: ${objType}.${objName} ==="
Write-Host ""

if ($DryRun) {
	Write-Host "[DRY-RUN] No changes will be made"
	Write-Host ""
}

$actions = 0
$errors = 0

# --- 1. Find object files ---

$typeDir = Join-Path $ConfigDir $typePlural
$objXml = Join-Path $typeDir "$objName.xml"
$objDir = Join-Path $typeDir $objName

# Support guard — removal requires the object be снят-с-поддержки (f1=2).
Assert-EditAllowed $objXml 'removed'

$hasXml = Test-Path $objXml
$hasDir = Test-Path $objDir -PathType Container

if (-not $hasXml -and -not $hasDir) {
	# Check if registered in Configuration.xml before proceeding
	$cfgCheckDoc = New-Object System.Xml.XmlDocument
	$cfgCheckDoc.PreserveWhitespace = $true
	$cfgCheckDoc.Load($configXml)
	$cfgCheckNs = New-Object System.Xml.XmlNamespaceManager($cfgCheckDoc.NameTable)
	$cfgCheckNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
	$cfgCheckNode = $cfgCheckDoc.DocumentElement.SelectSingleNode("md:Configuration/md:ChildObjects", $cfgCheckNs)
	$registeredInCfg = $false
	if ($cfgCheckNode) {
		foreach ($child in @($cfgCheckNode.ChildNodes)) {
			if ($child.NodeType -ne 'Element') { continue }
			if ($child.LocalName -eq $objType -and $child.InnerText.Trim() -eq $objName) {
				$registeredInCfg = $true; break
			}
		}
	}
	if (-not $registeredInCfg) {
		Write-Host "[ERROR] Object not found: $typePlural/$objName.xml and not registered in Configuration.xml"
		exit 1
	}
	Write-Host "[WARN]  Object files not found: $typePlural/$objName.xml"
	Write-Host "        Proceeding with deregistration only..."
} else {
	if ($hasXml) { Write-Host "[FOUND] $typePlural/$objName.xml" }
	if ($hasDir) {
		$fileCount = @(Get-ChildItem $objDir -Recurse -File).Count
		Write-Host "[FOUND] $typePlural/$objName/ ($fileCount files)"
	}
}

# --- 2. Reference check ---

Write-Host ""
Write-Host "--- Reference check ---"

# Build search patterns based on object type

# Type → reference type name (used in XML <v8:Type> elements)
$typeRefNames = @{
	"Catalog"                    = @("CatalogRef","CatalogObject")
	"Document"                   = @("DocumentRef","DocumentObject")
	"Enum"                       = @("EnumRef")
	"ExchangePlan"               = @("ExchangePlanRef","ExchangePlanObject")
	"ChartOfAccounts"            = @("ChartOfAccountsRef","ChartOfAccountsObject")
	"ChartOfCharacteristicTypes" = @("ChartOfCharacteristicTypesRef","ChartOfCharacteristicTypesObject")
	"ChartOfCalculationTypes"    = @("ChartOfCalculationTypesRef","ChartOfCalculationTypesObject")
	"BusinessProcess"            = @("BusinessProcessRef","BusinessProcessObject")
	"Task"                       = @("TaskRef","TaskObject")
}

# Type → Russian manager name (used in BSL code: Справочники.Товары)
$typeRuManager = @{
	"Catalog"                    = "Справочники"
	"Document"                   = "Документы"
	"Enum"                       = "Перечисления"
	"Constant"                   = "Константы"
	"InformationRegister"        = "РегистрыСведений"
	"AccumulationRegister"       = "РегистрыНакопления"
	"AccountingRegister"         = "РегистрыБухгалтерии"
	"CalculationRegister"        = "РегистрыРасчета"
	"ChartOfAccounts"            = "ПланыСчетов"
	"ChartOfCharacteristicTypes" = "ПланыВидовХарактеристик"
	"ChartOfCalculationTypes"    = "ПланыВидовРасчета"
	"BusinessProcess"            = "БизнесПроцессы"
	"Task"                       = "Задачи"
	"ExchangePlan"               = "ПланыОбмена"
	"Report"                     = "Отчеты"
	"DataProcessor"              = "Обработки"
	"DocumentJournal"            = "ЖурналыДокументов"
	"CommonModule"               = $null
}

$searchPatterns = @()

# 1) XML type references: CatalogRef.Name, CatalogObject.Name
if ($typeRefNames.ContainsKey($objType)) {
	foreach ($refName in $typeRefNames[$objType]) {
		$searchPatterns += "$refName.$objName"
	}
}

# 2) BSL code references: Справочники.Name, Catalogs.Name
$ruMgr = $typeRuManager[$objType]
if ($ruMgr) {
	$searchPatterns += "$ruMgr.$objName"
}
# English manager = plural directory name
$searchPatterns += "$typePlural.$objName"

# 3) CommonModule: method calls in BSL (ModuleName.)
if ($objType -eq "CommonModule") {
	$searchPatterns += "$objName."
}

# 4) ScheduledJob/EventSubscription handler references
if ($objType -eq "CommonModule") {
	$searchPatterns += "<Handler>$objName."
	$searchPatterns += "<MethodName>$objName."
}

# Exclude object's own files from search
$excludeDirs = @()
if ($hasDir) { $excludeDirs += $objDir }
$excludeFile = ""
if ($hasXml) { $excludeFile = $objXml }

# Search all XML and BSL files
$references = @()
$searchExtensions = @("*.xml", "*.bsl")

foreach ($ext in $searchExtensions) {
	$files = @(Get-ChildItem $ConfigDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue)
	foreach ($file in $files) {
		# Skip own files
		if ($excludeFile -and $file.FullName -eq $excludeFile) { continue }
		if ($excludeDirs.Count -gt 0) {
			$skip = $false
			foreach ($ed in $excludeDirs) {
				if ($file.FullName.StartsWith($ed)) { $skip = $true; break }
			}
			if ($skip) { continue }
		}
		# Skip auto-cleaned files (Configuration.xml, ConfigDumpInfo.xml, Subsystems)
		$relPath = $file.FullName.Substring($ConfigDir.Length + 1)
		if ($relPath -eq "Configuration.xml" -or $relPath -eq "ConfigDumpInfo.xml" -or $relPath.StartsWith("Subsystems")) { continue }

		$content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
		foreach ($pat in $searchPatterns) {
			if ($content.Contains($pat)) {
				$references += @{ File = $relPath; Pattern = $pat }
				break  # one match per file is enough
			}
		}
	}
}

# Also check for Type.Name references (subsystem content, doc journal, etc.) — but NOT in own files
$typeNameRef = "${objType}.${objName}"
$files = @(Get-ChildItem $ConfigDir -Filter "*.xml" -Recurse -File -ErrorAction SilentlyContinue)
foreach ($file in $files) {
	if ($excludeFile -and $file.FullName -eq $excludeFile) { continue }
	if ($excludeDirs.Count -gt 0) {
		$skip = $false
		foreach ($ed in $excludeDirs) {
			if ($file.FullName.StartsWith($ed)) { $skip = $true; break }
		}
		if ($skip) { continue }
	}
	# Skip Configuration.xml and Subsystems — they will be cleaned automatically
	$relPath = $file.FullName.Substring($ConfigDir.Length + 1)
	if ($relPath -eq "Configuration.xml") { continue }
	if ($relPath -eq "ConfigDumpInfo.xml") { continue }
	if ($relPath.StartsWith("Subsystems")) { continue }

	$content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
	if ($content.Contains($typeNameRef)) {
		# Check it's not already in references
		$alreadyFound = $false
		foreach ($r in $references) {
			if ($r.File -eq $relPath) { $alreadyFound = $true; break }
		}
		if (-not $alreadyFound) {
			$references += @{ File = $relPath; Pattern = $typeNameRef }
		}
	}
}

if ($references.Count -gt 0) {
	Write-Host "[WARN]  Found $($references.Count) reference(s) to ${objType}.${objName}:"
	Write-Host ""
	$shown = 0
	foreach ($ref in $references) {
		Write-Host "        $($ref.File)"
		Write-Host "          pattern: $($ref.Pattern)"
		$shown++
		if ($shown -ge 20) {
			$remaining = $references.Count - $shown
			if ($remaining -gt 0) {
				Write-Host "        ... and $remaining more"
			}
			break
		}
	}
	Write-Host ""

	if (-not $Force) {
		Write-Host "[ERROR] Cannot remove: object has $($references.Count) reference(s)."
		Write-Host "        Use -Force to remove anyway, or fix references first."
		exit 1
	} else {
		Write-Host "[WARN]  -Force specified, proceeding despite references"
	}
} else {
	Write-Host "[OK]    No references found"
}

# --- 3. Remove from Configuration.xml ChildObjects ---

Write-Host ""
Write-Host "--- Configuration.xml ---"

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
$xmlDoc.Load($configXml)

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

$cfgNode = $xmlDoc.DocumentElement.SelectSingleNode("md:Configuration", $ns)
if (-not $cfgNode) {
	Write-Host "[ERROR] Configuration element not found in Configuration.xml"
	$errors++
} else {
	$childObjects = $cfgNode.SelectSingleNode("md:ChildObjects", $ns)
	if ($childObjects) {
		$found = $false
		foreach ($child in @($childObjects.ChildNodes)) {
			if ($child.NodeType -ne 'Element') { continue }
			if ($child.LocalName -eq $objType -and $child.InnerText.Trim() -eq $objName) {
				$found = $true
				if (-not $DryRun) {
					# Remove preceding whitespace if present
					$prev = $child.PreviousSibling
					if ($prev -and $prev.NodeType -eq 'Whitespace') {
						$childObjects.RemoveChild($prev) | Out-Null
					}
					$childObjects.RemoveChild($child) | Out-Null
				}
				Write-Host "[OK]    Removed <$objType>$objName</$objType> from ChildObjects"
				$actions++
				break
			}
		}
		if (-not $found) {
			Write-Host "[WARN]  <$objType>$objName</$objType> not found in ChildObjects"
		}
	}

	# Save Configuration.xml
	if ($actions -gt 0 -and -not $DryRun) {
		$enc = New-Object System.Text.UTF8Encoding $true
		$sw = New-Object System.IO.StreamWriter($configXml, $false, $enc)
		$xmlDoc.Save($sw)
		$sw.Close()
		Write-Host "[OK]    Configuration.xml saved"
	}
}

# --- 4. Remove from subsystem Content ---

Write-Host ""
Write-Host "--- Subsystems ---"

$subsystemsDir = Join-Path $ConfigDir "Subsystems"
$subsystemsFound = 0
$subsystemsCleaned = 0

function Remove-FromSubsystems {
	param([string]$dir)

	$xmlFiles = @(Get-ChildItem $dir -Filter "*.xml" -File -ErrorAction SilentlyContinue)
	foreach ($xmlFile in $xmlFiles) {
		$ssDoc = New-Object System.Xml.XmlDocument
		$ssDoc.PreserveWhitespace = $true
		try { $ssDoc.Load($xmlFile.FullName) } catch { continue }

		$ssNs = New-Object System.Xml.XmlNamespaceManager($ssDoc.NameTable)
		$ssNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
		$ssNs.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")

		$ssNode = $ssDoc.DocumentElement.SelectSingleNode("md:Subsystem", $ssNs)
		if (-not $ssNode) { continue }

		$propsNode = $ssNode.SelectSingleNode("md:Properties", $ssNs)
		if (-not $propsNode) { continue }

		$contentNode = $propsNode.SelectSingleNode("md:Content", $ssNs)
		if (-not $contentNode) { continue }

		$ssNameNode = $propsNode.SelectSingleNode("md:Name", $ssNs)
		$ssName = if ($ssNameNode) { $ssNameNode.InnerText } else { $xmlFile.BaseName }

		# Content items are <v8:Value>Type.Name</v8:Value>
		$targetRef = "${objType}.${objName}"
		$modified = $false

		foreach ($item in @($contentNode.ChildNodes)) {
			if ($item.NodeType -ne 'Element') { continue }
			$val = $item.InnerText.Trim()
			# Content format: "Subsystem.X" or "Catalog.X" etc.
			if ($val -eq $targetRef) {
				$script:subsystemsFound++
				if (-not $DryRun) {
					$prev = $item.PreviousSibling
					if ($prev -and $prev.NodeType -eq 'Whitespace') {
						$contentNode.RemoveChild($prev) | Out-Null
					}
					$contentNode.RemoveChild($item) | Out-Null
					$modified = $true
				}
				Write-Host "[OK]    Removed from subsystem '$ssName'"
				$script:subsystemsCleaned++
			}
		}

		if ($modified -and -not $DryRun) {
			$enc = New-Object System.Text.UTF8Encoding $true
			$sw = New-Object System.IO.StreamWriter($xmlFile.FullName, $false, $enc)
			$ssDoc.Save($sw)
			$sw.Close()
		}

		# Recurse into child subsystems
		$childDir = Join-Path $dir ($xmlFile.BaseName)
		$childSubsystems = Join-Path $childDir "Subsystems"
		if (Test-Path $childSubsystems -PathType Container) {
			Remove-FromSubsystems -dir $childSubsystems
		}
	}
}

if (Test-Path $subsystemsDir -PathType Container) {
	Remove-FromSubsystems -dir $subsystemsDir
	if ($subsystemsCleaned -eq 0) {
		Write-Host "[OK]    Not referenced in any subsystem"
	}
} else {
	Write-Host "[OK]    No Subsystems directory"
}

# --- 5. Delete object files ---

Write-Host ""
Write-Host "--- Files ---"

if (-not $KeepFiles) {
	if ($hasDir -and -not $DryRun) {
		Remove-Item $objDir -Recurse -Force
		Write-Host "[OK]    Deleted directory: $typePlural/$objName/"
		$actions++
	} elseif ($hasDir) {
		Write-Host "[DRY]   Would delete directory: $typePlural/$objName/"
		$actions++
	}

	if ($hasXml -and -not $DryRun) {
		Remove-Item $objXml -Force
		Write-Host "[OK]    Deleted file: $typePlural/$objName.xml"
		$actions++
	} elseif ($hasXml) {
		Write-Host "[DRY]   Would delete file: $typePlural/$objName.xml"
		$actions++
	}

	if (-not $hasXml -and -not $hasDir) {
		Write-Host "[OK]    No files to delete"
	}
} else {
	Write-Host "[SKIP]  File deletion skipped (-KeepFiles)"
}

# --- Summary ---

Write-Host ""
$totalActions = $actions + $subsystemsCleaned
if ($DryRun) {
	Write-Host "=== Dry run complete: $totalActions actions would be performed ==="
} else {
	Write-Host "=== Done: $totalActions actions performed ($subsystemsCleaned subsystem references removed) ==="
}

if ($errors -gt 0) {
	exit 1
}
exit 0
