# Coverage Phase Tracker

Last updated: 2026-03-04 (Phase 2 in progress)

## Baseline
- Full suite: `01:39 +1568: All tests passed!`
- Overall coverage: `33.49% (13696/40892)` from `coverage/lcov.info`
- Layer coverage:
  - `core`: `58.16%`
  - `data`: `42.16%`
  - `domain`: `37.61%`
  - `presentation`: `8.93%`

## Current Snapshot
- Full suite: `01:21 +1597: All tests passed!`
- Overall coverage: `35.64% (14573/40892)`
- Coverage delta vs baseline: `+2.15` points (`+877` covered lines)
- Layer coverage:
  - `core`: `58.16%` (unchanged)
  - `data`: `42.16%` (unchanged)
  - `domain`: `44.54%` (`+6.93` points)
  - `presentation`: `8.93%` (unchanged)
- Phase 1 target files:
  - `lib/domain/services/contact_management_service.dart`: `76.90%` (`283/368`)
  - `lib/domain/services/archive_management_service.dart`: `63.25%` (`210/332`)
  - `lib/domain/services/chat_lifecycle_service.dart`: `61.64%` (`188/305`)

## Phase 2 Snapshot (Targeted data/services scope)
- Scope run: `00:13 +355: All tests passed!` via `flutter test --coverage --no-pub test/data/services`
- Phase 2 target files:
  - `lib/data/services/ble_message_handler_facade.dart`: `83.59%` (`214/256`)
  - `lib/data/services/ble_message_handler_facade_impl.dart`: `77.64%` (`184/237`)
  - `lib/data/services/ble_message_handler.dart`: `47.72%` (`136/285`)
- Notes:
  - Strong uplift delivered on seam/facade layers (`facade_impl` from prior `57.38%` to `77.64%` in this targeted scope).
  - Handler-core uplift delivered (`ble_message_handler.dart` from prior `38.95%` to `47.72%`).

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
- [ ] 2.4b Drive deeper `BLEMessageHandler` core processing/error branches
- [ ] 2.5 Re-run full suite + coverage for global delta and phase-close decision

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
- 2026-03-04: Targeted service-layer coverage run passed: `355` tests total.

## Checkpoints
- `e2591f6` - docs: add coverage phase tracker and baseline
- `6d75142` - test: add phase 1 service coverage suites
