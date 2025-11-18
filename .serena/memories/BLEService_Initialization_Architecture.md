# BLEService Initialization Architecture

## Executive Summary

BLEService uses a **lazy initialization pattern** with the following flow:
1. **Provider creates empty BLEService instance** (no managers yet)
2. **Waits for AppCore to fully initialize** (especially messageQueue)
3. **Calls BLEService.initialize()** which creates and wires all managers
4. **Initializes MessageRouter** after BLE service is ready

---

## 1. APPCORE INITIALIZATION ORDER (lib/core/app_core.dart)

AppCore follows this strict sequence in `AppCore.initialize()`:

```
1. Setup logging
2. Setup DI container (ServiceLocator)
3. Initialize repositories (DB, contacts, preferences)
4. Initialize message queue ⚠️ CRITICAL - must be before BLE
5. Initialize monitoring (PerformanceMonitor, AdaptiveEncryptionStrategy)
6. Initialize core services (SecurityManager, EphemeralKeyManager, TopologyManager, ContactService, ChatService)
7. Initialize BLE integration (currently just logging - BLEService creates its own BLEStateManager)
8. Initialize enhanced features (BatteryOptimizer, BurstScanningController)
9. Start integrated systems (AutoArchiveScheduler, burst scanning pre-initialization)
```

**Critical timing**: `messageQueue` MUST exist before BLE service can initialize (for GossipSyncManager).

---

## 2. BLESERVICE PROVIDER FLOW (lib/presentation/providers/ble_providers.dart)

### Stage 1: Lazy Provider Creation
```dart
final bleServiceProvider = Provider<BLEService>((ref) {
  final service = BLEService();  // ✅ NO initialization here
  ref.onDispose(() { service.dispose(); });
  return service;
});
```
- Creates empty BLEService instance
- No managers initialized
- No stream controllers created

### Stage 2: Wait for AppCore (bleServiceInitializedProvider)
```dart
final bleServiceInitializedProvider = FutureProvider<BLEService>((ref) async {
  final service = ref.watch(bleServiceProvider);
  
  // Poll until AppCore is initialized (max 10s)
  while (!AppCore.instance.isInitialized && attempts < 100) {
    await Future.delayed(Duration(milliseconds: 100));
  }
  
  // Now safe to initialize
  await service.initialize();
  await MessageRouter.initialize(service);
  return service;
});
```

### Stage 3: Burst Scanning Controller (depends on initialized BLE)
```dart
final burstScanningControllerProvider = FutureProvider<BurstScanningController>(...) {
  final controller = BurstScanningController();
  final bleService = await ref.watch(bleServiceInitializedProvider.future);
  await controller.initialize(bleService);
  await controller.startBurstScanning();
  return controller;
};
```

---

## 3. BLESERVICE INITIALIZATION (lib/data/services/ble_service.dart)

BLEService constructor:
```dart
class BLEService {
  final Completer<void> _initializationCompleter = Completer<void>();
  
  final CentralManager centralManager = CentralManager();
  final PeripheralManager peripheralManager = PeripheralManager();
  
  late final BLEConnectionManager _connectionManager;
  late final BLEMessageHandler _messageHandler;
  final BLEStateManager _stateManager = BLEStateManager();  // Created immediately
  
  // All other managers are late, created in initialize()
  late final PeripheralInitializer _peripheralInitializer;
  late final AdvertisingManager _advertisingManager;
  late final ConnectionCleanupHandler _cleanupHandler;
  late final HintScannerService _hintScanner;
  GossipSyncManager? _gossipSyncManager;
  OfflineMessageQueue? _offlineMessageQueue;
  
  // These are created before initialize() is called:
  final BluetoothStateMonitor _bluetoothStateMonitor = BluetoothStateMonitor.instance;
  final MessageReassembler _protocolMessageReassembler = MessageReassembler();
}
```

---

## 4. MANAGERS CREATED IN INITIALIZE() - EXACT ORDER

### Stream Controllers (Lines 268-285)
```dart
_connectionInfoController = StreamController<ConnectionInfo>.broadcast();
_devicesController = StreamController<List<Peripheral>>.broadcast();
_messagesController = StreamController<String>.broadcast();
_discoveryDataController = StreamController<Map<String, DiscoveredEventArgs>>.broadcast();
_hintMatchController = StreamController<String>.broadcast();
_spyModeDetectedController = StreamController<SpyModeInfo>.broadcast();
_identityRevealedController = StreamController<String>.broadcast();
```

### Core Managers (Lines 298-345)
1. **BLEConnectionManager** (lines 305-311)
   - Receives centralManager & peripheralManager
   - Receives PowerMode.balanced as default
   - setLocalHintProvider() called immediately
   
2. **BLEMessageHandler** (line 322)
   - No parameters
   
3. **BackgroundCacheService** (line 323)
   - Static initialize()

4. **PeripheralInitializer** (lines 326)
   - Receives peripheralManager
   
5. **AdvertisingManager** (lines 329-335)
   - Receives PeripheralInitializer, PeripheralManager, IntroHintRepository
   - Calls start() immediately
   
6. **ConnectionCleanupHandler** (lines 338-340)
   - No parameters
   - Calls start() immediately
   
7. **HintScannerService** (lines 343-345)
   - Receives ContactRepository
   - Calls initialize() async

### Bluetooth State Monitoring (Lines 347-390)
8. **BluetoothStateMonitor** (lines 350-355)
   - Already created in constructor
   - Calls initialize() with callbacks
   
- If Bluetooth ready → Start mesh networking
- If not → Defer until BluetoothStateMonitor callback fires

### Message Handler & State Manager Wiring (Lines 392-404)
```dart
_messageHandler.onContactRequestReceived = _stateManager.handleContactRequest;
_messageHandler.onContactAcceptReceived = _stateManager.handleContactAccept;
_messageHandler.onContactRejectReceived = _stateManager.handleContactReject;
_stateManager.onSpyModeDetected = _handleSpyModeDetected;
_stateManager.onIdentityRevealed = _handleIdentityRevealed;
_messageHandler.onIdentityRevealed = _handleIdentityRevealed;
```

### Relay & Queue Callbacks (Lines 406-415)
```dart
_messageHandler.onSendRelayMessage = (protocolMessage, nextHopId) async { ... };
// Queue sync callback will be set again after GossipSyncManager init
```

### EphemeralKeyManager Setup (Lines 417-434)
```dart
String? myEphemeralId;
try {
  myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
  _messageHandler.setCurrentNodeId(myEphemeralId);
} catch (e) {
  _logger.warning('⚠️ EphemeralKeyManager not ready yet...');
}
```

### GossipSyncManager (Lines 436-579)
9. **GossipSyncManager** (lines 456-461)
   - Requires AppCore to be initialized (checks for messageQueue access)
   - Receives myEphemeralId and AppCore.instance.messageQueue
   - Wires 3 callbacks: onSendSyncRequest, onSendSyncToPeer, onSendMessageToPeer
   - Queue sync callback wired to it
   - Started only if Bluetooth ready AND connection exists

### Connection Manager Callbacks (Lines 588-636)
```dart
_connectionManager.onConnectionChanged = (device) { ... };
_connectionManager.onConnectionInfoChanged = (info) { ... };
_connectionManager.onMonitoringChanged = (isMonitoring) { ... };
_connectionManager.onConnectionComplete = () async { ... };  // Triggers handshake
_connectionManager.onCentralDisconnected = (deviceAddress) { ... };  // Cleanup
```

### State Manager Initialization (Line 638)
```dart
await _stateManager.initialize();
```

### State Manager Callbacks (Lines 640-736)
```dart
_stateManager.onNameChanged = (name) { ... };
_stateManager.onSendPairingCode = (code) async { ... };
_stateManager.onSendPairingVerification = (hash) async { ... };
_stateManager.onSendPairingRequest = (message) async { ... };
_stateManager.onSendPairingAccept = (message) async { ... };
_stateManager.onSendPairingCancel = (message) async { ... };
_stateManager.onSendPersistentKeyExchange = (message) async { ... };
_stateManager.onSendContactRequest = (publicKey, displayName) async { ... };
```

---

## 5. DEPENDENCY GRAPH

```
AppCore (initializes first)
  ├── Database
  ├── Repositories
  ├── MessageQueue ⚠️ REQUIRED for GossipSyncManager
  ├── SecurityManager & EphemeralKeyManager
  └── TopologyManager

Provider Layer (waits for AppCore)
  ├── bleServiceProvider → BLEService()
  ├── bleServiceInitializedProvider → service.initialize()
  │   └── Creates all managers
  │   └── Initializes MessageRouter
  └── burstScanningControllerProvider → depends on bleServiceInitializedProvider

BLEService.initialize() (sequential)
  ├── Create stream controllers (7 total)
  ├── Create BLEConnectionManager
  ├── Create BLEMessageHandler
  ├── Create PeripheralInitializer
  ├── Create AdvertisingManager → start()
  ├── Create ConnectionCleanupHandler → start()
  ├── Create HintScannerService → initialize()
  ├── Initialize BluetoothStateMonitor → may trigger mesh networking
  ├── Wire message handler callbacks to state manager
  ├── Get ephemeral ID from EphemeralKeyManager
  ├── Create GossipSyncManager (requires AppCore.messageQueue) ⚠️
  ├── Wire GossipSyncManager callbacks
  ├── Initialize BLEStateManager
  └── Wire state manager callbacks
```

---

## 6. STREAM CONTROLLERS IN BLESERVICE

Total: **7 Stream Controllers** (all broadcast)

1. `_connectionInfoController` - ConnectionInfo updates
2. `_devicesController` - List<Peripheral> discovered devices
3. `_messagesController` - String received messages
4. `_discoveryDataController` - Map<String, DiscoveredEventArgs> discovery data with ads
5. `_hintMatchController` - String hint matches
6. `_spyModeDetectedController` - SpyModeInfo
7. `_identityRevealedController` - String contact name

All created in initialize() at lines 268-285, not in constructor.

---

## 7. CRITICAL INITIALIZATION REQUIREMENTS

### AppCore Must Complete FIRST
- `AppCore.instance.isInitialized == true` checked in line 442
- `AppCore.instance.messageQueue` required for GossipSyncManager (line 460)

### Pre-requisites for BLE Initialize
1. EphemeralKeyManager already initialized by AppCore (line 274)
2. SecurityManager already initialized by AppCore (line 265)
3. TopologyManager already initialized by AppCore (line 283)
4. Database already initialized (MessageRepository might be accessed)

### Timing Constraints
- Bluetooth state monitoring waits 5s for peripheral readiness
- Mesh networking deferred if Bluetooth not ready (callback drives later start)
- GossipSyncManager started only if Bluetooth ready AND connection exists

---

## 8. FACADE INITIALIZATION PATTERN (For New Code)

If building new facade, follow this order:

```dart
class BLEServiceFacade {
  late final BLEService _bleService;
  late final BLEConnectionManager _connectionManager;
  late final BLEMessageHandler _messageHandler;
  late final BLEStateManager _stateManager;
  late final AdvertisingManager _advertisingManager;
  late final GossipSyncManager _gossipSyncManager;
  
  Future<void> initialize(BLEService service) async {
    _bleService = service;
    // ✅ Managers are already created and wired by BLEService.initialize()
    _connectionManager = service.connectionManager;
    _stateManager = service.stateManager;
    _messageHandler = service._messageHandler; // private, might need getter
    _advertisingManager = service._advertisingManager; // private
    _gossipSyncManager = service._gossipSyncManager;
  }
}
```

**Key insight**: All managers are created and wired INSIDE `BLEService.initialize()`. Facade just needs to access them (may need public getters).

---

## 9. UNRESOLVED: IMPLICIT DEPENDENCIES

Some managers created but unclear initialization points:
- `BLEConnectionManager._limitConfig` - set in constructor from PowerMode
- `BLEConnectionManager._rssiThreshold` - set in constructor
- State for `_currentSessionId`, `_theirEphemeralId`, etc. - lazy on first use
- `_handshakeCoordinator` - created on-demand in `_performHandshake()`

These appear to have lazy initialization patterns - check those methods for full details.
