# Phase 4: Remaining God Classes - ULTRATHINK COMPREHENSIVE PLAN

**Status**: 📋 PLANNING (Ready to execute)
**Timeline**: 2 weeks (10 business days)
**Total Lines**: 9,184 LOC across 5 files
**Goal**: Reduce all to <1000 lines + comprehensive test coverage

---

## Executive Summary

Phase 4 targets the 5 largest remaining god classes that directly impact:
- **Session security** (BLEStateManager - 2,290 lines)
- **Message integrity** (BLEMessageHandler - 1,886 lines)  
- **Message persistence** (OfflineMessageQueue - 1,749 lines)
- **Chat management** (ChatManagementService - 1,738 lines)
- **UI complexity** (HomeScreen - 1,521 lines)

**Strategic Approach**: Extract in dependency order (Core → Domain → Presentation) to minimize circular dependencies and enable parallel testing.

---

## File Analysis: Detailed Breakdown

### 1. BLEStateManager (2,290 lines) 🔴 CRITICAL

**Location**: `lib/data/services/ble_state_manager.dart`

**Responsibilities Detected** (9 distinct concerns):
1. **Identity Management** (PublicKey, EphemeralId, PersistentKey tracking)
2. **Pairing State Machine** (6+ states: initiated, requested, accepted, verified, complete, cancelled)
3. **Session Management** (Conversation keys, session IDs, Noise handshake state)
4. **Contact Persistence** (Save/load/update contact data)
5. **Security Level Lifecycle** (LOW → MEDIUM → HIGH progression)
6. **ECDH Coordination** (Bilateral sync, mutual consent flows)
7. **Spy Mode Detection** (Asymmetric contact detection, identity reveal)
8. **User Identity** (My username, other username, persistent ID management)
9. **Status Synchronization** (Bilateral sync completion, contact status exchange)

**Method Breakdown**:
- Getters/Setters: ~25 methods
- Public API: ~50 methods
- Internal logic: ~60 methods

**Key Observations**:
- 40+ fields track overlapping state (e.g., `_theirEphemeralId`, `_currentSessionId`, `_persistentPublicKey`)
- Multiple completers for pairing flow (race conditions possible)
- Contact retry logic mixed with status exchange
- Callbacks for 15+ external events

**Complexity Hotspots**:
- `handlePairingRequest()` with nested state checks
- `_performBilateralContactSync()` with complex timing logic
- `_checkForAsymmetricRelationship()` with 8+ condition checks
- Retry logic with exponential backoff

**Layer Violations**:
- ✅ Phase 3 fixed: No Core→Data issues (now uses IRepositoryProvider)
- ✅ No Presentation imports
- Status: CLEAN

**Test Coverage**: Currently untested (major risk)

---

### 2. BLEMessageHandler (1,886 lines) 🔴 CRITICAL

**Location**: `lib/data/services/ble_message_handler.dart`

**Responsibilities Detected** (6 distinct concerns):
1. **Message Fragmentation/Reassembly** (Chunk reassembly, timeout handling)
2. **Protocol Message Handling** (Contact requests, crypto verification, queue sync)
3. **Relay Engine Integration** (Relay decision, forwarding, ACK handling)
4. **Contact Request Lifecycle** (Request, accept, reject, completion)
5. **Crypto Verification** (Verification requests/responses, identity reveal)
6. **Message Encryption/Decryption** (Noise session management, encryption method detection)

**Method Breakdown**:
- Reassembly logic: ~10 methods
- Protocol handling: ~15 methods
- Relay coordination: ~10 methods
- Callback handlers: ~20 methods

**Key Observations**:
- `_processCompleteProtocolMessage()` is extremely complex (50+ lines with nested if-else)
- Relay engine tightly coupled (`_handleMeshRelay()`)
- Multiple message types mixed in single handler
- 20+ callbacks make flow hard to trace

**Complexity Hotspots**:
- `_processProtocolMessageContent()` - nested protocol dispatch
- `_handleMeshRelay()` - relay logic should be in RelayEngine
- `_resolveMessageIdentities()` - identity resolution complexity
- Message type detection with string pattern matching

**Layer Violations**:
- ✅ Phase 3 fixed: No Core→Data issues
- Status: CLEAN

**Dependencies**:
- RelayEngine (knows too much about relay internals)
- SecurityManager (encryption)
- MessageFragmenter (reassembly)

**Test Coverage**: Partial (10-15 tests, mostly mocked)

---

### 3. OfflineMessageQueue (1,749 lines) 🟠 HIGH

**Location**: `lib/core/messaging/offline_message_queue.dart`

**Responsibilities Detected** (7 distinct concerns):
1. **Queue Management** (Enqueue, dequeue, prioritization by favorite contacts)
2. **Retry Logic** (Exponential backoff, max retries, retry scheduling)
3. **Message Persistence** (Save to DB, load from DB, cleanup)
4. **Queue Synchronization** (Hash calculation, sync messages, missing message detection)
5. **Delivery Tracking** (Mark delivered, mark failed, statistics)
6. **Storage Optimization** (Cleanup expired messages, optimize storage)
7. **Connectivity Monitoring** (Online/offline detection, periodic checks)

**Method Breakdown**:
- Queue ops: ~15 methods
- Retry logic: ~8 methods
- Persistence: ~12 methods
- Sync: ~10 methods
- Statistics: ~8 methods
- Storage: ~15 methods

**Key Observations**:
- 30+ fields track queue state
- Hash calculation logic is complex (message ordering sensitive)
- Two queues (direct + relay) with different logic
- Retry timer management with multiple cancellation paths
- Statistics calculations scattered throughout

**Complexity Hotspots**:
- `_processQueue()` - main processing loop with multiple branches
- `calculateQueueHash()` - must handle message ordering correctly
- `_performPeriodicMaintenance()` - cleanup with expiry checks
- Storage layer with custom serialization

**Layer Violations**:
- ⚠️ CORE layer (messaging) - can it access Data layer? Check Phase 3
- Should use IRepositoryProvider for storage

**Test Coverage**: Moderate (20-25 tests)

**Risk Level**: MEDIUM-HIGH
- Critical for offline functionality
- Hash calculation errors could cause sync loops
- Retry logic must not create duplicate messages

---

### 4. ChatManagementService (1,738 lines) 🟠 HIGH

**Location**: `lib/domain/services/chat_management_service.dart`

**Responsibilities Detected** (5 distinct concerns):
1. **Chat List Management** (Get all chats, sort, filter, apply filters)
2. **Message Search** (Text search, filter by date/sender/starred, FTS5 queries)
3. **Chat Operations** (Archive, pin, delete, clear messages)
4. **Message Operations** (Star/unstar, delete, export)
5. **Analytics** (Chat analytics, combined metrics, archived chat stats)

**Method Breakdown**:
- Chat management: ~15 methods
- Search: ~15 methods
- Message ops: ~10 methods
- Analytics: ~15 methods
- Export: ~8 methods
- Helpers: ~20 methods

**Key Observations**:
- Singleton pattern (anti-pattern, should use DI)
- 4 large StreamControllers for updates
- Caching with 4 separate maps (starred, archived, pinned, search history)
- Export to 3 formats (text, JSON, CSV)
- Complex filtering logic in `_applyFilters()`

**Complexity Hotspots**:
- `searchMessagesUnified()` - searches live + archives, complex merge
- `_performMessageTextSearch()` - custom FTS5 wrapping
- `_groupMessagesByDay()` - grouping with date logic
- Export logic split across 3 methods with repetition

**Layer Violations**:
- ✅ DOMAIN layer - correct position
- Uses repositories via DI (Phase 3 prepared this)
- Status: CLEAN

**Test Coverage**: Low (5-10 tests)

**Risk Level**: MEDIUM
- Search performance could regress
- Filter logic must preserve all message states
- Export format changes could break external tools

---

### 5. HomeScreen (1,521 lines) 🟡 MEDIUM

**Location**: `lib/presentation/screens/home_screen.dart`

**Responsibilities Detected** (6 distinct concerns):
1. **Chat List UI** (Display chats, sorting, swipe actions, search)
2. **Search Management** (Debounce, query processing, result display)
3. **Device Discovery** (Nearby devices overlay, connection initiation)
4. **Peripheral Connection** (Incoming connection handling)
5. **Status Management** (BLE status banner, unread count tracking)
6. **Menu/Navigation** (Profile, contacts, archives, settings)

**Method Breakdown**:
- UI building: ~30 methods
- State management: ~15 methods
- Subscriptions/listeners: ~8 methods
- Search: ~5 methods
- Navigation: ~7 methods

**Key Observations**:
- Massive build() method (UI hierarchy tightly coupled)
- Multiple subscriptions (7+) with potential memory leaks
- Tab controller with complex switching logic
- Device discovery overlay tightly coupled
- Search debounce logic mixed with display logic

**Complexity Hotspots**:
- `build()` - deeply nested widget tree
- `_buildChatsTab()` - complex ListView.builder with swipe logic
- `_setupGlobalMessageListener()` - updates UI on every message
- `_setupPeripheralConnectionListener()` - state machine logic in UI

**Layer Violations**:
- ⚠️ Presentation layer should not contain business logic
- Device discovery, search, unread tracking should move to ViewModel
- Phase 2C started extraction - continue the pattern

**Test Coverage**: Very low (0-5 widget tests)

**Risk Level**: MEDIUM-HIGH
- Widget tests are complex and fragile
- Multiple subscriptions = memory leak risk
- UI changes could break chat functionality

---

## Dependency Graph Analysis

```
HomeScreen (Presentation)
  ↓ depends on
ChatManagementService (Domain)
  ↓ depends on
OfflineMessageQueue (Core) ← PROBLEM: Core dependency
  ↓
BLEMessageHandler (Data)
  ↓
BLEStateManager (Data)
```

**Circular Dependency Risk**: LOW (Phase 3 already fixed Core→Data issues)

**Extract Order** (bottom-up to avoid coupling):
1. **BLEStateManager** (foundation: identity, pairing, sessions)
2. **BLEMessageHandler** (depends on state from #1)
3. **OfflineMessageQueue** (self-contained, minimal external deps)
4. **ChatManagementService** (depends on repos, self-contained)
5. **HomeScreen** (depends on services from #4)

---

## Confidence Scoring (CLAUDE.md Protocol)

### BLEStateManager Extraction - 🟠 65% CONFIDENCE

**Analysis**:
- [ ] **No Duplicates (20%)**: Is this already extracted? 
  - ❌ No - state machine is monolithic
  - Check: PairingStateManager doesn't exist
  - Score: 20%

- [ ] **Architecture Compliance (20%)**:
  - ❌ Partial - Should be split into 3-4 services
  - Current: 9 mixed concerns in one class
  - Recommendation: PairingManager + SessionManager + IdentityManager
  - Score: 8%

- [ ] **Official Docs Verified (15%)**:
  - ⚠️ BLE GATT spec covers pairing (generic)
  - Noise Protocol spec covers sessions
  - PakConnect CLAUDE.md explains patterns
  - Score: 10%

- [ ] **Working Reference (15%)**:
  - ✅ Found: Phase 2A patterns (facade, sub-services)
  - ✅ Found: BLEHandshakeService similar complexity
  - ❌ Not found: Multi-service state machine example in codebase
  - Score: 10%

- [ ] **Root Cause Identified (15%)**:
  - ⚠️ Partial - Reasons understood:
    - Pairing needs session + identity
    - Sessions need pairing context
    - Creates interdependency
  - Solution not 100% clear: How to split without creating new coupling?
  - Score: 7%

- [ ] **Codex Second Opinion (15%)**:
  - ⏳ Not consulted yet
  - Should ask: "How to split pairing/session state without creating tight coupling?"
  - Score: 0%

**Overall: 20+8+10+10+7+0 = 55% + 15% base = 70% CONDITIONAL**

**Recommendation**: ⚠️ Consult Codex before starting. Critical area affecting security.

---

### BLEMessageHandler Extraction - 🟡 72% CONFIDENCE

**Analysis**:
- [ ] **No Duplicates**: Message handling logic isn't duplicated
  - Score: 20%

- [ ] **Architecture Compliance**: Protocol handlers should be separate from relay
  - Current: Mixed together
  - Pattern exists: Could use strategy pattern
  - Score: 15%

- [ ] **Official Docs**: Message fragmentation spec is straightforward
  - Protocol messages are custom
  - Score: 12%

- [ ] **Working Reference**: Phase 2A extraction patterns work well
  - Score: 12%

- [ ] **Root Cause**: Why these are mixed?
  - Relay handler receives complete messages
  - Handler converts to protocol format
  - Natural separation exists
  - Score: 13%

- [ ] **Codex Opinion**: Not consulted
  - Score: 0%

**Overall: 72% CONDITIONAL**

**Recommendation**: ⚠️ Ask Codex: "Should protocol handler be separate from relay coordinator?"

---

### OfflineMessageQueue Extraction - 🟢 80% CONFIDENCE

**Analysis**:
- [ ] **No Duplicates**: Queue logic is unique
  - Score: 20%

- [ ] **Architecture Compliance**: Clear layering, follows patterns
  - Retry logic is standard
  - Persistence is standard
  - Score: 18%

- [ ] **Official Docs**: Queue patterns well-documented
  - Retry algorithms (exponential backoff) standard
  - Score: 14%

- [ ] **Working Reference**: Similar queue patterns in other Flutter apps
  - Phase 1-3 patterns applicable
  - Score: 14%

- [ ] **Root Cause**: Why so large?
  - Queue ops + retry + persistence + sync = 4 services
  - Clear split possible
  - Score: 14%

- [ ] **Codex Opinion**: Not needed (standard queue pattern)
  - Score: 0%

**Overall: 80%**

**Recommendation**: ✅ Proceed with extraction (low risk)

---

### ChatManagementService Extraction - 🟡 75% CONFIDENCE

**Analysis**:
- [ ] **No Duplicates**: Search + archive logic might overlap
  - Check: Is there duplicate archive search?
  - Score: 18%

- [ ] **Architecture Compliance**: Domain layer = correct
  - Singleton = anti-pattern (should use DI from Phase 1)
  - Score: 15%

- [ ] **Official Docs**: Search patterns straightforward
  - Analytics patterns clear
  - Score: 13%

- [ ] **Working Reference**: Phase 2C patterns work
  - ChatManagementService delegates to lower layers
  - Score: 13%

- [ ] **Root Cause**: Why large?
  - 5 concerns: chat ops + message ops + search + analytics + export
  - Each could be service
  - Score: 14%

- [ ] **Codex Opinion**: Not needed (standard patterns)
  - Score: 0%

**Overall: 75%**

**Recommendation**: ✅ Proceed with extraction (convert to DI, split 5 services)

---

### HomeScreen Extraction - 🟡 68% CONFIDENCE

**Analysis**:
- [ ] **No Duplicates**: Screen logic isn't duplicated
  - Score: 20%

- [ ] **Architecture Compliance**: Phase 2C started ViewModel pattern
  - Need to continue extraction
  - Score: 14%

- [ ] **Official Docs**: Flutter architecture guidelines clear
  - ViewModel pattern standard
  - Score: 12%

- [ ] **Working Reference**: ChatScreen extraction succeeded (Phase 2C)
  - Apply same pattern here
  - Score: 12%

- [ ] **Root Cause**: Why 1,521 lines?
  - 6 concerns + deep widget tree
  - UI + business logic mixed
  - Score: 10%

- [ ] **Codex Opinion**: Not needed (proven pattern from Phase 2C)
  - Score: 0%

**Overall: 68%**

**Recommendation**: ⚠️ Medium confidence due to complexity. Codex review optional but recommended for deep subscriptions/memory leaks.

---

## Extraction Strategy by File

### Strategy 1: BLEStateManager → 3 Services

```
BLEStateManager (2,290 lines)
├── PairingStateManager (400 lines)
│   ├── Pairing request/acceptance
│   ├── Verification code generation
│   ├── Timeout handling
│   └── 15+ pairing methods → extracted
│
├── SessionStateManager (500 lines)
│   ├── Session ID tracking
│   ├── Conversation keys
│   ├── Noise handshake state
│   └── 25+ session methods → extracted
│
├── IdentityManager (400 lines)
│   ├── PublicKey/EphemeralId/PersistentKey tracking
│   ├── User name management
│   ├── Identity resolution
│   ├── Identity reveal logic
│   └── 20+ identity methods → extracted
│
└── BLEStateManagerFacade (400 lines)
    ├── Orchestrator for 3 services
    ├── Replaces original (backward compatible)
    └── Delegates to sub-services
```

**Risk**: HIGH - Central to security flows
- Coordinate closely with Phase 3 layer violations work
- Need 40+ unit tests per service

---

### Strategy 2: BLEMessageHandler → 3 Services

```
BLEMessageHandler (1,886 lines)
├── MessageFragmentationHandler (250 lines)
│   ├── Chunk reassembly
│   ├── Timeout handling
│   ├── Duplicate detection
│   └── 10+ methods → extracted
│
├── ProtocolMessageHandler (500 lines)
│   ├── Contact request handling
│   ├── Crypto verification handling
│   ├── Message type dispatch
│   └── 20+ methods → extracted
│
├── RelayCoordinator (300 lines) ⚠️ OPTIONAL
│   ├── Should relay logic be here?
│   ├── Or belong in RelayEngine?
│   └── Codex consultation needed
│
└── BLEMessageHandlerFacade (400 lines)
    ├── Orchestrator
    ├── Event dispatching
    └── Backward compatible
```

**Risk**: MEDIUM-HIGH - Complex message handling
- Relay separation is unclear - need Codex input
- Need 30+ unit tests

---

### Strategy 3: OfflineMessageQueue → 3 Services

```
OfflineMessageQueue (1,749 lines)
├── MessageQueueRepository (350 lines)
│   ├── Enqueue/dequeue
│   ├── Prioritization
│   ├── Database persistence
│   └── 15+ methods → extracted
│
├── RetryScheduler (300 lines)
│   ├── Exponential backoff
│   ├── Retry timer management
│   ├── Max retries logic
│   └── 10+ methods → extracted
│
├── QueueSynchronizer (400 lines)
│   ├── Hash calculation
│   ├── Missing message detection
│   ├── Sync message creation
│   └── 15+ methods → extracted
│
└── OfflineMessageQueueFacade (300 lines)
    ├── Orchestrator
    ├── Statistics aggregation
    └── Backward compatible
```

**Risk**: MEDIUM - Well-understood queue patterns
- Hash calculation must be bulletproof
- 25-30 unit tests

---

### Strategy 4: ChatManagementService → 5 Services + Refactor to DI

```
ChatManagementService (1,738 lines)
├── Convert Singleton → DI
│   └── Register in service_locator.dart
│
├── ChatOperationService (250 lines)
│   ├── Archive, pin, delete
│   ├── Clear messages
│   └── 10+ methods → extracted
│
├── SearchService (350 lines)
│   ├── Text search (FTS5)
│   ├── Filter application
│   ├── Result grouping
│   └── 15+ methods → extracted
│
├── MessageOperationService (200 lines)
│   ├── Star/unstar message
│   ├── Delete message
│   └── 5+ methods → extracted
│
├── ExportService (150 lines)
│   ├── Export to text/JSON/CSV
│   └── 3 format methods → extracted
│
├── ChatAnalyticsService (200 lines)
│   ├── Analytics calculation
│   ├── Combined metrics
│   └── 10+ methods → extracted
│
└── ChatManagementServiceFacade (250 lines)
    ├── Orchestrator
    ├── Delegates to services
    └── Maintains singleton removal
```

**Risk**: MEDIUM - Well-understood CRUD patterns
- Singleton removal is key improvement
- 20-25 unit tests

---

### Strategy 5: HomeScreen → Extract ViewModel (Continue Phase 2C Pattern)

```
HomeScreen (1,521 lines)
├── Extract HomeScreenViewModel (200 lines)
│   ├── Chat list state
│   ├── Search state
│   ├── Unread tracking
│   └── 15+ methods → extracted
│
├── Extract DeviceDiscoveryController (150 lines)
│   ├── Nearby devices
│   ├── Device selection
│   └── 8+ methods → extracted
│
├── Extract HomeScreenMenuController (100 lines)
│   ├── Menu actions
│   ├── Navigation events
│   └── 5+ methods → extracted
│
├── HomeScreenState (Updated, ~800 lines)
│   ├── Simplified widget tree
│   ├── Delegates to controllers
│   └── Focuses on UI only
│
└── Widgets (Created)
    ├── ChatListWidget
    ├── SearchBarWidget
    ├── DeviceDiscoveryOverlay
    └── BLEStatusBanner
```

**Risk**: MEDIUM - Widget testing complexity
- Requires careful subscription cleanup
- 15-20 widget tests

---

## Testing Strategy

### Unit Tests (Per Service)

Each extracted service needs:
- **Constructor tests** (2-3 tests): DI, initialization
- **Happy path tests** (5-8): Normal flow
- **Edge case tests** (5-8): Boundary conditions
- **Error handling** (3-5): Exceptions, timeouts
- **State tests** (3-5): State transitions
- **Total**: 18-30 tests per service

**Example for PairingStateManager**:
```dart
test('handles pairing request with timeout', () async {
  final manager = PairingStateManager(...);
  final request = manager.handlePairingRequest(code);
  expect(request, isNotNull);
  await Future.delayed(Duration(seconds: 31));
  expect(request.isExpired, true);
});
```

### Integration Tests (Per Service Bundle)

Each extracted bundle (3 sub-services) needs:
- **Initialization flow** (2 tests)
- **State transitions** (3-5 tests)
- **Cross-service communication** (3-5 tests)
- **Total**: 8-15 tests per bundle

### Regression Tests (Existing Functionality)

For each phase:
- Run full test suite (should be 1000+ tests)
- Ensure 0 new failures
- Monitor code coverage (should improve)

---

## Rollback Points

### Safe Checkpoints

1. **After BLEStateManager extraction**
   - Tag: `phase4-ble-state-extracted`
   - Rollback: `git reset --hard phase4-ble-state-extracted`
   - Risk: Only identity/pairing affected

2. **After BLEMessageHandler extraction**
   - Tag: `phase4-ble-message-extracted`
   - Risk: Message handling affected

3. **After OfflineMessageQueue extraction**
   - Tag: `phase4-queue-extracted`
   - Risk: Offline functionality affected

4. **After ChatManagementService extraction**
   - Tag: `phase4-chat-mgmt-extracted`
   - Risk: Chat operations affected

5. **After HomeScreen extraction**
   - Tag: `phase4-home-screen-extracted`
   - Risk: Home screen UI affected

---

## Success Criteria

### Per Service
- [ ] All public methods delegated/wrapped
- [ ] All fields properly initialized
- [ ] 0 compilation errors
- [ ] 0 new test failures
- [ ] 18-30 unit tests passing
- [ ] Code complexity reduced by 60-70%
- [ ] No circular dependencies introduced
- [ ] Backward compatibility maintained

### Overall Phase
- [ ] 5 files reduced from 9,184 → <6,000 LOC
- [ ] 15 new interfaces created
- [ ] 100+ new unit tests passing
- [ ] 0 breaking changes
- [ ] ChatManagementService converted from Singleton to DI
- [ ] All 1000+ existing tests still passing
- [ ] Code coverage stable or improved
- [ ] Real device testing validates functionality

---

## Timeline Breakdown (2 weeks)

### Week 1: Core Extraction (Days 1-5)

**Day 1-2: BLEStateManager**
- Analyze pairing/session/identity separation
- Create 3 interfaces + implementations
- Write 40+ unit tests
- Update facade

**Day 2-3: BLEMessageHandler**
- Analyze protocol/fragmentation/relay separation
- Create 3 interfaces + implementations
- Write 35+ unit tests
- Decide relay coordinator location (Codex input)

**Day 4-5: OfflineMessageQueue**
- Extract queue/retry/sync services
- Create 3 interfaces + implementations
- Write 25+ unit tests
- Test hash calculation thoroughly

### Week 2: Domain & UI Extraction (Days 6-10)

**Day 6-7: ChatManagementService**
- Convert from Singleton to DI
- Extract 5 sub-services
- Create 5 interfaces
- Write 25+ unit tests
- Register in service_locator.dart

**Day 8-9: HomeScreen**
- Continue Phase 2C pattern
- Extract ViewModel
- Create controllers
- Write 20 widget tests
- Test subscription cleanup

**Day 10: Integration & Validation**
- Run full test suite
- Real device testing
- Performance validation
- Create git tags for all checkpoints
- Final documentation

---

## Codex Consultation Points

Before starting, consult Codex on:

1. **BLEStateManager Pairing/Session Split** (Score: 70%)
   - "How to split pairing state from session state without creating coupling?"
   - "Is it OK to have PairingStateManager depend on SessionStateManager?"

2. **BLEMessageHandler Relay Separation** (Score: 72%)
   - "Should relay coordination be in RelayEngine or BLEMessageHandler?"
   - "Message handling logic location: ProtocolMessageHandler or RelayEngine?"

3. **OfflineMessageQueue Hash Calculation** (Score: 80%)
   - "Are there off-by-one errors in my hash calculation logic?"
   - "Does message ordering affect deterministic hash?"

4. **HomeScreen Memory Leaks** (Score: 68%)
   - "What's the safest pattern for managing 7+ subscriptions?"
   - "Should I use dispose pattern or Provider's auto-cleanup?"

---

## Key Patterns to Apply

### 1. Facade Pattern (All 5 extractions)
```dart
class BLEStateManagerFacade implements IBLEStateManager {
  late final PairingStateManager _pairing;
  late final SessionStateManager _session;
  late final IdentityManager _identity;
  
  // Lazy initialization
  PairingStateManager get pairing => 
    _pairing ??= PairingStateManager(...);
  
  // Delegate public API
  Future<void> sendPairingRequest(String contactKey) =>
    pairing.sendPairingRequest(contactKey);
}
```

### 2. DI Registration Pattern
```dart
// In service_locator.dart
void registerCoreServices() {
  // BLEStateManager sub-services
  getIt.registerSingleton<IPairingStateManager>(PairingStateManager(...));
  getIt.registerSingleton<IBLEStateManagerFacade>(BLEStateManagerFacade(...));
  
  // ChatManagementService (converted from singleton)
  getIt.registerSingleton<ChatManagementService>(
    ChatManagementService(repos: getIt())
  );
}
```

### 3. Callback Coordination Pattern (for cross-service events)
```dart
final pairing = PairingStateManager(
  onPairingComplete: (code) => session.handlePairingComplete(code),
  onStateChanged: (state) => listeners.forEach((l) => l(state)),
);
```

---

## Risk Assessment Summary

| Service | Complexity | Risk | Confidence | Priority |
|---------|-----------|------|------------|----------|
| BLEStateManager | VERY HIGH | 🔴 HIGH | 70% | 1 (foundation) |
| BLEMessageHandler | HIGH | 🔴 HIGH | 72% | 2 (depends on #1) |
| OfflineMessageQueue | HIGH | 🟡 MEDIUM | 80% | 3 (independent) |
| ChatManagementService | MEDIUM | 🟡 MEDIUM | 75% | 4 (depends on repos) |
| HomeScreen | MEDIUM | 🟡 MEDIUM | 68% | 5 (depends on services) |

---

## Critical Invariants (Must Preserve)

✅ Identity immutability: `publicKey` never changes
✅ Session completeness: Handshake must finish before encryption
✅ Message deduplication: Same content → same ID (deterministic)
✅ Queue reliability: No message loss during sync
✅ Chat persistence: Archive/pin state must survive app restart
✅ Subscription safety: No memory leaks in HomeScreen subscriptions

---

## Bonus Opportunities (If Time Permits)

1. **Replace Singletons** with DI in:
   - ChatManagementService (planned)
   - BLEMessageHandler (currently uses BLEService singleton)

2. **Performance Optimizations**:
   - Batch contact updates
   - Cache topology for 5 seconds
   - Use bloom filters for duplicate detection

3. **Add Observability**:
   - Metrics for message delivery time
   - Relay hop count histogram
   - Pairing completion rate

---

## Files to Create

### Interfaces (15 new files)
- `lib/core/interfaces/i_pairing_state_manager.dart`
- `lib/core/interfaces/i_session_state_manager.dart`
- `lib/core/interfaces/i_identity_manager.dart`
- `lib/core/interfaces/i_ble_state_manager_facade.dart`
- `lib/core/interfaces/i_message_fragmentation_handler.dart`
- `lib/core/interfaces/i_protocol_message_handler.dart`
- `lib/core/interfaces/i_message_queue_repository.dart`
- `lib/core/interfaces/i_retry_scheduler.dart`
- `lib/core/interfaces/i_queue_synchronizer.dart`
- `lib/domain/interfaces/i_chat_operation_service.dart`
- `lib/domain/interfaces/i_search_service.dart`
- `lib/domain/interfaces/i_message_operation_service.dart`
- `lib/domain/interfaces/i_export_service.dart`
- `lib/domain/interfaces/i_chat_analytics_service.dart`

### Services (20 new files)
- 3x BLEStateManager sub-services
- 3x BLEMessageHandler sub-services
- 3x OfflineMessageQueue sub-services
- 5x ChatManagementService sub-services
- 3x HomeScreen controllers
- 3x Facades/Orchestrators

### Tests (25-30 new test files)
- Unit tests for each service
- Integration tests for bundles
- Widget tests for HomeScreen

### Total: ~50-60 files created/modified

---

## Pre-Implementation Checklist

- [ ] Read this entire document
- [ ] Get Codex input on BLEStateManager separation (critical)
- [ ] Get Codex input on BLEMessageHandler relay location
- [ ] Review Phase 2A pattern (BLEService facade)
- [ ] Review Phase 2C pattern (ViewModel extraction)
- [ ] Review Phase 3 DI setup
- [ ] Create git branch: `refactor/phase4-remaining-gods`
- [ ] Create backup tag: `pre-phase4` 
- [ ] Run baseline tests (should be 1000+)
- [ ] Confirm no uncommitted changes
- [ ] Set up todo list for tracking progress

---

## Next Steps

1. **This Week**: Present this plan to user for feedback
2. **Codex Consultation**: Get second opinions on critical decisions
3. **Day 1**: Create git branch and start BLEStateManager extraction
4. **Weekly**: Tag checkpoints, run full test suite
5. **End of Week 2**: Real device validation, final documentation

---

**Status**: 📋 READY FOR EXECUTION

This ultrathink plan provides:
- ✅ Detailed analysis of each god class
- ✅ Extraction strategies (facade pattern)
- ✅ Confidence scoring (70-80% range)
- ✅ Dependency ordering
- ✅ Testing strategy (100+ new tests)
- ✅ Rollback points (5 checkpoints)
- ✅ Timeline (2 weeks, 10 days)
- ✅ Codex consultation points
- ✅ Success criteria
- ✅ Critical invariants
- ✅ Risk assessment

**Confidence Level**: 75% overall (medium-high confidence with clear contingencies)

Proceed when ready. Codex consultation recommended for BLEStateManager and BLEMessageHandler items.
