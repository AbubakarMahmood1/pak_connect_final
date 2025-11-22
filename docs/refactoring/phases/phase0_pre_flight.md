# Phase 0: Pre-Flight

**Status**: ✅ Complete (perf baseline deferred to device pass)
**Duration**: 1 week (5 days)
**Started**: 2025-11-12
**Branch**: `phase-6-critical-refactoring`

> _Note_: The original snapshot branch `refactor/p2-architecture-baseline` was merged and deleted after the initial handoff, so all Phase 0 artifacts now live on `phase-6-critical-refactoring`.

---

## Objectives

1. Establish baseline metrics before any refactoring
2. Create safety nets (tests, tags, documentation)
3. Set up tooling and dependencies
4. Document current state for comparison

---

## Tasks Checklist

### Baseline Creation
- [x] Tag current commit as `v1.0-pre-refactor`
- [x] Run full test suite and document results

_Retired deliverable_: The temporary snapshot branch `refactor/p2-architecture-baseline` was merged and deleted during the Phase 0 handoff, so this requirement no longer applies.

### Documentation
- [x] Create master plan document
- [x] Create phase 0 documentation
- [x] Create Architecture Decision Record (ADR)
- [x] Create architecture analysis report _(see `docs/refactoring/ARCHITECTURE_ANALYSIS.md`)_

### Metrics Collection
- [x] Document test pass rate
- [x] Run test coverage report (`flutter test --coverage` ⇒ `coverage/lcov.info`)
- [x] Document performance baseline (startup time, BLE connection, memory)
  - Status: deferred to real-device pass; host benchmarks recorded in `docs/refactoring/PERFORMANCE_BASELINE.md`
- [x] Count God classes and architectural violations

### Dependencies
- [x] Add `get_it: ^7.6.0` to pubspec.yaml (see `pubspec.yaml:73`)
- [x] Add `mockito: ^5.4.0` to pubspec.yaml (`dev_dependencies`)
- [x] Add `build_runner: ^2.4.0` to pubspec.yaml (`dev_dependencies`)
- [x] Run `flutter pub get` (`pubspec.lock` present)

---

## Baseline Metrics

### Test Results (2025-11-19)

**Command**: `flutter test --coverage`
**Duration**: ~120 seconds on host

```
Total Tests: 1,325
✅ Passed: 1,325 (100%)
⏭️ Skipped: 0
❌ Failed: 0
```

**Notes**:
- Hardened harness: secure storage + SQLite shims allow full suite to pass on host.
- CI uses the same harness; see `flutter_test_latest.log` and `coverage/lcov.info`.

### Code Metrics

**God Classes (>500 lines)**:
- Total: 38 files
- Critical (>1500 lines): 9 files

**Top 5 God Classes (current reality)**:
1. BLEStateManager: 2,328 lines (`lib/data/services/ble_state_manager.dart`)
2. BLEMessageHandler: 1,891 lines (`lib/data/services/ble_message_handler.dart`)
3. DiscoveryOverlay: 1,866 lines (`lib/presentation/widgets/discovery_overlay.dart`)
4. OfflineMessageQueue: 1,778 lines (`lib/core/messaging/offline_message_queue.dart`)
5. SettingsScreen: 1,748 lines (`lib/presentation/screens/settings_screen.dart`)

**Architecture Violations**:
- Singleton patterns: 95 instances
- Direct instantiation: 124 instances
- GetIt usage: 0 instances
- Layer violations: 3 major violations

### Test Coverage

**Status**: Captured (2025-11-19 run)
**Command**: `flutter test --coverage`
**Artifacts**: `coverage/lcov.info`, `flutter_test_latest.log`

```
Lines covered: 9,046
Lines found: 32,924
Line coverage: 27.48%
```

Numbers computed from `coverage/lcov.info` and tracked for comparison after the refactor.

### Performance Baseline

**Status**: Deferred to real-device pass (not blocking). Host benchmarks recorded.

- Real-device metrics will be captured per `docs/refactoring/PERFORMANCE_BASELINE.md` when hardware is available.
- Interim host benchmarks (from `test/performance_getAllChats_benchmark_test.dart` in `flutter_test_latest.log`):
  - getAllChats × 10 contacts × 10 messages: 12 ms total (1.2 ms/chat)
  - getAllChats × 50 contacts × 10 messages: 5 ms total (0.1 ms/chat)
  - getAllChats × 100 contacts × 10 messages: 5 ms total (0.1 ms/chat)

---

## Architecture Decision Record (ADR)

### ADR-001: Adopt Dependency Injection with GetIt

**Status**: Proposed
**Date**: 2025-11-12
**Decision Makers**: Solo developer

**Context**:
- Current codebase has 95 singleton patterns
- 124 instances of direct instantiation
- Zero use of dependency injection framework
- Testing requires mocking concrete classes (difficult)
- Circular dependencies between services

**Decision**:
We will adopt GetIt as the service locator/DI framework for PakConnect.

**Rationale**:
1. **Testability**: Allows injecting mock implementations
2. **Decoupling**: Services depend on interfaces, not concrete classes
3. **Flexibility**: Easy to swap implementations (e.g., BLE vs mock)
4. **Industry Standard**: GetIt is widely used in Flutter ecosystem
5. **Minimal Overhead**: Service locator pattern is lightweight

**Alternatives Considered**:
1. **Provider/Riverpod DI**: Already using Riverpod for state, would mix concerns
2. **Injectable**: More powerful but adds code generation complexity
3. **Manual DI**: Passing dependencies through constructors (too verbose)

**Consequences**:
- ✅ Better testability
- ✅ Clear dependency graph
- ✅ Easier to mock for tests
- ⚠️ Learning curve for GetIt patterns
- ⚠️ Refactoring effort: ~56 files

**Implementation Plan**: See Phase 1 documentation

---

### ADR-002: Adopt Balanced Risk Refactoring Strategy

**Status**: Accepted
**Date**: 2025-11-12

**Context**:
- 773 existing tests must continue passing
- BLE functionality requires real device testing
- Solo developer with limited time
- High regression risk (56 files, 170 tests affected)

**Decision**:
Use phase-by-phase refactoring with full test suite validation at each checkpoint.

**Rationale**:
1. **Safety**: Each phase verified before proceeding
2. **Rollback**: Easy to revert to last stable checkpoint
3. **Progress**: Incremental improvements visible
4. **Risk Management**: Catch regressions early

**Rejected Alternatives**:
1. **Big-bang refactoring**: Too risky, would break tests
2. **Feature flags**: Adds complexity, not worth it for internal refactoring

**Consequences**:
- ✅ Lower regression risk
- ✅ Clear checkpoints
- ⚠️ Slower overall progress (but safer)

---

## Dependencies to Add

### get_it: ^7.6.0
**Purpose**: Service locator / dependency injection
**Usage**: Register all services, repositories, managers
**Migration**: Phase 1

### mockito: ^5.4.0
**Purpose**: Mock generation for testing
**Current**: Already in dev_dependencies (5.5.0)
**Action**: Update to latest 5.4.0 stable

### build_runner: ^2.4.0
**Purpose**: Code generation for mocks
**Current**: Already in dev_dependencies (2.7.1)
**Action**: No change needed (already compatible)

---

## Known Issues

### Test Failures
1. **database_v10_seen_messages_test.dart** (10 failures)
   - Root cause: SQLite FFI library not found
   - Fix: Install libsqlite3 or use in-memory database for tests
   - Priority: Low (will fix in Phase 5)

### Skipped Tests
- 19 tests skipped (mesh relay tests with timeout issues)
- Known flaky tests from previous work
- Will be stabilized in Phase 5

---

## Success Criteria

Phase 0 is complete when:
- [x] Baseline branch created and tagged
- [x] Full test suite run and documented
- [ ] Test coverage report generated
- [ ] ADR document created
- [ ] Architecture analysis complete
- [ ] Dependencies added
- [ ] Performance baseline documented
- [ ] Master plan document finalized

---

## Next Steps

After Phase 0 completion:
1. Create Phase 1 branch: `refactor/phase1-di-foundation`
2. Begin implementing DI with GetIt
3. Create service interfaces
4. Update AppCore initialization

**See**: [Phase 1: DI Foundation](./phase1_di_foundation.md) (TBD)

---

## Notes

- Test baseline saved to `test_baseline.log`
- All 773 passing tests must remain green throughout refactoring
- 10 failed tests are known issue (SQLite FFI), not regression
- Git tag `v1.0-pre-refactor` marks safe rollback point
