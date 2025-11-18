# BLE Service Extraction Analysis

## Overall Structure Analysis

**File Size**: 3,431 lines total
**Class**: BLEService (monolithic service managing all BLE concerns)

## Extraction Strategy

### Recommended Extraction Order (by dependency)

**Phase 1** (Foundation - No Dependencies):
1. **BLEAdvertisingService** - Advertising only (lines 1979-2099)
2. **BLEDiscoveryService** - Scanning/discovery only (lines 2160-2285)
3. **BLEMessagingService** - Message send/receive (lines 2790-3012)

**Phase 2** (Depends on Phase 1):
4. **BLEConnectionService** - Connection lifecycle (lines 2286-2343)

**Phase 3** (Depends on all previous):
5. **BLEHandshakeService** - Handshake protocol (lines 2345-2780)

---

## 1. BLEAdvertisingService

**Responsibility**: Manage peripheral mode advertising

### Line Ranges
```
Lines 1979-2099: startAsPeripheral() and refreshAdvertising()
Related state: _advertisingManager (lines 89-90, 329-334)
```

### Key Methods to Extract
```dart
Future<void> startAsPeripheral()                    // Lines 1979-2063
Future<void> refreshAdvertising({...})             // Lines 2068-2099
Future<String?> _buildLocalCollisionHint()         // Lines 2428-2464
Future<void> _sendPeripheralIdentityExchange()     // Lines 2384-2426
```

### State/Fields Required
```dart
// From BLEService (need to pass as constructor parameters or via interface)
PeripheralManager peripheralManager                // Line 75
BLEStateManager _stateManager                      // Line 80
AdvertisingManager _advertisingManager             // Line 90
PeripheralInitializer _peripheralInitializer       // Line 87
BLEConnectionManager _connectionManager            // Line 78
Logger _logger                                      // Line 67
IntroHintRepository _introHintRepo                 // Line 98

// Local fields specific to advertising
Central? _connectedCentral                         // Line 127
GATTCharacteristic? _connectedCharacteristic       // Line 128
int? _peripheralNegotiatedMTU                      // Line 135

// Callback interfaces needed
Function _updateConnectionInfo                     // Used in lines 2048-2051, 2087-2090
```

### Shared Dependencies
- **AdvertisingManager** - Already extracted, wraps low-level advertising
- **PeripheralInitializer** - Already extracted, handles service setup
- **BLEStateManager** - Shared state (mode flags, username, identity)
- **IntroHintRepository** - For collision hint generation
- **ConnectionInfo emission** - Via _connectionInfoController stream

### Key Invariants to Maintain
```
1. Advertising ONLY happens in peripheral mode (_stateManager.isPeripheralMode == true)
2. MTU negotiation MUST complete before sending messages (peripheral mode)
3. Identity in advertising payload is myPublicKey (persistent key)
4. Advertising refresh preserves online status preference
```

---

## 2. BLEDiscoveryService

**Responsibility**: Central mode device discovery and scanning

### Line Ranges
```
Lines 2160-2285: startScanning(), stopScanning(), related discovery logic
Lines 124: _discoveredDevices list
Lines 151-152: _isDiscoveryActive, _currentScanningSource
```

### Key Methods to Extract
```dart
Future<void> startScanning({ScanningSource source = ScanningSource.system})  // Lines 2160-2260
Future<void> stopScanning()                                                   // Lines 2262-2285
Future<Peripheral?> scanForSpecificDevice({...})                            // Lines 3078-3083
```

### State/Fields Required
```dart
// From BLEService
CentralManager centralManager                      // Line 74
BLEStateManager _stateManager                      // Line 80
BLEConnectionManager _connectionManager            // Line 78
Logger _logger                                      // Line 67
IntroHintRepository _introHintRepo                 // Line 98

// Local discovery state
List<Peripheral> _discoveredDevices                // Line 124
bool _isDiscoveryActive                            // Line 151
ScanningSource? _currentScanningSource             // Line 152
DeviceDeduplicationManager (imported but not shown) // Line 21

// Stream controllers
StreamController<List<Peripheral>>? _devicesController       // Line 112
StreamController<Map<String, DiscoveredEventArgs>>? _discoveryDataController  // Line 114

// Callback interface
Function _updateConnectionInfo                     // For status updates
```

### Shared Dependencies
- **CentralManager** - Low-level BLE scanning
- **BLEStateManager** - Session identity for filtering
- **DeviceDeduplicationManager** - Duplicate detection during scanning
- **ScanningSource enum** - Already exists (lines 43-47)
- **BLEConnectionManager** - For power mode coordination

### Key Invariants to Maintain
```
1. Only ONE scanning source active at a time (manual takes priority over burst)
2. Scanning stops when connecting to device
3. Discovered devices list excludes self (deduplication via MAC or ephemeral ID)
4. Scanning conflicts resolve: manual > burst > system
```

---

## 3. BLEMessagingService

**Responsibility**: Send and receive encrypted messages, handle fragmentation

### Line Ranges
```
Lines 2790-2834: sendMessage()
Lines 2836-2915: sendPeripheralMessage()
Lines 2918-2997: _sendProtocolMessage()
Lines 2999-3012: _processWriteQueue()
Lines 3014-3077: _sendIdentityExchange()
Lines 1448-1476: _processPendingMessages()
Lines 1494-1762: _handleReceivedData() - PRIMARY RECEIVER (large method)
Lines 1724-1761: looksLikeChunkStringLocal() helper
Lines 1400-1447: _handleReceivedData setup in _setupEventListeners()
```

### Key Methods to Extract
```dart
Future<bool> sendMessage(String message, {...})              // Lines 2790-2834
Future<bool> sendPeripheralMessage(String message, {...})   // Lines 2836-2915
Future<void> _sendProtocolMessage(ProtocolMessage message)   // Lines 2918-2997
Future<void> _processWriteQueue()                            // Lines 2999-3012
Future<void> _sendIdentityExchange()                         // Lines 3014-3077
void _processPendingMessages()                               // Lines 1448-1476
void _handleReceivedData(Uint8List data, {...})             // Lines ~1400-1762
```

### State/Fields Required
```dart
// From BLEService
CentralManager centralManager                      // Line 74
PeripheralManager peripheralManager                // Line 75
BLEConnectionManager _connectionManager            // Line 78
BLEMessageHandler _messageHandler                  // Line 79
BLEStateManager _stateManager                      // Line 80
ContactRepository _contactRepo                     // Line 97
Logger _logger                                      // Line 67

// Message buffering and reassembly
final List<_BufferedMessage> _messageBuffer        // Line 146
final MessageReassembler _protocolMessageReassembler  // Line 149
String? extractedMessageId                         // Line 143

// Write queue for serialized writes
List<Future<void> Function()> _writeQueue           // ~3080 (referenced in code)
bool _isProcessingWriteQueue                       // ~3082 (referenced in code)

// Peripheral mode specific
Central? _connectedCentral                         // Line 127
GATTCharacteristic? _connectedCharacteristic       // Line 128
int? _peripheralNegotiatedMTU                      // Line 135
bool _peripheralMtuReady                           // Line 136

// Stream controllers
StreamController<String>? _messagesController      // Line 113
StreamController<SpyModeInfo>? _spyModeDetectedController  // Line 116
StreamController<String>? _identityRevealedController      // Line 117

// Callbacks (to be injected)
Function _updateConnectionInfo
Function _handleSpyModeDetected
Function _handleIdentityRevealed
void Function(ProtocolMessage, String)? onSendRelayMessage
```

### Shared Dependencies
- **BLEMessageHandler** - Low-level message sending logic (already extracted)
- **MessageFragmenter** - Fragmentation/reassembly (already extracted)
- **MessageReassembler** - Protocol message reconstruction
- **ProtocolMessage** - Message type definitions
- **BLEConstants** - MTU and message sizes
- **SecurityManager** - Message encryption (called from BLEMessageHandler)

### Key Invariants to Maintain
```
1. Protocol messages MUST be fragmented before sending (not sent as binary)
2. Write queue MUST serialize all BLE writes to prevent GATT congestion
3. Peripheral mode messages use notifyCharacteristic, central uses writeCharacteristic
4. Messages buffered until identity exchange completes
5. MTU negotiation MUST complete before sending from peripheral mode
6. Recipient ID selection: persistent if paired, ephemeral otherwise
```

---

## 4. BLEConnectionService

**Responsibility**: Connection lifecycle (connect, disconnect, monitor state)

### Line Ranges
```
Lines 2286-2343: connectToDevice()
Lines 1979-2157: startAsPeripheral(), startAsCentral() mode switching
Lines 3055-3077: disconnect(), startConnectionMonitoring(), stopConnectionMonitoring()
Lines 3055-3077: setHandshakeInProgress()
```

### Key Methods to Extract
```dart
Future<void> connectToDevice(Peripheral device)           // Lines 2286-2343
Future<void> startConnectionMonitoring()                  // ~3055 (referenced)
Future<void> stopConnectionMonitoring()                   // ~3060 (referenced)
void setHandshakeInProgress(bool inProgress)              // ~3070 (referenced)
Future<void> disconnect()                                 // ~3050 (referenced)
```

### State/Fields Required
```dart
// From BLEService
CentralManager centralManager                      // Line 74
PeripheralManager peripheralManager                // Line 75
BLEConnectionManager _connectionManager            // Line 78
BLEStateManager _stateManager                      // Line 80
Logger _logger                                      // Line 67

// Connection state (from BLEStateManager, passed via interface)
bool _peripheralHandshakeStarted                   // Line 130
bool _meshNetworkingStarted                        // Line 132

// Peripheral specific
Central? _connectedCentral                         // Line 127
GATTCharacteristic? _connectedCharacteristic       // Line 128

// Callback interface
Function _updateConnectionInfo
Function _performHandshake                         // Triggered after connect
Function startAsPeripheral                         // Mode switching
```

### Shared Dependencies
- **BLEConnectionManager** - Connection state machine (already extracted)
- **BLEStateManager** - Session state
- **CentralManager** - Low-level connection
- **PeripheralManager** - Low-level peripheral connection

### Key Invariants to Maintain
```
1. Single-link policy: Adopt inbound link if exists for same peer
2. Connect stops any active discovery
3. Health checks started ONLY for manual connections (not reconnections)
4. Connection adoption from peripheral role respected
5. Session identity preserved across mode switches
```

---

## 5. BLEHandshakeService

**Responsibility**: Handshake protocol coordination and identity exchange

### Line Ranges
```
Lines 2345-2426: requestIdentityExchange(), triggerIdentityReExchange(), 
                 _sendPeripheralIdentityExchange()
Lines 2428-2464: _buildLocalCollisionHint()
Lines 2466-2710: _performHandshake() - CORE HANDSHAKE LOGIC
Lines 2618-2710: _sendHandshakeMessage(), _onHandshakeComplete()
Lines 2724-2780: _getPhaseMessage(), _handleSpyModeDetected(), 
                 _handleIdentityRevealed(), _isHandshakeMessage()
Lines 1494-1699: _processMessage() - RECEIVES AND ROUTES PROTOCOL MESSAGES
Lines 1500-1510: Route to handshake coordinator
Lines 2711: _disposeHandshakeCoordinator()
```

### Key Methods to Extract
```dart
Future<void> requestIdentityExchange()                           // Lines 2345-2354
Future<void> triggerIdentityReExchange()                        // Lines 2357-2381
Future<void> _sendPeripheralIdentityExchange()                  // Lines 2384-2426
Future<String?> _buildLocalCollisionHint()                      // Lines 2428-2464
Future<void> _performHandshake({bool? startAsInitiatorOverride})  // Lines 2466-2610
Future<void> _sendHandshakeMessage(ProtocolMessage message)     // Lines 2618-2710
void _onHandshakeComplete(...)                                  // Lines ~2700 (referenced)
void _disposeHandshakeCoordinator()                             // Lines 2711-2722
String _getPhaseMessage(ConnectionPhase phase)                  // Lines 2724-2757
void _handleSpyModeDetected(SpyModeInfo info)                   // Lines 2758-2767
void _handleIdentityRevealed(String contactName)                // Lines 2769-2778
bool _isHandshakeMessage(ProtocolMessageType type)              // Lines 2780-2788
void _processMessage(ProtocolMessage message, bool isFromPeripheral, ...) // Lines 1494-1762
```

### State/Fields Required
```dart
// From BLEService
CentralManager centralManager                      // Line 74
PeripheralManager peripheralManager                // Line 75
BLEConnectionManager _connectionManager            // Line 78
BLEStateManager _stateManager                      // Line 80
ContactRepository _contactRepo                     // Line 97
IntroHintRepository _introHintRepo                 // Line 98
Logger _logger                                      // Line 67
MessageRepository (implicit in lines 1584)         // Data access
ChatsRepository (implicit in lines 1604)           // Data access

// Handshake coordination
HandshakeCoordinator? _handshakeCoordinator        // Line 83
StreamSubscription<ConnectionPhase>? _handshakePhaseSubscription  // Line 84

// Peripheral connection tracking
Central? _connectedCentral                         // Line 127
GATTCharacteristic? _connectedCharacteristic       // Line 128
bool _peripheralHandshakeStarted                   // Line 130

// Message buffering during handshake
final List<_BufferedMessage> _messageBuffer        // Line 146

// Stream controllers
StreamController<String>? _messagesController      // Line 113
StreamController<SpyModeInfo>? _spyModeDetectedController  // Line 116
StreamController<String>? _identityRevealedController      // Line 117

// Callback interfaces
Function _updateConnectionInfo
Function _sendProtocolMessage                      // For handshake message sends
Function _processPendingMessages                   // After identity exchange
```

### Shared Dependencies
- **HandshakeCoordinator** - Noise protocol state machine (already extracted)
- **EphemeralKeyManager** - Ephemeral ID generation
- **HintAdvertisementService** - Collision hint derivation
- **MessageRepository** - Check for existing chat history
- **ChatsRepository** - Device mapping and contact tracking
- **ProtocolMessage** - Message types and serialization
- **BLEMessageHandler** - Receives raw data that feeds into _processMessage

### Key Invariants to Maintain
```
1. Handshake messages buffered until coordinator ready
2. Handshake coordinator ONLY receives handshake-type messages
3. Identity exchange MUST complete before contact saving
4. Ephemeral ID from EphemeralKeyManager, NOT BLEStateManager
5. Contact only saved if existing chat history or after pairing
6. Persistent key exchange distinct from identity exchange
7. Handshake timeout = 10 seconds per phase
8. Spy mode detection via MAC address collision
```

---

## Shared State Between Services (Dependency Graph)

```
BLEService (Facade)
├── BLEAdvertisingService
│   └── Shared: BLEStateManager, AdvertisingManager, BLEConnectionManager
├── BLEDiscoveryService
│   └── Shared: BLEStateManager, BLEConnectionManager
├── BLEConnectionService
│   ├── Depends: BLEAdvertisingService (startAsPeripheral)
│   ├── Depends: BLEDiscoveryService (stopScanning)
│   └── Shared: BLEStateManager, BLEConnectionManager
├── BLEMessagingService
│   ├── Depends: BLEConnectionService (hasBleConnection)
│   └── Shared: BLEMessageHandler, BLEConnectionManager, BLEStateManager
└── BLEHandshakeService
    ├── Depends: BLEMessagingService (_sendProtocolMessage)
    ├── Depends: BLEConnectionService (connection state)
    └── Shared: HandshakeCoordinator, BLEStateManager, ContactRepository
```

---

## Stream Controllers and Public API

Each service will expose its own streams:

```dart
// BLEAdvertisingService
Stream<ConnectionInfo> get advertisingStatus  // From _connectionInfoController

// BLEDiscoveryService
Stream<List<Peripheral>> get discoveredDevices     // _devicesController
Stream<Map<String, DiscoveredEventArgs>> get discoveryData  // _discoveryDataController

// BLEMessagingService
Stream<String> get receivedMessages           // _messagesController

// BLEHandshakeService
Stream<SpyModeInfo> get spyModeDetected       // _spyModeDetectedController
Stream<String> get identityRevealed           // _identityRevealedController
Stream<ConnectionInfo> get handshakeStatus    // From _connectionInfoController

// BLEConnectionService
Stream<ConnectionInfo> get connectionStatus   // _connectionInfoController
```

---

## Constructor Requirements Per Service

```dart
// BLEAdvertisingService constructor
BLEAdvertisingService({
  required PeripheralManager peripheralManager,
  required BLEStateManager stateManager,
  required AdvertisingManager advertisingManager,
  required PeripheralInitializer peripheralInitializer,
  required BLEConnectionManager connectionManager,
  required IntroHintRepository introHintRepo,
  required BLEServiceFacade facade,  // For callbacks
});

// BLEDiscoveryService constructor
BLEDiscoveryService({
  required CentralManager centralManager,
  required BLEStateManager stateManager,
  required BLEConnectionManager connectionManager,
  required BLEServiceFacade facade,  // For callbacks
});

// BLEConnectionService constructor
BLEConnectionService({
  required CentralManager centralManager,
  required PeripheralManager peripheralManager,
  required BLEStateManager stateManager,
  required BLEConnectionManager connectionManager,
  required BLEAdvertisingService advertisingService,
  required BLEDiscoveryService discoveryService,
  required BLEServiceFacade facade,  // For callbacks
});

// BLEMessagingService constructor
BLEMessagingService({
  required CentralManager centralManager,
  required PeripheralManager peripheralManager,
  required BLEConnectionManager connectionManager,
  required BLEMessageHandler messageHandler,
  required BLEStateManager stateManager,
  required BLEServiceFacade facade,  // For callbacks
});

// BLEHandshakeService constructor
BLEHandshakeService({
  required CentralManager centralManager,
  required PeripheralManager peripheralManager,
  required BLEStateManager stateManager,
  required BLEConnectionManager connectionManager,
  required ContactRepository contactRepo,
  required IntroHintRepository introHintRepo,
  required BLEMessagingService messagingService,
  required BLEConnectionService connectionService,
  required BLEServiceFacade facade,  // For callbacks
});
```

---

## Testing Considerations

### BLEAdvertisingService Tests
- Peripheral mode initialization
- Advertising start/stop
- MTU negotiation
- Collision hint generation
- Online status refresh

### BLEDiscoveryService Tests
- Central mode scanning
- Device deduplication
- Scanning source priority (manual > burst > system)
- Connection interruption of scanning

### BLEMessagingService Tests
- Message fragmentation/reassembly
- Write queue serialization
- Central vs. peripheral send paths
- MTU size handling
- Identity exchange message routing

### BLEConnectionService Tests
- Device connection lifecycle
- Inbound link adoption (single-link policy)
- Mode switching state preservation
- Health check initialization

### BLEHandshakeService Tests
- Handshake coordinator lifecycle
- Message buffering before identity exchange
- Spy mode detection
- Identity persistence vs. ephemeral
- Phase timeout handling

---

## Migration Notes

1. **BLEServiceFacade** will coordinate between services via callback functions
2. **Stream controllers** remain in facade, services emit via callbacks
3. **_connectionInfoController** is the central connection state bus (used by all services)
4. **Message processing flow**: Raw data → Fragmentation layer → Protocol message → Service routing
5. **Initialization order**: Advertising → Discovery → Connection → Messaging → Handshake
