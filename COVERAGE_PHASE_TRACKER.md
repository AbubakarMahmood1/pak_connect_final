# Coverage Phase Tracker

Last updated: 2026-03-04 (Phase 4 complete)

## Baseline
- Full suite: `01:39 +1568: All tests passed!`
- Overall coverage: `33.49% (13696/40892)` from `coverage/lcov.info`
- Layer coverage:
  - `core`: `58.16%`
  - `data`: `42.16%`
  - `domain`: `37.61%`
  - `presentation`: `8.93%`

## Current Snapshot
- Full suite: `01:33 +1698: All tests passed!`
- Overall coverage: `39.96% (16342/40892)`
- Coverage delta vs baseline: `+6.47` points (`+2646` covered lines)
- Coverage delta vs previous snapshot: `+1.82` points (`+745` covered lines)
- Layer coverage:
  - `core`: `58.16%` (unchanged)
  - `data`: `50.79%` (`+8.63` points)
  - `domain`: `46.15%` (`+8.54` points)
  - `presentation`: `13.79%` (`+4.86` points)
- Phase 1 target files:
  - `lib/domain/services/contact_management_service.dart`: `76.90%` (`283/368`)
  - `lib/domain/services/archive_management_service.dart`: `63.25%` (`210/332`)
  - `lib/domain/services/chat_lifecycle_service.dart`: `61.64%` (`188/305`)

## Phase 2 Snapshot (Targeted data/services scope)
- Scope run: `00:12 +357: All tests passed!` via `flutter test --coverage --no-pub test/data/services`
- Phase 2 target files:
  - `lib/data/services/ble_message_handler_facade.dart`: `83.59%` (`214/256`)
  - `lib/data/services/ble_message_handler_facade_impl.dart`: `77.64%` (`184/237`)
  - `lib/data/services/ble_message_handler.dart`: `57.54%` (`164/285`)
- Notes:
  - Strong uplift delivered on seam/facade layers (`facade_impl` from prior `57.38%` to `77.64%` in this targeted scope).
  - Handler-core uplift delivered (`ble_message_handler.dart` from prior `38.95%` to `57.54%`).

## Phase 3 Snapshot (Database/export/import hardening)
- Scope run: `00:06 +23: All tests passed!` via targeted Phase 3 suite
  - `flutter test --coverage --no-pub test/data/services/export_import test/data/database/database_backup_service_test.dart test/data/database/database_migration_runner_test.dart`
- Additional adapter run: `00:00 +4: All tests passed!` (`test/data/services/export_import/export_import_adapter_test.dart`)
- Full-suite validation: `01:32 +1657: All tests passed!`
- Phase 3 target files:
  - `lib/data/services/export_import/export_service.dart`: `87.88%` (`116/132`)
  - `lib/data/services/export_import/import_service.dart`: `85.12%` (`143/168`)
  - `lib/data/services/export_import/export_service_adapter.dart`: `100%` (`9/9`)
  - `lib/data/services/export_import/import_service_adapter.dart`: `100%` (`5/5`)
  - `lib/data/database/database_backup_service.dart`: `76.72%` (`145/189`)
  - `lib/data/database/database_migration_runner.dart`: `100%` (`71/71`)
  - `lib/data/services/export_import/selective_backup_service.dart`: `81.97%` (`100/122`)
  - `lib/data/services/export_import/selective_restore_service.dart`: `82.20%` (`97/118`)

## Phase 4 Snapshot (Presentation logic foundations)
- Scope run: `00:06 +41: All tests passed!` via targeted Phase 4 suite
  - `flutter test --coverage --no-pub test/presentation/controllers/chat_list_controller_test.dart test/presentation/notifiers/chat_session_state_notifier_test.dart test/presentation/providers/chat_notification_providers_test.dart test/presentation/providers/pinning_service_provider_test.dart test/presentation/providers/security_state_provider_test.dart test/presentation/providers/home_screen_providers_test.dart test/presentation/controllers/settings_controller_test.dart test/presentation/viewmodels/home_screen_view_model_test.dart`
- Full-suite validation: `01:33 +1698: All tests passed!` (captured in `flutter_test_latest.log`)
- Phase 4 target files (final):
  - `lib/presentation/controllers/chat_list_controller.dart`: `100%` (`19/19`)
  - `lib/presentation/notifiers/chat_session_state_notifier.dart`: `89.52%` (`94/105`)
  - `lib/presentation/providers/chat_notification_providers.dart`: `95.45%` (`21/22`)
  - `lib/presentation/providers/pinning_service_provider.dart`: `71.43%` (`10/14`)
  - `lib/presentation/providers/security_state_provider.dart`: `88.89%` (`56/63`)
  - `lib/presentation/providers/home_screen_providers.dart`: `82.61%` (`38/46`)
  - `lib/presentation/controllers/settings_controller.dart`: `78.19%` (`190/243`)
  - `lib/presentation/viewmodels/home_screen_view_model.dart`: `73.80%` (`138/187`)
- Notes:
  - Expanded `security_state_provider` to cover repository/live/asymmetric/cache-invalidation paths (subphase 4.7 complete).
  - Added larger presentation coverage on `settings_controller` and `home_screen_view_model` (subphase 4.8b complete).
  - Presentation layer moved from baseline `8.93%` to `13.79%` after full-suite validation (subphase 4.9 complete).

## Plan
- Phase 1: High-ROI unit tests for service/domain logic (no real-device dependency)
- Phase 2: BLE/data seam-driven tests with fakes
- Phase 3: Database/export/import failure-path hardening tests
- Phase 4: Presentation logic tests (controllers/providers/viewmodels)
- Phase 5: Widget tests for highest-uncovered screens/widgets
- Phase 6: Real-device validation (when hardware is available)

## Phase 1 Breakdown
- [x] 1.1 Add `ContactManagementService` unit tests
- [x] 1.2 Add `ArchiveManagementService` unit tests
- [x] 1.3 Expand `ChatLifecycleService` tests (logic-heavy paths)
- [x] 1.4 Run targeted tests and coverage, then re-baseline
- [x] 1.5 Run full suite sanity pass before phase-close checkpoint

## Phase 2 Breakdown
- [x] 2.1 Add `BLEMessageHandlerFacade` branch/fragment/binary tests
- [x] 2.2 Add `BLEMessageHandlerFacadeImpl` seam/resolver/queue path tests
- [x] 2.3 Run targeted `test/data/services` coverage and collect file metrics
- [x] 2.4a Add direct `BLEMessageHandler` non-device wrapper/QR/relay tests
- [x] 2.4b Drive deeper `BLEMessageHandler` core processing/error branches
- [x] 2.5 Re-run full suite + coverage for global delta and phase-close decision

## Phase 3 Breakdown
- [x] 3.1 Add `ExportService` failure/success/list/cleanup coverage tests
- [x] 3.2 Add `ImportService` validate/import failure-path tests + restore success-path coverage
- [x] 3.3 Add `DatabaseBackupService` metadata/backup-due/cleanup/restore-checksum tests
- [x] 3.4 Add `DatabaseMigrationRunner` migration-dispatch coverage tests
- [x] 3.5 Add export/import adapter forwarding tests (`ExportServiceAdapter`, `ImportServiceAdapter`)
- [x] 3.6 Re-run targeted coverage + full-suite coverage and phase-close decision

## Phase 4 Breakdown
- [x] 4.1 Add `ChatListController` merge/sort/surgical-update tests
- [x] 4.2 Add `ChatSessionStateStore` lifecycle/state mutation tests
- [x] 4.3 Add `ChatNotificationProviders` stream bridge tests
- [x] 4.4 Add `PinningServiceProvider` build/stream/dispose tests
- [x] 4.5 Add initial `SecurityStateProvider` helper/cache utility tests
- [x] 4.6 Run targeted Phase 4 coverage suite and collect per-file metrics
- [x] 4.7 Expand `SecurityStateProvider` compute-path coverage (live/repository/cache invalidation)
- [x] 4.8a Tackle `home_screen_providers` presentation provider-family coverage
- [x] 4.8b Tackle larger presentation targets (`settings_controller`, `home_screen_view_model`)
- [x] 4.9 Run full-suite coverage + phase-close decision

## Progress Log
- 2026-03-04: Tracker created. Starting Phase 1.1.
- 2026-03-04: Added new suites:
  - `test/domain/services/contact_management_service_test.dart` (8 tests)
  - `test/domain/services/archive_management_service_test.dart` (10 tests)
  - `test/domain/services/chat_lifecycle_service_test.dart` (11 tests)
- 2026-03-04: Targeted run passed: `29` new/targeted tests.
- 2026-03-04: Full-suite run with coverage passed: `1597` tests total.
- 2026-03-04: Phase 1 marked complete (domain service coverage uplift delivered).
- 2026-03-04: Phase 2 started with new seam-driven suites:
  - `test/data/services/ble_message_handler_facade_test.dart`
  - `test/data/services/ble_message_handler_facade_impl_test.dart`
- 2026-03-04: Expanded Phase 2 coverage tests (resolver/queue/adapter branches).
- 2026-03-04: Added `test/data/services/ble_message_handler_test.dart` for handler-core non-device paths.
- 2026-03-04: Expanded handler coverage with callback accessor + friend-reveal fail-closed tests.
- 2026-03-04: Targeted service-layer coverage run passed: `357` tests total.
- 2026-03-04: Full-suite coverage run passed: `1630` tests total (`36.81%` overall).
- 2026-03-04: Phase 3 started with new suites:
  - `test/data/services/export_import/export_service_test.dart`
  - `test/data/services/export_import/import_service_test.dart`
  - `test/data/database/database_backup_service_test.dart`
  - `test/data/database/database_migration_runner_test.dart`
- 2026-03-04: Added adapter forwarding suite:
  - `test/data/services/export_import/export_import_adapter_test.dart`
- 2026-03-04: Phase 3 targeted coverage run passed: `23` tests total.
- 2026-03-04: Full-suite coverage run passed: `1657` tests total (`38.14%` overall).
- 2026-03-04: Phase 3 marked complete (data-layer coverage uplift delivered on export/import + backup/migration paths).
- 2026-03-04: Phase 4 started with new presentation suites:
  - `test/presentation/controllers/chat_list_controller_test.dart`
  - `test/presentation/notifiers/chat_session_state_notifier_test.dart`
  - `test/presentation/providers/chat_notification_providers_test.dart`
  - `test/presentation/providers/pinning_service_provider_test.dart`
  - `test/presentation/providers/security_state_provider_test.dart`
- 2026-03-04: Expanded Phase 4 with:
  - `test/presentation/providers/home_screen_providers_test.dart`
- 2026-03-04: Phase 4 targeted coverage run passed: `26` tests total.
- 2026-03-04: Phase 4 subphase 4.1/4.8a marked complete (presentation foundations + home provider uplift delivered).
- 2026-03-04: Expanded Phase 4 with larger presentation suites:
  - `test/presentation/controllers/settings_controller_test.dart`
  - `test/presentation/viewmodels/home_screen_view_model_test.dart`
- 2026-03-04: Expanded `security_state_provider` compute-path coverage (live/repository/asymmetric/cache invalidation).
- 2026-03-04: Phase 4 targeted coverage run passed: `41` tests total.
- 2026-03-04: Full-suite coverage run passed: `1698` tests total (`39.96%` overall), output captured in `flutter_test_latest.log`.
- 2026-03-04: Phase 4 marked complete (presentation-layer uplift delivered across controllers/providers/viewmodels).
- 2026-03-04: Phase 4 review hardening pass completed:
  - `flutter analyze --no-pub test/presentation/controllers/settings_controller_test.dart test/presentation/viewmodels/home_screen_view_model_test.dart test/presentation/providers/security_state_provider_test.dart` → clean
  - targeted presentation rerun passed: `00:03 +43: All tests passed!`

## Checkpoints
- `e2591f6` - docs: add coverage phase tracker and baseline
- `6d75142` - test: add phase 1 service coverage suites
- `6e34216` - test: expand phase 2 BLE handler facade coverage
- `46ed66a` - test: add phase 2 BLE message handler core coverage
- `60fd308` - docs: record phase 2 checkpoint commits
- `b65d530` - test: deepen phase 2 ble handler branch coverage
- `1ca0503` - test: add phase 3 export-import and backup coverage suites
- `2c1249d` - test: add phase 4 presentation coverage foundations
- `e43307c` - test: add home screen providers coverage suite
- `b64447e` - test: complete phase 4 presentation coverage suites
- `d0f780a` - docs: record phase 4 completion coverage snapshot
- `35efad0` - test: harden phase 4 suites and clean analyzer warnings
