# Pass 6: Runtime Serialization Hardening (Complete)

**Status**: Complete  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Harden BLE/mesh runtime ownership by adding low-risk observability and guard
rails that expose split-brain symptoms (duplicate runtime owners/listeners)
before introducing behavior-changing coordination logic.

---

## Completed In This Slice

- Added BLE runtime instance instrumentation to detect duplicate facade owners:
  - `lib/data/services/ble_service_facade.dart`
  - `instanceId` per facade instance
  - global live instance counter
  - optional strict singleton guard via
    `PAKCONNECT_BLE_STRICT_SINGLETON_GUARD`

- Added connection-info subscription instrumentation to flag duplicate listeners:
  - listener add/remove counters with underflow protection and structured logs

- Added test-visible diagnostics for runtime instrumentation:
  - `BLEServiceFacade.debugLiveInstanceCount`
  - `BLEServiceFacade.debugConnectionInfoListenerCount`
  - `BLEServiceFacade.resetLifecycleInstrumentationForTests()`

- Ensured disposal lifecycle updates counters reliably:
  - `lib/data/services/ble_service_facade_runtime_helper.dart`
  - listener removal and instance disposal accounting now happen in `finally`

- Added lifecycle epoch guard for async Bluetooth callbacks:
  - initialization now captures an epoch token
  - monitor callbacks (`ready`/`unavailable`/`retry`) are ignored when stale
  - dispose invalidates the active epoch before teardown

- Added one-at-a-time serialized connection operation gate in facade runtime:
  - `lib/data/services/ble_service_facade.dart`
  - `connectToDevice(...)` now runs through a serialized operation tail
  - duplicate in-flight connect calls for the same address join the active
    operation
  - `disconnect()` now executes through the same serialized operation path
  - stale queued connection operations are skipped after lifecycle epoch
    invalidation/dispose

- Added targeted regression coverage for overlapping connect attempts:
  - `test/data/services/ble_service_facade_test.dart`
  - fake central manager now tracks concurrent connect call depth
  - new test asserts overlapping connect calls never execute central connect
    concurrently (`maxConcurrentConnects == 1`)

- Added deterministic cooldown/tie-break observability hooks:
  - `lib/domain/services/ble_connection_tracker.dart`
  - new read-only cooldown introspection APIs:
    - `retryBackoffRemaining(address)`
    - `nextAllowedAttemptAt(address)`
    - `pendingAttemptCount(address)`
  - `lib/data/services/ble_connection_manager_runtime_client_links.dart`
    now logs cooldown remaining/attempt count/next-allowed timestamp when
    reconnect is throttled
  - `lib/data/services/ble_connection_manager_runtime_collision_policy.dart`
    now logs normalized tie-break comparison context (token summaries,
    comparison result, inbound-viability) and suggested cooldown timing
  - `test/core/bluetooth/connection_tracker_test.dart` extended to verify
    cooldown introspection semantics

- Enforced minimal post-disconnect reconnect cooldown (feature-flagged):
  - `lib/domain/services/ble_connection_tracker.dart`
    - new compile-time flag:
      `PAKCONNECT_BLE_ENFORCE_POST_DISCONNECT_COOLDOWN` (default: `true`)
    - tracks disconnect cooldown windows per address
    - blocks `canAttempt(address)` while active cooldown remains
    - exposes enablement + cooldown constants for diagnostics/testing
  - `lib/data/services/ble_connection_manager_runtime_cleanup.dart`
    - preserves disconnect cooldown windows across connection-state resets
      so enforced cooldown survives cleanup transitions
  - `test/core/bluetooth/connection_tracker_test.dart`
    - added cooldown enforcement test covering blocked/released retry windows

- Added attempt-scoped stale-result guards in client connect runtime:
  - `lib/data/services/ble_connection_manager.dart`
    - per-address client attempt IDs with explicit begin/end/invalidate hooks
  - `lib/data/services/ble_connection_manager_runtime_client_links.dart`
    - connect pipeline now checks attempt currency across async stages
    - stale attempts are ignored safely (optional best-effort disconnect cleanup)
    - stale failure/finalizer paths no longer clear/override newer attempt state
  - `lib/data/services/ble_connection_manager_runtime_cleanup.dart`
    - clearing connection state now invalidates active attempt IDs and pending
      outbound set to prevent stale callbacks from reviving old flows

---

## Verification

Commands run:

```powershell
flutter analyze lib/data/services/ble_service_facade.dart lib/data/services/ble_service_facade_runtime_helper.dart
flutter analyze test/data/services/ble_service_facade_test.dart
flutter analyze lib/domain/services/ble_connection_tracker.dart lib/data/services/ble_connection_manager_runtime_client_links.dart lib/data/services/ble_connection_manager_runtime_collision_policy.dart test/core/bluetooth/connection_tracker_test.dart
flutter analyze lib/data/services/ble_connection_manager_runtime_cleanup.dart
flutter analyze lib/data/services/ble_connection_manager.dart
flutter test test/data/services/ble_service_facade_test.dart --plain-name \"connectToDevice() serializes overlapping connect attempts\"
flutter test test/core/bluetooth/connection_tracker_test.dart
flutter test test/data/services/ble_service_facade_test.dart
flutter test test/data/services/ble_service_facade_test.dart --plain-name \"initialize() completes successfully\"
flutter test test/data/services/ble_service_facade_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass6_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze: **No issues found**
- Targeted BLE/mesh tests: **All passed**
- Snapshot (`validation_outputs/di_pass6_snapshot.json`):
  - `GetIt` resolutions in `lib/**`: **43**
  - `.instance` usages in `lib/**`: **92**
  - Presentation import guard violations: **0**
  - Presentation DI mutation violations: **0**

---

## Next Slice

- Start Pass 7 policy lock-in:
  - tighten strict singleton guard usage in CI/debug profiles
  - trim remaining legacy runtime fallback seams that bypass composition root
