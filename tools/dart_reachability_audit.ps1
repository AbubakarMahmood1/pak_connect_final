[CmdletBinding()]
param(
  [string]$RepoRoot = (Join-Path $PSScriptRoot '..'),
  [string]$AllowlistPath = (Join-Path $PSScriptRoot 'dart_reachability_allowlist.json'),
  [switch]$FailOnUnreviewed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
}

function Get-RepoRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

$repoRootPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$libRoot = Join-Path $repoRootPath 'lib'
$normalizedLibRoot = Get-NormalizedPath -Path $libRoot
$pubspecPath = Join-Path $repoRootPath 'pubspec.yaml'

if (-not (Test-Path -LiteralPath $libRoot -PathType Container)) {
  throw "Missing lib directory under repo root: $repoRootPath"
}
if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) {
  throw "Missing pubspec.yaml under repo root: $repoRootPath"
}

$pubspecText = Get-Content -LiteralPath $pubspecPath -Raw
$packageNameMatch = [regex]::Match(
  $pubspecText,
  '(?m)^\s*name:\s*([A-Za-z0-9_]+)\s*$'
)
if (-not $packageNameMatch.Success) {
  throw 'Could not read the Dart package name from pubspec.yaml.'
}
$packagePrefix = "package:$($packageNameMatch.Groups[1].Value)/"

$libFiles = @(
  Get-ChildItem -LiteralPath $libRoot -Recurse -File -Filter '*.dart' |
    Sort-Object FullName
)
$libraryByPath = @{}
foreach ($file in $libFiles) {
  $libraryByPath[(Get-NormalizedPath -Path $file.FullName)] = $file
}

$missingLocalReferences = [System.Collections.Generic.List[string]]::new()

function Get-LocalDartReferences {
  param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

  $content = Get-Content -LiteralPath $File.FullName -Raw
  $references = @()
  $directiveMatches = [regex]::Matches(
    $content,
    '(?ms)^\s*(?:import|export|part)\s+(?!of\b)([^;]+);'
  )

  foreach ($directive in $directiveMatches) {
    $uriMatches = [regex]::Matches(
      $directive.Groups[1].Value,
      '[''"]([^''"]+\.dart)[''"]'
    )
    foreach ($uriMatch in $uriMatches) {
      $uri = $uriMatch.Groups[1].Value
      $target = $null
      $isPackageLocal = $false

      if ($uri.StartsWith($packagePrefix, [System.StringComparison]::Ordinal)) {
        $target = Join-Path $libRoot $uri.Substring($packagePrefix.Length)
        $isPackageLocal = $true
      }
      elseif (-not $uri.Contains(':')) {
        $target = Join-Path $File.DirectoryName $uri
      }
      else {
        continue
      }

      $targetPath = Get-NormalizedPath -Path $target
      if ($libraryByPath.ContainsKey($targetPath)) {
        $references += $targetPath
      }
      elseif (
        $isPackageLocal -or
        (Get-NormalizedPath -Path $File.FullName).StartsWith(
          "$normalizedLibRoot/",
          [System.StringComparison]::OrdinalIgnoreCase
        )
      ) {
        $sourcePath = Get-RepoRelativePath -Root $repoRootPath -Path $File.FullName
        $missingLocalReferences.Add("$sourcePath -> $uri")
      }
    }
  }

  return @($references | Sort-Object -Unique)
}

$edges = @{}
foreach ($file in $libFiles) {
  $sourcePath = Get-NormalizedPath -Path $file.FullName
  $edges[$sourcePath] = @(Get-LocalDartReferences -File $file)
}

function Get-ReachableSet {
  param(
    [Parameter(Mandatory = $true)][string[]]$Roots,
    [Parameter(Mandatory = $true)][hashtable]$Graph
  )

  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  $pending = [System.Collections.Generic.Stack[string]]::new()
  foreach ($root in $Roots) {
    if ($libraryByPath.ContainsKey($root)) {
      $pending.Push($root)
    }
  }

  while ($pending.Count -gt 0) {
    $current = $pending.Pop()
    if (-not $seen.Add($current)) {
      continue
    }
    foreach ($next in @($Graph[$current])) {
      if (-not $seen.Contains($next)) {
        $pending.Push($next)
      }
    }
  }

  Write-Output -NoEnumerate $seen
}

$runtimeRootRelativePaths = @('lib/main.dart')
$runtimeRootPaths = @(
  $runtimeRootRelativePaths |
    ForEach-Object { Get-NormalizedPath -Path (Join-Path $repoRootPath $_) }
)
foreach ($runtimeRoot in $runtimeRootPaths) {
  if (-not $libraryByPath.ContainsKey($runtimeRoot)) {
    throw "Runtime root is missing or outside lib: $runtimeRoot"
  }
}
$runtimeReachable = Get-ReachableSet -Roots $runtimeRootPaths -Graph $edges

$testFiles = @()
foreach ($testDirectory in @('test', 'integration_test')) {
  $testRoot = Join-Path $repoRootPath $testDirectory
  if (Test-Path -LiteralPath $testRoot -PathType Container) {
    $testFiles += @(
      Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.dart'
    )
  }
}
$testLibraryRoots = @()
foreach ($testFile in @($testFiles | Sort-Object FullName)) {
  $testLibraryRoots += @(Get-LocalDartReferences -File $testFile)
}
$testReachable = Get-ReachableSet `
  -Roots @($testLibraryRoots | Sort-Object -Unique) `
  -Graph $edges

if ($missingLocalReferences.Count -gt 0) {
  $details = $missingLocalReferences | Sort-Object -Unique
  throw "Unresolved local Dart references prevent a complete graph:`n$($details -join "`n")"
}

$resolvedAllowlistPath = if ([System.IO.Path]::IsPathRooted($AllowlistPath)) {
  $AllowlistPath
}
else {
  Join-Path $repoRootPath $AllowlistPath
}
if (-not (Test-Path -LiteralPath $resolvedAllowlistPath -PathType Leaf)) {
  throw "Reachability allowlist not found: $resolvedAllowlistPath"
}

$allowlist = Get-Content -LiteralPath $resolvedAllowlistPath -Raw |
  ConvertFrom-Json
if ($allowlist.schemaVersion -ne 1) {
  throw "Unsupported allowlist schemaVersion: $($allowlist.schemaVersion)"
}
if ([string]::IsNullOrWhiteSpace([string]$allowlist.reviewedOn)) {
  throw 'Reachability allowlist is missing reviewedOn.'
}

$reviewedByPath = @{}
foreach ($entry in @($allowlist.entries)) {
  foreach ($requiredField in @(
    'path',
    'classification',
    'owner',
    'reason',
    'exitCondition'
  )) {
    $value = $entry.$requiredField
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
      throw "Allowlist entry is missing '$requiredField': $($entry | ConvertTo-Json -Compress)"
    }
  }

  $entryPath = ([string]$entry.path).Replace('\', '/')
  if ([System.IO.Path]::IsPathRooted($entryPath) -or $entryPath.Contains('..')) {
    throw "Allowlist paths must be repo-relative and cannot contain '..': $entryPath"
  }
  if (-not $entryPath.StartsWith('lib/') -or -not $entryPath.EndsWith('.dart')) {
    throw "Allowlist entries must identify Dart libraries under lib/: $entryPath"
  }
  if ($reviewedByPath.ContainsKey($entryPath)) {
    throw "Duplicate reachability allowlist entry: $entryPath"
  }

  $fullEntryPath = Join-Path $repoRootPath $entryPath
  if (-not (Test-Path -LiteralPath $fullEntryPath -PathType Leaf)) {
    throw "Allowlisted Dart library does not exist: $entryPath"
  }
  $reviewedByPath[$entryPath] = $entry
}

$candidates = @()
foreach ($key in @($libraryByPath.Keys | Sort-Object)) {
  if ($runtimeReachable.Contains($key)) {
    continue
  }

  $file = $libraryByPath[$key]
  $relativePath = Get-RepoRelativePath -Root $repoRootPath -Path $file.FullName
  $candidates += [pscustomobject]@{
    Path = $relativePath
    Lines = @(Get-Content -LiteralPath $file.FullName).Count
    TestReachable = $testReachable.Contains($key)
    Reviewed = $reviewedByPath.ContainsKey($relativePath)
  }
}
$candidates = @($candidates | Sort-Object Path)

$staleReviewedPaths = @(
  $reviewedByPath.Keys |
    Where-Object { $_ -notin $candidates.Path } |
    Sort-Object
)
if ($staleReviewedPaths.Count -gt 0) {
  throw "Allowlist contains runtime-reachable or stale paths:`n$($staleReviewedPaths -join "`n")"
}

$reviewedCandidates = @($candidates | Where-Object Reviewed)
$unreviewedTestOnly = @(
  $candidates |
    Where-Object { -not $_.Reviewed -and $_.TestReachable }
)
$unreviewedDead = @(
  $candidates |
    Where-Object { -not $_.Reviewed -and -not $_.TestReachable }
)
$testOnlyCandidates = @($candidates | Where-Object TestReachable)
$runtimeAndTestUnreached = @(
  $candidates | Where-Object { -not $_.TestReachable }
)

Write-Output 'Dart library reachability audit'
Write-Output '-------------------------------'
Write-Output "Runtime roots:                  $($runtimeRootRelativePaths -join ', ')"
Write-Output "Libraries under lib/:           $($libFiles.Count)"
Write-Output "Runtime reachable:              $($runtimeReachable.Count)"
Write-Output "Runtime unreachable:            $($candidates.Count)"
Write-Output "Runtime-unreachable lines:      $(($candidates | Measure-Object Lines -Sum).Sum)"
Write-Output "Test-root-only candidates:      $($testOnlyCandidates.Count)"
Write-Output "Runtime + test unreachable:     $($runtimeAndTestUnreached.Count)"
Write-Output "Reviewed candidates:            $($reviewedCandidates.Count)"
Write-Output "Unreviewed test-only:           $($unreviewedTestOnly.Count)"
Write-Output "Unreviewed runtime + test dead: $($unreviewedDead.Count)"

Write-Output ''
Write-Output 'Reviewed candidates'
foreach ($candidate in $reviewedCandidates) {
  $entry = $reviewedByPath[$candidate.Path]
  Write-Output "  $($candidate.Path) [$($entry.classification); owner=$($entry.owner)]"
}

Write-Output ''
Write-Output 'Unreviewed test-root-only candidates'
foreach ($candidate in $unreviewedTestOnly) {
  Write-Output "  $($candidate.Path) ($($candidate.Lines) lines)"
}

Write-Output ''
Write-Output 'Unreviewed runtime + test unreachable candidates'
foreach ($candidate in $unreviewedDead) {
  Write-Output "  $($candidate.Path) ($($candidate.Lines) lines)"
}

if ($FailOnUnreviewed -and (
  $unreviewedTestOnly.Count -gt 0 -or $unreviewedDead.Count -gt 0
)) {
  Write-Error 'Unreviewed unreachable Dart libraries remain.'
  exit 1
}
