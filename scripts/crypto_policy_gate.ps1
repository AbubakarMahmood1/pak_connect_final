param(
    [string]$FlutterExe = 'flutter',
    [string]$LogPath = 'crypto_policy_gate_latest.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-StrictCryptoTest {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$TestFile,
        [Parameter(Mandatory = $true)][string]$PlainName,
        [string[]]$Defines = @()
    )

    Write-Host ''
    Write-Host "==> $Label"

    $args = @('test', $TestFile, '--plain-name', $PlainName) + $Defines
    $commandPreview = "$FlutterExe $($args -join ' ')"
    Write-Host $commandPreview

    Add-Content -Path $LogPath -Value ''
    Add-Content -Path $LogPath -Value "==> $Label"
    Add-Content -Path $LogPath -Value $commandPreview

    & $FlutterExe @args 2>&1 | Tee-Object -FilePath $LogPath -Append
    if ($LASTEXITCODE -ne 0) {
        throw "Crypto policy gate failed: $Label"
    }
}

if (Test-Path $LogPath) {
    Remove-Item -Path $LogPath -Force
}

$testCases = @(
    [PSCustomObject]@{
        Label = 'reject removed legacy transport when no sealed_v1 fallback exists'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'central send rejects removed legacy transport when no sealed_v1 fallback exists'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'upgrade removed legacy transport to sealed_v1 when recipient static key exists'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'send upgrades to sealed_v1 when recipient Noise static key is known'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'auto-fall back to sealed_v1 when removed legacy transport cannot send directly'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'send auto-falls back to sealed_v1 when legacy transport is unavailable'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'use sealed_v1 for upgraded peers after removed legacy transport'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'upgraded peer also uses sealed_v1 after legacy transport removal'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'protocol handler enforces v2 encrypted signature policy'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'requires signature for v2 encrypted message when policy enabled'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'protocol handler enforces v2 encrypted signature after peer upgrade'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'requires signature for encrypted v2 message once peer floor is upgraded'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'protocol handler rejects sealed v2 messages missing sender binding'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'rejects v2 sealed message missing sender binding'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'protocol handler rejects unsigned v2 direct plaintext text'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'rejects unsigned v2 direct plaintext text message'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'protocol handler rejects removed legacy transport after peer upgrade'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'rejects removed legacy transport header after peer upgrade'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'inbound processor enforces v2 encrypted signature policy'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'requires signature for v2 encrypted message when policy enabled'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'inbound processor enforces v2 encrypted signature after peer upgrade'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'requires signature for encrypted v2 message once peer floor is upgraded'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'inbound processor rejects sealed v2 payload missing sender binding'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'rejects sealed v2 payload missing sender binding'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'inbound processor rejects unsigned v2 direct plaintext text'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'rejects unsigned v2 direct plaintext text message'
        Defines = @()
    },
    [PSCustomObject]@{
        Label = 'inbound processor rejects removed legacy transport after peer upgrade'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'rejects removed legacy transport header after peer upgrade'
        Defines = @()
    }
)

foreach ($testCase in $testCases) {
    Invoke-StrictCryptoTest `
        -Label $testCase.Label `
        -TestFile $testCase.TestFile `
        -PlainName $testCase.PlainName `
        -Defines $testCase.Defines
}

Write-Host ''
Write-Host "Crypto policy gate passed. Log: $LogPath"
