param(
    [switch]$EnforceNoPrint,
    [switch]$EnforceTimerPeriodicGate,
    [int]$MaxTimerPeriodicCount = 23
)

$ErrorActionPreference = "Stop"

function Get-RgMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [string]$Path = "lib",
        [switch]$Pcre2
    )

    $args = @("-n", "--glob", "*.dart")
    if ($Pcre2) {
        $args += "-P"
    }
    $args += $Pattern
    $args += $Path

    $output = & rg @args 2>$null
    if ($LASTEXITCODE -eq 0) {
        return @($output)
    }
    if ($LASTEXITCODE -eq 1) {
        return @()
    }
    throw "ripgrep failed with exit code $LASTEXITCODE for pattern: $Pattern"
}

if ($EnforceNoPrint) {
    $printMatches = Get-RgMatches -Pattern '^\s*(?!//).*\bprint\(' -Path "lib" -Pcre2
    $printCount = $printMatches.Count
    Write-Host "Runtime hygiene: non-comment print(...) usages in lib = $printCount"
    if ($printCount -gt 0) {
        Write-Host "Disallowed print(...) usages detected:" -ForegroundColor Red
        $printMatches | ForEach-Object { Write-Host $_ }
        throw "Runtime hygiene gate failed: print(...) is not allowed in lib/."
    }
}

if ($EnforceTimerPeriodicGate) {
    $timerMatches = Get-RgMatches -Pattern '\bTimer\.periodic\(' -Path "lib"
    $timerCount = $timerMatches.Count
    Write-Host "Runtime hygiene: Timer.periodic(...) usages in lib = $timerCount (max allowed: $MaxTimerPeriodicCount)"
    if ($timerCount -gt $MaxTimerPeriodicCount) {
        Write-Host "Timer.periodic(...) over budget. Matches:" -ForegroundColor Red
        $timerMatches | ForEach-Object { Write-Host $_ }
        throw "Runtime hygiene gate failed: Timer.periodic count increased beyond baseline."
    }
}
