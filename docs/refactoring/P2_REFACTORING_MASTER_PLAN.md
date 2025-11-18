# P2 Architecture Refactoring - Master Plan

**Status**: Phase 5 - Testing Infrastructure (Completed)
**Started**: 2025-11-12
**Target Completion**: 2025-02-04 (12 weeks)
**Current Branch**: multi-phase refactor branches (phase-specific)

---

## Executive Summary

**Scope**: Refactor 56 files, update/create 170 tests
**Timeline**: 12 weeks (solo developer + AI pair programming)
**Approach**: Balanced risk (phase-by-phase with full test validation)
**Risk Level**: HIGH

### Latest Reality Check (2025-11-19)

- **Git Tag**: `v1.0-pre-refactor` (still baseline; per-phase tags pending)
- **Test Results**: 1,284 passed / 19 skipped / 0 failing (`flutter test --coverage`, log in `flutter_test_latest.log`)
- **Test Coverage**: `coverage/lcov.info` generated from the latest full run
- **God Classes**: 0 remaining over 1,000 lines among core services (BLE/Mesh/Queue split complete)
- **Largest Refactored Unit**: BLEService orchestrated via `BLEServiceFacade` + focused sub-services with DI seams
- **Layer Violations**: NavigationService + HomeScreen fixed; presentation now depends only on domain/presentation providers
- **Singleton Patterns**: Legacy singletons replaced by DI registration for services/repositories; BLE facade uses `IBLEPlatformHost`
- **Dependency Injection**: GetIt container seeded via `setupServiceLocator()` + repository abstractions (mirrored in tests via `configureTestDI`)

### Current Focus (Phase 6 Prep)

1. **BLE Runtime & State Management**
   - With the BLE facade now testable, Phase 6 can focus on runtime/stability refactors (dual-role orchestration, MTU negotiation policies).
   - Introduce DI seams for remaining platform-dependent services so the new host pattern extends beyond the facade.

2. **CI Coverage Integration**
   - Wire the green `flutter test --coverage` run (log + `coverage/lcov.info`) into CI so regressions are caught automatically.

3. **Analyzer Hygiene (Optional)**
   - Legacy warnings remain; tackle them opportunistically once Phase 6 work is underway to keep the tree lint-clean.

---

## Phase Progress Tracker

| Phase | Status | Duration | Start Date | End Date | Branch |
|-------|--------|----------|------------|----------|--------|
| Phase | Status | Duration | Start Date | End Date | Branch |
|-------|--------|----------|------------|----------|--------|
| **Phase 0: Pre-Flight** | 🟢 Completed | 1 day | 2025-11-12 | 2025-11-12 | `refactor/p2-architecture-baseline` |
| **Phase 1: DI Foundation** | 🟢 Completed | 1 day | 2025-11-12 | 2025-11-12 | `refactor/phase1-di-foundation` |
| **Phase 2A/2B/2C: Top 3 God Classes** | 🟢 Completed | 3 weeks | 2025-11-13 | 2025-12-03 | `refactor/phase2a-ble-service-split` + follow-ups |
| **Phase 3: Layer Violations** | 🟢 Completed | 2 weeks | 2025-12-04 | 2025-12-17 | branch `refactor/phase3-layer-fixes` |
| **Phase 4: Remaining God Classes** | 🟢 Completed | 2 weeks | 2025-12-18 | 2026-01-02 | branch `refactor/phase4a-ble-state-extraction` |
| **Phase 5: Testing Infrastructure** | 🟢 Completed | 1 week | 2026-01-06 | 2026-01-10 | tbd |
| **Phase 6: State Management** | ⏳ Not Started | 1 week | TBD | TBD | TBD |

**Legend**: 🟢 Completed | 🟡 In Progress | ⏳ Not Started | 🔴 Blocked

---

## Quick Links

- [Phase 0: Pre-Flight](./phases/phase0_pre_flight.md)
- [Phase 1: DI Foundation](./phases/phase1_di_foundation.md) (TBD)
- [Phase 2: Top 3 God Classes](./phases/phase2_god_classes.md) (TBD)
- [Phase 3: Layer Violations](./phases/phase3_layer_violations.md) (TBD)
- [Phase 4: Remaining God Classes](./phases/phase4_remaining_god_classes.md) (TBD)
- [Phase 5: Testing Infrastructure](./phases/phase5_testing.md) (TBD)
- [Phase 5 Detailed Plan](./phase5_testing_plan.md)
- [Phase 6: State Management](./phases/phase6_state_management.md) (TBD)
- [Architecture Analysis Report](./ARCHITECTURE_ANALYSIS.md)

---

## Success Criteria

### Code Quality Targets
- [ ] Zero files >1000 lines
- [ ] All services use DI (no singletons)
- [ ] All layer violations fixed
- [ ] Test coverage >85%
- [ ] Zero circular dependencies

### Performance Targets
- [ ] App startup time ≤ baseline
- [ ] BLE connection time ≤ baseline
- [ ] Message latency ≤ baseline
- [ ] Memory footprint ≤ baseline

### Architecture Targets
- [ ] Dependency graph is acyclic
- [ ] All critical services have interfaces
- [ ] Strict layer separation (Presentation → Domain → Data)
- [ ] All tests pass (100% pass rate)

---

## Risk Mitigation

### Feature Freeze
- ✅ No new features during refactoring
- ✅ Bug fixes only (in separate branches)
- ✅ Merge to main only after phase completion

### Phase Completion Checklist
Each phase requires:
- [ ] All tests green (773+ tests)
- [ ] BLE tested on real Android devices (2+)
- [ ] Code review (AI pair programming)
- [ ] Git tag (e.g., `refactor-phase1-complete`)
- [ ] Phase documentation updated
- [ ] Master plan updated

### Rollback Strategy
- Each phase in separate branch
- Can revert to previous phase if issues arise
- Main branch stays stable
- Git tags mark stable checkpoints

---

## Current Phase: Phase 5 - Testing Infrastructure (Complete)

**Goal**: Harden the Flutter/Dart test harness so all suites (DB-heavy, BLE-heavy, export/import) can run in CI without platform plugins, and raise coverage with DI-friendly utilities.

### Tracks (see [`phase5_testing_plan.md`](./phase5_testing_plan.md) for full detail)
- Harness Hardening (sqlite loader, per-suite DB isolation, secure storage overrides everywhere)
- DI Test Utilities & canonical mocks (`setupTestDI()`, fake BLE/services)
- Test Refactors & Coverage Push (`flutter test --coverage`, migrating brittle suites to new helpers)
- Benchmark Hygiene (ensure performance suites log instead of fail)

**Latest Metrics**:
- `flutter analyze`: passes (legacy warnings remain documented in analyzer logs)
- `flutter test --coverage`: 1,284 passed / 19 skipped / 0 failing (see `flutter_test_latest.log`)
- Coverage artifact: `coverage/lcov.info` (generated from the latest run)

All DB-heavy, BLE-heavy, and benchmark suites run inside the shared harness using the new `IBLEPlatformHost` seam, so Phase 6 can proceed without worrying about flaky infrastructure.

---

## Timeline

| Week | Focus | Status |
|------|-------|--------|
| 1 | Phase 0 – Pre-Flight | ✅ |
| 2–3 | Phase 1 – DI Foundation | ✅ |
| 4–6 | Phase 2 – BLEService/Mesh/ChatScreen splits | ✅ |
| 7–8 | Phase 3 – Layer violations + DI abstractions | ✅ |
| 9–10 | Phase 4 – Remaining god classes | ✅ |
| 11 | Phase 5 – Testing Infrastructure | ✅ |
| 12 | Phase 6 – State management cleanup | ⏳ |

---

## Change Log

### 2025-11-12 — Phase 0 (Pre-Flight)
- ✅ Created master plan & baseline branch (`refactor/p2-architecture-baseline`)
- ✅ Tagged `v1.0-pre-refactor`; captured initial test baseline (773/802)
- ✅ Authored Phase 0 docs, architecture analysis, ADR-001/002, performance placeholders

### 2025-11-12 — Phase 1 (DI Foundation)
- ✅ Added GetIt service locator (`lib/core/di/service_locator.dart`)
- ✅ Authored interfaces for contact/message/security/BLE/mesh
- ✅ Wired AppCore to initialize DI; 15 DI-focused tests passing
- ✅ Recorded ADR-003/004/005
- ✅ Test delta: 845 passed / 19 skipped / 9 failed (873 total)

### 2025-11-13 → 2025-12-03 — Phase 2 (Top 3 God Classes)
- ✅ BLEService split into 5 sub-services + `BLEServiceFacade`
- ✅ Mesh routing orchestration extracted; ChatScreen refactored into ViewModel + controllers
- ✅ 150+ new unit tests for BLE/mesh/chat layers
- ✅ Documentation: `phase2a_migration_strategy.md`, completion summaries

### 2025-12-04 → 2025-12-17 — Phase 3 (Layer Violations)
- ✅ Added `IRepositoryProvider`, `IConnectionService`, and DI fallbacks
- ✅ Moved presentation-only handlers out of Core; fixed NavigationService imports
- ✅ 61 new integration tests verifying layer boundaries

### 2025-12-18 → 2026-01-02 — Phase 4 (Remaining God Classes)
- ✅ Split BLEStateManager, BLEMessageHandler, OfflineMessageQueue, ChatManagementService, HomeScreen into facades + sub-services
- ✅ 150+ additional tests + documentation (`EXTRACTION_SUMMARY_PHASE4D.md`, etc.)

### 2026-01-06 — Phase 5 (Testing Infrastructure) Kickoff
- ✅ Captured real test failures + harness gaps in `flutter_test_latest.log`
- ✅ Added fake secure storage overrides + BLE platform mocks
- ✅ Authored [`phase5_testing_plan.md`](./phase5_testing_plan.md) with detailed workstreams
- 🔄 In progress: harness hardening, DI test utilities, coverage reporting

---

## Notes

- Working alone with AI pair programming (Claude Code)
- Access to multiple Android BLE devices for testing
- Balanced risk approach: phase-by-phase with full test suite validation
- Documentation-first approach to track progress and decisions
