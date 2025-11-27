# Phase 6: ChatScreen & StreamController Refactoring Plan

## Executive Summary

**Status**: Codex assessment CONFIRMED via code audit
- ChatScreen migration: 33% complete (564/1,693 LOC extracted)
- StreamController usage: 147 occurrences across 33 files (high)

**Goal**: Complete ChatScreen ViewModel/Lifecycle extraction + reduce StreamController usage to <10 justified instances

**Estimated Duration**: 6 phases, ~12-15 hours total work

---

## Phase 6A: ChatScreen Migration - ViewModel Extraction

### Objective
Move pure state mutations and UI helpers from ChatScreenController → ChatSessionViewModel

### Measurable Success Criteria
- [ ] ChatSessionViewModel reaches 300-400 LOC (from current 143 LOC)
- [ ] ChatScreenController reduces to <900 LOC (from 1,129 LOC)
- [ ] 15+ ViewModel unit tests covering send/retry/delete/scroll/search
- [ ] `flutter analyze` shows 0 errors
- [ ] Existing tests remain passing (no regressions)

### Work Breakdown (4-5 hours)

#### M1: Identify Controller Logic to Extract (1 hour)
**Codex Task**: Audit `chat_screen_controller.dart` against `chat_session_view_model.dart`
- Generate checklist of methods still in controller that should be in ViewModel
- Categorize: state mutations, UI helpers, business logic, infrastructure
- Output: Markdown checklist with LOC estimates per method

**Deliverable**: `phase6a-extraction-checklist.md`

**Oversight Checkpoint**: Claude reviews checklist for completeness before proceeding

#### M2: Extract Send/Retry/Delete Logic (1.5 hours)
**Codex Task**: Move send/retry/delete business logic to ViewModel
- Methods to extract:
  - `sendMessage()` → ViewModel.sendMessage()
  - `retryFailedMessages()` → ViewModel.retryMessage()
  - `deleteMessage()` → ViewModel.deleteMessage()
  - `_autoRetryFailedMessages()` → ViewModel.autoRetryFailed()
  - `_retryRepositoryMessage()` → ViewModel.retryFromRepository()
- Controller becomes thin delegator
- Add 6+ ViewModel tests for send/retry/delete flows

**Deliverable**: Updated ViewModel + tests, controller delegates only

**Oversight Checkpoint**:
- Claude runs `flutter test` to confirm no regressions
- Claude reviews diff to ensure no business logic remains in controller

#### M3: Extract Scroll/Search Plumbing (1 hour)
**Codex Task**: Move scroll intent and search toggle to ViewModel
- Methods to extract:
  - `scrollToBottom()` → ViewModel.requestScrollToBottom()
  - `toggleSearchMode()` → ViewModel.toggleSearch()
  - `_onSearch()` → ViewModel.updateSearchQuery()
  - `_navigateToSearchResult()` → ViewModel.navigateToResult()
- Add 4+ ViewModel tests for scroll/search state transitions

**Deliverable**: Updated ViewModel + tests

**Oversight Checkpoint**: Claude verifies scroll behavior matches original

#### M4: Extract Unread Separator Logic (0.5 hours)
**Codex Task**: Move unread separator state management to ViewModel
- Extract `_syncScrollState()` unread logic
- Add 3+ ViewModel tests for unread separator timing

**Deliverable**: Updated ViewModel + tests

**Oversight Checkpoint**: Claude confirms separator behavior unchanged

#### M5: Validation & Commit (1 hour)
**Claude Task**: Full validation sweep
- Run `flutter analyze` (expect 0 errors)
- Run `flutter test` (all existing tests passing)
- Run targeted ChatScreen widget tests
- Review final LOC counts:
  - ChatSessionViewModel: 300-400 LOC ✅
  - ChatScreenController: <900 LOC ✅
- Git commit: "refactor(Phase 6A): Extract ViewModel business logic from ChatScreenController"

---

## Phase 6B: ChatScreen Migration - Lifecycle Extraction

### Objective
Move subscriptions/timers/buffers from ChatScreenController → ChatSessionLifecycle

### Measurable Success Criteria
- [ ] ChatSessionLifecycle reaches 600-700 LOC (from current 421 LOC)
- [ ] ChatScreenController reduces to <600 LOC (from <900 LOC after 6A)
- [ ] 10+ Lifecycle tests with fakes covering delivery/retry/mesh/pairing hooks
- [ ] `flutter analyze` shows 0 errors
- [ ] Existing tests remain passing

### Work Breakdown (3-4 hours)

#### M1: Identify Subscription/Timer Logic (0.5 hours)
**Codex Task**: Audit controller for lifecycle-related code
- Identify subscriptions, timers, buffers still in controller
- Generate extraction checklist

**Deliverable**: `phase6b-lifecycle-checklist.md`

**Oversight Checkpoint**: Claude reviews checklist

#### M2: Extract Delivery Subscription Wiring (1 hour)
**Codex Task**: Move delivery listener setup to Lifecycle
- Extract `_setupDeliveryListener()` → Lifecycle.setupDeliveryListener()
- Extract `_updateMessageStatus()` → Lifecycle.handleDeliveryUpdate()
- Add 3+ Lifecycle tests with fake delivery streams

**Deliverable**: Updated Lifecycle + tests

**Oversight Checkpoint**: Claude verifies delivery updates work correctly

#### M3: Extract Retry Wiring (1 hour)
**Codex Task**: Move retry coordination to Lifecycle
- Extract retry timer management
- Extract `_fallbackRetryFailedMessages()` → Lifecycle
- Add 3+ Lifecycle tests for retry flows

**Deliverable**: Updated Lifecycle + tests

**Oversight Checkpoint**: Claude confirms retry behavior unchanged

#### M4: Extract Mesh/Pairing Hooks (1 hour)
**Codex Task**: Move mesh and pairing listeners to Lifecycle
- Extract `_setupMeshNetworking()` → Lifecycle
- Extract `_setupSecurityStateListener()` → Lifecycle
- Extract `_setupContactRequestListener()` → Lifecycle
- Add 4+ Lifecycle tests with fake mesh/pairing streams

**Deliverable**: Updated Lifecycle + tests

**Oversight Checkpoint**: Claude verifies mesh/pairing hooks work

#### M5: Validation & Commit (0.5 hours)
**Claude Task**: Validation sweep + commit
- LOC verification:
  - ChatSessionLifecycle: 600-700 LOC ✅
  - ChatScreenController: <600 LOC ✅
- Git commit: "refactor(Phase 6B): Extract Lifecycle subscriptions from ChatScreenController"

---

## Phase 6C: ChatScreen Migration - Provider Flip

### Objective
Flip ChatScreen widget to consume provider state/actions directly (deprecate ChangeNotifier)

### Measurable Success Criteria
- [ ] ChatScreen widget consumes `chatSessionViewModelProvider` and `chatSessionLifecycleProvider`
- [ ] Controller becomes thin facade shim (keep for legacy compatibility)
- [ ] ChatScreenController reduces to <300 LOC (just provider delegation)
- [ ] 8+ provider integration tests for send/retry/search/reconnect
- [ ] `flutter test` shows all tests passing

### Work Breakdown (2-3 hours)

#### M1: Create Riverpod Providers (0.5 hours)
**Codex Task**: Define providers for ViewModel and Lifecycle
- Create `chatSessionViewModelProvider` (family by chatId)
- Create `chatSessionLifecycleProvider` (family by chatId)
- Wire up dependencies (repositories, services)

**Deliverable**: Provider definitions in `lib/presentation/providers/chat_session_providers.dart`

**Oversight Checkpoint**: Claude reviews provider structure

#### M2: Update ChatScreen Widget (1.5 hours)
**Codex Task**: Refactor ChatScreen to use providers
- Replace controller method calls with provider actions
- Replace controller state reads with provider state consumption
- Keep controller facade as thin shim for legacy constructors
- Ensure widget tree remains unchanged (UI parity)

**Deliverable**: Updated ChatScreen widget

**Oversight Checkpoint**:
- Claude runs app to verify UI unchanged
- Claude runs widget tests to confirm behavior parity

#### M3: Add Provider Integration Tests (0.5 hours)
**Codex Task**: Write integration tests for provider flows
- Test: Send message via provider
- Test: Retry message via provider
- Test: Search toggle via provider
- Test: Manual reconnection via provider
- Test: Delivery update propagates to UI

**Deliverable**: 8+ provider integration tests

**Oversight Checkpoint**: Claude confirms all tests passing

#### M4: Deprecate ChangeNotifier Fields (0.5 hours)
**Codex Task**: Clean up controller redundant state
- Mark old ChangeNotifier fields as @deprecated
- Remove state duplication in controller
- Ensure controller is thin wrapper only (<300 LOC)

**Deliverable**: Cleaned controller + deprecation notices

**Oversight Checkpoint**: Claude confirms LOC target met

#### M5: Validation & Commit (0.5 hours)
**Claude Task**: Final validation + commit
- Run `flutter analyze` (0 errors)
- Run `flutter test` (all passing)
- Run manual UI test (send/retry/search work)
- LOC verification:
  - ChatScreenController: <300 LOC ✅
  - ChatScreen widget: Provider-based ✅
- Git commit: "refactor(Phase 6C): Flip ChatScreen to Riverpod providers"

---

## Phase 6D: StreamController Audit - Inventory & Analysis

### Objective
Inventory high-count StreamController files and categorize replacement strategy

### Measurable Success Criteria
- [ ] All 33 files with StreamController inventoried
- [ ] Each file categorized: "Replace with Provider" / "Replace with Bus" / "Keep (justified)"
- [ ] Replacement plan document created with LOC estimates
- [ ] No code changes (audit only)

### Work Breakdown (1-2 hours)

#### M1: Generate StreamController Inventory (0.5 hours)
**Codex Task**: Scan codebase for StreamController usage
- Use `rg "StreamController" --type dart` to find all files
- For each file, extract:
  - File path
  - Number of StreamController instances
  - Controller names
  - Stream purposes (e.g., "connection status", "message delivery")
  - Listener count (how many subscribers)

**Deliverable**: `phase6d-streamcontroller-inventory.csv`

**Oversight Checkpoint**: Claude reviews CSV for completeness

#### M2: Categorize Replacement Strategy (1 hour)
**Codex Task**: Analyze each file and recommend replacement
- For each file, determine:
  - **Category A**: Replace with Riverpod StreamProvider/StateNotifier (stateful, UI-bound)
  - **Category B**: Replace with shared event bus (cross-service events)
  - **Category C**: Keep StreamController (justified: platform channel bridge, hot-reload required)
- Estimate LOC for replacement
- Identify duplicate streams (e.g., BLE facade duplications)

**Deliverable**: `phase6d-replacement-plan.md` with categorization + LOC estimates

**Oversight Checkpoint**: Claude reviews plan and validates categorization logic

#### M3: Identify Quick Wins (0.5 hours)
**Codex Task**: Find low-hanging fruit for immediate reduction
- Identify files with duplicate controllers (can consolidate)
- Identify files with unused controllers (can delete)
- Identify files where disposal is missing (add cleanup)

**Deliverable**: Section in `phase6d-replacement-plan.md` with quick win list

**Oversight Checkpoint**: Claude approves quick win targets

---

## Phase 6E: StreamController Reduction - High-Count Files

### Objective
Replace/consolidate StreamControllers in top 5 offender files

### Measurable Success Criteria
- [ ] `ble_service_facade.dart`: Reduce from 11 → <3 controllers
- [ ] `mesh_network_health_monitor.dart`: Reduce from 8 → <2 controllers
- [ ] `user_preferences.dart`: Reduce from 6 → <2 controllers
- [ ] `topology_manager.dart`: Reduce from 6 → <2 controllers
- [ ] `ble_handshake_service.dart`: Reduce from 5 → <2 controllers
- [ ] Total StreamController occurrences: Reduce from 147 → <50
- [ ] All affected tests passing

### Work Breakdown (4-5 hours)

#### M1: BLE Service Facade Reduction (1.5 hours)
**Codex Task**: Consolidate duplicate streams in BLE facade
- Audit 11 controllers to identify duplicates
- Replace broadcast controllers with Riverpod providers where appropriate
- Keep controllers only for platform channel bridges
- Add targeted tests to ensure emissions work

**Deliverable**: Updated facade with <3 controllers + tests

**Oversight Checkpoint**:
- Claude runs BLE tests to confirm no regressions
- Claude verifies controller count reduction

#### M2: Mesh Health Monitor Reduction (1 hour)
**Codex Task**: Replace health monitor streams with Riverpod
- Convert 8 health metric streams to StateNotifiers
- Use Riverpod AsyncValue for async health checks
- Remove redundant StreamControllers

**Deliverable**: Updated health monitor with <2 controllers + tests

**Oversight Checkpoint**: Claude confirms mesh health metrics still work

#### M3: User Preferences Reduction (0.5 hours)
**Codex Task**: Replace preference streams with Riverpod StateNotifier
- Convert 6 preference streams to single StateNotifier
- Use shared preference notifier pattern

**Deliverable**: Updated user_preferences with <2 controllers + tests

**Oversight Checkpoint**: Claude verifies preference updates propagate

#### M4: Topology Manager Reduction (1 hour)
**Codex Task**: Replace topology streams with Riverpod
- Convert 6 topology streams to StateNotifiers
- Consolidate duplicate topology change notifications

**Deliverable**: Updated topology_manager with <2 controllers + tests

**Oversight Checkpoint**: Claude confirms topology updates work

#### M5: BLE Handshake Service Reduction (0.5 hours)
**Codex Task**: Consolidate handshake streams
- Merge 5 handshake streams into 2 (state + events)
- Use Riverpod for handshake state management

**Deliverable**: Updated ble_handshake_service with <2 controllers + tests

**Oversight Checkpoint**: Claude verifies handshake flows work

#### M6: Validation & Commit (1 hour)
**Claude Task**: Full validation sweep
- Run `rg "StreamController" --type dart | wc -l` (expect <50)
- Run `flutter analyze` (0 errors)
- Run `flutter test` (all passing)
- Run manual BLE + mesh tests
- Git commit: "refactor(Phase 6E): Reduce StreamController usage in top 5 files"

---

## Phase 6F: StreamController Reduction - Sweep Remaining Files

### Objective
Sweep remaining 28 files to consolidate/remove unnecessary StreamControllers

### Measurable Success Criteria
- [ ] Total StreamController occurrences: <20 (from <50 after 6E)
- [ ] All retained controllers have justification comments
- [ ] Disposal logic verified via DI lifecycle
- [ ] All tests passing

### Work Breakdown (2-3 hours)

#### M1: Quick Win Sweep (1 hour)
**Codex Task**: Remove unused/duplicate controllers from identified quick wins
- Process each quick win from Phase 6D M3
- Delete unused controllers
- Add disposal logic where missing

**Deliverable**: Updated files with controllers removed

**Oversight Checkpoint**: Claude confirms deletions are safe

#### M2: Consolidate Event Bus Candidates (1 hour)
**Codex Task**: Replace cross-service StreamControllers with shared event bus
- Identify streams used for cross-service communication
- Replace with MessageBus or existing event infrastructure
- Update subscribers to use bus

**Deliverable**: Updated files using event bus

**Oversight Checkpoint**: Claude verifies event propagation works

#### M3: Document Retained Controllers (0.5 hours)
**Codex Task**: Add justification comments to remaining controllers
- For each retained StreamController, add comment explaining why it's needed
- Verify disposal logic in place
- Expected: ~10-15 retained controllers (platform channels, hot-reload bridges)

**Deliverable**: Commented code with justifications

**Oversight Checkpoint**: Claude reviews justifications

#### M4: Final Validation & Commit (0.5 hours)
**Claude Task**: Final validation + commit
- Run `rg "StreamController" --type dart | wc -l` (expect <20)
- Run `flutter analyze` (0 errors)
- Run `flutter test` (all passing)
- Git commit: "refactor(Phase 6F): Final StreamController reduction sweep"

---

## Success Metrics Summary

### ChatScreen Migration Completion
| Metric | Before | Target | Validation |
|--------|--------|--------|------------|
| ChatScreenController LOC | 1,129 | <300 | `wc -l chat_screen_controller.dart` |
| ChatSessionViewModel LOC | 143 | 300-400 | `wc -l chat_session_view_model.dart` |
| ChatSessionLifecycle LOC | 421 | 600-700 | `wc -l chat_session_lifecycle.dart` |
| Provider-based ChatScreen | No | Yes | Code inspection |
| ViewModel unit tests | 0 | 15+ | `flutter test` count |
| Lifecycle unit tests | 0 | 10+ | `flutter test` count |
| Provider integration tests | 0 | 8+ | `flutter test` count |

### StreamController Reduction
| Metric | Before | Target | Validation |
|--------|--------|--------|------------|
| Total StreamController occurrences | 147 | <20 | `rg "StreamController" \| wc -l` |
| Files with StreamController | 33 | <15 | `rg "StreamController" -c \| wc -l` |
| BLE facade controllers | 11 | <3 | File inspection |
| Mesh health controllers | 8 | <2 | File inspection |
| User prefs controllers | 6 | <2 | File inspection |
| Topology controllers | 6 | <2 | File inspection |
| Handshake controllers | 5 | <2 | File inspection |

### Quality Gates (All Phases)
- [ ] `flutter analyze` produces 0 errors at each phase
- [ ] `flutter test` passes all tests at each phase
- [ ] No regressions in BLE functionality (manual test)
- [ ] No regressions in mesh functionality (manual test)
- [ ] No regressions in chat send/receive (manual test)

---

## Codex Oversight Protocol

### Before Each Phase
1. **Claude reviews previous phase commit** to ensure no regressions
2. **Claude reads phase objectives** to Codex as clear instructions
3. **Claude provides Codex with file list** and LOC targets
4. **Codex works autonomously** on the phase tasks

### During Phase (Checkpoints)
1. **After each milestone**: Codex reports completion + provides diff summary
2. **Claude reviews diff**: Checks for anti-patterns, regressions, scope creep
3. **Claude runs validation**: `flutter analyze`, targeted tests
4. **If issues found**: Claude provides feedback, Codex fixes, repeat checkpoint
5. **If checkpoint passes**: Codex proceeds to next milestone

### After Each Phase
1. **Claude runs full test suite**: `flutter test --coverage`
2. **Claude validates metrics**: LOC counts, StreamController counts
3. **Claude reviews git diff**: Entire phase changes reviewed for quality
4. **If phase passes**: Git commit, move to next phase
5. **If phase fails**: Codex reverts changes, re-attempts with corrected approach

### Failure Recovery Protocol
- If Codex breaks critical functionality: **Immediate git revert** + Claude debugging session
- If Codex misunderstands task: Claude re-explains with concrete examples + Codex retries
- If Codex produces low-quality code: Claude provides code review feedback + Codex refactors
- If stuck >30 minutes: Claude takes over that specific task, Codex continues on other tasks

---

## Timeline Estimate

| Phase | Duration | Codex Work | Claude Oversight | Total |
|-------|----------|------------|------------------|-------|
| 6A: ViewModel Extraction | 4-5h | 3.5h | 1h | 4.5h |
| 6B: Lifecycle Extraction | 3-4h | 3h | 0.5h | 3.5h |
| 6C: Provider Flip | 2-3h | 2h | 0.5h | 2.5h |
| 6D: StreamController Audit | 1-2h | 1.5h | 0.5h | 2h |
| 6E: High-Count Reduction | 4-5h | 4h | 1h | 5h |
| 6F: Remaining Sweep | 2-3h | 2h | 0.5h | 2.5h |
| **Total** | **16-22h** | **16h** | **4h** | **20h** |

**Realistic completion**: 3-4 working days with proper oversight

---

## Git Branch Strategy

- **Branch**: `phase-6-critical-refactoring` (current)
- **Commit frequency**: After each phase (6A, 6B, 6C, 6D, 6E, 6F)
- **Commit message format**: `refactor(Phase 6X): <phase name>`
- **PR creation**: After Phase 6F completion
- **PR target**: `main` branch

---

## Risk Mitigation

### Risk 1: Codex breaks ChatScreen functionality
- **Mitigation**: Checkpoint after each milestone, Claude runs manual tests
- **Recovery**: Git revert to last checkpoint, Claude reviews diff

### Risk 2: StreamController reduction breaks BLE/mesh
- **Mitigation**: Keep integration tests running, manual BLE tests after each phase
- **Recovery**: Revert to provider-based approach if event bus fails

### Risk 3: LOC targets not met (controller still too large)
- **Mitigation**: Re-audit controller after each phase, identify missed extractions
- **Recovery**: Add Phase 6G if needed to finish extraction

### Risk 4: Test suite fails after refactoring
- **Mitigation**: Run tests after each milestone, fix immediately
- **Recovery**: Pause Codex work, Claude fixes tests before proceeding

---

## Next Steps

1. **Claude**: Review this plan with user for approval
2. **User**: Approve plan or request changes
3. **Claude**: Activate Phase 6A, delegate first milestone (M1) to Codex
4. **Codex**: Execute Phase 6A M1 (ChatScreen audit + checklist)
5. **Claude**: Review checklist at checkpoint, approve or provide feedback
6. **Repeat**: Milestone by milestone, phase by phase, with oversight

---

**Status**: READY FOR EXECUTION
**Plan Confidence**: 95% (based on code audit + Codex guidance)
**Expected Completion**: 3-4 working days
