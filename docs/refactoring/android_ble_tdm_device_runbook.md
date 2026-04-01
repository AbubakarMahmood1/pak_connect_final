# Android BLE TDM Device Runbook

## Purpose

This runbook is the practical next step after the strict-TDM spike implementation.

The code work is done. The automated test work is done. What remains is the real Android device decision gate:

1. run the current concurrent BLE mode on real devices
2. run the strict TDM BLE mode on the same devices
3. capture logs
4. compare the metrics
5. decide whether strict TDM is good enough for now or whether the next step is native Android BLE extraction

## Important Reality Check

`PAKCONNECT_STRICT_TDM` is **not** a UI toggle.

It is a **build-time Dart define**, read in [ble_service_facade.dart](C:/Users/theab/Compressed/pak_connect_final/lib/data/services/ble_service_facade.dart). That means:

- normal run: concurrent mode
- rebuilt run with `--dart-define=PAKCONNECT_STRICT_TDM=true`: strict TDM mode

You must do a **fresh app run/build** for the strict-TDM version. Hot reload is not enough.

The metrics recorder logs `BLE_EXPERIMENT_SUMMARY` with:

- `sessionMode: "concurrent"`
- or `sessionMode: "strict_tdm"`

That log line is emitted by [ble_experiment_metrics_recorder.dart](C:/Users/theab/Compressed/pak_connect_final/lib/data/services/ble_experiment_metrics_recorder.dart).

## What You Need

- 2 Android devices for the two-device connect/handshake runs
- 3 Android devices for the relay runs
- USB debugging enabled
- `adb` working
- `flutter devices` showing the devices
- one terminal per device for `flutter run`
- one terminal per device for `adb logcat`

Recommended mode for decision testing:

- use `--profile`
- do **not** use debug mode for the final comparison
- keep the same mode for both baseline and strict-TDM runs

## Folder Setup

From repo root:

```powershell
New-Item -ItemType Directory -Force logs\ble-experiments | Out-Null
flutter devices
adb devices
```

Name your devices consistently for the whole experiment:

- Device A
- Device B
- Device C

Keep a simple text note with the mapping:

- Device A = `<serial>`
- Device B = `<serial>`
- Device C = `<serial>`

## Logging Setup

Before each run mode, clear Android logs for each device:

```powershell
adb -s <deviceA-serial> logcat -c
adb -s <deviceB-serial> logcat -c
adb -s <deviceC-serial> logcat -c
```

Start one log capture terminal per device.

Baseline example:

```powershell
adb -s <deviceA-serial> logcat | Tee-Object logs\ble-experiments\baseline_device_a.log
adb -s <deviceB-serial> logcat | Tee-Object logs\ble-experiments\baseline_device_b.log
adb -s <deviceC-serial> logcat | Tee-Object logs\ble-experiments\baseline_device_c.log
```

Strict-TDM example:

```powershell
adb -s <deviceA-serial> logcat | Tee-Object logs\ble-experiments\strict_tdm_device_a.log
adb -s <deviceB-serial> logcat | Tee-Object logs\ble-experiments\strict_tdm_device_b.log
adb -s <deviceC-serial> logcat | Tee-Object logs\ble-experiments\strict_tdm_device_c.log
```

## Mode 1: Baseline Concurrent Run

Launch the normal build on each device in separate terminals:

```powershell
flutter run -d <deviceA-serial> --profile
flutter run -d <deviceB-serial> --profile
flutter run -d <deviceC-serial> --profile
```

Expected mode in summary logs:

- `sessionMode: "concurrent"`

## Mode 2: Strict-TDM Run

Launch the strict-TDM build on each device in separate terminals:

```powershell
flutter run -d <deviceA-serial> --profile --dart-define=PAKCONNECT_STRICT_TDM=true
flutter run -d <deviceB-serial> --profile --dart-define=PAKCONNECT_STRICT_TDM=true
flutter run -d <deviceC-serial> --profile --dart-define=PAKCONNECT_STRICT_TDM=true
```

Expected mode in summary logs:

- `sessionMode: "strict_tdm"`

## Two-Device Test Procedure

Target:

- 20 attempts total

Devices:

- Device A
- Device B

Definition of success for one attempt:

- devices discover each other
- devices connect
- handshake completes
- a short message from A to B succeeds
- a short message from B to A succeeds

Recommended per-attempt flow:

1. Make sure both devices are on the same run mode.
2. Bring both apps to the foreground.
3. Let mesh startup happen normally.
4. Wait up to 60 seconds for the link to come up.
5. Send a short test message from A to B.
6. Send a short test message from B to A.
7. Mark the attempt as:
   - `success`
   - `handshake failed`
   - `connect failed`
   - `peer never discovered`
   - `dropped after connect`
8. Move to the next attempt.

Recommended reset between attempts:

- if the devices are still connected, disconnect them using your normal app flow if available
- if there is no clean in-app disconnect, stop the `flutter run` session for both devices with `q`, restart both runs, and continue

Keep the reset method the same for both baseline and strict-TDM runs.

## Three-Device Relay Test Procedure

Target:

- 10 attempts total

Devices:

- Device A
- Device B
- Device C

Physical layout:

- A should reach B
- B should reach C
- A should **not** directly reach C

Definition of success for one attempt:

- A and B connect or discover each other
- B and C connect or discover each other
- a message from A reaches C via B

Recommended per-attempt flow:

1. Put B between A and C.
2. Verify A and C are not directly in easy BLE range.
3. Open all three apps in the same run mode.
4. Allow the mesh to stabilize for up to 90 seconds.
5. Send a short test message from A to C.
6. Confirm receipt on C.
7. Mark the attempt as:
   - `success`
   - `relay not formed`
   - `message not delivered`
   - `mid-run disconnect`

Again, keep the reset method identical for baseline and strict-TDM runs.

## Ending a Run Cleanly

At the end of a baseline or strict-TDM run:

1. stop each `flutter run` session by pressing `q`
2. wait a few seconds
3. then stop the `adb logcat` capture terminals with `Ctrl+C`

This order matters. The metrics summary is emitted during facade shutdown. If you kill log capture first, you may miss the summary.

## Extract the Summaries

After each run mode, extract the summary lines:

```powershell
Select-String -Path logs\ble-experiments\baseline_*.log -Pattern 'BLE_EXPERIMENT_SUMMARY'
Select-String -Path logs\ble-experiments\strict_tdm_*.log -Pattern 'BLE_EXPERIMENT_SUMMARY'
```

Useful extra checks:

```powershell
Select-String -Path logs\ble-experiments\baseline_*.log -Pattern 'sessionMode'
Select-String -Path logs\ble-experiments\strict_tdm_*.log -Pattern 'sessionMode'
```

You want to see:

- baseline logs with `sessionMode":"concurrent"`
- strict logs with `sessionMode":"strict_tdm"`

## What to Compare

Use the `BLE_EXPERIMENT_SUMMARY` values plus your manual attempt counts.

Compare:

- `discoverySuccessRate`
- `connectSuccessRate`
- `handshakeSuccessRate`
- `disconnectDropRate`
- `medianTimeToFirstPeerMs`
- `medianConnectToHandshakeReadyMs`

And separately compare your manual relay numbers:

- successful relay attempts out of 10

## Decision Gate

Strict TDM counts as good enough for now only if all of these are true:

- at least 90% successful connect + handshake rate across the 20 two-device attempts
- at least 80% successful relay attempts across the 10 three-device runs
- at least 50% fewer handshake/drop failures than baseline concurrent mode
- median time to first peer is no worse than 2x the baseline
- median time to second peer / relay discovery is no worse than 2.5x the baseline

Interpretation:

- if all thresholds pass: keep strict TDM as the working Android BLE architecture for now
- if stability improves but latency/discovery gets too slow: move to native Android BLE engine next
- if stability barely improves: skip more plugin work and move directly to native Android BLE engine

## Recommended Results Template

Copy this into a notes file while running:

```text
Device mapping
- A:
- B:
- C:

Baseline concurrent
- two-device attempts: __ / 20 successful
- three-device relay attempts: __ / 10 successful
- handshake/drop failures:
- median time to first peer:
- median connect to handshake ready:
- summary log files:

Strict TDM
- two-device attempts: __ / 20 successful
- three-device relay attempts: __ / 10 successful
- handshake/drop failures:
- median time to first peer:
- median connect to handshake ready:
- summary log files:

Decision
- strict TDM good enough for now: yes / no
- next step:
```

## Troubleshooting

If you do not see `BLE_EXPERIMENT_SUMMARY`:

- make sure you ended `flutter run` with `q`
- wait a few seconds before stopping `adb logcat`
- confirm you were not killing the app process first

If you are unsure which mode was active:

- check the summary `sessionMode`
- baseline should say `concurrent`
- strict run should say `strict_tdm`

If strict mode looks identical to baseline:

- verify you used `--dart-define=PAKCONNECT_STRICT_TDM=true`
- do a fresh `flutter run`, not hot reload

If timings look wildly inconsistent:

- make sure both modes used the same build mode
- use `--profile` for both
- keep the same reset routine and device layout for both runs

## Out of Scope

This runbook does **not** decide iOS.

It is intentionally:

- Android first
- TDM first
- decision driven by measurements, not vibes
