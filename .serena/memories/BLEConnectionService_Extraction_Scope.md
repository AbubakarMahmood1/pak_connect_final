# BLEConnectionService Extraction Scope (Line Numbers & Signatures)

**File**: `/home/abubakar/dev/pak_connect/lib/data/services/ble_service.dart`

**Total Extraction Size**: ~500 lines, 30+ methods and properties

---

## Connection-Related Properties (Private Fields)

### StreamControllers
| Line | Property | Type | Purpose |
|------|----------|------|---------|
| 111 | `_connectionInfoController` | `StreamController<ConnectionInfo>?` | Broadcasts connection state changes |

### State Properties
| Line | Property | Type | Purpose |
|------|----------|------|---------|
| 127 | `_connectedCentral` | `Central?` | Connected central (peripheral role) |
| 128 | `_connectedCharacteristic` | `GATTCharacteristic?` | GATT characteristic for peripheral messaging |
| 130 | `_peripheralHandshakeStarted` | `bool` | Tracks if peripheral handshake initiated |
| 132 | `_meshNetworkingStarted` | `bool` | Tracks if mesh networking started |
| 136 | `_peripheralMtuReady` | `bool` | Tracks MTU negotiation completion |
| 151 | `_isDiscoveryActive` | `bool` | Tracks active device discovery |
| 174 | `_lastEmittedConnectionInfo` | `ConnectionInfo?` | Last emitted state (deduplication) |
| 176 | `_currentConnectionInfo` | `ConnectionInfo` | Current connection state |
| 78 | `_connectionManager` | `late final BLEConnectionManager` | Core connection lifecycle manager |

### Dependency Injection Properties
| Line | Property | Type | Purpose |
|------|----------|------|---------|
| 79 | `_messageHandler` | `late final BLEMessageHandler` | Message handling orchestrator |
| 87 | `_peripheralInitializer` | `late final PeripheralInitializer` | Peripheral mode setup |
| 90 | `_advertisingManager` | `late final AdvertisingManager` | Advertising management |
| 93 | `_cleanupHandler` | `late final ConnectionCleanupHandler` | Cleanup coordination |

---

## Connection-Related Getters (Public API)

| Line | Getter | Return Type | Purpose |
|------|--------|-------------|---------|
| 157 | `currentConnectionInfo` | `ConnectionInfo` | Current connection state |
| 165 | `connectedCentral` | `Central?` | Get connected central (read-only) |
| 172 | `isBluetoothReady` | `bool` | Bluetooth adapter ready status |
| 184-211 | `isConnected` | `bool` | Is BLE + identity connected |
| 213 | `isPeripheralMode` | `bool` | Peripheral mode active |
| 214 | `isMonitoring` | `bool` | Connection monitoring active |
| 229-232 | `isActivelyReconnecting` | `bool` | Actively reconnecting |
| 234-236 | `hasPeripheralConnection` | `bool` | Has BLE + characteristic (peripheral) |
| 238-242 | `hasCentralConnection` | `bool` | Has BLE + characteristic (central) |
| 245-252 | `canSendMessages` | `bool` | Can send encrypted messages |
| 251 | `connectionManager` | `BLEConnectionManager` | Access to connection manager |
| 848-862 | `_authoritativeAdvertisingState` | `bool` | Get authoritative advertising state |

---

## Core Connection Methods

### Connection Lifecycle (Public)

**Method 1**: `connectToDevice(Peripheral device)`
- **Line**: 2286
- **Signature**: `Future<void> connectToDevice(Peripheral device) async`
- **Purpose**: Initiate outbound connection to device; handles single-link policy
- **Key Logic**: Adopts inbound link if exists, starts health checks, handles reconnection monitoring

**Method 2**: `disconnect()`
- **Line**: 3076
- **Signature**: `Future<void> disconnect() => _connectionManager.disconnect()`
- **Purpose**: Terminate current BLE connection
- **Key Logic**: Delegates to BLEConnectionManager

**Method 3**: `startConnectionMonitoring()`
- **Line**: 3070
- **Signature**: `void startConnectionMonitoring() => _connectionManager.startConnectionMonitoring()`
- **Purpose**: Start automatic reconnection monitoring
- **Key Logic**: Delegates to BLEConnectionManager

**Method 4**: `stopConnectionMonitoring()`
- **Line**: 3072
- **Signature**: `void stopConnectionMonitoring() => _connectionManager.stopConnectionMonitoring()`
- **Purpose**: Stop automatic reconnection monitoring
- **Key Logic**: Delegates to BLEConnectionManager

**Method 5**: `setHandshakeInProgress(bool inProgress)`
- **Line**: 3074
- **Signature**: `void setHandshakeInProgress(bool inProgress) => _connectionManager.setHandshakeInProgress(inProgress)`
- **Purpose**: Signal handshake state to connection manager
- **Key Logic**: Delegates to BLEConnectionManager

---

### Connection State Management (Public)

**Method 6**: `requestIdentityExchange()`
- **Line**: 2345
- **Signature**: `Future<void> requestIdentityExchange() async`
- **Purpose**: Manually trigger identity exchange with connected device
- **Key Logic**: Checks BLE + characteristic, calls `_sendIdentityExchange()`

**Method 7**: `getConnectionInfoWithFallback()`
- **Line**: 3084
- **Signature**: `Future<ConnectionInfo?> getConnectionInfoWithFallback() async`
- **Purpose**: Get connection info with fallback to persistent storage
- **Key Logic**: Returns null if not connected, retrieves identity via `_stateManager.getIdentityWithFallback()`, constructs ConnectionInfo

**Method 8**: `attemptIdentityRecovery()`
- **Line**: 3120
- **Signature**: `Future<bool> attemptIdentityRecovery() async`
- **Purpose**: Recover identity when BLE connected but session cleared
- **Key Logic**: Checks if recovery needed, calls `_stateManager.recoverIdentityFromStorage()`, updates connection info

---

### Connection State Update (Private)

**Method 9**: `_updateConnectionInfo({...})`
- **Line**: 864
- **Signature**: 
  ```dart
  void _updateConnectionInfo({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  })
  ```
- **Purpose**: Update and broadcast connection state
- **Key Logic**: 
  - Preserves advertising state if not provided (`_authoritativeAdvertisingState`)
  - Calls `_shouldEmitConnectionInfo()` for deduplication
  - Broadcasts via `_connectionInfoController`
  - Extensive logging with 🎯 emoji

**Method 10**: `_shouldEmitConnectionInfo(ConnectionInfo newInfo)`
- **Line**: 927
- **Signature**: `bool _shouldEmitConnectionInfo(ConnectionInfo newInfo)`
- **Purpose**: Deduplication filter for connection state updates
- **Key Logic**: Compares with `_lastEmittedConnectionInfo`, returns true if meaningful change detected
- **Checks**: isConnected, isReady, otherUserName, isScanning, isAdvertising, isReconnecting, statusMessage

---

## Setup & Initialization Methods

**Method 11**: `_setupAutoConnectCallback()`
- **Line**: 943
- **Signature**: `void _setupAutoConnectCallback()`
- **Purpose**: Register callback for known contact discovery
- **Key Logic**:
  - Sets `DeviceDeduplicationManager.onKnownContactDiscovered`
  - Checks auto-connect preference
  - Verifies connection slot availability
  - Checks if already connected
  - Calls `connectToDevice()` for auto-connect

**Method 12**: `_setupDeduplicationListener()`
- **Line**: 1020
- **Signature**: `void _setupDeduplicationListener()`
- **Purpose**: Listen to deduplicated device stream and clean stale devices
- **Key Logic**: 
  - Listens to `DeviceDeduplicationManager.uniqueDevicesStream`
  - Updates `_discoveredDevices` and broadcasts via `_devicesController`
  - Periodically calls `DeviceDeduplicationManager.removeStaleDevices()`

**Method 13**: `_setupEventListeners()`
- **Line**: 1043
- **Signature**: `void _setupEventListeners()`
- **Purpose**: Register BLE state change handlers
- **Key Logic**: 
  - Listens to `centralManager.stateChanged`
  - Handles Bluetooth power state changes (off/on)
  - Manages session clearing on power-off
  - Requests permissions on unauthorized state
  - Handles reconnection via `_connectionManager.handleBluetoothStateChange()`

---

## Bluetooth State Lifecycle

**Method 14**: `_onBluetoothBecameReady()`
- **Line**: 3179
- **Signature**: `void _onBluetoothBecameReady()`
- **Purpose**: Handle Bluetooth becoming available
- **Key Logic**:
  - Updates status: "Bluetooth ready for dual-role operation"
  - Starts deferred mesh networking if not started
  - Restarts mesh networking if advertising was lost
  - Includes 500ms delay to avoid race conditions

**Method 15**: `_onBluetoothBecameUnavailable()`
- **Line**: 3242
- **Signature**: `void _onBluetoothBecameUnavailable()`
- **Purpose**: Handle Bluetooth becoming unavailable
- **Key Logic**:
  - Clears session state only if active session exists
  - Disposes handshake coordinator
  - Clears peripheral state: `_connectedCentral`, `_connectedCharacteristic`, `_peripheralHandshakeStarted`
  - Provides specific status message based on Bluetooth state (off/unauthorized/unsupported/unknown)

---

## Helper/Utility Methods

**Method 16**: `_getPhaseMessage(ConnectionPhase phase)`
- **Line**: 2724
- **Signature**: `String _getPhaseMessage(ConnectionPhase phase)`
- **Purpose**: Convert handshake phase to user-friendly status message
- **Key Logic**: Switch statement mapping phases to messages:
  - bleConnected → "Connected..."
  - readySent → "Synchronizing..."
  - identityComplete → "Identity verified..."
  - noiseHandshake1Sent → "Establishing secure session..."
  - noiseHandshakeComplete → "Secure session established..."
  - complete → "Ready to chat"
  - timeout → "Connection timeout"
  - failed → "Connection failed"

**Method 17**: `_onBluetoothInitializationRetry()`
- **Line**: 3306
- **Signature**: `void _onBluetoothInitializationRetry()`
- **Purpose**: Handle Bluetooth initialization retry
- **Key Logic**: Updates status to "Checking Bluetooth status..."

---

## Stream/Provider API

**Property**: `connectionInfo` Stream
- **Line**: 155-156
- **Signature**: `Stream<ConnectionInfo> get connectionInfo => _connectionInfoController!.stream`
- **Purpose**: Broadcast connection state to UI

---

## Integration Points with Other Classes

### BLEConnectionManager Delegation
These methods delegate to `_connectionManager` (BLEConnectionManager):
- `startConnectionMonitoring()` → `_connectionManager.startConnectionMonitoring()`
- `stopConnectionMonitoring()` → `_connectionManager.stopConnectionMonitoring()`
- `setHandshakeInProgress(inProgress)` → `_connectionManager.setHandshakeInProgress(inProgress)`
- `disconnect()` → `_connectionManager.disconnect()`
- `connectToDevice(device)` → `_connectionManager.connectToDevice(device)` (+ single-link logic)

### StateManager Integration
- `_updateConnectionInfo()` updates `_currentConnectionInfo`
- `attemptIdentityRecovery()` calls `_stateManager.recoverIdentityFromStorage()`
- `getConnectionInfoWithFallback()` calls `_stateManager.getIdentityWithFallback()`
- Session clearing: `_stateManager.clearSessionState()`

### DeviceDeduplicationManager Integration
- `_setupAutoConnectCallback()` sets `DeviceDeduplicationManager.onKnownContactDiscovered`
- `_setupDeduplicationListener()` listens to `DeviceDeduplicationManager.uniqueDevicesStream`

### HandshakeCoordinator Integration
- `_onBluetoothBecameUnavailable()` calls `_disposeHandshakeCoordinator()`
- Handshake phase updates trigger `_updateConnectionInfo()` with phase-specific messages

---

## Critical Invariants

1. **Connection State Preservation**: Advertising state never cleared by accident
   - `_updateConnectionInfo()` uses `_authoritativeAdvertisingState` as default
   - `_shouldEmitConnectionInfo()` prevents spurious updates

2. **Deduplication**: `_lastEmittedConnectionInfo` prevents duplicate emissions
   - Only emits if meaningful change detected
   - Saves state between updates

3. **Session Cleanup**: Only clears session state if active session exists
   - Prevents verbose logging on redundant clears
   - Checks `_stateManager.otherUserName`, `_connectedCentral`, `_connectionManager.connectedDevice`

4. **Single-Link Policy**: Adopts inbound links when available
   - In `connectToDevice()`, checks if inbound link exists to target device
   - Skips outbound connection if inbound already established

5. **Dual-Role State**: Separate peripheral and central state tracking
   - Peripheral: `_connectedCentral`, `_connectedCharacteristic`
   - Central: `_connectionManager.connectedDevice`, `_connectionManager.messageCharacteristic`

---

## Lifecycle Summary

1. **Initialization** (in AppCore/initialize):
   - `_connectionInfoController` created
   - `_setupDeduplicationListener()` called
   - `_setupAutoConnectCallback()` called
   - `_setupEventListeners()` called

2. **Connection Flow**:
   - User taps device → `connectToDevice(device)`
   - `_connectionManager.connectToDevice()` establishes BLE link
   - Health checks start if outbound, or inbound adopted
   - `_updateConnectionInfo()` broadcasts connection state

3. **Handshake Flow**:
   - `HandshakeCoordinator` triggers phase transitions
   - Each phase calls `_updateConnectionInfo()` with phase message
   - Phase completion updates status (e.g., "Ready to chat")

4. **Disconnection**:
   - User taps disconnect → `disconnect()`
   - BLEConnectionManager closes link
   - Session state cleared if needed
   - `_updateConnectionInfo()` broadcasts disconnect

5. **Bluetooth Unavailable**:
   - Bluetooth stack notifies unavailable
   - `_onBluetoothBecameUnavailable()` fires
   - Session cleared, handshake disposed
   - Status updated to reason (off/unauthorized/etc)

---

## Line Number Index (Quick Reference)

| Component | Start Line | End Line | Type |
|-----------|-----------|----------|------|
| _connectionInfoController | 111 | 111 | Field |
| _connectedCentral | 127 | 127 | Field |
| _connectedCharacteristic | 128 | 128 | Field |
| _connectionManager | 78 | 78 | Field |
| _currentConnectionInfo | 176 | 176 | Field |
| _lastEmittedConnectionInfo | 174 | 174 | Field |
| isConnected getter | 184 | 211 | Getter |
| currentConnectionInfo getter | 157 | 157 | Getter |
| isMonitoring getter | 214 | 214 | Getter |
| connectionInfo Stream | 155 | 156 | Property |
| _authoritativeAdvertisingState | 848 | 862 | Getter |
| _updateConnectionInfo | 864 | 925 | Method |
| _shouldEmitConnectionInfo | 927 | 940 | Method |
| _setupAutoConnectCallback | 943 | 1017 | Method |
| _setupDeduplicationListener | 1020 | 1041 | Method |
| _setupEventListeners | 1043 | 1202+ | Method |
| requestIdentityExchange | 2345 | 2354 | Method |
| connectToDevice | 2286 | 2343 | Method |
| _getPhaseMessage | 2724 | 2753 | Method |
| getConnectionInfoWithFallback | 3084 | 3117 | Method |
| attemptIdentityRecovery | 3120 | 3177 | Method |
| startConnectionMonitoring | 3070 | 3071 | Method |
| stopConnectionMonitoring | 3072 | 3073 | Method |
| setHandshakeInProgress | 3074 | 3075 | Method |
| disconnect | 3076 | 3076 | Method |
| _onBluetoothBecameReady | 3179 | 3239 | Method |
| _onBluetoothBecameUnavailable | 3242 | 3303 | Method |
| _onBluetoothInitializationRetry | 3306 | 3311 | Method |

---

## Estimation: Extracted Lines

**Public Interface** (to keep in BLEService):
- getConnectionInfoWithFallback (~35 lines)
- attemptIdentityRecovery (~60 lines)
- requestIdentityExchange (~10 lines)
- Delegation methods: startConnectionMonitoring, stopConnectionMonitoring, setHandshakeInProgress, disconnect (~4 lines)
- Properties: connectedCentral, currentConnectionInfo, isConnected, isMonitoring, isActivelyReconnecting, hasPeripheralConnection, hasCentralConnection, canSendMessages, connectionInfo Stream (~50 lines)
- **Subtotal**: ~160 lines

**Extracted to BLEConnectionService**:
- _connectionInfoController declaration (~1 line)
- _connectedCentral, _connectedCharacteristic, peripheral state (~10 lines)
- connectionManager delegate (~1 line) 
- _currentConnectionInfo, _lastEmittedConnectionInfo (~3 lines)
- _updateConnectionInfo (~65 lines)
- _shouldEmitConnectionInfo (~15 lines)
- _setupAutoConnectCallback (~75 lines)
- _setupDeduplicationListener (~22 lines)
- _setupEventListeners (~160 lines)
- _getPhaseMessage (~35 lines)
- _onBluetoothBecameReady (~60 lines)
- _onBluetoothBecameUnavailable (~65 lines)
- _onBluetoothInitializationRetry (~5 lines)
- **Subtotal**: ~480 lines

**Total**: ~640 lines of code (extraction + retained)

---

## Suggested Split Strategy

### Keep in BLEService (Orchestrator Role)
1. High-level message API: `sendMessage()`, `sendEncryptedMessage()`
2. Device discovery: `startScanning()`, `stopScanning()`
3. Peripheral mode: `startAsPeripheral()`, `stopAsPeripheral()`
4. Public connection getters: `isConnected`, `currentConnectionInfo`, `connectedDevice`, etc.
5. Public connection API: `connectToDevice()`, `disconnect()`, `requestIdentityExchange()`

### Move to BLEConnectionService (New Class)
1. All private connection state: `_connectedCentral`, `_connectedCharacteristic`, `_currentConnectionInfo`
2. Connection info stream: `_connectionInfoController`, `connectionInfo` getter
3. State management: `_updateConnectionInfo()`, `_shouldEmitConnectionInfo()`, `_lastEmittedConnectionInfo`
4. Initialization: `_setupAutoConnectCallback()`, `_setupDeduplicationListener()`, `_setupEventListeners()`
5. Bluetooth lifecycle: `_onBluetoothBecameReady()`, `_onBluetoothBecameUnavailable()`, `_onBluetoothInitializationRetry()`
6. Fallback methods: `getConnectionInfoWithFallback()`, `attemptIdentityRecovery()`
7. Utilities: `_getPhaseMessage()`

---

## Next Steps

1. **Create BLEConnectionService class** in `lib/data/services/ble_connection_service.dart`
2. **Move extracted methods** with their dependencies
3. **Update BLEService** to inject BLEConnectionService and use its public API
4. **Update tests** to mock/inject BLEConnectionService
5. **Verify compilation** and run integration tests
6. **Document in CLAUDE.md** with new architecture diagram
