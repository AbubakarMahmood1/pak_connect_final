param(
  [switch]$Delete
)

$ErrorActionPreference = 'Stop'

$legacyDirs = @(
  'lib/core/interfaces',
  'lib/core/models',
  'lib/core/constants',
  'lib/core/utils',
  'lib/core/routing',
  'lib/core/config',
  'lib/core/compression',
  'lib/core/monitoring',
  'lib/core/networking',
  'lib/core/performance',
  'lib/core/scanning'
)

function Get-DirEntries {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    return @()
  }
  return @(Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue)
}

Write-Output "Legacy shim directory audit:"
$nonEmpty = @()

foreach ($dir in $legacyDirs) {
  if (-not (Test-Path $dir)) {
    Write-Output "  [MISSING] $dir"
    continue
  }

  $entries = Get-DirEntries -Path $dir
  if ($entries.Count -eq 0) {
    Write-Output "  [EMPTY]   $dir"
  } else {
    Write-Output "  [NONEMPTY] $dir (entries: $($entries.Count))"
    $nonEmpty += $dir
    foreach ($entry in $entries) {
      Write-Output "    - $($entry.FullName)"
    }
  }
}

if (-not $Delete) {
  if ($nonEmpty.Count -eq 0) {
    Write-Output "`nAll legacy shim directories are empty or missing."
  } else {
    Write-Output "`nSome legacy shim directories are non-empty. Review before deleting."
    exit 1
  }
  exit 0
}

Write-Output "`nDelete mode enabled."
if ($nonEmpty.Count -gt 0) {
  Write-Output "Aborting delete: one or more directories are non-empty."
  exit 1
}

foreach ($dir in $legacyDirs) {
  if (Test-Path $dir) {
    Remove-Item $dir -Force
    Write-Output "  Deleted empty directory: $dir"
  }
}

Write-Output "Cleanup complete."
