# Two-Android-device execution checklist

This is the executable run sheet for the live matrix in
[DEVICE_VALIDATION_STATUS.md](DEVICE_VALIDATION_STATUS.md). Run it from the
repository root in Windows PowerShell. Use only `PASS`, `FAIL`, `BLOCKED`, and
`NOT RUN` in the final record.

The fixed code/test/tooling baseline is:

- commit: `9cccd014c7bb93d0a3aab26aaf7674c3a5192dd3`
- short commit: `9cccd01`
- branch used to prepare the baseline: `codex/reconcile-pakconnect`
- local verification toolchain: Flutter 3.41.5 / Dart 3.11.3
- analyzer: clean on 2026-07-13
- full desktop suite: 5,539 passed, 0 failed, 5m20s
- full-suite log: 9,515,985 bytes; SHA-256
  `152F6CABA2083675728A7F0A1CDEF6CEA20AA7BDECFE96BDD4C912AE2BAE53FE`
- verified debug APK: `build/app/outputs/flutter-apk/app-debug.apk`
- verified debug APK size: `203988403` bytes
- verified debug APK SHA-256:
  `3A0B32EBBB8255C539C62BDD6ACA077108BC5EEF0D431AAEBA5232FB64E28B50`

A documentation-only descendant is acceptable. Any changed build input is a
hard stop until the new code has its own baseline and desktop verification.
The previous `a5c2b08` baseline and `fcb3013` candidate remain historical
provenance only. Flutter 3.44 analysis required an equivalent null-aware syntax
cleanup after `fcb3013`; neither older commit is valid for this run.

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
is run.

## 0. Baseline and workspace gate

Open a PowerShell terminal at the repository root and run:

```powershell
$Baseline = '9cccd01'
$ExpectedBaseline = '9cccd014c7bb93d0a3aab26aaf7674c3a5192dd3'
$Package = 'com.pakconnect.app'

$ResolvedBaseline = (git rev-parse $Baseline).Trim()
if ($LASTEXITCODE -ne 0 -or $ResolvedBaseline -ne $ExpectedBaseline) {
  throw "Wrong or missing baseline: $ResolvedBaseline"
}

git merge-base --is-ancestor $Baseline HEAD
if ($LASTEXITCODE -ne 0) {
  throw 'The device baseline is not an ancestor of HEAD.'
}

$BuildInputs = @(
  'lib', 'test', 'integration_test', 'android', 'ios', 'assets',
  'pubspec.yaml', 'pubspec.lock'
)
git diff --exit-code "${Baseline}..HEAD" -- $BuildInputs
if ($LASTEXITCODE -ne 0) {
  throw "Build inputs differ from $Baseline. Create and verify a new baseline."
}

git status --short
git log -2 --oneline --decorate
flutter --version
flutter doctor -v
adb --version
```

Checklist:

- [ ] Baseline resolves to the expected full commit.
- [ ] Baseline is an ancestor of `HEAD`.
- [ ] The build-input diff command exits zero with no output.
- [ ] The worktree is clean before device evidence begins.
- [ ] Flutter reports the expected toolchain; any drift is saved in evidence.
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
"head=$((git rev-parse HEAD).Trim())" | Add-Content "$Evidence\session_metadata.txt"
"branch=$((git branch --show-current).Trim())" | Add-Content "$Evidence\session_metadata.txt"
"started=$((Get-Date).ToString('o'))" | Add-Content "$Evidence\session_metadata.txt"
flutter --version 2>&1 | Tee-Object "$Evidence\flutter_version.txt"
flutter doctor -v 2>&1 | Tee-Object "$Evidence\flutter_doctor.txt"
adb devices -l 2>&1 | Tee-Object "$Evidence\adb_devices.txt"

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

If the already-built APK exists, hash it. If it is absent, rebuild it from the
accepted code tree. A rebuild may have a different byte hash; that is allowed
only when the commit/build-input gate above passed, and the new hash must be
recorded instead of being mislabeled as the previously verified binary.

```powershell
$DebugApk = Join-Path (Get-Location) 'build\app\outputs\flutter-apk\app-debug.apk'
if (-not (Test-Path $DebugApk)) {
  flutter build apk --debug --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Debug APK build failed.' }
}

$DebugItem = Get-Item $DebugApk
$DebugHash = (Get-FileHash $DebugApk -Algorithm SHA256).Hash
"debug_apk=$($DebugItem.FullName)" | Add-Content "$Evidence\session_metadata.txt"
"debug_apk_bytes=$($DebugItem.Length)" | Add-Content "$Evidence\session_metadata.txt"
"debug_apk_sha256=$DebugHash" | Add-Content "$Evidence\session_metadata.txt"
Copy-Item $DebugApk "$Evidence\pakconnect_${Baseline}_debug.apk"

if ($DebugHash -ne '3A0B32EBBB8255C539C62BDD6ACA077108BC5EEF0D431AAEBA5232FB64E28B50') {
  Write-Warning 'This is a rebuilt baseline APK, not the previously hashed APK; the new hash is recorded.'
}

adb -s $DeviceA uninstall $Package
adb -s $DeviceB uninstall $Package
adb -s $DeviceA install "$Evidence\pakconnect_${Baseline}_debug.apk"
if ($LASTEXITCODE -ne 0) { throw 'Install failed on Device A.' }
adb -s $DeviceB install "$Evidence\pakconnect_${Baseline}_debug.apk"
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
$DeviceA = '<device-A-serial>'
$Evidence = '<absolute evidence directory from step 1>'
adb -s $DeviceA logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\functional_device_A.log"
```

Terminal B:

```powershell
$DeviceB = '<device-B-serial>'
$Evidence = '<absolute evidence directory from step 1>'
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
adb -s $DeviceA shell run-as $Package sh -c 'ls -lt app_flutter/binary_payloads; sha256sum app_flutter/binary_payloads/*.bin' |
  Set-Content "$Evidence\media_hashes_A.txt"
adb -s $DeviceB shell run-as $Package sh -c 'ls -lt app_flutter/binary_payloads; sha256sum app_flutter/binary_payloads/*.bin' |
  Set-Content "$Evidence\media_hashes_B.txt"
```

The new sender and receiver `.bin` files can have different filenames, but
they must have one common SHA-256 digest. That common digest is the byte-perfect
reassembly proof. If `run-as` or `sha256sum` is unavailable, record `BLOCKED`
for byte equality rather than substituting a visual check.

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

1. Turn Bluetooth off on B and wait until A's chat reports `Offline` or shows
   `Reconnect Now`.
2. A sends, in order:
   `PK-OFFLINE-<Stamp>-01`, `PK-OFFLINE-<Stamp>-02`, and
   `PK-OFFLINE-<Stamp>-03`.
3. Confirm all three remain pending on A and none claims delivery.
4. Wait 30 seconds, turn Bluetooth on on B, and bring B to the foreground.
5. On A tap `Reconnect Now` once if automatic reconnect has not started.
6. Within 60 seconds, B must receive all three in order and exactly once; A
   must transition them out of pending only after delivery/ACK.
7. Leave both apps open another 60 seconds to detect late duplicates.

```powershell
Mark 'OFFLINE_QUEUE RESULT: PASS|FAIL - <delivery order, latency, duplicates>'
Mark 'MANUAL_RECONNECT RESULT: PASS|FAIL - <target identity and latency>'
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

1. Force-stop B: `adb -s $DeviceB shell am force-stop $Package`.
2. A sends `PK-RELAUNCH-<Stamp>-01`; it must remain pending.
3. Relaunch B with
   `adb -s $DeviceB shell am start -n "$Package/.MainActivity"`.
4. Confirm the paired identity/data survives and the message arrives once
   after reconnect.

```powershell
Mark 'PROCESS_DEATH_RELAUNCH RESULT: PASS|FAIL - <observation>'
```

This proves recovery after relaunch, not delivery while the process is dead.
Do not claim a native killed-process background service from this result.

### 9.4 Doze/battery-saver observation

Run this last among messaging scenarios so forced idle cannot contaminate
earlier timing:

```powershell
adb -s $DeviceB shell dumpsys deviceidle force-idle 2>&1 |
  Tee-Object "$Evidence\device_B_force_idle_start.txt"
Mark 'DEVICE B FORCE-IDLE START'
```

Send `PK-DOZE-<Stamp>-01` from A and record whether it is delivered, queued, or
fails. If the command output does not confirm forced idle, mark the forced-idle
subcase `BLOCKED`; ordinary screen-off behavior is not a substitute. Then
always clean up and resume B:

```powershell
adb -s $DeviceB shell dumpsys deviceidle unforce 2>&1 |
  Tee-Object "$Evidence\device_B_force_idle_end.txt"
adb -s $DeviceB shell am start -n "$Package/.MainActivity"
Mark 'DEVICE B FORCE-IDLE END'
```

Confirm any pending message delivers once after resume. Record the observed
behavior; no current claim promises killed/dozing background delivery.

## 10. Concurrent versus strict-TDM profile comparison

Use profile mode for both sides and both modes. Build once per mode, preserve
the APK, then use the same prebuilt APK on A and B. This avoids concurrent
Gradle builds producing different binaries.

```powershell
flutter build apk --profile --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Concurrent profile build failed.' }
$ConcurrentApk = "$Evidence\pakconnect_${Baseline}_concurrent_profile.apk"
Copy-Item 'build\app\outputs\flutter-apk\app-profile.apk' $ConcurrentApk
Get-FileHash $ConcurrentApk -Algorithm SHA256 |
  Format-List | Out-File "$Evidence\concurrent_profile_hash.txt"

flutter build apk --profile --no-pub --dart-define=PAKCONNECT_STRICT_TDM=true
if ($LASTEXITCODE -ne 0) { throw 'Strict-TDM profile build failed.' }
$StrictApk = "$Evidence\pakconnect_${Baseline}_strict_tdm_profile.apk"
Copy-Item 'build\app\outputs\flutter-apk\app-profile.apk' $StrictApk
Get-FileHash $StrictApk -Algorithm SHA256 |
  Format-List | Out-File "$Evidence\strict_tdm_profile_hash.txt"
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
$DeviceA = '<device-A-serial>'
$Evidence = '<absolute evidence directory from step 1>'
adb -s $DeviceA logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\concurrent_device_A.log"
```

Concurrent log terminal B:

```powershell
$DeviceB = '<device-B-serial>'
$Evidence = '<absolute evidence directory from step 1>'
adb -s $DeviceB logcat -v threadtime 2>&1 |
  Tee-Object "$Evidence\concurrent_device_B.log"
```

After concurrent attempt 20 has ended and its summary has appeared, stop those
two log terminals. Clear logcat again, mark `STRICT TDM PROFILE COMPARISON
START`, and repeat the same two commands with filenames
`strict_tdm_device_A.log` and `strict_tdm_device_B.log`.

2. In separate interactive terminals, launch the same preserved APK:

```powershell
flutter run -d <device-A-serial> --profile --use-application-binary='<absolute mode APK>'
flutter run -d <device-B-serial> --profile --use-application-binary='<absolute mode APK>'
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
flutter test integration_test/security/database_encryption_device_test.dart `
  -d $DeviceA 2>&1 | Tee-Object "$Evidence\sqlcipher_device_A.txt"
if ($LASTEXITCODE -ne 0) { throw 'Android SQLCipher device proof failed.' }
```

The test writes a marker, verifies the file lacks the plaintext
`SQLite format 3` header, proves a no-password query fails, and reopens it
through the app's SQLCipher path. Record the exact device, commit, output, and
exit code.

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
$Logs = Get-ChildItem $Evidence -Filter '*.log'

$PayloadNeedles = @(
  'PK-A2B-', 'PK-B2A-', 'PK-UNICODE-', 'PK-KK-', 'PK-OFFLINE-',
  'PK-RESUME-', 'PK-RELAUNCH-', 'PK-DOZE-'
)
Select-String -Path $Logs.FullName -SimpleMatch -Pattern $PayloadNeedles |
  Set-Content "$Evidence\privacy_payload_hits.txt"

Select-String -Path $Logs.FullName `
  -Pattern 'private[_ ]?key|passphrase|password|SQLCipher.{0,20}key|encryption.{0,20}key|FATAL EXCEPTION|nonce|replay|authentication failed|decrypt.*failed|status 133' `
  -Context 1,1 | Set-Content "$Evidence\privacy_and_failure_review.txt"

Get-ChildItem $Evidence -File | Get-FileHash -Algorithm SHA256 |
  Format-Table -AutoSize | Out-File "$Evidence\evidence_hashes.txt"
```

Review every hit in context. The payload-hit file must be empty for plaintext
content. A label such as `private key unavailable` may be harmless; actual key
bytes, passphrases, passwords, SQLCipher credentials, or plaintext payload
previews are a failure.

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
| Multi-link inventory/routing | BLOCKED | needs 3 devices |  |  | Third device required |
| Relay A -> B -> C | BLOCKED | needs 3 devices |  |  | Third device required |
| Log/privacy inspection |  | all modes |  |  |  |
| SQLCipher at-rest proof |  | integration/device |  |  |  |
| Process death/relaunch |  | debug |  |  |  |
| Doze observation |  | debug |  |  |  |

Closeout checks:

```powershell
"ended=$((Get-Date).ToString('o'))" | Add-Content "$Evidence\session_metadata.txt"
adb devices -l | Add-Content "$Evidence\adb_devices_end.txt"

git diff --exit-code "${Baseline}..HEAD" -- $BuildInputs
if ($LASTEXITCODE -ne 0) { throw 'Build inputs drifted during the run.' }

git status --short
```

Flutter may regenerate tracked plugin registrants during builds. Inspect their
diffs; if they are only generated churn and the pre-run worktree was clean,
restore them before closing the evidence pass:

```powershell
git restore -- `
  linux/flutter/generated_plugin_registrant.cc `
  linux/flutter/generated_plugin_registrant.h `
  linux/flutter/generated_plugins.cmake `
  macos/Flutter/GeneratedPluginRegistrant.swift `
  windows/flutter/generated_plugin_registrant.cc `
  windows/flutter/generated_plugin_registrant.h `
  windows/flutter/generated_plugins.cmake
```

The recommended next action after this two-device pass is to fix any saved
`FAIL` before expanding scope. If all executable two-device rows pass, add one
third Android device only for multi-link inventory/routing and the controlled
A -> B -> C relay/TDM decision gate.
