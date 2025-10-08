# Handshake Protocol Implementation Guide

## Overview
This guide shows how to integrate the HandshakeCoordinator and PeripheralInitializer into BLEService to fix timing issues between devices with different chipsets.

## Step 1: Add Class Members

In `BLEService` class (around line 68), add:

```dart
// Sub-components
late final BLEConnectionManager _connectionManager;
late final BLEMessageHandler _messageHandler;
final BLEStateManager _stateManager = BLEStateManager();

// NEW: Handshake protocol coordinator
HandshakeCoordinator? _handshakeCoordinator;

// NEW: Peripheral initialization helper
late final PeripheralInitializer _peripheralInitializer;
```

## Step 2: Initialize PeripheralInitializer

In `initialize()` method (around line 203), add after message handler initialization:

```dart
_messageHandler = BLEMessageHandler();
BackgroundCacheService.initialize();

// NEW: Initialize peripheral initializer
_peripheralInitializer = PeripheralInitializer(peripheralManager);
```

## Step 3: Fix startAsPeripheral()

Replace current `startAsPeripheral()` method (lines 937-1063) with:

```dart
Future<void> startAsPeripheral() async {
  _logger.info('Starting as Peripheral (discoverable)...');

  final preservedOtherPublicKey = _stateManager.otherDevicePersistentId;
  final preservedOtherName = _stateManager.otherUserName;
  final preservedTheyHaveUs = _stateManager.theyHaveUsAsContact;
  final preservedWeHaveThem = await _stateManager.weHaveThemAsContact;

  _stateManager.setPeripheralMode(true);
  _connectionManager.setPeripheralMode(true);

  if (_connectionManager.connectedDevice != null) {
    try {
      await _connectionManager.disconnect();
    } catch (e) {
      _logger.warning('Error disconnecting during mode switch: $e');
    }
  }

  _connectedCentral = null;
  _connectedCharacteristic = null;
  _peripheralNegotiatedMTU = null;

  try {
    await centralManager.stopDiscovery();
  } catch (e) {
    // Ignore
  }

  _updateConnectionInfo(
    isConnected: false,
    isReady: false,
    otherUserName: null,
    statusMessage: 'Initializing peripheral mode...'
  );

  _stateManager.preserveContactRelationship(
    otherPublicKey: preservedOtherPublicKey,
    otherName: preservedOtherName,
    theyHaveUs: preservedTheyHaveUs,
    weHaveThem: preservedWeHaveThem,
  );

  _discoveredDevices.clear();
  _devicesController?.add([]);

  try {
    // ✅ FIX: Use safe peripheral initialization
    _logger.info('🔧 Preparing peripheral manager...');

    final messageCharacteristic = GATTCharacteristic.mutable(
      uuid: BLEConstants.messageCharacteristicUUID,
      properties: [
        GATTCharacteristicProperty.read,
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
        GATTCharacteristicProperty.notify,
      ],
      permissions: [
        GATTCharacteristicPermission.read,
        GATTCharacteristicPermission.write,
      ],
      descriptors: [],
    );

    final service = GATTService(
      uuid: BLEConstants.serviceUUID,
      isPrimary: true,
      includedServices: [],
      characteristics: [messageCharacteristic],
    );

    // ✅ FIX: Safely add service with proper initialization wait
    final serviceAdded = await _peripheralInitializer.safelyAddService(
      service,
      timeout: Duration(seconds: 5),
    );

    if (!serviceAdded) {
      throw Exception('Failed to add GATT service - peripheral not ready');
    }

    // Get intro hint (if any active QR)
    final introHint = await _introHintRepo.getMostRecentActiveHint();

    // Compute my ephemeral hint for contacts
    final myPublicKey = await _stateManager.getMyPersistentId();
    final mySharedSeed = await _getOrGenerateMySharedSeed(myPublicKey);
    final mySensitiveHint = mySharedSeed != null
        ? SensitiveContactHint.compute(
            contactPublicKey: myPublicKey,
            sharedSeed: mySharedSeed,
          )
        : null;

    // Pack hints into advertisement
    final advData = HintAdvertisementService.packAdvertisement(
      introHint: introHint,
      ephemeralHint: mySensitiveHint,
    );

    _logger.info('📡 Advertising: intro=${introHint?.hintHex ?? "none"}, sensitive=${mySensitiveHint?.hintHex ?? "none"}');

    final advertisement = Advertisement(
      name: null,
      serviceUUIDs: [BLEConstants.serviceUUID],
      manufacturerSpecificData: Platform.isIOS || Platform.isMacOS ? [] : [
        ManufacturerSpecificData(
          id: 0x2E19,
          data: advData,
        ),
      ],
    );

    // ✅ FIX: Safely start advertising with proper initialization wait
    final advertisingStarted = await _peripheralInitializer.safelyStartAdvertising(
      advertisement,
      timeout: Duration(seconds: 5),
    );

    if (!advertisingStarted) {
      throw Exception('Failed to start advertising - peripheral not ready');
    }

    _stateManager.setPeripheralMode(true);
    _connectionManager.setPeripheralMode(true);
    _updateConnectionInfo(isAdvertising: true, statusMessage: 'Advertising - discoverable');
    _logger.info('✅ Now advertising as discoverable device!');

  } catch (e, stack) {
    _logger.severe('Failed to start as peripheral: $e', e, stack);
    _updateConnectionInfo(
      isAdvertising: false,
      statusMessage: 'Peripheral mode failed'
    );
    rethrow;
  }
}
```

## Step 4: Replace Name Exchange with Handshake Protocol

Replace `_performNameExchangeWithRetry()` (lines 1285-1317) with:

```dart
Future<void> _performHandshake() async {
  _logger.info('🤝 Starting handshake protocol...');

  try {
    final myPublicKey = await _stateManager.getMyPersistentId();
    final myDisplayName = _stateManager.myUserName ?? 'User';

    // Create handshake coordinator
    _handshakeCoordinator = HandshakeCoordinator(
      myPublicKey: myPublicKey,
      myDisplayName: myDisplayName,
      sendMessage: _sendHandshakeMessage,
      onHandshakeComplete: _onHandshakeComplete,
      checkHaveAsContact: _checkHaveAsContact,
      phaseTimeout: Duration(seconds: 10),
    );

    // Listen to phase changes for UI feedback
    _handshakeCoordinator!.phaseStream.listen((phase) {
      _logger.info('🤝 Handshake phase: $phase');
      _updateConnectionInfo(statusMessage: _getPhaseMessage(phase));
    });

    // Start the handshake
    await _handshakeCoordinator!.startHandshake();

  } catch (e, stack) {
    _logger.severe('🚨 Handshake failed: $e', e, stack);
    _updateConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Connection failed'
    );
  }
}

/// Send handshake protocol messages
Future<void> _sendHandshakeMessage(ProtocolMessage message) async {
  if (_connectionManager.hasBleConnection && _connectionManager.messageCharacteristic != null) {
    await centralManager.writeCharacteristic(
      _connectionManager.connectedDevice!,
      _connectionManager.messageCharacteristic!,
      value: message.toBytes(),
      type: GATTCharacteristicWriteType.withResponse,
    );
  } else if (isPeripheralMode && _connectedCentral != null && _connectedCharacteristic != null) {
    await peripheralManager.notifyCharacteristic(
      _connectedCentral!,
      _connectedCharacteristic!,
      value: message.toBytes(),
    );
  }
}

/// Called when handshake completes successfully
Future<void> _onHandshakeComplete(String publicKey, String displayName) async {
  _logger.info('🎉 Handshake complete! Connected to: $displayName');

  // Store identity
  _stateManager.setOtherDeviceIdentity(publicKey, displayName);

  // Check if we already have chat history
  final myPublicKey = await _stateManager.getMyPersistentId();
  final chatId = ChatUtils.generateChatId(myPublicKey, publicKey);
  final messageRepo = MessageRepository();
  final existingMessages = await messageRepo.getMessages(chatId);

  // Only save contact if we have chat history
  if (existingMessages.isNotEmpty) {
    await _stateManager.saveContact(publicKey, displayName);
    _logger.info('Contact restored from existing chat history: $displayName');
  }

  await _stateManager.initializeContactFlags();

  // Update last seen
  final chatsRepo = ChatsRepository();
  await chatsRepo.updateContactLastSeen(publicKey);
  await chatsRepo.storeDeviceMapping(_connectionManager.connectedDevice?.uuid.toString(), publicKey);

  // Process any buffered messages
  _processPendingMessages();

  // Update UI
  _updateConnectionInfo(
    isConnected: true,
    isReady: true,
    otherUserName: displayName,
    statusMessage: 'Ready to chat',
  );
}

/// Check if we have someone as contact
Future<bool> _checkHaveAsContact(String publicKey) async {
  final contact = await _stateManager.getContact(publicKey);
  return contact != null;
}

/// Convert connection phase to user-friendly message
String _getPhaseMessage(ConnectionPhase phase) {
  switch (phase) {
    case ConnectionPhase.bleConnected:
      return 'Connected...';
    case ConnectionPhase.readySent:
    case ConnectionPhase.readyAckWaiting:
      return 'Synchronizing...';
    case ConnectionPhase.readyComplete:
      return 'Ready check complete...';
    case ConnectionPhase.identitySent:
    case ConnectionPhase.identityAckWaiting:
      return 'Exchanging identities...';
    case ConnectionPhase.identityComplete:
      return 'Identity verified...';
    case ConnectionPhase.contactStatusSent:
    case ConnectionPhase.contactStatusAckWaiting:
      return 'Syncing contact status...';
    case ConnectionPhase.contactStatusComplete:
      return 'Contact status synced...';
    case ConnectionPhase.sessionReadySent:
      return 'Finalizing connection...';
    case ConnectionPhase.complete:
      return 'Ready to chat';
    case ConnectionPhase.timeout:
      return 'Connection timeout';
    case ConnectionPhase.failed:
      return 'Connection failed';
    default:
      return 'Connecting...';
  }
}
```

## Step 5: Route Handshake Messages

In `_handleReceivedData()` method (around line 707), add routing for handshake messages BEFORE other protocol messages:

```dart
Future<void> _handleReceivedData(Uint8List data, {required bool isFromPeripheral, Central? central, GATTCharacteristic? characteristic}) async {
  try {
    final protocolMessage = ProtocolMessage.fromBytes(data);

    // ✅ NEW: Route handshake protocol messages to coordinator
    if (_handshakeCoordinator != null && _isHandshakeMessage(protocolMessage.type)) {
      await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
      return;
    }

    // ... existing contactStatus handling ...
    // ... existing identity handling ...
    // ... rest of protocol message handling ...

  } catch (e) {
    // Not a protocol message, continue to regular message processing
  }

  // ... existing message processing logic ...
}

/// Check if message type is part of handshake protocol
bool _isHandshakeMessage(ProtocolMessageType type) {
  return type == ProtocolMessageType.connectionReady ||
         type == ProtocolMessageType.connectionReadyAck ||
         type == ProtocolMessageType.identityAck ||
         type == ProtocolMessageType.contactStatusAck ||
         type == ProtocolMessageType.sessionReady ||
         type == ProtocolMessageType.sessionReadyAck;
}
```

## Step 6: Update Connection Callback

In `initialize()` method, update `_connectionManager.onConnectionComplete` callback (around line 256):

```dart
_connectionManager.onConnectionComplete = () async {
  _logger.info('Connection complete - starting handshake protocol');

  // CRITICAL: Stop discovery after successful connection
  try {
    await centralManager.stopDiscovery();
    _logger.info('Stopped discovery after successful connection');
  } catch (e) {
    // Ignore
  }

  // ✅ NEW: Use handshake protocol instead of simple name exchange
  await _performHandshake();
};
```

## Step 7: Clean Up on Dispose

In `dispose()` method (around line 1723), add:

```dart
void dispose() {
  // NEW: Dispose handshake coordinator
  _handshakeCoordinator?.dispose();

  // ... existing dispose logic ...
}
```

## Testing the Implementation

### Test 1: Peripheral Initialization (Friend's Device)
1. Start as peripheral on friend's device
2. Check logs for:
   - ✅ "Peripheral ready after Xms"
   - ✅ "GATT service added successfully"
   - ✅ "Advertising started successfully"
3. Should NOT see "IllegalStateException"

### Test 2: Handshake Protocol (Both Devices)
1. Device A connects to Device B
2. Watch logs for handshake phases:
   - 📤 Phase 0: Sending connectionReady
   - 📥 Received connectionReadyAck
   - ✅ Phase 0 Complete: Both devices ready
   - 📤 Phase 1: Sending identity
   - 📥 Received identityAck
   - ✅ Phase 1 Complete: Identity exchange done
   - ... (continues through all phases)
   - 🎉 HANDSHAKE COMPLETE!
3. Both devices should see each other's names

### Test 3: Slow Device Handling
1. Use oldest Android device available
2. Should work even if phases take longer
3. Timeouts are 10s per phase (vs old 3s total)
4. Each phase confirms before proceeding

## Migration Notes

### Removed Code
- `_performNameExchangeWithRetry()` - replaced by `_performHandshake()`
- Hard-coded 3-second timeout logic
- "Fire and hope" identity exchange

### New Code
- `HandshakeCoordinator` - manages multi-phase handshake
- `PeripheralInitializer` - handles peripheral timing
- Phase-based state machine
- Explicit ACK for every communication

### Backward Compatibility
- Old protocol messages still work for existing features
- Only identity exchange uses new handshake protocol
- Can be extended to other features later

## Future Extensions

This handshake framework can be reused for:
- Secure pairing (add `pairingReady` phase)
- Feature negotiation (add `capabilitiesExchange` phase)
- Encryption setup (add `keyExchange` phase)

Each new feature just adds new phases with their own ACKs, following the same pattern.

## Key Benefits

1. **No Race Conditions**: Every step waits for explicit confirmation
2. **Device-Agnostic**: Works on fast and slow devices
3. **Future-Proof**: Easy to add new phases
4. **Debuggable**: Clear logging of each phase
5. **Reliable**: Timeouts per phase, not total
6. **Extensible**: Reusable pattern for any future protocol additions

This ensures **ANY device** can reliably connect, regardless of chipset speed! 🎉
