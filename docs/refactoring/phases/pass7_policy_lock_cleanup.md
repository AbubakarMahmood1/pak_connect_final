# Pass 7: Policy Lock + Cleanup (In Progress)

**Status**: In Progress  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Lock in the runtime hardening guardrails from Pass 6 and reduce remaining
escape hatches that can reintroduce split-brain behavior.

---

## Completed In This Slice

- Hardened BLE facade lifecycle tests to be strict-guard compatible:
  - `test/data/services/ble_service_facade_test.dart`
  - converted teardown/lifecycle dispose paths to await asynchronous disposal
  - removed ad-hoc secondary facade instantiation in mesh event bubbling tests
    (tests now use the primary per-test facade instance)

- Verified strict singleton guard behavior in test execution:
  - `PAKCONNECT_BLE_STRICT_SINGLETON_GUARD=true` now passes for
    `ble_service_facade_test.dart`
  - confirms no accidental concurrent facade ownership within the suite

- Wired strict singleton guard verification into CI:
  - `.github/workflows/flutter_coverage.yml`
  - added `Enforce BLE strict singleton guard suite` step that runs:
    - `flutter test test/data/services/ble_service_facade_test.dart --dart-define=PAKCONNECT_BLE_STRICT_SINGLETON_GUARD=true`
  - publishes `ble_strict_singleton_latest.log` as workflow artifact

- Pruned one legacy security fallback escape hatch:
  - `lib/domain/services/security_service_locator.dart`
    - removed implicit fallback instance path (`registerFallback`)
    - locator now requires explicit resolver configuration
  - `lib/core/services/security_manager.dart`
    - removed constructor-side implicit fallback registration
  - `test/data/services/ble_write_adapter_test.dart`
    - migrated to explicit `configureServiceResolver(...)` + teardown cleanup

- Pruned presentation singleton usage for app-composed management services:
  - `lib/core/di/app_services.dart`
    - expanded typed composition snapshot to include
      `ContactManagementService`, `ChatManagementService`,
      `ArchiveManagementService`, and `ArchiveSearchService`
  - `lib/core/app_core.dart`
    - persisted archive management/search services as app-composed fields and
      exposed all four management services through `_buildAppServices()`
  - `lib/presentation/providers/archive_provider.dart`
  - `lib/presentation/providers/archive_management_service_provider.dart`
  - `lib/presentation/providers/archive_search_service_provider.dart`
  - `lib/presentation/providers/chat_notification_providers.dart`
  - `lib/presentation/providers/contact_provider.dart`
    - all now resolve management services through
      `resolveFromAppServicesOrServiceLocator(...)` with AppServices-first
      behavior
  - `test/core/test_helpers/test_setup.dart`
    - test harness now composes and snapshots these same management services in
      `AppServices`, keeping provider/runtime seams consistent in tests

---

## Verification

Commands run:

```powershell
flutter analyze test/data/services/ble_service_facade_test.dart
flutter test test/data/services/ble_service_facade_test.dart
flutter test test/data/services/ble_service_facade_test.dart --dart-define=PAKCONNECT_BLE_STRICT_SINGLETON_GUARD=true
flutter analyze lib/domain/services/security_service_locator.dart lib/core/services/security_manager.dart test/data/services/ble_write_adapter_test.dart
flutter test test/data/services/ble_write_adapter_test.dart
flutter analyze lib/core/di/app_services.dart lib/core/app_core.dart lib/presentation/providers/archive_provider.dart lib/presentation/providers/archive_management_service_provider.dart lib/presentation/providers/archive_search_service_provider.dart lib/presentation/providers/chat_notification_providers.dart lib/presentation/providers/contact_provider.dart test/core/test_helpers/test_setup.dart
flutter test test/domain/services/archive_search_service_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass7_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze/tests: **Passed**
- Strict guard mode test run: **Passed**
- Snapshot (`validation_outputs/di_pass7_snapshot.json`):
  - `GetIt` resolutions in `lib/**`: **43**
  - `.instance` usages in `lib/**`: **86**
  - Presentation import guard violations: **0**
  - Presentation DI mutation violations: **0**

---

## Next Slice

- Continue pruning resolver fallback seams in domain/core singleton factories
  where composition-root wiring is now guaranteed.
