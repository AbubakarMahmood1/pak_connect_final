# Phase 2 Part A: BLEService Split Analysis

## CONSUMERS OF BLESERVICE (18 files)

### Production Code (11 files)
1. **lib/data/services/ble_message_handler.dart** - Dependency injection
2. **lib/domain/services/mesh_networking_service.dart** - Heavy use (~15 method calls)
3. **lib/domain/services/security_state_computer.dart** - Light use (~2 method calls)
4. **lib/presentation/screens/home_screen.dart** - UI queries (~8 method calls)
5. **lib/presentation/widgets/discovery_overlay.dart** - UI queries (~12 method calls)
6. **lib/presentation/providers/ble_providers.dart** - Provider definition + queries (~20 method calls)
7. **lib/core/routing/network_topology_analyzer.dart** - BLE quality queries (~3 method calls)
8. **lib/core/routing/connection_quality_monitor.dart** - Signal strength queries (~3 method calls)
9. **lib/core/messaging/message_router.dart** - Dependency injection
10. **lib/core/scanning/burst_scanning_controller.dart** - Scanning control (~4 method calls)
11. **lib/data/services/ble_connection_manager.dart** - (Dependency of BLEService)

### Test Code (7 files)
1. **test/test_helpers/ble/fake_ble_service.dart** - FakeBleService extends BLEService
2. **test/widget_test.dart** - Mock usage
3. **test/mesh_networking_integration_test.dart** - FakeBleService usage
4. **test/*_test.dart** (estimated 4 more files with BLE tests)

### Import Pattern Analysis
- **Direct imports**: 11 files
- **Transitive dependencies**: ~5 more through repositories/managers
- **Provider pattern**: ble_providers.dart provides singleton
- **Fake for testing**: FakeBleService extends BLEService (5 test files)

---

## PROPOSED 6-SERVICE SPLIT

### Service 1: BLEConnectionService (~500 lines)
**Responsibility**: Connection lifecycle, role management, MTU negotiation

**Methods to extract** (23 methods):
- `connectToDevice()` - Central connection initiation
- `disconnect()` - Clean disconnection
- `startConnectionMonitoring()` - Health check monitoring
- `stopConnectionMonitoring()` - Stop monitoring
- `setHandshakeInProgress()` - Flag management
- `_updateConnectionInfo()` - State broadcast
- `_shouldEmitConnectionInfo()` - Deduplication logic
- `_getConnectedCentral()` - State access
- Connection state properties (10+)
- Connection manager delegation methods (5)
- Bluetooth state handlers (3)

**Dependencies**:
- CentralManager, PeripheralManager
- BLEStateManager
- ConnectionInfo model
- StreamController<ConnectionInfo>

**Consumers affected**: 8 files (home_screen, discovery_overlay, ble_providers, security_state_computer, mesh_networking_service)

---

### Service 2: BLEMessagingService (~400 lines)
**Responsibility**: Message sending, encryption coordination, fragmentation

**Methods to extract** (15 methods):
- `sendMessage()` - Central mode message send
- `sendPeripheralMessage()` - Peripheral mode message send
- `_sendIdentityExchange()` - Central identity protocol
- `_sendPeripheralIdentityExchange()` - Peripheral identity protocol
- `_sendHandshakeMessage()` - Handshake message routing
- `_sendProtocolMessage()` - Fragment and queue
- `_processWriteQueue()` - Serialize BLE writes
- `_processMessage()` - Decrypt and emit
- `_handleReceivedData()` - Route incoming data
- `_processPendingMessages()` - Process buffered messages
- Messaging state properties (5)
- Write queue management (2)

**Dependencies**:
- BLEMessageHandler
- MessageFragmenter
- SecurityManager
- StreamController<String> (messages)
- Write queue + Uint8List buffer

**Consumers affected**: 2 files (directly) + 3 indirectly

---

### Service 3: BLEDiscoveryService (~300 lines)
**Responsibility**: Device scanning, deduplication, device list management

**Methods to extract** (12 methods):
- `startScanning()` - Begin scan with source tracking
- `stopScanning()` - End scan
- `startScanningWithValidation()` - Validate state before scanning
- `scanForSpecificDevice()` - Targeted scan
- `_setupDeduplicationListener()` - Device dedup integration
- `_setupAutoConnectCallback()` - Auto-connect logic
- Discovery state properties (6)
- Hint matching callbacks (2)

**Dependencies**:
- CentralManager
- DeviceDeduplicationManager
- HintScannerService
- StreamController<List<Peripheral>>
- StreamController<String> (hint matches)

**Consumers affected**: 3 files (discovery_overlay, ble_providers, burst_scanning_controller)

---

### Service 4: BLEAdvertisingService (~200 lines)
**Responsibility**: Peripheral advertising, service setup, online status

**Methods to extract** (8 methods):
- `startAsPeripheral()` - Enter peripheral mode
- `startAsPeripheralWithValidation()` - Validate before advertising
- `refreshAdvertising()` - Update advertising data
- `startAsCentral()` - Exit peripheral mode
- Advertising state properties (4)

**Dependencies**:
- AdvertisingManager (already exists - just integrate)
- PeripheralInitializer
- PeripheralManager
- BLEStateManager
- ConnectionInfo broadcast

**Consumers affected**: 2 files (home_screen, discovery_overlay)

---

### Service 5: BLEHandshakeService (~600 lines)
**Responsibility**: Handshake protocol execution, phase management, identity resolution

**Methods to extract** (18 methods):
- `_performHandshake()` - Main handshake orchestrator
- `_onHandshakeComplete()` - Completion handler
- `_disposeHandshakeCoordinator()` - Cleanup
- `_getPhaseMessage()` - Phase → string
- `_isHandshakeMessage()` - Message type check
- `requestIdentityExchange()` - Manual re-exchange
- `triggerIdentityReExchange()` - Username change propagation
- `_buildLocalCollisionHint()` - Collision detection hint
- `_handleMutualConsentRequired()` - Asymmetric handling
- `_handleAsymmetricContact()` - Legacy fallback
- `_handleSpyModeDetected()` - Spy mode event
- `_handleIdentityRevealed()` - Identity exposure event
- Handshake state properties (7)

**Dependencies**:
- HandshakeCoordinator
- BLEStateManager
- SecurityManager
- ContactRepository
- StreamController<SpyModeInfo>
- StreamController<String> (identity revealed)
- Message buffer + reassembler

**Consumers affected**: 5 files (high impact - handshake is critical)

---

### Service 6: BLEServiceFacade (~500 lines)
**Responsibility**: Main orchestrator, initialization, cleanup, delegation to sub-services

**Methods to extract** (20 methods):
- `initialize()` - Setup all sub-services
- `dispose()` - Cleanup all resources
- `registerQueueSyncHandler()` - Mesh networking integration
- `sendQueueSyncMessage()` - Relay message routing
- `getMyPublicKey()` - Key access
- `getMyEphemeralId()` - Ephemeral key access
- `setMyUserName()` - Username management
- `getConnectionInfoWithFallback()` - Fallback state
- `attemptIdentityRecovery()` - Recovery logic
- `_setupEventListeners()` - Cross-service wiring
- Initialization properties (1)
- Bluetooth state monitoring (2)
- Mesh networking integration (3)
- Delegation properties (8)

**Dependencies**:
- All 5 sub-services above
- AppCore (for messageQueue access)
- GossipSyncManager, OfflineMessageQueue
- BluetoothStateMonitor

**Consumers affected**: ALL 18 files (facade is public interface)

---

## IMPLEMENTATION STRATEGY

### Phase 2A.1: Create Sub-Service Interfaces (Week 1, Day 1-2)
- ✅ IBLEConnectionService interface
- ✅ IBLEMessagingService interface
- ✅ IBLEDiscoveryService interface
- ✅ IBLEAdvertisingService interface
- ✅ IBLEHandshakeService interface

**Risk**: NONE - Pure interface definition
**Tests**: 5 new interface tests

### Phase 2A.2: Extract Sub-Services (Week 1, Day 3-5)
- ✅ BLEConnectionService implementation
- ✅ BLEMessagingService implementation
- ✅ BLEDiscoveryService implementation
- ✅ BLEAdvertisingService implementation
- ✅ BLEHandshakeService implementation

**Risk**: MEDIUM - Each service must work independently
**Tests**: 40 new unit tests (8 per service)
**Validation**: All 957 existing tests must pass

### Phase 2A.3: Update BLEService to Delegate (Week 2, Day 1-3)
- ✅ Convert BLEService to BLEServiceFacade
- ✅ Move remaining logic to facade
- ✅ Create delegation methods for backward compatibility

**Risk**: LOW - No external code changes needed yet
**Tests**: None new (facade just delegates)
**Validation**: All 957 + 40 = 997 tests must pass

### Phase 2A.4: Update Consumers (Week 2, Day 4-5)
- ⚠️ Update 11 consumer files to use sub-services directly
- ⚠️ Update 5 test files to mock sub-services

**Risk**: HIGH - Breaking changes to public API
**Tests**: Update 5 test mocks to new interfaces
**Validation**: ALL 997 tests must pass + real device testing

---

## CRITICAL INVARIANTS TO MAINTAIN

### Connection State Invariant
- Single source of truth: `ConnectionInfo` broadcast via `_connectionInfoController`
- No duplicate advertising state trackers (learned from Phase 1)

### Message Buffering Invariant
- Messages buffered until identity exchange complete (Phase 1.5)
- BufferedMessage dequeued in order after `_onHandshakeComplete()`

### Handshake Completion Invariant
- MUST reach `ConnectionPhase.complete` before regular messages
- No race between phase progression and message processing

### Identity Resolution Invariant
- publicKey (ephemeral) vs persistentPublicKey (pairing) distinction maintained
- currentEphemeralId updates per connection

### Write Serialization Invariant
- All BLE writes routed through `_sendProtocolMessage()` → `_processWriteQueue()`
- Prevents concurrent write exceptions

### Dual-Role Integrity
- Can advertise AND scan simultaneously
- Single connection policy (adopt inbound if already connected to same device)

---

## CONSUMER IMPACT MATRIX

| File | Calls | Impact | Refactor Effort |
|------|-------|--------|-----------------|
| ble_providers.dart | 20 | HIGH - Multiple imports | MEDIUM (reorganize imports) |
| discovery_overlay.dart | 12 | HIGH - Direct properties | MEDIUM (inject services) |
| home_screen.dart | 8 | MEDIUM - Queries only | LOW (pass service down) |
| mesh_networking_service.dart | 15 | CRITICAL - Central control | HIGH (complex refactor) |
| burst_scanning_controller.dart | 4 | LOW - Scanning only | LOW (inject scanner service) |
| network_topology_analyzer.dart | 3 | LOW - Quality queries | LOW (pass service) |
| connection_quality_monitor.dart | 3 | LOW - Signal queries | LOW (pass service) |
| security_state_computer.dart | 2 | LOW - State queries | LOW (pass service) |
| ble_message_handler.dart | ~2 | MEDIUM - Dependency | MEDIUM (update DI) |
| message_router.dart | ~2 | MEDIUM - Dependency | MEDIUM (update DI) |
| Fake/Test helpers | 5+ | MEDIUM - Mock implementation | MEDIUM (extend interfaces) |

---

## CONFIDENCE ASSESSMENT

### No Duplicates (20%): ✅ 100%
- Single BLEService implementation (not duplicated elsewhere)
- No hidden BLE orchestrators in other services
- Clean separation: BLEService handles BLE, SecurityManager handles Noise

### Architecture Compliance (20%): ✅ 95%
- Follows Repository pattern (BLEService → BLEMessageHandler, BLEStateManager)
- Follows Service layer pattern (orchestrator wrapping managers)
- Layers intact: Presentation uses providers, providers use BLEService
- Minor caveat: Some state queries in UI (discovery_overlay) should be provider-based (Phase 3 improvement)

### Official Docs Verified (15%): ✅ 90%
- ✅ BLE GATT spec reviewed (MTU negotiation, connection phases)
- ✅ Bluetooth_low_energy package API reviewed (CentralManager, PeripheralManager)
- ✅ Noise Protocol XX handshake spec (4 phases)
- Minor: No external BLE split patterns found (custom design)

### Working Reference (15%): ✅ 80%
- ✅ FakeBleService in tests shows extension pattern works
- ✅ BLEConnectionManager/BLEMessageHandler show service decomposition pattern
- ✅ BLEStateManager shows state management separation
- Gap: No split-from-monolith Dart BLE examples (but pattern is standard)

### Root Cause Identified (15%): ✅ 95%
- ✅ God class is 3,431 lines across 6 distinct responsibilities
- ✅ Each sub-service naturally encapsulates one responsibility
- ✅ Consumer dependencies clear: some use connection state, some use messaging, some use discovery
- ✅ Risk: Write queue/buffer sharing (need careful extraction)

### Codex Second Opinion (15%): ⏳ Pending
- Will consult after presenting plan to user

### OVERALL CONFIDENCE: 92% ✅
- **Action**: Proceed with detailed plan and get user approval before implementation
- **Why**: Clear boundaries, natural decomposition, low architectural risk, but requires careful testing
