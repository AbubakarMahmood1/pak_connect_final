# P2 Architecture Refactoring – Reality Snapshot

_Last updated: 2025-11-20_

This document replaces the older narrative with a concise, up-to-date snapshot so
the team can see what is actually done and what must happen next.

---

## Current Status Summary

- **Phase 0 – Pre-Flight (✅)**: Checklist updated; ADR + architecture analysis +
  dependencies all marked complete; performance baseline explicitly deferred to
  the upcoming device pass with host benchmarks captured
  (`docs/refactoring/phases/phase0_pre_flight.md`). Snapshot branch requirement
  retired; work tracks on `phase-6-critical-refactoring`.
- **Phase 1 – DI Foundation (✅)**: SecurityManager implements
  `ISecurityManager` (`lib/core/services/security_manager.dart:16`),
  MeshNetworkingService implements `IMeshNetworkingService`
  (`lib/domain/services/mesh_networking_service.dart:37`), and BLEServiceFacade
  fulfills `IConnectionService`/`IMeshBleService`
  (`lib/data/services/ble_service.dart:18-53`,
  `lib/data/services/ble_service_facade.dart:45`). AppCore registers everything
  via `registerInitializedServices` before Riverpod reads from GetIt
  (`lib/core/app_core.dart:324-359`, `lib/core/di/service_locator.dart:259-337`).
- **Phase 2 – Top 3 God Classes (✅)**: BLE monolith replaced by the facade +
  sub-services; providers and UI resolve `IConnectionService`. MeshNetworking
  sits at 572 lines (`lib/domain/services/mesh_networking_service.dart`) and
  ChatScreen at 442 lines (`lib/presentation/screens/chat_screen.dart`) with the
  controller/view-model in place.
- **Phase 3 – Layer Violations (✅)**: BLE/mesh coordinators now depend on
  `IConnectionService` (burst scanning, chat list/home facades, relay/queue
  coordinators, topology/connection monitors), NavigationService is callback
  based, repositories flow via `IRepositoryProvider`, and
  SecurityStateComputer lives in data. Remaining IMeshBleService references are
  aliased solely for backwards compatibility in DI/providers.
- **Phase 4 – Remaining God Classes (~20 %)**: >1,000-line targets remain:
  `ble_state_manager.dart` (2,328), `ble_message_handler.dart` (1,891),
  `discovery_overlay.dart` (1,866), `offline_message_queue.dart` (1,778),
  `settings_screen.dart` (1,748), `chat_management_service.dart` (1,739),
  `home_screen.dart` (1,147).
- **Phase 5 – Testing Infrastructure (~85 %)**: Harness/fakes/coverage workflow
  live; latest run shows **1,325 passing tests**
  (`flutter_test_latest.log:3766`). Remaining tasks: reduce
  `InvalidCipherTextException`/SQLCipher “Database deleted” noise and refresh
  docs with the current test count.

---

## Latest Reality Check

- **Branches**: No branch named `refactor/p2-architecture-baseline` in `git branch
  -a`; snapshot work must be documented another way.
- **Tests**: `flutter test --coverage` last produced `flutter_test_latest.log`
  with 1,325 passes and warnings about SQLCipher cleanup. Coverage data exists at
  `coverage/lcov.info`.
- **Dependencies**: `pubspec.yaml:30-91` already includes `get_it`, `mockito`,
  and the updated `build_runner`, matching the dependency task even though docs
  say otherwise.
- **Performance Baseline**:
  `docs/refactoring/PERFORMANCE_BASELINE.md:9-60` remains “Status: Pending” on
  purpose—real-device performance validation is deferred until the device pass;
  host benchmarks are recorded so the phase is not blocking.

---

## Phase 2 Deep Dive (requested)

| Deliverable | Status | Evidence |
|-------------|--------|----------|
| BLE split into facade + sub-services registered via DI | ✅ Complete | `lib/data/services/ble_service_facade.dart`, `lib/data/services/ble_service.dart:18-53`, `lib/core/di/service_locator.dart:259-337` |
| App runtime and UI consume `IConnectionService` instead of the monolith | ✅ Complete | `lib/presentation/providers/ble_providers.dart:118-213`, `lib/presentation/screens/chat_screen.dart:1-442`, `lib/presentation/widgets/discovery_overlay.dart` |
| MeshNetworkingService reduced below 1,000 lines with relay/queue coordinators | ✅ Complete | `lib/domain/services/mesh_networking_service.dart:1-572`, `lib/domain/services/mesh/mesh_relay_coordinator.dart`, `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart` |
| ChatScreen reduced below 500 lines with view model/controllers wired through DI | ✅ Complete | `lib/presentation/screens/chat_screen.dart:1-442` |

**Phase 2 completion**: ✅ Done; remaining >1,000-line classes are tracked for Phase 4.

---

## Action Plan

1. **Phase 0/1/2/3 documentation baseline (done)**: phase0 checklist and master
   plan reflect current reality; Phase 3 layer seams now resolved on
   `IConnectionService`.
2. **Phase 4 prep**: plan splits for the current >1,000-line files
   (`ble_state_manager.dart`, `ble_message_handler.dart`,
   `offline_message_queue.dart`, `settings_screen.dart`,
   `chat_management_service.dart`, `home_screen.dart`,
   `discovery_overlay.dart`), sequencing lowest-risk first.
3. **Phase 5 hardening**: wire `MockConnectionService`
   (`test/test_helpers/mocks/mock_connection_service.dart`) into suites to reduce
   SQLCipher noise; update `phase5_testing_plan.md` with the 1,325-test reality
   and coverage artifacts; continue chasing the `InvalidCipherTextException`
   warnings.

Proceeding with Phase 4 on this updated baseline keeps later refactors aligned
with the current code shape.
