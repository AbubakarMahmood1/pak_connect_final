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

- Pruned presentation `SecurityServiceLocator` singleton usage in chat flow:
  - `lib/presentation/providers/chat_messaging_view_model.dart`
    - introduced injected/resolved `ISecurityService` dependency
      (AppServices-first)
  - `lib/presentation/controllers/chat_screen_controller.dart`
    - chat open-state security/encryption reads now resolve `ISecurityService`
      via DI helper
  - `lib/presentation/screens/chat_screen.dart`
    - media send Noise-session callback now resolves from DI helper instead of
      static locator singleton

- Pruned presentation `MessageRouter.instance` singleton usage in chat flow:
  - `lib/domain/services/message_router.dart`
    - added optional singleton accessor `MessageRouter.maybeInstance`
  - `lib/presentation/controllers/chat_session_lifecycle.dart`
    - queue/router resolution now uses `maybeInstance` and keeps existing
      on-demand initialize fallback behavior
  - `lib/presentation/providers/chat_messaging_view_model.dart`
    - delete-for-everyone path now uses optional router access with explicit
      uninitialized guard handling

- Pruned repeated static security locator usage in outbound send pipeline:
  - `lib/data/services/outbound_message_sender.dart`
    - added injectable `ISecurityService` dependency (defaulted once during
      sender construction)
    - replaced repeated `SecurityServiceLocator.instance` calls in message
      encrypt/trust-level/session checks with injected service usage

- Pruned repeated static security locator usage in inbound text pipeline:
  - `lib/data/services/inbound_text_processor.dart`
    - added injectable `ISecurityService` dependency (defaulted once during
      processor construction)
    - replaced repeated `SecurityServiceLocator.instance` calls in decrypt +
      identity-mapping logic with injected service usage

- Pruned repeated static security locator usage in pairing lifecycle flows:
  - `lib/data/services/pairing_lifecycle_service.dart`
  - `lib/data/services/pairing_failure_handler.dart`
  - `lib/data/services/pairing_request_coordinator.dart`
    - each now takes optional `ISecurityService` injection and resolves lazily
      when needed, replacing repeated per-method static locator calls while
      avoiding eager resolver requirements during test setup

- Pruned protocol-level static security locator usage:
  - `lib/data/services/protocol_message_handler.dart`
    - now requires explicit `ISecurityService` constructor dependency
  - `lib/data/services/ble_message_handler_facade.dart`
    - now owns a shared `ISecurityService` dependency and passes it into
      `ProtocolMessageHandler`, and also reuses it for binary payload decrypt
  - `test/data/services/protocol_message_handler_test.dart`
    - now uses `_FakeSecurityService` injection for constructor-first test setup

- Hardened security locator access API:
  - `lib/domain/services/security_service_locator.dart`
    - added explicit `resolveService()` API (getter now delegates)
  - migrated remaining data/BLE callsites from
    `SecurityServiceLocator.instance` to
    `SecurityServiceLocator.resolveService()` to reduce singleton-style access
    patterns without behavior changes

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
flutter analyze lib/presentation/providers/chat_messaging_view_model.dart lib/presentation/controllers/chat_screen_controller.dart lib/presentation/screens/chat_screen.dart
flutter test test/presentation/chat_screen_controller_test.dart
flutter test test/presentation/chat_session_view_model_test.dart
flutter analyze lib/domain/services/message_router.dart lib/presentation/controllers/chat_session_lifecycle.dart lib/presentation/providers/chat_messaging_view_model.dart
flutter analyze lib/data/services/outbound_message_sender.dart lib/data/services/ble_write_adapter.dart lib/data/services/ble_message_handler.dart
flutter test test/data/services/ble_messaging_service_test.dart
flutter test test/data/services/ble_write_adapter_test.dart
flutter analyze lib/data/services/inbound_text_processor.dart lib/data/services/ble_message_handler.dart
flutter analyze lib/data/services/pairing_lifecycle_service.dart lib/data/services/pairing_failure_handler.dart lib/data/services/pairing_request_coordinator.dart
flutter test test/data/services/pairing_flow_controller_test.dart
flutter analyze lib/data/services/protocol_message_handler.dart lib/data/services/ble_message_handler_facade.dart test/data/services/protocol_message_handler_test.dart
flutter test test/data/services/protocol_message_handler_test.dart
flutter analyze lib/domain/services/security_service_locator.dart lib/data/services/ble_message_handler.dart lib/data/services/ble_message_handler_facade.dart lib/data/services/ble_messaging_transport_helper.dart lib/data/services/ble_service_facade_runtime_helper.dart lib/data/services/inbound_text_processor.dart lib/data/services/outbound_message_sender.dart lib/data/services/pairing_failure_handler.dart lib/data/services/pairing_lifecycle_service.dart lib/data/services/pairing_request_coordinator.dart
flutter test test/data/services/ble_messaging_service_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass7_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze/tests: **Passed**
- Strict guard mode test run: **Passed**
- Snapshot (`validation_outputs/di_pass7_snapshot.json`):
  - `GetIt` resolutions in `lib/**`: **43**
  - `.instance` usages in `lib/**`: **56**
  - Presentation import guard violations: **0**
  - Presentation DI mutation violations: **0**

---

## Next Slice

- Continue pruning resolver fallback seams in domain/core singleton factories
  where composition-root wiring is now guaranteed.
