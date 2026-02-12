param(
  [string]$RepoRoot = '.',
  [string]$BaselineOut = 'validation_outputs/di_pass0_baseline.json',
  [switch]$WriteBaseline,
  [switch]$EnforcePresentationImportGate,
  [switch]$EnforcePresentationDiMutationGate,
  [switch]$EnforceMetricsGate,
  [int]$MaxGetItResolutionCount = -1,
  [int]$MaxInstanceUsageCount = -1,
  [string[]]$AllowedPresentationGetItFiles = @(
    'lib/presentation/providers/di_providers.dart'
  )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RgLines {
  param(
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string[]]$Paths
  )

  $args = @('-n', $Pattern) + $Paths + @('--glob', '*.dart')
  $raw = & rg @args 2>$null
  if ($LASTEXITCODE -eq 0) {
    return @($raw)
  }
  if ($LASTEXITCODE -eq 1) {
    return @()
  }
  throw "rg command failed for pattern: $Pattern"
}

function Parse-RgEntries {
  param([string[]]$Lines)
  $entries = @()
  foreach ($line in $Lines) {
    if ($line -match '^([^:]+):(\d+):(.*)$') {
      $entries += [PSCustomObject]@{
        Path = $Matches[1].Replace('\', '/')
        Line = [int]$Matches[2]
        Text = $Matches[3]
      }
    }
  }
  return $entries
}

Push-Location $RepoRoot
try {
  if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
    throw 'ripgrep (rg) is required for this audit script.'
  }

  $allowedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($allowed in $AllowedPresentationGetItFiles) {
    [void]$allowedSet.Add($allowed.Replace('\', '/'))
  }

  $getItResolutionEntries = Parse-RgEntries (Get-RgLines -Pattern 'GetIt\.instance|getIt<' -Paths @('lib'))
  $instanceEntries = Parse-RgEntries (Get-RgLines -Pattern '\.instance\b' -Paths @('lib'))
  $presentationResolutionEntries = Parse-RgEntries (Get-RgLines -Pattern 'GetIt\.instance|getIt<' -Paths @('lib/presentation'))
  $presentationGetItImportEntries = Parse-RgEntries (Get-RgLines -Pattern "import 'package:get_it/get_it.dart';" -Paths @('lib/presentation'))
  $presentationDiMutationEntries = Parse-RgEntries (Get-RgLines -Pattern '\.(registerSingleton|registerLazySingleton|registerFactory|unregister)<' -Paths @('lib/presentation'))

  $resolutionByLayer = @()
  $resolutionByLayer += $getItResolutionEntries | ForEach-Object {
    $parts = $_.Path -split '/'
    $layer = if ($parts.Length -ge 2) { $parts[1] } else { 'unknown' }
    [PSCustomObject]@{
      Layer = $layer
      Count = 1
    }
  } | Group-Object Layer | Sort-Object Count -Descending | ForEach-Object {
    [PSCustomObject]@{
      layer = $_.Name
      count = $_.Count
    }
  }

  $topGetItResolutionFiles = @()
  $topGetItResolutionFiles += $getItResolutionEntries |
    Group-Object Path |
    Sort-Object Count -Descending |
    Select-Object -First 20 |
    ForEach-Object {
      [PSCustomObject]@{
        path = $_.Name
        count = $_.Count
      }
    }

  $presentationImportFiles = @(
    $presentationGetItImportEntries |
      Select-Object -ExpandProperty Path -Unique |
      Sort-Object
  )

  $presentationImportViolations = @()
  foreach ($path in $presentationImportFiles) {
    if (-not $allowedSet.Contains($path)) {
      $presentationImportViolations += $path
    }
  }

  $presentationDiMutationFiles = @(
    $presentationDiMutationEntries |
      Select-Object -ExpandProperty Path -Unique |
      Sort-Object
  )

  $snapshot = [PSCustomObject]@{
    schemaVersion = 2
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    scope = 'lib/**/*.dart'
    metrics = [PSCustomObject]@{
      getItResolutionCount = @($getItResolutionEntries).Count
      instanceUsageCount = @($instanceEntries).Count
      presentationGetItResolutionCount = @($presentationResolutionEntries).Count
      presentationGetItImportCount = @($presentationGetItImportEntries).Count
      presentationGetItImportFileCount = @($presentationImportFiles).Count
      presentationDiMutationCount = @($presentationDiMutationEntries).Count
    }
    breakdown = [PSCustomObject]@{
      getItResolutionsByLayer = $resolutionByLayer
      topGetItResolutionFiles = $topGetItResolutionFiles
    }
    guardrails = [PSCustomObject]@{
      mode = if ($EnforcePresentationImportGate) { 'enforced' } else { 'advisory' }
      allowedPresentationGetItImportFiles = $AllowedPresentationGetItFiles
      presentationGetItImportViolationCount = @($presentationImportViolations).Count
      presentationGetItImportViolations = $presentationImportViolations
      presentationDiMutationViolationCount = @($presentationDiMutationFiles).Count
      presentationDiMutationViolations = $presentationDiMutationFiles
    }
  }

  Write-Host ''
  Write-Host 'DI Pass 0 Snapshot'
  Write-Host '------------------'
  Write-Host ("GetIt resolutions (lib):            {0}" -f $snapshot.metrics.getItResolutionCount)
  Write-Host (".instance usages (lib):             {0}" -f $snapshot.metrics.instanceUsageCount)
  Write-Host ("GetIt resolutions (presentation):   {0}" -f $snapshot.metrics.presentationGetItResolutionCount)
  Write-Host ("get_it imports (presentation):      {0} in {1} files" -f $snapshot.metrics.presentationGetItImportCount, $snapshot.metrics.presentationGetItImportFileCount)
  Write-Host ("Import guard violations:            {0}" -f $snapshot.guardrails.presentationGetItImportViolationCount)
  Write-Host ("DI mutation sites (presentation):   {0}" -f $snapshot.metrics.presentationDiMutationCount)
  Write-Host ("DI mutation file violations:        {0}" -f $snapshot.guardrails.presentationDiMutationViolationCount)
  if ($EnforceMetricsGate) {
    if ($MaxGetItResolutionCount -ge 0) {
      Write-Host ("Metric gate (GetIt max):            {0}" -f $MaxGetItResolutionCount)
    }
    if ($MaxInstanceUsageCount -ge 0) {
      Write-Host ("Metric gate (.instance max):        {0}" -f $MaxInstanceUsageCount)
    }
  }

  if ($WriteBaseline) {
    $outputDir = Split-Path -Parent $BaselineOut
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $BaselineOut -Encoding UTF8
    Write-Host ("Baseline written:                   {0}" -f $BaselineOut)
  }

  if ($EnforcePresentationImportGate -and @($presentationImportViolations).Count -gt 0) {
    Write-Error (
      "Presentation import gate failed. get_it is only allowed in: " +
      ($AllowedPresentationGetItFiles -join ', ')
    )
    Write-Error ("Violations: {0}" -f ($presentationImportViolations -join ', '))
    exit 1
  }

  if ($EnforcePresentationDiMutationGate -and @($presentationDiMutationFiles).Count -gt 0) {
    Write-Error (
      "Presentation DI mutation gate failed. Provider/presentation code must not call " +
      "registerSingleton/registerLazySingleton/registerFactory/unregister."
    )
    Write-Error ("Violations: {0}" -f ($presentationDiMutationFiles -join ', '))
    exit 1
  }

  if ($EnforceMetricsGate) {
    if ($MaxGetItResolutionCount -ge 0 -and
        $snapshot.metrics.getItResolutionCount -gt $MaxGetItResolutionCount) {
      Write-Error (
        "DI metric gate failed: getItResolutionCount={0} exceeds max={1}" -f
        $snapshot.metrics.getItResolutionCount, $MaxGetItResolutionCount
      )
      exit 1
    }

    if ($MaxInstanceUsageCount -ge 0 -and
        $snapshot.metrics.instanceUsageCount -gt $MaxInstanceUsageCount) {
      Write-Error (
        "DI metric gate failed: instanceUsageCount={0} exceeds max={1}" -f
        $snapshot.metrics.instanceUsageCount, $MaxInstanceUsageCount
      )
      exit 1
    }
  }
}
finally {
  Pop-Location
}
