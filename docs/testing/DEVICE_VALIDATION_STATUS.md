# PakConnect device validation status

Last updated: 2026-07-13

## Current environment

- No Android or iOS phone was attached during the reconciliation pass.
- Available Flutter targets were Windows, Chrome and Edge.
- Visual Studio was absent, so a Windows desktop build was not available.
- Android SDK/JDK setup and licenses were healthy.
- Desktop SQLite tests used the documented plaintext fallback because a
  native SQLCipher library was not available.

This means desktop analysis/tests can prove deterministic policy and state
machine behavior, but not radio interoperability, OS lifecycle behavior or
encrypted bytes at rest on a phone.

## Evidence states

Use only these labels:

- `PASS`: observed on the named device/build with saved evidence.
- `FAIL`: reproducible failure with saved evidence.
- `BLOCKED`: environment or hardware unavailable.
- `NOT RUN`: runnable but not executed yet.

## Build/install matrix

| Item | Status | Evidence/notes |
|---|---|---|
| `flutter analyze --no-pub` | PASS | Clean on 2026-07-13 with Flutter 3.41.5 / Dart 3.11.3 |
| Desktop full unit/widget suite | PASS | 5,539 tests, 0 failures, 4m56s; 9,200,096-byte `flutter_test_latest.log`, SHA-256 `80BCAA4C731DA95071547487DEFAFA612945CF338F55DCF491567D4A0395C2B4` |
| Android debug APK | PASS | `build/app/outputs/flutter-apk/app-debug.apk`; 203,988,403 bytes; SHA-256 `40DBD095BF796A71B8B66DB6194724E2699325D3BF457093758276903EAF3C92`; its exact code/build-input tree is committed as baseline `fcb3013` |
| Android release APK | BLOCKED | Signing configuration must be supplied/verified |
| Install on Android device A | BLOCKED | No device attached |
| Install on Android device B | BLOCKED | No device attached |
| iOS build/install | BLOCKED | No macOS/Xcode/iOS device in this environment |

## Two-Android-device protocol matrix

Record device model, OS, app commit, build flavor, timestamps and log file for
every row.

Code baseline for the next run: `fcb3013215484d2e5b3c3b75f655d81c28209171`
(`fcb3013`). A documentation-only descendant is acceptable if
`git diff fcb3013..HEAD -- lib test integration_test android ios assets pubspec.yaml pubspec.lock`
is empty. Execute the matrix with the exact PowerShell run sheet in
[TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md](TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md).

The previous verified baseline `a5c2b08` and its APK/test hashes remain
historical provenance only. Do not use them for a new device run.

| Scenario | Status | Required observation |
|---|---|---|
| Permissions and Bluetooth readiness | BLOCKED | Both devices reach ready state after fresh install and denied-then-granted permission paths |
| A scans, B advertises | BLOCKED | Discovery by PakConnect service UUID; no unrelated advertiser selected |
| B scans, A advertises | BLOCKED | Reverse-role discovery works |
| Simultaneous discovery/collision | BLOCKED | Single surviving link; no handshake storm or duplicate session |
| Strict-TDM bring-up | BLOCKED | One attempt's MTU, notify and handshake milestones release its connect lock; old attempt events do not |
| Noise XX first contact | BLOCKED | Handshake establishes before encrypted traffic; identities saved at LOW security correctly |
| Noise KK paired reconnect | BLOCKED | Persistent pairing reconnects and establishes without nonce reuse |
| A sends text to B | BLOCKED | B receives once, ACK completes A's queued message |
| B sends text to A | BLOCKED | Reverse direction works |
| Unicode and pipe-heavy text | BLOCKED | Exact Urdu/emoji/CJK/pipe round-trip across fragmentation |
| Large/binary media | BLOCKED | Target-route MTU respected; byte-perfect reassembly; progress/retry sane |
| Offline queue then reconnect | BLOCKED | Pending direct message reaches intended peer only |
| Foreground -> background -> resume | BLOCKED | Dart resume hook flushes backlog on a ready link; this does not claim delivery while killed or dozing |
| Route disappears mid-send | BLOCKED | Sender fails promptly and retains/retries queue item; no false success |
| Manual reconnect | BLOCKED | Finds the other PakConnect advertiser and reconnects |
| Multi-link inventory/routing | BLOCKED | All links listed; control frames use exact route/MTU; ambiguous direct payloads defer until per-link identity/ACK binding exists |
| Relay A -> B -> C | BLOCKED | Requires three phones. Final C delivery decodes the signed encrypted v2 inner `ProtocolMessage`, authenticates/decrypts and persists it before the routed ACK; processing failure emits no ACK and does not mark the message seen; a duplicate completed delivery resends the ACK without redelivery |
| Log/privacy inspection | BLOCKED | No keys, plaintext payload previews, passphrases or SQLCipher key material in logs |

## SQLCipher proof

Run on a production-like Android build, not the desktop plaintext test mode:

1. Create contacts/messages, close the app and pull or inspect the database
   file with authorized debug tooling.
2. Confirm ordinary SQLite cannot read schema/content without the random
   secure-storage credential supplied to SQLCipher.
3. Reopen through the app and confirm data remains readable.
4. Exercise credential persistence across restart. Record controlled secure
   storage failure/recovery injection as blocked unless a reviewed safe hook is
   added. Export/import passphrases are a separate PBKDF2 flow.
5. Save command output with secrets redacted and record the exact commit/device.

Status: `BLOCKED` (no phone attached).

Controlled secure-storage fault injection: `BLOCKED` because the current
baseline has no reviewed safe injection hook. Do not delete production key
material ad hoc.

## Background execution proof

The current implementation has a Dart lifecycle resume flush. It does not yet
prove delivery while Android/iOS has suspended or killed the process. A native
background scheduler/service decision is still open. Test at minimum:

- foreground -> background for 30 seconds -> resume;
- OS process suspension;
- process death and relaunch;
- battery saver/doze;
- iOS background limits if an iOS target is claimed.

## Runner/tooling status

- `scripts/real_device_test.sh` now defaults to debug, accepts
  `--debug|--release`, uses `build/app/outputs/flutter-apk/app-{mode}.apk`, and
  performs a release-signing preflight.
- Shell syntax validation passes and the corrected debug artifact path is
  proven by a successful direct Flutter build. Script-driven installation is
  blocked because no Android device is attached.
- Capture `flutter devices`, build output, `adb devices -l`, per-device logs and
  the final matrix in a timestamped evidence directory excluded from Git when
  it contains device identifiers.
- The two-device run can close all executable A/B rows, but multi-link
  inventory/routing and `A -> B -> C` relay remain blocked until a third
  physical Android device is available.

## Exit gate

PakConnect is not device-ready merely because unit tests pass. Minimum exit is:

- debug APK builds (`PASS` locally);
- two Android devices pass discovery in both roles;
- XX and KK handshakes pass;
- bidirectional direct messages and offline/reconnect delivery pass;
- targeted MTU/fragmentation and stale-attempt regressions pass on hardware;
- SQLCipher at-rest proof passes;
- failures and logs contain no sensitive material.
