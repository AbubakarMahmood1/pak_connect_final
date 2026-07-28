# PakConnect device validation status

Last updated: 2026-07-14

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
| `flutter analyze --no-pub` | PASS | Clean on 2026-07-29 for baseline `7944c93` with Flutter 3.44.4 revision `ad70ec4617166f1c38e5d2bfd388af71fda14f06` / Dart 3.12.2 |
| Desktop full unit/widget suite | PASS | 5,691 passed, 0 failed; reporter 5m37s; measured wall 353,083 ms; 9,268,167-byte `flutter_test_latest.log`, SHA-256 `78798AD4575FB77E3B99F50C5D30B4715CE44CAA9BDC5245982CAF5F3892C905` |
| Coverage artifact | PASS | `coverage/lcov.info`; 426,546 bytes; SHA-256 `57F95535FC93711B39344343A1D8F2DE644B9697EA23F45204D1529CE84BF794` |
| Strict BLE / crypto policy gates | PASS | 108 strict BLE tests and all 14 crypto-policy cases passed |
| DI / hygiene / reachability gates | PASS | 0 direct `GetIt` calls and 16 reviewed `.instance` references; 0 runtime `print()` calls and 21 reviewed timers; 437 libraries / 433 runtime / 4 reviewed test-only / 0 unreviewed |
| Android debug APK | PASS | `build/app/outputs/flutter-apk/app-debug.apk`; 205,113,616 bytes; SHA-256 `84C9B0F5E32D34C90C06D2F9CE7787E23AF60CF79692395B75C2B5DC0BF46059`; its exact runtime/build-input tree is committed as baseline `7944c93` |
| Android release APK | BLOCKED | Signing configuration must be supplied/verified |
| Install on Android device A | BLOCKED | No device attached |
| Install on Android device B | BLOCKED | No device attached |
| iOS build/install | BLOCKED | No macOS/Xcode/iOS device in this environment |

## Two-Android-device protocol matrix

Record device model, OS, app commit, build flavor, timestamps and log file for
every row.

Runtime/build-input baseline for the next run:
`7944c9385a367746646229f5f33c410a39d57570` (`7944c93`) on
`codex/archive-delete-contract`. A descendant is acceptable only if this
runtime/build-input diff is empty:

```powershell
git diff 7944c93..HEAD -- lib test integration_test android ios linux macos web windows assets pubspec.yaml pubspec.lock .metadata analysis_options.yaml
```

Execute the matrix with the exact PowerShell run sheet in
[TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md](TWO_ANDROID_DEVICE_EXECUTION_CHECKLIST.md).

The route-hardening baseline `53bb4fe`, its status descendant `ed4d416`, and
toolchain checkpoint `eccced7` are historical provenance only; `eccced7` was
superseded by `7944c93`. Previous baselines `5a2cb8e` and `979e106`, plus
candidate `0c8fa87`, are also historical. Do not use an older
commit for a new device run.

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
| Sender process death -> relaunch | BLOCKED | A persists a pending row while B is unavailable, survives A process death/relaunch, then delivers exactly once after B returns |
| Doze/battery-saver observation | BLOCKED | Forced-idle state is recorded; any pending row survives and delivers once after unforce/resume, without claiming native background delivery |
| Route disappears mid-send | BLOCKED | Sender fails promptly and retains/retries queue item; no false success |
| Manual reconnect | BLOCKED | Finds the other PakConnect advertiser and reconnects |
| Bluetooth off/on reconnect target | BLOCKED | Record the connected platform peripheral UUID before and after cycling Bluetooth on each phone. Stable UUID may auto-reconnect only to that exact target; rotation must ignore other advertisers and safely time out until manual identity-verified reconnect |
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
  performs a release-signing preflight. It is a legacy convenience helper,
  not an evidence protocol; do not use it to mark rows `PASS` unless the exact
  baseline checklist explicitly routes the operator through it.
- Shell syntax validation passes and the corrected debug artifact path is
  proven by a successful direct Flutter build. Script-driven installation is
  blocked because no Android device is attached.
- Capture `flutter devices`, build output, `adb devices -l`, per-device logs and
  the final matrix in a timestamped evidence directory excluded from Git when
  it contains device identifiers.
- The two-device run can close all executable A/B rows, but multi-link
  inventory/routing and `A -> B -> C` relay remain blocked until a third
  physical Android device is available.

## Cross-cutting readiness matrix

These rows prevent a device pass from being stretched into unrelated SRS or
release claims. They use the same evidence-state vocabulary, but not every row
is device-bound.

| Area | Status | Required disposition/evidence |
|---|---|---|
| v10 -> v11 -> v12 database upgrade | NOT RUN | Add a populated v10 fixture upgrade test that verifies the v11 change-log table/triggers, v12 per-peer cursor, preserved user data, schema version and reopen; after that, retain one Android app-update smoke artifact |
| Mixed app/protocol versions | BLOCKED | The current exact checklist installs one identical APK hash on both phones and therefore cannot prove cross-version compatibility. Define supported old/new build hashes, install/upgrade order, expected protocol-floor accept/reject behavior, and bidirectional XX/KK/message cases in a checklist extension |
| Accessibility | NOT RUN | Record TalkBack traversal and labels, 200% text scaling without clipped actions/content, non-color-only status meaning, touch targets, and any claimed keyboard/focus behavior. High-contrast mode remains not implemented |
| Numeric performance/battery targets | NOT RUN | Treat every numeric NFR as a design target until a fixed build/device/OS/workload, sample count, percentile rule, radio conditions and raw result artifact are recorded |
| Third-party license and crypto-distribution audit | NOT RUN | Generate a lockfile-derived dependency/SBOM inventory, review bundled licenses/notices and applicable jurisdictional crypto obligations, then retain shipped notices. A phone run cannot close this release gate |

## Exit gate

PakConnect is not device-ready merely because unit tests pass. Minimum exit is:

- debug APK builds (`PASS` locally);
- two Android devices pass discovery in both roles;
- XX and KK handshakes pass;
- bidirectional direct messages and offline/reconnect delivery pass;
- targeted MTU/fragmentation and stale-attempt regressions pass on hardware;
- SQLCipher at-rest proof passes;
- failures and logs contain no sensitive material.
