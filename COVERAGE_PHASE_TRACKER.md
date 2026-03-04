# Coverage Phase Tracker

Last updated: 2026-03-04

## Baseline
- Full suite: `01:39 +1568: All tests passed!`
- Overall coverage: `33.49% (13696/40892)` from `coverage/lcov.info`
- Layer coverage:
  - `core`: `58.16%`
  - `data`: `42.16%`
  - `domain`: `37.61%`
  - `presentation`: `8.93%`

## Plan
- Phase 1: High-ROI unit tests for service/domain logic (no real-device dependency)
- Phase 2: BLE/data seam-driven tests with fakes
- Phase 3: Database/export/import failure-path hardening tests
- Phase 4: Presentation logic tests (controllers/providers/viewmodels)
- Phase 5: Widget tests for highest-uncovered screens/widgets
- Phase 6: Real-device validation (when hardware is available)

## Phase 1 Breakdown
- [ ] 1.1 Add `ContactManagementService` unit tests
- [ ] 1.2 Add `ArchiveManagementService` unit tests
- [ ] 1.3 Expand `ChatLifecycleService` tests (logic-heavy paths)
- [ ] 1.4 Run targeted tests and coverage, then re-baseline
- [ ] 1.5 Run full suite sanity pass before phase-close checkpoint

## Progress Log
- 2026-03-04: Tracker created. Starting Phase 1.1.

## Checkpoints
- Pending
