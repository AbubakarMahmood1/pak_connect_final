# Pass 7: Policy Lock + Cleanup (Complete)

**Status**: Complete  
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

- Pruned archive service singleton fallback chaining in chat management:
  - `lib/domain/services/chat_management_service.dart`
    - `fromServiceLocator()` now composes archive collaborators via
      `ArchiveManagementService.fromServiceLocator()` and
      `ArchiveSearchService.fromServiceLocator()` instead of `.instance`
      access, reducing implicit singleton reach-through in fallback paths

- Pruned handshake singleton reach-through in Noise/topology paths:
  - `lib/core/bluetooth/handshake_coordinator.dart`
  - `lib/core/bluetooth/handshake_coordinator_phase2_helper.dart`
    - coordinator now resolves Noise access via injected/defaulted resolver
      callback and routes topology writes via a configurable callback, removing
      repeated direct `SecurityManager.instance`/`TopologyManager.instance`
      access in handshake execution paths
  - `lib/domain/routing/topology_manager.dart`
    - added constructor-style singleton access (`factory TopologyManager()`)
      for composition-friendly call sites
  - `lib/core/app_core.dart`
    - app boot now uses constructor-style singleton access for security/topology
      setup and local `_isInitialized` checks in message-send guard paths

- Pruned repeated `AppCore.instance` access in bootstrap/runtime wrappers:
  - `lib/core/app_core.dart`
    - added constructor-style singleton access (`factory AppCore()`)
  - `lib/main.dart`
    - `AppWrapperState` now holds a retained `AppCore` handle and routes
      initialize/dispose/status checks through that instance field
  - `lib/core/services/app_core_shared_message_queue_provider.dart`
    - provider now takes/stores an injected `AppCore` handle (default
      `AppCore()`), removing repeated static singleton lookups

- Normalized remaining singleton access patterns to constructor-style paths:
  - added factory constructors:
    - `lib/core/services/navigation_service.dart`
    - `lib/domain/services/bluetooth_state_monitor.dart`
    - `lib/core/messaging/relay_config_manager.dart`
    - `lib/data/database/database_query_optimizer.dart`
    - `lib/data/services/seen_message_store.dart`
  - migrated call sites from `.instance` to constructor-style access:
    - `lib/domain/services/burst_scanning_controller.dart`
    - `lib/data/services/ble_service_facade.dart`
    - `lib/domain/services/chat_management_facade.dart`
    - `lib/presentation/providers/bluetooth_state_provider.dart`
    - `lib/presentation/providers/topology_provider.dart`
  - test harness alignment:
    - `test/core/test_helpers/test_setup.dart`
      - now always configures `SecurityServiceLocator` from the composed
        harness security service snapshot, keeping stricter resolver policy
        compatible with facade/integration suites

- Post-pass DI hardening follow-through:
  - `.github/workflows/flutter_coverage.yml`
    - CI now enforces DI metric regression gates using
      `scripts/di_pass0_audit.ps1 -EnforceMetricsGate`
      (`GetIt <= 43`, `.instance <= 24`)
  - `lib/core/app_core.dart`
  - `lib/core/di/service_locator.dart`
  - `lib/data/di/data_layer_service_registrar.dart`
    - normalized remaining locator resolutions to `getIt.get<T>()` calls
      (removed direct callable-locator syntax from production paths)
  - `lib/presentation/providers/ble_providers.dart`
  - `lib/presentation/providers/chat_messaging_view_model.dart`
  - `lib/presentation/providers/mesh_networking_provider.dart`
  - `lib/data/di/data_layer_service_registrar.dart`
  - `lib/core/messaging/mesh_relay_engine.dart`
    - pruned remaining non-framework `.instance` callsites in provider/runtime
      wiring paths (constructor/object reference based access)

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
flutter analyze lib/core/bluetooth/handshake_coordinator.dart lib/core/app_core.dart lib/domain/routing/topology_manager.dart
flutter test test/core/bluetooth/handshake_coordinator_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass7_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
flutter analyze lib/main.dart lib/core/services/app_core_shared_message_queue_provider.dart lib/core/app_core.dart
flutter test test/core/app_core_initialization_retry_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass7_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
flutter analyze lib/core/services/navigation_service.dart lib/domain/services/bluetooth_state_monitor.dart lib/core/messaging/relay_config_manager.dart lib/data/database/database_query_optimizer.dart lib/domain/services/burst_scanning_controller.dart lib/data/services/ble_service_facade.dart lib/data/services/seen_message_store.dart lib/presentation/providers/bluetooth_state_provider.dart lib/core/messaging/mesh_relay_engine.dart lib/domain/services/chat_management_facade.dart lib/presentation/providers/topology_provider.dart lib/presentation/providers/mesh_networking_provider.dart
flutter test test/data/services/ble_service_facade_test.dart
flutter test test/database_query_optimizer_test.dart
flutter test test/core/messaging/relay_phase1_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -EnforceMetricsGate -MaxGetItResolutionCount 5 -MaxInstanceUsageCount 17 -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
flutter analyze lib/core/app_core.dart lib/core/di/service_locator.dart lib/core/messaging/mesh_relay_engine.dart lib/data/di/data_layer_service_registrar.dart lib/presentation/providers/ble_providers.dart lib/presentation/providers/chat_messaging_view_model.dart lib/presentation/providers/mesh_networking_provider.dart
flutter test test/core/app_core_initialization_retry_test.dart test/core/di/phase3_integration_flows_test.dart test/core/messaging/relay_phase2_test.dart test/core/messaging/relay_phase3_test.dart
flutter test test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
flutter test test/data/services/ble_service_facade_test.dart test/presentation/controllers/home_screen_controller_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass7_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze/tests: **Passed**
- Strict guard mode test run: **Passed**
- Snapshot (`validation_outputs/di_pass7_snapshot.json`):
  - `GetIt` resolutions in `lib/**`: **5**
  - `.instance` usages in `lib/**`: **17**
  - Presentation import guard violations: **0**
  - Presentation DI mutation violations: **0**

---

## Next Slice

- Pass 7 objectives complete. Future DI work should be treated as routine
  maintenance (new features should default to constructor/provider injection
  and avoid introducing new global singleton reach-through paths).
