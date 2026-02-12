# Pass 6: Runtime Serialization Hardening (In Progress)

**Status**: In Progress  
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

---

## Verification

Commands run:

```powershell
flutter analyze lib/data/services/ble_service_facade.dart lib/data/services/ble_service_facade_runtime_helper.dart
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

- Add one-at-a-time connect attempt gate in runtime coordination path (lock/
  queue) without changing public APIs.
- Add deterministic cooldown/tie-break logging hooks to verify behavior before
  enforcing stricter runtime transitions.
