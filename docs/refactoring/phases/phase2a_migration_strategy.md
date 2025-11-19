# Phase 2A: BLEService Split - Detailed Migration Strategy

## Overview

Split BLEService (3,432 lines) into 6 focused services + 1 facade. This document details the SAFE, INCREMENTAL approach to avoid breaking the app.

**Total Effort**: 2-3 weeks (with daily real device testing)
**Risk Level**: MEDIUM (high payoff, managed with incremental testing)
**Test Coverage Target**: 97%+ (must maintain or exceed current 95.3%)

---

## Migration Strategy: Three-Phase Approach

### Phase 2A.2.1: Create Stub Services (Delegate Pattern)
- Create each service implementation with delegation to BLEService
- All logic still in BLEService, services just wrap it
- Tests pass immediately (no behavioral change)
- **Duration**: 1-2 days
- **Risk**: NONE (pure additive)

### Phase 2A.2.2: Gradual Code Movement (Service by Service)
- Move code from BLEService → specific service
- Test each service independently
- Update BLEService to delegate to service
- **Duration**: 1-2 weeks (2-3 days per service)
- **Risk**: MEDIUM (mitigated by incremental testing)

### Phase 2A.2.3: Consumer Migration
- Update consumers to use sub-services
- Maintain facade for backward compatibility
- Remove facade once all consumers migrated
- **Duration**: 3-5 days
- **Risk**: LOW (facade remains as fallback)

---

## Detailed Service Extraction Order

### Why This Order?

1. **BLEAdvertisingService** (START HERE)
   - Smallest (200 lines)
   - Least dependencies
   - Easiest to test independently
   - Low impact if something breaks

2. **BLEDiscoveryService** (NEXT)
   - Small (300 lines)
   - Dependencies mostly unidirectional
   - Used by DiscoveryOverlay (easy to test in UI)

3. **BLEConnectionService** (THIRD)
   - Medium (500 lines)
   - Core orchestration point
   - Many consumers
   - Must work perfectly

4. **BLEMessagingService** (FOURTH)
   - Large (400 lines)
   - Complex encryption integration
   - Critical path (messages must not break!)

5. **BLEHandshakeService** (FIFTH)
   - Largest (600 lines)
   - Most complex state machine
   - Most test coverage needed

6. **BLEServiceFacade** (FINAL)
   - Orchestrator (500 lines)
   - Delegates to all 5 services
   - Public API layer

---

## ✅ COMPLETED - Service 1: BLEAdvertisingService (200 lines)

### Methods to Extract
```
- startAsPeripheral()
- startAsPeripheralWithValidation()
- refreshAdvertising()
- startAsCentral()
```

### Properties to Extract
```
- _advertisingManager
- _peripheralInitializer
- _peripheralNegotiatedMTU
- _peripheralMtuReady
- _connectedCentral (shared with connection service)
- _connectedCharacteristic (shared with connection service)
- _peripheralHandshakeStarted (shared)
```

### Step 2A.2.1.1: Create Stub
```dart
// lib/data/services/ble_advertising_service.dart

class BLEAdvertisingService implements IBLEAdvertisingService {
  final BLEService _bleService;  // Delegate to this initially

  BLEAdvertisingService(this._bleService);

  @override
  Future<void> startAsPeripheral() => _bleService.startAsPeripheral();
  // ... all methods delegate
}
```

### Step 2A.2.1.2: Move Code from BLEService
```dart
// In BLEAdvertisingService (now owned here):
final AdvertisingManager _advertisingManager;
final PeripheralInitializer _peripheralInitializer;
int? _peripheralNegotiatedMTU;
bool _peripheralMtuReady = false;

// Extract actual implementation:
@override
Future<void> startAsPeripheral() async {
  _logger.info('📡 Starting peripheral advertising (dual-role mode)...');
  // ... (move lines 1979-2063 from BLEService)
}
```

### Step 2A.2.1.3: Update BLEService
```dart
// In BLEService:
late final BLEAdvertisingService _advertisingService;

@override
Future<void> startAsPeripheral() => _advertisingService.startAsPeripheral();

@override
Future<void> refreshAdvertising({bool? showOnlineStatus}) =>
  _advertisingService.refreshAdvertising(showOnlineStatus: showOnlineStatus);
```

### Tests for BLEAdvertisingService
```
test/services/ble_advertising_service_test.dart
- ✅ startAsPeripheral() initializes GATT service
- ✅ startAsPeripheral() starts advertising
- ✅ startAsPeripheral() skips if already advertising
- ✅ refreshAdvertising() updates advertising data
- ✅ refreshAdvertising() fails if not in peripheral mode
- ✅ startAsCentral() stops advertising
- ✅ startAsCentral() clears peripheral state
- ✅ Integration: startAsPeripheral → refreshAdvertising → startAsCentral
```

### Real Device Test
- Start app → Check Bluetooth settings → Device visible as "PakConnect"
- Change name in settings → Device name updates in Bluetooth list
- Restart app → Device still advertising

---

## Service 2: BLEDiscoveryService (300 lines)

### Methods to Extract
```
- startScanning()
- stopScanning()
- startScanningWithValidation()
- scanForSpecificDevice()
```

### Properties to Extract
```
- _discoveredDevices
- _devicesController
- _hintMatchController
- _isDiscoveryActive
- _currentScanningSource
- _setupDeduplicationListener()  (partially)
- buildLocalCollisionHint()
```

### Tests (8 tests)
```
- ✅ startScanning() begins central discovery
- ✅ stopScanning() stops discovery
- ✅ startScanningWithValidation() defers if BT unavailable
- ✅ scanForSpecificDevice() finds target device
- ✅ scanForSpecificDevice() times out when device not found
- ✅ Duplicate devices are deduplicated
- ✅ Hint matches are detected
- ✅ Integration: startScanning → scanForSpecificDevice → stopScanning
```

---

## Service 3: BLEConnectionService (500 lines)

### Methods to Extract
```
- connectToDevice()
- disconnect()
- startConnectionMonitoring()
- stopConnectionMonitoring()
- setHandshakeInProgress()
- getConnectionInfoWithFallback()
- attemptIdentityRecovery()
- _updateConnectionInfo()
- _shouldEmitConnectionInfo()
- _setupAutoConnectCallback()
- _setupEventListeners() (connection-specific)
- _onBluetoothBecameReady()
- _onBluetoothBecameUnavailable()
```

### Properties to Extract
```
- _connectionInfoController
- _currentConnectionInfo
- _lastEmittedConnectionInfo
- _connectionManager
- All connection state getters (isConnected, currentDevice, etc.)
```

### Tests (8 tests)
```
- ✅ connectToDevice() initiates connection
- ✅ disconnect() terminates connection
- ✅ Connection state updates broadcast correctly
- ✅ Auto-connect enabled → connects to known contact
- ✅ Auto-connect disabled → skips auto-connect
- ✅ Identity recovery from storage
- ✅ Bluetooth unavailable → connection deferred
- ✅ Integration: Scan → Connect → Handshake → Messages
```

---

## Service 4: BLEMessagingService (400 lines)

### Methods to Extract
```
- sendMessage()
- sendPeripheralMessage()
- sendQueueSyncMessage()
- _sendIdentityExchange()
- _sendPeripheralIdentityExchange()
- _sendHandshakeMessage()
- _sendProtocolMessage()
- _processWriteQueue()
- _processMessage()
- _handleReceivedData()
- _processPendingMessages()
```

### Properties to Extract
```
- _messagesController
- _messageHandler
- _writeQueue
- _isProcessingWriteQueue
- _messageBuffer
- _protocolMessageReassembler
```

### Tests (8 tests)
```
- ✅ sendMessage() encrypts and fragments message
- ✅ sendMessage() queues write operations
- ✅ sendPeripheralMessage() sends from peripheral mode
- ✅ Received messages are decrypted and emitted
- ✅ Message buffer holds messages before identity
- ✅ Write queue serializes BLE writes (no concurrent errors)
- ✅ Protocol ACK sent for received messages
- ✅ Integration: Full send/receive cycle
```

---

## Service 5: BLEHandshakeService (600 lines)

### Methods to Extract
```
- performHandshake()
- onHandshakeComplete()
- disposeHandshakeCoordinator()
- requestIdentityExchange()
- triggerIdentityReExchange()
- buildLocalCollisionHint()
- handleMutualConsentRequired()
- handleAsymmetricContact()
- _handleSpyModeDetected()
- _handleIdentityRevealed()
```

### Properties to Extract
```
- _handshakeCoordinator
- _handshakePhaseSubscription
- _peripheralHandshakeStarted
- _meshNetworkingStarted
- _spyModeDetectedController
- _identityRevealedController
- _messageBuffer (partially)
```

### Tests (8 tests)
```
- ✅ Handshake progresses through 4 phases
- ✅ Identity exchange sets user names
- ✅ Spy mode detection triggers correctly
- ✅ Identity exposure detection works
- ✅ Collision detection resolves device conflicts
- ✅ Buffered messages processed after handshake
- ✅ Handshake timeout → recovery attempt
- ✅ Integration: Full handshake cycle (XX pattern)
```

---

## Service 6: BLEServiceFacade (500 lines)

### Responsibility
- Initialize all 5 services in correct order
- Provide unified public API (implements all 5 interfaces)
- Coordinate cross-service concerns
- Manage Bluetooth state monitoring
- Integrate mesh networking

### Implementation Pattern
```dart
class BLEServiceFacade implements IBLEServiceFacade {
  late final BLEAdvertisingService _advertisingService;
  late final BLEDiscoveryService _discoveryService;
  late final BLEConnectionService _connectionService;
  late final BLEMessagingService _messagingService;
  late final BLEHandshakeService _handshakeService;

  @override
  Future<void> initialize() async {
    // 1. Create all sub-services
    // 2. Call initialize() on each
    // 3. Wire event listeners
    // 4. Start Bluetooth monitoring
  }

  // Delegation:
  @override
  Future<void> connectToDevice(Peripheral device) =>
    _connectionService.connectToDevice(device);

  // Sub-service access:
  @override
  IBLEConnectionService get connectionService => _connectionService;
}
```

### Tests (5 tests)
```
- ✅ All services initialized in correct order
- ✅ Bluetooth state monitoring active
- ✅ Cross-service event wiring works
- ✅ Mesh networking callbacks registered
- ✅ Proper cleanup on dispose()
```

---

## Testing Strategy

### Unit Tests (Per Service): 40+ tests
- Each service tested in isolation
- Mock external dependencies
- Test state transitions
- **Target**: 95%+ coverage per service

### Integration Tests: 20+ tests
- Test multi-service interactions
- Example: Scan → Connect → Handshake → Message
- Use FakeBleService for realistic testing
- **Target**: 100% critical path coverage

### Real Device Tests: Daily
- Each day, test on physical devices:
  - Connection establishment
  - Message send/receive
  - Device discovery
  - Advertising visibility
  - Handshake completion
- **Frequency**: Once per service extraction + daily final check
- **Devices**: 2+ phones (both central and peripheral modes)

---

## Validation Gates (Must Pass Before Proceeding)

### Gate 1: Stub Services Created
- ✅ 6 service stubs compile
- ✅ All 1,000+ existing tests pass
- ✅ No behavioral changes (stubs just delegate)

### Gate 2: After Each Service Extraction
- ✅ Unit tests for service pass (100%)
- ✅ All 1,000+ existing tests pass
- ✅ Real device testing successful
- ✅ No regressions in consumer files

### Gate 3: All Services Extracted
- ✅ All 40+ service unit tests pass
- ✅ All 1,000+ existing tests pass
- ✅ All 20+ integration tests pass
- ✅ Real device testing successful (all critical paths)

### Gate 4: Consumers Updated
- ✅ All consumer files updated
- ✅ All 1,000+ tests pass
- ✅ Real device smoke test (5-minute usage)

---

## Fallback Strategy (If Something Breaks)

1. **Service extraction breaks tests**:
   - Roll back to facade pattern (keep delegation)
   - Extract code more carefully

2. **Consumer migration breaks app**:
   - Revert consumer to using facade
   - Consumer can remain using old API indefinitely

3. **Real device issue discovered**:
   - Revert that service's extraction
   - File bug report with specific error
   - Schedule for later refactoring

---

## Estimated Timeline

| Phase | Duration | Days |
|-------|----------|------|
| 2A.2.1: Stubs | 1-2 days | 2 |
| 2A.2.2a: BLEAdvertisingService | 2-3 days | 3 |
| 2A.2.2b: BLEDiscoveryService | 2-3 days | 3 |
| 2A.2.2c: BLEConnectionService | 2-3 days | 3 |
| 2A.2.2d: BLEMessagingService | 2-3 days | 3 |
| 2A.2.2e: BLEHandshakeService | 3-4 days | 4 |
| 2A.2.2f: BLEServiceFacade | 1-2 days | 2 |
| 2A.2.3: Consumer Migration | 2-3 days | 3 |
| 2A: Real Device Testing | 2-3 days | 3 |
| **TOTAL** | | **24-26 days** |

**Compressed Timeline** (with parallelization): 2-3 weeks

---

## Success Criteria

- ✅ 6 focused services, each <700 lines
- ✅ Single responsibility per service
- ✅ 1,000+ tests pass (same or better)
- ✅ Real device testing successful (all critical paths)
- ✅ Code is cleaner and more maintainable
- ✅ Each service can be tested independently
- ✅ Each service can be replaced/mocked easily

---

## Next Steps

1. User approval of strategy
2. Create 6 service stubs (1-2 days)
3. Start with BLEAdvertisingService extraction (2-3 days)
4. Progress through remaining services
5. Daily real device testing
6. Update consumers once all services stable

