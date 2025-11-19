# Phase 5 – Testing Infrastructure Plan (2025-11-18)

## 1. Current Snapshot
- Phase 5 deliverables are merged: GetIt + repository abstractions back every module and presentation wiring stays within its own layer.
- Secure-storage/sqlite shims flow through `TestSetup.initializeTestEnvironment`, `configureTestDatabase`, and `setupTestDI`, so every DB-heavy suite now runs against its own SQLCipher file.
- BLE, mesh, queue, and widget suites rely on focused services with deterministic harnesses; the new `IBLEPlatformHost` seam plus `FakeBlePlatformHost` keep BLE facade tests pure Dart.
- Plugin-touching utilities (BatteryOptimizer, EphemeralKeyManager) have explicit test gates, so shared initialization no longer leaks into `flutter test`.

## 2. Latest Test Signals
- `flutter test --coverage` (see `flutter_test_latest.log`) now finishes cleanly with **1 284 passing specs, 19 skipped, 0 failing** and refreshes `coverage/lcov.info` for CI.
- The BLE service facade suite runs inside the harness again: `test/services/ble_service_facade_test.dart` injects `_FakeBlePlatformHost` + stub services so no platform channels are touched.
- Queue persistence, mesh networking, selective export/import, relay, retry, and benchmark suites all pass in isolation and as part of the full matrix using the labeled databases.
- Analyzer continues to surface only the long-standing warnings that were already documented; no new lint debt was introduced by the harness changes.

## 3. Objectives
1. ✅ Stabilize the harness so every suite runs against isolated sqlite + fake secure storage (done via `initializeTestEnvironment` + per-suite labels).
2. ✅ Provide DI-aware mocks (`configureTestDI`, canonical repositories, `MockConnectionService`, `_FakeBlePlatformHost`) so service/BLE tests are pure Dart.
3. ✅ Raise coverage once the harness is stable — `flutter test --coverage` now completes and writes `coverage/lcov.info`.
4. ✅ Capture repeatable logs/coverage artifacts (`flutter_test_latest.log`, coverage artifact, Phase 5 journal) for future phases and CI.

## 4. Workstreams
### W1 – Harness Hardening
- Status: Complete. Every suite now calls `TestSetup.initializeTestEnvironment` with a `dbLabel`, and helpers such as `configureTestDatabase`, `nukeDatabase`, and `setupTestDI` are the canonical entry points. BatteryOptimizer/EphemeralKeyManager are gated in tests, so no suite touches real plugins.
- Outcome: Mesh, relay, queue, favorites, export/import, and benchmark specs run concurrently without colliding sqlite files or deleting each other’s temp DBs.

### W2 – DI Utilities & Mocks
- Status: Complete. `configureTestDI()` resets GetIt, registers mock repositories, and exposes the canonical mocks in `test/test_helpers/mocks/`. BLE-focused suites use `_FakeBlePlatformHost` + stub services instead of platform singletons.
- Outcome: All service-level tests (queue persistence, chat connection manager, relay coordinators, retry schedulers, etc.) execute entirely within the DI harness with deterministic dependencies.

### W3 – Test Refactors & Coverage
- Status: Complete. The harness migratons plus BLE platform host allow the entire matrix (1 284 specs) to pass; the `flutter test --coverage` run refreshes both `coverage/lcov.info` and `flutter_test_latest.log`.
- Outcome: Coverage data is reproducible, handshake/mesh/relay suites no longer flake, and BLE facade tests run in <10s without device access.

### W4 – Performance & Benchmark Hygiene
- Status: Complete. Benchmark suites (getAllChats, relay, routing) reuse the labeled databases and log-only reporting, so CI treats them as informational rather than failures.
- Outcome: No benchmark noise during the coverage run; logs capture timing data without tripping CI.

## 5. Immediate Next Actions
1. Promote the new BLE platform host/testing pattern to CLAUDE.md/AGENTS.md so future contributors follow the same seam when adding BLE tests.
2. Wire `flutter test --coverage` (plus collection of `flutter_test_latest.log` and `coverage/lcov.info`) into CI so Phase 6 starts from a reproducible baseline.
3. Shift the master plan to Phase 6 priorities (BLE/runtime refactors) while keeping an eye on the lone skipped suite (`ble_service_facade_test.dart` now green, no remaining skips beyond the intentional hardware gaps).
