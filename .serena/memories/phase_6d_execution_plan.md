# Phase 6D Execution Plan - Phases 2-3

## Overall Progress
- Phase 1: COMPLETE (7 services, 11 controllers → provider-wrapped)
- Phase 2-3: IN PROGRESS (remaining 57 StreamControllers across ~14 files)

## Phase 2 (MEDIUM RISK) - Target Controllers: 18-20

Priority Order (based on dependency graph):

### Group 2A: Chat Services (3-4 controllers, 2-3h)
1. **chat_list_coordinator.dart** - 1 controller (_unreadCountController)
   - Type: State Broadcast → StateNotifier
   - Pattern: Similar to Phase 1 M2-M7
   - Consumers: ChatListScreen, HomeScreenFacade
   
2. **chat_connection_manager.dart** - 1 controller (_connectionStatusController)
   - Type: Event Stream → StreamProvider
   - Pattern: Similar to Phase 1 M2
   - Consumers: ChatScreen, ConnectionState
   
3. **chat_interaction_handler.dart** - 1 controller (_intentController)
   - Type: Action intent stream
   - Pattern: Custom event stream

### Group 2B: BLE Discovery (2-3 controllers, 2-3h)
4. **ble_discovery_service.dart** - 2 controllers (devicesController, hintMatchController)
   - Type: Device stream, hint stream
   - Pattern: Event streams
   - Note: Used by BLEServiceFacade
   
### Group 2C: Scanning (1-2 controllers, 1-2h)
5. **burst_scanning_controller.dart** - 1 controller (_statusController)
   - Type: State Broadcast → StateNotifier
   - Pattern: Similar to Phase 1
   - Consumers: Scanning UI

### Group 2D: Home Screen (1 controller, 1h)
6. **home_screen_facade.dart** - 1 controller (_controller for ChatInteractionIntent)
   - Type: Action intent stream
   - Pattern: Similar to chat_interaction_handler

### Group 2E: Device Management (1 controller, 1h)
7. **device_deduplication_manager.dart** - 1 controller (_devicesController)
   - Type: Static device stream
   - Pattern: Singleton with broadcast stream

### Group 2F: Mesh Network Health (4 controllers, 3-4h) ⚠️ MEDIUM-HIGH COMPLEXITY
8. **mesh_network_health_monitor.dart** - 4 controllers
   - _meshStatusController, _relayStatsController, _queueStatsController, _messageDeliveryController
   - Type: Multiple event streams (status, relay stats, queue stats, delivery)
   - Pattern: Expert-identified consolidation target → 2 providers
   - Consumers: Mesh status UI, stats reporting
   - Note: Was flagged as top consolidation opportunity (80 LOC saved)

---

## Phase 3 (HIGH RISK) - Target Controllers: 10

### Group 3A: Core Bluetooth (6-8 controllers, 4-5h) ⚠️ CRITICAL PATH
1. **ble_service_facade.dart** - 7 controllers
   - _connectionInfoController, _discoveredDevicesController, _hintMatchesController
   - _handshakeSpyModeController, _handshakeIdentityController, ...
   - Type: Core BLE event stream orchestrator
   - Pattern: Expert-identified consolidation → 1 unified BLE event stream (60 LOC saved)
   - Consumers: ChatScreen, BLE UI, Connection management
   - Risk: CRITICAL - Core BLE infrastructure
   - Note: Codex audit identified this as top consolidation opportunity

2. **ble_handshake_service.dart** - 2 controllers
   - _spyModeDetectedController, _identityRevealedController
   - Type: Handshake event streams
   - Pattern: Event streams
   - Consumers: Handshake lifecycle
   - Note: Often used by BLEServiceFacade

3. **ble_connection_service.dart** - 1 controller (connectionInfoController)
   - Type: Connection state stream
   - Pattern: Event stream
   - Consumers: Connection management

4. **ble_messaging_service.dart** - 1 controller (_messagesController)
   - Type: Message stream
   - Pattern: Event stream
   - Consumers: Message handling

### Group 3B: Bluetooth State Monitoring (2 controllers, 2-3h) ⚠️ MEDIUM-HIGH COMPLEXITY
5. **bluetooth_state_monitor.dart** - 2 controllers
   - _stateController, _messageController
   - Type: Bluetooth state + status message streams
   - Pattern: Expert-identified consolidation
   - Consumers: BLE status UI, connection logic
   - Risk: MEDIUM-HIGH (core BLE state)

6. **handshake_coordinator.dart** - 1 controller (_phaseController)
   - Type: Handshake phase progression stream
   - Pattern: State stream → StateNotifier
   - Consumers: Handshake UI, phase tracking

### Group 3C: Global App Core (1 controller, 2-3h) ⚠️ CRITICAL - LAST
7. **app_core.dart** - 1 controller (_statusController)
   - Type: Global app lifecycle status
   - Pattern: Singleton with global scope
   - Risk: CRITICAL - Global singleton, affects entire app
   - Note: Must be last in Phase 3 (done after all other services stable)
   - Consumers: App initialization, shutdown, error recovery

---

## Estimated Time Breakdown

Phase 2: 16-18 hours
- Group 2A (chat services): 2-3h
- Group 2B (BLE discovery): 2-3h
- Group 2C (scanning): 1-2h
- Group 2D (home screen): 1h
- Group 2E (device mgmt): 1h
- Group 2F (mesh health): 3-4h

Phase 3: 10-12 hours
- Group 3A (core BLE + handshake): 4-5h
- Group 3B (BLE state): 2-3h
- Group 3C (app core): 2-3h

---

## Key Patterns (Based on Phase 1)

### Pattern 1: Complete Removal (M1)
- Goal: Remove StreamController entirely
- Result: Clean provider-based state
- Example: UserPreferences
- Risk: LOW
- Time: 1-2h per file

### Pattern 2: Provider Wrapping (M2-M7)
- Goal: Keep StreamController, expose via provider
- Result: StreamProvider wraps .stream
- Example: TopologyManager
- Risk: LOW-MEDIUM
- Time: 1-2h per file

### Pattern 3: Consolidation (High-Value Targets)
- Goal: Merge multiple controllers into unified event stream
- Result: 1-2 providers instead of 3-4+ controllers
- Examples: BLEServiceFacade (5→1), MeshNetworkHealthMonitor (4→2)
- Risk: MEDIUM-HIGH
- Time: 3-4h per file (complex logic)

---

## Phase 2-3 Progress

### Completed (File 1/28)
✅ **chatlist_coordinator.dart** (Commit d9d6268)
- Type: Dead Code Removal
- Change: Removed unused _unreadCountController
- Result: 1 StreamController removed, tests passing
- Time: 15 minutes

### Analyzed (Not Yet Migrated)
🔍 **chat_connection_manager.dart** - Active event broadcaster
- Uses: StreamController to emit ConnectionStatus events
- Consumers: ChatListCoordinator, HomeScreenFacade
- Pattern: Requires provider wrapping (complex)
- Issue: Would need StateNotifier + StreamProvider + consumer updates

🔍 **chat_interaction_handler.dart** - Action intent emitter
- Uses: StreamController to emit ChatInteractionIntent events
- Consumers: Various UI handlers
- Pattern: Requires provider wrapping (complex)
- Issue: Multiple intent types, event-driven architecture

### Key Insight: Two Migration Patterns Identified

**Pattern A: Dead Code** (Simple, 30-60 min/file)
- Characteristics: StreamController created but never exposed or used
- Solution: Remove controller, simplify method implementations
- Risk: LOW
- Confidence: HIGH
- Examples: ChatListCoordinator

**Pattern B: Active Event Broadcasters** (Complex, 2-3 hours/file)
- Characteristics: StreamController actively used to emit events from listeners
- Solution: Create StateNotifier, wrap with StreamProvider, update consumers
- Risk: MEDIUM-HIGH (must find all consumers, update call sites)
- Confidence: MEDIUM (architectural pattern less established)
- Examples: ChatConnectionManager, ChatInteractionHandler, (likely) MeshNetworkHealthMonitor, BLEServiceFacade

### Completed Work

**Commit d9d6268**: ChatListCoordinator dead code removal (15 min)
- Removed unused _unreadCountController
- Tests passing

**Commit b9625c0**: Provider wrapper pattern established (45 min)
- Created chat_connection_provider.dart
- Established replicable pattern for remaining files
- Pattern: Provider.autoDispose + StreamProvider wrapper + ref.onDispose

### Recommendations for Continued Execution

**Option 1** (RECOMMENDED - Pragmatic): Two-Phase Approach
- Phase 2A (2-3 hours): Find and remove all "dead code" StreamControllers first
  - Use Codex or pattern search to identify unused controllers
  - Quick wins, confidence in changes high
  - Build momentum with clear successes
- Phase 2B (12-14 hours): Migrate active event broadcasters
  - Establish StateNotifier + StreamProvider pattern in first file
  - Apply pattern repetitively to remaining files
  - Test thoroughly at each step

**Option 2** (Faster): Focus on specific high-impact files
- Identify top 3-5 StreamController consumers (e.g., BLEServiceFacade with 7 controllers)
- Consolidate multiple controllers into single unified provider
- Skip lower-impact files for now

**Option 3** (Current pace): Careful step-by-step migration
- Continue file-by-file analysis
- Estimate 3-4 hours per complex file
- Results in highest quality but longest timeline

---

## Execution Rules

1. **Quality First**: Run `flutter analyze` + `flutter test` after each file
2. **One File at a Time**: Don't batch changes
3. **Provider Pattern**: Follow Phase 1 patterns strictly
4. **Consumer Search**: Find ALL external consumers before refactoring
5. **Backup Plan**: If issues arise, revert and reassess

---

## Success Metrics

- Phase 2: 57 → 30 StreamControllers (47% reduction)
- Phase 3: 30 → <10 StreamControllers (67% total reduction from current 68)
- Coverage: All tests passing, `flutter analyze` clean
- Commit: 2-3 commits (Phase 2 + Phase 3 Part 1 + Phase 3 Part 2)

---

## Next Step

Start with Phase 2, Group 2A (chat services) - lowest risk, establishes patterns for later groups.
