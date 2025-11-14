# Phase 2 Part A: BLEService Split - Pre-Implementation Analysis

**Date**: 2025-11-14
**Status**: PLANNING (DO NOT IMPLEMENT YET)
**Goal**: Split BLEService (3,431 lines) into 6 focused services

---

## 📊 Current State Analysis

### BLEService Statistics
- **Total Lines**: 3,431
- **Estimated Methods**: ~66 public methods
- **Sub-components**: 15+ internal dependencies
- **Direct Dependents**: 9 files
- **Instantiation Points**: 1 (ble_providers.dart)

### Existing Sub-Components (Already Extracted)
✅ These already exist as separate classes:
1. **HandshakeCoordinator** (`lib/core/bluetooth/handshake_coordinator.dart`)
   - Handshake protocol (4 phases)
   - Already handles Phase 0 → 1 → 1.5 → 2

2. **AdvertisingManager** (`lib/core/bluetooth/advertising_manager.dart`)
   - Advertising lifecycle
   - Hint-based advertising

3. **PeripheralInitializer** (`lib/core/bluetooth/peripheral_initializer.dart`)
   - GATT server setup
   - Peripheral mode initialization

4. **ConnectionCleanupHandler** (`lib/core/bluetooth/connection_cleanup_handler.dart`)
   - Connection resource cleanup
   - Disconnection handling

5. **BluetoothStateMonitor** (`lib/core/bluetooth/bluetooth_state_monitor.dart`)
   - BLE adapter state tracking
   - Permission monitoring

6. **BLEConnectionManager** (`lib/data/services/ble_connection_manager.dart`)
   - Connection lifecycle
   - MTU negotiation
   - Connection state tracking

7. **BLEMessageHandler** (`lib/data/services/ble_message_handler.dart`)
   - Message send/receive
   - Protocol message handling
   - Fragmentation coordination

8. **BLEStateManager** (`lib/data/services/ble_state_manager.dart`)
   - User identity state
   - Session ID tracking
   - Mode tracking (central/peripheral)

### Dependencies (Who Uses BLEService)

**9 Files Import BLEService**:
1. `lib/domain/services/mesh_networking_service.dart` ⚠️ **CRITICAL**
2. `lib/domain/services/security_state_computer.dart`
3. `lib/presentation/providers/ble_providers.dart` ⚠️ **INSTANTIATION POINT**
4. `lib/presentation/widgets/discovery_overlay.dart`
5. `lib/presentation/screens/home_screen.dart`
6. `lib/core/scanning/burst_scanning_controller.dart`
7. `lib/core/routing/network_topology_analyzer.dart`
8. `lib/core/routing/connection_quality_monitor.dart`
9. `lib/core/messaging/message_router.dart`

**CRITICAL INSIGHT**: Only `ble_providers.dart` instantiates BLEService!
- All others receive it via dependency injection
- This makes refactoring EASIER (single constructor change point)

---

## 🎯 Refactoring Strategy

### Phase 2A.1: Analysis & Planning (CURRENT)
- Map all public methods
- Categorize by responsibility
- Identify coupling points
- Create migration checklist

### Phase 2A.2: Interface Creation (Week 1, Day 1)
- Create `IBLEService` interface (facade pattern)
- Extract method signatures from current BLEService
- NO implementation changes yet

### Phase 2A.3: Service Extraction (Week 1, Day 2-4)
Extract in this order (safest → riskiest):

**Order 1: BLEDiscoveryService** (SAFEST)
- Reason: Least coupled, mostly read-only
- Lines: ~300
- Methods: startDiscovery, stopDiscovery, _handleDiscoveredPeripheral
- Dependencies: DeviceDeduplicationManager, HintScannerService

**Order 2: BLEAdvertisingService** (SAFE)
- Reason: Already mostly delegated to AdvertisingManager
- Lines: ~200
- Methods: startAdvertising, stopAdvertising, updateAdvertising
- Dependencies: AdvertisingManager, PeripheralInitializer

**Order 3: BLEMessagingService** (MODERATE)
- Reason: Well-defined boundary, existing BLEMessageHandler
- Lines: ~400
- Methods: sendMessage, sendProtocolMessage, _handleNotification
- Dependencies: BLEMessageHandler, MessageFragmenter

**Order 4: BLEConnectionService** (MODERATE-HIGH)
- Reason: Core functionality, many dependents
- Lines: ~500
- Methods: connectToDevice, disconnect, _handleConnectionState
- Dependencies: BLEConnectionManager, BLEStateManager

**Order 5: BLEHandshakeService** (HIGH RISK)
- Reason: Critical path, handshake timing issues
- Lines: ~600
- Methods: _startHandshake, _handleHandshakePhase, _waitForPeerNoiseKey
- Dependencies: HandshakeCoordinator, SecurityManager

**Order 6: BLEServiceFacade** (FINAL)
- Reason: Orchestrator, depends on all others
- Lines: ~500
- Methods: initialize, orchestration logic
- Dependencies: All 5 sub-services

### Phase 2A.4: Internal Delegation (Week 1, Day 5)
- BLEService delegates to sub-services internally
- NO external API changes
- All 9 dependents unchanged
- Test suite should still pass

### Phase 2A.5: Dependent Migration (Week 2, Day 1-2)
- Update `ble_providers.dart` to create sub-services
- Register sub-services in DI container
- Update 8 other dependents to use sub-services directly
- Deprecate BLEService (keep as facade)

### Phase 2A.6: Testing & Validation (Week 2, Day 3)
- Run full test suite (691 tests expected)
- Real device testing (2 devices, handshake, messaging)
- Rollback plan if >5% tests fail

---

## 📋 Detailed Method Categorization

### Category A: Discovery (~12 methods)
**Target**: BLEDiscoveryService

Methods:
- `startDiscovery()` / `stopDiscovery()`
- `_handleDiscoveredPeripheral()`
- `_processDiscoveryEvent()`
- `_updateDiscoveredDevices()`
- `_deduplicateDevices()`
- `_filterSelfConnection()`
- `_emitDiscoveryData()`
- `get discoveredDevices` stream
- `get discoveryData` stream
- `get isDiscoveryActive` getter
- Hint scanning integration
- Spy mode detection

**Dependencies**:
- DeviceDeduplicationManager
- HintScannerService
- BackgroundCacheService (hint matching)

**Risk**: LOW (mostly independent)

---

### Category B: Advertising (~8 methods)
**Target**: BLEAdvertisingService

Methods:
- `startAdvertising()`
- `stopAdvertising()`
- `updateAdvertising()`
- `_setupPeripheralMode()`
- `_handleAdvertisingState()`
- `get _authoritativeAdvertisingState` getter
- HintAdvertisementService integration
- Peripheral connection tracking

**Dependencies**:
- AdvertisingManager (already extracted)
- PeripheralInitializer (already extracted)
- HintAdvertisementService

**Risk**: LOW (already delegated to AdvertisingManager)

---

### Category C: Messaging (~15 methods)
**Target**: BLEMessagingService

Methods:
- `sendMessage(String recipientKey, String message)`
- `sendProtocolMessage(ProtocolMessage message)`
- `sendQueueSyncMessage(QueueSyncMessage queueMessage)`
- `_handleNotification()` (central mode receive)
- `_handleWriteRequest()` (peripheral mode receive)
- `_processReceivedData()`
- `_handleFragmentedMessage()`
- `_sendAcknowledgment()`
- `_retryFailedMessage()`
- `get receivedMessages` stream
- `get canSendMessages` getter
- Message buffering (_bufferedMessages)
- Protocol ACK tracking (extractedMessageId)
- GossipSyncManager integration
- OfflineMessageQueue integration

**Dependencies**:
- BLEMessageHandler (already extracted)
- MessageFragmenter
- GossipSyncManager
- OfflineMessageQueue
- SecurityManager (encryption)

**Risk**: MODERATE (critical path for messaging)

---

### Category D: Connection Management (~18 methods)
**Target**: BLEConnectionService

Methods:
- `connectToDevice(String deviceId)`
- `disconnect()`
- `_handleConnectionState()`
- `_handleMtuChange()`
- `_negotiateMtu()`
- `_setupNotifications()` (central mode)
- `_handleCentralConnected()` (peripheral mode)
- `_handlePeripheralDisconnected()`
- `_handleConnectionFailure()`
- `_retryConnection()`
- `get isConnected` getter
- `get hasCentralConnection` getter
- `get hasPeripheralConnection` getter
- `get isActivelyReconnecting` getter
- `get isMonitoring` getter
- Connection cleanup integration
- Auto-reconnect logic
- Connection info streaming

**Dependencies**:
- BLEConnectionManager (already extracted)
- BLEStateManager (already extracted)
- ConnectionCleanupHandler (already extracted)
- PreferencesRepository (auto-connect settings)

**Risk**: MODERATE-HIGH (core functionality)

---

### Category E: Handshake Protocol (~13 methods)
**Target**: BLEHandshakeService

Methods:
- `_startHandshake(bool isInitiator)`
- `_handleHandshakePhase(ConnectionPhase phase)`
- `_sendIdentityExchange()`
- `_handleIdentityExchange()`
- `_initiateNoiseHandshake()`
- `_handleNoiseHandshake()`
- `_waitForPeerNoiseKey()` ⚠️ **FIX-008 CRITICAL**
- `_sendContactStatusSync()`
- `_handleContactStatusSync()`
- `_completeHandshake()`
- `_handleMutualConsentRequired()`
- `_handleAsymmetricContact()`
- Handshake phase subscription management

**Dependencies**:
- HandshakeCoordinator (already extracted)
- SecurityManager (Noise Protocol)
- ContactRepository (contact persistence)
- NotificationService (pairing requests)

**Risk**: HIGH (critical path, timing-sensitive, FIX-008)

---

### Category F: Orchestration (~20+ methods)
**Target**: BLEServiceFacade (what BLEService becomes)

Methods:
- `initialize()` ⚠️ **CRITICAL**
- `dispose()`
- `registerQueueSyncHandler()`
- State coordination
- Stream forwarding
- Sub-service lifecycle management
- Error handling
- Logging
- Performance monitoring
- Initialization completer
- Bluetooth state monitoring delegation
- Power management coordination
- Dual-role coordination (central + peripheral)

**Dependencies**:
- All 5 sub-services above
- AppCore
- AdaptivePowerManager
- BluetoothStateMonitor

**Risk**: MODERATE (orchestration logic)

---

## 🚨 Critical Risks & Mitigation

### Risk 1: Breaking Handshake Timing (FIX-008)
**Severity**: HIGH
**Probability**: MEDIUM

**Issue**: FIX-008 added retry logic for handshake phase timing. Extracting BLEHandshakeService could break this.

**Mitigation**:
1. Extract `_waitForPeerNoiseKey()` as-is (no refactoring)
2. Test handshake timing on real devices IMMEDIATELY after extraction
3. Keep exponential backoff logic intact
4. Rollback if handshake fails on devices

**Test**: Two-device handshake (15 min per refactoring step)

---

### Risk 2: Stream Controller Lifecycle
**Severity**: MEDIUM
**Probability**: LOW

**Issue**: BLEService has 7 StreamControllers. Moving methods might orphan stream subscriptions.

**Mitigation**:
1. Keep stream controllers in BLEServiceFacade initially
2. Sub-services call facade methods to emit events
3. Gradually migrate streams to sub-services in Phase 2A.5
4. Test stream subscriptions after each migration

**Test**: Verify all providers receive stream events

---

### Risk 3: Circular Dependencies
**Severity**: HIGH
**Probability**: MEDIUM

**Issue**: Sub-services might need to call each other, creating circular imports.

**Example**: BLEMessagingService needs BLEConnectionService to check `isConnected`.

**Mitigation**:
1. Use interfaces (IBLEConnectionService)
2. Inject dependencies via constructors
3. Use facade as mediator if needed
4. Dependency injection (GetIt) to break compile-time cycles

**Test**: `flutter analyze` should show zero circular dependency errors

---

### Risk 4: State Management Complexity
**Severity**: MEDIUM
**Probability**: HIGH

**Issue**: BLEService has 20+ state flags. Splitting them across services could cause state desync.

**Examples**:
- `_isDiscoveryActive`
- `_peripheralHandshakeStarted`
- `_peripheralMtuReady`
- `_meshNetworkingStarted`

**Mitigation**:
1. Create shared state object (BLESessionState)
2. All sub-services reference same state instance
3. Use getters/setters for atomic updates
4. Document state ownership clearly

**Test**: State transitions should match before/after split

---

### Risk 5: MeshNetworkingService Dependency
**Severity**: CRITICAL
**Probability**: LOW

**Issue**: `mesh_networking_service.dart` imports BLEService. This is a **layer violation** (Domain → Data).

**Current**: MeshNetworkingService → BLEService (WRONG)
**Should be**: MeshNetworkingService → IBLEMessagingService (RIGHT)

**Mitigation**:
1. Create IBLEMessagingService interface
2. Update MeshNetworkingService to use interface
3. Fix layer violation as part of refactoring
4. Document in architecture docs

**Test**: Static analysis should show clean layer separation

---

## 📁 File Structure (Proposed)

```
lib/
├── data/
│   └── services/
│       ├── ble_service.dart (KEEP as facade, deprecate later)
│       ├── ble_connection_manager.dart (existing)
│       ├── ble_message_handler.dart (existing)
│       └── ble_state_manager.dart (existing)
├── core/
│   ├── bluetooth/
│   │   ├── advertising_manager.dart (existing)
│   │   ├── handshake_coordinator.dart (existing)
│   │   ├── peripheral_initializer.dart (existing)
│   │   ├── connection_cleanup_handler.dart (existing)
│   │   └── bluetooth_state_monitor.dart (existing)
│   └── services/  ← NEW SUB-SERVICES GO HERE
│       ├── ble_discovery_service.dart (NEW)
│       ├── ble_advertising_service.dart (NEW)
│       ├── ble_messaging_service.dart (NEW)
│       ├── ble_connection_service.dart (NEW)
│       ├── ble_handshake_service.dart (NEW)
│       └── ble_service_facade.dart (NEW - what BLEService becomes)
├── core/
│   └── interfaces/
│       ├── i_ble_service.dart (existing from Phase 1)
│       ├── i_ble_discovery_service.dart (NEW)
│       ├── i_ble_messaging_service.dart (NEW)
│       └── i_ble_connection_service.dart (NEW)
```

**Rationale**:
- Keep existing files unchanged
- New services in `core/services` (infrastructure layer)
- Interfaces in `core/interfaces` (contract layer)
- BLEService becomes facade in `data/services` (backward compatibility)

---

## 🧪 Testing Strategy

### Unit Tests (40 new tests)
- BLEDiscoveryService: 8 tests
- BLEAdvertisingService: 6 tests
- BLEMessagingService: 12 tests
- BLEConnectionService: 10 tests
- BLEHandshakeService: 12 tests
- BLEServiceFacade: 8 tests

### Integration Tests (10 tests)
- Full discovery → connect → handshake → message flow
- Dual-role scenarios (central + peripheral)
- Reconnection scenarios
- Error handling cascades

### Real Device Tests (CRITICAL)
**After each extraction step**:
1. Build debug APK
2. Install on 2 devices
3. Test: Scan → Connect → Handshake → Send message
4. Verify: No errors, handshake completes, message delivered
5. Time: 10-15 minutes per test

**Rollback trigger**: If any device test fails

---

## 📊 Success Metrics

### Code Quality
- [ ] Zero files >1000 lines
- [ ] All services have interfaces
- [ ] `flutter analyze` shows 0 errors
- [ ] Test coverage ≥85%

### Functional
- [ ] All 691 existing tests pass
- [ ] 40 new unit tests pass
- [ ] 10 new integration tests pass
- [ ] Real device tests pass (2 devices)

### Performance
- [ ] App startup time ≤ baseline (±5%)
- [ ] BLE connection time ≤ baseline
- [ ] Message latency ≤ baseline
- [ ] No memory leaks (StreamControllers)

---

## 🚦 Go/No-Go Decision Points

### After Analysis (NOW)
**Go if**:
- User approves plan
- All risks understood
- Rollback strategy clear

**No-Go if**:
- User wants two-device testing first
- More analysis needed

### After Each Service Extraction
**Go if**:
- All existing tests pass
- Real device test passes
- No new errors in logs

**No-Go if**:
- >5% tests fail
- Device test fails
- Critical errors appear

### After Full Migration
**Go if**:
- All 691 + 50 new tests pass
- Real device tests pass
- Performance ≤ baseline

**No-Go if**:
- Any critical test fails
- Performance degrades >10%
- Rollback to Phase 1

---

## 📋 Pre-Implementation Checklist

Before writing ANY code:
- [ ] User approval on this plan
- [ ] Create `phase2a-ble-service-split` branch
- [ ] Tag current state: `v1.2-pre-phase2a`
- [ ] Document rollback procedure
- [ ] Prepare real devices for testing
- [ ] Set up continuous testing script

---

## 🎯 Next Steps

**WAIT FOR USER APPROVAL** before proceeding.

**If approved**:
1. Create detailed method extraction plan (file-by-file)
2. Generate interface definitions
3. Create branch and tag
4. Extract BLEDiscoveryService (safest first)
5. Test on real devices
6. Repeat for each service

**If not approved**:
- Revise plan based on feedback
- Do two-device testing first
- Defer Phase 2A

---

**Status**: READY FOR USER REVIEW
**Estimated Time**: 2-3 weeks (with real device testing)
**Risk Level**: MEDIUM-HIGH (mitigated with incremental approach)
**Confidence**: 85% (will increase to 95% after first successful extraction)
