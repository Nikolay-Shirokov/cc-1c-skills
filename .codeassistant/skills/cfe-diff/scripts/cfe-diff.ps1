# cfe-diff v1.0 — Analyze and compare 1C configuration extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$ExtensionPath,

	[Parameter(Mandatory)]
	[string]$ConfigPath,

	[ValidateSet("A","B")]
	[string]$Mode = "A"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve paths ---
if (-not [System.IO.Path]::IsPathRooted($ExtensionPath)) {
	$ExtensionPath = Join-Path (Get-Location).Path $ExtensionPath
}
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path (Get-Location).Path $ConfigPath
}
if (Test-Path $ExtensionPath -PathType Leaf) { $ExtensionPath = Split-Path $ExtensionPath -Parent }
if (Test-Path $ConfigPath -PathType Leaf) { $ConfigPath = Split-Path $ConfigPath -Parent }

$extCfg = Join-Path $ExtensionPath "Configuration.xml"
$srcCfg = Join-Path $ConfigPath "Configuration.xml"
if (-not (Test-Path $extCfg)) { Write-Error "Extension Configuration.xml not found: $extCfg"; exit 1 }
if (-not (Test-Path $srcCfg)) { Write-Error "Config Configuration.xml not found: $srcCfg"; exit 1 }

# --- Type -> directory mapping ---
$childTypeDirMap = @{
	"Catalog"="Catalogs"; "Document"="Documents"; "Enum"="Enums"
	"CommonModule"="CommonModules"; "CommonPicture"="CommonPictures"
	"CommonCommand"="CommonCommands"; "CommonTemplate"="CommonTemplates"
	"ExchangePlan"="ExchangePlans"; "Report"="Reports"; "DataProcessor"="DataProcessors"
	"InformationRegister"="InformationRegisters"; "AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"; "CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"Subsystem"="Subsystems"; "Role"="Roles"; "Constant"="Constants"
	"FunctionalOption"="FunctionalOptions"; "DefinedType"="DefinedTypes"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"
	"CommonForm"="CommonForms"; "DocumentJournal"="DocumentJournals"
	"SessionParameter"="SessionParameters"; "StyleItem"="StyleItems"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"
	"SettingsStorage"="SettingsStorages"; "FilterCriterion"="FilterCriteria"
	"CommandGroup"="CommandGroups"; "DocumentNumerator"="DocumentNumerators"
	"Sequence"="Sequences"; "IntegrationService"="IntegrationServices"
	"CommonAttribute"="CommonAttributes"
}

# --- Parse extension Configuration.xml ---
$extDoc = New-Object System.Xml.XmlDocument
$extDoc.PreserveWhitespace = $false
$extDoc.Load($extCfg)

$ns = New-Object System.Xml.XmlNamespaceManager($extDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")

$extProps = $extDoc.SelectSingleNode("//md:Configuration/md:Properties", $ns)
$extNameNode = $extProps.SelectSingleNode("md:Name", $ns)
$extName = if ($extNameNode) { $extNameNode.InnerText } else { "?" }
$prefixNode = $extProps.SelectSingleNode("md:NamePrefix", $ns)
$namePrefix = if ($prefixNode -and $prefixNode.InnerText) { $prefixNode.InnerText } else { "" }
$purposeNode = $extProps.SelectSingleNode("md:ConfigurationExtensionPurpose", $ns)
$purpose = if ($purposeNode) { $purposeNode.InnerText } else { "?" }

Write-Host "=== cfe-diff Mode ${Mode}: $extName (${purpose}) ==="
Write-Host "    NamePrefix: $namePrefix"
Write-Host ""

# --- Collect ChildObjects ---
$childObjNode = $extDoc.SelectSingleNode("//md:Configuration/md:ChildObjects", $ns)
if (-not $childObjNode) {
	Write-Host "[WARN] No ChildObjects in extension"
	exit 0
}

$objects = @()
foreach ($child in $childObjNode.ChildNodes) {
	if ($child.NodeType -ne 'Element') { continue }
	if ($child.LocalName -eq "Language") { continue }
	$objects += @{ Type = $child.LocalName; Name = $child.InnerText }
}

if ($objects.Count -eq 0) {
	Write-Host "No objects (besides Language) in extension."
	exit 0
}

# --- Helper: check if object is borrowed ---
function Get-ObjectInfo {
	param([string]$objType, [string]$objName)

	if (-not $childTypeDirMap.ContainsKey($objType)) { return $null }
	$dirName = $childTypeDirMap[$objType]
	$objFile = Join-Path (Join-Path $ExtensionPath $dirName) "${objName}.xml"

	if (-not (Test-Path $objFile)) { return @{ Borrowed = $false; File = $objFile; Exists = $false } }

	$doc = New-Object System.Xml.XmlDocument
	$doc.PreserveWhitespace = $false
	$doc.Load($objFile)

	$objNs = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
	$objNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

	$objEl = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) { return @{ Borrowed = $false; File = $objFile; Exists = $true } }

	$propsEl = $objEl.SelectSingleNode("md:Properties", $objNs)
	$obNode = if ($propsEl) { $propsEl.SelectSingleNode("md:ObjectBelonging", $objNs) } else { $null }

	$info = @{
		Borrowed = ($obNode -and $obNode.InnerText -eq "Adopted")
		File = $objFile
		Exists = $true
		Type = $objType
		Name = $objName
		DirName = $dirName
		ObjElement = $objEl
		ObjNs = $objNs
	}
	return $info
}

# --- Helper: find .bsl files for object ---
function Get-BslFiles {
	param([string]$objType, [string]$objName)

	if (-not $childTypeDirMap.ContainsKey($objType)) { return @() }
	$dirName = $childTypeDirMap[$objType]
	$objDir = Join-Path (Join-Path $ExtensionPath $dirName) $objName

	if (-not (Test-Path $objDir -PathType Container)) { return @() }

	$bslFiles = @()
	$extDir = Join-Path $objDir "Ext"
	if (Test-Path $extDir) {
		$items = Get-ChildItem -Path $extDir -Filter "*.bsl" -ErrorAction SilentlyContinue
		foreach ($item in $items) { $bslFiles += $item.FullName }
	}

	# Forms
	$formsDir = Join-Path $objDir "Forms"
	if (Test-Path $formsDir) {
		$formModules = Get-ChildItem -Path $formsDir -Recurse -Filter "Module.bsl" -ErrorAction SilentlyContinue
		foreach ($fm in $formModules) { $bslFiles += $fm.FullName }
	}

	return $bslFiles
}

# --- Helper: parse interceptors from .bsl ---
function Get-Interceptors {
	param([string]$bslPath)

	if (-not (Test-Path $bslPath)) { return @() }
	$lines = [System.IO.File]::ReadAllLines($bslPath, [System.Text.Encoding]::UTF8)
	$interceptors = @()
	$i = 0
	while ($i -lt $lines.Count) {
		$line = $lines[$i].Trim()
		if ($line -match '^&(Перед|После|ИзменениеИКонтроль|Вместо)\("([^"]+)"\)') {
			$type = $Matches[1]
			$method = $Matches[2]
			$interceptors += @{ Type = $type; Method = $method; Line = $i + 1; File = $bslPath }
		}
		$i++
	}
	return $interceptors
}

# --- Helper: extract #Вставка blocks from .bsl ---
function Get-InsertionBlocks {
	param([string]$bslPath)

	if (-not (Test-Path $bslPath)) { return @() }
	$lines = [System.IO.File]::ReadAllLines($bslPath, [System.Text.Encoding]::UTF8)
	$blocks = @()
	$inBlock = $false
	$blockLines = @()
	$startLine = 0

	for ($i = 0; $i -lt $lines.Count; $i++) {
		$line = $lines[$i].Trim()
		if ($line -eq "#Вставка") {
			$inBlock = $true
			$blockLines = @()
			$startLine = $i + 1
		} elseif ($line -eq "#КонецВставки" -and $inBlock) {
			$inBlock = $false
			$blocks += @{
				StartLine = $startLine
				EndLine = $i + 1
				Code = ($blockLines -join "`n").Trim()
				File = $bslPath
			}
		} elseif ($inBlock) {
			$blockLines += $lines[$i]
		}
	}
	return $blocks
}

# --- Helper: analyze form for callType events and commands ---
function Get-FormInterceptors {
	param([string]$formXmlPath)

	if (-not (Test-Path $formXmlPath)) { return $null }

	$formDoc = New-Object System.Xml.XmlDocument
	$formDoc.PreserveWhitespace = $false
	try { $formDoc.Load($formXmlPath) } catch { return $null }

	$fNs = New-Object System.Xml.XmlNamespaceManager($formDoc.NameTable)
	$fNs.AddNamespace("f", "http://v8.1c.ru/8.3/xcf/logform")

	$fRoot = $formDoc.DocumentElement
	$baseForm = $fRoot.SelectSingleNode("f:BaseForm", $fNs)
	$isBorrowed = ($baseForm -ne $null)

	$interceptors = @()

	# Form-level events with callType
	$eventsNode = $fRoot.SelectSingleNode("f:Events", $fNs)
	if ($eventsNode) {
		foreach ($evt in $eventsNode.SelectNodes("f:Event", $fNs)) {
			$ct = $evt.GetAttribute("callType")
			if ($ct) {
				$interceptors += "Event:$($evt.GetAttribute('name')) [$ct] -> $($evt.InnerText)"
			}
		}
	}

	# Element-level events with callType (scan all elements recursively)
	$childItems = $fRoot.SelectSingleNode("f:ChildItems", $fNs)
	if ($childItems) {
		foreach ($evtNode in $childItems.SelectNodes(".//*[f:Events/f:Event[@callType]]", $fNs)) {
			$elName = $evtNode.GetAttribute("name")
			foreach ($evt in $evtNode.SelectNodes("f:Events/f:Event[@callType]", $fNs)) {
				$ct = $evt.GetAttribute("callType")
				$interceptors += "Element:${elName}.$($evt.GetAttribute('name')) [$ct] -> $($evt.InnerText)"
			}
		}
	}

	# Commands with callType on Action
	foreach ($cmd in $fRoot.SelectNodes("f:Commands/f:Command", $fNs)) {
		$cmdName = $cmd.GetAttribute("name")
		foreach ($action in $cmd.SelectNodes("f:Action[@callType]", $fNs)) {
			$ct = $action.GetAttribute("callType")
			$interceptors += "Command:$cmdName [$ct] -> $($action.InnerText)"
		}
	}

	return @{
		IsBorrowed = $isBorrowed
		Interceptors = $interceptors
	}
}

# ============================================================
# MODE A: Extension overview
# ============================================================
if ($Mode -eq "A") {
	$borrowedList = @()
	$ownList = @()

	foreach ($obj in $objects) {
		$info = Get-ObjectInfo $obj.Type $obj.Name
		if (-not $info) {
			Write-Host "  [?] $($obj.Type).$($obj.Name) — unknown type"
			continue
		}
		if (-not $info.Exists) {
			Write-Host "  [?] $($obj.Type).$($obj.Name) — file not found"
			continue
		}

		if ($info.Borrowed) {
			$borrowedList += $obj

			Write-Host "  [BORROWED] $($obj.Type).$($obj.Name)"

			# Find .bsl files and interceptors
			$bslFiles = Get-BslFiles $obj.Type $obj.Name
			foreach ($bsl in $bslFiles) {
				$relPath = $bsl.Replace($ExtensionPath, "").TrimStart("\", "/")
				$interceptors = Get-Interceptors $bsl
				if ($interceptors.Count -gt 0) {
					foreach ($ic in $interceptors) {
						Write-Host "             &$($ic.Type)(`"$($ic.Method)`") — line $($ic.Line) in $relPath"
					}
				} else {
					Write-Host "             $relPath (no interceptors)"
				}
			}

			# Check for own attributes/forms in ChildObjects
			if ($info.ObjElement) {
				$childObj = $info.ObjElement.SelectSingleNode("md:ChildObjects", $info.ObjNs)
				if ($childObj) {
					$ownAttrs = 0
					$ownForms = 0
					$ownTS = 0
					$borrowedItems = 0
					$formNames = @()
					foreach ($c in $childObj.ChildNodes) {
						if ($c.NodeType -ne 'Element') { continue }
						$cProps = $c.SelectSingleNode("md:Properties", $info.ObjNs)
						if ($cProps) {
							$cOb = $cProps.SelectSingleNode("md:ObjectBelonging", $info.ObjNs)
							if ($cOb -and $cOb.InnerText -eq "Adopted") {
								$borrowedItems++
								continue
							}
						}
						switch ($c.LocalName) {
							"Attribute" { $ownAttrs++ }
							"TabularSection" { $ownTS++ }
							"Form" { $formNames += $c.InnerText; $ownForms++ }
						}
					}
					$parts = @()
					if ($ownAttrs -gt 0) { $parts += "$ownAttrs own attrs" }
					if ($ownTS -gt 0) { $parts += "$ownTS own TS" }
					if ($ownForms -gt 0) { $parts += "$ownForms own forms" }
					if ($borrowedItems -gt 0) { $parts += "$borrowedItems borrowed items" }
					if ($parts.Count -gt 0) {
						Write-Host "             ChildObjects: $($parts -join ', ')"
					}

					# Analyze forms
					$borrowedFormCount = 0
					$ownFormCount = 0
					foreach ($fn in $formNames) {
						$formXmlPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $ExtensionPath $info.DirName) $info.Name) "Forms") $fn) "Ext/Form.xml"
						$fi = Get-FormInterceptors $formXmlPath
						if (-not $fi) {
							Write-Host "             Form.$fn (?)"
							continue
						}
						$formTag = if ($fi.IsBorrowed) { "borrowed"; $borrowedFormCount++ } else { "own"; $ownFormCount++ }
						if ($fi.Interceptors.Count -gt 0) {
							Write-Host "             Form.$fn ($formTag):"
							foreach ($ic in $fi.Interceptors) {
								Write-Host "               $ic"
							}
						} else {
							Write-Host "             Form.$fn ($formTag)"
						}
					}
				}
			}
		} else {
			$ownList += $obj
			Write-Host "  [OWN]      $($obj.Type).$($obj.Name)"

			# Brief info for own objects
			if ($info.ObjElement) {
				$childObj = $info.ObjElement.SelectSingleNode("md:ChildObjects", $info.ObjNs)
				if ($childObj) {
					$attrs = 0; $forms = 0; $ts = 0
					foreach ($c in $childObj.ChildNodes) {
						if ($c.NodeType -ne 'Element') { continue }
						switch ($c.LocalName) {
							"Attribute" { $attrs++ }
							"TabularSection" { $ts++ }
							"Form" { $forms++ }
						}
					}
					$parts = @()
					if ($attrs -gt 0) { $parts += "$attrs attrs" }
					if ($ts -gt 0) { $parts += "$ts TS" }
					if ($forms -gt 0) { $parts += "$forms forms" }
					if ($parts.Count -gt 0) {
						Write-Host "             $($parts -join ', ')"
					}
				}
			}
		}
	}

	Write-Host ""
	Write-Host "=== Summary: $($borrowedList.Count) borrowed, $($ownList.Count) own objects ==="
}

# ============================================================
# MODE B: Transfer check
# ============================================================
if ($Mode -eq "B") {
	$transferred = 0
	$notTransferred = 0
	$needsReview = 0

	foreach ($obj in $objects) {
		$info = Get-ObjectInfo $obj.Type $obj.Name
		if (-not $info -or -not $info.Exists -or -not $info.Borrowed) { continue }

		# Find .bsl files with &ИзменениеИКонтроль
		$bslFiles = Get-BslFiles $obj.Type $obj.Name
		foreach ($bsl in $bslFiles) {
			$interceptors = Get-Interceptors $bsl
			$macInterceptors = @($interceptors | Where-Object { $_.Type -eq "ИзменениеИКонтроль" })

			if ($macInterceptors.Count -eq 0) { continue }

			foreach ($ic in $macInterceptors) {
				$methodName = $ic.Method
				$relBsl = $bsl.Replace($ExtensionPath, "").TrimStart("\", "/")

				# Find #Вставка blocks in this file
				$insertBlocks = Get-InsertionBlocks $bsl

				if ($insertBlocks.Count -eq 0) {
					Write-Host "  [NEEDS_REVIEW] $($obj.Type).$($obj.Name) — &ИзменениеИКонтроль(`"$methodName`") — no #Вставка blocks"
					$needsReview++
					continue
				}

				# Find corresponding module in config
				if (-not $childTypeDirMap.ContainsKey($obj.Type)) { continue }
				$dirName = $childTypeDirMap[$obj.Type]
				$configBsl = $bsl.Replace($ExtensionPath, $ConfigPath)

				if (-not (Test-Path $configBsl)) {
					Write-Host "  [NEEDS_REVIEW] $($obj.Type).$($obj.Name) — &ИзменениеИКонтроль(`"$methodName`") — config module not found"
					$needsReview++
					continue
				}

				$configContent = [System.IO.File]::ReadAllText($configBsl, [System.Text.Encoding]::UTF8)

				$allTransferred = $true
				foreach ($block in $insertBlocks) {
					$code = $block.Code
					if (-not $code) { continue }

					# Normalize whitespace for comparison
					$codeNorm = $code -replace '\s+', ' '
					$configNorm = $configContent -replace '\s+', ' '

					if ($configNorm.Contains($codeNorm)) {
						# Found in config
					} else {
						$allTransferred = $false
					}
				}

				if ($allTransferred) {
					Write-Host "  [TRANSFERRED]     $($obj.Type).$($obj.Name) — &ИзменениеИКонтроль(`"$methodName`") — $($insertBlocks.Count) block(s)"
					$transferred++
				} else {
					Write-Host "  [NOT_TRANSFERRED] $($obj.Type).$($obj.Name) — &ИзменениеИКонтроль(`"$methodName`") — some blocks not found in config"
					$notTransferred++
				}
			}
		}
	}

	Write-Host ""
	Write-Host "=== Transfer check: $transferred transferred, $notTransferred not transferred, $needsReview needs review ==="
}
