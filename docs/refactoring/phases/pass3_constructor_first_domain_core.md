# Pass 3: Constructor-First Domain/Core (In Progress)

**Status**: In Progress  
**Date**: 2026-02-12  
**Owner**: Architecture Refactor Track

---

## Objective

Move core/domain services away from hidden global dependency lookups and toward
explicit constructor wiring, while preserving backward compatibility during
migration.

---

## Completed In This Slice

- Added constructor-first creation paths and singleton install hooks:
  - `lib/domain/services/contact_management_service.dart`
  - `lib/domain/services/archive_management_service.dart`
  - `lib/domain/services/archive_search_service.dart`
  - `lib/domain/services/chat_management_service.dart`

- Updated `ChatSyncService` to require explicit dependencies:
  - `lib/domain/services/chat_sync_service.dart`

- Updated `AppCore` composition to construct and install these services
  explicitly instead of relying on implicit global lookups:
  - `lib/core/app_core.dart`

- Added config-first/runtime-composed wiring for scheduler + notifications:
  - `lib/domain/services/auto_archive_scheduler.dart`
  - `lib/domain/services/notification_handler_factory.dart`
  - `lib/domain/services/notification_service.dart`
  - `lib/core/app_core.dart`
  - `lib/presentation/controllers/settings_controller.dart`

- Removed internal `GetIt` lookup paths from extracted chat utilities and wired
  provider composition to reuse one injected pinning service instance:
  - `lib/core/services/search_service.dart`
  - `lib/domain/services/pinning_service.dart`
  - `lib/presentation/providers/pinning_service_provider.dart`
  - `lib/presentation/providers/chat_notification_providers.dart`

- Removed additional hidden DI lookups in runtime helper services and wired
  explicit dependency flow from composition points:
  - `lib/core/services/archive_service.dart`
  - `lib/domain/services/message_retry_coordinator.dart`
  - `lib/presentation/controllers/chat_retry_helper.dart`
  - `lib/domain/services/hint_cache_manager.dart`
  - `lib/domain/services/device_deduplication_manager.dart`
  - `lib/core/app_core.dart`
  - `lib/data/services/ble_service_facade.dart`
  - `lib/data/services/ble_service_facade_runtime_helper.dart`

- Removed hidden DI lookups from router/mesh runtime construction and switched
  mesh service creation to explicit repository injection:
  - `lib/domain/services/message_router.dart`
  - `lib/domain/services/mesh_networking_service.dart`
  - `lib/core/app_core.dart`
  - `test/core/test_helpers/test_setup.dart`
  - `test/domain/services/mesh/mesh_networking_service_binary_test.dart`

- Replaced legacy singleton `fromServiceLocator()` internals in domain
  management services with composition-configured resolver hooks:
  - `lib/domain/services/archive_management_service.dart`
  - `lib/domain/services/archive_search_service.dart`
  - `lib/domain/services/contact_management_service.dart`
  - `lib/domain/services/chat_management_service.dart`
  - `lib/core/app_core.dart`
  - `lib/core/di/service_locator.dart`
  - `test/core/test_helpers/test_setup.dart`
  - `test/domain/services/archive_search_service_test.dart`
  - `test/domain/services/mesh/mesh_networking_service_binary_test.dart`

- Removed hidden relay-engine fallback lookups and moved resolver wiring to
  composition/harness edges:
  - `lib/core/messaging/mesh_relay_engine.dart`
  - `lib/core/messaging/relay_decision_engine.dart`
  - `lib/core/app_core.dart`
  - `lib/core/di/service_locator.dart`
  - `test/core/test_helpers/test_setup.dart`

- Removed hidden repository-provider fallback lookups from BLE handshake
  coordinators/managers and moved resolver wiring to composition/harness edges:
  - `lib/core/bluetooth/handshake_coordinator.dart`
  - `lib/core/bluetooth/smart_handshake_manager.dart`
  - `lib/core/app_core.dart`
  - `lib/core/di/service_locator.dart`
  - `test/core/test_helpers/test_setup.dart`

- Removed hidden contact repository fallback lookups from security runtime and
  wired resolver-based composition/harness configuration:
  - `lib/core/services/security_manager.dart`
  - `lib/core/app_core.dart`
  - `lib/core/di/service_locator.dart`
  - `test/core/test_helpers/test_setup.dart`

- Removed hidden data-layer fallback lookups from relay/protocol/cleanup
  services and replaced them with resolver hooks configured at data registrar
  boundaries:
  - `lib/data/services/relay_coordinator.dart`
  - `lib/data/services/mesh_relay_handler.dart`
  - `lib/data/services/protocol_message_handler.dart`
  - `lib/data/services/ephemeral_contact_cleaner.dart`
  - `lib/data/di/data_layer_service_registrar.dart`
  - `test/core/test_helpers/test_setup.dart`

- Removed hidden BLE handshake/facade `GetIt.instance` fallback lookups and
  replaced them with explicit resolver/registrar hooks from composition points:
  - `lib/data/services/ble_handshake_service.dart`
  - `lib/data/services/ble_message_handler_facade.dart`
  - `lib/data/services/ble_message_handler_facade_impl.dart`
  - `lib/data/services/ble_service_facade.dart`
  - `lib/data/di/data_layer_service_registrar.dart`
  - `test/core/test_helpers/test_setup.dart`

- Added typed composition-root scaffold and consolidated app-composed
  dependency references to avoid repeated locator lookups:
  - `lib/core/di/app_services.dart`
  - `lib/core/app_core.dart`

---

## Verification

Commands run:

```powershell
flutter analyze lib/core/app_core.dart lib/domain/services/chat_management_service.dart lib/domain/services/chat_sync_service.dart lib/domain/services/contact_management_service.dart lib/domain/services/archive_management_service.dart lib/domain/services/archive_search_service.dart lib/domain/services/auto_archive_scheduler.dart lib/domain/services/notification_service.dart lib/domain/services/notification_handler_factory.dart lib/presentation/controllers/settings_controller.dart lib/core/services/search_service.dart lib/domain/services/pinning_service.dart lib/presentation/providers/pinning_service_provider.dart lib/presentation/providers/chat_notification_providers.dart
flutter analyze lib/core/services/archive_service.dart lib/domain/services/message_retry_coordinator.dart lib/presentation/controllers/chat_retry_helper.dart lib/domain/services/hint_cache_manager.dart lib/domain/services/device_deduplication_manager.dart lib/core/app_core.dart lib/data/services/ble_service_facade.dart lib/data/services/ble_service_facade_runtime_helper.dart
pwsh -File scripts/di_pass0_audit.ps1 -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
flutter test test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
flutter test test/core/messaging/message_retry_coordination_test.dart test/core/messaging/offline_message_queue_sqlite_test.dart
flutter analyze lib/domain/services/hint_scanner_service.dart lib/core/security/contact_recognizer.dart lib/core/services/message_queue_repository.dart lib/core/services/queue_persistence_manager.dart lib/core/messaging/offline_queue_store.dart lib/core/messaging/offline_message_queue.dart lib/core/app_core.dart test/core/test_helpers/test_setup.dart
flutter test test/core/services/message_queue_repository_test.dart test/core/services/queue_persistence_manager_test.dart test/core/messaging/message_retry_coordination_test.dart test/core/messaging/offline_message_queue_sqlite_test.dart
flutter analyze lib/domain/services/message_router.dart lib/domain/services/mesh_networking_service.dart lib/core/app_core.dart test/core/test_helpers/test_setup.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
flutter test test/domain/services/mesh/mesh_networking_service_binary_test.dart test/core/services/message_queue_repository_test.dart test/core/services/queue_persistence_manager_test.dart test/core/messaging/message_retry_coordination_test.dart test/core/messaging/offline_message_queue_sqlite_test.dart
flutter analyze lib/domain/services/archive_management_service.dart lib/domain/services/archive_search_service.dart lib/domain/services/contact_management_service.dart lib/domain/services/chat_management_service.dart lib/core/di/service_locator.dart lib/core/app_core.dart test/core/test_helpers/test_setup.dart test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
flutter test test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart test/presentation/controllers/home_screen_controller_test.dart test/core/services/message_queue_repository_test.dart test/core/services/queue_persistence_manager_test.dart test/core/messaging/message_retry_coordination_test.dart test/core/messaging/offline_message_queue_sqlite_test.dart
flutter analyze lib/core/di/service_locator.dart lib/core/app_core.dart lib/domain/services/archive_management_service.dart lib/domain/services/archive_search_service.dart lib/domain/services/contact_management_service.dart lib/domain/services/chat_management_service.dart test/core/test_helpers/test_setup.dart test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart
flutter test test/domain/services/archive_search_service_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart test/presentation/controllers/home_screen_controller_test.dart
flutter analyze lib/core/messaging/mesh_relay_engine.dart lib/core/messaging/relay_decision_engine.dart lib/core/app_core.dart lib/core/di/service_locator.dart test/core/test_helpers/test_setup.dart
flutter test test/core/messaging/relay_phase2_test.dart test/core/messaging/relay_phase3_test.dart test/core/messaging/mesh_routing_integration_test.dart test/core/messaging/mesh_relay_flow_test.dart test/domain/services/mesh/mesh_networking_service_binary_test.dart test/presentation/controllers/home_screen_controller_test.dart
flutter analyze lib/core/bluetooth/handshake_coordinator.dart lib/core/bluetooth/smart_handshake_manager.dart lib/core/app_core.dart lib/core/di/service_locator.dart test/core/test_helpers/test_setup.dart
flutter test test/core/bluetooth/handshake_coordinator_test.dart test/core/bluetooth/kk_protocol_integration_test.dart test/core/security/noise/noise_end_to_end_test.dart test/presentation/controllers/home_screen_controller_test.dart
flutter test test/data/services/ble_write_adapter_test.dart
flutter test test/presentation/controllers/home_screen_controller_test.dart
flutter analyze lib/core/services/security_manager.dart lib/core/app_core.dart lib/core/di/service_locator.dart test/core/test_helpers/test_setup.dart
flutter test test/core/services/security_manager_test.dart
flutter test test/core/services/message_sending_fixes_test.dart
flutter analyze lib/data/services/mesh_relay_handler.dart lib/data/services/relay_coordinator.dart lib/data/services/protocol_message_handler.dart lib/data/services/ephemeral_contact_cleaner.dart lib/data/di/data_layer_service_registrar.dart test/core/test_helpers/test_setup.dart
flutter test test/data/services/protocol_message_handler_test.dart test/data/services/relay_coordinator_test.dart test/core/messaging/mesh_relay_flow_test.dart test/core/messaging/queue_sync_system_test.dart
flutter analyze lib/data/services/ble_handshake_service.dart lib/data/services/ble_message_handler_facade.dart lib/data/services/ble_message_handler_facade_impl.dart lib/data/di/data_layer_service_registrar.dart test/core/test_helpers/test_setup.dart
flutter test test/data/services/ble_handshake_service_test.dart test/data/services/ble_service_facade_test.dart test/data/services/protocol_message_handler_test.dart test/data/services/relay_coordinator_test.dart
flutter analyze lib/data/services/ble_service_facade.dart lib/data/di/data_layer_service_registrar.dart test/core/test_helpers/test_setup.dart
flutter test test/data/services/ble_service_facade_test.dart
flutter analyze lib/core/di/app_services.dart lib/core/app_core.dart lib/presentation/providers/di_providers.dart
flutter test test/presentation/controllers/home_screen_controller_test.dart test/core/di/service_locator_test.dart
pwsh -File scripts/di_pass0_audit.ps1 -WriteBaseline -BaselineOut validation_outputs/di_pass3_snapshot.json -EnforcePresentationImportGate -EnforcePresentationDiMutationGate
```

Results:

- Targeted analyze: **No issues found**
- Targeted tests: **All passed**
- DI snapshot deltas:
  - `GetIt` resolutions in `lib/**`: **101 → 44**
  - `.instance` usages in `lib/**`: **167 → 92**
  - Latest slice delta: `GetIt` **47 → 44**, `.instance` **93 → 92**
  - Presentation DI guardrails: still **0 violations**

---

## Remaining Pass 3 Work

- Continue constructor-first migration for remaining core/domain services still
  doing internal `GetIt` resolution.
- Reduce singleton `.instance` reliance where practical before Pass 4
  composition-root formalization.
