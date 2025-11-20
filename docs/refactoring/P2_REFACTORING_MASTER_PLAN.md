# P2 Architecture Refactoring – Reality Snapshot

_Last updated: 2025-11-20_

This document replaces the older narrative with a concise, up-to-date snapshot so
the team can see what is actually done and what must happen next.

---

## Current Status Summary

- **Phase 0 – Pre-Flight (~60 %)**: Baseline test log and `docs/refactoring/ARCHITECTURE_ANALYSIS.md`
  exist, but the checklist in `docs/refactoring/phases/phase0_pre_flight.md:21-42`
  still marks the ADR, dependency, and performance work as pending. Snapshot
  branches such as `refactor/p2-architecture-baseline` were intentionally retired
  once the work moved to the main local branch, so we no longer track them here.
- **Phase 1 – DI Foundation (✅ 100 %)**: SecurityManager implements
  `ISecurityManager` (`lib/core/services/security_manager.dart:16`),
  MeshNetworkingService implements `IMeshNetworkingService`
  (`lib/domain/services/mesh_networking_service.dart:33`), and BLEService fulfills
  `IConnectionService` plus `IMeshBleService`
  (`lib/data/services/ble_service.dart:18-54`). AppCore registers everything via
  `registerInitializedServices` before Riverpod reads from GetIt
  (`lib/core/app_core.dart:324-353`, `lib/core/di/service_locator.dart:253-304`).
- **Phase 2 – Top 3 God Classes (~35 %)**: The BLE split is live
  (`lib/data/services/ble_service_facade.dart:32-840`) and UI/providers now depend
  on `IConnectionService` (`lib/presentation/providers/ble_providers.dart:16-227`,
  `lib/presentation/screens/chat_screen.dart:150-2144`), but
  `MeshNetworkingService` (1,517 lines) and `ChatScreen` (2,357 lines) remain
  monoliths with no extracted coordinators or view models wired up.
- **Phase 3 – Layer Violations (~70 %)**: Most consumers resolve interfaces such
  as `IMeshBleService`/`IRepositoryProvider` and navigation is callback-driven, but
  there is still no production `IConnectionService` implementation used by the
  domain layer, and `MeshNetworkingService` talks directly to BLE instead of via a
  dedicated connection abstraction.
- **Phase 4 – Remaining God Classes (~20 %)**: Stubs like
  `OfflineQueueFacade` exist, yet the targeted files are still >1,000 lines:
  `ble_state_manager.dart` (2,326), `ble_message_handler.dart` (1,889),
  `offline_message_queue.dart` (1,777), `chat_management_service.dart` (1,739),
  `home_screen.dart` (1,150).
- **Phase 5 – Testing Infrastructure (~85 %)**: Harness plumbing, fake BLE
  platform, and CI coverage workflow are live, and `flutter_test_latest.log`
  records **1,303 passing tests** (`flutter_test_latest.log:11540`), but the doc
  still claims 1,284 tests, and log noise such as repeated
  `InvalidCipherTextException` warnings has not been resolved.

---

## Latest Reality Check

- **Branches**: No branch named `refactor/p2-architecture-baseline` in `git branch
  -a`; snapshot work must be documented another way.
- **Tests**: `flutter test --coverage` last produced `flutter_test_latest.log`
  with 1,303 passes and warnings about SQLCipher cleanup. Coverage data exists at
  `coverage/lcov.info`.
- **Dependencies**: `pubspec.yaml:30-91` already includes `get_it`, `mockito`,
  and the updated `build_runner`, matching the dependency task even though docs
  say otherwise.
- **Performance Baseline**:
  `docs/refactoring/PERFORMANCE_BASELINE.md:9-60` remains “Status: Pending” on
  purpose—real-device performance validation is deferred until after the current
  refactor finishes, so the doc should capture that deferral instead of implying
  work is blocked.

---

## Phase 2 Deep Dive (requested)

| Deliverable | Status | Evidence |
|-------------|--------|----------|
| BLE split into facade + sub-services registered via DI | ✅ Complete | `lib/data/services/ble_service_facade.dart:32-840`, `lib/data/services/ble_service.dart:18-53`, `lib/core/di/service_locator.dart:253-304` |
| App runtime and UI consume `IConnectionService` instead of the monolith | ✅ Complete | `lib/presentation/providers/ble_providers.dart:16-227`, `lib/presentation/screens/chat_screen.dart:150-2144`, `lib/presentation/widgets/discovery_overlay.dart:300-680` |
| MeshNetworkingService reduced below 1,000 lines with relay/queue coordinators | ❌ Not started | `lib/domain/services/mesh_networking_service.dart` is still 1,517 lines and no `MeshRelayCoordinator`/`MeshQueueSyncService` files exist |
| ChatScreen reduced below 500 lines with view model/controllers wired through DI | ❌ Not started | `lib/presentation/screens/chat_screen.dart` remains 2,357 lines even though helper types live under `lib/presentation/providers` and `lib/presentation/controllers` |

**Phase 2 completion estimate**: roughly **35 %** (BLE stack done, Mesh +
Chat refactors outstanding).

---

## Action Plan

1. **Document Phase 0 reality**: update `phase0_pre_flight.md` with the finished
   ADR/architecture/dependency ticks, record the missing branch decision, and fill
   in the `PERFORMANCE_BASELINE.md` numbers (or state why they are blocked).
2. **Finalize BLE seam adoption**: keep `IConnectionService` as the single
   runtime seam and register the facade as such everywhere; remove any remaining
   direct `BLEService` references once backwards compatibility is no longer
   required.
3. **Resume Phase 2 refactors**:
   - Split `MeshNetworkingService` into the planned
     `MeshRelayCoordinator`/`MeshQueueSyncService`/`MeshNetworkHealthMonitor`
     pieces and wire them via DI.
   - Move ChatScreen logic (retry wiring, mesh setup, pairing flows) into
     `ChatMessagingViewModel`, controllers, and Riverpod providers so the widget
     drops below the 500-line goal.
4. **Phase 3 follow-through**: make `MeshNetworkingService` and other domain/core
   services depend on `IConnectionService` (or another connection abstraction)
   instead of `IMeshBleService`, then update `phase3` docs once the seam is live.
5. **Phase 4 extractions**: execute the queued splits for
   `ble_state_manager.dart`, `ble_message_handler.dart`,
   `offline_message_queue.dart`, `chat_management_service.dart`, and
   `home_screen.dart`, deleting unused facades/factories afterward.
6. **Phase 5 hardening**: adopt `MockConnectionService`
   (`test/test_helpers/mocks/mock_connection_service.dart`) inside suites,
   eliminate the SQLCipher warnings, and refresh `phase5_testing_plan.md` with the
   real 1,303 test count and coverage artifacts.

Staying disciplined on the action plan ensures the later phases build on an
accurate foundation instead of the outdated assumptions that were previously
recorded here.
