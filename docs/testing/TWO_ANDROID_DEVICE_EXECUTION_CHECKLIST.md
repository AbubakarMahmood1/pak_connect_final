# Two-Android-device execution checklist

This is the executable run sheet for the live matrix in
[DEVICE_VALIDATION_STATUS.md](DEVICE_VALIDATION_STATUS.md). Run it from the
repository root in PowerShell 7 or newer. Use only `PASS`, `FAIL`, `BLOCKED`,
and `NOT RUN` in the final record.

The fixed build/runtime verification baseline is:

- commit: `9434384851298c976cda0269f6cef65ebaafed1c`
- short commit: `9434384`
- branch used to prepare the baseline: `codex/archive-delete-contract`
- local verification toolchain: Flutter 3.44.4 revision
  `ad70ec4617166f1c38e5d2bfd388af71fda14f06` / Dart 3.12.2
- analyzer: clean on 2026-07-14
- full desktop suite: 5,691 passed, 0 failed; reporter 5m37s; measured wall
  353,083 ms
- full-suite log: 9,268,167 bytes; SHA-256
  `78798AD4575FB77E3B99F50C5D30B4715CE44CAA9BDC5245982CAF5F3892C905`
- coverage artifact: `coverage/lcov.info`; 426,546 bytes; SHA-256
  `57F95535FC93711B39344343A1D8F2DE644B9697EA23F45204D1529CE84BF794`
- verified debug APK: `build/app/outputs/flutter-apk/app-debug.apk`
- verified debug APK size: `205113616` bytes
- verified debug APK SHA-256:
  `84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059`

A descendant with no changes in the listed build/runtime verification tree is
acceptable. Any changed listed input is a hard stop until the new code has its
own baseline and desktop verification. In the rewritten local history,
`19c4824` is the combined route/offline implementation commit, `10b1830` is
its documentation checkpoint, and `b024cab` is the superseded prior runtime
baseline. They remain historical provenance only; no older commit is valid for
this run.

## Honest two-device boundary

Two Android phones can close the permissions, directional discovery,
collision, Noise XX/KK, direct messaging, queue/reconnect,
foreground/background/resume, fragmentation, strict-TDM bring-up,
log/privacy, and the SQLCipher at-rest row. They cannot prove delivery while an
app is killed or dozing. Controlled secure-storage fault injection remains
`BLOCKED` without a reviewed safe hook.

Two phones cannot prove either of these rows:

- `Multi-link inventory/routing`: requires one device to hold at least two
  simultaneous peer links, so add a third device.
- `Relay A -> B -> C`: requires three physical peers with A unable to reach C
  directly. C must decode the signed encrypted v2 inner `ProtocolMessage`,
  authenticate/decrypt and persist it before the routed ACK. A processing
  failure must produce no ACK and no seen mark; a retry after completed final
  delivery must resend the ACK without redelivering the message.

Record those two rows as `BLOCKED: third Android device required`; do not infer
a pass from unit tests or a single A/B link. The full strict-TDM architecture
decision also remains provisional until the three-device relay comparison in
[android_ble_tdm_device_runbook.md](../refactoring/android_ble_tdm_device_runbook.md)
is promoted into a baseline-bound extension of this checklist and run. The
legacy runbook by itself is not evidence.

## 0. Baseline and workspace gate

Open a PowerShell terminal at the repository root and run:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') {
  throw 'This run sheet requires PowerShell 7 or newer.'
}

$ExpectedBaseline = '9434384851298c976cda0269f6cef65ebaafed1c'
$BaselineShort = $ExpectedBaseline.Substring(0, 7)
$Baseline = $BaselineShort
$Package = 'com.pakconnect.app'
$PuroEnvironment = 'ci-3-44-4'
$ExpectedFlutterVersion = '3.44.4'
$ExpectedFlutterRevision = 'ad70ec4617166f1c38e5d2bfd388af71fda14f06'
$ExpectedDartVersion = '3.12.2'

$PuroCommand = (Get-Command puro -ErrorAction Stop).Source
function Invoke-BaselineFlutter {
  & $PuroCommand --no-progress -e $PuroEnvironment flutter @args
}

$ResolvedBaselineOutput = git rev-parse $Baseline 2>&1
if ($LASTEXITCODE -ne 0) { throw "Missing baseline: $Baseline" }
$ResolvedBaseline = ($ResolvedBaselineOutput | Out-String).Trim()
if ($ResolvedBaseline -ne $ExpectedBaseline) {
  throw "Wrong or missing baseline: $ResolvedBaseline"
}

git merge-base --is-ancestor $Baseline HEAD
if ($LASTEXITCODE -ne 0) {
  throw 'The device baseline is not an ancestor of HEAD.'
}

$BuildInputs = @(
  'lib', 'test', 'integration_test', 'android', 'ios', 'linux', 'macos',
  'web', 'windows', 'assets', 'pubspec.yaml', 'pubspec.lock', '.metadata',
  'analysis_options.yaml'
)
git diff --exit-code "${Baseline}..HEAD" -- $BuildInputs
if ($LASTEXITCODE -ne 0) {
  throw "Build inputs differ from $Baseline. Create and verify a new baseline."
}

git diff --exit-code $Baseline -- $BuildInputs
if ($LASTEXITCODE -ne 0) {
  throw 'Tracked build inputs have staged or unstaged edits.'
}
$BuildInputStatus = @(git status --porcelain -- $BuildInputs)
if ($LASTEXITCODE -ne 0 -or $BuildInputStatus.Count -gt 0) {
  throw "Build-input worktree is not clean:`n$($BuildInputStatus -join "`n")"
}

$InitialStatus = @(git status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $InitialStatus.Count -gt 0) {
  throw "The full worktree must be clean before device evidence begins:`n$($InitialStatus -join "`n")"
}

$ChecklistPath = (Resolve-Path -LiteralPath `
  'docs/testing/TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md').Path
$ChecklistHash = (Get-FileHash -LiteralPath $ChecklistPath -Algorithm SHA256).Hash

git status --short
git log -2 --oneline --decorate

$FlutterMachineRaw = (Invoke-BaselineFlutter --version --machine 2>&1 |
  Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Pinned flutter --version --machine failed.' }
try {
  $FlutterMachine = $FlutterMachineRaw | ConvertFrom-Json
} catch {
  throw "Could not parse pinned Flutter machine output:`n$FlutterMachineRaw"
}

$ParsedFlutterVersion = [string]$FlutterMachine.frameworkVersion
$ParsedFlutterRevision = [string]$FlutterMachine.frameworkRevision
$ParsedDartVersion = [string]$FlutterMachine.dartSdkVersion
if ($ParsedFlutterVersion -ne $ExpectedFlutterVersion -or
    $ParsedFlutterRevision -ne $ExpectedFlutterRevision -or
    $ParsedDartVersion -ne $ExpectedDartVersion) {
  throw "Toolchain drift: Flutter $ParsedFlutterVersion ($ParsedFlutterRevision), Dart $ParsedDartVersion. Promote a new baseline instead."
}

$FlutterVersionOutput = (Invoke-BaselineFlutter --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Pinned flutter --version failed.' }

$FlutterVersionOutput
Invoke-BaselineFlutter doctor -v
if ($LASTEXITCODE -ne 0) { throw 'Pinned flutter doctor failed.' }
adb --version
if ($LASTEXITCODE -ne 0) { throw 'adb --version failed.' }
```

Checklist:

- [ ] Baseline resolves to the expected full commit.
- [ ] Baseline is an ancestor of `HEAD`.
- [ ] The build-input diff command exits zero with no output.
- [ ] The worktree is clean before device evidence begins.
- [ ] Puro environment `ci-3-44-4` resolves exact Flutter 3.44.4 revision
  `ad70ec4617166f1c38e5d2bfd388af71fda14f06` with bundled Dart 3.12.2.
  Any drift is a hard stop requiring a new baseline.
- [ ] Full toolchain output and the exact checklist hash are saved in evidence.
- [ ] Android toolchain and licenses are healthy.

Do not switch branches, pull, merge, rebase, or change dependencies during the
run.

## 1. Create an ignored evidence session

`validation_outputs/` is Git-ignored. Device serials and raw logs stay there;
do not put them in committed Markdown.

```powershell
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Evidence = Join-Path (Get-Location) "validation_outputs\android_two_device_$Stamp"
New-Item -ItemType Directory -Force $Evidence | Out-Null

"baseline=$ExpectedBaseline" | Set-Content "$Evidence\session_metadata.txt"
"baseline_short=$BaselineShort" | Add-Content "$Evidence\session_metadata.txt"
"head=$((git rev-parse HEAD).Trim())" | Add-Content "$Evidence\session_metadata.txt"
"branch=$((git branch --show-current).Trim())" | Add-Content "$Evidence\session_metadata.txt"
"started=$((Get-Date).ToString('o'))" | Add-Content "$Evidence\session_metadata.txt"
"flutter_version=$ParsedFlutterVersion" | Add-Content "$Evidence\session_metadata.txt"
"flutter_revision=$ParsedFlutterRevision" | Add-Content "$Evidence\session_metadata.txt"
"dart_version=$ParsedDartVersion" | Add-Content "$Evidence\session_metadata.txt"
"flutter_root=$($FlutterMachine.flutterRoot)" | Add-Content "$Evidence\session_metadata.txt"
"puro_environment=$PuroEnvironment" | Add-Content "$Evidence\session_metadata.txt"
"checklist_sha256=$ChecklistHash" | Add-Content "$Evidence\session_metadata.txt"
$FlutterMachineRaw | Set-Content "$Evidence\flutter_version_machine.json"
$FlutterVersionOutput | Set-Content "$Evidence\flutter_version.txt"
Copy-Item -LiteralPath $ChecklistPath `
  "$Evidence\TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md"
Set-Content "$Evidence\git_status_start.txt" -Value ($InitialStatus -join "`n")
Invoke-BaselineFlutter doctor -v 2>&1 |
  Tee-Object "$Evidence\flutter_doctor.txt"
if ($LASTEXITCODE -ne 0) { throw 'Pinned flutter doctor capture failed.' }
adb devices -l 2>&1 | Tee-Object "$Evidence\adb_devices.txt"
if ($LASTEXITCODE -ne 0) { throw 'Initial adb device capture failed.' }

function Mark([string]$Text) {
  "$((Get-Date).ToString('o')) $Text" |
    Tee-Object -FilePath "$Evidence\operator_timeline.txt" -Append
}
```

Connect exactly two physical Android phones by USB, accept their debugging
prompts, then assign their serials. Keep the mapping unchanged for the entire
run.

```powershell
$DeviceA = '<device-A-serial>'
$DeviceB = '<device-B-serial>'

if ($DeviceA -eq $DeviceB -or $DeviceA.Contains('<') -or $DeviceB.Contains('<')) {
  throw 'Set two distinct physical-device serials.'
}
if ((adb -s $DeviceA get-state).Trim() -ne 'device') { throw 'Device A is not ready.' }
if ((adb -s $DeviceB get-state).Trim() -ne 'device') { throw 'Device B is not ready.' }

$DeviceMap = @(
  [pscustomobject]@{ Label = 'A'; Serial = $DeviceA }
  [pscustomobject]@{ Label = 'B'; Serial = $DeviceB }
)
foreach ($Entry in $DeviceMap) {
  $Label = $Entry.Label
  $Serial = $Entry.Serial
  @(
    "label=$Label"
    "serial=$Serial"
    "manufacturer=$(adb -s $Serial shell getprop ro.product.manufacturer)"
    "model=$(adb -s $Serial shell getprop ro.product.model)"
    "android=$(adb -s $Serial shell getprop ro.build.version.release)"
    "sdk=$(adb -s $Serial shell getprop ro.build.version.sdk)"
    "build=$(adb -s $Serial shell getprop ro.build.fingerprint)"
  ) | Set-Content "$Evidence\device_${Label}_metadata.txt"
}
```

Checklist:

- [ ] Both entries are physical phones in `device` state, not emulators.
- [ ] Both support BLE and meet the claimed minimum Android API.
- [ ] Both have at least 50% battery.
- [ ] Device labels A/B are physically attached to the phones.
- [ ] Model, Android version, SDK, fingerprint, and serial are saved locally.
- [ ] Wi-Fi state is recorded, but Wi-Fi is not treated as a PakConnect
  transport requirement.

## 2. Freeze and install the functional debug APK

If the already-built APK is absent, rebuild it from the accepted code tree.
Install only the exact verified artifact below. A size/hash mismatch is a hard
stop: it may be stale, built by another toolchain, or otherwise different from
the binary covered by this baseline. Record and promote a new verified artifact
before continuing instead of relabeling the mismatch.

```powershell
$DebugApk = Join-Path (Get-Location) 'build\app\outputs\flutter-apk\app-debug.apk'
$ExpectedDebugBytes = 205113616
$ExpectedDebugHash = '84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059'
if (-not (Test-Path $DebugApk)) {
  Invoke-BaselineFlutter build apk --debug --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Debug APK build failed.' }
}

$DebugItem = Get-Item $DebugApk
$DebugHash = (Get-FileHash $DebugApk -Algorithm SHA256).Hash
if ($DebugItem.Length -ne $ExpectedDebugBytes -or $DebugHash -ne $ExpectedDebugHash) {
  throw "APK does not match the verified baseline: bytes=$($DebugItem.Length), sha256=$DebugHash"
}
"debug_apk=$($DebugItem.FullName)" | Add-Content "$Evidence\session_metadata.txt"
"debug_apk_bytes=$($DebugItem.Length)" | Add-Content "$Evidence\session_metadata.txt"
"debug_apk_sha256=$DebugHash" | Add-Content "$Evidence\session_metadata.txt"
Copy-Item $DebugApk "$Evidence\pakconnect_${BaselineShort}_debug.apk"

adb -s $DeviceA uninstall $Package
adb -s $DeviceB uninstall $Package
adb -s $DeviceA install "$Evidence\pakconnect_${BaselineShort}_debug.apk"
if ($LASTEXITCODE -ne 0) { throw 'Install failed on Device A.' }
adb -s $DeviceB install "$Evidence\pakconnect_${BaselineShort}_debug.apk"
if ($LASTEXITCODE -ne 0) { throw 'Install failed on Device B.' }

adb -s $DeviceA shell dumpsys package $Package |
  Select-String 'versionName|versionCode|firstInstallTime|lastUpdateTime' |
  Set-Content "$Evidence\device_A_package.txt"
adb -s $DeviceB shell dumpsys package $Package |
  Select-String 'versionName|versionCode|firstInstallTime|lastUpdateTime' |
  Set-Content "$Evidence\device_B_package.txt"
```

The uninstall is intentional: the functional run must start with independent,
fresh identities and no inherited pairing/database state. Do not use `-g` on
install because the denied-then-granted permission path must be observed.

## 3. Start full log capture

Clear logcat only after installation. Then keep one PowerShell terminal per
device running for the full functional pass.

```powershell
adb -s $DeviceA logcat -c
adb -s $DeviceB logcat -c
Mark 'FUNCTIONAL LOG CAPTURE START'
```

Terminal A:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DeviceA = '<device-A-serial>'
$Evidence = '<absolute evidence directory from step 1>'
if ($DeviceA.Contains('<') -or $Evidence.Contains('<')) {
  throw 'Replace the Device A and evidence-directory placeholders.'
}
$Evidence = (Resolve-Path -LiteralPath $Evidence -ErrorAction Stop).Path
$SerialLine = Select-String -LiteralPath "$Evidence\device_A_metadata.txt" `
  -Pattern '^serial=' | Select-Object -First 1
if ($null -eq $SerialLine -or $SerialLine.Line.Substring(7) -ne $DeviceA) {
  throw 'Device A does not match the saved A/B mapping.'
}
$DeviceState = (adb -s $DeviceA get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $DeviceState -ne 'device') {
  throw "Device A is not ready: $DeviceState"
}
adb -s $DeviceA logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\functional_device_A.log"
```

Terminal B:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DeviceB = '<device-B-serial>'
$Evidence = '<absolute evidence directory from step 1>'
if ($DeviceB.Contains('<') -or $Evidence.Contains('<')) {
  throw 'Replace the Device B and evidence-directory placeholders.'
}
$Evidence = (Resolve-Path -LiteralPath $Evidence -ErrorAction Stop).Path
$SerialLine = Select-String -LiteralPath "$Evidence\device_B_metadata.txt" `
  -Pattern '^serial=' | Select-Object -First 1
if ($null -eq $SerialLine -or $SerialLine.Line.Substring(7) -ne $DeviceB) {
  throw 'Device B does not match the saved A/B mapping.'
}
$DeviceState = (adb -s $DeviceB get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $DeviceState -ne 'device') {
  throw "Device B is not ready: $DeviceState"
}
adb -s $DeviceB logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\functional_device_B.log"
```

Capture full logcat, not only the Flutter tag, so native BLE failures and
Android crashes are retained. Stop both captures with `Ctrl+C` only after the
functional scenarios finish.

## 4. Permissions and Bluetooth readiness

Launch both apps:

```powershell
Mark 'PERMISSIONS START'
adb -s $DeviceA shell am start -n "$Package/.MainActivity"
adb -s $DeviceB shell am start -n "$Package/.MainActivity"
```

On each phone, in this order:

1. On `Set Up PakConnect`, tap `Grant Permission`.
2. Deny the Nearby Devices/Bluetooth request the first time.
3. Confirm the app remains on a permission-required screen, offers
   `Open Settings`, and does not reach a false ready state or crash.
4. Tap `Open Settings`; grant Nearby Devices. Grant notifications when the OS
   exposes that separate Android 13+ prompt.
5. Return to PakConnect. Confirm it refreshes to `Setup complete` without an
   app restart; tap `Open Home`.
6. Turn Bluetooth off. Confirm the app reports Bluetooth unavailable/off and
   disables discovery instead of claiming ready.
7. Turn Bluetooth on. Confirm the app recovers to a usable Home/discovery
   state without clearing data.
8. Set the display names to `Device A <Stamp>` and `Device B <Stamp>` so the
   two independent identities are unambiguous.

Record:

```powershell
Mark 'PERMISSIONS RESULT: PASS|FAIL - <observation>'
```

Pass only if both phones complete the denied-then-granted and off-then-on
paths. A permission grant on one phone is not evidence for the other.

## 5. Directional discovery, collision, and Noise XX

Use the Home Bluetooth discovery floating action button. The overlay title is
`Discovered Devices`; its swap button changes the view to
`Connected Centrals`. The PakConnect GATT service UUID is
`effb4bc7-485c-4b47-8666-e1cca40d84e0`; the discovery logs must show that
filter/advertisement, not an unrelated advertiser.

### 5.1 A scans and explicitly dials B

1. On B, open discovery and switch to `Connected Centrals`; leave it visible.
2. On A, open `Discovered Devices`, start/retry scanning if necessary, and wait
   at most 60 seconds.
3. Confirm the selected tile is Device B's PakConnect identity and the logs
   show the PakConnect service UUID. Do not select an unrelated BLE advertiser.
4. Tap B once. Do not issue a second connect while the first is pending.
5. Confirm A shows the outbound/central connection and B lists A as an inbound
   connected central.
6. Open the chat. Confirm it reaches `Connected` plus `Basic Encryption`
   before sending anything.
7. Confirm the logs contain an XX start/completion and do not show encrypted
   application traffic before the handshake completes.

```powershell
Mark 'A_SCAN_B_ADVERTISE RESULT: PASS|FAIL - <latency and observation>'
```

### 5.2 B scans and explicitly dials A

Preserve app data, but force-stop and relaunch both apps to end the first link:

```powershell
adb -s $DeviceA shell am force-stop $Package
adb -s $DeviceB shell am force-stop $Package
adb -s $DeviceA shell am start -n "$Package/.MainActivity"
adb -s $DeviceB shell am start -n "$Package/.MainActivity"
```

Repeat the preceding flow with A in `Connected Centrals` and B selecting A in
`Discovered Devices`.

```powershell
Mark 'B_SCAN_A_ADVERTISE RESULT: PASS|FAIL - <latency and observation>'
```

### 5.3 Simultaneous dial collision

1. Force-stop and relaunch both apps again without clearing data.
2. Open `Discovered Devices` on both phones.
3. When each peer is visible, tap the opposite peer on both phones within one
   second.
4. Wait up to 60 seconds.
5. Confirm collision resolution leaves one usable peer session, not two
   competing handshakes, a reconnect loop, or duplicated chat delivery.
6. Leave the pair connected for 60 seconds and confirm no handshake storm.

```powershell
Mark 'SIMULTANEOUS_COLLISION RESULT: PASS|FAIL - <surviving role and observation>'
Select-String -Path "$Evidence\functional_device_*.log" `
  -Pattern 'Starting XX handshake|XX handshake complete|duplicate|collision|handshake storm' `
  -Context 1,1 | Set-Content "$Evidence\functional_handshake_collision_extract.txt"
```

Pass the Noise XX row only if the first-contact logs show XX and application
messages are unavailable until the session is established.

## 6. Direct text, ACK, Unicode, and duplicate check

Use these exact, unique payloads, replacing `<Stamp>` with the evidence stamp:

```text
PK-A2B-<Stamp>-01
PK-B2A-<Stamp>-01
PK-UNICODE-<Stamp>|اردو: سلام دنیا|中文: 你好世界|emoji: 🔐📡🧪|pipes: a||b|c
```

1. A sends `PK-A2B-<Stamp>-01`; B must receive it once and A must leave the
   queued/sending state only after ACK completion.
2. B sends `PK-B2A-<Stamp>-01`; A must receive it once with the same ACK rule.
3. A sends the Unicode/pipe payload. Compare the displayed value character for
   character on B; no replacement characters, lost pipes, or JSON fragments.
4. Wait 60 seconds and reopen both chats. None of the three messages may be
   duplicated.

```powershell
Mark 'DIRECT_AND_UNICODE RESULT: PASS|FAIL - <A2B latency, B2A latency, exactness>'
```

Any UI-only `sent` indication without receiver observation is not a pass.

## 7. Pair to MEDIUM and prove a Noise KK reconnect

1. Keep the established A/B chat open on both phones.
2. Tap the open-lock `Secure Chat` action on both phones.
3. Each `Secure Pairing` dialog displays a four-digit code. Enter A's code on
   B and B's code on A; tap `Verify` if the dialog has not auto-submitted.
4. Confirm both sides report pairing success and the chat/contact security
   state is `Paired` or `ECDH Encrypted` (MEDIUM+), not merely a locally renamed
   contact.
5. Force-stop both apps without uninstalling or clearing storage.
6. Relaunch, reconnect, and wait for ready state.
7. Send `PK-KK-<Stamp>-A2B` and `PK-KK-<Stamp>-B2A`; each must arrive once.
8. Confirm logs show `Starting KK handshake` and `KK handshake complete` on
   the reconnect. XX fallback is a failure unless a logged, investigated
   protocol reason justifies it.
9. Confirm no nonce-reuse, replay, authentication, or decrypt error appears.

```powershell
Mark 'NOISE_KK RESULT: PASS|FAIL - <security state and reconnect observation>'
Select-String -Path "$Evidence\functional_device_*.log" `
  -Pattern 'Starting KK handshake|KK handshake complete|nonce|replay|authentication failed|decrypt' `
  -Context 1,1 | Set-Content "$Evidence\functional_kk_extract.txt"
```

## 8. Large media, target MTU, byte equality, and route loss

Use a high-detail image that remains at least several hundred KiB after the
picker's resize/compression. A tiny icon does not exercise fragmentation.

### 8.1 Successful fragmented transfer

1. Confirm the A/B link is ready and Noise is established.
2. In A's chat, use the image action and select the test image.
3. Confirm A reports `Image queued for sending` and B shows `New media
   received` exactly once.
4. Open the received image on B and visually verify it is not truncated.
5. Save directory listings and SHA-256 values for app-private payloads:

```powershell
$MediaAOutput = adb -s $DeviceA shell run-as $Package sh -c `
  'ls -lt app_flutter/binary_payloads; sha256sum app_flutter/binary_payloads/*.bin' 2>&1
$MediaAExit = $LASTEXITCODE
($MediaAOutput | Out-String) | Set-Content "$Evidence\media_hashes_A.txt"

$MediaBOutput = adb -s $DeviceB shell run-as $Package sh -c `
  'ls -lt app_flutter/binary_payloads; sha256sum app_flutter/binary_payloads/*.bin' 2>&1
$MediaBExit = $LASTEXITCODE
($MediaBOutput | Out-String) | Set-Content "$Evidence\media_hashes_B.txt"

@(
  "device_A_exit=$MediaAExit"
  "device_B_exit=$MediaBExit"
) | Set-Content "$Evidence\media_hash_exit_codes.txt"

$HashPattern = '(?i)\b[a-f0-9]{64}\b'
$MediaAHashes = @([regex]::Matches(($MediaAOutput -join "`n"), $HashPattern).Value |
  ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)
$MediaBHashes = @([regex]::Matches(($MediaBOutput -join "`n"), $HashPattern).Value |
  ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)

if ($MediaAExit -ne 0 -or $MediaBExit -ne 0 -or
    $MediaAHashes.Count -eq 0 -or $MediaBHashes.Count -eq 0) {
  $MediaByteEqualityStatus = 'BLOCKED'
  Mark 'MEDIA_BYTE_EQUALITY RESULT: BLOCKED - run-as/sha256sum failed or produced no digest'
} else {
  $CommonMediaHashes = @($MediaAHashes | Where-Object { $MediaBHashes -contains $_ })
  if ($CommonMediaHashes.Count -eq 0) {
    $MediaByteEqualityStatus = 'FAIL'
    Mark 'MEDIA_BYTE_EQUALITY RESULT: FAIL - no common sender/receiver digest'
  } else {
    $MediaByteEqualityStatus = 'PASS'
    Mark "MEDIA_BYTE_EQUALITY RESULT: PASS - common sha256=$($CommonMediaHashes -join ',')"
  }
}
```

The new sender and receiver `.bin` files can have different filenames, but
they must have one common SHA-256 digest. That common digest is the byte-perfect
reassembly proof. The script records native exit codes and requires at least one
digest from each phone before comparison. If `run-as` or `sha256sum` is
unavailable, keep byte equality `BLOCKED` rather than substituting a visual
check.

6. Extract MTU/fragment evidence:

```powershell
Select-String -Path "$Evidence\functional_device_*.log" `
  -Pattern 'negotiated larger MTU|MTU detection successful|Updated server MTU|fragment|reassembled' `
  -Context 1,1 | Set-Content "$Evidence\functional_mtu_fragment_extract.txt"
Mark 'LARGE_MEDIA RESULT: PASS|FAIL|BLOCKED - <bytes, common hash, negotiated MTU>'
```

Pass only if the negotiated MTU belongs to the target A/B route, reassembly is
byte-equal, and there is no duplicate media event.

### 8.2 Route disappears during transfer

1. Select a second high-detail image on A.
2. As soon as the send begins, turn off Bluetooth on B before completion.
3. If the transfer completed before Bluetooth was disabled, mark the attempt
   invalid and repeat with a larger image; do not count it as a pass or fail.
4. Confirm A promptly reports failure/pending and retains a retryable item. It
   must not report final delivery.
5. Turn B's Bluetooth on, restore the exact A/B link, tap `Retry now`, and
   confirm B receives one complete copy.

```powershell
Mark 'ROUTE_LOSS_MID_SEND RESULT: PASS|FAIL - <failure latency and retry result>'
```

## 9. Offline queue, manual reconnect, and Android lifecycle

### 9.1 Offline queue and reconnect

1. In A's log, record the full platform peripheral UUID associated with B from
   `Found device advertising our service:` or `Scanning for reconnect target`.
   Call it `B-UUID-BEFORE`; it is a routing hint, not B's authenticated
   identity.
2. Turn Bluetooth off on B and wait until A's chat reports `Offline` or shows
   `Reconnect Now`.
3. A sends, in order:
   `PK-OFFLINE-<Stamp>-01`, `PK-OFFLINE-<Stamp>-02`, and
   `PK-OFFLINE-<Stamp>-03`.
4. Confirm all three remain pending on A and none claims delivery.
5. Wait 30 seconds, turn Bluetooth on on B, and bring B to the foreground.
6. Inspect A's log for the reconnect target and discovered UUIDs:

   ```powershell
   Select-String -Path "$Evidence\functional_device_A.log" `
     -Pattern 'Scanning for reconnect target|Ignoring nonmatching reconnect advertiser|Found device advertising our service'
   ```

   Record B's post-cycle UUID as `B-UUID-AFTER`.
7. If `B-UUID-AFTER` equals `B-UUID-BEFORE`, automatic reconnect may connect
   only to that exact UUID. If it differs, automatic reconnect must ignore
   other advertisers and safely time out; then tap `Reconnect Now` once and
   verify B through the paired chat identity. A first-advertiser fallback is a
   failure.
8. Within 60 seconds of a valid reconnect, B must receive all three in order and exactly once; A
   must transition them out of pending only after delivery/ACK.
9. Leave both apps open another 60 seconds to detect late duplicates.

```powershell
Mark 'OFFLINE_QUEUE RESULT: PASS|FAIL - <delivery order, latency, duplicates>'
Mark 'MANUAL_RECONNECT RESULT: PASS|FAIL - <target identity and latency>'
Mark 'RECONNECT_UUID RESULT: PASS|FAIL - <before UUID, after UUID, automatic timeout/connect behavior>'
```

The reconnect is a failure if it binds the chat to any identity other than the
paired Device B contact.

### 9.2 Foreground -> background -> resume flush

1. Turn B's Bluetooth off and wait for A to be offline.
2. A sends `PK-RESUME-<Stamp>-01` and confirms it is pending.
3. Press Home on A and leave PakConnect backgrounded for 30 seconds.
4. While A is backgrounded, turn Bluetooth on on B and foreground PakConnect
   on B; wait 10 seconds.
5. Return A to PakConnect. Wait up to 60 seconds for link readiness and queue
   flush.
6. B must receive the message once and A must clear pending only after ACK.
7. Inspect the log for the resume flush/skip decision.

```powershell
Select-String -Path "$Evidence\functional_device_*.log" `
  -Pattern 'resume|Resume flush|backlog|queue.*flush' -Context 1,1 |
  Set-Content "$Evidence\functional_resume_extract.txt"
Mark 'BACKGROUND_RESUME RESULT: PASS|FAIL|NOT RUN - <observation>'
```

If the message delivered before A resumed, record the stronger observed
background behavior but mark the specific resume-hook isolation `NOT RUN`; the
scenario did not prove that the resume hook caused delivery.

### 9.3 Process death and relaunch

1. Force-stop B: `adb -s $DeviceB shell am force-stop $Package`, and wait for A
   to show B as unavailable.
2. A sends `PK-RELAUNCH-<Stamp>-01`; it must remain pending and must not claim
   delivery.
3. Force-stop the sender A:
   `adb -s $DeviceA shell am force-stop $Package`. Keep B unavailable.
4. Relaunch A with
   `adb -s $DeviceA shell am start -n "$Package/.MainActivity"`.
5. Before restoring B, confirm the exact queue row is still present and
   pending on A. A missing row or a delivered state is a failure.
6. Relaunch B with
   `adb -s $DeviceB shell am start -n "$Package/.MainActivity"`, restore the
   exact paired A/B link, and wait up to 60 seconds.
7. Confirm B receives exactly one copy and A clears the pending row only after
   the delivery ACK. Leave both apps open another 60 seconds to catch a late
   duplicate.

```powershell
Mark 'PROCESS_DEATH_RELAUNCH RESULT: PASS|FAIL - <observation>'
```

This proves recovery after relaunch, not delivery while the process is dead.
Do not claim a native killed-process background service from this result.

### 9.4 Doze/battery-saver observation

Run this last among messaging scenarios so forced idle cannot contaminate
earlier timing. Run the guarded block below. While it pauses, send
`PK-DOZE-<Stamp>-01` from A and record whether it is delivered, queued, or
fails; then press Enter. Do not close this terminal while B is forced idle.

```powershell
$ForceIdleConfirmed = $false
try {
  $ForceIdleOutput = adb -s $DeviceB shell dumpsys deviceidle force-idle 2>&1
  $ForceIdleExit = $LASTEXITCODE
  ($ForceIdleOutput | Out-String) |
    Tee-Object "$Evidence\device_B_force_idle_start.txt"
  if ($ForceIdleExit -ne 0 -or
      ($ForceIdleOutput -join "`n") -notmatch '(?i)forced.+idle') {
    Mark 'DOZE RESULT: BLOCKED - force-idle was not confirmed'
    throw 'Device B did not confirm forced idle.'
  }

  $ForceIdleConfirmed = $true
  Mark 'DEVICE B FORCE-IDLE START'
  Read-Host 'Send PK-DOZE from A, record the observation, then press Enter to unforce B'
} finally {
  $UnforceOutput = adb -s $DeviceB shell dumpsys deviceidle unforce 2>&1
  $UnforceExit = $LASTEXITCODE
  ($UnforceOutput | Out-String) |
    Tee-Object "$Evidence\device_B_force_idle_unforce.txt"

  $IdleEndOutput = adb -s $DeviceB shell dumpsys deviceidle get deep 2>&1
  $IdleEndExit = $LASTEXITCODE
  ($IdleEndOutput | Out-String) |
    Tee-Object "$Evidence\device_B_force_idle_end.txt"

  if ($UnforceExit -ne 0 -or $IdleEndExit -ne 0 -or
      ($IdleEndOutput -join "`n") -notmatch '(?i)ACTIVE') {
    throw 'Failed to prove Device B returned to ACTIVE after force-idle.'
  }

  adb -s $DeviceB shell am start -n "$Package/.MainActivity"
  if ($LASTEXITCODE -ne 0) { throw 'Failed to relaunch Device B after unforce.' }
  Mark 'DEVICE B FORCE-IDLE END - ACTIVE CONFIRMED'
}
```

Confirm any pending message delivers once after resume. Record the observed
behavior; no current claim promises killed/dozing background delivery.

If the terminal is closed or the host loses power while B is forced idle, run
`adb -s <device-B-serial> shell dumpsys deviceidle unforce` from a new terminal
before any further scenario, then save `dumpsys deviceidle get deep` showing
`ACTIVE`. The interrupted row remains `FAIL` or `BLOCKED`; do not retry over it.

## 10. Concurrent versus strict-TDM profile comparison

Use profile mode for both sides and both modes. Build once per mode, preserve
the APK, then use the same prebuilt APK on A and B. This avoids concurrent
Gradle builds producing different binaries.

```powershell
Invoke-BaselineFlutter build apk --profile --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Concurrent profile build failed.' }
$ConcurrentApk = "$Evidence\pakconnect_${BaselineShort}_concurrent_profile.apk"
Copy-Item 'build\app\outputs\flutter-apk\app-profile.apk' $ConcurrentApk
$ConcurrentHash = (Get-FileHash $ConcurrentApk -Algorithm SHA256).Hash
@(
  'mode=concurrent'
  "apk=$ConcurrentApk"
  "sha256=$ConcurrentHash"
) | Set-Content "$Evidence\concurrent_profile_artifact.txt"

Invoke-BaselineFlutter build apk --profile --no-pub `
  --dart-define=PAKCONNECT_STRICT_TDM=true
if ($LASTEXITCODE -ne 0) { throw 'Strict-TDM profile build failed.' }
$StrictApk = "$Evidence\pakconnect_${BaselineShort}_strict_tdm_profile.apk"
Copy-Item 'build\app\outputs\flutter-apk\app-profile.apk' $StrictApk
$StrictHash = (Get-FileHash $StrictApk -Algorithm SHA256).Hash
@(
  'mode=strict_tdm'
  "apk=$StrictApk"
  "sha256=$StrictHash"
) | Set-Content "$Evidence\strict_tdm_profile_artifact.txt"
```

Do 20 normal attempts and then 20 strict-TDM attempts. Use the same phone
positions, reset method, 60-second timeout, and message directions. Each
attempt passes only when discovery, connection, handshake, A-to-B message, and
B-to-A message all succeed. Allowed failure labels are:

- `handshake failed`
- `connect failed`
- `peer never discovered`
- `dropped after connect`

For each mode:

1. Clear logcat and start one full-log capture terminal per phone. Keep each
   capture running across all 20 attempts for that mode.

Main terminal before concurrent attempts:

```powershell
adb -s $DeviceA logcat -c
adb -s $DeviceB logcat -c
Mark 'CONCURRENT PROFILE COMPARISON START'
```

Concurrent log terminal A:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DeviceA = '<device-A-serial>'
$Evidence = '<absolute evidence directory from step 1>'
if ($DeviceA.Contains('<') -or $Evidence.Contains('<')) {
  throw 'Replace the Device A and evidence-directory placeholders.'
}
$Evidence = (Resolve-Path -LiteralPath $Evidence -ErrorAction Stop).Path
$SerialLine = Select-String -LiteralPath "$Evidence\device_A_metadata.txt" `
  -Pattern '^serial=' | Select-Object -First 1
if ($null -eq $SerialLine -or $SerialLine.Line.Substring(7) -ne $DeviceA) {
  throw 'Device A does not match the saved A/B mapping.'
}
$DeviceState = (adb -s $DeviceA get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $DeviceState -ne 'device') {
  throw "Device A is not ready: $DeviceState"
}
adb -s $DeviceA logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\concurrent_device_A.log"
```

Concurrent log terminal B:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DeviceB = '<device-B-serial>'
$Evidence = '<absolute evidence directory from step 1>'
if ($DeviceB.Contains('<') -or $Evidence.Contains('<')) {
  throw 'Replace the Device B and evidence-directory placeholders.'
}
$Evidence = (Resolve-Path -LiteralPath $Evidence -ErrorAction Stop).Path
$SerialLine = Select-String -LiteralPath "$Evidence\device_B_metadata.txt" `
  -Pattern '^serial=' | Select-Object -First 1
if ($null -eq $SerialLine -or $SerialLine.Line.Substring(7) -ne $DeviceB) {
  throw 'Device B does not match the saved A/B mapping.'
}
$DeviceState = (adb -s $DeviceB get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $DeviceState -ne 'device') {
  throw "Device B is not ready: $DeviceState"
}
adb -s $DeviceB logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\concurrent_device_B.log"
```

After concurrent attempt 20 has ended and its summary has appeared, stop those
two log terminals. Clear logcat again, mark `STRICT TDM PROFILE COMPARISON
START`, and repeat the same two commands with filenames
`strict_tdm_device_A.log` and `strict_tdm_device_B.log`.

2. In each of two separate interactive terminals, fill the mode, label, serial,
   and evidence directory. The script derives the only accepted APK for that
   mode, verifies its saved SHA-256, and records the exact device/artifact
   pairing. Run it once for A and once for B:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Mode = '<concurrent-or-strict_tdm>'
$Label = '<A-or-B>'
$Device = '<matching-device-serial>'
$Evidence = '<absolute evidence directory from step 1>'

if ($Mode -notin @('concurrent', 'strict_tdm') -or
    $Label -notin @('A', 'B') -or $Device.Contains('<') -or
    $Evidence.Contains('<')) {
  throw 'Replace every profile-launch placeholder with the saved run values.'
}
$Evidence = (Resolve-Path -LiteralPath $Evidence -ErrorAction Stop).Path
$BaselineShortLine = Select-String -LiteralPath `
  "$Evidence\session_metadata.txt" -Pattern '^baseline_short=' |
  Select-Object -First 1
if ($null -eq $BaselineShortLine) {
  throw 'Missing baseline short commit in session metadata.'
}
$BaselineShort = $BaselineShortLine.Line.Substring(15)
if ($BaselineShort -notmatch '^[0-9a-f]{7}$') {
  throw "Invalid baseline short commit in session metadata: $BaselineShort"
}

if ($Mode -eq 'concurrent') {
  $ProfileApkName = "pakconnect_${BaselineShort}_concurrent_profile.apk"
  $ArtifactRecordName = 'concurrent_profile_artifact.txt'
} else {
  $ProfileApkName = "pakconnect_${BaselineShort}_strict_tdm_profile.apk"
  $ArtifactRecordName = 'strict_tdm_profile_artifact.txt'
}
$ProfileApk = (Resolve-Path -LiteralPath (Join-Path $Evidence $ProfileApkName) `
  -ErrorAction Stop).Path
$ArtifactRecord = Join-Path $Evidence $ArtifactRecordName
$RecordedPathLine = Select-String -LiteralPath $ArtifactRecord `
  -Pattern '^apk=' | Select-Object -First 1
$RecordedHashLine = Select-String -LiteralPath $ArtifactRecord `
  -Pattern '^sha256=' | Select-Object -First 1
if ($null -eq $RecordedPathLine -or $null -eq $RecordedHashLine) {
  throw "Missing artifact identity fields for mode $Mode."
}
$RecordedPath = (Resolve-Path -LiteralPath $RecordedPathLine.Line.Substring(4) `
  -ErrorAction Stop).Path
$RecordedHash = $RecordedHashLine.Line.Substring(7)
$ActualHash = (Get-FileHash -LiteralPath $ProfileApk -Algorithm SHA256).Hash
if ($RecordedPath -ne $ProfileApk -or $RecordedHash -ne $ActualHash) {
  throw "Profile artifact identity mismatch for mode $Mode."
}

$SerialLine = Select-String -LiteralPath "$Evidence\device_${Label}_metadata.txt" `
  -Pattern '^serial=' | Select-Object -First 1
if ($null -eq $SerialLine -or $SerialLine.Line.Substring(7) -ne $Device) {
  throw "Device $Label does not match the saved A/B mapping."
}
$DeviceState = (adb -s $Device get-state 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $DeviceState -ne 'device') {
  throw "Device $Label is not ready: $DeviceState"
}

@(
  "started=$((Get-Date).ToString('o'))"
  "mode=$Mode"
  "label=$Label"
  "serial=$Device"
  "apk=$ProfileApk"
  "sha256=$ActualHash"
) | Add-Content "$Evidence\${Mode}_device_${Label}_launch.txt"

& puro --no-progress -e ci-3-44-4 flutter run --no-pub -d $Device `
  --profile --use-application-binary=$ProfileApk
$ProfileRunExit = $LASTEXITCODE
@(
  "ended=$((Get-Date).ToString('o'))"
  "exit=$ProfileRunExit"
) | Add-Content "$Evidence\${Mode}_device_${Label}_launch.txt"
if ($ProfileRunExit -ne 0) { throw "Profile run failed on Device $Label." }
```

3. Wait up to 60 seconds for ready state.
4. Send `PK-<MODE>-<ATTEMPT>-A2B` and
   `PK-<MODE>-<ATTEMPT>-B2A`.
5. Record the result and timings.
6. End both `flutter run` sessions with `q`; wait several seconds so
   `BLE_EXPERIMENT_SUMMARY` is emitted. Keep the mode's logcat captures running
   until attempt 20.
7. Relaunch both preserved binaries for the next attempt. After attempt 20,
   wait for its summaries and then stop the two logcat terminals with
   `Ctrl+C`. Do not use hot reload and do not change the reset method between
   modes.

Attempt record:

| Attempt | Concurrent result | Concurrent first-peer / handshake ms | Strict-TDM result | Strict first-peer / handshake ms |
|---:|---|---|---|---|
| 01 |  |  |  |  |
| 02 |  |  |  |  |
| 03 |  |  |  |  |
| 04 |  |  |  |  |
| 05 |  |  |  |  |
| 06 |  |  |  |  |
| 07 |  |  |  |  |
| 08 |  |  |  |  |
| 09 |  |  |  |  |
| 10 |  |  |  |  |
| 11 |  |  |  |  |
| 12 |  |  |  |  |
| 13 |  |  |  |  |
| 14 |  |  |  |  |
| 15 |  |  |  |  |
| 16 |  |  |  |  |
| 17 |  |  |  |  |
| 18 |  |  |  |  |
| 19 |  |  |  |  |
| 20 |  |  |  |  |

Extract and verify mode labels:

```powershell
Select-String -Path "$Evidence\concurrent_*.log" -Pattern 'BLE_EXPERIMENT_SUMMARY|sessionMode' |
  Set-Content "$Evidence\concurrent_summaries.txt"
Select-String -Path "$Evidence\strict_tdm_*.log" -Pattern 'BLE_EXPERIMENT_SUMMARY|sessionMode' |
  Set-Content "$Evidence\strict_tdm_summaries.txt"
```

- [ ] Concurrent summaries say `sessionMode":"concurrent"`.
- [ ] Strict summaries say `sessionMode":"strict_tdm"`.
- [ ] Strict-TDM connect + handshake success is at least 18/20.
- [ ] Strict TDM has at least 50% fewer handshake/drop failures than concurrent.
  If concurrent has zero such failures, this improvement criterion is
  mathematically unavailable; record that fact instead of inventing a pass.
- [ ] Strict median time to first peer is no worse than 2x concurrent.
- [ ] The reset method and physical layout were identical.

Run one extra strict-TDM fault-injection attempt, excluded from the 20 trials:

1. Start a fresh strict-TDM connect.
2. Turn B's Bluetooth off while A is connecting, before handshake readiness.
3. Wait for the attempt to fail, turn B on, and start a new attempt.
4. Confirm the new attempt reaches MTU, notify, handshake, and ready state; an
   old attempt must not release or mutate the new connect lock.
5. Save lines matching `attempt#`, `stale`, `mtu-ready`,
   `notify-subscribed`, `handshake-started`, and `handshake-ready`.

If Android emits no delayed callback, record `NOT RUN` for direct stale-event
rejection while retaining the successful interrupted-attempt recovery. Do not
claim an event was rejected when no stale event was observed.

The strict-TDM row may pass its two-device bring-up criteria. The overall
strict-TDM/native-engine decision remains `BLOCKED` until the three-device
relay gate is measured.

## 11. Android SQLCipher device proof

Run this after messaging because the integration-test install may replace or
clear normal app state:

```powershell
Invoke-BaselineFlutter test --no-pub `
  integration_test/security/database_encryption_device_test.dart `
  -d $DeviceA 2>&1 | Tee-Object "$Evidence\sqlcipher_device_A.txt"
if ($LASTEXITCODE -ne 0) { throw 'Android SQLCipher device proof failed.' }
```

The test writes a marker, verifies the file lacks the plaintext
`SQLite format 3` header, proves a no-password query fails, and asks the app's
database helper to report its encryption state. It does not independently
reopen the file with the secure-storage credential and read the marker back.
Record the exact device, commit, output, and exit code.

Step 7 already supplies the normal-app persistence check: after pairing and
writing chat/contact state, both apps are force-stopped and relaunched without
clearing data. Record whether the paired identity and messages remain readable
there. Together with this integration test, that covers encrypted-file
behavior and secure-credential persistence without adding another destructive
reinstall.

There is no safe baseline hook for injecting secure-storage failure. Do not
delete production key material ad hoc. Record that subcase `BLOCKED: controlled
secure-storage failure injection unavailable` unless a reviewed test hook is
added on a new baseline.

## 12. Log/privacy review and stop conditions

After stopping log capture, run:

```powershell
$ExpectedLogNames = @(
  'functional_device_A.log', 'functional_device_B.log',
  'concurrent_device_A.log', 'concurrent_device_B.log',
  'strict_tdm_device_A.log', 'strict_tdm_device_B.log'
)
$LogGateProblems = @()
foreach ($LogName in $ExpectedLogNames) {
  $LogPath = Join-Path $Evidence $LogName
  if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    $LogGateProblems += "missing=$LogName"
  } elseif ((Get-Item -LiteralPath $LogPath).Length -eq 0) {
    $LogGateProblems += "empty=$LogName"
  }
}

if ($LogGateProblems.Count -gt 0) {
  $PrivacyScanComplete = $false
  $LogGateProblems | Set-Content "$Evidence\privacy_scan_blockers.txt"
  Mark "LOG_PRIVACY RESULT: BLOCKED - $($LogGateProblems -join ', ')"
} else {
  $PrivacyScanComplete = $true
  $Logs = $ExpectedLogNames | ForEach-Object {
    Get-Item -LiteralPath (Join-Path $Evidence $_)
  }

  $PayloadHits = @(Select-String -Path $Logs.FullName -SimpleMatch -Pattern 'PK-')
  $PayloadHits | Out-File "$Evidence\privacy_payload_hits.txt"

  $ReviewHits = @(Select-String -Path $Logs.FullName `
    -Pattern 'private[_ ]?key|passphrase|password|SQLCipher.{0,20}key|encryption.{0,20}key|FATAL EXCEPTION|nonce|replay|authentication failed|decrypt.*failed|status 133' `
    -Context 1,1)
  $ReviewHits | Out-File "$Evidence\privacy_and_failure_review.txt"
}
```

The privacy row cannot pass unless `$PrivacyScanComplete` is true. Review every
hit in context. The payload-hit file must be empty for plaintext content; the
broad `PK-` prefix includes functional and both profile-mode payloads. A label
such as `private key unavailable` may be harmless; actual key bytes,
passphrases, passwords, SQLCipher credentials, or plaintext payload previews
are a failure.

Stop the run and preserve evidence immediately if any of these occurs:

- baseline/HEAD build inputs differ;
- a device becomes `unauthorized`, `offline`, or changes identity mapping;
- the two phones are not running the same artifact/mode for a comparison;
- `sessionMode` disagrees with the intended mode;
- crash loop, native `FATAL EXCEPTION`, database-open failure, or plaintext
  mobile SQLite fallback;
- nonce reuse, replay acceptance, Noise authentication/decrypt failure;
- wrong-recipient delivery, duplicate delivery, false delivered/ACK state, or
  a pending item is silently dropped;
- key material, passphrase, SQLCipher credential, or plaintext message content
  appears in logs;
- the reset method or physical layout changes mid-comparison.

Do not keep retrying a failed scenario until it happens to pass. Save the first
failure, assign `FAIL`, and create a bounded reproduction before any fix.

## 13. Final result record

Save this table as `$Evidence\results.md`, then copy only the redacted outcome
and evidence-session name into [DEVICE_VALIDATION_STATUS.md](DEVICE_VALIDATION_STATUS.md).

| Scenario | Status | Mode/build | Start/end | Evidence | Observation |
|---|---|---|---|---|---|
| Permissions and Bluetooth readiness |  | debug |  |  |  |
| A scans, B advertises |  | debug |  |  |  |
| B scans, A advertises |  | debug |  |  |  |
| Simultaneous discovery/collision |  | debug |  |  |  |
| Strict-TDM bring-up |  | profile strict |  |  |  |
| Noise XX first contact |  | debug |  |  |  |
| Noise KK paired reconnect |  | debug |  |  |  |
| A sends text to B |  | debug |  |  |  |
| B sends text to A |  | debug |  |  |  |
| Unicode and pipe-heavy text |  | debug |  |  |  |
| Large/binary media |  | debug |  |  |  |
| Offline queue then reconnect |  | debug |  |  |  |
| Foreground -> background -> resume |  | debug |  |  | No killed/dozing-delivery claim |
| Route disappears mid-send |  | debug |  |  |  |
| Manual reconnect |  | debug |  |  |  |
| Bluetooth off/on reconnect target |  | debug |  |  | Record before/after UUID and exact-target auto-connect or safe-timeout behavior |
| Multi-link inventory/routing | BLOCKED | needs 3 devices |  |  | Third device required |
| Relay A -> B -> C | BLOCKED | needs 3 devices |  |  | Third device required |
| Log/privacy inspection |  | all modes |  |  |  |
| SQLCipher at-rest proof |  | integration/device |  |  |  |
| Sender process death -> relaunch |  | debug |  |  |  |
| Doze/battery-saver observation |  | debug |  |  |  |

Closeout checks:

```powershell
$ResultsPath = Join-Path $Evidence 'results.md'
if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf) -or
    (Get-Item -LiteralPath $ResultsPath).Length -eq 0) {
  throw 'Save the completed final result table as results.md before closeout.'
}

$ExpectedResultScenarios = @(
  'Permissions and Bluetooth readiness'
  'A scans, B advertises'
  'B scans, A advertises'
  'Simultaneous discovery/collision'
  'Strict-TDM bring-up'
  'Noise XX first contact'
  'Noise KK paired reconnect'
  'A sends text to B'
  'B sends text to A'
  'Unicode and pipe-heavy text'
  'Large/binary media'
  'Offline queue then reconnect'
  'Foreground -> background -> resume'
  'Route disappears mid-send'
  'Manual reconnect'
  'Bluetooth off/on reconnect target'
  'Multi-link inventory/routing'
  'Relay A -> B -> C'
  'Log/privacy inspection'
  'SQLCipher at-rest proof'
  'Sender process death -> relaunch'
  'Doze/battery-saver observation'
)
$AllowedResultStatuses = @('PASS', 'FAIL', 'BLOCKED', 'NOT RUN')
$ResultRows = @{}
foreach ($Line in Get-Content -LiteralPath $ResultsPath) {
  if ($Line -notmatch '^\|\s*(?<Scenario>[^|]+?)\s*\|\s*(?<Status>[^|]*?)\s*\|\s*(?<Mode>[^|]*?)\s*\|\s*(?<StartEnd>[^|]*?)\s*\|\s*(?<Evidence>[^|]*?)\s*\|\s*(?<Observation>[^|]*?)\s*\|\s*$') {
    continue
  }
  $Scenario = $Matches['Scenario'].Trim()
  if ($Scenario -notin $ExpectedResultScenarios) { continue }
  if ($ResultRows.ContainsKey($Scenario)) {
    throw "Duplicate final-result row: $Scenario"
  }

  $Status = $Matches['Status'].Trim()
  $Mode = $Matches['Mode'].Trim()
  $StartEnd = $Matches['StartEnd'].Trim()
  $EvidenceCell = $Matches['Evidence'].Trim()
  $Observation = $Matches['Observation'].Trim()
  $EditableCells = @(
    $Status, $Mode, $StartEnd, $EvidenceCell, $Observation
  ) -join ' | '
  if ($EditableCells -match '<[^>]+>') {
    throw "Unreplaced placeholder in final-result row: $Scenario"
  }
  if ($Status -notin $AllowedResultStatuses) {
    throw "Missing or invalid status for final-result row: $Scenario"
  }
  if ($Status -in @('PASS', 'FAIL') -and
      ([string]::IsNullOrWhiteSpace($Mode) -or
       [string]::IsNullOrWhiteSpace($StartEnd) -or
       [string]::IsNullOrWhiteSpace($EvidenceCell))) {
    throw "PASS/FAIL row requires mode, start/end and evidence: $Scenario"
  }
  if ($Status -in @('BLOCKED', 'NOT RUN') -and
      [string]::IsNullOrWhiteSpace($Observation)) {
    throw "BLOCKED/NOT RUN row requires a reason: $Scenario"
  }
  $ResultRows[$Scenario] = $Status
}
$MissingResultRows = @(
  $ExpectedResultScenarios | Where-Object { -not $ResultRows.ContainsKey($_) }
)
if ($MissingResultRows.Count -gt 0) {
  throw "Incomplete final-result table; missing completed rows: $($MissingResultRows -join ', ')"
}

"ended=$((Get-Date).ToString('o'))" | Add-Content "$Evidence\session_metadata.txt"
$AdbEndOutput = adb devices -l 2>&1
$AdbEndExit = $LASTEXITCODE
($AdbEndOutput | Out-String) | Set-Content "$Evidence\adb_devices_end.txt"
if ($AdbEndExit -ne 0) { throw 'Final adb device capture failed.' }

$GeneratedRegistrantPaths = @(
  'linux/flutter/generated_plugin_registrant.cc'
  'linux/flutter/generated_plugin_registrant.h'
  'linux/flutter/generated_plugins.cmake'
  'macos/Flutter/GeneratedPluginRegistrant.swift'
  'windows/flutter/generated_plugin_registrant.cc'
  'windows/flutter/generated_plugin_registrant.h'
  'windows/flutter/generated_plugins.cmake'
)
$GeneratedStatus = @(git status --porcelain -- $GeneratedRegistrantPaths)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect generated registrants.' }
if ($GeneratedStatus.Count -gt 0) {
  git diff -- $GeneratedRegistrantPaths |
    Set-Content "$Evidence\generated_registrant_diff.txt"
  if ($LASTEXITCODE -ne 0) { throw 'Could not save generated-registrant diff.' }
  git restore -- $GeneratedRegistrantPaths
  if ($LASTEXITCODE -ne 0) { throw 'Could not restore generated registrants.' }
}

git diff --exit-code "${Baseline}..HEAD" -- $BuildInputs
if ($LASTEXITCODE -ne 0) { throw 'Build inputs drifted during the run.' }

git diff --exit-code $Baseline -- $BuildInputs
if ($LASTEXITCODE -ne 0) { throw 'Tracked build-input edits appeared during the run.' }
$BuildInputStatus = @(git status --porcelain -- $BuildInputs)
if ($LASTEXITCODE -ne 0 -or $BuildInputStatus.Count -gt 0) {
  throw "Build-input worktree drifted during the run:`n$($BuildInputStatus -join "`n")"
}

$FinalStatus = @(git status --porcelain --untracked-files=all)
Set-Content "$Evidence\git_status_end.txt" -Value ($FinalStatus -join "`n")
if ($LASTEXITCODE -ne 0 -or $FinalStatus.Count -gt 0) {
  throw "Worktree drift remains after the run:`n$($FinalStatus -join "`n")"
}

$ManifestPath = Join-Path $Evidence 'evidence_hashes.txt'
$ManifestLines = Get-ChildItem -LiteralPath $Evidence -File -Recurse |
  Where-Object FullName -ne $ManifestPath |
  Sort-Object FullName |
  ForEach-Object {
    $Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    $RelativePath = [IO.Path]::GetRelativePath($Evidence, $_.FullName)
    "$Hash  $RelativePath"
  }
$ManifestLines | Set-Content -LiteralPath $ManifestPath
```

The run starts from a fully clean worktree, so restoring only the listed
generated registrants is safe. Their pre-restore diff is retained. The final
full-worktree gate must be empty, and the evidence manifest is created last so
it includes the completed result table, end timestamp, final device list, and
final Git status while excluding only itself.

The recommended next action after this two-device pass is to fix any saved
`FAIL` before expanding scope. If all executable two-device rows pass, add one
third Android device only for multi-link inventory/routing and the controlled
A -> B -> C relay/TDM decision gate.
