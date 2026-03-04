# Coverage Phase Tracker

Last updated: 2026-03-04 (Phase 1 complete)

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

## Progress Log
- 2026-03-04: Tracker created. Starting Phase 1.1.
- 2026-03-04: Added new suites:
  - `test/domain/services/contact_management_service_test.dart` (8 tests)
  - `test/domain/services/archive_management_service_test.dart` (10 tests)
  - `test/domain/services/chat_lifecycle_service_test.dart` (11 tests)
- 2026-03-04: Targeted run passed: `29` new/targeted tests.
- 2026-03-04: Full-suite run with coverage passed: `1597` tests total.
- 2026-03-04: Phase 1 marked complete (domain service coverage uplift delivered).

## Checkpoints
- `e2591f6` - docs: add coverage phase tracker and baseline
- `6d75142` - test: add phase 1 service coverage suites
