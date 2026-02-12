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

$strictBlePolicyDefines = @(
    '--dart-define=PAKCONNECT_ALLOW_LEGACY_V2_SEND=false',
    '--dart-define=PAKCONNECT_ENABLE_SEALED_V1_SEND=true'
)

$testCases = @(
    [PSCustomObject]@{
        Label = 'block legacy v2 send when strict policy is enabled'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'central send blocks legacy v2 crypto mode when compatibility is disabled'
        Defines = $strictBlePolicyDefines
    },
    [PSCustomObject]@{
        Label = 'allow sealed_v1 strict fallback when recipient static key exists'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'strict mode can emit sealed_v1 when recipient Noise static key is known'
        Defines = $strictBlePolicyDefines
    },
    [PSCustomObject]@{
        Label = 'auto sealed_v1 fallback for upgraded peers'
        TestFile = 'test/data/services/ble_write_adapter_test.dart'
        PlainName = 'upgraded peer auto-falls back to sealed_v1 even when rollout flag is disabled'
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
        Label = 'protocol handler blocks legacy v2 mode for upgraded peer floor'
        TestFile = 'test/data/services/protocol_message_handler_test.dart'
        PlainName = 'blocks legacy v2 decrypt mode for peers already observed at v2 floor'
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
        Label = 'inbound processor blocks legacy v2 mode for upgraded peer floor'
        TestFile = 'test/data/services/inbound_text_processor_test.dart'
        PlainName = 'blocks legacy v2 decrypt mode for peers already observed at v2 floor'
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
