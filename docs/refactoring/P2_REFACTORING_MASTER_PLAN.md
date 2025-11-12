# P2 Architecture Refactoring - Master Plan

**Status**: Phase 0 - Pre-Flight (In Progress)
**Started**: 2025-11-12
**Target Completion**: 2025-02-04 (12 weeks)
**Current Branch**: `refactor/p2-architecture-baseline`

---

## Executive Summary

**Scope**: Refactor 56 files, update/create 170 tests
**Timeline**: 12 weeks (solo developer + AI pair programming)
**Approach**: Balanced risk (phase-by-phase with full test validation)
**Risk Level**: HIGH

### Baseline Metrics (2025-11-12)

- **Git Tag**: `v1.0-pre-refactor`
- **Test Results**: 773 passed, 19 skipped, 10 failed (802 total)
- **Test Coverage**: TBD (running coverage report next)
- **God Classes**: 57 files >500 lines, 15 files >1500 lines
- **Largest File**: BLEService (3,431 lines)
- **Architecture Violations**: 3 major layer violations identified
- **Singleton Patterns**: 95 instances
- **Dependency Injection**: 0 (none - all direct instantiation)

### Critical Issues Identified

1. **BLEService God Class** (3,431 lines)
   - 15+ responsibilities
   - 9 direct dependents
   - No interfaces (untestable without real BLE)

2. **Layer Violations**
   - Domain → Data: MeshNetworkingService imports BLEService
   - Core → Presentation: NavigationService imports screens

3. **Circular Dependencies**
   - BLEService ↔ MeshNetworkingService
   - BLEService ↔ BLEStateManager ↔ BLEMessageHandler

4. **No DI Framework**
   - GetIt: 0 usages
   - Direct instantiation: 124 instances
   - Singleton pattern: 95 instances

---

## Phase Progress Tracker

| Phase | Status | Duration | Start Date | End Date | Branch |
|-------|--------|----------|------------|----------|--------|
| **Phase 0: Pre-Flight** | 🟡 In Progress | 1 week | 2025-11-12 | TBD | `refactor/p2-architecture-baseline` |
| **Phase 1: DI Foundation** | ⏳ Not Started | 2 weeks | TBD | TBD | TBD |
| **Phase 2: Top 3 God Classes** | ⏳ Not Started | 3 weeks | TBD | TBD | TBD |
| **Phase 3: Layer Violations** | ⏳ Not Started | 2 weeks | TBD | TBD | TBD |
| **Phase 4: Remaining God Classes** | ⏳ Not Started | 2 weeks | TBD | TBD | TBD |
| **Phase 5: Testing Infrastructure** | ⏳ Not Started | 1 week | TBD | TBD | TBD |
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

## Current Phase: Phase 0 - Pre-Flight

**Goal**: Set up safety nets BEFORE touching production code

### Tasks
- [x] Create baseline branch and tag (`v1.0-pre-refactor`)
- [x] Run full test suite (773 passed, 19 skipped, 10 failed)
- [ ] Create ADR document
- [ ] Run test coverage report
- [ ] Add dependencies (get_it, mockito, build_runner)
- [ ] Document performance metrics

**See**: [Phase 0 Detailed Documentation](./phases/phase0_pre_flight.md)

---

## Timeline

**Week 1**: Phase 0 - Pre-Flight
**Weeks 2-3**: Phase 1 - DI Foundation
**Weeks 4-6**: Phase 2 - Top 3 God Classes (BLEService, MeshNetworkingService, ChatScreen)
**Weeks 7-8**: Phase 3 - Layer Violations
**Weeks 9-10**: Phase 4 - Remaining God Classes
**Week 11**: Phase 5 - Testing Infrastructure
**Week 12**: Phase 6 - State Management & Cleanup

---

## Change Log

### 2025-11-12 (Phase 0 - Day 1)
- ✅ Created master plan document
- ✅ Established baseline branch `refactor/p2-architecture-baseline`
- ✅ Tagged `v1.0-pre-refactor`
- ✅ Documented test baseline: 773 passed, 19 skipped, 10 failed
- ✅ Created Phase 0 detailed documentation
- ✅ Created comprehensive Architecture Analysis report
- ✅ Added dependencies: get_it ^7.6.0, mockito ^5.4.4
- ✅ Created ADR-001 (Dependency Injection with GetIt)
- ✅ Created ADR-002 (Balanced Risk Refactoring Strategy)
- ✅ Created performance baseline placeholder document
- 🔄 Test coverage report (in progress)
- Started Phase 0: Pre-Flight

---

## Notes

- Working alone with AI pair programming (Claude Code)
- Access to multiple Android BLE devices for testing
- Balanced risk approach: phase-by-phase with full test suite validation
- Documentation-first approach to track progress and decisions
