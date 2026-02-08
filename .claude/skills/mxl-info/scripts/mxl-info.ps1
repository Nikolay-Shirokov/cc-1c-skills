param(
	[string]$TemplatePath,
	[string]$ProcessorName,
	[string]$TemplateName,
	[string]$SrcDir = "src",
	[ValidateSet("text", "json")]
	[string]$Format = "text",
	[switch]$WithText,
	[int]$MaxParams = 10,
	[int]$Limit = 150,
	[int]$Offset = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve template path ---

if (-not $TemplatePath) {
	if (-not $ProcessorName -or -not $TemplateName) {
		Write-Error "Specify -TemplatePath or both -ProcessorName and -TemplateName"
		exit 1
	}
	$TemplatePath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $SrcDir $ProcessorName) "Templates") $TemplateName) "Ext") "Template.xml"
}

if (-not (Test-Path $TemplatePath)) {
	Write-Error "File not found: $TemplatePath"
	exit 1
}

# --- Load XML ---

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load((Resolve-Path $TemplatePath).Path)

$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("d", "http://v8.1c.ru/8.2/data/spreadsheet")
$nsMgr.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$nsMgr.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

$root = $xmlDoc.DocumentElement

# --- Column sets ---

$columnSets = @()
$defaultColCount = 0

foreach ($cols in $root.SelectNodes("d:columns", $nsMgr)) {
	$sizeNode = $cols.SelectSingleNode("d:size", $nsMgr)
	$idNode = $cols.SelectSingleNode("d:id", $nsMgr)
	$size = if ($sizeNode) { [int]$sizeNode.InnerText } else { 0 }

	if ($idNode) {
		$columnSets += @{ Id = $idNode.InnerText; Size = $size }
	} else {
		$defaultColCount = $size
	}
}

# --- Rows: collect row data ---

$rowNodes = $root.SelectNodes("d:rowsItem", $nsMgr)
$totalRows = $rowNodes.Count

$heightNode = $root.SelectSingleNode("d:height", $nsMgr)
$docHeight = if ($heightNode) { [int]$heightNode.InnerText } else { $totalRows }

# --- Named items ---

$namedAreas = @()
$namedDrawings = @()

foreach ($ni in $root.SelectNodes("d:namedItem", $nsMgr)) {
	$niType = $ni.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	$name = $ni.SelectSingleNode("d:name", $nsMgr).InnerText

	if ($niType -like "*NamedItemCells*") {
		$area = $ni.SelectSingleNode("d:area", $nsMgr)
		$areaType = $area.SelectSingleNode("d:type", $nsMgr).InnerText
		$beginRow = [int]$area.SelectSingleNode("d:beginRow", $nsMgr).InnerText
		$endRow = [int]$area.SelectSingleNode("d:endRow", $nsMgr).InnerText
		$beginCol = [int]$area.SelectSingleNode("d:beginColumn", $nsMgr).InnerText
		$endCol = [int]$area.SelectSingleNode("d:endColumn", $nsMgr).InnerText
		$colsId = $null
		$colsIdNode = $area.SelectSingleNode("d:columnsID", $nsMgr)
		if ($colsIdNode) { $colsId = $colsIdNode.InnerText }

		$namedAreas += @{
			Name      = $name
			AreaType  = $areaType
			BeginRow  = $beginRow
			EndRow    = $endRow
			BeginCol  = $beginCol
			EndCol    = $endCol
			ColumnsID = $colsId
		}
	} elseif ($niType -like "*NamedItemDrawing*") {
		$drawId = $ni.SelectSingleNode("d:drawingID", $nsMgr).InnerText
		$namedDrawings += @{ Name = $name; DrawingID = $drawId }
	}
}

# --- Scan rows for parameters and text ---

# Build row index map: rowIndex -> XmlNode
$rowMap = @{}
foreach ($ri in $rowNodes) {
	$idx = [int]$ri.SelectSingleNode("d:index", $nsMgr).InnerText
	$rowMap[$idx] = $ri
}

function Get-CellData {
	param($rowNode, [System.Xml.XmlNamespaceManager]$ns, [bool]$includeText)

	$row = $rowNode.SelectSingleNode("d:row", $ns)
	if (-not $row) { return @() }

	$results = @()
	foreach ($cGroup in $row.SelectNodes("d:c", $ns)) {
		$cell = $cGroup.SelectSingleNode("d:c", $ns)
		if (-not $cell) { continue }

		$param = $cell.SelectSingleNode("d:parameter", $ns)
		$detail = $cell.SelectSingleNode("d:detailParameter", $ns)
		$tl = $cell.SelectSingleNode("d:tl", $ns)

		if ($param) {
			$entry = @{ Kind = "Parameter"; Value = $param.InnerText }
			if ($detail) { $entry.Detail = $detail.InnerText }
			$results += $entry
		}

		if ($includeText -and $tl) {
			$content = $tl.SelectSingleNode("v8:item/v8:content", $ns)
			if ($content -and $content.InnerText) {
				$text = $content.InnerText
				# Detect if this is a Template (has [...] placeholders)
				if ($text -match '\[.+\]') {
					$results += @{ Kind = "Template"; Value = $text }
				} else {
					$results += @{ Kind = "Text"; Value = $text }
				}
			}
		}
	}
	return $results
}

function Get-AreaCellData {
	param(
		[hashtable]$area,
		[hashtable]$rowMap,
		[System.Xml.XmlNamespaceManager]$ns,
		[bool]$includeText
	)

	$params = @()
	$texts = @()
	$templates = @()

	$startRow = $area.BeginRow
	$endRow = $area.EndRow
	if ($startRow -eq -1) { $startRow = 0 }
	if ($endRow -eq -1) { $endRow = $docHeight - 1 }

	for ($r = $startRow; $r -le $endRow; $r++) {
		if ($rowMap.ContainsKey($r)) {
			$cells = Get-CellData -rowNode $rowMap[$r] -ns $ns -includeText $includeText
			foreach ($c in $cells) {
				switch ($c.Kind) {
					"Parameter" { $params += $c.Value }
					"Text"      { $texts += $c.Value }
					"Template"  { $templates += $c.Value }
				}
			}
		}
	}

	return @{ Params = $params; Texts = $texts; Templates = $templates }
}

# Collect data for each area
$areaData = @()
$coveredRows = @{}

foreach ($area in $namedAreas) {
	$data = Get-AreaCellData -area $area -rowMap $rowMap -ns $nsMgr -includeText $WithText
	$areaData += @{
		Area      = $area
		Params    = $data.Params
		Texts     = $data.Texts
		Templates = $data.Templates
	}

	# Track covered rows
	$sr = $area.BeginRow
	$er = $area.EndRow
	if ($sr -ne -1 -and $er -ne -1) {
		for ($r = $sr; $r -le $er; $r++) {
			$coveredRows[$r] = $true
		}
	}
}

# Find parameters outside named areas
$outsideParams = @()
$outsideTexts = @()
$outsideTemplates = @()

foreach ($r in $rowMap.Keys | Sort-Object) {
	if (-not $coveredRows.ContainsKey($r)) {
		$cells = Get-CellData -rowNode $rowMap[$r] -ns $nsMgr -includeText $WithText
		foreach ($c in $cells) {
			switch ($c.Kind) {
				"Parameter" { $outsideParams += $c.Value }
				"Text"      { $outsideTexts += $c.Value }
				"Template"  { $outsideTemplates += $c.Value }
			}
		}
	}
}

# --- Counts ---

$mergeCount = $root.SelectNodes("d:merge", $nsMgr).Count
$drawingNodes = $root.SelectNodes("d:drawing", $nsMgr)
$drawingCount = $drawingNodes.Count

# --- Output ---

function Truncate-List {
	param([string[]]$items, [int]$max)
	if ($items.Count -le $max) {
		return ($items -join ", ")
	}
	$shown = ($items[0..($max - 1)] -join ", ")
	$remaining = $items.Count - $max
	return "$shown, ... (+$remaining)"
}

# Determine template name from path
$templateName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($TemplatePath)))

if ($Format -eq "json") {
	$result = @{
		name        = $templateName
		rows        = $docHeight
		columns     = $defaultColCount
		columnSets  = @($columnSets)
		areas       = @()
		outsideParams = @($outsideParams)
		mergeCount  = $mergeCount
		drawingCount = $drawingCount
	}

	foreach ($ad in $areaData) {
		$areaObj = @{
			name      = $ad.Area.Name
			type      = $ad.Area.AreaType
			beginRow  = $ad.Area.BeginRow
			endRow    = $ad.Area.EndRow
			beginCol  = $ad.Area.BeginCol
			endCol    = $ad.Area.EndCol
			params    = @($ad.Params)
		}
		if ($ad.Area.ColumnsID) { $areaObj.columnsID = $ad.Area.ColumnsID }
		if ($WithText) {
			$areaObj.texts = @($ad.Texts)
			$areaObj.templates = @($ad.Templates)
		}
		$result.areas += $areaObj
	}

	if ($WithText) {
		$result.outsideTexts = @($outsideTexts)
		$result.outsideTemplates = @($outsideTemplates)
	}

	foreach ($nd in $namedDrawings) {
		$result.areas += @{
			name      = $nd.Name
			type      = "Drawing"
			drawingID = $nd.DrawingID
		}
	}

	$result | ConvertTo-Json -Depth 5
	exit 0
}

# --- Text format output ---

$lines = @()

$lines += "=== $templateName ==="
$lines += "  Rows: $docHeight, Columns: $defaultColCount"

if ($columnSets.Count -eq 0) {
	$lines += "  Column sets: 1 (default only)"
} else {
	$lines += "  Column sets: $($columnSets.Count + 1) (default + $($columnSets.Count) additional)"
}

$lines += ""
$lines += "--- Named areas ---"

foreach ($ad in $areaData) {
	$a = $ad.Area
	$paramCount = $ad.Params.Count
	$rowRange = ""

	switch ($a.AreaType) {
		"Rows"      { $rowRange = "rows $($a.BeginRow)-$($a.EndRow)" }
		"Columns"   { $rowRange = "cols $($a.BeginCol)-$($a.EndCol)" }
		"Rectangle" { $rowRange = "rows $($a.BeginRow)-$($a.EndRow), cols $($a.BeginCol)-$($a.EndCol)" }
	}

	$colsInfo = ""
	if ($a.ColumnsID) {
		$colsInfo = " [colset]"
	}

	$paramInfo = "($paramCount params)"
	$nameStr = $a.Name.PadRight(25)
	$typeStr = $a.AreaType.PadRight(12)
	$lines += "  $nameStr $typeStr $rowRange  $paramInfo$colsInfo"
}

foreach ($nd in $namedDrawings) {
	$nameStr = $nd.Name.PadRight(25)
	$lines += "  $nameStr Drawing      drawingID=$($nd.DrawingID)"
}

# Parameters by area
$hasParams = ($areaData | Where-Object { $_.Params.Count -gt 0 }) -or ($outsideParams.Count -gt 0)

if ($hasParams) {
	$lines += ""
	$lines += "--- Parameters by area ---"
	foreach ($ad in $areaData) {
		if ($ad.Params.Count -gt 0) {
			$paramStr = Truncate-List -items $ad.Params -max $MaxParams
			$lines += "  $($ad.Area.Name): $paramStr"
		}
	}
	if ($outsideParams.Count -gt 0) {
		$paramStr = Truncate-List -items $outsideParams -max $MaxParams
		$lines += "  (outside areas): $paramStr"
	}
}

# WithText sections
if ($WithText) {
	$hasText = ($areaData | Where-Object { $_.Texts.Count -gt 0 -or $_.Templates.Count -gt 0 }) -or ($outsideTexts.Count -gt 0) -or ($outsideTemplates.Count -gt 0)

	if ($hasText) {
		$lines += ""
		$lines += "--- Text content ---"
		foreach ($ad in $areaData) {
			if ($ad.Texts.Count -gt 0 -or $ad.Templates.Count -gt 0) {
				$lines += "  $($ad.Area.Name):"
				if ($ad.Texts.Count -gt 0) {
					$textItems = $ad.Texts | ForEach-Object { "`"$_`"" }
					$textStr = Truncate-List -items $textItems -max $MaxParams
					$lines += "    Text: $textStr"
				}
				if ($ad.Templates.Count -gt 0) {
					$tplItems = $ad.Templates | ForEach-Object { "`"$_`"" }
					$tplStr = Truncate-List -items $tplItems -max $MaxParams
					$lines += "    Templates: $tplStr"
				}
			}
		}
		if ($outsideTexts.Count -gt 0 -or $outsideTemplates.Count -gt 0) {
			$lines += "  (outside areas):"
			if ($outsideTexts.Count -gt 0) {
				$textItems = $outsideTexts | ForEach-Object { "`"$_`"" }
				$textStr = Truncate-List -items $textItems -max $MaxParams
				$lines += "    Text: $textStr"
			}
			if ($outsideTemplates.Count -gt 0) {
				$tplItems = $outsideTemplates | ForEach-Object { "`"$_`"" }
				$tplStr = Truncate-List -items $tplItems -max $MaxParams
				$lines += "    Templates: $tplStr"
			}
		}
	}
}

$lines += ""
$lines += "--- Stats ---"
$lines += "  Merges: $mergeCount"
$lines += "  Drawings: $drawingCount"

# --- Truncation protection ---

$totalLines = $lines.Count

if ($Offset -gt 0) {
	if ($Offset -ge $totalLines) {
		Write-Host "[INFO] Offset $Offset exceeds total lines ($totalLines). Nothing to show."
		exit 0
	}
	$lines = $lines[$Offset..($totalLines - 1)]
}

if ($lines.Count -gt $Limit) {
	$shown = $lines[0..($Limit - 1)]
	foreach ($l in $shown) { Write-Host $l }
	$remaining = $totalLines - $Offset - $Limit
	Write-Host ""
	Write-Host "[TRUNCATED] Shown $Limit of $totalLines lines. Use -Offset $($Offset + $Limit) to continue."
} else {
	foreach ($l in $lines) { Write-Host $l }
}
